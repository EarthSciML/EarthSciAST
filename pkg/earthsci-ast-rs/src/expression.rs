//! Expression manipulation utilities

use crate::Expr;
use std::collections::{HashMap, HashSet};

/// Extract all free variables from an expression
///
/// # Arguments
///
/// * `expr` - The expression to analyze
///
/// # Returns
///
/// * Set of variable names referenced in the expression
pub fn free_variables(expr: &Expr) -> HashSet<String> {
    let mut vars = HashSet::new();
    collect_variables(expr, &mut vars);
    vars
}

/// Extract all free parameters from an expression
///
/// This is currently the same as free_variables since we don't distinguish
/// parameters from variables at the expression level.
///
/// # Arguments
///
/// * `expr` - The expression to analyze
///
/// # Returns
///
/// * Set of parameter names referenced in the expression
pub fn free_parameters(expr: &Expr) -> HashSet<String> {
    free_variables(expr)
}

/// Check if an expression contains a specific variable
///
/// # Arguments
///
/// * `expr` - The expression to search
/// * `var_name` - The variable name to look for
///
/// # Returns
///
/// * `true` if the variable is found, `false` otherwise
pub fn contains(expr: &Expr, var_name: &str) -> bool {
    match expr {
        Expr::Variable(name) => name == var_name,
        Expr::Operator(op_node) => op_node.any_child(&mut |arg| contains(arg, var_name)),
        Expr::Number(_) | Expr::Integer(_) => false,
    }
}

/// Simplify an expression (basic symbolic simplification).
///
/// Applies constant folding and the identity/absorbing-element rules for
/// binary `+`, `*`, and `^`. Children are simplified first — including
/// sidecar expressions (aggregate bodies, `filter`, integral bounds,
/// makearray `values`, `table_lookup` axes) — and operator nodes are rebuilt
/// with [`crate::types::ExpressionNode::map_children`], so all node metadata
/// is preserved.
pub fn simplify(expr: &Expr) -> Expr {
    match expr {
        Expr::Number(n) => Expr::Number(*n),
        Expr::Integer(n) => Expr::Integer(*n),
        Expr::Variable(name) => Expr::Variable(name.clone()),
        Expr::Operator(op_node) => simplify_node(op_node.map_children(&mut |c| simplify(c))),
    }
}

/// Insert every variable name referenced anywhere in `expr` into `vars`,
/// walking the canonical child set via
/// [`crate::types::ExpressionNode::for_each_child`]. This is the single
/// crate-internal implementation of expression variable collection (it backs
/// [`free_variables`]); other modules should reuse it rather than hand-rolling
/// another walker.
pub(crate) fn collect_variables(expr: &Expr, vars: &mut HashSet<String>) {
    match expr {
        Expr::Variable(name) => {
            vars.insert(name.clone());
        }
        Expr::Operator(op_node) => {
            op_node.for_each_child(&mut |arg| collect_variables(arg, vars));
        }
        Expr::Number(_) | Expr::Integer(_) => {
            // Numbers don't contain variables
        }
    }
}

