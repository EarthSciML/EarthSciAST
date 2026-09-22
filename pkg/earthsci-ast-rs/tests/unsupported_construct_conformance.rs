//! Cross-language conformance for the three constructs neither Rust evaluator
//! runs: a continuous event, a discrete event and an implicit equation (issues
//! #264, #356).
//!
//! Drives the shared manifest at `tests/conformance/unsupported_construct/`.
//! All three used to validate and then vanish on the array evaluator's
//! single-model route — the event never fired and the residual was never
//! solved, so an inline test reported a number the document does not describe —
//! while the scalar interpreter and the coupled route refused both kinds of
//! event under a different wording, and the scalar interpreter ignored an
//! implicit equation whenever its unknown had another defining equation. Every
//! refusal case must now fail with `unsupported_construct` naming the construct
//! and the evaluator; the control must still run.

use earthsci_ast::{SolveOptions, load_path, run_inline_tests_with_base_dir};
use serde_json::Value;
use std::path::{Path, PathBuf};

fn category_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance/unsupported_construct")
}

/// A missing manifest is a hard failure, not a skip.
fn manifest() -> Value {
    let raw = std::fs::read_to_string(category_dir().join("manifest.json"))
        .expect("the unsupported_construct manifest is readable");
    serde_json::from_str(&raw).expect("the unsupported_construct manifest parses")
}

/// Which of this binding's evaluators a refusal NAMES.
///
/// Always the array one now. `native` and `interpreter` are both the array
/// runtime, for every document whatever its shape (API_SPEC §5.8), so the
/// scalar ODE interpreter is no longer reachable from `esm_problem` and cannot
/// be the one that refuses. The manifest's `evaluator_path` still records
/// which path each case USED to take — it is read here only to check the
/// manifest itself is well formed, which is what keeps a typo in it from
/// passing silently.
fn evaluator_for(path: &str) -> &'static str {
    match path {
        "array" | "scalar" => "Rust array evaluator",
        other => panic!("unknown evaluator_path {other:?}"),
    }
}

#[test]
fn every_case_is_refused_or_runs_as_the_manifest_says() {
    let m = manifest();
    let code = m["code"].as_str().expect("`code` is a string");
    assert_eq!(code, "unsupported_construct");
    assert!(
        earthsci_ast::error_code_names().contains(&code),
        "`{code}` is not in the crate's diagnostic-code registry"
    );
    let cases = m["cases"].as_array().expect("`cases` is an array");
    assert!(
        cases.iter().any(|c| c["expect"] == "run"),
        "no control case"
    );
    assert!(
        cases.iter().any(|c| c["expect"] == "refuse"),
        "no refusal case"
    );

    for case in cases {
        let id = case["id"].as_str().expect("`id` is a string");
        let path = category_dir().join(case["path"].as_str().expect("`path` is a string"));
        let file = load_path(&path).unwrap_or_else(|e| panic!("{id}: does not load: {e}"));
        let results = run_inline_tests_with_base_dir(
            &file,
            None,
            &SolveOptions::default(),
            Some(category_dir().as_path()),
        );
        assert!(!results.is_empty(), "{id}: ran no assertions");
        match case["expect"].as_str() {
            Some("refuse") => {
                let construct = case["construct"].as_str().expect("`construct`");
                let evaluator =
                    evaluator_for(case["evaluator_path"].as_str().expect("`evaluator_path`"));
                for r in &results {
                    assert!(!r.passed, "{id}: an assertion passed: {}", r.message);
                    assert!(
                        r.actual.is_none(),
                        "{id}: the build produced a number ({:?}) instead of refusing: {}",
                        r.actual,
                        r.message
                    );
                    let needle = format!("{code}: {construct}");
                    assert!(
                        r.message.contains(&needle),
                        "{id}: expected `{needle}` in: {}",
                        r.message
                    );
                    assert!(
                        r.message.contains(evaluator),
                        "{id}: expected the evaluator `{evaluator}` to be named in: {}",
                        r.message
                    );
                }
            }
            Some("run") => {
                for r in &results {
                    assert!(r.passed, "{id}: the control failed: {}", r.message);
                }
            }
            other => panic!("{id}: unknown expect {other:?}"),
        }
    }
}
