// Most of these symbols are only used by feature-gated tests (parallel, simd,
// zero_copy, custom_alloc). Under the default feature set only the compact
// expression tests run, so we silence the unused-import warning rather than
// scatter cfg attributes over every import.
#[allow(unused_imports)]
use earthsci_ast::{
    Expr, ExpressionNode, Reaction, ReactionSystem, Species, StoichiometricEntry,
    performance::CompactExpr, types::Parameter,
};
#[allow(unused_imports)]
use std::collections::HashMap;

#[cfg(feature = "parallel")]
use earthsci_ast::performance::ParallelEvaluator;

#[cfg(feature = "simd")]
use earthsci_ast::performance::simd_math;

#[cfg(feature = "custom_alloc")]
use earthsci_ast::performance::ModelAllocator;

#[cfg(feature = "zero_copy")]
use earthsci_ast::performance::fast_parse;

#[test]
fn test_compact_expression_creation() {
    // Test simple expression: x + 1
    let expr = Expr::Operator(earthsci_ast::ExpressionNode {
        op: "+".to_string(),
        args: vec![Expr::Variable("x".to_string()), Expr::Number(1.0)],
        wrt: None,
        dim: None,
        ..Default::default()
    });

    let compact = CompactExpr::from_expr(&expr);

    // Should have 3 nodes: Variable(x), Number(1.0), Operator(+)
    assert_eq!(compact.nodes.len(), 3);
    assert_eq!(compact.var_cache.len(), 1);
    assert!(compact.var_cache.contains_key("x"));
}

#[cfg(feature = "parallel")]
#[test]
fn test_compact_expression_evaluation() {
    use earthsci_ast::performance::CompactExpr;

    // Test simple expression: x + 1
    let expr = Expr::Operator(earthsci_ast::ExpressionNode {
        op: "+".to_string(),
        args: vec![Expr::Variable("x".to_string()), Expr::Number(1.0)],
        wrt: None,
        dim: None,
        ..Default::default()
    });

    let compact = CompactExpr::from_expr(&expr);

    let mut variables = HashMap::new();
    variables.insert("x".to_string(), 5.0);

    let result = compact.evaluate_fast(&variables).unwrap();
    assert_eq!(result, 6.0);
}

#[cfg(feature = "parallel")]
#[test]
fn test_parallel_evaluator_creation() {
    use earthsci_ast::performance::ParallelEvaluator;

    let evaluator = ParallelEvaluator::new(Some(2));
    assert!(evaluator.is_ok());
}

#[cfg(feature = "simd")]
#[test]
fn test_simd_operations() {
    use earthsci_ast::performance::simd_math;

    let a = vec![1.0, 2.0, 3.0, 4.0];
    let b = vec![2.0, 3.0, 4.0, 5.0];
    let mut result = vec![0.0; 4];

    // Test SIMD addition
    simd_math::add_vectors_simd(&a, &b, &mut result).unwrap();
    assert_eq!(result, vec![3.0, 5.0, 7.0, 9.0]);

    // Test SIMD dot product
    let dot = simd_math::dot_product_simd(&a, &b).unwrap();
    assert_eq!(dot, 40.0); // 1*2 + 2*3 + 3*4 + 4*5 = 2 + 6 + 12 + 20 = 40
}

#[cfg(feature = "custom_alloc")]
#[test]
fn test_model_allocator() {
    use earthsci_ast::performance::ModelAllocator;

    let allocator = ModelAllocator::new();
    let slice = allocator.alloc_slice::<f64>(100);
    assert_eq!(slice.len(), 100);

    // All elements should be initialized to default (0.0)
    assert!(slice.iter().all(|&x| x == 0.0));
}

#[cfg(feature = "zero_copy")]
#[test]
fn test_fast_parse() {
    use earthsci_ast::performance::fast_parse;

    let json_data = r#"
    {
        "esm": "0.1.0",
        "metadata": {
            "name": "test"
        }
    }"#;

    let result = fast_parse(json_data);
    assert!(result.is_ok());

    let esm_file = result.unwrap();
    assert_eq!(esm_file.esm, "0.1.0");
    assert_eq!(esm_file.metadata.name, Some("test".to_string()));
}

