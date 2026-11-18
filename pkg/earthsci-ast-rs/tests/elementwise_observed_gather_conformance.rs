//! Cross-language conformance: an ARRAY-shaped OBSERVED written ELEMENTWISE over
//! another array and consumed ONLY through an `index(f, j)` gather inside an
//! `faq` body (esm-spec §4.3.4 elementwise broadcast, §6.6.5 assertions).
//!
//! Shared fixtures + Julia-minted goldens live under
//! `tests/conformance/elementwise_observed_gather/` (repo root); the Julia
//! runner (`conformance_elementwise_observed_gather_test.jl`) and the Python
//! runner (`test_elementwise_observed_gather_conformance.py`) gate the same
//! goldens.
//!
//! `zc` is a const field shaped `[lev]`; `f = 1 + cos(pi*zc)` is the natural
//! per-level spelling; `colsum[i] = Σ_{j≤i} f[j]` and `total = Σ_j f[j]` read it
//! through gathers and nothing else reads it at all. A binding that inlines `f`
//! into its readers by name substitution turns the gather into
//! `index(1 + cos(pi*zc), j)` and must distribute it over the elementwise
//! combination down to the array leaf. Julia's tree-walk resolver tested only
//! the IMMEDIATE operands for array-ness, so the leaf under the `cos` matched
//! nothing and `zc` reached the compiler bare (`E_TREEWALK_UNBOUND_VARIABLE`,
//! issue #175); Rust and Python already evaluated the document. This suite pins
//! Rust against the reference binding so that stays true.
//!
//! The category carries a controlled PAIR: `elementwise_gather` is the shape
//! under test and `explicit_gather` is the identical field written as an
//! explicit `aggregate(k from lev; 1 + cos(pi*index(zc, k)))`. They share every
//! assertion, so this suite additionally requires them to agree with each other
//! actual-for-actual — a divergence is the gather push-down, not the physics.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::BTreeMap;

use crate::common;
use crate::common::tier::{GoldenCheck, Tier};

#[test]
fn elementwise_observed_gather_matches_golden() {
    let tier = Tier::open("elementwise_observed_gather");
    let (rtol, atol) = (tier.rtol, tier.atol);
    let check = GoldenCheck {
        by_test_id: true,
        ..Default::default()
    };
    let mut by_id: BTreeMap<String, BTreeMap<usize, f64>> = BTreeMap::new();
    for fx in tier.fixtures() {
        let id = fx["id"].as_str().expect("id").to_string();
        by_id.insert(id, tier.check_fixture(fx, &check));
    }

    // The elementwise spelling under test and the explicit-gather control must
    // agree actual-for-actual: they are the same field written two ways.
    let elementwise = by_id
        .get("elementwise_gather")
        .expect("elementwise_gather fixture");
    let explicit = by_id
        .get("explicit_gather")
        .expect("explicit_gather fixture");
    assert_eq!(
        elementwise.keys().collect::<Vec<_>>(),
        explicit.keys().collect::<Vec<_>>()
    );
    for (idx, value) in elementwise {
        let other = explicit[idx];
        assert!(
            common::close(*value, other, rtol, atol),
            "assertion {idx}: elementwise {value} vs explicit {other}"
        );
    }
}
