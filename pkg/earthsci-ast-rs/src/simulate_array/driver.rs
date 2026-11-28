//! Solver plumbing on [`ArrayCompiled`]: `solve` / `solve_inspect`, what a
//! solve session sets up once (parameter vector, initial state, tape, cadence
//! partition, static hoist), the right-hand-side evaluators its segments run,
//! the observed trajectory exposure, the crate-private `debug_*` RHS entry
//! points behind [`super::SolveRhs`] and the tests, and the external
//! forcing-channel handle ([`ArrayCompiled::forcing_handle`]). The
//! segment loop itself is in `session`.

#[cfg(feature = "solve")]
use super::tape::TapeProgram;
use super::*;
#[cfg_attr(not(feature = "solve"), allow(unused_imports))]
use crate::simulate::SimulateError;
#[cfg(feature = "solve")]
use crate::simulate::{ReturnCode, Solution, SolutionMetadata, SolveOptions};
// The solver is optional (esm-libraries-spec §2.5.9). Everything below that
// touches `diffsol` is gated on the `solve` feature; the `debug_*` RHS entry
// points and the forcing-channel handle are not, because a caller that only
// BUILDS an EsmProblem still reaches them (through `SolveRhs`).
#[cfg(feature = "solve")]
use std::collections::HashSet;

/// A taped read-out of every observed, at one state and one time.
///
/// Under the strict compilers every rule is on the tape, so the observeds a
/// setup or output-time pass needs are computed by the tape's own CONST /
/// SEGMENT / CONTINUOUS sections. This runs the tape with its `Export`
/// publishes forced on and hands back the published map.
///
/// The production right-hand side keeps its exports OFF (nothing inside a
/// call reads them, and the publish is a memcpy per observed per call), so
/// this carries its own scratch and its own slab.
#[cfg(feature = "solve")]
struct TapedObserveds {
    scratch: RhsScratch,
    /// The tape writes `dy` whether or not the caller wants it; a setup or
    /// output-time pass does not, so it lands here and is discarded.
    dy: Vec<f64>,
}

#[cfg(feature = "solve")]
impl TapedObserveds {
    fn new(compiled: &ArrayCompiled, tape: &std::sync::Arc<TapeProgram>) -> Self {
        let mut scratch = compiled.new_scratch();
        scratch.install_tape(std::sync::Arc::clone(tape));
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
        evaluate_rhs_with_scratch(
            &compiled.rhs_call(state, params, t),
            &mut self.dy,
            &mut RhsStats::default(),
            &mut self.scratch,
        );
        self.scratch
            .taped_observeds()
            .expect("the harvester installs a tape on its own scratch")
    }
}

/// Every observed's value at one state and time, from the evaluator the
/// compiler names: the tape under `native` and `xla` ([`TapedObserveds`]),
/// the per-cell oracle under `interpreter`.
#[cfg(feature = "solve")]
enum ObservedReadout {
    Taped(Box<TapedObserveds>),
    /// The CONST observeds seeded once and retained; `rules` (the varying
    /// ones a caller needs) re-materialized at every call.
    PerCell {
        rules: Vec<AlgebraicRule>,
        static_keys: HashSet<String>,
        state_arrays: ArrMap,
        obs: ArrMap,
    },
}

#[cfg(feature = "solve")]
impl ObservedReadout {
    /// The observeds at `state` and `t`.
    fn at(&mut self, compiled: &ArrayCompiled, state: &[f64], params: &[f64], t: f64) -> &ArrMap {
        match self {
            ObservedReadout::Taped(taped) => taped.at(compiled, state, params, t),
            ObservedReadout::PerCell {
                rules,
                static_keys,
                state_arrays,
                obs,
            } => {
                refill_state_arrays(state_arrays, &compiled.var_shapes, state);
                obs.retain(|name, _| static_keys.contains(name));
                materialize_observeds_pass(
                    obs,
                    rules,
                    &compiled.eval_env(state_arrays, params, t),
                    &mut RhsStats::default(),
                );
                obs
            }
        }
    }

    /// What the last [`Self::at`] produced, without evaluating again.
    fn last(&self) -> &ArrMap {
        match self {
            ObservedReadout::Taped(taped) => taped.scratch_observeds(),
            ObservedReadout::PerCell { obs, .. } => obs,
        }
    }
}

impl ArrayCompiled {
    /// The observed read-out of a solve: from `tape` when the solve has one,
    /// else per cell, seeded with the CONST observeds `static_obs` and
    /// evaluating `rules` at each call.
    #[cfg(feature = "solve")]
    fn observed_readout(
        &self,
        tape: Option<&std::sync::Arc<TapeProgram>>,
        static_obs: &ArrMap,
        rules: Vec<AlgebraicRule>,
    ) -> ObservedReadout {
        match tape {
            Some(tape) => ObservedReadout::Taped(Box::new(TapedObserveds::new(self, tape))),
            None => ObservedReadout::PerCell {
                rules,
                static_keys: static_obs.keys().cloned().collect(),
                state_arrays: build_state_arrays(&self.var_shapes, &vec![0.0; self.n_states]),
                obs: static_obs.clone(),
            },
        }
    }
}

