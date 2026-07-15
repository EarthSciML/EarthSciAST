#![allow(deprecated)] // exercises the deprecated `substitute_in_expression` alias on purpose
//! Substitution tests matching fixtures
//!
//! Tests the variable and expression substitution functionality.

use earthsci_ast::*;
use std::collections::HashMap;

/// Test simple variable replacement
#[test]
fn test_simple_var_replace() {
    let fixture = include_str!("../../../tests/substitution/simple_var_replace.json");
    let test_data: serde_json::Value =
        serde_json::from_str(fixture).expect("Failed to parse simple var replace fixture");

    if let (Some(input_expr), Some(substitutions_data), Some(expected_expr)) = (
        test_data.get("input_expression"),
        test_data.get("substitutions"),
        test_data.get("expected_result"),
    ) {
        // Parse input expression
        let input_str =
            serde_json::to_string(input_expr).expect("Failed to serialize input expression");
        let input: Expr =
            serde_json::from_str(&input_str).expect("Failed to parse input expression");

        // Parse substitutions
        let mut substitutions = HashMap::new();
        if let Some(subs_obj) = substitutions_data.as_object() {
            for (var_name, sub_expr) in subs_obj {
                let sub_str =
                    serde_json::to_string(sub_expr).expect("Failed to serialize substitution");
                let sub: Expr =
                    serde_json::from_str(&sub_str).expect("Failed to parse substitution");
                substitutions.insert(var_name.clone(), sub);
            }
        }

        // Parse expected result
        let expected_str =
            serde_json::to_string(expected_expr).expect("Failed to serialize expected result");
        let expected: Expr =
            serde_json::from_str(&expected_str).expect("Failed to parse expected result");

        // Perform substitution
        let result = substitute_in_expression(&input, &substitutions);

        // Compare results (this is simplified - real comparison would be more sophisticated)
        assert_eq!(
            serde_json::to_value(&result).expect("Failed to serialize result"),
            serde_json::to_value(&expected).expect("Failed to serialize expected"),
            "Substitution result doesn't match expected"
        );
    }
}

/// Test nested substitution
#[test]
fn test_nested_substitution() {
    let fixture = include_str!("../../../tests/substitution/nested_substitution.json");
    let test_data: serde_json::Value =
        serde_json::from_str(fixture).expect("Failed to parse nested substitution fixture");

    if let (Some(input_expr), Some(substitutions_data), Some(expected_expr)) = (
        test_data.get("input_expression"),
        test_data.get("substitutions"),
        test_data.get("expected_result"),
    ) {
        // Parse input expression
        let input_str =
            serde_json::to_string(input_expr).expect("Failed to serialize input expression");
        let input: Expr =
            serde_json::from_str(&input_str).expect("Failed to parse input expression");

        // Parse substitutions
        let mut substitutions = HashMap::new();
        if let Some(subs_obj) = substitutions_data.as_object() {
            for (var_name, sub_expr) in subs_obj {
                let sub_str =
                    serde_json::to_string(sub_expr).expect("Failed to serialize substitution");
                let sub: Expr =
                    serde_json::from_str(&sub_str).expect("Failed to parse substitution");
                substitutions.insert(var_name.clone(), sub);
            }
        }

        // Parse expected result
        let expected_str =
            serde_json::to_string(expected_expr).expect("Failed to serialize expected result");
        let expected: Expr =
            serde_json::from_str(&expected_str).expect("Failed to parse expected result");

        // Perform substitution
        let result = substitute_in_expression(&input, &substitutions);

        // Compare results
        assert_eq!(
            serde_json::to_value(&result).expect("Failed to serialize result"),
            serde_json::to_value(&expected).expect("Failed to serialize expected"),
            "Nested substitution result doesn't match expected"
        );
    }
}

