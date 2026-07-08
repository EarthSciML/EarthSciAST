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

fn collect_variables(expr: &Expr, vars: &mut HashSet<String>) {
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
    let folded = match (node.op.as_str(), node.args.as_slice()) {
        // 0 + x = x ; x + 0 = x
        ("+", [Expr::Number(z), x]) | ("+", [x, Expr::Number(z)]) if *z == 0.0 => Some(x.clone()),
        // a + b for numbers
        ("+", [Expr::Number(a), Expr::Number(b)]) => Some(Expr::Number(a + b)),
        // 0 * x = 0 ; x * 0 = 0
        ("*", [Expr::Number(z), _]) | ("*", [_, Expr::Number(z)]) if *z == 0.0 => {
            Some(Expr::Number(0.0))
        }
        // 1 * x = x ; x * 1 = x
        ("*", [Expr::Number(one), x]) | ("*", [x, Expr::Number(one)]) if *one == 1.0 => {
            Some(x.clone())
        }
        // a * b for numbers
        ("*", [Expr::Number(a), Expr::Number(b)]) => Some(Expr::Number(a * b)),
        // x^0 = 1
        ("^", [_, Expr::Number(z)]) if *z == 0.0 => Some(Expr::Number(1.0)),
        // x^1 = x
        ("^", [x, Expr::Number(one)]) if *one == 1.0 => Some(x.clone()),
        // a^b for numbers
        ("^", [Expr::Number(a), Expr::Number(b)]) => Some(Expr::Number(a.powf(*b))),
        _ => None,
    };
    folded.unwrap_or(Expr::Operator(node))
}

/// Evaluate a scalar AST expression against a map of float variable bindings.
///
/// This is the official ESS Rust runner entry point (the public API exported
/// as `earthsci_ast::evaluate`). It delegates to
/// [`crate::simulate::fold_constant_expr`] — the single canonical scalar
/// evaluator for this binding.
///
/// `bindings` maps free-variable names to their `f64` values. The special
/// key `"t"` supplies the simulation time (defaults to `0.0` if absent).
/// Returns `Ok(f64)` on success, or `Err(Vec<String>)` listing unbound
/// variable names if any variable in `expr` is missing from `bindings`.
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
#[cfg(not(target_arch = "wasm32"))]
pub fn evaluate(expr: &Expr, bindings: &HashMap<String, f64>) -> Result<f64, Vec<String>> {
    crate::simulate::fold_constant_expr(expr, bindings)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::substitute::substitute;
    use crate::types::ExpressionNode;
    use std::collections::HashMap;

    #[test]
    fn test_free_variables() {
        let expr = Expr::Operator(ExpressionNode {
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
        let expr = Expr::Operator(ExpressionNode {
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
        let expr = Expr::Operator(ExpressionNode {
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
        let expr = Expr::Operator(ExpressionNode {
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
        let expr = Expr::Operator(ExpressionNode {
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

        let expr = Expr::Operator(ExpressionNode {
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
}
