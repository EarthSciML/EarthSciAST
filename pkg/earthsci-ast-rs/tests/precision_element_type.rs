//! `domain.element_type: "Float32"` means the evaluator computes in binary32,
//! rounding once per operation (esm-spec §11.3).
//!
//! The field was accepted, documented and **silently ignored**: a document
//! declaring it evaluated in binary64 anyway. This file pins the contract that
//! replaced that, and it pins it on **exact bit patterns** rather than
//! tolerances — a tolerance test cannot see a one-ulp difference, which is the
//! entire point of the mode.
//!
//! ## The witness
//!
//! `100 * ((100 - 73.5) / 100) / (100 - 73.5)` is exactly `1.0` in binary64 and
//! `0.99999994` (`0x3F7FFFFF`, one ulp below one) in binary32. In the fixtures
//! every operand is a runtime `parameter`, so a build-time constant fold cannot
//! account for the difference: the rounding has to happen per operation, in the
//! evaluator, at run time.
//!
//! Downstream this is not a cosmetic difference. A residual that is `0.0` in
//! binary64 and `5.96e-08` in binary32 propagates through an age-distribution
//! recurrence until a `<= 0` skip changes sides, and a relational model emits
//! 144 rows instead of 140. Per-operation rounding decides which rows exist.
//!
//! ## What is asserted here
//!
//! 1. The witness document answers the binary32 value at ZERO tolerance.
//! 2. The same document with `element_type: "Float64"` answers exactly `1.0` —
//!    the default path, unchanged.
//! 3. Literals round on ingress, and the mode guard restores what it replaced.
//! 4. An unknown `element_type`, and a construct binary32 cannot carry, are
//!    ERRORS naming themselves — never a quiet fall back to binary64.
//!
//! The kernel tables and the reduction accumulator are pinned inside the crate,
//! next to their definitions (`simulate_array::eval::kernel_equivalence_tests`,
//! `aggregate::reduce_tests`), where they are reachable.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::precision::{self, Precision};
use earthsci_ast::{PdeAssertionResult, load_path, run_pde_tests, SolveOptions};

fn fixture(name: &str) -> std::path::PathBuf {
    std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/precision")
        .join(name)
}

fn run(name: &str) -> Vec<PdeAssertionResult> {
    let file = load_path(fixture(name)).expect("fixture parses");
    run_pde_tests(&file, None, &SolveOptions::default())
}

/// The one assertion of the witness document, with its actual value.
fn only_actual(name: &str) -> (bool, f64) {
    let results = run(name);
    assert_eq!(results.len(), 1, "one assertion: {results:?}");
    let r = &results[0];
    let actual = r
        .actual
        .unwrap_or_else(|| panic!("{name}: no actual value — {}", r.message));
    (r.passed, actual)
}

// ---------------------------------------------------------------------------
// 1. The witness: Float32 evaluates in binary32, per operation.
// ---------------------------------------------------------------------------

/// **The regression.** Before the fix this document evaluated in binary64 and
/// reported `actual = 1`, passing nothing and failing the zero-tolerance
/// assertion by one ulp.
///
/// Asserted on BITS: `0.9999999403953552` is `0.99999994_f32` widened, and
/// nothing else must be accepted for it.
#[test]
fn float32_document_rounds_every_operation() {
    let (passed, actual) = only_actual("f32_per_op_rounding.esm");
    assert_eq!(
        actual.to_bits(),
        (0.99999994_f32 as f64).to_bits(),
        "expected the binary32 value {:?} (bits {:#018x}), got {actual:?} (bits {:#018x}); \
         a result of exactly 1.0 means the document evaluated in binary64",
        0.99999994_f32 as f64,
        (0.99999994_f32 as f64).to_bits(),
        actual.to_bits(),
    );
    assert!(passed, "the zero-tolerance assertion must pass");
}

/// The identical document in the default precision still answers exactly
/// `1.0`. This is the other half of the pin: it shows the fixture's arithmetic
/// really does differ between the two precisions, so test 1 cannot pass by
/// accident.
#[test]
fn float64_document_is_unchanged() {
    let (passed, actual) = only_actual("f64_per_op_rounding.esm");
    assert_eq!(
        actual.to_bits(),
        1.0_f64.to_bits(),
        "the Float64 path must be bit-unchanged; got {actual:?}"
    );
    assert!(passed);
}

