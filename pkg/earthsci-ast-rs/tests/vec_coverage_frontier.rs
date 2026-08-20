//! The **coverage frontier** of the whole-array overlay, pinned as executable
//! fact (audit `perf/rust-vec-coverage-audit`).
//!
//! `pde_vectorized_eval.rs` asserts that the constructs the overlay *does*
//! cover stay covered. This file is its complement: one minimal fixture per
//! construct that today still falls back to the per-cell AST oracle, each
//! asserting the CURRENT verdict.
//!
//! Two reasons that is worth a test rather than a document:
//!
//!   * **It guards a concurrent rewrite.** The overlay's hot files are being
//!     reworked (allocator / axis classification, CSE over expanded subtrees).
//!     A refactor that quietly narrows coverage — re-introducing a fallback on
//!     a construct that vectorizes today — is invisible in a numeric
//!     conformance run, because the oracle gives the same answer, only slower.
//!     Every `expect_vectorized` case below is a tripwire for exactly that.
//!
//!   * **It is the work queue.** Each `expect_per_cell` case is a gate from the
//!     ranked inventory, reduced to the smallest model that provokes it. When
//!     someone implements the gate, the corresponding assertion fails and tells
//!     them so — at which point the fixture is already the unit test for the
//!     new path, and `oracle_agreement` below is already the bit-identity check.
//!
//! Every fixture here is a self-contained JSON model: no sibling checkout, no
//! network, no golden file.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::simulate_array::ArrayCompiled;
use earthsci_ast::load;
use std::collections::HashMap;

fn compile(json: &str) -> ArrayCompiled {
    let file = load(json).expect("fixture loads");
    ArrayCompiled::from_file(&file).expect("fixture compiles")
}

/// A deterministic, non-degenerate state (no zeros, no repeats — a stencil that
/// silently read the wrong neighbour would still be caught).
fn sample_state(n: usize) -> Vec<f64> {
    (0..n).map(|k| (0.7 * k as f64 + 0.3).sin() + 1.5).collect()
}

