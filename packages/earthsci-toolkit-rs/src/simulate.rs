//! Native ODE simulation via [`diffsol`] (gt-5ws, v1).
//!
//! This module provides a *correctness-first* simulation API for the Rust
//! Core tier. It consumes a [`FlattenedSystem`] (the canonical output of
//! [`crate::flatten`]) and runs it through diffsol's BDF / SDIRK / explicit
//! Runge-Kutta solvers.
//!
//! ## Scope
//!
//! - **ODE only.** [`FlattenedSystem::independent_variables`] must equal `["t"]`.
//!   Hybrid PDE / spatial systems return [`CompileError::UnsupportedDimensionalityError`].
//! - **No event handling.** Models with non-empty `continuous_events` /
//!   `discrete_events` return [`CompileError::UnsupportedFeatureError`].
//! - **Both targets.** diffsol's Faer backend is pure Rust and cross-compiles to
//!   wasm32 (spike S1), so this module is compiled for the browser too. The one
//!   native-only seam is the dispatch into [`crate::simulate_array`] for
//!   array-op / spatial files, which is `cfg`-gated off wasm.
//!
//! ## Usage
//!
//! ```no_run
//! use earthsci_toolkit::{load, simulate, SimulateOptions};
//! use std::collections::HashMap;
//!
//! let file = load(r#"{"esm":"0.1.0","metadata":{},"models":{}}"#).unwrap();
//! let params = HashMap::new();
//! let ic = HashMap::new();
//! let opts = SimulateOptions::default();
//! let _ = simulate(&file, (0.0, 1.0), &params, &ic, &opts);
//! ```

use crate::flatten::{FlattenedSystem, flatten, flatten_model};
use crate::types::{EsmFile, Expr, Model};
use std::collections::{HashMap, HashSet};
use thiserror::Error;

use diffsol::{
    Bdf, FaerLU, FaerMat, NewtonNonlinearSolver, OdeBuilder, OdeSolverMethod, Sdirk, VectorHost,
};

// ============================================================================
// Errors
// ============================================================================

// `CompileError` is defined in the non-gated `crate::compile_error` module so
// the WASM-compiled `aggregate` / `join` passes can name it; re-exported here
// to preserve the native `crate::simulate::CompileError` path.
pub use crate::compile_error::CompileError;

/// Errors raised when running [`Compiled::simulate`] or the convenience
/// [`simulate`] free function.
#[derive(Error, Debug)]
pub enum SimulateError {
    /// Wraps a CompileError raised by the convenience [`simulate`] function
    /// before solving even starts.
    #[error("Compile failed: {0}")]
    Compile(#[from] CompileError),

    /// diffsol returned a solver-internal error (build failure, step failure,
    /// etc.).
    #[error("diffsol error: {details}")]
    DiffsolError {
        /// The underlying diffsol error message.
        details: String,
    },

    /// The integrator could not satisfy the requested tolerances.
    #[error("Tolerance not met")]
    ToleranceNotMet,

    /// The integrator hit the configured `max_steps` cap before reaching the
    /// end of the integration interval.
    #[error("Maximum steps ({max_steps}) exceeded")]
    MaxStepsExceeded {
        /// The configured cap.
        max_steps: usize,
    },

    /// The user supplied a parameter name that does not appear in the
    /// flattened system.
    #[error("Invalid parameter '{name}'")]
    InvalidParameter {
        /// The unknown parameter name.
        name: String,
    },

    /// The user supplied an initial condition for a name that is not a state
    /// variable, or a state variable has no initial value (no entry in
    /// `initial_conditions` and no `default` on the `ModelVariable`).
    #[error("Invalid initial condition '{name}'")]
    InvalidInitialCondition {
        /// The variable name.
        name: String,
    },

    /// An `ic(target)` field initial condition could not be resolved to a
    /// per-cell value. Carries the `ic(...)` target state name plus a
    /// diagnostic saying why (wrong field rank, unresolvable RHS, ...), so
    /// the name field stays a plain identifier.
    #[error("Invalid field initial condition for '{name}': {details}")]
    InvalidFieldInitialCondition {
        /// The `ic(...)` target state name.
        name: String,
        /// Why the initial condition could not be resolved.
        details: String,
    },
}

// ============================================================================
// Public API surface (per gt-5ws design)
// ============================================================================

/// Which solver family to use inside diffsol.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SolverChoice {
    /// Backward Differentiation Formulas — implicit, default for stiff ODEs.
    Bdf,
    /// Singly Diagonally Implicit Runge-Kutta (TR-BDF2 tableau) — implicit,
    /// alternative stiff solver.
    Sdirk,
    /// Explicit Runge-Kutta (Tsitouras 5(4)) — non-stiff.
    Erk,
}

/// Tunable options for [`Compiled::simulate`] / [`simulate`].
#[derive(Debug, Clone)]
pub struct SimulateOptions {
    /// Which solver family to use. Defaults to [`SolverChoice::Bdf`].
    pub solver: SolverChoice,
    /// Absolute tolerance. Defaults to `1e-8`.
    pub abstol: f64,
    /// Relative tolerance. Defaults to `1e-6`.
    pub reltol: f64,
    /// Maximum number of integrator steps before bailing out. Defaults to `10_000`.
    pub max_steps: usize,
    /// If `Some`, the solution is sampled (via dense output / interpolation)
    /// at exactly these times. If `None`, the natural step times are
    /// returned.
    pub output_times: Option<Vec<f64>>,
}

impl Default for SimulateOptions {
    fn default() -> Self {
        Self {
            solver: SolverChoice::Bdf,
            abstol: 1e-8,
            reltol: 1e-6,
            max_steps: 10_000,
            output_times: None,
        }
    }
}

/// A simulation result.
///
/// `state[i][k]` is the value of state variable `state_variable_names[i]` at
/// time `time[k]`.
#[derive(Debug, Clone)]
pub struct Solution {
    /// Output time grid.
    pub time: Vec<f64>,
    /// State trajectories, indexed `[variable_index][time_index]`.
    pub state: Vec<Vec<f64>>,
    /// Names of the state variables, parallel to the rows of `state`.
    pub state_variable_names: Vec<String>,
    /// Solver provenance and step counts.
    pub metadata: SolutionMetadata,
}

/// Provenance metadata for a [`Solution`].
#[derive(Debug, Clone, Default)]
pub struct SolutionMetadata {
    /// Solver name (e.g. `"Bdf"`, `"Sdirk"`, `"Erk"`).
    pub solver: String,
    /// Number of RHS function evaluations performed (best-effort, may be
    /// zero in v1 if diffsol does not expose it).
    pub n_rhs_calls: usize,
    /// Number of Jacobian evaluations performed (best-effort).
    pub n_jacobian_calls: usize,
    /// Number of accepted integrator steps (best-effort).
    pub n_accepted_steps: usize,
    /// Number of rejected integrator steps (best-effort).
    pub n_rejected_steps: usize,
}

// ============================================================================
// Compiled model: pre-resolved expression interpreter
// ============================================================================

/// A compiled, parameter-sweep-ready ODE model.
///
/// Built once via [`Compiled::from_flattened`] / [`Compiled::from_model`] /
/// [`Compiled::from_file`], then reused across many [`Compiled::simulate`]
/// calls with different parameters and initial conditions.
#[derive(Debug, Clone)]
pub struct Compiled {
    state_names: Vec<String>,
    state_index: HashMap<String, usize>,
    state_defaults: Vec<Option<f64>>,
    param_names: Vec<String>,
    param_index: HashMap<String, usize>,
    param_defaults: Vec<Option<f64>>,
    /// Observed variable names in topological order (each obs only references
    /// state, params, time, or earlier-indexed observed variables).
    observed_names: Vec<String>,
    /// Defining expressions for observed variables, parallel to
    /// `observed_names`.
    observed_exprs: Vec<ResolvedExpr>,
    /// Per-state classification + defining expression. A `Differential` entry
    /// carries the RHS for `D(state, t) = ...`; an `Algebraic` entry carries
    /// the value expression for `state = ...` (treated as the scalar
    /// equivalent of MTK's `structural_simplify` — esm-0kt).
    state_kinds: Vec<StateKind>,
    /// State indices that are algebraic, in dependency-respecting order. Each
    /// algebraic state's expression may reference differential states,
    /// parameters, time, observed variables, or *earlier-listed* algebraic
    /// states. Cycles are rejected at compile time.
    algebraic_topo: Vec<usize>,
}

/// Internal classification of how a state variable is defined.
#[derive(Debug, Clone)]
enum StateKind {
    /// `D(state, t) = rhs` — advanced by the integrator.
    Differential(ResolvedExpr),
    /// `state = rhs` — value reconstructed from `rhs` at every evaluation;
    /// the integrator's derivative for this slot is held at zero.
    Algebraic(ResolvedExpr),
}

