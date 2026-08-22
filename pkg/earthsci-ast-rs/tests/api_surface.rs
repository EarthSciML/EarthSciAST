//! The Rust binding's public surface must equal the API manifest.
//!
//! `api-surface.json` at the repo root is the cross-language record of what
//! every binding exports (see `API_SPEC.md`). This test pins the Rust half: a
//! root re-export the manifest does not list fails, and a Rust name in the
//! manifest that the crate root does not re-export fails too.
//!
//! # Why this is not `cargo public-api`
//!
//! `cargo public-api` is the tool of record for this job, but it requires a
//! nightly toolchain (it drives `rustdoc`'s unstable JSON output) and is not
//! installed in this repo's environment — `cargo public-api --version` reports
//! `no such command`. This is the vendored equivalent, scoped to the thing that
//! actually matters for cross-language harmonisation: the crate ROOT, which is
//! the only source of `earthsci_ast::<name>` paths. It parses `src/lib.rs`'s
//! root `pub use` / `pub const` items — the crate's single declaration of "this
//! is the public name" — and additionally proves, at COMPILE time, that a
//! sample of the manifest's names really resolve (see `manifest_names_resolve`).
//!
//! Module interiors (`earthsci_ast::intern::…`, `::performance::…`,
//! `::simulate_array::…`) are extension seams under `API_SPEC.md` §3 and are
//! pinned only at module granularity, via `binding_profiles.rust.public_modules`.
//!
//! If this test fails you have changed the public API. That is allowed — but
//! regenerate the manifest in the same commit:
//!
//! ```text
//! python3 scripts/gen-api-surface.py
//! ```
//!
//! and then say in `API_SPEC.md` which tier the new symbol lands in.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

fn repo_root() -> PathBuf {
    // CARGO_MANIFEST_DIR is pkg/earthsci-ast-rs.
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
}

fn lib_rs() -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src/lib.rs");
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
}

