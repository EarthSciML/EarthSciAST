//! Solver plumbing on [`ArrayCompiled`]: `solve` / `solve_inspect`
//! (diffsol problem build, RHS/Jacobian closures, observed trajectory
//! exposure), the `debug_*` RHS entry points, and the external forcing-channel
//! handle ([`ArrayCompiled::forcing_handle`]).

#[cfg(feature = "solve")]
use super::tape::TapeProgram;
use super::tape::tape_disabled;
use super::*;
#[cfg_attr(not(feature = "solve"), allow(unused_imports))]
use crate::simulate::SimulateError;
#[cfg(feature = "solve")]
use crate::simulate::{
    Alg, Progress, ProgressFn, ReturnCode, Solution, SolutionMetadata, SolveOptions, SolveStats,
};
// The solver is optional (esm-libraries-spec §2.5.9). Everything below that
// touches `diffsol` is gated on the `solve` feature; the `debug_*` RHS entry
// points and the forcing-channel handle are not, because a caller that only
// BUILDS a EsmProblem still reaches them.
#[cfg(feature = "solve")]
use diffsol::{Bdf, FaerLU, FaerMat, NewtonNonlinearSolver, OdeBuilder, Sdirk, VectorHost};
use std::collections::HashSet;

/// A taped read-out of every observed, at one state and one time.
///
/// Under [`RuntimeMode::Native`] every rule is on the tape — construction
/// refused the document otherwise — so the observeds a setup or output-time
/// pass needs are already computed by the tape's own CONST / SEGMENT /
/// CONTINUOUS sections. This runs the tape with its `Export` publishes forced
/// on and hands back the published map.
///
/// It exists because the passes it replaces evaluated the SAME rules through
/// the whole-array overlay, with the per-cell oracle beneath it and no entry in
/// any fallback report — the silent demotion `esm-libraries-spec.md` §2.5.10
/// refuses, and one that a gate over `Instr::Fallback` alone cannot see,
/// because the overlay declines on its own terms. Serving them from the tape
/// makes the gate honest: there is no second evaluator left to disagree.
///
/// The production RHS scratch keeps its exports OFF (with no fallback rule
/// nothing can read them, and the publish is a memcpy per observed per call),
/// so this carries its own scratch and its own slab.
#[cfg(feature = "solve")]
struct TapedObserveds {
    scratch: RhsScratch,
    /// The tape writes `dy` whether or not the caller wants it; a setup or
    /// output-time pass does not, so it lands here and is discarded.
    dy: Vec<f64>,
}

#[cfg(feature = "solve")]
impl TapedObserveds {
    fn new(compiled: &ArrayCompiled, tape: &(Rc<TapeProgram>, Rc<Vec<AlgebraicRule>>)) -> Self {
        let mut scratch = RhsScratch::new(&compiled.var_shapes);
        scratch.set_const_arrays(Rc::clone(&compiled.const_scope));
        scratch.install_tape(Rc::clone(&tape.0), Rc::clone(&tape.1));
        scratch.set_exports_active(true);
        TapedObserveds {
            scratch,
            dy: vec![0.0f64; compiled.n_states],
        }
    }

    /// The map the last [`Self::at`] published, without running the tape
    /// again — so the node-0 values that decided the row layout are recorded
    /// rather than recomputed.
    fn scratch_observeds(&self) -> &ArrMap {
        self.scratch
            .taped_observeds()
            .expect("the harvester installs a tape on its own scratch")
    }

    /// Every observed's value at `state` and `t`, published by the tape.
    ///
    /// The CONST and SEGMENT sections prime on the first call and are not
    /// re-run while the parameter vector is unchanged, so a sweep over output
    /// nodes pays for the CONTINUOUS section only — the same amortization the
    /// static hoist existed to provide.
    fn at(&mut self, compiled: &ArrayCompiled, state: &[f64], params: &[f64], t: f64) -> &ArrMap {
        for v in self.dy.iter_mut() {
            *v = 0.0;
        }
        evaluate_rhs_with_scratch(
            &RhsCall {
                rhs_rules: &compiled.rhs_rules,
                observed_rules: &compiled.observed_rules,
                var_shapes: &compiled.var_shapes,
                param_names: &compiled.param_names,
                state,
                params,
                forcing: &compiled.forcing,
                t,
                declared: &compiled.declared_names,
            },
            &mut self.dy,
            false,
            &mut RhsStats::default(),
            &mut self.scratch,
        );
        self.scratch
            .taped_observeds()
            .expect("the harvester installs a tape on its own scratch")
    }
}

/// The refusal a model that serves [`crate::Compiler::Xla`] gets when no
/// compiled program was installed on it.
///
/// It is `compiler_unavailable` rather than a refused rule because nothing
/// about the DOCUMENT is wrong: the build either never got as far as emitting
/// (no `xla` feature) or handed the integrator a model it had not finished.
#[cfg(feature = "solve")]
fn xla_not_installed() -> SimulateError {
    SimulateError::CompilerUnavailable {
        compiler: "xla",
        details: "this Problem names `xla` but carries no compiled program; the build did not \
                  install one, and the tape is NOT run in its place — a compiler that cannot \
                  run says so (esm-libraries-spec §2.5.10)"
            .to_string(),
    }
}

/// Run the compiled XLA right-hand side into `out`, routing a device failure
/// into `fault` (FIRST failure wins) and leaving `out` NaN so the solver stops
/// instead of integrating whatever was there before.
///
/// Shared by the production right-hand side and the finite-difference
/// Jacobian, which under [`crate::Compiler::Xla`] evaluate exactly the same
/// program; a second copy of the failure handling would be a second place to
/// get it wrong.
#[cfg(all(feature = "solve", feature = "xla"))]
fn run_xla_rhs(
    program: &crate::xla_runtime::CompiledRhs,
    fault: &Rc<RefCell<Option<String>>>,
    state: &[f64],
    params: &[f64],
    t: f64,
    out: &mut [f64],
) -> bool {
    match program.eval_into(state, params, t, out) {
        Ok(()) => true,
        Err(e) => {
            let mut slot = fault.borrow_mut();
            if slot.is_none() {
                *slot = Some(e.to_string());
            }
            for v in out.iter_mut() {
                *v = f64::NAN;
            }
            false
        }
    }
}

/// The finite-difference Jacobian-vector product `J v ≈ (f(y + εv) − f(y)) / ε`
/// the XLA arm of the integrator's Jacobian closure computes, with the
/// evaluation at the base point shared across calls and every buffer
/// allocated once.
///
/// diffsol assembles a Jacobian by calling the product once per column, all
/// at ONE `(y, p, t)`. Only `f(y + εv)` depends on the column, so keeping
/// `f(y)` makes a Jacobian of `n` states cost `n + 1` right-hand-side
/// evaluations instead of `2n` — and under [`crate::Compiler::Xla`] each one
/// is a host-to-device-to-host round trip. The kept `f(y)` is reused only
/// when `y`, `p` and `t` are bit-for-bit the ones it was computed at, and the
/// forcing buffer the right-hand side may read is fixed for the segment the
/// closure lives in, so the product is bit-identical to recomputing both
/// evaluations every call.
#[cfg(all(feature = "solve", any(test, feature = "xla")))]
struct FdJvp {
    base_y: Vec<f64>,
    base_p: Vec<f64>,
    base_t: f64,
    /// `f(base_y, base_p, base_t)`; meaningful only while `base_valid`.
    f_y: Vec<f64>,
    base_valid: bool,
    y_perturbed: Vec<f64>,
    f_yp: Vec<f64>,
}

#[cfg(all(feature = "solve", any(test, feature = "xla")))]
impl FdJvp {
    fn new(n_states: usize) -> Self {
        FdJvp {
            base_y: vec![0.0; n_states],
            base_p: Vec::new(),
            base_t: 0.0,
            f_y: vec![0.0; n_states],
            base_valid: false,
            y_perturbed: vec![0.0; n_states],
            f_yp: vec![0.0; n_states],
        }
    }

    /// Write `J(y, p, t) v` into `jv`. `eval(state, params, t, out)` fills
    /// `out` with the right-hand side and reports whether it succeeded; a
    /// failed evaluation of `f(y)` is not kept, so the next call tries again.
    fn apply(
        &mut self,
        y: &[f64],
        p: &[f64],
        t: f64,
        v: &[f64],
        jv: &mut [f64],
        mut eval: impl FnMut(&[f64], &[f64], f64, &mut [f64]) -> bool,
    ) {
        let n = y.len();
        let mut y_norm = 0.0f64;
        for &yi in y {
            y_norm += yi * yi;
        }
        let y_norm = y_norm.sqrt().max(1.0);
        let eps = f64::EPSILON.sqrt() * y_norm;

        let same_point = self.base_valid
            && self.base_t.to_bits() == t.to_bits()
            && same_bits(&self.base_y, y)
            && same_bits(&self.base_p, p);
        if !same_point {
            self.base_y.clear();
            self.base_y.extend_from_slice(y);
            self.base_p.clear();
            self.base_p.extend_from_slice(p);
            self.base_t = t;
            self.f_y.resize(n, 0.0);
            self.base_valid = eval(y, p, t, &mut self.f_y);
        }

        self.y_perturbed.clear();
        self.y_perturbed
            .extend(y.iter().zip(v).map(|(&yi, &vi)| yi + eps * vi));
        self.f_yp.resize(n, 0.0);
        eval(&self.y_perturbed, p, t, &mut self.f_yp);
        for ((out, &fp), &f0) in jv.iter_mut().zip(&self.f_yp).zip(&self.f_y) {
            *out = (fp - f0) / eps;
        }
    }
}

/// Bitwise slice equality: `-0.0` and `0.0` differ, and a `NaN` equals the
/// same `NaN`, which is what reusing a function value requires.
#[cfg(all(feature = "solve", any(test, feature = "xla")))]
fn same_bits(a: &[f64], b: &[f64]) -> bool {
    a.len() == b.len() && a.iter().zip(b).all(|(x, y)| x.to_bits() == y.to_bits())
}

/// One evaluation a model's field initial conditions performed
/// ([`ArrayCompiled::field_ic_records`]).
#[cfg(feature = "solve")]
#[derive(Clone, Debug)]
pub(crate) struct FieldIcRecord {
    /// The `ic` target, or the state-free observed materialized for its scope.
    pub name: String,
    /// `"initial condition"` or `"initial-condition scope"`.
    pub kind: &'static str,
    /// Whether the reference evaluator walked a `faq` in it cell by cell.
    pub per_cell: bool,
}

/// The field initial conditions construction resolved, held for the first
/// solve ([`ArrayCompiled::field_ic_records`] fills it, the first
/// `build_initial_state` takes it).
///
/// Construction has to evaluate every field `ic` — a strict compiler refuses
/// one it would walk per cell, and the report names the route of each — and
/// the first solve needs exactly those values, so resolving them twice was a
/// second full evaluation of every `ic` field on every Problem. The resolution
/// reads two inputs, and the memo answers only when neither has moved:
///
/// * the parameters, checked here bit for bit against the positional vector
///   the solve resolved (a [`crate::remake`] with new `p` shares this model and
///   misses);
/// * the provider forcing buffer, which is final by the time construction
///   records (the CONST providers are bound before the compiler gate runs) and
///   first refreshed AFTER the initial state is built. Taking the memo, rather
///   than keeping it, is what holds that: only the first solve can read it,
///   and every later one resolves from the buffer as it stands.
///
/// Initial-condition overrides are applied over the result, not read by it.
#[cfg(feature = "solve")]
pub(crate) struct FieldIcMemo {
    params: Vec<u64>,
    slots: HashMap<usize, f64>,
}

#[cfg(all(test, feature = "solve"))]
thread_local! {
    static FIELD_IC_RESOLUTIONS: std::cell::Cell<u64> = const { std::cell::Cell::new(0) };
}

/// Test hook: how many times this thread has resolved a model's field initial
/// conditions.
#[cfg(all(test, feature = "solve"))]
pub(crate) fn field_ic_resolutions() -> u64 {
    FIELD_IC_RESOLUTIONS.with(std::cell::Cell::get)
}

#[cfg(feature = "solve")]
fn param_bits(param_vec: &[f64]) -> Vec<u64> {
    param_vec.iter().map(|x| x.to_bits()).collect()
}

impl ArrayCompiled {
    /// Whether the TAPE serves this Problem's passes other than the right-hand
    /// side — the build-time materialization of constants and static
    /// observeds, the per-segment seed, the inspection snapshot and the
    /// observeds reported at output times (esm-libraries-spec §2.5.10).
    ///
    /// True under the two STRICT compilers, [`crate::Compiler::Native`] and
    /// [`crate::Compiler::Xla`], and for the same reason in both: each refuses
    /// the document unless every rule lowered to the tape, so there is no
    /// second evaluator left for those passes to drift against. Under `xla`
    /// the right-hand side itself runs on the emitted executable instead (see
    /// `is_xla`) — the emitted program's only output is `du`, so the
    /// observed passes stay on the tape the emitter was built from, which is
    /// still ONE evaluator rather than two.
    pub(crate) fn tape_serves_passes(&self) -> bool {
        matches!(self.runtime_mode, RuntimeMode::Native | RuntimeMode::Xla)
    }

    /// Whether this model serves a [`crate::Compiler::Xla`] build: the
    /// right-hand side (and the finite-difference Jacobian differenced out of
    /// it) is the XLA executable rather than the tape's own interpreter.
    pub(crate) fn is_xla(&self) -> bool {
        self.runtime_mode == RuntimeMode::Xla
    }

    /// Emit this model's tape as an XLA computation, compile it for the
    /// device, and install it as the right-hand side
    /// [`crate::Compiler::Xla`] runs (API_SPEC §5.8).
    ///
    /// Called ONCE, at construction, by [`crate::problem::esm_problem`] — so a
    /// model the emitter cannot lower is a BUILD refusal naming the rule
    /// rather than a surprise on the first step, and so the XLA compilation
    /// (seconds for a large program) is paid once per Problem rather than once
    /// per integration segment. Idempotent: a second call keeps the first
    /// executable.
    #[cfg(feature = "xla")]
    pub(crate) fn install_xla_rhs(&self) -> Result<(), crate::xla_runtime::CompileRhsError> {
        use crate::xla_runtime::{CompileRhsError, CompiledRhs};
        if self.xla_rhs.get().is_some() {
            return Ok(());
        }
        let program = CompiledRhs::compile(self)?;
        // The two length contracts `CompiledRhs::eval` would otherwise raise
        // per CALL, checked once here instead. After this the only way an
        // evaluation can fail is the device itself, which is what the run-time
        // error channel in [`Self::run_one_segment`] carries.
        if program.n_states() != self.n_states {
            return Err(CompileRhsError::Runtime(format!(
                "the emitted program returns {} state slots, the model has {}",
                program.n_states(),
                self.n_states
            )));
        }
        if program.params_len() < self.param_names.len() {
            return Err(CompileRhsError::Runtime(format!(
                "the emitted program takes {} parameters, the model has {}",
                program.params_len(),
                self.param_names.len()
            )));
        }
        let _ = self.xla_rhs.set(Rc::new(program));
        Ok(())
    }

    /// The installed XLA executable, when this model serves
    /// [`crate::Compiler::Xla`]. `None` under every other compiler, so a
    /// caller can hand the answer straight to the closure builders.
    #[cfg(feature = "xla")]
    pub(crate) fn xla_program(&self) -> Option<Rc<crate::xla_runtime::CompiledRhs>> {
        if self.is_xla() {
            self.xla_rhs.get().cloned()
        } else {
            None
        }
    }

    /// Whether this model serves a [`crate::Compiler::Interpreter`] build: no
    /// tape, and the whole-array overlay off, so every rule is walked per cell.
    pub(crate) fn is_interpreter(&self) -> bool {
        self.runtime_mode == RuntimeMode::Interpreter
    }

    /// The flatten-time merge map (issue #230): every state spelling an
    /// `operator_compose` renaming match DELETED, mapped onto the survivor.
    pub(crate) fn merged_renames(&self) -> &HashMap<String, String> {
        &self.merged_renames
    }

    /// A clonable handle to the external forcing buffer (PR-1, ess-14f.7). A
    /// driver that integrates this model in discrete-cadence segments holds the
    /// returned `Rc` and, at each cadence boundary, refreshes a loader-fed
    /// field: `compiled.forcing_handle().borrow_mut().insert(var, regridded)`.
    /// The captured RHS/Jacobian closures read the *same* buffer live on the
    /// next `step()`, so the refresh is reflected without rebuilding the
    /// problem. The buffer is shared (the handle and the closures clone one
    /// `Rc`); mutate it only *between* segments, never inside a solver step, to
    /// keep the RHS pure within a segment.
    pub fn forcing_handle(&self) -> Rc<RefCell<HashMap<String, ArrayD<f64>>>> {
        Rc::clone(&self.forcing)
    }

    /// Whether this model has anything for the ODE solver to integrate — at
    /// least one `D(var, t) = …` rule.
    ///
    /// An array model whose every equation is ALGEBRAIC compiles to observed
    /// rules and no `RhsRule`, so it evaluates without the integrator ever
    /// touching a value. That distinction is what
    /// `problem::reject_f32_integration` needs: a Float32 declaration is
    /// honourable for such a model and not for one with real dynamics.
    pub fn has_differential_equations(&self) -> bool {
        !self.rhs_rules.is_empty()
    }

