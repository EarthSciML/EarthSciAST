//! Cross-language conformance: esm-spec §6.6.5 assertions on a STATE-DEPENDENT
//! array OBSERVED (category `pde_inline_observed_state_dependent`).
//!
//! The shared fixture, the declared assertions and the Julia-minted goldens
//! live under `tests/conformance/pde_inline_observed_state_dependent/` (repo
//! root); the Julia runner
//! (`conformance_pde_inline_observed_state_dependent_test.jl`) and the Python
//! runner (`test_pde_inline_observed_state_dependent_conformance.py`) gate the
//! same manifest.
//!
//! The defect it closes: an array-shaped observed whose value depends on the
//! integrated state (`g = 2*u + rate`) reaches NO build-time product — only
//! STATE-FREE observeds hoist into a `BuildInspection`'s setup arrays — and is
//! not a scalar output row either, so every binding refused such an assertion
//! outright with "array state 'g' has no cells in var_map". §6.6.5 admits any
//! shaped variable in a `coords` / `reduce` assertion and §5.23 makes a
//! reference denote its expansion, so the observed must be read at the SAMPLED
//! STATE. In Rust that means the runner REQUESTS it
//! (`SolveOptions::output_observed`), which the array runtime already knows how
//! to emit as one row per cell. The fixture's `rate` is the state-free array
//! observed of the same document, asserted alongside so the
//! build-materialized path stays pinned too.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Alg, SolveOptions, load_string, run_pde_tests_with_base_dir};
use std::fs;
use std::path::PathBuf;

mod common;

fn category_dir() -> PathBuf {
    common::repo_fixture("conformance/pde_inline_observed_state_dependent")
}

fn read_json(path: &PathBuf) -> serde_json::Value {
    let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

#[test]
fn state_dependent_array_observed_is_assertable() {
    let dir = category_dir();
    let manifest = read_json(&dir.join("manifest.json"));
    assert_eq!(
        manifest["category"].as_str(),
        Some("pde_inline_observed_state_dependent")
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

    let rs = &manifest["integrators"]["rust"];
    assert_eq!(rs["solver"].as_str(), Some("Erk"));
    let opts = SolveOptions {
        alg: Alg::Erk,
        reltol: rs["reltol"].as_f64().expect("reltol"),
        abstol: rs["abstol"].as_f64().expect("abstol"),
        ..Default::default()
    };
    let rtol = manifest["tolerances"]["assertion_rtol"]
        .as_f64()
        .expect("assertion_rtol");
    let atol = manifest["tolerances"]["assertion_atol"]
        .as_f64()
        .expect("assertion_atol");

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

        let goldens = golden["assertions"].as_array().expect("golden assertions");
        assert_eq!(
            results.len(),
            goldens.len(),
            "the fixture ran {} assertions and the golden records {}",
            results.len(),
            goldens.len()
        );
        // Each assertion is gated against BOTH the golden actual (the
        // cross-binding anchor) and the fixture's own `expected`.
        for g in goldens {
            let idx = g["assertion_idx"].as_u64().expect("assertion_idx") as usize;
            let r = results
                .iter()
                .find(|r| r.assertion_idx == idx)
                .unwrap_or_else(|| panic!("missing assertion #{idx}"));
            assert_eq!(r.variable, g["variable"].as_str().expect("variable"));
            assert!(r.passed, "assertion #{idx} ({}): {}", r.variable, r.message);
            let actual = r
                .actual
                .unwrap_or_else(|| panic!("assertion #{idx}: no actual ({})", r.message));
            let want = g["actual"].as_f64().expect("golden actual");
            assert!(
                (actual - want).abs() <= atol + rtol * want.abs(),
                "assertion #{idx}: actual {actual} vs golden {want}"
            );
        }
        for decl in fx["assertions"].as_array().expect("declared assertions") {
            let idx = decl["assertion_idx"].as_u64().expect("assertion_idx") as usize;
            let r = results
                .iter()
                .find(|r| r.assertion_idx == idx)
                .unwrap_or_else(|| panic!("missing assertion #{idx}"));
            assert_eq!(r.variable, decl["variable"].as_str().expect("variable"));
            assert_eq!(r.reduce.as_deref(), decl["reduce"].as_str());
            assert_eq!(r.expected, decl["expected"].as_f64().expect("expected"));
        }
    }
}
