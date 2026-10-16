//! The join and build-time pipeline shapes the strict `native` compiler used to
//! refuse, each now built natively and bit-identical to the interpreter:
//!
//! * a build-time observed the whole-array overlay declines — a join-gated
//!   binning `faq`, an equi-join over ingested key columns, a
//!   `polygon_intersection_area` inside a `faq`, a recurrence — is lowered on
//!   a standalone tape instead of being walked per cell, and reported
//!   `"taped"`;
//! * a join keyed on a CONST-cadence computed observed (CONFORMANCE_SPEC
//!   §5.5.8) is folded at build time, so the gate still drives enumeration;
//!   one keyed on a parameter-dependent observed is still refused, naming why.

use std::collections::HashMap;

use earthsci_ast::{
    CompileError, Compiler, EsmProblem, ProblemOptions, SimulateError, esm_problem, observed_field,
};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};

fn arr(shape: &[usize], data: &[f64]) -> ArrayD<f64> {
    ArrayD::from_shape_vec(IxDyn(shape), data.to_vec()).unwrap()
}

fn build(
    doc: &Value,
    compiler: Compiler,
    pipeline: bool,
    consts: &HashMap<String, ArrayD<f64>>,
) -> Result<EsmProblem, SimulateError> {
    esm_problem(
        doc,
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(compiler),
            const_arrays: consts.clone(),
            build_pipeline: pipeline,
            ..Default::default()
        },
    )
}

fn bits(p: &EsmProblem, name: &str) -> Vec<u64> {
    observed_field(p, name)
        .unwrap_or_else(|e| panic!("{name}: {e}"))
        .iter()
        .map(|x| x.to_bits())
        .collect()
}

fn values(p: &EsmProblem, name: &str) -> Vec<f64> {
    observed_field(p, name).unwrap().iter().copied().collect()
}

fn tier(p: &EsmProblem, rule: &str) -> String {
    let report = p.compiler_report();
    report
        .rules()
        .iter()
        .find(|r| r.rule == rule)
        .unwrap_or_else(|| panic!("no row for {rule}: {report}"))
        .tier
        .to_string()
}

/// Native through the pipeline: builds, every named field agrees with the
/// interpreter's pipeline bit for bit, and `rule` is reported `"taped"`.
fn check_pipeline(
    doc: &Value,
    consts: &HashMap<String, ArrayD<f64>>,
    rule: &str,
    fields: &[&str],
) -> EsmProblem {
    let native = build(doc, Compiler::Native, true, consts).expect("native builds");
    let interp = build(doc, Compiler::Interpreter, true, consts).expect("interpreter builds");
    for f in fields {
        assert_eq!(bits(&native, f), bits(&interp, f), "{f}");
    }
    assert_eq!(tier(&native, rule), "taped");
    assert_eq!(tier(&interp, rule), "oracle");
    native
}

fn model_doc(index_sets: Value, variables: Value, equations: Value) -> Value {
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "BuildTimeTape"},
        "index_sets": index_sets,
        "models": {"M": {"variables": variables, "equations": equations}},
    })
}