impl Compiled {
    /// Build from a [`FlattenedSystem`] (the spec-compliant flattening output).
    ///
    /// The build runs as a sequence of named phases: v1 scope guards
    /// ([`reject_unsupported_features`]), equation classification
    /// ([`classify_equations`]), observed-variable topo-sort + resolution
    /// ([`resolve_observed`]), algebraic-state topo-sort
    /// ([`order_algebraic_states`], esm-0kt), and per-state lowering
    /// ([`build_state_kinds`]).
    pub fn from_flattened(flat: &FlattenedSystem) -> Result<Self, CompileError> {
        // (1) Reject hybrid dimensionality and events (v1 scope).
        reject_unsupported_features(flat)?;

        // (2) Build name -> index tables for state, params, observed.
        let state_names: Vec<String> = flat.state_variables.keys().cloned().collect();
        let state_index = build_index_map(&state_names);
        let state_defaults: Vec<Option<f64>> =
            flat.state_variables.values().map(|mv| mv.default).collect();

        let param_names: Vec<String> = flat.parameters.keys().cloned().collect();
        let param_index = build_index_map(&param_names);
        let param_defaults: Vec<Option<f64>> =
            flat.parameters.values().map(|mv| mv.default).collect();

        let observed_names_raw: Vec<String> = flat.observed_variables.keys().cloned().collect();
        let observed_index_raw = build_index_map(&observed_names_raw);

        // (3) Classify equations into differential / algebraic / observed
        // defining expressions.
        let ClassifiedEquations {
            state_diff_raw,
            state_alg_raw,
            observed_rhs_raw,
        } = classify_equations(flat, &state_names, &state_index, &observed_index_raw)?;

        // (4) Topologically sort observed variables and resolve their
        // expressions to typed indices.
        let (observed_names, observed_index, observed_exprs) = resolve_observed(
            &observed_names_raw,
            &observed_index_raw,
            &observed_rhs_raw,
            &state_index,
            &param_index,
        )?;

        // (5) Topologically sort algebraic states (esm-0kt).
        let algebraic_topo = order_algebraic_states(&state_names, &state_index, &state_alg_raw)?;

        // (6) Build per-state classification + resolved expression.
        let state_kinds = build_state_kinds(
            &state_diff_raw,
            &state_alg_raw,
            &state_index,
            &param_index,
            &observed_index,
        )?;

        Ok(Self {
            state_names,
            state_index,
            state_defaults,
            param_names,
            param_index,
            param_defaults,
            observed_names,
            observed_exprs,
            state_kinds,
            algebraic_topo,
        })
    }

    /// Convenience: flatten the model first, then build.
    pub fn from_model(model: &Model) -> Result<Self, CompileError> {
        let flat = flatten_model(model)?;
        Self::from_flattened(&flat)
    }

    /// Convenience: flatten the file first, then build.
    pub fn from_file(file: &EsmFile) -> Result<Self, CompileError> {
        let flat = flatten(file)?;
        Self::from_flattened(&flat)
    }

    /// State variable names in fixed order. Index `i` corresponds to row `i`
    /// of [`Solution::state`].
    pub fn state_variable_names(&self) -> &[String] {
        &self.state_names
    }

    /// Parameter names in fixed order. Match these against the keys of the
    /// `params` HashMap passed to [`Self::simulate`].
    pub fn parameter_names(&self) -> &[String] {
        &self.param_names
    }

    /// Observed variable names in topological-evaluation order.
    pub fn observed_variable_names(&self) -> &[String] {
        &self.observed_names
    }

    /// Run the simulation.
    ///
    /// Phases, each a named private method below: input validation + vector
    /// assembly ([`Self::build_param_vec`] / [`Self::build_initial_state`]),
    /// algebraic IC consistency ([`Self::apply_algebraic_ics`], esm-0kt),
    /// problem build + solver dispatch ([`Self::integrate`]), and
    /// algebraic-trajectory output reconstruction
    /// ([`Self::reconstruct_algebraic_trajectory`]).
    pub fn simulate(
        &self,
        tspan: (f64, f64),
        params: &HashMap<String, f64>,
        initial_conditions: &HashMap<String, f64>,
        opts: &SimulateOptions,
    ) -> Result<Solution, SimulateError> {
        let (t0, t_end) = tspan;

        let param_vec = self.build_param_vec(params)?;
        let mut ic_vec = self.build_initial_state(initial_conditions)?;
        self.apply_algebraic_ics(&mut ic_vec, &param_vec, t0);

        let (time, mut state) = self.integrate(t0, t_end, &param_vec, &ic_vec, opts)?;
        self.reconstruct_algebraic_trajectory(&time, &mut state, &param_vec);

        Ok(Solution {
            time,
            state,
            state_variable_names: self.state_names.clone(),
            metadata: SolutionMetadata {
                solver: solver_name(opts.solver).to_string(),
                ..Default::default()
            },
        })
    }