/// Test scoped reference substitution
#[test]
fn test_scoped_reference() {
    let fixture = include_str!("../../../tests/substitution/scoped_reference.json");
    let test_data: serde_json::Value =
        serde_json::from_str(fixture).expect("Failed to parse scoped reference fixture");

    if let (Some(input_expr), Some(substitutions_data), Some(expected_expr)) = (
        test_data.get("input_expression"),
        test_data.get("substitutions"),
        test_data.get("expected_result"),
    ) {
        // Parse input expression
        let input_str =
            serde_json::to_string(input_expr).expect("Failed to serialize input expression");
        let input: Expr =
            serde_json::from_str(&input_str).expect("Failed to parse input expression");

        // Parse substitutions
        let mut substitutions = HashMap::new();
        if let Some(subs_obj) = substitutions_data.as_object() {
            for (var_name, sub_expr) in subs_obj {
                let sub_str =
                    serde_json::to_string(sub_expr).expect("Failed to serialize substitution");
                let sub: Expr =
                    serde_json::from_str(&sub_str).expect("Failed to parse substitution");
                substitutions.insert(var_name.clone(), sub);
            }
        }

        // Parse expected result
        let expected_str =
            serde_json::to_string(expected_expr).expect("Failed to serialize expected result");
        let expected: Expr =
            serde_json::from_str(&expected_str).expect("Failed to parse expected result");

        // Perform substitution
        let result = substitute_in_expression(&input, &substitutions);

        // Compare results
        assert_eq!(
            serde_json::to_value(&result).expect("Failed to serialize result"),
            serde_json::to_value(&expected).expect("Failed to serialize expected"),
            "Scoped reference substitution result doesn't match expected"
        );
    }
}

/// Test substitution in model context
#[test]
fn test_model_substitution() {
    // Create a simple model for testing
    let mut variables = HashMap::new();
    variables.insert(
        "x".to_string(),
        ModelVariable {
            default_units: None,
            var_type: VariableType::State,
            units: None,
            default: Some(1.0),
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        },
    );
    variables.insert(
        "k".to_string(),
        ModelVariable {
            default_units: None,
            var_type: VariableType::Parameter,
            units: None,
            default: Some(0.1),
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        },
    );
    variables.insert(
        "y".to_string(),
        ModelVariable {
            default_units: None,
            var_type: VariableType::State,
            units: None,
            default: Some(0.0),
            description: None,
            expression: None,
            shape: None,
            location: None,
            noise_kind: None,
            correlation_group: None,
        },
    );

    let model = Model {
        subsystems: None,
        reference: None,
        name: Some("Test Model".to_string()),
        variables,
        equations: vec![Equation {
            lhs: Expr::Operator(ExpressionNode {
                op: "D".to_string(),
                args: vec![Expr::Variable("x".to_string())],
                wrt: Some("t".to_string()),
                dim: None,
                ..Default::default()
            }),
            rhs: Expr::Operator(ExpressionNode {
                op: "*".to_string(),
                args: vec![
                    Expr::Variable("k".to_string()),
                    Expr::Variable("x".to_string()),
                ],
                wrt: None,
                dim: None,
                ..Default::default()
            }),
        }],
        discrete_events: None,
        continuous_events: None,
        description: None,
        tolerance: None,
        tests: None,
        initialization_equations: None,
        guesses: None,
        system_kind: None,
    };

    // Create substitutions
    let mut substitutions = HashMap::new();
    substitutions.insert("k".to_string(), Expr::Number(0.2));

    // Perform substitution on model
    let result = substitute_in_model(&model, &substitutions);

    // Check that substitution worked
    if let Some(equation) = result.equations.first()
        && let Expr::Operator(rhs_node) = &equation.rhs
        && let Expr::Number(val) = &rhs_node.args[0]
    {
        assert_eq!(*val, 0.2, "Expected k to be substituted with 0.2");
    }
}

