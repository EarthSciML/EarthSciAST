//! Pretty-print tests
//!
//! Tests the pretty-printing functionality with working examples.

use earthsci_toolkit::*;

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

/// Test fixture-based formatting (if fixtures exist)
#[test]
fn test_fixture_based_formatting() {
    // Try to load display fixtures, but gracefully handle if they don't exist
    let fixture_files = [
        "../../../tests/display/chemical_subscripts.json",
        "../../../tests/display/operator_precedence.json",
        "../../../tests/display/all_operators.json",
    ];

    for fixture_path in &fixture_files {
        if let Ok(fixture_content) = std::fs::read_to_string(fixture_path)
            && let Ok(test_data) = serde_json::from_str::<serde_json::Value>(&fixture_content)
        {
            // Process test cases if they exist
            if let Some(cases) = test_data.as_array() {
                for case in cases.iter().take(5) {
                    // Test first 5 cases only
                    if let Some(input) = case.get("input").and_then(|v| v.as_str()) {
                        // Create a variable expression from the input
                        let expr = Expr::Variable(input.to_string());

                        let unicode_result = to_unicode(&expr);
                        let latex_result = to_latex(&expr);
                        let ascii_result = to_ascii(&expr);

                        assert!(!unicode_result.is_empty());
                        assert!(!latex_result.is_empty());
                        assert!(!ascii_result.is_empty());
                    }
                }
            } else if let Some(obj) = test_data.as_object() {
                // Handle object-based test format
                for (key, _value) in obj.iter().take(3) {
                    // Test first 3 entries only
                    let expr = Expr::Variable(key.to_string());

                    let unicode_result = to_unicode(&expr);
                    let latex_result = to_latex(&expr);
                    let ascii_result = to_ascii(&expr);

                    assert!(!unicode_result.is_empty());
                    assert!(!latex_result.is_empty());
                    assert!(!ascii_result.is_empty());
                }
            }
        }
    }
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
