//! No document both VALIDATES and PANICS: the array runtime's evaluable-core
//! audit (esm-spec §4.2).
//!
//! `eval_op`'s backstop for an operator it has no arm for is `unreachable!` —
//! deliberately, because the alternative it replaced was a silent `NaN`. That
//! makes the gate load-bearing: an entry point that reaches the evaluator
//! without calling `check_evaluable` first turns a schema-valid document into
//! `exit 101` and a panic message, which gives an author nothing to act on.
//! `hoist_static_observeds` was such an entry point.
//!
//! The §4.2 evaluable-core set (`op_registry::arity_of`) is larger than the set
//! this evaluator has rules for (`is_evaluable_op`). The full difference, as
//! audited when this file was written:
//!
//! | op | why it has no rule | what must happen |
//! |---|---|---|
//! | `skolem`, `rank`, `distinct`, `argmin`, `argmax` | build-time relational, materialized by `value_invention` | build error |
//! | `enum`, `apply_expression_template` | lowered at LOAD; surviving one is a lowering bug | build error |
//! | `table_lookup` | lowered on the way into the BUILD (§9.5.3, `lower_table_lookup`) — at load it would break the §9.5.4 round trip; surviving one is a lowering bug | build error |
//! | `ic` | structural: initial-condition assembly reads the equation, the evaluator never sees the node | build error in a BODY, legal as an equation LHS |
//! | `true` | **nothing consumes it** — it is a boolean literal | EVALUATE it |
//!
//! `true` was the odd one out and is now evaluable (1.0); the other nine are
//! gated at build, in `compile.rs`'s stage (0), so each raises
//! `unevaluable_operator` naming itself instead of reaching the backstop.
//!
//! The two registries this audit compares (`op_registry::arity_of` and
//! `simulate_array::is_evaluable_op`) are crate-internal, so their agreement is
//! pinned by unit tests next to them in `eval.rs`
//! (`every_registry_op_is_either_evaluable_or_gated`,
//! `the_true_literal_evaluates_to_one`). What this file asserts is what an
//! AUTHOR sees: a document, through the public API, either answering or failing
//! with a diagnostic.
//!
//! # The scalar half (issue #220)
//!
//! Everything above is about the ARRAY runtime. The SCALAR ODE interpreter
//! (`Compiled::from_file` / `crate::simulate`) is the crate's other evaluator,
//! and it had no such gate: its `eval_op` ended in `_ => f64::NAN`, so the same
//! nine ops came back from it as a NUMBER. The author-visible difference was
//! stark — the array runtime named the pipeline stage at fault, the scalar one
//! reported `actual=NaN expected=25`.
//!
//! `resolve_expr` — the one funnel through which every expression that
//! interpreter evaluates becomes a `ResolvedExpr` — now applies the scalar
//! `is_evaluable_op` the same way stage (0) applies the array one, and the
//! `NaN` backstop is an `unreachable!` matching the array evaluator's. The
//! second half of this file asserts the resulting property: **no document both
//! VALIDATES and silently returns NaN**, over the same op list.
//!
//! The scalar rule set is SMALLER than the array one, so the gate covers more
//! than the nine: the array/tensor + geometry ops have no scalar rule either
//! (nor does an ARRAY `const`, whose value has no `f64` form) and are refused
//! by name rather than NaN'd. That wider gap is pinned by a unit test next to
//! the oracle
//! (`simulate::tests::the_scalar_evaluable_gap_is_pinned`); the nine are what
//! this file carries, because they are the ops BOTH evaluators must refuse.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::{
    Compiled, EsmFile, SolveOptions, load_path, run_inline_tests, run_inline_tests_with_base_dir,
    validate,
};
use serde_json::json;

fn fixture(name: &str) -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/evaluable_core")
        .join(name)
}

/// A `{"op": "true"}` aggregate body — the semi-join spelling — evaluates.
/// This document validated and then panicked (`exit 101`, no diagnostic).
#[test]
fn a_true_body_counts_instead_of_panicking() {
    let path = fixture("semijoin_true_body.esm");
    let file = load_path(&path).expect("loads");
    let results =
        run_inline_tests_with_base_dir(&file, None, &SolveOptions::default(), path.parent());
    assert_eq!(results.len(), 2, "two inline assertions: {results:?}");
    for r in &results {
        assert!(
            r.passed,
            "{}: actual={:?} expected={} {}",
            r.variable, r.actual, r.expected, r.message
        );
    }
    assert_eq!(results[0].actual, Some(2.0), "the join admits two pairs");
    assert_eq!(results[1].actual, Some(3.0), "the range carries three rows");
}

