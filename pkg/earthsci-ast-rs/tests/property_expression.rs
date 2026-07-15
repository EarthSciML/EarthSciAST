//! Property-based tests for expression JSON round-trip invariants (gt-onq5).
//!
//! Phase 4 of the cross-binding fuzzing initiative (gt-72z). Ports the Python
//! `hypothesis`-driven generator from
//! `pkg/earthsci-ast-py/tests/test_property_expression.py` to Rust
//! `proptest`, exercising the same invariants on the Rust `Expr` /
//! `ExpressionNode` types:
//!
//!   - `from_value(to_value(e)) == e` structurally.
//!   - Serialization is idempotent (`to_value` twice yields the same JSON
//!     value).
//!   - The text-JSON round trip (`to_string` → `from_str`) preserves the
//!     expression under `to_value` normalization.
//!
//! The Rust type system already excludes several shapes the Python generator
//! had to filter out (e.g. `ranges` values are fixed `[i64; 2]` arrays, and
//! `output_idx` entries are always strings), so the generator here tracks the
//! Rust type constraints rather than mirroring Python exactly.

use earthsci_ast::{Expr, ExpressionNode};
use proptest::prelude::*;

// ---------------------------------------------------------------------------
// Atomic strategies
// ---------------------------------------------------------------------------

fn int_literal() -> impl Strategy<Value = f64> {
    (-1_000_000_i64..=1_000_000).prop_map(|i| i as f64)
}

fn float_literal() -> impl Strategy<Value = f64> {
    // Bounded finite range — JSON has no representation for NaN / ±Inf, and
    // large magnitudes risk losing precision in f64→decimal→f64 text trips.
    -1e9_f64..1e9_f64
}

fn var_name() -> impl Strategy<Value = String> {
    "[a-z][a-zA-Z0-9_]{0,7}".prop_map(String::from)
}

fn index_name() -> impl Strategy<Value = String> {
    "[a-z]".prop_map(String::from)
}

fn leaf() -> BoxedStrategy<Expr> {
    prop_oneof![
        int_literal().prop_map(Expr::Number),
        float_literal().prop_map(Expr::Number),
        var_name().prop_map(Expr::Variable),
    ]
    .boxed()
}

// ---------------------------------------------------------------------------
// Operator-shape strategies
// ---------------------------------------------------------------------------

fn mk_plain(op: &'static str, args: Vec<Expr>) -> Expr {
    Expr::Operator(ExpressionNode {
        op: op.to_string(),
        args,
        ..Default::default()
    })
}

fn op_nary(
    op: &'static str,
    child: BoxedStrategy<Expr>,
    min: usize,
    max: usize,
) -> BoxedStrategy<Expr> {
    prop::collection::vec(child, min..=max)
        .prop_map(move |args| mk_plain(op, args))
        .boxed()
}

fn op_unary(op: &'static str, child: BoxedStrategy<Expr>) -> BoxedStrategy<Expr> {
    child.prop_map(move |a| mk_plain(op, vec![a])).boxed()
}

fn op_binary(op: &'static str, child: BoxedStrategy<Expr>) -> BoxedStrategy<Expr> {
    (child.clone(), child)
        .prop_map(move |(a, b)| mk_plain(op, vec![a, b]))
        .boxed()
}

fn op_unary_or_binary(op: &'static str, child: BoxedStrategy<Expr>) -> BoxedStrategy<Expr> {
    prop_oneof![op_unary(op, child.clone()), op_binary(op, child)].boxed()
}

fn op_ifelse(child: BoxedStrategy<Expr>) -> BoxedStrategy<Expr> {
    (child.clone(), child.clone(), child)
        .prop_map(|(a, b, c)| mk_plain("ifelse", vec![a, b, c]))
        .boxed()
}

