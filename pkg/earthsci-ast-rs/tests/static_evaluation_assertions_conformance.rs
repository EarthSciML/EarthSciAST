//! Cross-language conformance: an assertion's `time` is the time its
//! expression is EVALUATED at, including on a document with nothing to
//! integrate (esm-spec §6.6.3, §6.3.1; issue #406).
//!
//! Shared fixtures + Julia-minted goldens live under
//! `tests/conformance/static_evaluation_assertions/` (repo root); the Julia
//! runner (`conformance_static_evaluation_assertions_test.jl`) and the Python
//! runner (`test_static_evaluation_assertions_conformance.py`) gate the same
//! goldens. Go and TypeScript are `scope_excluded` in the manifest: neither
//! ships an integrator or an inline-test runner, so neither has an execution
//! path that could read an assertion's `time` at all.
//!
//! What was wrong here. The inline-test runner builds with `Compile::Always`,
//! so an algebraic-only document got a compiled right-hand side over an EMPTY
//! state vector instead of the `Backend::Static` that `esm simulate` selects
//! for it with `Compile::Auto`. Handing that to diffsol produced "Exceeded
//! maximum number of nonlinear solver failures (51) at time = 0" — a
//! diagnostic naming the nonlinear solver rather than the real condition — for
//! a document `simulate` evaluates without complaint. It passed only when
//! every assertion sat at the span's start, which is the one case the
//! integrator never has to step for.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::run_inline_tests_with_base_dir;
use earthsci_ast::{Alg, SolveOptions, load_string};
use std::fs;
use std::path::PathBuf;

mod common;

fn category_dir() -> PathBuf {
    common::repo_fixture("conformance/static_evaluation_assertions")
}

fn read_json(path: &PathBuf) -> serde_json::Value {
    let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

fn manifest_opts(manifest: &serde_json::Value) -> SolveOptions {
    let rs = &manifest["integrators"]["rust"];
    assert_eq!(rs["solver"].as_str(), Some("Erk"));
    SolveOptions {
        alg: Alg::Erk,
        reltol: Some(rs["reltol"].as_f64().expect("reltol")),
        abstol: Some(rs["abstol"].as_f64().expect("abstol")),
        ..Default::default()
    }
}

#[test]
fn static_evaluation_assertions_match_golden() {
    let dir = category_dir();
    let manifest = read_json(&dir.join("manifest.json"));
    assert_eq!(
        manifest["category"].as_str(),
        Some("static_evaluation_assertions")
    );
    assert_eq!(manifest["reference_binding"].as_str(), Some("julia"));
    let required: Vec<&str> = manifest["bindings_required"]
        .as_array()
        .expect("bindings_required")
        .iter()
        .map(|v| v.as_str().expect("binding name"))
        .collect();
    for b in ["julia", "python", "rust"] {
        assert!(required.contains(&b), "manifest must require {b}");
    }

    let rtol = manifest["tolerances"]["assertion_rtol"]
        .as_f64()
        .expect("rtol");
    let atol = manifest["tolerances"]["assertion_atol"]
        .as_f64()
        .expect("atol");
    let opts = manifest_opts(&manifest);

    for fx in manifest["fixtures"].as_array().expect("fixtures") {
        let esm_path = dir.join(fx["path"].as_str().expect("path"));
        let golden = read_json(&dir.join(fx["golden"].as_str().expect("golden")));
        assert_eq!(golden["reference_binding"].as_str(), Some("julia"));

        let text =
            fs::read_to_string(&esm_path).unwrap_or_else(|e| panic!("read {esm_path:?}: {e}"));
        let file = load_string(&text)
            .unwrap_or_else(|e| panic!("fixture {esm_path:?} does not load: {e}"));
        let results =
            run_inline_tests_with_base_dir(&file, fx["model"].as_str(), &opts, Some(dir.as_path()));

        let expected = golden["assertions"].as_array().expect("golden assertions");
        assert_eq!(
            results.len(),
            expected.len(),
            "{}: assertion count",
            fx["id"]
        );

        for g in expected {
            let test_id = g["test_id"].as_str().expect("test_id");
            let idx = g["assertion_idx"].as_u64().expect("assertion_idx") as usize;
            let r = results
                .iter()
                .find(|r| r.test_id == test_id && r.assertion_idx == idx)
                .unwrap_or_else(|| panic!("missing assertion {test_id}#{idx}"));
            assert!(r.passed, "{test_id}#{idx}: {}", r.message);
            let actual = r
                .actual
                .unwrap_or_else(|| panic!("{test_id}#{idx}: no actual"));
            let want = g["actual"].as_f64().expect("golden actual");
            let diff = (actual - want).abs();
            assert!(
                diff <= atol || diff <= rtol * want.abs().max(actual.abs()),
                "{test_id}#{idx}: actual {actual} vs golden {want}"
            );
        }
    }
}

/// The regression itself, stated without the golden machinery: the SAME
/// algebraic-only document, asserted at the span's start and away from it.
///
/// Before the fix the first of these passed and the second reported
/// `Exceeded maximum number of nonlinear solver failures (51) at time = 0`,
/// which is why the defect survived a corpus in which most static documents
/// assert at `time: 0` only.
#[test]
fn an_algebraic_document_is_evaluated_at_every_asserted_time() {
    let doc = |time: f64, expected: f64| {
        format!(
            r#"{{
              "esm": "1.1.0",
              "metadata": {{"name": "TimeProbe", "description": "algebraic-only", "license": "MIT"}},
              "models": {{"TimeProbe": {{
                "variables": {{
                  "a": {{"type": "parameter", "units": "1/s", "default": 2.0}},
                  "y": {{"type": "unknown", "units": "1"}}
                }},
                "equations": [{{"lhs": "y", "rhs": {{"op": "*", "args": ["a", "t"]}}}}],
                "tests": [{{"id": "t_dep", "time_span": {{"start": 0, "end": 10}},
                  "assertions": [{{"variable": "y", "time": {time}, "expected": {expected},
                                  "tolerance": {{"abs": 1e-12}}}}]}}]
              }}}}
            }}"#
        )
    };
    for (time, expected) in [(0.0, 0.0), (5.0, 10.0), (10.0, 20.0)] {
        let file = load_string(&doc(time, expected)).expect("document loads");
        let results = run_inline_tests_with_base_dir(&file, None, &SolveOptions::default(), None);
        assert_eq!(results.len(), 1);
        let r = &results[0];
        assert!(
            r.passed,
            "y = a*t at t={time} should be {expected}: {} (actual {:?})",
            r.message, r.actual
        );
    }
}

