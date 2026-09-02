//! Substitution tests matching fixtures
//!
//! Tests the variable and expression substitution functionality.

use earthsci_ast::*;
use indexmap::IndexMap;
use std::collections::HashMap;

/// Run every case in a substitution fixture file. Each fixture is a JSON
/// ARRAY of cases carrying `input`, `bindings`, and `expected` (plus an
/// optional `description`). Every key is REQUIRED: a missing or renamed key —
/// or an empty case list — is a test failure, never a silent pass. (The
/// previous version of these tests probed the fixture root for object keys
/// that do not exist in the array-shaped fixtures, so they asserted nothing.)
fn run_substitution_fixture(name: &str, fixture: &str) {
    let cases: Vec<serde_json::Value> = serde_json::from_str(fixture)
        .unwrap_or_else(|e| panic!("{name}: fixture must be a JSON array of cases: {e}"));
    assert!(!cases.is_empty(), "{name}: fixture has no cases");

    for (i, case) in cases.iter().enumerate() {
        let label = match case.get("description").and_then(|d| d.as_str()) {
            Some(d) => format!("{name}[{i}] ({d})"),
            None => format!("{name}[{i}]"),
        };

        let input: Expr = serde_json::from_value(
            case.get("input")
                .unwrap_or_else(|| panic!("{label}: case key 'input' missing"))
                .clone(),
        )
        .unwrap_or_else(|e| panic!("{label}: failed to parse 'input': {e}"));

        let bindings_obj = case
            .get("bindings")
            .unwrap_or_else(|| panic!("{label}: case key 'bindings' missing"))
            .as_object()
            .unwrap_or_else(|| panic!("{label}: 'bindings' must be an object"));
        let mut substitutions = HashMap::new();
        for (var_name, sub_expr) in bindings_obj {
            let sub: Expr = serde_json::from_value(sub_expr.clone()).unwrap_or_else(|e| {
                panic!("{label}: failed to parse binding for '{var_name}': {e}")
            });
            substitutions.insert(var_name.clone(), sub);
        }

        let expected: Expr = serde_json::from_value(
            case.get("expected")
                .unwrap_or_else(|| panic!("{label}: case key 'expected' missing"))
                .clone(),
        )
        .unwrap_or_else(|e| panic!("{label}: failed to parse 'expected': {e}"));

        let result = substitute(&input, &substitutions);
        assert_eq!(
            serde_json::to_value(&result).expect("Failed to serialize result"),
            serde_json::to_value(&expected).expect("Failed to serialize expected"),
            "{label}: substitution result doesn't match expected"
        );
    }
}

/// Test simple variable replacement
#[test]
fn test_simple_var_replace() {
    run_substitution_fixture(
        "simple_var_replace",
        include_str!("../../../tests/substitution/simple_var_replace.json"),
    );
}

/// Test nested substitution
#[test]
fn test_nested_substitution() {
    run_substitution_fixture(
        "nested_substitution",
        include_str!("../../../tests/substitution/nested_substitution.json"),
    );
}

/// Test scoped reference substitution
#[test]
fn test_scoped_reference() {
    run_substitution_fixture(
        "scoped_reference",
        include_str!("../../../tests/substitution/scoped_reference.json"),
    );
}

