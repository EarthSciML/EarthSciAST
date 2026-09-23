//! Leaf-operator tests for the public [`earthsci_ast::evaluate`], which runs a
//! single expression through the array runtime's per-cell oracle.
//!
//! The op-by-op VALUE rows for arithmetic, `abs`/`sign`/`floor`/`ceil`,
//! `min`/`max`, `ifelse`, the relational and the logical ops are the
//! cross-binding `tests/conformance/scalar_operator_semantics/` tier
//! (CONFORMANCE_SPEC §5.45.4), which `scripts/test-conformance.sh` runs for
//! julia, rust and python under both `interpreter` and `native`. What stays
//! here is what that fixture does not carry: the rows whose last bits belong to
//! a libm at operands the fixture does not state, the inverse and hyperbolic
//! leaves that `tests/conformance/inverse_trig/` owns, the binding of names and
//! `t`, and the refusals.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Expr, ExpressionNode, evaluate};
use std::collections::HashMap;
use std::f64::consts::PI;

fn n(v: f64) -> Expr {
    Expr::Number(v)
}

fn var(name: &str) -> Expr {
    Expr::Variable(name.to_string())
}

fn op(name: &str, args: Vec<Expr>) -> Expr {
    Expr::operator(ExpressionNode {
        op: name.to_string(),
        args,
        ..Default::default()
    })
}

/// `expr` evaluated with no bindings.
fn eval(expr: &Expr) -> f64 {
    evaluate(expr, &HashMap::new()).expect("the ops exercised here all evaluate")
}

fn approx(a: f64, b: f64, eps: f64) -> bool {
    (a - b).abs() <= eps * (1.0 + b.abs())
}

#[test]
fn exp_log_log10_sqrt() {
    assert!(approx(
        eval(&op("exp", vec![n(1.0)])),
        std::f64::consts::E,
        1e-12
    ));
    assert!(approx(
        eval(&op("log", vec![n(std::f64::consts::E)])),
        1.0,
        1e-12
    ));
    assert!(approx(
        eval(&op("ln", vec![n(std::f64::consts::E)])),
        1.0,
        1e-12
    ));
    assert!(approx(eval(&op("log10", vec![n(1000.0)])), 3.0, 1e-12));
    assert!(approx(
        eval(&op("sqrt", vec![n(2.0)])),
        std::f64::consts::SQRT_2,
        1e-12
    ));
}

#[test]
fn trig() {
    assert!(approx(eval(&op("sin", vec![n(0.0)])), 0.0, 1e-12));
    assert!(approx(eval(&op("cos", vec![n(0.0)])), 1.0, 1e-12));
    assert!(approx(eval(&op("tan", vec![n(PI / 4.0)])), 1.0, 1e-12));
    assert!(approx(eval(&op("asin", vec![n(1.0)])), PI / 2.0, 1e-12));
    assert!(approx(eval(&op("acos", vec![n(1.0)])), 0.0, 1e-12));
    assert!(approx(eval(&op("atan", vec![n(1.0)])), PI / 4.0, 1e-12));
    assert!(approx(
        eval(&op("atan2", vec![n(1.0), n(1.0)])),
        PI / 4.0,
        1e-12
    ));
}

#[test]
fn hyperbolic() {
    assert!(approx(eval(&op("sinh", vec![n(0.0)])), 0.0, 1e-12));
    assert!(approx(eval(&op("cosh", vec![n(0.0)])), 1.0, 1e-12));
    assert!(approx(eval(&op("tanh", vec![n(0.0)])), 0.0, 1e-12));
}

/// Bound names read their bindings and `t` reads the `"t"` binding.
#[test]
fn bound_names_and_time() {
    // a*k + b - t with a = 20, k = 3, b = 7, t = 5 → 62
    let e = op(
        "+",
        vec![
            op("+", vec![op("*", vec![var("a"), var("k")]), var("b")]),
            op("-", vec![var("t")]),
        ],
    );
    let bindings: HashMap<String, f64> = [("a", 20.0), ("k", 3.0), ("b", 7.0), ("t", 5.0)]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
    assert_eq!(evaluate(&e, &bindings).unwrap(), 62.0);

    // `t` defaults to 0 when the caller binds none.
    assert_eq!(eval(&op("+", vec![var("t"), n(1.0)])), 1.0);
}

/// An unbound name is reported by name, not evaluated.
#[test]
fn an_unbound_name_is_reported() {
    let err = evaluate(&op("+", vec![var("x"), var("y")]), &HashMap::new())
        .expect_err("unbound names must not evaluate");
    assert_eq!(err, vec!["x".to_string(), "y".to_string()]);
}

/// A structural `D` has no value to invent (esm-spec §4.2), in particular not
/// `0`, so it is refused by name.
#[test]
fn a_structural_d_is_refused_by_name() {
    let d = Expr::operator(ExpressionNode {
        op: "D".to_string(),
        args: vec![n(123.0)],
        wrt: Some("t".to_string()),
        ..Default::default()
    });
    let err = evaluate(&d, &HashMap::new()).expect_err("`D` must be refused by name");
    let msg = err.join("; ");
    assert!(
        msg.contains("unevaluable_operator") && msg.contains("'D'"),
        "the refusal must name the operator, got: {msg}"
    );
}

/// An op with no evaluation rule is refused BY NAME before any of the
/// expression is evaluated — never answered with a `NaN` (issue #220).
#[test]
fn an_op_with_no_rule_is_refused_by_name() {
    // The open-tier rewrite targets, which a discretization rule must lower
    // first (esm-spec §4.2), plus any unregistered op.
    for name in [
        "grad",
        "div",
        "laplacian",
        "curl",
        "∇",
        "integral",
        "totally_made_up",
    ] {
        let err = evaluate(&op(name, vec![n(123.0)]), &HashMap::new())
            .expect_err("an op with no evaluation rule must not evaluate");
        let msg = err.join("; ");
        assert!(
            msg.contains("unlowered_operator") && msg.contains(name),
            "{name} must be refused by name: {msg}"
        );
    }

    // Evaluable-core ops with no value over scalar bindings: the build-time
    // relational ops.
    for name in ["skolem", "rank"] {
        let err = evaluate(&op(name, vec![n(1.0)]), &HashMap::new())
            .expect_err("an op with no scalar rule must not evaluate");
        let msg = err.join("; ");
        assert!(
            msg.contains("unevaluable_operator") && msg.contains(name),
            "{name} must be refused by name: {msg}"
        );
    }
}

#[test]
fn pre_returns_argument() {
    assert_eq!(eval(&op("Pre", vec![n(42.0)])), 42.0);
}
