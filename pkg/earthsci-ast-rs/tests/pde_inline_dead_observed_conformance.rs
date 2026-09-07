//! Cross-language conformance: a §6.6.5 assertion may read an array OBSERVED
//! that NO LIVE EQUATION CONSUMES (esm-spec §6.6.5, §5.23).
//!
//! Shared fixture + Julia-minted golden live under
//! `tests/conformance/pde_inline_dead_observed/` (repo root); the Julia runner
//! (`conformance_pde_inline_dead_observed_test.jl`) and the Python runner
//! (`test_pde_inline_dead_observed_conformance.py`) gate the same golden.
//!
//! An inline test's natural target is a quantity computed FOR the test — a
//! tendency, a flux, a diagnostic — which by construction nothing else reads.
//! Model `M` declares two such dead observeds: `diag = 2*base`, and
//! `chain = diag + base`, which is dead AND reads a dead observed. Julia
//! refused both (`array state 'diag' has no cells in var_map`) because its
//! build inlines an elementwise array observed into its readers and drops the
//! equation, and a dead one has no readers to be inlined into; Rust REQUESTS
//! the asserted observed from the runtime, which never asked whether anything
//! else reads it, so it already answered them. This suite pins that against
//! the reference binding.
//!
//! The only state is `u`, integrated with a zero right-hand side, so the
//! trajectory is constant and every assertion is exact under any pinned solver
//! family: a divergence here is a semantics divergence, never an integrator one.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::run_pde_tests_with_base_dir;
use earthsci_ast::{Alg, SolveOptions, load_string};
use std::fs;
use std::path::PathBuf;

mod common;

fn category_dir() -> PathBuf {
    common::repo_fixture("conformance/pde_inline_dead_observed")
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
fn dead_observed_matches_golden() {
    let dir = category_dir();
    let manifest = read_json(&dir.join("manifest.json"));
    assert_eq!(
        manifest["category"].as_str(),
        Some("pde_inline_dead_observed")
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

        // Gate each assertion against BOTH the golden actual (the cross-binding
        // anchor) and the fixture's own declared `expected` (author intent).
        let find = |idx: usize| {
            results
                .iter()
                .find(|r| r.assertion_idx == idx)
                .unwrap_or_else(|| panic!("missing assertion {idx}"))
        };
        let close = |actual: f64, want: f64| {
            let diff = (actual - want).abs();
            diff <= atol || diff <= rtol * want.abs().max(actual.abs())
        };
        for g in expected {
            let idx = g["assertion_idx"].as_u64().expect("assertion_idx") as usize;
            let r = find(idx);
            assert!(r.passed, "assertion {idx}: {}", r.message);
            let actual = r
                .actual
                .unwrap_or_else(|| panic!("assertion {idx}: no actual"));
            let want = g["actual"].as_f64().expect("golden actual");
            assert!(
                close(actual, want),
                "assertion {idx}: actual {actual} vs golden {want}"
            );
        }
        for a in fx["assertions"].as_array().expect("fixture assertions") {
            let idx = a["assertion_idx"].as_u64().expect("assertion_idx") as usize;
            let r = find(idx);
            assert_eq!(r.variable, a["variable"].as_str().expect("variable"));
            let want = a["expected"].as_f64().expect("expected");
            let actual = r.actual.expect("actual");
            assert!(
                close(actual, want),
                "assertion {idx}: actual {actual} vs declared expected {want}"
            );
        }
    }
}