    /// Validate user-supplied parameters (every key must be a known param)
    /// and build the parameter vector in canonical order: user value >
    /// declared default; a parameter with neither is an error.
    fn build_param_vec(&self, params: &HashMap<String, f64>) -> Result<Vec<f64>, SimulateError> {
        for key in params.keys() {
            if !self.param_index.contains_key(key) {
                return Err(SimulateError::InvalidParameter { name: key.clone() });
            }
        }
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

    /// Validate user-supplied initial conditions (every key must be a state
    /// variable) and build the initial state vector: user value > declared
    /// default; a state with neither is an error.
    fn build_initial_state(
        &self,
        initial_conditions: &HashMap<String, f64>,
    ) -> Result<Vec<f64>, SimulateError> {
        for key in initial_conditions.keys() {
            if !self.state_index.contains_key(key) {
                return Err(SimulateError::InvalidInitialCondition { name: key.clone() });
            }
        }
        let mut ic_vec = vec![0.0f64; self.state_names.len()];
        for (i, name) in self.state_names.iter().enumerate() {
            if let Some(&v) = initial_conditions.get(name) {
                ic_vec[i] = v;
            } else if let Some(d) = self.state_defaults[i] {
                ic_vec[i] = d;
            } else {
                return Err(SimulateError::InvalidInitialCondition { name: name.clone() });
            }
        }
        Ok(ic_vec)
    }

    /// Apply algebraic constraints to the initial-condition vector so that
    /// y0[i] for an algebraic state is consistent with its defining body
    /// — otherwise users must hand-tune defaults to satisfy the algebraic
    /// equations at t = t0 (esm-0kt).
    fn apply_algebraic_ics(&self, ic_vec: &mut [f64], param_vec: &[f64], t0: f64) {
        let n_obs0 = self.observed_exprs.len();
        let mut obs_buf = vec![0.0f64; n_obs0];
        for (i, e) in self.observed_exprs.iter().enumerate() {
            obs_buf[i] = interpret(e, ic_vec, param_vec, &obs_buf, t0);
        }
        for &idx in &self.algebraic_topo {
            if let StateKind::Algebraic(expr) = &self.state_kinds[idx] {
                ic_vec[idx] = interpret(expr, ic_vec, param_vec, &obs_buf, t0);
            }
        }
    }

    /// Build the RHS closure: y is current state, p is param vector, t is
    /// time, dy is the derivative output. Captures owned clones of the
    /// compiled expressions so the closure is `'static`.
    ///
    /// For models with algebraic states (esm-0kt), the integrator is not
    /// free to wander the algebraic-state slots: dy[idx] must be zero AND
    /// y[idx] must be reconstructed from the algebraic body before the
    /// differential RHS reads it. We work in a local copy of y so the
    /// integrator's own state vector is untouched.
    fn make_rhs_closure(
        &self,
    ) -> impl Fn(&diffsol::FaerVec<f64>, &diffsol::FaerVec<f64>, f64, &mut diffsol::FaerVec<f64>) + use<>
    {
        let state_kinds = self.state_kinds.clone();
        let observed_exprs = self.observed_exprs.clone();
        let algebraic_topo = self.algebraic_topo.clone();
        let n_obs = observed_exprs.len();

        move |y: &diffsol::FaerVec<f64>,
              p: &diffsol::FaerVec<f64>,
              t: f64,
              dy: &mut diffsol::FaerVec<f64>| {
            let p_s = p.as_slice();
            let mut obs_buf = vec![0.0f64; n_obs];
            // Only the algebraic reconstruction below mutates the state the
            // differential RHS reads. With no algebraic variables there is
            // nothing to reconstruct, so read the integrator's state slice
            // directly and skip the gratuitous full-state copy every step.
            let mut y_owned: Vec<f64>;
            let y_eff: &[f64] = if algebraic_topo.is_empty() {
                for (i, e) in observed_exprs.iter().enumerate() {
                    obs_buf[i] = interpret(e, y.as_slice(), p_s, &obs_buf, t);
                }
                y.as_slice()
            } else {
                y_owned = y.as_slice().to_vec();
                for (i, e) in observed_exprs.iter().enumerate() {
                    obs_buf[i] = interpret(e, &y_owned, p_s, &obs_buf, t);
                }
                for &idx in &algebraic_topo {
                    if let StateKind::Algebraic(expr) = &state_kinds[idx] {
                        y_owned[idx] = interpret(expr, &y_owned, p_s, &obs_buf, t);
                    }
                }
                &y_owned
            };
            let dy_s = dy.as_mut_slice();
            for (i, kind) in state_kinds.iter().enumerate() {
                match kind {
                    StateKind::Differential(expr) => {
                        dy_s[i] = interpret(expr, y_eff, p_s, &obs_buf, t);
                    }
                    StateKind::Algebraic(_) => {
                        dy_s[i] = 0.0;
                    }
                }
            }
        }
    }

    /// Build the Jacobian-vector product closure (finite differences).
    /// Algebraic slots in `y` are reconstructed from the algebraic body
    /// before the differential RHS is evaluated, on both the unperturbed and
    /// perturbed states, so the resulting Jacobian column reflects the
    /// total derivative through any chained algebraic substitutions.
    fn make_jac_closure(
        &self,
    ) -> impl Fn(
        &diffsol::FaerVec<f64>,
        &diffsol::FaerVec<f64>,
        f64,
        &diffsol::FaerVec<f64>,
        &mut diffsol::FaerVec<f64>,
    ) + use<> {
        let state_kinds_jac = self.state_kinds.clone();
        let observed_exprs_jac = self.observed_exprs.clone();
        let algebraic_topo_jac = self.algebraic_topo.clone();
        let n_obs = observed_exprs_jac.len();

        move |y: &diffsol::FaerVec<f64>,
              p: &diffsol::FaerVec<f64>,
              t: f64,
              v: &diffsol::FaerVec<f64>,
              jv: &mut diffsol::FaerVec<f64>| {
            let n = y.as_slice().len();
            let v_s = v.as_slice();
            let p_s = p.as_slice();
            let y_s = y.as_slice();

            // Choose step proportional to ||y|| as is conventional for forward
            // finite differences. Bound below to avoid catastrophic cancellation.
            let mut y_norm = 0.0f64;
            for &yi in y_s {
                y_norm += yi * yi;
            }
            let y_norm = y_norm.sqrt().max(1.0);
            let eps = (f64::EPSILON.sqrt()) * y_norm;

            let mut y_a: Vec<f64> = y_s.to_vec();
            let mut y_b: Vec<f64> = vec![0.0f64; n];
            for i in 0..n {
                y_b[i] = y_s[i] + eps * v_s[i];
            }

            let mut obs_a = vec![0.0f64; n_obs];
            let mut obs_b = vec![0.0f64; n_obs];
            for (i, e) in observed_exprs_jac.iter().enumerate() {
                obs_a[i] = interpret(e, &y_a, p_s, &obs_a, t);
            }
            for (i, e) in observed_exprs_jac.iter().enumerate() {
                obs_b[i] = interpret(e, &y_b, p_s, &obs_b, t);
            }
            for &idx in &algebraic_topo_jac {
                if let StateKind::Algebraic(expr) = &state_kinds_jac[idx] {
                    y_a[idx] = interpret(expr, &y_a, p_s, &obs_a, t);
                    y_b[idx] = interpret(expr, &y_b, p_s, &obs_b, t);
                }
            }
            let jv_s = jv.as_mut_slice();
            for (i, kind) in state_kinds_jac.iter().enumerate() {
                match kind {
                    StateKind::Differential(expr) => {
                        let f_y = interpret(expr, &y_a, p_s, &obs_a, t);
                        let f_yp = interpret(expr, &y_b, p_s, &obs_b, t);
                        jv_s[i] = (f_yp - f_y) / eps;
                    }
                    StateKind::Algebraic(_) => {
                        jv_s[i] = 0.0;
                    }
                }
            }
        }
    }

    /// Assemble the diffsol [`OdeBuilder`] problem (RHS + Jacobian closures,
    /// tolerances, initial state) and dispatch to the configured solver
    /// family, returning the raw `(time, state_rows)` trajectory from
    /// [`run_solver`].
    fn integrate(
        &self,
        t0: f64,
        t_end: f64,
        param_vec: &[f64],
        ic_vec: &[f64],
        opts: &SimulateOptions,
    ) -> Result<(Vec<f64>, Vec<Vec<f64>>), SimulateError> {
        let n_states = self.state_names.len();
        let rhs_closure = self.make_rhs_closure();
        let jac_closure = self.make_jac_closure();

        // ----- Build the OdeBuilder -----
        let abstol = opts.abstol;
        let reltol = opts.reltol;
        let ic_for_init = ic_vec.to_vec();

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

        // ----- Solver dispatch -----
        let trajectory = match opts.solver {
            SolverChoice::Bdf => {
                let mut solver: Bdf<'_, _, NewtonNonlinearSolver<_, FaerLU<f64>, _>> = problem
                    .bdf::<FaerLU<f64>>()
                    .map_err(|e| SimulateError::DiffsolError {
                        details: e.to_string(),
                    })?;
                run_solver(&mut solver, t_end, opts)?
            }
            SolverChoice::Sdirk => {
                let mut solver: Sdirk<'_, _, FaerLU<f64>> = problem
                    .tr_bdf2::<FaerLU<f64>>()
                    .map_err(|e| SimulateError::DiffsolError {
                        details: e.to_string(),
                    })?;
                run_solver(&mut solver, t_end, opts)?
            }
            SolverChoice::Erk => {
                let mut solver = problem.tsit45().map_err(|e| SimulateError::DiffsolError {
                    details: e.to_string(),
                })?;
                run_solver(&mut solver, t_end, opts)?
            }
        };
        Ok(trajectory)
    }

    /// Reconstruct algebraic-state values along the output trajectory
    /// (esm-0kt). The integrator carries the algebraic slots forward
    /// without advancing them, so the natural state matrix shows the
    /// algebraic IC at every sample. Recompute from the differential
    /// states + parameters at each output time. No-op for a system without
    /// algebraic states.
    fn reconstruct_algebraic_trajectory(
        &self,
        time: &[f64],
        state: &mut [Vec<f64>],
        param_vec: &[f64],
    ) {
        if self.algebraic_topo.is_empty() || time.is_empty() {
            return;
        }
        let n_obs0 = self.observed_exprs.len();
        let n_states = self.state_names.len();
        let mut y_eff = vec![0.0f64; n_states];
        let mut obs_buf = vec![0.0f64; n_obs0];
        for (k, &t) in time.iter().enumerate() {
            for i in 0..n_states {
                y_eff[i] = state[i][k];
            }
            for (i, e) in self.observed_exprs.iter().enumerate() {
                obs_buf[i] = interpret(e, &y_eff, param_vec, &obs_buf, t);
            }
            for &idx in &self.algebraic_topo {
                if let StateKind::Algebraic(expr) = &self.state_kinds[idx] {
                    let v = interpret(expr, &y_eff, param_vec, &obs_buf, t);
                    y_eff[idx] = v;
                    state[idx][k] = v;
                }
            }
        }
    }
}

/// Human-readable solver-family name recorded in [`SolutionMetadata::solver`].
fn solver_name(choice: SolverChoice) -> &'static str {
    match choice {
        SolverChoice::Bdf => "Bdf",
        SolverChoice::Sdirk => "Sdirk",
        SolverChoice::Erk => "Erk",
    }
}

// ============================================================================
// from_flattened build phases
// ============================================================================

/// v1 scope guards for [`Compiled::from_flattened`]: only pure `t`-dimensional
/// ODE systems with no continuous or discrete events are supported.
fn reject_unsupported_features(flat: &FlattenedSystem) -> Result<(), CompileError> {
    if flat.independent_variables != ["t"] {
        return Err(CompileError::UnsupportedDimensionalityError {
            independent_variables: flat.independent_variables.clone(),
        });
    }
    if !flat.continuous_events.is_empty() {
        return Err(CompileError::UnsupportedFeatureError {
            feature: "continuous_events".to_string(),
            message: "v1 does not support continuous (root-finding) events. \
                      Track the future Rust events bead for support."
                .to_string(),
        });
    }
    if !flat.discrete_events.is_empty() {
        return Err(CompileError::UnsupportedFeatureError {
            feature: "discrete_events".to_string(),
            message: "v1 does not support discrete events. \
                      Track the future Rust events bead for support."
                .to_string(),
        });
    }
    Ok(())
}

/// Per-name defining expressions extracted from a [`FlattenedSystem`] by
/// [`classify_equations`]. Indices parallel the state / raw-observed name
/// tables built in [`Compiled::from_flattened`].
struct ClassifiedEquations {
    /// `D(state, t) = rhs` RHS per state index.
    state_diff_raw: Vec<Option<Expr>>,
    /// Bare-LHS algebraic body per state index (esm-0kt).
    state_alg_raw: Vec<Option<Expr>>,
    /// Defining RHS per raw observed index.
    observed_rhs_raw: Vec<Option<Expr>>,
}

/// Walk `flat.equations` and classify each as a differential state
/// derivative, an algebraic state definition, or an observed assignment.
/// Then enforce that every state has a defining equation — either a
/// differential `D(state, t)` RHS or a bare-LHS algebraic body. If both are
/// present the differential equation wins (matches the Python simulation
/// runner's overdetermined-system rule, esm-y3n).
fn classify_equations(
    flat: &FlattenedSystem,
    state_names: &[String],
    state_index: &HashMap<String, usize>,
    observed_index_raw: &HashMap<String, usize>,
) -> Result<ClassifiedEquations, CompileError> {
    let mut state_diff_raw: Vec<Option<Expr>> = vec![None; state_names.len()];
    let mut state_alg_raw: Vec<Option<Expr>> = vec![None; state_names.len()];
    let mut observed_rhs_raw: Vec<Option<Expr>> = vec![None; flat.observed_variables.len()];

    // Pull observed defining expressions out of the variable struct as a
    // fallback (some flattening pipelines store the expression there
    // rather than as an algebraic equation).
    for (idx, (_name, mv)) in flat.observed_variables.iter().enumerate() {
        if let Some(expr) = &mv.expression {
            observed_rhs_raw[idx] = Some(expr.clone());
        }
    }

    for eq in &flat.equations {
        if let Some(state_name) = state_lhs_name(&eq.lhs) {
            let idx = state_index.get(&state_name).ok_or_else(|| {
                CompileError::InterpreterBuildError {
                    details: format!(
                        "Equation defines D({state_name}, t) but '{state_name}' \
                             is not in flat.state_variables"
                    ),
                }
            })?;
            state_diff_raw[*idx] = Some(eq.rhs.clone());
        } else if let Some(name) = observed_lhs_name(&eq.lhs) {
            if let Some(idx) = state_index.get(&name) {
                // Bare-LHS equation whose target is a *state* variable
                // — algebraic-elimination case (esm-0kt). The integrator
                // does not advance this slot; its value is reconstructed
                // from the body whenever the RHS or output is evaluated.
                state_alg_raw[*idx] = Some(eq.rhs.clone());
            } else if let Some(idx) = observed_index_raw.get(&name) {
                observed_rhs_raw[*idx] = Some(eq.rhs.clone());
            }
            // Bare-LHS equations whose target is neither a state nor an
            // observed variable are ignored — they'd be true DAE
            // constraints (out of v1 scope).
        }
        // Other LHS shapes (array ops, etc.) are handled elsewhere or
        // ignored.
    }

    // Every state must have a defining equation; differential wins over
    // algebraic when both are present (esm-y3n).
    for (idx, name) in state_names.iter().enumerate() {
        if state_diff_raw[idx].is_some() {
            state_alg_raw[idx] = None;
            continue;
        }
        if state_alg_raw[idx].is_none() {
            return Err(CompileError::InterpreterBuildError {
                details: format!(
                    "State variable '{name}' has no D({name}, t) = ... equation in \
                     flat.equations. Cannot simulate."
                ),
            });
        }
    }

    Ok(ClassifiedEquations {
        state_diff_raw,
        state_alg_raw,
        observed_rhs_raw,
    })
}

