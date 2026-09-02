//! Causal self-reference along one index axis — esm-spec §4.3.1.1.
//!
//! A recurrence's output cells are **not independent**, which is what separates
//! this construct from everything else in the array runtime and what these
//! tests exist to pin. Three things follow, and each is asserted here on a
//! specific value rather than within a tolerance:
//!
//! * the **value** is a fully determined function of the document (the sweep
//!   order is fixed and each cell is published before the axis advances), so a
//!   cancellation ladder separates the normative left fold from every
//!   reassociation and reordering — CONFORMANCE_SPEC §5.19.1;
//! * an **unavailable** self-read — out of range, or a cell the sweep has not
//!   published — is a fault, never a number. §5.19.4 is emphatic about this and
//!   the reason is specific to a recurrence: it feeds itself, so one substituted
//!   zero propagates along the whole axis, and a `max(x, 0)` in the body
//!   launders even a NaN sentinel into something plausible;
//! * a shape that is **not** a well-founded causal read is rejected with a
//!   code, not evaluated to something. The pre-feature behaviour for every one
//!   of these was a document that validated and then produced a wrong answer or
//!   no answer at all, which is exactly the failure this toolchain is prone to.
//!
//! Every assertion below names an expected value or an expected code. None
//! asserts a bound, and none asserts merely that a run completed.

use earthsci_ast::{PdeAssertionResult, SolveOptions, load_path, load_string, run_pde_tests};
use serde_json::{Value, json};

fn fixture(name: &str) -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/recurrence")
        .join(name)
}

fn run_fixture(name: &str) -> Vec<PdeAssertionResult> {
    let file = load_path(fixture(name)).expect("fixture parses");
    let results = run_pde_tests(&file, None, &SolveOptions::default());
    assert!(!results.is_empty(), "{name}: the fixture asserts nothing");
    results
}

/// Every inline assertion of a fixture must pass, and each must have produced a
/// real number. A missing `actual` is the interesting failure — it is what a
/// variable that never materialized looks like — so it is reported separately
/// from a value mismatch.
fn assert_fixture_passes(name: &str) {
    for r in run_fixture(name) {
        let actual = r.actual.unwrap_or_else(|| {
            panic!(
                "{name}: {}[{}] on '{}' produced NO value — {}",
                r.test_id, r.assertion_idx, r.variable, r.message
            )
        });
        assert!(
            r.passed,
            "{name}: {}[{}] on '{}' expected {:?} (bits {:#018x}), got {actual:?} \
             (bits {:#018x}) at rtol={} atol={}",
            r.test_id,
            r.assertion_idx,
            r.variable,
            r.expected,
            r.expected.to_bits(),
            actual.to_bits(),
            r.rtol,
            r.atol,
        );
    }
}

// ---------------------------------------------------------------------------
// 1. The six pinned fixtures
// ---------------------------------------------------------------------------

/// `s[1] = 1`, `s[k] = 2·s[k−1]` → `[1, 2, 4, 8]`. The construct's minimal
/// case, and the one that had no spelling at all: written this way the document
/// used to validate and then leave `s` unmaterialized.
#[test]
fn doubling_recurrence_evaluates() {
    assert_fixture_passes("01_recurrence_doubling.esm");
}

/// **The order pin.** `s[k] = s[k−1] + u[k]` over `u = [1e16, 1, −1e16, 1]`.
/// The ascending sweep is the left fold, `[1e16, 1e16, 0, 1]`; a reassociating
/// or reordered evaluation reaches `[1e16, 1e16, 1, 2]`. Both are asserted
/// below — the second as a value that must NOT come back — because "passes at
/// some tolerance" would accept either.
#[test]
fn cancellation_ladder_is_the_left_fold() {
    assert_fixture_passes("02_recurrence_cancellation_ladder.esm");
    let cell3 = run_fixture("02_recurrence_cancellation_ladder.esm")
        .into_iter()
        .find(|r| r.assertion_idx == 3)
        .expect("the third assertion");
    let actual = cell3.actual.expect("a value");
    assert_eq!(
        actual.to_bits(),
        0.0f64.to_bits(),
        "the left fold gives exactly 0 at cell 3; got {actual:?}"
    );
    assert_ne!(
        actual, 1.0,
        "1.0 at cell 3 is the signature of a reassociated window"
    );
}