/// Algebraic identities over a node whose children are already simplified.
/// Returns the node unchanged (all fields intact) when no rule applies.
fn simplify_node(node: crate::types::ExpressionNode) -> Expr {
    // The three numeric folds below are constant folding, so they round to the
    // active precision (`crate::precision`, esm-spec §11.3.1): a Float32
    // document in which `a + b` was folded in binary64 would disagree with the
    // same subexpression evaluated at run time. Identity under Float64, where
    // `round` is `|v| v` and each arm is the expression it always was. The
    // identity/annihilator arms (`0 + x`, `1 * x`, `x^0`, `x^1`, `0 * x`) fold
    // to an operand or to an exactly-representable constant, so they need none.
    let prec = crate::precision::active();
    let folded = match (node.op.as_str(), node.args.as_slice()) {
        // 0 + x = x ; x + 0 = x
        ("+", [Expr::Number(z), x]) | ("+", [x, Expr::Number(z)]) if *z == 0.0 => Some(x.clone()),
        // a + b for numbers
        ("+", [Expr::Number(a), Expr::Number(b)]) => {
            Some(Expr::Number(prec.round(prec.round(*a) + prec.round(*b))))
        }
        // 0 * x = 0 ; x * 0 = 0
        ("*", [Expr::Number(z), _]) | ("*", [_, Expr::Number(z)]) if *z == 0.0 => {
            Some(Expr::Number(0.0))
        }
        // 1 * x = x ; x * 1 = x
        ("*", [Expr::Number(one), x]) | ("*", [x, Expr::Number(one)]) if *one == 1.0 => {
            Some(x.clone())
        }
        // a * b for numbers
        ("*", [Expr::Number(a), Expr::Number(b)]) => {
            Some(Expr::Number(prec.round(prec.round(*a) * prec.round(*b))))
        }
        // x^0 = 1
        ("^", [_, Expr::Number(z)]) if *z == 0.0 => Some(Expr::Number(1.0)),
        // x^1 = x
        ("^", [x, Expr::Number(one)]) if *one == 1.0 => Some(x.clone()),
        // a^b for numbers
        ("^", [Expr::Number(a), Expr::Number(b)]) => Some(Expr::Number(
            crate::simulate_array::apply_binary("^", *a, *b),
        )),
        _ => None,
    };
    folded.unwrap_or(Expr::operator(node))
}

/// Evaluate a scalar AST expression against a map of float variable bindings.
///
/// This is the official ESS Rust runner entry point (the public API exported
/// as `earthsci_ast::evaluate`). The array runtime's per-cell oracle — the
/// binding's one interpreter — does the evaluation, so a single expression
/// means here exactly what it means inside a simulated model.
///
/// `bindings` maps free-variable names to their `f64` values. The special
/// key `"t"` supplies the simulation time (defaults to `0.0` if absent).
/// Returns `Ok(f64)` on success, or `Err(Vec<String>)` listing unbound
/// variable names if any variable in `expr` is missing from `bindings`, or
/// carrying the diagnostic (`unlowered_operator` / `unevaluable_operator`, with
/// the op named) for an operator this evaluator cannot evaluate — including the
/// array, tensor and geometry ops, which have no value over scalar bindings.
/// That check runs over the whole expression before any of it is evaluated
/// (esm-spec §9.6.6). Genuine MATH errors (division by zero, the log of a
/// non-positive number) are not errors: they come back as `NaN` or `±inf` in
/// the `Ok` branch, which is the answer.
///
/// # Examples
///
/// ```
/// use earthsci_ast::{Expr, evaluate};
/// use std::collections::HashMap;
///
/// let expr = Expr::Variable("x".to_string());
/// let mut bindings = HashMap::new();
/// bindings.insert("x".to_string(), 3.14_f64);
/// let result = evaluate(&expr, &bindings).unwrap();
/// assert!((result - 3.14).abs() < 1e-10);
/// ```
pub fn evaluate(expr: &Expr, bindings: &HashMap<String, f64>) -> Result<f64, Vec<String>> {
    let mut unbound: Vec<String> = Vec::new();
    collect_unbound(expr, bindings, &mut unbound);
    if !unbound.is_empty() {
        return Err(unbound);
    }
    let mut names: Vec<String> = bindings.keys().cloned().collect();
    names.sort();
    let values: Vec<f64> = names.iter().map(|n| bindings[n]).collect();
    let t = bindings.get("t").copied().unwrap_or(0.0);
    crate::simulate_array::eval_scalar_expression(expr, &values, &names, t)
        .map_err(|e| vec![e.to_string()])
}