/// Output of [`resolve_observed`]: observed names in evaluation order, the
/// matching name -> index table, and the resolved defining expressions
/// (parallel to the ordered names).
type ResolvedObserved = (Vec<String>, HashMap<String, usize>, Vec<ResolvedExpr>);

/// Topologically sort observed variables and resolve their defining
/// expressions to typed indices. Each observed expression may only reference
/// state, params, time, or *earlier* observed variables; the dependency set
/// per observed variable is restricted to other observed names. Returns the
/// names in evaluation order, the matching name -> index table, and the
/// resolved expressions (parallel to the ordered names).
fn resolve_observed(
    observed_names_raw: &[String],
    observed_index_raw: &HashMap<String, usize>,
    observed_rhs_raw: &[Option<Expr>],
    state_index: &HashMap<String, usize>,
    param_index: &HashMap<String, usize>,
) -> Result<ResolvedObserved, CompileError> {
    let mut obs_deps: Vec<HashSet<usize>> = vec![HashSet::new(); observed_names_raw.len()];
    for (i, raw) in observed_rhs_raw.iter().enumerate() {
        if let Some(expr) = raw {
            collect_observed_refs(expr, observed_index_raw, &mut obs_deps[i]);
        }
    }

    let order = topo_sort(&obs_deps).map_err(|cycle| CompileError::InterpreterBuildError {
        details: format!(
            "Cyclic observed-variable dependency: {:?}",
            cycle
                .into_iter()
                .map(|i| observed_names_raw[i].clone())
                .collect::<Vec<_>>()
        ),
    })?;

    let observed_names: Vec<String> = order
        .iter()
        .map(|&i| observed_names_raw[i].clone())
        .collect();
    let observed_index = build_index_map(&observed_names);
    let observed_raw_in_order: Vec<Option<Expr>> =
        order.iter().map(|&i| observed_rhs_raw[i].clone()).collect();

    // Resolve every expression to ResolvedExpr (variable refs become typed
    // indices); `Some(i)` enforces the forward-only observed dependency rule.
    let observed_exprs: Vec<ResolvedExpr> = observed_raw_in_order
        .iter()
        .enumerate()
        .map(|(i, raw)| {
            let expr = raw.as_ref().unwrap_or(&Expr::Number(0.0));
            resolve_expr(expr, state_index, param_index, &observed_index, Some(i))
        })
        .collect::<Result<_, _>>()?;

    Ok((observed_names, observed_index, observed_exprs))
}

/// Topologically sort algebraic states (esm-0kt). An algebraic state's
/// defining body may reference parameters, time, observed variables,
/// differential states, or *other* algebraic states. The scalar equivalent of
/// MTK's structural_simplify is a single pass that resolves each algebraic
/// body in dependency order, so by the time we evaluate it every algebraic
/// dependency already has a current value in the working state buffer. Cycles
/// among algebraic states are rejected — the integrator has no way to break
/// them.
fn order_algebraic_states(
    state_names: &[String],
    state_index: &HashMap<String, usize>,
    state_alg_raw: &[Option<Expr>],
) -> Result<Vec<usize>, CompileError> {
    let algebraic_indices: Vec<usize> = (0..state_names.len())
        .filter(|i| state_alg_raw[*i].is_some())
        .collect();
    let alg_membership: HashSet<usize> = algebraic_indices.iter().copied().collect();

    let mut alg_deps_dense: Vec<HashSet<usize>> = vec![HashSet::new(); state_names.len()];
    for &i in &algebraic_indices {
        if let Some(expr) = state_alg_raw[i].as_ref() {
            collect_state_refs(expr, state_index, &alg_membership, &mut alg_deps_dense[i]);
        }
    }
    topo_sort_subset(&algebraic_indices, &alg_deps_dense).map_err(|cycle| {
        CompileError::InterpreterBuildError {
            details: format!(
                "Cyclic algebraic equations detected: {}",
                cycle
                    .into_iter()
                    .map(|i| state_names[i].clone())
                    .collect::<Vec<_>>()
                    .join(" -> ")
            ),
        }
    })
}

/// Build the per-state classification + resolved defining expression: a
/// [`StateKind::Differential`] for each `D(state, t)` RHS, a
/// [`StateKind::Algebraic`] for each bare-LHS algebraic body (every state has
/// exactly one after [`classify_equations`]).
fn build_state_kinds(
    state_diff_raw: &[Option<Expr>],
    state_alg_raw: &[Option<Expr>],
    state_index: &HashMap<String, usize>,
    param_index: &HashMap<String, usize>,
    observed_index: &HashMap<String, usize>,
) -> Result<Vec<StateKind>, CompileError> {
    let mut state_kinds: Vec<StateKind> = Vec::with_capacity(state_diff_raw.len());
    for i in 0..state_diff_raw.len() {
        if let Some(rhs) = state_diff_raw[i].as_ref() {
            let resolved = resolve_expr(rhs, state_index, param_index, observed_index, None)?;
            state_kinds.push(StateKind::Differential(resolved));
        } else {
            let body = state_alg_raw[i]
                .as_ref()
                .expect("algebraic-only states checked in classify_equations");
            let resolved = resolve_expr(body, state_index, param_index, observed_index, None)?;
            state_kinds.push(StateKind::Algebraic(resolved));
        }
    }
    Ok(state_kinds)
}

/// Run the configured solver from `t0` to `t_end`, honoring `opts.max_steps`
/// and `opts.output_times`. Returns `(time_vec, state_matrix_rows)` where
/// `state_matrix_rows[i]` is the trajectory of state variable `i`.
///
/// If `opts.output_times` is `Some`, the solver advances natively but the
/// returned grid is interpolated to exactly those times. We watch each step's
/// `[t_prev, t_curr]` interval and interpolate any user time inside it before
/// moving on, since `interpolate()` is only valid for times within the
/// solver's current dense output window (calling it backwards on a stiff
/// solver returns garbage).
pub(crate) fn run_solver<'a, S, Eqn>(
    solver: &mut S,
    t_end: f64,
    opts: &SimulateOptions,
) -> Result<(Vec<f64>, Vec<Vec<f64>>), SimulateError>
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

    solver
        .set_stop_time(t_end)
        .map_err(|e| SimulateError::DiffsolError {
            details: e.to_string(),
        })?;

    let mut step_count: usize = 0;

    if let Some(t_eval) = &opts.output_times {
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
            if step_count >= opts.max_steps {
                return Err(SimulateError::MaxStepsExceeded {
                    max_steps: opts.max_steps,
                });
            }
            let stop = solver.step().map_err(|e| SimulateError::DiffsolError {
                details: e.to_string(),
            })?;
            step_count += 1;
            let t_curr = solver.state().t;

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
        // the user asked for it.
        while next_idx < t_eval.len() {
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
            if step_count >= opts.max_steps {
                return Err(SimulateError::MaxStepsExceeded {
                    max_steps: opts.max_steps,
                });
            }
            let stop = solver.step().map_err(|e| SimulateError::DiffsolError {
                details: e.to_string(),
            })?;
            step_count += 1;
            let t_curr = solver.state().t;
            let y_owned: Vec<f64> = solver.state().y.as_slice().to_vec();
            push_state(&mut times, &mut state_rows, t_curr, &y_owned);
            if matches!(stop, OdeSolverStopReason::TstopReached) {
                break;
            }
        }
    }

    Ok((times, state_rows))
}

