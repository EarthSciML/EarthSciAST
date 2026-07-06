//! Operator-by-operator unit tests for the [`earthsci_toolkit::simulate`]
//! interpreter (gt-5ws). Every operator in the ESM expression algebra is
//! exercised at least once with concrete numeric inputs and expected outputs
//! taken from independent computation.
//!
//! Skipped on `wasm32` because the simulate module is gated to native
//! targets.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_toolkit::{ResolvedExpr, interpret};
use std::f64::consts::PI;

fn n(v: f64) -> ResolvedExpr {
    ResolvedExpr::Number(v)
}

fn op(name: &str, args: Vec<ResolvedExpr>) -> ResolvedExpr {
    ResolvedExpr::Op {
        op: name.to_string(),
        args,
    }
}

fn approx(a: f64, b: f64, eps: f64) -> bool {
    (a - b).abs() <= eps * (1.0 + b.abs())
}

// ============================================================================
// Arithmetic
// ============================================================================

#[test]
fn add() {
    let e = op("+", vec![n(2.0), n(3.0)]);
    assert_eq!(interpret(&e, &[], &[], &[], 0.0), 5.0);

    // n-ary addition
    let e = op("+", vec![n(1.0), n(2.0), n(3.0), n(4.0)]);
    assert_eq!(interpret(&e, &[], &[], &[], 0.0), 10.0);
}

#[test]
fn sub_binary_and_unary() {
    let e = op("-", vec![n(10.0), n(3.0)]);
    assert_eq!(interpret(&e, &[], &[], &[], 0.0), 7.0);

    let e = op("-", vec![n(5.0)]);
    assert_eq!(interpret(&e, &[], &[], &[], 0.0), -5.0);
}

#[test]
fn mul_and_div() {
    let e = op("*", vec![n(2.0), n(3.0), n(4.0)]);
    assert_eq!(interpret(&e, &[], &[], &[], 0.0), 24.0);

    let e = op("/", vec![n(7.0), n(2.0)]);
    assert_eq!(interpret(&e, &[], &[], &[], 0.0), 3.5);
}

#[test]
fn pow() {
    let e = op("^", vec![n(2.0), n(10.0)]);
    assert_eq!(interpret(&e, &[], &[], &[], 0.0), 1024.0);
}

// ============================================================================
// Transcendentals
// ============================================================================

#[test]
fn exp_log_log10_sqrt() {
    assert!(approx(
        interpret(&op("exp", vec![n(1.0)]), &[], &[], &[], 0.0),
        std::f64::consts::E,
        1e-12
    ));
    assert!(approx(
        interpret(&op("log", vec![n(std::f64::consts::E)]), &[], &[], &[], 0.0),
        1.0,
        1e-12
    ));
    assert!(approx(
        interpret(&op("ln", vec![n(std::f64::consts::E)]), &[], &[], &[], 0.0),
        1.0,
        1e-12
    ));
    assert!(approx(
        interpret(&op("log10", vec![n(1000.0)]), &[], &[], &[], 0.0),
        3.0,
        1e-12
    ));
    assert!(approx(
        interpret(&op("sqrt", vec![n(2.0)]), &[], &[], &[], 0.0),
        std::f64::consts::SQRT_2,
        1e-12
    ));
}

#[test]
fn abs_sign_floor_ceil() {
    assert_eq!(
        interpret(&op("abs", vec![n(-3.5)]), &[], &[], &[], 0.0),
        3.5
    );
    assert_eq!(
        interpret(&op("sign", vec![n(-7.0)]), &[], &[], &[], 0.0),
        -1.0
    );
    assert_eq!(
        interpret(&op("sign", vec![n(2.0)]), &[], &[], &[], 0.0),
        1.0
    );
    assert_eq!(
        interpret(&op("sign", vec![n(0.0)]), &[], &[], &[], 0.0),
        0.0
    );
    assert_eq!(
        interpret(&op("floor", vec![n(2.7)]), &[], &[], &[], 0.0),
        2.0
    );
    assert_eq!(
        interpret(&op("ceil", vec![n(2.2)]), &[], &[], &[], 0.0),
        3.0
    );
}

// ============================================================================
// Trig and hyperbolics
// ============================================================================

#[test]
fn trig() {
    assert!(approx(
        interpret(&op("sin", vec![n(0.0)]), &[], &[], &[], 0.0),
        0.0,
        1e-12
    ));
    assert!(approx(
        interpret(&op("cos", vec![n(0.0)]), &[], &[], &[], 0.0),
        1.0,
        1e-12
    ));
    assert!(approx(
        interpret(&op("tan", vec![n(PI / 4.0)]), &[], &[], &[], 0.0),
        1.0,
        1e-12
    ));
    assert!(approx(
        interpret(&op("asin", vec![n(1.0)]), &[], &[], &[], 0.0),
        PI / 2.0,
        1e-12
    ));
    assert!(approx(
        interpret(&op("acos", vec![n(1.0)]), &[], &[], &[], 0.0),
        0.0,
        1e-12
    ));
    assert!(approx(
        interpret(&op("atan", vec![n(1.0)]), &[], &[], &[], 0.0),
        PI / 4.0,
        1e-12
    ));
    assert!(approx(
        interpret(&op("atan2", vec![n(1.0), n(1.0)]), &[], &[], &[], 0.0),
        PI / 4.0,
        1e-12
    ));
}

