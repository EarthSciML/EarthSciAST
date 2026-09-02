use super::*;

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
    /// Per-state `ic(state) = rhs` initial value (esm-spec §11.4), resolved
    /// against the PARAMETER scope only — §6.6.5 binds the model's parameters
    /// as load-time constants in a build-time expression, and state is not in
    /// scope (there is no trajectory value at build time). `None` where the
    /// state declares no `ic`, which falls back to its declared `default`.
    state_ic_exprs: Vec<Option<ResolvedExpr>>,
    /// State indices that are algebraic, in dependency-respecting order. Each
    /// algebraic state's expression may reference differential states,
    /// parameters, time, observed variables, or *earlier-listed* algebraic
    /// states. Cycles are rejected at compile time.
    algebraic_topo: Vec<usize>,
    /// The working precision this model was COMPILED under
    /// (`crate::precision`), captured so evaluation reproduces it even when the
    /// caller reaches a `Compiled` directly rather than through an
    /// `EsmProblem`. Constant folding at build and evaluation at run must round
    /// the same way, and the only way to guarantee that is for the artifact to
    /// carry the precision its constants were folded in.
    precision: crate::precision::Env,
}

/// Internal classification of how a state variable is defined.
#[derive(Debug, Clone)]
pub(super) enum StateKind {
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

        // EVERY parameter, of every cadence. A DISCRETE parameter is
        // piecewise-constant between refreshes, and this scalar backend has no
        // refresh machinery — but it must still RESOLVE, seeded at its declared
        // `default`, or every expression naming one fails to compile. The
        // driver-level segmented solve (`crate::provider`) is what actually
        // rewrites such a value between segments. Since esm-libraries-spec
        // §4.7.5 step 4 the cadence subsets PARTITION `parameters` rather than
        // sitting beside it, so one map is the whole set.
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
            state_ic_raw,
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