// ============================================================================
// COMPREHENSIVE ERROR CONDITION TESTS
// ============================================================================

#[cfg(feature = "simd")]
#[test]
fn test_simd_vector_length_mismatch() {
    let a = vec![1.0, 2.0, 3.0];
    let b = vec![4.0, 5.0]; // Different length
    let mut result = vec![0.0; 3];

    let err = simd_math::add_vectors_simd(&a, &b, &mut result);
    assert!(err.is_err());
    assert!(
        err.unwrap_err()
            .to_string()
            .contains("Vector length mismatch")
    );

    let err = simd_math::multiply_vectors_simd(&a, &b, &mut result);
    assert!(err.is_err());

    let err = simd_math::dot_product_simd(&a, &b);
    assert!(err.is_err());
}

#[cfg(feature = "simd")]
#[test]
fn test_simd_result_buffer_size_mismatch() {
    let a = vec![1.0, 2.0, 3.0];
    let b = vec![4.0, 5.0, 6.0];
    let mut result = vec![0.0; 2]; // Too small

    let err = simd_math::add_vectors_simd(&a, &b, &mut result);
    assert!(err.is_err());
    assert!(
        err.unwrap_err()
            .to_string()
            .contains("Vector length mismatch")
    );
}

#[cfg(feature = "parallel")]
#[test]
fn test_compact_expr_evaluation_errors() {
    // Test undefined variable error
    let expr = Expr::Variable("undefined_var".to_string());
    let compact = CompactExpr::from_expr(&expr);
    let variables = HashMap::new();

    let result = compact.evaluate_fast(&variables);
    assert!(result.is_err());
    assert!(
        result
            .unwrap_err()
            .to_string()
            .contains("Undefined variable")
    );

    // Test division by zero
    let expr = Expr::Operator(ExpressionNode {
        op: "/".to_string(),
        args: vec![Expr::Number(1.0), Expr::Number(0.0)],
        wrt: None,
        dim: None,
        ..Default::default()
    });
    let compact = CompactExpr::from_expr(&expr);

    let result = compact.evaluate_fast(&variables);
    assert!(result.is_err());
    assert!(result.unwrap_err().to_string().contains("Division by zero"));

    // Test invalid log argument
    let expr = Expr::Operator(ExpressionNode {
        op: "log".to_string(),
        args: vec![Expr::Number(-1.0)],
        wrt: None,
        dim: None,
        ..Default::default()
    });
    let compact = CompactExpr::from_expr(&expr);

    let result = compact.evaluate_fast(&variables);
    assert!(result.is_err());
    assert!(
        result
            .unwrap_err()
            .to_string()
            .contains("Invalid log argument")
    );
}

#[cfg(feature = "zero_copy")]
#[test]
fn test_fast_parse_invalid_json() {
    let invalid_json = r#"{ invalid json }"#;
    let result = fast_parse(invalid_json);
    assert!(result.is_err());
}

#[cfg(feature = "zero_copy")]
#[test]
fn test_fast_parse_empty_json() {
    let result = fast_parse("");
    assert!(result.is_err());
}

// ============================================================================
// EDGE CASES AND BOUNDARY CONDITIONS
// ============================================================================

#[cfg(feature = "simd")]
#[test]
fn test_simd_operations_empty_vectors() {
    let a: Vec<f64> = vec![];
    let b: Vec<f64> = vec![];
    let mut result: Vec<f64> = vec![];

    // Empty vectors should work
    simd_math::add_vectors_simd(&a, &b, &mut result).unwrap();
    assert_eq!(result.len(), 0);

    let dot = simd_math::dot_product_simd(&a, &b).unwrap();
    assert_eq!(dot, 0.0);
}

