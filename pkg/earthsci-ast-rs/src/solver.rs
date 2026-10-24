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
use std::path::Path;

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
            "/solver/external: \"{external}\" carries an unexpanded '${{...}}' variable. \
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

/// Whether `path` begins with a drive letter, `C:/` or `C:\`, which esm-spec
/// §2.2.6 reads as absolute on every host.
fn is_drive_path(path: &str) -> bool {
    let b = path.as_bytes();
    b.len() >= 3 && b[0].is_ascii_alphabetic() && b[1] == b':' && matches!(b[2], b'/' | b'\\')
}

fn is_absolute_location_path(path: &str) -> bool {
    path.starts_with('/') || is_drive_path(path)
}

/// RFC 3986 §5.2.4 dot-segment removal on a `/`-separated absolute path,
/// lexically: `.` dropped, `..` removes the preceding segment, a `..` at the
/// root dropped.
fn remove_dot_segments(path: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    for seg in path.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                out.pop();
            }
            s => out.push(s),
        }
    }
    format!("/{}", out.join("/"))
}

/// An absolute `path` with its dot segments removed. A drive-letter path comes
/// back as `C:/…`, its `\` read as `/` and its drive a root that `..` does not
/// climb above.
fn lexical_absolute(path: &str) -> String {
    if is_drive_path(path) {
        format!(
            "{}{}",
            &path[..2],
            remove_dot_segments(&path[2..].replace('\\', "/"))
        )
    } else {
        remove_dot_segments(path)
    }
}

/// A host path as a `/`-separated string, or `None` when it is not UTF-8.
fn slashed(path: &Path) -> Option<String> {
    let s = path.to_str()?;
    Some(if std::path::MAIN_SEPARATOR == '/' {
        s.to_string()
    } else {
        s.replace(std::path::MAIN_SEPARATOR, "/")
    })
}

/// `dir` as the absolute, dot-segment-free directory *D* of esm-spec §2.2.6,
/// or `None` when it is not UTF-8. A relative `dir` is taken against the
/// process working directory. Purely lexical: never `realpath`, never the
/// filesystem.
pub(crate) fn absolute_directory(dir: &Path) -> Option<String> {
    let d = slashed(dir)?;
    let d = if d.is_empty() { ".".to_string() } else { d };
    if is_absolute_location_path(&d) {
        return Some(lexical_absolute(&d));
    }
    let cwd = std::env::current_dir()
        .ok()
        .and_then(|c| slashed(&c))
        .unwrap_or_else(|| "/".to_string());
    Some(lexical_absolute(&format!("{cwd}/{d}")))
}

/// `file://` plus an absolute, dot-segment-free path, each byte of its UTF-8
/// encoding outside `A-Za-z0-9-._~/:` written `%XX` (esm-spec §2.2.6). A drive
/// path gets the third slash: `file:///C:/…`.
fn file_location_url(path: &str) -> String {
    use std::fmt::Write as _;
    let mut url = String::from("file://");
    if !path.starts_with('/') {
        url.push('/');
    }
    for &b in path.as_bytes() {
        if b.is_ascii_alphanumeric() || b"-._~/:".contains(&b) {
            url.push(b as char);
        } else {
            let _ = write!(url, "%{b:02X}");
        }
    }
    url
}

/// Where the document's `solver.external` points (esm-spec §2.2.6), or
/// `Ok(None)` when the document names no run configuration.
///
/// A URL (`scheme://…`) is returned unchanged. An absolute path — `/…`, or a
/// drive-letter `C:/…` / `C:\…` — has its dot segments removed, is
/// percent-encoded and is prefixed `file://` (`file:///C:/…` for a drive).
/// Anything else is joined onto the base first: `base` when given (a relative
/// `base` is taken against the process working directory), otherwise the
/// directory recorded at load ([`EsmFile::document_base`]), otherwise, for a
/// document built in memory, the process working directory. Percent-encoding
/// writes each byte of the path's UTF-8 encoding outside `A-Za-z0-9-._~/:` as
/// `%XX`, `%` included: the input is a path, not a URL.
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
    if is_absolute_location_path(external) {
        return Ok(Some(file_location_url(&lexical_absolute(external))));
    }
    let dir = match (base, file.document_base.as_deref()) {
        (Some(b), _) => absolute_directory(b),
        (None, Some(recorded)) => Some(recorded.to_string()),
        (None, None) => absolute_directory(Path::new(".")),
    };
    let Some(dir) = dir else {
        return Err(err(
            codes::SOLVER_EXTERNAL_UNRESOLVED,
            format!(
                "/solver/external: \"{external}\" is relative, and the directory it \
                 resolves against is not valid UTF-8, so it cannot be spelled as a URL \
                 (esm-spec §2.2.6)."
            ),
        ));
    };
    Ok(Some(file_location_url(&lexical_absolute(&format!(
        "{dir}/{external}"
    )))))
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