/// isrm's containment binning: each record's value summed into the grid cell
/// whose rectangle holds it, through a spatial `overlap` join gate.
#[test]
fn an_overlap_gated_binning_faq_in_the_pipeline_is_taped() {
    let rect = json!({"type": "parameter", "default": 0.0, "shape": ["cells"]});
    let rec = json!({"type": "parameter", "default": 0.0, "shape": ["recs"]});
    let within = |lo: &str, x: &str, hi: &str| {
        json!({"op": "and", "args": [
            {"op": "<=", "args": [{"op": "index", "args": [lo, "c"]}, {"op": "index", "args": [x, "r"]}]},
            {"op": "<", "args": [{"op": "index", "args": [x, "r"]}, {"op": "index", "args": [hi, "c"]}]}
        ]})
    };
    let binning = |payload: Value| {
        json!({
            "op": "faq", "args": [], "output_idx": ["r"], "reduce": "+",
            "ranges": {"c": {"from": "cells"}, "r": {"from": "recs"}},
            "expr": {"op": "*", "args": [
                {"op": "ifelse", "args": [
                    {"op": "and", "args": [within("W", "X", "E"), within("S", "Y", "N")]}, 1.0, 0.0]},
                payload]},
            "join": [{"overlap": {"src_env": ["X", "Y"], "tgt_env": ["W", "S", "E", "N"], "eps": 0.0}}]})
    };
    let doc = model_doc(
        json!({"cells": {"kind": "interval", "size": 4}, "recs": {"kind": "interval", "size": 3},
               "cells2": {"kind": "interval", "size": 8}}),
        json!({"W": rect, "S": rect, "E": rect, "N": rect, "val": rect, "X": rec, "Y": rec,
               "layered": {"type": "parameter", "default": 0.0, "shape": ["cells2"]},
               "out": {"type": "unknown", "shape": ["recs"]},
               "out2": {"type": "unknown", "shape": ["recs"]}}),
        json!([{"lhs": "out", "rhs": binning(json!({"op": "index", "args": ["val", "c"]}))},
               // isrm's `cell_at_model_layer`: the cell above `c` in layer 2
               // of a layer-major table, `index(fld, 1*N + c)`.
               {"lhs": "out2", "rhs": binning(json!({"op": "index", "args": ["layered",
                   {"op": "+", "args": [{"op": "*", "args": [1, 4]}, "c"]}]}))}]),
    );
    let consts: HashMap<String, ArrayD<f64>> = [
        ("W", arr(&[4], &[0.0, 1.0, 0.0, 1.0])),
        ("E", arr(&[4], &[1.0, 2.0, 1.0, 2.0])),
        ("S", arr(&[4], &[0.0, 0.0, 1.0, 1.0])),
        ("N", arr(&[4], &[1.0, 1.0, 2.0, 2.0])),
        ("val", arr(&[4], &[1.0, 2.0, 3.0, 4.0])),
        (
            "layered",
            arr(&[8], &[1.0, 2.0, 3.0, 4.0, 50.0, 60.0, 70.0, 80.0]),
        ),
        ("X", arr(&[3], &[0.5, 1.5, 1.2])),
        ("Y", arr(&[3], &[0.5, 1.5, 0.2])),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect();
    let native = check_pipeline(&doc, &consts, "M.out", &["M.out", "M.out2"]);
    assert_eq!(values(&native, "M.out"), vec![1.0, 4.0, 2.0]);
    assert_eq!(values(&native, "M.out2"), vec![50.0, 80.0, 60.0]);
}

/// moves' shape: a sum over the rows of an ingested table whose key column
/// matches a computed key, `total[k] = Σ_j [want[k] == key[j]] pay[j]`, plus
/// an array-valued `bool_and_or` presence flag over the same join, which the
/// pipeline evaluates cell by cell.
#[test]
fn an_equi_join_over_ingested_columns_in_the_pipeline_is_taped() {
    let col = json!({"type": "parameter", "default": 0.0, "shape": ["rows"]});
    let out = json!({"type": "unknown", "shape": ["keys"]});
    let joined = |semiring: &str, expr: Value| {
        json!({"op": "faq", "args": [], "semiring": semiring, "output_idx": ["k"],
               "ranges": {"k": {"from": "keys"}, "j": {"from": "rows"}},
               "join": [{"on": [["want", "key"]]}], "expr": expr})
    };
    let doc = model_doc(
        json!({"rows": {"kind": "interval", "size": 6}, "keys": {"kind": "interval", "size": 3}}),
        json!({"key": col, "pay": col, "want": out, "total": out, "present": out}),
        json!([
            {"lhs": "want", "rhs": {"op": "faq", "args": [], "output_idx": ["k"],
                "ranges": {"k": {"from": "keys"}}, "expr": {"op": "+", "args": ["k", 6.0]}}},
            {"lhs": "total", "rhs": joined("sum_product", json!({"op": "index", "args": ["pay", "j"]}))},
            {"lhs": "present", "rhs": joined("bool_and_or", json!(1.0))},
        ]),
    );
    let consts: HashMap<String, ArrayD<f64>> = [
        ("key", arr(&[6], &[7.0, 9.0, 7.0, 11.0, 9.0, 7.0])),
        ("pay", arr(&[6], &[0.1, 1e-3, 0.2, 5.0, 3e7, 0.3])),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect();
    let native = check_pipeline(&doc, &consts, "M.total", &["M.total", "M.present"]);
    assert_eq!(values(&native, "M.present"), vec![1.0, 0.0, 1.0]);
    assert_eq!(tier(&native, "M.present"), "taped");
}

/// isrm's polygon documents: `polygon_intersection_area` of each record's
/// ring with each grid cell's, inside a `faq`.
#[test]
fn polygon_intersection_area_in_a_pipeline_faq_is_taped() {
    let doc = model_doc(
        json!({"cells": {"kind": "interval", "size": 2}, "recs": {"kind": "interval", "size": 1},
               "vert": {"kind": "interval", "size": 4}, "xy": {"kind": "interval", "size": 2}}),
        json!({"cring": {"type": "parameter", "default": 0.0, "shape": ["cells", "vert", "xy"]},
               "pring": {"type": "parameter", "default": 0.0, "shape": ["recs", "vert", "xy"]},
               "out": {"type": "unknown", "shape": ["cells"]}}),
        json!([{"lhs": "out", "rhs": {
            "op": "faq", "output_idx": ["c"], "reduce": "+",
            "ranges": {"c": {"from": "cells"}, "r": {"from": "recs"}},
            "args": ["cring", "pring"],
            "expr": {"op": "polygon_intersection_area", "manifold": "planar", "args": [
                {"op": "index", "args": ["pring", "r"]}, {"op": "index", "args": ["cring", "c"]}]}}}]),
    );
    let consts: HashMap<String, ArrayD<f64>> = [
        (
            "cring",
            arr(
                &[2, 4, 2],
                &[
                    0., 0., 1., 0., 1., 1., 0., 1., 1., 0., 2., 0., 2., 1., 1., 1.,
                ],
            ),
        ),
        (
            "pring",
            arr(&[1, 4, 2], &[0.5, 0.25, 1.5, 0.25, 1.5, 1.25, 0.5, 1.25]),
        ),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect();
    let native = check_pipeline(&doc, &consts, "M.out", &["M.out"]);
    assert_eq!(values(&native, "M.out"), vec![0.375, 0.375]);
}

/// isrm's polygon binning: the area share inside a `faq` driven by an
/// `overlap` join on the rings' bounding boxes, so each ring is read at a loop
/// symbol of the tuple list.
#[test]
fn polygon_intersection_area_in_a_join_gated_pipeline_faq_is_taped() {
    let env = |set: &str| json!({"type": "parameter", "default": 0.0, "shape": [set]});
    let doc = model_doc(
        json!({"cells": {"kind": "interval", "size": 3}, "recs": {"kind": "interval", "size": 2},
               "vert": {"kind": "interval", "size": 4}, "xy": {"kind": "interval", "size": 2}}),
        json!({"cring": {"type": "parameter", "default": 0.0, "shape": ["cells", "vert", "xy"]},
               "pring": {"type": "parameter", "default": 0.0, "shape": ["recs", "vert", "xy"]},
               "cx0": env("cells"), "cy0": env("cells"), "cx1": env("cells"), "cy1": env("cells"),
               "px0": env("recs"), "py0": env("recs"), "px1": env("recs"), "py1": env("recs"),
               "out": {"type": "unknown", "shape": ["cells"]}}),
        json!([{"lhs": "out", "rhs": {
            "op": "faq", "args": [], "output_idx": ["c"], "reduce": "+",
            "ranges": {"c": {"from": "cells"}, "r": {"from": "recs"}},
            "expr": {"op": "polygon_intersection_area", "manifold": "planar", "args": [
                {"op": "index", "args": ["pring", "r"]}, {"op": "index", "args": ["cring", "c"]}]},
            "join": [{"overlap": {"src_env": ["px0", "py0", "px1", "py1"],
                                  "tgt_env": ["cx0", "cy0", "cx1", "cy1"], "eps": 0.0}}]}}]),
    );
    let sq = |x0: f64, y0: f64, x1: f64, y1: f64| vec![x0, y0, x1, y0, x1, y1, x0, y1];
    let cring: Vec<f64> = [sq(0., 0., 1., 1.), sq(1., 0., 2., 1.), sq(5., 5., 6., 6.)].concat();
    let pring: Vec<f64> = [sq(0.5, 0.25, 1.5, 1.25), sq(1.25, 0.5, 1.75, 0.75)].concat();
    let consts: HashMap<String, ArrayD<f64>> = [
        ("cring", arr(&[3, 4, 2], &cring)),
        ("pring", arr(&[2, 4, 2], &pring)),
        ("cx0", arr(&[3], &[0., 1., 5.])),
        ("cy0", arr(&[3], &[0., 0., 5.])),
        ("cx1", arr(&[3], &[1., 2., 6.])),
        ("cy1", arr(&[3], &[1., 1., 6.])),
        ("px0", arr(&[2], &[0.5, 1.25])),
        ("py0", arr(&[2], &[0.25, 0.5])),
        ("px1", arr(&[2], &[1.5, 1.75])),
        ("py1", arr(&[2], &[1.25, 0.75])),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect();
    let native = check_pipeline(&doc, &consts, "M.out", &["M.out"]);
    assert_eq!(values(&native, "M.out"), vec![0.375, 0.5, 0.0]);
}

/// A causal self-reference (esm-spec §4.3.1.1) in an ingesting document runs
/// on the tape's ordered sweep instead of the pipeline's per-cell one.
#[test]
fn a_recurrence_in_the_pipeline_is_taped() {
    let doc = model_doc(
        json!({"steps": {"kind": "interval", "size": 5}}),
        json!({"x": {"type": "parameter", "default": 0.0, "shape": ["steps"]},
               "s": {"type": "unknown", "shape": ["steps"]}}),
        json!([{"lhs": "s", "rhs": {
            "op": "faq", "args": [], "output_idx": ["k"], "ranges": {"k": {"from": "steps"}},
            "expr": {"op": "ifelse", "args": [
                {"op": "<=", "args": ["k", 1]},
                {"op": "index", "args": ["x", 1]},
                {"op": "+", "args": [
                    {"op": "*", "args": [0.3, {"op": "index", "args": ["s", {"op": "-", "args": ["k", 1]}]}]},
                    {"op": "index", "args": ["x", "k"]}]}]}}}]),
    );
    let consts: HashMap<String, ArrayD<f64>> =
        [("x".to_string(), arr(&[5], &[1.0, 0.1, 7.0, 1e-9, 2.5]))]
            .into_iter()
            .collect();
    check_pipeline(&doc, &consts, "M.s", &["M.s"]);
}

/// A join whose key column is an observed computed from index symbols only
/// (CONFORMANCE_SPEC §5.5.8: build-time constant) builds natively, with no
/// pipeline at all; moves' F57 control.
#[test]
fn a_join_keyed_on_a_const_cadence_observed_builds_natively() {
    let doc = model_doc(
        json!({"rows": {"kind": "interval", "size": 4}, "keys": {"kind": "interval", "size": 2}}),
        json!({"row_key": {"type": "unknown", "shape": ["rows"], "units": "1"},
               "want": {"type": "unknown", "shape": ["keys"], "units": "1"},
               "total": {"type": "unknown", "shape": ["keys"], "units": "1"}}),
        json!([
            {"lhs": "row_key", "rhs": {"op": "faq", "args": [], "output_idx": ["r"],
                "ranges": {"r": {"from": "rows"}},
                "expr": {"op": "-", "args": ["r", {"op": "*", "args": [2, {"op": "floor", "args": [
                    {"op": "/", "args": [{"op": "-", "args": ["r", 1]}, 2]}]}]}]}}},
            {"lhs": "want", "rhs": {"op": "faq", "args": [], "output_idx": ["k"],
                "ranges": {"k": {"from": "keys"}}, "expr": "k"}},
            {"lhs": "total", "rhs": {"op": "faq", "args": [], "semiring": "sum_product",
                "output_idx": ["k"], "ranges": {"k": {"from": "keys"}, "r": {"from": "rows"}},
                "join": [{"on": [["want", "row_key"]]}], "expr": 1.0}},
        ]),
    );
    let none = HashMap::new();
    let native = build(&doc, Compiler::Native, false, &none).expect("native builds");
    let interp = build(&doc, Compiler::Interpreter, false, &none).expect("interpreter");
    assert_eq!(bits(&native, "M.total"), bits(&interp, "M.total"));
    assert_eq!(values(&native, "M.total"), vec![2.0, 2.0]);
}

/// A key column that reads a parameter is not build-time data — a caller may
/// change the parameter between solves — so the join is still refused, and the
/// refusal says why.
#[test]
fn a_join_keyed_on_a_parameter_dependent_observed_is_refused_naming_why() {
    let doc = model_doc(
        json!({"rows": {"kind": "interval", "size": 4}, "keys": {"kind": "interval", "size": 2}}),
        json!({"offset": {"type": "parameter", "units": "1", "default": 0.0},
               "row_key": {"type": "unknown", "shape": ["rows"], "units": "1"},
               "want": {"type": "unknown", "shape": ["keys"], "units": "1"},
               "total": {"type": "unknown", "shape": ["keys"], "units": "1"}}),
        json!([
            {"lhs": "row_key", "rhs": {"op": "faq", "args": [], "output_idx": ["r"],
                "ranges": {"r": {"from": "rows"}},
                "expr": {"op": "-", "args": ["r", {"op": "*", "args": [2, {"op": "floor", "args": [
                    {"op": "/", "args": [{"op": "-", "args": ["r", 1]}, 2]}]}]}]}}},
            {"lhs": "want", "rhs": {"op": "faq", "args": [], "output_idx": ["k"],
                "ranges": {"k": {"from": "keys"}}, "expr": {"op": "+", "args": ["k", "offset"]}}},
            {"lhs": "total", "rhs": {"op": "faq", "args": [], "semiring": "sum_product",
                "output_idx": ["k"], "ranges": {"k": {"from": "keys"}, "r": {"from": "rows"}},
                "join": [{"on": [["want", "row_key"]]}], "expr": 1.0}},
        ]),
    );
    let none = HashMap::new();
    match build(&doc, Compiler::Native, false, &none) {
        Err(SimulateError::Compile(CompileError::CompilerRefusedRule { rule, reason, .. })) => {
            assert!(rule.ends_with("total"), "{rule}");
            assert!(reason.contains("want` is not build-time data"), "{reason}");
            assert!(reason.contains("reads a parameter"), "{reason}");
        }
        Err(e) => panic!("expected compiler_refused_rule, got {e}"),
        Ok(_) => panic!("a parameter-dependent key must not be folded"),
    }
    let interp = build(&doc, Compiler::Interpreter, false, &none).expect("interpreter");
    assert_eq!(values(&interp, "M.total"), vec![2.0, 2.0]);
}
