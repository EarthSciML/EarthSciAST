//! CONST-ARRAY gather boundary policy (CONFORMANCE_SPEC.md §5.5.5).
//!
//! The dense evaluator used to apply the homogeneous-Dirichlet ZERO-GHOST
//! convention to every out-of-range gather, const-array gathers included: an
//! off-the-end flat gather raised `BoundsError` in Julia and `IndexError` in
//! Python, but read silently as `0.0` in Rust. §5.5.5 is explicit that the
//! zero-ghost convention is the state-VARIABLE gather's boundary default and is
//! **never** applied to a const-array gather, which without a declared boundary
//! policy MUST raise `E_TREEWALK_CONSTARRAY_OOB`.
//!
//! The reference numerics for `M = [10, 20, 30, 40]` (§5.5.5, and the same
//! table [`earthsci_ast::value_invention`] already honours on the
//! value-invention path): `clamp(M, 5) = 40`, `periodic(M, 5) = 10`,
//! `periodic(M, 0) = 40`.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::BoundaryKind;
use earthsci_ast::prepare::{PrepareOptions, prepare};
use earthsci_ast::simulate_array::{
    ConstArrayScope, Value as EvalValue, eval_expression_with_extents,
    eval_expression_with_extents_and_consts,
};
use earthsci_ast::types::Expr;
use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};

const M: [f64; 4] = [10.0, 20.0, 30.0, 40.0];

fn m_arrays() -> HashMap<String, ArrayD<f64>> {
    [(
        "M".to_string(),
        ArrayD::from_shape_vec(IxDyn(&[4]), M.to_vec()).unwrap(),
    )]
    .into_iter()
    .collect()
}

/// `index(M, i)` as a typed expression.
fn gather(i: i64) -> Expr {
    serde_json::from_value(json!({"op": "index", "args": ["M", i]})).unwrap()
}

fn eval_with(scope: &ConstArrayScope, i: i64) -> Result<f64, String> {
    let extents: HashMap<String, i64> = HashMap::new();
    eval_expression_with_extents_and_consts(
        &gather(i),
        &m_arrays(),
        &[],
        &[],
        0.0,
        &extents,
        scope,
    )
    .map(|v| match v {
        EvalValue::Scalar(s) => s,
        EvalValue::Array(a) => a.iter().next().copied().unwrap_or(f64::NAN),
    })
    .map_err(|e| e.to_string())
}

#[test]
fn undeclared_const_array_gather_out_of_range_is_an_error_not_a_zero_ghost() {
    let scope = ConstArrayScope::from_names(["M".to_string()]);
    // In range: unchanged.
    assert_eq!(eval_with(&scope, 1).unwrap(), 10.0);
    assert_eq!(eval_with(&scope, 4).unwrap(), 40.0);
    // Off either end: the error, naming the code.
    for i in [0i64, 5, 99, -3] {
        let e = eval_with(&scope, i).expect_err("const-array OOB must fail closed");
        assert!(
            e.contains("E_TREEWALK_CONSTARRAY_OOB"),
            "index {i}: wrong diagnostic: {e}"
        );
    }
}

#[test]
fn declared_periodic_and_clamp_policies_match_the_reference_numerics() {
    let periodic = ConstArrayScope::default().with_boundary("M", vec![BoundaryKind::Periodic]);
    let clamp = ConstArrayScope::default().with_boundary("M", vec![BoundaryKind::Clamp]);
    assert_eq!(eval_with(&periodic, 5).unwrap(), 10.0);
    assert_eq!(eval_with(&periodic, 0).unwrap(), 40.0);
    assert_eq!(eval_with(&clamp, 5).unwrap(), 40.0);
    assert_eq!(eval_with(&clamp, 0).unwrap(), 10.0);
    // In-range gathers are unaffected by either policy.
    assert_eq!(eval_with(&periodic, 3).unwrap(), 30.0);
    assert_eq!(eval_with(&clamp, 3).unwrap(), 30.0);
}

#[test]
fn a_state_or_observed_gather_keeps_the_zero_ghost_convention() {
    // The SAME expression, with `M` outside the const-array registry, is a
    // state/observed gather and still reads the homogeneous-Dirichlet ghost.
    let extents: HashMap<String, i64> = HashMap::new();
    let v = eval_expression_with_extents(&gather(5), &m_arrays(), &[], &[], 0.0, &extents).unwrap();
    assert!(matches!(v, EvalValue::Scalar(s) if s == 0.0));
    assert_eq!(eval_with(ConstArrayScope::empty(), 5).unwrap(), 0.0);
}

/// The measured symptom: an off-the-end FLAT gather over a whole axis, driven
/// through the `prepare` front door where the caller's `const_arrays` are the
/// const-array registry. It used to materialise `[0.0, 0.0, 0.0, 0.0]`.
#[test]
fn off_the_end_flat_gather_through_prepare_fails_closed() {
    let doc = json!({
        "esm": "0.9.0",
        "metadata": {"name": "const_array_oob"},
        "index_sets": {"k": {"kind": "interval", "size": 4}},
        "models": {"Gather": {
            "variables": {
                "M": {"type": "parameter", "shape": ["k"]},
                "shifted": {
                    "type": "observed",
                    "shape": ["k"],
                    "expression": {
                        "op": "aggregate",
                        "output_idx": ["i"],
                        "ranges": {"i": {"from": "k"}},
                        "args": ["M"],
                        "expr": {"op": "index", "args": [
                            "M", {"op": "+", "args": ["i", 4]}
                        ]}
                    }
                }
            },
            "equations": []
        }}
    });
    let opts = PrepareOptions {
        model_name: Some("Gather".into()),
        ..Default::default()
    };
    let e = match prepare(&doc, m_arrays(), Vec::new(), &opts) {
        Err(e) => e,
        Ok(prep) => panic!(
            "an entirely off-the-end const-array gather must fail closed; got {:?}",
            prep.observed_field("shifted").map(|a| a.iter().copied().collect::<Vec<_>>())
        ),
    };
    assert!(
        e.0.contains("E_TREEWALK_CONSTARRAY_OOB"),
        "wrong diagnostic: {}",
        e.0
    );
    let _: Value = doc; // the document is untouched
}
