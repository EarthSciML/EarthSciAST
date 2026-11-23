//! Running a Problem: `solve`, its provider refresh, and the stepping
//! integrator.

use super::*;

// =============================================================================
// solve
// =============================================================================

/// Run `prob` to completion (§2.5.3).
///
/// `opts` carries only per-run knobs: `alg`, `abstol`, `reltol`, `saveat`,
/// `callback`, `maxiters`. The result carries a
/// [`retcode`](crate::ReturnCode) — a caller distinguishes "ran to `tspan.1`"
/// from "stopped early, here is why" without parsing prose.
///
/// **`opts.callback` REPLACES the EsmProblem's callback set entirely.** It does
/// not append, merge or wrap. To extend rather than replace, read the set back
/// with [`callbacks`] and [`compose`] explicitly. See §2.5.4 for why
/// replacement is the safe default.
///
/// **`opts.output_observed` adds rows.** A [`Solution`] carries state rows by
/// default; a name listed there is appended as extra rows in the flat cell-key
/// spelling the state uses, which is what [`crate::derive_output_plan`] needs
/// to write that field alongside the state (RFC decision 8).
#[cfg(feature = "solve")]
pub fn solve(prob: &EsmProblem, opts: &SolveOptions) -> Result<Solution, SimulateError> {
    refuse_stripped(prob, "solve")?;
    // Re-arm the document's working precision for the duration of this call
    // (`domain.element_type`, esm-spec §11.3); a no-op for a Float64 document.
    let _precision_guard = prob.precision.enter();
    let effective = effective_options(prob, opts);
    match &*prob.backend {
        Backend::Static(reason) => Err(SimulateError::NotDynamic {
            details: reason.clone(),
        }),
        Backend::Array(compiled) => {
            let mut insp = BuildInspection::default();
            let sink = prob.inspect.then_some(&mut insp);
            let mut forcing = ProviderRefresh::new(prob, compiled);
            let run = forcing.run_spec(opts);
            let sol = compiled
                .solve_run(&run, &effective, sink, &mut |t| forcing.at(t))
                .map_err(|e| compiled.show_error(e))?;
            if prob.inspect {
                *prob.inspection.borrow_mut() = insp;
            }
            Ok(sol)
        }
    }
}

/// The provider refresh a run of a Problem drives
/// (`simulate_array::session::Refresh`): at the run's start, the record in
/// effect there, whatever an earlier run of this Problem (or of one remade
/// from it) left in the forcing buffer, and the declared default where no
/// record is in effect yet; at every later call, a refresh time. A Problem
/// with no discrete-cadence provider refreshes nothing.
#[cfg(feature = "solve")]
pub(super) struct ProviderRefresh<'p> {
    prob: &'p EsmProblem,
    #[cfg(not(target_arch = "wasm32"))]
    exec: Option<(&'p SharedRefresh, &'p ArrayCompiled)>,
    #[cfg(not(target_arch = "wasm32"))]
    started: bool,
}

#[cfg(feature = "solve")]
impl<'p> ProviderRefresh<'p> {
    fn new(prob: &'p EsmProblem, compiled: &'p ArrayCompiled) -> Self {
        let _ = compiled;
        ProviderRefresh {
            prob,
            #[cfg(not(target_arch = "wasm32"))]
            exec: prob
                .refresh
                .as_ref()
                .filter(|_| !prob.discrete_forcing.is_empty())
                .map(|exec| (exec, compiled)),
            #[cfg(not(target_arch = "wasm32"))]
            started: false,
        }
    }