fn manifest() -> serde_json::Value {
    let path = repo_root().join("api-surface.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
    serde_json::from_str(&text).expect("api-surface.json parses")
}

/// Strip `//`, `//!` and `///` comments so a commented-out `pub use` never
/// counts as surface. Block comments do not appear in lib.rs's item region.
fn strip_comments(src: &str) -> String {
    src.lines()
        .map(|line| match line.find("//") {
            Some(i) => &line[..i],
            None => line,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Every name reachable as `earthsci_ast::<name>`: the root `pub use`
/// re-exports plus the root `pub const`s.
fn root_surface(src: &str) -> BTreeSet<String> {
    let src = strip_comments(src);
    let mut names = BTreeSet::new();

    // `pub use module::{a, b as c, d};`
    let mut rest = src.as_str();
    while let Some(i) = rest.find("pub use ") {
        rest = &rest[i + "pub use ".len()..];
        let end = match rest.find(';') {
            Some(e) => e,
            None => break,
        };
        let item = &rest[..end];
        rest = &rest[end + 1..];
        if let (Some(open), Some(close)) = (item.find('{'), item.rfind('}')) {
            for part in item[open + 1..close].split(',') {
                let part = part.trim();
                if part.is_empty() {
                    continue;
                }
                names.insert(final_segment(part));
            }
        } else {
            names.insert(final_segment(item.trim()));
        }
    }

    // `pub const NAME: T = ...;`
    let mut rest = src.as_str();
    while let Some(i) = rest.find("pub const ") {
        rest = &rest[i + "pub const ".len()..];
        let name: String = rest
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
            .collect();
        if !name.is_empty() {
            names.insert(name);
        }
    }
    names
}

/// The name a `pub use` path binds: the alias after `as`, else the last
/// `::`-separated segment.
fn final_segment(item: &str) -> String {
    let item = item.trim();
    if let Some(idx) = item.rfind(" as ") {
        return item[idx + 4..].trim().to_string();
    }
    item.rsplit("::").next().unwrap_or(item).trim().to_string()
}

/// Root `pub mod` declarations.
fn public_modules(src: &str) -> BTreeSet<String> {
    let src = strip_comments(src);
    let mut mods = BTreeSet::new();
    for line in src.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("pub mod ") {
            let name: String = rest
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                .collect();
            if !name.is_empty() {
                mods.insert(name);
            }
        }
    }
    mods
}

/// binding entry -> spellings. A string, or a list when the binding exports
/// aliases for one canonical symbol.
fn spellings(v: &serde_json::Value) -> Vec<String> {
    match v {
        serde_json::Value::String(s) => vec![s.clone()],
        serde_json::Value::Array(a) => a
            .iter()
            .filter_map(|x| x.as_str().map(str::to_string))
            .collect(),
        _ => vec![],
    }
}

fn declared_rust_surface(m: &serde_json::Value) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for sym in m["symbols"].as_array().expect("symbols array") {
        if let Some(entry) = sym["bindings"].get("rust") {
            let kind = sym["kind"].as_str().unwrap_or("").to_string();
            for name in spellings(entry) {
                out.insert(name, kind.clone());
            }
        }
    }
    out
}

#[test]
fn root_surface_is_non_trivial() {
    // Guard against the parser silently matching nothing and every assertion
    // below passing vacuously.
    let surface = root_surface(&lib_rs());
    assert!(
        surface.len() > 200,
        "parsed only {} root exports out of lib.rs; expected the full surface",
        surface.len()
    );
}

#[test]
fn exports_nothing_the_manifest_does_not_declare() {
    let declared = declared_rust_surface(&manifest());
    let extra: Vec<_> = root_surface(&lib_rs())
        .into_iter()
        .filter(|n| !declared.contains_key(n))
        .collect();
    assert!(
        extra.is_empty(),
        "re-exported from the crate root but absent from api-surface.json:\n  {}\n\
         Add them by re-running `python3 scripts/gen-api-surface.py`, then assign \
         each a tier in API_SPEC.md.",
        extra.join("\n  ")
    );
}

#[test]
fn exports_everything_the_manifest_declares() {
    let surface = root_surface(&lib_rs());
    let missing: Vec<_> = declared_rust_surface(&manifest())
        .into_keys()
        .filter(|n| !surface.contains(n))
        .collect();
    assert!(
        missing.is_empty(),
        "declared for rust in api-surface.json but not re-exported from the crate root:\n  {}\n\
         Either restore the export or drop it from the manifest — dropping a \
         `stable` symbol is a major-version break (API_SPEC.md §3).",
        missing.join("\n  ")
    );
}

#[test]
fn public_module_list_matches_the_manifest() {
    let m = manifest();
    let declared: BTreeSet<String> = m["binding_profiles"]["rust"]["public_modules"]
        .as_array()
        .expect("public_modules array")
        .iter()
        .filter_map(|v| v.as_str().map(str::to_string))
        .collect();
    let actual = public_modules(&lib_rs());
    assert_eq!(
        actual, declared,
        "the crate's `pub mod` list changed; a module is an extension seam and \
         must be declared in api-surface.json"
    );
}

/// Compile-time proof that the manifest's names are real paths, not just
/// strings that happen to appear in lib.rs. If any of these is renamed or
/// removed, this test file stops compiling — which is a test failure.
///
/// A representative sample rather than all 280: the textual check above already
/// covers the full set, and this one exists to catch the case where lib.rs says
/// `pub use x::Y` for a `Y` that no longer exists behind a `cfg`.
#[test]
#[allow(unused_imports, deprecated)]
fn manifest_names_resolve() {
    use earthsci_ast::{
        // Core format surface.
        EsmFile, Expr, Metadata, Model, ModelVariable, ReactionSystem, load, save,
        // Classification (esm-spec §6.3.1).
        algebraic_unknowns, is_ode_state, observed_unknowns, ode_states, system_kind,
        // Flatten / validate / display / canonicalize.
        FlattenedSystem, ValidationResult, canonical_json, canonicalize, flatten, to_ascii,
        to_latex, to_unicode, validate,
        // Expression operations.
        free_variables, parse_expression, simplify, substitute,
        // Errors.
        EsmError, ExpressionParseError, SchemaError, StructuralError,
        // Versions.
        SCHEMA_VERSION, VERSION,
    };
}
