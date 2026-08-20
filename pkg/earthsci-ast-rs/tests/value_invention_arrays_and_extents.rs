//! The two seams a Rust runner needs to drive a REAL value-invention model —
//! one whose factor arrays arrive from data loaders rather than from `const`
//! literals in the document, and whose interesting quantities are shaped on (or
//! contracted over) the index set those factors invent.
//!
//! Both are exercised against the ISRM L1 geometry and the shared pushdown
//! fixture `fixtures/pushdown/overlap_gate_point_in_rect.esm`, whose support-set
//! golden is `[1, 2, 4, 9]` (see `overlap_gate_conformance.rs`).
//!
//! **Seam 1 — the caller-supplied factor-array channel.** ISRM's overlap gate
//! reads envelope factors `X`/`Y` (emission points) and `W`/`S`/`E`/`N` (cell
//! rectangles). All six are declared `type: "parameter"` and are fed by data
//! loaders through `coupling` `param_to_var` edges; none is a `const` literal.
//! The build path's `const`-expression scan therefore finds nothing for them, so
//! without a caller channel the gate has no envelopes and the producer invents
//! no members. [`run_value_invention`] takes that channel.
//!
//! **Seam 2 — sizing an axis from the invented set.** `emis_src_cells` is
//! `{"kind":"derived","from_faq":"emis_src_cells_faq"}`. Every interesting
//! observed either ranges over it as an OUTPUT axis (`E_VOC`, `E_NOx`, … are
//! shaped on it) or CONTRACTS over it (`conc_SOA` and friends reduce with
//! `ranges: {"s": {"from": "emis_src_cells"}}`). Neither could be evaluated
//! before: the output axis was rejected outright, and the contracted axis
//! resolved against the geometry clip-ring registry, found nothing, and folded
//! silently to the additive identity. `resolve_expr_ranges_with_extents` and
//! `eval_expression_with_extents` close both.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::Key;
use earthsci_ast::aggregate::resolve_expr_ranges_with_extents;
use earthsci_ast::simulate_array::{
    Value, eval_expression, eval_expression_with_extents, run_value_invention,
};
use earthsci_ast::types::{Expr, IndexSet, Model};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Value as Json, json};

const FIXTURE: &str = include_str!("fixtures/pushdown/overlap_gate_point_in_rect.esm");

fn arr(shape: &[usize], data: Vec<f64>) -> ArrayD<f64> {
    ArrayD::from_shape_vec(IxDyn(shape), data).expect("shape matches data")
}

fn inputs(pairs: Vec<(&str, ArrayD<f64>)>) -> HashMap<String, ArrayD<f64>> {
    pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
}

/// The ISRM L1 geometry as a data loader would deliver it: a 3x3 grid of 2x2
/// cells (cell k = (row-1)*3 + col) and 5 emission points hand-placed in cells
/// {1, 2, 4, 9}. Identical numbers to `overlap_gate_conformance.rs`, so the
/// support-set golden below is the same `[1, 2, 4, 9]`.
fn l1_loaded_arrays() -> HashMap<String, ArrayD<f64>> {
    inputs(vec![
        (
            "W",
            arr(&[9], vec![0.0, 2.0, 4.0, 0.0, 2.0, 4.0, 0.0, 2.0, 4.0]),
        ),
        (
            "E",
            arr(&[9], vec![2.0, 4.0, 6.0, 2.0, 4.0, 6.0, 2.0, 4.0, 6.0]),
        ),
        (
            "S",
            arr(&[9], vec![0.0, 0.0, 0.0, 2.0, 2.0, 2.0, 4.0, 4.0, 4.0]),
        ),
        (
            "N",
            arr(&[9], vec![2.0, 2.0, 2.0, 4.0, 4.0, 4.0, 6.0, 6.0, 6.0]),
        ),
        // e1(1,1)->c1, e2(3,1)->c2, e3(1,3)->c4, e4(5,5)->c9, e5(1.5,1.5)->c1.
        ("X", arr(&[5], vec![1.0, 3.0, 1.0, 5.0, 1.5])),
        ("Y", arr(&[5], vec![1.0, 1.0, 3.0, 5.0, 1.5])),
    ])
}