    /// The run over the Problem's span and bindings, with the refresh
    /// boundaries and the discrete-cadence forcing this refresh serves.
    fn run_spec(&self, opts: &SolveOptions) -> crate::simulate_array::RunSpec<'p> {
        static NONE: std::sync::OnceLock<std::collections::HashSet<String>> =
            std::sync::OnceLock::new();
        let prob = self.prob;
        #[cfg(not(target_arch = "wasm32"))]
        let (discrete_forcing, boundaries): (_, &[f64]) = match self.exec {
            Some(_) => (&prob.discrete_forcing, &prob.refresh_boundaries),
            None => (NONE.get_or_init(Default::default), &[]),
        };
        #[cfg(target_arch = "wasm32")]
        let (discrete_forcing, boundaries): (_, &[f64]) = (NONE.get_or_init(Default::default), &[]);
        crate::simulate_array::RunSpec {
            tspan: prob.tspan,
            params: &prob.p,
            initial_conditions: &prob.u0,
            discrete_forcing,
            boundaries,
            reltol_source: if opts.reltol.is_some() {
                "call site"
            } else if prob
                .solver
                .as_ref()
                .is_some_and(|solver| solver.reltol.is_some())
            {
                "solver.reltol"
            } else {
                "binding default"
            },
        }
    }

    fn at(&mut self, t: f64) -> Result<(), SimulateError> {
        #[cfg(not(target_arch = "wasm32"))]
        if let Some((exec, compiled)) = self.exec {
            let given = &self.prob.provider_keys;
            let forcing = compiled.forcing_handle();
            let mut exec = exec.borrow_mut();
            if std::mem::replace(&mut self.started, true) {
                return exec
                    .refresh_named(t, &forcing)
                    .map(|_| ())
                    .map_err(|e| loader_error(given, e));
            }
            let vacant = exec
                .sample_in_effect(t, &forcing, &mut Vec::new())
                .map_err(|e| loader_error(given, e))?;
            return seed_vacant_discrete(
                compiled,
                &vacant,
                given,
                "the solve's start",
                t,
                &mut forcing.borrow_mut(),
            );
        }
        let _ = t;
        Ok(())
    }
}

/// The initial state `prob` integrates from, one value per state element,
/// aligned with [`EsmProblem::state_variable_names`].
///
/// This is the state every solve of `prob` starts from at `tspan.0`, built
/// the same way: per element, the first of the Problem's `u0` override
/// ([`ProblemOptions::u0`]), an initialization equation (esm-spec §6.2), an
/// `ic` equation or field initial condition (§11.4, §11.4.1; a scoped or
/// coordinate-expression `ic` included), and the variable's declared
/// `default`, with the Problem's parameters ([`ProblemOptions::p`], else
/// their defaults) bound in every initial condition's scope (§6.6.5).
/// [`crate::RhsProgram::default_state`] is the declared defaults alone.
///
/// Nothing is integrated, and the result does not depend on any solver
/// option. An `ic` right-hand side reads each data-fed field at `tspan.0`
/// (esm-spec §11.4.2): the providers of the discrete-cadence fields it reads
/// are sampled there into a buffer of their own, without writing the
/// Problem's forcing, so calling this before or after a solve gives the same
/// state, and a solve after it still starts from the record in effect at its
/// start. Julia's equivalent is the `prob.u0` field, indexed through
/// `prob.var_map`.
///
/// # Errors
///
/// [`SimulateError::NotDynamic`] for a Problem with no right-hand side to
/// integrate, and every error building the initial state raises in a solve:
/// [`SimulateError::InvalidInitialCondition`] for an element none of the four
/// sources values, and the error of an initial condition that cannot be
/// evaluated.
#[cfg(feature = "solve")]
pub fn initial_state(prob: &EsmProblem) -> Result<Vec<f64>, SimulateError> {
    // Re-arm the document's working precision for the duration of this call
    // (`domain.element_type`, esm-spec §11.3); a no-op for a Float64 document.
    let _precision_guard = prob.precision.enter();
    // The discrete-cadence fields the solve's own refresh would write: none
    // when the Problem holds no executor, as in `solve`. An `ic` right-hand
    // side reads each at its value at the start of the run (esm-spec
    // §11.4.2), which is not necessarily the record the forcing buffer holds
    // (construction sampled `sample_time`; a solve leaves a later record), so
    // the providers of the ones it reads are sampled at `tspan.0` into a
    // buffer of their own.
    let none = std::collections::HashSet::new();
    let t0 = prob.tspan.0;
    #[cfg(not(target_arch = "wasm32"))]
    let (discrete_forcing, at_t0) = match (&prob.refresh, &*prob.backend) {
        (Some(exec), Backend::Array(compiled)) if !prob.discrete_forcing.is_empty() => {
            let read: std::collections::HashSet<String> = compiled
                .ic_forcing_reads()
                .into_iter()
                .filter(|n| prob.discrete_forcing.contains(n))
                .collect();
            let at_t0 = if read.is_empty() {
                None
            } else {
                Some(discrete_at_start(
                    compiled,
                    exec,
                    &read,
                    t0,
                    &prob.provider_keys,
                )?)
            };
            (&prob.discrete_forcing, at_t0)
        }
        _ => (&none, None),
    };
    #[cfg(target_arch = "wasm32")]
    let (discrete_forcing, at_t0): (_, Option<HashMap<String, ndarray::ArrayD<f64>>>) =
        (&none, None);
    let start = crate::simulate_array::IcStart {
        t0,
        at_t0: at_t0.as_ref(),
        exclude: discrete_forcing,
    };
    match &*prob.backend {
        Backend::Static(reason) => Err(SimulateError::NotDynamic {
            details: reason.clone(),
        }),
        Backend::Array(compiled) => compiled.initial_state(&prob.p, &prob.u0, &start),
    }
}