#[cfg(feature = "simd")]
#[test]
fn test_simd_operations_single_element() {
    let a = vec![5.0];
    let b = vec![3.0];
    let mut result = vec![0.0];

    simd_math::add_vectors_simd(&a, &b, &mut result).unwrap();
    assert_eq!(result, vec![8.0]);

    simd_math::multiply_vectors_simd(&a, &b, &mut result).unwrap();
    assert_eq!(result, vec![15.0]);

    let dot = simd_math::dot_product_simd(&a, &b).unwrap();
    assert_eq!(dot, 15.0);
}

#[cfg(feature = "simd")]
#[test]
fn test_simd_operations_non_multiple_of_four() {
    // Test with 7 elements (not divisible by 4)
    let a = vec![1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0];
    let b = vec![2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0];
    let mut result = vec![0.0; 7];

    simd_math::add_vectors_simd(&a, &b, &mut result).unwrap();
    assert_eq!(result, vec![3.0, 5.0, 7.0, 9.0, 11.0, 13.0, 15.0]);

    simd_math::multiply_vectors_simd(&a, &b, &mut result).unwrap();
    assert_eq!(result, vec![2.0, 6.0, 12.0, 20.0, 30.0, 42.0, 56.0]);

    let dot = simd_math::dot_product_simd(&a, &b).unwrap();
    assert_eq!(dot, 168.0); // 2+6+12+20+30+42+56 = 168
}

#[cfg(feature = "simd")]
#[test]
fn test_simd_operations_large_vectors() {
    let size = 1000;
    let a: Vec<f64> = (0..size).map(|i| i as f64).collect();
    let b: Vec<f64> = (0..size).map(|i| (i * 2) as f64).collect();
    let mut result = vec![0.0; size];

    // Test addition
    simd_math::add_vectors_simd(&a, &b, &mut result).unwrap();
    for (i, v) in result.iter().enumerate().take(size) {
        assert_eq!(*v, (i * 3) as f64);
    }

    // Test multiplication
    simd_math::multiply_vectors_simd(&a, &b, &mut result).unwrap();
    for (i, v) in result.iter().enumerate().take(size) {
        assert_eq!(*v, (i * i * 2) as f64);
    }

    // Test dot product
    let dot = simd_math::dot_product_simd(&a, &b).unwrap();
    let expected: f64 = (0..size).map(|i| (i * i * 2) as f64).sum();
    assert_eq!(dot, expected);
}

