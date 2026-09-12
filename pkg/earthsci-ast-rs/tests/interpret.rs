//! Operator-by-operator unit tests for the [`earthsci_ast::simulate`]
//! interpreter (gt-5ws). Every operator in the ESM expression algebra is
//! exercised at least once with concrete numeric inputs and expected outputs
//! taken from independent computation.
//!
//! Skipped on `wasm32` because the simulate module is gated to native
//! targets.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{ResolvedExpr, interpret};
use std::f64::consts::PI;

fn n(v: f64) -> ResolvedExpr {
    ResolvedExpr::Number(v)
}

/// `ResolvedExpr::Op` is sealed (`#[non_exhaustive]`), so an out-of-crate
/// caller builds one only through `ResolvedExpr::op`, which refuses an
/// operator the interpreter has no evaluation rule for (issue #220). Every
/// operator exercised below has one, so the `expect` never fires; the refusal
/// itself is the subject of `an_op_with_no_rule_cannot_be_built`.
fn op(name: &str, args: Vec<ResolvedExpr>) -> ResolvedExpr {
    ResolvedExpr::op(name, args).expect("the ops exercised here all have rules")
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
// Differential operators: neither a structural `D` nor a spatial sugar op can
// be built for this evaluator at all
// ============================================================================

/// A structural `D` can no longer be BUILT for this evaluator, let alone
/// evaluated (esm-spec §4.2).
///
/// It used to be constructible and answer `0.0` — the "legacy parity" marker,
/// matching what the two array evaluators returned. That parity was real and
/// all three were wrong together: four shipped documents computed silent zeros
/// through it, and §4.2 now says an implementation MUST NOT invent a value for
/// a right-hand-side `D`, in particular not `0`.
///
/// Nothing is lost. A `D` on an equation's LEFT-hand side never reaches this
/// evaluator — `resolve_expr` runs only over right-hand sides, observed bodies
/// and event bodies — and a `D` on a RIGHT-hand side is resolved to the
/// quantity's tendency by `flatten`'s phase 5b′, or refused with
/// `unlowered_operator` before any build. So the only `D` that could arrive
/// here is a pipeline bug, and issue #220's answer to that is a refusal naming
/// the op.
#[test]
fn a_structural_d_cannot_be_built_for_the_scalar_evaluator() {
    let err = ResolvedExpr::op("D", vec![n(123.0)])
        .expect_err("`D` has no evaluation rule here and must be refused by name");
    assert!(
        format!("{err}").contains('D'),
        "the refusal must name the operator, got: {err}"
    );
}

/// An operator with no evaluation rule is refused BY NAME at construction, and
/// so can never be evaluated at all (issue #220).
///
/// This used to read the other way round: `ResolvedExpr::Op` was freely
/// constructible and `interpret` answered `f64::NAN` — "undeterminable", and
/// deliberately not a silent `0.0` that would quietly poison a trajectory. But
/// a NaN is indistinguishable from a legitimate numerical result and propagates
/// into the solution just as silently, which is the defect #220 reports; the
/// author saw `actual=NaN expected=25` rather than the name of the operator at
/// fault. Sealing the variant behind `ResolvedExpr::op` moves the answer from
/// evaluation time to construction time, where it can name the operator.
#[test]
fn an_op_with_no_rule_cannot_be_built() {
    // The open-tier rewrite targets: ordinary rewrite targets with NO
    // privileged semantics, undeterminable until a discretization rule lowers
    // them (esm-spec §4.2), plus any unregistered op.
    for name in [
        "grad",
        "div",
        "laplacian",
        "curl",
        "∇",
        "integral",
        "totally_made_up",
    ] {
        let err = ResolvedExpr::op(name, vec![n(123.0)])
            .expect_err("an op with no evaluation rule must not be constructible");
        let msg = err.to_string();
        assert!(
            msg.contains("unevaluable_operator") && msg.contains(name),
            "{name} must be refused by name: {msg}"
        );
    }

    // The evaluable-core ops that are legal in an AST but that THIS evaluator
    // has no rule for are refused by the same door.
    for name in ["skolem", "rank", "faq", "intersect_polygon"] {
        assert!(
            ResolvedExpr::op(name, Vec::new()).is_err(),
            "{name} has no scalar rule and must not be constructible"
        );
    }
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
