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

// ---------------------------------------------------------------------------
// `esm simulate` on a recurrence — the OTHER command, and the one that was dead
// ---------------------------------------------------------------------------
//
// A causal self-reference (esm-spec §4.3.1.1) evaluated correctly under
// `esm test` and returned a plausible wrong answer under `esm simulate` for as
// long as it existed, because the two commands take different evaluation
// routes: `esm test` materializes observeds per step, while `esm simulate`'s
// static branch rebuilds with the BUILD PIPELINE on in order to materialize an
// array observed at all. The construct was implemented on the first only.
//
// It was silent. The self-read fell through to an unbound-name NaN, and
// `max(NaN, 0.0)` returns `0.0` — IEEE-754 `max` yields the non-NaN operand —
// so a body containing a clamp produced a finite, monotone, wrong field with
// nothing logged. The `esm test` verdict stayed green throughout.
//
// So the two commands are now held to AGREEING on the same document, which is
// the property that was missing. Asserting `esm test` alone cannot see this
// defect, and neither can asserting that `esm simulate` merely ran.

/// The `Name.var[i] = value` lines from an `esm simulate` final-state block.
fn final_state(stdout: &str) -> Vec<(String, f64)> {
    stdout
        .lines()
        .skip_while(|l| !l.starts_with("Final state at t"))
        .filter_map(|l| {
            let (lhs, rhs) = l.trim().split_once(" = ")?;
            Some((lhs.trim().to_string(), rhs.trim().parse().ok()?))
        })
        .collect()
}

#[test]
fn esm_simulate_evaluates_a_recurrence_and_agrees_with_esm_test() {
    let doc = "../../tests/valid/recurrence_causal_self_reference.esm";

    // `esm test` — the path that always worked. Six assertions, zero tolerance.
    let (ok, out) = esm(&["test", doc]);
    assert!(ok, "esm test must pass on the valid corpus fixture:\n{out}");
    assert_eq!(total_row(&out), (6, 0, 0), "esm test verdict:\n{out}");

    // `esm simulate` — the path that returned the non-recurrent const verbatim.
    let (ok, out) = esm(&["simulate", doc]);
    assert!(ok, "esm simulate must succeed:\n{out}");
    let state = final_state(&out);
    assert_eq!(
        state.len(),
        6,
        "expected six cells of 'r' in the final state:\n{out}"
    );

    // The values an INDEPENDENT ascending fold gives. `r[3]` is the
    // order-sensitive one and `r[6]` the cancelling one, so a reassociated or
    // reordered evaluation fails here rather than agreeing loosely.
    let want = [
        1e-16,
        0.999_999_999_999_999_9,
        -1.0,
        99_999_997.0,
        -99_999_997.0,
        -1.000_000_029_999_999_2e16,
    ];
    for (i, ((name, got), expect)) in state.iter().zip(want.iter()).enumerate() {
        assert!(
            (got - expect).abs() <= expect.abs() * 1e-12,
            "esm simulate {name} (cell {}) = {got:?}, want {expect:?}\n{out}",
            i + 1
        );
    }

    // And the regression named as a value that must not come back: the
    // document's own non-recurrent `b[y]` const, which is what every
    // recurrence term contributing zero produces.
    let laundered = [1e-16, 1.0, 1e-16, 100_000_000.0, 3.0, -1e16];
    let got: Vec<f64> = state.iter().map(|(_, v)| *v).collect();
    assert_ne!(
        got.as_slice(),
        laundered.as_slice(),
        "esm simulate returned the b[y] const verbatim — the signature of a self-read \
         resolving to NaN and the body's `max(x, 0)` laundering it to zero \
         (CONFORMANCE_SPEC §5.19.4)\n{out}"
    );
}
