use super::*;

// ============================================================================
// Solver loop and array/spatial routing
// ============================================================================

/// Refuse a time span whose start or end is not a finite number.
///
/// `NaN` and both infinities are refused together, and refused at the backend
/// entry points — ahead of the branch between [`nonadvancing_trajectory`] and
/// the solver — so the two cannot disagree about what such a span means.
///
/// Neither is a span this format can express (see
/// [`SimulateError::InvalidTimeSpan`]), and neither names an integration:
/// against `NaN` every ordering test is false, which is indistinguishable from
/// a span that cannot advance, and an infinite end is a stop time the solver
/// loop can never reach.
#[cfg(feature = "solve")]
pub(crate) fn reject_nonfinite_span(t0: f64, t_end: f64) -> Result<(), SimulateError> {
    if t0.is_finite() && t_end.is_finite() {
        return Ok(());
    }
    Err(SimulateError::InvalidTimeSpan {
        start: t0,
        end: t_end,
    })
}

/// The answer to a run that provably never takes a solver step, or `None` when
/// the solver really does have to advance.
///
/// Two shapes qualify, and the answer to both is the initial state on the
/// caller's output grid:
///
///   * an EMPTY interval (`t_end <= t0`). esm-spec §6.6.2 makes that a real
///     test shape — "the instantaneous-derivative test shape (observed
///     tendencies asserted at `time: 0`)" — and §6.6 constrains an assertion's
///     `time` only to lie in `[time_span.start, time_span.end]`, which `0` does
///     in `[0, 0]`; the schema's `TimeSpan` carries no `end > start` rule
///     either. So a document may legitimately ask for `{start: 0, end: 0}` and
///     does: `tests/valid/units_propagation.esm` among others. `set_stop_time`
///     REFUSES that interval — "Stop time is at the current state time" — so it
///     has to be answered without entering diffsol at all.
///   * a NON-empty interval whose whole output grid lies at or before `t0`
///     (`saveat` present and every requested time `<= t0`) — the shape an
///     inline test takes when the document declares, say, `{start: 0, end: 1}`
///     and every assertion is at the initial instant. [`run_solver`]'s `saveat`
///     branch drains such times from the initial state and breaks before its
///     first `step()`, so the trajectory is the same either way.
///
/// Every caller consults this BEFORE building the diffsol problem and its
/// solver (issue #438). Constructing an implicit solver materializes a dense
/// Jacobian, and this crate supplies a MATRIX-FREE finite-difference Jacobian,
/// so diffsol pays one closure call per state column and each call evaluates
/// the whole right-hand side twice: `2·n_states + 1` full RHS evaluations,
/// every observed included, for a run whose answer is the untouched initial
/// state. On a column model whose state count and whose per-evaluation cost
/// both grow with the vertical grid, that is quadratic work in the grid size
/// for an answer that needs one evaluation.
///
/// The `Flow::Cancel` arm is the caller's progress observer declining the run
/// before it starts, exactly as it may inside [`run_solver`]; the single step-0
/// report is made here so that a caller sees the same one either way.
#[cfg(feature = "solve")]
pub(crate) fn nonadvancing_trajectory(
    t0: f64,
    t_end: f64,
    initial_state: &[f64],
    opts: &SolveOptions,
) -> Option<RawTrajectory> {
    // A grid that asks for nothing past `t0` cannot observe a step, so taking
    // one is pure cost. An ABSENT grid is the solver's own natural step grid,
    // which a non-empty interval does have to produce.
    let grid_ends_at_start = match &opts.saveat {
        Some(t_eval) => t_eval.iter().all(|&t| t <= t0),
        None => false,
    };
    if t_end > t0 && !grid_ends_at_start {
        return None;
    }

    let mut times: Vec<f64> = Vec::new();
    let mut state_rows: Vec<Vec<f64>> = vec![Vec::new(); initial_state.len()];
    if let Some(cb) = &opts.progress {
        let p = Progress {
            t0,
            t: t0,
            t_end,
            step: 0,
            maxiters: opts.maxiters,
            u: initial_state,
        };
        if matches!(cb(&p), Flow::Cancel) {
            return Some((times, state_rows, ReturnCode::Terminated));
        }
    }

    // With a grid, every requested time gets the initial state — including a
    // time BEYOND an empty interval: a run that never moves has only the
    // initial state to report. (A run that does step leaves a time past its
    // end out instead; see the tail of [`run_solver`]'s `saveat` branch.)
    // Without a grid, the single point the run produces is `t0` itself.
    let natural = [t0];
    let grid: &[f64] = opts.saveat.as_deref().unwrap_or(&natural);
    for &t in grid {
        times.push(t);
        for (i, &v) in initial_state.iter().enumerate() {
            state_rows[i].push(v);
        }
    }
    Some((times, state_rows, ReturnCode::Success))
}