/// Two literal lags in one body — `s[k] = s[k−1] + s[k−2]`. A single-step
/// accumulator (`acc[i] = f(acc[i−1], body[i])`) cannot express this, which is
/// why the primitive is a bounded-lag read rather than a widened prefix scan.
#[test]
fn two_literal_lags_evaluate() {
    assert_fixture_passes("03_recurrence_multi_lag.esm");
}

/// A **symbol-valued** lag: one node covering every lag in a contracted index's
/// range, under a banded `filter`, with a clamp inside the fold. This is the
/// shape a real bounded-lag fold has — the alternative is one hand-written term
/// per lag — and its `lag = a` straddles zero, which is admitted because the
/// `a = 0` cell is guarded and an unpublished cell could not be read anyway.
/// The fixture also pins the IN-BODY reduction order to the bit.
#[test]
fn symbol_valued_banded_lag_evaluates_in_ascending_order() {
    assert_fixture_passes("04_recurrence_banded_lag_fold.esm");
    let cell3 = run_fixture("04_recurrence_banded_lag_fold.esm")
        .into_iter()
        .find(|r| r.assertion_idx == 3)
        .expect("the third assertion");
    let actual = cell3.actual.expect("a value");
    assert_eq!(
        actual.to_bits(),
        (-1.0f64).to_bits(),
        "ascending-in-`a` gives exactly −1.0 at r[3]; got {actual:?}. \
         −1.0000000000000002 is the same window folded from its high end."
    );
}

/// A rank-2 variable folding along ONE axis and free in the other: the carried
/// state is a whole column, so the construct serves an array-valued accumulator
/// with no extra machinery. Also pins the sweep order — recurrence axis
/// outermost, free axis inside it.
#[test]
fn recurrence_on_one_of_two_axes_evaluates() {
    assert_fixture_passes("05_recurrence_two_axes.esm");
}

/// The carried value is rounded to the variable's `element_type` at EVERY cell
/// (§5.19.3a). A binding that folds in binary64 and narrows once at the end
/// gets `0.9999999999999999` — a *better* answer than the `real*4` reference
/// this construct exists to reproduce, and the hardest kind of wrong to notice.
#[test]
fn float32_recurrence_carries_binary32_state_at_every_step() {
    assert_fixture_passes("06_recurrence_float32_state.esm");
    let last = run_fixture("06_recurrence_float32_state.esm")
        .into_iter()
        .find(|r| r.assertion_idx == 3)
        .expect("the s[10] assertion");
    let actual = last.actual.expect("a value");
    assert_eq!(
        actual.to_bits(),
        (1.0000001_f32 as f64).to_bits(),
        "expected the binary32 fold {:?}, got {actual:?}; \
         0.9999999999999999 means the fold ran in binary64 and narrowed at the end",
        1.0000001_f32 as f64,
    );
}

/// **The real lag scale.** Thirty-eight distinct lags with thirty-eight
/// distinct weights, in ONE node, with a clamp inside the fold that fires at 19
/// of the 40 cells and alters 38 of the 40 values.
///
/// This is the fixture that answers the three design questions at once. The lag
/// is symbol-valued, so thirty-eight lags are one `index(r, y − a)` rather than
/// thirty-eight authored terms. The per-lag weights all differ, so no single
/// carried value summarizes the history — which is exactly why §4.3.1's prefix
/// scan, whose entire optimization is one accumulator, declines a body that
/// reads its own output, and why widening it would not have been enough. And
/// the clamp makes the recurrence non-linear, so no linear closed form
/// reproduces these numbers.
///
/// The expected values come from an independent ascending fold in Python, not
/// from running the document.
#[test]
fn thirty_eight_distinct_lags_in_one_node_evaluate() {
    assert_fixture_passes("07_recurrence_thirty_eight_lags.esm");
}

// ---------------------------------------------------------------------------
// 2. Fail-closed reads
// ---------------------------------------------------------------------------

/// One-variable recurrence document with `body` as the aggregate's `expr`.
fn doc_with_body(body: Value) -> String {
    json!({
      "esm": "1.0.0",
      "metadata": { "name": "R", "description": "probe", "authors": ["t"] },
      "index_sets": { "steps": { "kind": "interval", "size": 4 } },
      "models": { "R": {
        "tolerance": { "rel": 0.0, "abs": 0.0 },
        "variables": { "s": { "type": "unknown", "shape": ["steps"], "units": "1" } },
        "equations": [ { "lhs": "s", "rhs": {
          "op": "aggregate", "args": [], "output_idx": ["k"],
          "ranges": { "k": { "from": "steps" } }, "expr": body } } ],
        "tests": [ { "id": "probe", "description": "probe",
          "time_span": { "start": 0.0, "end": 0.0 },
          "assertions": [ { "variable": "s", "time": 0.0, "expected": 1.0,
                            "coords": { "steps": 1 } } ] } ]
      } }
    })
    .to_string()
}

