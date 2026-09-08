//! `esm test` must EVALUATE a `table_lookup` — esm-spec §9.5.3, issue #188.
//!
//! `esm validate` accepted a document whose observed was defined by a
//! `table_lookup`, and then every inline-test assertion depending on it failed:
//! the §9.5.3 lowering to `fn interp.linear(const data, const axis, x)` lived
//! only in the conformance harness (`function_tables_lowering.rs`), never on
//! the path an evaluation takes, so the op reached the array runtime's
//! evaluable-core gate. Spelling the same lookup by hand passed.
//!
//! These tests drive the SHARED corpus fixtures
//! (`tests/conformance/function_tables/`, esm-spec §9.5.6) rather than
//! Rust-local copies, because the property is cross-binding: all five bindings
//! had the same gap, and the same two files pin all five.
//!
//! * `inline_test/` — the end-to-end case, through `run_inline_tests`. Its three
//!   assertions are the differential: `y` (a `table_lookup`) and `w` (a
//!   `table_lookup` past the last knot, exercising the default clamp) fail
//!   while `z` (the hand-lowered twin) passes, for exactly as long as the
//!   lowering is missing from the evaluation path.
//! * `out_of_bounds_error/` — §9.5.3a: a mode this binding does not implement
//!   is REFUSED, not silently answered under `clamp`.
//!
//! The last test is the other half of the contract: §9.5.4 makes the authored
//! form first-class, so the lowering must NOT follow the document back out
//! through the serializer.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{SolveOptions, load_path, run_inline_tests_with_base_dir};

mod common;

/// Both `table_lookup` assertions pass, and the interpolating one agrees with
/// its hand-lowered twin bit for bit — the §9.5 bit-equivalence promise, which
/// holds because both arms drive the same closed-registry `interp.linear`.
#[test]
fn a_table_lookup_observed_evaluates_like_its_hand_lowered_twin() {
    let path = common::repo_fixture("conformance/function_tables/inline_test/fixture.esm");
    let file = load_path(&path).expect("fixture loads");
    let results =
        run_inline_tests_with_base_dir(&file, None, &SolveOptions::default(), path.parent());

    assert_eq!(results.len(), 3, "three inline assertions: {results:?}");
    for r in &results {
        assert!(
            r.passed,
            "{}: actual={:?} expected={} {}",
            r.variable, r.actual, r.expected, r.message
        );
    }
    assert_eq!(results[0].variable, "y", "the `table_lookup` arm is first");
    assert_eq!(results[1].variable, "z", "the hand-lowered arm is second");
    assert_eq!(results[2].variable, "w", "the clamped arm is third");
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
    assert_eq!(
        results[2].actual,
        Some(40.0),
        "an input past the last knot clamps to the last table value"
    );
}

/// esm-spec §9.5.3a. `out_of_bounds: "error"` is "conformant when implemented"
/// and this binding has not implemented it, so the lookup is refused by name.
/// The alternative — lowering it to the clamping `interp.*` form — would answer
/// in a mode the author did not declare, which is the defect class this whole
/// module exists to remove.
#[test]
fn an_error_out_of_bounds_table_is_refused_by_name() {
    let path = common::repo_fixture("conformance/function_tables/out_of_bounds_error/fixture.esm");
    // The document is schema-valid and §9.5.5 lists no LOAD-time diagnostic
    // for it: the refusal belongs to the evaluation path, not the loader.
    let file = load_path(&path).expect("fixture loads");

    let err = earthsci_ast::esm_problem(&file, (0.0, 1.0), Default::default())
        .expect_err("must not build");
    let text = err.to_string();
    assert!(
        text.contains("table_out_of_bounds_unsupported"),
        "expected the §9.5.3a refusal by name, got: {text}"
    );
}

/// Lowering is a transformation on the way into an evaluation: the loaded
/// document — the one `emit` serializes — still carries the authored
/// `table_lookup` node and its `function_tables` block (esm-spec §9.5.4).
#[test]
fn the_loaded_document_still_serializes_the_authored_form() {
    let file = load_path(common::repo_fixture(
        "conformance/function_tables/inline_test/fixture.esm",
    ))
    .expect("fixture loads");
    let out = serde_json::to_value(&file).expect("serialize");
    let rhs = &out["models"]["TableLookupObserved"]["equations"][1]["rhs"];
    assert_eq!(rhs["op"], "table_lookup", "authored form preserved: {rhs}");
    assert_eq!(rhs["table"], "t_prof");
    assert!(
        out["function_tables"]["t_prof"].is_object(),
        "the `function_tables` block survives too"
    );
}