/// One-shot convenience: flatten -> compile -> simulate.
///
/// Dispatches to the array-op interpreter ([`crate::simulate_array`]) when
/// the file contains any `arrayop`, `makearray`, `reshape`, `transpose`,
/// `concat`, `broadcast`, or `index` nodes (gt-oxr), **or** when the file
/// has spatial model structure — top-level grid declarations or any model
/// with array-shaped state variables (non-empty `shape` field). Spatial
/// models that have already been discretized (spatial ops rewritten to
/// `index`-addressed array equations) integrate end-to-end via the ArrayOp
/// runtime without hitting the scalar-ODE rejection guard. Their
/// method-of-lines stencil RHS is evaluated **vectorized** — whole-array
/// shifted-slice stencils + region-materialized boundary makearrays, no
/// per-cell scalarization (ess-bdm; see
/// [`crate::simulate_array::ArrayCompiled`] and the no-scalarization
/// verification in `tests/pde_vectorized_eval.rs`).
///
/// Falls back to the scalar path via [`Compiled::from_file`] for pure-ODE
/// files with no array-op or spatial structure.
pub fn simulate(
    file: &EsmFile,
    tspan: (f64, f64),
    params: &HashMap<String, f64>,
    initial_conditions: &HashMap<String, f64>,
    opts: &SimulateOptions,
) -> Result<Solution, SimulateError> {
    // Array-op / spatial files route to the `simulate_array` backend. This
    // branch is compiled on wasm too (EarthSciSerialization-akz): the array
    // runtime is wasm-clean — planar / geometry-free PDEs run, and a
    // spherical/geodesic geometry op degrades to a runtime `GeometryError` via
    // the `crate::geometry` wasm stub rather than a compile failure. Pure-ODE
    // files still fall through to the scalar path below.
    if crate::simulate_array::file_has_array_ops(file)
        || crate::simulate_array::file_has_spatial_model(file)
    {
        // A coupled (multi-model) file has no single raw `Model` for the array
        // runtime to consume — `ArrayCompiled::from_file` rejects `models.len()
        // != 1`. Flatten the coupling into one namespaced system first, then
        // build the array runtime from that flatten output (ess-14f.8). The
        // single-model array path is left byte-identical (`from_file`).
        let model_count = file.models.as_ref().map_or(0, |m| m.len());
        let compiled = if model_count > 1 {
            let flat = flatten(file).map_err(CompileError::from)?;
            crate::simulate_array::ArrayCompiled::from_flattened(&flat)?
        } else {
            crate::simulate_array::ArrayCompiled::from_file(file)?
        };
        return compiled.simulate(tspan, params, initial_conditions, opts);
    }
    let compiled = Compiled::from_file(file)?;
    compiled.simulate(tspan, params, initial_conditions, opts)
}

/// [`simulate`] with a build-observability sink (the Rust mirror of the Julia
/// `simulate(…; inspect=BuildInspection())` keyword): identical routing and an
/// identical [`Solution`], plus `inspect` is filled with the array runtime's
/// named build-time products — the state-free observed arrays materialized at
/// the initial state (per-pair regrid geometry `A_ij`/`A_j`/`W_ij`, const mesh
/// factors and their aliases, rule outputs like the MPAS `div_flux`) and the
/// resolved observed expression map. See
/// [`crate::simulate_array::BuildInspection`]. A pure-scalar file runs through
/// the scalar interpreter unchanged and leaves the sink empty (it has no array
/// build products). Native-only, like the array runtime it observes.
#[cfg(not(target_arch = "wasm32"))]
pub fn simulate_with_inspection(
    file: &EsmFile,
    tspan: (f64, f64),
    params: &HashMap<String, f64>,
    initial_conditions: &HashMap<String, f64>,
    opts: &SimulateOptions,
    inspect: &mut crate::simulate_array::BuildInspection,
) -> Result<Solution, SimulateError> {
    if crate::simulate_array::file_has_array_ops(file)
        || crate::simulate_array::file_has_spatial_model(file)
    {
        let model_count = file.models.as_ref().map_or(0, |m| m.len());
        let compiled = if model_count > 1 {
            let flat = flatten(file).map_err(CompileError::from)?;
            crate::simulate_array::ArrayCompiled::from_flattened(&flat)?
        } else {
            crate::simulate_array::ArrayCompiled::from_file(file)?
        };
        return compiled.simulate_inspect(tspan, params, initial_conditions, opts, Some(inspect));
    }
    let compiled = Compiled::from_file(file)?;
    compiled.simulate(tspan, params, initial_conditions, opts)
}

// ============================================================================
// Resolved expression: precomputed indices for the hot interpreter loop
// ============================================================================

/// Internal: an Expr with variable references replaced by typed integer
/// indices into the state / parameter / observed buffers.
#[derive(Debug, Clone)]
pub enum ResolvedExpr {
    /// Constant.
    Number(f64),
    /// `state[i]`
    State(usize),
    /// `param[i]`
    Param(usize),
    /// `observed[i]`
    Observed(usize),
    /// The independent variable `t`.
    Time,
    /// Operator node.
    Op {
        /// Operator name (string-tagged for v1; cheap to dispatch on).
        op: String,
        /// Resolved children.
        args: Vec<ResolvedExpr>,
    },
    /// Closed-registry function call (the `fn` op, esm-spec §9.2). Held as a
    /// distinct variant because — unlike a plain [`ResolvedExpr::Op`] — it
    /// carries the dotted function `name` and its arguments may be array
    /// literals (the `table` / `axis` of `interp.linear` / `interp.bilinear`),
    /// which the scalar `f64` interpreter otherwise has no way to represent.
    /// Array arguments are inline `const` literals, so they are materialized
    /// once at resolve time; scalar arguments stay as sub-expressions evaluated
    /// per call.
    Fn {
        /// Dotted module path of the registered function (e.g. `interp.linear`).
        name: String,
        /// Resolved arguments, each either a per-call scalar sub-expression or a
        /// materialized constant array.
        args: Vec<ResolvedFnArg>,
    },
}

/// One argument to a resolved [`ResolvedExpr::Fn`] call.
#[derive(Debug, Clone)]
pub enum ResolvedFnArg {
    /// A scalar argument, evaluated per call (e.g. the query point `x`, which
    /// may reference a parameter or state).
    Scalar(Box<ResolvedExpr>),
    /// A 1-D constant array argument (an inline `const` literal — e.g. the
    /// `table` or `axis` of `interp.linear`).
    Array(Vec<f64>),
    /// A 2-D constant array argument (the `table` of `interp.bilinear`).
    Array2D(Vec<Vec<f64>>),
}

/// Build a `name -> position` lookup from an ordered list of names.
fn build_index_map(names: &[String]) -> HashMap<String, usize> {
    names
        .iter()
        .enumerate()
        .map(|(i, n)| (n.clone(), i))
        .collect()
}

/// Resolve an `Expr` against name -> index tables. If `obs_limit` is `Some(i)`,
/// observed-variable references must be to indices `< i` (forward-only
/// dependency check during topo-resolution of observed expressions).
fn resolve_expr(
    expr: &Expr,
    state_index: &HashMap<String, usize>,
    param_index: &HashMap<String, usize>,
    observed_index: &HashMap<String, usize>,
    obs_limit: Option<usize>,
) -> Result<ResolvedExpr, CompileError> {
    match expr {
        Expr::Number(n) => Ok(ResolvedExpr::Number(*n)),
        Expr::Integer(n) => Ok(ResolvedExpr::Number(*n as f64)),
        Expr::Variable(name) => {
            if name == "t" {
                Ok(ResolvedExpr::Time)
            } else if let Some(&i) = state_index.get(name) {
                Ok(ResolvedExpr::State(i))
            } else if let Some(&i) = param_index.get(name) {
                Ok(ResolvedExpr::Param(i))
            } else if let Some(&i) = observed_index.get(name) {
                if let Some(limit) = obs_limit
                    && i >= limit
                {
                    return Err(CompileError::InterpreterBuildError {
                        details: format!(
                            "Observed variable references not-yet-defined observed '{name}' \
                             (forward dependency)"
                        ),
                    });
                }
                Ok(ResolvedExpr::Observed(i))
            } else {
                Err(CompileError::InterpreterBuildError {
                    details: format!("Unknown variable '{name}' referenced in expression"),
                })
            }
        }
        Expr::Operator(node) => {
            // Reject unlowered rewrite-target operators at compile time
            // (esm-spec §4.2 / §9.6.8): the optional sugar ops
            // `grad` / `div` / `laplacian` (and `curl` / `∇`) have no evaluator,
            // and a SPATIAL `D` (`wrt` != "t") is a rewrite-target that a
            // discretization rule must lower to a stencil before evaluation. The
            // structural time derivative `D(_, t)` stays evaluable-core. The gate
            // fires here — before evaluation — with the uniform
            // `unlowered_operator` code.
            let unlowered = match node.op.as_str() {
                "grad" | "div" | "laplacian" | "curl" | "∇" => true,
                "D" => node.wrt.as_deref().is_some_and(|w| w != "t"),
                _ => false,
            };
            if unlowered {
                return Err(CompileError::UnloweredOperatorError {
                    op: node.op.clone(),
                });
            }
            // Closed-registry function call (esm-spec §9.2): resolve to the
            // dedicated `Fn` variant so the callee `name` and any inline array
            // arguments survive to evaluation (a plain `Op` drops both — the
            // root cause of `fn` ops NaN-ing on the scalar path).
            if node.op == "fn" {
                let name =
                    node.name
                        .clone()
                        .ok_or_else(|| CompileError::InterpreterBuildError {
                            details: "`fn` op is missing its required `name` field".to_string(),
                        })?;
                let args = node
                    .args
                    .iter()
                    .map(|a| resolve_fn_arg(a, state_index, param_index, observed_index, obs_limit))
                    .collect::<Result<Vec<_>, _>>()?;
                return Ok(ResolvedExpr::Fn { name, args });
            }
            let args = node
                .args
                .iter()
                .map(|a| resolve_expr(a, state_index, param_index, observed_index, obs_limit))
                .collect::<Result<Vec<_>, _>>()?;
            Ok(ResolvedExpr::Op {
                op: node.op.clone(),
                args,
            })
        }
    }
}