/// The message of the single assertion of a probe document, whether it came
/// from a compile refusal or a runtime fault.
fn probe_message(body: Value) -> String {
    let file = load_string(&doc_with_body(body)).expect("probe parses");
    let results = run_pde_tests(&file, None, &SolveOptions::default());
    assert_eq!(results.len(), 1, "one assertion: {results:?}");
    let r = &results[0];
    assert!(
        r.actual.is_none() && !r.passed,
        "the probe must produce NO value, got actual={:?} passed={}",
        r.actual,
        r.passed
    );
    r.message.clone()
}

/// **The one that would otherwise return a number.** `s[k] = 2·s[k−1]` with no
/// base-case guard: at `k = 1` the body reads position 0. That read must fault.
/// Under the zero-ghost convention every other gather uses it would have been
/// `0`, and the whole array would then be zeros — four plausible numbers and
/// nothing to say they are wrong.
#[test]
fn unguarded_self_read_at_the_first_cell_is_a_fault() {
    let msg = probe_message(json!({
        "op": "*",
        "args": [ { "op": "index", "args": ["s", { "op": "-", "args": ["k", 1] }] }, 2.0 ]
    }));
    assert!(
        msg.contains("E_TREEWALK_RECUR_UNAVAILABLE"),
        "expected the fail-closed fault, got: {msg}"
    );
}

// ---------------------------------------------------------------------------
// 3. Rejections — the compile path
// ---------------------------------------------------------------------------

fn assert_probe_rejected_with(body: Value, code: &str, what: &str) {
    let msg = probe_message(body);
    assert!(
        msg.contains(code),
        "{what}: expected `{code}`, got: {msg}"
    );
}

#[test]
fn forward_self_read_is_rejected() {
    assert_probe_rejected_with(
        json!({ "op": "index", "args": ["s", { "op": "+", "args": ["k", 1] }] }),
        "recurrence_not_wellfounded",
        "index(s, k+1) names a cell the sweep has not reached",
    );
}

#[test]
fn same_cell_self_read_is_rejected() {
    assert_probe_rejected_with(
        json!({ "op": "index", "args": ["s", "k"] }),
        "recurrence_not_wellfounded",
        "index(s, k) defines s in terms of itself, not of an earlier position",
    );
}

#[test]
fn bare_self_read_is_rejected() {
    assert_probe_rejected_with(
        json!({ "op": "+", "args": [
            "s",
            { "op": "index", "args": ["s", { "op": "-", "args": ["k", 1] }] }
        ] }),
        "recurrence_not_wellfounded",
        "a bare `s` names the whole array, which does not exist during the sweep",
    );
}

#[test]
fn non_affine_self_index_is_rejected() {
    assert_probe_rejected_with(
        json!({ "op": "index", "args": ["s", { "op": "*", "args": ["k", 2] }] }),
        "recurrence_not_wellfounded",
        "2*k does not name a position relative to the cell being written",
    );
}

#[test]
fn constant_self_index_is_rejected() {
    assert_probe_rejected_with(
        json!({ "op": "index", "args": ["s", 1] }),
        "recurrence_not_wellfounded",
        "a constant index does not say which axis the recurrence folds along",
    );
}