    /// The single model's own namespace (the top-level `models` map key), or
    /// `None` on the flattened path, whose names are already qualified.
    ///
    /// The single-model build names its slots BARE (`u[1]`, `k`), because the
    /// raw `Model` it consumed carries no namespace; the flattened build
    /// qualifies them (`M.u[1]`). Reported here so
    /// [`crate::problem::EsmProblem`] can present ONE spelling whichever route
    /// its document took.
    pub(crate) fn namespace(&self) -> Option<&str> {
        self.namespace.as_deref()
    }

    /// The OBSERVED variables this model declares, in dependency order.
    ///
    /// What [`crate::problem::observed_trajectories`] resolves a caller's name
    /// against, with the §5.8 precedence.
    pub fn observed_variable_names(&self) -> Vec<String> {
        self.observed_rules
            .iter()
            .map(|r| observed_rule_var(r).clone())
            .collect()
    }

    pub fn state_variable_names(&self) -> &[String] {
        &self.scalar_state_names
    }
    pub fn parameter_names(&self) -> &[String] {
        &self.param_names
    }

    /// Cadence partition of the observed rules given the discrete-forcing names,
    /// as `(const, discrete, continuous)` sorted name lists. Exposed for the
    /// cadence-tier test: a forcing-derived but state-free / `t`-free observed
    /// must land in the DISCRETE tier (materialized once per segment), not
    /// CONTINUOUS (recomputed every step). Mirrors the split in `run_segmented`.
    #[doc(hidden)]
    pub fn debug_cadence_partition(
        &self,
        discrete_forcing: &[String],
    ) -> (Vec<String>, Vec<String>, Vec<String>) {
        let df: HashSet<String> = discrete_forcing.iter().cloned().collect();
        let const_set = self.classify_static_observeds(&df);
        let leq_discrete = self.classify_segment_invariant_observeds(&df, true);
        let mut const_: Vec<String> = const_set.iter().cloned().collect();
        let mut discrete: Vec<String> = leq_discrete
            .iter()
            .filter(|n| !const_set.contains(*n))
            .cloned()
            .collect();
        let mut continuous: Vec<String> = self
            .observed_rules
            .iter()
            .map(observed_rule_var)
            .filter(|n| !leq_discrete.contains(*n))
            .cloned()
            .collect();
        const_.sort();
        discrete.sort();
        continuous.sort();
        (const_, discrete, continuous)
    }

    /// Evaluate the RHS `f(state, t)` once and return `(dy, stats)`. Exposed for
    /// the no-scalarization verification (ess-bdm): callers compare the
    /// vectorized path (`force_scalar = false`) against the per-cell oracle
    /// (`force_scalar = true`) for bit-equivalence, and assert that the
    /// vectorized [`RhsStats::kernel_ops`] is independent of the grid size N.
    #[doc(hidden)]
    pub fn debug_eval_rhs(
        &self,
        state: &[f64],
        t: f64,
        params: &HashMap<String, f64>,
        force_scalar: bool,
    ) -> (Vec<f64>, RhsStats) {
        let param_vec = self.debug_resolve_params(params);
        let mut dy = vec![0.0f64; self.n_states];
        let mut stats = RhsStats::default();
        let mut scratch = RhsScratch::new(&self.var_shapes);
        scratch.set_const_arrays(Rc::clone(&self.const_scope));
        evaluate_rhs_with_scratch(
            &RhsCall {
                rhs_rules: &self.rhs_rules,
                observed_rules: &self.observed_rules,
                var_shapes: &self.var_shapes,
                param_names: &self.param_names,
                state,
                params: &param_vec,
                forcing: &self.forcing,
                t,
                declared: &self.declared_names,
            },
            &mut dy,
            force_scalar,
            &mut stats,
            &mut scratch,
        );
        (dy, stats)
    }

    /// Build a persistent [`RhsScratch`] sized to this model. Exposed for the
    /// zero-allocation verification (ess-mro): a counting-allocator test drives
    /// [`Self::debug_eval_rhs_into`] with a reused scratch and asserts that the
    /// steady-state vectorized RHS allocates nothing.
    #[doc(hidden)]
    pub fn debug_new_scratch(&self) -> RhsScratch {
        let mut s = RhsScratch::new(&self.var_shapes);
        s.set_const_arrays(Rc::clone(&self.const_scope));
        s
    }

    /// Build a scratch with the compiled tape installed (Step 3b) — what the
    /// production RHS closure carries. A document the tape cannot express at
    /// all ([`tape_disabled`]) gets a legacy scratch, so a caller can observe
    /// the routing through [`RhsScratch::has_tape`] /
    /// [`RhsStats::taped_rules`]. Exposed for the fast-executor A/B,
    /// allocation-steady-state and invalidation tests, driven through
    /// [`Self::debug_eval_rhs_into`].
    #[doc(hidden)]
    pub fn debug_new_scratch_taped(&self) -> RhsScratch {
        let mut s = RhsScratch::new(&self.var_shapes);
        s.set_const_arrays(Rc::clone(&self.const_scope));
        if !tape_disabled() {
            let (prog, _report) = self.build_tape(&HashSet::new());
            s.install_tape(Rc::new(prog), Rc::new(self.observed_rules.clone()));
        }
        s
    }

    /// Resolve a parameter map into the positional parameter vector once, so the
    /// zero-allocation RHS test can pre-build it outside the measured loop.
    #[doc(hidden)]
    pub fn debug_resolve_params(&self, params: &HashMap<String, f64>) -> Vec<f64> {
        let mut param_vec = vec![0.0f64; self.param_names.len()];
        for (i, name) in self.param_names.iter().enumerate() {
            if let Some(&v) = params.get(name) {
                param_vec[i] = v;
            } else if let Some(d) = self.param_defaults[i] {
                param_vec[i] = d;
            }
        }
        param_vec
    }

    /// Evaluate the vectorized RHS into a caller-owned `dy` using a caller-owned
    /// scratch — the allocation-free entry point. With a warmed scratch and a
    /// pre-resolved `param_vec`, this performs no heap allocation (ess-mro
    /// acceptance criterion 1).
    #[doc(hidden)]
    pub fn debug_eval_rhs_into(
        &self,
        state: &[f64],
        t: f64,
        param_vec: &[f64],
        dy: &mut [f64],
        scratch: &mut RhsScratch,
        stats: &mut RhsStats,
    ) {
        for slot in dy.iter_mut() {
            *slot = 0.0;
        }
        evaluate_rhs_with_scratch(
            &RhsCall {
                rhs_rules: &self.rhs_rules,
                observed_rules: &self.observed_rules,
                var_shapes: &self.var_shapes,
                param_names: &self.param_names,
                state,
                params: param_vec,
                forcing: &self.forcing,
                t,
                declared: &self.declared_names,
            },
            dy,
            false,
            stats,
            scratch,
        );
    }

    /// Whether every observed rule is a plain scalar expression: a
    /// [`AlgebraicRule::Scalar`] whose body [`check_scalar_evaluable`] admits
    /// (no array, tensor or geometry op).
    ///
    /// The precondition under which a stateless evaluation
    /// ([`Self::evaluate_stateless_observeds`]) is the whole answer for a
    /// document with nothing to integrate. A SHAPED document answers
    /// differently — from the fields its build materialized — so it is told
    /// apart here rather than by what an evaluation happens to produce.
    #[cfg(all(not(target_arch = "wasm32"), feature = "solve"))]
    pub(crate) fn observeds_are_scalar(&self) -> bool {
        self.observed_rules.iter().all(|rule| match rule {
            AlgebraicRule::Scalar { body, .. } => check_scalar_evaluable(body).is_ok(),
            _ => false,
        })
    }

    /// Every 0-D observed of a model with NO state vector, evaluated at each of
    /// `times` — `(name, values)` in dependency order, one value per time.
    ///
    /// The answer for a document with nothing to integrate: its observeds are
    /// pure functions of the parameters and `t`, so one evaluation per time is
    /// the whole of it, and no integrator is involved. Each evaluation is one
    /// right-hand-side call over the empty state, on the evaluator this model
    /// serves — the tape under `native` / `xla`, the per-cell oracle under
    /// `interpreter` — so the values are the ones a solve would report.
    ///
    /// Names are the rules' own (flattened on the `from_flattened` path, bare
    /// with [`Self::namespace`] on the single-model one). An observed with more
    /// than one cell is not reported; it has no scalar value per time. One
    /// declared with a single cell (`[1]`) is, and the caller decides its rank
    /// from the declaration.
    ///
    /// # Errors
    ///
    /// A parameter override that designates nothing, a parameter with neither
    /// an override nor a default, and any fault the evaluator latched (an
    /// out-of-range const-array gather, an unbound name) — all as a solve would
    /// report them. A model that HAS state is refused rather than read at a
    /// state nobody supplied.
    #[cfg(all(not(target_arch = "wasm32"), feature = "solve"))]
    pub(crate) fn evaluate_stateless_observeds(
        &self,
        params: &HashMap<String, f64>,
        times: &[f64],
    ) -> Result<Vec<(String, Vec<f64>)>, SimulateError> {
        let mut out: Vec<(String, Vec<f64>)> = Vec::new();
        self.stateless_pass(params, times, |k, obs| {
            if k == 0 {
                out = self
                    .observed_rules
                    .iter()
                    .map(observed_rule_var)
                    .filter(|name| obs.get(*name).is_some_and(|a| a.len() == 1))
                    .map(|name| (name.clone(), Vec::with_capacity(times.len())))
                    .collect();
            }
            for (name, values) in &mut out {
                let v = obs.get(name).and_then(|a| a.first().copied());
                values.push(v.unwrap_or(f64::NAN));
            }
        })?;
        Ok(out)
    }

    /// Every observed of a model with NO state vector, whatever its shape,
    /// evaluated once at `t` — `(name, field)` in dependency order.
    ///
    /// [`Self::evaluate_stateless_observeds`]'s single-time sibling for the
    /// build-time fields of a state-free document (`observed_field`): the same
    /// one right-hand-side call over the empty state, on the evaluator this
    /// model serves, so a shaped observed comes off the tape under `native`
    /// exactly as a scalar one does. Errors as that method's.
    pub(crate) fn evaluate_stateless_fields(
        &self,
        params: &HashMap<String, f64>,
        t: f64,
    ) -> Result<Vec<(String, ArrayD<f64>)>, SimulateError> {
        let mut out: Vec<(String, ArrayD<f64>)> = Vec::new();
        self.stateless_pass(params, &[t], |_, obs| {
            out = self
                .observed_rules
                .iter()
                .map(observed_rule_var)
                .filter_map(|name| obs.get(name).map(|a| (name.clone(), a.clone())))
                .collect();
        })?;
        Ok(out)
    }

    /// One right-hand-side call over the empty state per entry of `times`,
    /// handing `visit` the observeds each call published.
    fn stateless_pass(
        &self,
        params: &HashMap<String, f64>,
        times: &[f64],
        mut visit: impl FnMut(usize, &ArrMap),
    ) -> Result<(), SimulateError> {
        if self.n_states != 0 {
            return Err(SimulateError::Compile(
                crate::compile_error::CompileError::InterpreterBuildError {
                    details: format!(
                        "a stateless evaluation was asked of a model with {} state slot(s)",
                        self.n_states
                    ),
                },
            ));
        }
        let _precision_guard = self.precision.enter();
        let param_vec = self.build_param_vec(params)?;
        let mut scratch = RhsScratch::new(&self.var_shapes);
        scratch.set_const_arrays(Rc::clone(&self.const_scope));
        if self.tape_serves_passes() && !tape_disabled() {
            let (prog, _report) = self.build_tape(&HashSet::new());
            scratch.install_tape(Rc::new(prog), Rc::new(self.observed_rules.clone()));
            scratch.set_exports_active(true);
        }
        let mut dy: Vec<f64> = Vec::new();
        crate::simulate_array::take_const_array_oob();
        for (k, &t) in times.iter().enumerate() {
            evaluate_rhs_with_scratch(
                &RhsCall {
                    rhs_rules: &self.rhs_rules,
                    observed_rules: &self.observed_rules,
                    var_shapes: &self.var_shapes,
                    param_names: &self.param_names,
                    state: &[],
                    params: &param_vec,
                    forcing: &self.forcing,
                    t,
                    declared: &self.declared_names,
                },
                &mut dy,
                self.is_interpreter(),
                &mut RhsStats::default(),
                &mut scratch,
            );
            if let Some(details) = crate::simulate_array::take_const_array_oob() {
                return Err(
                    crate::compile_error::CompileError::InterpreterBuildError { details }.into(),
                );
            }
            let obs = scratch
                .taped_observeds()
                .unwrap_or_else(|| scratch.observed_arrays());
            visit(k, obs);
        }
        Ok(())
    }

    /// Resolve the deferred scoped-reference / array `ic` equations
    /// (esm-spec §11.4.1) into per-slot initial values keyed by flat state slot.
    /// A loaded-field RHS (`InitialConditions.O3_init`) is read from the
    /// provider-seeded forcing buffer and folded into the lifted grid state's cells
    /// (column-major, matching the slot enumeration in [`Self::from_model`]); a
    /// constant RHS broadcasts to every cell. Empty on the non-`ic` path.
    ///
    /// `records`, when given, receives one [`FieldIcRecord`] per evaluation
    /// this performs — each state-free observed materialized for the `ic`
    /// scope, then each target — saying whether it was walked per cell.
    #[cfg(feature = "solve")]
    fn resolve_field_ics(
        &self,
        params: &HashMap<String, f64>,
        mut records: Option<&mut Vec<FieldIcRecord>>,
    ) -> Result<HashMap<usize, f64>, SimulateError> {
        let mut out: HashMap<usize, f64> = HashMap::new();
        if self.field_ics.is_empty() {
            return Ok(out);
        }
        #[cfg(test)]
        FIELD_IC_RESOLUTIONS.with(|c| c.set(c.get() + 1));
        let walks = crate::simulate_array::per_cell_walks;
        // `interpreter` runs these on the per-cell oracle like every other
        // evaluation it performs; the other compilers leave the overlay on.
        let _overlay = OverlayGuard::armed(self.is_interpreter());
        // esm-spec §6.6.5 build-time scope: materialize the STATE-FREE array
        // observeds an `ic` RHS may read (a `const` gather, a parameter-only
        // expression) and overlay them on the provider forcing buffer. A
        // provider-served field of the same name still WINS — loaded data beats
        // a document-side definition, the same direction `vi_factor_arrays`
        // takes. An observed that does not evaluate is skipped rather than
        // raised on: it simply is not in the ic scope, and the resolver's own
        // diagnostic then names the unusable RHS.
        //
        // Built ONLY when the document has such definitions: with none (every
        // document before this), the resolver reads the forcing buffer straight
        // through and no provider field is copied.
        let borrowed = self.forcing.borrow();
        let mut scope: Option<HashMap<String, ArrayD<f64>>> = None;
        if !self.ic_scope_defs.is_empty() {
            let mut built: HashMap<String, ArrayD<f64>> = HashMap::new();
            // One pass per definition is enough for any acyclic chain: each
            // pass resolves at least the definitions whose dependencies are
            // already in scope, so `n` passes close a chain of length `n`.
            for _ in 0..self.ic_scope_defs.len() {
                let before = built.len();
                for (name, body) in &self.ic_scope_defs {
                    if built.contains_key(name) {
                        continue;
                    }
                    let before = walks();
                    if let Ok(Value::Array(arr)) =
                        eval_buildtime_field_in_scope(body, &self.index_sets, params, &built)
                    {
                        built.insert(name.clone(), *arr);
                        if let Some(sink) = records.as_deref_mut() {
                            sink.push(FieldIcRecord {
                                name: name.clone(),
                                kind: "initial-condition scope",
                                per_cell: walks() != before,
                            });
                        }
                    }
                }
                if built.len() == before {
                    break;
                }
            }
            for (name, arr) in borrowed.iter() {
                built.insert(name.clone(), arr.clone());
            }
            scope = Some(built);
        }
        let forcing: &HashMap<String, ArrayD<f64>> = scope.as_ref().unwrap_or(&borrowed);
        for (target, rhs) in &self.field_ics {
            let vs = self.var_shapes.get(target).ok_or_else(|| {
                SimulateError::InvalidFieldInitialCondition {
                    name: target.clone(),
                    details: "scoped-reference target is not a state variable of the flattened \
                              system"
                        .to_string(),
                }
            })?;
            let total = vs.shape.iter().copied().product::<usize>().max(1);
            // Coordinate-expression ICs (case 3 in `resolve_field_ic_cell`)
            // evaluate the WHOLE field with one `eval_buildtime_field` call and
            // then read a single cell — so recomputing it per cell was O(cells)
            // full-field evaluations for an O(cells)-sized result. Resolve it
            // once per target and let every cell index the cached field. The
            // cell-independent cases (1 loaded field / 2 constant) ignore it.
            let mut cached_field: Option<Value> = None;
            let before = walks();
            for flat in 0..total {
                let multi = flat_to_multi_col_major(flat, &vs.shape);
                let slot = vs.flat_offset + flat;
                out.insert(
                    slot,
                    resolve_field_ic_cell(
                        target,
                        rhs,
                        &multi,
                        forcing,
                        &self.index_sets,
                        params,
                        &mut cached_field,
                    )?,
                );
            }
            if let Some(sink) = records.as_deref_mut() {
                sink.push(FieldIcRecord {
                    name: target.clone(),
                    kind: "initial condition",
                    per_cell: walks() != before,
                });
            }
        }
        Ok(out)
    }