/// Resolve one argument of a `fn` op. An inline `const` literal whose value is
/// a JSON array is materialized to a constant [`ResolvedFnArg::Array`] /
/// [`ResolvedFnArg::Array2D`] (the `table` / `axis` operands of the `interp.*`
/// functions are always compile-time constants); every other argument — a
/// scalar `const`, a number, a variable, or a nested expression — resolves to a
/// per-call [`ResolvedFnArg::Scalar`] sub-expression.
fn resolve_fn_arg(
    expr: &Expr,
    state_index: &HashMap<String, usize>,
    param_index: &HashMap<String, usize>,
    observed_index: &HashMap<String, usize>,
    obs_limit: Option<usize>,
) -> Result<ResolvedFnArg, CompileError> {
    if let Expr::Operator(node) = expr
        && node.op == "const"
        && let Some(value) = &node.value
        && let Some(arg) = json_to_fn_array_arg(value)
    {
        return Ok(arg);
    }
    let resolved = resolve_expr(expr, state_index, param_index, observed_index, obs_limit)?;
    Ok(ResolvedFnArg::Scalar(Box::new(resolved)))
}

/// Materialize a `const`-op JSON value into an array `fn` argument. Returns
/// `Some(Array)` for a flat numeric list, `Some(Array2D)` for a list of
/// equal-length numeric rows, and `None` for a scalar number or any non-numeric
/// / ragged shape (a scalar `const` falls back to the per-call scalar path).
fn json_to_fn_array_arg(value: &serde_json::Value) -> Option<ResolvedFnArg> {
    let items = value.as_array()?;
    if items.iter().all(|it| it.is_array()) {
        // 2-D: every element is itself a numeric row.
        let rows: Option<Vec<Vec<f64>>> = items
            .iter()
            .map(|row| {
                row.as_array()?
                    .iter()
                    .map(|n| n.as_f64())
                    .collect::<Option<Vec<f64>>>()
            })
            .collect();
        rows.map(ResolvedFnArg::Array2D)
    } else {
        // 1-D: a flat numeric list.
        let flat: Option<Vec<f64>> = items.iter().map(|n| n.as_f64()).collect();
        flat.map(ResolvedFnArg::Array)
    }
}

/// Walk an expression and collect the indices of any observed variables it
/// references. Used by the topological sort.
fn collect_observed_refs(
    expr: &Expr,
    observed_index: &HashMap<String, usize>,
    out: &mut HashSet<usize>,
) {
    match expr {
        Expr::Number(_) | Expr::Integer(_) => {}
        Expr::Variable(name) => {
            if let Some(&i) = observed_index.get(name) {
                out.insert(i);
            }
        }
        Expr::Operator(node) => {
            for a in &node.args {
                collect_observed_refs(a, observed_index, out);
            }
        }
    }
}

/// Walk an expression and collect the indices of any *state* variables it
/// references whose state index is also a member of `members`. Used to build
/// the algebraic-state dependency graph for topo-sorting (esm-0kt).
fn collect_state_refs(
    expr: &Expr,
    state_index: &HashMap<String, usize>,
    members: &HashSet<usize>,
    out: &mut HashSet<usize>,
) {
    match expr {
        Expr::Number(_) | Expr::Integer(_) => {}
        Expr::Variable(name) => {
            if let Some(&i) = state_index.get(name)
                && members.contains(&i)
            {
                out.insert(i);
            }
        }
        Expr::Operator(node) => {
            for a in &node.args {
                collect_state_refs(a, state_index, members, out);
            }
        }
    }
}

/// Topologically sort a subset of node ids whose dependency edges live in a
/// dense `deps[id] -> set of dependency ids` array. Returns the subset in
/// dependency-respecting order. On a cycle, returns Err with the cycle path
/// for diagnostic naming.
fn topo_sort_subset(
    members: &[usize],
    deps_dense: &[HashSet<usize>],
) -> Result<Vec<usize>, Vec<usize>> {
    let member_set: HashSet<usize> = members.iter().copied().collect();
    let mut order: Vec<usize> = Vec::with_capacity(members.len());
    let mut visited: HashSet<usize> = HashSet::new();
    let mut on_stack: HashSet<usize> = HashSet::new();
    let mut path: Vec<usize> = Vec::new();

    fn visit(
        i: usize,
        deps_dense: &[HashSet<usize>],
        member_set: &HashSet<usize>,
        visited: &mut HashSet<usize>,
        on_stack: &mut HashSet<usize>,
        path: &mut Vec<usize>,
        order: &mut Vec<usize>,
    ) -> Result<(), Vec<usize>> {
        if visited.contains(&i) {
            return Ok(());
        }
        if on_stack.contains(&i) {
            // Trim path back to the start of the cycle.
            let start = path.iter().position(|&x| x == i).unwrap_or(0);
            let mut cycle: Vec<usize> = path[start..].to_vec();
            cycle.push(i);
            return Err(cycle);
        }
        on_stack.insert(i);
        path.push(i);
        for &d in &deps_dense[i] {
            if member_set.contains(&d) {
                visit(d, deps_dense, member_set, visited, on_stack, path, order)?;
            }
        }
        path.pop();
        on_stack.remove(&i);
        visited.insert(i);
        order.push(i);
        Ok(())
    }

    for &i in members {
        visit(
            i,
            deps_dense,
            &member_set,
            &mut visited,
            &mut on_stack,
            &mut path,
            &mut order,
        )?;
    }
    Ok(order)
}

/// Topological sort over a per-node dependency set. Returns nodes in
/// dependency-respecting order (each node appears after its deps). On a
/// cycle, returns Err containing the (arbitrary) cycle node ids.
fn topo_sort(deps: &[HashSet<usize>]) -> Result<Vec<usize>, Vec<usize>> {
    let n = deps.len();
    let mut order = Vec::with_capacity(n);
    let mut visited = vec![false; n];
    let mut on_stack = vec![false; n];

    fn visit(
        i: usize,
        deps: &[HashSet<usize>],
        visited: &mut [bool],
        on_stack: &mut [bool],
        order: &mut Vec<usize>,
    ) -> Result<(), Vec<usize>> {
        if visited[i] {
            return Ok(());
        }
        if on_stack[i] {
            return Err(vec![i]);
        }
        on_stack[i] = true;
        for &d in &deps[i] {
            visit(d, deps, visited, on_stack, order)?;
        }
        on_stack[i] = false;
        visited[i] = true;
        order.push(i);
        Ok(())
    }

    for i in 0..n {
        visit(i, deps, &mut visited, &mut on_stack, &mut order)?;
    }
    Ok(order)
}

// ============================================================================
// Interpreter
// ============================================================================

/// Walk a [`ResolvedExpr`] tree given current state, parameter, observed
/// vectors and time. Returns a finite f64 on success, or NaN / ±inf on
/// runtime math errors (the solver detects these as a step failure).
pub fn interpret(
    expr: &ResolvedExpr,
    state: &[f64],
    params: &[f64],
    observed: &[f64],
    t: f64,
) -> f64 {
    match expr {
        ResolvedExpr::Number(n) => *n,
        ResolvedExpr::State(i) => state[*i],
        ResolvedExpr::Param(i) => params[*i],
        ResolvedExpr::Observed(i) => observed[*i],
        ResolvedExpr::Time => t,
        ResolvedExpr::Op { op, args } => eval_op(op, args, state, params, observed, t),
        ResolvedExpr::Fn { name, args } => eval_fn(name, args, state, params, observed, t),
    }
}

/// Evaluate a resolved `fn` call (esm-spec §9.2). Scalar arguments are folded
/// per call through [`interpret`]; array arguments were materialized at resolve
/// time. Dispatches to the shared [`crate::registered_functions`] kernel and
/// lifts the result to `f64`. A registry error (unknown function, arity /
/// shape mismatch, non-monotonic axis) surfaces as the NaN sentinel — the same
/// runtime-error convention [`eval_op`] uses; the solver reads NaN as a step
/// failure.
fn eval_fn(
    name: &str,
    args: &[ResolvedFnArg],
    state: &[f64],
    params: &[f64],
    observed: &[f64],
    t: f64,
) -> f64 {
    use crate::registered_functions::{ClosedArg, evaluate_closed_function};

    let closed_args: Vec<ClosedArg> = args
        .iter()
        .map(|a| match a {
            ResolvedFnArg::Scalar(e) => ClosedArg::Scalar(interpret(e, state, params, observed, t)),
            ResolvedFnArg::Array(v) => ClosedArg::Array(v.clone()),
            ResolvedFnArg::Array2D(v) => ClosedArg::Array2D(v.clone()),
        })
        .collect();
    match evaluate_closed_function(name, &closed_args) {
        Ok(v) => v.as_f64(),
        Err(_) => f64::NAN,
    }
}