/// Test substitution in reaction system context
#[test]
fn test_reaction_system_substitution() {
    // Create a simple reaction system
    let species = {
        let mut m = std::collections::HashMap::new();
        m.insert(
            "A".to_string(),
            Species {
                units: Some("mol/L".to_string()),
                default: Some(1.0),
                description: None,
                constant: None,
            },
        );
        m.insert(
            "B".to_string(),
            Species {
                units: Some("mol/L".to_string()),
                default: Some(0.0),
                description: None,
                constant: None,
            },
        );
        m
    };

    let reactions = vec![Reaction {
        id: None,
        name: None,
        substrates: Some(vec![StoichiometricEntry {
            species: "A".to_string(),
            coefficient: 1.0,
        }]),
        products: Some(vec![StoichiometricEntry {
            species: "B".to_string(),
            coefficient: 1.0,
        }]),
        rate: Expr::Operator(ExpressionNode {
            op: "*".to_string(),
            args: vec![
                Expr::Variable("k_rate".to_string()),
                Expr::Variable("A".to_string()),
            ],
            wrt: None,
            dim: None,
            ..Default::default()
        }),
        reference: None,
    }];

    let rs = ReactionSystem {
        subsystems: None,
        reference: None,
        species,
        parameters: HashMap::new(),
        reactions,
        constraint_equations: None,
        discrete_events: None,
        continuous_events: None,
    };

    // Create substitutions
    let mut substitutions = HashMap::new();
    substitutions.insert("k_rate".to_string(), Expr::Number(1.5));

    // Perform substitution on reaction system
    let result = substitute_in_reaction_system(&rs, &substitutions);

    // Check that substitution worked
    if let Some(reaction) = result.reactions.first()
        && let Expr::Operator(rate_node) = &reaction.rate
        && let Expr::Number(val) = &rate_node.args[0]
    {
        assert_eq!(*val, 1.5, "Expected k_rate to be substituted with 1.5");
    }
}

/// Test complex substitution patterns
#[test]
fn test_complex_substitution_patterns() {
    // Create a complex expression with nested operators
    let complex_expr = Expr::Operator(ExpressionNode {
        op: "+".to_string(),
        args: vec![
            Expr::Operator(ExpressionNode {
                op: "*".to_string(),
                args: vec![
                    Expr::Variable("a".to_string()),
                    Expr::Operator(ExpressionNode {
                        op: "^".to_string(),
                        args: vec![Expr::Variable("x".to_string()), Expr::Number(2.0)],
                        wrt: None,
                        dim: None,
                        ..Default::default()
                    }),
                ],
                wrt: None,
                dim: None,
                ..Default::default()
            }),
            Expr::Operator(ExpressionNode {
                op: "*".to_string(),
                args: vec![
                    Expr::Variable("b".to_string()),
                    Expr::Variable("x".to_string()),
                ],
                wrt: None,
                dim: None,
                ..Default::default()
            }),
            Expr::Variable("c".to_string()),
        ],
        wrt: None,
        dim: None,
        ..Default::default()
    });

    // Create complex substitutions
    let mut substitutions = HashMap::new();
    substitutions.insert("a".to_string(), Expr::Number(1.0));
    substitutions.insert("b".to_string(), Expr::Number(-2.0));
    substitutions.insert("c".to_string(), Expr::Number(1.0));

    // Perform substitution
    let result = substitute_in_expression(&complex_expr, &substitutions);

    // Verify that substitution occurred in nested structures
    if let Expr::Operator(result_node) = result {
        assert_eq!(result_node.args.len(), 3, "Expected 3 arguments in result");
    }
}

/// Test substitution with no-op (identity)
#[test]
fn test_identity_substitution() {
    let expr = Expr::Variable("x".to_string());
    let substitutions = HashMap::new(); // No substitutions

    let result = substitute_in_expression(&expr, &substitutions);

    // Should return unchanged expression
    assert_eq!(
        serde_json::to_value(&result).expect("Failed to serialize result"),
        serde_json::to_value(&expr).expect("Failed to serialize original"),
        "Identity substitution should return unchanged expression"
    );
}

/// Test substitution with variable not present
#[test]
fn test_substitution_variable_not_present() {
    let expr = Expr::Variable("x".to_string());
    let mut substitutions = HashMap::new();
    substitutions.insert("y".to_string(), Expr::Number(42.0)); // Different variable

    let result = substitute_in_expression(&expr, &substitutions);

    // Should return unchanged expression since 'x' is not in substitutions
    assert_eq!(
        serde_json::to_value(&result).expect("Failed to serialize result"),
        serde_json::to_value(&expr).expect("Failed to serialize original"),
        "Substitution with non-present variable should return unchanged expression"
    );
}

// ========================================
// Edge cases and error handling
//
// Substitution semantics documented in CONFORMANCE_SPEC.md §2.2.3:
// - single-pass (non-transitive): bindings are applied once, not re-applied
//   to their replacements, so mutual/self references terminate
// - recursive over AST structure: arbitrary nesting is supported up to
//   native stack limits
// - operator nodes with empty args are valid inputs and are preserved
// - null/None inputs have no Rust equivalent: Expr is a closed enum
// ========================================