#[test]
fn hyperbolic() {
    assert!(approx(
        interpret(&op("sinh", vec![n(0.0)]), &[], &[], &[], 0.0),
        0.0,
        1e-12
    ));
    assert!(approx(
        interpret(&op("cosh", vec![n(0.0)]), &[], &[], &[], 0.0),
        1.0,
        1e-12
    ));
    assert!(approx(
        interpret(&op("tanh", vec![n(0.0)]), &[], &[], &[], 0.0),
        0.0,
        1e-12
    ));
}

// ============================================================================
// Min / max / ifelse
// ============================================================================

#[test]
fn min_max() {
    assert_eq!(
        interpret(&op("min", vec![n(2.0), n(3.0)]), &[], &[], &[], 0.0),
        2.0
    );
    assert_eq!(
        interpret(&op("max", vec![n(2.0), n(3.0)]), &[], &[], &[], 0.0),
        3.0
    );
}

#[test]
fn ifelse_chooses_branch() {
    let e = op("ifelse", vec![n(1.0), n(42.0), n(99.0)]);
    assert_eq!(interpret(&e, &[], &[], &[], 0.0), 42.0);

    let e = op("ifelse", vec![n(0.0), n(42.0), n(99.0)]);
    assert_eq!(interpret(&e, &[], &[], &[], 0.0), 99.0);
}

// ============================================================================
// Relational and logical (return 0/1)
// ============================================================================

#[test]
fn relational() {
    assert_eq!(
        interpret(&op("<", vec![n(1.0), n(2.0)]), &[], &[], &[], 0.0),
        1.0
    );
    assert_eq!(
        interpret(&op("<", vec![n(2.0), n(2.0)]), &[], &[], &[], 0.0),
        0.0
    );
    assert_eq!(
        interpret(&op(">", vec![n(3.0), n(2.0)]), &[], &[], &[], 0.0),
        1.0
    );
    assert_eq!(
        interpret(&op("<=", vec![n(2.0), n(2.0)]), &[], &[], &[], 0.0),
        1.0
    );
    assert_eq!(
        interpret(&op(">=", vec![n(2.0), n(2.0)]), &[], &[], &[], 0.0),
        1.0
    );
    assert_eq!(
        interpret(&op("==", vec![n(2.0), n(2.0)]), &[], &[], &[], 0.0),
        1.0
    );
    assert_eq!(
        interpret(&op("!=", vec![n(2.0), n(3.0)]), &[], &[], &[], 0.0),
        1.0
    );
}

#[test]
fn logical() {
    assert_eq!(
        interpret(&op("and", vec![n(1.0), n(1.0)]), &[], &[], &[], 0.0),
        1.0
    );
    assert_eq!(
        interpret(&op("and", vec![n(1.0), n(0.0)]), &[], &[], &[], 0.0),
        0.0
    );
    assert_eq!(
        interpret(&op("or", vec![n(0.0), n(1.0)]), &[], &[], &[], 0.0),
        1.0
    );
    assert_eq!(
        interpret(&op("or", vec![n(0.0), n(0.0)]), &[], &[], &[], 0.0),
        0.0
    );
    assert_eq!(interpret(&op("not", vec![n(0.0)]), &[], &[], &[], 0.0), 1.0);
    assert_eq!(interpret(&op("not", vec![n(1.0)]), &[], &[], &[], 0.0), 0.0);
}

// ============================================================================
// Variable references
// ============================================================================

#[test]
fn state_param_observed_time_refs() {
    // f(state, params, observed, t) = state[1]*param[0] + observed[0] - t
    let e = op(
        "+",
        vec![
            op(
                "+",
                vec![
                    op("*", vec![ResolvedExpr::State(1), ResolvedExpr::Param(0)]),
                    ResolvedExpr::Observed(0),
                ],
            ),
            op("-", vec![ResolvedExpr::Time]),
        ],
    );
    let state = [10.0, 20.0];
    let params = [3.0];
    let observed = [7.0];
    let t = 5.0;
    // 20*3 + 7 - 5 = 62
    assert_eq!(interpret(&e, &state, &params, &observed, t), 62.0);
}

// ============================================================================
// Differential operators are no-ops on the RHS
// ============================================================================

#[test]
fn differential_ops_zero_on_rhs() {
    assert_eq!(interpret(&op("D", vec![n(123.0)]), &[], &[], &[], 0.0), 0.0);
    assert_eq!(
        interpret(&op("grad", vec![n(123.0)]), &[], &[], &[], 0.0),
        0.0
    );
    assert_eq!(
        interpret(&op("div", vec![n(123.0)]), &[], &[], &[], 0.0),
        0.0
    );
    assert_eq!(
        interpret(&op("laplacian", vec![n(123.0)]), &[], &[], &[], 0.0),
        0.0
    );
}

// ============================================================================
// Pre passes through
// ============================================================================

#[test]
fn pre_returns_argument() {
    assert_eq!(
        interpret(&op("Pre", vec![n(42.0)]), &[], &[], &[], 0.0),
        42.0
    );
}

// ============================================================================
// Unknown operator yields NaN (so the solver detects the failure)
// ============================================================================

#[test]
fn unknown_op_returns_nan() {
    let v = interpret(&op("totally_made_up", vec![n(1.0)]), &[], &[], &[], 0.0);
    assert!(v.is_nan());
}
