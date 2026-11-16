//! Cross-language conformance: a SHAPED observed whose right-hand side is a
//! SCALAR fills every cell of its declared shape (esm-spec §4.3.4).
//!
//! Shared fixture + Julia-minted golden live under
//! `tests/conformance/shaped_observed_scalar_broadcast/` (repo root); the Julia
//! runner (`conformance_shaped_observed_scalar_broadcast_test.jl`) and the
//! Python runner (`test_shaped_observed_scalar_broadcast_conformance.py`) gate
//! the same golden.
//!
//! A scalar operand replicates along every axis of a shaped result, and a
//! right-hand side that is a scalar is the one-operand case of that rule. The
//! fixture writes it as a literal, as a scalar parameter, and as an `ifelse`
//! whose predicate is a constant, so it evaluates to its scalar branch
//! (issue #262). The wholesale observed rule stored such a value as a 0-d
//! array, which no longer matched the declared rank, so the assertion reader
//! found no field and failed with `array state '<name>' has no cells in var_map`.

#![cfg(not(target_arch = "wasm32"))]

use crate::common::tier::{Declared, GoldenCheck, Tier};

#[test]
fn scalar_rhs_broadcast_matches_golden() {
    // This fixture's `ifelse` has branch value boxes that differ under a
    // runtime scalar condition, which the tape cannot lower, so `native`
    // refuses it by NAME (API_SPEC §5.8). The golden it is compared
    // against is the reference evaluator's.
    Tier::open("shaped_observed_scalar_broadcast").check_all(&GoldenCheck {
        compiler: Some(earthsci_ast::Compiler::Interpreter),
        declared: Declared::ActualNearExpected,
        ..Default::default()
    });
}