/// Fold a scalar [`Expr`] to a numeric value with the given variable bindings.
///
/// Canonical single-expression entry point on the scalar runner: builds a
/// parameter table from `bindings`, runs [`resolve_expr`], then walks the
/// result through [`interpret`] / [`eval_op`] — the same primitives the
/// `simulate` ODE solver uses. Adding an op to `eval_op` transparently
/// extends single-expression evaluation; there is no parallel dispatch table.
///
/// State and observed buffers are empty. The independent-variable `t` reads
/// from `bindings.get("t")` if present (caller-supplied "current time"),
/// otherwise defaults to `0.0`.
///
/// On success returns `Ok(value)`. If `expr` references variable names that
/// are not in `bindings` (and that aren't `t`), returns `Err(names)` listing
/// each missing reference in encounter order. Math errors (division by zero,
/// log of a non-positive number, unknown ops) propagate as `f64::NAN` or
/// `±inf` in the `Ok` branch — that is the canonical runner's convention.
pub fn fold_constant_expr(
    expr: &Expr,
    bindings: &HashMap<String, f64>,
) -> Result<f64, Vec<String>> {
    let mut unbound: Vec<String> = Vec::new();
    collect_unbound(expr, bindings, &mut unbound);
    if !unbound.is_empty() {
        return Err(unbound);
    }
    let mut names: Vec<String> = bindings.keys().cloned().collect();
    names.sort();
    let mut param_index: HashMap<String, usize> = HashMap::with_capacity(names.len());
    let mut params: Vec<f64> = Vec::with_capacity(names.len());
    for (i, n) in names.iter().enumerate() {
        param_index.insert(n.clone(), i);
        params.push(bindings[n]);
    }
    let resolved = resolve_expr(expr, &HashMap::new(), &param_index, &HashMap::new(), None)
        .map_err(|e| vec![format!("{e:?}")])?;
    let t_value = bindings.get("t").copied().unwrap_or(0.0);
    Ok(interpret(&resolved, &[], &params, &[], t_value))
}

fn collect_unbound(expr: &Expr, bindings: &HashMap<String, f64>, out: &mut Vec<String>) {
    match expr {
        Expr::Number(_) | Expr::Integer(_) => {}
        Expr::Variable(name) => {
            // `t` is supplied by the caller (or defaults to 0.0); never report
            // it as unbound even if the user did not put it in `bindings`.
            if name != "t" && !bindings.contains_key(name) {
                out.push(name.clone());
            }
        }
        Expr::Operator(node) => {
            for arg in &node.args {
                collect_unbound(arg, bindings, out);
            }
        }
    }
}

fn eval_op(
    op: &str,
    args: &[ResolvedExpr],
    state: &[f64],
    params: &[f64],
    observed: &[f64],
    t: f64,
) -> f64 {
    let v = |i: usize| interpret(&args[i], state, params, observed, t);
    match op {
        // n-ary arithmetic
        "+" => args
            .iter()
            .map(|a| interpret(a, state, params, observed, t))
            .sum(),
        "*" => args
            .iter()
            .map(|a| interpret(a, state, params, observed, t))
            .product(),
        "-" => match args.len() {
            1 => -v(0),
            2 => v(0) - v(1),
            _ => f64::NAN,
        },
        "/" => v(0) / v(1),
        "^" => v(0).powf(v(1)),

        // unary transcendentals
        "exp" => v(0).exp(),
        "log" | "ln" => v(0).ln(),
        "log10" => v(0).log10(),
        "sqrt" => v(0).sqrt(),
        "abs" => v(0).abs(),
        "sign" => {
            // Mathematical sign convention (sign(0) = 0), matching the spec
            // and the cross-binding contract. This differs from `f64::signum`,
            // which returns ±1 for ±0.
            let x = v(0);
            if x > 0.0 {
                1.0
            } else if x < 0.0 {
                -1.0
            } else {
                0.0
            }
        }
        "floor" => v(0).floor(),
        "ceil" => v(0).ceil(),

        // trig
        "sin" => v(0).sin(),
        "cos" => v(0).cos(),
        "tan" => v(0).tan(),
        "asin" => v(0).asin(),
        "acos" => v(0).acos(),
        "atan" => v(0).atan(),
        "atan2" => v(0).atan2(v(1)),
        "sinh" => v(0).sinh(),
        "cosh" => v(0).cosh(),
        "tanh" => v(0).tanh(),
        "asinh" => v(0).asinh(),
        "acosh" => v(0).acosh(),
        "atanh" => v(0).atanh(),

        // n-ary min / max (esm-spec §4.2 — arity ≥ 2)
        "min" => args
            .iter()
            .map(|a| interpret(a, state, params, observed, t))
            .fold(f64::INFINITY, f64::min),
        "max" => args
            .iter()
            .map(|a| interpret(a, state, params, observed, t))
            .fold(f64::NEG_INFINITY, f64::max),

        // conditional
        "ifelse" => {
            if v(0) != 0.0 {
                v(1)
            } else {
                v(2)
            }
        }

        // relational (return 0/1)
        "<" => f64::from(v(0) < v(1)),
        ">" => f64::from(v(0) > v(1)),
        "<=" => f64::from(v(0) <= v(1)),
        ">=" => f64::from(v(0) >= v(1)),
        "==" => {
            if (v(0) - v(1)).abs() < f64::EPSILON {
                1.0
            } else {
                0.0
            }
        }
        "!=" => {
            if (v(0) - v(1)).abs() >= f64::EPSILON {
                1.0
            } else {
                0.0
            }
        }

        // logical
        "and" => {
            if v(0) != 0.0 && v(1) != 0.0 {
                1.0
            } else {
                0.0
            }
        }
        "or" => {
            if v(0) != 0.0 || v(1) != 0.0 {
                1.0
            } else {
                0.0
            }
        }
        "not" => {
            if v(0) == 0.0 {
                1.0
            } else {
                0.0
            }
        }

        // Differential operator on RHS. `D` is a programming-form-only
        // marker on the LHS of state equations and is rewritten elsewhere;
        // if it shows up on the RHS we treat it as 0 (legacy parity).
        "D" => 0.0,

        // Spatial differential operators on the RHS are treated as 0 (same
        // convention as "D"). They are rewritten by ESD discretization before
        // reaching the solver in the normal pipeline; returning 0 here keeps
        // interpret() well-defined when called directly on expressions that
        // contain spatial operators (e.g. in tests or expression walkers).
        "grad" | "div" | "laplacian" => 0.0,

        // Pre is the previous-value operator (used by event handling). With
        // events disallowed in v1 it should never appear, but if it does we
        // pass through the argument unchanged.
        "Pre" => v(0),

        _ => f64::NAN,
    }
}

// ============================================================================
// LHS classification helpers
// ============================================================================

/// If `lhs` is `D(state_var, t)`, return the state variable name.
fn state_lhs_name(lhs: &Expr) -> Option<String> {
    let Expr::Operator(node) = lhs else {
        return None;
    };
    if node.op != "D" {
        return None;
    }
    if node.args.len() != 1 {
        return None;
    }
    match (&node.args[0], &node.wrt) {
        (Expr::Variable(name), Some(wrt)) if wrt == "t" => Some(name.clone()),
        // Also accept `D(x, t)` encoded as a 2-arg form (some pipelines do this).
        _ => None,
    }
}

/// If `lhs` is a plain variable reference, return its name (used for
/// observed-variable algebraic equations).
fn observed_lhs_name(lhs: &Expr) -> Option<String> {
    if let Expr::Variable(name) = lhs {
        Some(name.clone())
    } else {
        None
    }
}