    /// Every evaluation the field initial conditions perform, exercised at
    /// CONSTRUCTION against `params` so a strict compiler can refuse a per-cell
    /// one there (esm-libraries-spec §2.5.10 asks that every evaluation a
    /// compiler performs for the Problem be exercised at construction) and the
    /// compiler report can show the route.
    ///
    /// Empty for a model with no field `ic`, and — deliberately — for one whose
    /// initial conditions cannot be resolved yet: `solve` resolves them again
    /// and raises the diagnostic there, where it always has been.
    ///
    /// `strict` is the compiler's: the first per-cell walk then stops at its
    /// first cell (see `StopAtFirstCell`), because its record is a refusal and
    /// the rest of the walk would buy nothing. A resolution that walked no cell
    /// is kept for the first solve ([`FieldIcMemo`]).
    #[cfg(feature = "solve")]
    pub(crate) fn field_ic_records(
        &self,
        params: &HashMap<String, f64>,
        strict: bool,
    ) -> Vec<FieldIcRecord> {
        if self.field_ics.is_empty() {
            return Vec::new();
        }
        let Ok(param_vec) = self.build_param_vec(params) else {
            return Vec::new();
        };
        let resolved: HashMap<String, f64> = self
            .param_names
            .iter()
            .cloned()
            .zip(param_vec.iter().copied())
            .collect();
        let _precision_guard = self.precision.enter();
        let mut records = Vec::new();
        let stop = strict.then(crate::simulate_array::StopAtFirstCell::arm);
        let result = self.resolve_field_ics(&resolved, Some(&mut records));
        if let Ok(slots) = result
            && !stop.as_ref().is_some_and(|s| s.stopped())
        {
            *self.field_ic_memo.borrow_mut() = Some(FieldIcMemo {
                params: param_bits(&param_vec),
                slots,
            });
        }
        records
    }

    /// The component / subsystem names a rule-2 override key may spell in its
    /// LEADING segments (esm-spec §6.6.2, §4.6).
    ///
    /// The namespace segments the build's own names carry cover a mounted
    /// subsystem (`sub` in `sub.g`) and, on the `from_flattened` path, every
    /// contributing component (`Left` in `Left.gain`). [`Self::namespace`]
    /// supplies the one namespace the names CANNOT show: the enclosing model's
    /// own, which the single-model path does not qualify its variables with —
    /// it is exactly what makes `P.sub.g` a legal spelling of `sub.g`.
    fn override_namespaces(&self) -> std::collections::HashSet<String> {
        crate::simulate::namespace_scope(
            self.param_names
                .iter()
                .chain(self.scalar_state_names.iter())
                .map(String::as_str),
            self.namespace.as_deref(),
        )
    }

    /// Run the simulation.
    /// Validate override parameter names and build the positional param
    /// vector (override > variable default; a parameter with neither is an
    /// [`SimulateError::InvalidParameter`]). The strict simulate-time
    /// counterpart of the lenient [`Self::debug_resolve_params`].
    fn build_param_vec(&self, params: &HashMap<String, f64>) -> Result<Vec<f64>, SimulateError> {
        // esm-spec §6.6.2 caller-key canonicalization (see
        // `crate::simulate::canonicalize_override_keys`). This subsumes the
        // former `normalize_override_keys`, which only stripped this model's
        // `<namespace>.` prefix: rule 2 resolves `M.A` against a bare-named
        // single-model system, and rule 3 resolves the LOCAL `A` against a
        // flattening-qualified `M.A` — which the prefix strip could not do.
        let params = crate::simulate::canonicalize_override_keys(
            &self.param_index,
            &self.override_namespaces(),
            params,
            &self.merged_renames,
        )
        .map_err(crate::simulate::param_key_error)?;
        let mut param_vec = vec![0.0f64; self.param_names.len()];
        for (i, name) in self.param_names.iter().enumerate() {
            if let Some(&v) = params.get(name) {
                param_vec[i] = v;
            } else if let Some(d) = self.param_defaults[i] {
                param_vec[i] = d;
            } else {
                return Err(SimulateError::InvalidParameter { name: name.clone() });
            }
        }
        Ok(param_vec)
    }

    /// Validate override initial-condition names and build the initial state
    /// vector `u0`. Scoped-reference / array `ic` fields (esm-spec §11.4.1)
    /// are folded in from the provider-seeded forcing buffer (DESIGN
    /// pde_simulation_pipeline §2 R2); priority per slot: explicit
    /// `initial_conditions` override > loaded field ic > variable default (a
    /// slot with none of the three is an
    /// [`SimulateError::InvalidInitialCondition`]).
    #[cfg(feature = "solve")]
    fn build_initial_state(
        &self,
        initial_conditions: &HashMap<String, f64>,
        param_vec: &[f64],
    ) -> Result<Vec<f64>, SimulateError> {
        // Same §6.6.2 canonicalization as `build_param_vec`, on the state side.
        let initial_conditions = crate::simulate::canonicalize_override_keys(
            &self.scalar_state_index,
            &self.override_namespaces(),
            initial_conditions,
            &self.merged_renames,
        )
        .map_err(crate::simulate::ic_key_error)?;
        // What construction resolved, when it resolved it under these
        // parameters ([`FieldIcMemo`]).
        let memo = self
            .field_ic_memo
            .borrow_mut()
            .take()
            .filter(|m| m.params == param_bits(param_vec));
        let field_ic_map = match memo {
            Some(m) => m.slots,
            None => {
                // Resolved scalar-parameter scope (load-time constants) for the
                // ic coordinate-expression path — a parameter-dependent
                // grid-geometry template (`x0 + (i − 1/2)·dx`) binds here; STATE
                // is not in scope.
                let resolved_params: HashMap<String, f64> = self
                    .param_names
                    .iter()
                    .cloned()
                    .zip(param_vec.iter().copied())
                    .collect();
                self.resolve_field_ics(&resolved_params, None)?
            }
        };
        let mut ic_vec = vec![0.0f64; self.n_states];
        for (i, name) in self.scalar_state_names.iter().enumerate() {
            if let Some(&v) = initial_conditions.get(name) {
                ic_vec[i] = v;
            } else if let Some(&v) = field_ic_map.get(&i) {
                ic_vec[i] = v;
            } else if let Some(d) = self.state_defaults[i] {
                ic_vec[i] = d;
            } else {
                return Err(SimulateError::InvalidInitialCondition { name: name.clone() });
            }
        }
        Ok(ic_vec)
    }

    #[cfg(feature = "solve")]
    pub fn solve(
        &self,
        tspan: (f64, f64),
        params: &HashMap<String, f64>,
        initial_conditions: &HashMap<String, f64>,
        opts: &SolveOptions,
    ) -> Result<Solution, SimulateError> {
        self.solve_inspect(tspan, params, initial_conditions, opts, None)
    }

    /// [`Self::solve`] with an optional build-observability sink (see
    /// [`BuildInspection`]). When `inspect` is `Some`, the sink is filled —
    /// after the initial state vector is assembled and before the solver runs —
    /// with the state-free observed arrays materialized at `u0`/`t0` and every
    /// observed rule's resolved body expression. The integration itself is
    /// byte-identical with or without a sink.
    #[cfg(feature = "solve")]
    pub fn solve_inspect(
        &self,
        tspan: (f64, f64),
        params: &HashMap<String, f64>,
        initial_conditions: &HashMap<String, f64>,
        opts: &SolveOptions,
        inspect: Option<&mut BuildInspection>,
    ) -> Result<Solution, SimulateError> {
        // Re-arm the precision this model was compiled under
        // (`crate::precision`); a no-op for a Float64 model.
        let _precision_guard = self.precision.enter();
        // CONST / single-segment: no discrete forcing, no refresh boundaries.
        self.solve_core(
            tspan,
            params,
            initial_conditions,
            opts,
            inspect,
            &HashSet::new(),
            &[],
            |_t| Ok(()),
        )
    }

    /// [`Self::solve_inspect`] with a DISCRETE-cadence forcing refresh. The
    /// integration is SEGMENTED on `boundaries` (solver-second refresh anchors);
    /// at each boundary `refresh_fn(t)` re-slices the live forcing buffer to that
    /// record. Observeds transitively reaching a `discrete_forcing` name are
    /// excluded from the build-once static hoist, so they recompute over the
    /// refreshed buffer per segment while the CONST terrain regrid stays hoisted.
    /// This is the Rust analog of the ESS-Julia live-field taint + segmented driver.
    #[allow(clippy::too_many_arguments)]
    #[cfg(all(feature = "solve", not(target_arch = "wasm32")))]
    pub(crate) fn solve_with_refresh_inspect(
        &self,
        tspan: (f64, f64),
        params: &HashMap<String, f64>,
        initial_conditions: &HashMap<String, f64>,
        opts: &SolveOptions,
        inspect: Option<&mut BuildInspection>,
        discrete_forcing: &HashSet<String>,
        boundaries: &[f64],
        refresh_fn: impl FnMut(f64) -> Result<(), SimulateError>,
    ) -> Result<Solution, SimulateError> {
        self.solve_core(
            tspan,
            params,
            initial_conditions,
            opts,
            inspect,
            discrete_forcing,
            boundaries,
            refresh_fn,
        )
    }

    /// Shared setup + segmented integration (see the two entry points above).
    /// `boundaries` are the sorted solver-second refresh anchors strictly inside
    /// `(t0, t_end)`; an empty `boundaries` (the CONST path) runs one segment,
    /// byte-identical to the un-segmented driver.
    #[allow(clippy::too_many_arguments)]
    #[cfg(feature = "solve")]
    fn solve_core(
        &self,
        tspan: (f64, f64),
        params: &HashMap<String, f64>,
        initial_conditions: &HashMap<String, f64>,
        opts: &SolveOptions,
        inspect: Option<&mut BuildInspection>,
        discrete_forcing: &HashSet<String>,
        boundaries: &[f64],
        mut refresh_fn: impl FnMut(f64) -> Result<(), SimulateError>,
    ) -> Result<Solution, SimulateError> {
        let params_owned = params;
        let ics_owned = initial_conditions;
        let (t0, t_end) = tspan;
        // Validated here, at the entry point every array solve shares, so the
        // non-advancing shortcut in `run_one_segment` and the solver path below
        // it are never handed a span they would read differently.
        crate::simulate::reject_nonfinite_span(t0, t_end)?;

        // Validate the override names and build the positional param vector
        // and the initial state vector `u0` (loaded-field / coordinate
        // `ic`s folded in — see [`Self::build_initial_state`]).
        // §5.5.5: the per-cell oracle LATCHES an out-of-range const-array gather
        // rather than raising (the tree walk returns a bare `Value`). Clear the
        // latch before the solve; `assemble_solution` drains it at every exit,
        // so a trajectory built on a const-array bug fails loudly instead of
        // carrying the `NaN` the gather substituted.
        crate::simulate_array::take_const_array_oob();
        let param_vec = self.build_param_vec(params_owned)?;
        let ic_vec = self.build_initial_state(ics_owned, &param_vec)?;

        // Seed the forcing buffer at t0 BEFORE the static hoist reads it — a
        // no-op for the CONST/single-segment path; for DISCRETE it primes the
        // first record so the static regrid geometry sees a populated buffer.
        refresh_fn(t0)?;

        // The tape is built BEFORE the static hoist, not after it. Under
        // either strict compiler the hoist is served FROM the tape (see
        // [`Self::hoist_static_observeds`]), so the order the two ran in was
        // itself the defect: the hoist evaluated every CONST-tier observed
        // through the whole-array overlay, once per solve, before the tape the
        // caller asked for had been built at all.
        let (tape, tape_fallbacks) = self.build_solve_tape(discrete_forcing);

        let cadence = self.partition_observed_cadence(discrete_forcing);
        let setup = self.hoist_static_observeds(cadence, &ic_vec, &param_vec, t0, tape.as_ref());

        if let Some(insp) = inspect {
            self.fill_solve_inspection(
                insp,
                &setup,
                &ic_vec,
                &param_vec,
                t0,
                boundaries,
                tape.as_ref(),
            );
        }

        let solver_name = match opts.alg {
            Alg::Bdf => "Bdf",
            Alg::Sdirk => "Sdirk",
            Alg::Erk => "Erk",
        };

        // CONST / single-segment (or no output grid to align segment samples on):
        // the original un-segmented run — byte-identical to the pre-segmentation
        // driver (one `run_one_segment` over the whole span with `opts` verbatim).
        if boundaries.is_empty() || opts.saveat.is_none() {
            let (time, state, stats, retcode) = self
                .run_one_segment(
                    t0,
                    t_end,
                    &ic_vec,
                    &param_vec,
                    &setup.static_obs,
                    &setup.cadence.segment_static_rules,
                    &setup.cadence.continuous_rules,
                    opts,
                    tape.as_ref(),
                )
                .map_err(Self::const_oob_first)?;
            return self.assemble_solution(
                time,
                state,
                retcode,
                solution_metadata(
                    solver_name,
                    &stats,
                    tape_fallbacks,
                    self.merged_renames.clone(),
                    self.namespace.clone(),
                ),
                &param_vec,
                &setup,
                &opts.output_observed,
                tape.as_ref(),
            );
        }

        let run = SegmentedRun {
            t0,
            t_end,
            boundaries,
            ic_vec: &ic_vec,
            param_vec: &param_vec,
            setup: &setup,
            opts,
            tape: tape.as_ref(),
        };
        let (time, state, stats, retcode) = self.run_segmented(&run, &mut refresh_fn)?;

        // Note: `assemble_solution` re-evaluates the varying observeds against
        // the CURRENT (last-segment) forcing buffer, so an appended scalar
        // observed reading a discrete forcing reflects the final hour — the
        // array STATE trajectory (the fire front) is per-segment correct, which
        // is what the runner reads.
        self.assemble_solution(
            time,
            state,
            retcode,
            solution_metadata(
                solver_name,
                &stats,
                tape_fallbacks,
                self.merged_renames.clone(),
                self.namespace.clone(),
            ),
            &param_vec,
            &setup,
            &opts.output_observed,
            tape.as_ref(),
        )
    }

    /// Three-tier cadence split of the observed rules (cadence.rs lattice
    /// `CONST ⊏ DISCRETE ⊏ CONTINUOUS`):
    ///
    /// ```text
    ///   * CONST      (static_rules)         — materialized ONCE at setup (see
    ///                                         hoist_static_observeds).
    ///   * DISCRETE   (segment_static_rules) — state-free & t-free but reaches a
    ///                                         refreshed forcing buffer; constant
    ///                                         WITHIN a segment, so materialized
    ///                                         once per segment in run_one_segment.
    ///   * CONTINUOUS (continuous_rules)     — reaches t or state; re-evaluated
    ///                                         every RHS step.
    /// ```
    ///
    /// Collapsing DISCRETE into CONTINUOUS (the old two-tier split) recomputed
    /// the per-cell conservative regrid every step — the dominant cost of a
    /// coupled loader model. `varying_rules` (DISCRETE ∪ CONTINUOUS) is retained
    /// for the non-hot observed-trajectory output pass.
    #[cfg(feature = "solve")]
    fn partition_observed_cadence(&self, discrete_forcing: &HashSet<String>) -> ObservedCadence {
        let static_names = self.classify_static_observeds(discrete_forcing);
        let seg_invariant_names = self.classify_segment_invariant_observeds(discrete_forcing, true);
        let static_rules: Vec<AlgebraicRule> = self
            .observed_rules
            .iter()
            .filter(|r| static_names.contains(observed_rule_var(r)))
            .cloned()
            .collect();
        let segment_static_rules: Vec<AlgebraicRule> = self
            .observed_rules
            .iter()
            .filter(|r| {
                seg_invariant_names.contains(observed_rule_var(r))
                    && !static_names.contains(observed_rule_var(r))
            })
            .cloned()
            .collect();
        let continuous_rules: Vec<AlgebraicRule> = self
            .observed_rules
            .iter()
            .filter(|r| !seg_invariant_names.contains(observed_rule_var(r)))
            .cloned()
            .collect();
        let varying_rules: Vec<AlgebraicRule> = self
            .observed_rules
            .iter()
            .filter(|r| !static_names.contains(observed_rule_var(r)))
            .cloned()
            .collect();
        ObservedCadence {
            static_names,
            static_rules,
            segment_static_rules,
            continuous_rules,
            varying_rules,
        }
    }

