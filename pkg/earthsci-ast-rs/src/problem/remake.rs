//! `remake` and ensembles: a Problem rebound to new values without a rebuild.

use super::*;

// =============================================================================
// remake
// =============================================================================

/// The substitutions [`remake`] applies. Every field is optional; an omitted
/// field is inherited unchanged.
#[derive(Debug, Clone, Default)]
pub struct Remake {
    /// Replacement parameter bindings, merged over the EsmProblem's.
    pub p: HashMap<String, f64>,
    /// Replacement initial-state bindings, merged over the EsmProblem's.
    pub u0: HashMap<String, f64>,
    /// A different integration interval.
    pub tspan: Option<(f64, f64)>,
    /// Replacement callbacks. `None` inherits the EsmProblem's set.
    pub callbacks: Option<CallbackSet>,
}

/// A NEW EsmProblem with `changes` applied and everything else shared (§2.5.5).
///
/// Does not mutate `prob`, and does not redo the parts of construction the
/// substitution cannot have invalidated: the compiled right-hand side, the
/// build-time fields and the materialized provider data are shared by `Rc`, not
/// rebuilt. A changed parameter value does not re-fetch provider data or
/// recompile.
///
/// **Refusal is deliberate.** A substitution the EsmProblem cannot honour without
/// a rebuild raises [`SimulateError::UnsubstitutableBinding`], naming the
/// binding and the class that makes it un-substitutable, rather than silently
/// rebuilding or silently ignoring it. Two classes refuse: a parameter that was
/// baked into the build (it is a load-time constant of the compiled RHS, not a
/// solver input), and a name that is not a parameter of the compiled system at
/// all.
pub fn remake(prob: &EsmProblem, changes: &Remake) -> Result<EsmProblem, SimulateError> {
    // Re-arm the document's working precision for the duration of this call
    // (`domain.element_type`, esm-spec §11.3); a no-op for a Float64 document.
    let _precision_guard = prob.precision.enter();
    // Each new key designates one parameter of the compiled system by the
    // esm-spec §6.6.2 rules, as Julia's `remake_parameters` and Python's
    // `remake` resolve it: an ambiguous key, or two keys for one parameter,
    // is refused here rather than at the next solve.
    let names = prob.parameter_names();
    let keys = crate::simulate::KeyResolver::new(
        crate::simulate::KeyPolicy::Spec,
        names.iter().map(String::as_str),
        crate::simulate::namespace_scope(
            names.iter().map(String::as_str),
            prob.model_name.as_deref(),
        ),
    );
    let canonical: HashMap<&str, String> = keys
        .canonical(changes.p.keys().map(String::as_str))
        .map_err(crate::simulate::param_key_error)?
        .into_iter()
        .map(|(name, k)| (k, name))
        .collect();

    // A baked parameter is recorded under the spelling the build saw; a key
    // refuses when the parameter it designates and that spelling designate
    // one parameter, either one spelling the other (esm-spec §6.6.2).
    let model = prob.model_name.as_deref();
    let same_parameter = |a: &str, b: &str| {
        crate::simulate::key_spells(a, b, model).is_some()
            || crate::simulate::key_spells(b, a, model).is_some()
    };
    let mut keys_in_order: Vec<&String> = changes.p.keys().collect();
    keys_in_order.sort();
    for name in keys_in_order {
        let designated = canonical.get(name.as_str());
        let spelled = designated.map_or(name.as_str(), String::as_str);
        if let Some(baked) = prob
            .build
            .baked_parameters
            .iter()
            .find(|b| same_parameter(b, spelled) || same_parameter(b, name))
        {
            let class = if prob.build.join_baked_parameters.contains(baked) {
                "baked into the build as a load-time constant, because a join reads it — an \
                 `on` key column or an `overlap` envelope factor such as a cell ring, \
                 directly or through observeds — and the match set or candidate pairs it \
                 decides are built once (CONFORMANCE_SPEC §5.5.6, §5.5.8); it is baked \
                 everywhere it is read, not only there — build a new EsmProblem"
            } else {
                "baked into the build as a load-time constant — build a new EsmProblem"
            };
            return Err(SimulateError::UnsubstitutableBinding {
                name: name.clone(),
                class: class.to_string(),
            });
        }
        if prob.is_dynamic() && designated.is_none() && !keys.designates_any(name) {
            return Err(SimulateError::UnsubstitutableBinding {
                name: name.clone(),
                class: "not a parameter of the compiled system".to_string(),
            });
        }
    }

    let mut p = prob.p.clone();
    p.extend(changes.p.iter().map(|(k, v)| (k.clone(), *v)));
    let mut u0 = prob.u0.clone();
    u0.extend(changes.u0.iter().map(|(k, v)| (k.clone(), *v)));
    let tspan = changes.tspan.unwrap_or(prob.tspan);

    // The remade span's own boundaries, from every refresh time (the
    // original's were cut to its span, which a remake may widen).
    #[cfg(not(target_arch = "wasm32"))]
    let boundaries: Vec<f64> = match &prob.refresh {
        Some(exec) => exec
            .borrow()
            .refresh_times()
            .into_iter()
            .filter(|&b| b > tspan.0 && b < tspan.1)
            .collect(),
        None => Vec::new(),
    };

    Ok(EsmProblem {
        doc: Rc::clone(&prob.doc),
        solver: prob.solver.clone(),
        model_name: prob.model_name.clone(),
        precision: prob.precision.clone(),
        tspan,
        p,
        u0,
        backend: Rc::clone(&prob.backend),
        build: Rc::clone(&prob.build),
        inspection: std::cell::RefCell::new(prob.inspection.borrow().clone()),
        inspect: prob.inspect,
        // The backend is SHARED (`Rc::clone` above), so the compiler and its
        // per-rule record carry over verbatim: a remake re-binds values, it
        // never rebuilds a right-hand side, and reporting a compiler the
        // derivative did not run would be a lie about which one produced its
        // numbers.
        compiler: prob.compiler,
        compiler_report: prob.compiler_report.clone(),
        callbacks: changes
            .callbacks
            .clone()
            .unwrap_or_else(|| prob.callbacks.clone()),
        // The bound providers are SHARED: a remade EsmProblem reads the SAME
        // forcing buffer (the backend is shared), and refetching what
        // construction fetched is exactly the work §2.5.5 forbids redoing. A
        // solve of either Problem samples the providers at its own start and
        // refreshes them at its own boundaries, so the two never integrate
        // each other's records.
        #[cfg(not(target_arch = "wasm32"))]
        refresh: prob.refresh.clone(),
        #[cfg(not(target_arch = "wasm32"))]
        discrete_forcing: prob.discrete_forcing.clone(),
        #[cfg(not(target_arch = "wasm32"))]
        refresh_boundaries: boundaries,
        #[cfg(not(target_arch = "wasm32"))]
        provider_keys: prob.provider_keys.clone(),
        program_source: prob.program_source.clone(),
        runtime_array_parameters: prob.runtime_array_parameters,
        stripped: Rc::clone(&prob.stripped),
        strip_source: prob.strip_source.clone(),
    })
}