/// The fixture's `ISRM` model and the document-scoped index-set registry, typed.
fn isrm_model() -> (Model, HashMap<String, IndexSet>) {
    let doc: Json = serde_json::from_str(FIXTURE).expect("fixture parses");
    let model: Model =
        serde_json::from_value(doc["models"]["ISRM"].clone()).expect("ISRM model deserializes");
    let index_sets: HashMap<String, IndexSet> =
        serde_json::from_value(doc["index_sets"].clone()).expect("index_sets deserialize");
    (model, index_sets)
}

// ===========================================================================
// Seam 1 — caller-supplied factor arrays reach the overlap gate.
// ===========================================================================

/// The headline: loader-fed envelope factors handed in through the caller
/// channel drive the spatial overlap gate and the producer invents EXACTLY the
/// Julia support set `[1, 2, 4, 9]`.
#[test]
fn caller_supplied_arrays_reach_the_overlap_gate() {
    let (model, index_sets) = isrm_model();
    let loaded = l1_loaded_arrays();

    let vi = run_value_invention(&model, &index_sets, Some(&loaded))
        .expect("value invention runs with caller-supplied envelope factors");

    assert_eq!(
        vi.members["emis_src_cells_faq"],
        vec![Key::Int(1), Key::Int(2), Key::Int(4), Key::Int(9)],
        "caller-supplied arrays must drive the gate to the L1 golden support set"
    );
    assert_eq!(
        vi.extents["emis_src_cells_faq"], 4,
        "the invented set's cardinality is the number of containing cells"
    );
}

/// The channel is LOAD-BEARING, not decorative: the same model with no caller
/// arrays cannot size its envelopes, because `X`/`Y`/`W`/`S`/`E`/`N` are
/// `type: "parameter"` and carry no `const` expression for the build path's scan
/// to find. It fails LOUDLY on the missing factor rather than quietly inventing
/// an empty (or different) member set.
#[test]
fn without_the_caller_channel_the_gate_has_no_envelopes() {
    let (model, index_sets) = isrm_model();

    let err = run_value_invention(&model, &index_sets, None)
        .expect_err("with no factor arrays the gate has nothing to build an envelope from");
    let msg = format!("{err:?}");
    assert!(
        msg.contains("overlap-join env factor") && msg.contains("not supplied in const arrays"),
        "expected the missing-envelope-factor diagnostic, got: {msg}"
    );
}

/// A caller array OVERRIDES a same-named `const` factor in the document. This is
/// the direction a runner needs: the document's literal is a placeholder or a
/// default, and the loaded field is the truth. Shifting the points two units
/// east moves them out of cells {1, 2, 4, 9} and into {2, 3, 5, 9}, so the
/// support set is a different, exactly-predictable set.
#[test]
fn caller_arrays_win_over_document_const_factors() {
    let doc: Json = serde_json::from_str(FIXTURE).expect("fixture parses");
    let mut model_json = doc["models"]["ISRM"].clone();
    // Give `X` a document `const` literal carrying the UNSHIFTED points.
    //
    // From esm 1.0.0 that means making `X` an OBSERVED unknown: only an unknown
    // is defined by an equation, and a const-backed observed IS what a document
    // literal factor is (esm-spec §6.3.1). The fixture declares `X` a bare
    // parameter — a name the runner supplies — so the declaration is flipped
    // alongside the equation, which is the whole point of the test: the
    // document's literal is a placeholder the caller's array overrides.
    model_json["variables"]["X"]["type"] = json!("unknown");
    model_json["equations"]
        .as_array_mut()
        .expect("equations array")
        .push(json!({
            "lhs": "X",
            "rhs": {"op": "const", "args": [], "value": [1.0, 3.0, 1.0, 5.0, 1.5]}
        }));
    let model: Model = serde_json::from_value(model_json).expect("model deserializes");
    let index_sets: HashMap<String, IndexSet> =
        serde_json::from_value(doc["index_sets"].clone()).expect("index_sets deserialize");

    // The document `const` alone (X unshifted) reproduces the L1 golden.
    let mut with_const = l1_loaded_arrays();
    with_const.remove("X");
    let vi_const = run_value_invention(&model, &index_sets, Some(&with_const))
        .expect("the document `const` supplies X");
    assert_eq!(
        vi_const.members["emis_src_cells_faq"],
        vec![Key::Int(1), Key::Int(2), Key::Int(4), Key::Int(9)],
        "document `const` X should reproduce the unshifted support set"
    );

    // The caller's X (shifted +2 east) wins over that same `const`.
    let mut shifted = l1_loaded_arrays();
    shifted.insert("X".to_string(), arr(&[5], vec![3.0, 5.0, 3.0, 7.0, 3.5]));
    // e1(3,1)->c2, e2(5,1)->c3, e3(3,3)->c5, e4(7,5) is outside the grid, e5(3.5,1.5)->c2.
    let vi_caller = run_value_invention(&model, &index_sets, Some(&shifted))
        .expect("the caller's X supplies X");
    assert_eq!(
        vi_caller.members["emis_src_cells_faq"],
        vec![Key::Int(2), Key::Int(3), Key::Int(5)],
        "the caller-supplied X must override the document `const`"
    );
    assert_eq!(vi_caller.extents["emis_src_cells_faq"], 3);
}

