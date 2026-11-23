//! The segment loop.
//!
//! A [`SolveSession`] holds what one run of an [`ArrayCompiled`] keeps from
//! its start to its end: the positional parameter vector, the current state,
//! the tape, the cadence partition with the hoisted static observeds, the
//! taped program's workspaces, and the solver statistics so far.
//! [`SolveSession::advance_to`] integrates from where the run stands to a
//! target time, one segment per stretch between refresh boundaries. Each
//! segment is a fresh diffsol problem ([`ArrayCompiled::run_one_segment`])
//! driven by the step loop ([`run_solver`]).
//!
//! [`crate::solve`] advances a session once, to the end of its span;
//! [`crate::Integrator`] advances one output-grid point per step.

use super::driver::{
    FdJvp, PerCellRhs, SolveProgram, SolveRhs, SolveSetup, SolveTape, Use, fault_error,
    fault_first, solution_metadata, xla_not_installed,
};
use super::*;
use crate::precision::{FLOAT32_RELTOL_FLOOR, Precision, StateScalar};
use crate::simulate::{
    Alg, Flow, Progress, ProgressFn, RawTrajectory, ReturnCode, SimulateError, Solution,
    SolutionMetadata, SolveOptions,
};
use diffsol::{
    Bdf, FaerLU, FaerMat, NewtonNonlinearSolver, OdeBuilder, OdeSolverMethod, Op, Sdirk, VectorHost,
};

/// What one run integrates: its span, the caller's bindings, and the
/// discrete-cadence forcing a refresh rewrites at each boundary.
pub(crate) struct RunSpec<'a> {
    pub(crate) tspan: (f64, f64),
    pub(crate) params: &'a HashMap<String, f64>,
    pub(crate) initial_conditions: &'a HashMap<String, f64>,
    /// The forcing names a refresh rewrites; empty when nothing refreshes.
    pub(crate) discrete_forcing: &'a HashSet<String>,
    /// The refresh times. Only those strictly inside the span are used.
    pub(crate) boundaries: &'a [f64],
    pub(crate) reltol_source: &'static str,
}

/// The forcing refresh a run drives: called once with the start of the run,
/// before the initial state is built, and then at each refresh boundary the
/// run reaches, before integrating past it.
pub(crate) type Refresh<'r> = dyn FnMut(f64) -> Result<(), SimulateError> + 'r;

/// One run of an [`ArrayCompiled`], advanced in pieces (see the module
/// documentation).
pub(crate) struct SolveSession<'c> {
    compiled: &'c ArrayCompiled,
    /// The run's options. Their `saveat` is not read: each advance names its
    /// own output grid.
    opts: SolveOptions,
    tspan: (f64, f64),
    precision: Option<Precision>,
    /// The refresh boundaries strictly inside `tspan`, ascending.
    boundaries: Vec<f64>,
    /// The first boundary not yet refreshed at.
    next_refresh: usize,
    param_vec: Vec<f64>,
    tape: SolveTape,
    setup: SolveSetup,
    /// The taped program under `native`, with its workspaces.
    program: Option<SolveProgram>,
    /// Where the state is known: the start of the run, or the last segment
    /// end an advance reached.
    t: f64,
    u: Vec<f64>,
    stats: SolveStats,
    retcode: ReturnCode,
}

impl ArrayCompiled {
    /// Run `run` to the end of its span in one advance, reporting at
    /// `opts.saveat` (or at the solver's own steps without one).
    pub(crate) fn solve_run(
        &self,
        run: &RunSpec<'_>,
        opts: &SolveOptions,
        inspect: Option<&mut BuildInspection>,
        refresh: &mut Refresh<'_>,
    ) -> Result<Solution, SimulateError> {
        // §5.5.5: the evaluators LATCH a fail-closed fault (an out-of-range
        // const-array gather, say) rather than raising, since the right-hand
        // side has no error channel. The run owns the latch from the initial
        // state to the assembled solution, which drains it, so a trajectory
        // built on such a fault fails loudly instead of carrying the `NaN` it
        // substituted.
        let faults = FaultScope::enter();
        let mut session = self.start_session(
            run,
            opts.clone(),
            opts.saveat.as_deref().unwrap_or(&[]),
            inspect,
            refresh,
        )?;
        let (time, state) =
            session.advance_to(run.tspan.1, opts.saveat.as_deref(), &faults, refresh)?;
        session.solution(&faults, time, state)
    }

