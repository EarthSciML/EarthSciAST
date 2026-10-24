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
//! This module carries the parts that are NOT advisory: the spec-version gates
//! (§2.2.4), the §2.2.2 tolerance resolution order, and the §2.2.6 resolution
//! of `solver.external` to a location.

use crate::diagnostic::{DiagnosticError, codes, err};
// The binding defaults (API_SPEC §5.8) live with `SolveOptions`, which is where
// they are applied; the §2.2.2 chain bottoms out on the same two constants
// rather than a second copy that could drift from them.
use crate::simulate::{DEFAULT_ABSTOL, DEFAULT_RELTOL};
use serde_json::Value;
use std::path::{Path, PathBuf};

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

/// Reject `solver.external` in a file declaring esm < 1.3.0.
///
/// The field arrives at `esm: 1.3.0`, after the block itself, so it carries
/// its own code (esm-spec §2.2.4 requirement 4). A 1.1.0 or 1.2.0 document
/// whose block has no `external` stays valid. Below 1.1.0 the whole block is
/// already refused by [`reject_solver_pre_v11`], which runs first.
pub fn reject_solver_external_pre_v13(view: &Value) -> Result<(), DiagnosticError> {
    let Some(obj) = view.as_object() else {
        return Ok(());
    };
    let carries_external = obj
        .get("solver")
        .and_then(Value::as_object)
        .is_some_and(|s| s.contains_key("external"));
    if !carries_external {
        return Ok(());
    }
    let Some(esm) = obj.get("esm").and_then(|v| v.as_str()) else {
        return Ok(());
    };
    let Some((major, minor, _)) = crate::diagnostic::parse_semver(esm) else {
        return Ok(());
    };
    if (major, minor) >= (1, 3) {
        return Ok(());
    }
    Err(err(
        codes::SOLVER_EXTERNAL_VERSION_TOO_OLD,
        format!(
            "`solver.external` requires esm >= 1.3.0; file declares {esm}. \
             Offending path: /solver/external"
        ),
    ))
}

/// Refuse a `solver.external` containing `${` (esm-spec §2.2.6).
///
/// Nothing is ever substituted into the reference: numerics chosen by the
/// environment are not reproducible, so a deployment-chosen run configuration
/// is a call-site argument, not a variable in the document.
fn refuse_unexpanded(external: &str) -> Result<(), DiagnosticError> {
    if !external.contains("${") {
        return Ok(());
    }
    Err(err(
        codes::SOLVER_EXTERNAL_UNRESOLVED,
        format!(
            "/solver/external {external:?} carries an unexpanded '${{...}}' variable. \
             esm-spec §2.2.6 never expands environment variables into a run-configuration \
             reference; write a path relative to this document, or pass the run \
             configuration at the call site."
        ),
    ))
}

/// The load-time half of [`refuse_unexpanded`], over the raw document. A
/// non-string `external` is left to schema validation.
pub(crate) fn reject_solver_external_unresolved(view: &Value) -> Result<(), DiagnosticError> {
    match view.pointer("/solver/external").and_then(Value::as_str) {
        Some(external) => refuse_unexpanded(external),
        None => Ok(()),
    }
}

/// Where the document's `solver.external` points (esm-spec §2.2.6), or
/// `Ok(None)` when the document names no run configuration.
///
/// A URL (`scheme://…`) is returned unchanged. An absolute path has its dot
/// segments removed and is prefixed `file://`. Anything else is joined onto
/// the base first: `base` when given (a relative `base` is taken against the
/// process working directory), otherwise the directory the document was read
/// from ([`EsmFile::document_base`]), otherwise the process working directory.
///
/// Purely lexical (RFC 3986 §5.2.4): never `realpath`, never the filesystem or
/// the network, so a location that does not exist resolves like any other.
/// The document is not changed — `emit` writes the authored string.
///
/// [`EsmFile::document_base`]: crate::EsmFile::document_base
pub fn solver_external_location(
    file: &crate::EsmFile,
    base: Option<&Path>,
) -> Result<Option<String>, DiagnosticError> {
    let Some(external) = file.solver.as_ref().and_then(|s| s.external.as_deref()) else {
        return Ok(None);
    };
    refuse_unexpanded(external)?;
    if crate::data_source_urls::is_scheme_led(external) {
        return Ok(Some(external.to_string()));
    }
    let joined = if external.starts_with('/') {
        PathBuf::from(external)
    } else {
        let dir = match (base, file.document_base.as_deref()) {
            (Some(b), _) => b.to_path_buf(),
            (None, Some(recorded)) => PathBuf::from(recorded),
            (None, None) => PathBuf::from("."),
        };
        crate::data_source_urls::absolute_base(&dir).join(external)
    };
    let resolved = crate::data_source_urls::remove_dot_segments(&joined);
    let Some(resolved) = resolved.to_str() else {
        return Err(err(
            codes::SOLVER_EXTERNAL_UNRESOLVED,
            format!(
                "/solver/external {external:?} resolves to a path that is not valid UTF-8 \
                 and so cannot be spelled as a URL (esm-spec §2.2.6)."
            ),
        ));
    };
    Ok(Some(format!("file://{resolved}")))
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
pub(crate) fn normalize_empty(
    solver: Option<crate::types::Solver>,
) -> Option<crate::types::Solver> {
    let s = solver?;
    if s.stiffness.is_none()
        && s.abstol.is_none()
        && s.reltol.is_none()
        && s.splitting.is_none()
        && s.external.is_none()
    {
        return None;
    }
    Some(s)
}
