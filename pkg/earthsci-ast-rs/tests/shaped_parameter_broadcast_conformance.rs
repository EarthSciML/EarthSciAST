//! Cross-language conformance: a SCALAR on a shaped PARAMETER broadcasts over
//! its declared grid (esm-spec §6.3 "Inline array data", §6.6.2 "Shaped
//! values").
//!
//! Shared fixture + Julia-minted golden live under
//! `tests/conformance/shaped_parameter_broadcast/` (repo root); the Julia runner
//! (`conformance_shaped_parameter_broadcast_test.jl`) and the Python runner
//! (`test_shaped_parameter_broadcast_conformance.py`) gate the same golden.
//!
//! Rust left such a parameter in its positional scalar `params` vector, which
//! holds one f64 per parameter and so cannot carry "the one value applies to
//! every element". Every per-cell read then indexed a scalar — the `index(p, k)`
//! the document writes, and the gather `index_array_leaves_by_loops` inserts for
//! a bare whole-array `D(state)` right-hand side — which `eval_index` resolves
//! to `NaN`. The right-hand side went non-finite on its first evaluation and the
//! solve died at `t = 0` with `Exceeded maximum number of nonlinear solver
//! failures`, naming no parameter at all (EarthSciML/EarthSciAST#219).
//! `lower_inline_array_parameters` now broadcasts the scalar onto the grid and
//! lowers it into the same `const` observed the array spelling already took.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::run_pde_tests_with_base_dir;
use earthsci_ast::{Alg, SolveOptions, load_string};
use std::fs;
use std::path::PathBuf;

mod common;

fn category_dir() -> PathBuf {
    common::repo_fixture("conformance/shaped_parameter_broadcast")
}

fn read_json(path: &PathBuf) -> serde_json::Value {
    let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

fn manifest_opts(manifest: &serde_json::Value) -> SolveOptions {
    let rs = &manifest["integrators"]["rust"];
    assert_eq!(rs["solver"].as_str(), Some("Erk"));
    SolveOptions {
        alg: Alg::Erk,
        reltol: rs["reltol"].as_f64().expect("reltol"),
        abstol: rs["abstol"].as_f64().expect("abstol"),
        ..Default::default()
    }
}

#[test]
fn shaped_parameter_broadcast_matches_golden() {
    let dir = category_dir();
    let manifest = read_json(&dir.join("manifest.json"));
    assert_eq!(
        manifest["category"].as_str(),
        Some("shaped_parameter_broadcast")
    );
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

    let rtol = manifest["tolerances"]["assertion_rtol"]
        .as_f64()
        .expect("rtol");
    let atol = manifest["tolerances"]["assertion_atol"]
        .as_f64()
        .expect("atol");
    let opts = manifest_opts(&manifest);

    for fx in manifest["fixtures"].as_array().expect("fixtures") {
        let esm_path = dir.join(fx["path"].as_str().expect("path"));
        let golden = read_json(&dir.join(fx["golden"].as_str().expect("golden")));
        assert_eq!(golden["reference_binding"].as_str(), Some("julia"));

        let text =
            fs::read_to_string(&esm_path).unwrap_or_else(|e| panic!("read {esm_path:?}: {e}"));
        let file = load_string(&text)
            .unwrap_or_else(|e| panic!("fixture {esm_path:?} does not load: {e}"));
        let results =
            run_pde_tests_with_base_dir(&file, fx["model"].as_str(), &opts, Some(dir.as_path()));

        let expected = golden["assertions"].as_array().expect("golden assertions");
        assert_eq!(results.len(), expected.len());

        for g in expected {
            let test_id = g["test_id"].as_str().expect("test_id");
            let idx = g["assertion_idx"].as_u64().expect("assertion_idx") as usize;
            let r = results
                .iter()
                .find(|r| r.test_id == test_id && r.assertion_idx == idx)
                .unwrap_or_else(|| panic!("missing assertion {test_id}#{idx}"));
            assert!(r.passed, "{test_id}#{idx}: {}", r.message);
            let actual = r
                .actual
                .unwrap_or_else(|| panic!("{test_id}#{idx}: no actual"));
            let want = g["actual"].as_f64().expect("golden actual");
            let diff = (actual - want).abs();
            assert!(
                diff <= atol || diff <= rtol * want.abs().max(actual.abs()),
                "{test_id}#{idx}: actual {actual} vs golden {want}"
            );
        }
    }
}

/// The reduced form of the issue's own reproducer: a bare whole-array
/// `D(theta) ~ ramp` over a shaped parameter with a scalar `default`. It is
/// NOT in the shared fixture because that spelling does not reach every
/// binding's array runtime, but it is the document #219 was filed with and it
/// exercises the OTHER Rust gather — the one the whole-array lowering inserts
/// rather than one the author wrote.
#[test]
fn bare_whole_array_derivative_over_a_broadcast_parameter() {
    let text = r#"{
      "esm": "1.0.0",
      "metadata": { "name": "MinimalShapedColumn", "authors": ["conformance"] },
      "index_sets": { "lev": { "kind": "interval", "size": 4 } },
      "models": {
        "Column": {
          "variables": {
            "ramp":  { "type": "parameter", "units": "K/s", "default": 1.0, "shape": ["lev"] },
            "theta": { "type": "unknown",   "units": "K",   "default": 1.0, "shape": ["lev"] }
          },
          "equations": [
            { "lhs": { "op": "D", "args": ["theta"], "wrt": "t" }, "rhs": "ramp" }
          ],
          "tests": [
            {
              "id": "theta_ramps",
              "time_span": { "start": 0.0, "end": 1.0 },
              "tolerance": { "abs": 1e-5, "rel": 1e-6 },
              "assertions": [
                { "variable": "theta", "time": 1.0, "coords": { "lev": 2 }, "expected": 2.0 }
              ]
            }
          ]
        }
      }
    }"#;
    let file = load_string(text).expect("document loads");
    let opts = SolveOptions {
        alg: Alg::Erk,
        reltol: 1e-12,
        abstol: 1e-14,
        ..Default::default()
    };
    let results = run_pde_tests_with_base_dir(&file, Some("Column"), &opts, None);
    assert_eq!(results.len(), 1);
    let r = &results[0];
    assert!(r.passed, "{}", r.message);
    let actual = r.actual.expect("actual");
    assert!(
        (actual - 2.0).abs() < 1e-9,
        "theta[2](1) = {actual}, want 2.0"
    );
}
