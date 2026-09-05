//! Cross-language conformance: an ARRAY-shaped OBSERVED written ELEMENTWISE over
//! another array and consumed ONLY through an `index(f, j)` gather inside an
//! `aggregate` body (esm-spec §4.3.4 elementwise broadcast, §6.6.5 assertions).
//!
//! Shared fixtures + Julia-minted goldens live under
//! `tests/conformance/elementwise_observed_gather/` (repo root); the Julia
//! runner (`conformance_elementwise_observed_gather_test.jl`) and the Python
//! runner (`test_elementwise_observed_gather_conformance.py`) gate the same
//! goldens.
//!
//! `zc` is a const field shaped `[lev]`; `f = 1 + cos(pi*zc)` is the natural
//! per-level spelling; `colsum[i] = Σ_{j≤i} f[j]` and `total = Σ_j f[j]` read it
//! through gathers and nothing else reads it at all. A binding that inlines `f`
//! into its readers by name substitution turns the gather into
//! `index(1 + cos(pi*zc), j)` and must distribute it over the elementwise
//! combination down to the array leaf. Julia's tree-walk resolver tested only
//! the IMMEDIATE operands for array-ness, so the leaf under the `cos` matched
//! nothing and `zc` reached the compiler bare (`E_TREEWALK_UNBOUND_VARIABLE`,
//! issue #175); Rust and Python already evaluated the document. This suite pins
//! Rust against the reference binding so that stays true.
//!
//! The category carries a controlled PAIR: `elementwise_gather` is the shape
//! under test and `explicit_gather` is the identical field written as an
//! explicit `aggregate(k from lev; 1 + cos(pi*index(zc, k)))`. They share every
//! assertion, so this suite additionally requires them to agree with each other
//! actual-for-actual — a divergence is the gather push-down, not the physics.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::run_pde_tests_with_base_dir;
use earthsci_ast::{Alg, SolveOptions, load_string};
use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

mod common;

fn category_dir() -> PathBuf {
    common::repo_fixture("conformance/elementwise_observed_gather")
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

fn close(a: f64, b: f64, rtol: f64, atol: f64) -> bool {
    let diff = (a - b).abs();
    diff <= atol || diff <= rtol * a.abs().max(b.abs())
}

/// Run one fixture through the official runner, gate it against its golden, and
/// return its actuals keyed by `assertion_idx`.
fn run_fixture(
    dir: &PathBuf,
    manifest: &serde_json::Value,
    fx: &serde_json::Value,
) -> BTreeMap<usize, f64> {
    let rtol = manifest["tolerances"]["assertion_rtol"]
        .as_f64()
        .expect("rtol");
    let atol = manifest["tolerances"]["assertion_atol"]
        .as_f64()
        .expect("atol");
    let opts = manifest_opts(manifest);

    let esm_path = dir.join(fx["path"].as_str().expect("path"));
    let golden = read_json(&dir.join(fx["golden"].as_str().expect("golden")));
    assert_eq!(golden["reference_binding"].as_str(), Some("julia"));

    let text = fs::read_to_string(&esm_path).unwrap_or_else(|e| panic!("read {esm_path:?}: {e}"));
    let file =
        load_string(&text).unwrap_or_else(|e| panic!("fixture {esm_path:?} does not load: {e}"));
    let results = run_pde_tests_with_base_dir(&file, fx["model"].as_str(), &opts, Some(dir.as_path()));

    let expected = golden["assertions"].as_array().expect("golden assertions");
    assert_eq!(results.len(), expected.len());

    let mut actuals = BTreeMap::new();
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
        assert!(
            close(actual, want, rtol, atol),
            "{test_id}#{idx}: actual {actual} vs golden {want}"
        );
        actuals.insert(idx, actual);
    }
    actuals
}

#[test]
fn elementwise_observed_gather_matches_golden() {
    let dir = category_dir();
    let manifest = read_json(&dir.join("manifest.json"));
    assert_eq!(
        manifest["category"].as_str(),
        Some("elementwise_observed_gather")
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

    let mut by_id: BTreeMap<String, BTreeMap<usize, f64>> = BTreeMap::new();
    for fx in manifest["fixtures"].as_array().expect("fixtures") {
        let id = fx["id"].as_str().expect("id").to_string();
        by_id.insert(id, run_fixture(&dir, &manifest, fx));
    }

    // The elementwise spelling under test and the explicit-gather control must
    // agree actual-for-actual: they are the same field written two ways.
    let elementwise = by_id
        .get("elementwise_gather")
        .expect("elementwise_gather fixture");
    let explicit = by_id
        .get("explicit_gather")
        .expect("explicit_gather fixture");
    assert_eq!(
        elementwise.keys().collect::<Vec<_>>(),
        explicit.keys().collect::<Vec<_>>()
    );
    for (idx, value) in elementwise {
        let other = explicit[idx];
        assert!(
            close(*value, other, rtol, atol),
            "assertion {idx}: elementwise {value} vs explicit {other}"
        );
    }
}
