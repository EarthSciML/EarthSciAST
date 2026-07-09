//! Solver plumbing on [`ArrayCompiled`]: `simulate` / `simulate_inspect`
//! (diffsol problem build, RHS/Jacobian closures, scalar-observed trajectory
//! exposure), the `debug_*` RHS entry points, and the external forcing-channel
//! handle ([`ArrayCompiled::forcing_handle`]).

use super::*;
use crate::simulate::{SimulateError, SimulateOptions, Solution, SolutionMetadata, SolverChoice};
use diffsol::{Bdf, FaerLU, FaerMat, NewtonNonlinearSolver, OdeBuilder, Sdirk, VectorHost};
use std::collections::HashSet;

impl ArrayCompiled {
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

    pub fn state_variable_names(&self) -> &[String] {
        &self.scalar_state_names
    }
    pub fn parameter_names(&self) -> &[String] {
        &self.param_names
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
        evaluate_rhs_with_scratch(
            &self.rhs_rules,
            &self.observed_rules,
            &self.var_shapes,
            &self.param_names,
            state,
            &param_vec,
            &self.forcing,
            t,
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
        RhsScratch::new(&self.var_shapes)
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
            &self.rhs_rules,
            &self.observed_rules,
            &self.var_shapes,
            &self.param_names,
            state,
            param_vec,
            &self.forcing,
            t,
            dy,
            false,
            stats,
            scratch,
        );
    }