/// The nine core ops with NO rule, each as a `faq` BODY — the position
/// the reported document put `true` in. Every one must end in a DIAGNOSTIC.
/// A panic fails this test by aborting it, which is the detection: before the
/// gate, six of these nine reached `eval_op`'s `unreachable!` exactly as `true`
/// did, so the panic was a class and not one op.
///
/// Built as a typed document rather than loaded, deliberately: `enum` and
/// `apply_expression_template` are lowered at LOAD, so a loader-borne test
/// could never place one in front of the build gate, which is the gate under
/// test. `table_lookup` lowers on the way into the build instead (§9.5.3), and
/// reaches the gate here for the reason a real document would — the document
/// declares no `function_tables`, so there is nothing to lower it against.
#[test]
fn every_unevaluable_core_op_ends_in_a_diagnostic_not_a_panic() {
    /// What refuses this op, audited case by case rather than asserted
    /// generically — a change of refuser is a change worth re-reading.
    enum RefusedBy {
        /// The array runtime's stage-(0) evaluability gate, naming the op.
        EvaluabilityGate,
        /// An EARLIER stage already handles it: the value-invention engine
        /// strips or materializes the producer, and refuses it in its own
        /// vocabulary. Also acceptable — it is a diagnostic, not a panic.
        ValueInvention,
    }
    use RefusedBy::*;

    let cases: [(&str, RefusedBy, serde_json::Value); 9] = [
        // Stripped as a value-invention producer: the observed never reaches
        // the evaluator, and the runner reports the missing observed.
        (
            "skolem",
            ValueInvention,
            json!({ "op": "skolem", "args": ["row"] }),
        ),
        (
            "rank",
            EvaluabilityGate,
            json!({ "op": "rank", "args": ["row"] }),
        ),
        (
            "distinct",
            EvaluabilityGate,
            json!({ "op": "distinct", "args": ["row"] }),
        ),
        // Refused by the VI materializer (an arg-witness needs one output index).
        (
            "argmin",
            ValueInvention,
            json!({ "op": "argmin", "args": [], "arg": "i",
                    "ranges": { "i": [1, 3] }, "expr": "row" }),
        ),
        (
            "argmax",
            ValueInvention,
            json!({ "op": "argmax", "args": [], "arg": "i",
                    "ranges": { "i": [1, 3] }, "expr": "row" }),
        ),
        (
            "ic",
            EvaluabilityGate,
            json!({ "op": "ic", "args": ["row"] }),
        ),
        (
            "enum",
            EvaluabilityGate,
            json!({ "op": "enum", "args": ["colors", "red"] }),
        ),
        (
            "table_lookup",
            EvaluabilityGate,
            json!({ "op": "table_lookup", "args": [] }),
        ),
        (
            "apply_expression_template",
            EvaluabilityGate,
            json!({ "op": "apply_expression_template", "args": [], "name": "tmpl" }),
        ),
    ];

    for (op, refused_by, body) in cases {
        let file: EsmFile = serde_json::from_value(json!({
            "esm": "1.1.0",
            "metadata": { "name": "UnevaluableProbe" },
            "index_sets": { "rows": { "kind": "interval", "size": 2 } },
            "models": { "M": {
                "variables": {
                    "row": { "type": "unknown" },
                    "probe": { "type": "unknown" }
                },
                "equations": [
                    { "lhs": "row", "rhs": { "op": "const", "args": [], "value": 1.0 } },
                    { "lhs": "probe",
                      "rhs": { "op": "faq", "args": [], "semiring": "sum_product",
                               "output_idx": [], "ranges": { "q": { "from": "rows" } },
                               "expr": body } }
                ],
                "tests": [ { "id": "probe", "time_span": { "start": 0.0, "end": 0.0 },
                             "assertions": [ { "variable": "probe", "time": 0.0,
                                               "expected": 1.0 } ] } ]
            }}
        }))
        .expect("typed document");

        let results = run_inline_tests(&file, Some("M"), &SolveOptions::default());
        assert_eq!(results.len(), 1, "`{op}`: one assertion, got {results:?}");
        let r = &results[0];
        assert!(
            !r.passed,
            "`{op}` has no evaluation rule; it must not answer"
        );
        assert!(
            !r.message.is_empty(),
            "`{op}` must fail with a message an author can act on"
        );
        match refused_by {
            EvaluabilityGate => assert!(
                r.message.contains("unevaluable_operator") && r.message.contains(op),
                "`{op}` must be refused BY NAME by the evaluability gate, got: {}",
                r.message
            ),
            ValueInvention => assert!(
                r.message.contains("value-invention") || r.message.contains("not found"),
                "`{op}` is expected to be refused by the value-invention stage, got: {}",
                r.message
            ),
        }
    }
}

