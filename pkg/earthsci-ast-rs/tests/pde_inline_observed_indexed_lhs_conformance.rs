//! Cross-language conformance: the INDEXED LHS spelling of an ARRAY-shaped
//! observed (category `pde_inline_observed_indexed_lhs`).
//!
//! The shared fixture, the declared assertions and the Julia-minted goldens
//! live under `tests/conformance/pde_inline_observed_indexed_lhs/` (repo root);
//! the Julia runner (`conformance_pde_inline_observed_indexed_lhs_test.jl`) and
//! the Python runner (`test_pde_inline_observed_indexed_lhs_conformance.py`)
//! gate the same manifest.
//!
//! The defect it closes: esm-spec §6.3.1 admits TWO LHS spellings for the
//! equation that DEFINES an unknown — bare (`y ~ f(…)`) and indexed
//! (`y[i] ~ f(…)`, which defines the whole array `y`) — and neither is
//! restricted by rank, since the defining form is read through the LHS's BASE
//! NAME. Julia's tree-walk build classified equations by the SYNTACTIC
//! `lhs isa VarExpr` instead, so an array-shaped observed written the indexed
//! way matched no owner bucket and was refused outright with
//! `E_TREEWALK_UNSUPPORTED_SHAPE` on a document Rust and Python both ran
//! (issue #232).
//!
//! Both array observeds here use the indexed spelling: `wf` is STATE-FREE and
//! `ws` is STATE-DEPENDENT, the two classes a binding routes differently, so
//! fixing one path only does not pass this category.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Alg, SolveOptions, load_string, run_pde_tests_with_base_dir};
use std::fs;
use std::path::PathBuf;

mod common;

fn category_dir() -> PathBuf {
    common::repo_fixture("conformance/pde_inline_observed_indexed_lhs")
}

fn read_json(path: &PathBuf) -> serde_json::Value {
    let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

#[test]
fn indexed_lhs_array_observed_runs() {
    let dir = category_dir();
    let manifest = read_json(&dir.join("manifest.json"));
    assert_eq!(
        manifest["category"].as_str(),
        Some("pde_inline_observed_indexed_lhs")
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
        reltol: Some(rs["reltol"].as_f64().expect("reltol")),
        abstol: Some(rs["abstol"].as_f64().expect("abstol")),
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