    /// A session at the start of `run`, for a caller that advances it in
    /// pieces. A fault latched while building the initial state is reported
    /// here.
    pub(crate) fn open_session(
        &self,
        run: &RunSpec<'_>,
        opts: SolveOptions,
        grid: &[f64],
        refresh: &mut Refresh<'_>,
    ) -> Result<SolveSession<'_>, SimulateError> {
        let faults = FaultScope::enter();
        let session = self.start_session(run, opts, grid, None, refresh)?;
        match faults.finish() {
            Some(fault) => Err(fault_error(fault)),
            None => Ok(session),
        }
    }

    /// Everything a run pays for once: the parameter vector, the forcing at
    /// the start, the initial state, the tape, the cadence partition and the
    /// static hoist.
    fn start_session(
        &self,
        run: &RunSpec<'_>,
        opts: SolveOptions,
        grid: &[f64],
        inspect: Option<&mut BuildInspection>,
        refresh: &mut Refresh<'_>,
    ) -> Result<SolveSession<'_>, SimulateError> {
        let (t0, t_end) = run.tspan;
        // Validated here, where every array run starts, so the non-advancing
        // shortcut in `run_one_segment` and the solver path below it are never
        // handed a span they would read differently.
        reject_nonfinite_span(t0, t_end)?;
        let mut boundaries: Vec<f64> = Vec::new();
        for &b in run.boundaries {
            if b > t0 && b < t_end && boundaries.last().is_none_or(|&last| last < b) {
                boundaries.push(b);
            }
        }

        let precision = if t_end > t0 {
            self.integration_precision()?
        } else {
            None
        };
        if precision == Some(Precision::Float32) {
            let reltol = opts.reltol_or_default();
            if reltol < FLOAT32_RELTOL_FLOOR {
                return Err(SimulateError::ToleranceBelowWorkingPrecision {
                    source_name: run.reltol_source,
                    reltol,
                    floor: FLOAT32_RELTOL_FLOOR,
                });
            }
            check_float32_clock(t0, t_end, grid, &boundaries)?;
        }
        let param_vec = self.build_param_vec(run.params)?;

        // The forcing at t0 comes first: the static hoist reads it, and the
        // initial state's `ic` right-hand sides read the data-fed fields at t0
        // (esm-spec §11.4.2).
        refresh(t0)?;
        let no_exclusions = HashSet::new();
        let u = self.build_initial_state(
            run.initial_conditions,
            &param_vec,
            &IcStart {
                t0,
                at_t0: None,
                exclude: &no_exclusions,
            },
        )?;

        // The tape is built before the static hoist: under the strict
        // compilers the hoist is served from it.
        let tape = self.build_solve_tape(run.discrete_forcing)?;
        let cadence = self.partition_observed_cadence(run.discrete_forcing);
        let setup = self.hoist_static_observeds(cadence, &u, &param_vec, t0, tape.as_ref());
        let program = match (&tape, self.runtime_mode) {
            (Some(prog), RuntimeMode::Native) => Some(SolveProgram::new(self, prog)),
            _ => None,
        };
        if let Some(insp) = inspect {
            self.fill_solve_inspection(
                insp,
                &setup,
                &u,
                &param_vec,
                t0,
                !boundaries.is_empty(),
                tape.as_ref(),
            );
        }
        Ok(SolveSession {
            compiled: self,
            opts: SolveOptions {
                saveat: None,
                ..opts
            },
            tspan: run.tspan,
            precision,
            boundaries,
            next_refresh: 0,
            param_vec,
            tape,
            setup,
            program,
            t: t0,
            u,
            stats: SolveStats::default(),
            retcode: ReturnCode::Success,
        })
    }
}