    /// Hoist the STATE-FREE / `t`-free observeds (ess: static-observed hoist)
    /// out of the per-step RHS. Within a single `simulate` call the forcing
    /// buffer is constant (the free `simulate` never refreshes it between
    /// segments), so a rule whose transitive references reach no state
    /// variable and no `t` is CONSTANT across the whole solve: the
    /// conservative-regrid geometry (`intersect_polygon` over the src×tgt cell
    /// rings), the regridded terrain and its slopes, the Rothermel
    /// coefficients derived from the CONST forcing. Materialize them ONCE here
    /// and seed them into every RHS eval, rather than recomputing the
    /// (expensive) regrid on every step. A model with no such observeds hoists
    /// nothing and stays byte-identical to the un-hoisted path.
    #[cfg(feature = "solve")]
    fn hoist_static_observeds(
        &self,
        cadence: ObservedCadence,
        ic_vec: &[f64],
        param_vec: &[f64],
        t0: f64,
        tape: Option<&(Rc<TapeProgram>, Rc<Vec<AlgebraicRule>>)>,
    ) -> SolveSetup {
        let sa0 = build_state_arrays(&self.var_shapes, ic_vec);
        // The two STRICT compilers, `native` and `xla` (API_SPEC §5.8): the
        // tape's own CONST section computes exactly these rules, once per
        // solve, on the same schedule this hoist used to. Materializing them a
        // SECOND time through the whole-array overlay would be the off-tape
        // per-cell evaluation `esm-libraries-spec.md` §2.5.10 refuses — and it would be invisible,
        // since the overlay declines on its own terms and reports nothing.
        //
        // What consumed the hoisted map still gets it: the RHS and Jacobian
        // scratches read the tape's slots rather than a seeded observed map,
        // and the inspection snapshot and the output-node pass harvest their
        // values from the tape ([`TapedObserveds`]).
        if self.tape_serves_passes() && tape.is_some() {
            return SolveSetup {
                cadence,
                sa0,
                static_obs: ArrMap::default(),
            };
        }
        let static_rings_cell: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
        let mut static_obs = ArrMap::default();
        let env = EvalEnv {
            state_arrays: &sa0,
            params: param_vec,
            param_names: &self.param_names,
            t: t0,
            // The regrid's FAQ rings are produced AND consumed within this
            // one-time static pass (its ring-consuming aggregates are themselves
            // static), so the sink is discarded after — no varying rule reads a
            // static ring, and each RHS eval starts from empty `derived_rings`.
            derived_rings: &static_rings_cell,
            derived_extents: empty_derived_extents(),
            forcing: &self.forcing,
            // One-shot materialization: no CSE memo (nothing to amortize the
            // structural analysis over).
            cse: None,
            const_lits: None,
            const_arrays: &self.const_scope,
            declared: &self.declared_names,
        };
        materialize_observeds_pass(
            &mut static_obs,
            &cadence.static_rules,
            &ObsPass {
                env,
                // `interpreter` is the reference and carries no performance
                // promise: every fast tier off, including the whole-array
                // overlay, at setup as much as on the hot path.
                force_scalar: self.is_interpreter(),
            },
            &mut RhsStats::default(),
        );
        drop(static_rings_cell);
        SolveSetup {
            cadence,
            sa0,
            static_obs,
        }
    }

    /// Build observability (see `BuildInspection`): the hoisted static
    /// observeds ARE the build-once products (regrid geometry, regridded
    /// terrain, slopes). Nothing downstream consults the sink, so the
    /// integration is unchanged.
    #[cfg(feature = "solve")]
    #[allow(clippy::too_many_arguments)]
    fn fill_solve_inspection(
        &self,
        insp: &mut BuildInspection,
        setup: &SolveSetup,
        ic_vec: &[f64],
        param_vec: &[f64],
        t0: f64,
        boundaries: &[f64],
        tape: Option<&(Rc<TapeProgram>, Rc<Vec<AlgebraicRule>>)>,
    ) {
        // Under either strict compiler: one taped read-out at t0 answers BOTH
        // halves of this sink — the static observeds (which the hoist no
        // longer materializes) and, on a segmented run, the varying ones. The
        // off-tape snapshot below is what §2.5.10 would otherwise leave
        // un-gated.
        if self.tape_serves_passes()
            && let Some(tape) = tape
        {
            let mut harvest = TapedObserveds::new(self, tape);
            let obs = harvest.at(self, ic_vec, param_vec, t0);
            self.fill_inspection(insp, obs, &setup.cadence.static_names, param_vec);
            if !boundaries.is_empty() {
                for rule in &setup.cadence.varying_rules {
                    let name = observed_rule_var(rule);
                    if let Some(a) = obs.get(name) {
                        insp.setup_arrays.insert(name.clone(), a.clone());
                    }
                }
            }
            return;
        }
        self.fill_inspection(
            insp,
            &setup.static_obs,
            &setup.cadence.static_names,
            param_vec,
        );
        // Segmented (DISCRETE) run: the time-varying regrid observeds (the
        // ERA5 t_xy/rh_xy/u_xy/v_xy over the first hour's slice) are NOT in
        // the static hoist, so ALSO snapshot them at t0 into `setup_arrays` —
        // a caller reading the build-time per-cell forcing (the runner's
        // forcing print) then still sees the ERA5 fields at their t=0 record.
        if !boundaries.is_empty() {
            let dr: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
            let mut snapshot = setup.static_obs.clone();
            materialize_observeds_pass(
                &mut snapshot,
                &setup.cadence.varying_rules,
                &ObsPass {
                    env: EvalEnv {
                        state_arrays: &setup.sa0,
                        params: param_vec,
                        param_names: &self.param_names,
                        t: t0,
                        derived_rings: &dr,
                        derived_extents: empty_derived_extents(),
                        forcing: &self.forcing,
                        cse: None,
                        const_lits: None,
                        const_arrays: &self.const_scope,
                        declared: &self.declared_names,
                    },
                    // Build-time t0 snapshot: vectorized overlay
                    // (bit-identical), unless this is the `interpreter`
                    // reference, which runs every tier off.
                    force_scalar: self.is_interpreter(),
                },
                &mut RhsStats::default(),
            );
            for rule in &setup.cadence.varying_rules {
                let name = observed_rule_var(rule);
                if let Some(a) = snapshot.get(name) {
                    insp.setup_arrays.insert(name.clone(), a.clone());
                }
            }
        }
    }

    /// Step 3b: compile the tape program ONCE per solve and share it across
    /// every integration segment (each segment's fresh RHS scratch gets its
    /// own slab and re-runs the CONST/SEGMENT sections — the same cadence as
    /// the static-observed hoist above). [`crate::Compiler::Interpreter`]
    /// builds no tape at all — it IS the per-cell oracle — and neither does a
    /// document whose per-variable element types the tape cannot express
    /// ([`tape_disabled`]).
    ///
    /// The build report's fallback list is kept, not dropped: a rule the
    /// tape could not compile is evaluated by the per-cell oracle, whose
    /// cost grows with the cell count, and that is invisible from the
    /// outside (the numbers are bit-identical — only the runtime differs).
    /// It rides out on [`SolutionMetadata::tape_fallbacks`] so a caller —
    /// including the wasm/JS host, which has no other window into the
    /// build — can name the offending rule and the reason.
    #[cfg(feature = "solve")]
    fn build_solve_tape(
        &self,
        discrete_forcing: &HashSet<String>,
    ) -> (SolveTape, Vec<(String, String)>) {
        let mut tape_fallbacks: Vec<(String, String)> = Vec::new();
        // `interpreter` (API_SPEC §5.8) is the reference and nothing else: no
        // tape, and the whole-array overlay off under it, so every rule is
        // walked per cell. It is the compiler the caller named, and the only
        // way to reach the oracle.
        let tape: SolveTape = if self.is_interpreter() || tape_disabled() {
            None
        } else {
            let (prog, report) = self.build_tape(discrete_forcing);
            tape_fallbacks = report.fallbacks;
            Some((Rc::new(prog), Rc::new(self.observed_rules.clone())))
        };
        (tape, tape_fallbacks)
    }

    /// DISCRETE: integrate in segments split on the refresh boundaries. Segment
    /// endpoints = t0, each boundary strictly inside (t0, t_end) ascending, t_end.
    #[cfg(feature = "solve")]
    fn run_segmented(
        &self,
        run: &SegmentedRun<'_>,
        refresh_fn: &mut impl FnMut(f64) -> Result<(), SimulateError>,
    ) -> Result<(Vec<f64>, Vec<Vec<f64>>, SolveStats, ReturnCode), SimulateError> {
        let &SegmentedRun {
            t0,
            t_end,
            boundaries,
            ic_vec,
            param_vec,
            setup,
            opts,
            tape,
        } = run;
        let n_states = self.n_states;

        let mut endpoints: Vec<f64> = vec![t0];
        for &b in boundaries {
            if b > t0 && b < t_end && *endpoints.last().unwrap() < b {
                endpoints.push(b);
            }
        }
        if *endpoints.last().unwrap() < t_end {
            endpoints.push(t_end);
        }

        let global_out = opts.saveat.clone().expect("output grid checked Some");
        let mut u0 = ic_vec.to_vec();
        let mut time: Vec<f64> = Vec::new();
        let mut state: Vec<Vec<f64>> = vec![Vec::new(); n_states];
        // Each segment integrates with its own fresh diffsol solver, so the
        // reported step/eval counts are the sum across all segments.
        let mut stats = SolveStats::default();
        let mut retcode = ReturnCode::Success;

        for w in endpoints.windows(2) {
            let (a, b) = (w[0], w[1]);
            // Refresh the live buffer at the START of every segment after the
            // first (t0 was already primed by `refresh_fn(t0)` in `solve_core`).
            if a != t0 {
                refresh_fn(a)?;
            }
            // Requested outputs falling in this segment: (a, b] — or [a, b] for
            // the first. Always run the solver's grid up to `b` (append if
            // absent) so the state at `b` seeds the next segment.
            let requested: Vec<f64> = global_out
                .iter()
                .copied()
                .filter(|&g| (if a == t0 { g >= a } else { g > a }) && g <= b)
                .collect();
            let mut grid = requested.clone();
            if grid.last() != Some(&b) {
                grid.push(b);
            }
            // Report progress against the GLOBAL interval, not the segment's.
            // Each segment runs a fresh solver over [a, b] with its own step
            // counter, so handing the caller's observer through unwrapped would
            // restart the bar from 0% at every refresh boundary.
            let seg_progress: Option<ProgressFn> = opts.progress.as_ref().map(|user| {
                let user = user.clone();
                let steps_before = stats.n_accepted_steps;
                let wrapped: ProgressFn = std::sync::Arc::new(move |p: &Progress<'_>| {
                    user(&Progress {
                        t0,
                        t: p.t,
                        t_end,
                        step: steps_before + p.step,
                        maxiters: p.maxiters,
                        u: p.u,
                    })
                });
                wrapped
            });
            let seg_opts = SolveOptions {
                saveat: Some(grid),
                progress: seg_progress,
                ..opts.clone()
            };
            let (seg_time, seg_state, seg_stats, seg_retcode) = self
                .run_one_segment(
                    a,
                    b,
                    &u0,
                    param_vec,
                    &setup.static_obs,
                    &setup.cadence.segment_static_rules,
                    &setup.cadence.continuous_rules,
                    &seg_opts,
                    tape,
                )
                .map_err(Self::const_oob_first)?;
            stats += seg_stats;
            // A segment that stopped early ends the whole run: the state at its
            // right endpoint never materialised, so there is nothing to seed the
            // next segment with. Its reason becomes the run's `retcode`.
            if !seg_retcode.is_success() {
                retcode = seg_retcode;
            }
            // `run_solver` pushes the REQUESTED grid time verbatim, so a float
            // equality against `requested`/`b` is exact.
            for (i, &t) in seg_time.iter().enumerate() {
                if t == b {
                    u0 = (0..n_states).map(|r| seg_state[r][i]).collect();
                }
                if requested.contains(&t) {
                    time.push(t);
                    for r in 0..n_states {
                        state[r].push(seg_state[r][i]);
                    }
                }
            }
            if !retcode.is_success() {
                break;
            }
        }