/// Run the esm-spec §2.2.2 tolerance chain against `prob`'s `solver` block and
/// return `opts` with both tolerances made CONCRETE.
///
/// Caller > the document's `solver` block > binding default, per field. The
/// chain belongs to "a document is being integrated", not to one entry point:
/// [`effective_options`] applies it, and both doors a document is integrated
/// through, `solve` and `init` (§2.5.6's stepping lifecycle), go through that.
///
/// **Idempotent**: the result has `Some` in both slots, so a second pass
/// resolves at level 1 to the same values.
pub(super) fn with_resolved_tolerances(prob: &EsmProblem, opts: &SolveOptions) -> SolveOptions {
    let (abstol, reltol) =
        crate::resolve_tolerances(prob.solver.as_ref(), opts.abstol, opts.reltol);
    SolveOptions {
        abstol: Some(abstol),
        reltol: Some(reltol),
        ..opts.clone()
    }
}

/// Fold the EsmProblem's callbacks (or the run's REPLACEMENT set) and the
/// extension-seam progress observer into the one per-step hook the solver
/// loop drives, on top of the §2.2.2 tolerance chain. Applied once per run:
/// it is not idempotent in the callbacks (a second pass would wrap the
/// already-wrapped observer and invoke every callback twice per step).
pub(super) fn effective_options(prob: &EsmProblem, opts: &SolveOptions) -> SolveOptions {
    // An OUTPUT REQUEST is keyed by name, so it addresses a state an
    // `operator_compose` renaming match may have DELETED (issue #230). Resolve
    // the request list onto the surviving spellings here, where the compiled
    // artifact's map is in hand — `derive_output_plan` sees only the request and
    // the slot names, and would report the dead spelling as unknown.
    let observed = resolve_output_request(prob, &opts.output_observed);

    // esm-spec §2.2.2, resolved once here — the single point where a `solve`
    // run's options and the document meet — so every backend below sees
    // concrete tolerances and none of them has to know about the chain.
    let resolved = with_resolved_tolerances(prob, opts);

    // §2.5.4: the run's `callback` REPLACES the EsmProblem's set. It does not
    // append, merge, or wrap.
    let set = opts
        .callback
        .clone()
        .unwrap_or_else(|| prob.callbacks.clone());
    if set.is_empty() {
        return match observed {
            Some(output_observed) => SolveOptions {
                output_observed,
                ..resolved
            },
            None => resolved,
        };
    }
    let user = opts.progress.clone();
    let observer: ProgressFn = wrap_observer(set, user);
    SolveOptions {
        progress: Some(observer),
        output_observed: observed.unwrap_or_else(|| opts.output_observed.clone()),
        ..resolved
    }
}