/// `system_kind` is a CHECKED DECLARATION, not a selector (esm-spec §6.3.1:
/// "A binding uses the derivation when the field is absent, and reports
/// `system_kind_mismatch` when a present field contradicts it").
///
/// So the algebraic document above must answer identically with and without
/// `"system_kind": "nonlinear"` — the path is chosen by the derivation, which
/// is a function of the equations alone. Issue #406 reported the byte-identical
/// outcome as evidence the declaration was ignored; it is evidence the
/// declaration is not a switch, and the switch it was mistaken for is
/// `has_differential_equations`, which now routes this document itself.
#[test]
fn declaring_system_kind_nonlinear_changes_nothing() {
    let doc = |declared: &str| {
        format!(
            r#"{{
              "esm": "1.1.0",
              "metadata": {{"name": "TimeProbe", "description": "algebraic-only", "license": "MIT"}},
              "models": {{"TimeProbe": {{
                {declared}
                "variables": {{
                  "a": {{"type": "parameter", "units": "1/s", "default": 2.0}},
                  "y": {{"type": "unknown", "units": "1"}}
                }},
                "equations": [{{"lhs": "y", "rhs": {{"op": "*", "args": ["a", "t"]}}}}],
                "tests": [{{"id": "t_dep", "time_span": {{"start": 0, "end": 10}},
                  "assertions": [{{"variable": "y", "time": 5.0, "expected": 10.0,
                                  "tolerance": {{"abs": 1e-12}}}}]}}]
              }}}}
            }}"#
        )
    };
    let run = |declared: &str| {
        let file = load_string(&doc(declared)).expect("document loads");
        let results = run_inline_tests_with_base_dir(&file, None, &SolveOptions::default(), None);
        assert_eq!(results.len(), 1);
        (results[0].passed, results[0].actual)
    };
    let bare = run("");
    let declared = run("\"system_kind\": \"nonlinear\",");
    assert!(bare.0, "the undeclared document must pass");
    assert_eq!(bare, declared, "the declaration must not change the answer");
}

