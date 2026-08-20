//! Bit-identity gate for the common-subexpression overlay (ess-cse).
//!
//! CSE is a pure restructuring: it evaluates each distinct subtree once per
//! scope instead of once per occurrence. If any bit moves, the arithmetic has
//! changed — so this compares the vectorized+CSE RHS against the **per-cell
//! oracle** (`force_scalar = true`), which is the correctness reference, on raw
//! IEEE bits.
//!
//! The fixtures are chosen to attack the scoping rule specifically:
//!
//! * a body with the SAME subexpression repeated several times (the sharing the
//!   optimization exists for),
//! * a bare output-index symbol used as a value — the coordinate ramp, whose
//!   value depends on the box's `lo` — repeated inside a `makearray` whose
//!   regions have DIFFERENT `lo`. A memo shared across region boundaries would
//!   hand the wrong ramp to a region and the answer would move.
//! * an einsum contraction whose body mentions the contracted index, so the
//!   per-tuple `cvals` binding differs between memo probes. Sharing a term
//!   across contraction tuples would collapse the fold.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::load;
use earthsci_ast::simulate_array::{ArrayCompiled, RhsStats};

fn compile(json: &str) -> ArrayCompiled {
    let file = load(json).expect("fixture parses");
    ArrayCompiled::from_file(&file).expect("fixture compiles")
}

/// A deterministic, non-degenerate state (no zeros, no repeats), so a wrongly
/// shared subexpression cannot coincidentally agree.
fn state(n: usize) -> Vec<f64> {
    (0..n)
        .map(|k| 1.0 + (k as f64) * 0.37 - (k as f64).sin() * 0.11)
        .collect()
}

fn assert_bits(label: &str, got: &[f64], want: &[f64]) {
    assert_eq!(got.len(), want.len(), "{label}: length");
    for (k, (a, b)) in got.iter().zip(want.iter()).enumerate() {
        assert_eq!(
            a.to_bits(),
            b.to_bits(),
            "{label}: slot {k} diverged: {a:?} ({:016x}) vs {b:?} ({:016x})",
            a.to_bits(),
            b.to_bits()
        );
    }
}

fn assert_bit_identical_to_oracle(label: &str, compiled: &ArrayCompiled, u: &[f64]) {
    let (fast, stats) = compiled.debug_eval_rhs(u, 0.0, &HashMap::new(), false);
    let (oracle, _) = compiled.debug_eval_rhs(u, 0.0, &HashMap::new(), true);
    assert_eq!(
        stats.vectorized_rules, 1,
        "{label}: the rule must take the vectorized path for this to test anything \
         (vectorized={}, per-cell={})",
        stats.vectorized_rules, stats.scalar_rules
    );
    assert_eq!(fast.len(), oracle.len(), "{label}: length");
    for (k, (a, b)) in fast.iter().zip(oracle.iter()).enumerate() {
        assert_eq!(
            a.to_bits(),
            b.to_bits(),
            "{label}: slot {k} diverged from the per-cell oracle: \
             {a:?} ({:016x}) vs {b:?} ({:016x})",
            a.to_bits(),
            b.to_bits()
        );
    }
}

/// A `makearray` stencil whose three regions carry the SAME expression text but
/// different region boxes, and whose interior repeats one subexpression four
/// times and the coordinate ramp twice.
fn repeated_subexpr_json(n: usize) -> String {
    // d = u[i] - u[i-1], repeated; `i` is the ramp (box-`lo`-dependent).
    const BODY: &str = r#"{"op": "+", "args": [
        {"op": "*", "args": [
          {"op": "-", "args": [{"op": "index", "args": ["u", "i"]},
                               {"op": "index", "args": ["u", {"op": "-", "args": ["i", 1]}]}]},
          {"op": "-", "args": [{"op": "index", "args": ["u", "i"]},
                               {"op": "index", "args": ["u", {"op": "-", "args": ["i", 1]}]}]}]},
        {"op": "*", "args": ["i",
          {"op": "-", "args": [{"op": "index", "args": ["u", "i"]},
                               {"op": "index", "args": ["u", {"op": "-", "args": ["i", 1]}]}]}]},
        {"op": "min", "args": [
          {"op": "abs", "args": [
            {"op": "-", "args": [{"op": "index", "args": ["u", "i"]},
                                 {"op": "index", "args": ["u", {"op": "-", "args": ["i", 1]}]}]}]},
          {"op": "*", "args": ["i", "i"]}]}]}"#;
    const TEMPLATE: &str = r#"{
 "esm": "1.0.0",
 "metadata": {"name": "cse_repeat"},
 "models": {
  "M": {
   "variables": {"u": {"type": "unknown", "shape": ["i"]}},
   "equations": [
    {
     "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, __N__]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "ranges": {"i": [1, __N__]},
             "expr": {"op": "index", "args": [
               {"op": "makearray", "args": [],
                "regions": [[[2, __NM1__]], [[1, 1]], [[__N__, __N__]]],
                "values": [__BODY__, __BODY__, __BODY__]},
               "i"]}}
    }
   ]
  }
 }
}"#;
    TEMPLATE
        .replace("__NM1__", &(n - 1).to_string())
        .replace("__N__", &n.to_string())
        .replace("__BODY__", BODY)
}