/// A self-read on TWO axes at once. `m[i,j]` reading `m[i−1, j−1]` has no
/// single axis to fold along: the sweep would have to advance both at once.
#[test]
fn self_read_offset_on_two_axes_is_rejected() {
    let doc = json!({
      "esm": "1.0.0",
      "metadata": { "name": "R2", "description": "probe", "authors": ["t"] },
      "index_sets": { "rows": { "kind": "interval", "size": 3 },
                      "cols": { "kind": "interval", "size": 3 } },
      "models": { "R2": {
        "tolerance": { "rel": 0.0, "abs": 0.0 },
        "variables": { "m": { "type": "unknown", "shape": ["rows", "cols"], "units": "1" } },
        "equations": [ { "lhs": "m", "rhs": {
          "op": "aggregate", "args": [], "output_idx": ["i", "j"],
          "ranges": { "i": { "from": "rows" }, "j": { "from": "cols" } },
          "expr": { "op": "index", "args": ["m",
                      { "op": "-", "args": ["i", 1] },
                      { "op": "-", "args": ["j", 1] } ] } } } ],
        "tests": [ { "id": "probe", "description": "probe",
          "time_span": { "start": 0.0, "end": 0.0 },
          "assertions": [ { "variable": "m", "time": 0.0, "expected": 1.0,
                            "coords": { "rows": 1, "cols": 1 } } ] } ]
      } }
    })
    .to_string();
    let file = load_string(&doc).expect("probe parses");
    let results = run_pde_tests(&file, None, &SolveOptions::default());
    assert_eq!(results.len(), 1);
    let msg = &results[0].message;
    assert!(
        msg.contains("recurrence_not_wellfounded"),
        "expected `recurrence_not_wellfounded`, got: {msg}"
    );
}

/// The `makearray` spelling. Its regions are ORDERED and §4.3.2's overlap rule
/// is "later entries overwrite earlier ones", which reads like a licence to
/// define position `k` from position `k−1`. It is not one — the region order
/// fixes which write wins, not the order cells are evaluated in — so it is
/// refused with the code that says the READ is causal but the CARRIER cannot
/// sequence it. Before this feature it produced no value and said nothing.
#[test]
fn makearray_region_self_read_is_refused_as_unsupported_form() {
    let doc = json!({
      "esm": "1.0.0",
      "metadata": { "name": "RM", "description": "probe", "authors": ["t"] },
      "index_sets": { "steps": { "kind": "interval", "size": 4 } },
      "models": { "RM": {
        "tolerance": { "rel": 0.0, "abs": 0.0 },
        "variables": { "s": { "type": "unknown", "shape": ["steps"], "units": "1" } },
        "equations": [ { "lhs": "s", "rhs": {
          "op": "makearray", "args": [],
          "regions": [ [[1, 1]], [[2, 4]] ],
          "values": [ 1.0, {
            "op": "aggregate", "args": [], "output_idx": ["k"],
            "ranges": { "k": [2, 4] },
            "expr": { "op": "*", "args": [
              { "op": "index", "args": ["s", { "op": "-", "args": ["k", 1] }] }, 2.0 ] } } ] } } ],
        "tests": [ { "id": "probe", "description": "probe",
          "time_span": { "start": 0.0, "end": 0.0 },
          "assertions": [ { "variable": "s", "time": 0.0, "expected": 1.0,
                            "coords": { "steps": 1 } } ] } ]
      } }
    })
    .to_string();
    let file = load_string(&doc).expect("probe parses");
    let results = run_pde_tests(&file, None, &SolveOptions::default());
    assert_eq!(results.len(), 1);
    let msg = &results[0].message;
    assert!(
        msg.contains("recurrence_unsupported_form"),
        "expected `recurrence_unsupported_form`, got: {msg}"
    );
}

// ---------------------------------------------------------------------------
// 4. Rejections — the structural validator
// ---------------------------------------------------------------------------
//
// The compile path above refuses these when a document is EVALUATED. The
// structural validator has to refuse them when a document is merely VALIDATED,
// because that is the only check the two non-evaluating bindings can run
// (CONFORMANCE_SPEC §5.19.5) — and because an author who never simulates should
// still be told.

fn validation_codes(doc: &str) -> Vec<(String, String)> {
    let file = load_string(doc).expect("probe parses");
    earthsci_ast::validate(&file)
        .structural_errors
        .into_iter()
        .map(|e| (e.code.to_string(), e.path))
        .collect()
}

#[test]
fn structural_validator_rejects_a_forward_self_read() {
    let codes = validation_codes(&doc_with_body(
        json!({ "op": "index", "args": ["s", { "op": "+", "args": ["k", 1] }] }),
    ));
    assert!(
        codes.contains(&(
            "recurrence_not_wellfounded".to_string(),
            "/models/R/equations/0/rhs".to_string()
        )),
        "expected the code at the equation's rhs pointer, got {codes:?}"
    );
}