/// Every variable `expr` reads that `bindings` does not bind, in encounter
/// order. `t` is never unbound: the caller supplies it or it defaults.
fn collect_unbound(expr: &Expr, bindings: &HashMap<String, f64>, out: &mut Vec<String>) {
    match expr {
        Expr::Number(_) | Expr::Integer(_) => {}
        Expr::Variable(name) => {
            if name != "t" && !bindings.contains_key(name) {
                out.push(name.clone());
            }
        }
        Expr::Operator(node) => {
            for arg in &node.args {
                collect_unbound(arg, bindings, out);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::substitute::substitute;
    use crate::types::ExpressionNode;
    use std::collections::HashMap;

    #[test]
    fn test_free_variables() {
        let expr = Expr::operator(ExpressionNode {
            op: "+".to_string(),
            args: vec![
                Expr::Variable("x".to_string()),
                Expr::Variable("y".to_string()),
            ],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        let vars = free_variables(&expr);
        assert_eq!(vars.len(), 2);
        assert!(vars.contains("x"));
        assert!(vars.contains("y"));
    }

    #[test]
    fn test_contains() {
        let expr = Expr::operator(ExpressionNode {
            op: "*".to_string(),
            args: vec![Expr::Number(2.0), Expr::Variable("x".to_string())],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        assert!(contains(&expr, "x"));
        assert!(!contains(&expr, "y"));
    }

    #[test]
    fn test_simplify_zero_addition() {
        let expr = Expr::operator(ExpressionNode {
            op: "+".to_string(),
            args: vec![Expr::Variable("x".to_string()), Expr::Number(0.0)],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        let simplified = simplify(&expr);
        match simplified {
            Expr::Variable(name) => assert_eq!(name, "x"),
            _ => panic!("Expected variable 'x'"),
        }
    }

    #[test]
    fn test_simplify_one_multiplication() {
        let expr = Expr::operator(ExpressionNode {
            op: "*".to_string(),
            args: vec![Expr::Number(1.0), Expr::Variable("x".to_string())],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        let simplified = simplify(&expr);
        match simplified {
            Expr::Variable(name) => assert_eq!(name, "x"),
            _ => panic!("Expected variable 'x'"),
        }
    }

    #[test]
    fn test_simplify_zero_multiplication() {
        let expr = Expr::operator(ExpressionNode {
            op: "*".to_string(),
            args: vec![Expr::Number(0.0), Expr::Variable("x".to_string())],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        let simplified = simplify(&expr);
        match simplified {
            Expr::Number(n) => assert_eq!(n, 0.0),
            _ => panic!("Expected number 0"),
        }
    }

    #[test]
    fn test_substitute_variable() {
        let mut bindings = HashMap::new();
        bindings.insert("x".to_string(), Expr::Number(42.0));

        let expr = Expr::Variable("x".to_string());
        let result = substitute(&expr, &bindings);

        match result {
            Expr::Number(n) => assert_eq!(n, 42.0),
            _ => panic!("Expected number"),
        }
    }

    #[test]
    fn test_substitute_no_match() {
        let bindings = HashMap::new();
        let expr = Expr::Variable("y".to_string());
        let result = substitute(&expr, &bindings);

        match result {
            Expr::Variable(name) => assert_eq!(name, "y"),
            _ => panic!("Expected variable"),
        }
    }

    #[test]
    fn test_substitute_in_operator() {
        let mut bindings = HashMap::new();
        bindings.insert("x".to_string(), Expr::Number(2.0));
        bindings.insert("y".to_string(), Expr::Number(3.0));

        let expr = Expr::operator(ExpressionNode {
            op: "+".to_string(),
            args: vec![
                Expr::Variable("x".to_string()),
                Expr::Variable("y".to_string()),
            ],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        let result = substitute(&expr, &bindings);

        match result {
            Expr::Operator(op_node) => {
                assert_eq!(op_node.op, "+");
                assert_eq!(op_node.args.len(), 2);
                match &op_node.args[0] {
                    Expr::Number(n) => assert_eq!(*n, 2.0),
                    _ => panic!("Expected number"),
                }
                match &op_node.args[1] {
                    Expr::Number(n) => assert_eq!(*n, 3.0),
                    _ => panic!("Expected number"),
                }
            }
            _ => panic!("Expected operator"),
        }
    }

    /// A WELL-FORMED operator node for `op`: the minimum arity the registry
    /// admits, plus the sidecar field `op_registry::check_node` insists on for
    /// `broadcast`, so the registry's own checks cannot mask the gate under
    /// test.
    fn node_with_legal_arity(op: &str) -> Expr {
        let arity = crate::op_registry::arity_of(op).expect("registry-legal op");
        let n = (0..=3)
            .find(|n| arity.admits(*n))
            .expect("some arity in 0..=3 is admitted");
        Expr::operator(ExpressionNode {
            op: op.to_string(),
            args: (0..n).map(|_| Expr::Number(1.0)).collect(),
            broadcast_fn: (op == "broadcast").then(|| "+".to_string()),
            ..Default::default()
        })
    }

    /// The §4.2 core set minus what [`evaluate`] answers, pinned member by
    /// member so a rule added or lost is a test diff and not a silent
    /// behaviour change. Every member is refused BY NAME, as
    /// `unevaluable_operator`.
    ///
    /// It is the array oracle's own nine-op gap plus what has no value over
    /// scalar bindings: the array / tensor and geometry ops, an array `const`
    /// (the bare node here carries no value at all), and a structural `D`,
    /// which never legitimately reaches evaluation (esm-spec §4.2) and would
    /// otherwise come back as the oracle's `NaN` sentinel.
    #[test]
    fn the_evaluate_gap_is_pinned() {
        const CORE: &[&str] = &[
            "+",
            "-",
            "*",
            "/",
            "^",
            "neg",
            "exp",
            "log",
            "ln",
            "log10",
            "sqrt",
            "abs",
            "sign",
            "floor",
            "ceil",
            "sin",
            "cos",
            "tan",
            "asin",
            "acos",
            "atan",
            "sinh",
            "cosh",
            "tanh",
            "asinh",
            "acosh",
            "atanh",
            "atan2",
            "min",
            "max",
            "ifelse",
            "==",
            "!=",
            "<",
            "<=",
            ">",
            ">=",
            "and",
            "or",
            "not",
            "D",
            "ic",
            "Pre",
            "const",
            "true",
            "fn",
            "enum",
            "table_lookup",
            "apply_expression_template",
            "faq",
            "makearray",
            "index",
            "broadcast",
            "reshape",
            "transpose",
            "concat",
            "skolem",
            "rank",
            "distinct",
            "argmin",
            "argmax",
            "intersect_polygon",
            "polygon_intersection_area",
        ];
        let mut gap: Vec<&str> = Vec::new();
        for op in CORE {
            assert!(
                crate::op_registry::is_core_op(op),
                "{op} is listed here but the registry does not carry it"
            );
            match crate::simulate_array::check_scalar_evaluable(&node_with_legal_arity(op)) {
                Ok(()) => {}
                Err(crate::compile_error::CompileError::UnevaluableOperatorError { op: got }) => {
                    assert_eq!(&got, op, "the refusal must name the op itself");
                    gap.push(op);
                }
                Err(other) => panic!("{op} must be admitted or refused BY NAME, got {other:?}"),
            }
        }
        gap.sort_unstable();
        assert_eq!(
            gap,
            vec![
                "D",
                "apply_expression_template",
                "argmax",
                "argmin",
                "broadcast",
                "concat",
                "const",
                "distinct",
                "enum",
                "faq",
                "ic",
                "index",
                "intersect_polygon",
                "makearray",
                "polygon_intersection_area",
                "rank",
                "reshape",
                "skolem",
                "table_lookup",
                "transpose",
            ]
        );
    }

    /// The gate is not merely top-level: an op with no scalar value NESTED
    /// inside an otherwise-fine expression is still refused.
    #[test]
    fn a_nested_op_with_no_scalar_value_is_refused_too() {
        let outer = Expr::operator(ExpressionNode {
            op: "+".to_string(),
            args: vec![Expr::Number(1.0), node_with_legal_arity("rank")],
            ..Default::default()
        });
        let err = evaluate(&outer, &HashMap::new()).expect_err("a nested `rank` must not evaluate");
        assert!(
            err.iter()
                .any(|m| m.contains("unevaluable_operator") && m.contains("rank")),
            "{err:?}"
        );
    }

    /// `neg`, `true` and a scalar `const` are §4.2 core ops that Python, Julia
    /// and Go all answer for, so the public `evaluate` answers for them too; an
    /// ARRAY `const` has no scalar value and is refused by name.
    #[test]
    fn neg_true_and_a_scalar_const_evaluate_as_the_other_bindings_do() {
        let node = |op: &str, args: Vec<Expr>, value: Option<serde_json::Value>| {
            Expr::operator(ExpressionNode {
                op: op.to_string(),
                args,
                value,
                ..Default::default()
            })
        };
        let eval = |e: &Expr| evaluate(e, &HashMap::new()).expect("core op with a rule");

        assert_eq!(eval(&node("neg", vec![Expr::Number(3.5)], None)), -3.5);
        assert_eq!(eval(&node("true", Vec::new(), None)), 1.0);
        assert_eq!(
            eval(&node("const", Vec::new(), Some(serde_json::json!(2.5)))),
            2.5
        );

        let err = evaluate(
            &node("const", Vec::new(), Some(serde_json::json!([1.0, 2.0]))),
            &HashMap::new(),
        )
        .expect_err("an array `const` has no scalar value");
        assert!(
            err.iter()
                .any(|m| m.contains("unevaluable_operator") && m.contains("const")),
            "{err:?}"
        );
    }

    /// The scalar-value gate runs BEFORE the §11.3 Float32 gate. The two
    /// geometry ops trip both — `precision::f32_unsupported_reason` names them
    /// — and `unevaluable_operator` is the more fundamental answer: declaring
    /// `Float64` would not make either evaluable over scalar bindings.
    #[test]
    fn the_scalar_value_gate_precedes_the_float32_gate() {
        for op in ["intersect_polygon", "polygon_intersection_area"] {
            assert!(
                crate::precision::f32_unsupported_reason(op, None).is_some(),
                "{op} must be one of the ops that trips BOTH gates, or this pins nothing"
            );
            let _f32 = crate::precision::enter(crate::precision::Precision::Float32);
            let err = crate::simulate_array::check_scalar_evaluable(&node_with_legal_arity(op))
                .expect_err("an op with no scalar value must be refused under Float32 too");
            assert!(
                matches!(
                    err,
                    crate::compile_error::CompileError::UnevaluableOperatorError { op: ref got }
                        if got == op
                ),
                "{op} must report `unevaluable_operator`, not `float32_unsupported`: {err:?}"
            );
        }
    }

    /// A `fn` call's inline table and axis are array `const`s, and they are
    /// what `interp.linear` reads — the gate admits them there, and the call
    /// evaluates.
    #[test]
    fn a_fn_table_argument_is_admitted() {
        let expr: Expr = serde_json::from_value(serde_json::json!({
            "op": "fn",
            "name": "interp.linear",
            "args": [
                { "op": "const", "value": [10.0, 20.0, 40.0], "args": [] },
                { "op": "const", "value": [0.0, 1.0, 2.0], "args": [] },
                "code"
            ]
        }))
        .expect("expression decodes");
        let bindings: HashMap<String, f64> = [("code".to_string(), 1.5)].into_iter().collect();
        assert_eq!(evaluate(&expr, &bindings).expect("evaluates"), 30.0);
    }
}