// ===========================================================================
// Seam 2 — a value-invented derived index set sizes a range / shape.
// ===========================================================================

/// The invented extent for the L1 fixture, obtained the way a runner would.
fn l1_extents() -> HashMap<String, i64> {
    let (model, index_sets) = isrm_model();
    run_value_invention(&model, &index_sets, Some(&l1_loaded_arrays()))
        .expect("value invention runs")
        .extents
}

/// An `E_VOC`-shaped observed: an aggregate whose OUTPUT axis ranges over the
/// value-invented `emis_src_cells`. Its shape is the invented cardinality (4),
/// and its values are the per-member rate scaled by the emission factor.
#[test]
fn derived_output_axis_is_sized_by_the_invented_set() {
    let (_, index_sets) = isrm_model();
    let extents = l1_extents();

    // E_VOC[s] = 2.5 * rate[s], s over the invented source-cell set.
    let mut expr: Expr = serde_json::from_value(json!({
        "op": "aggregate",
        "args": [],
        "id": "e_voc",
        "semiring": "sum_product",
        "output_idx": ["s"],
        "ranges": {"s": {"from": "emis_src_cells"}},
        "expr": {"op": "*", "args": [2.5, {"op": "index", "args": ["rate", "s"]}]}
    }))
    .expect("aggregate deserializes");

    resolve_expr_ranges_with_extents(&mut expr, &index_sets, &extents)
        .expect("a value-invented derived set may size an output axis");

    let rate = inputs(vec![("rate", arr(&[4], vec![10.0, 20.0, 30.0, 40.0]))]);
    let out = eval_expression_with_extents(&expr, &rate, &[], &[], 0.0, &extents)
        .expect("the aggregate evaluates");
    let Value::Array(a) = out else {
        panic!("an aggregate with a non-empty output_idx must produce an array");
    };
    assert_eq!(
        a.shape(),
        &[4],
        "the output axis is the invented cardinality"
    );
    assert_eq!(
        a.iter().copied().collect::<Vec<f64>>(),
        vec![25.0, 50.0, 75.0, 100.0]
    );
}

/// Without the extents the SAME output axis is rejected — the extent genuinely
/// comes from the relational engine and nowhere else, and an unresolvable axis
/// is an error rather than a silent zero- or one-length dimension.
#[test]
fn derived_output_axis_without_extents_is_rejected() {
    let (_, index_sets) = isrm_model();
    let mut expr: Expr = serde_json::from_value(json!({
        "op": "aggregate",
        "args": [],
        "id": "e_voc",
        "output_idx": ["s"],
        "ranges": {"s": {"from": "emis_src_cells"}},
        "expr": {"op": "index", "args": ["rate", "s"]}
    }))
    .expect("aggregate deserializes");

    let err = resolve_expr_ranges_with_extents(&mut expr, &index_sets, &HashMap::new())
        .expect_err("an unmaterialized derived set cannot size an output axis");
    let msg = format!("{err:?}");
    assert!(
        msg.contains("derived output index"),
        "expected the derived-output-index rejection, got: {msg}"
    );
}

