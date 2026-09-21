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
use earthsci_ast::Expr;
use earthsci_ast::simulate_array::{
    ConstArrayScope, Value as EvalValue, eval_expression_with_extents,
    eval_expression_with_extents_and_consts,
};
use earthsci_ast::{ProblemOptions, esm_problem, observed_field};
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
    eval_expression_with_extents_and_consts(&gather(i), &m_arrays(), &[], &[], 0.0, &extents, scope)
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

/// A `const` literal written inline as the `index` base is a const array in its
/// own right (esm-spec §4.3.3): it needs no registry entry, and out of range on
/// any axis it fails closed instead of reading the zero ghost.
#[test]
fn an_inline_const_literal_out_of_range_is_an_error_not_a_zero_ghost() {
    let extents: HashMap<String, i64> = HashMap::new();
    let inline = |args: Value| -> Result<f64, String> {
        let e: Expr = serde_json::from_value(json!({"op": "index", "args": args})).unwrap();
        eval_expression_with_extents(&e, &HashMap::new(), &[], &[], 0.0, &extents)
            .map(|v| match v {
                EvalValue::Scalar(s) => s,
                EvalValue::Array(_) => f64::NAN,
            })
            .map_err(|e| e.to_string())
    };
    let t1 = json!({"op": "const", "args": [], "value": [10.0, 20.0, 30.0, 40.0]});
    let t2 = json!({"op": "const", "args": [], "value": [[1.0, 2.0], [3.0, 4.0], [5.0, 6.0]]});
    assert_eq!(inline(json!([t1, 4])).unwrap(), 40.0);
    assert_eq!(inline(json!([t2, 3, 2])).unwrap(), 6.0);
    for args in [
        json!([t1, 0]),
        json!([t1, 5]),
        json!([t2, 4, 1]),
        json!([t2, 1, 3]),
    ] {
        let e = inline(args.clone()).expect_err("inline const OOB must fail closed");
        assert!(
            e.contains("E_TREEWALK_CONSTARRAY_OOB"),
            "{args}: wrong diagnostic: {e}"
        );
    }
}

/// The same inline literal gathered over a whole axis of an array right-hand side,
/// `D(u[i]) = C[i + 1]`, which the vectorized and taped paths lower rather than
/// the per-cell interpreter. The last cell reads past the end of `C`.
#[test]
fn an_inline_const_gather_over_a_whole_axis_fails_closed() {
    use earthsci_ast::{Alg, SolveOptions, load_string, run_inline_tests_with_base_dir};
    let gather = |offset: i64| {
        json!({
            "esm": "1.1.0",
            "metadata": {"name": "inline_const_array_oob"},
            "index_sets": {"k": {"kind": "interval", "size": 4}},
            "models": {"Gather": {
                "variables": {"u": {"type": "unknown", "shape": ["k"], "default": 0.0}},
                "equations": [{
                    "lhs": {"op": "faq", "output_idx": ["i"], "ranges": {"i": {"from": "k"}},
                            "args": [],
                            "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}],
                                     "wrt": "t"}},
                    "rhs": {"op": "faq", "output_idx": ["i"], "ranges": {"i": {"from": "k"}},
                            "args": [],
                            "expr": {"op": "index", "args": [
                                {"op": "const", "args": [], "value": M.to_vec()},
                                {"op": "+", "args": ["i", offset]}
                            ]}}
                }],
                "tests": [{"id": "gather", "time_span": {"start": 0.0, "end": 1.0},
                           "assertions": [{"variable": "u", "time": 1.0, "reduce": "max",
                                           "expected": 40.0}]}]
            }}
        })
        .to_string()
    };
    let opts = SolveOptions {
        alg: Alg::Erk,
        ..Default::default()
    };
    let run = |offset: i64| {
        let file = load_string(&gather(offset)).expect("document loads");
        let results = earthsci_ast::run_inline_tests_with_options(
            &file,
            // As `const_array_gather_bounds_conformance`: §5.5.5's out-of-
            // range gather is a per-cell policy the tape has no form for, so
            // `native` refuses it by NAME.
            &earthsci_ast::InlineTestOptions {
                model_name: Some("Gather".to_string()),
                solve: opts.clone(),
                compiler: Some(earthsci_ast::Compiler::Interpreter),
                ..Default::default()
            },
            None,
        );
        assert_eq!(results.len(), 1);
        results.into_iter().next().unwrap()
    };
    // In range (`C[i]`): the whole-axis read is unchanged.
    let ok = run(0);
    assert!(
        ok.passed,
        "in-range whole-axis gather must pass: {}",
        ok.message
    );
    // Past the end on the last cell (`C[i + 1]`).
    let r = run(1);
    assert!(
        !r.passed && r.message.contains("E_TREEWALK_CONSTARRAY_OOB"),
        "an inline const gather past the end must fail closed; got actual {:?}: {}",
        r.actual,
        r.message
    );
}

/// The measured symptom: an off-the-end FLAT gather over a whole axis, driven
/// through the `prepare` front door where the caller's `const_arrays` are the
/// const-array registry. It used to materialise `[0.0, 0.0, 0.0, 0.0]`.
#[test]
fn off_the_end_flat_gather_through_prepare_fails_closed() {
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "const_array_oob"},
        "index_sets": {"k": {"kind": "interval", "size": 4}},
        "models": {"Gather": {
            "variables": {
                "M": {"type": "parameter", "shape": ["k"]},
                "shifted": {
                    "type": "unknown",
                    "shape": ["k"]}
            },
            "equations": [
                {"lhs": "shifted", "rhs": {
                        "op": "faq",
                        "output_idx": ["i"],
                        "ranges": {"i": {"from": "k"}},
                        "args": ["M"],
                        "expr": {"op": "index", "args": [
                            "M", {"op": "+", "args": ["i", 4]}
                        ]}
                    }}]
        }}
    });
    let opts = ProblemOptions {
        model_name: Some("Gather".into()),
        ..Default::default()
    };
    let e = match esm_problem(
        &doc,
        (0.0, 0.0),
        ProblemOptions {
            const_arrays: m_arrays(),
            build_providers: Vec::new(),
            ..opts
        },
    ) {
        Err(e) => e,
        Ok(prep) => panic!(
            "an entirely off-the-end const-array gather must fail closed; got {:?}",
            observed_field(&prep, "shifted").map(|a| a.iter().copied().collect::<Vec<_>>())
        ),
    };
    let msg = e.to_string();
    assert!(
        msg.contains("E_TREEWALK_CONSTARRAY_OOB"),
        "wrong diagnostic: {msg}"
    );
    let _: Value = doc; // the document is untouched
}