/// Best-effort solver step / evaluation counters read out of diffsol after a
/// solve, surfaced through [`SolutionMetadata`].
///
/// RHS and Jacobian evaluation counts come from the equations' per-op
/// [`diffsol::OpStatistics`] (`number_of_calls` / `number_of_matrix_evals`),
/// which any [`OdeSolverMethod`] exposes via `problem().eqn.rhs()`. Accepted and
/// rejected step counts come from each concrete solver's `get_statistics()`
/// (a `BdfStatistics`, shared by the Bdf/Sdirk/Erk solvers): `number_of_steps`
/// for accepted steps, and error-test + nonlinear-solver failures for rejected
/// steps. `get_statistics()` is not on the `OdeSolverMethod` trait, so the
/// caller reads those two counts off the concrete solver and passes them in.
#[cfg(feature = "solve")]
#[derive(Debug, Clone, Default)]
pub(crate) struct SolveStats {
    pub n_rhs_calls: usize,
    pub n_jacobian_calls: usize,
    pub n_accepted_steps: usize,
    pub n_rejected_steps: usize,
}

#[cfg(feature = "solve")]
impl SolveStats {
    /// Assemble from a solver's equation-eval statistics (`problem().eqn.rhs()`)
    /// plus the accepted/rejected step counts the caller pulled from the
    /// concrete solver's `get_statistics()`.
    pub(crate) fn from_solver<'a, S, Eqn>(
        solver: &S,
        n_accepted_steps: usize,
        n_rejected_steps: usize,
    ) -> Self
    where
        S: OdeSolverMethod<'a, Eqn>,
        Eqn: diffsol::OdeEquations<T = f64, V = diffsol::FaerVec<f64>> + 'a,
    {
        let op = solver.problem().eqn.rhs().statistics();
        Self {
            n_rhs_calls: op.number_of_calls,
            n_jacobian_calls: op.number_of_matrix_evals,
            n_accepted_steps,
            n_rejected_steps,
        }
    }
}

#[cfg(feature = "solve")]
impl std::ops::AddAssign for SolveStats {
    fn add_assign(&mut self, rhs: Self) {
        self.n_rhs_calls += rhs.n_rhs_calls;
        self.n_jacobian_calls += rhs.n_jacobian_calls;
        self.n_accepted_steps += rhs.n_accepted_steps;
        self.n_rejected_steps += rhs.n_rejected_steps;
    }
}

