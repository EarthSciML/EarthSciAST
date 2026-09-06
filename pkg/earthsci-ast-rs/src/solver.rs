//! Document-scoped solver hints (esm-spec §2.2).
//!
//! The `solver` block records numerics the document knows about *itself* —
//! stiffness, integration tolerances, and a splitting hint — which each binding
//! maps to its own integrator.
//!
//! Every field is ADVISORY: a binding may ignore any or all of them and still
//! conform. Advisory governs the MECHANISM, never the OUTCOME — the
//! CONFORMANCE_SPEC §5.9 requirement to integrate successfully and agree within
//! the error band is untouched by this block and is not excused by it.
//!
//! This module carries the parts that are NOT advisory: the spec-version gate
//! (§2.2.4) and the §2.2.2 tolerance resolution order.

use crate::diagnostic::{DiagnosticError, codes, err};
// The binding defaults (API_SPEC §5.8) live with `SolveOptions`, which is where
// they are applied; the §2.2.2 chain bottoms out on the same two constants
// rather than a second copy that could drift from them.
use crate::simulate::{DEFAULT_ABSTOL, DEFAULT_RELTOL};
use serde_json::Value;

/// Reject a top-level `solver` block in a file declaring esm < 1.1.0.
///
/// The block arrives at `esm: 1.1.0`; a document declaring an earlier version
/// that carries one is rejected with `solver_version_too_old` (esm-spec
/// §2.2.4). Mirrors [`crate::template_imports::reject_template_imports_pre_v08`].
pub fn reject_solver_pre_v11(view: &Value) -> Result<(), DiagnosticError> {
    let Some(obj) = view.as_object() else {
        return Ok(());
    };
    if !obj.contains_key("solver") {
        return Ok(());
    }
    let Some(esm) = obj.get("esm").and_then(|v| v.as_str()) else {
        return Ok(());
    };
    let Some((major, minor, _)) = crate::diagnostic::parse_semver(esm) else {
        return Ok(());
    };
    if (major, minor) >= (1, 1) {
        return Ok(());
    }
    Err(err(
        codes::SOLVER_VERSION_TOO_OLD,
        format!(
            "the top-level `solver` block requires esm >= 1.1.0; file declares {esm}. \
             Offending path: /solver"
        ),
    ))
}

/// Resolve integration tolerances most-specific first (esm-spec §2.2.2):
///
/// 1. An explicit argument at the `solve` call site — wins outright.
/// 2. Otherwise the document's `solver.abstol` / `solver.reltol`.
/// 3. Otherwise the binding default (`reltol` 1e-4, `abstol` 1e-6).
///
/// The two resolve INDEPENDENTLY, so a document declaring only `reltol` leaves
/// `abstol` on the default — the same per-field fall-through §6.6.4 uses.
///
/// These are INTEGRATION tolerances, a different quantity from the `tolerance`
/// object an assertion is COMPARED at (§6.6.4).
pub fn resolve_tolerances(
    solver: Option<&crate::types::Solver>,
    abstol: Option<f64>,
    reltol: Option<f64>,
) -> (f64, f64) {
    (
        abstol
            .or_else(|| solver.and_then(|s| s.abstol))
            .unwrap_or(DEFAULT_ABSTOL),
        reltol
            .or_else(|| solver.and_then(|s| s.reltol))
            .unwrap_or(DEFAULT_RELTOL),
    )
}

/// Map a `solver` block with nothing set to absence (esm-spec §2.2).
///
/// `"solver": {}` is legal — every other optional top-level container admits an
/// empty object, and making this one the exception would be a rule with no
/// payoff — but it means exactly what omitting the block means, so it is
/// normalized away AT LOAD. The typed document then never holds a block with
/// nothing set, and `parse -> emit` cannot disagree across bindings about
/// whether `{}` survives. Not covered by `skip_serializing_if`: that is
/// per-FIELD, so an empty `Solver` would still emit its enclosing `{}`.
pub(crate) fn normalize_empty(solver: Option<crate::types::Solver>) -> Option<crate::types::Solver> {
    let s = solver?;
    if s.stiffness.is_none() && s.abstol.is_none() && s.reltol.is_none() && s.splitting.is_none() {
        return None;
    }
    Some(s)
}
