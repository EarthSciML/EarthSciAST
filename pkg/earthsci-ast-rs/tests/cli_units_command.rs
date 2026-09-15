//! End-to-end coverage of `esm units`, the dimensional analysis report.
//!
//! The report must carry the dimensional analyser's verdict for every equation:
//! consistent (with the propagated dimension), a provable mismatch, or not
//! checked, naming the operand whose dimension could not be determined. An
//! equation that is not checked is the case a reader most needs to see: a bare
//! literal in a product leaves the whole side indeterminate (esm-spec §4.8.4),
//! and `esm validate` stays silent about it.
//!
//! `--check` must not call a document dimensionally consistent when validation
//! found a provable mismatch, and must exit non-zero in that case.
//!
//! Gated on the features the `esm` target itself requires: with `cli` or
//! `solve` off cargo skips the binary, and `CARGO_BIN_EXE_esm` does not exist.

#![cfg(all(not(target_arch = "wasm32"), feature = "cli", feature = "solve"))]

use std::path::PathBuf;
use std::process::Command;

use serde_json::{Value, json};

/// A three-equation model: `a` [m] and `b` [s] are set by constants, and `c`,
/// declared in `c_units`, is defined by `rhs`.
fn document(c_units: &str, rhs: Value) -> Value {
    json!({
        "esm": "1.0.0",
        "metadata": { "name": "u", "description": "units report probe" },
        "index_sets": { "r": { "kind": "interval", "size": 1 } },
        "models": { "U": {
            "variables": {
                "a": { "type": "unknown", "shape": ["r"], "units": "m" },
                "b": { "type": "unknown", "shape": ["r"], "units": "s" },
                "c": { "type": "unknown", "shape": ["r"], "units": c_units }
            },
            "equations": [
                { "lhs": "a", "rhs": { "op": "const", "args": [], "value": [10.0] } },
                { "lhs": "b", "rhs": { "op": "const", "args": [], "value": [2.0] } },
                { "lhs": "c", "rhs": rhs }
            ]
        } }
    })
}

/// Write `doc` to a per-test file and run `esm units [--check] <file>`.
fn esm_units(name: &str, doc: &Value, check: bool) -> (bool, String) {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join("cli_units_command");
    std::fs::create_dir_all(&dir).expect("create test dir");
    let path = dir.join(format!("{name}.esm"));
    std::fs::write(&path, serde_json::to_string_pretty(doc).unwrap()).expect("write fixture");
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_esm"));
    cmd.arg("units");
    if check {
        cmd.arg("--check");
    }
    let out = cmd
        .arg(&path)
        .output()
        .unwrap_or_else(|e| panic!("could not run the esm binary: {e}"));
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    (out.status.success(), stdout)
}

/// The report line for equation `n` (1-based, as printed).
fn equation_line(stdout: &str, n: usize) -> String {
    let prefix = format!("Equation {n}");
    stdout
        .lines()
        .map(str::trim)
        .find(|l| l.starts_with(&format!("{prefix}:")) || l.starts_with(&format!("{prefix} ")))
        .unwrap_or_else(|| panic!("no line for {prefix} in:\n{stdout}"))
        .to_string()
}

#[test]
fn a_consistent_equation_reports_its_propagated_dimension() {
    let doc = document("m/s", json!({ "op": "/", "args": ["a", "b"] }));
    let (ok, stdout) = esm_units("consistent", &doc, false);
    assert!(ok, "esm units failed:\n{stdout}");
    assert!(
        !stdout.contains("dimensional analysis needed"),
        "report still prints the placeholder:\n{stdout}"
    );
    let line = equation_line(&stdout, 3);
    assert!(
        line.contains("consistent") && line.contains("length*time^-1"),
        "equation 3 is a/b = m/s and should be reported consistent: {line}"
    );
}

#[test]
fn a_provable_mismatch_is_reported_as_one() {
    let doc = document("kg", json!({ "op": "/", "args": ["a", "b"] }));
    let (_, stdout) = esm_units("mismatch", &doc, false);
    let line = equation_line(&stdout, 3);
    assert!(
        line.contains("MISMATCH") && line.contains("mass"),
        "equation 3 declares kg for a/b and should be a mismatch: {line}"
    );
}

#[test]
fn an_equation_with_a_literal_factor_is_reported_not_checked_naming_the_literal() {
    let doc = document("kg", json!({ "op": "*", "args": ["a", 0.44704] }));
    let (_, stdout) = esm_units("literal_factor", &doc, false);
    let line = equation_line(&stdout, 3);
    assert!(
        line.contains("NOT CHECKED") && line.contains("0.44704"),
        "equation 3 multiplies by a bare literal; it must say it was not checked and why: {line}"
    );
    // A `const` node has no dimensional rule, so equations 1 and 2 are not
    // checked either, and the report must say so rather than calling them fine.
    let line = equation_line(&stdout, 1);
    assert!(
        line.contains("NOT CHECKED") && line.contains("const"),
        "equation 1 is defined by a const node: {line}"
    );
}

#[test]
fn check_flag_fails_on_a_provable_mismatch() {
    let doc = document("kg", json!({ "op": "/", "args": ["a", "b"] }));
    let (ok, stdout) = esm_units("check_mismatch", &doc, true);
    assert!(
        !stdout.contains("All units are dimensionally consistent"),
        "--check called a mismatched document consistent:\n{stdout}"
    );
    assert!(!ok, "--check exited 0 on a provable mismatch:\n{stdout}");
}

#[test]
fn check_flag_passes_a_consistent_document_and_counts_unchecked_equations() {
    let doc = document("m/s", json!({ "op": "/", "args": ["a", "b"] }));
    let (ok, stdout) = esm_units("check_consistent", &doc, true);
    assert!(ok, "--check failed a consistent document:\n{stdout}");
    assert!(
        stdout.contains("2 not checked"),
        "--check must say how many equations it could not check:\n{stdout}"
    );
}
