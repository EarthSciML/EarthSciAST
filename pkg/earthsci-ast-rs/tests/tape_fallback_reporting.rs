//! A rule the tape could not compile must be NAMED on the way out.
//!
//! A fallback rule is evaluated by the per-cell oracle, which re-walks the rule
//! body once per grid cell per RHS call. The numbers are bit-identical to the
//! vectorized path — that is the whole point of the fallback — so nothing about
//! the *result* betrays it, while the runtime can differ by three to four
//! orders of magnitude and, unlike the taped path, grows with the cell count.
//! Before this, the tape build knew exactly which rule and why, and threw it
//! away at both production build sites; from a caller's seat (especially a
//! browser one, with no native `tape_report` to run) a model that would not
//! finish was indistinguishable from a model that was merely big.
//!
//! Pinned here:
//!
//!   1. a surviving fallback reaches [`SolutionMetadata::tape_fallbacks`] with
//!      its rule name and its reason;
//!   2. a fully taped model reports an EMPTY list — the negative control,
//!      without which (1) would pass on a field that is always populated.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::{SimulateOptions, load, simulate};

/// `k` is an array-valued `const` observed, which the whole-array overlay does
/// not cover (`vec_coverage_frontier::frontier_array_valued_const_falls_back`),
/// so the rule that reads it cannot be taped. Kept deliberately unrelated to
/// the nested-aggregate shadowing this release taught the admission test about:
/// this fixture must keep falling back for the assertion to mean anything.
const FALLBACK_MODEL: &str = r#"{
 "esm": "0.8.0",
 "metadata": {"name": "fallback_reporting"},
 "index_sets": {"c": {"kind": "interval", "size": 3}},
 "models": {"M": {
   "variables": {
     "psi": {"type": "state", "shape": ["c"], "default": 1.0},
     "k": {"type": "observed", "shape": ["c"],
           "expression": {"op": "const", "value": [1.0, 2.0, 3.0], "args": []}},
     "a": {"type": "observed", "shape": ["c"],
           "expression": {"op": "+", "args": ["psi", "k"]}}
   },
   "equations": [
     {"lhs": {"op": "D", "args": ["psi"], "wrt": "t"},
      "rhs": {"op": "-", "args": ["a"]}}
   ]
 }}
}"#;

/// The same physics with the constant table written as an arithmetic ramp over
/// the output index instead of an array literal: fully vectorizable, hence
/// fully taped.
const TAPED_MODEL: &str = r#"{
 "esm": "0.8.0",
 "metadata": {"name": "taped_reporting"},
 "index_sets": {"c": {"kind": "interval", "size": 3}},
 "models": {"M": {
   "variables": {
     "psi": {"type": "state", "shape": ["c"], "default": 1.0},
     "k": {"type": "observed", "shape": ["c"],
           "expression": {"op": "aggregate", "args": [], "output_idx": ["i"],
                          "ranges": {"i": [1, 3]}, "expr": "i"}},
     "a": {"type": "observed", "shape": ["c"],
           "expression": {"op": "+", "args": ["psi", "k"]}}
   },
   "equations": [
     {"lhs": {"op": "D", "args": ["psi"], "wrt": "t"},
      "rhs": {"op": "-", "args": ["a"]}}
   ]
 }}
}"#;

fn run(json: &str) -> earthsci_ast::Solution {
    let file = load(json).expect("fixture loads");
    let opts = SimulateOptions::default();
    simulate(&file, (0.0, 0.1), &HashMap::new(), &HashMap::new(), &opts).expect("fixture simulates")
}

#[test]
fn a_surviving_fallback_is_named_in_the_solution_metadata() {
    let sol = run(FALLBACK_MODEL);
    let fb = &sol.metadata.tape_fallbacks;
    assert!(
        !fb.is_empty(),
        "the array-valued `const` rule falls back, so the solve must report it; \
         got an empty list. If this fixture became vectorizable, that is good \
         news — replace it with a construct that is still on the frontier \
         (see tests/vec_coverage_frontier.rs) rather than deleting the test."
    );
    for (rule, reason) in fb {
        assert!(!rule.is_empty(), "every fallback must name its rule");
        assert!(
            !reason.is_empty(),
            "fallback on `{rule}` reached the caller with no reason"
        );
    }
    assert!(
        fb.iter().any(|(_, reason)| reason.contains("const")),
        "the reason must identify the unsupported construct: {fb:?}"
    );
}

#[test]
fn a_fully_taped_model_reports_no_fallbacks() {
    let sol = run(TAPED_MODEL);
    assert!(
        sol.metadata.tape_fallbacks.is_empty(),
        "nothing in this model is unvectorizable, so the list must be empty: {:?}",
        sol.metadata.tape_fallbacks
    );
    // The negative control is only worth anything if the model actually ran.
    assert!(sol.time.len() > 1, "the fixture must have integrated");
}