/// An einsum contraction (`sum_k`) whose body repeats a subexpression that
/// mentions the contracted index `k`, so each tuple must get its own memo.
fn contracted_repeat_json(n: usize) -> String {
    const TEMPLATE: &str = r#"{
 "esm": "1.0.0",
 "metadata": {"name": "cse_contract"},
 "models": {
  "M": {
   "variables": {"u": {"type": "unknown", "shape": ["i"]}},
   "equations": [
    {
     "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, __N__]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "reduce": "+",
             "ranges": {"i": [1, __N__], "k": [-1, 1]},
             "expr": {"op": "+", "args": [
               {"op": "*", "args": [
                 {"op": "ifelse", "args": [{"op": "==", "args": ["k", 0]}, -2, 1]},
                 {"op": "index", "args": ["u", {"op": "+", "args": ["i", "k"]}]}]},
               {"op": "*", "args": [
                 {"op": "ifelse", "args": [{"op": "==", "args": ["k", 0]}, -2, 1]},
                 {"op": "index", "args": ["u", {"op": "+", "args": ["i", "k"]}]}]}]}}
    }
   ]
  }
 }
}"#;
    TEMPLATE.replace("__N__", &n.to_string())
}

#[test]
fn cse_is_bit_identical_to_the_per_cell_oracle() {
    for n in [6usize, 11] {
        let c = compile(&repeated_subexpr_json(n));
        assert_bit_identical_to_oracle(&format!("makearray repeats N={n}"), &c, &state(n));
        let c = compile(&contracted_repeat_json(n));
        assert_bit_identical_to_oracle(&format!("contraction repeats N={n}"), &c, &state(n));
    }
}

/// A `RhsScratch` — and so the CSE class table inside it — outlives the model
/// it was built for. `CseRt::retarget` exists to throw that classification away
/// when the rule set under it changes, and everything derived from it (the
/// resolved address→class table `class_of` actually reads, the class-indexed
/// memo rows) must go with it. A survivor would hand a node ANOTHER node's
/// class and produce a wrong answer that still looks plausible.
///
/// The hazard is address REUSE, so each model is dropped before the next is
/// built: the allocator is then free to hand the next model's rule bodies the
/// very addresses the previous one's were classified under.
#[test]
fn a_retargeted_scratch_does_not_reuse_a_stale_classification() {
    const N: usize = 11;
    let u = state(N);
    let params = HashMap::new();

    // Reference answers, each computed on its own private scratch.
    let (want_a, _) = compile(&repeated_subexpr_json(N)).debug_eval_rhs(&u, 0.0, &params, false);
    let (want_b, _) = compile(&contracted_repeat_json(N)).debug_eval_rhs(&u, 0.0, &params, false);
    assert_eq!(want_a.len(), want_b.len(), "the two fixtures share a state shape");

    let a = compile(&repeated_subexpr_json(N));
    // One scratch, carried across all three models below.
    let mut scratch = a.debug_new_scratch();
    let mut got = vec![0.0f64; want_a.len()];
    let mut stats = RhsStats::default();

    let pv = a.debug_resolve_params(&params);
    a.debug_eval_rhs_into(&u, 0.0, &pv, &mut got, &mut scratch, &mut stats);
    assert_bits("A on a fresh scratch", &got, &want_a);
    drop(a);

    // A DIFFERENT rule set on the same scratch: the class table must be
    // discarded and rebuilt against B's bodies.
    let b = compile(&contracted_repeat_json(N));
    let pv = b.debug_resolve_params(&params);
    b.debug_eval_rhs_into(&u, 0.0, &pv, &mut got, &mut scratch, &mut stats);
    assert_bits("B on A's retargeted scratch", &got, &want_b);
    drop(b);

    // …and back again, on the twice-retargeted scratch.
    let a2 = compile(&repeated_subexpr_json(N));
    let pv = a2.debug_resolve_params(&params);
    a2.debug_eval_rhs_into(&u, 0.0, &pv, &mut got, &mut scratch, &mut stats);
    assert_bits("A rebuilt on the twice-retargeted scratch", &got, &want_a);

    // Repeated evaluation on the settled scratch must be stable too — the memo
    // is recycled between calls, and a cell surviving into the next evaluation
    // would show up here.
    for _ in 0..4 {
        a2.debug_eval_rhs_into(&u, 0.0, &pv, &mut got, &mut scratch, &mut stats);
        assert_bits("A repeated on a warm scratch", &got, &want_a);
    }
}

/// The overlay's node-visit count is a function of the discretized expression
/// only, so CSE must not make it grid-dependent — it only lowers it.
#[test]
fn cse_keeps_the_kernel_op_count_grid_independent() {
    let small = compile(&repeated_subexpr_json(6));
    let large = compile(&repeated_subexpr_json(24));
    let (_, s) = small.debug_eval_rhs(&state(6), 0.0, &HashMap::new(), false);
    let (_, l) = large.debug_eval_rhs(&state(24), 0.0, &HashMap::new(), false);
    assert_eq!(
        s.kernel_ops, l.kernel_ops,
        "kernel op count moved with N ({} at N=6 vs {} at N=24)",
        s.kernel_ops, l.kernel_ops
    );
    assert_eq!(s.vectorized_rules, 1);
    assert_eq!(l.vectorized_rules, 1);
    // …and the memo must actually be firing, or the bit-identity test above
    // would be vacuous: this fixture visits 89 nodes with `ESS_CSE_DISABLE=1`
    // and 53 with the memo on.
    assert!(
        s.kernel_ops < 89,
        "CSE did not engage: {} node visits, same as the un-memoized walk",
        s.kernel_ops
    );
}