/// The problem's flatten-time merge map (issue #230), or an empty one for a
/// backend that carries none.
pub(super) fn problem_merged_renames(prob: &EsmProblem) -> &HashMap<String, String> {
    static EMPTY: std::sync::OnceLock<HashMap<String, String>> = std::sync::OnceLock::new();
    match &*prob.backend {
        Backend::Array(c) => c.merged_renames(),
        Backend::Static(_) => EMPTY.get_or_init(HashMap::new),
    }
}

/// Rewrite an output request off names an `operator_compose` renaming match
/// DELETED. `None` when nothing changes, so the common path clones nothing.
///
/// Not gated on `solve`: its one caller, `effective_options`, is not either.
pub(super) fn resolve_output_request(
    prob: &EsmProblem,
    requested: &[String],
) -> Option<Vec<String>> {
    if requested.is_empty() {
        return None;
    }
    let renames = problem_merged_renames(prob);
    if renames.is_empty() || !requested.iter().any(|n| renames.contains_key(n.as_str())) {
        return None;
    }
    Some(
        requested
            .iter()
            .map(|n| {
                renames
                    .get(n.as_str())
                    .cloned()
                    .unwrap_or_else(|| n.clone())
            })
            .collect(),
    )
}

/// The document's §2.2 `solver` block, read out of a raw document.
///
/// Used at CONSTRUCTION, for the input carriers that reach `esm_problem` as raw
/// JSON (a path, a `Json` value, or a typed file the build pipeline
/// re-serialized). The typed carriers read `EsmFile::solver` directly; either
/// way the block lands on [`EsmProblem::solver`], which is what the §2.2.2
/// chain consults at solve time.
pub(super) fn document_solver(doc: &JsonValue) -> Option<crate::Solver> {
    let block = doc.get("solver")?;
    // §2.2: an EMPTY block means what absence means, so it normalizes away
    // rather than becoming a `Solver` with nothing set.
    crate::solver::normalize_empty(serde_json::from_value(block.clone()).ok()?)
}

#[cfg(not(target_arch = "wasm32"))]
pub(super) fn wrap_observer(set: CallbackSet, user: Option<ProgressFn>) -> ProgressFn {
    std::sync::Arc::new(move |p: &Progress<'_>| {
        let a = set.invoke(p);
        let b = user.as_ref().map(|f| f(p)).unwrap_or(Flow::Continue);
        if matches!(a, Flow::Cancel) || matches!(b, Flow::Cancel) {
            Flow::Cancel
        } else {
            Flow::Continue
        }
    })
}

#[cfg(target_arch = "wasm32")]
pub(super) fn wrap_observer(set: CallbackSet, user: Option<ProgressFn>) -> ProgressFn {
    std::sync::Arc::new(move |p: &Progress<'_>| {
        let a = set.invoke(p);
        let b = user.as_ref().map(|f| f(p)).unwrap_or(Flow::Continue);
        if matches!(a, Flow::Cancel) || matches!(b, Flow::Cancel) {
            Flow::Cancel
        } else {
            Flow::Continue
        }
    })
}

// =============================================================================
// Stepping
// =============================================================================

