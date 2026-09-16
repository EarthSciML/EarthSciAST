use super::*;

// ============================================================================
// Solver loop and array/spatial routing
// ============================================================================

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

    // One report before stepping, so a host can render a determinate 0% the
    // moment the solve starts rather than after the first (possibly slow) step.
    let mut retcode = ReturnCode::Success;
    if matches!(report(0, t0, &initial_state), Flow::Cancel) {
        return Ok((times, state_rows, ReturnCode::Terminated));
    }

    // An EMPTY interval integrates nothing, and its whole answer is the initial
    // state. esm-spec §6.6.2 makes that a real test shape — "the
    // instantaneous-derivative test shape (observed tendencies asserted at
    // `time: 0`)" — and §6.6 constrains an assertion's `time` only to lie in
    // `[time_span.start, time_span.end]`, which `0` does in `[0, 0]`; the
    // schema's `TimeSpan` carries no `end > start` rule either. So a document
    // may legitimately ask for `{start: 0, end: 0}` and does:
    // `tests/valid/units_propagation.esm`, and 22 other corpus documents that
    // only got away with it by being STATIC (no ODEs at all, so `solve` returns
    // `NotDynamic` and the inline-test runner answers from the build).
    //
    // `set_stop_time` REFUSES that interval — "Stop time is at the current state
    // time" — so the one dynamic document in that set failed all ten of its
    // assertions on a solver complaint about having nothing to do, while Julia
    // and Python both evaluated it. Answer it here instead, from the state the
    // solver was initialized with, and never enter diffsol. Nothing about how
    // diffsol is driven over a NON-empty interval changes: `set_stop_time` now
    // runs just below, on exactly the intervals it always accepted.
    //
    // The `saveat` branch already did this for the requested times at or before
    // `t0`; this is the same answer for the whole grid when the run cannot get
    // past `t0`. A grid time BEYOND an empty interval is the courtesy
    // extrapolation the tail of that branch performs, which for a run that
    // never moves is the initial state too.
    if t_end <= t0 {
        match &opts.saveat {
            Some(t_eval) => {
                for &t in t_eval {
                    push_state(&mut times, &mut state_rows, t, &initial_state);
                }
            }
            None => push_state(&mut times, &mut state_rows, t0, &initial_state),
        }
        return Ok((times, state_rows, retcode));
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
            if step_count >= opts.maxiters {
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
        // Anything after the solver's tstop is interpolated by extrapolation
        // — strictly speaking out-of-range, but accept it as a courtesy if
        // the user asked for it. A run that stopped early (max iterations, an
        // unstable state, a cancel) is NOT extrapolated past where it got to:
        // the trajectory ends where the integration ended.
        while retcode.is_success() && next_idx < t_eval.len() {
            let t = t_eval[next_idx];
            let y = solver
                .interpolate(t)
                .map_err(|e| SimulateError::DiffsolError {
                    details: e.to_string(),
                })?;
            push_state(&mut times, &mut state_rows, t, y.as_slice());
            next_idx += 1;
        }
        let _ = t_prev;
    } else {
        // Native step grid: record the initial point, then every step.
        push_state(&mut times, &mut state_rows, t0, &initial_state);
        loop {
            if step_count >= opts.maxiters {
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

/// Whether `file` must route to the array/spatial runtime
/// ([`crate::simulate_array`]) rather than the scalar ODE interpreter: it has
/// array-op nodes or spatial model structure. EsmProblem construction
/// ([`crate::problem::esm_problem`]) is the single caller, so the routing is
/// decided exactly once, at build time.
pub(crate) fn is_array_file(file: &EsmFile) -> bool {
    crate::simulate_array::file_has_array_ops(file)
        || crate::simulate_array::file_has_spatial_model(file)
}

/// Build the array/spatial runtime for `file`. A coupled (multi-model) file has
/// no single raw `Model` for `ArrayCompiled::from_file` to consume — it rejects
/// `models.len() != 1` — so flatten the coupling into one namespaced system first
/// and build from that (ess-14f.8). The single-model path is byte-identical to
/// the original `from_file` call. Shared by all three public entry points.
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
    let model_count = file.models.as_ref().map_or(0, |m| m.len());
    if model_count > 1 {
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
/// pure-scalar file belongs to [`Compiled::from_file`], whose build is cheap
/// enough that a two-step split buys nothing.
pub fn compile_array(file: EsmFile) -> Result<crate::simulate_array::ArrayCompiled, SimulateError> {
    if !is_array_file(&file) {
        return Err(SimulateError::Compile(
            CompileError::InterpreterBuildError {
                details: "compile_array requires an array/spatial model (this file has none); \
                      use Compiled::from_file for pure-scalar files"
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
    let model_count = file.models.as_ref().map_or(0, |m| m.len());
    if model_count > 1 {
        refuse_coupled_subsystem_event(&file)?;
        let flat = flatten(&file).map_err(CompileError::from)?;
        drop(file);
        Ok(crate::simulate_array::ArrayCompiled::from_flattened(&flat)?)
    } else {
        Ok(crate::simulate_array::ArrayCompiled::from_file_owned(file)?)
    }
}
