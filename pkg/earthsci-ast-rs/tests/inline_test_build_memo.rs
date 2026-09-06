//! The inline-test runner's BUILD MEMO, and the `--filter` that now skips work.
//!
//! `run_model_tests` used to build and evaluate the whole document once per
//! test, whether or not two tests differed in anything the build depends on
//! (moves.esm `docs/findings/README.md` F31: 200 tests over that repository
//! needed 47 builds). It now reuses the built problem across CONSECUTIVE tests
//! whose `BuildKey` — `expression_template_imports`, `time_span`,
//! `parameter_overrides`, `initial_conditions` — is unchanged.
//!
//! A memo keyed on too little is a SILENT WRONG ANSWER, so this file is the
//! invalidation suite, and it works two ways at once:
//!
//! 1. **By count.** The `build_providers` FACTORY is called exactly once per
//!    BUILD (it used to be once per test, which is precisely what the memo
//!    changes). A counting factory therefore reports the number of builds
//!    directly, so a key that fails to invalidate is visible as a count that is
//!    too LOW even when the answers happen to coincide.
//! 2. **By answer.** Every case is also built so that reusing the previous
//!    test's problem produces a WRONG number, not merely a fast one.
//!
//! Sabotage check (how to confirm this suite bites): delete any one field from
//! `BuildKey::of` in `src/pde_inline_tests.rs` and the matching
//! `rebuilds_when_*` test fails on both counts.

use earthsci_ast::{
    BuildProviderFactory, PdeAssertionResult, SolveOptions, load_string, run_pde_tests_filtered,
    run_pde_tests_with_base_dir, run_pde_tests_with_providers,
};
use serde_json::{Value, json};
use std::cell::Cell;
use std::path::Path;

fn opts() -> SolveOptions {
    SolveOptions {
        reltol: 1e-10,
        abstol: 1e-12,
        ..Default::default()
    }
}

/// `dx/dt = k`, `x(0) = 0`, so `x(t) = k·t` — one build input per key field:
/// `k` is reached by `parameter_overrides`, `x` by `initial_conditions`, the
/// integration window by `time_span`.
fn doc(tests: Value) -> Value {
    json!({
        "esm": "1.0.0",
        "metadata": {"name": "build_memo"},
        "models": {"M": {
            "variables": {
                "k": {"type": "parameter", "units": "1", "default": 1.0},
                "x": {"type": "unknown", "units": "1"},
            },
            "equations": [
                {"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": "k"},
                {"lhs": {"op": "ic", "args": ["x"]}, "rhs": 0.0},
            ],
            "tests": tests,
        }},
    })
}

fn test_entry(id: &str, start: f64, end: f64, at: f64, expected: f64) -> Value {
    json!({
        "id": id,
        "time_span": {"start": start, "end": end},
        "assertions": [{"variable": "x", "time": at, "expected": expected,
                        "tolerance": {"rel": 1e-6, "abs": 1e-9}}],
    })
}

/// Run `tests` with a counting provider factory; return the results and the
/// number of times the factory was called, i.e. the number of BUILDS.
fn run_counting(file_json: &Value, filter: Option<&str>) -> (Vec<PdeAssertionResult>, usize) {
    let file = load_string(&file_json.to_string()).expect("document loads");
    let builds = Cell::new(0usize);
    // An EMPTY provider set: this document reads no `data_sources`, and the
    // factory is here to be counted, not to feed anything. It still puts the
    // runner on the with-providers path, which is the path every real
    // invocation of `esm test` takes.
    let make: Box<BuildProviderFactory<'_>> = Box::new(|| {
        builds.set(builds.get() + 1);
        Ok(Vec::new())
    });
    let results = run_pde_tests_filtered(&file, None, &opts(), None, Some(&*make), filter);
    (results, builds.get())
}

fn actual(results: &[PdeAssertionResult], id: &str) -> f64 {
    let r = results
        .iter()
        .find(|r| r.test_id == id)
        .unwrap_or_else(|| panic!("no result for test {id}; got {results:#?}"));
    r.actual
        .unwrap_or_else(|| panic!("test {id} recorded no actual: {}", r.message))
}