/// A stepping integrator (§2.5.6) — the same lifecycle [`solve`] performs
/// internally, exposed for callers that need to interleave their own work with
/// the integration: the coupling driver in a host model, an interactive
/// session, a progress UI.
///
/// [`init`] pays for what a run sets up once — the parameter vector, the
/// initial state, the tape, the cadence partition of the observeds and the
/// right-hand side's workspaces — and the integrator keeps them, with the
/// state vector, across every step.
///
/// # What a "step" is here
///
/// [`Integrator::step`] advances to the next entry of the **output grid**, not
/// to the next internal solver step. Each advance runs the configured
/// algorithm over `[t_now, t_next]` from the current state, split on the
/// provider refresh boundaries in between exactly as [`solve`] splits its run.
/// That means the adaptive controller restarts at every interleave point, so
/// a run stepped in N pieces is not step-for-step identical to the same run
/// solved in one call — it is the same trajectory to tolerance, at some extra
/// cost per boundary. Choose the grid accordingly: coarse when you only need
/// to interleave, fine when you need control.
///
/// (`diffsol`'s solver borrows its `OdeSolverProblem`, so an integrator that
/// also owned a live solver would be self-referential. Restarting per grid
/// interval is the safe-Rust way to expose the lifecycle, and it is the
/// mechanism a solve already uses at a refresh boundary.)
///
/// A progress observer or callback sees the whole run: `t0` and `t_end` are
/// the Problem's span and `step` counts accepted steps from the start of the
/// run, as in one [`solve`].
#[cfg(feature = "solve")]
pub struct Integrator<'a> {
    prob: &'a EsmProblem,
    session: crate::simulate_array::SolveSession<'a>,
    forcing: ProviderRefresh<'a>,
    grid: Vec<f64>,
    next: usize,
    t: f64,
    /// The state by name, refreshed from the session after every step.
    u: HashMap<String, f64>,
    time: Vec<f64>,
    state: Vec<Vec<f64>>,
    names: Vec<String>,
}

#[cfg(feature = "solve")]
impl std::fmt::Debug for Integrator<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Integrator")
            .field("t", &self.t)
            .field("remaining", &(self.grid.len().saturating_sub(self.next)))
            .field("retcode", &self.session.retcode())
            .finish()
    }
}

/// Whether an [`Integrator`] has more to do.
#[cfg(feature = "solve")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StepStatus {
    /// The integrator advanced and has further grid points to cover.
    Advanced,
    /// The integrator reached `tspan.1`, or stopped early — read
    /// [`Integrator::retcode`].
    Done,
}

/// Build a stepping integrator for `prob` (§2.5.6).
///
/// The step grid is `opts.saveat` when the caller supplied one, else 100 evenly
/// spaced points across `tspan`.
///
/// The esm-spec §2.2.2 tolerance chain and the callback folding run HERE, as
/// at `solve`: the integrator carries the document's `solver.abstol` /
/// `reltol` whenever the caller named none, so stepping a document honours its
/// declared numerics exactly as solving it does.
///
/// The initial state is built here, so an error building it (an element no
/// source values, an initial condition that cannot be evaluated) is reported
/// by `init`.
#[cfg(feature = "solve")]
pub fn init<'a>(
    prob: &'a EsmProblem,
    opts: &SolveOptions,
) -> Result<Integrator<'a>, SimulateError> {
    refuse_stripped(prob, "init")?;
    // Re-arm the document's working precision for the duration of this call
    // (`domain.element_type`, esm-spec §11.3); a no-op for a Float64 document.
    let _precision_guard = prob.precision.enter();
    let compiled = match &*prob.backend {
        Backend::Static(reason) => {
            return Err(SimulateError::NotDynamic {
                details: reason.clone(),
            });
        }
        Backend::Array(compiled) => compiled,
    };
    let (t0, t_end) = prob.tspan;
    let grid = match &opts.saveat {
        Some(g) if g.len() >= 2 => g.clone(),
        _ => {
            let n = 100usize;
            (0..=n)
                .map(|i| t0 + (t_end - t0) * (i as f64) / (n as f64))
                .collect()
        }
    };
    let mut forcing = ProviderRefresh::new(prob, compiled);
    let run = forcing.run_spec(opts);
    let effective = effective_options(prob, opts);
    let session = compiled.open_session(&run, effective, &grid, &mut |t| forcing.at(t))?;
    let names = prob.state_variable_names();
    let u = names
        .iter()
        .cloned()
        .zip(session.state().iter().copied())
        .collect();
    Ok(Integrator {
        prob,
        session,
        forcing,
        grid,
        next: 0,
        t: t0,
        u,
        time: Vec::new(),
        state: Vec::new(),
        names,
    })
}