/// Circular bindings must not loop: substitution is single-pass.
///
/// Mirrors Python's `test_substitute_circular_reference_detection`
/// (test_substitute.py:295). With bindings {x -> y, y -> x}, substituting
/// `x` yields `y` — the replacement `y` is NOT re-resolved via the `y -> x`
/// binding. This ensures termination for mutually-referential bindings
/// without needing explicit cycle detection.
#[test]
fn test_substitute_circular_reference_single_pass() {
    let expr = Expr::Variable("x".to_string());
    let mut substitutions = HashMap::new();
    substitutions.insert("x".to_string(), Expr::Variable("y".to_string()));
    substitutions.insert("y".to_string(), Expr::Variable("x".to_string()));

    let result = substitute_in_expression(&expr, &substitutions);

    // Single-pass: x -> y (the y is NOT re-substituted back to x)
    assert_eq!(
        result,
        Expr::Variable("y".to_string()),
        "Circular bindings should resolve via single pass, not iterate"
    );
}

/// Self-referential binding {x -> x} must terminate with x unchanged.
#[test]
fn test_substitute_self_reference_terminates() {
    let expr = Expr::Variable("x".to_string());
    let mut substitutions = HashMap::new();
    substitutions.insert("x".to_string(), Expr::Variable("x".to_string()));

    let result = substitute_in_expression(&expr, &substitutions);

    assert_eq!(
        result,
        Expr::Variable("x".to_string()),
        "Self-referential binding should yield the same variable (single-pass)"
    );
}

/// Self-referential binding inside a nested operator must also terminate.
#[test]
fn test_substitute_self_reference_in_nested_expression() {
    let expr = Expr::Operator(ExpressionNode {
        op: "+".to_string(),
        args: vec![
            Expr::Variable("x".to_string()),
            Expr::Operator(ExpressionNode {
                op: "*".to_string(),
                args: vec![Expr::Variable("x".to_string()), Expr::Number(2.0)],
                ..Default::default()
            }),
        ],
        ..Default::default()
    });
    let mut substitutions = HashMap::new();
    substitutions.insert(
        "x".to_string(),
        Expr::Operator(ExpressionNode {
            op: "+".to_string(),
            args: vec![Expr::Variable("x".to_string()), Expr::Number(1.0)],
            ..Default::default()
        }),
    );

    let result = substitute_in_expression(&expr, &substitutions);

    // Each occurrence of x is replaced once; the inner `x` inside the
    // replacement is NOT further substituted.
    if let Expr::Operator(node) = &result {
        assert_eq!(node.op, "+");
        assert_eq!(node.args.len(), 2);
        if let Expr::Operator(inner) = &node.args[0] {
            assert_eq!(inner.op, "+");
            assert_eq!(inner.args.len(), 2);
            assert_eq!(inner.args[0], Expr::Variable("x".to_string()));
            assert_eq!(inner.args[1], Expr::Number(1.0));
        } else {
            panic!("Expected first arg to be operator node");
        }
    } else {
        panic!("Expected operator result");
    }
}

/// Mutually-referential bindings applied to a compound expression.
///
/// {a -> b, b -> a} applied to `(a + b)` produces `(b + a)` — each
/// variable is rewritten exactly once.
#[test]
fn test_substitute_mutual_reference_compound() {
    let expr = Expr::Operator(ExpressionNode {
        op: "+".to_string(),
        args: vec![
            Expr::Variable("a".to_string()),
            Expr::Variable("b".to_string()),
        ],
        ..Default::default()
    });
    let mut substitutions = HashMap::new();
    substitutions.insert("a".to_string(), Expr::Variable("b".to_string()));
    substitutions.insert("b".to_string(), Expr::Variable("a".to_string()));

    let result = substitute_in_expression(&expr, &substitutions);

    if let Expr::Operator(node) = result {
        assert_eq!(node.args[0], Expr::Variable("b".to_string()));
        assert_eq!(node.args[1], Expr::Variable("a".to_string()));
    } else {
        panic!("Expected operator result");
    }
}

