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
use earthsci_ast::simulate_array::ArrayCompiled;

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
 "esm": "0.1.0",
 "metadata": {"name": "cse_repeat"},
 "models": {
  "M": {
   "variables": {"u": {"type": "state", "shape": ["i"]}},
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
 "esm": "0.1.0",
 "metadata": {"name": "cse_contract"},
 "models": {
  "M": {
   "variables": {"u": {"type": "state", "shape": ["i"]}},
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
