//! Cross-language conformance: build-time value invention over a derived index
//! set (`tests/conformance/value_invention_materialize/`, issue #266).
//!
//! The Julia and Python runners gate the same manifest. A `value` case pins the
//! member count a contraction over the derived axis reads; a `refused` case pins
//! the code a producer that cannot run is refused under, with no actual — in
//! particular not the 0 an empty range contracts to.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{SolveOptions, load_string, run_inline_tests_with_base_dir};
use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

mod common;

fn category_dir() -> PathBuf {
    common::repo_fixture("conformance/value_invention_materialize")
}

fn manifest() -> serde_json::Value {
    let path = category_dir().join("manifest.json");
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

#[test]
fn manifest_requires_rust_and_both_halves() {
    let m = manifest();
    assert_eq!(m["category"].as_str(), Some("value_invention_materialize"));
    let required: Vec<&str> = m["bindings_required"]
        .as_array()
        .expect("bindings_required")
        .iter()
        .map(|v| v.as_str().expect("binding name"))
        .collect();
    assert!(required.contains(&"rust"), "manifest must require rust");
    let outcomes: BTreeSet<&str> = m["fixtures"]
        .as_array()
        .expect("fixtures")
        .iter()
        .flat_map(|fx| fx["cases"].as_array().expect("cases"))
        .map(|c| c["outcome"].as_str().expect("outcome"))
        .collect();
    assert_eq!(outcomes, BTreeSet::from(["refused", "value"]));
}

#[test]
fn value_invention_materialize_outcomes_match_the_manifest() {
    let dir = category_dir();
    let m = manifest();
    let opts = SolveOptions::default();

    for fx in m["fixtures"].as_array().expect("fixtures") {
        let id = fx["id"].as_str().expect("id");
        let esm_path = dir.join(fx["path"].as_str().expect("path"));
        let test_id = fx["test_id"].as_str().expect("test_id");
        let text =
            fs::read_to_string(&esm_path).unwrap_or_else(|e| panic!("read {esm_path:?}: {e}"));
        let file = load_string(&text)
            .unwrap_or_else(|e| panic!("fixture {esm_path:?} does not load: {e}"));
        let results =
            run_inline_tests_with_base_dir(&file, fx["model"].as_str(), &opts, Some(dir.as_path()));

        let cases = fx["cases"].as_array().expect("cases");
        assert_eq!(results.len(), cases.len(), "{id}: assertion count");
        for c in cases {
            let idx = c["assertion_idx"].as_u64().expect("assertion_idx") as usize;
            let r = results
                .iter()
                .find(|r| r.test_id == test_id && r.assertion_idx == idx)
                .unwrap_or_else(|| panic!("{id}#{idx}: no result row"));
            assert_eq!(r.variable, c["variable"].as_str().expect("variable"));
            match c["outcome"].as_str().expect("outcome") {
                "value" => {
                    assert!(r.passed, "{id}#{idx}: {}", r.message);
                    let actual = r
                        .actual
                        .unwrap_or_else(|| panic!("{id}#{idx}: no actual ({})", r.message));
                    let want = c["expected"].as_f64().expect("expected");
                    assert!(
                        (actual - want).abs() <= 1e-12 * want.abs().max(1.0),
                        "{id}#{idx}: actual {actual} vs expected {want}"
                    );
                }
                "refused" => {
                    assert!(!r.passed, "{id}#{idx}: a refusal cannot pass");
                    assert!(
                        r.actual.is_none(),
                        "{id}#{idx}: must be refused, not answered — got {:?} ({})",
                        r.actual,
                        r.message
                    );
                    let code = c["code"].as_str().expect("code");
                    assert!(r.message.contains(code), "{id}#{idx}: want `{code}`: {}", r.message);
                    if let Some(name) = c["names"].as_str() {
                        assert!(r.message.contains(name), "{id}#{idx}: want `{name}`: {}", r.message);
                    }
                }
                other => panic!("{id}#{idx}: unknown outcome {other:?}"),
            }
        }
    }
}
