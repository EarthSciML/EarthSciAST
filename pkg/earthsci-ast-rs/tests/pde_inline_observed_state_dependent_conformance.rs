//! Cross-language conformance: esm-spec §6.6.5 assertions on a STATE-DEPENDENT
//! array OBSERVED (category `pde_inline_observed_state_dependent`).
//!
//! The shared fixture, the declared assertions and the Julia-minted goldens
//! live under `tests/conformance/pde_inline_observed_state_dependent/` (repo
//! root); the Julia runner
//! (`conformance_pde_inline_observed_state_dependent_test.jl`) and the Python
//! runner (`test_pde_inline_observed_state_dependent_conformance.py`) gate the
//! same manifest.
//!
//! The defect it closes: an array-shaped observed whose value depends on the
//! integrated state (`g = 2*u + rate`) reaches NO build-time product — only
//! STATE-FREE observeds hoist into a `BuildInspection`'s setup arrays — and is
//! not a scalar output row either, so every binding refused such an assertion
//! outright with "array state 'g' has no cells in var_map". §6.6.5 admits any
//! shaped variable in a `coords` / `reduce` assertion and §5.23 makes a
//! reference denote its expansion, so the observed must be read at the SAMPLED
//! STATE. In Rust that means the runner REQUESTS it
//! (`SolveOptions::output_observed`), which the array runtime already knows how
//! to emit as one row per cell. The fixture's `rate` is the state-free array
//! observed of the same document, asserted alongside so the
//! build-materialized path stays pinned too.

#![cfg(not(target_arch = "wasm32"))]

use crate::common::tier::{Closeness, Declared, GoldenCheck, Tier};

#[test]
fn state_dependent_array_observed_is_assertable() {
    Tier::open("pde_inline_observed_state_dependent").check_all(&GoldenCheck {
        golden_variable: true,
        closeness: Closeness::SumBound,
        declared: Declared::SameAssertion,
        ..Default::default()
    });
}
