//! Acceptance tests for the Step 3b fast tape executor's invalidation
//! discipline, mirroring `tests/pde_const_hoist.rs` for the CONST-hoist:
//!
//! 1. **A warm taped scratch stays right as the state moves.** The CONST
//!    section runs once per scratch and its slab values are then READ by every
//!    later call — a stale-value bug is invisible on call 1, so a sequence of
//!    different states is driven through ONE scratch and each result compared
//!    to the per-cell oracle at raw bit precision.
//!
//! 2. **The CONST section does not outlive the parameters it read.** A
//!    CONST-section value may fold scalar parameters (here: an observed
//!    `c[j] = cos(a_geom · j)` and an inline geometry factor), so a caller
//!    reusing one scratch across a parameter change must be re-primed — the
//!    `bind_params`-style generation guard in `run_tape_call`. This is the
//!    NEGATIVE CONTROL: remove the guard and `reused_at_hi` keeps the stale
//!    `a_geom = 3` CONST values and the test fails.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::load;
use earthsci_ast::simulate_array::{ArrayCompiled, RhsStats};

/// A stencil model whose RHS folds BOTH a CONST-tier observed (`c[i]`,
/// state-free and parameter-dependent — it lands in the tape's CONST section)
/// and a state-dependent term:
///
/// ```text
/// c[i]    = cos(a_geom · i) + b_geom          (observed, CONST tier)
/// D(u[i]) = c[i] · u[i] − 0.1 · u[i]
/// ```
fn geom_json(n: usize) -> String {
    const TEMPLATE: &str = r#"{
 "esm": "0.1.0",
 "metadata": {"name": "tape_const_geom"},
 "models": {
  "Geom": {
   "variables": {
     "u": {"type": "state", "shape": ["i"]},
     "a_geom": {"type": "parameter", "units": "1", "default": 3.0},
     "b_geom": {"type": "parameter", "units": "1", "default": 0.5},
     "c": {"type": "observed", "shape": ["i"],
           "expression": {"op": "aggregate", "args": [], "output_idx": ["i"],
               "ranges": {"i": [1, __N__]},
               "expr": {"op": "+", "args": [
                 {"op": "cos", "args": [{"op": "*", "args": ["a_geom", "i"]}]},
                 "b_geom"]}}}
   },
   "equations": [
    {
     "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, __N__]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "ranges": {"i": [1, __N__]},
             "expr": {"op": "-", "args": [
               {"op": "*", "args": [
                 {"op": "index", "args": ["c", "i"]},
                 {"op": "index", "args": ["u", "i"]}]},
               {"op": "*", "args": [0.1, {"op": "index", "args": ["u", "i"]}]}
             ]}}
    }
   ]
  }
 }
}"#;
    TEMPLATE.replace("__N__", &n.to_string())
}

fn compile(n: usize) -> ArrayCompiled {
    let file = load(&geom_json(n)).expect("load geom model");
    ArrayCompiled::from_file(&file).expect("compile geom model")
}

fn state(n: usize, seed: f64) -> Vec<f64> {
    (0..n).map(|k| (0.9 * k as f64 + seed).sin() + 1.5).collect()
}

fn hex(v: &[f64]) -> Vec<String> {
    v.iter().map(|x| format!("{:016x}", x.to_bits())).collect()
}

/// Drive ONE warm taped scratch across a sequence of states and compare every
/// result to the production interpreter at raw bit precision. Call 1 primes
/// the CONST section; calls 2..n are the ones a stale-slab bug would corrupt.
#[test]
fn taped_rhs_matches_the_interpreter_on_every_call() {
    for n in [8usize, 32] {
        let compiled = compile(n);
        let nstates = compiled.state_variable_names().len();
        let params = compiled.debug_resolve_params(&HashMap::new());
        let mut scratch = compiled.debug_new_scratch_taped();
        assert!(scratch.has_tape(), "N={n}: scratch must carry a tape");
        let mut dy = vec![0.0f64; nstates];
        let mut stats = RhsStats::default();

        for step in 0..6 {
            let s = state(nstates, 0.3 * step as f64);
            compiled.debug_eval_rhs_into(&s, 0.0, &params, &mut dy, &mut scratch, &mut stats);
            let (oracle, _) = compiled.debug_eval_rhs(&s, 0.0, &HashMap::new(), false);
            assert_eq!(
                hex(&dy),
                hex(&oracle),
                "N={n} step={step}: taped RHS diverged from the interpreter"
            );
        }
        assert!(stats.taped_rules > 0, "the tape must have run");
        assert_eq!(stats.fallback_rules, 0, "fixture must tape fully");
    }
}

/// Reusing a taped scratch across a parameter change must re-prime the CONST
/// section rather than serve slab values computed from the previous
/// parameters. Negative control for the `params_gen` guard in the executor:
/// remove the guard and `at_hi_reused` reproduces `a_geom = 3`'s CONST `c[i]`.
#[test]
fn a_parameter_change_reprimes_the_const_section() {
    let n = 16usize;
    let compiled = compile(n);
    let nstates = compiled.state_variable_names().len();
    let s = state(nstates, 1.1);

    let p_lo = compiled.debug_resolve_params(&HashMap::from([("a_geom".to_string(), 3.0)]));
    let p_hi = compiled.debug_resolve_params(&HashMap::from([("a_geom".to_string(), 11.0)]));
    assert_ne!(p_lo, p_hi, "the two parameter vectors must actually differ");

    let mut stats = RhsStats::default();
    let mut dy = vec![0.0f64; nstates];

    // A taped scratch already primed on `p_lo` — its CONST slab holds values
    // built from a_geom = 3.
    let mut reused = compiled.debug_new_scratch_taped();
    assert!(reused.has_tape());
    for _ in 0..4 {
        compiled.debug_eval_rhs_into(&s, 0.0, &p_lo, &mut dy, &mut reused, &mut stats);
    }
    let at_lo = hex(&dy);

    // Same scratch, different parameters.
    compiled.debug_eval_rhs_into(&s, 0.0, &p_hi, &mut dy, &mut reused, &mut stats);
    let at_hi_reused = hex(&dy);

    // A pristine taped scratch is the reference for what `p_hi` must produce.
    let mut fresh = compiled.debug_new_scratch_taped();
    compiled.debug_eval_rhs_into(&s, 0.0, &p_hi, &mut dy, &mut fresh, &mut stats);
    let at_hi_fresh = hex(&dy);

    // And the interpreter oracle agrees with the fresh taped scratch.
    let (oracle, _) = compiled.debug_eval_rhs(
        &s,
        0.0,
        &HashMap::from([("a_geom".to_string(), 11.0)]),
        false,
    );
    assert_eq!(at_hi_fresh, hex(&oracle), "fresh taped scratch vs oracle");

    assert_ne!(
        at_lo, at_hi_fresh,
        "the parameter must actually change the answer, or this test proves nothing"
    );
    assert_eq!(
        at_hi_reused, at_hi_fresh,
        "a reused taped scratch served CONST-section values primed under the \
         PREVIOUS parameter vector"
    );
}
