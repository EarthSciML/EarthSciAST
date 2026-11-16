//! Cross-language conformance: the INDEXED LHS spelling of an ARRAY-shaped
//! observed (category `pde_inline_observed_indexed_lhs`).
//!
//! The shared fixture, the declared assertions and the Julia-minted goldens
//! live under `tests/conformance/pde_inline_observed_indexed_lhs/` (repo root);
//! the Julia runner (`conformance_pde_inline_observed_indexed_lhs_test.jl`) and
//! the Python runner (`test_pde_inline_observed_indexed_lhs_conformance.py`)
//! gate the same manifest.
//!
//! The defect it closes: esm-spec §6.3.1 admits TWO LHS spellings for the
//! equation that DEFINES an unknown — bare (`y ~ f(…)`) and indexed
//! (`y[i] ~ f(…)`, which defines the whole array `y`) — and neither is
//! restricted by rank, since the defining form is read through the LHS's BASE
//! NAME. Julia's tree-walk build classified equations by the SYNTACTIC
//! `lhs isa VarExpr` instead, so an array-shaped observed written the indexed
//! way matched no owner bucket and was refused outright with
//! `E_TREEWALK_UNSUPPORTED_SHAPE` on a document Rust and Python both ran
//! (issue #232).
//!
//! Both array observeds here use the indexed spelling: `wf` is STATE-FREE and
//! `ws` is STATE-DEPENDENT, the two classes a binding routes differently, so
//! fixing one path only does not pass this category.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Alg, SolveOptions, load_string};
use earthsci_ast::{InlineTestOptions, run_inline_tests_with_options};
use std::fs;

use crate::common;
use crate::common::tier::{Closeness, Declared, GoldenCheck, Tier};

#[test]
fn indexed_lhs_array_observed_runs() {
    Tier::open("pde_inline_observed_indexed_lhs").check_all(&GoldenCheck {
        golden_variable: true,
        closeness: Closeness::SumBound,
        declared: Declared::SameAssertion,
        ..Default::default()
    });
}

/// CONFORMANCE_SPEC §5.36.2: a bare-index definition whose RHS is not a `faq`
/// naming the LHS subscripts in order is REFUSED — every assertion reports no
/// actual and is not passed, and the message carries the code and names the
/// variable.
#[test]
fn bare_index_definition_outside_the_runnable_form_is_refused() {
    let dir = common::category_dir("pde_inline_observed_indexed_lhs");
    let manifest = common::read_json(dir.join("manifest.json"));
    let rs = &manifest["integrators"]["rust"];
    let opts = SolveOptions {
        alg: Alg::Erk,
        reltol: Some(rs["reltol"].as_f64().expect("reltol")),
        abstol: Some(rs["abstol"].as_f64().expect("abstol")),
        ..Default::default()
    };
    let refusals = manifest["refusals"].as_array().expect("refusals");
    assert!(!refusals.is_empty());
    for rf in refusals {
        let id = rf["id"].as_str().expect("id");
        let esm_path = dir.join(rf["path"].as_str().expect("path"));
        let text =
            fs::read_to_string(&esm_path).unwrap_or_else(|e| panic!("read {esm_path:?}: {e}"));
        let file = load_string(&text).unwrap_or_else(|e| panic!("{id} does not load: {e}"));
        let results = run_inline_tests_with_options(
            &file,
            &InlineTestOptions {
                model_name: rf["model"].as_str().map(str::to_string),
                solve: opts.clone(),
                base_dir: Some(dir.clone()),
                ..Default::default()
            });
        assert_eq!(
            results.len() as u64,
            rf["assertion_count"].as_u64().expect("assertion_count"),
            "{id}: assertion count"
        );
        let code = rf["diagnostic"].as_str().expect("diagnostic");
        let var = rf["names_variable"].as_str().expect("names_variable");
        for r in &results {
            assert!(
                !r.passed,
                "{id}#{}: must be refused, not passed",
                r.assertion_idx
            );
            assert!(
                r.actual.is_none(),
                "{id}#{}: a refusal has no actual, got {:?}",
                r.assertion_idx,
                r.actual
            );
            assert!(
                r.message.contains(code),
                "{id}: want {code}, got: {}",
                r.message
            );
            assert!(
                r.message.contains(var),
                "{id}: must name {var}, got: {}",
                r.message
            );
        }
    }
}