fn assert_all_pass(results: &[PdeAssertionResult]) {
    for r in results {
        assert!(
            r.passed,
            "{}[{}]: {} (actual {:?}, expected {})",
            r.test_id, r.assertion_idx, r.message, r.actual, r.expected
        );
    }
}

// ---------------------------------------------------------------------------
// The memo hits when — and only when — the key is unchanged.
// ---------------------------------------------------------------------------

/// Three tests that differ in NOTHING the build depends on (only their ids and
/// their assertion times, which feed the solve) share ONE build.
#[test]
fn identical_keys_share_one_build() {
    let (results, builds) = run_counting(
        &doc(json!([
            test_entry("a", 0.0, 4.0, 1.0, 1.0),
            test_entry("b", 0.0, 4.0, 2.0, 2.0),
            test_entry("c", 0.0, 4.0, 3.0, 3.0),
        ])),
        None,
    );
    assert_eq!(results.len(), 3);
    assert_all_pass(&results);
    assert_eq!(builds, 1, "three same-key tests must build once");
    // And each still gets its OWN solve: the assertion times are not keyed,
    // because they never reach the build.
    assert!((actual(&results, "a") - 1.0).abs() < 1e-6);
    assert!((actual(&results, "b") - 2.0).abs() < 1e-6);
    assert!((actual(&results, "c") - 3.0).abs() < 1e-6);
}

/// `parameter_overrides` — `x(1) = k`, so a memo that ignored `p` would answer
/// 2 for both tests.
#[test]
fn rebuilds_when_parameter_overrides_differ() {
    let mut lo = test_entry("k_lo", 0.0, 1.0, 1.0, 2.0);
    lo["parameter_overrides"] = json!({"k": 2.0});
    let mut hi = test_entry("k_hi", 0.0, 1.0, 1.0, 3.0);
    hi["parameter_overrides"] = json!({"k": 3.0});
    let (results, builds) = run_counting(&doc(json!([lo, hi])), None);
    assert_all_pass(&results);
    assert_eq!(builds, 2, "differing parameter_overrides must rebuild");
    assert!((actual(&results, "k_lo") - 2.0).abs() < 1e-6);
    assert!((actual(&results, "k_hi") - 3.0).abs() < 1e-6);
}

/// A test with NO `parameter_overrides` and one with an EMPTY map key the same
/// (both reach `ProblemOptions::p` as an empty map), and neither shares a build
/// with one that actually overrides.
#[test]
fn absent_and_empty_overrides_are_one_key() {
    let none = test_entry("none", 0.0, 1.0, 1.0, 1.0);
    let mut empty = test_entry("empty", 0.0, 1.0, 1.0, 1.0);
    empty["parameter_overrides"] = json!({});
    let mut set = test_entry("set", 0.0, 1.0, 1.0, 5.0);
    set["parameter_overrides"] = json!({"k": 5.0});
    let (results, builds) = run_counting(&doc(json!([none, empty, set])), None);
    assert_all_pass(&results);
    assert_eq!(
        builds, 2,
        "absent and empty are one build; the override is another"
    );
}

/// `initial_conditions` — `x(1) = x0 + 1`, so a memo that ignored `u0` would
/// answer 3 for both.
#[test]
fn rebuilds_when_initial_conditions_differ() {
    let mut lo = test_entry("x_lo", 0.0, 1.0, 1.0, 3.0);
    lo["initial_conditions"] = json!({"x": 2.0});
    let mut hi = test_entry("x_hi", 0.0, 1.0, 1.0, 8.0);
    hi["initial_conditions"] = json!({"x": 7.0});
    let (results, builds) = run_counting(&doc(json!([lo, hi])), None);
    assert_all_pass(&results);
    assert_eq!(builds, 2, "differing initial_conditions must rebuild");
    assert!((actual(&results, "x_lo") - 3.0).abs() < 1e-6);
    assert!((actual(&results, "x_hi") - 8.0).abs() < 1e-6);
}