// ============================================================================
// Inline unit tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn interpret_arithmetic() {
        // 2 * (3 + 4) = 14
        let e = ResolvedExpr::Op {
            op: "*".to_string(),
            args: vec![
                ResolvedExpr::Number(2.0),
                ResolvedExpr::Op {
                    op: "+".to_string(),
                    args: vec![ResolvedExpr::Number(3.0), ResolvedExpr::Number(4.0)],
                },
            ],
        };
        assert!((interpret(&e, &[], &[], &[], 0.0) - 14.0).abs() < 1e-12);
    }

    #[test]
    fn interpret_state_param_time() {
        // state[0] * param[0] + t  with state=[2], params=[3], t=10 -> 16
        let e = ResolvedExpr::Op {
            op: "+".to_string(),
            args: vec![
                ResolvedExpr::Op {
                    op: "*".to_string(),
                    args: vec![ResolvedExpr::State(0), ResolvedExpr::Param(0)],
                },
                ResolvedExpr::Time,
            ],
        };
        assert!((interpret(&e, &[2.0], &[3.0], &[], 10.0) - 16.0).abs() < 1e-12);
    }

    #[test]
    fn interpret_unary_minus_and_pow() {
        // (-x)^2 with x=4 -> 16
        let e = ResolvedExpr::Op {
            op: "^".to_string(),
            args: vec![
                ResolvedExpr::Op {
                    op: "-".to_string(),
                    args: vec![ResolvedExpr::State(0)],
                },
                ResolvedExpr::Number(2.0),
            ],
        };
        assert!((interpret(&e, &[4.0], &[], &[], 0.0) - 16.0).abs() < 1e-12);
    }

    #[test]
    fn interpret_transcendentals_and_relational() {
        // ifelse(x > 0, log(x), 0)
        let e = ResolvedExpr::Op {
            op: "ifelse".to_string(),
            args: vec![
                ResolvedExpr::Op {
                    op: ">".to_string(),
                    args: vec![ResolvedExpr::State(0), ResolvedExpr::Number(0.0)],
                },
                ResolvedExpr::Op {
                    op: "log".to_string(),
                    args: vec![ResolvedExpr::State(0)],
                },
                ResolvedExpr::Number(0.0),
            ],
        };
        let x_pos = std::f64::consts::E;
        // ifelse(true, log(e^1), 0) = 1
        assert!((interpret(&e, &[x_pos], &[], &[], 0.0) - 1.0).abs() < 1e-12);
        assert_eq!(interpret(&e, &[-1.0], &[], &[], 0.0), 0.0);
    }

    #[test]
    fn topo_sort_empty_and_simple() {
        // No deps -> any order is fine, but length matches.
        let deps = vec![HashSet::new(), HashSet::new(), HashSet::new()];
        let order = topo_sort(&deps).unwrap();
        assert_eq!(order.len(), 3);

        // 0 -> 1 -> 2 (2 depends on 1, 1 depends on 0)
        let mut s1 = HashSet::new();
        s1.insert(0);
        let mut s2 = HashSet::new();
        s2.insert(1);
        let deps = vec![HashSet::new(), s1, s2];
        let order = topo_sort(&deps).unwrap();
        assert_eq!(order, vec![0, 1, 2]);
    }

    #[test]
    fn topo_sort_cycle_detected() {
        // 0 -> 1 -> 0
        let mut s0 = HashSet::new();
        s0.insert(1);
        let mut s1 = HashSet::new();
        s1.insert(0);
        let deps = vec![s0, s1];
        assert!(topo_sort(&deps).is_err());
    }

    /// Cyclic algebraic-state systems must be rejected at compile time
    /// (esm-0kt). `from_flattened` should return an `InterpreterBuildError`
    /// whose message names the offending variables.
    #[test]
    fn algebraic_cycle_rejected() {
        // Two algebraic states a, b form a cycle: a = b + 1, b = a * 2.
        // dx/dt = a is a non-cyclic ODE that anchors the system.
        let json = r#"{
            "esm": "0.4.0",
            "metadata": {"name": "TestFixture"},
            "models": {
                "M": {
                    "variables": {
                        "x": {"type": "state", "default": 0.0},
                        "a": {"type": "state", "default": 1.0},
                        "b": {"type": "state", "default": 1.0}
                    },
                    "equations": [
                        {
                            "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                            "rhs": "a"
                        },
                        {
                            "lhs": "a",
                            "rhs": {"op": "+", "args": ["b", 1.0]}
                        },
                        {
                            "lhs": "b",
                            "rhs": {"op": "*", "args": ["a", 2.0]}
                        }
                    ]
                }
            }
        }"#;
        let file = crate::parse::load(json).expect("parse fixture");
        let err = Compiled::from_file(&file).expect_err("cycle must be rejected");
        let msg = err.to_string();
        assert!(msg.contains("Cyclic"), "expected cycle error, got: {msg}");
        assert!(
            msg.contains("a") && msg.contains("b"),
            "cycle error should name both vars: {msg}"
        );
    }

    /// A `fn`-op observed (`interp.linear` fuel-table lookup) must evaluate
    /// through the closed-function registry on the scalar path — not NaN out.
    /// Regression for the coupled-fire blocker: `resolve_expr` used to drop the
    /// `fn` op's `name` and its inline array args, so `interp.linear` fell
    /// through `eval_op`'s `_ => NaN` arm and poisoned every downstream state.
    #[test]
    fn fn_op_interp_linear_scalar_path() {
        // looked_up = interp.linear([10,20,40,80,160], [0,1,2,3,4], code);
        // dx/dt = looked_up, x(0) = 0. At code = 2.0 the lookup is the exact
        // knot 40.0, so x(1) = 40.0.
        let json = r#"{
            "esm": "0.8.0",
            "metadata": {"name": "FnFixture"},
            "models": {
                "M": {
                    "variables": {
                        "x": {"type": "state", "default": 0.0},
                        "code": {"type": "parameter", "default": 2.0},
                        "looked_up": {"type": "observed", "expression": {
                            "op": "fn", "name": "interp.linear", "args": [
                                {"op": "const", "value": [10.0, 20.0, 40.0, 80.0, 160.0], "args": []},
                                {"op": "const", "value": [0.0, 1.0, 2.0, 3.0, 4.0], "args": []},
                                "code"
                            ]}}
                    },
                    "equations": [
                        {
                            "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                            "rhs": "looked_up"
                        }
                    ]
                }
            }
        }"#;
        let file = crate::parse::load(json).expect("parse fixture");
        let compiled = Compiled::from_file(&file).expect("compile succeeds");
        let opts = SimulateOptions {
            output_times: Some(vec![0.0, 1.0]),
            ..Default::default()
        };
        let sol = compiled
            .simulate((0.0, 1.0), &HashMap::new(), &HashMap::new(), &opts)
            .expect("simulate succeeds");
        let x_idx = sol
            .state_variable_names
            .iter()
            .position(|n| n.ends_with("x"))
            .expect("x in solution");
        assert!(
            (sol.state[x_idx][1] - 40.0).abs() < 1e-6,
            "x(1) should be 40.0 (dx/dt = interp.linear(...,2.0) = 40), got {}",
            sol.state[x_idx][1]
        );

        // A different query point exercises the blend, not just a knot: at
        // code = 0.5 the lookup is 0.5*(10+20)... = 15.0.
        let mut params = HashMap::new();
        params.insert("M.code".to_string(), 0.5);
        let sol2 = compiled
            .simulate((0.0, 1.0), &params, &HashMap::new(), &opts)
            .expect("simulate succeeds");
        assert!(
            (sol2.state[x_idx][1] - 15.0).abs() < 1e-6,
            "x(1) should be 15.0 at code=0.5, got {}",
            sol2.state[x_idx][1]
        );
    }

    /// A `fn`-op with a *scalar* argument (`datetime.year`) exercises the
    /// `name`-threading fix independent of the array-arg materialization path.
    #[test]
    fn fn_op_datetime_scalar_arg() {
        // yr = datetime.year(946684800) = 2000 (2000-01-01T00:00:00Z).
        // dx/dt = yr, x(0) = 0, so x(1) = 2000.
        let json = r#"{
            "esm": "0.8.0",
            "metadata": {"name": "DatetimeFixture"},
            "models": {
                "M": {
                    "variables": {
                        "x": {"type": "state", "default": 0.0},
                        "yr": {"type": "observed", "expression": {
                            "op": "fn", "name": "datetime.year", "args": [946684800.0]}}
                    },
                    "equations": [
                        {
                            "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                            "rhs": "yr"
                        }
                    ]
                }
            }
        }"#;
        let file = crate::parse::load(json).expect("parse fixture");
        let compiled = Compiled::from_file(&file).expect("compile succeeds");
        let opts = SimulateOptions {
            output_times: Some(vec![0.0, 1.0]),
            ..Default::default()
        };
        let sol = compiled
            .simulate((0.0, 1.0), &HashMap::new(), &HashMap::new(), &opts)
            .expect("simulate succeeds");
        let x_idx = sol
            .state_variable_names
            .iter()
            .position(|n| n.ends_with("x"))
            .expect("x in solution");
        assert!(
            (sol.state[x_idx][1] - 2000.0).abs() < 1e-9,
            "x(1) should be 2000.0 (dx/dt = datetime.year = 2000), got {}",
            sol.state[x_idx][1]
        );
    }

    /// Algebraic states whose `default` does not satisfy the constraint at
    /// t=0 must be reconciled before integration starts (esm-0kt).
    #[test]
    fn algebraic_ic_reconciled_to_constraint() {
        // dD/dt = -k*G,  G = D  (so D evolves as exp(-k*t), G tracks D).
        // G's default is deliberately wrong (99.0) to prove the IC pass
        // overrides it from the algebraic body.
        let json = r#"{
            "esm": "0.4.0",
            "metadata": {"name": "TestFixture"},
            "models": {
                "M": {
                    "variables": {
                        "D": {"type": "state", "default": 1.0},
                        "G": {"type": "state", "default": 99.0},
                        "k": {"type": "parameter", "default": 1.0}
                    },
                    "equations": [
                        {
                            "lhs": {"op": "D", "args": ["D"], "wrt": "t"},
                            "rhs": {"op": "*", "args": [{"op": "-", "args": ["k"]}, "G"]}
                        },
                        {
                            "lhs": "G",
                            "rhs": "D"
                        }
                    ]
                }
            }
        }"#;
        let file = crate::parse::load(json).expect("parse fixture");
        let compiled = Compiled::from_file(&file).expect("compile succeeds");
        let opts = SimulateOptions {
            output_times: Some(vec![0.0, 1.0]),
            ..Default::default()
        };
        let sol = compiled
            .simulate((0.0, 1.0), &HashMap::new(), &HashMap::new(), &opts)
            .expect("simulate succeeds");

        let d_idx = sol
            .state_variable_names
            .iter()
            .position(|n| n.ends_with("D"))
            .expect("D in solution");
        let g_idx = sol
            .state_variable_names
            .iter()
            .position(|n| n.ends_with("G"))
            .expect("G in solution");

        assert!(
            (sol.state[d_idx][0] - 1.0).abs() < 1e-12,
            "D(0) should be 1.0, got {}",
            sol.state[d_idx][0]
        );
        // The bogus G default (99.0) must be reconciled to D(0)=1.0.
        assert!(
            (sol.state[g_idx][0] - 1.0).abs() < 1e-12,
            "G(0) should be reconciled to D(0)=1.0, got {}",
            sol.state[g_idx][0]
        );
        let expected = (-1.0_f64).exp();
        assert!(
            (sol.state[d_idx][1] - expected).abs() < 1e-6,
            "D(1) ≈ exp(-1), got {}",
            sol.state[d_idx][1]
        );
        assert!(
            (sol.state[g_idx][1] - sol.state[d_idx][1]).abs() < 1e-12,
            "G(1) must equal D(1) by algebraic constraint"
        );
    }
}