        Ok((time, state, stats, retcode))
    }

    /// Solution assembly, shared by the single-segment and segmented exits:
    /// expose observed trajectories alongside the states (see
    /// [`Self::append_observed_trajectories`]), then drain the §5.5.5
    /// const-array OOB latch so a trajectory built on a const-array bug fails
    /// loudly instead of carrying the `NaN` the gather substituted.
    #[cfg(feature = "solve")]
    #[allow(clippy::too_many_arguments)]
    fn assemble_solution(
        &self,
        time: Vec<f64>,
        mut state: Vec<Vec<f64>>,
        retcode: ReturnCode,
        metadata: SolutionMetadata,
        param_vec: &[f64],
        setup: &SolveSetup,
        output_observed: &[String],
        tape: Option<&(Rc<TapeProgram>, Rc<Vec<AlgebraicRule>>)>,
    ) -> Result<Solution, SimulateError> {
        let mut state_variable_names = self.scalar_state_names.clone();
        self.append_observed_trajectories(
            &time,
            &mut state,
            &mut state_variable_names,
            param_vec,
            &setup.static_obs,
            &setup.cadence.static_names,
            &setup.cadence.varying_rules,
            output_observed,
            tape,
        );
        if let Some(details) = crate::simulate_array::take_const_array_oob() {
            return Err(
                crate::compile_error::CompileError::InterpreterBuildError { details }.into(),
            );
        }
        Ok(Solution {
            time,
            state,
            state_variable_names,
            retcode,
            metadata,
        })
    }

    /// A solve that fails after the RHS latched an out-of-range const-array gather
    /// failed BECAUSE of it: the gather substituted `NaN`, and the integrator's
    /// step-size or error-test failure is the symptom. Report the latched
    /// `E_TREEWALK_CONSTARRAY_OOB` instead, as `assemble_solution` does on success.
    #[cfg(feature = "solve")]
    fn const_oob_first(err: SimulateError) -> SimulateError {
        match crate::simulate_array::take_const_array_oob() {
            Some(details) => {
                crate::compile_error::CompileError::InterpreterBuildError { details }.into()
            }
            None => err,
        }
    }

    /// Integrate ONE segment `[t0, t_end]` from initial state `u0`, reading the
    /// live forcing buffer (`self.forcing`) — which a segmented driver refreshes
    /// between segments. Builds a fresh RHS/Jacobian closure pair (each scratch
    /// pre-seeded with the already-materialized `static_obs`) and a fresh diffsol
    /// problem, returning the states at `opts.saveat`.
    #[allow(clippy::too_many_arguments)]
    #[cfg(feature = "solve")]
    fn run_one_segment(
        &self,
        t0: f64,
        t_end: f64,
        u0: &[f64],
        param_vec: &[f64],
        static_obs: &ArrMap,
        segment_static_rules: &[AlgebraicRule],
        continuous_rules: &[AlgebraicRule],
        opts: &SolveOptions,
        // Step 3b: the solve-wide tape program + the FULL observed rule list
        // its fallback indices resolve against. `None` ⇒ legacy interpreter.
        tape: Option<&(Rc<TapeProgram>, Rc<Vec<AlgebraicRule>>)>,
    ) -> Result<(Vec<f64>, Vec<Vec<f64>>, SolveStats, ReturnCode), SimulateError> {
        // A segment that never advances is answered from its own initial state,
        // before any closure, scratch buffer or diffsol problem is built
        // (issue #438): building the solver materializes a dense Jacobian,
        // which the matrix-free finite-difference Jacobian below pays for in
        // full right-hand-side evaluations, one pair per state column, each one
        // materializing every varying observed — recurrence sweeps included —
        // for a trajectory that is the untouched initial state. See
        // [`crate::simulate::nonadvancing_trajectory`], which also makes the
        // step-0 progress report. [`crate::simulate::run_solver`] keeps the same
        // check as a backstop and produces the identical trajectory, so this is
        // a cost-only shortcut.
        if let Some((time, state, retcode)) =
            crate::simulate::nonadvancing_trajectory(t0, t_end, u0, opts)
        {
            return Ok((time, state, SolveStats::default(), retcode));
        }
        let n_states = self.n_states;
        let rhs_rules = self.rhs_rules.clone();
        let var_shapes = self.var_shapes.clone();
        let param_names = self.param_names.clone();

        let rhs_rules_jac = rhs_rules.clone();
        let varying_rules_rhs = continuous_rules.to_vec();
        let varying_rules_jac = continuous_rules.to_vec();
        let var_shapes_jac = var_shapes.clone();
        let param_names_jac = param_names.clone();
        // See [`EvalCtx::declared`] (issue #181): the declared-name set is a
        // property of the compiled MODEL, so each RHS/Jacobian closure carries
        // its own clone rather than borrowing `self`.
        let declared = self.declared_names.clone();
        let declared_jac = declared.clone();

        // Materialize the DISCRETE (segment-invariant) observeds ONCE for this
        // segment, on top of the CONST `static_obs`. The caller refreshed the
        // forcing buffer at this segment's start (`refresh_fn(a)` / the `t0`
        // prime), and it stays fixed within the segment, so these forcing-derived
        // but state-free / `t`-free observeds (the per-cell conservative regrid)
        // are constant here — evaluating them once and seeding them as "static"
        // for the segment removes the per-step recompute that dominated the
        // coupled-loader profile. They are state-free, so `sa_seg` is only a
        // consistency placeholder; their FAQ rings are produced-and-consumed in
        // this one pass (own transient registry, discarded after).
        let seg_seed: ArrMap = if segment_static_rules.is_empty() || self.tape_serves_passes() {
            // Under either strict compiler: the tape's SEGMENT section
            // computes the segment-invariant observeds itself, on the same
            // once-per-segment schedule, so seeding them here would be the same rules evaluated
            // a second time off the tape (§2.5.10). `static_obs` is empty
            // under them for the same reason — see `hoist_static_observeds`.
            static_obs.clone()
        } else {
            let sa_seg = build_state_arrays(&self.var_shapes, u0);
            let seg_rings: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
            let mut seed = static_obs.clone();
            materialize_observeds_pass(
                &mut seed,
                segment_static_rules,
                &ObsPass {
                    env: EvalEnv {
                        state_arrays: &sa_seg,
                        params: param_vec,
                        param_names: &self.param_names,
                        t: t0,
                        derived_rings: &seg_rings,
                        derived_extents: empty_derived_extents(),
                        forcing: &self.forcing,
                        cse: None,
                        const_lits: None,
                        const_arrays: &self.const_scope,
                        declared: &self.declared_names,
                    },
                    force_scalar: false,
                },
                &mut RhsStats::default(),
            );
            seed
        };

        // `xla` (API_SPEC §5.8): the right-hand side is the XLA executable the
        // build installed, not the tape's own interpreter. The FD Jacobian
        // goes through it too — it differences two right-hand-side evaluations
        // of the same rules, so leaving it on the tape would mean an implicit
        // solve ran the whole model on a DIFFERENT compiler from the one the
        // caller named, once per Jacobian call.
        //
        // Both closures hold the ONE executable (`Rc`); nothing recompiles per
        // segment or per call.
        //
        // A missing executable under `xla` is a REFUSAL, not a quiet return to
        // the tape. Without this the one way the two could come apart — a
        // model that reached the integrator with `RuntimeMode::Xla` and an
        // empty cell — would be answered by the tape under the name `xla`,
        // which is exactly the substitution §2.5.10 exists to prevent.
        #[cfg(feature = "xla")]
        let xla_rhs = match (self.is_xla(), self.xla_program()) {
            (false, _) => None,
            (true, Some(program)) => Some(program),
            (true, None) => return Err(xla_not_installed()),
        };
        #[cfg(not(feature = "xla"))]
        if self.is_xla() {
            // Unreachable: a build without the feature answers
            // `compiler_unavailable` for `xla` before a backend exists. Kept
            // so the no-fallback property holds by CODE rather than by that
            // argument.
            return Err(xla_not_installed());
        }
        // Per-closure reusable scratch (ess-mro), pre-seeded ONCE with the
        // CONST + per-segment DISCRETE observeds (retained in place across steps,
        // never re-cloned) so each RHS eval materializes only the CONTINUOUS
        // observeds. `RefCell` gives the interior mutability diffsol's `Fn` RHS
        // requires; the Jacobian closure carries its own so the two never alias.
        // Under `xla` the tape never evaluates the right-hand side, so this
        // scratch (state-array buffers plus a copy of the seeded observed map)
        // is not built at all.
        #[cfg(feature = "xla")]
        let tape_rhs = xla_rhs.is_none();
        #[cfg(not(feature = "xla"))]
        let tape_rhs = true;
        let seg_seed = Rc::new(seg_seed);
        let rhs_scratch: RefCell<Option<RhsScratch>> = RefCell::new(tape_rhs.then(|| {
            let mut s = RhsScratch::new(&var_shapes);
            s.set_const_arrays(Rc::clone(&self.const_scope));
            s.set_static((*seg_seed).clone());
            // Step 3b: the production RHS closure's scratch gets the compiled
            // tape (fresh slab per segment; CONST/SEGMENT sections prime on the
            // segment's first call).
            if let Some((prog, full_obs)) = tape {
                s.install_tape(Rc::clone(prog), Rc::clone(full_obs));
            }
            s
        }));
        // The Jacobian scratch is built LAZILY on the first Jacobian call:
        // diffsol's `rhs_implicit` builder demands a Jacobian closure even for
        // the explicit (ERK) solver, which then never invokes it — so an eager
        // scratch (state-array buffers + a full copy of the seeded observed map)
        // was memory spent on a closure that never runs. The implicit solvers
        // (BDF/SDIRK) build it on their first Jacobian evaluation instead;
        // construction is deterministic, so results are bit-identical either way.
        let jac_seed = Rc::clone(&seg_seed);
        let const_scope_jac = Rc::clone(&self.const_scope);
        let jac_scratch: RefCell<Option<RhsScratch>> = RefCell::new(None);
        let tape_jac: Option<(Rc<TapeProgram>, Rc<Vec<AlgebraicRule>>)> =
            match (self.tape_serves_passes(), tape) {
                (true, Some((prog, full_obs))) => Some((Rc::clone(prog), Rc::clone(full_obs))),
                _ => None,
            };
        // `interpreter`: the per-cell oracle for the right-hand side too, not
        // just for the observeds. The strict compilers and the legacy routing
        // pass `false` and take the whole-array overlay where the tape is
        // absent.
        let force_scalar = self.is_interpreter();

        // The XLA Jacobian's buffers and kept base-point evaluation (see
        // [`FdJvp`]), built on its first call for the same reason the tape's
        // Jacobian scratch is.
        #[cfg(feature = "xla")]
        let xla_jac: Option<(Rc<crate::xla_runtime::CompiledRhs>, RefCell<Option<FdJvp>>)> =
            xla_rhs.clone().map(|program| (program, RefCell::new(None)));
        // Where an XLA execution failure goes. diffsol's right-hand side is
        // `Fn(..) -> ()`, so a device failure has no return channel: it lands
        // here, the derivative is filled with NaN so the solver stops rather
        // than integrating stale numbers, and the first message is raised
        // after the run as `compiler_unavailable` — which is what a device
        // that stopped working mid-solve IS (esm-spec §9.6.6: this binding,
        // build or PROCESS cannot provide the compiler). The lengths that
        // `CompiledRhs::eval_into` would otherwise report here were already
        // checked at install time, so nothing about the MODEL can reach this
        // channel.
        #[cfg(feature = "xla")]
        let xla_fault: Rc<RefCell<Option<String>>> = Rc::new(RefCell::new(None));
        #[cfg(feature = "xla")]
        let xla_fault_rhs = Rc::clone(&xla_fault);
        #[cfg(feature = "xla")]
        let xla_fault_jac = Rc::clone(&xla_fault);

        // External forcing channel (PR-1, ess-14f.7): clone the `Rc` handle into
        // each closure so both the RHS and the Jacobian read the *same*
        // model-lifetime buffer the caller refreshes between segments.
        let forcing_rhs = Rc::clone(&self.forcing);
        let forcing_jac = Rc::clone(&self.forcing);

        let rhs_closure = move |y: &diffsol::FaerVec<f64>,
                                p: &diffsol::FaerVec<f64>,
                                t: f64,
                                dy: &mut diffsol::FaerVec<f64>| {
            let y_s = y.as_slice();
            let p_s = p.as_slice();
            let dy_s = dy.as_mut_slice();
            for slot in dy_s.iter_mut() {
                *slot = 0.0;
            }
            #[cfg(feature = "xla")]
            if let Some(program) = &xla_rhs {
                run_xla_rhs(program, &xla_fault_rhs, y_s, p_s, t, dy_s);
                return;
            }
            let mut scratch_slot = rhs_scratch.borrow_mut();
            let scratch = scratch_slot
                .as_mut()
                .expect("the tape scratch is built whenever no XLA program serves the rhs");
            evaluate_rhs_with_scratch(
                &RhsCall {
                    rhs_rules: &rhs_rules,
                    observed_rules: &varying_rules_rhs,
                    var_shapes: &var_shapes,
                    param_names: &param_names,
                    state: y_s,
                    params: p_s,
                    forcing: &forcing_rhs,
                    t,
                    declared: &declared,
                },
                dy_s,
                force_scalar,
                &mut RhsStats::default(),
                scratch,
            );
        };

        let jac_closure = move |y: &diffsol::FaerVec<f64>,
                                p: &diffsol::FaerVec<f64>,
                                t: f64,
                                v: &diffsol::FaerVec<f64>,
                                jv: &mut diffsol::FaerVec<f64>| {
            #[cfg(feature = "xla")]
            if let Some((program, jvp)) = &xla_jac {
                let mut jvp = jvp.borrow_mut();
                let jvp = jvp.get_or_insert_with(|| FdJvp::new(n_states));
                jvp.apply(
                    y.as_slice(),
                    p.as_slice(),
                    t,
                    v.as_slice(),
                    jv.as_mut_slice(),
                    |state, params, t, out| {
                        run_xla_rhs(program, &xla_fault_jac, state, params, t, out)
                    },
                );
                return;
            }
            let n = y.as_slice().len();
            let v_s = v.as_slice();
            let p_s = p.as_slice();
            let y_s = y.as_slice();
            let mut y_norm = 0.0f64;
            for &yi in y_s {
                y_norm += yi * yi;
            }
            let y_norm = y_norm.sqrt().max(1.0);
            let eps = f64::EPSILON.sqrt() * y_norm;

            let mut y_perturbed = vec![0.0f64; n];
            for i in 0..n {
                y_perturbed[i] = y_s[i] + eps * v_s[i];
            }

            let mut f_y = vec![0.0f64; n];
            let mut f_yp = vec![0.0f64; n];
            let mut scratch_slot = jac_scratch.borrow_mut();
            let scratch = scratch_slot.get_or_insert_with(|| {
                let mut s = RhsScratch::new(&var_shapes_jac);
                s.set_const_arrays(Rc::clone(&const_scope_jac));
                s.set_static((*jac_seed).clone());
                // Under `native` the FD Jacobian runs on the TAPE as well
                // (under `xla` it runs on the emitted program instead, which
                // the arm above took).
                // The two right-hand-side evaluations it differences are the
                // same rules the production closure runs, so leaving them on
                // the legacy interpreter meant an implicit solve evaluated the
                // whole model through the overlay — and, wherever the overlay
                // declined, per cell — at every Jacobian call: the largest
                // off-tape evaluation in the driver, and one §2.5.10 covers
                // ("every evaluation the compiler performs for the Problem").
                // The tape is bit-identical to the legacy path (that is what
                // the compiler-agreement tier asserts, CONFORMANCE_SPEC
                // §5.44), so the differenced Jacobian is unchanged.
                if let Some((prog, full_obs)) = &tape_jac {
                    s.install_tape(Rc::clone(prog), Rc::clone(full_obs));
                }
                s
            });
            evaluate_rhs_with_scratch(
                &RhsCall {
                    rhs_rules: &rhs_rules_jac,
                    observed_rules: &varying_rules_jac,
                    var_shapes: &var_shapes_jac,
                    param_names: &param_names_jac,
                    state: y_s,
                    params: p_s,
                    forcing: &forcing_jac,
                    t,
                    declared: &declared_jac,
                },
                &mut f_y,
                force_scalar,
                &mut RhsStats::default(),
                scratch,
            );
            evaluate_rhs_with_scratch(
                &RhsCall {
                    rhs_rules: &rhs_rules_jac,
                    observed_rules: &varying_rules_jac,
                    var_shapes: &var_shapes_jac,
                    param_names: &param_names_jac,
                    state: &y_perturbed,
                    params: p_s,
                    forcing: &forcing_jac,
                    t,
                    declared: &declared_jac,
                },
                &mut f_yp,
                force_scalar,
                &mut RhsStats::default(),
                scratch,
            );
            let jv_s = jv.as_mut_slice();
            for i in 0..n {
                jv_s[i] = (f_yp[i] - f_y[i]) / eps;
            }
        };

        // Concrete values: `solve` has already resolved the esm-spec §2.2.2
        // chain into `opts`. The fallback covers a direct call that bypasses
        // `solve` and therefore has no document to consult.
        let abstol = opts.abstol_or_default();
        let reltol = opts.reltol_or_default();
        let ic_for_init = u0.to_vec();

        let builder = OdeBuilder::<FaerMat<f64>>::new()
            .t0(t0)
            .rtol(reltol)
            .atol(vec![abstol; n_states])
            .p(param_vec.to_vec())
            .rhs_implicit(rhs_closure, jac_closure)
            .init(
                move |_p: &diffsol::FaerVec<f64>, _t: f64, y: &mut diffsol::FaerVec<f64>| {
                    let y_s = y.as_mut_slice();
                    for (i, &v) in ic_for_init.iter().enumerate() {
                        y_s[i] = v;
                    }
                },
                n_states,
            );

        let problem = builder.build().map_err(|e| SimulateError::DiffsolError {
            details: e.to_string(),
        })?;

        // Run the solver, then read the real step/eval counters out of diffsol
        // before the concrete solver is dropped (see [`SolveStats::from_solver`]).
        //
        // Wrapped in an immediately-invoked closure so a solver failure does
        // not leave the function before the XLA fault channel below is read: a
        // device that stopped working reaches the solver as a NaN derivative,
        // and reporting "tolerance not met" for it would name the wrong thing.
        type SolvedSegment = (Vec<f64>, Vec<Vec<f64>>, SolveStats, ReturnCode);
        let solved = (|| -> Result<SolvedSegment, SimulateError> {
            let out = match opts.alg {
                Alg::Bdf => {
                    let mut solver: Bdf<'_, _, NewtonNonlinearSolver<_, FaerLU<f64>, _>> = problem
                        .bdf::<FaerLU<f64>>()
                        .map_err(|e| SimulateError::DiffsolError {
                            details: e.to_string(),
                        })?;
                    let (time, state, retcode) =
                        crate::simulate::run_solver(&mut solver, t_end, opts)?;
                    let bs = solver.get_statistics();
                    let stats = SolveStats::from_solver(
                        &solver,
                        bs.number_of_steps,
                        bs.number_of_error_test_failures + bs.number_of_nonlinear_solver_fails,
                    );
                    (time, state, stats, retcode)
                }
                Alg::Sdirk => {
                    let mut solver: Sdirk<'_, _, FaerLU<f64>> = problem
                        .tr_bdf2::<FaerLU<f64>>()
                        .map_err(|e| SimulateError::DiffsolError {
                            details: e.to_string(),
                        })?;
                    let (time, state, retcode) =
                        crate::simulate::run_solver(&mut solver, t_end, opts)?;
                    let bs = solver.get_statistics();
                    let stats = SolveStats::from_solver(
                        &solver,
                        bs.number_of_steps,
                        bs.number_of_error_test_failures + bs.number_of_nonlinear_solver_fails,
                    );
                    (time, state, stats, retcode)
                }
                Alg::Erk => {
                    let mut solver = problem.tsit45().map_err(|e| SimulateError::DiffsolError {
                        details: e.to_string(),
                    })?;
                    let (time, state, retcode) =
                        crate::simulate::run_solver(&mut solver, t_end, opts)?;
                    let bs = solver.get_statistics();
                    let stats = SolveStats::from_solver(
                        &solver,
                        bs.number_of_steps,
                        bs.number_of_error_test_failures + bs.number_of_nonlinear_solver_fails,
                    );
                    (time, state, stats, retcode)
                }
            };
            Ok(out)
        })();
        // §9.6.6 `compiler_unavailable`: the caller named `xla`, and the XLA
        // runtime stopped being able to provide it mid-solve. It is reported
        // in preference to whatever the solver made of the NaN derivative,
        // because that is the fact — and the first failure is reported, since
        // every one after it ran on the same broken device.
        #[cfg(feature = "xla")]
        if let Some(details) = xla_fault.borrow().clone() {
            return Err(SimulateError::CompilerUnavailable {
                compiler: "xla",
                details: format!("the compiled right-hand side failed during the solve: {details}"),
            });
        }
        let (time, state, stats, retcode) = solved?;
        Ok((time, state, stats, retcode))
    }

    /// Expose observed trajectories (e.g. an `area` FAQ) alongside the states
    /// so inline conformance assertions can read algebraic quantities
    /// (RFC §8.1; CONFORMANCE_SPEC.md §5.8). The integrator carries only the
    /// state vector, so re-evaluate the (dependency-ordered, derived-ring-aware)
    /// observeds from the state trajectory at each output node and append them
    /// as extra rows (with matching entries in `state_variable_names`). Mirrors
    /// the Python `_simulate_with_numpy` output-observed exposure. A model with
    /// no observed rules (or an empty trajectory) is untouched.
    ///
    /// **Scalar observeds are always exposed; array-valued ones only on
    /// request.** `requested` is [`SolveOptions::output_observed`] — the
    /// caller-named subset of streaming-output-sinks RFC decision 8. An
    /// array-valued observed (the clip ring, the const polygons, a gridded
    /// emissions field) is `n_cells` rows, not one, so materializing every one
    /// of them unasked would multiply the trajectory's memory by the grid size;
    /// a requested one is flattened to one row per cell named exactly like a
    /// state cell — `name[i,j,…]`, 1-based and column-major, the spelling
    /// [`build_slot_tables`] gives the state and the one
    /// [`crate::derive_output_plan`] inverts back into a labeled output array.
    /// Names may be bare or `Model.`-qualified.
    #[cfg(feature = "solve")]
    #[allow(clippy::too_many_arguments)]
    #[allow(clippy::too_many_arguments)]
    fn append_observed_trajectories(
        &self,
        time: &[f64],
        state: &mut Vec<Vec<f64>>,
        state_variable_names: &mut Vec<String>,
        param_vec: &[f64],
        static_obs: &ArrMap,
        static_names: &HashSet<String>,
        varying_rules: &[AlgebraicRule],
        requested: &[String],
        tape: Option<&(Rc<TapeProgram>, Rc<Vec<AlgebraicRule>>)>,
    ) {
        if self.observed_rules.is_empty() || time.is_empty() {
            return;
        }
        // Under either strict compiler: the observeds reported at output
        // times are read off the TAPE, one call per saved node, instead of being re-derived through
        // the whole-array overlay. esm-libraries-spec §2.5.10 names this pass
        // explicitly — "the observeds reported at output times" are under the
        // refusal like the right-hand side is — and it is the one that runs
        // most often, once per saved time point.
        if self.tape_serves_passes()
            && let Some(tape) = tape
        {
            self.append_observed_trajectories_taped(
                time,
                state,
                state_variable_names,
                param_vec,
                static_names,
                varying_rules,
                requested,
                tape,
            );
            return;
        }
        let wanted = self.resolve_requested_observeds(requested);
        let nt = time.len();

        // ---- per-node evaluation state, allocated ONCE ----------------------
        // The old shape of this pass built a fresh `ArrMap`, a fresh state-array
        // map and a deep `arr.clone()` of every hoisted static observed at every
        // one of the NT output nodes. All three are hoisted out of the node loop
        // here: the state arrays are refilled in place (the same
        // `refill_state_arrays` the RHS uses — identical column-major placement),
        // and the observed map keeps its static entries in place across nodes,
        // dropping only the varying ones with `retain`, exactly as `RhsScratch`
        // does between RHS calls.
        let mut flat = vec![0.0f64; self.n_states];
        for (i, slot) in flat.iter_mut().enumerate() {
            *slot = state[i][0];
        }
        let mut sa = build_state_arrays(&self.var_shapes, &flat);
        let static_keys: HashSet<String> = static_obs.keys().cloned().collect();
        let mut obs: ArrMap = ArrMap::default();
        for (name, arr) in static_obs {
            obs.insert(name.clone(), arr.clone());
        }
        let dr: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());

        // ess-cse: this pass walks the SAME expanded discretization bodies the
        // RHS does (one `simpleclimate` advection observed is 45k+ operator
        // nodes) and used to run with `cse: None` — i.e. with no memoization at
        // all, re-evaluating every repeated subtree at every occurrence at every
        // output node. Give it its own runtime. The class table is keyed by AST
        // node address, so it is (re)bound to whichever rule slice is about to be
        // evaluated; see [`CseRt::retarget`].
        let cse = CseRt::default();
        let bind_cse = |rules: &[AlgebraicRule]| {
            cse.retarget(
                (rules.as_ptr() as u64).rotate_left(17)
                    ^ ((rules.len() as u64) << 16)
                    ^ 0x0b5e_0b5e_0b5e_0b5e,
            );
        };

        // ---- dependency-cone pruning ---------------------------------------
        // Only the 0-D observeds become rows, but every varying rule — the whole
        // PPM stencil chain — was materialized at every node and then thrown
        // away. Restrict the work to the transitive dependency cone of what is
        // actually read.
        //
        // The cone is computed from `Expr::Variable` leaves, so it is only valid
        // for rules whose dependency edges are all expressible that way: a FAQ
        // ring producer/consumer pair and a ragged/derived contraction bound
        // couple two rules through the `derived_rings` registry / an `offsets`
        // factor name instead, and a `join` couples them through key COLUMN
        // names. A model using any of those keeps the old un-pruned behaviour.
        let prune = varying_rules
            .iter()
            .all(|r| !expr_blocks_output_pruning(observed_rule_body(r)));

        // Probe: the rules that must actually run before 0-D-ness is known. A
        // rule whose value is provably an array needs no probe at all, and a
        // hoisted static observed's rank is already in `obs`.
        let probe_owned: Vec<AlgebraicRule>;
        let probe_rules: &[AlgebraicRule] = if prune {
            // A REQUESTED array-valued observed becomes rows as well, so it
            // must be in the probe cone even though its rank is already known.
            let unknown: HashSet<String> = self
                .observed_rules
                .iter()
                .filter(|r| {
                    !observed_rule_is_array_valued(r) || wanted.contains(observed_rule_var(r))
                })
                .map(|r| observed_rule_var(r).clone())
                .collect();
            match dependency_cone(varying_rules, &unknown) {
                None => varying_rules,
                Some(cone) => {
                    probe_owned = cone;
                    &probe_owned
                }
            }
        } else {
            varying_rules
        };
        if !probe_rules.is_empty() {
            bind_cse(probe_rules);
            materialize_observeds_pass(
                &mut obs,
                probe_rules,
                &ObsPass {
                    env: EvalEnv {
                        state_arrays: &sa,
                        params: param_vec,
                        param_names: &self.param_names,
                        t: time[0],
                        derived_rings: &dr,
                        derived_extents: empty_derived_extents(),
                        forcing: &self.forcing,
                        cse: Some(&cse),
                        const_lits: None,
                        const_arrays: &self.const_scope,
                        declared: &self.declared_names,
                    },
                    // Output-node observed snapshot: vectorized overlay,
                    // unless this is the `interpreter` reference.
                    force_scalar: self.is_interpreter(),
                },
                &mut RhsStats::default(),
            );
        }
        // What becomes rows: every 0-D observed, as before, plus every
        // CALLER-REQUESTED array-valued one, at one row per cell.
        //
        // A name the probe did not materialize at all is skipped, and the
        // verdict is the same one the full materialization would have produced:
        // by construction such a name is either array-valued and unrequested —
        // so not a row either way — or outside the cone of anything that could
        // be 0-D. A requested array observed IS in the probe cone (see above),
        // so its rank and shape are known here; taking the shape from the probe
        // rather than per node is what keeps the row block from shifting if a
        // later node fails to materialize the name.
        let emit: Vec<ObservedRows> = self
            .observed_rules
            .iter()
            .filter_map(|rule| {
                let name = observed_rule_var(rule);
                let arr = obs.get(name)?;
                if arr.ndim() == 0 {
                    Some(ObservedRows::scalar(name.clone()))
                } else if wanted.contains(name) {
                    Some(ObservedRows::gridded(name.clone(), arr.shape().to_vec()))
                } else {
                    None
                }
            })
            .collect();
        if emit.is_empty() {
            return;
        }
        let n_rows: usize = emit.iter().map(ObservedRows::n_rows).sum();

        // Value pass: the cone of the rows we actually emit.
        let value_owned: Vec<AlgebraicRule>;
        let value_rules: &[AlgebraicRule] = if prune {
            let seeds: HashSet<String> = emit.iter().map(|e| e.name.clone()).collect();
            match dependency_cone(varying_rules, &seeds) {
                None => varying_rules,
                Some(cone) => {
                    value_owned = cone;
                    &value_owned
                }
            }
        } else {
            varying_rules
        };

        let mut rows: Vec<Vec<f64>> = vec![Vec::with_capacity(nt); n_rows];
        let record = |obs: &ArrMap, rows: &mut Vec<Vec<f64>>| {
            let mut j = 0usize;
            for e in &emit {
                match obs.get(&e.name) {
                    Some(a) if e.shape.is_empty() => {
                        rows[j].push(a.first().copied().unwrap_or(f64::NAN));
                        j += 1;
                    }
                    Some(a) if a.shape() == e.shape.as_slice() => {
                        // Column-major, the order the cell keys were named in.
                        for v in arrayd_to_col_major(a) {
                            rows[j].push(v);
                            j += 1;
                        }
                    }
                    // Absent at this node, or a rank the probe did not see: NaN
                    // across the block, so the fault shows in the values rather
                    // than silently shifting every later row.
                    _ => {
                        for _ in 0..e.n_rows() {
                            rows[j].push(f64::NAN);
                            j += 1;
                        }
                    }
                }
            }
        };
        record(&obs, &mut rows);
        if value_rules.is_empty() {
            // Every 0-D observed sits in the hoisted static set, so its value is
            // node-independent: replicate node 0 instead of re-running the whole
            // varying rule set NT times for a number that cannot change.
            for row in rows.iter_mut() {
                let v = row[0];
                row.resize(nt, v);
            }
        } else {
            bind_cse(value_rules);
            for k in 1..nt {
                for (i, slot) in flat.iter_mut().enumerate() {
                    *slot = state[i][k];
                }
                refill_state_arrays(&mut sa, &self.var_shapes, &flat);
                obs.retain(|name, _| static_keys.contains(name));
                dr.borrow_mut().clear();
                materialize_observeds_pass(
                    &mut obs,
                    value_rules,
                    &ObsPass {
                        env: EvalEnv {
                            state_arrays: &sa,
                            params: param_vec,
                            param_names: &self.param_names,
                            t: time[k],
                            derived_rings: &dr,
                            derived_extents: empty_derived_extents(),
                            forcing: &self.forcing,
                            cse: Some(&cse),
                            const_lits: None,
                            const_arrays: &self.const_scope,
                            declared: &self.declared_names,
                        },
                        force_scalar: self.is_interpreter(),
                    },
                    &mut RhsStats::default(),
                );
                record(&obs, &mut rows);
            }
        }
        let mut rows = rows.into_iter();
        for e in &emit {
            for name in e.row_names() {
                let Some(row) = rows.next() else { break };
                state_variable_names.push(name);
                state.push(row);
            }
        }
    }

    /// [`Self::append_observed_trajectories`] served from the tape — the path
    /// both strict compilers take.
    ///
    /// Same rows, same order, same cell-key spelling; the only difference is
    /// where the numbers come from. One taped call per saved time point
    /// publishes every observed (a strict build exports them all, because a
    /// harvest that covered only the probe cone would silently skip a
    /// caller-requested array observed and a static one), and the rows are read
    /// straight off that map.
    ///
    /// The dependency-cone pruning the overlay path needs has no counterpart
    /// here: the tape computes the whole CONTINUOUS section either way, and
    /// its CONST and SEGMENT sections prime once for the whole sweep rather
    /// than once per node, which is what the pruning was buying back.
    #[cfg(feature = "solve")]
    #[allow(clippy::too_many_arguments)]
    fn append_observed_trajectories_taped(
        &self,
        time: &[f64],
        state: &mut Vec<Vec<f64>>,
        state_variable_names: &mut Vec<String>,
        param_vec: &[f64],
        static_names: &HashSet<String>,
        varying_rules: &[AlgebraicRule],
        requested: &[String],
        tape: &(Rc<TapeProgram>, Rc<Vec<AlgebraicRule>>),
    ) {
        let wanted = self.resolve_requested_observeds(requested);
        // WHICH observeds become rows is decided exactly as the overlay path
        // decides it, and deliberately not by what the tape happens to
        // publish: a strict build exports every observed so the harvest
        // cannot miss one, and emitting every one of them would put rows in
        // the solution that the same document did not carry before. The
        // candidates are the hoisted static observeds plus the probe cone —
        // the potentially-scalar rules and their transitive dependencies —
        // which is what `obs` holds at this point on the overlay path.
        let emitted = self.output_row_candidates(static_names, varying_rules, &wanted);
        let nt = time.len();
        let mut harvest = TapedObserveds::new(self, tape);
        let mut flat = vec![0.0f64; self.n_states];

        for (i, slot) in flat.iter_mut().enumerate() {
            *slot = state[i][0];
        }
        // What becomes rows: every 0-D observed, plus every CALLER-REQUESTED
        // array-valued one at one row per cell. Decided at node 0 and held
        // fixed, so a later node cannot shift the row block.
        let emit: Vec<ObservedRows> = {
            let obs = harvest.at(self, &flat, param_vec, time[0]);
            self.observed_rules
                .iter()
                .filter_map(|rule| {
                    let name = observed_rule_var(rule);
                    if !emitted.contains(name) {
                        return None;
                    }
                    let arr = obs.get(name)?;
                    if arr.ndim() == 0 {
                        Some(ObservedRows::scalar(name.clone()))
                    } else if wanted.contains(name) {
                        Some(ObservedRows::gridded(name.clone(), arr.shape().to_vec()))
                    } else {
                        None
                    }
                })
                .collect()
        };
        if emit.is_empty() {
            return;
        }
        let n_rows: usize = emit.iter().map(ObservedRows::n_rows).sum();
        let mut rows: Vec<Vec<f64>> = vec![Vec::with_capacity(nt); n_rows];
        let record = |obs: &ArrMap, rows: &mut Vec<Vec<f64>>| {
            let mut j = 0usize;
            for e in &emit {
                match obs.get(&e.name) {
                    Some(a) if e.shape.is_empty() => {
                        rows[j].push(a.first().copied().unwrap_or(f64::NAN));
                        j += 1;
                    }
                    Some(a) if a.shape() == e.shape.as_slice() => {
                        for v in arrayd_to_col_major(a) {
                            rows[j].push(v);
                            j += 1;
                        }
                    }
                    // Absent, or a rank node 0 did not see: NaN across the
                    // block, so the fault shows in the values rather than
                    // silently shifting every later row.
                    _ => {
                        for _ in 0..e.n_rows() {
                            rows[j].push(f64::NAN);
                            j += 1;
                        }
                    }
                }
            }
        };
        record(harvest.scratch_observeds(), &mut rows);
        for k in 1..nt {
            for (i, slot) in flat.iter_mut().enumerate() {
                *slot = state[i][k];
            }
            let obs = harvest.at(self, &flat, param_vec, time[k]);
            record(obs, &mut rows);
        }

        let mut rows = rows.into_iter();
        for e in &emit {
            for name in e.row_names() {
                let Some(row) = rows.next() else { break };
                state_variable_names.push(name);
                state.push(row);
            }
        }
    }

    /// The observeds that may become solution rows: the hoisted static ones
    /// plus the output-node probe cone.
    ///
    /// The overlay path's candidate set, named. It materializes the statics
    /// once and then the PROBE CONE — every potentially-scalar observed and
    /// its transitive dependencies — and an observed outside both is simply
    /// not in `obs` when the row set is decided, so it becomes no row. The
    /// taped path publishes every observed (that is what makes its harvest
    /// complete), so it has to be told the same rule rather than inferring it
    /// from what happens to be published.
    #[cfg(feature = "solve")]
    fn output_row_candidates(
        &self,
        static_names: &HashSet<String>,
        varying_rules: &[AlgebraicRule],
        wanted: &HashSet<String>,
    ) -> HashSet<String> {
        let mut out: HashSet<String> = static_names.clone();
        let prune = varying_rules
            .iter()
            .all(|r| !expr_blocks_output_pruning(observed_rule_body(r)));
        let cone: Option<Vec<AlgebraicRule>> = if prune {
            let unknown: HashSet<String> = self
                .observed_rules
                .iter()
                .filter(|r| {
                    !observed_rule_is_array_valued(r) || wanted.contains(observed_rule_var(r))
                })
                .map(|r| observed_rule_var(r).clone())
                .collect();
            dependency_cone(varying_rules, &unknown)
        } else {
            None
        };
        match cone {
            Some(rules) => out.extend(rules.iter().map(|r| observed_rule_var(r).clone())),
            // No cone: the un-pruned behaviour materializes every varying rule.
            None => out.extend(varying_rules.iter().map(|r| observed_rule_var(r).clone())),
        }
        out
    }

    /// The observed-rule names `requested` names.
    ///
    /// The rule [`crate::derive_output_plan`] applies to an output request
    /// (CONFORMANCE_SPEC §5.17.4), over the observed rules: the exact name, else
    /// the ONE rule whose last dotted segment equals the request's. A name that
    /// matches nothing, or whose last segment several rules share, selects
    /// nothing and is not an error here — the output plan diagnoses it with
    /// [`crate::OutputError::UnknownObserved`] or
    /// [`crate::OutputError::AmbiguousRequest`], and it also sees the state
    /// slots, so it tells the caller the whole truth.
    #[cfg(feature = "solve")]
    fn resolve_requested_observeds(&self, requested: &[String]) -> HashSet<String> {
        if requested.is_empty() {
            return HashSet::new();
        }
        let vars: Vec<&str> = self
            .observed_rules
            .iter()
            .map(|r| observed_rule_var(r).as_str())
            .collect();
        requested
            .iter()
            .filter_map(
                |r| match crate::data_output::match_output_request(r, &vars) {
                    crate::data_output::RequestMatch::Named(var) => Some(var.to_string()),
                    _ => None,
                },
            )
            .collect()
    }

    /// Names of the observeds that are STATE-FREE and `t`-free: their transitive
    /// references reach no state variable and no `t` (each reference is a
    /// parameter, a loop index, an external forcing entry, or an already-static
    /// observed). Because `observed_rules` is dependency-ordered (Kahn sweep at
    /// build), one forward pass classifies each rule after its references; a
    /// cycle survivor's unplaced reference correctly disqualifies it.
    ///
    /// These are the observeds the RHS hoists out of the per-step loop and the
    /// build-once products a [`BuildInspection`] records. Unlike a strict
    /// "state-free" set, an external **forcing** reference is ALLOWED: a CONST
    /// loader field is constant within a `simulate` call (the free `simulate`
    /// never refreshes the forcing buffer mid-run), so an observed reaching only
    /// params + forcing + static observeds is constant across the whole solve.
    /// The regridded terrain (`elev_xy`) and its slopes — forcing-derived but
    /// state-free — thus hoist and land in `setup_arrays`, matching the Julia /
    /// Python `BuildInspection`.
    pub(super) fn classify_static_observeds(
        &self,
        discrete_forcing: &HashSet<String>,
    ) -> HashSet<String> {
        // CONST tier: state-free, `t`-free, AND forcing-free.
        self.classify_segment_invariant_observeds(discrete_forcing, false)
    }

    /// Classify the observeds that are invariant *within a cadence segment* — the
    /// cadence lattice's `≤ DISCRETE` set (`CONST ⊏ DISCRETE`, `cadence.rs`): their
    /// transitive references reach neither `t` nor any state variable.
    ///
    /// * `allow_forcing = false` → the CONST set (also forcing-free): constant for
    ///   the entire solve, materialized ONCE at setup (the hoisted `static_obs`).
    /// * `allow_forcing = true` → CONST ∪ DISCRETE: an observed may reach a
    ///   discrete forcing buffer. Since the driver refreshes forcing only *between*
    ///   segments (never inside a solver step), such an observed is constant
    ///   *within* a segment — so the DISCRETE remainder is materialized ONCE per
    ///   segment rather than re-evaluated every RHS step. This is the fix for a
    ///   coupled model whose per-cell conservative-regrid observeds (state-free,
    ///   `t`-free, forcing-fed) were previously recomputed every step.
    ///
    /// `observed_rules` are dependency-ordered, so the transitive
    /// `set.contains(r)` check resolves against already-classified predecessors.
    pub(super) fn classify_segment_invariant_observeds(
        &self,
        discrete_forcing: &HashSet<String>,
        allow_forcing: bool,
    ) -> HashSet<String> {
        let observed_names: HashSet<&String> =
            self.observed_rules.iter().map(observed_rule_var).collect();
        let mut set: HashSet<String> = HashSet::new();
        for rule in &self.observed_rules {
            let mut refs = HashSet::new();
            collect_expr_var_refs(observed_rule_body(rule), &mut refs);
            // A RECURRENCE rule's body reads the variable the rule DEFINES
            // (esm-spec §4.3.1.1). That self-edge is not a dependency on
            // another observed — it is an ordering within this one — so it is
            // dropped, exactly as `dependency_order_observed` drops it. Leaving
            // it in made the rule classify as non-static and never be hoisted,
            // which is why a state-free recurrence materialized nowhere at all
            // before this feature landed.
            //
            // Conditioned on the rule KIND, not applied to every rule: a
            // self-reference the recurrence lowering did not recognize is not
            // an ordering, it is a rule that reads a name nothing binds, and
            // hoisting it as a build-once constant would freeze that. The
            // exemption belongs to the construct that earns it.
            if matches!(rule, AlgebraicRule::Recurrence { .. }) {
                let self_name = observed_rule_var(rule);
                refs.retain(|r| r != self_name);
            }
            let ok = refs.iter().all(|r| {
                r != "t"
                    && !self.var_shapes.contains_key(r)
                    // A DISCRETE (hourly) forcing buffer is a LIVE field the driver
                    // refreshes between segments. Excluded from the CONST tier (it
                    // must not freeze at setup), but ALLOWED in the ≤DISCRETE tier
                    // (constant *within* a segment, so hoistable to per-segment).
                    && (allow_forcing || !discrete_forcing.contains(r))
                    && (!observed_names.contains(r) || set.contains(r))
            });
            if ok {
                set.insert(observed_rule_var(rule).clone());
            }
        }
        set
    }

    /// Fill a [`BuildInspection`] sink from the already-hoisted static observeds:
    /// record every rule's resolved body expression, the resolved scalar
    /// parameters, and the arrays of the static (state-free / `t`-free) subset
    /// (`static_obs`, materialized once by the caller). Read-only with respect to
    /// the run.
    #[cfg(feature = "solve")]
    fn fill_inspection(
        &self,
        insp: &mut BuildInspection,
        static_obs: &ArrMap,
        static_names: &HashSet<String>,
        param_vec: &[f64],
    ) {
        // Resolved scalar parameters (load-time constants) so the reference / ic
        // positions can bind them into a build-time cellwise evaluation.
        for (i, name) in self.param_names.iter().enumerate() {
            insp.params.insert(name.clone(), param_vec[i]);
        }
        for rule in &self.observed_rules {
            insp.observed_exprs.insert(
                observed_rule_var(rule).clone(),
                observed_rule_body(rule).clone(),
            );
            // esm-spec §4.3.1.1 / RFC §2.1: the recurrence a document's
            // self-read was interpreted as, reported rather than authored.
            if let AlgebraicRule::Recurrence {
                var,
                output_idx_names,
                axis,
                max_lag,
                lag_proven,
                ..
            } = rule
            {
                insp.recurrences
                    .push(crate::simulate_array::RecurrenceInfo {
                        var: var.clone(),
                        axis: output_idx_names[*axis].clone(),
                        max_lag: *max_lag,
                        lag_proven: *lag_proven,
                    });
            }
        }
        for name in static_names {
            if let Some(a) = static_obs.get(name) {
                insp.setup_arrays.insert(name.clone(), a.clone());
            }
        }
    }
}

