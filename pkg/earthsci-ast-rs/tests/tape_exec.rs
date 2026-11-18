//! Acceptance tests for the Step 3b fast tape executor's invalidation
//! discipline, mirroring `tests/pde_const_hoist.rs` for the CONST-hoist:
//!
//! 1. **A warm taped workspace stays right as the state moves.** The CONST
//!    section runs once per workspace and its slab values are then READ by every
//!    later call — a stale-value bug is invisible on call 1, so a sequence of
//!    different states is driven through ONE workspace and each result compared
//!    to the per-cell oracle at raw bit precision.
//!
//! 2. **The CONST section does not outlive the parameters it read.** A
//!    CONST-section value may fold scalar parameters (here: an observed
//!    `c[j] = cos(a_geom · j)` and an inline geometry factor), so a caller
//!    reusing one workspace across a parameter change must be re-primed — the
//!    `bind_params`-style generation guard in `run_tape_call`. This is the
//!    NEGATIVE CONTROL: remove the guard and `reused_at_hi` keeps the stale
//!    `a_geom = 3` CONST values and the test fails.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::{Compiler, EsmProblem, ProblemOptions, Rhs, esm_problem};

use crate::common::rhs::ProblemRhs;

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
 "esm": "2.0.0",
 "metadata": {"name": "tape_const_geom"},
 "models": {
  "Geom": {
   "variables": {
     "u": {"type": "unknown", "shape": ["i"]},
     "a_geom": {"type": "parameter", "units": "1", "default": 3.0},
     "b_geom": {"type": "parameter", "units": "1", "default": 0.5},
     "c": {"type": "unknown", "shape": ["i"]}
   },
   "equations": [
                {"lhs": "c", "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
               "ranges": {"i": [1, __N__]},
               "expr": {"op": "+", "args": [
                 {"op": "cos", "args": [{"op": "*", "args": ["a_geom", "i"]}]},
                 "b_geom"]}}},
    {
     "lhs": {"op": "faq", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, __N__]}},
     "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
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

/// The model under `compiler`. Its right-hand side is driven through the
/// public program: under `native` the strict tape (a program a rule leaves is
/// refused), under `interpreter` the per-cell oracle.
fn problem(n: usize, compiler: Compiler) -> EsmProblem {
    // The probes pass the state explicitly; any starting value builds it.
    let mut doc: serde_json::Value = serde_json::from_str(&geom_json(n)).expect("parse geom model");
    crate::common::supply_state_defaults(&mut doc);
    esm_problem(
        &doc,
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(compiler),
            rhs: Rhs::Always,
            ..Default::default()
        },
    )
    .expect("build geom model")
}

fn state(n: usize, seed: f64) -> Vec<f64> {
    (0..n)
        .map(|k| (0.9 * k as f64 + seed).sin() + 1.5)
        .collect()
}

fn hex(v: &[f64]) -> Vec<String> {
    v.iter().map(|x| format!("{:016x}", x.to_bits())).collect()
}

/// Drive ONE warm taped workspace across a sequence of states and compare every
/// result to the production interpreter at raw bit precision. Call 1 primes
/// the CONST section; calls 2..n are the ones a stale-slab bug would corrupt.
#[test]
fn taped_rhs_matches_the_interpreter_on_every_call() {
    for n in [8usize, 32] {
        let mut taped = ProblemRhs::new(&problem(n, Compiler::Native));
        let mut oracle = ProblemRhs::new(&problem(n, Compiler::Interpreter));
        let nstates = taped.n_states();
        let mut dy = vec![0.0f64; nstates];

        for step in 0..6 {
            let s = state(nstates, 0.3 * step as f64);
            taped.eval_into(&s, 0.0, &mut dy);
            let oracle = oracle.eval(&s, 0.0);
            assert_eq!(
                hex(&dy),
                hex(&oracle),
                "N={n} step={step}: taped RHS diverged from the interpreter"
            );
        }
    }
}

/// Reusing a taped workspace across a parameter change must re-prime the CONST
/// section rather than serve slab values computed from the previous
/// parameters. Negative control for the `params_gen` guard in the executor:
/// remove the guard and `at_hi_reused` reproduces `a_geom = 3`'s CONST `c[i]`.
#[test]
fn a_parameter_change_reprimes_the_const_section() {
    let n = 16usize;
    let native = problem(n, Compiler::Native);
    let lo = HashMap::from([("a_geom".to_string(), 3.0)]);
    let hi = HashMap::from([("a_geom".to_string(), 11.0)]);

    // A taped workspace already primed on `lo`: its CONST slab holds values
    // built from a_geom = 3.
    let mut reused = ProblemRhs::with_params(&native, &lo);
    let p_lo = reused.params().to_vec();
    let s = state(reused.n_states(), 1.1);
    let mut dy = vec![0.0f64; s.len()];
    for _ in 0..4 {
        reused.eval_into(&s, 0.0, &mut dy);
    }
    let at_lo = hex(&dy);

    // Same workspace, different parameters.
    reused.set_params(&hi);
    assert_ne!(
        p_lo,
        reused.params(),
        "the two parameter vectors must actually differ"
    );
    reused.eval_into(&s, 0.0, &mut dy);
    let at_hi_reused = hex(&dy);

    // A pristine taped workspace is the reference for what `hi` must produce.
    let at_hi_fresh = hex(&ProblemRhs::with_params(&native, &hi).eval(&s, 0.0));

    // And the interpreter oracle agrees with the fresh taped workspace.
    let oracle = ProblemRhs::with_params(&problem(n, Compiler::Interpreter), &hi).eval(&s, 0.0);
    assert_eq!(at_hi_fresh, hex(&oracle), "fresh taped workspace vs oracle");

    assert_ne!(
        at_lo, at_hi_fresh,
        "the parameter must actually change the answer, or this test proves nothing"
    );
    assert_eq!(
        at_hi_reused, at_hi_fresh,
        "a reused taped workspace served CONST-section values primed under the \
         PREVIOUS parameter vector"
    );
}
