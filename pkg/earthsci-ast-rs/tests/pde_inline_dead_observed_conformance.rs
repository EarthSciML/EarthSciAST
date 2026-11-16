//! Cross-language conformance: a §6.6.5 assertion may read an array OBSERVED
//! that NO LIVE EQUATION CONSUMES (esm-spec §6.6.5, §5.23).
//!
//! Shared fixture + Julia-minted golden live under
//! `tests/conformance/pde_inline_dead_observed/` (repo root); the Julia runner
//! (`conformance_pde_inline_dead_observed_test.jl`) and the Python runner
//! (`test_pde_inline_dead_observed_conformance.py`) gate the same golden.
//!
//! An inline test's natural target is a quantity computed FOR the test — a
//! tendency, a flux, a diagnostic — which by construction nothing else reads.
//! Model `M` declares two such dead observeds: `diag = 2*base`, and
//! `chain = diag + base`, which is dead AND reads a dead observed. Julia
//! refused both (`array state 'diag' has no cells in var_map`) because its
//! build inlines an elementwise array observed into its readers and drops the
//! equation, and a dead one has no readers to be inlined into; Rust REQUESTS
//! the asserted observed from the runtime, which never asked whether anything
//! else reads it, so it already answered them. This suite pins that against
//! the reference binding.
//!
//! The only state is `u`, integrated with a zero right-hand side, so the
//! trajectory is constant and every assertion is exact under any pinned solver
//! family: a divergence here is a semantics divergence, never an integrator one.

#![cfg(not(target_arch = "wasm32"))]

use crate::common::tier::{Declared, GoldenCheck, Tier};

#[test]
fn dead_observed_matches_golden() {
    Tier::open("pde_inline_dead_observed").check_all(&GoldenCheck {
        declared: Declared::ActualNearExpected,
        ..Default::default()
    });
}