/// The refusal a model that serves [`crate::Compiler::Xla`] gets when no
/// compiled program was installed on it.
///
/// It is `compiler_unavailable` rather than a refused rule because nothing
/// about the DOCUMENT is wrong: the build either never got as far as emitting
/// (no `xla` feature) or handed the integrator a model it had not finished.
#[cfg(feature = "solve")]
pub(super) fn xla_not_installed() -> SimulateError {
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
/// every solve's Jacobian closure computes, over whichever evaluator the
/// compiler names ([`SolveRhs`]), with the evaluation at the base point shared
/// across calls and every buffer allocated once.
///
/// diffsol assembles a Jacobian by calling the product once per column, all
/// at ONE `(y, p, t)`. Only `f(y + εv)` depends on the column, so keeping
/// `f(y)` makes a Jacobian of `n` states cost `n + 1` right-hand-side
/// evaluations instead of `2n`. The kept `f(y)` is reused only when `y`, `p`
/// and `t` are bit-for-bit the ones it was computed at, and the forcing
/// buffer the right-hand side may read is fixed for the segment the closure
/// lives in, so the product is bit-identical to recomputing both evaluations
/// every call.
#[cfg(feature = "solve")]
pub(super) struct FdJvp {
    precision: crate::precision::Precision,
    base_y: Vec<f64>,
    base_p: Vec<f64>,
    base_t: f64,
    /// `f(base_y, base_p, base_t)`; meaningful only while `base_valid`.
    f_y: Vec<f64>,
    base_valid: bool,
    y_perturbed: Vec<f64>,
    f_yp: Vec<f64>,
}

#[cfg(feature = "solve")]
impl FdJvp {
    #[cfg(test)]
    pub(super) fn new(n_states: usize) -> Self {
        Self::with_precision(n_states, crate::precision::Precision::Float64)
    }

    pub(super) fn with_precision(n_states: usize, precision: crate::precision::Precision) -> Self {
        FdJvp {
            precision,
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
    pub(super) fn apply(
        &mut self,
        y: &[f64],
        p: &[f64],
        t: f64,
        v: &[f64],
        jv: &mut [f64],
        mut eval: impl FnMut(&[f64], &[f64], f64, &mut [f64]) -> bool,
    ) {
        let n = y.len();
        let eps = if self.precision.is_f32() {
            let scale = y
                .iter()
                .fold(1.0_f32, |scale, &v| scale.max((v as f32).abs()));
            f64::from(f32::EPSILON.sqrt() * scale)
        } else {
            let norm_sq: f64 = y.iter().map(|v| v * v).sum();
            f64::EPSILON.sqrt() * norm_sq.sqrt().max(1.0)
        };

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
        self.y_perturbed.extend(y.iter().zip(v).map(|(&yi, &vi)| {
            if self.precision.is_f32() {
                f64::from(yi as f32 + eps as f32 * vi as f32)
            } else {
                yi + eps * vi
            }
        }));
        self.f_yp.resize(n, 0.0);
        eval(&self.y_perturbed, p, t, &mut self.f_yp);
        for ((out, &fp), &f0) in jv.iter_mut().zip(&self.f_yp).zip(&self.f_y) {
            *out = if self.precision.is_f32() {
                f64::from((fp as f32 - f0 as f32) / eps as f32)
            } else {
                (fp - f0) / eps
            };
        }
    }
}

/// Bitwise slice equality: `-0.0` and `0.0` differ, and a `NaN` equals the
/// same `NaN`, which is what reusing a function value requires.
#[cfg(feature = "solve")]
fn same_bits(a: &[f64], b: &[f64]) -> bool {
    a.len() == b.len() && a.iter().zip(b).all(|(x, y)| x.to_bits() == y.to_bits())
}

/// The error a latched fault reports.
pub(super) fn fault_error(fault: Fault) -> SimulateError {
    crate::compile_error::CompileError::InterpreterBuildError {
        details: fault.message,
    }
    .into()
}

/// A solve that fails after the right-hand side latched a fault failed
/// BECAUSE of it: the fault substituted `NaN`, and the integrator's step-size
/// or error-test failure is the symptom. Report the latched fault instead, as
/// `assemble_solution` does on success.
#[cfg(feature = "solve")]
pub(super) fn fault_first(faults: &FaultScope, err: SimulateError) -> SimulateError {
    faults.take().map_or(err, fault_error)
}

/// Which of a solve's two evaluation workspaces a call uses: the right-hand
/// side's or the finite-difference Jacobian's, so the two never alias.
#[cfg(feature = "solve")]
#[derive(Clone, Copy)]
pub(super) enum Use {
    Rhs,
    Jacobian,
}

/// What evaluates one integration segment's right-hand side: one variant per
/// compiler, and the only place the solve branches on it.
#[cfg(feature = "solve")]
pub(super) enum SolveRhs<'a> {
    /// `native`: the solve's taped program.
    Program {
        program: &'a SolveProgram,
        forcing: &'a RefCell<HashMap<String, ArrayD<f64>>>,
    },
    /// `interpreter`: the per-cell oracle.
    PerCell(Box<PerCellRhs<'a>>),
    /// `xla`: the compiled executable. A device failure lands in `fault`
    /// (first one wins) and leaves the derivative NaN so the solver stops.
    #[cfg(feature = "xla")]
    Xla {
        program: Rc<crate::xla_runtime::CompiledRhs>,
        fault: Rc<RefCell<Option<String>>>,
    },
}

/// The `interpreter`'s right-hand side for one segment: the per-cell oracle
/// over the CONTINUOUS observeds and the state rules, on scratches seeded
/// once with the CONST and DISCRETE observeds.
#[cfg(feature = "solve")]
pub(super) struct PerCellRhs<'a> {
    pub(super) compiled: &'a ArrayCompiled,
    pub(super) continuous_rules: &'a [AlgebraicRule],
    pub(super) seed: ArrMap,
    pub(super) rhs: RefCell<Option<RhsScratch>>,
    pub(super) jac: RefCell<Option<RhsScratch>>,
}

#[cfg(feature = "solve")]
impl SolveRhs<'_> {
    /// Write the right-hand side at `(state, params, t)` into `out`, reporting
    /// whether the evaluation succeeded.
    pub(super) fn eval(
        &self,
        slot: Use,
        state: &[f64],
        params: &[f64],
        t: f64,
        out: &mut [f64],
    ) -> bool {
        match self {
            SolveRhs::Program { program, forcing } => {
                let ws = match slot {
                    Use::Rhs => &program.rhs,
                    Use::Jacobian => &program.jac,
                };
                let mut ws = ws.borrow_mut();
                let ws = ws.get_or_insert_with(|| program.program.solve_workspace());
                program
                    .program
                    .eval_solve(state, params, t, &forcing.borrow(), out, ws);
                true
            }
            SolveRhs::PerCell(pc) => {
                let scratch = match slot {
                    Use::Rhs => &pc.rhs,
                    Use::Jacobian => &pc.jac,
                };
                let mut scratch = scratch.borrow_mut();
                let scratch = scratch.get_or_insert_with(|| {
                    let mut s = pc.compiled.new_scratch();
                    s.set_static(pc.seed.clone());
                    s
                });
                let c = pc.compiled;
                evaluate_rhs_with_scratch(
                    &RhsCall {
                        observed_rules: pc.continuous_rules,
                        ..c.rhs_call(state, params, t)
                    },
                    out,
                    &mut RhsStats::default(),
                    scratch,
                );
                true
            }
            #[cfg(feature = "xla")]
            SolveRhs::Xla { program, fault } => {
                out.fill(0.0);
                run_xla_rhs(program, fault, state, params, t, out)
            }
        }
    }
}

/// One evaluation a model's field initial conditions performed
/// ([`ArrayCompiled::field_ic_records`]).
#[cfg(feature = "solve")]
#[derive(Clone, Debug)]
pub(crate) struct FieldIcRecord {
    /// The `ic` target, or the state-free observed materialized for its scope.
    pub name: String,
    /// `"initial condition"`, `"initial-condition scope"` or
    /// `"initialization equation"`.
    pub kind: &'static str,
    /// The evaluator that served it, or — under a strict compiler — the
    /// tape's reason for declining what the reference evaluator would have
    /// walked per cell: the refusal.
    pub route: Result<BuildRoute, String>,
}

/// A strict compiler's refusal of a build-time field evaluation `name` of
/// `kind`: recorded in `records` when construction is exercising the
/// evaluations, and otherwise (a solve) raised.
#[cfg(feature = "solve")]
fn refuse_field_ic(
    records: Option<&mut Vec<FieldIcRecord>>,
    name: &str,
    kind: &'static str,
    why: String,
) -> Result<(), SimulateError> {
    match records {
        Some(sink) => {
            sink.push(FieldIcRecord {
                name: name.to_string(),
                kind,
                route: Err(why),
            });
            Ok(())
        }
        None => Err(SimulateError::InvalidFieldInitialCondition {
            name: name.to_string(),
            details: format!("the tape declined it: {why}"),
        }),
    }
}

/// The field initial conditions construction resolved, held for the first
/// solve ([`ArrayCompiled::field_ic_records`] fills it, the first solve's
/// `build_initial_state` takes it, and [`ArrayCompiled::initial_state`] reads it
/// in place).
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
/// * the forcing fields the resolution read (every name
///   [`ArrayCompiled::ic_read_names`] gives, as the forcing buffer holds it),
///   recorded as a fingerprint of their names, shapes and values
///   ([`ArrayCompiled::ic_forcing_fingerprint`]) and compared when the memo
///   is read, so a write to one of them by anyone, between construction and
///   the solve, retires the memo, and a write to any other field does not.
///
/// A resolution that read a discrete-cadence field is never kept (the field
/// is not sampled yet at construction), so the refresh a solve makes at its
/// start, before the initial state, cannot move what the memo holds. Every
/// read but the first solve's leaves the memo in place; the first solve takes
/// it, and every later one resolves from the buffer as it stands.
///
/// Initial-condition overrides are applied over the result, not read by it.
#[cfg(feature = "solve")]
pub(crate) struct FieldIcMemo {
    params: Vec<u64>,
    /// [`ArrayCompiled::ic_forcing_fingerprint`] when the resolution ran.
    forcing: u64,
    /// The start of the run the `ic` right-hand sides were evaluated at
    /// (esm-spec §11.4.2), as bits.
    t0: u64,
    slots: HashMap<usize, f64>,
}

/// Where an `ic` right-hand side reads the start of the run (esm-spec
/// §11.4.2): the start `t0` itself, which `t` is bound to, and the data-fed
/// fields' values there.
#[cfg(feature = "solve")]
pub(crate) struct IcStart<'a> {
    /// The start of the run, `tspan.0`.
    pub(crate) t0: f64,
    /// Fields read in place of the forcing buffer's: each data-fed field's
    /// value at `t0`, where the buffer holds another record or none.
    pub(crate) at_t0: Option<&'a HashMap<String, ArrayD<f64>>>,
    /// Buffer fields not to read: a discrete-cadence field whose value at
    /// `t0` is not known here (the buffer may hold any record of it).
    pub(crate) exclude: &'a HashSet<String>,
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
        !self.is_interpreter()
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
    /// tape, and every rule walked per cell.
    pub(crate) fn is_interpreter(&self) -> bool {
        self.runtime_mode == RuntimeMode::Interpreter
    }

    /// The flatten-time merge map (issue #230): every state spelling an
    /// `operator_compose` renaming match DELETED, mapped onto the survivor.
    pub(crate) fn merged_renames(&self) -> &HashMap<String, String> {
        &self.merged_renames
    }

    /// The shaped parameters this build left with no value (see the field).
    pub(crate) fn unvalued_shaped_params(&self) -> &[String] {
        &self.unvalued_shaped_params
    }

    /// The names the forcing buffer serves: every parameter refreshed from
    /// outside the model (a data source or a registered handler).
    pub(crate) fn forcing_names(&self) -> impl Iterator<Item = &String> {
        self.forcing_decls.keys()
    }

    /// Each forcing parameter's declared shape resolved against the index-set
    /// registry, `None` where the registry cannot size it (see the field).
    pub(crate) fn declared_forcing_shapes(
        &self,
    ) -> &indexmap::IndexMap<String, Option<Vec<usize>>> {
        &self.declared_forcing_shapes
    }

    /// Whether the forcing buffer serves `name` (a compiled name).
    pub(crate) fn serves_forcing(&self, name: &str) -> bool {
        self.forcing_decls.contains_key(name)
    }

    /// The resolver that routes run-time provider keys (and the
    /// `const_arrays` keys checked against them) onto this build's parameters;
    /// see [`ParameterKeyResolver`].
    pub(crate) fn parameter_key_resolver(&self) -> ParameterKeyResolver {
        let params: HashSet<String> = self
            .forcing_decls
            .keys()
            .chain(self.param_names.iter())
            .cloned()
            .collect();
        let known = crate::simulate::SuffixIndex::new(params.iter().map(String::as_str));
        let others: HashSet<String> = self
            .var_shapes
            .keys()
            .cloned()
            .chain(self.observed_rule_names())
            .filter(|n| !params.contains(n))
            .collect();
        ParameterKeyResolver {
            params,
            known,
            others,
            namespaces: self.override_namespaces(),
        }
    }

    /// The declared default of forcing parameter `name`: `None` when it
    /// declares none, `Some(None)` when its shape does not resolve yet, and
    /// otherwise the dense field it denotes over that shape.
    pub(crate) fn forcing_default(&self, name: &str) -> Option<Option<ArrayD<f64>>> {
        let entry = self.forcing_defaults.get(name)?;
        Some(entry.as_ref().and_then(|(shape, values)| {
            ArrayD::from_shape_vec(ndarray::IxDyn(shape), values.clone()).ok()
        }))
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
    ///
    /// A write to a field the model's field initial conditions read retires
    /// what construction resolved from it ([`FieldIcMemo`]): the next solve
    /// resolves them from the buffer as it then stands.
    pub fn forcing_handle(&self) -> Rc<RefCell<HashMap<String, ArrayD<f64>>>> {
        Rc::clone(&self.forcing)
    }

    /// Every DATA-FED parameter this build routed to the forcing channel, as
    /// `(name, data_sources key)` — see [`crate::data_fed::refuse_unbound`],
    /// which is the only reader.
    pub(crate) fn data_fed(&self) -> &[(String, String)] {
        &self.data_fed
    }

    /// Whether this model has anything for the ODE solver to integrate — at
    /// least one `D(var, t) = …` rule.
    ///
    /// An array model whose every equation is ALGEBRAIC compiles to observed
    /// rules and no `RhsRule`, so it evaluates without the integrator ever
    /// touching a value.
    pub fn has_differential_equations(&self) -> bool {
        !self.rhs_rules.is_empty()
    }

    /// The model a one-model document is shown under (see the field), or
    /// `None`.
    pub(crate) fn namespace(&self) -> Option<&str> {
        self.namespace.as_deref()
    }

    /// `name` as this artifact shows it: without the one-model document's
    /// `M.` ([`Self::namespace`]).
    pub(crate) fn shown<'a>(&self, name: &'a str) -> &'a str {
        self.namespace
            .as_deref()
            .and_then(|ns| name.strip_prefix(ns))
            .and_then(|rest| rest.strip_prefix('.'))
            .unwrap_or(name)
    }

    /// What this build knows of its variables by name
    /// ([`super::BuiltVariables`]), keyed by the name the build gives each. A variable
    /// declared without a `shape` that the build evaluates over a grid — a
    /// pointwise lift (esm-spec §10.5), a lifted reaction-system species, an
    /// input a `variable_map` binds to a shaped host variable — has the grid's
    /// index sets there.
    pub(crate) fn built_variables(&self) -> &super::BuiltVariables {
        &self.built_variables
    }

    /// The OBSERVED variables this model declares, in dependency order, as
    /// this artifact shows them ([`Self::shown`]).
    pub fn observed_variable_names(&self) -> Vec<String> {
        self.observed_rule_names()
            .map(|n| self.shown(&n).to_string())
            .collect()
    }

    /// The OBSERVED variables this model declares, in dependency order, by
    /// the names the build gave them. What
    /// [`crate::problem::observed_trajectories`] resolves a caller's name
    /// against, with the §5.8 precedence.
    pub(crate) fn observed_rule_names(&self) -> impl Iterator<Item = String> + '_ {
        self.observed_rules
            .iter()
            .map(|r| observed_rule_var(r).clone())
    }

    /// Every state slot's name (`u[2,3]`, or a 0-D state's bare name), in
    /// flat state-vector order, as this artifact shows it ([`Self::shown`]).
    /// Built from the slot layout the first time it is asked for, then kept.
    pub fn state_variable_names(&self) -> &[String] {
        if self.namespace.is_none() {
            return self.qualified_state_names();
        }
        self.state_names.get_or_init(|| {
            super::layout::slot_names_with(&self.var_shapes, |v| self.shown(v).to_string())
        })
    }

    /// Every state slot's name as the build made it (`M.u[2,3]`), in flat
    /// state-vector order: the spelling the Problem reports.
    pub(crate) fn qualified_state_names(&self) -> &[String] {
        self.qualified_state_names
            .get_or_init(|| super::layout::slot_names(&self.var_shapes))
    }

    /// The length of the flat state vector.
    pub fn n_states(&self) -> usize {
        self.n_states
    }
    /// The scalar parameters, in parameter-vector order, as this artifact
    /// shows them ([`Self::shown`]).
    pub fn parameter_names(&self) -> &[String] {
        if self.namespace.is_none() {
            return &self.param_names;
        }
        self.shown_param_names.get_or_init(|| {
            self.param_names
                .iter()
                .map(|n| self.shown(n).to_string())
                .collect()
        })
    }

    /// The scalar parameters, in parameter-vector order, by the names the
    /// build gave them.
    pub(crate) fn qualified_parameter_names(&self) -> &[String] {
        &self.param_names
    }

    /// Cadence partition of the observed rules given the discrete-forcing names,
    /// as `(const, discrete, continuous)` sorted name lists, for the
    /// cadence-tier test: a forcing-derived but state-free / `t`-free observed
    /// must land in the DISCRETE tier (materialized once per segment), not
    /// CONTINUOUS (recomputed every step). Mirrors the split a solve session makes.
    #[cfg(test)]
    pub(super) fn cadence_partition(
        &self,
        discrete_forcing: &[String],
    ) -> (Vec<String>, Vec<String>, Vec<String>) {
        let df: HashSet<String> = discrete_forcing.iter().cloned().collect();
        let deps = self.observed_dependencies(&df);
        let tier = |c: crate::cadence::Cadence| -> Vec<String> {
            self.observed_rules
                .iter()
                .map(observed_rule_var)
                .filter(|n| deps.get(n).is_some_and(|s| s.cadence() == c))
                .cloned()
                .collect()
        };
        let mut const_ = tier(crate::cadence::Cadence::Const);
        let mut discrete = tier(crate::cadence::Cadence::Discrete);
        let mut continuous = tier(crate::cadence::Cadence::Continuous);
        const_.sort();
        discrete.sort();
        continuous.sort();
        (const_, discrete, continuous)
    }

    /// Evaluate the RHS `f(state, t)` once through the per-cell oracle and
    /// return `(dy, stats)`: the reference a compiler's evaluation is checked
    /// against.
    pub(crate) fn debug_eval_rhs(
        &self,
        state: &[f64],
        t: f64,
        params: &HashMap<String, f64>,
    ) -> (Vec<f64>, RhsStats) {
        let param_vec = self.debug_resolve_params(params);
        let mut dy = vec![0.0f64; self.n_states];
        let mut stats = RhsStats::default();
        let mut scratch = self.new_scratch();
        evaluate_rhs_with_scratch(
            &self.rhs_call(state, &param_vec, t),
            &mut dy,
            &mut stats,
            &mut scratch,
        );
        (dy, stats)
    }

    /// The inputs of one right-hand-side call over this model's full rule set.
    pub(super) fn rhs_call<'a>(
        &'a self,
        state: &'a [f64],
        params: &'a [f64],
        t: f64,
    ) -> RhsCall<'a> {
        RhsCall {
            rhs_rules: &self.rhs_rules,
            observed_rules: &self.observed_rules,
            var_shapes: &self.var_shapes,
            param_names: &self.param_names,
            state,
            params,
            forcing: &self.forcing,
            t,
            declared: &self.declared_names,
            ops: &self.operators,
        }
    }

    /// An evaluation environment over this model at `state_arrays`, `params`
    /// and `t`.
    fn eval_env<'a>(&'a self, state_arrays: &'a ArrMap, params: &'a [f64], t: f64) -> EvalEnv<'a> {
        EvalEnv {
            state_arrays,
            params,
            param_names: &self.param_names,
            t,
            derived_extents: empty_derived_extents(),
            forcing: &self.forcing,
            const_arrays: &self.const_scope,
            declared: &self.declared_names,
            ops: &self.operators,
        }
    }

    /// A scratch sized to this model, with its const-array registry installed.
    pub(super) fn new_scratch(&self) -> RhsScratch {
        let mut s = RhsScratch::new(&self.var_shapes);
        s.set_const_arrays(std::sync::Arc::clone(&self.const_scope));
        s
    }

    /// The `interpreter`'s per-segment seed: the CONST observeds `static_obs`
    /// plus the DISCRETE ones, materialized once for the segment. The caller
    /// refreshed the forcing buffer at the segment's start and it stays fixed
    /// within the segment, so these state-free, `t`-free observeds are
    /// constant there. Under the strict compilers the tape's SEGMENT section
    /// computes them itself, on the same schedule.
    #[cfg(feature = "solve")]
    pub(super) fn segment_seed(
        &self,
        static_obs: &ArrMap,
        segment_static_rules: &[AlgebraicRule],
        u0: &[f64],
        param_vec: &[f64],
        t0: f64,
    ) -> ArrMap {
        let mut seed = static_obs.clone();
        if segment_static_rules.is_empty() {
            return seed;
        }
        let sa_seg = build_state_arrays(&self.var_shapes, u0);
        materialize_observeds_pass(
            &mut seed,
            segment_static_rules,
            &self.eval_env(&sa_seg, param_vec, t0),
            &mut RhsStats::default(),
        );
        seed
    }

    /// Build a scratch with the compiled tape installed, for the tape-versus-
    /// oracle, allocation-steady-state and invalidation tests, driven through
    /// [`Self::debug_eval_rhs_into`].
    ///
    /// A model whose tape declined a rule has no program to install, so this
    /// is the same refusal a solve raises ([`Self::strict_tape`]).
    #[cfg(test)]
    pub(crate) fn debug_new_scratch_taped(&self) -> Result<RhsScratch, SimulateError> {
        let mut s = self.new_scratch();
        s.install_tape(self.strict_tape(&HashSet::new())?);
        Ok(s)
    }

    /// Resolve a parameter map into the positional parameter vector once, so the
    /// zero-allocation RHS test can pre-build it outside the measured loop.
    /// Keys are matched as a solve matches them (esm-spec §6.6.2); leniently,
    /// so a key that designates no parameter is ignored.
    pub(crate) fn debug_resolve_params(&self, params: &HashMap<String, f64>) -> Vec<f64> {
        use crate::simulate::KeyHit;
        let namespaces = self.override_namespaces();
        let mut resolved: HashMap<String, f64> = HashMap::new();
        for (key, &v) in params {
            match crate::simulate::resolve_key(&self.param_index, &namespaces, key) {
                KeyHit::Exact(name) => {
                    resolved.insert(name, v);
                }
                KeyHit::Alias(name) => {
                    resolved.entry(name).or_insert(v);
                }
                KeyHit::Ambiguous(_) | KeyHit::Unknown => {}
            }
        }
        let params = &resolved;
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

    /// Evaluate the RHS into a caller-owned `dy` using a caller-owned scratch:
    /// the tape when the scratch carries one
    /// ([`Self::debug_new_scratch_taped`]), else the per-cell oracle. With a
    /// warmed taped scratch and a pre-resolved `param_vec`, this performs no
    /// heap allocation.
    pub(crate) fn debug_eval_rhs_into(
        &self,
        state: &[f64],
        t: f64,
        param_vec: &[f64],
        dy: &mut [f64],
        scratch: &mut RhsScratch,
        stats: &mut RhsStats,
    ) {
        evaluate_rhs_with_scratch(&self.rhs_call(state, param_vec, t), dy, stats, scratch);
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
            AlgebraicRule::Scalar { body, .. } => {
                check_scalar_evaluable_in(body, &self.operators).is_ok()
            }
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
        scratch.set_const_arrays(std::sync::Arc::clone(&self.const_scope));
        if self.tape_serves_passes() {
            scratch.install_tape(self.strict_tape(&HashSet::new())?);
            scratch.set_exports_active(true);
        }
        let mut dy: Vec<f64> = Vec::new();
        let faults = FaultScope::enter();
        for (k, &t) in times.iter().enumerate() {
            evaluate_rhs_with_scratch(
                &self.rhs_call(&[], &param_vec, t),
                &mut dy,
                &mut RhsStats::default(),
                &mut scratch,
            );
            if let Some(fault) = faults.take() {
                return Err(fault_error(fault));
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
    /// (column-major, matching the slot enumeration in [`Self::from_model_with_arrays`]); a
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
        start: &IcStart<'_>,
    ) -> Result<HashMap<usize, f64>, SimulateError> {
        let mut out: HashMap<usize, f64> = HashMap::new();
        if self.field_ics.is_empty() {
            return Ok(out);
        }
        self.refuse_ic_state_reads()?;
        // The independent variable is the start of the run (esm-spec §11.4.2).
        let mut with_t: HashMap<String, f64>;
        let params: &HashMap<String, f64> = {
            with_t = params.clone();
            with_t.insert("t".to_string(), start.t0);
            &with_t
        };
        #[cfg(test)]
        FIELD_IC_RESOLUTIONS.with(|c| c.set(c.get() + 1));
        // `interpreter` runs these on the per-cell oracle like every other
        // evaluation it performs; the other compilers evaluate whole arrays.
        let mode = BuildEval::of_compiler(self.is_interpreter());
        // esm-spec §6.6.5 build-time scope: materialize the STATE-FREE
        // observeds an `ic` RHS reads (a `const` gather, a parameter-only
        // expression) over the provider forcing buffer. A provider-served field
        // of the same name WINS — loaded data beats a document-side definition,
        // the same direction `vi_factor_arrays` takes — and the definitions
        // only it read are not evaluated. An observed that does not evaluate is
        // skipped rather than raised on: it simply is not in the ic scope, and
        // the resolver's own diagnostic then names the unusable RHS, and why.
        //
        // Built ONLY when the document has such definitions: with none (every
        // document before this), the resolver reads the forcing buffer straight
        // through and no provider field is copied.
        //
        // A data-fed field is read at the start of the run (esm-spec §11.4.2):
        // from `start.at_t0` where the caller sampled it there, and never as
        // a discrete-cadence record the buffer holds for another time.
        //
        // Only the fields the evaluation reads are taken, each from
        // `start.at_t0` first, then from the buffer unless excluded.
        let mut borrowed: HashMap<String, ArrayD<f64>> = {
            let buffer = self.forcing.borrow();
            self.ic_read_names()
                .into_iter()
                .filter_map(|name| {
                    let value = start
                        .at_t0
                        .and_then(|m| m.get(&name))
                        .or_else(|| {
                            (!start.exclude.contains(&name))
                                .then(|| buffer.get(&name))
                                .flatten()
                        })?
                        .clone();
                    Some((name, value))
                })
                .collect()
        };
        let mut scope: Option<HashMap<String, ArrayD<f64>>> = None;
        // A scalar-valued scope definition (`dz = H/N`) binds where a
        // parameter does, for the definitions after it and for the targets.
        let mut scope_params: Option<HashMap<String, f64>> = None;
        let mut skipped: HashMap<&str, String> = self
            .ic_scope
            .excluded
            .iter()
            .map(|(name, reason)| (name.as_str(), reason.clone()))
            .collect();
        if !self.ic_scope.defs.is_empty() {
            // The cone still to evaluate: from the definitions the `ic`s name,
            // through what each reads, stopping at a provider-served field.
            let by_name: HashMap<&str, &super::compile::IcScopeDef> = self
                .ic_scope
                .defs
                .iter()
                .map(|d| (d.name.as_str(), d))
                .collect();
            let mut live: HashSet<&str> = HashSet::new();
            let mut stack: Vec<&str> = self.ic_scope.roots.iter().map(String::as_str).collect();
            while let Some(name) = stack.pop() {
                if borrowed.contains_key(name) || !live.insert(name) {
                    continue;
                }
                if let Some(def) = by_name.get(name) {
                    stack.extend(def.deps.iter().map(String::as_str));
                }
            }
            let mut built: HashMap<String, ArrayD<f64>> = std::mem::take(&mut borrowed);
            let mut bound: HashMap<String, f64> = params.clone();
            // In dependency order: everything a definition reads is built (or
            // known not to be) by the time it is reached, so one pass is enough.
            for def in &self.ic_scope.defs {
                if !live.contains(def.name.as_str()) {
                    continue;
                }
                // Never evaluated with a read missing: an absent name does not
                // resolve, so the evaluation could only fail.
                if let Some(missing) = def
                    .needs
                    .iter()
                    .find(|n| !built.contains_key(*n) && !bound.contains_key(*n))
                {
                    let why = match skipped.get(missing.as_str()) {
                        Some(inner) => format!("reads '{missing}', which {inner}"),
                        None => format!("reads '{missing}', which is not in the build-time scope"),
                    };
                    skipped.insert(&def.name, why);
                    continue;
                }
                let routed = eval_buildtime_field_routed(
                    Some(&def.name),
                    &def.body,
                    &self.index_sets,
                    &bound,
                    &built,
                    mode,
                    &self.operators,
                );
                let route = match routed {
                    Ok(Routed::Refused(why)) => {
                        // A strict compiler's refusal: the tape declined
                        // what the reference evaluator would walk per cell.
                        return refuse_field_ic(
                            records.as_deref_mut(),
                            &def.name,
                            "initial-condition scope",
                            why,
                        )
                        .map(|()| out);
                    }
                    Ok(Routed::Value(Value::Array(arr), route)) => {
                        built.insert(def.name.clone(), *arr);
                        route
                    }
                    Ok(Routed::Value(Value::Scalar(v), route)) => {
                        bound.insert(def.name.clone(), v);
                        route
                    }
                    Err(e) => {
                        skipped.insert(&def.name, format!("does not evaluate at build time: {e}"));
                        continue;
                    }
                };
                if let Some(sink) = records.as_deref_mut() {
                    sink.push(FieldIcRecord {
                        name: def.name.clone(),
                        kind: "initial-condition scope",
                        route: Ok(route),
                    });
                }
            }
            scope = Some(built);
            scope_params = Some(bound);
        }
        let forcing: &HashMap<String, ArrayD<f64>> = scope.as_ref().unwrap_or(&borrowed);
        let params: &HashMap<String, f64> = scope_params.as_ref().unwrap_or(params);
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
            // evaluate the WHOLE field with one build-time evaluation and
            // then read a single cell — so recomputing it per cell was O(cells)
            // full-field evaluations for an O(cells)-sized result. Resolve it
            // once per target and let every cell index the cached field. The
            // cell-independent cases (1 loaded field / 2 constant) ignore it.
            let mut memo = super::compile::IcTargetMemo {
                mode,
                field: None,
                route: None,
            };
            for flat in 0..total {
                let multi = flat_to_multi_col_major(flat, &vs.shape);
                let slot = vs.flat_offset + flat;
                let value = resolve_field_ic_cell(
                    target,
                    rhs,
                    &multi,
                    forcing,
                    &self.index_sets,
                    params,
                    &mut memo,
                    &self.operators,
                );
                if let Some(Err(why)) = memo.route {
                    // As for the scope above: the tape's decline is the
                    // refusal.
                    return refuse_field_ic(
                        records.as_deref_mut(),
                        target,
                        "initial condition",
                        why,
                    )
                    .map(|()| out);
                }
                out.insert(
                    slot,
                    value.map_err(|e| explain_ic_scope_miss(e, rhs, &skipped))?,
                );
            }
            if let Some(sink) = records.as_deref_mut() {
                sink.push(FieldIcRecord {
                    name: target.clone(),
                    kind: "initial condition",
                    route: memo.route.unwrap_or(Ok(BuildRoute::Whole)),
                });
            }
        }
        Ok(out)
    }

    /// The initial state before any override: each variable's default (one
    /// fill, or one gather of its inline data), then the field `ic` slots.
    /// The mask, when present, flags the slots neither of them set.
    #[cfg(feature = "solve")]
    fn seeded_defaults(&self, field_ic_map: &HashMap<usize, f64>) -> (Vec<f64>, Option<Vec<bool>>) {
        let mut ic_vec = vec![0.0f64; self.n_states];
        let mut unset: Option<Vec<bool>> = None;
        for ((_, vs), default) in self.var_shapes.iter().zip(&self.state_defaults) {
            let n = vs.shape.iter().copied().product::<usize>().max(1);
            let range = vs.flat_offset..vs.flat_offset + n;
            if !super::layout::write_state_default(vs, default, &mut ic_vec[range.clone()]) {
                unset.get_or_insert_with(|| vec![false; self.n_states])[range].fill(true);
            }
        }
        for (&slot, &v) in field_ic_map {
            ic_vec[slot] = v;
            if let Some(u) = unset.as_mut() {
                u[slot] = false;
            }
        }
        (ic_vec, unset)
    }

    /// Evaluate the triangular steps of the initialization system (esm-spec
    /// §11.4.3) into `ic_vec`, in evaluation order: `u ~ faq(…)` assigns every
    /// cell of its ranges the value its body takes there, and a scalar target
    /// takes its right-hand side's value. Each reads the initial state seeded
    /// so far (defaults, explicit initial conditions, the supplied values and
    /// the steps before it) by state name — the step's `ic(w)` read as `w` —
    /// with the parameters and forcing fields. A slot in `keep` keeps its
    /// value. Returns the slots assigned.
    ///
    /// The whole `faq` is one build-time field evaluation, as a field `ic`'s
    /// coordinate expression is ([`BuildEval::of_compiler`]): the interpreter
    /// walks it cell by cell, and the other compilers lower it on a standalone
    /// tape, refusing it when the tape declines (`records` then carries the
    /// refusal).
    #[cfg(feature = "solve")]
    pub(crate) fn seed_initialization_equations(
        &self,
        ic_vec: &mut [f64],
        params: &HashMap<String, f64>,
        keep: &HashSet<usize>,
        plan: Option<&crate::initialization::InitPlan>,
        mut records: Option<&mut Vec<FieldIcRecord>>,
    ) -> Result<Vec<usize>, SimulateError> {
        let mut assigned = Vec::new();
        if self.init_faqs.is_empty() {
            return Ok(assigned);
        }
        let mode = BuildEval::of_compiler(self.is_interpreter());
        let none: HashSet<usize> = HashSet::new();
        let all_keep = keep;
        for k in self.init_seed_order(plan) {
            let (target, rhs) = &self.init_faqs[k];
            // A supplied value stands over an explicit initial condition; a
            // step's target is never supplied (a supplied target makes the
            // equation one of the implicit part, or a surplus one).
            let keep = if k < self.n_explicit_faqs {
                all_keep
            } else {
                &none
            };
            let rule = format!("init({target})");
            let invalid = |details: String| SimulateError::InvalidFieldInitialCondition {
                name: rule.clone(),
                details,
            };
            let vs = self.var_shapes.get(target).ok_or_else(|| {
                invalid(format!(
                    "the target `{target}` of an initialization equation is not a state \
                     variable"
                ))
            })?;
            // The state as seeded so far, where a state array would bind (a
            // scalar state binds as a scalar), and the forcing fields a state
            // does not shadow.
            let mut scope: HashMap<String, ArrayD<f64>> = HashMap::new();
            let mut step_params: HashMap<String, f64> = params.clone();
            for (name, s) in &self.var_shapes {
                let n = s.shape.iter().copied().product::<usize>().max(1);
                let flat = &ic_vec[s.flat_offset..s.flat_offset + n];
                if s.shape.is_empty() {
                    step_params.insert(name.clone(), flat[0]);
                } else {
                    scope.insert(name.clone(), col_major_to_arrayd(flat, &s.shape));
                }
            }
            for (name, arr) in self.forcing.borrow().iter() {
                scope.entry(name.clone()).or_insert_with(|| arr.clone());
            }
            // A state-free observed of the build-time scope (a shaped
            // parameter's `const` data included), or a shaped parameter the
            // forcing buffer does not hold yet, reads as a field initial
            // condition reads it.
            for name in super::compile::free_names(rhs) {
                self.bind_ic_scope_name(&name, &mut scope, &mut step_params, mode, 0);
            }
            let params = &step_params;
            if !super::compile::is_cell_assigning_faq(rhs) {
                // A scalar target: one value, its right-hand side's.
                if vs.shape.iter().product::<usize>() != 1 {
                    return Err(invalid(format!(
                        "the right-hand side is not elementwise over the axes of `{target}`, \
                         so it gives no value per cell"
                    )));
                }
                let slot = vs.flat_offset;
                if keep.contains(&slot) {
                    continue;
                }
                let value = eval_buildtime_field_routed(
                    None,
                    rhs,
                    &self.index_sets,
                    params,
                    &scope,
                    mode,
                    &self.operators,
                );
                let v = match value {
                    Ok(Routed::Refused(why)) => {
                        return refuse_field_ic(
                            records.as_deref_mut(),
                            &rule,
                            "initialization equation",
                            why,
                        )
                        .map(|()| assigned);
                    }
                    Ok(Routed::Value(v, route)) => {
                        if let Some(sink) = records.as_deref_mut() {
                            sink.push(FieldIcRecord {
                                name: rule.clone(),
                                kind: "initialization equation",
                                route: Ok(route),
                            });
                        }
                        match v {
                            Value::Scalar(x) => x,
                            Value::Array(a) if a.len() == 1 => {
                                a.iter().copied().next().unwrap_or(0.0)
                            }
                            Value::Array(_) => {
                                return Err(invalid(format!(
                                    "the right-hand side is an array, and `{target}` is a scalar"
                                )));
                            }
                        }
                    }
                    Err(e) => return Err(invalid(e.to_string())),
                };
                if let Some(fault) = take_fault() {
                    return Err(invalid(fault.message));
                }
                ic_vec[slot] = v;
                assigned.push(slot);
                continue;
            }
            let mut resolved = rhs.clone();
            crate::faq::resolve_expr_ranges(&mut resolved, &self.index_sets)
                .map_err(|e| invalid(e.to_string()))?;
            let Expr::Operator(node) = &resolved else {
                unreachable!("an initialization faq is an operator");
            };
            let names = node.output_idx.clone().unwrap_or_default();
            let mut ranges: Vec<(i64, i64)> = Vec::with_capacity(names.len());
            for n in &names {
                let b = node
                    .ranges
                    .as_ref()
                    .and_then(|r| r.get(n))
                    .and_then(|s| s.bounds());
                let Some([lo, hi]) = b else {
                    return Err(invalid(format!("output index `{n}` has no static range")));
                };
                ranges.push((lo, hi));
            }
            if ranges.len() != vs.shape.len() {
                return Err(invalid(format!(
                    "{} output indices for a {}-D state",
                    ranges.len(),
                    vs.shape.len()
                )));
            }
            // Unnamed: the scope binds `target` itself, as seeded so far, and
            // a read of it is not a self-reference.
            let value = eval_buildtime_field_routed(
                None,
                &resolved,
                &self.index_sets,
                params,
                &scope,
                mode,
                &self.operators,
            );
            let value = match value {
                Ok(Routed::Refused(why)) => {
                    return refuse_field_ic(
                        records.as_deref_mut(),
                        &rule,
                        "initialization equation",
                        why,
                    )
                    .map(|()| assigned);
                }
                Ok(Routed::Value(v, route)) => {
                    if let Some(sink) = records.as_deref_mut() {
                        sink.push(FieldIcRecord {
                            name: rule.clone(),
                            kind: "initialization equation",
                            route: Ok(route),
                        });
                    }
                    Ok(v)
                }
                Err(e) => Err(e),
            };
            let arr = match value {
                Ok(Value::Array(a)) if a.ndim() == ranges.len() => a,
                Ok(_) => return Err(invalid("the `faq` did not evaluate to its box".to_string())),
                Err(e) => return Err(invalid(e.to_string())),
            };
            if let Some(fault) = take_fault() {
                return Err(invalid(fault.message));
            }
            // Every cell of the ranges, the box `eval_faq` fills from `lo`.
            let total: usize = ranges
                .iter()
                .map(|(lo, hi)| (hi - lo + 1).max(0) as usize)
                .product();
            let mut cell: Vec<i64> = ranges.iter().map(|(lo, _)| *lo).collect();
            for _ in 0..total {
                if cell
                    .iter()
                    .zip(&vs.origin)
                    .zip(&vs.shape)
                    .any(|((&c, &o), &n)| c < o || c >= o + n as i64)
                {
                    return Err(invalid(format!("cell {cell:?} is outside `{target}`")));
                }
                let slot = vs.flat_offset + multi_to_flat_col_major(&cell, &vs.shape, &vs.origin);
                if !keep.contains(&slot) {
                    let at: Vec<usize> = cell
                        .iter()
                        .zip(&ranges)
                        .map(|(c, (lo, _))| (c - lo) as usize)
                        .collect();
                    ic_vec[slot] = arr[IxDyn(&at)];
                    assigned.push(slot);
                }
                let mut d = cell.len();
                while d > 0 {
                    d -= 1;
                    cell[d] += 1;
                    if cell[d] <= ranges[d].1 {
                        break;
                    }
                    cell[d] = ranges[d].0;
                }
            }
        }
        Ok(assigned)
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
    /// Under a strict compiler an evaluation the tape declines is recorded as
    /// a refusal ([`FieldIcRecord::route`]) and ends the resolution. A
    /// resolution nothing refused is kept for the first solve
    /// ([`FieldIcMemo`]).
    ///
    /// `t0` is the start of the run, where the `ic` right-hand sides are
    /// evaluated (esm-spec §11.4.2). The DISCRETE-cadence fields
    /// (`discrete_forcing`) are not sampled yet: each is read here at its
    /// declared default, which exercises the route an evaluation takes but
    /// not its value, so a resolution that read one is not kept.
    #[cfg(feature = "solve")]
    pub(crate) fn field_ic_records(
        &self,
        params: &HashMap<String, f64>,
        t0: f64,
        discrete_forcing: &HashSet<String>,
    ) -> Vec<FieldIcRecord> {
        if self.field_ics.is_empty() && self.init_faqs.is_empty() {
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
        // No discrete-cadence field is in the buffer before the first refresh:
        // each stands in at its declared default.
        let discrete_read: Vec<String> = self
            .ic_forcing_reads()
            .into_iter()
            .filter(|n| discrete_forcing.contains(n))
            .collect();
        let reads_discrete = !discrete_read.is_empty();
        let stand_ins: HashMap<String, ArrayD<f64>> = discrete_read
            .into_iter()
            .filter_map(|n| {
                let value = self.forcing_default(&n)??;
                Some((n, value))
            })
            .collect();
        let start = IcStart {
            t0,
            at_t0: Some(&stand_ins),
            exclude: discrete_forcing,
        };
        let result = self.resolve_field_ics(&resolved, Some(&mut records), &start);
        let stopped = records.iter().any(|r| r.route.is_err());
        if let Ok(slots) = &result
            && !stopped
            && !self.init_faqs.is_empty()
        {
            // The initialization equations over the defaults and these fields:
            // the caller's `u0` is not known yet, and only the route each one
            // takes is recorded here. `build_initial_state` evaluates them.
            let (mut ic_vec, _) = self.seeded_defaults(slots);
            let _ = self.seed_initialization_equations(
                &mut ic_vec,
                &resolved,
                &HashSet::new(),
                None,
                Some(&mut records),
            );
        }
        if let Ok(slots) = result
            && !stopped
            && !reads_discrete
        {
            *self.field_ic_memo.borrow_mut() = Some(FieldIcMemo {
                params: param_bits(&param_vec),
                forcing: self.ic_forcing_fingerprint(),
                t0: t0.to_bits(),
                slots,
            });
        }
        records
    }

    /// Every name an evaluation of the `ic` right-hand sides may read from
    /// the forcing: what each right-hand side names, and what each
    /// definition of their state-free scope reads.
    fn ic_read_names(&self) -> HashSet<String> {
        let mut names: HashSet<String> = self
            .field_ics
            .iter()
            .flat_map(|(_, rhs)| super::compile::free_names(rhs))
            .collect();
        for def in &self.ic_scope.defs {
            names.extend(def.needs.iter().cloned());
        }
        names
    }

    /// The forcing fields an evaluation of the `ic` right-hand sides may
    /// read: the provider-fed fields whose value at the start of the run
    /// it needs (esm-spec §11.4.2).
    #[cfg(feature = "solve")]
    pub(crate) fn ic_forcing_reads(&self) -> HashSet<String> {
        let mut names = self.ic_read_names();
        names.retain(|n| self.serves_forcing(n));
        names
    }

    /// A fingerprint of the forcing fields an evaluation of the `ic`
    /// right-hand sides reads ([`Self::ic_read_names`]) as the buffer holds
    /// them: each name, in byte order, with its entry's shape and value bits,
    /// or its absence. What [`FieldIcMemo`] compares to tell whether the
    /// buffer moved under a resolution.
    #[cfg(feature = "solve")]
    fn ic_forcing_fingerprint(&self) -> u64 {
        use std::hash::{Hash, Hasher};
        let mut names: Vec<String> = self.ic_read_names().into_iter().collect();
        names.sort();
        let buffer = self.forcing.borrow();
        let mut h = std::collections::hash_map::DefaultHasher::new();
        for name in &names {
            name.hash(&mut h);
            match buffer.get(name) {
                Some(a) => {
                    a.shape().hash(&mut h);
                    for v in a.iter() {
                        v.to_bits().hash(&mut h);
                    }
                }
                None => u8::MAX.hash(&mut h),
            }
        }
        h.finish()
    }

    /// Refuse an `ic` right-hand side that reads a state, directly or through
    /// observeds (esm-spec §11.4.2, `ic_reads_state`): it has no value at the
    /// start of the run.
    pub(crate) fn refuse_ic_state_reads(&self) -> Result<(), SimulateError> {
        // The initialization system's own (esm-spec §11.4.2): an equation that
        // mentions `ic` and reads a trajectory value.
        if let Some(e) = self.init_system.reads_state() {
            return Err(e);
        }
        match self.ic_scope.state_reads.first() {
            Some((name, details)) => Err(SimulateError::IcReadsState {
                name: name.clone(),
                details: details.clone(),
            }),
            None => Ok(()),
        }
    }

    /// Refuse an overlap join gate whose envelope factor is not build-time
    /// data (CONFORMANCE_SPEC §5.5.6): a factor that is, or reads through
    /// observeds, a state, the time, or an input refreshed from outside the
    /// model (a data-fed or handler-updated parameter). The candidate pairs
    /// are built once, so such a gate has no fixed candidate set.
    ///
    /// Run before either compiler sees the rules, so `interpreter` and
    /// `native` refuse the same document with the same diagnostic, Julia's
    /// `E_TREEWALK_JOIN_OVERLAP`. Without it `native` refused at its own
    /// gate (the factor is not foldable) while `interpreter` declined the
    /// gate and walked the full product.
    pub(crate) fn refuse_live_overlap_factors(&self) -> Result<(), SimulateError> {
        fn rhs_body(r: &RhsRule) -> &Expr {
            match r {
                RhsRule::Scalar { body, .. }
                | RhsRule::IndexedScalar { body, .. }
                | RhsRule::ArrayLoop { body, .. } => body,
            }
        }
        fn overlap_factors<'e>(e: &'e Expr, out: &mut Vec<&'e String>) {
            if let Expr::Operator(n) = e {
                for ov in n.join.iter().flatten().filter_map(|c| c.overlap.as_ref()) {
                    out.extend(ov.src_env.iter().chain(&ov.tgt_env));
                }
                n.for_each_child(&mut |c| overlap_factors(c, out));
            }
        }
        let mut factors: Vec<&String> = Vec::new();
        for body in self
            .observed_rules
            .iter()
            .map(observed_rule_body)
            .chain(self.rhs_rules.iter().map(rhs_body))
        {
            overlap_factors(body, &mut factors);
        }
        if factors.is_empty() {
            return Ok(());
        }
        let outside: HashSet<&str> = self
            .forcing_decls
            .keys()
            .map(String::as_str)
            .chain(self.data_fed.iter().map(|(n, _)| n.as_str()))
            .collect();
        // Why a name is not build-time data, or `None`. `observed_rules` are
        // dependency-ordered, so an observed's reads are classified before it.
        let leaf = |name: &str| -> Option<String> {
            if name == "t" {
                Some("the time `t`".to_string())
            } else if self.var_shapes.contains_key(name) {
                Some(format!("the state `{name}`"))
            } else if outside.contains(name) {
                Some(format!(
                    "`{name}`, an input refreshed from outside the model"
                ))
            } else {
                None
            }
        };
        let mut live: HashMap<&str, String> = HashMap::new();
        for rule in &self.observed_rules {
            let var = observed_rule_var(rule);
            let mut refs = HashSet::new();
            collect_expr_var_refs(observed_rule_body(rule), &mut refs);
            refs.remove(var.as_str());
            let mut refs: Vec<String> = refs.into_iter().collect();
            refs.sort();
            let why = refs.iter().find_map(|r| {
                leaf(r).or_else(|| live.get(r.as_str()).map(|w| format!("{w} through `{r}`")))
            });
            if let Some(why) = why {
                live.insert(var.as_str(), why);
            }
        }
        for name in factors {
            let why = leaf(name).or_else(|| live.get(name.as_str()).cloned());
            if let Some(why) = why {
                return Err(SimulateError::Compile(
                    crate::compile_error::CompileError::coded_build_err(
                        crate::join::JOIN_OVERLAP,
                        format!(
                            "E_TREEWALK_JOIN_OVERLAP: overlap join env factor `{name}` is not \
                     build-time data: it reads {why}. An envelope factor must be a const \
                     array, a const observed or setup geometry, not a live forcing / \
                     data-loader array or a state, because the gate's candidate pairs are \
                     built once (CONFORMANCE_SPEC §5.5.6)"
                        ),
                    ),
                ));
            }
        }
        Ok(())
    }

    /// The component / subsystem names a rule-2 override key may spell in its
    /// LEADING segments (esm-spec §6.6.2, §4.6): every namespace segment the
    /// build's qualified names carry (`M` and `sub` in `M.sub.g`).
    fn override_namespaces(&self) -> std::collections::HashSet<String> {
        crate::simulate::namespace_scope(
            // A slot name's cell suffix carries no `.`, so the state
            // VARIABLES' names carry every namespace their slots' names do.
            self.param_names
                .iter()
                .chain(self.var_shapes.keys())
                .map(String::as_str),
            [],
        )
    }

    /// The scalar-table parameters neither `params` (the caller's `p`,
    /// canonicalized as [`Self::build_param_vec`] does) nor a declared default
    /// gives a value. Empty when a key does not canonicalize: that is the
    /// solve's diagnostic, not this one.
    pub(crate) fn unsupplied_params(&self, params: &HashMap<String, f64>) -> Vec<String> {
        let Ok(params) = crate::simulate::canonicalize_override_keys(
            &self.param_index,
            &self.override_namespaces(),
            params,
            &self.merged_renames,
        ) else {
            return Vec::new();
        };
        self.param_names
            .iter()
            .zip(&self.param_defaults)
            .filter(|(name, d)| d.is_none() && !params.contains_key(*name))
            .map(|(name, _)| name.clone())
            .collect()
    }

    /// The states none of whose slots anything gives a starting value — no
    /// default, no field `ic`, no initialization equation, no entry of
    /// `initial_conditions` (the caller's `u0`) — by name. Read at construction, from the field `ic`s
    /// construction resolved ([`FieldIcMemo`], left in place for the first
    /// solve); empty when those could not be resolved there, or a key does not
    /// canonicalize, which leaves the diagnostic to the solve.
    #[cfg(feature = "solve")]
    pub(crate) fn unset_initial_slots(
        &self,
        initial_conditions: &HashMap<String, f64>,
    ) -> Vec<String> {
        let Ok(initial_conditions) = crate::simulate::canonicalize_override_keys(
            &super::layout::SlotNames(&self.var_shapes),
            &self.override_namespaces(),
            initial_conditions,
            &self.merged_renames,
        ) else {
            return Vec::new();
        };
        let memo_slots;
        let empty = HashMap::new();
        let field_ic_map = if self.field_ics.is_empty() {
            &empty
        } else {
            match self.field_ic_memo.borrow().as_ref() {
                Some(m) => {
                    memo_slots = m.slots.clone();
                    &memo_slots
                }
                None => return Vec::new(),
            }
        };
        let (_, unset) = self.seeded_defaults(field_ic_map);
        let Some(mut unset) = unset else {
            return Vec::new();
        };
        for name in initial_conditions.keys() {
            if let Some(slot) = super::layout::lookup_slot(&self.var_shapes, name) {
                unset[slot] = false;
            }
        }
        // An initialization equation assigns its whole target, and a held
        // state (no `D`, no definition) is not an ODE state. A stripped
        // implicit part's unknown with a guess starts from it.
        let plan = self
            .check_initialization(&initial_conditions)
            .unwrap_or_default();
        let guessed: Vec<String> = self
            .guess_seeded_unknowns(&plan)
            .into_iter()
            .map(|(w, _)| w)
            .collect();
        for target in self
            .init_faqs
            .iter()
            .map(|(t, _)| t)
            .chain(&self.held_at_ic)
            .chain(&guessed)
        {
            if let Some(vs) = self.var_shapes.get(target) {
                let n = vs.shape.iter().copied().product::<usize>().max(1);
                unset[vs.flat_offset..vs.flat_offset + n].fill(false);
            }
        }
        // A state is refused only when NONE of its slots got a value: cells left
        // over in a partly seeded one are layout (a grid widened past the cells
        // the document names) and keep their placeholder.
        self.var_shapes
            .iter()
            .filter(|(_, vs)| {
                let n = vs.shape.iter().copied().product::<usize>().max(1);
                unset[vs.flat_offset..vs.flat_offset + n].iter().all(|&u| u)
            })
            .map(|(name, _)| name.clone())
            .collect()
    }

    /// Run the simulation.
    /// Validate override parameter names and build the positional param
    /// vector (override > variable default; a parameter with neither is an
    /// [`SimulateError::InvalidParameter`]). The strict simulate-time
    /// counterpart of the lenient [`Self::debug_resolve_params`].
    pub(super) fn build_param_vec(
        &self,
        params: &HashMap<String, f64>,
    ) -> Result<Vec<f64>, SimulateError> {
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
            param_vec[i] = self.precision.variable(name).round(param_vec[i]);
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
    pub(super) fn build_initial_state(
        &self,
        initial_conditions: &HashMap<String, f64>,
        param_vec: &[f64],
        start: &IcStart<'_>,
    ) -> Result<Vec<f64>, SimulateError> {
        self.build_initial_state_with(initial_conditions, param_vec, start, true)
    }

    /// The initial state vector `u0` a solve under `params` and
    /// `initial_conditions` starts from, in flat state-vector order (the
    /// order of [`Self::qualified_state_names`]): the same
    /// [`Self::build_initial_state`] the solve runs, without integrating.
    ///
    /// It reads the memo of construction's field initial conditions without
    /// taking it ([`FieldIcMemo`]), so the first solve after it still answers
    /// from the memo. Like the solve, it reports an out-of-range constant-array
    /// gather an initial condition made rather than returning the `NaN` the
    /// gather substituted.
    #[cfg(feature = "solve")]
    pub(crate) fn initial_state(
        &self,
        params: &HashMap<String, f64>,
        initial_conditions: &HashMap<String, f64>,
        start: &IcStart<'_>,
    ) -> Result<Vec<f64>, SimulateError> {
        let faults = FaultScope::enter();
        let u0 = self.build_param_vec(params).and_then(|param_vec| {
            self.build_initial_state_with(initial_conditions, &param_vec, start, false)
        });
        // An error building the state is the answer over a gather it latched.
        match (u0, faults.finish()) {
            (Ok(_), Some(fault)) => Err(fault_error(fault)),
            (u0, _) => u0,
        }
    }

    /// [`Self::build_initial_state`], taking construction's memo
    /// (`consume_memo`, what a solve does) or reading it in place.
    #[cfg(feature = "solve")]
    fn build_initial_state_with(
        &self,
        initial_conditions: &HashMap<String, f64>,
        param_vec: &[f64],
        start: &IcStart<'_>,
        consume_memo: bool,
    ) -> Result<Vec<f64>, SimulateError> {
        // Same §6.6.2 canonicalization as `build_param_vec`, on the state side.
        let initial_conditions = crate::simulate::canonicalize_override_keys(
            &super::layout::SlotNames(&self.var_shapes),
            &self.override_namespaces(),
            initial_conditions,
            &self.merged_renames,
        )
        .map_err(crate::simulate::ic_key_error)?;
        // The initialization system under these supplied values (esm-spec
        // §11.4.3): its balance, checked before anything is evaluated, and
        // the order of its steps.
        let plan = self.check_initialization(&initial_conditions)?;
        // What construction resolved, when it resolved it under these
        // parameters ([`FieldIcMemo`]).
        let bits = param_bits(param_vec);
        let fresh = |m: &FieldIcMemo| {
            m.params == bits
                && m.t0 == start.t0.to_bits()
                && m.forcing == self.ic_forcing_fingerprint()
        };
        let taken = consume_memo
            .then(|| self.field_ic_memo.borrow_mut().take())
            .flatten()
            .filter(|m| fresh(m));
        let kept = (!consume_memo).then(|| self.field_ic_memo.borrow());
        let kept = kept
            .as_deref()
            .and_then(Option::as_ref)
            .filter(|m| fresh(m));
        // Resolved scalar-parameter scope (load-time constants) for the ic
        // coordinate-expression path — a parameter-dependent grid-geometry
        // template (`x0 + (i − 1/2)·dx`) binds here — and for the
        // initialization equations.
        let resolved_params: HashMap<String, f64> = self
            .param_names
            .iter()
            .cloned()
            .zip(param_vec.iter().copied())
            .collect();
        let field_ic_map: std::borrow::Cow<'_, HashMap<usize, f64>> = match (taken, kept) {
            (Some(m), _) => std::borrow::Cow::Owned(m.slots),
            (None, Some(m)) => std::borrow::Cow::Borrowed(&m.slots),
            (None, None) => {
                std::borrow::Cow::Owned(self.resolve_field_ics(&resolved_params, None, start)?)
            }
        };
        // Per slot, the first of: an explicit override, an initialization
        // equation, a field `ic`, the variable's default. Written lowest
        // priority first; a slot left with none of them is flagged, and only a
        // variable that declares no default can leave one.
        let (mut ic_vec, mut unset) = self.seeded_defaults(&field_ic_map);
        let mut overridden: HashSet<usize> = HashSet::new();
        for (name, &v) in &initial_conditions {
            // Canonicalization answers only with names the layout resolves.
            let slot = super::layout::lookup_slot(&self.var_shapes, name)
                .expect("a canonical initial-condition key names a slot");
            ic_vec[slot] = v;
            overridden.insert(slot);
            if let Some(u) = unset.as_mut() {
                u[slot] = false;
            }
        }
        self.round_initial_state(&mut ic_vec);
        // The steps read `t` as the start of the run (esm-spec §11.4.2).
        let mut step_params = resolved_params.clone();
        step_params.insert("t".to_string(), start.t0);
        // After the overrides, so a body reading a state reads the caller's
        // value, and around them, so the caller's value stands.
        for slot in self.seed_initialization_equations(
            &mut ic_vec,
            &step_params,
            &overridden,
            Some(&plan),
            None,
        )? {
            if let Some(u) = unset.as_mut() {
                u[slot] = false;
            }
        }
        // A stripped algebraic unknown's warm start (`strip` class
        // `algebraic`, API_SPEC §5.8 as PR #820 drafted it): its explicit `ic`
        // value over a supplied one.
        if self.alg_stripped {
            for w in &self.held_at_ic {
                let Some(vs) = self.var_shapes.get(w) else {
                    continue;
                };
                let n = vs.shape.iter().copied().product::<usize>().max(1);
                for slot in vs.flat_offset..vs.flat_offset + n {
                    if let Some(&v) = field_ic_map.get(&slot) {
                        ic_vec[slot] = v;
                    }
                }
            }
        }
        let mut keep_guess = overridden.clone();
        keep_guess.extend(field_ic_map.keys().copied());
        for slot in
            self.seed_stripped_starting_points(&mut ic_vec, &resolved_params, &keep_guess, &plan)
        {
            if let Some(u) = unset.as_mut() {
                u[slot] = false;
            }
        }
        if let Some(slot) = unset.and_then(|u| u.iter().position(|&x| x)) {
            let name = super::layout::slot_name(&self.var_shapes, slot).unwrap_or_default();
            return Err(SimulateError::InvalidInitialCondition { name });
        }
        self.round_initial_state(&mut ic_vec);
        Ok(ic_vec)
    }

    /// Bind `name` into a step's build-time scope when nothing binds it yet:
    /// a state-free observed of [`Self::ic_scope`] (its own reads first), else
    /// a forcing slot's declared value.
    #[cfg(feature = "solve")]
    fn bind_ic_scope_name(
        &self,
        name: &str,
        scope: &mut HashMap<String, ArrayD<f64>>,
        params: &mut HashMap<String, f64>,
        mode: BuildEval,
        depth: usize,
    ) {
        if depth > 64 || scope.contains_key(name) || params.contains_key(name) {
            return;
        }
        if let Some(def) = self.ic_scope.defs.iter().find(|d| d.name == name) {
            for dep in &def.deps {
                self.bind_ic_scope_name(dep, scope, params, mode, depth + 1);
            }
            for need in &def.needs {
                self.bind_ic_scope_name(need, scope, params, mode, depth + 1);
            }
            if let Ok(Routed::Value(v, _)) = eval_buildtime_field_routed(
                Some(&def.name),
                &def.body,
                &self.index_sets,
                params,
                scope,
                mode,
                &self.operators,
            ) {
                match v {
                    Value::Array(a) => {
                        scope.insert(name.to_string(), *a);
                    }
                    Value::Scalar(x) => {
                        params.insert(name.to_string(), x);
                    }
                }
            }
            return;
        }
        if let Some(Some(v)) = self.forcing_default(name) {
            scope.insert(name.to_string(), v);
        }
    }

    /// The supplied values of `initial_conditions` (canonical keys), per
    /// state, as the column-major elements they set.
    fn supplied_elements(
        &self,
        initial_conditions: &HashMap<String, f64>,
    ) -> HashMap<String, Vec<usize>> {
        let mut out: HashMap<String, Vec<usize>> = HashMap::new();
        for name in initial_conditions.keys() {
            if let Some(vs) = self.var_shapes.get(name) {
                // A whole-variable key sets every element.
                let n = vs.shape.iter().copied().product::<usize>().max(1);
                out.entry(name.clone()).or_default().extend(0..n);
                continue;
            }
            let Some(slot) = super::layout::lookup_slot(&self.var_shapes, name) else {
                continue;
            };
            for (var, vs) in &self.var_shapes {
                let n = vs.shape.iter().copied().product::<usize>().max(1);
                if (vs.flat_offset..vs.flat_offset + n).contains(&slot) {
                    out.entry(var.clone())
                        .or_default()
                        .push(slot - vs.flat_offset);
                }
            }
        }
        out
    }

    /// The initialization system under the supplied values
    /// `initial_conditions` (caller keys, as given or canonical), with every
    /// check of esm-spec §11.4.3 that depends on them: the structural
    /// refusals, the balance, then the refusal of an implicit part the
    /// caller did not take (`strip` class `initialization`).
    pub(crate) fn check_initialization(
        &self,
        initial_conditions: &HashMap<String, f64>,
    ) -> Result<crate::initialization::InitPlan, SimulateError> {
        if self.init_system.is_empty() {
            return Ok(Default::default());
        }
        let canonical = crate::simulate::canonicalize_override_keys(
            &super::layout::SlotNames(&self.var_shapes),
            &self.override_namespaces(),
            initial_conditions,
            &self.merged_renames,
        )
        .map_err(crate::simulate::ic_key_error)?;
        let supplied = self.supplied_elements(&canonical);
        self.init_system
            .check(&supplied, self.alg_stripped, self.init_stripped)
    }

    /// The positions in [`Self::init_faqs`] a build evaluates, in order: the
    /// explicit initial conditions over some cells, then the steps `plan`
    /// orders (every step, in equation order, without one: construction
    /// records the routes before the supplied values are known).
    #[cfg(feature = "solve")]
    fn init_seed_order(&self, plan: Option<&crate::initialization::InitPlan>) -> Vec<usize> {
        let explicit = 0..self.n_explicit_faqs;
        let Some(plan) = plan else {
            return (0..self.init_faqs.len()).collect();
        };
        let step_of: HashMap<usize, usize> = self
            .init_system
            .solved_equations()
            .into_iter()
            .enumerate()
            .map(|(j, k)| (k, self.n_explicit_faqs + j))
            .collect();
        explicit
            .chain(plan.order.iter().filter_map(|k| step_of.get(k).copied()))
            .filter(|&p| p < self.init_faqs.len())
            .collect()
    }

    /// The starting point of every cell of a stripped implicit part (`strip`
    /// class `initialization`, API_SPEC §5.8) and of every stripped algebraic
    /// unknown (`strip` class `algebraic`), written into `ic_vec`: a supplied
    /// value stands (`keep`), else the `guesses` entry, else the declared
    /// default already seeded (else the `0` the state starts from). Returns
    /// the slots it starts.
    #[cfg(feature = "solve")]
    fn seed_stripped_starting_points(
        &self,
        ic_vec: &mut [f64],
        params: &HashMap<String, f64>,
        keep: &HashSet<usize>,
        plan: &crate::initialization::InitPlan,
    ) -> Vec<usize> {
        let mut out = Vec::new();
        for (w, cells) in self.guess_seeded_unknowns(plan) {
            let Some(vs) = self.var_shapes.get(&w) else {
                continue;
            };
            let n = vs.shape.iter().copied().product::<usize>().max(1);
            let guess = self.init_guesses.get(&w).and_then(|g| {
                crate::simulate_array::eval_buildtime_values(g, &self.index_sets, params).ok()
            });
            for i in cells.unwrap_or_else(|| (0..n).collect()) {
                let slot = vs.flat_offset + i;
                if keep.contains(&slot) {
                    continue;
                }
                match guess.as_deref() {
                    Some([v]) => ic_vec[slot] = *v,
                    Some(values) if values.len() == n => ic_vec[slot] = values[i],
                    _ => {}
                }
                out.push(slot);
            }
        }
        out
    }

    /// The unknowns whose `guesses` entry is a starting point of this
    /// Problem's state, each with its cells (`None`: all of them): the cells
    /// of the implicit part of the initialization system `plan` leaves (when
    /// the caller took it, `strip` class `initialization`), and the stripped
    /// algebraic unknowns (`strip` class `algebraic`, whose warm start the
    /// caller takes), below an explicit `ic` and a supplied value.
    fn guess_seeded_unknowns(
        &self,
        plan: &crate::initialization::InitPlan,
    ) -> Vec<(String, Option<Vec<usize>>)> {
        let mut out: Vec<(String, Option<Vec<usize>>)> = Vec::new();
        if self.init_stripped {
            out.extend(
                plan.unknowns
                    .iter()
                    .map(|(w, cells)| (w.clone(), Some(cells.clone()))),
            );
        }
        if self.alg_stripped {
            let mut held: Vec<&String> = self.held_at_ic.iter().collect();
            held.sort();
            out.extend(held.into_iter().map(|w| (w.clone(), None)));
        }
        out
    }

    /// The flat state slots of the unknowns of `plan`'s implicit part, in the
    /// order the stripped object lists them (API_SPEC §5.8): the scalar
    /// unknowns by sorted name, then the arrays by sorted name, each in
    /// layout order.
    pub(crate) fn initialization_unknown_slots(
        &self,
        plan: &crate::initialization::InitPlan,
    ) -> Vec<usize> {
        let mut vars: Vec<(bool, &String, &Vec<usize>)> = plan
            .unknowns
            .iter()
            .filter_map(|(w, cells)| {
                let vs = self.var_shapes.get(w)?;
                Some((!vs.shape.is_empty(), w, cells))
            })
            .collect();
        vars.sort();
        vars.into_iter()
            .flat_map(|(_, w, cells)| {
                let off = self.var_shapes[w].flat_offset;
                cells.iter().map(move |i| off + i)
            })
            .collect()
    }

    #[cfg(feature = "solve")]
    fn round_initial_state(&self, state: &mut [f64]) {
        for (name, block) in &self.var_shapes {
            let precision = self.precision.variable(name);
            if precision.is_f32() {
                let end = block.flat_offset + block.shape.iter().product::<usize>();
                for value in &mut state[block.flat_offset..end] {
                    *value = precision.round(*value);
                }
            }
        }
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
        mut inspect: Option<&mut BuildInspection>,
    ) -> Result<Solution, SimulateError> {
        // Re-arm the precision this model was compiled under
        // (`crate::precision`); a no-op for a Float64 model.
        let _precision_guard = self.precision.enter();
        // No discrete forcing, so no refresh boundaries.
        let none = HashSet::new();
        let sol = self
            .solve_run(
                &super::RunSpec {
                    tspan,
                    params,
                    initial_conditions,
                    discrete_forcing: &none,
                    boundaries: &[],
                    reltol_source: if opts.reltol.is_some() {
                        "call site"
                    } else {
                        "binding default"
                    },
                },
                opts,
                inspect.as_deref_mut(),
                &mut |_t| Ok(()),
            )
            .map_err(|e| self.show_error(e))?;
        if let Some(insp) = inspect {
            self.show_inspection(insp);
        }
        Ok(self.show_solution(sol))
    }

    /// `insp`, filled by a run of this model, keyed as this artifact shows
    /// names ([`Self::shown`]).
    #[cfg(feature = "solve")]
    fn show_inspection(&self, insp: &mut BuildInspection) {
        if self.namespace.is_none() {
            return;
        }
        fn rekey<V>(m: &mut HashMap<String, V>, shown: impl Fn(&str) -> String) {
            *m = std::mem::take(m)
                .into_iter()
                .map(|(k, v)| (shown(&k), v))
                .collect();
        }
        rekey(&mut insp.setup_arrays, |k| self.shown(k).to_string());
        rekey(&mut insp.observed_exprs, |k| self.shown(k).to_string());
        rekey(&mut insp.params, |k| self.shown(k).to_string());
    }

    /// `sol`, a run of this model, as this artifact shows it: a one-model
    /// document's rows without its `M.`, and the solution's
    /// [`SolutionMetadata::namespace`] naming `M`, so a qualified read still
    /// finds them.
    #[cfg(feature = "solve")]
    fn show_solution(&self, mut sol: Solution) -> Solution {
        if let Some(ns) = &self.namespace {
            for name in &mut sol.state_variable_names {
                *name = self.shown(name).to_string();
            }
            sol.metadata.namespace = Some(ns.clone());
        }
        sol
    }

    /// `e`, an error this model raised, as this artifact shows it: naming a
    /// one-model document's variables without its `M.`.
    pub(crate) fn show_error(&self, e: SimulateError) -> SimulateError {
        match &self.namespace {
            Some(ns) => e.unqualified(ns),
            None => e,
        }
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
    pub(super) fn partition_observed_cadence(
        &self,
        discrete_forcing: &HashSet<String>,
    ) -> ObservedCadence {
        let deps = self.observed_dependencies(discrete_forcing);
        let static_names = deps.at_most(crate::cadence::Cadence::Const);
        let seg_invariant_names = deps.at_most(crate::cadence::Cadence::Discrete);
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
    /// conservative-regrid weights over the src×tgt cell pairs, the regridded
    /// terrain and its slopes, the Rothermel
    /// coefficients derived from the CONST forcing. Materialize them ONCE here
    /// and seed them into every RHS eval, rather than recomputing the
    /// (expensive) regrid on every step. A model with no such observeds hoists
    /// nothing and stays byte-identical to the un-hoisted path.
    #[cfg(feature = "solve")]
    pub(super) fn hoist_static_observeds(
        &self,
        cadence: ObservedCadence,
        ic_vec: &[f64],
        param_vec: &[f64],
        t0: f64,
        tape: Option<&std::sync::Arc<TapeProgram>>,
    ) -> SolveSetup {
        // Under the strict compilers the tape's own CONST section computes
        // exactly these rules, once per solve, and the inspection snapshot and
        // the output-node pass read them off the tape ([`TapedObserveds`]).
        if tape.is_some() {
            return SolveSetup {
                cadence,
                static_obs: ArrMap::default(),
            };
        }
        let sa0 = build_state_arrays(&self.var_shapes, ic_vec);
        let mut static_obs = ArrMap::default();
        materialize_observeds_pass(
            &mut static_obs,
            &cadence.static_rules,
            &self.eval_env(&sa0, param_vec, t0),
            &mut RhsStats::default(),
        );
        SolveSetup {
            cadence,
            static_obs,
        }
    }

    /// Build observability (see `BuildInspection`): the hoisted static
    /// observeds ARE the build-once products (regrid geometry, regridded
    /// terrain, slopes). Nothing downstream consults the sink, so the
    /// integration is unchanged.
    #[cfg(feature = "solve")]
    #[allow(clippy::too_many_arguments)]
    pub(super) fn fill_solve_inspection(
        &self,
        insp: &mut BuildInspection,
        setup: &SolveSetup,
        ic_vec: &[f64],
        param_vec: &[f64],
        t0: f64,
        segmented: bool,
        tape: Option<&std::sync::Arc<TapeProgram>>,
    ) {
        // One read-out at t0 answers both halves of this sink: the static
        // observeds and, on a run with refresh boundaries, the varying ones —
        // the time-varying forcing-derived fields at their first record, which
        // a caller reading the build-time per-cell forcing expects to see.
        let varying: &[AlgebraicRule] = if segmented {
            &setup.cadence.varying_rules
        } else {
            &[]
        };
        let mut readout = self.observed_readout(tape, &setup.static_obs, varying.to_vec());
        let obs = readout.at(self, ic_vec, param_vec, t0);
        self.fill_inspection(insp, obs, &setup.cadence.static_names, param_vec);
        for rule in varying {
            let name = observed_rule_var(rule);
            if let Some(a) = obs.get(name) {
                insp.setup_arrays.insert(name.clone(), a.clone());
            }
        }
    }

    /// Compile the tape program ONCE per solve and share it across every
    /// integration segment. [`crate::Compiler::Interpreter`] builds no tape at
    /// all — it IS the per-cell oracle.
    ///
    /// The tape is mandatory under the strict compilers: a build that declined
    /// a rule is a refusal ([`Self::strict_tape`], naming the rule and the
    /// reason), never a solve of the whole model on another evaluator.
    #[cfg(feature = "solve")]
    pub(super) fn build_solve_tape(
        &self,
        discrete_forcing: &HashSet<String>,
    ) -> Result<SolveTape, SimulateError> {
        // `interpreter` (API_SPEC §5.8) is the reference and nothing else: no
        // tape, and every rule walked per cell.
        if self.is_interpreter() {
            return Ok(None);
        }
        Ok(Some(self.strict_tape(discrete_forcing)?))
    }

    /// Solution assembly, shared by the single-segment and segmented exits:
    /// expose observed trajectories alongside the states (see
    /// [`Self::append_observed_trajectories`]), then drain the §5.5.5
    /// const-array OOB latch so a trajectory built on a const-array bug fails
    /// loudly instead of carrying the `NaN` the gather substituted.
    #[cfg(feature = "solve")]
    #[allow(clippy::too_many_arguments)]
    pub(super) fn assemble_solution(
        &self,
        faults: &FaultScope,
        time: Vec<f64>,
        mut state: Vec<Vec<f64>>,
        retcode: ReturnCode,
        metadata: SolutionMetadata,
        param_vec: &[f64],
        setup: &SolveSetup,
        output_observed: &[String],
        tape: Option<&std::sync::Arc<TapeProgram>>,
    ) -> Result<Solution, SimulateError> {
        let mut state_variable_names = self.qualified_state_names().to_vec();
        self.append_observed_trajectories(
            &time,
            &mut state,
            &mut state_variable_names,
            param_vec,
            setup,
            output_observed,
            tape,
        );
        if let Some(fault) = faults.take() {
            return Err(fault_error(fault));
        }
        Ok(Solution {
            time,
            state,
            state_variable_names,
            retcode,
            metadata,
        })
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
    /// array-valued observed (a regrid weight matrix, a const table, a gridded
    /// emissions field) is `n_cells` rows, not one, so materializing every one
    /// of them unasked would multiply the trajectory's memory by the grid size;
    /// a requested one is flattened to one row per cell named exactly like a
    /// state cell — `name[i,j,…]`, 1-based and column-major, the spelling
    /// [`build_slot_tables`] gives the state and the one
    /// [`crate::derive_output_plan`] inverts back into a labeled output array.
    /// Names may be bare or `Model.`-qualified.
    ///
    /// The values come from the compiler's own evaluator
    /// ([`ObservedReadout`]): one call per saved time point. Which observeds
    /// become rows is decided by [`Self::output_row_candidates`] and at the
    /// first node, and held fixed so a later node cannot shift the row block.
    #[cfg(feature = "solve")]
    #[allow(clippy::too_many_arguments)]
    fn append_observed_trajectories(
        &self,
        time: &[f64],
        state: &mut Vec<Vec<f64>>,
        state_variable_names: &mut Vec<String>,
        param_vec: &[f64],
        setup: &SolveSetup,
        requested: &[String],
        tape: Option<&std::sync::Arc<TapeProgram>>,
    ) {
        let static_obs = &setup.static_obs;
        let static_names = &setup.cadence.static_names;
        let varying_rules = &setup.cadence.varying_rules[..];
        if self.observed_rules.is_empty() || time.is_empty() {
            return;
        }
        let wanted = self.resolve_requested_observeds(requested);
        let emitted = self.output_row_candidates(static_names, varying_rules, &wanted);
        let nt = time.len();
        // The per-cell read-out evaluates only the cone of the candidates; the
        // tape computes its whole CONTINUOUS section either way.
        let rules = if tape.is_some() {
            Vec::new()
        } else {
            dependency_cone(varying_rules, &emitted).unwrap_or_else(|| varying_rules.to_vec())
        };
        let mut readout = self.observed_readout(tape, static_obs, rules);
        let mut flat = vec![0.0f64; self.n_states];
        for (i, slot) in flat.iter_mut().enumerate() {
            *slot = state[i][0];
        }
        // What becomes rows: every 0-D observed, plus every CALLER-REQUESTED
        // array-valued one at one row per cell.
        let emit: Vec<ObservedRows> = {
            let obs = readout.at(self, &flat, param_vec, time[0]);
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
                        // Column-major, the order the cell keys were named in.
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
        record(readout.last(), &mut rows);
        for k in 1..nt {
            for (i, slot) in flat.iter_mut().enumerate() {
                *slot = state[i][k];
            }
            let obs = readout.at(self, &flat, param_vec, time[k]);
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
    /// plus the output-node probe cone — every potentially-scalar observed,
    /// every requested one, and their transitive dependencies. The tape
    /// publishes every observed, so the row set is decided by this rule rather
    /// than by what a read-out happens to hold.
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

    /// The dependency summary of every observed rule, given the forcing
    /// names the driver refreshes between segments (`discrete_forcing`).
    ///
    /// A rule's [`Cadence`](crate::cadence::Cadence) is its tier:
    ///
    /// * CONST — reaches no state, no `t` and no discrete forcing: constant
    ///   for the whole solve, materialized ONCE at setup (the hoisted
    ///   `static_obs`), and recorded in a [`BuildInspection`]'s
    ///   `setup_arrays`. A CONST loader field read through the forcing buffer
    ///   is constant within a `simulate` call (the free `simulate` never
    ///   refreshes it mid-run), so an observed reaching only parameters, CONST
    ///   forcing and other CONST observeds is constant across the whole solve:
    ///   regridded terrain and its slopes hoist, matching the Julia / Python
    ///   `BuildInspection`.
    /// * DISCRETE — reaches a discrete forcing buffer but no state and no
    ///   `t`. The driver refreshes forcing only between segments, never
    ///   inside a solver step, so it is constant within a segment and
    ///   materialized once per segment rather than every RHS step.
    /// * CONTINUOUS — reaches a state or `t`, or cannot be ordered.
    ///
    /// A RECURRENCE rule's body reads the variable the rule DEFINES (esm-spec
    /// §4.3.1.1). That self-edge is an ordering within the one rule, not a
    /// dependency on another observed, so it is dropped, as
    /// `dependency_order_observed` drops it. Only for that rule kind: a
    /// self-reference the recurrence lowering did not recognize reads a name
    /// nothing binds, and hoisting it as a build-once constant would freeze
    /// that, so it stays an edge and the rule is CONTINUOUS.
    pub(crate) fn observed_dependencies(
        &self,
        discrete_forcing: &HashSet<String>,
    ) -> crate::dependency::DependencySummaries {
        use crate::dependency::{DependencySummaries, Leaf, Reads};
        let defs = self.observed_rules.iter().map(|rule| {
            let var = observed_rule_var(rule);
            let reads = Reads::of(observed_rule_body(rule));
            let reads = if matches!(rule, AlgebraicRule::Recurrence { .. }) {
                reads.without(var)
            } else {
                reads
            };
            (var.clone(), reads)
        });
        DependencySummaries::new(defs, |name| {
            if self.var_shapes.contains_key(name) {
                Leaf::State
            } else if discrete_forcing.contains(name) {
                Leaf::Discrete
            } else {
                Leaf::Const
            }
        })
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
///   * a `distinct` aggregate produces a data-dependent index set, and a
///     `kind:"derived"` contraction bound elsewhere consumes it by its node id
///     — not by name;
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
    if matches!(node.op.as_str(), "distinct") {
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

/// The solve-wide tape program (`None` only under the `interpreter`
/// compiler, which builds no tape).
#[cfg(feature = "solve")]
pub(super) type SolveTape = Option<std::sync::Arc<TapeProgram>>;

/// The run's [`SolutionMetadata`] — one construction for both driver exits.
#[cfg(feature = "solve")]
pub(super) fn solution_metadata(
    solver_name: &str,
    stats: &super::session::SolveStats,
    merged_variable_renames: HashMap<String, String>,
    integrator_precision: Option<crate::IntegratorPrecision>,
) -> SolutionMetadata {
    SolutionMetadata {
        alg: solver_name.to_string(),
        integrator_precision,
        n_rhs_calls: stats.n_rhs_calls,
        n_jacobian_calls: stats.n_jacobian_calls,
        n_accepted_steps: stats.n_accepted_steps,
        n_rejected_steps: stats.n_rejected_steps,
        // Rides to the caller so a name-keyed read of the result can resolve a
        // spelling the merge deleted (issue #230).
        merged_variable_renames,
        // Every row is qualified.
        namespace: None,
    }
}

/// The three-tier cadence partition of one solve's observed rules (see
/// [`ArrayCompiled::partition_observed_cadence`]).
#[cfg(feature = "solve")]
pub(super) struct ObservedCadence {
    /// The CONST tier's names — consulted by the build inspection.
    static_names: HashSet<String>,
    /// CONST: materialized once at setup (the hoisted `static_obs`).
    static_rules: Vec<AlgebraicRule>,
    /// DISCRETE remainder: materialized once per segment.
    pub(super) segment_static_rules: Vec<AlgebraicRule>,
    /// CONTINUOUS: re-evaluated every RHS step.
    pub(super) continuous_rules: Vec<AlgebraicRule>,
    /// DISCRETE ∪ CONTINUOUS — the non-hot observed-trajectory output pass.
    varying_rules: Vec<AlgebraicRule>,
}

/// The run-wide products of the cadence partition and the static hoist,
/// shared by every segment of a [`super::SolveSession`].
#[cfg(feature = "solve")]
pub(super) struct SolveSetup {
    pub(super) cadence: ObservedCadence,
    /// The CONST observeds, materialized ONCE — seeded into every RHS eval.
    pub(super) static_obs: ArrMap,
}

/// The program a `native` solve integrates, with the right-hand side's and
/// the Jacobian's workspaces, kept across all of its integration segments.
///
/// Each segment builds a fresh solver and fresh closures, but not fresh
/// workspaces: the tape's CONST section primes once per solve (the parameter
/// vector does not change between segments), and after the driver refreshes
/// the forcing buffer at a segment boundary [`Self::forcing_refreshed`]
/// re-runs the SEGMENT section, where the DISCRETE forcing loads and
/// everything computed from them live, on the next call.
#[cfg(feature = "solve")]
pub(super) struct SolveProgram {
    program: super::range::RhsProgram,
    rhs: RefCell<Option<super::range::RhsWorkspace>>,
    jac: RefCell<Option<super::range::RhsWorkspace>>,
}

#[cfg(feature = "solve")]
impl SolveProgram {
    pub(super) fn new(compiled: &ArrayCompiled, tape: &std::sync::Arc<TapeProgram>) -> Self {
        SolveProgram {
            program: super::range::RhsProgram::for_solve(compiled, std::sync::Arc::clone(tape)),
            rhs: RefCell::new(None),
            jac: RefCell::new(None),
        }
    }

    /// The driver refreshed the forcing buffer: every workspace built so far
    /// re-runs its SEGMENT section on its next call.
    pub(super) fn forcing_refreshed(&self) {
        for w in [&self.rhs, &self.jac] {
            if let Some(ws) = w.borrow_mut().as_mut() {
                ws.forcing_refreshed();
            }
        }
    }
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

/// A field `ic` that could not be resolved, told why the build-time scope
/// lacks the observeds its RHS reads, when that is the reason: an observed
/// left out of the scope is otherwise just an "unusable RHS".
#[cfg(feature = "solve")]
fn explain_ic_scope_miss(
    err: SimulateError,
    rhs: &Expr,
    skipped: &HashMap<&str, String>,
) -> SimulateError {
    let SimulateError::InvalidFieldInitialCondition { name, mut details } = err else {
        return err;
    };
    if !skipped.is_empty() {
        let mut reads: Vec<String> = super::compile::free_names(rhs).into_iter().collect();
        reads.sort();
        for read in reads {
            if let Some(why) = skipped.get(read.as_str()) {
                details.push_str(&format!(
                    "; the observed '{read}' is not in the build-time scope: it {why}"
                ));
            }
        }
    }
    SimulateError::InvalidFieldInitialCondition { name, details }
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
              "esm": "2.0.0",
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
            .insert("Forced.w".to_string(), arr1(&[10.0, 20.0, 30.0]));
        let (dy1, _) = compiled.debug_eval_rhs(&state, 0.0, &params);
        assert_eq!(
            dy1,
            vec![10.0, 20.0, 30.0],
            "RHS must read the forcing array live from the buffer"
        );

        // Refresh #2 — a driver mutating the buffer between segments. The change
        // is reflected in the RHS output: the channel is live, not build-frozen.
        forcing
            .borrow_mut()
            .insert("Forced.w".to_string(), arr1(&[1.0, 2.0, 3.0]));
        let (dy2, _) = compiled.debug_eval_rhs(&state, 0.0, &params);
        assert_eq!(
            dy2,
            vec![1.0, 2.0, 3.0],
            "a buffer mutation must change the RHS output"
        );
        assert_ne!(
            dy1, dy2,
            "the refreshed forcing must produce a different RHS"
        );

        // The per-cell oracle reads the same buffer.
        let (dy_oracle, _) = compiled.debug_eval_rhs(&state, 0.0, &params);
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
            .insert("Forced.w".to_string(), arr1(&[2.0, 4.0, 6.0]));
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
              "esm": "2.0.0",
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

        let (dy_no_forcing, _) = compiled.debug_eval_rhs(&state, 0.0, &params);
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
        let (dy_with_junk, _) = compiled.debug_eval_rhs(&state, 0.0, &params);
        assert_eq!(
            dy_with_junk,
            vec![6.0, 10.0],
            "an unrelated forcing entry must not perturb the parameter path"
        );
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
    use crate::problem::{Compiler, ProblemOptions, Remake, esm_problem, remake, solve};
    use crate::simulate_array::per_cell_cells;
    use crate::{SolveOptions, load_string};
    use serde_json::{Value, json};

    /// `u` over `n` cells with `D(u) = -u` and `ic(u) = rhs_ic`, and a
    /// parameter `a = 0.5` the `ic` may read.
    fn with_ic(n: usize, rhs_ic: Value) -> crate::EsmFile {
        let doc = json!({
            "esm": "2.0.0",
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

    /// `initial_state` reads the memo in place: neither it nor the first solve
    /// after it resolves the field initial conditions again.
    #[test]
    fn the_initial_state_accessor_leaves_the_memo_for_the_first_solve() {
        let file = with_ic(3, scaled_index());
        for compiler in [Compiler::Native, Compiler::Interpreter] {
            let prob = esm_problem(&file, (0.0, 1.0), opts(compiler))
                .unwrap_or_else(|e| panic!("[{compiler}] {e}"));
            let before = field_ic_resolutions();
            let u0 = crate::problem::initial_state(&prob).expect("an initial state");
            assert_eq!(u0, [0.5, 1.0, 1.5], "[{compiler}]");
            assert_eq!(crate::problem::initial_state(&prob).expect("again"), u0);
            let sol = solve(&prob, &SolveOptions::default()).expect("solves");
            assert_eq!(
                field_ic_resolutions() - before,
                0,
                "[{compiler}] the accessor or the solve after it resolved the ics again"
            );
            assert_eq!(first_column(&sol), u0, "[{compiler}]");
            // The solve spent the memo; the accessor now resolves, to the same
            // values.
            assert_eq!(crate::problem::initial_state(&prob).expect("after"), u0);
            assert_eq!(field_ic_resolutions() - before, 1, "[{compiler}]");
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

    /// A strict compiler lowers an `ic` the reference evaluator would walk
    /// per cell on a standalone tape, after one cell of the walk, and agrees
    /// with the interpreter's full walk bit for bit.
    #[test]
    fn a_large_per_cell_initial_condition_is_taped_after_one_cell() {
        let cumulative = json!({"op": "faq", "args": [], "output_idx": ["i"],
                                "ranges": {"i": {"from": "x"}, "j": {"from": "x"}},
                                "filter": {"op": "<=", "args": ["j", "i"]},
                                "expr": 1.0});
        let n = 100_000;
        let tier_and_u0 = |ic: Value, compiler: Compiler| {
            let file = with_ic(n, ic);
            let before = per_cell_cells();
            let prob = esm_problem(&file, (0.0, 1.0), opts(compiler)).expect("builds");
            let cells = per_cell_cells() - before;
            let tier = prob
                .compiler_report()
                .rules()
                .iter()
                .find(|r| r.kind == "initial condition")
                .expect("an ic row")
                .tier;
            let u0: Vec<u64> = crate::problem::initial_state(&prob)
                .expect("u0")
                .iter()
                .map(|x| x.to_bits())
                .collect();
            (tier, cells, u0)
        };
        // What the rest of the expression makes of the stopped walk's
        // placeholder is not the value either: `1 / Σ` over a walk that
        // stopped reads a zero, and the infinity that follows must not leak.
        let reciprocal = json!({"op": "/", "args": [1.0, cumulative.clone()]});
        for ic in [cumulative, reciprocal] {
            let (tier, cells, native) = tier_and_u0(ic.clone(), Compiler::Native);
            assert_eq!(tier, "taped");
            assert_eq!(cells, 1, "the walk must stop at its first cell");
            let (_, _, interp) = tier_and_u0(ic, Compiler::Interpreter);
            assert_eq!(native, interp);
        }
    }

    /// A CONST provider serving `w` as zeros over three cells.
    struct Zeros;

    impl crate::provider::DataProvider for Zeros {
        fn sample(&mut self) -> Result<ndarray::ArrayD<f64>, crate::provider::ProviderError> {
            Ok(ndarray::ArrayD::zeros(ndarray::IxDyn(&[3])))
        }
    }

    fn loaded(compiler: Compiler) -> crate::EsmProblem {
        let file = with_ic(3, json!("w"));
        let options = ProblemOptions {
            providers: [(
                "w".to_string(),
                Box::new(Zeros) as Box<dyn crate::provider::DataProvider>,
            )]
            .into(),
            ..opts(compiler)
        };
        esm_problem(&file, (0.0, 1.0), options).unwrap_or_else(|e| panic!("[{compiler}] {e}"))
    }

    /// The memo was resolved from the forcing buffer as construction left it.
    /// A host that writes the buffer through `forcing_handle` before the first
    /// solve must get initial conditions from what it wrote.
    #[test]
    fn a_forcing_write_before_the_first_solve_is_not_masked_by_the_memo() {
        for compiler in [Compiler::Native, Compiler::Interpreter] {
            // Untouched, the first solve takes the construction's resolution.
            let prob = loaded(compiler);
            let before = field_ic_resolutions();
            let sol = solve(&prob, &SolveOptions::default()).expect("solves");
            assert_eq!(field_ic_resolutions() - before, 0, "[{compiler}]");
            assert_eq!(first_column(&sol), [0.0, 0.0, 0.0], "[{compiler}]");

            let prob = loaded(compiler);
            let compiled = prob.debug_array_compiled().expect("an array model");
            compiled.forcing_handle().borrow_mut().insert(
                "M.w".to_string(),
                ndarray::ArrayD::from_shape_vec(ndarray::IxDyn(&[3]), vec![1.0, 2.0, 3.0])
                    .expect("shape"),
            );
            let before = field_ic_resolutions();
            let sol = solve(&prob, &SolveOptions::default()).expect("solves");
            assert_eq!(field_ic_resolutions() - before, 1, "[{compiler}]");
            assert_eq!(first_column(&sol), [1.0, 2.0, 3.0], "[{compiler}]");
        }
    }

    /// The memo answers to what the resolution read, not to who holds the
    /// buffer: taking a handle, or writing a field no initial condition
    /// reads, leaves it standing.
    #[test]
    fn a_handle_or_an_unread_write_keeps_the_memo() {
        for compiler in [Compiler::Native, Compiler::Interpreter] {
            let prob = loaded(compiler);
            let compiled = prob.debug_array_compiled().expect("an array model");
            compiled.forcing_handle().borrow_mut().insert(
                "not_read_by_any_ic".to_string(),
                ndarray::ArrayD::from_elem(ndarray::IxDyn(&[]), 7.0),
            );
            let before = field_ic_resolutions();
            let sol = solve(&prob, &SolveOptions::default()).expect("solves");
            assert_eq!(field_ic_resolutions() - before, 0, "[{compiler}]");
            assert_eq!(first_column(&sol), [0.0, 0.0, 0.0], "[{compiler}]");
        }
    }

    /// A DISCRETE provider serving the scalar `b = 1` at every time.
    struct One;

    impl crate::provider::DataProvider for One {
        fn sample(&mut self) -> Result<ndarray::ArrayD<f64>, crate::provider::ProviderError> {
            unreachable!("a discrete provider is not sampled whole")
        }
        fn refresh(
            &mut self,
            _t: f64,
        ) -> Result<Option<ndarray::ArrayD<f64>>, crate::provider::ProviderError> {
            Ok(Some(ndarray::ArrayD::from_elem(ndarray::IxDyn(&[]), 1.0)))
        }
        fn refresh_times(&self) -> Vec<f64> {
            vec![0.5]
        }
    }

    /// A discrete-cadence field no `ic` reads does not stop the first solve
    /// from taking the construction's resolution.
    #[test]
    fn a_discrete_field_no_ic_reads_keeps_the_memo() {
        let doc = json!({
            "esm": "1.1.0",
            "metadata": {"name": "FieldIcMemoDiscrete"},
            "index_sets": {"x": {"kind": "interval", "size": 3}},
            "models": {"M": {
                "variables": {
                    "u": {"type": "unknown", "units": "1", "shape": ["x"]},
                    "a": {"type": "parameter", "units": "1", "default": 0.5},
                    "b": {"type": "parameter", "units": "1", "default": 1.0}
                },
                "equations": [
                    {"lhs": {"op": "ic", "args": ["u"]}, "rhs": scaled_index()},
                    {"lhs": {"op": "faq", "args": [], "output_idx": ["i"],
                             "ranges": {"i": {"from": "x"}},
                             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}],
                                      "wrt": "t"}},
                     "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                             "ranges": {"i": {"from": "x"}},
                             "expr": {"op": "*", "args": ["b", {"op": "-", "args": [
                                 {"op": "index", "args": ["u", "i"]}]}]}}},
                ],
            }},
        });
        let file = load_string(&doc.to_string()).expect("loads");
        for compiler in [Compiler::Native, Compiler::Interpreter] {
            let options = ProblemOptions {
                providers: [(
                    "b".to_string(),
                    Box::new(One) as Box<dyn crate::provider::DataProvider>,
                )]
                .into(),
                ..opts(compiler)
            };
            let before = field_ic_resolutions();
            let prob = esm_problem(&file, (0.0, 1.0), options)
                .unwrap_or_else(|e| panic!("[{compiler}] {e}"));
            let sol = solve(&prob, &SolveOptions::default()).expect("solves");
            assert_eq!(
                field_ic_resolutions() - before,
                1,
                "[{compiler}] the first solve must take the construction's resolution"
            );
            assert_eq!(first_column(&sol), [0.5, 1.0, 1.5], "[{compiler}]");
        }
    }
}

/// Routes caller keys onto a build's parameters (esm-spec §6.6.2) by the rules
/// a `parameter_overrides` key follows, applied to the parameters' qualified
/// names: `Fed.s` is exact, and a bare `s` or a partial qualification is an
/// alias that an exact key for the same parameter shadows.
///
/// A key that is not a parameter's full name is not routed when it exactly
/// names a state or observed variable, or is one the caller asks to keep (a
/// name a coupling reads): such a key, and one that designates no parameter,
/// is used as given.
pub(crate) struct ParameterKeyResolver {
    /// Every forcing and table parameter.
    params: HashSet<String>,
    known: crate::simulate::SuffixIndex,
    /// The states and observed variables that are not parameters.
    others: HashSet<String>,
    namespaces: HashSet<String>,
}

impl ParameterKeyResolver {
    fn routable(&self, key: &str, keep: &HashSet<String>) -> bool {
        self.params.contains(key) || !(keep.contains(key) || self.others.contains(key))
    }

    /// What one key designates (an ambiguous key's candidates too).
    pub(crate) fn resolve(&self, key: &str, keep: &HashSet<String>) -> crate::simulate::KeyHit {
        use crate::simulate::KeyHit;
        if !self.routable(key, keep) {
            return KeyHit::Unknown;
        }
        crate::simulate::resolve_key(&self.known, &self.namespaces, key)
    }

    /// Route `keys` together ([`crate::simulate::route_keys`]).
    pub(crate) fn route<'a>(
        &self,
        keys: impl IntoIterator<Item = &'a str>,
        keep: &HashSet<String>,
    ) -> Result<crate::simulate::KeyRouting, crate::simulate::OverrideKeyError> {
        let routable = keys.into_iter().filter(|k| self.routable(k, keep));
        crate::simulate::route_keys(&self.known, &self.namespaces, routable)
    }
}

#[cfg(test)]
mod parameter_key_resolver_tests {
    use super::*;
    use crate::simulate::KeyHit;

    /// A one-model build: every name carries `Fed`.
    fn resolver() -> ParameterKeyResolver {
        let params: HashSet<String> = ["Fed.s", "Fed.T"].map(String::from).into();
        ParameterKeyResolver {
            known: crate::simulate::SuffixIndex::new(params.iter().map(String::as_str)),
            params,
            others: HashSet::from(["Fed.u".to_string()]),
            namespaces: HashSet::from(["Fed".to_string()]),
        }
    }

    /// Answers are compiled names; a key a coupling reads, or one naming a
    /// state, is used as given unless it is a parameter's full name.
    #[test]
    fn routes_in_compiled_names_and_keeps_coupling_reads() {
        let r = resolver();
        let none = HashSet::new();
        assert_eq!(r.resolve("Fed.s", &none), KeyHit::Exact("Fed.s".into()));
        assert_eq!(r.resolve("s", &none), KeyHit::Alias("Fed.s".into()));
        assert_eq!(r.resolve("Fed.u", &none), KeyHit::Unknown);
        let keep = HashSet::from(["T".to_string(), "Fed.T".to_string()]);
        assert_eq!(r.resolve("T", &keep), KeyHit::Unknown);
        assert_eq!(r.resolve("Fed.T", &keep), KeyHit::Exact("Fed.T".into()));
        let routing = r.route(["T", "s"], &keep).expect("routes");
        assert!(!routing.targets.contains_key("T"));
        assert_eq!(routing.targets.get("s").map(String::as_str), Some("Fed.s"));
    }
}