/// Assert the compiled-rule verdict for `json`, and — either way — that the
/// vectorized-path run agrees with the per-cell oracle **bit for bit**.
///
/// The oracle here is `force_scalar = true`, which is a valid reference for
/// these fixtures *only* because each one puts its stencil in a compiled `D(…)`
/// rule, which is one of the two call sites that flag gates. It is NOT a valid
/// oracle for a model whose stencils live in observeds — those reach the
/// overlay through `eval_arrayop`, which the flag does not touch; use
/// `ESS_VEC_DISABLE=1` for that. Keep new fixtures in this file rule-shaped so
/// the cheap in-process oracle stays sound.
fn check(name: &str, json: &str, expect_vectorized: bool) {
    let compiled = compile(json);
    let n = compiled.state_variable_names().len();
    assert!(n > 0, "{name}: fixture has no state");
    let params = HashMap::new();

    for perturb in [0.0, 1e-3, -1e-3] {
        let state: Vec<f64> = sample_state(n).iter().map(|v| v + perturb).collect();
        let (dy_vec, vstats) = compiled.debug_eval_rhs(&state, 0.0, &params, false);
        let (dy_ref, sstats) = compiled.debug_eval_rhs(&state, 0.0, &params, true);

        if perturb == 0.0 {
            if expect_vectorized {
                assert_eq!(
                    vstats.scalar_rules, 0,
                    "{name}: expected the whole-array overlay, got {vstats:?}. \
                     If this is a deliberate narrowing, update the inventory; \
                     if not, the overlay just lost coverage it had."
                );
                assert!(
                    vstats.vectorized_rules > 0,
                    "{name}: no rule went through the overlay: {vstats:?}"
                );
            } else {
                assert_eq!(
                    vstats.vectorized_rules, 0,
                    "{name}: this construct is on the audit's FALLBACK list but \
                     now vectorizes ({vstats:?}). That is good news — move it to \
                     `expect_vectorized` and strike it from the inventory."
                );
                assert!(
                    vstats.scalar_rules > 0,
                    "{name}: expected a per-cell fallback: {vstats:?}"
                );
            }
            assert_eq!(
                sstats.scalar_rules,
                sstats.scalar_rules.max(1),
                "{name}: force_scalar must reach the oracle"
            );
        }

        // Bit-identity, not tolerance: the overlay is an evaluation-strategy
        // overlay on the same IEEE arithmetic, so any difference at all is a
        // divergence. Compared as raw bit patterns so a signed zero or a NaN
        // payload cannot pass as equal.
        assert_eq!(dy_vec.len(), dy_ref.len(), "{name}: length differs");
        for (k, (a, b)) in dy_vec.iter().zip(dy_ref.iter()).enumerate() {
            assert_eq!(
                a.to_bits(),
                b.to_bits(),
                "{name}: slot {k} differs from the per-cell oracle at \
                 perturbation {perturb}: {a:?} ({:#x}) vs {b:?} ({:#x})",
                a.to_bits(),
                b.to_bits()
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Model builder: one state `u[1..N]`, one `D(u[i]) = <rhs over i>` rule.
// ---------------------------------------------------------------------------

fn rule_model(n: usize, rhs_expr: &str) -> String {
    format!(
        r#"{{
 "esm": "1.0.0",
 "metadata": {{"name": "vec_frontier"}},
 "models": {{
  "M": {{
   "variables": {{"u": {{"type": "unknown", "shape": ["i"]}}}},
   "equations": [
    {{
     "lhs": {{"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {{"op": "D", "args": [{{"op": "index", "args": ["u", "i"]}}], "wrt": "t"}},
             "ranges": {{"i": [1, {n}]}}}},
     "rhs": {{"op": "aggregate", "args": [], "output_idx": ["i"],
             "ranges": {{"i": [1, {n}]}},
             "expr": {rhs_expr}}}
    }}
   ]
  }}
 }}
}}"#
    )
}

// ---------------------------------------------------------------------------
// COVERED — tripwires against a silent narrowing of coverage.
// ---------------------------------------------------------------------------

/// Affine neighbour shift with the Dirichlet ghost-0 convention.
#[test]
fn covered_affine_shift_stencil() {
    let rhs = r#"{"op": "+", "args": [
        {"op": "index", "args": ["u", {"op": "-", "args": ["i", 1]}]},
        {"op": "*", "args": [-2, {"op": "index", "args": ["u", "i"]}]},
        {"op": "index", "args": ["u", {"op": "+", "args": ["i", 1]}]}
    ]}"#;
    check("affine shift", &rule_model(6, rhs), true);
}

/// A bare output index symbol used as a VALUE — the coordinate-ramp idiom
/// (`phi = -90 + (j-1)·dlat`) that gated every simpleclimate geometry observed
/// before `ef51292c`.
#[test]
fn covered_output_index_as_coordinate_ramp() {
    let rhs = r#"{"op": "*", "args": [
        {"op": "index", "args": ["u", "i"]},
        {"op": "-", "args": ["i", 1]}
    ]}"#;
    check("coordinate ramp", &rule_model(6, rhs), true);
}

/// A per-cell mask: an array-valued comparison feeding an array-valued
/// `ifelse`. Both branches evaluate and the select is elementwise.
#[test]
fn covered_array_valued_ifelse_mask() {
    let rhs = r#"{"op": "ifelse", "args": [
        {"op": ">", "args": [{"op": "index", "args": ["u", "i"]}, 1.5]},
        {"op": "index", "args": ["u", "i"]},
        {"op": "*", "args": [-1, {"op": "index", "args": ["u", "i"]}]}
    ]}"#;
    check("array ifelse", &rule_model(6, rhs), true);
}

/// Region-materialized `makearray` boundary dispatch (interior + two ghosts).
#[test]
fn covered_makearray_region_dispatch() {
    let rhs = r#"{"op": "index", "args": [
        {"op": "makearray", "args": [],
         "regions": [[[1, 6]], [[1, 1]], [[6, 6]]],
         "values": [
           {"op": "index", "args": ["u", {"op": "+", "args": ["i", 1]}]},
           {"op": "index", "args": ["u", "i"]},
           {"op": "index", "args": ["u", {"op": "-", "args": ["i", 1]}]}
         ]},
        "i"]}"#;
    check("makearray regions", &rule_model(6, rhs), true);
}

