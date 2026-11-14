//! Conformance: the load warning for the deprecated `records_per_sample`
//! (esm-spec §8.5.1), through the `esm` binary. The rest of the tier
//! (`tests/conformance/records_per_sample/manifest.json`) is consumed by
//! `earthsci-ast`'s `tests/records_per_sample_conformance.rs`.

use serde_json::Value;
use std::path::PathBuf;

fn tier_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../tests/conformance/records_per_sample")
}

fn manifest() -> Value {
    serde_json::from_str(&std::fs::read_to_string(tier_dir().join("manifest.json")).unwrap())
        .unwrap()
}

fn cases<'a>(m: &'a Value, expect: &str) -> Vec<&'a Value> {
    m["cases"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|c| c["expect"] == expect)
        .collect()
}

fn case_path(case: &Value) -> PathBuf {
    tier_dir().join(case["path"].as_str().unwrap())
}

fn expected_sites(case: &Value) -> Vec<String> {
    case["deprecated_fields"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p.as_str().unwrap().to_string())
        .collect()
}

/// Loading warns `deprecated_records_per_sample` once, naming the sites,
/// exactly when the deprecated field is written; checked through the `esm`
/// binary, whose `validate` loads the file once, so its stderr is the load's.
#[test]
fn loading_warns_once_exactly_when_the_field_is_written() {
    let m = manifest();
    for case in cases(&m, "valid") {
        let id = case["id"].as_str().unwrap();
        let out = std::process::Command::new(env!("CARGO_BIN_EXE_esm"))
            .arg("validate")
            .arg(case_path(case))
            .output()
            .unwrap_or_else(|e| panic!("could not run the esm binary: {e}"));
        let stderr = String::from_utf8_lossy(&out.stderr);
        let warnings = stderr
            .matches("warning: deprecated_records_per_sample:")
            .count();
        let sites = expected_sites(case);
        if sites.is_empty() {
            assert_eq!(warnings, 0, "{id}: {stderr}");
        } else {
            assert_eq!(warnings, 1, "{id}: {stderr}");
            assert!(
                stderr.contains(&format!("Written at: {}.", sites.join(", "))),
                "{id}: {stderr}"
            );
        }
    }
}
