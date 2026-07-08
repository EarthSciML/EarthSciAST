//! Pretty-print tests
//!
//! Tests the pretty-printing functionality with working examples.

use earthsci_ast::*;

/// Test basic expression formatting
#[test]
fn test_basic_expression_formatting() {
    let expressions = [
        Expr::Variable("H2O".to_string()),
        Expr::Variable("CO2".to_string()),
        Expr::Variable("CH4".to_string()),
        Expr::Number(42.0),
        Expr::Operator(ExpressionNode {
            op: "+".to_string(),
            args: vec![Expr::Variable("x".to_string()), Expr::Number(1.0)],
            wrt: None,
            dim: None,
            ..Default::default()
        }),
    ];

    for expr in &expressions {
        let unicode_result = to_unicode(expr);
        let latex_result = to_latex(expr);
        let ascii_result = to_ascii(expr);

        assert!(
            !unicode_result.is_empty(),
            "Unicode formatting should not be empty"
        );
        assert!(
            !latex_result.is_empty(),
            "LaTeX formatting should not be empty"
        );
        assert!(
            !ascii_result.is_empty(),
            "ASCII formatting should not be empty"
        );
    }
}

/// Test operator formatting
#[test]
fn test_operator_formatting() {
    let operators = ["+", "-", "*", "/", "^", "D", "sin", "cos", "exp", "log"];

    for op in &operators {
        let expr = Expr::Operator(ExpressionNode {
            op: op.to_string(),
            args: vec![Expr::Variable("x".to_string())],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        let unicode_result = to_unicode(&expr);
        let latex_result = to_latex(&expr);
        let ascii_result = to_ascii(&expr);

        assert!(
            !unicode_result.is_empty(),
            "Unicode formatting for {op} should not be empty"
        );
        assert!(
            !latex_result.is_empty(),
            "LaTeX formatting for {op} should not be empty"
        );
        assert!(
            !ascii_result.is_empty(),
            "ASCII formatting for {op} should not be empty"
        );
    }
}

/// Test chemical formula formatting
#[test]
fn test_chemical_formula_formatting() {
    let chemicals = ["H2O", "CO2", "CH4", "NO2", "O3", "NH3", "SO2"];

    for chemical in &chemicals {
        let expr = Expr::Variable(chemical.to_string());

        let unicode_result = to_unicode(&expr);
        let latex_result = to_latex(&expr);
        let ascii_result = to_ascii(&expr);

        // Unicode should handle subscripts for chemical formulas
        assert!(!unicode_result.is_empty());
        // LaTeX should format chemical formulas appropriately
        assert!(!latex_result.is_empty());
        // ASCII should provide fallback formatting
        assert!(!ascii_result.is_empty());
    }
}

/// Test complex expression formatting
#[test]
fn test_complex_expression_formatting() {
    // Create a complex expression: k * (A + B)^2
    let complex_expr = Expr::Operator(ExpressionNode {
        op: "*".to_string(),
        args: vec![
            Expr::Variable("k".to_string()),
            Expr::Operator(ExpressionNode {
                op: "^".to_string(),
                args: vec![
                    Expr::Operator(ExpressionNode {
                        op: "+".to_string(),
                        args: vec![
                            Expr::Variable("A".to_string()),
                            Expr::Variable("B".to_string()),
                        ],
                        wrt: None,
                        dim: None,
                        ..Default::default()
                    }),
                    Expr::Number(2.0),
                ],
                wrt: None,
                dim: None,
                ..Default::default()
            }),
        ],
        wrt: None,
        dim: None,
        ..Default::default()
    });

    let unicode_result = to_unicode(&complex_expr);
    let latex_result = to_latex(&complex_expr);
    let ascii_result = to_ascii(&complex_expr);

    assert!(!unicode_result.is_empty());
    assert!(!latex_result.is_empty());
    assert!(!ascii_result.is_empty());

    // Unicode should handle superscripts and proper parentheses
    assert!(unicode_result.contains("A") && unicode_result.contains("B"));
    // LaTeX should include proper formatting commands
    assert!(latex_result.contains("A") && latex_result.contains("B"));
}

/// Test derivative expression formatting
#[test]
fn test_derivative_formatting() {
    let derivative_expr = Expr::Operator(ExpressionNode {
        op: "D".to_string(),
        args: vec![Expr::Variable("x".to_string())],
        wrt: Some("t".to_string()),
        dim: None,
        ..Default::default()
    });

    let unicode_result = to_unicode(&derivative_expr);
    let latex_result = to_latex(&derivative_expr);
    let ascii_result = to_ascii(&derivative_expr);

    assert!(!unicode_result.is_empty());
    assert!(!latex_result.is_empty());
    assert!(!ascii_result.is_empty());

    // Should properly format derivatives with partial derivative symbols
    assert!(unicode_result.contains("∂") && unicode_result.contains("t"));
}

/// Test number formatting
#[test]
fn test_number_formatting() {
    let numbers = [1.0, -1.0, 42.0, 3.15159, 1.23e-6, 1.23e15, 0.0];

    for &num in &numbers {
        let expr = Expr::Number(num);

        let unicode_result = to_unicode(&expr);
        let latex_result = to_latex(&expr);
        let ascii_result = to_ascii(&expr);

        assert!(!unicode_result.is_empty());
        assert!(!latex_result.is_empty());
        assert!(!ascii_result.is_empty());

        // All formats should contain some representation of the number
        let num_str = num.to_string();
        let has_number_representation = unicode_result.contains(&num_str) ||
            unicode_result.chars().any(|c| c.is_ascii_digit()) ||
            unicode_result.contains("×") || // Scientific notation
            unicode_result.contains("e"); // Exponential notation
        assert!(
            has_number_representation,
            "Number {num} should be represented in unicode output"
        );
    }
}

/// Exact-match conformance against the shared cross-language display fixtures.
///
/// Every `input` is deserialized into the real [`Expr`] AST and its
/// `to_unicode` / `to_latex` / `to_ascii` renderings MUST equal the fixture
/// strings byte-for-byte. This is the enforcement of the frozen rendering
/// contract (`tests/display/RENDERING_CONTRACT.md`); the reference
/// implementation is `pkg/earthsci-ast-ts/src/pretty-print.ts`.
#[test]
fn test_display_fixtures_exact() {
    let fixtures = [
        "../../tests/display/structural_ops.json",
        "../../tests/display/comprehensive_operators.json",
    ];

    let mut failures: Vec<String> = Vec::new();
    let mut checked = 0usize;

    for path in &fixtures {
        let content = std::fs::read_to_string(path)
            .unwrap_or_else(|e| panic!("cannot read required fixture {path}: {e}"));
        let groups: serde_json::Value =
            serde_json::from_str(&content).unwrap_or_else(|e| panic!("invalid JSON in {path}: {e}"));
        let groups = groups
            .as_array()
            .unwrap_or_else(|| panic!("fixture {path} is not a JSON array"));

        for group in groups {
            let Some(tests) = group.get("tests").and_then(|t| t.as_array()) else {
                continue;
            };
            for test in tests {
                let name = test.get("name").and_then(|v| v.as_str()).unwrap_or("<unnamed>");
                let input = test
                    .get("input")
                    .unwrap_or_else(|| panic!("{path} :: {name}: missing `input`"));
                let expr: Expr = serde_json::from_value(input.clone()).unwrap_or_else(|e| {
                    panic!("{path} :: {name}: cannot deserialize input into Expr: {e}")
                });

                for (fmt, rendered) in [
                    ("unicode", to_unicode(&expr)),
                    ("latex", to_latex(&expr)),
                    ("ascii", to_ascii(&expr)),
                ] {
                    let Some(expected) = test.get(fmt).and_then(|v| v.as_str()) else {
                        continue;
                    };
                    checked += 1;
                    if rendered != expected {
                        failures.push(format!(
                            "  [{fmt}] {name}\n    input:    {input}\n    expected: {expected:?}\n    actual:   {rendered:?}"
                        ));
                    }
                }
            }
        }
    }

    assert!(
        failures.is_empty(),
        "{} of {} display renderings did not byte-match the fixtures:\n{}",
        failures.len(),
        checked,
        failures.join("\n")
    );
    assert!(checked > 0, "no fixture assertions ran — check fixture paths");
}

/// Test that display functions handle edge cases gracefully
#[test]
fn test_edge_cases() {
    let edge_cases = [
        Expr::Variable("123".to_string()),   // Numeric variable name
        Expr::Variable("x_y_z".to_string()), // Underscores
        Expr::Variable("long_variable_name_with_many_underscores".to_string()),
        Expr::Operator(ExpressionNode {
            op: "unknown_op".to_string(),
            args: vec![Expr::Variable("x".to_string())],
            wrt: None,
            dim: None,
            ..Default::default()
        }),
    ];

    for expr in &edge_cases {
        let unicode_result = to_unicode(expr);
        let latex_result = to_latex(expr);
        let ascii_result = to_ascii(expr);

        // Should not crash or return empty strings
        assert!(!unicode_result.is_empty());
        assert!(!latex_result.is_empty());
        assert!(!ascii_result.is_empty());
    }
}

// ---------------------------------------------------------------------------
// LaTeX \frac rendering for the division operator (folded in from the former
// test_proper_division.rs single-topic file).
// ---------------------------------------------------------------------------

#[test]
fn test_division_latex_frac() {
    // Test simple binary division: a / b should render as \frac{a}{b}
    let division_expr = Expr::Operator(ExpressionNode {
        op: "/".to_string(),
        args: vec![
            Expr::Variable("a".to_string()),
            Expr::Variable("b".to_string()),
        ],
        wrt: None,
        dim: None,
        ..Default::default()
    });

    let latex_result = to_latex(&division_expr);
    assert_eq!(
        latex_result, "\\frac{a}{b}",
        "Simple division should render as \\frac{{}}{{}}"
    );

    // Test with numbers: 1 / 2
    let number_division = Expr::Operator(ExpressionNode {
        op: "/".to_string(),
        args: vec![Expr::Number(1.0), Expr::Number(2.0)],
        wrt: None,
        dim: None,
        ..Default::default()
    });

    let latex_result = to_latex(&number_division);
    assert_eq!(
        latex_result, "\\frac{1}{2}",
        "Number division should render as \\frac{{}}{{}}"
    );

    // Test nested expressions in division: (x + y) / (z - w)
    let nested_division = Expr::Operator(ExpressionNode {
        op: "/".to_string(),
        args: vec![
            Expr::Operator(ExpressionNode {
                op: "+".to_string(),
                args: vec![
                    Expr::Variable("x".to_string()),
                    Expr::Variable("y".to_string()),
                ],
                wrt: None,
                dim: None,
                ..Default::default()
            }),
            Expr::Operator(ExpressionNode {
                op: "-".to_string(),
                args: vec![
                    Expr::Variable("z".to_string()),
                    Expr::Variable("w".to_string()),
                ],
                wrt: None,
                dim: None,
                ..Default::default()
            }),
        ],
        wrt: None,
        dim: None,
        ..Default::default()
    });

    let latex_result = to_latex(&nested_division);
    assert_eq!(
        latex_result, "\\frac{x + y}{z - w}",
        "Nested division should render as \\frac{{}}{{}}"
    );

    // Test single argument division (edge case) - should use fallback
    let single_arg_division = Expr::Operator(ExpressionNode {
        op: "/".to_string(),
        args: vec![Expr::Variable("x".to_string())],
        wrt: None,
        dim: None,
        ..Default::default()
    });

    let latex_result = to_latex(&single_arg_division);
    assert_eq!(
        latex_result, "\\div(x)",
        "Single argument division should use \\div fallback"
    );

    // Test empty argument division (edge case)
    let empty_division = Expr::Operator(ExpressionNode {
        op: "/".to_string(),
        args: vec![],
        wrt: None,
        dim: None,
        ..Default::default()
    });

    let latex_result = to_latex(&empty_division);
    assert_eq!(
        latex_result, "\\div()",
        "Empty division should use \\div fallback"
    );
}

#[test]
fn test_division_in_complex_expressions() {
    // Test division within multiplication: a * (b / c)
    let complex_expr = Expr::Operator(ExpressionNode {
        op: "*".to_string(),
        args: vec![
            Expr::Variable("a".to_string()),
            Expr::Operator(ExpressionNode {
                op: "/".to_string(),
                args: vec![
                    Expr::Variable("b".to_string()),
                    Expr::Variable("c".to_string()),
                ],
                wrt: None,
                dim: None,
                ..Default::default()
            }),
        ],
        wrt: None,
        dim: None,
        ..Default::default()
    });

    let latex_result = to_latex(&complex_expr);
    assert_eq!(
        latex_result, "a \\cdot \\frac{b}{c}",
        "Division in multiplication should render correctly"
    );

    // Test nested divisions: (a / b) / c = \frac{a/b}{c} = \frac{\frac{a}{b}}{c}
    let nested_divisions = Expr::Operator(ExpressionNode {
        op: "/".to_string(),
        args: vec![
            Expr::Operator(ExpressionNode {
                op: "/".to_string(),
                args: vec![
                    Expr::Variable("a".to_string()),
                    Expr::Variable("b".to_string()),
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

    let latex_result = to_latex(&nested_divisions);
    assert_eq!(
        latex_result, "\\frac{\\frac{a}{b}}{c}",
        "Nested divisions should render correctly"
    );
}