/// A nested `aggregate` whose own `output_idx` SHADOWS the enclosing output
/// symbol (issue #98).
///
/// `index(aggregate[i](u[i+1] − u[i]), i)` inside `aggregate[i](…)` is what a
/// discretization template expands to when the `D(·)` is written inline in an
/// equation body rather than named as its own observed. The two aggregates
/// collide on `i` because both are keyed on the grid's index names.
///
/// The overlay's hoisting precondition is "the nested body must not depend on
/// an enclosing binding". A shadowed name is not a dependence — inside the
/// inner body `i` IS the inner index — and both whole-array resolvers consult
/// the aggregate's own box symbols first, exactly as the per-cell oracle
/// rebinds `idx_names ∪ contract_names` around its body walk. Rejecting it cost
/// three to four orders of magnitude, and unlike the overlay the per-cell cost
/// grows with the cell count.
#[test]
fn covered_nested_aggregate_shadowing_enclosing_index() {
    let rhs = r#"{"op": "index", "args": [
        {"op": "aggregate", "args": [], "output_idx": ["i"],
         "ranges": {"i": [1, 6]},
         "expr": {"op": "-", "args": [
            {"op": "index", "args": ["u", {"op": "+", "args": ["i", 1]}]},
            {"op": "index", "args": ["u", "i"]}
         ]}},
        "i"]}"#;
    check(
        "nested aggregate, shadowed index",
        &rule_model(6, rhs),
        true,
    );
}

// ---------------------------------------------------------------------------
// FRONTIER — constructs still on the per-cell oracle. Each is an inventory
// entry; a failure here means the gate was implemented.
// ---------------------------------------------------------------------------

/// **Not a gate — the soundness boundary of the shadow analysis above.**
///
/// The inner aggregate is keyed on `j` and its body multiplies by the ENCLOSING
/// `i`, which it does not rebind. That is a real dependence: the oracle
/// produces a different sub-array for every enclosing cell, so the node cannot
/// be materialized once. Unlike the other entries below, this one must NOT be
/// "implemented" — the hoisted box drops the enclosing symbols, so accepting it
/// would silently rebind `i` to a same-named state/observed/parameter.
#[test]
fn frontier_nested_aggregate_capturing_enclosing_index_falls_back() {
    let rhs = r#"{"op": "index", "args": [
        {"op": "aggregate", "args": [], "output_idx": ["j"],
         "ranges": {"j": [1, 6]},
         "expr": {"op": "*", "args": [{"op": "index", "args": ["u", "j"]}, "i"]}},
        "i"]}"#;
    check(
        "nested aggregate, captured index",
        &rule_model(6, rhs),
        false,
    );
}

/// **Gate C1 — clamped ("replicate-edge") index.**
///
/// `index(u, max(1, min(N, i-1)))` is the zero-gradient / clamp-to-edge
/// boundary idiom. `classify_axis_index` accepts an affine map or a periodic
/// wrap, and `const_index_value` accepts a constant; `max`/`min` of an affine
/// term in an output symbol is neither, so the axis is rejected.
///
/// It is a whole-array construct: a clamp over one axis is three copy segments
/// — a left plateau replicating `src[lo]`, an affine middle run, a right
/// plateau replicating `src[hi]` — the same segment machinery
/// `AxisIndex::Wrap` already uses for its two-segment roll.
///
/// Breadth in the corpus: `grids/duo/rules/duo_extend.esm` alone contains 242
/// of these, and it is the only construct standing between the ESD
/// `duo_swe_freestream` case and a vectorized RHS.
#[test]
fn frontier_clamped_index_falls_back() {
    let rhs = r#"{"op": "index", "args": ["u",
        {"op": "max", "args": [1, {"op": "min", "args": [6,
            {"op": "-", "args": ["i", 1]}]}]}]}"#;
    check("clamped index", &rule_model(6, rhs), false);
}