// ---------------------------------------------------------------------------
// 2. Ingress and the mode guard.
//
// The kernel tables themselves are pinned inside the crate, next to their
// definitions, where `apply_binary` / `apply_unary` / `ReduceKind::combine` are
// reachable: `simulate_array::eval::kernel_equivalence_tests` and
// `aggregate::reduce_tests`.
// ---------------------------------------------------------------------------

/// A literal that is not a binary32 number rounds on ingress, so a value that
/// reaches a result through NO operator is still binary32.
#[test]
fn literals_round_on_ingress() {
    let _g = precision::enter(Precision::Float32);
    assert_eq!(precision::round(0.1).to_bits(), (0.1_f32 as f64).to_bits());
    assert_ne!(precision::round(0.1).to_bits(), 0.1_f64.to_bits());
}

/// The precision guard restores what it replaced, including when nested, so a
/// Float32 build cannot leak into the next evaluation on the same thread.
#[test]
fn the_guard_restores_the_enclosing_precision() {
    assert_eq!(precision::active(), Precision::Float64);
    {
        let _outer = precision::enter(Precision::Float32);
        assert_eq!(precision::active(), Precision::Float32);
        {
            let _inner = precision::enter(Precision::Float64);
            assert_eq!(precision::active(), Precision::Float64);
        }
        assert_eq!(precision::active(), Precision::Float32);
    }
    assert_eq!(precision::active(), Precision::Float64);
}

// ---------------------------------------------------------------------------
// 3. Nothing falls back silently.
// ---------------------------------------------------------------------------

/// An `element_type` this evaluator does not implement is an error naming
/// itself — not a quiet binary64 evaluation, which is the defect class this
/// whole change exists to remove.
#[test]
fn an_unknown_element_type_is_an_error() {
    for bad in ["Float16", "float32", "Double", "f32"] {
        let err = Precision::from_element_type(Some(bad))
            .unwrap_err()
            .to_string();
        assert!(
            err.contains("unsupported_element_type") && err.contains(bad),
            "{bad}: {err}"
        );
    }
    assert_eq!(
        Precision::from_element_type(None).unwrap(),
        Precision::Float64,
        "an absent element_type is the schema default"
    );
}

/// The constructs whose numeric work is hand-written binary64 are refused under
/// Float32, naming themselves. Evaluating one in binary64 while everything
/// around it rounded is the silent fallback the brief forbids.
#[test]
fn constructs_binary32_cannot_carry_are_named() {
    for (op, name) in [
        ("intersect_polygon", None),
        ("polygon_intersection_area", None),
        ("fn", Some("interp.linear")),
        ("fn", Some("interp.bilinear")),
        ("fn", Some("datetime.julian_day")),
    ] {
        let hit = precision::f32_unsupported_reason(op, name);
        let (construct, _) = hit
            .unwrap_or_else(|| panic!("{op}/{name:?} must be rejected under Float32"));
        let expected = name.unwrap_or(op);
        assert!(
            construct.contains(expected),
            "the diagnostic must name the construct: {construct}"
        );
    }
    // Exact-integer closed functions are representable and stay allowed.
    for (op, name) in [
        ("fn", Some("interp.searchsorted")),
        ("fn", Some("datetime.year")),
        ("fn", Some("datetime.day_of_year")),
        ("+", None),
        ("aggregate", None),
    ] {
        assert!(
            precision::f32_unsupported_reason(op, name).is_none(),
            "{op}/{name:?} must remain evaluable under Float32"
        );
    }
}

/// An index set larger than binary32's exact-integer range is refused naming
/// itself: index expressions share the value kernels, so a subscript that
/// large would round and a gather would read the wrong cell.
#[test]
fn an_unaddressable_index_set_is_named() {
    assert!(precision::check_index_set_extent("rows", precision::F32_EXACT_INT_LIMIT).is_ok());
    let err = precision::check_index_set_extent("rows", precision::F32_EXACT_INT_LIMIT + 1)
        .unwrap_err()
        .to_string();
    assert!(err.contains("float32_unsupported") && err.contains("rows"), "{err}");
}