/// `time_span` — the window is baked into the problem (`EsmProblem::tspan`), so
/// a memo that ignored it would integrate the SHORT window and have nothing
/// saved at t = 3.
#[test]
fn rebuilds_when_time_span_differs() {
    let (results, builds) = run_counting(
        &doc(json!([
            test_entry("short", 0.0, 1.0, 1.0, 1.0),
            test_entry("long", 0.0, 3.0, 3.0, 3.0),
        ])),
        None,
    );
    assert_all_pass(&results);
    assert_eq!(builds, 2, "a differing time_span must rebuild");
    assert!((actual(&results, "long") - 3.0).abs() < 1e-6);
}

/// `expression_template_imports` (esm-spec §9.7.10 form C) — the component's
/// `D(s, wrt: z)` leaf is DISCRETIZATION-AGNOSTIC (no import of its own, so the
/// node survives the load unlowered, exactly as `tests/conformance/
/// expression_templates/inject_test_block/fixture.esm` leaves its `D(c, wrt:
/// lon)`), and each test injects a different library that matches it. The two
/// builds therefore lower different right-hand sides: `dx/dt` is 2 under one
/// and 3 under the other. A memo that ignored the imports would answer 2 twice.
///
/// The libraries must be injected rather than imported by the component,
/// because a component's own imports are CONSUMED at load — the leaf would
/// already be lowered by the time a test's injection was applied, and the test
/// would pass for the wrong reason.
#[test]
fn rebuilds_when_expression_template_imports_differ() {
    let dir = tempfile::tempdir().expect("tempdir");
    for (name, rate) in [("lib_two", 2.0), ("lib_three", 3.0)] {
        std::fs::write(
            dir.path().join(format!("{name}.esm")),
            json!({
                "esm": "1.0.0",
                "metadata": {"name": name},
                "expression_templates": {name: {
                    "params": ["f"],
                    "match": {"op": "D", "args": ["f"], "wrt": "z"},
                    "body": {"op": "*", "args": [rate, "f"]},
                }},
            })
            .to_string(),
        )
        .expect("write template library");
    }
    let leaf_doc = |tests: Value| {
        json!({
            "esm": "1.0.0",
            "metadata": {"name": "import_memo"},
            "models": {"M": {
                "variables": {
                    "x": {"type": "unknown", "units": "1"},
                    "s": {"type": "parameter", "units": "1", "default": 1.0},
                },
                "equations": [
                    {"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                     "rhs": {"op": "D", "args": ["s"], "wrt": "z"}},
                    {"lhs": {"op": "ic", "args": ["x"]}, "rhs": 0.0},
                ],
                "tests": tests,
            }},
        })
    };
    let entry = |id: &str, lib: &str, expected: f64| {
        json!({
            "id": id,
            "time_span": {"start": 0.0, "end": 1.0},
            "expression_template_imports": [{"ref": format!("./{lib}.esm")}],
            "assertions": [{"variable": "x", "time": 1.0, "expected": expected,
                            "tolerance": {"rel": 1e-6, "abs": 1e-9}}],
        })
    };
    let two = entry("t_two", "lib_two", 2.0);
    let three = entry("t_three", "lib_three", 3.0);

    let run = |tests: Value| -> Vec<PdeAssertionResult> {
        let base = dir.path().join("model.esm");
        std::fs::write(&base, leaf_doc(tests).to_string()).expect("write model");
        let file = earthsci_ast::load_path(&base).expect("model loads");
        run_pde_tests_with_base_dir(&file, None, &opts(), Some(dir.path()))
    };

    let fwd = run(json!([two.clone(), three.clone()]));
    assert_all_pass(&fwd);
    assert!((actual(&fwd, "t_two") - 2.0).abs() < 1e-6);
    assert!((actual(&fwd, "t_three") - 3.0).abs() < 1e-6);
    // And the same both ways round, so neither answer is the other's leftover.
    let rev = run(json!([three, two]));
    assert_all_pass(&rev);
    for id in ["t_two", "t_three"] {
        assert_eq!(actual(&fwd, id).to_bits(), actual(&rev, id).to_bits());
    }
}

/// Order-independence (CONFORMANCE_SPEC §5.7 rule 5): the same tests in a
/// different order give the same per-test answers. A single-slot memo makes the
/// BUILD COUNT order-dependent — the point of this test is that nothing else is.
#[test]
fn answers_do_not_depend_on_test_order() {
    let mut a = test_entry("a", 0.0, 1.0, 1.0, 2.0);
    a["parameter_overrides"] = json!({"k": 2.0});
    let mut b = test_entry("b", 0.0, 1.0, 1.0, 3.0);
    b["parameter_overrides"] = json!({"k": 3.0});
    let mut a2 = a.clone();
    a2["id"] = json!("a2");

    let (fwd, fwd_builds) = run_counting(&doc(json!([a.clone(), a2.clone(), b.clone()])), None);
    let (alt, alt_builds) = run_counting(&doc(json!([a, b, a2])), None);
    assert_all_pass(&fwd);
    assert_all_pass(&alt);
    for id in ["a", "a2", "b"] {
        assert_eq!(
            actual(&fwd, id).to_bits(),
            actual(&alt, id).to_bits(),
            "test {id} answered differently in a different order"
        );
    }
    // Grouped: 2 builds. Interleaved: 3, because the slot holds one build.
    assert_eq!((fwd_builds, alt_builds), (2, 3));
}

// ---------------------------------------------------------------------------
// `--filter` skips WORK, not just rows.
// ---------------------------------------------------------------------------

/// The filter selects before anything is built: three tests with three distinct
/// keys cost three builds unfiltered and ONE when filtered to one of them, and
/// the surviving row is byte-identical to the one the unfiltered run reported.
#[test]
fn filter_skips_the_build_of_every_test_it_excludes() {
    let mut a = test_entry("alpha", 0.0, 1.0, 1.0, 2.0);
    a["parameter_overrides"] = json!({"k": 2.0});
    let mut b = test_entry("beta", 0.0, 1.0, 1.0, 3.0);
    b["parameter_overrides"] = json!({"k": 3.0});
    let mut c = test_entry("gamma", 0.0, 1.0, 1.0, 4.0);
    c["parameter_overrides"] = json!({"k": 4.0});
    let all = doc(json!([a, b, c]));

    let (unfiltered, unfiltered_builds) = run_counting(&all, None);
    assert_eq!(unfiltered_builds, 3);
    assert_eq!(unfiltered.len(), 3);

    let (filtered, filtered_builds) = run_counting(&all, Some("beta"));
    assert_eq!(filtered_builds, 1, "--filter must skip the excluded builds");
    assert_eq!(filtered.len(), 1);
    let want = unfiltered.iter().find(|r| r.test_id == "beta").unwrap();
    assert_eq!(
        serde_json::to_string(&filtered[0]).unwrap(),
        serde_json::to_string(want).unwrap(),
        "the surviving row must be exactly what the unfiltered run reported"
    );
}

/// A filter matching nothing runs nothing and reports nothing (rather than
/// running everything and printing nothing, which is what it used to do).
#[test]
fn filter_matching_nothing_builds_nothing() {
    let (results, builds) = run_counting(
        &doc(json!([
            test_entry("a", 0.0, 1.0, 1.0, 1.0),
            test_entry("b", 0.0, 1.0, 1.0, 1.0),
        ])),
        Some("no_such_test"),
    );
    assert!(results.is_empty());
    assert_eq!(builds, 0);
}

/// The unfiltered entry points keep their meaning: `run_pde_tests_with_providers`
/// is `run_pde_tests_filtered(.., None)`.
#[test]
fn unfiltered_entry_point_runs_everything() {
    let file = load_string(
        &doc(json!([
            test_entry("a", 0.0, 1.0, 1.0, 1.0),
            test_entry("b", 0.0, 1.0, 1.0, 1.0),
        ]))
        .to_string(),
    )
    .expect("document loads");
    let builds = Cell::new(0usize);
    let make: Box<BuildProviderFactory<'_>> = Box::new(|| {
        builds.set(builds.get() + 1);
        Ok(Vec::new())
    });
    let results = run_pde_tests_with_providers(&file, None, &opts(), None::<&Path>, Some(&*make));
    assert_eq!(results.len(), 2);
    assert_eq!(builds.get(), 1);
}
