//! Cross-language conformance for one unknown carrying two whole definitions.
//!
//! Drives the shared manifest at `tests/conformance/doubly_defined_state/`.
//! `D(x, t) ~ f` beside `x ~ g` is two equations for one unknown (esm-spec
//! §4.9.4), so the document is unbalanced and `validate` reports
//! `equation_count_mismatch`. This crate used to tie-break in favour of the
//! derivative on purpose, dropping the constraint and integrating the rest; the
//! ruling this category pins is that the BUILD refuses under the same code
//! `validate` uses, naming the unknown and both equations. The controls are the
//! same documents with the algebraic equation removed and must still run.

use earthsci_ast::{
    ProblemOptions, SolveOptions, esm_problem, load_path, run_inline_tests_with_base_dir, validate,
};
use serde_json::Value;
use std::path::{Path, PathBuf};

fn category_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance/doubly_defined_state")
}

/// A missing manifest is a hard failure, not a skip.
fn manifest() -> Value {
    let raw = std::fs::read_to_string(category_dir().join("manifest.json"))
        .expect("the doubly_defined_state manifest is readable");
    serde_json::from_str(&raw).expect("the doubly_defined_state manifest parses")
}

/// Read only to check the manifest itself is well formed, which is what keeps a
/// typo in it from passing silently. `native` and `interpreter` are both the
/// array runtime for every document whatever its shape (API_SPEC §5.8), so the
/// two paths are one build here — but the fixtures still differ in shape,
/// because they are shared with the bindings whose routes do diverge.
fn check_evaluator_path(path: &str) {
    assert!(
        matches!(path, "array" | "scalar"),
        "unknown evaluator_path {path:?}"
    );
}

#[test]
fn every_case_is_refused_or_runs_as_the_manifest_says() {
    let m = manifest();
    let code = m["code"].as_str().expect("`code` is a string");
    assert_eq!(code, "equation_count_mismatch");
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
        check_evaluator_path(case["evaluator_path"].as_str().expect("`evaluator_path`"));
        let file = load_path(&path).unwrap_or_else(|e| panic!("{id}: does not load: {e}"));

        match case["expect"].as_str() {
            Some("refuse") => {
                let unknown = case["unknown"].as_str().expect("`unknown` is a string");
                // The BUILD refuses, naming the unknown and both equations.
                let err = esm_problem(&file, (0.0, 1.0), ProblemOptions::default())
                    .err()
                    .unwrap_or_else(|| panic!("{id}: the build did not refuse"));
                let msg = err.to_string();
                assert!(msg.contains(code), "{id}: expected `{code}` in: {msg}");
                assert!(msg.contains(unknown), "{id}: `{unknown}` not named in: {msg}");
                assert!(
                    msg.contains("D(") && msg.contains("§4.9.4"),
                    "{id}: both equations and the rule must be named in: {msg}"
                );
                // …and `validate` says the same, which is what makes the
                // refusal a property of the file rather than of the evaluator.
                let report = validate(&file);
                assert!(!report.is_valid, "{id}: validate accepted it");
                assert!(
                    report.structural_errors.iter().any(|e| {
                        matches!(
                            e.code,
                            earthsci_ast::StructuralErrorCode::EquationCountMismatch
                        )
                    }),
                    "{id}: validate reported {:?}",
                    report.structural_errors
                );
                // An inline test reports the refusal rather than a number.
                let results = run_inline_tests_with_base_dir(
                    &file,
                    None,
                    &SolveOptions::default(),
                    Some(category_dir().as_path()),
                );
                assert!(!results.is_empty(), "{id}: ran no assertions");
                for r in &results {
                    assert!(!r.passed, "{id}: an assertion passed: {}", r.message);
                    assert!(
                        r.actual.is_none(),
                        "{id}: the build produced a number ({:?}) instead of refusing: {}",
                        r.actual,
                        r.message
                    );
                    assert!(
                        r.message.contains(code),
                        "{id}: expected `{code}` in: {}",
                        r.message
                    );
                }
            }
            Some("run") => {
                let results = run_inline_tests_with_base_dir(
                    &file,
                    None,
                    &SolveOptions::default(),
                    Some(category_dir().as_path()),
                );
                assert!(!results.is_empty(), "{id}: ran no assertions");
                for r in &results {
                    assert!(r.passed, "{id}: the control failed: {}", r.message);
                }
            }
            other => panic!("{id}: unknown expect {other:?}"),
        }
    }
}
