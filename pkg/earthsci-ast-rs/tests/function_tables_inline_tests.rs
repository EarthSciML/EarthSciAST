//! `esm test` must EVALUATE a `table_lookup` — esm-spec §9.5.3, issue #188.
//!
//! `esm validate` accepted a document whose observed was defined by a
//! `table_lookup`, and then every inline-test assertion depending on it failed:
//! the §9.5.3 lowering to `fn interp.linear(const data, const axis, x)` lived
//! only in the conformance harness (`function_tables_lowering.rs`), never on
//! the build path, so the op reached the array runtime's evaluable-core gate.
//! Spelling the same lookup by hand passed, which is the shape of this fixture:
//! `y` is the `table_lookup` and `z` is its hand-lowered twin, and the two must
//! agree.
//!
//! The second test is the other half of the contract: §9.5.4 makes the authored
//! form first-class, so the lowering must NOT follow the document back out
//! through the serializer.

#![cfg(not(target_arch = "wasm32"))]

use std::path::PathBuf;

use earthsci_ast::{SolveOptions, load_path, run_pde_tests_with_base_dir};

fn fixture() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/function_tables/table_lookup_observed.esm")
}

/// Both assertions pass, and the `table_lookup` arm agrees with the
/// hand-lowered `interp.linear` arm bit for bit (the §9.5 bit-equivalence
/// promise — both drive the same closed-registry implementation).
#[test]
fn a_table_lookup_observed_evaluates_like_its_hand_lowered_twin() {
    let path = fixture();
    let file = load_path(&path).expect("fixture loads");
    let results = run_pde_tests_with_base_dir(&file, None, &SolveOptions::default(), path.parent());

    assert_eq!(results.len(), 2, "two inline assertions: {results:?}");
    for r in &results {
        assert!(
            r.passed,
            "{}: actual={:?} expected={} {}",
            r.variable, r.actual, r.expected, r.message
        );
    }
    assert_eq!(results[0].variable, "y", "the `table_lookup` arm is first");
    assert_eq!(results[1].variable, "z", "the hand-lowered arm is second");
    assert_eq!(
        results[0].actual,
        Some(25.0),
        "p=2.5 blends the 20.0 and 30.0 knots"
    );
    assert_eq!(
        results[0].actual, results[1].actual,
        "`table_lookup` and the equivalent inline-const lookup must agree bit for bit \
         (esm-spec §9.5.3)"
    );
}

/// Lowering is a BUILD-time transformation: the loaded document — the one
/// `emit` serializes — still carries the authored `table_lookup` node
/// (esm-spec §9.5.4).
#[test]
fn the_loaded_document_still_serializes_the_authored_form() {
    let file = load_path(fixture()).expect("fixture loads");
    let out = serde_json::to_value(&file).expect("serialize");
    let rhs = &out["models"]["TableLookupObserved"]["equations"][1]["rhs"];
    assert_eq!(rhs["op"], "table_lookup", "authored form preserved: {rhs}");
    assert_eq!(rhs["table"], "t_prof");
    assert!(
        out["function_tables"]["t_prof"].is_object(),
        "the `function_tables` block survives too"
    );
}