/// Test substitution in model context
#[test]
fn test_model_substitution() {
    // Create a simple model for testing
    let mut variables = IndexMap::new();
    variables.insert(
        "x".to_string(),
        ModelVariable {
            default_units: None,
            element_type: None,
            var_type: VariableType::Unknown,
            units: None,
            default: Some(1.0),
            description: None,
            shape: None,
            location: None,
            distribution: None,
            update: None,
        },
    );
    variables.insert(
        "k".to_string(),
        ModelVariable {
            default_units: None,
            element_type: None,
            var_type: VariableType::Parameter,
            units: None,
            default: Some(0.1),
            description: None,
            shape: None,
            location: None,
            distribution: None,
            update: None,
        },
    );
    variables.insert(
        "y".to_string(),
        ModelVariable {
            default_units: None,
            element_type: None,
            var_type: VariableType::Unknown,
            units: None,
            default: Some(0.0),
            description: None,
            shape: None,
            location: None,
            distribution: None,
            update: None,
        },
    );

    let model = Model {
        analyses: None,
        subsystems: None,
        reference: None,
        name: Some("Test Model".to_string()),
        variables,
        equations: vec![Equation {
            comment: None,
            lhs: Expr::operator(ExpressionNode {
                op: "D".to_string(),
                args: vec![Expr::Variable("x".to_string())],
                wrt: Some("t".to_string()),
                dim: None,
                ..Default::default()
            }),
            rhs: Expr::operator(ExpressionNode {
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

    // Check that substitution worked. Every step is a hard requirement: a
    // shape mismatch is a failure, not a silently skipped assertion.
    let equation = result
        .equations
        .first()
        .expect("substituted model must keep its one equation");
    let Expr::Operator(rhs_node) = &equation.rhs else {
        panic!(
            "expected operator RHS after substitution, got {:?}",
            equation.rhs
        );
    };
    let Expr::Number(val) = &rhs_node.args[0] else {
        panic!(
            "expected k substituted with a number, got {:?}",
            rhs_node.args[0]
        );
    };
    assert_eq!(*val, 0.2, "Expected k to be substituted with 0.2");
}

/// Test substitution in reaction system context
#[test]
fn test_reaction_system_substitution() {
    // Create a simple reaction system
    let species = {
        let mut m = indexmap::IndexMap::new();
        m.insert(
            "A".to_string(),
            Species {
                default_units: None,
                units: Some("mol/L".to_string()),
                default: Some(1.0),
                description: None,
                constant: None,
            },
        );
        m.insert(
            "B".to_string(),
            Species {
                default_units: None,
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
        rate: Expr::operator(ExpressionNode {
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
        tolerance: None,
        tests: None,
        analyses: None,
        subsystems: None,
        reference: None,
        species,
        parameters: IndexMap::new(),
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

    // Check that substitution worked. Every step is a hard requirement: a
    // shape mismatch is a failure, not a silently skipped assertion.
    let reaction = result
        .reactions
        .first()
        .expect("substituted reaction system must keep its one reaction");
    let Expr::Operator(rate_node) = &reaction.rate else {
        panic!(
            "expected operator rate after substitution, got {:?}",
            reaction.rate
        );
    };
    let Expr::Number(val) = &rate_node.args[0] else {
        panic!(
            "expected k_rate substituted with a number, got {:?}",
            rate_node.args[0]
        );
    };
    assert_eq!(*val, 1.5, "Expected k_rate to be substituted with 1.5");
}

/// Test complex substitution patterns
#[test]
fn test_complex_substitution_patterns() {
    // Create a complex expression with nested operators
    let complex_expr = Expr::operator(ExpressionNode {
        op: "+".to_string(),
        args: vec![
            Expr::operator(ExpressionNode {
                op: "*".to_string(),
                args: vec![
                    Expr::Variable("a".to_string()),
                    Expr::operator(ExpressionNode {
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
            Expr::operator(ExpressionNode {
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
    let result = substitute(&complex_expr, &substitutions);

    // Verify that substitution occurred in nested structures — at every
    // depth, not just that the top-level shape survived.
    let Expr::Operator(result_node) = &result else {
        panic!("expected operator result, got {result:?}");
    };
    assert_eq!(result_node.args.len(), 3, "Expected 3 arguments in result");
    let Expr::Operator(first_term) = &result_node.args[0] else {
        panic!("expected a*x^2 term, got {:?}", result_node.args[0]);
    };
    assert_eq!(
        first_term.args[0],
        Expr::Number(1.0),
        "a must be substituted inside the first nested term"
    );
    let Expr::Operator(second_term) = &result_node.args[1] else {
        panic!("expected b*x term, got {:?}", result_node.args[1]);
    };
    assert_eq!(
        second_term.args[0],
        Expr::Number(-2.0),
        "b must be substituted inside the second nested term"
    );
    assert_eq!(
        result_node.args[2],
        Expr::Number(1.0),
        "c must be substituted at the top level"
    );
}

/// Test substitution with no-op (identity)
#[test]
fn test_identity_substitution() {
    let expr = Expr::Variable("x".to_string());
    let substitutions = HashMap::new(); // No substitutions

    let result = substitute(&expr, &substitutions);

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

    let result = substitute(&expr, &substitutions);

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

    let result = substitute(&expr, &substitutions);

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

    let result = substitute(&expr, &substitutions);

    assert_eq!(
        result,
        Expr::Variable("x".to_string()),
        "Self-referential binding should yield the same variable (single-pass)"
    );
}

/// Self-referential binding inside a nested operator must also terminate.
#[test]
fn test_substitute_self_reference_in_nested_expression() {
    let expr = Expr::operator(ExpressionNode {
        op: "+".to_string(),
        args: vec![
            Expr::Variable("x".to_string()),
            Expr::operator(ExpressionNode {
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
        Expr::operator(ExpressionNode {
            op: "+".to_string(),
            args: vec![Expr::Variable("x".to_string()), Expr::Number(1.0)],
            ..Default::default()
        }),
    );

    let result = substitute(&expr, &substitutions);

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
    let expr = Expr::operator(ExpressionNode {
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

    let result = substitute(&expr, &substitutions);

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
        expr = Expr::operator(ExpressionNode {
            op: "+".to_string(),
            args: vec![expr, Expr::Variable(format!("v{i}"))],
            ..Default::default()
        });
    }

    let mut substitutions = HashMap::new();
    substitutions.insert("x".to_string(), Expr::Number(1.0));

    let result = substitute(&expr, &substitutions);

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
    let expr = Expr::operator(ExpressionNode {
        op: "+".to_string(),
        args: vec![],
        ..Default::default()
    });
    let mut substitutions = HashMap::new();
    substitutions.insert("x".to_string(), Expr::Variable("y".to_string()));

    let result = substitute(&expr, &substitutions);

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
    let expr = Expr::operator(ExpressionNode {
        op: "*".to_string(),
        args: vec![
            Expr::Variable("x".to_string()),
            Expr::operator(ExpressionNode {
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

    let result = substitute(&expr, &substitutions);

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
    let expr = Expr::operator(ExpressionNode {
        op: "D".to_string(),
        args: vec![Expr::Variable("x".to_string())],
        wrt: Some("t".to_string()),
        dim: Some("time".to_string()),
        ..Default::default()
    });
    let mut substitutions = HashMap::new();
    substitutions.insert("x".to_string(), Expr::Number(2.5));

    let result = substitute(&expr, &substitutions);

    if let Expr::Operator(node) = result {
        assert_eq!(node.op, "D");
        assert_eq!(node.wrt, Some("t".to_string()));
        assert_eq!(node.dim, Some("time".to_string()));
        assert_eq!(node.args[0], Expr::Number(2.5));
    } else {
        panic!("Expected operator result");
    }
}

/// Chained bindings {a -> b, b -> c} rename `a` to `b` — NEVER to `c`.
///
/// Substitution is single-pass (CONFORMANCE_SPEC.md §2.2.3 rule 1), so a
/// binding map doubles as a simultaneous RENAME map. Transitive expansion here
/// would silently corrupt every chained rename.
#[test]
fn test_substitute_chained_binding_is_not_transitive() {
    let expr = Expr::operator(ExpressionNode {
        op: "+".to_string(),
        args: vec![
            Expr::Variable("a".to_string()),
            Expr::Variable("b".to_string()),
        ],
        ..Default::default()
    });
    let mut substitutions = HashMap::new();
    substitutions.insert("a".to_string(), Expr::Variable("b".to_string()));
    substitutions.insert("b".to_string(), Expr::Variable("c".to_string()));

    let result = substitute(&expr, &substitutions);

    let expected = Expr::operator(ExpressionNode {
        op: "+".to_string(),
        args: vec![
            Expr::Variable("b".to_string()),
            Expr::Variable("c".to_string()),
        ],
        ..Default::default()
    });
    assert_eq!(
        result, expected,
        "Chained bindings must not expand transitively: a -> b, not a -> c"
    );
}

/// A mutually-referential binding set applied across a compound expression is
/// a simultaneous SWAP, not a cycle.
#[test]
fn test_substitute_mutual_binding_is_a_simultaneous_swap() {
    let expr = Expr::operator(ExpressionNode {
        op: "-".to_string(),
        args: vec![
            Expr::Variable("a".to_string()),
            Expr::Variable("b".to_string()),
        ],
        ..Default::default()
    });
    let mut substitutions = HashMap::new();
    substitutions.insert("a".to_string(), Expr::Variable("b".to_string()));
    substitutions.insert("b".to_string(), Expr::Variable("a".to_string()));

    let result = substitute(&expr, &substitutions);

    let expected = Expr::operator(ExpressionNode {
        op: "-".to_string(),
        args: vec![
            Expr::Variable("b".to_string()),
            Expr::Variable("a".to_string()),
        ],
        ..Default::default()
    });
    assert_eq!(result, expected, "a<->b must swap, not error or iterate");
}

/// A variable appearing REPEATEDLY is not a cycle: every occurrence in the
/// input is substituted, at every sibling position.
#[test]
fn test_substitute_repeated_variable_is_not_a_cycle() {
    let replacement = Expr::operator(ExpressionNode {
        op: "*".to_string(),
        args: vec![
            Expr::Variable("a".to_string()),
            Expr::Variable("a".to_string()),
        ],
        ..Default::default()
    });
    let expr = Expr::operator(ExpressionNode {
        op: "*".to_string(),
        args: vec![
            Expr::Variable("x".to_string()),
            Expr::Variable("x".to_string()),
        ],
        ..Default::default()
    });
    let mut substitutions = HashMap::new();
    substitutions.insert("x".to_string(), replacement.clone());

    let result = substitute(&expr, &substitutions);

    let expected = Expr::operator(ExpressionNode {
        op: "*".to_string(),
        args: vec![replacement.clone(), replacement],
        ..Default::default()
    });
    assert_eq!(
        result, expected,
        "A repeated variable substitutes at every occurrence"
    );
}