/// One observed's contribution to the appended trajectory rows: a 0-D observed
/// is a single row named after itself, an array-valued one is `n_cells` rows
/// named `base[i,j,…]` (1-based, column-major) — the identical cell-key scheme
/// [`build_slot_tables`] gives an array STATE, so the two are indistinguishable
/// to [`crate::derive_output_gridding`] and land on the same emergent grid.
#[cfg(feature = "solve")]
struct ObservedRows {
    /// The observed rule's variable name.
    name: String,
    /// Gridded shape, in cell-key axis order; EMPTY for a 0-D observed.
    shape: Vec<usize>,
}

#[cfg(feature = "solve")]
impl ObservedRows {
    fn scalar(name: String) -> Self {
        ObservedRows {
            name,
            shape: Vec::new(),
        }
    }

    fn gridded(name: String, shape: Vec<usize>) -> Self {
        ObservedRows { name, shape }
    }

    /// How many trajectory rows this observed contributes (1 for a scalar).
    fn n_rows(&self) -> usize {
        self.shape.iter().product::<usize>().max(1)
    }

    /// The row names, in the order [`ObservedRows::n_rows`] counts them.
    fn row_names(&self) -> Vec<String> {
        if self.shape.is_empty() {
            return vec![self.name.clone()];
        }
        (0..self.n_rows())
            .map(|flat| {
                let idx = flat_to_multi_col_major(flat, &self.shape)
                    .iter()
                    .map(|i| (i + 1).to_string())
                    .collect::<Vec<_>>()
                    .join(",");
                format!("{}[{}]", self.name, idx)
            })
            .collect()
    }
}