#[test]
fn structural_validator_rejects_a_makearray_region_self_read() {
    let doc = json!({
      "esm": "1.0.0",
      "metadata": { "name": "R", "description": "probe", "authors": ["t"] },
      "index_sets": { "steps": { "kind": "interval", "size": 4 } },
      "models": { "R": {
        "tolerance": { "rel": 0.0, "abs": 0.0 },
        "variables": { "s": { "type": "unknown", "shape": ["steps"], "units": "1" } },
        "equations": [ { "lhs": "s", "rhs": {
          "op": "makearray", "args": [],
          "regions": [ [[1, 1]], [[2, 4]] ],
          "values": [ 1.0, {
            "op": "aggregate", "args": [], "output_idx": ["k"],
            "ranges": { "k": [2, 4] },
            "expr": { "op": "index", "args": ["s", { "op": "-", "args": ["k", 1] }] } } ] } } ]
      } }
    })
    .to_string();
    let codes = validation_codes(&doc);
    assert!(
        codes
            .iter()
            .any(|(c, _)| c == "recurrence_unsupported_form"),
        "expected `recurrence_unsupported_form`, got {codes:?}"
    );
}

/// The corpus fixture every binding must ACCEPT. Rejection parity cuts both
/// ways: a binding that treats a self-read as a cycle rejects a legal document,
/// which is the same defect as admitting an illegal one.
#[test]
fn the_valid_corpus_recurrence_validates_clean() {
    let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/valid/recurrence_causal_self_reference.esm");
    let file = load_path(&path).expect("fixture parses");
    let report = earthsci_ast::validate(&file);
    let recurrence: Vec<_> = report
        .structural_errors
        .iter()
        .filter(|e| e.code.to_string().starts_with("recurrence_"))
        .collect();
    assert!(
        recurrence.is_empty(),
        "a well-founded recurrence must validate clean, got {recurrence:?}"
    );
}

/// A two-variable cycle must NOT be mistaken for a recurrence, and admitting a
/// recurrence must not make one start working.
///
/// The distinction is exactly the self-edge: `V → V` through a strictly earlier
/// position is an ORDERING within one variable and is dropped from the observed
/// dependency graph, while `a → b → a` is a genuine cycle with no order that
/// satisfies it. So this document must keep producing nothing, and — the part
/// this feature could have broken — it must not be diagnosed as a recurrence
/// on the way.
///
/// Note what is NOT claimed here. Rust's `circular_dependency` code is about
/// MODEL-to-model coupling, not variable-to-variable, and the array path's
/// two-variable algebraic cycle is a pre-existing gap: it fails to materialize
/// rather than being diagnosed (`tests/conformance/simulate_cycles`'
/// `cyclic_algebraic` covers the scalar path, which does fail fast). This test
/// pins the property this change is responsible for and does not overstate the
/// one it inherited.
#[test]
fn a_two_variable_cycle_is_not_a_recurrence_and_still_produces_nothing() {
    let cyclic = json!({
      "esm": "1.0.0",
      "metadata": { "name": "C", "description": "probe", "authors": ["t"] },
      "index_sets": { "steps": { "kind": "interval", "size": 4 } },
      "models": { "C": {
        "tolerance": { "rel": 1e-9 },
        "variables": {
          "a": { "type": "unknown", "shape": ["steps"], "units": "1" },
          "b": { "type": "unknown", "shape": ["steps"], "units": "1" }
        },
        "equations": [
          { "lhs": "a", "rhs": { "op": "aggregate", "args": [], "output_idx": ["k"],
            "ranges": { "k": { "from": "steps" } },
            "expr": { "op": "index", "args": ["b", "k"] } } },
          { "lhs": "b", "rhs": { "op": "aggregate", "args": [], "output_idx": ["k"],
            "ranges": { "k": { "from": "steps" } },
            "expr": { "op": "index", "args": ["a", "k"] } } }
        ],
        "tests": [ { "id": "probe", "description": "probe",
          "time_span": { "start": 0.0, "end": 0.0 },
          "assertions": [ { "variable": "a", "time": 0.0, "expected": 1.0,
                            "coords": { "steps": 1 } } ] } ]
      } }
    })
    .to_string();
    let codes = validation_codes(&cyclic);
    assert!(
        !codes.iter().any(|(c, _)| c.starts_with("recurrence_")),
        "a two-variable cycle is not a recurrence diagnosis, got {codes:?}"
    );
    let file = load_string(&cyclic).expect("probe parses");
    let results = run_pde_tests(&file, None, &SolveOptions::default());
    assert_eq!(results.len(), 1);
    assert!(
        results[0].actual.is_none() && !results[0].passed,
        "a two-variable cycle must still produce no value, got actual={:?}",
        results[0].actual
    );
}