#[cfg(feature = "parallel")]
#[test]
fn test_compact_expr_complex_expressions() {
    // Test complex nested expression: (x + y) * (sin(z) - cos(w))
    let expr = Expr::Operator(ExpressionNode {
        op: "*".to_string(),
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
                    Expr::Operator(ExpressionNode {
                        op: "sin".to_string(),
                        args: vec![Expr::Variable("z".to_string())],
                        wrt: None,
                        dim: None,
                        ..Default::default()
                    }),
                    Expr::Operator(ExpressionNode {
                        op: "cos".to_string(),
                        args: vec![Expr::Variable("w".to_string())],
                        wrt: None,
                        dim: None,
                        ..Default::default()
                    }),
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

    let compact = CompactExpr::from_expr(&expr);
    let mut variables = HashMap::new();
    variables.insert("x".to_string(), 2.0);
    variables.insert("y".to_string(), 3.0);
    variables.insert("z".to_string(), 0.5); // sin(0.5) ≈ 0.479
    variables.insert("w".to_string(), 1.0); // cos(1.0) ≈ 0.540

    let result = compact.evaluate_fast(&variables).unwrap();
    let expected = (2.0 + 3.0) * (0.5_f64.sin() - 1.0_f64.cos());
    assert!((result - expected).abs() < 1e-10);
}

#[cfg(feature = "parallel")]
#[test]
fn test_compact_expr_all_operators() {
    let test_cases = vec![
        ("+", vec![2.0, 3.0], 5.0),
        ("-", vec![7.0, 3.0], 4.0),
        ("*", vec![4.0, 5.0], 20.0),
        ("/", vec![15.0, 3.0], 5.0),
        ("^", vec![2.0, 3.0], 8.0),
        ("**", vec![3.0, 2.0], 9.0),
    ];

    for (op, args, expected) in test_cases {
        let expr = if args.len() == 2 {
            Expr::Operator(ExpressionNode {
                op: op.to_string(),
                args: vec![Expr::Number(args[0]), Expr::Number(args[1])],
                wrt: None,
                dim: None,
                ..Default::default()
            })
        } else {
            continue;
        };

        let compact = CompactExpr::from_expr(&expr);
        let variables = HashMap::new();
        let result = compact.evaluate_fast(&variables).unwrap();
        assert!(
            (result - expected).abs() < 1e-10,
            "Failed for operator {op}: got {result}, expected {expected}"
        );
    }

    // Test unary operators
    let unary_test_cases = vec![
        ("sin", 1.0, 1.0_f64.sin()),
        ("cos", 0.0, 1.0),
        ("exp", 1.0, 1.0_f64.exp()),
        ("log", std::f64::consts::E, 1.0),
    ];

    for (op, arg, expected) in unary_test_cases {
        let expr = Expr::Operator(ExpressionNode {
            op: op.to_string(),
            args: vec![Expr::Number(arg)],
            wrt: None,
            dim: None,
            ..Default::default()
        });

        let compact = CompactExpr::from_expr(&expr);
        let variables = HashMap::new();
        let result = compact.evaluate_fast(&variables).unwrap();
        assert!(
            (result - expected).abs() < 1e-10,
            "Failed for operator {op}: got {result}, expected {expected}"
        );
    }
}

// ============================================================================
// PARALLEL PROCESSING TESTS
// ============================================================================

#[cfg(feature = "parallel")]
#[test]
fn test_parallel_evaluator_different_thread_counts() {
    let thread_counts = vec![1, 2, 4];

    for num_threads in thread_counts {
        let evaluator = ParallelEvaluator::new(Some(num_threads)).unwrap();

        // Test with batch evaluation
        let expressions = vec![Expr::Number(1.0), Expr::Number(2.0), Expr::Number(3.0)];
        let variables = HashMap::new();

        let results = evaluator.evaluate_batch(&expressions, &variables).unwrap();
        assert_eq!(results, vec![1.0, 2.0, 3.0]);
    }
}

#[cfg(feature = "parallel")]
#[test]
fn test_parallel_evaluator_complex_batch() {
    let evaluator = ParallelEvaluator::new(Some(2)).unwrap();

    // Create complex expressions involving variables
    let expressions = vec![
        Expr::Operator(ExpressionNode {
            op: "+".to_string(),
            args: vec![Expr::Variable("x".to_string()), Expr::Number(1.0)],
            wrt: None,
            dim: None,
            ..Default::default()
        }),
        Expr::Operator(ExpressionNode {
            op: "*".to_string(),
            args: vec![Expr::Variable("y".to_string()), Expr::Number(2.0)],
            wrt: None,
            dim: None,
            ..Default::default()
        }),
        Expr::Operator(ExpressionNode {
            op: "sin".to_string(),
            args: vec![Expr::Variable("z".to_string())],
            wrt: None,
            dim: None,
            ..Default::default()
        }),
    ];

    let mut variables = HashMap::new();
    variables.insert("x".to_string(), 5.0);
    variables.insert("y".to_string(), 3.0);
    variables.insert("z".to_string(), 0.5);

    let results = evaluator.evaluate_batch(&expressions, &variables).unwrap();
    assert_eq!(results.len(), 3);
    assert_eq!(results[0], 6.0); // x + 1 = 5 + 1 = 6
    assert_eq!(results[1], 6.0); // y * 2 = 3 * 2 = 6
    assert!((results[2] - 0.5_f64.sin()).abs() < 1e-10); // sin(z) = sin(0.5)
}

#[cfg(feature = "parallel")]
#[test]
fn test_parallel_stoichiometric_matrix_computation() {
    let evaluator = ParallelEvaluator::new(Some(2)).unwrap();

    // Create a simple reaction system: A + B -> C (species are keyed by name)
    let mut species = HashMap::new();
    species.insert(
        "A".to_string(),
        Species {
            units: Some("mol".to_string()),
            default: Some(1.0),
            description: None,
            constant: None,
        },
    );
    species.insert(
        "B".to_string(),
        Species {
            units: Some("mol".to_string()),
            default: Some(1.0),
            description: None,
            constant: None,
        },
    );
    species.insert(
        "C".to_string(),
        Species {
            units: Some("mol".to_string()),
            default: Some(0.0),
            description: None,
            constant: None,
        },
    );

    let reactions = vec![Reaction {
        id: None,
        name: Some("R1".to_string()),
        substrates: Some(vec![
            StoichiometricEntry {
                species: "A".to_string(),
                coefficient: 1.0,
            },
            StoichiometricEntry {
                species: "B".to_string(),
                coefficient: 1.0,
            },
        ]),
        products: Some(vec![StoichiometricEntry {
            species: "C".to_string(),
            coefficient: 1.0,
        }]),
        rate: Expr::Number(1.0),
        reference: None,
    }];

    let mut parameters = HashMap::new();
    // Add a simple parameter if needed
    parameters.insert(
        "k1".to_string(),
        Parameter {
            units: Some("1/s".to_string()),
            default: Some(1.0),
            description: None,
        },
    );

    let system = ReactionSystem {
        subsystems: None,
        coupletype: None,
        reference: None,
        species,
        parameters,
        reactions,
        constraint_equations: None,
        discrete_events: None,
        continuous_events: None,
    };

    let matrix = evaluator
        .compute_stoichiometric_matrix_parallel(&system)
        .unwrap();

    // Matrix should be 3x1 (3 species, 1 reaction)
    assert_eq!(matrix.len(), 3);
    assert_eq!(matrix[0].len(), 1);

    // A: -1 (substrate), B: -1 (substrate), C: +1 (product)
    assert_eq!(matrix[0][0], -1.0); // A
    assert_eq!(matrix[1][0], -1.0); // B
    assert_eq!(matrix[2][0], 1.0); // C
}

// ============================================================================
// MEMORY ALLOCATION TESTS
// ============================================================================

#[cfg(feature = "custom_alloc")]
#[test]
fn test_model_allocator_with_capacity() {
    let capacity = 1024;
    let allocator = ModelAllocator::with_capacity(capacity);

    // Bump allocators may pre-allocate, so bytes_before might be > 0
    let bytes_before = allocator.allocated_bytes();

    // Allocate some memory
    let slice = allocator.alloc_slice::<f64>(100);
    let bytes_after = allocator.allocated_bytes();

    // The allocator should have allocated the slice successfully
    assert_eq!(slice.len(), 100);

    // Test that allocated bytes reflect memory usage
    // (Note: Some allocators may not change allocated_bytes until a threshold is reached)
    assert!(
        bytes_after >= bytes_before,
        "Expected allocated_bytes to be >= {bytes_before} but was {bytes_after}"
    );

    // Test that we can allocate more memory
    let _slice2 = allocator.alloc_slice::<i32>(200);
    let bytes_after_second = allocator.allocated_bytes();
    assert!(
        bytes_after_second >= bytes_after,
        "Expected allocated_bytes after second allocation to be >= {bytes_after} but was {bytes_after_second}"
    );
}

#[cfg(feature = "custom_alloc")]
#[test]
fn test_model_allocator_reset() {
    let mut allocator = ModelAllocator::new();

    // Allocate memory
    let _slice1 = allocator.alloc_slice::<f64>(50);
    let _bytes_after_first_alloc = allocator.allocated_bytes();

    // Reset allocator
    allocator.reset();

    // Allocate again after reset - should work fine
    let _slice2 = allocator.alloc_slice::<f64>(25);
    let bytes_after_reset_and_realloc = allocator.allocated_bytes();

    // The allocator should be functioning after reset
    // Note: bump allocators typically don't free memory on reset,
    // they just reset the allocation pointer
    assert!(bytes_after_reset_and_realloc > 0);

    // Test that we can allocate different sizes after reset
    let _slice3 = allocator.alloc_slice::<i32>(100);
    assert!(allocator.allocated_bytes() >= bytes_after_reset_and_realloc);
}

#[cfg(feature = "custom_alloc")]
#[test]
fn test_model_allocator_large_allocations() {
    let allocator = ModelAllocator::new();

    // Test various data types
    let float_slice = allocator.alloc_slice::<f64>(1000);
    assert_eq!(float_slice.len(), 1000);
    assert!(float_slice.iter().all(|&x| x == 0.0));

    let int_slice = allocator.alloc_slice::<i32>(500);
    assert_eq!(int_slice.len(), 500);
    assert!(int_slice.iter().all(|&x| x == 0));

    let bool_slice = allocator.alloc_slice::<bool>(200);
    assert_eq!(bool_slice.len(), 200);
    assert!(bool_slice.iter().all(|&x| !x));
}

// ============================================================================
// INTEGRATION TESTS WITH REAL ESM DATA
// ============================================================================

#[cfg(feature = "zero_copy")]
#[test]
fn test_fast_parse_complete_esm_file() {
    let complex_json = r#"
    {
        "esm": "0.1.0",
        "metadata": {
            "name": "complex_model",
            "description": "A complex test model"
        },
        "models": {
            "chemistry": {
                "variables": {
                    "temperature": {
                        "type": "state",
                        "units": "K",
                        "description": "Temperature"
                    }
                },
                "equations": [
                    {
                        "lhs": "d(temperature)/dt",
                        "rhs": "heating_rate"
                    }
                ],
                "parameters": {
                    "heating_rate": {
                        "type": "parameter",
                        "units": "K/s",
                        "description": "Heating rate"
                    }
                }
            }
        }
    }"#;

    let result = fast_parse(complex_json).unwrap();

    assert_eq!(result.esm, "0.1.0");
    assert_eq!(result.metadata.name, Some("complex_model".to_string()));
    assert!(result.models.as_ref().unwrap().contains_key("chemistry"));
}

// ============================================================================
// PERFORMANCE COMPARISON TESTS (when both features are enabled)
// ============================================================================

#[cfg(all(feature = "zero_copy", not(feature = "zero_copy")))]
#[test]
fn test_parse_performance_comparison() {
    // This test would compare simd-json vs regular serde_json
    // but requires careful setup - leaving as placeholder for now
}

#[test]
fn test_compact_expr_variable_caching() {
    // Test that variable cache works correctly with multiple variables
    let expr = Expr::Operator(ExpressionNode {
        op: "+".to_string(),
        args: vec![
            Expr::Operator(ExpressionNode {
                op: "*".to_string(),
                args: vec![
                    Expr::Variable("x".to_string()),
                    Expr::Variable("x".to_string()), // Same variable used twice
                ],
                wrt: None,
                dim: None,
                ..Default::default()
            }),
            Expr::Variable("y".to_string()),
        ],
        wrt: None,
        dim: None,
        ..Default::default()
    });

    let compact = CompactExpr::from_expr(&expr);

    // Should have cached both variables
    assert_eq!(compact.var_cache.len(), 2);
    assert!(compact.var_cache.contains_key("x"));
    assert!(compact.var_cache.contains_key("y"));

    // Test evaluation: x * x + y
    #[cfg(feature = "parallel")]
    {
        let mut variables = HashMap::new();
        variables.insert("x".to_string(), 3.0);
        variables.insert("y".to_string(), 4.0);

        let result = compact.evaluate_fast(&variables).unwrap();
        assert_eq!(result, 13.0); // 3*3 + 4 = 9 + 4 = 13
    }
}
