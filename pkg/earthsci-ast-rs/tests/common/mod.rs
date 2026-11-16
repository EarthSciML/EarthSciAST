//! Shared helpers for the integration-test suite.
//!
//! Fixture files live in the REPO-ROOT `tests/` tree (shared across the five
//! language bindings), two directories above this crate. Use these helpers
//! rather than climbing from `CARGO_MANIFEST_DIR` in a test file: the paths,
//! a conformance tier's directory and manifest, its pinned solver options and
//! assertion tolerances, and the mock data providers several suites share.
//!
//! The `integration` binary and the few standalone `[[test]]` targets each
//! compile their own copy of this module, so helpers a given binary does not
//! use are expected — hence the allow.
#![allow(dead_code)]

use std::path::{Path, PathBuf};

use earthsci_ast::{Alg, AxisSel, PrepareError, PrepareProvider, SolveOptions};
use ndarray::{ArrayD, IxDyn};
use serde_json::Value;

/// The repository root, two directories above this crate.
pub fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("the crate sits two levels under the repository root")
}

/// The repo-root `tests/` directory (the cross-binding fixture tree).
pub fn repo_tests_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests")
}

/// Absolute path of a fixture given its path relative to the repo-root
/// `tests/` directory (e.g. `"valid/units_conversions.esm"`).
pub fn repo_fixture(rel: &str) -> PathBuf {
    repo_tests_dir().join(rel)
}

/// The directory of the conformance tier `category`
/// (`tests/conformance/<category>`).
pub fn category_dir(category: &str) -> PathBuf {
    repo_fixture(&format!("conformance/{category}"))
}

/// Read and parse a JSON file, panicking with the offending path on failure.
pub fn read_json(path: impl AsRef<Path>) -> Value {
    let path = path.as_ref();
    let text =
        std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {}: {e}", path.display()))
}

/// The manifest of the conformance tier `category`.
pub fn tier_manifest(category: &str) -> Value {
    read_json(category_dir(category).join("manifest.json"))
}

/// The header every cross-binding tier manifest carries: its own `category`,
/// Julia as the reference binding, and Julia, Python and Rust all required.
pub fn assert_tier_header(manifest: &Value, category: &str) {
    assert_eq!(manifest["category"].as_str(), Some(category));
    assert_eq!(manifest["reference_binding"].as_str(), Some("julia"));
    let required: Vec<&str> = manifest["bindings_required"]
        .as_array()
        .expect("bindings_required")
        .iter()
        .map(|v| v.as_str().expect("binding name"))
        .collect();
    for b in ["julia", "python", "rust"] {
        assert!(required.contains(&b), "manifest must require {b}");
    }
}

/// The manifest's `(assertion_rtol, assertion_atol)`.
pub fn assertion_tolerances(manifest: &Value) -> (f64, f64) {
    let tol = &manifest["tolerances"];
    (
        tol["assertion_rtol"].as_f64().expect("rtol"),
        tol["assertion_atol"].as_f64().expect("atol"),
    )
}

/// The solver options a tier pins for this binding (`integrators.rust`), whose
/// solver must be the explicit Runge-Kutta family.
pub fn erk_solve_options(manifest: &Value) -> SolveOptions {
    let rs = &manifest["integrators"]["rust"];
    assert_eq!(rs["solver"].as_str(), Some("Erk"));
    SolveOptions {
        alg: Alg::Erk,
        // `Some`: the manifest NAMES both tolerances, and `SolveOptions` takes
        // `Option<f64>` so that "the caller said nothing" stays distinguishable
        // from "the caller asked for the default" (esm-spec §2.2.2).
        reltol: Some(rs["reltol"].as_f64().expect("reltol")),
        abstol: Some(rs["abstol"].as_f64().expect("abstol")),
        ..Default::default()
    }
}

/// Whether `actual` is within `atol` of `want`, or within `rtol` of the larger
/// magnitude of the two.
pub fn close(actual: f64, want: f64, rtol: f64, atol: f64) -> bool {
    let diff = (actual - want).abs();
    diff <= atol || diff <= rtol * want.abs().max(actual.abs())
}

/// A data provider that serves one fixed 1-D array, wholesale.
pub struct MockConst(pub Vec<f64>);

impl PrepareProvider for MockConst {
    fn sample(&mut self) -> Result<ArrayD<f64>, PrepareError> {
        Ok(ArrayD::from_shape_vec(IxDyn(&[self.0.len()]), self.0.clone()).unwrap())
    }
}

/// `full` cut down by a pushdown selection: each `Indices` axis keeps the
/// listed positions, every other axis is kept whole.
pub fn select_axes(full: &ArrayD<f64>, selection: &[AxisSel]) -> ArrayD<f64> {
    let mut arr = full.clone();
    for (i, ax) in selection.iter().enumerate() {
        if let AxisSel::Indices(idx) = ax {
            arr = arr.select(ndarray::Axis(i), idx);
        }
    }
    arr
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