impl SolveSession<'_> {
    /// The run's options (their `saveat` is not read).
    #[cfg(test)]
    pub(crate) fn options(&self) -> &SolveOptions {
        &self.opts
    }

    /// The state at the last point the run reached, in flat state-vector
    /// order.
    pub(crate) fn state(&self) -> &[f64] {
        &self.u
    }

    /// Why the run stopped, once it has.
    pub(crate) fn retcode(&self) -> ReturnCode {
        self.retcode
    }

    /// The run's metadata: the solver statistics summed over every segment
    /// integrated so far.
    pub(crate) fn metadata(&self) -> SolutionMetadata {
        let solver_name = match self.opts.alg {
            Alg::Bdf => "Bdf",
            Alg::Sdirk => "Sdirk",
            Alg::Erk => "Erk",
        };
        solution_metadata(
            solver_name,
            &self.stats,
            self.compiled.merged_renames.clone(),
            self.precision.map(|p| crate::IntegratorPrecision {
                state: p,
                time: p,
                norms: p,
                linear_algebra: p,
            }),
        )
    }

    /// Advance to `target`, reporting at the times of `saveat` this advance
    /// covers, and return the solution over those times, observed rows
    /// included. A fault latched on the way is reported here.
    pub(crate) fn advance(
        &mut self,
        target: f64,
        saveat: Option<&[f64]>,
        refresh: &mut Refresh<'_>,
    ) -> Result<Solution, SimulateError> {
        let faults = FaultScope::enter();
        let (time, state) = self.advance_to(target, saveat, &faults, refresh)?;
        self.solution(&faults, time, state)
    }

    /// Integrate from where the run stands to `target`, in segments split on
    /// the refresh boundaries in between, and return the trajectory at the
    /// times of `saveat` it covers (without a grid, the solver's own steps).
    ///
    /// The forcing is refreshed at the start of every segment that begins on
    /// a boundary. Each segment runs a fresh solver from the state the one
    /// before it ended at, so the adaptive controller restarts there, and
    /// always runs to its end, appended to the grid when absent, so that state
    /// is known. A segment that stops early ends the run; its reason becomes
    /// the run's return code.
    ///
    /// The first advance of a run that covers the whole span without
    /// crossing a boundary is one segment on the caller's grid as given.
    fn advance_to(
        &mut self,
        target: f64,
        saveat: Option<&[f64]>,
        faults: &FaultScope,
        refresh: &mut Refresh<'_>,
    ) -> Result<(Vec<f64>, Vec<Vec<f64>>), SimulateError> {
        let compiled = self.compiled;
        let n_states = compiled.n_states;
        let start = self.t;
        let (t0, t_end) = self.tspan;

        let mut endpoints: Vec<f64> = vec![start];
        for &b in &self.boundaries {
            if b > start && b < target && *endpoints.last().unwrap() < b {
                endpoints.push(b);
            }
        }
        if *endpoints.last().unwrap() < target {
            endpoints.push(target);
        }

        if start == t0 && target == t_end && endpoints.len() <= 2 {
            let opts = SolveOptions {
                saveat: saveat.map(<[f64]>::to_vec),
                ..self.opts.clone()
            };
            let (time, state, stats, retcode) = compiled
                .run_one_segment(
                    start,
                    target,
                    &self.u,
                    &self.param_vec,
                    &self.setup,
                    &opts,
                    self.program.as_ref(),
                    self.precision.unwrap_or_default(),
                )
                .map_err(|e| fault_first(faults, e))?;
            self.stats += stats;
            self.retcode = retcode;
            if retcode.is_success()
                && let Some(k) = time.len().checked_sub(1)
                && time[k] == target
            {
                self.t = target;
                self.u = state.iter().map(|row| row[k]).collect();
            }
            return Ok((time, state));
        }

        let mut time: Vec<f64> = Vec::new();
        let mut state: Vec<Vec<f64>> = vec![Vec::new(); n_states];
        for w in endpoints.windows(2) {
            let (a, b) = (w[0], w[1]);
            if self.boundaries.get(self.next_refresh) == Some(&a) {
                refresh(a)?;
                if let Some(p) = &self.program {
                    p.forcing_refreshed();
                }
                self.next_refresh += 1;
            }
            // Requested outputs in this segment: (a, b], or [a, b] for the
            // advance's first.
            let in_segment = |g: f64| (if a == start { g >= a } else { g > a }) && g <= b;
            let requested: Option<Vec<f64>> =
                saveat.map(|out| out.iter().copied().filter(|&g| in_segment(g)).collect());
            let grid = requested.as_ref().map(|requested| {
                let mut grid = requested.clone();
                if grid.last() != Some(&b) {
                    grid.push(b);
                }
                grid
            });
            // Progress against the run's span and step count, not the
            // segment's: each segment's solver counts its steps from zero.
            let progress: Option<ProgressFn> = self.opts.progress.as_ref().map(|user| {
                let user = user.clone();
                let steps_before = self.stats.n_accepted_steps;
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
                saveat: grid,
                progress,
                ..self.opts.clone()
            };
            let (seg_time, seg_state, seg_stats, seg_retcode) = compiled
                .run_one_segment(
                    a,
                    b,
                    &self.u,
                    &self.param_vec,
                    &self.setup,
                    &seg_opts,
                    self.program.as_ref(),
                    self.precision.unwrap_or_default(),
                )
                .map_err(|e| fault_first(faults, e))?;
            self.stats += seg_stats;
            if !seg_retcode.is_success() {
                self.retcode = seg_retcode;
            }
            // `run_solver` pushes the requested grid times verbatim and stops
            // its own step grid exactly at `b`, so float equality against
            // `requested` and `b` is exact.
            for (i, &t) in seg_time.iter().enumerate() {
                if t == b {
                    self.t = b;
                    self.u = seg_state.iter().map(|row| row[i]).collect();
                }
                let keep = match &requested {
                    Some(requested) => requested.contains(&t),
                    None => in_segment(t),
                };
                if keep {
                    time.push(t);
                    for (row, seg_row) in state.iter_mut().zip(&seg_state) {
                        row.push(seg_row[i]);
                    }
                }
            }
            if !self.retcode.is_success() {
                break;
            }
        }
        Ok((time, state))
    }

    pub(crate) fn output_time(&self, time: f64) -> f64 {
        self.precision.unwrap_or_default().round(time)
    }

    /// The solution over `time` and `state`, with the observed rows appended
    /// ([`ArrayCompiled::assemble_solution`], which drains the fault latch).
    fn solution(
        &self,
        faults: &FaultScope,
        mut time: Vec<f64>,
        state: Vec<Vec<f64>>,
    ) -> Result<Solution, SimulateError> {
        if self.precision == Some(Precision::Float32) && self.tspan.1 > self.tspan.0 {
            time.iter_mut().for_each(|t| *t = self.output_time(*t));
        }
        self.compiled.assemble_solution(
            faults,
            time,
            state,
            self.retcode,
            self.metadata(),
            &self.param_vec,
            &self.setup,
            &self.opts.output_observed,
            self.tape.as_ref(),
        )
    }
}