    /// Resolve the deferred scoped-reference / array `ic` equations
    /// (esm-spec §11.4.1) into per-slot initial values keyed by flat state slot.
    /// A loaded-field RHS (`InitialConditions.O3_init`) is read from the
    /// provider-seeded forcing buffer and folded into the lifted grid state's cells
    /// (column-major, matching the slot enumeration in [`Self::from_model`]); a
    /// constant RHS broadcasts to every cell. Empty on the non-`ic` path.
    fn resolve_field_ics(
        &self,
        params: &HashMap<String, f64>,
    ) -> Result<HashMap<usize, f64>, SimulateError> {
        let mut out: HashMap<usize, f64> = HashMap::new();
        if self.field_ics.is_empty() {
            return Ok(out);
        }
        let forcing = self.forcing.borrow();
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
            for flat in 0..total {
                let multi = flat_to_multi_col_major(flat, &vs.shape);
                let slot = vs.flat_offset + flat;
                out.insert(
                    slot,
                    resolve_field_ic_cell(
                        target,
                        rhs,
                        &multi,
                        &forcing,
                        &self.index_sets,
                        params,
                        &mut cached_field,
                    )?,
                );
            }
        }
        Ok(out)
    }

    /// Run the simulation.
    /// Rewrite override-map keys to the BARE names this single-model system uses,
    /// stripping a leading `<namespace>.` when present (WS3 parity). A no-op clone
    /// when `namespace` is `None` (the already-namespaced `from_flattened` path)
    /// or when a key carries no such prefix.
    fn normalize_override_keys(&self, m: &HashMap<String, f64>) -> HashMap<String, f64> {
        let Some(ns) = &self.namespace else {
            return m.clone();
        };
        let prefix = format!("{ns}.");
        m.iter()
            .map(|(k, v)| {
                let key = k
                    .strip_prefix(&prefix)
                    .map(str::to_string)
                    .unwrap_or_else(|| k.clone());
                (key, *v)
            })
            .collect()
    }

    /// Validate override parameter names and build the positional param
    /// vector (override > variable default; a parameter with neither is an
    /// [`SimulateError::InvalidParameter`]). The strict simulate-time
    /// counterpart of the lenient [`Self::debug_resolve_params`].
    fn build_param_vec(&self, params: &HashMap<String, f64>) -> Result<Vec<f64>, SimulateError> {
        // Validate param names and build the param vec.
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

    /// Validate override initial-condition names and build the initial state
    /// vector `u0`. Scoped-reference / array `ic` fields (esm-spec §11.4.1)
    /// are folded in from the provider-seeded forcing buffer (DESIGN
    /// pde_simulation_pipeline §2 R2); priority per slot: explicit
    /// `initial_conditions` override > loaded field ic > variable default (a
    /// slot with none of the three is an
    /// [`SimulateError::InvalidInitialCondition`]).
    fn build_initial_state(
        &self,
        initial_conditions: &HashMap<String, f64>,
        param_vec: &[f64],
    ) -> Result<Vec<f64>, SimulateError> {
        // Validate IC names and build the initial state vector.
        for key in initial_conditions.keys() {
            if !self.scalar_state_index.contains_key(key) {
                return Err(SimulateError::InvalidInitialCondition { name: key.clone() });
            }
        }
        // Resolved scalar-parameter scope (load-time constants) for the ic
        // coordinate-expression path — a parameter-dependent grid-geometry
        // template (`x0 + (i − 1/2)·dx`) binds here; STATE is not in scope.
        let resolved_params: HashMap<String, f64> = self
            .param_names
            .iter()
            .cloned()
            .zip(param_vec.iter().copied())
            .collect();
        let field_ic_map = self.resolve_field_ics(&resolved_params)?;
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

    pub fn simulate(
        &self,
        tspan: (f64, f64),
        params: &HashMap<String, f64>,
        initial_conditions: &HashMap<String, f64>,
        opts: &SimulateOptions,
    ) -> Result<Solution, SimulateError> {
        self.simulate_inspect(tspan, params, initial_conditions, opts, None)
    }

    /// [`Self::simulate`] with an optional build-observability sink (see
    /// [`BuildInspection`]). When `inspect` is `Some`, the sink is filled —
    /// after the initial state vector is assembled and before the solver runs —
    /// with the state-free observed arrays materialized at `u0`/`t0` and every
    /// observed rule's resolved body expression. The integration itself is
    /// byte-identical with or without a sink.
    pub fn simulate_inspect(
        &self,
        tspan: (f64, f64),
        params: &HashMap<String, f64>,
        initial_conditions: &HashMap<String, f64>,
        opts: &SimulateOptions,
        inspect: Option<&mut BuildInspection>,
    ) -> Result<Solution, SimulateError> {
        // CONST / single-segment: no discrete forcing, no refresh boundaries.
        self.simulate_core(
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

    /// [`Self::simulate_inspect`] with a DISCRETE-cadence forcing refresh. The
    /// integration is SEGMENTED on `boundaries` (solver-second refresh anchors);
    /// at each boundary `refresh_fn(t)` re-slices the live forcing buffer to that
    /// record. Observeds transitively reaching a `discrete_forcing` name are
    /// excluded from the build-once static hoist, so they recompute over the
    /// refreshed buffer per segment while the CONST terrain regrid stays hoisted.
    /// This is the Rust analog of the ESS-Julia live-field taint + segmented driver.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn simulate_with_refresh_inspect(
        &self,
        tspan: (f64, f64),
        params: &HashMap<String, f64>,
        initial_conditions: &HashMap<String, f64>,
        opts: &SimulateOptions,
        inspect: Option<&mut BuildInspection>,
        discrete_forcing: &HashSet<String>,
        boundaries: &[f64],
        refresh_fn: impl FnMut(f64) -> Result<(), SimulateError>,
    ) -> Result<Solution, SimulateError> {
        self.simulate_core(
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
    fn simulate_core(
        &self,
        tspan: (f64, f64),
        params: &HashMap<String, f64>,
        initial_conditions: &HashMap<String, f64>,
        opts: &SimulateOptions,
        inspect: Option<&mut BuildInspection>,
        discrete_forcing: &HashSet<String>,
        boundaries: &[f64],
        mut refresh_fn: impl FnMut(f64) -> Result<(), SimulateError>,
    ) -> Result<Solution, SimulateError> {
        // WS3 override-naming parity: on the single-model path names are BARE
        // (`R_0`), but callers (and the Julia toolkit) key overrides by the
        // namespaced `Model.R_0`. Strip this model's `<namespace>.` prefix from
        // any override key so both forms resolve; keys without the prefix pass
        // through unchanged. No-op on the already-namespaced `from_flattened` path.
        let params_owned = self.normalize_override_keys(params);
        let ics_owned = self.normalize_override_keys(initial_conditions);
        let (t0, t_end) = tspan;
        let n_states = self.n_states;

        // Validate the override names and build the positional param vector
        // and the initial state vector `u0` (loaded-field / coordinate
        // `ic`s folded in — see [`Self::build_initial_state`]).
        let param_vec = self.build_param_vec(&params_owned)?;
        let ic_vec = self.build_initial_state(&ics_owned, &param_vec)?;

        // Seed the forcing buffer at t0 BEFORE the static hoist reads it — a
        // no-op for the CONST/single-segment path; for DISCRETE it primes the
        // first record so the static regrid geometry sees a populated buffer.
        refresh_fn(t0)?;

        // Hoist the STATE-FREE / `t`-free observeds (ess: static-observed hoist)
        // out of the per-step RHS. Within a single `simulate` call the forcing
        // buffer is constant (the free `simulate` never refreshes it between
        // segments), so a rule whose transitive references reach no state
        // variable and no `t` is CONSTANT across the whole solve: the
        // conservative-regrid geometry (`intersect_polygon` over the src×tgt cell
        // rings), the regridded terrain and its slopes, the Rothermel
        // coefficients derived from the CONST forcing. Materialize them ONCE here
        // and seed them into every RHS eval, rather than recomputing the
        // (expensive) regrid on every step. A model with no such observeds hoists
        // nothing and stays byte-identical to the un-hoisted path.
        let static_names = self.classify_static_observeds(discrete_forcing);
        let static_rules: Vec<AlgebraicRule> = self
            .observed_rules
            .iter()
            .filter(|r| static_names.contains(observed_rule_var(r)))
            .cloned()
            .collect();
        let varying_rules: Vec<AlgebraicRule> = self
            .observed_rules
            .iter()
            .filter(|r| !static_names.contains(observed_rule_var(r)))
            .cloned()
            .collect();
        let static_rings_cell: RefCell<HashMap<String, ArrayD<f64>>> =
            RefCell::new(HashMap::new());
        let sa0 = build_state_arrays(&self.var_shapes, &ic_vec);
        let static_obs = materialize_observeds(
            &static_rules,
            &sa0,
            &param_vec,
            &self.param_names,
            t0,
            // The regrid's FAQ rings are produced AND consumed within this
            // one-time static pass (its ring-consuming aggregates are themselves
            // static), so the sink is discarded after — no varying rule reads a
            // static ring, and each RHS eval starts from empty `derived_rings`.
            &static_rings_cell,
            &self.forcing,
        );
        drop(static_rings_cell);

        // Build observability (see `BuildInspection`): the hoisted static
        // observeds ARE the build-once products (regrid geometry, regridded
        // terrain, slopes). Nothing downstream consults the sink, so the
        // integration is unchanged.
        if let Some(insp) = inspect {
            self.fill_inspection(insp, &static_obs, &static_names, &param_vec);
            // Segmented (DISCRETE) run: the time-varying regrid observeds (the
            // ERA5 t_xy/rh_xy/u_xy/v_xy over the first hour's slice) are NOT in
            // the static hoist, so ALSO snapshot them at t0 into `setup_arrays` —
            // a caller reading the build-time per-cell forcing (the runner's
            // forcing print) then still sees the ERA5 fields at their t=0 record.
            if !boundaries.is_empty() {
                let dr: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
                let mut snapshot = static_obs.clone();
                materialize_observeds_append(
                    &mut snapshot,
                    &varying_rules,
                    &sa0,
                    &param_vec,
                    &self.param_names,
                    t0,
                    &dr,
                    &self.forcing,
                    // Build-time t0 snapshot: vectorized overlay (bit-identical).
                    false,
                    &mut RhsStats::default(),
                );
                for rule in &varying_rules {
                    let name = observed_rule_var(rule);
                    if let Some(a) = snapshot.get(name) {
                        insp.setup_arrays.insert(name.clone(), a.clone());
                    }
                }
            }
        }

        let solver_name = match opts.solver {
            SolverChoice::Bdf => "Bdf",
            SolverChoice::Sdirk => "Sdirk",
            SolverChoice::Erk => "Erk",
        };

        // CONST / single-segment (or no output grid to align segment samples on):
        // the original un-segmented run — byte-identical to the pre-segmentation
        // driver (one `run_one_segment` over the whole span with `opts` verbatim).
        if boundaries.is_empty() || opts.output_times.is_none() {
            let (time, mut state) = self.run_one_segment(
                t0,
                t_end,
                &ic_vec,
                &param_vec,
                &static_obs,
                &varying_rules,
                opts,
            )?;
            let mut state_variable_names = self.scalar_state_names.clone();
            self.append_scalar_observed_trajectories(
                &time,
                &mut state,
                &mut state_variable_names,
                &param_vec,
                &static_obs,
                &varying_rules,
            );
            return Ok(Solution {
                time,
                state,
                state_variable_names,
                metadata: SolutionMetadata {
                    solver: solver_name.to_string(),
                    ..Default::default()
                },
            });
        }

        // DISCRETE: integrate in segments split on the refresh boundaries. Segment
        // endpoints = t0, each boundary strictly inside (t0, t_end) ascending, t_end.
        let mut endpoints: Vec<f64> = vec![t0];
        for &b in boundaries {
            if b > t0 && b < t_end && *endpoints.last().unwrap() < b {
                endpoints.push(b);
            }
        }
        if *endpoints.last().unwrap() < t_end {
            endpoints.push(t_end);
        }

        let global_out = opts.output_times.clone().expect("output grid checked Some");
        let mut u0 = ic_vec.clone();
        let mut time: Vec<f64> = Vec::new();
        let mut state: Vec<Vec<f64>> = vec![Vec::new(); n_states];

        for w in endpoints.windows(2) {
            let (a, b) = (w[0], w[1]);
            // Refresh the live buffer at the START of every segment after the
            // first (t0 was already primed by `refresh_fn(t0)` above).
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
            let seg_opts = SimulateOptions {
                output_times: Some(grid),
                ..opts.clone()
            };
            let (seg_time, seg_state) = self.run_one_segment(
                a,
                b,
                &u0,
                &param_vec,
                &static_obs,
                &varying_rules,
                &seg_opts,
            )?;
            // `run_solver` pushes the REQUESTED grid time verbatim, so a float
            // equality against `requested`/`b` is exact.
            for (i, &t) in seg_time.iter().enumerate() {
                if t == b {
                    u0 = (0..n_states).map(|r| seg_state[r][i]).collect();
                }
                if requested.iter().any(|&g| g == t) {
                    time.push(t);
                    for r in 0..n_states {
                        state[r].push(seg_state[r][i]);
                    }
                }
            }
        }

        // Expose scalar observed trajectories alongside the states (see
        // [`Self::append_scalar_observed_trajectories`]). Note: this re-evaluates
        // the varying observeds against the CURRENT (last-segment) forcing buffer,
        // so an appended scalar observed reading a discrete forcing reflects the
        // final hour — the array STATE trajectory (the fire front) is per-segment
        // correct, which is what the runner reads.
        let mut state_variable_names = self.scalar_state_names.clone();
        self.append_scalar_observed_trajectories(
            &time,
            &mut state,
            &mut state_variable_names,
            &param_vec,
            &static_obs,
            &varying_rules,
        );

        Ok(Solution {
            time,
            state,
            state_variable_names,
            metadata: SolutionMetadata {
                solver: solver_name.to_string(),
                ..Default::default()
            },
        })
    }

    /// Integrate ONE segment `[t0, t_end]` from initial state `u0`, reading the
    /// live forcing buffer (`self.forcing`) — which a segmented driver refreshes
    /// between segments. Builds a fresh RHS/Jacobian closure pair (each scratch
    /// pre-seeded with the already-materialized `static_obs`) and a fresh diffsol
    /// problem, returning the states at `opts.output_times`.
    #[allow(clippy::too_many_arguments)]
    fn run_one_segment(
        &self,
        t0: f64,
        t_end: f64,
        u0: &[f64],
        param_vec: &[f64],
        static_obs: &ArrMap,
        varying_rules: &[AlgebraicRule],
        opts: &SimulateOptions,
    ) -> Result<(Vec<f64>, Vec<Vec<f64>>), SimulateError> {
        let n_states = self.n_states;
        let rhs_rules = self.rhs_rules.clone();
        let var_shapes = self.var_shapes.clone();
        let param_names = self.param_names.clone();

        let rhs_rules_jac = rhs_rules.clone();
        let varying_rules_rhs = varying_rules.to_vec();
        let varying_rules_jac = varying_rules.to_vec();
        let var_shapes_jac = var_shapes.clone();
        let param_names_jac = param_names.clone();

        // Per-closure reusable scratch (ess-mro), pre-seeded ONCE with the
        // hoisted static observeds (retained in place across steps, never
        // re-cloned) so each RHS eval materializes only the varying observeds.
        // `RefCell` gives the interior mutability diffsol's `Fn` RHS requires;
        // the Jacobian closure carries its own so the two never alias.
        let mut rhs_scratch_val = RhsScratch::new(&var_shapes);
        rhs_scratch_val.set_static(static_obs.clone());
        let rhs_scratch = RefCell::new(rhs_scratch_val);
        let mut jac_scratch_val = RhsScratch::new(&var_shapes_jac);
        jac_scratch_val.set_static(static_obs.clone());
        let jac_scratch = RefCell::new(jac_scratch_val);

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
            let mut scratch = rhs_scratch.borrow_mut();
            evaluate_rhs_with_scratch(
                &rhs_rules,
                &varying_rules_rhs,
                &var_shapes,
                &param_names,
                y_s,
                p_s,
                &forcing_rhs,
                t,
                dy_s,
                false,
                &mut RhsStats::default(),
                &mut scratch,
            );
        };

        let jac_closure = move |y: &diffsol::FaerVec<f64>,
                                p: &diffsol::FaerVec<f64>,
                                t: f64,
                                v: &diffsol::FaerVec<f64>,
                                jv: &mut diffsol::FaerVec<f64>| {
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
            let mut scratch = jac_scratch.borrow_mut();
            evaluate_rhs_with_scratch(
                &rhs_rules_jac,
                &varying_rules_jac,
                &var_shapes_jac,
                &param_names_jac,
                y_s,
                p_s,
                &forcing_jac,
                t,
                &mut f_y,
                false,
                &mut RhsStats::default(),
                &mut scratch,
            );
            evaluate_rhs_with_scratch(
                &rhs_rules_jac,
                &varying_rules_jac,
                &var_shapes_jac,
                &param_names_jac,
                &y_perturbed,
                p_s,
                &forcing_jac,
                t,
                &mut f_yp,
                false,
                &mut RhsStats::default(),
                &mut scratch,
            );
            let jv_s = jv.as_mut_slice();
            for i in 0..n {
                jv_s[i] = (f_yp[i] - f_y[i]) / eps;
            }
        };

        let abstol = opts.abstol;
        let reltol = opts.reltol;
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

        let out = match opts.solver {
            SolverChoice::Bdf => {
                let mut solver: Bdf<'_, _, NewtonNonlinearSolver<_, FaerLU<f64>, _>> = problem
                    .bdf::<FaerLU<f64>>()
                    .map_err(|e| SimulateError::DiffsolError {
                        details: e.to_string(),
                    })?;
                crate::simulate::run_solver(&mut solver, t_end, opts)?
            }
            SolverChoice::Sdirk => {
                let mut solver: Sdirk<'_, _, FaerLU<f64>> = problem
                    .tr_bdf2::<FaerLU<f64>>()
                    .map_err(|e| SimulateError::DiffsolError {
                        details: e.to_string(),
                    })?;
                crate::simulate::run_solver(&mut solver, t_end, opts)?
            }
            SolverChoice::Erk => {
                let mut solver = problem.tsit45().map_err(|e| SimulateError::DiffsolError {
                    details: e.to_string(),
                })?;
                crate::simulate::run_solver(&mut solver, t_end, opts)?
            }
        };
        Ok(out)
    }

    /// Expose scalar observed trajectories (e.g. an `area` FAQ) alongside the
    /// states so inline conformance assertions can read algebraic quantities
    /// (RFC §8.1; CONFORMANCE_SPEC.md §5.8). The integrator carries only the
    /// state vector, so re-evaluate the (dependency-ordered, derived-ring-aware)
    /// observeds from the state trajectory at each output node and append the
    /// scalar ones as extra rows (with matching entries in
    /// `state_variable_names`). Array-valued observeds (the clip ring, the
    /// const polygons) are not scalar rows and are skipped. Mirrors the Python
    /// `_simulate_with_numpy` output-observed exposure. A model with no
    /// observed rules (or an empty trajectory) is untouched.
    fn append_scalar_observed_trajectories(
        &self,
        time: &[f64],
        state: &mut Vec<Vec<f64>>,
        state_variable_names: &mut Vec<String>,
        param_vec: &[f64],
        static_obs: &ArrMap,
        varying_rules: &[AlgebraicRule],
    ) {
        if self.observed_rules.is_empty() || time.is_empty() {
            return;
        }
        // Which observeds resolve to scalars? Reconstruct the full observed
        // picture at each node by SEEDING the hoisted static observeds (constant
        // across nodes — the regrid geometry, terrain slopes, Rothermel
        // coefficients) and materializing only the VARYING rules over them, so the
        // expensive build-once conservative regrid is NOT recomputed at every one
        // of the NT output nodes (which, unhoisted, dominated the whole run).
        let obs_at = |k: usize| -> ArrMap {
            let flat: Vec<f64> = (0..self.n_states).map(|i| state[i][k]).collect();
            let sa = build_state_arrays(&self.var_shapes, &flat);
            let dr: RefCell<HashMap<String, ArrayD<f64>>> = RefCell::new(HashMap::new());
            let mut obs = ArrMap::default();
            for (name, arr) in static_obs {
                obs.insert(name.clone(), arr.clone());
            }
            materialize_observeds_append(
                &mut obs,
                varying_rules,
                &sa,
                param_vec,
                &self.param_names,
                time[k],
                &dr,
                &self.forcing,
                // Per-segment observed snapshot (inspection): vectorized overlay.
                false,
                &mut RhsStats::default(),
            );
            obs
        };
        let obs0 = obs_at(0);
        let scalar_obs: Vec<String> = self
            .observed_rules
            .iter()
            .map(|r| observed_rule_var(r).clone())
            .filter(|name| obs0.get(name).map(|a| a.ndim() == 0).unwrap_or(false))
            .collect();
        if !scalar_obs.is_empty() {
            let mut rows: Vec<Vec<f64>> = vec![Vec::with_capacity(time.len()); scalar_obs.len()];
            for k in 0..time.len() {
                let obs = if k == 0 { obs0.clone() } else { obs_at(k) };
                for (j, name) in scalar_obs.iter().enumerate() {
                    rows[j].push(
                        obs.get(name)
                            .and_then(|a| a.first().copied())
                            .unwrap_or(f64::NAN),
                    );
                }
            }
            for (name, row) in scalar_obs.into_iter().zip(rows) {
                state_variable_names.push(name);
                state.push(row);
            }
        }
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
    fn classify_static_observeds(&self, discrete_forcing: &HashSet<String>) -> HashSet<String> {
        let observed_names: HashSet<&String> =
            self.observed_rules.iter().map(observed_rule_var).collect();
        let mut static_set: HashSet<String> = HashSet::new();
        for rule in &self.observed_rules {
            let mut refs = HashSet::new();
            collect_expr_var_refs(observed_rule_body(rule), &mut refs);
            let ok = refs.iter().all(|r| {
                r != "t"
                    && !self.var_shapes.contains_key(r)
                    // A DISCRETE (hourly) forcing buffer is a LIVE field the driver
                    // refreshes between segments — an observed reaching it must NOT
                    // freeze at setup; it recomputes over the refreshed buffer. (A
                    // CONST forcing, e.g. terrain, is absent here and stays static.)
                    && !discrete_forcing.contains(r)
                    && (!observed_names.contains(r) || static_set.contains(r))
            });
            if ok {
                static_set.insert(observed_rule_var(rule).clone());
            }
        }
        static_set
    }

    /// Fill a [`BuildInspection`] sink from the already-hoisted static observeds:
    /// record every rule's resolved body expression, the resolved scalar
    /// parameters, and the arrays of the static (state-free / `t`-free) subset
    /// (`static_obs`, materialized once by the caller). Read-only with respect to
    /// the run.
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
            insp.observed_exprs
                .insert(observed_rule_var(rule).clone(), observed_rule_body(rule).clone());
        }
        for name in static_names {
            if let Some(a) = static_obs.get(name) {
                insp.setup_arrays.insert(name.clone(), a.clone());
            }
        }
    }
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
    use crate::parse::load;

    fn arr1(v: &[f64]) -> ArrayD<f64> {
        ArrayD::from_shape_vec(IxDyn(&[v.len()]), v.to_vec()).unwrap()
    }

    /// A model whose state derivative reads an external forcing array `w`
    /// elementwise: `D(u[i]) = w[i]`, i ∈ [1,3]. `w` is declared in no variable
    /// block — it is a loader-fed field that resolves through the forcing buffer
    /// (the new lowest-precedence binding), precisely the channel PR-1 adds.
    fn forced_model() -> ArrayCompiled {
        let json = r#"{
         "esm": "0.1.0",
         "metadata": {"name": "forcing_channel"},
         "models": {
          "Forced": {
           "variables": {"u": {"type": "state", "shape": ["i"], "default": 0.0}},
           "equations": [
            {
             "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                     "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
                     "ranges": {"i": [1, 3]}},
             "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                     "ranges": {"i": [1, 3]},
                     "expr": {"op": "index", "args": ["w", "i"]}}
            }
           ]
          }
         }
        }"#;
        let file = load(json).expect("parse forcing model");
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
        let opts = SimulateOptions::default();
        let sol = compiled
            .simulate((0.0, 1.0), &params, &ics, &opts)
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
        let json = r#"{
         "esm": "0.1.0",
         "metadata": {"name": "param_path"},
         "models": {
          "P": {
           "variables": {
             "u": {"type": "state", "shape": ["i"]},
             "k": {"type": "parameter"}
           },
           "equations": [
            {
             "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                     "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
                     "ranges": {"i": [1, 2]}},
             "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                     "ranges": {"i": [1, 2]},
                     "expr": {"op": "*", "args": ["k", {"op": "index", "args": ["u", "i"]}]}}
            }
           ]
          }
         }
        }"#;
        let file = load(json).expect("parse param model");
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
        let json = r#"{
         "esm": "0.8.0",
         "metadata": {"name": "fn_array_path"},
         "models": {
          "F": {
           "variables": {
             "u": {"type": "state", "shape": ["i"]},
             "code": {"type": "parameter"},
             "looked_up": {"type": "observed", "expression": {
                "op": "fn", "name": "interp.linear", "args": [
                   {"op": "const", "value": [10.0, 20.0, 40.0, 80.0, 160.0], "args": []},
                   {"op": "const", "value": [0.0, 1.0, 2.0, 3.0, 4.0], "args": []},
                   "code"]}}
           },
           "equations": [
            {
             "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                     "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
                     "ranges": {"i": [1, 2]}},
             "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
                     "ranges": {"i": [1, 2]},
                     "expr": "looked_up"}
            }
           ]
          }
         }
        }"#;
        let file = load(json).expect("parse fn model");
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