fn op_derivative(child: BoxedStrategy<Expr>) -> BoxedStrategy<Expr> {
    (child, var_name())
        .prop_map(|(a, v)| {
            Expr::Operator(ExpressionNode {
                op: "D".into(),
                args: vec![a],
                wrt: Some(v),
                ..Default::default()
            })
        })
        .boxed()
}

fn op_grad(child: BoxedStrategy<Expr>) -> BoxedStrategy<Expr> {
    (child, var_name())
        .prop_map(|(a, d)| {
            Expr::Operator(ExpressionNode {
                op: "grad".into(),
                args: vec![a],
                dim: Some(d),
                ..Default::default()
            })
        })
        .boxed()
}

// ---------------------------------------------------------------------------
// Array-op strategies — exercise the auxiliary fields on ExpressionNode
// (expr, output_idx, reduce, ranges, regions, values, shape, perm, axis, fn).
// ---------------------------------------------------------------------------

fn op_reshape(child: BoxedStrategy<Expr>) -> BoxedStrategy<Expr> {
    (child, prop::collection::vec(1_i64..=16, 1..=4))
        .prop_map(|(a, shape)| {
            Expr::Operator(ExpressionNode {
                op: "reshape".into(),
                args: vec![a],
                shape: Some(shape),
                ..Default::default()
            })
        })
        .boxed()
}

fn op_transpose(child: BoxedStrategy<Expr>) -> BoxedStrategy<Expr> {
    // perm is optional; cover both shapes.
    let with_perm = (child.clone(), prop::collection::vec(0_i64..=8, 1..=4)).prop_map(|(a, p)| {
        Expr::Operator(ExpressionNode {
            op: "transpose".into(),
            args: vec![a],
            perm: Some(p),
            ..Default::default()
        })
    });
    let without_perm = child.prop_map(|a| mk_plain("transpose", vec![a]));
    prop_oneof![with_perm, without_perm].boxed()
}

fn op_concat(child: BoxedStrategy<Expr>) -> BoxedStrategy<Expr> {
    // axis is required and may legitimately be 0 — a falsy value that a naive
    // `if axis {…}` check would drop.
    (prop::collection::vec(child, 2..=3), 0_i64..=3_i64)
        .prop_map(|(args, axis)| {
            Expr::Operator(ExpressionNode {
                op: "concat".into(),
                args,
                axis: Some(axis),
                ..Default::default()
            })
        })
        .boxed()
}

fn op_broadcast(child: BoxedStrategy<Expr>) -> BoxedStrategy<Expr> {
    let fn_strategy = prop_oneof![
        Just("+".to_string()),
        Just("-".to_string()),
        Just("*".to_string()),
        Just("/".to_string()),
        Just("max".to_string()),
        Just("min".to_string()),
    ];
    (prop::collection::vec(child, 1..=3), fn_strategy)
        .prop_map(|(args, f)| {
            Expr::Operator(ExpressionNode {
                op: "broadcast".into(),
                args,
                broadcast_fn: Some(f),
                ..Default::default()
            })
        })
        .boxed()
}

fn op_index(child: BoxedStrategy<Expr>) -> BoxedStrategy<Expr> {
    prop::collection::vec(child, 1..=3)
        .prop_map(|args| mk_plain("index", args))
        .boxed()
}

fn op_arrayop(child: BoxedStrategy<Expr>) -> BoxedStrategy<Expr> {
    let output_idx = prop::collection::vec(index_name(), 1..=3);
    let reduce = prop_oneof![
        Just(Some("+".to_string())),
        Just(Some("*".to_string())),
        Just(Some("max".to_string())),
        Just(Some("min".to_string())),
        Just(None::<String>),
    ];
    let range_pair = (0_i64..=8, 0_i64..=8)
        .prop_map(|(a, b)| earthsci_ast::types::RangeSpec::Interval([a, b]));
    let ranges = prop::option::of(prop::collection::hash_map(index_name(), range_pair, 0..=3));
    let args = prop::collection::vec(child.clone(), 1..=2);
    (args, output_idx, child, reduce, ranges)
        .prop_map(|(args, oi, body, red, rngs)| {
            Expr::Operator(ExpressionNode {
                op: "arrayop".into(),
                args,
                output_idx: Some(oi),
                expr: Some(Box::new(body)),
                reduce: red,
                ranges: rngs,
                ..Default::default()
            })
        })
        .boxed()
}

