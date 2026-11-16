//! Cross-language conformance: esm-spec §6.6.5 inline `reference` scope — the
//! field's DIMENSION NAMES are free variables of the reference (category
//! `pde_inline_reference_dimension_names`).
//!
//! The shared fixture, the declared assertions and the Julia-minted goldens
//! live under `tests/conformance/pde_inline_reference_dimension_names/` (repo
//! root); the Julia runner
//! (`conformance_pde_inline_reference_dimension_names_test.jl`) and the Python
//! runner (`test_pde_inline_reference_dimension_names_conformance.py`) gate the
//! same manifest.
//!
//! The defect it closes: §6.6.5 says an inline `reference` is "an Expression
//! whose free variables are the domain dimension names", but every binding
//! evaluated the reference as ONE build-time array expression and sampled it
//! per cell, so a dimension name mentioned free was unbound
//! (`E_TREEWALK_UNBOUND_NAME: 'x'` here) and authors had to spell every
//! reference as an explicit `aggregate(i from x; …)` gather. For a field shaped
//! over index sets the dimension names are the asserted variable's `shape`
//! entries, bound per cell to the 1-based position along the axis (the index
//! space `coords` reads). The fixture spells one exact decay field through the
//! free-name analytic form, a table lookup by the dimension name, the explicit
//! gather, and a gather that rebinds the dimension name as its own loop symbol
//! (which must NOT be wrapped a second time), plus a reference-free `mean`.

#![cfg(not(target_arch = "wasm32"))]

use crate::common::tier::{Closeness, Declared, GoldenCheck, Tier};

#[test]
fn reference_dimension_names_are_bound_per_cell() {
    Tier::open("pde_inline_reference_dimension_names").check_all(&GoldenCheck {
        golden_variable: true,
        closeness: Closeness::SumBound,
        declared: Declared::SameAssertion,
        ..Default::default()
    });
}
