//! End-to-end coverage of `esm test`, the CLI runner for a document's inline
//! §6.6 tests.
//!
//! These drive the real binary rather than calling `run_pde_tests` directly:
//! what is under test here is the CLI contract — the verdict classification,
//! the summary table, and above all the EXIT CODE, which is the only part of
//! the command a CI job actually reads. A runner that reports failures on
//! stdout and still exits 0 is a gate that never closes, so every case below
//! asserts the status alongside the output.
//!
//! Gated on the features the `esm` target itself requires: with `cli` or
//! `solve` off cargo skips the binary, and `CARGO_BIN_EXE_esm` does not exist.

#![cfg(all(not(target_arch = "wasm32"), feature = "cli", feature = "solve"))]

use std::process::Command;

/// Run `esm <args>` from the crate directory, so the relative paths below —
/// and the relative paths the summary prints back — are stable.
fn esm(args: &[&str]) -> (bool, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_esm"))
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .args(args)
        .output()
        .unwrap_or_else(|e| panic!("could not run the esm binary: {e}"));
    let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
    (out.status.success(), stdout)
}

/// The `pass | fail | err` triple from the summary's `TOTAL` row.
fn total_row(stdout: &str) -> (usize, usize, usize) {
    let line = stdout
        .lines()
        .find(|l| l.trim_start().starts_with("TOTAL"))
        .unwrap_or_else(|| panic!("no TOTAL row in:\n{stdout}"));
    let counts: Vec<usize> = line
        .split_whitespace()
        .skip(1)
        .map(|tok| {
            tok.parse()
                .unwrap_or_else(|e| panic!("TOTAL row {line:?} has a non-numeric count: {e}"))
        })
        .collect();
    assert_eq!(counts.len(), 3, "TOTAL row {line:?} is not pass/fail/err");
    (counts[0], counts[1], counts[2])
}

const PASSING: &str = "tests/fixtures/inline_tests/passing_decay.esm";
const FAILING: &str = "tests/fixtures/inline_tests/failing_decay.esm";

#[test]
fn all_assertions_passing_exits_zero_with_no_failures_block() {
    let (ok, stdout) = esm(&["test", PASSING]);
    assert!(ok, "a passing fixture must exit 0; got:\n{stdout}");
    assert_eq!(total_row(&stdout), (3, 0, 0), "in:\n{stdout}");
    assert!(stdout.contains("Files discovered: 1"), "in:\n{stdout}");
    assert!(stdout.contains("Assertions:       3"), "in:\n{stdout}");
    assert!(
        !stdout.contains("Failures:"),
        "a clean run must not print a Failures block:\n{stdout}"
    );
}

#[test]
fn a_wrong_expected_value_is_a_fail_and_exits_nonzero() {
    let (ok, stdout) = esm(&["test", FAILING]);
    assert!(
        !ok,
        "a failing assertion must exit non-zero; got:\n{stdout}"
    );
    assert_eq!(total_row(&stdout), (0, 1, 0), "in:\n{stdout}");
    assert!(stdout.contains("Failures:"), "in:\n{stdout}");
    // The run reached the tolerance comparison, so this is a FAIL and not an
    // ERROR — the distinction the CLI recovers from `actual.is_none()`.
    assert!(
        stdout.contains("FailingDecay/intentionally_wrong[1] (x@t=100.0) — FAIL"),
        "in:\n{stdout}"
    );
    assert!(stdout.contains("expected=0.5"), "in:\n{stdout}");
}

#[test]
fn a_directory_is_walked_and_one_failure_fails_the_batch() {
    let (ok, stdout) = esm(&["test", "tests/fixtures/inline_tests"]);
    assert!(!ok, "one failure must fail the batch; got:\n{stdout}");
    assert!(stdout.contains("Files discovered: 2"), "in:\n{stdout}");
    assert_eq!(total_row(&stdout), (3, 1, 0), "in:\n{stdout}");
    // Per-file rows, so a batch says WHICH file failed and not just that one did.
    assert!(stdout.contains("failing_decay.esm"), "in:\n{stdout}");
    assert!(stdout.contains("passing_decay.esm"), "in:\n{stdout}");
}

#[test]
fn an_unloadable_file_is_one_error_row_not_a_crash() {
    let (ok, stdout) = esm(&["test", "tests/fixtures/inline_tests_invalid"]);
    assert!(!ok, "a parse failure must exit non-zero; got:\n{stdout}");
    assert_eq!(total_row(&stdout), (0, 0, 1), "in:\n{stdout}");
    assert!(stdout.contains("<parse>/<load>[0]"), "in:\n{stdout}");
    assert!(stdout.contains("— ERROR"), "in:\n{stdout}");
    assert!(stdout.contains("Parse failed:"), "in:\n{stdout}");
}

#[test]
fn model_and_filter_select_a_subset() {
    let (ok, stdout) = esm(&[
        "test",
        "--model",
        "PassingDecay",
        "--filter",
        "decay_trajectory",
        "tests/fixtures/inline_tests",
    ]);
    assert!(ok, "the failing model was filtered out; got:\n{stdout}");
    assert_eq!(total_row(&stdout), (3, 0, 0), "in:\n{stdout}");
}

#[test]
fn a_filter_matching_nothing_reports_no_tests_and_exits_zero() {
    let (ok, stdout) = esm(&[
        "test",
        "--filter",
        "no-such-test-id",
        "tests/fixtures/inline_tests",
    ]);
    assert!(ok, "finding no tests is not a failure; got:\n{stdout}");
    assert!(stdout.contains("(no inline tests found)"), "in:\n{stdout}");
}

#[test]
fn a_directory_holding_no_esm_files_warns_and_exits_zero() {
    // `tests/common` is the shared helper module — a real directory with no
    // `.esm` file under it.
    let (ok, stdout) = esm(&["test", "tests/common"]);
    assert!(ok, "discovering nothing is not a failure; got:\n{stdout}");
    assert!(
        stdout.contains("No .esm files discovered"),
        "a mis-rooted invocation must warn rather than pass silently:\n{stdout}"
    );
}

#[test]
fn verbose_reports_every_assertion_including_the_passing_ones() {
    let (ok, stdout) = esm(&["test", "--verbose", PASSING]);
    assert!(ok, "got:\n{stdout}");
    for idx in 1..=3 {
        assert!(
            stdout.contains(&format!("PASS  PassingDecay/decay_trajectory[{idx}]")),
            "assertion {idx} missing from verbose output:\n{stdout}"
        );
    }
}

#[test]
fn the_run_tests_alias_reaches_the_same_command() {
    let (ok, stdout) = esm(&["run-tests", PASSING]);
    assert!(ok, "got:\n{stdout}");
    assert_eq!(total_row(&stdout), (3, 0, 0), "in:\n{stdout}");
}