#[cfg(feature = "solve")]
impl Integrator<'_> {
    /// The independent-variable value reached so far.
    pub fn t(&self) -> f64 {
        self.session.output_time(self.t)
    }

    /// Why the integration stopped, once it has.
    pub fn retcode(&self) -> crate::simulate::ReturnCode {
        self.session.retcode()
    }

    /// The current state, keyed by state-variable name.
    pub fn u(&self) -> &HashMap<String, f64> {
        &self.u
    }

    /// Advance to the next grid point. Returns [`StepStatus::Done`] at the end
    /// of `tspan` or when the run stopped early.
    pub fn step(&mut self) -> Result<StepStatus, SimulateError> {
        // Re-arm the document's working precision (esm-spec §11.3); a stepping
        // caller reaches the RHS without passing back through `solve`.
        let _precision_guard = self.prob.precision.enter();
        if !self.retcode().is_success() {
            return Ok(StepStatus::Done);
        }
        // Skip grid points at or behind where we already are.
        while self.next < self.grid.len() && self.grid[self.next] <= self.t {
            self.next += 1;
        }
        if self.next >= self.grid.len() {
            return Ok(StepStatus::Done);
        }
        let t_next = self.grid[self.next];
        let forcing = &mut self.forcing;
        let sol = self
            .session
            .advance(t_next, Some(&[t_next]), &mut |t| forcing.at(t))?;

        if self.state.is_empty() {
            // The state rows, then the observed rows the first step reported.
            self.names = sol.state_variable_names.clone();
            self.state = vec![Vec::new(); self.names.len()];
        }
        if let Some(k) = sol.time.len().checked_sub(1) {
            self.time.push(sol.time[k]);
            for (row, sol_row) in self.state.iter_mut().zip(&sol.state) {
                if let Some(v) = sol_row.get(k) {
                    row.push(*v);
                }
            }
            self.t = t_next;
        }
        // The leading names are the state's, in state-vector order.
        for (name, v) in self.names.iter().zip(self.session.state()) {
            self.u.insert(name.clone(), *v);
        }
        self.next += 1;
        if self.next >= self.grid.len() || !self.retcode().is_success() {
            Ok(StepStatus::Done)
        } else {
            Ok(StepStatus::Advanced)
        }
    }

    /// Run to completion and take the accumulated [`Solution`]. This is the
    /// `solve!` of the SciML lifecycle; it is spelled out because `!` is not a
    /// legal suffix in Rust.
    pub fn solve_to_completion(&mut self) -> Result<Solution, SimulateError> {
        while matches!(self.step()?, StepStatus::Advanced) {}
        let metadata = self.session.metadata();
        Ok(Solution {
            time: std::mem::take(&mut self.time),
            state: std::mem::take(&mut self.state),
            state_variable_names: self.names.clone(),
            retcode: self.retcode(),
            metadata,
        })
    }
}

/// Advance `integrator` by one grid point (§2.5.6's `step!`).
#[cfg(feature = "solve")]
pub fn step(integrator: &mut Integrator<'_>) -> Result<StepStatus, SimulateError> {
    integrator.step()
}

/// Run `integrator` to completion (§2.5.6's `solve!`).
#[cfg(feature = "solve")]
pub fn solve_to_completion(integrator: &mut Integrator<'_>) -> Result<Solution, SimulateError> {
    integrator.solve_to_completion()
}