impl ArrayCompiled {
    fn integration_precision(&self) -> Result<Option<Precision>, SimulateError> {
        if !self.has_differential_equations() {
            return Ok(None);
        }
        let mut types = self
            .var_shapes
            .keys()
            .map(|name| self.precision.variable(name));
        let first = types.next().unwrap_or(self.precision.document);
        if types.any(|p| p != first) {
            return Err(float32_unsupported(
                "time integration of a state mixing Float32 and Float64 variables",
                "diffsol uses one scalar type for all state slots",
            ));
        }
        Ok(Some(first))
    }

    /// Integrate ONE segment `[t0, t_end]` from initial state `u0`, reading the
    /// live forcing buffer (`self.forcing`), which the session refreshes
    /// between segments. Builds a fresh RHS/Jacobian closure pair (each scratch
    /// pre-seeded with the already-materialized `static_obs`) and a fresh
    /// diffsol problem, returning the states at `opts.saveat`.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn run_one_segment(
        &self,
        t0: f64,
        t_end: f64,
        u0: &[f64],
        param_vec: &[f64],
        setup: &SolveSetup,
        opts: &SolveOptions,
        // The run's taped program under `native`, kept across segments.
        program: Option<&SolveProgram>,
        precision: Precision,
    ) -> Result<(Vec<f64>, Vec<Vec<f64>>, SolveStats, ReturnCode), SimulateError> {
        // A segment that never advances is answered from its own initial state,
        // before any closure, scratch buffer or diffsol problem is built
        // (issue #438): building the solver materializes a dense Jacobian,
        // which the matrix-free finite-difference Jacobian below pays for in
        // full right-hand-side evaluations, one per state column, each one
        // materializing every varying observed — recurrence sweeps included —
        // for a trajectory that is the untouched initial state. See
        // [`nonadvancing_trajectory`], which also makes the step-0 progress
        // report. [`run_solver`] keeps the same check as a backstop and
        // produces the identical trajectory, so this is a cost-only shortcut.
        if let Some((time, state, retcode)) = nonadvancing_trajectory(t0, t_end, u0, opts) {
            return Ok((time, state, SolveStats::default(), retcode));
        }
        // `xla` (API_SPEC §5.8): the right-hand side is the XLA executable the
        // build installed, and the Jacobian differences it too. A missing
        // executable is a refusal, never the tape answering under the name
        // `xla` (esm-libraries-spec §2.5.10).
        #[cfg(feature = "xla")]
        let xla_fault: Rc<RefCell<Option<String>>> = Rc::new(RefCell::new(None));
        let evaluator = match self.runtime_mode {
            RuntimeMode::Native => SolveRhs::Program {
                program: program.expect("a native solve builds its program"),
                forcing: &self.forcing,
            },
            RuntimeMode::Interpreter => SolveRhs::PerCell(Box::new(PerCellRhs {
                compiled: self,
                continuous_rules: &setup.cadence.continuous_rules,
                seed: self.segment_seed(
                    &setup.static_obs,
                    &setup.cadence.segment_static_rules,
                    u0,
                    param_vec,
                    t0,
                ),
                rhs: RefCell::new(None),
                jac: RefCell::new(None),
            })),
            #[cfg(feature = "xla")]
            RuntimeMode::Xla => SolveRhs::Xla {
                program: self.xla_program().ok_or_else(xla_not_installed)?,
                fault: Rc::clone(&xla_fault),
            },
            // A build without the feature answers `compiler_unavailable` for
            // `xla` before a backend exists; kept so the no-fallback property
            // holds by code rather than by that argument.
            #[cfg(not(feature = "xla"))]
            RuntimeMode::Xla => return Err(xla_not_installed()),
        };
        let solved = match precision {
            Precision::Float32 => integrate::<f32>(&evaluator, t0, t_end, u0, param_vec, opts),
            Precision::Float64 => integrate::<f64>(&evaluator, t0, t_end, u0, param_vec, opts),
        };
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
        solved
    }
}