fn op_makearray(child: BoxedStrategy<Expr>) -> BoxedStrategy<Expr> {
    let region_entry =
        prop::collection::vec((0_i64..=8, 0_i64..=8).prop_map(|(a, b)| [a, b]), 1..=3);
    // Regions and values must have equal length, so generate pairs together.
    let pair = (region_entry, child).prop_map(|(r, v)| (r, v));
    prop::collection::vec(pair, 1..=3)
        .prop_map(|pairs| {
            let (regions, values): (Vec<_>, Vec<_>) = pairs.into_iter().unzip();
            Expr::Operator(ExpressionNode {
                op: "makearray".into(),
                args: vec![],
                regions: Some(regions),
                values: Some(values),
                ..Default::default()
            })
        })
        .boxed()
}

// ---------------------------------------------------------------------------
// Recursive assembly
// ---------------------------------------------------------------------------

fn expr_strategy() -> BoxedStrategy<Expr> {
    leaf()
        .prop_recursive(4, 64, 4, |inner| {
            prop_oneof![
                // n-ary arithmetic
                op_nary("+", inner.clone(), 2, 4),
                op_nary("*", inner.clone(), 2, 4),
                op_unary_or_binary("-", inner.clone()),
                op_binary("/", inner.clone()),
                op_binary("^", inner.clone()),
                // transcendentals
                op_unary("log", inner.clone()),
                op_unary("exp", inner.clone()),
                op_unary("sin", inner.clone()),
                op_unary("cos", inner.clone()),
                op_unary("tan", inner.clone()),
                op_unary("asin", inner.clone()),
                op_unary("acos", inner.clone()),
                op_unary("atan", inner.clone()),
                op_binary("atan2", inner.clone()),
                // misc scalar
                op_unary("abs", inner.clone()),
                op_unary("sign", inner.clone()),
                op_unary("sqrt", inner.clone()),
                op_unary("log10", inner.clone()),
                op_unary("floor", inner.clone()),
                op_unary("ceil", inner.clone()),
                op_nary("min", inner.clone(), 1, 4),
                op_nary("max", inner.clone(), 1, 4),
                // logical
                op_nary("and", inner.clone(), 2, 4),
                op_nary("or", inner.clone(), 2, 4),
                op_unary("not", inner.clone()),
                // control flow and scalar auxiliary-field ops
                op_ifelse(inner.clone()),
                op_derivative(inner.clone()),
                op_grad(inner.clone()),
                // array-op extensions
                op_reshape(inner.clone()),
                op_transpose(inner.clone()),
                op_concat(inner.clone()),
                op_broadcast(inner.clone()),
                op_index(inner.clone()),
                op_arrayop(inner.clone()),
                op_makearray(inner),
            ]
        })
        .boxed()
}

// ---------------------------------------------------------------------------
// Properties
// ---------------------------------------------------------------------------