// ===========================================================================
// Unit tests
// ===========================================================================

/// The esm-spec §2.2.2 chain at the STEPPING door.
///
/// These live in-crate rather than in `tests/solver_block.rs` because what has
/// to be pinned is that the resolved tolerances land ON the integrator — a
/// private field. An observational test (does a looser tolerance change the
/// trajectory?) would pass either way for a well-conditioned decay and is not
/// the property; this is.
#[cfg(all(test, feature = "solve", not(target_arch = "wasm32")))]
mod stepping_tolerance_tests {
    use super::*;
    use crate::simulate::{DEFAULT_ABSTOL, DEFAULT_RELTOL};

    fn doc(solver: &str) -> serde_json::Value {
        serde_json::from_str(&format!(
            r#"{{"esm": "2.0.0","metadata":{{"name":"T"}},{solver}"models":{{"M":{{
                 "variables":{{"y":{{"type":"unknown","units":"m","default":1.0}}}},
                 "equations":[{{"lhs":{{"op":"D","args":["y"],"wrt":"t"}},
                                "rhs":{{"op":"-","args":["y"]}}}}]}}}}}}"#
        ))
        .expect("fixture parses")
    }

    fn problem(solver: &str) -> EsmProblem {
        let json = doc(solver);
        esm_problem(
            ProblemInput::Json(&json),
            (0.0, 1.0),
            ProblemOptions::default(),
        )
        .expect("builds")
    }

    /// A stepping caller who names no tolerance gets the DOCUMENT's, not the
    /// binding default, and the integrator holds the tolerances it runs at.
    #[test]
    fn init_resolves_the_documents_tolerances() {
        let prob = problem(r#""solver":{"abstol":1e-8,"reltol":1e-6},"#);
        let integ = init(&prob, &SolveOptions::default()).expect("init");
        assert_eq!(integ.session.options().abstol, Some(1e-8));
        assert_eq!(integ.session.options().reltol, Some(1e-6));
    }

    /// Level 1 still wins: an explicitly-passed option beats the document.
    #[test]
    fn an_explicit_call_site_option_still_beats_the_document() {
        let prob = problem(r#""solver":{"abstol":1e-8,"reltol":1e-6},"#);
        let opts = SolveOptions {
            abstol: Some(1e-12),
            reltol: Some(1e-11),
            ..SolveOptions::default()
        };
        let integ = init(&prob, &opts).expect("init");
        assert_eq!(integ.session.options().abstol, Some(1e-12));
        assert_eq!(integ.session.options().reltol, Some(1e-11));
    }

    /// Per FIELD, and level 3 for whatever the document leaves unsaid.
    #[test]
    fn each_tolerance_falls_through_on_its_own() {
        let only_reltol = problem(r#""solver":{"reltol":1e-9},"#);
        let integ = init(&only_reltol, &SolveOptions::default()).expect("init");
        assert_eq!(integ.session.options().reltol, Some(1e-9));
        assert_eq!(integ.session.options().abstol, Some(DEFAULT_ABSTOL));

        let no_block = problem("");
        let integ = init(&no_block, &SolveOptions::default()).expect("init");
        assert_eq!(integ.session.options().abstol, Some(DEFAULT_ABSTOL));
        assert_eq!(integ.session.options().reltol, Some(DEFAULT_RELTOL));
    }

    /// The chain is idempotent: a second pass neither changes the answer nor
    /// displaces the document.
    #[test]
    fn resolving_twice_is_resolving_once() {
        let prob = problem(r#""solver":{"abstol":1e-8,"reltol":1e-6},"#);
        let once = with_resolved_tolerances(&prob, &SolveOptions::default());
        let twice = with_resolved_tolerances(&prob, &once);
        assert_eq!((twice.abstol, twice.reltol), (once.abstol, once.reltol));
        assert_eq!((twice.abstol, twice.reltol), (Some(1e-8), Some(1e-6)));
    }
}