/// Run the configured solver from `t0` to `t_end`, honoring `opts.maxiters`
/// and `opts.saveat`. Returns `(time_vec, state_matrix_rows)` where
/// `state_matrix_rows[i]` is the trajectory of state variable `i`.
///
/// If `opts.saveat` is `Some`, the solver advances natively but the
/// returned grid is interpolated to exactly those times. We watch each step's
/// `[t_prev, t_curr]` interval and interpolate any user time inside it before
/// moving on, since `interpolate()` is only valid for times within the
/// solver's current dense output window (calling it backwards on a stiff
/// solver returns garbage).
#[cfg(feature = "solve")]
pub(crate) fn run_solver<'a, S, Eqn>(
    solver: &mut S,
    t_end: f64,
    opts: &SolveOptions,
) -> Result<RawTrajectory, SimulateError>
where
    S: OdeSolverMethod<'a, Eqn>,
    Eqn: diffsol::OdeEquations<T = f64, V = diffsol::FaerVec<f64>>,
    Eqn: 'a,
{
    use diffsol::OdeSolverStopReason;

    let t0 = solver.state().t;
    let n_states = solver.state().y.as_slice().len();
    let initial_state: Vec<f64> = solver.state().y.as_slice().to_vec();

    let mut times: Vec<f64> = Vec::new();
    let mut state_rows: Vec<Vec<f64>> = vec![Vec::new(); n_states];

    let push_state = |times: &mut Vec<f64>, state_rows: &mut [Vec<f64>], t: f64, y: &[f64]| {
        times.push(t);
        for (i, &v) in y.iter().enumerate() {
            state_rows[i].push(v);
        }
    };

    // Progress observer (no-op when the caller supplied none). Both loops below
    // report through this, so a host sees the same stream whether it asked for
    // an interpolated output grid or the solver's natural steps.
    //
    // A `Flow::Cancel` is NOT an error: it ends the run with
    // [`ReturnCode::Terminated`] and the trajectory computed so far, because a
    // caller who stops a run deliberately still wants what it produced
    // (`esm-libraries-spec.md` §2.5.3).
    let report = |step: usize, t: f64, u: &[f64]| -> Flow {
        let Some(cb) = &opts.progress else {
            return Flow::Continue;
        };
        let p = Progress {
            t0,
            t,
            t_end,
            step,
            maxiters: opts.maxiters,
            u,
        };
        cb(&p)
    };

    // A run that provably never steps is answered from the initial state
    // without touching diffsol — an empty interval, or an output grid that
    // asks for nothing past `t0` (see [`nonadvancing_trajectory`], which makes
    // the step-0 report itself so a host still sees exactly one).
    //
    // Reaching it here is a backstop: every caller that builds a solver checks
    // it FIRST, because the expense this avoids — the dense Jacobian an
    // implicit solver materializes on construction — is already paid by the
    // time `run_solver` is handed one (issue #438).
    if let Some(traj) = nonadvancing_trajectory(t0, t_end, &initial_state, opts) {
        return Ok(traj);
    }

    // One report before stepping, so a host can render a determinate 0% the
    // moment the solve starts rather than after the first (possibly slow) step.
    let mut retcode = ReturnCode::Success;
    if matches!(report(0, t0, &initial_state), Flow::Cancel) {
        return Ok((times, state_rows, ReturnCode::Terminated));
    }

    solver
        .set_stop_time(t_end)
        .map_err(|e| SimulateError::DiffsolError {
            details: e.to_string(),
        })?;

    let mut step_count: usize = 0;

    if let Some(t_eval) = &opts.saveat {
        // Cursor into the user's evaluation grid. Each step we drain any
        // requested times that now lie inside the solver's [t_prev, t_curr]
        // window.
        let mut next_idx: usize = 0;

        // Handle requested times at or before t0 directly from the initial
        // state — interpolating at t0 on a solver that has not stepped yet
        // is undefined behaviour for some methods.
        while next_idx < t_eval.len() && t_eval[next_idx] <= t0 {
            push_state(
                &mut times,
                &mut state_rows,
                t_eval[next_idx],
                &initial_state,
            );
            next_idx += 1;
        }

        let mut t_prev = t0;
        loop {
            if next_idx >= t_eval.len() {
                break;
            }
            if opts.maxiters.is_some_and(|cap| step_count >= cap) {
                retcode = ReturnCode::MaxIters;
                break;
            }
            let stop = solver.step().map_err(|e| SimulateError::DiffsolError {
                details: e.to_string(),
            })?;
            step_count += 1;
            let t_curr = solver.state().t;
            let y_now = solver.state().y.as_slice().to_vec();
            if !y_now.iter().all(|v| v.is_finite()) {
                retcode = ReturnCode::Unstable;
                break;
            }
            if matches!(report(step_count, t_curr, &y_now), Flow::Cancel) {
                retcode = ReturnCode::Terminated;
                break;
            }

            // Drain user grid points inside (t_prev, t_curr].
            while next_idx < t_eval.len() && t_eval[next_idx] <= t_curr {
                let t = t_eval[next_idx];
                let y = solver
                    .interpolate(t)
                    .map_err(|e| SimulateError::DiffsolError {
                        details: e.to_string(),
                    })?;
                let y_s = y.as_slice();
                push_state(&mut times, &mut state_rows, t, y_s);
                next_idx += 1;
            }

            t_prev = t_curr;
            if matches!(stop, OdeSolverStopReason::TstopReached) {
                break;
            }
        }
        // Whatever is left of the grid lies past `t_end`, or past where a run
        // that stopped early (max iterations, an unstable state, a cancel)
        // got to, and is not part of the trajectory: the trajectory ends where
        // the integration ended. diffsol cannot interpolate past its stop time
        // — every method refuses (issue #478) — so such times are left out,
        // as the segmented path in `simulate_array` leaves them out of its
        // per-segment grids.
        let _ = t_prev;
    } else {
        // Native step grid: record the initial point, then every step.
        push_state(&mut times, &mut state_rows, t0, &initial_state);
        loop {
            if opts.maxiters.is_some_and(|cap| step_count >= cap) {
                retcode = ReturnCode::MaxIters;
                break;
            }
            let stop = solver.step().map_err(|e| SimulateError::DiffsolError {
                details: e.to_string(),
            })?;
            step_count += 1;
            let t_curr = solver.state().t;
            let y_owned: Vec<f64> = solver.state().y.as_slice().to_vec();
            if !y_owned.iter().all(|v| v.is_finite()) {
                retcode = ReturnCode::Unstable;
                break;
            }
            push_state(&mut times, &mut state_rows, t_curr, &y_owned);
            if matches!(report(step_count, t_curr, &y_owned), Flow::Cancel) {
                retcode = ReturnCode::Terminated;
                break;
            }
            if matches!(stop, OdeSolverStopReason::TstopReached) {
                break;
            }
        }
    }

    Ok((times, state_rows, retcode))
}