/// esm-spec §6.6.3 constrains an assertion's `time` to `[time_span.start,
/// time_span.end]`.
///
/// The integrating path enforces that incidentally — the trajectory stops at
/// the span's end — and Python's runner, which samples a dense grid over the
/// span, refuses the same assertion on a STATIC document. The static evaluation
/// added for issue #406 has no boundary of its own: before the grid was
/// restricted to the span, `y = a*t` on a span of `[0, 1]` answered `t = 100`
/// with `200` and reported a PASS, and `t = -5` with `-10`. Both now report
/// `no saved state at t=… (nearest …)`, the same refusal and the same wording
/// as the integrating path and as Python.
#[test]
fn a_static_assertion_outside_the_declared_span_is_refused() {
    let doc = r#"{
      "esm": "1.1.0",
      "metadata": {"name": "TimeProbe", "description": "algebraic-only", "license": "MIT"},
      "models": {"TimeProbe": {
        "variables": {
          "a": {"type": "parameter", "units": "1/s", "default": 2.0},
          "y": {"type": "unknown", "units": "1"}
        },
        "equations": [{"lhs": "y", "rhs": {"op": "*", "args": ["a", "t"]}}],
        "tests": [
          {"id": "past_end", "time_span": {"start": 0, "end": 1},
           "assertions": [{"variable": "y", "time": 100.0, "expected": 200.0}]},
          {"id": "before_start", "time_span": {"start": 0, "end": 1},
           "assertions": [{"variable": "y", "time": -5.0, "expected": -10.0}]},
          {"id": "at_the_end", "time_span": {"start": 0, "end": 1},
           "assertions": [{"variable": "y", "time": 1.0, "expected": 2.0,
                           "tolerance": {"abs": 1e-12}}]}
        ]
      }}
    }"#;
    let file = load_string(doc).expect("document loads");
    let results = run_inline_tests_with_base_dir(&file, None, &SolveOptions::default(), None);
    assert_eq!(results.len(), 3);
    for id in ["past_end", "before_start"] {
        let r = results
            .iter()
            .find(|r| r.test_id == id)
            .unwrap_or_else(|| panic!("missing {id}"));
        assert!(!r.passed, "{id} must not pass: actual {:?}", r.actual);
        assert!(r.message.contains("no saved state"), "{id}: {}", r.message);
    }
    // The span's own endpoint is inside it and still answers.
    let at_end = results
        .iter()
        .find(|r| r.test_id == "at_the_end")
        .expect("missing at_the_end");
    assert!(at_end.passed, "at_the_end: {}", at_end.message);
    assert!((at_end.actual.expect("actual") - 2.0).abs() <= 1e-12);
}

/// The `shape`d half of "a document with nothing to integrate still honours
/// `time`" (§5.43.7).
///
/// A SHAPED state-free document takes the ARRAY runtime under
/// `Compile::Always`, which carries no scalar observed graph, so the static
/// evaluation `static_trajectory` performs cannot serve it. Before the runner
/// asked for the build that materializes its fields, `solve` handed a
/// right-hand side over an empty state vector to the integrator and reported
/// `Exceeded maximum number of nonlinear solver failures (51) at time = 0` —
/// issue #406's own diagnostic — at EVERY asserted time, including `t = 0`,
/// and whether or not the observed was a function of `t`. Python and Julia
/// both answer `4` here.
#[test]
fn a_state_free_shaped_observed_is_answered_at_every_asserted_time() {
    let doc = r#"{
      "esm": "1.1.0",
      "metadata": {"name": "ShapedStatic", "description": "state-free, shaped, time-invariant", "license": "MIT"},
      "index_sets": {"x": {"kind": "interval", "size": 3}},
      "models": {"ShapedStatic": {
        "variables": {
          "a": {"type": "parameter", "units": "1", "default": 2.0},
          "g": {"type": "unknown", "units": "1", "shape": ["x"]}
        },
        "equations": [
          {"lhs": "g",
           "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                   "expr": {"op": "*", "args": ["a", "i"]}}}
        ],
        "tests": [{"id": "shaped", "time_span": {"start": 0.0, "end": 10.0},
          "tolerance": {"rel": 1e-9, "abs": 1e-11},
          "assertions": [
            {"variable": "g", "time": 5.0, "coords": {"x": 2}, "expected": 4.0},
            {"variable": "g", "time": 0.0, "coords": {"x": 2}, "expected": 4.0}
          ]}]
      }}
    }"#;
    let file = load_string(doc).expect("document loads");
    let results = run_inline_tests_with_base_dir(&file, None, &SolveOptions::default(), None);
    assert_eq!(results.len(), 2);
    for r in &results {
        assert!(
            r.passed,
            "g[2] = a*2 = 4 at t={}: {} (actual {:?})",
            r.time, r.message, r.actual
        );
    }
}

