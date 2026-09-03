//! Cross-language conformance: esm-spec §6.6.3's assertion comparison when the
//! ACTUAL value is NOT FINITE (CONFORMANCE_SPEC §5.20).
//!
//! The shared fixture and the per-assertion verdicts live under
//! `tests/conformance/assertion_nonfinite/` (repo root); the Julia runner
//! (`conformance_assertion_nonfinite_test.jl`) and the Python runner
//! (`test_assertion_nonfinite_conformance.py`) gate the same manifest.
//!
//! This category pins VERDICTS rather than actuals, because ±Inf and NaN are
//! not JSON-representable: each case declares the class of the actual value
//! (`+inf` / `-inf` / `nan` / `finite`) and the pass/fail the §6.6.3 rule
//! requires. An assertion passes only when `actual == expected`, or both are
//! finite and within the resolved tolerance — so a non-finite actual fails
//! against every finite `expected`, whatever the tolerance.
//!
//! The defect it closes: `check_assertion` applied the tolerance bound with no
//! finiteness guard, and with `actual = ±Inf` both sides of
//! `|actual − expected| ≤ max(atol, rtol·max(|actual|, |expected|))` are `Inf`,
//! so EVERY expected value passed. Julia's `isapprox` — the semantics both the
//! Rust and the Python predicate say they mirror — carries the guard
//! (`x == y || (isfinite(x) && isfinite(y) && …)`); the two re-implementations
//! dropped it, which is exactly the kind of divergence this suite exists for.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Alg, SolveOptions, load_string, run_pde_tests_with_base_dir};
use std::fs;
use std::path::PathBuf;

mod common;

fn category_dir() -> PathBuf {
    common::repo_fixture("conformance/assertion_nonfinite")
}

fn read_json(path: &PathBuf) -> serde_json::Value {
    let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

/// The class the manifest names for one actual value.
fn class_of(v: f64) -> &'static str {
    if v.is_nan() {
        "nan"
    } else if v == f64::INFINITY {
        "+inf"
    } else if v == f64::NEG_INFINITY {
        "-inf"
    } else {
        "finite"
    }
}

#[test]
fn nonfinite_actuals_fail_every_finite_expectation() {
    let dir = category_dir();
    let manifest = read_json(&dir.join("manifest.json"));
    assert_eq!(manifest["category"].as_str(), Some("assertion_nonfinite"));
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

    for fx in manifest["fixtures"].as_array().expect("fixtures") {
        let esm_path = dir.join(fx["path"].as_str().expect("path"));
        let test_id = fx["test_id"].as_str().expect("test_id");
        let text =
            fs::read_to_string(&esm_path).unwrap_or_else(|e| panic!("read {esm_path:?}: {e}"));
        let file = load_string(&text)
            .unwrap_or_else(|e| panic!("fixture {esm_path:?} does not load: {e}"));
        let results =
            run_pde_tests_with_base_dir(&file, fx["model"].as_str(), &opts, Some(dir.as_path()));

        let cases = fx["cases"].as_array().expect("cases");
        assert_eq!(
            results.len(),
            cases.len(),
            "the fixture ran {} assertions and the manifest declares {} cases",
            results.len(),
            cases.len()
        );
        for c in cases {
            let idx = c["assertion_idx"].as_u64().expect("assertion_idx") as usize;
            let r = results
                .iter()
                .find(|r| r.test_id == test_id && r.assertion_idx == idx)
                .unwrap_or_else(|| panic!("missing assertion {test_id}#{idx}"));
            assert_eq!(
                r.variable,
                c["variable"].as_str().expect("variable"),
                "{test_id}#{idx}: the manifest and the fixture disagree on the variable"
            );
            let actual = r
                .actual
                .unwrap_or_else(|| panic!("{test_id}#{idx}: no actual ({})", r.message));
            assert_eq!(
                class_of(actual),
                c["actual_class"].as_str().expect("actual_class"),
                "{test_id}#{idx}: actual {actual} is not of the declared class"
            );
            // The verdict IS the contract.
            assert_eq!(
                r.passed,
                c["passed"].as_bool().expect("passed"),
                "{test_id}#{idx}: verdict {} (actual={actual}, expected={}, rtol={}, atol={}) — {}",
                r.passed,
                r.expected,
                r.rtol,
                r.atol,
                c["note"].as_str().unwrap_or("")
            );
            if let Some(want) = c["actual"].as_f64() {
                assert!(
                    (actual - want).abs() <= 1e-9 * want.abs(),
                    "{test_id}#{idx}: finite actual {actual} vs manifest {want}"
                );
            }
        }
    }
}