/// The coupled array route builds from the flattened system, and `flatten` lifts
/// only the top-level components' events, so an event an inline subsystem owns
/// is refused here, while the document still holds it.
fn refuse_coupled_subsystem_event(file: &EsmFile) -> Result<(), CompileError> {
    match crate::compile_error::first_event_in_file(file) {
        Some((construct, name)) => Err(crate::compile_error::event_refusal(
            construct,
            crate::compile_error::ARRAY_EVALUATOR,
            name.as_deref(),
        )),
        None => Ok(()),
    }
}

/// Whether the document's WHOLE content is one model — the only shape
/// `ArrayCompiled::from_file` can consume, since it takes that one raw `Model`
/// and nothing else.
///
/// A reaction system beside the model counts as content: its reactions lower
/// to `D(species, t) = …` during flattening, and a build that skipped them
/// would drop every species from the compiled system. A system with NO
/// reactions lowers to nothing, so it is not content.
pub(crate) fn whole_document_is_one_model(file: &EsmFile) -> bool {
    let one_model = file.models.as_ref().map_or(0, |m| m.len()) == 1;
    let has_reactions = file
        .reaction_systems
        .as_ref()
        .is_some_and(|systems| systems.iter().any(|(_, rs)| !rs.reactions.is_empty()));
    one_model && !has_reactions
}

/// Whether `file` has array-op nodes or spatial model structure — the
/// documents [`compile_array`] accepts.
pub(crate) fn is_array_file(file: &EsmFile) -> bool {
    crate::simulate_array::file_has_array_ops(file)
        || crate::simulate_array::file_has_spatial_model(file)
}

