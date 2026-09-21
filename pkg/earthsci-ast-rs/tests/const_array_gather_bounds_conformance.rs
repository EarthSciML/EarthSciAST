//! Cross-language conformance: an out-of-range const-array gather
//! (esm-spec §4.3.3, CONFORMANCE_SPEC §5.5.5 and §5.40).
//!
//! The shared fixtures live under `tests/conformance/const_array_gather_bounds/`
//! (repo root); the Julia runner (`conformance_const_array_gather_bounds_test.jl`)
//! and the Python runner (`test_const_array_gather_bounds_conformance.py`) gate
//! the same manifest. An `index` whose base is a `const` literal written inline,
//! or an observed defined by one, must fail with `E_TREEWALK_CONSTARRAY_OOB` when
//! any index lies outside its own axis; an in-range control must pass.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Alg, SolveOptions, load_string, run_inline_tests_with_base_dir};
use std::fs;

mod common;

#[test]
fn const_array_gathers_out_of_range_fail_with_the_spec_code() {
    let dir = common::repo_fixture("conformance/const_array_gather_bounds");
    let text = fs::read_to_string(dir.join("manifest.json")).expect("read manifest");
    let manifest: serde_json::Value = serde_json::from_str(&text).expect("parse manifest");
    assert_eq!(
        manifest["category"].as_str(),
        Some("const_array_gather_bounds")
    );
    assert!(
        manifest["bindings_required"]
            .as_array()
            .expect("bindings_required")
            .iter()
            .any(|b| b.as_str() == Some("rust"))
    );

    let rs = &manifest["integrators"]["rust"];
    let opts = SolveOptions {
        alg: Alg::Erk,
        reltol: rs["reltol"].as_f64(),
        abstol: rs["abstol"].as_f64(),
        ..Default::default()
    };

    let fixtures = manifest["fixtures"].as_array().expect("fixtures");
    assert!(fixtures.iter().any(|f| f["outcome"] == "error"));
    assert!(fixtures.iter().any(|f| f["outcome"] == "pass"));
    for fx in fixtures {
        let id = fx["id"].as_str().expect("id");
        let path = dir.join(fx["path"].as_str().expect("path"));
        let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
        let file = load_string(&text).unwrap_or_else(|e| panic!("{id}: does not load: {e}"));
        let results = earthsci_ast::run_inline_tests_with_options(
            &file,
            // §5.5.5 resolves an out-of-range const-array gather PER CELL by
            // its declared boundary policy, which the tape has no form for,
            // so `native` refuses these documents by NAME (API_SPEC §5.8).
            // The fault they assert is the reference evaluator's.
            &earthsci_ast::InlineTestOptions {
                model_name: fx["model"].as_str().map(str::to_string),
                solve: opts.clone(),
                base_dir: Some(dir.clone()),
                compiler: Some(earthsci_ast::Compiler::Interpreter),
                ..Default::default()
            },
            None,
        );
        assert_eq!(results.len(), 1, "{id}: expected one assertion result");
        let r = &results[0];
        match fx["outcome"].as_str().expect("outcome") {
            "pass" => {
                assert!(r.passed, "{id}: must pass, got {}", r.message);
                assert_eq!(
                    r.actual,
                    fx["expected"].as_f64(),
                    "{id}: wrong in-range value"
                );
            }
            "error" => {
                let code = fx["error_code"].as_str().expect("error_code");
                assert!(!r.passed, "{id}: must fail, got actual {:?}", r.actual);
                assert!(
                    r.message.contains(code),
                    "{id}: must report {code}, got actual {:?}: {}",
                    r.actual,
                    r.message
                );
            }
            other => panic!("{id}: unknown outcome {other}"),
        }
    }
}
