//! Acceptance tests for the CONST-subexpression hoist (ess-lih).
//!
//! The vectorized overlay caches a **box-pure** subtree — one whose leaves are
//! only the enclosing box's index symbols and CONST-tier names (hoisted static
//! observeds, scalar parameters) — in a store that outlives the RHS call, so a
//! model's geometry factors are computed once for a whole solve instead of once
//! per step. Two things have to hold for that to be safe, and both are checked
//! here rather than argued:
//!
//! 1. **The cached value is still the right value on later calls**, when the
//!    STATE has moved. That is the property a stale-cache bug breaks silently:
//!    the first call is right, so a single-shot comparison sees nothing wrong.
//!    `hoisted_geometry_matches_the_oracle_on_every_call` therefore drives one
//!    warm scratch over a sequence of different states and compares each result
//!    to the per-cell oracle at raw bit precision.
//!
//! 2. **The cache does not outlive what it was computed from.** A box-pure
//!    subtree may read scalar parameters, so a caller that reuses one scratch
//!    across a parameter change must not be served the old parameters' values.
//!    On the `simulate` path this cannot arise (the driver builds a fresh
//!    scratch per integration segment), but `debug_eval_rhs_into` exposes it,
//!    and a parameter sweep is exactly the shape of caller that would hit it.
//!    `a_parameter_change_invalidates_the_hoisted_values` pins it.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::load_string;
use earthsci_ast::simulate_array::{ArrayCompiled, RhsStats};

/// A 1-D advection-ish tendency carrying a `k`-dependent geometry factor built
/// from the loop index and two parameters:
///
/// ```text
/// D(u[i]) = (a_geom · sin(0.1 · (i − 1))² + b_geom) · u[i]
/// ```
///
/// The parenthesized factor is box-pure: its leaves are the output index `i` and
/// the parameters `a_geom` / `b_geom`, so it is exactly what the hoist targets —
/// a coordinate ramp, a transcendental, a power, and a parameter multiply, all
/// invariant across every RHS call of a solve. `u[i]` keeps the whole tendency
/// state-dependent, so the enclosing product is NOT hoistable and the cut lands
/// on the geometry factor, which is the intended granularity.
fn geom_json(n: usize) -> String {
    const TEMPLATE: &str = r#"{
 "esm": "1.0.0",
 "metadata": {"name": "const_hoist_geom"},
 "models": {
  "Geom": {
   "variables": {
     "u": {"type": "unknown", "shape": ["i"]},
     "a_geom": {"type": "parameter", "units": "1", "default": 3.0},
     "b_geom": {"type": "parameter", "units": "1", "default": 0.5}
   },
   "equations": [
    {
     "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, __N__]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "ranges": {"i": [1, __N__]},
             "expr": {"op": "*", "args": [
               {"op": "+", "args": [
                 {"op": "*", "args": [
                   "a_geom",
                   {"op": "^", "args": [
                     {"op": "sin", "args": [
                       {"op": "*", "args": [0.1, {"op": "-", "args": ["i", 1]}]}]},
                     2]}]},
                 "b_geom"]},
               {"op": "index", "args": ["u", "i"]}]}}
    }
   ]
  }
 }
}"#;
    TEMPLATE.replace("__N__", &n.to_string())
}

fn compile(n: usize) -> ArrayCompiled {
    let file = load_string(&geom_json(n)).expect("load json model");
    ArrayCompiled::from_file(&file).expect("compile json model")
}

/// A state that changes shape-of-values between calls, so a cached *state*
/// read (as opposed to a cached CONST read) would show up immediately.
fn state(n: usize, seed: f64) -> Vec<f64> {
    (0..n)
        .map(|k| (0.7 * k as f64 + seed).sin() + 1.5)
        .collect()
}

fn hex(v: &[f64]) -> Vec<String> {
    v.iter().map(|x| format!("{:016x}", x.to_bits())).collect()
}

/// Drive ONE warm scratch across a sequence of states and compare every result
/// to the per-cell oracle at raw bit precision. Call 1 fills the persistent
/// store; calls 2..n are the ones a stale-value bug would corrupt.
#[test]
fn hoisted_geometry_matches_the_oracle_on_every_call() {
    for n in [8usize, 32] {
        let compiled = compile(n);
        let nstates = compiled.state_variable_names().len();
        let params = compiled.debug_resolve_params(&HashMap::new());
        let mut scratch = compiled.debug_new_scratch();
        let mut dy = vec![0.0f64; nstates];
        let mut stats = RhsStats::default();

        for step in 0..6 {
            let s = state(nstates, 0.3 * step as f64);
            compiled.debug_eval_rhs_into(&s, 0.0, &params, &mut dy, &mut scratch, &mut stats);
            // `force_scalar = true` is the per-cell oracle for an `ArrayLoop`
            // state rule, and it runs on its own throw-away scratch, so it can
            // never be served a hoisted value.
            let (oracle, _) = compiled.debug_eval_rhs(&s, 0.0, &HashMap::new(), true);
            assert_eq!(
                hex(&dy),
                hex(&oracle),
                "N={n} step={step}: hoisted RHS diverged from the per-cell oracle"
            );
        }
    }
}

/// Reusing a scratch across a parameter change must not serve values computed
/// from the previous parameters. The hoisted factor here is `a_geom·sin(…)² +
/// b_geom`, so a stale store would silently keep the old `a_geom`.
#[test]
fn a_parameter_change_invalidates_the_hoisted_values() {
    let n = 16usize;
    let compiled = compile(n);
    let nstates = compiled.state_variable_names().len();
    let s = state(nstates, 1.1);

    let p_lo = compiled.debug_resolve_params(&HashMap::from([("a_geom".to_string(), 3.0)]));
    let p_hi = compiled.debug_resolve_params(&HashMap::from([("a_geom".to_string(), 11.0)]));
    assert_ne!(p_lo, p_hi, "the two parameter vectors must actually differ");

    let mut stats = RhsStats::default();
    let mut dy = vec![0.0f64; nstates];

    // A scratch that has already been warmed on `p_lo` — its persistent store is
    // full of values built from a_geom = 3.
    let mut reused = compiled.debug_new_scratch();
    for _ in 0..4 {
        compiled.debug_eval_rhs_into(&s, 0.0, &p_lo, &mut dy, &mut reused, &mut stats);
    }
    let at_lo = hex(&dy);

    // Same scratch, different parameters.
    compiled.debug_eval_rhs_into(&s, 0.0, &p_hi, &mut dy, &mut reused, &mut stats);
    let at_hi_reused = hex(&dy);

    // A pristine scratch is the reference for what `p_hi` must produce.
    let mut fresh = compiled.debug_new_scratch();
    compiled.debug_eval_rhs_into(&s, 0.0, &p_hi, &mut dy, &mut fresh, &mut stats);
    let at_hi_fresh = hex(&dy);

    assert_ne!(
        at_lo, at_hi_fresh,
        "the parameter must actually change the answer, or this test proves nothing"
    );
    assert_eq!(
        at_hi_reused, at_hi_fresh,
        "a reused scratch served values hoisted under the PREVIOUS parameter vector"
    );
}