        // (7) Resolve each `ic(state) = rhs` (esm-spec §11.4) in the BUILD-TIME
        // scope: model parameters are load-time constants and bind (§6.6.5);
        // state and observed do not, so an empty state/observed table turns a
        // reference to either into the ordinary unknown-variable build error
        // rather than a silently-zero read at u0.
        let empty_scope: HashMap<String, usize> = HashMap::new();
        let state_ic_exprs = state_ic_raw
            .iter()
            .map(|slot| {
                slot.as_ref()
                    .map(|rhs| resolve_expr(rhs, &empty_scope, &param_index, &empty_scope, None))
                    .transpose()
            })
            .collect::<Result<Vec<_>, _>>()?;

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
            state_ic_exprs,
            algebraic_topo,
            precision: crate::precision::Env::capture(),
        })
    }

    /// Convenience: flatten the model first, then build.
    pub fn from_model(model: &Model) -> Result<Self, CompileError> {
        let flat = flatten_model(model)?;
        Self::from_flattened(&flat)
    }

    /// Convenience: flatten the file first, then build.
    ///
    /// Arms the document's `domain.element_type` for the build
    /// (`crate::precision`), so a `Compiled` reached directly — without an
    /// `EsmProblem` — folds its constants in the declared precision and
    /// records it. `EsmProblem` has already armed the same value by the time
    /// it gets here, and re-arming the same mode is a no-op.
    pub fn from_file(file: &EsmFile) -> Result<Self, CompileError> {
        let env = crate::precision_infer::env_of_file(file)?;
        let _precision_guard = env.enter();
        // Under a per-variable element type the equations need their precision
        // boundaries marked before they are lowered; `None` — and no copy —
        // for every document that declares none.
        let annotated = crate::precision_infer::annotated(file)?;
        let file = annotated.as_ref().unwrap_or(file);
        let flat = flatten(file)?;
        Self::from_flattened(&flat)
    }

    /// Whether this model has anything for the ODE solver to integrate — at
    /// least one `D(state, t) = rhs` equation. A system of purely ALGEBRAIC
    /// states is reconstructed from its expressions and never integrated.
    pub fn has_differential_equations(&self) -> bool {
        self.state_kinds
            .iter()
            .any(|k| matches!(k, StateKind::Differential(_)))
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
    #[cfg(feature = "solve")]
    pub fn solve(
        &self,
        tspan: (f64, f64),
        params: &HashMap<String, f64>,
        initial_conditions: &HashMap<String, f64>,
        opts: &SolveOptions,
    ) -> Result<Solution, SimulateError> {
        // Re-arm the precision this model was compiled under
        // (`crate::precision`); a no-op for a Float64 model.
        let _precision_guard = self.precision.enter();
        let (t0, t_end) = tspan;

        let param_vec = self.build_param_vec(params)?;
        let mut ic_vec = self.build_initial_state(initial_conditions, &param_vec, t0)?;
        self.apply_algebraic_ics(&mut ic_vec, &param_vec, t0);

        let (time, mut state, stats, retcode) =
            self.integrate(t0, t_end, &param_vec, &ic_vec, opts)?;
        self.reconstruct_algebraic_trajectory(&time, &mut state, &param_vec);

        Ok(Solution {
            time,
            state,
            state_variable_names: self.state_names.clone(),
            retcode,
            metadata: SolutionMetadata {
                alg: solver_name(opts.alg).to_string(),
                n_rhs_calls: stats.n_rhs_calls,
                n_jacobian_calls: stats.n_jacobian_calls,
                n_accepted_steps: stats.n_accepted_steps,
                n_rejected_steps: stats.n_rejected_steps,
                // The scalar interpreter builds no tape, so there is nothing to
                // fall back FROM.
                tape_fallbacks: Vec::new(),
            },
        })
    }

    /// Validate user-supplied parameters (every key must be a known param)
    /// and build the parameter vector in canonical order: user value >
    /// declared default; a parameter with neither is an error.
    fn build_param_vec(&self, params: &HashMap<String, f64>) -> Result<Vec<f64>, SimulateError> {
        // esm-spec §6.6.2 keys `parameter_overrides` by LOCAL parameter name
        // (`A`), while flattening qualifies it (`M.A`). Canonicalize first so
        // both spellings bind, then reject anything that still designates no
        // parameter — an unknown key is `InvalidParameter`, a bare name two
        // components both carry is the distinct `AmbiguousParameter`.
        let params =
            canonicalize_override_keys(&self.param_index, params).map_err(param_key_error)?;
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
    /// variable) and build the initial state vector in the esm-spec §11.4
    /// precedence: an explicit `initial_conditions` override wins ("Run-time
    /// overrides ... overrides the `ic` equation's value for that run"), else
    /// the state's own `ic` equation const-folded in the parameter scope
    /// (§6.6.5), else the declared `default`; a state with none of the three
    /// is an error.
    fn build_initial_state(
        &self,
        initial_conditions: &HashMap<String, f64>,
        param_vec: &[f64],
        t0: f64,
    ) -> Result<Vec<f64>, SimulateError> {
        // Same §6.6.2 canonicalization as `build_param_vec`, on the state side.
        let initial_conditions = canonicalize_override_keys(&self.state_index, initial_conditions)
            .map_err(ic_key_error)?;
        let no_state: [f64; 0] = [];
        let no_obs: [f64; 0] = [];
        let mut ic_vec = vec![0.0f64; self.state_names.len()];
        for (i, name) in self.state_names.iter().enumerate() {
            if let Some(&v) = initial_conditions.get(name) {
                ic_vec[i] = v;
            } else if let Some(expr) = self.state_ic_exprs[i].as_ref() {
                // `ic` bodies resolve against the parameter scope alone (see
                // `state_ic_exprs`), so the empty state/observed buffers here
                // are never indexed.
                ic_vec[i] = interpret(expr, &no_state, param_vec, &no_obs, t0);
            } else if let Some(d) = self.state_defaults[i] {
                ic_vec[i] = d;
            } else if matches!(self.state_kinds[i], StateKind::Algebraic(_)) {
                // An algebraic state's initial value is DETERMINED, not supplied.
                //
                // `apply_algebraic_ics` runs immediately after this and
                // overwrites this slot by interpreting the state's own defining
                // body (esm-0kt), so whatever goes here is discarded before the
                // solve begins. Demanding a `default` therefore rejected a
                // perfectly well-posed model — `NOx = NO + NO2` needs no initial
                // condition, because it HAS one the moment NO and NO2 do.
                //
                // Only a DIFFERENTIAL state genuinely needs a starting value,
                // and that case still errors below.
                //
                // Callers used to paper over this themselves: the TypeScript
                // binding injected a placeholder for exactly these states before
                // calling the solver, which meant a model ran in the browser and
                // failed on a server that called the same function directly.
                ic_vec[i] = 0.0;
            } else {
                return Err(SimulateError::InvalidInitialCondition { name: name.clone() });
            }
        }
        Ok(ic_vec)
    }

    /// Every observed variable's value at `t`, evaluated against an EMPTY
    /// state vector — the state-free build-time evaluation behind
    /// [`crate::problem::observed_field`].
    ///
    /// Only meaningful when the system has no state variables. The observed
    /// bodies are then pure functions of the parameters and `t`, and the
    /// topological order [`Self::observed_variable_names`] already carries
    /// makes one forward pass enough — no solver, and no build pipeline.
    /// A `ResolvedExpr::State` would index the empty slice, so callers MUST
    /// check `state_variable_names().is_empty()` first.
    ///
    /// Names are FLATTENED names (`Sites.North.u`), which is the spelling
    /// `observed_field` resolves against in every binding.
    pub(crate) fn evaluate_static_observeds(
        &self,
        params: &HashMap<String, f64>,
        t: f64,
    ) -> Result<Vec<(String, f64)>, SimulateError> {
        // Re-arm the precision this model was compiled under
        // (`crate::precision`); a no-op for a Float64 model.
        let _precision_guard = self.precision.enter();
        debug_assert!(
            self.state_names.is_empty(),
            "evaluate_static_observeds is only defined for a state-free system"
        );
        let param_vec = self.build_param_vec(params)?;
        let no_state: [f64; 0] = [];
        let mut obs = vec![0.0f64; self.observed_exprs.len()];
        for (i, e) in self.observed_exprs.iter().enumerate() {
            // Each observed is evaluated at the element type of the variable it
            // defines (esm-spec §11.3.1) — the document's unless that variable
            // declared its own, which is why this is a thread-local read and a
            // no-op swap for every document that declares none.
            let _rule_precision = crate::precision::has_variable_overrides().then(|| {
                crate::precision::enter(crate::precision::of_variable(&self.observed_names[i]))
            });
            obs[i] = interpret(e, &no_state, &param_vec, &obs, t);
        }
        Ok(self.observed_names.iter().cloned().zip(obs).collect())
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
    #[cfg(feature = "solve")]
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
    #[cfg(feature = "solve")]
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
    #[cfg(feature = "solve")]
    fn integrate(
        &self,
        t0: f64,
        t_end: f64,
        param_vec: &[f64],
        ic_vec: &[f64],
        opts: &SolveOptions,
    ) -> IntegrateResult {
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
        // Each arm runs the solver, then reads the real step/eval counters out of
        // diffsol before the concrete solver is dropped: RHS + Jacobian evals from
        // the equations' per-op `OpStatistics` (via `eqn_eval_stats`, available on
        // any `OdeSolverMethod`), accepted/rejected steps from each solver's
        // concrete `get_statistics()` (`BdfStatistics`, shared by Bdf/Sdirk/Erk).
        let (time, state, stats, retcode) = match opts.alg {
            Alg::Bdf => {
                let mut solver: Bdf<'_, _, NewtonNonlinearSolver<_, FaerLU<f64>, _>> = problem
                    .bdf::<FaerLU<f64>>()
                    .map_err(|e| SimulateError::DiffsolError {
                        details: e.to_string(),
                    })?;
                let (time, state, retcode) = run_solver(&mut solver, t_end, opts)?;
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
                let (time, state, retcode) = run_solver(&mut solver, t_end, opts)?;
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
                let (time, state, retcode) = run_solver(&mut solver, t_end, opts)?;
                let bs = solver.get_statistics();
                let stats = SolveStats::from_solver(
                    &solver,
                    bs.number_of_steps,
                    bs.number_of_error_test_failures + bs.number_of_nonlinear_solver_fails,
                );
                (time, state, stats, retcode)
            }
        };
        Ok((time, state, stats, retcode))
    }

    /// The trajectories of the named observed variables over an output grid.
    ///
    /// The companion to [`Self::evaluate_static_observeds`] for a system that
    /// DOES integrate. An observed is a pure function of `(state, params, t)`;
    /// the compiled system holds the function and the caller's solution holds
    /// the arguments, which is exactly why neither alone can answer and why
    /// this takes both.
    ///
    /// One forward pass per output time over the already-topo-sorted graph —
    /// the same pass [`Self::reconstruct_algebraic_trajectory`] makes, which
    /// computes every one of these values and then keeps only the algebraic
    /// states. Every requested name is filled from that one pass rather than
    /// re-walking the graph per name.
    ///
    /// `state` is read as given. A solution's algebraic rows have already been
    /// reconstructed by the time a caller has one, so no second fixup is
    /// wanted here — doing it again would be harmless but would say that this
    /// function knows something about solution provenance that it does not.
    ///
    /// Returns `InvalidParameter` for a name that is not an observed variable;
    /// the caller resolves spellings (API_SPEC §5.8) before getting here.
    #[cfg(feature = "solve")]
    pub(crate) fn observed_trajectories(
        &self,
        names: &[String],
        time: &[f64],
        state: &[Vec<f64>],
        params: &HashMap<String, f64>,
    ) -> Result<Vec<Vec<f64>>, SimulateError> {
        let slots: Vec<usize> = names
            .iter()
            .map(|n| {
                self.observed_names
                    .iter()
                    .position(|o| o == n)
                    .ok_or_else(|| SimulateError::InvalidParameter { name: n.clone() })
            })
            .collect::<Result<_, _>>()?;

        let param_vec = self.build_param_vec(params)?;
        let n_states = self.state_names.len();
        let mut out = vec![vec![0.0f64; time.len()]; names.len()];
        let mut y_eff = vec![0.0f64; n_states];
        let mut obs_buf = vec![0.0f64; self.observed_exprs.len()];

        for (k, &t) in time.iter().enumerate() {
            for (i, y) in y_eff.iter_mut().enumerate() {
                // A short row is a caller error rather than something to paper
                // over with a zero: it would produce a plausible number from a
                // state that was never there.
                *y = *state.get(i).and_then(|r| r.get(k)).ok_or_else(|| {
                    SimulateError::InvalidParameter {
                        name: format!(
                            "{} (the solution has no value at output index {k})",
                            self.state_names[i]
                        ),
                    }
                })?;
            }
            for (i, e) in self.observed_exprs.iter().enumerate() {
                obs_buf[i] = interpret(e, &y_eff, &param_vec, &obs_buf, t);
            }
            for (row, &slot) in out.iter_mut().zip(&slots) {
                row[k] = obs_buf[slot];
            }
        }
        Ok(out)
    }

    /// Reconstruct algebraic-state values along the output trajectory
    /// (esm-0kt). The integrator carries the algebraic slots forward
    /// without advancing them, so the natural state matrix shows the
    /// algebraic IC at every sample. Recompute from the differential
    /// states + parameters at each output time. No-op for a system without
    /// algebraic states.
    #[cfg(feature = "solve")]
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
#[cfg(feature = "solve")]
fn solver_name(choice: Alg) -> &'static str {
    match choice {
        Alg::Bdf => "Bdf",
        Alg::Sdirk => "Sdirk",
        Alg::Erk => "Erk",
    }
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