/// Is this observed rule's value provably an ARRAY (`ndim ≥ 1`) *without*
/// evaluating it? Used only to keep a rule out of the 0-D probe in
/// [`ArrayCompiled::append_observed_trajectories`], so it must never
/// claim "array" for a rule that can materialize 0-D. Both arms read the rank
/// straight off the rule's own output box:
///
///   * an `ArrayLoop` writes a box of rank `output_ranges.len()` on BOTH the
///     vectorized fast path and the per-cell oracle (see
///     [`materialize_observeds_pass`]);
///   * a `Scalar` rule whose body is a `faq` carrying a body (`expr`) and
///     a non-empty `output_idx` is evaluated by [`eval_faq`], which returns
///     a `Value::Array` of rank `output_idx.len()`. (Without `expr` the oracle
///     reports the scalar `NaN` sentinel, hence the `expr.is_some()` guard.)
///
/// Anything else — a bare variable reference, an arithmetic body, a contraction
/// with no free index — is "unknown" and gets probed.
pub(super) fn observed_rule_is_array_valued(rule: &AlgebraicRule) -> bool {
    match rule {
        // A recurrence materializes the same padded box its frame declares
        // (esm-spec §4.3.1.1), so it is array-valued exactly when it has axes.
        AlgebraicRule::ArrayLoop { output_ranges, .. }
        | AlgebraicRule::Recurrence { output_ranges, .. } => !output_ranges.is_empty(),
        AlgebraicRule::Scalar { body, .. } => match &**body {
            Expr::Operator(node) => {
                node.op == "faq"
                    && node.expr.is_some()
                    && node.output_idx.as_ref().is_some_and(|ix| !ix.is_empty())
            }
            _ => false,
        },
    }
}

/// Does `expr` carry a dependency edge that a `Expr::Variable` walk cannot see?
/// Such an edge makes the observed-trajectory dependency cone unsound, so the
/// pruning is disabled wholesale for a model containing one:
///
///   * `intersect_polygon` / `polygon_intersection_area` register a FAQ overlap
///     ring in `derived_rings` under their node id, and a `kind:"derived"`
///     contraction bound elsewhere consumes it by that id — not by name;
///   * a `distinct` aggregate likewise produces a data-dependent index set;
///   * a ragged range names its `offsets` FACTOR as a bare string;
///   * a `join` clause couples factors through key COLUMN names.
///
/// `simpleclimate.esm` (and any pure-stencil model) contains none of these, so
/// pruning is live there; a conservative-regrid / relational model keeps the
/// old un-pruned behaviour, bit-for-bit.
pub(super) fn expr_blocks_output_pruning(expr: &Expr) -> bool {
    let Expr::Operator(node) = expr else {
        return false;
    };
    if matches!(
        node.op.as_str(),
        "intersect_polygon" | "polygon_intersection_area" | "skolem" | "rank" | "distinct"
    ) {
        return true;
    }
    if node.join.is_some() || node.distinct == Some(true) {
        return true;
    }
    if let Some(ranges) = &node.ranges
        && ranges
            .values()
            .any(|r| r.ragged().is_some() || r.derived().is_some())
    {
        return true;
    }
    node.any_child(&mut expr_blocks_output_pruning)
}

/// The solve-wide tape program plus the FULL observed rule list its fallback
/// indices resolve against (`None` => legacy interpreter).
#[cfg(feature = "solve")]
type SolveTape = Option<(Rc<TapeProgram>, Rc<Vec<AlgebraicRule>>)>;

/// The run's [`SolutionMetadata`] — one construction for both driver exits.
#[cfg(feature = "solve")]
fn solution_metadata(
    solver_name: &str,
    stats: &SolveStats,
    tape_fallbacks: Vec<(String, String)>,
    merged_variable_renames: HashMap<String, String>,
    namespace: Option<String>,
) -> SolutionMetadata {
    SolutionMetadata {
        alg: solver_name.to_string(),
        n_rhs_calls: stats.n_rhs_calls,
        n_jacobian_calls: stats.n_jacobian_calls,
        n_accepted_steps: stats.n_accepted_steps,
        n_rejected_steps: stats.n_rejected_steps,
        tape_fallbacks,
        // Rides to the caller so a name-keyed read of the result can resolve a
        // spelling the merge deleted (issue #230).
        merged_variable_renames,
        namespace,
    }
}

/// The three-tier cadence partition of one solve's observed rules (see
/// [`ArrayCompiled::partition_observed_cadence`]).
#[cfg(feature = "solve")]
struct ObservedCadence {
    /// The CONST tier's names — consulted by the build inspection.
    static_names: HashSet<String>,
    /// CONST: materialized once at setup (the hoisted `static_obs`).
    static_rules: Vec<AlgebraicRule>,
    /// DISCRETE remainder: materialized once per segment.
    segment_static_rules: Vec<AlgebraicRule>,
    /// CONTINUOUS: re-evaluated every RHS step.
    continuous_rules: Vec<AlgebraicRule>,
    /// DISCRETE ∪ CONTINUOUS — the non-hot observed-trajectory output pass.
    varying_rules: Vec<AlgebraicRule>,
}

/// The solve-wide products of the cadence partition and the static hoist,
/// shared by every segment and by both driver exits.
#[cfg(feature = "solve")]
struct SolveSetup {
    cadence: ObservedCadence,
    /// The t0 state arrays the hoist (and the inspection snapshot) evaluate over.
    sa0: ArrMap,
    /// The CONST observeds, materialized ONCE — seeded into every RHS eval.
    static_obs: ArrMap,
}

/// One segmented (DISCRETE-cadence) integration's fixed inputs — bundled so
/// [`ArrayCompiled::run_segmented`] takes the run plus the refresh callback.
#[cfg(feature = "solve")]
struct SegmentedRun<'a> {
    t0: f64,
    t_end: f64,
    boundaries: &'a [f64],
    ic_vec: &'a [f64],
    param_vec: &'a [f64],
    setup: &'a SolveSetup,
    opts: &'a SolveOptions,
    tape: Option<&'a (Rc<TapeProgram>, Rc<Vec<AlgebraicRule>>)>,
}

/// The transitive dependency cone of `seeds` within a dependency-ORDERED rule
/// slice, returned in the original order (which is therefore still a valid
/// evaluation order). One backward pass suffices: a rule's dependencies always
/// precede it, so by the time the sweep reaches a rule every consumer of it has
/// already been visited and has registered its name.
///
/// `None` means "the cone is the whole slice" — the caller then keeps using the
/// original slice rather than paying a deep AST clone of every rule for nothing.
pub(super) fn dependency_cone(
    rules: &[AlgebraicRule],
    seeds: &HashSet<String>,
) -> Option<Vec<AlgebraicRule>> {
    let mut needed: HashSet<String> = seeds.clone();
    let mut keep = vec![false; rules.len()];
    let mut n_kept = 0usize;
    for (i, rule) in rules.iter().enumerate().rev() {
        if needed.contains(observed_rule_var(rule)) {
            keep[i] = true;
            n_kept += 1;
            collect_expr_var_refs(observed_rule_body(rule), &mut needed);
        }
    }
    if n_kept == rules.len() {
        return None;
    }
    Some(
        rules
            .iter()
            .zip(keep)
            .filter(|(_, k)| *k)
            .map(|(r, _)| r.clone())
            .collect(),
    )
}

#[cfg(test)]
mod forcing_channel_tests {
    //! PR-1 (ess-14f.7): the external refreshable forcing-array channel into the
    //! diffsol array RHS. These tests are the bead's acceptance evidence:
    //!   1. the RHS reads a forcing array *live* from the buffer,
    //!   2. a buffer mutation (a driver refreshing between cadence segments) is
    //!      reflected in the RHS output, and
    //!   3. the existing scalar-`p` / parameter path is unaffected.
    //!
    //! The forcing buffer is the runtime landing zone for a discrete-cadence
    //! loader's regridded field; here it is driven by hand (no I/O), exactly the
    //! "testable with a hand-built buffer" contract the plan (PR-1) specifies.
    use super::*;
    use crate::parse::load_string;

    fn arr1(v: &[f64]) -> ArrayD<f64> {
        ArrayD::from_shape_vec(IxDyn(&[v.len()]), v.to_vec()).unwrap()
    }

    /// A model whose state derivative reads an external forcing array `w`
    /// elementwise: `D(u[i]) = w[i]`, i ∈ [1,3]. `w` is declared in no variable
    /// block — it is a loader-fed field that resolves through the forcing buffer
    /// (the new lowest-precedence binding), precisely the channel PR-1 adds.
    fn forced_model() -> ArrayCompiled {
        let json = r#"
            {
              "esm": "1.1.0",
              "metadata": {
                "name": "forcing_channel"
              },
              "models": {
                "Forced": {
                  "variables": {
                    "u": {
                      "type": "unknown",
                      "shape": [
                        "i"
                      ],
                      "default": 0.0
                    }
                  },
                  "equations": [
                    {
                      "lhs": {
                        "op": "faq",
                        "args": [],
                        "output_idx": [
                          "i"
                        ],
                        "expr": {
                          "op": "D",
                          "args": [
                            {
                              "op": "index",
                              "args": [
                                "u",
                                "i"
                              ]
                            }
                          ],
                          "wrt": "t"
                        },
                        "ranges": {
                          "i": [
                            1,
                            3
                          ]
                        }
                      },
                      "rhs": {
                        "op": "faq",
                        "args": [],
                        "output_idx": [
                          "i"
                        ],
                        "ranges": {
                          "i": [
                            1,
                            3
                          ]
                        },
                        "expr": {
                          "op": "index",
                          "args": [
                            "w",
                            "i"
                          ]
                        }
                      }
                    }
                  ]
                }
              }
            }
            "#;
        let file = load_string(json).expect("parse forcing model");
        ArrayCompiled::from_file(&file).expect("compile forcing model")
    }

    #[test]
    fn rhs_reads_forcing_array_and_reflects_mutation() {
        let compiled = forced_model();
        let forcing = compiled.forcing_handle();
        let params = HashMap::new();
        let state = vec![0.0, 0.0, 0.0];

        // Refresh #1 — the RHS reads the forcing array live from the buffer.
        forcing
            .borrow_mut()
            .insert("w".to_string(), arr1(&[10.0, 20.0, 30.0]));
        let (dy1, _) = compiled.debug_eval_rhs(&state, 0.0, &params, false);
        assert_eq!(
            dy1,
            vec![10.0, 20.0, 30.0],
            "RHS must read the forcing array live from the buffer"
        );

        // Refresh #2 — a driver mutating the buffer between segments. The change
        // is reflected in the RHS output: the channel is live, not build-frozen.
        forcing
            .borrow_mut()
            .insert("w".to_string(), arr1(&[1.0, 2.0, 3.0]));
        let (dy2, _) = compiled.debug_eval_rhs(&state, 0.0, &params, false);
        assert_eq!(
            dy2,
            vec![1.0, 2.0, 3.0],
            "a buffer mutation must change the RHS output"
        );
        assert_ne!(
            dy1, dy2,
            "the refreshed forcing must produce a different RHS"
        );

        // The per-cell oracle path (force_scalar = true) reads the same buffer —
        // the production vectorized path bails forcing reads to this oracle.
        let (dy_oracle, _) = compiled.debug_eval_rhs(&state, 0.0, &params, true);
        assert_eq!(
            dy_oracle,
            vec![1.0, 2.0, 3.0],
            "the oracle path resolves forcing identically"
        );
    }

    #[test]
    fn forcing_flows_through_the_production_solve() {
        // The forcing buffer is captured (Rc clone) into the diffsol RHS closure,
        // so a constant forcing `D(u[i]) = w[i]` integrates to `u(t) = u0 + w·t`
        // through the real solver — proving the channel is wired into `simulate`,
        // not only the debug RHS entry point.
        let compiled = forced_model();
        compiled
            .forcing_handle()
            .borrow_mut()
            .insert("w".to_string(), arr1(&[2.0, 4.0, 6.0]));
        let params = HashMap::new();
        let ics = HashMap::new(); // states default to 0
        let opts = SolveOptions::default();
        let sol = compiled
            .solve((0.0, 1.0), &params, &ics, &opts)
            .expect("solve with forcing");
        // Final state ≈ u0 + w·1 = [2, 4, 6].
        for (i, want) in [2.0, 4.0, 6.0].iter().enumerate() {
            let got = *sol.state[i].last().expect("trajectory non-empty");
            assert!(
                (got - want).abs() < 1e-6,
                "forcing must drive the solve: state[{i}] got {got}, want {want}"
            );
        }
    }

