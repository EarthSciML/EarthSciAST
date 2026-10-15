//! Build-time observeds that gather at computed subscripts: a gather through
//! an index array (`b[ix[k]]`), a data-dependent offset inside a contraction
//! (`fld[layer[r] * 4 + c]`), and an inline `const` array literal indexed by a
//! box symbol. The build pipeline evaluates them with the whole-array overlay,
//! so `native` builds them without walking a cell, with the interpreter's
//! values.

use earthsci_ast::{Compiler, ProblemOptions, esm_problem, observed_field};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};
use std::collections::HashMap;

fn arrays(entries: &[(&str, &[usize], &[f64])]) -> HashMap<String, ArrayD<f64>> {
    entries
        .iter()
        .map(|(k, shape, data)| {
            (
                k.to_string(),
                ArrayD::from_shape_vec(IxDyn(shape), data.to_vec()).expect("shape"),
            )
        })
        .collect()
}

fn field(d: &Value, consts: &HashMap<String, ArrayD<f64>>, compiler: Compiler) -> Vec<f64> {
    let opts = ProblemOptions {
        compiler: Some(compiler),
        const_arrays: consts.clone(),
        build_pipeline: true,
        ..Default::default()
    };
    let p = esm_problem(d, (0.0, 1.0), opts)
        .unwrap_or_else(|e| panic!("{compiler:?} builds the document: {e}"));
    observed_field(&p, "M.out")
        .expect("the observed is materialized")
        .iter()
        .copied()
        .collect()
}

/// Native and the interpreter agree, bit for bit, and equal `want`.
fn agrees(d: Value, consts: HashMap<String, ArrayD<f64>>, want: &[f64]) {
    let native = field(&d, &consts, Compiler::Native);
    let interp = field(&d, &consts, Compiler::Interpreter);
    let bits = |v: &[f64]| v.iter().map(|x| x.to_bits()).collect::<Vec<_>>();
    assert_eq!(
        bits(&native),
        bits(&interp),
        "native {native:?} vs interpreter {interp:?}"
    );
    assert_eq!(native, want);
}

fn doc(index_sets: Value, variables: Value, rhs: Value) -> Value {
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "BuildTimeComputedGathers"},
        "index_sets": index_sets,
        "models": {"M": {
            "system_kind": "nonlinear",
            "variables": variables,
            "equations": [{"lhs": "out", "rhs": rhs}]
        }}
    })
}

#[test]
fn gather_through_an_index_array() {
    let d = doc(
        json!({"n": {"kind": "interval", "size": 5}, "k": {"kind": "interval", "size": 3}}),
        json!({
            "b": {"type": "parameter", "default": 0.0, "shape": ["n"]},
            "ix": {"type": "parameter", "default": 0.0, "shape": ["k"]},
            "out": {"type": "unknown", "shape": ["k"]}
        }),
        json!({"op": "faq", "output_idx": ["k"], "ranges": {"k": {"from": "k"}},
               "args": ["b", "ix"],
               "expr": {"op": "index", "args": ["b", {"op": "index", "args": ["ix", "k"]}]}}),
    );
    let consts = arrays(&[
        ("b", &[5], &[10.0, 20.0, 30.0, 40.0, 50.0]),
        ("ix", &[3], &[1.0, 3.0, 5.0]),
    ]);
    agrees(d, consts, &[10.0, 30.0, 50.0]);
}

#[test]
fn data_dependent_offset_in_a_contraction() {
    let d = doc(
        json!({
            "cells": {"kind": "interval", "size": 4},
            "recs": {"kind": "interval", "size": 3},
            "all": {"kind": "interval", "size": 12}
        }),
        json!({
            "hit": {"type": "parameter", "default": 0.0, "shape": ["recs", "cells"]},
            "fld": {"type": "parameter", "default": 0.0, "shape": ["all"]},
            "layer": {"type": "parameter", "default": 0.0, "shape": ["recs"]},
            "out": {"type": "unknown", "shape": ["recs"]}
        }),
        json!({"op": "faq", "output_idx": ["r"], "reduce": "+",
               "ranges": {"r": {"from": "recs"}, "c": {"from": "cells"}},
               "args": ["hit", "fld", "layer"],
               "expr": {"op": "*", "args": [
                   {"op": "index", "args": ["hit", "r", "c"]},
                   {"op": "index", "args": ["fld", {"op": "+", "args": [
                       {"op": "*", "args": [{"op": "index", "args": ["layer", "r"]}, 4]}, "c"]}]}]}}),
    );
    let consts = arrays(&[
        (
            "hit",
            &[3, 4],
            &[1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0],
        ),
        ("fld", &[12], &(100..112).map(f64::from).collect::<Vec<_>>()),
        ("layer", &[3], &[0.0, 2.0, 1.0]),
    ]);
    agrees(d, consts, &[100.0, 111.0, 105.0]);
}

#[test]
fn inline_const_array_indexed_by_a_box_symbol() {
    let sets =
        json!({"cells": {"kind": "interval", "size": 3}, "xy": {"kind": "interval", "size": 2}});
    let vars = json!({
        "x": {"type": "parameter", "default": 0.0, "shape": ["cells"]},
        "y": {"type": "parameter", "default": 0.0, "shape": ["cells"]},
        "out": {"type": "unknown", "shape": ["cells", "xy"]}
    });
    let sel = |v: [f64; 2]| json!({"op": "index", "args": [{"op": "const", "value": v, "args": []}, "d"]});
    let consts = arrays(&[
        ("x", &[3], &[1.0, 2.0, 3.0]),
        ("y", &[3], &[10.0, 20.0, 30.0]),
    ]);
    let ring = json!({"op": "faq", "output_idx": ["c", "d"],
        "ranges": {"c": {"from": "cells"}, "d": {"from": "xy"}}, "args": ["x", "y"],
        "expr": {"op": "+", "args": [
            {"op": "*", "args": [sel([1.0, 0.0]), {"op": "index", "args": ["x", "c"]}]},
            {"op": "*", "args": [sel([0.0, 1.0]), {"op": "index", "args": ["y", "c"]}]}]}});
    agrees(
        doc(sets.clone(), vars.clone(), ring),
        consts.clone(),
        &[1.0, 10.0, 2.0, 20.0, 3.0, 30.0],
    );
    let selector = json!({"op": "faq", "output_idx": ["c", "d"],
        "ranges": {"c": {"from": "cells"}, "d": {"from": "xy"}}, "args": ["x", "y"],
        "expr": sel([1.0, 0.0])});
    agrees(
        doc(sets, vars, selector),
        consts,
        &[1.0, 0.0, 1.0, 0.0, 1.0, 0.0],
    );
}