proptest! {
    // 64 cases per property keeps the whole file well under a second while
    // still exercising a substantial variety of shapes. Failing cases are
    // cached by proptest across runs, so coverage grows with use.
    #![proptest_config(ProptestConfig {
        cases: 64,
        .. ProptestConfig::default()
    })]

    /// Round-tripping through `Value` preserves the expression's CANONICAL form.
    /// Under §5.5.3.1 an integral float operand (`Number(9.0)`) serializes as an
    /// integer literal, so `Number(9.0)` and `Integer(9)` are indistinguishable
    /// after a trip — the AST node kind is NOT preserved, but the serialized
    /// (canonical) value is, which is the property the cross-binding contract
    /// actually requires (and matches the JS/Julia/Python bindings).
    #[test]
    fn parse_serialize_round_trip_in_memory(expr in expr_strategy()) {
        let value = serde_json::to_value(&expr).expect("serialize to Value");
        let parsed: Expr = serde_json::from_value(value.clone()).expect("deserialize from Value");
        prop_assert_eq!(serde_json::to_value(&parsed).expect("re-serialize"), value);
    }

    /// Serializing twice yields the same JSON value (content-equal).
    #[test]
    fn serialize_idempotent(expr in expr_strategy()) {
        let once = serde_json::to_value(&expr).expect("serialize #1");
        let parsed: Expr = serde_json::from_value(once.clone()).expect("round-trip parse");
        let twice = serde_json::to_value(&parsed).expect("serialize #2");
        prop_assert_eq!(once, twice);
    }

    /// Full text-JSON round trip preserves the expression. We compare both
    /// sides *after* one text trip so that f64 values on both sides have gone
    /// through the same lossy decimal→binary conversion (matching the Python
    /// test's `_serialized_equal` pattern). Parsing the text back to `Value`
    /// also normalizes HashMap iteration order via serde_json's BTreeMap-
    /// backed `Map`.
    #[test]
    fn round_trip_through_json_text(expr in expr_strategy()) {
        let s_once = serde_json::to_string(&expr).expect("to_string #1");
        let reparsed: Expr = serde_json::from_str(&s_once).expect("from_str");
        let s_twice = serde_json::to_string(&reparsed).expect("to_string #2");
        let v_once: serde_json::Value =
            serde_json::from_str(&s_once).expect("from_str (Value) #1");
        let v_twice: serde_json::Value =
            serde_json::from_str(&s_twice).expect("from_str (Value) #2");
        prop_assert_eq!(v_once, v_twice);
    }
}

// ---------------------------------------------------------------------------
// Targeted regressions — mirror the Python file's edge-case tests.
// ---------------------------------------------------------------------------

/// Under the ESM canonical-number rule (§5.5.3.1) a value that is integral —
/// signed zero included — serializes as an integer literal, exactly as the
/// JS/Julia/Python bindings do (`JSON.stringify(-0) === "0"`). So `-0.0` and
/// `0.0` both canonicalize to the integer `0`. (The pre-canonical binding
/// preserved the `-0.0` sign as a float; that diverged from every other
/// binding, so this now asserts the collapse instead.)
#[test]
fn negative_zero_canonicalizes_to_integer_zero() {
    let expr = Expr::Operator(ExpressionNode {
        op: "+".into(),
        args: vec![Expr::Number(-0.0), Expr::Number(0.0)],
        ..Default::default()
    });
    let s = serde_json::to_string(&expr).unwrap();
    assert!(!s.contains("0.0"), "integral zero must not serialize with a fraction: {s}");
    assert!(!s.contains("-0"), "signed zero must collapse to `0`: {s}");
    let parsed: Expr = serde_json::from_str(&s).unwrap();
    match parsed {
        Expr::Operator(node) => {
            assert_eq!(
                node.args,
                vec![Expr::Integer(0), Expr::Integer(0)],
                "both operands must canonicalize to the integer 0"
            );
        }
        _ => panic!("not an operator after round trip"),
    }
}

#[test]
fn round_trip_preserves_unary_minus_arity() {
    let expr = Expr::Operator(ExpressionNode {
        op: "-".into(),
        args: vec![Expr::Variable("x".into())],
        ..Default::default()
    });
    let s = serde_json::to_string(&expr).unwrap();
    let parsed: Expr = serde_json::from_str(&s).unwrap();
    assert_eq!(parsed, expr, "unary minus lost its arity");
    if let Expr::Operator(node) = &parsed {
        assert_eq!(node.args.len(), 1, "unary minus must remain unary");
    } else {
        panic!("not an operator after round trip");
    }
}