/// A `conc_SOA`-shaped observed: a `sum_product` CONTRACTION over the invented
/// set, gathered through a `[pop_cells, emis_src_cells]` source-receptor matrix.
/// This is the shape every ISRM concentration takes.
#[test]
fn derived_contraction_axis_is_sized_by_the_invented_set() {
    let (_, index_sets) = isrm_model();
    let extents = l1_extents();

    // conc[i] = Σ_s SR[i, s] * E[s], i over 9 population cells, s over the 4
    // invented source cells.
    let mut expr: Expr = serde_json::from_value(json!({
        "op": "aggregate",
        "args": [],
        "id": "conc_soa",
        "semiring": "sum_product",
        "output_idx": ["i"],
        "ranges": {"i": {"from": "pop_cells"}, "s": {"from": "emis_src_cells"}},
        "expr": {"op": "*", "args": [
            {"op": "index", "args": ["SR", "i", "s"]},
            {"op": "index", "args": ["E", "s"]}
        ]}
    }))
    .expect("aggregate deserializes");

    resolve_expr_ranges_with_extents(&mut expr, &index_sets, &extents)
        .expect("the contracted derived axis resolves");

    // SR[i, s] = i + s/10 (row-major, 9 x 4); E = [1, 2, 3, 4].
    let sr: Vec<f64> = (1..=9)
        .flat_map(|i| (1..=4).map(move |s| i as f64 + s as f64 / 10.0))
        .collect();
    let data = inputs(vec![
        ("SR", arr(&[9, 4], sr)),
        ("E", arr(&[4], vec![1.0, 2.0, 3.0, 4.0])),
    ]);
    let out = eval_expression_with_extents(&expr, &data, &[], &[], 0.0, &extents)
        .expect("the contraction evaluates");
    let Value::Array(a) = out else {
        panic!("expected an array over the 9 population cells");
    };
    assert_eq!(a.shape(), &[9]);
    // Σ_s (i + s/10)·E[s] = i·(1+2+3+4) + (0.1·1 + 0.2·2 + 0.3·3 + 0.4·4)
    //                     = 10·i + 3.0.
    let expected: Vec<f64> = (1..=9).map(|i| 10.0 * i as f64 + 3.0).collect();
    for (k, (got, want)) in a.iter().zip(expected.iter()).enumerate() {
        assert!(
            (got - want).abs() < 1e-12,
            "conc[{k}] = {got}, expected {want}"
        );
    }
}

/// The evaluation-context channel itself: an expression already resolved to a
/// dynamic `DerivedDyn` bound — which is what a contracted derived axis looks
/// like when its ranges were resolved WITHOUT the engine's results in hand —
/// gets a real extent from `eval_expression_with_extents`, and folds to the
/// additive identity without it.
#[test]
fn eval_context_extents_size_an_already_resolved_derived_bound() {
    let (_, index_sets) = isrm_model();
    let extents = l1_extents();

    // total = Σ_s E[s] — a scalar reduction over the invented set.
    let mut expr: Expr = serde_json::from_value(json!({
        "op": "aggregate",
        "args": [],
        "id": "e_total",
        "semiring": "sum_product",
        "output_idx": [],
        "ranges": {"s": {"from": "emis_src_cells"}},
        "expr": {"op": "index", "args": ["E", "s"]}
    }))
    .expect("aggregate deserializes");

    // Resolve WITHOUT extents: legal for a contracted axis, and it leaves a
    // `DerivedDyn` bound that only the evaluator can size.
    resolve_expr_ranges_with_extents(&mut expr, &index_sets, &HashMap::new())
        .expect("a contracted derived axis resolves to a dynamic bound");

    let e = inputs(vec![("E", arr(&[4], vec![10.0, 20.0, 30.0, 40.0]))]);

    let with = eval_expression_with_extents(&expr, &e, &[], &[], 0.0, &extents)
        .expect("evaluates with extents");
    assert!(
        matches!(with, Value::Scalar(s) if s == 100.0),
        "the invented extent must open the contraction over all 4 members, got {with:?}"
    );

    let without = eval_expression(&expr, &e, &[], &[], 0.0).expect("evaluates without extents");
    assert!(
        matches!(without, Value::Scalar(s) if s == 0.0),
        "with no producer materialized the contraction is empty and folds to 0̄, got {without:?}"
    );
}
