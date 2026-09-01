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
//! | `enum`, `table_lookup`, `apply_expression_template` | lowered at LOAD; surviving one is a lowering bug | build error |
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

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::{
    Compiled, EsmFile, SolveOptions, load_path, run_pde_tests, run_pde_tests_with_base_dir,
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
    let results = run_pde_tests_with_base_dir(&file, None, &SolveOptions::default(), path.parent());
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

/// The nine core ops with NO rule, each as an `aggregate` BODY — the position
/// the reported document put `true` in. Every one must end in a DIAGNOSTIC.
/// A panic fails this test by aborting it, which is the detection: before the
/// gate, six of these nine reached `eval_op`'s `unreachable!` exactly as `true`
/// did, so the panic was a class and not one op.
///
/// Built as a typed document rather than loaded, deliberately: `enum`,
/// `table_lookup` and `apply_expression_template` are lowered at LOAD, so a
/// loader-borne test could never place one in front of the build gate, which is
/// the gate under test.
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
        ("skolem", ValueInvention, json!({ "op": "skolem", "args": ["row"] })),
        ("rank", EvaluabilityGate, json!({ "op": "rank", "args": ["row"] })),
        ("distinct", EvaluabilityGate, json!({ "op": "distinct", "args": ["row"] })),
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
        ("ic", EvaluabilityGate, json!({ "op": "ic", "args": ["row"] })),
        ("enum", EvaluabilityGate, json!({ "op": "enum", "args": ["colors", "red"] })),
        ("table_lookup", EvaluabilityGate, json!({ "op": "table_lookup", "args": [] })),
        (
            "apply_expression_template",
            EvaluabilityGate,
            json!({ "op": "apply_expression_template", "args": [], "name": "tmpl" }),
        ),
    ];

    for (op, refused_by, body) in cases {
        let file: EsmFile = serde_json::from_value(json!({
            "esm": "1.0.0",
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
                      "rhs": { "op": "aggregate", "args": [], "semiring": "sum_product",
                               "output_idx": [], "ranges": { "q": { "from": "rows" } },
                               "expr": body } }
                ],
                "tests": [ { "id": "probe", "time_span": { "start": 0.0, "end": 0.0 },
                             "assertions": [ { "variable": "probe", "time": 0.0,
                                               "expected": 1.0 } ] } ]
            }}
        }))
        .expect("typed document");

        let results = run_pde_tests(&file, Some("M"), &SolveOptions::default());
        assert_eq!(results.len(), 1, "`{op}`: one assertion, got {results:?}");
        let r = &results[0];
        assert!(!r.passed, "`{op}` has no evaluation rule; it must not answer");
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