/// **Gate C2 — indirect (data-dependent) gather.**
///
/// `index(phi, index(cellsOnEdge, e, 2))`: the inner `index` is itself an
/// affine map of an output symbol, so it evaluates to a whole-array vector of
/// INDICES, and the outer read is a gather along that vector. The axis
/// classifier sees an `index` node where it wants an affine/wrap/constant
/// expression and bails.
///
/// This is the unstructured-mesh connectivity idiom: every MPAS rule
/// (`fv_gradient_edge`, `fv_divergence_cell`, `fv_laplacian_cell`) is built on
/// it, as is the `mpas_l0_to_octants_sphere` regrid.
#[test]
fn frontier_indirect_gather_falls_back() {
    // `nbr[i] = 7 - i` is the reversal permutation over 1..6: a legitimate
    // index vector, produced (like MPAS `cellsOnEdge`) as an ordinary observed
    // rather than a literal, so the fixture isolates the GATHER and does not
    // also trip the array-valued-`const` gate below.
    let json = r#"{
 "esm": "1.0.0",
 "metadata": {"name": "vec_frontier_gather"},
 "models": {
  "M": {
   "variables": {
     "u": {"type": "unknown", "shape": ["i"]},
     "nbr": {"type": "observed", "shape": ["i"],
             "expression": {"op": "aggregate", "args": [], "output_idx": ["i"],
                            "ranges": {"i": [1, 6]},
                            "expr": {"op": "-", "args": [7, "i"]}}}
   },
   "equations": [
    {
     "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, 6]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "ranges": {"i": [1, 6]},
             "expr": {"op": "index", "args": ["u",
                       {"op": "index", "args": ["nbr", "i"]}]}}
    }
   ]
  }
 }
}"#;
    check("indirect gather", json, false);
}

/// **Gate C4 — array-valued `const`.**
///
/// `eval_vec_op`'s `const` arm returns a `VecValue::Scalar` for a numeric
/// literal and bails outright for an array literal, so an inlined constant
/// TABLE — a metric term, a panel-connectivity map — takes the whole enclosing
/// expression to the oracle.
///
/// This is the cheapest entry in the inventory: the oracle already materializes
/// the same `ArrayD` through `eval_const`, so the whole-array form is that array
/// copied into a pooled buffer with origin 1. No new analysis, no new
/// numerics — element-for-element the same values the oracle reads.
///
/// Measured: in ESD `duo_swe_freestream`, the observed `node` — whose only
/// recorded bail is this one — costs **134 ms of a single RHS evaluation**.
#[test]
fn frontier_array_valued_const_falls_back() {
    let rhs = r#"{"op": "*", "args": [
        {"op": "index", "args": ["u", "i"]},
        {"op": "index", "args": [
            {"op": "const", "args": [], "value": [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]},
            "i"]}
    ]}"#;
    check("array-valued const", &rule_model(6, rhs), false);
}

// **Gate C3 — non-static (ragged / derived) contraction bound** — deliberately
// NOT pinned here.
//
// A CSR neighbour sum whose per-row extent comes from an offsets factor
// (`nEdgesOnCell`) is not a uniform whole-array window, so
// `eval_vec_contracted` bails on the `ContractDim::Ragged` arm. It has no
// rule-shaped minimal form: a ragged set needs an `index_sets` declaration plus
// the offsets/values keyed factors, which only exist on an observed, and an
// observed reaches the overlay through `eval_arrayop`, where `force_scalar` —
// the oracle this file's `check` uses — has no effect. Pinning it here would
// mean either an invalid fixture that silently no-ops or an unsound oracle.
//
// It is already exercised for real, and its verdict is stable, in
// `simulate_array::compile::subsystem_ragged_and_inspection_tests::
// ragged_csr_miniature_through_subsystem_and_aliases` (in-crate) and by
// `divergence_mpas` / `laplacian_mpas` in the ESD corpus. Use `ESS_VEC_DISABLE`
// rather than `force_scalar` if you ever need an oracle for it.
