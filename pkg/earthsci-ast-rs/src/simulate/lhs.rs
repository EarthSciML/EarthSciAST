use super::*;

// ============================================================================
// Observed-unknown report
// ============================================================================

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