type SolvedSegment = (Vec<f64>, Vec<Vec<f64>>, SolveStats, ReturnCode);

fn integrate<T: diffsol::FaerScalar + StateScalar>(
    evaluator: &SolveRhs<'_>,
    t0: f64,
    t_end: f64,
    u0: &[f64],
    param_vec: &[f64],
    opts: &SolveOptions,
) -> Result<SolvedSegment, SimulateError> {
    let n_states = u0.len();
    // diffsol's `rhs_implicit` builder demands a Jacobian closure even for
    // the explicit solver, which never calls it, so its buffers are built
    // on the first call.
    let jvp: RefCell<Option<FdJvp>> = RefCell::new(None);
    let rhs_output = RefCell::new(Vec::new());
    let jac_output = RefCell::new(Vec::new());
    let rhs_closure =
        |y: &diffsol::FaerVec<T>, _p: &diffsol::FaerVec<T>, t: T, dy: &mut diffsol::FaerVec<T>| {
            let y = T::widen_slice(y.as_slice());
            with_wide_output(dy.as_mut_slice(), &rhs_output, |out| {
                evaluator.eval(Use::Rhs, &y, param_vec, t.widen(), out);
            });
        };
    let jac_closure = |y: &diffsol::FaerVec<T>,
                       _p: &diffsol::FaerVec<T>,
                       t: T,
                       v: &diffsol::FaerVec<T>,
                       jv: &mut diffsol::FaerVec<T>| {
        let mut jvp = jvp.borrow_mut();
        with_wide_output(jv.as_mut_slice(), &jac_output, |out| {
            jvp.get_or_insert_with(|| FdJvp::with_precision(n_states, T::PRECISION))
                .apply(
                    &T::widen_slice(y.as_slice()),
                    param_vec,
                    t.widen(),
                    &T::widen_slice(v.as_slice()),
                    out,
                    |state, params, t, out| evaluator.eval(Use::Jacobian, state, params, t, out),
                );
        });
    };

    let builder = OdeBuilder::<FaerMat<T>>::new()
        .t0(t0)
        .rtol(opts.reltol_or_default())
        .atol(vec![opts.abstol_or_default(); n_states])
        .rhs_implicit(rhs_closure, jac_closure)
        .init(
            |_p: &diffsol::FaerVec<T>, _t: T, y: &mut diffsol::FaerVec<T>| {
                for (target, &value) in y.as_mut_slice().iter_mut().zip(u0) {
                    *target = T::narrow(value);
                }
            },
            n_states,
        );

    let problem = builder.build().map_err(|e| SimulateError::DiffsolError {
        details: e.to_string(),
    })?;

    let out = match opts.alg {
        Alg::Bdf => {
            let mut solver: Bdf<'_, _, NewtonNonlinearSolver<_, FaerLU<T>, _>> = problem
                .bdf::<FaerLU<T>>()
                .map_err(|e| SimulateError::DiffsolError {
                    details: e.to_string(),
                })?;
            let (time, state, retcode) = run_solver(&mut solver, t0, t_end, opts)?;
            let bs = solver.get_statistics();
            let stats = SolveStats::from_solver(
                &solver,
                bs.number_of_steps,
                bs.number_of_error_test_failures + bs.number_of_nonlinear_solver_fails,
            );
            (time, state, stats, retcode)
        }
        Alg::Sdirk => {
            let mut solver: Sdirk<'_, _, FaerLU<T>> =
                problem
                    .tr_bdf2::<FaerLU<T>>()
                    .map_err(|e| SimulateError::DiffsolError {
                        details: e.to_string(),
                    })?;
            let (time, state, retcode) = run_solver(&mut solver, t0, t_end, opts)?;
            let bs = solver.get_statistics();
            let stats = SolveStats::from_solver(
                &solver,
                bs.number_of_steps,
                bs.number_of_error_test_failures + bs.number_of_nonlinear_solver_fails,
            );
            (time, state, stats, retcode)
        }
        Alg::Erk => {
            let _seq = SequentialFaer::enter();
            let mut solver = problem.tsit45().map_err(|e| SimulateError::DiffsolError {
                details: e.to_string(),
            })?;
            let (time, state, retcode) = run_solver(&mut solver, t0, t_end, opts)?;
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
}

fn with_wide_output<T: StateScalar>(
    output: &mut [T],
    scratch: &RefCell<Vec<f64>>,
    fill: impl FnOnce(&mut [f64]),
) {
    if let Some(output) = T::as_f64_mut(output) {
        fill(output);
    } else {
        let mut scratch = scratch.borrow_mut();
        scratch.resize(output.len(), 0.0);
        fill(&mut scratch);
        for (target, &value) in output.iter_mut().zip(scratch.iter()) {
            *target = T::narrow(value);
        }
    }
}

fn float32_unsupported(construct: &str, reason: &str) -> SimulateError {
    crate::compile_error::CompileError::Float32Unsupported {
        construct: construct.to_owned(),
        reason: reason.to_owned(),
    }
    .into()
}

fn check_float32_clock(
    start: f64,
    end: f64,
    grid: &[f64],
    boundaries: &[f64],
) -> Result<(), SimulateError> {
    // Provider refreshes and requested samples must stay ordered on the
    // solver clock. An exact shared boundary needs just one clock tick.
    let mut times: Vec<_> = grid
        .iter()
        .copied()
        .filter(|t| *t >= start && *t <= end)
        .collect();
    if times.windows(2).any(|w| w[0] as f32 == w[1] as f32) {
        return Err(float32_unsupported(
            "binary32 clock over tspan",
            "consecutive output times coincide in binary32",
        ));
    }
    times.extend_from_slice(boundaries);
    times.extend([start, end]);
    times.sort_by(f64::total_cmp);
    times.dedup();
    if times.iter().any(|&t| !(t as f32).is_finite())
        || times.windows(2).any(|w| w[0] as f32 == w[1] as f32)
    {
        return Err(float32_unsupported(
            "binary32 clock over tspan",
            "distinct times must remain finite and distinct in binary32",
        ));
    }
    Ok(())
}

// ============================================================================
// The diffsol step loop
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
fn reject_nonfinite_span(t0: f64, t_end: f64) -> Result<(), SimulateError> {
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
fn nonadvancing_trajectory(
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
#[derive(Debug, Clone, Default)]
pub(crate) struct SolveStats {
    pub n_rhs_calls: usize,
    pub n_jacobian_calls: usize,
    pub n_accepted_steps: usize,
    pub n_rejected_steps: usize,
}

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
        Eqn: diffsol::OdeEquations + 'a,
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

impl std::ops::AddAssign for SolveStats {
    fn add_assign(&mut self, rhs: Self) {
        self.n_rhs_calls += rhs.n_rhs_calls;
        self.n_jacobian_calls += rhs.n_jacobian_calls;
        self.n_accepted_steps += rhs.n_accepted_steps;
        self.n_rejected_steps += rhs.n_rejected_steps;
    }
}

/// faer's process-wide parallelism held at sequential while an explicit solve
/// runs (restored when the last one ends).
///
/// diffsol's Runge-Kutta step combines its stages with faer matrix-vector
/// products over an `n x stages` matrix, and faer reads its parallelism from
/// a process-wide setting whose default is every rayon thread. From about
/// 10^4 states its threaded column-major product gives each thread a
/// temporary `n`-vector to clear, fill and sum back serially, which costs
/// several times the product itself, more the more threads there are, and
/// makes the step's rounding depend on the thread count. Sequential is one
/// pass, the same at any thread count. The right-hand side threads on its own
/// pool (`simulate_array::tape::exec::par`). Implicit solves keep faer's
/// setting: their dense factorizations are what its threads are for.
struct SequentialFaer(());

static SEQUENTIAL_FAER: std::sync::Mutex<(usize, Option<faer::Par>)> =
    std::sync::Mutex::new((0, None));

impl SequentialFaer {
    fn enter() -> Self {
        let mut held = SEQUENTIAL_FAER.lock().unwrap_or_else(|e| e.into_inner());
        if held.0 == 0 {
            held.1 = Some(faer::get_global_parallelism());
            faer::set_global_parallelism(faer::Par::Seq);
        }
        held.0 += 1;
        SequentialFaer(())
    }
}

impl Drop for SequentialFaer {
    fn drop(&mut self) {
        let mut held = SEQUENTIAL_FAER.lock().unwrap_or_else(|e| e.into_inner());
        held.0 -= 1;
        if held.0 == 0
            && let Some(par) = held.1.take()
        {
            faer::set_global_parallelism(par);
        }
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
fn run_solver<'a, S, Eqn, T>(
    solver: &mut S,
    t0: f64,
    t_end: f64,
    opts: &SolveOptions,
) -> Result<RawTrajectory, SimulateError>
where
    S: OdeSolverMethod<'a, Eqn>,
    T: diffsol::FaerScalar + StateScalar,
    Eqn: diffsol::OdeEquations<T = T, V = diffsol::FaerVec<T>>,
    Eqn: 'a,
{
    use diffsol::{DiffsolError, OdeSolverStopReason, error::OdeSolverError};

    let start = solver.state().t;
    let end = T::narrow(t_end);
    let n_states = solver.state().y.as_slice().len();
    let initial_state: Vec<f64> = T::widen_slice(solver.state().y.as_slice()).into_owned();

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

    let clock_error = |reason| float32_unsupported("binary32 clock over tspan", reason);
    solver.set_stop_time(end).map_err(|e| match e {
        DiffsolError::OdeSolverError(OdeSolverError::StopTimeAtCurrentTime)
            if T::PRECISION.is_f32() =>
        {
            clock_error("the segment is shorter than diffsol's clock resolution")
        }
        _ => SimulateError::DiffsolError {
            details: e.to_string(),
        },
    })?;

    let mut previous_time = start;
    let mut step = |solver: &mut S| -> Result<(T, bool), SimulateError> {
        let stop = solver.step().map_err(|e| SimulateError::DiffsolError {
            details: e.to_string(),
        })?;
        let time = solver.state().t;
        let at_stop = matches!(stop, OdeSolverStopReason::TstopReached);
        if T::PRECISION.is_f32() {
            if time <= previous_time {
                return Err(clock_error("an accepted step did not advance the clock"));
            }
            if at_stop && time < end {
                return Err(clock_error(
                    "diffsol stopped before the segment's final clock tick",
                ));
            }
        }
        previous_time = time;
        Ok((time, at_stop))
    };

    let mut step_count = 0;
    if let Some(t_eval) = &opts.saveat {
        // Cursor into the user's evaluation grid. Each step we drain any
        // requested times that now lie inside the solver's [t_prev, t_curr]
        // window.
        let mut next_idx: usize = 0;

        // Handle requested times at or before t0 directly from the initial
        // state — interpolating at t0 on a solver that has not stepped yet
        // is undefined behaviour for some methods.
        while next_idx < t_eval.len() && T::narrow(t_eval[next_idx]) <= start {
            push_state(
                &mut times,
                &mut state_rows,
                t_eval[next_idx],
                &initial_state,
            );
            next_idx += 1;
        }

        loop {
            if next_idx >= t_eval.len() {
                break;
            }
            if opts.maxiters.is_some_and(|cap| step_count >= cap) {
                retcode = ReturnCode::MaxIters;
                break;
            }
            let (t_curr, at_stop) = step(solver)?;
            step_count += 1;
            let y_now = T::widen_slice(solver.state().y.as_slice()).into_owned();
            if !y_now.iter().all(|v| v.is_finite()) {
                retcode = ReturnCode::Unstable;
                break;
            }
            if matches!(report(step_count, t_curr.widen(), &y_now), Flow::Cancel) {
                retcode = ReturnCode::Terminated;
                break;
            }

            // Drain user grid points inside (t_prev, t_curr].
            while next_idx < t_eval.len()
                && t_eval[next_idx] <= t_end
                && T::narrow(t_eval[next_idx]) <= t_curr
            {
                let t = t_eval[next_idx];
                let y =
                    solver
                        .interpolate(T::narrow(t))
                        .map_err(|e| SimulateError::DiffsolError {
                            details: e.to_string(),
                        })?;
                let y_s = T::widen_slice(y.as_slice());
                push_state(&mut times, &mut state_rows, t, &y_s);
                next_idx += 1;
            }

            if at_stop {
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
    } else {
        // Native step grid: record the initial point, then every step.
        push_state(&mut times, &mut state_rows, t0, &initial_state);
        loop {
            if opts.maxiters.is_some_and(|cap| step_count >= cap) {
                retcode = ReturnCode::MaxIters;
                break;
            }
            let (t_curr, at_stop) = step(solver)?;
            step_count += 1;
            let y_owned: Vec<f64> = T::widen_slice(solver.state().y.as_slice()).into_owned();
            if !y_owned.iter().all(|v| v.is_finite()) {
                retcode = ReturnCode::Unstable;
                break;
            }
            if T::PRECISION.is_f32() && at_stop {
                // The session uses logical segment boundaries internally.
                // Round them for callers only after collecting the segments.
                if t_curr == end {
                    push_state(&mut times, &mut state_rows, t_end, &y_owned);
                } else {
                    let y = solver
                        .interpolate(end)
                        .map_err(|e| SimulateError::DiffsolError {
                            details: e.to_string(),
                        })?;
                    push_state(
                        &mut times,
                        &mut state_rows,
                        t_end,
                        &T::widen_slice(y.as_slice()),
                    );
                }
            } else {
                push_state(&mut times, &mut state_rows, t_curr.widen(), &y_owned);
            }
            if matches!(report(step_count, t_curr.widen(), &y_owned), Flow::Cancel) {
                retcode = ReturnCode::Terminated;
                break;
            }
            if at_stop {
                break;
            }
        }
    }

    Ok((times, state_rows, retcode))
}
