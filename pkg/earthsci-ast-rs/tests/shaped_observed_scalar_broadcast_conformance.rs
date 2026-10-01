//! Cross-language conformance: a SHAPED observed whose right-hand side is a
//! SCALAR fills every cell of its declared shape (esm-spec §4.3.4).
//!
//! Shared fixture + Julia-minted golden live under
//! `tests/conformance/shaped_observed_scalar_broadcast/` (repo root); the Julia
//! runner (`conformance_shaped_observed_scalar_broadcast_test.jl`) and the
//! Python runner (`test_shaped_observed_scalar_broadcast_conformance.py`) gate
//! the same golden.
//!
//! A scalar operand replicates along every axis of a shaped result, and a
//! right-hand side that is a scalar is the one-operand case of that rule. The
//! fixture writes it as a literal, as a scalar parameter, and as an `ifelse`
//! whose predicate is a constant, so it evaluates to its scalar branch
//! (issue #262). The wholesale observed rule stored such a value as a 0-d
//! array, which no longer matched the declared rank, so the assertion reader
//! found no field and failed with `array state '<name>' has no cells in var_map`.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Alg, SolveOptions, load_string};
use std::fs;
use std::path::PathBuf;

mod common;

fn category_dir() -> PathBuf {
    common::repo_fixture("conformance/shaped_observed_scalar_broadcast")
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
        // `Some`: the manifest NAMES both tolerances, and `SolveOptions` takes
        // `Option<f64>` so that "the caller said nothing" stays distinguishable
        // from "the caller asked for the default" (esm-spec §2.2.2).
        reltol: Some(rs["reltol"].as_f64().expect("reltol")),
        abstol: Some(rs["abstol"].as_f64().expect("abstol")),
        ..Default::default()
    }
}

#[test]
fn scalar_rhs_broadcast_matches_golden() {
    let dir = category_dir();
    let manifest = read_json(&dir.join("manifest.json"));
    assert_eq!(
        manifest["category"].as_str(),
        Some("shaped_observed_scalar_broadcast")
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
        let results = earthsci_ast::run_inline_tests_with_options(
            &file,
            // This fixture's `ifelse` has branch value boxes that differ
            // under a runtime scalar condition, which the tape cannot lower,
            // so `native` refuses it by NAME (API_SPEC §5.8). The golden it
            // is compared against is the reference evaluator's.
            &earthsci_ast::InlineTestOptions {
                model_name: fx["model"].as_str().map(str::to_string),
                solve: opts.clone(),
                base_dir: Some(dir.clone()),
                compiler: Some(earthsci_ast::Compiler::Interpreter),
                ..Default::default()
            },
            None,
        );

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
