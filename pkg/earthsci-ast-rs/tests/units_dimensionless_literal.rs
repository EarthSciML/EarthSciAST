//! esm-spec §4.8.6: the `units_dimensionless_literal_mismatch` warning.
//!
//! Pinned by `tests/conformance/dimensionless_literal/golden/expected_warnings.json`:
//! every listed file validates, and the pointers of its warnings with this code,
//! sorted, equal the golden's list exactly.

use earthsci_ast::*;
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn validate_repo_file(rel: &str) -> ValidationResult {
    let path = repo_root().join(rel);
    let json = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", path.display()));
    validate_text(&json, path.parent())
}

fn literal_warning_paths(result: &ValidationResult) -> Vec<String> {
    let mut paths: Vec<String> = result
        .unit_warnings
        .iter()
        .filter(|w| w.code == UNIT_FINDING_DIMENSIONLESS_LITERAL)
        .map(|w| w.path.clone())
        .collect();
    paths.sort();
    paths
}

#[test]
fn the_code_is_the_cross_binding_string() {
    assert_eq!(
        UNIT_FINDING_DIMENSIONLESS_LITERAL,
        "units_dimensionless_literal_mismatch"
    );
}

#[test]
fn warnings_match_the_golden() {
    let golden_path =
        repo_root().join("tests/conformance/dimensionless_literal/golden/expected_warnings.json");
    let golden: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&golden_path).expect("read golden"))
            .expect("parse golden");
    assert_eq!(golden["code"], "units_dimensionless_literal_mismatch");
    let files = golden["files"].as_object().expect("golden files map");
    assert!(!files.is_empty());
    for (rel, expected) in files {
        let result = validate_repo_file(rel);
        assert!(
            result.is_valid,
            "{rel}: expected valid, got schema {:?} structural {:?}",
            result.schema_errors, result.structural_errors
        );
        let mut expected: Vec<String> = expected
            .as_array()
            .expect("golden list")
            .iter()
            .map(|p| p.as_str().expect("pointer").to_string())
            .collect();
        expected.sort();
        assert_eq!(literal_warning_paths(&result), expected, "{rel}");
    }
}

#[test]
fn the_message_names_the_literal_and_the_repair() {
    let result = validate_repo_file(
        "tests/conformance/dimensionless_literal/fixtures/dimensionless_literal.esm",
    );
    let warning = result
        .unit_warnings
        .iter()
        .find(|w| {
            w.code == UNIT_FINDING_DIMENSIONLESS_LITERAL && w.path == "/models/Literals/equations/0"
        })
        .expect("a warning at /models/Literals/equations/0");
    assert!(
        warning.message.contains("/models/Literals/equations/0"),
        "{}",
        warning.message
    );
    assert!(warning.message.contains("273.15"), "{}", warning.message);
    assert!(warning.message.contains("const("), "{}", warning.message);
}