/// The other half: the build materialized those fields ONCE, at `tspan.0`, so
/// a SHAPED state-free observed that is a function of `t` has no value at any
/// other asserted time — and this binding has no way to produce one, because
/// the array runtime carries no scalar observed graph to re-evaluate.
///
/// Answering anyway would report the value at the start of the span for a
/// question asked elsewhere, which is the outcome issue #406 is about, so it is
/// refused BY NAME. The refusal is the test's, not the assertion's, so a test
/// mixing an out-of-reach assertion with an in-reach one is refused whole; a
/// test that asserts only at `tspan.0` answers.
#[test]
fn a_shaped_state_free_observed_of_t_is_refused_by_name() {
    let doc = r#"{
      "esm": "1.1.0",
      "metadata": {"name": "ShapedOfT", "description": "state-free, shaped, a function of t", "license": "MIT"},
      "index_sets": {"x": {"kind": "interval", "size": 3}},
      "models": {"ShapedOfT": {
        "variables": {
          "a": {"type": "parameter", "units": "1", "default": 2.0},
          "g": {"type": "unknown", "units": "1", "shape": ["x"]}
        },
        "equations": [
          {"lhs": "g",
           "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                   "expr": {"op": "*", "args": ["a", {"op": "*", "args": ["t", "i"]}]}}}
        ],
        "tests": [
          {"id": "away_from_the_start", "time_span": {"start": 0.0, "end": 10.0},
           "tolerance": {"rel": 1e-9, "abs": 1e-11},
           "assertions": [{"variable": "g", "time": 5.0, "coords": {"x": 2}, "expected": 20.0}]},
          {"id": "at_the_start", "time_span": {"start": 0.0, "end": 10.0},
           "tolerance": {"rel": 1e-9, "abs": 1e-11},
           "assertions": [{"variable": "g", "time": 0.0, "coords": {"x": 2}, "expected": 0.0}]}
        ]
      }}
    }"#;
    let file = load_string(doc).expect("document loads");
    let results = run_inline_tests_with_base_dir(&file, None, &SolveOptions::default(), None);
    assert_eq!(results.len(), 2);
    let away = results
        .iter()
        .find(|r| r.test_id == "away_from_the_start")
        .expect("missing away_from_the_start");
    assert!(!away.passed, "must not answer: actual {:?}", away.actual);
    assert!(
        away.message.contains("'g' is a function of `t`"),
        "{}",
        away.message
    );
    assert!(
        away.message.contains("nothing to integrate"),
        "{}",
        away.message
    );
    // Not the nonlinear-solver message issue #406 was filed about.
    assert!(
        !away.message.contains("nonlinear solver failures"),
        "{}",
        away.message
    );
    // The span's start IS the time the fields were materialized at.
    let at_start = results
        .iter()
        .find(|r| r.test_id == "at_the_start")
        .expect("missing at_the_start");
    assert!(at_start.passed, "{}", at_start.message);
}

/// esm-spec §6.6.5 names what an analytic `reference` may read — the asserted
/// field's dimension names, free, and the model's parameters — and `t` is
/// neither. Refused at the document level, with the sentence the three
/// bindings share (CONFORMANCE_SPEC §5.43.6).
///
/// Before the refusal this document reported `actual = 2` against
/// `expected = 0`: the field is `t`, and a reference read at `t = 0` is off by
/// the whole asserted time. Julia and Python reported the same wrong number.
#[test]
fn a_reference_that_mentions_t_is_refused() {
    let doc = r#"{
      "esm": "1.1.0",
      "metadata": {"name": "RefT", "description": "a reference that mentions t", "license": "MIT"},
      "index_sets": {"x": {"kind": "interval", "size": 2}},
      "models": {"RefT": {
        "variables": {"u": {"type": "unknown", "units": "1", "shape": ["x"]}},
        "equations": [
          {"lhs": {"op": "ic", "args": ["u"]},
           "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}}, "expr": 0.0}},
          {"lhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 2]},
                   "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"}},
           "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 2]}, "expr": 1.0}}
        ],
        "tests": [{"id": "reference_mentions_t", "time_span": {"start": 0.0, "end": 2.0},
          "assertions": [{"variable": "u", "time": 2.0, "reduce": "Linf_error",
                          "reference": {"op": "*", "args": [1.0, "t"]}, "expected": 0.0,
                          "tolerance": {"abs": 1e-9}}]}]
      }}
    }"#;
    let file = load_string(doc).expect("document loads");
    let results = run_inline_tests_with_base_dir(&file, None, &SolveOptions::default(), None);
    assert_eq!(results.len(), 1);
    let r = &results[0];
    assert!(!r.passed, "actual {:?}", r.actual);
    assert!(r.actual.is_none());
    // BYTE-IDENTICAL in Julia (`_REFERENCE_MENTIONS_TIME`) and Python
    // (`REFERENCE_MENTIONS_TIME`).
    assert!(
        r.message.contains(
            "inline `reference` mentions `t`, which esm-spec §6.6.5 does not admit: a \
             reference's free variables are the field's dimension names, and its other \
             names are the model's parameters. A reference is evaluated at build time, \
             where the independent variable has no value, so `t` would silently read 0 \
             rather than the asserted time."
        ),
        "{}",
        r.message
    );
}