/// The one structural exception, pinned so the gate above cannot be tightened
/// into rejecting it: `ic` is legal as an equation LHS (esm-spec §11.4) because
/// initial-condition assembly reads the equation and the evaluator never sees
/// the node. Widening stage (0) without this carve-out failed 15 tests across
/// the suite, every one of them an `ic`.
#[test]
fn an_ic_equation_lhs_still_builds() {
    let file: EsmFile = serde_json::from_value(json!({
        "esm": "1.0.0",
        "metadata": { "name": "IcLhsProbe" },
        "models": { "M": {
            "variables": { "u": { "type": "unknown", "units": "1", "default": 0.0 } },
            "equations": [
                { "lhs": { "op": "D", "args": ["u"], "wrt": "t" },
                  "rhs": { "op": "-", "args": ["u"] } },
                { "lhs": { "op": "ic", "args": ["u"] }, "rhs": 2.0 }
            ]
        }}
    }))
    .expect("typed document");
    let compiled = Compiled::from_file(&file).expect("an `ic` LHS is not an unevaluable operator");
    compiled
        .solve(
            (0.0, 1.0),
            &HashMap::new(),
            &HashMap::new(),
            &SolveOptions::default(),
        )
        .expect("and it still solves");
}

// ============================================================================
// The scalar interpreter (issue #220)
// ============================================================================

/// A minimal PURELY SCALAR document — no `shape`, no array op, no bracketed
/// variable name — whose observed `y` is defined by `body`, with an inline
/// assertion on `y`.
///
/// Every one of those absences is load-bearing: `simulate::is_array_file`
/// routes on exactly those signals, and a document carrying any of them would
/// be answered by the ARRAY runtime, whose gate the first half of this file
/// already covers. This shape is what reaches the SCALAR interpreter.
fn scalar_probe(body: serde_json::Value) -> EsmFile {
    serde_json::from_value(json!({
        "esm": "1.0.0",
        "metadata": { "name": "ScalarUnevaluableProbe" },
        "models": { "M": {
            "variables": {
                "p": { "type": "parameter", "units": "1", "default": 2.0 },
                "y": { "type": "unknown", "units": "1" },
                "u": { "type": "unknown", "units": "1", "default": 1.0 }
            },
            "equations": [
                { "lhs": { "op": "D", "args": ["u"], "wrt": "t" }, "rhs": "y" },
                { "lhs": "y", "rhs": body }
            ],
            // A non-degenerate span: `y` is asserted at t=0, but the solver
            // refuses a zero-width one, and the counterweight test below has to
            // reach the solver to prove the gate let it through.
            "tests": [ { "id": "probe", "time_span": { "start": 0.0, "end": 1.0 },
                         "assertions": [ { "variable": "y", "time": 0.0,
                                           "expected": 25.0 } ] } ]
        }}
    }))
    .expect("typed document")
}