    #[test]
    fn empty_forcing_leaves_param_path_unaffected() {
        // A parameter+state model `D(u[i]) = k·u[i]` with no forcing reference.
        // With an empty buffer the parameter/state path is byte-identical; and an
        // *unrelated* forcing entry does not perturb it, because forcing is
        // resolved last and only fills otherwise-unbound names.
        let json = r#"
            {
              "esm": "1.1.0",
              "metadata": {
                "name": "param_path"
              },
              "models": {
                "P": {
                  "variables": {
                    "u": {
                      "type": "unknown",
                      "shape": [
                        "i"
                      ]
                    },
                    "k": {
                      "type": "parameter"
                    }
                  },
                  "equations": [
                    {
                      "lhs": {
                        "op": "faq",
                        "args": [],
                        "output_idx": [
                          "i"
                        ],
                        "expr": {
                          "op": "D",
                          "args": [
                            {
                              "op": "index",
                              "args": [
                                "u",
                                "i"
                              ]
                            }
                          ],
                          "wrt": "t"
                        },
                        "ranges": {
                          "i": [
                            1,
                            2
                          ]
                        }
                      },
                      "rhs": {
                        "op": "faq",
                        "args": [],
                        "output_idx": [
                          "i"
                        ],
                        "ranges": {
                          "i": [
                            1,
                            2
                          ]
                        },
                        "expr": {
                          "op": "*",
                          "args": [
                            "k",
                            {
                              "op": "index",
                              "args": [
                                "u",
                                "i"
                              ]
                            }
                          ]
                        }
                      }
                    }
                  ]
                }
              }
            }
            "#;
        let file = load_string(json).expect("parse param model");
        let compiled = ArrayCompiled::from_file(&file).expect("compile param model");
        let mut params = HashMap::new();
        params.insert("k".to_string(), 2.0);
        let state = vec![3.0, 5.0];

        let (dy_no_forcing, _) = compiled.debug_eval_rhs(&state, 0.0, &params, false);
        assert_eq!(
            dy_no_forcing,
            vec![6.0, 10.0],
            "empty forcing leaves the parameter path identical (k·u)"
        );

        // An unrelated forcing entry must not leak into the parameter path.
        compiled
            .forcing_handle()
            .borrow_mut()
            .insert("unrelated".to_string(), arr1(&[99.0]));
        let (dy_with_junk, _) = compiled.debug_eval_rhs(&state, 0.0, &params, false);
        assert_eq!(
            dy_with_junk,
            vec![6.0, 10.0],
            "an unrelated forcing entry must not perturb the parameter path"
        );
    }

    #[test]
    fn fn_op_interp_linear_in_array_runtime() {
        // A scalar observed computed via `interp.linear` (a fuel-table lookup,
        // as in the coupled fire stack's FuelModelLookup) drives an array
        // state: D(u[i]) = looked_up. Before the `fn` arm existed, the observed
        // NaN-ed out and poisoned the whole RHS. At code = 2.0 the lookup is
        // the exact knot 40.0, so both cells' derivative must be 40.0.
        let json = r#"
            {
              "esm": "1.1.0",
              "metadata": {
                "name": "fn_array_path"
              },
              "models": {
                "F": {
                  "variables": {
                    "u": {
                      "type": "unknown",
                      "shape": [
                        "i"
                      ]
                    },
                    "code": {
                      "type": "parameter"
                    },
                    "looked_up": {
                      "type": "unknown"
                    }
                  },
                  "equations": [
                    {
                      "lhs": {
                        "op": "faq",
                        "args": [],
                        "output_idx": [
                          "i"
                        ],
                        "expr": {
                          "op": "D",
                          "args": [
                            {
                              "op": "index",
                              "args": [
                                "u",
                                "i"
                              ]
                            }
                          ],
                          "wrt": "t"
                        },
                        "ranges": {
                          "i": [
                            1,
                            2
                          ]
                        }
                      },
                      "rhs": {
                        "op": "faq",
                        "args": [],
                        "output_idx": [
                          "i"
                        ],
                        "ranges": {
                          "i": [
                            1,
                            2
                          ]
                        },
                        "expr": "looked_up"
                      }
                    },
                    {
                      "lhs": "looked_up",
                      "rhs": {
                        "op": "fn",
                        "name": "interp.linear",
                        "args": [
                          {
                            "op": "const",
                            "value": [
                              10.0,
                              20.0,
                              40.0,
                              80.0,
                              160.0
                            ],
                            "args": []
                          },
                          {
                            "op": "const",
                            "value": [
                              0.0,
                              1.0,
                              2.0,
                              3.0,
                              4.0
                            ],
                            "args": []
                          },
                          "code"
                        ]
                      }
                    }
                  ]
                }
              }
            }
            "#;
        let file = load_string(json).expect("parse fn model");
        let compiled = ArrayCompiled::from_file(&file).expect("compile fn model");
        let mut params = HashMap::new();
        params.insert("code".to_string(), 2.0);
        let state = vec![0.0, 0.0];
        let (dy, _) = compiled.debug_eval_rhs(&state, 0.0, &params, false);
        assert_eq!(
            dy,
            vec![40.0, 40.0],
            "interp.linear(...,2.0)=40 must drive both cells (was NaN before the `fn` arm)"
        );

        // The blend (not just a knot): code = 0.5 -> 15.0.
        params.insert("code".to_string(), 0.5);
        let (dy2, _) = compiled.debug_eval_rhs(&state, 0.0, &params, false);
        assert_eq!(dy2, vec![15.0, 15.0], "interp.linear(...,0.5)=15");
    }
}

#[cfg(all(test, feature = "solve"))]
mod fd_jvp_tests {
    //! The finite-difference Jacobian-vector product the XLA arm of the
    //! integrator's Jacobian closure runs ([`FdJvp`]): how many right-hand-side
    //! evaluations a Jacobian costs, when the kept `f(y)` is thrown away, and
    //! that keeping it changes no bit of the product.
    use super::*;
    use std::cell::Cell;

    /// A nonlinear right-hand side reading every argument, so a stale `f(y)`
    /// kept across a change of `y`, `p` or `t` would show in the product.
    fn f(y: &[f64], p: &[f64], t: f64, out: &mut [f64]) {
        let n = y.len();
        for (i, o) in out.iter_mut().enumerate() {
            *o = p[0] * y[i] * y[(i + 1) % n] - (t * y[i]).sin() + 1.0 / y[i];
        }
    }

    /// The product with both evaluations made every call: the reference a
    /// kept `f(y)` must match bit for bit.
    fn uncached(y: &[f64], p: &[f64], t: f64, v: &[f64]) -> Vec<f64> {
        let n = y.len();
        let mut y_norm = 0.0f64;
        for &yi in y {
            y_norm += yi * yi;
        }
        let y_norm = y_norm.sqrt().max(1.0);
        let eps = f64::EPSILON.sqrt() * y_norm;
        let yp: Vec<f64> = (0..n).map(|i| y[i] + eps * v[i]).collect();
        let (mut fy, mut fyp) = (vec![0.0; n], vec![0.0; n]);
        f(y, p, t, &mut fy);
        f(&yp, p, t, &mut fyp);
        (0..n).map(|i| (fyp[i] - fy[i]) / eps).collect()
    }

    fn unit(n: usize, j: usize) -> Vec<f64> {
        (0..n).map(|i| if i == j { 1.0 } else { 0.0 }).collect()
    }

    fn bits(v: &[f64]) -> Vec<u64> {
        v.iter().map(|x| x.to_bits()).collect()
    }

    /// Run one product through `jvp`, returning it and how many evaluations
    /// it took.
    fn apply(jvp: &mut FdJvp, y: &[f64], p: &[f64], t: f64, v: &[f64]) -> (Vec<f64>, usize) {
        let calls = Cell::new(0usize);
        let mut jv = vec![0.0; y.len()];
        jvp.apply(y, p, t, v, &mut jv, |s, q, t, out| {
            calls.set(calls.get() + 1);
            f(s, q, t, out);
            true
        });
        (jv, calls.get())
    }

    /// A dense Jacobian of `n` states, one product per column at one point,
    /// costs `n + 1` evaluations rather than `2n`, and every column is
    /// bit-identical to evaluating both points every call.
    #[test]
    fn a_jacobian_at_one_point_evaluates_the_base_once() {
        let (y, p, t) = (vec![0.7, 1.3, 2.9, 0.4], vec![1.5], 0.25);
        let n = y.len();
        let mut jvp = FdJvp::new(n);
        let mut total = 0;
        for j in 0..n {
            let v = unit(n, j);
            let (jv, calls) = apply(&mut jvp, &y, &p, t, &v);
            total += calls;
            assert_eq!(bits(&jv), bits(&uncached(&y, &p, t, &v)), "column {j}");
        }
        assert_eq!(total, n + 1);
    }

    /// Any change to the point — one state, the parameters, the time, or
    /// only the sign of a zero — evaluates the base again, and the product
    /// still matches the uncached one bit for bit.
    #[test]
    fn a_new_point_evaluates_the_base_again() {
        let (y, p, t) = (vec![0.7, 1.3, 0.0], vec![1.5], 0.25);
        let v = vec![0.3, -1.1, 0.8];
        let mut jvp = FdJvp::new(y.len());
        assert_eq!(apply(&mut jvp, &y, &p, t, &v).1, 2);
        assert_eq!(apply(&mut jvp, &y, &p, t, &v).1, 1, "same point");

        let mut y2 = y.clone();
        y2[1] = 1.3000000000000003;
        let mut signed_zero = y.clone();
        signed_zero[2] = -0.0;
        let points: [(&[f64], &[f64], f64, &str); 4] = [
            (&y2, &p, t, "one state"),
            (&y, &[2.5], t, "the parameters"),
            (&y, &p, 0.5, "the time"),
            (&signed_zero, &p, t, "the sign of a zero"),
        ];
        for (yk, pk, tk, what) in points {
            // Start each from the original point so each change is the only one.
            apply(&mut jvp, &y, &p, t, &v);
            let (jv, calls) = apply(&mut jvp, yk, pk, tk, &v);
            assert_eq!(calls, 2, "{what}");
            assert_eq!(bits(&jv), bits(&uncached(yk, pk, tk, &v)), "{what}");
        }
    }

    /// A failed evaluation of `f(y)` — a device error under `xla` — is not
    /// kept: the next product at the same point tries it again.
    #[test]
    fn a_failed_base_evaluation_is_not_kept() {
        let (y, p, t) = (vec![0.7, 1.3], vec![1.5], 0.25);
        let v = vec![1.0, 0.0];
        let mut jvp = FdJvp::new(y.len());
        let mut jv = vec![0.0; 2];
        let calls = Cell::new(0usize);
        jvp.apply(&y, &p, t, &v, &mut jv, |s, q, t, out| {
            calls.set(calls.get() + 1);
            if calls.get() == 1 {
                out.fill(f64::NAN);
                return false;
            }
            f(s, q, t, out);
            true
        });
        assert_eq!(calls.get(), 2);
        assert!(jv.iter().all(|x| x.is_nan()));
        let (jv, calls) = apply(&mut jvp, &y, &p, t, &v);
        assert_eq!(calls, 2, "the base is evaluated again");
        assert_eq!(bits(&jv), bits(&uncached(&y, &p, t, &v)));
    }
}

#[cfg(all(test, feature = "solve"))]
mod field_ic_memo_tests {
    //! Construction resolves every field initial condition (the compiler gate
    //! and the report need it), and the first solve takes that resolution
    //! instead of computing it again. Counted with the resolver's test hook.
    use super::field_ic_resolutions;
    use crate::compile_error::CompileError;
    use crate::problem::{Compiler, ProblemOptions, Remake, esm_problem, remake, solve};
    use crate::simulate::SimulateError;
    use crate::simulate_array::per_cell_cells;
    use crate::{SolveOptions, load_string};
    use serde_json::{Value, json};

    /// `u` over `n` cells with `D(u) = -u` and `ic(u) = rhs_ic`, and a
    /// parameter `a = 0.5` the `ic` may read.
    fn with_ic(n: usize, rhs_ic: Value) -> crate::EsmFile {
        let doc = json!({
            "esm": "1.1.0",
            "metadata": {"name": "FieldIcMemo"},
            "index_sets": {"x": {"kind": "interval", "size": n}},
            "models": {"M": {
                "variables": {
                    "u": {"type": "unknown", "units": "1", "shape": ["x"]},
                    "a": {"type": "parameter", "units": "1", "default": 0.5}
                },
                "equations": [
                    {"lhs": {"op": "ic", "args": ["u"]}, "rhs": rhs_ic},
                    {"lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                             "ranges": {"i": {"from": "x"}},
                             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}],
                                      "wrt": "t"}},
                     "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                             "ranges": {"i": {"from": "x"}},
                             "expr": {"op": "-", "args": [{"op": "index", "args": ["u", "i"]}]}}},
                ],
            }},
        });
        load_string(&doc.to_string()).expect("loads")
    }

    /// `ic(u)[i] = a · i`: a coordinate expression over the grid.
    fn scaled_index() -> Value {
        json!({"op": "faq", "args": [], "output_idx": ["i"],
               "ranges": {"i": {"from": "x"}},
               "expr": {"op": "*", "args": ["a", "i"]}})
    }

    fn opts(compiler: Compiler) -> ProblemOptions {
        ProblemOptions {
            compiler: Some(compiler),
            ..Default::default()
        }
    }

    fn first_column(sol: &crate::Solution) -> Vec<f64> {
        sol.state.iter().map(|r| r[0]).collect()
    }

    fn bits(sol: &crate::Solution) -> Vec<Vec<u64>> {
        sol.state
            .iter()
            .map(|r| r.iter().map(|x| x.to_bits()).collect())
            .collect()
    }

    #[test]
    fn the_first_solve_takes_the_resolution_construction_made() {
        let file = with_ic(3, scaled_index());
        for compiler in [Compiler::Native, Compiler::Interpreter] {
            let before = field_ic_resolutions();
            let prob = esm_problem(&file, (0.0, 1.0), opts(compiler))
                .unwrap_or_else(|e| panic!("[{compiler}] {e}"));
            assert_eq!(
                field_ic_resolutions() - before,
                1,
                "[{compiler}] construction"
            );
            assert!(
                prob.compiler_report()
                    .rules()
                    .iter()
                    .any(|r| r.kind == "initial condition"),
                "[{compiler}] the report keeps its row"
            );

            let first = solve(&prob, &SolveOptions::default()).expect("solves");
            assert_eq!(
                field_ic_resolutions() - before,
                1,
                "[{compiler}] the first solve must not resolve the ics again"
            );
            assert_eq!(first_column(&first), [0.5, 1.0, 1.5], "[{compiler}]");

            // A later solve resolves from the buffer as it stands, to the same
            // bits.
            let second = solve(&prob, &SolveOptions::default()).expect("solves");
            assert_eq!(field_ic_resolutions() - before, 2, "[{compiler}]");
            assert_eq!(bits(&first), bits(&second), "[{compiler}]");
        }
    }

    #[test]
    fn a_remake_with_new_parameters_resolves_again() {
        let file = with_ic(3, scaled_index());
        let prob = esm_problem(&file, (0.0, 1.0), opts(Compiler::Native)).expect("builds");
        let before = field_ic_resolutions();
        let changed = remake(
            &prob,
            &Remake {
                p: [("a".to_string(), 2.0)].into_iter().collect(),
                ..Default::default()
            },
        )
        .expect("remakes");
        let sol = solve(&changed, &SolveOptions::default()).expect("solves");
        assert_eq!(
            field_ic_resolutions() - before,
            1,
            "new parameters, new ics"
        );
        assert_eq!(first_column(&sol), [2.0, 4.0, 6.0]);
        // The memo was keyed to the construction's parameters, and a miss
        // spends it: the original resolves too, to its own values.
        let sol = solve(&prob, &SolveOptions::default()).expect("solves");
        assert_eq!(field_ic_resolutions() - before, 2);
        assert_eq!(first_column(&sol), [0.5, 1.0, 1.5]);
    }

    /// A strict compiler refuses an `ic` the reference evaluator walks per
    /// cell, and refuses it after one cell of the walk.
    #[test]
    fn a_large_per_cell_initial_condition_is_refused_after_one_cell() {
        let cumulative = json!({"op": "faq", "args": [], "output_idx": ["i"],
                                "ranges": {"i": {"from": "x"}, "j": {"from": "x"}},
                                "filter": {"op": "<=", "args": ["j", "i"]},
                                "expr": 1.0});
        let refusal = |n: usize| {
            let file = with_ic(n, cumulative.clone());
            let before = per_cell_cells();
            let err = esm_problem(&file, (0.0, 1.0), opts(Compiler::Native)).expect_err("per cell");
            let cells = per_cell_cells() - before;
            match err {
                SimulateError::Compile(CompileError::CompilerRefusedRule {
                    kind,
                    rule,
                    reason,
                    ..
                }) => ((kind, rule, reason), cells),
                other => panic!("expected compiler_refused_rule, got {other:?}"),
            }
        };
        let (small, _) = refusal(3);
        let (large, cells) = refusal(100_000);
        assert_eq!(large, small);
        assert_eq!(large.0, "initial condition");
        assert_eq!(cells, 1, "the walk must stop at its first cell");
    }
}
