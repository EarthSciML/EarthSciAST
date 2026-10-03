//! Shared helpers for the integration-test suite.
//!
//! Fixture files live in the REPO-ROOT `tests/` tree (shared across the five
//! language bindings), two directories above this crate. Every test file
//! previously re-implemented this path climb under a different helper name
//! (`fixture_dir`, `fixture_path`, `fixtures_root`, `fixtures_dir`, ...);
//! use these instead.
//!
//! Each integration-test binary compiles its own copy of this module, so
//! helpers a given binary does not use are expected — hence the allow.
#![allow(dead_code)]

use std::path::PathBuf;

/// The repo-root `tests/` directory (the cross-binding fixture tree).
pub fn repo_tests_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests")
}

/// Absolute path of a fixture given its path relative to the repo-root
/// `tests/` directory (e.g. `"valid/units_conversions.esm"`).
pub fn repo_fixture(rel: &str) -> PathBuf {
    repo_tests_dir().join(rel)
}

/// Read and `load_string()` a fixture given its repo-root-relative `tests/` path,
/// panicking with the offending path on failure.
pub fn load_repo_fixture(rel: &str) -> earthsci_ast::EsmFile {
    let path = repo_fixture(rel);
    let content = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read fixture {}: {e}", path.display()));
    earthsci_ast::load_string(&content)
        .unwrap_or_else(|e| panic!("fixture {} does not load: {e}", path.display()))
}

/// Give every ODE state (a `D` target on some equation's left-hand side) that
/// declares no `default` a starting value of 0.0. Several corpus documents
/// leave their states' starting values to the harness; built without one they
/// are refused (`E_TREEWALK_MISSING_INITIAL_VALUE`, esm-spec §11.4).
pub fn supply_state_defaults(doc: &mut serde_json::Value) {
    fn d_target(lhs: &serde_json::Value) -> Option<String> {
        match lhs.get("op").and_then(|o| o.as_str()) {
            Some("D") => {
                let a = lhs.get("args")?.get(0)?;
                a.as_str()
                    .map(str::to_string)
                    .or_else(|| a.get("args")?.get(0)?.as_str().map(str::to_string))
            }
            Some("faq") => d_target(lhs.get("expr")?),
            _ => None,
        }
    }
    let Some(models) = doc.get_mut("models").and_then(|m| m.as_object_mut()) else {
        return;
    };
    for model in models.values_mut() {
        let targets: Vec<String> = model
            .get("equations")
            .and_then(|e| e.as_array())
            .map(|eqs| eqs.iter().filter_map(|e| d_target(e.get("lhs")?)).collect())
            .unwrap_or_default();
        let Some(vars) = model.get_mut("variables").and_then(|v| v.as_object_mut()) else {
            continue;
        };
        for t in targets {
            if let Some(v) = vars.get_mut(&t)
                && v.get("default").is_none()
            {
                v["default"] = serde_json::json!(0.0);
            }
        }
    }
}