/// Build the array/spatial runtime for `file`. A coupled (multi-model) file has
/// no single raw `Model` for `ArrayCompiled::from_file` to consume — it rejects
/// `models.len() != 1` — so flatten the coupling into one namespaced system first
/// and build from that (ess-14f.8). The single-model path is byte-identical to
/// the original `from_file` call. Shared by all three public entry points.
///
/// **The single-model arm is for a document whose WHOLE content is that one
/// model.** Two other shapes must flatten first, and both used to reach
/// `from_file`:
///
///   * no `models` map at all — a document whose whole content is a
///     `reaction_systems` block, which has no models until flattening lowers
///     each reaction to `D(species, t) = …`. `from_file` refused it with "File
///     has no models to simulate"; every pure-chemistry document in the wild
///     is that shape (`pollu`, `superfast`, `geoschem_fullchem`), and the
///     2026-09-21 census counted 25 of them, all fully taped once flattened;
///   * one model BESIDE a reaction system. `from_file` consumes the single
///     `Model` and DROPS the reaction system, so the species and their
///     reactions vanish from the compiled system — silently, because what is
///     left still builds. A `dAdt = D(Chem.A)` observed then fails as an
///     unlowered `D` and an assertion on `Chem.A` finds no such state.
pub(crate) fn build_array_compiled(
    file: &EsmFile,
) -> Result<crate::simulate_array::ArrayCompiled, SimulateError> {
    // Arm the document's whole precision environment for the build
    // (`crate::precision`) — its `domain.element_type` AND the per-variable
    // `element_type` overrides under it (esm-spec §11.3.1). These are public
    // entries that do not go through `EsmProblem`, and the compiled artifact
    // records the environment it folded its constants in. Re-arming what
    // `EsmProblem` already set is a no-op.
    let env = crate::precision_infer::env_of_file(file).map_err(SimulateError::Compile)?;
    let _precision_guard = env.enter();
    // Under a per-variable element type the equations need their precision
    // boundaries marked before they are lowered, which means working from an
    // annotated COPY (`None`, and no copy at all, for every other document).
    let annotated = crate::precision_infer::annotated(file).map_err(SimulateError::Compile)?;
    let file = annotated.as_ref().unwrap_or(file);
    if !whole_document_is_one_model(file) {
        refuse_coupled_subsystem_event(file)?;
        let flat = flatten(file).map_err(CompileError::from)?;
        Ok(crate::simulate_array::ArrayCompiled::from_flattened(&flat)?)
    } else {
        Ok(crate::simulate_array::ArrayCompiled::from_file(file)?)
    }
}

/// Two-step entry point for array/spatial files: CONSUME the parsed
/// [`EsmFile`] and compile it into the array runtime's
/// [`crate::simulate_array::ArrayCompiled`], which the caller then solves
/// with [`crate::simulate_array::ArrayCompiled::simulate`]. The one-shot
/// [`crate::problem::esm_problem`] borrows `file` and so keeps it alive for the
/// whole build; for
/// a large expanded discretization the typed file is on the order of the
/// compiled rules themselves (~1 GiB for `simpleclimate.esm` at its
/// production grid), and taking the file by value both lets it die before
/// the solve AND lets the single-model build move the observed bodies into
/// the compiled rules instead of deep-copying them
/// ([`crate::simulate_array::ArrayCompiled::from_file_owned`]).
///
/// ```text
/// let compiled = compile_array(file)?;          // file is consumed here
/// let sol = compiled.solve(tspan, &params, &ics, &opts)?;
/// ```
///
/// Routing matches the one-shot entry points ([`build_array_compiled`]): a
/// coupled (multi-model) file is flattened first (the file is dropped right
/// after flattening); a single-model file compiles directly. Errors with
/// [`SimulateError`] if `file` has no array-op or spatial structure — a
/// pure-scalar file is built by [`crate::problem::esm_problem`], whose build
/// is cheap enough for it that a two-step split buys nothing.
pub fn compile_array(file: EsmFile) -> Result<crate::simulate_array::ArrayCompiled, SimulateError> {
    if !is_array_file(&file) {
        return Err(SimulateError::Compile(
            CompileError::InterpreterBuildError {
                details: "compile_array requires an array/spatial model (this file has none); \
                      use esm_problem for pure-scalar files"
                    .to_string(),
            },
        ));
    }
    // As `build_array_compiled`: the document's whole precision environment,
    // and an annotated copy when (and only when) a variable declares its own
    // `element_type` (esm-spec §11.3.1).
    let env = crate::precision_infer::env_of_file(&file).map_err(SimulateError::Compile)?;
    let _precision_guard = env.enter();
    let file = match crate::precision_infer::annotated(&file).map_err(SimulateError::Compile)? {
        Some(annotated) => annotated,
        None => file,
    };
    if !whole_document_is_one_model(&file) {
        refuse_coupled_subsystem_event(&file)?;
        let flat = flatten(&file).map_err(CompileError::from)?;
        drop(file);
        Ok(crate::simulate_array::ArrayCompiled::from_flattened(&flat)?)
    } else {
        Ok(crate::simulate_array::ArrayCompiled::from_file_owned(file)?)
    }
}