/// No document both VALIDATES and silently returns NaN — the scalar half of
/// this file's invariant, over the same nine ops (issue #220).
///
/// Before the fix every one of these SIMULATED and answered `NaN`: the scalar
/// `eval_op`'s backstop was `_ => f64::NAN`, and `resolve_expr` gated only the
/// OPEN tier (`op_registry::check_node`), never the evaluable-core ops with no
/// rule. The reported symptom was literally
/// `actual=NaN expected=25 (rtol=0.000001, atol=0)` — a number, from a document
/// the array runtime refused by name.
///
/// The two assertions that matter are the NaN one and the naming one. `passed`
/// being false is not enough: a NaN never compares equal to 25, so a NaN'ing
/// interpreter fails this assertion too — which is exactly why the bug survived
/// until someone read the message.
#[test]
fn no_scalar_document_both_validates_and_returns_nan() {
    /// Does the probe carrying this op pass structural validation? Recorded per
    /// op rather than asserted uniformly, because one of the nine genuinely
    /// cannot: `enum`'s operands are an enum NAME and a SYMBOL (esm-spec §9.3),
    /// and the structural reference checker reads every bare string operand as
    /// a variable reference, so `enum(colors, red)` is reported as two
    /// undefined variables. That op therefore reaches an evaluator only from a
    /// TYPED document — which is how the array half of this file builds all
    /// nine — and the gate must still refuse it, so it stays in the list with
    /// the validation half skipped rather than being dropped.
    #[derive(PartialEq)]
    enum Validates {
        Yes,
        NoBecauseSymbolOperands,
    }
    use Validates::*;

    let cases: [(&str, Validates, serde_json::Value); 9] = [
        ("skolem", Yes, json!({ "op": "skolem", "args": ["p"] })),
        ("rank", Yes, json!({ "op": "rank", "args": ["p"] })),
        ("distinct", Yes, json!({ "op": "distinct", "args": ["p"] })),
        (
            "argmin",
            Yes,
            json!({ "op": "argmin", "args": [], "arg": "i",
                    "ranges": { "i": [1, 3] }, "expr": "p" }),
        ),
        (
            "argmax",
            Yes,
            json!({ "op": "argmax", "args": [], "arg": "i",
                    "ranges": { "i": [1, 3] }, "expr": "p" }),
        ),
        ("ic", Yes, json!({ "op": "ic", "args": ["p"] })),
        (
            "enum",
            NoBecauseSymbolOperands,
            json!({ "op": "enum", "args": ["colors", "red"] }),
        ),
        (
            "table_lookup",
            Yes,
            json!({ "op": "table_lookup", "args": [] }),
        ),
        (
            "apply_expression_template",
            Yes,
            json!({ "op": "apply_expression_template", "args": [], "name": "tmpl" }),
        ),
    ];

    for (op, validates, body) in cases {
        let file = scalar_probe(body);

        // "VALIDATES" is half the claim, so it is checked rather than assumed:
        // these are schema- and structurally-valid documents, which is what
        // makes a silent NaN from one indefensible.
        if validates == Yes {
            let v = validate(&file);
            assert!(
                v.is_valid,
                "`{op}`: the probe must VALIDATE for this test to say anything — {:?}",
                v.structural_errors
            );
        }

        let results = run_inline_tests(&file, Some("M"), &SolveOptions::default());
        assert_eq!(results.len(), 1, "`{op}`: one assertion, got {results:?}");
        let r = &results[0];

        // (1) It must not answer with a NUMBER — least of all the NaN sentinel,
        //     which is indistinguishable from a legitimate result and would
        //     propagate into the solution.
        assert!(
            !matches!(r.actual, Some(v) if v.is_nan()),
            "`{op}` has no scalar evaluation rule and must not evaluate to NaN; \
             got actual={:?} message={}",
            r.actual,
            r.message
        );
        assert!(
            r.actual.is_none(),
            "`{op}` must fail to produce a value at all, got actual={:?}",
            r.actual
        );

        // (2) It must say WHICH operator, in the same vocabulary the array
        //     runtime uses, so one defect reads the same on both evaluators.
        assert!(
            r.message.contains("unevaluable_operator") && r.message.contains(op),
            "`{op}` must be refused BY NAME with `unevaluable_operator`, got: {}",
            r.message
        );
        assert!(!r.passed, "`{op}` must not pass");
    }
}

/// The scalar gate reaches NESTED positions, not just a bare observed body: an
/// unevaluable op buried in an otherwise ordinary arithmetic expression is
/// refused too, because `resolve_expr` recurses through every operand before
/// building the parent node.
#[test]
fn a_nested_unevaluable_op_is_refused_on_the_scalar_path() {
    let file = scalar_probe(json!({
        "op": "+",
        "args": [
            { "op": "*", "args": ["p", 2.0] },
            { "op": "rank", "args": ["p"] }
        ]
    }));
    let results = run_inline_tests(&file, Some("M"), &SolveOptions::default());
    assert_eq!(results.len(), 1, "one assertion, got {results:?}");
    let r = &results[0];
    assert!(
        !matches!(r.actual, Some(v) if v.is_nan()),
        "a nested `rank` must not NaN the whole expression; got {:?}",
        r.actual
    );
    assert!(
        r.message.contains("unevaluable_operator") && r.message.contains("rank"),
        "the nested op must be named, got: {}",
        r.message
    );
}

/// The counterweight, so the scalar gate cannot be widened into refusing work
/// it can do: an ordinary scalar document still SIMULATES and answers. `D` on
/// an equation LHS, `fn` through the closed-function registry, and a `Pre`
/// operand are all evaluable-core ops the gate must let through.
#[test]
fn an_ordinary_scalar_document_still_answers() {
    let file = scalar_probe(json!({
        "op": "+",
        "args": [
            { "op": "*", "args": ["p", 10.0] },
            { "op": "Pre", "args": [{ "op": "sqrt", "args": [25.0] }] }
        ]
    }));
    let results = run_inline_tests(&file, Some("M"), &SolveOptions::default());
    assert_eq!(results.len(), 1, "one assertion, got {results:?}");
    let r = &results[0];
    assert!(
        r.passed,
        "p*10 + Pre(sqrt(25)) = 25 must still evaluate: actual={:?} {}",
        r.actual, r.message
    );
}
