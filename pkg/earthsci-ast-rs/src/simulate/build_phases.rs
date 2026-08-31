use super::*;

// ============================================================================
// from_flattened build phases
// ============================================================================

/// v1 scope guards for [`Compiled::from_flattened`]: only pure `t`-dimensional
/// ODE systems with no continuous or discrete events are supported.
pub(super) fn reject_unsupported_features(flat: &FlattenedSystem) -> Result<(), CompileError> {
    if flat.independent_variables != ["t"] {
        // A spatial independent variable means a rewrite-target operator was
        // never discretized. Report THAT, with the uniform
        // `unlowered_operator` code esm-spec §4.2 / §9.6.8 specifies for
        // an op reaching evaluation unlowered; the dimensionality error
        // is the fallback for a spatial axis with no such op behind it.
        if let Some(op) = crate::flatten::first_unlowered_operator(flat) {
            return Err(CompileError::UnloweredOperatorError { op });
        }
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
pub(super) struct ClassifiedEquations {
    /// `D(state, t) = rhs` RHS per state index.
    pub(super) state_diff_raw: Vec<Option<Expr>>,
    /// Bare-LHS algebraic body per state index (esm-0kt).
    pub(super) state_alg_raw: Vec<Option<Expr>>,
    /// `ic(state) = rhs` RHS per state index (esm-spec §11.4). Folded into u0
    /// by [`Compiled::build_initial_state`], never integrated.
    pub(super) state_ic_raw: Vec<Option<Expr>>,
    /// Defining RHS per raw observed index.
    pub(super) observed_rhs_raw: Vec<Option<Expr>>,
}

/// Walk `flat.equations` and classify each as a differential state
/// derivative, an algebraic state definition, or an observed assignment.
/// Then enforce that every state has a defining equation — either a
/// differential `D(state, t)` RHS or a bare-LHS algebraic body. If both are
/// present the differential equation wins (matches the Python simulation
/// runner's overdetermined-system rule, esm-y3n).
pub(super) fn classify_equations(
    flat: &FlattenedSystem,
    state_names: &[String],
    state_index: &HashMap<String, usize>,
    observed_index_raw: &HashMap<String, usize>,
) -> Result<ClassifiedEquations, CompileError> {
    let mut state_diff_raw: Vec<Option<Expr>> = vec![None; state_names.len()];
    let mut state_alg_raw: Vec<Option<Expr>> = vec![None; state_names.len()];
    let mut state_ic_raw: Vec<Option<Expr>> = vec![None; state_names.len()];
    let mut observed_rhs_raw: Vec<Option<Expr>> = vec![None; flat.observed_variables.len()];

    // An observed unknown's defining expression is an EQUATION from esm 1.0.0
    // (esm-spec §6.3.1) — a bare-variable LHS in `flat.equations`, which the
    // classification loop below picks up. The variable struct carries no
    // `expression` field to fall back to any more, and `flatten` no longer
    // produces one.

    // `ic(state) = rhs` (esm-spec §11.4) declares the target's INITIAL value,
    // not its dynamics, so `flatten` routes every one of them out of
    // `flat.equations` into `flat.field_ics`. This scalar interpreter used to
    // read only `flat.equations` and so never saw them at all: `ic(u) ~ 3.0`
    // was dropped and the state silently started at its declared `default`.
    // (The ARRAY runtime in `simulate_array` already consumes `field_ics`;
    // only this pathway ignored them.)
    // A target that is not a state of this system is SKIPPED rather than
    // rejected: `ic` is also written against a discrete parameter that events
    // mutate (`ic(EventSystem.dose_counter)` in tests/simulation/event_chain.esm),
    // which has no u0 slot to seed. That has always been inert here and in
    // Julia, whose `_build_u0` simply never looks such a key up; making it an
    // error would be a separate, structural-validation decision.
    for (target, rhs) in &flat.field_ics {
        if let Some(&idx) = state_index.get(target) {
            state_ic_raw[idx] = Some(rhs.clone());
        }
    }
    for eq in &flat.equations {
        if let Some(state_name) = state_lhs_name(&eq.lhs) {
            let idx = state_index.get(&state_name).ok_or_else(|| {
                CompileError::build_err(format!(
                    "Equation defines D({state_name}, t) but '{state_name}' \
                             is not in flat.state_variables"
                ))
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
            return Err(CompileError::build_err(format!(
                "State variable '{name}' has no D({name}, t) = ... equation in \
                     flat.equations. Cannot simulate."
            )));
        }
    }

    Ok(ClassifiedEquations {
        state_diff_raw,
        state_alg_raw,
        state_ic_raw,
        observed_rhs_raw,
    })
}

/// Output of [`resolve_observed`]: observed names in evaluation order, the
/// matching name -> index table, and the resolved defining expressions
/// (parallel to the ordered names).
pub(super) type ResolvedObserved = (Vec<String>, HashMap<String, usize>, Vec<ResolvedExpr>);

/// Topologically sort observed variables and resolve their defining
/// expressions to typed indices. Each observed expression may only reference
/// state, params, time, or *earlier* observed variables; the dependency set
/// per observed variable is restricted to other observed names. Returns the
/// names in evaluation order, the matching name -> index table, and the
/// resolved expressions (parallel to the ordered names).
pub(super) fn resolve_observed(
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

    let order = topo_sort(&obs_deps).map_err(|cycle| {
        CompileError::build_err(format!(
            "Cyclic observed-variable dependency: {:?}",
            cycle
                .into_iter()
                .map(|i| observed_names_raw[i].clone())
                .collect::<Vec<_>>()
        ))
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
            // An observed variable with no defining expression (no equation and no
            // `variable.expression`) is undefined. Fail the build naming it, rather
            // than silently substituting the constant 0.0 — which turned a modelling
            // mistake into a plausible-looking zero trajectory.
            let expr = raw.as_ref().ok_or_else(|| {
                CompileError::build_err(format!(
                    "Observed variable '{}' has no defining expression (no \
                     equation and no `expression` field); cannot simulate.",
                    observed_names[i]
                ))
            })?;
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
pub(super) fn order_algebraic_states(
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
        CompileError::build_err(format!(
            "Cyclic algebraic equations detected: {}",
            cycle
                .into_iter()
                .map(|i| state_names[i].clone())
                .collect::<Vec<_>>()
                .join(" -> ")
        ))
    })
}

/// Build the per-state classification + resolved defining expression: a
/// [`StateKind::Differential`] for each `D(state, t)` RHS, a
/// [`StateKind::Algebraic`] for each bare-LHS algebraic body (every state has
/// exactly one after [`classify_equations`]).
pub(super) fn build_state_kinds(
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
