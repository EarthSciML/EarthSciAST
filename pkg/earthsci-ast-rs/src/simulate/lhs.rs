use super::*;

// ============================================================================
// LHS classification helpers
// ============================================================================

/// If `lhs` is `D(state_var, t)`, return the state variable name.
pub(super) fn state_lhs_name(lhs: &Expr) -> Option<String> {
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
pub(super) fn observed_lhs_name(lhs: &Expr) -> Option<String> {
    if let Expr::Variable(name) = lhs {
        Some(name.clone())
    } else {
        None
    }
}

/// Flattened names of the unknowns whose value is fixed by a bare-LHS equation
/// `x = …` (e.g. `NOx = NO + NO2`) rather than by a derivative `D(x, t) = …` —
/// the OBSERVED unknowns of esm-spec §6.3.1.
///
/// These are not user-settable initial conditions: their value is reconstructed
/// from the defining body, so an initial value supplied for one would be
/// discarded. Exposed because every host needs this distinction to build a run
/// UI — an initial-condition editor must not offer a field whose value the
/// solver is going to overwrite.
///
/// esm 1.0.0 is what makes this ONE set rather than two. Before it, a variable
/// declared `state` with a bare-LHS equation was an "algebraic state" (kept as a
/// row, reconciled at t₀) while one declared `observed` with the same equation
/// was eliminated — a difference in the DECLARATION, not in the mathematics.
/// With two declared types the distinction has nowhere to live, and §6.3.1
/// settles it the eliminable way: a bare-variable LHS makes an unknown observed.
/// [`crate::flatten`] therefore routes every one of them into
/// `observed_variables`, which is exactly the set this reports.
///
/// The precedence rule is unchanged and now lives in the shared derivation: an
/// unknown carrying BOTH a derivative and a bare-LHS equation is an ODE state,
/// not observed (esm-y3n).
pub fn algebraic_state_names(flat: &FlattenedSystem) -> Vec<String> {
    flat.observed_variables.keys().cloned().collect()
}