// =============================================================================
// Ensembles
// =============================================================================

/// A EsmProblem plus a per-trajectory rewrite, and the family it stands for
/// (§2.5.8) — the canonical form for parameter sweeps, Monte Carlo over
/// declared distributions, and perturbed initial conditions.
pub struct EnsembleProblem<'a> {
    prob: &'a EsmProblem,
    trajectories: usize,
    #[allow(clippy::type_complexity)]
    rewrite: Box<dyn Fn(&EsmProblem, usize) -> Result<Remake, SimulateError> + 'a>,
}

impl std::fmt::Debug for EnsembleProblem<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EnsembleProblem")
            .field("trajectories", &self.trajectories)
            .field("prob", self.prob)
            .finish()
    }
}

impl<'a> EnsembleProblem<'a> {
    /// Wrap `prob` with a rewrite applied once per trajectory index.
    ///
    /// The rewrite returns a [`Remake`], not a EsmProblem, so every trajectory
    /// goes through the same refusal rules and shares the same compiled
    /// right-hand side.
    pub fn new(
        prob: &'a EsmProblem,
        trajectories: usize,
        rewrite: impl Fn(&EsmProblem, usize) -> Result<Remake, SimulateError> + 'a,
    ) -> Self {
        Self {
            prob,
            trajectories,
            rewrite: Box::new(rewrite),
        }
    }

    /// The base EsmProblem.
    pub fn problem(&self) -> &EsmProblem {
        self.prob
    }

    /// How many trajectories the family holds.
    pub fn trajectories(&self) -> usize {
        self.trajectories
    }

    /// The EsmProblem for trajectory `i`.
    pub fn trajectory(&self, i: usize) -> Result<EsmProblem, SimulateError> {
        let changes = (self.rewrite)(self.prob, i)?;
        remake(self.prob, &changes)
    }
}

/// Solve every trajectory of `ens`, in index order (§2.5.8).
#[cfg(feature = "solve")]
pub fn solve_ensemble(
    ens: &EnsembleProblem<'_>,
    opts: &SolveOptions,
) -> Result<Vec<Solution>, SimulateError> {
    let mut out = Vec::with_capacity(ens.trajectories());
    for i in 0..ens.trajectories() {
        let prob = ens.trajectory(i)?;
        out.push(solve(&prob, opts)?);
    }
    Ok(out)
}