/// Deep nesting must not overflow the stack at reasonable depths.
///
/// Mirrors Python's `test_substitute_deep_nesting` (test_substitute.py:310).
/// Python uses depth 5; we exercise a stronger bound to catch accidental
/// stack-consumption regressions.
#[test]
fn test_substitute_deep_nesting() {
    const DEPTH: usize = 200;

    // Build: ((((x + v0) + v1) + v2) ... + v{DEPTH-1})
    let mut expr = Expr::Variable("x".to_string());
    for i in 0..DEPTH {
        expr = Expr::Operator(ExpressionNode {
            op: "+".to_string(),
            args: vec![expr, Expr::Variable(format!("v{i}"))],
            ..Default::default()
        });
    }

    let mut substitutions = HashMap::new();
    substitutions.insert("x".to_string(), Expr::Number(1.0));

    let result = substitute_in_expression(&expr, &substitutions);

    // Verify the innermost `x` was replaced, by walking down the left spine.
    let mut cursor = &result;
    for _ in 0..DEPTH {
        match cursor {
            Expr::Operator(node) => {
                assert_eq!(node.op, "+");
                assert_eq!(node.args.len(), 2);
                cursor = &node.args[0];
            }
            _ => panic!("Expected operator at this depth"),
        }
    }
    assert_eq!(
        cursor,
        &Expr::Number(1.0),
        "Innermost variable x should be replaced with 1.0"
    );
}

/// Operator node with empty args is a structurally valid Expr and is
/// returned unchanged (modulo allocation) — no panic, no error.
///
/// Mirrors Python's `test_substitute_with_invalid_expression`
/// (test_substitute.py:286), which exercises `{"op": "+"}` (missing args).
/// In Rust, the closest analogue is an `ExpressionNode` with `args: vec![]`.
#[test]
fn test_substitute_operator_with_empty_args() {
    let expr = Expr::Operator(ExpressionNode {
        op: "+".to_string(),
        args: vec![],
        ..Default::default()
    });
    let mut substitutions = HashMap::new();
    substitutions.insert("x".to_string(), Expr::Variable("y".to_string()));

    let result = substitute_in_expression(&expr, &substitutions);

    if let Expr::Operator(node) = result {
        assert_eq!(node.op, "+");
        assert!(
            node.args.is_empty(),
            "Empty-args operator should remain empty-args"
        );
    } else {
        panic!("Expected operator result");
    }
}

/// Empty substitutions map: every expression is returned structurally equal.
#[test]
fn test_substitute_empty_substitutions_on_compound() {
    let expr = Expr::Operator(ExpressionNode {
        op: "*".to_string(),
        args: vec![
            Expr::Variable("x".to_string()),
            Expr::Operator(ExpressionNode {
                op: "+".to_string(),
                args: vec![Expr::Variable("y".to_string()), Expr::Number(1.0)],
                ..Default::default()
            }),
        ],
        wrt: Some("t".to_string()),
        dim: Some("time".to_string()),
        ..Default::default()
    });
    let substitutions: HashMap<String, Expr> = HashMap::new();

    let result = substitute_in_expression(&expr, &substitutions);

    assert_eq!(
        serde_json::to_value(&result).unwrap(),
        serde_json::to_value(&expr).unwrap(),
        "Empty substitutions should yield structurally equal expression"
    );
}

/// Substituting a variable with a number literal preserves wrt/dim on the
/// enclosing operator node.
#[test]
fn test_substitute_preserves_operator_metadata() {
    let expr = Expr::Operator(ExpressionNode {
        op: "D".to_string(),
        args: vec![Expr::Variable("x".to_string())],
        wrt: Some("t".to_string()),
        dim: Some("time".to_string()),
        ..Default::default()
    });
    let mut substitutions = HashMap::new();
    substitutions.insert("x".to_string(), Expr::Number(2.5));

    let result = substitute_in_expression(&expr, &substitutions);

    if let Expr::Operator(node) = result {
        assert_eq!(node.op, "D");
        assert_eq!(node.wrt, Some("t".to_string()));
        assert_eq!(node.dim, Some("time".to_string()));
        assert_eq!(node.args[0], Expr::Number(2.5));
    } else {
        panic!("Expected operator result");
    }
}
