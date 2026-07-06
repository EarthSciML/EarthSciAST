//! Basic functionality tests
//!
//! Tests basic parsing, serialization, and core functionality with simple valid examples.

use earthsci_toolkit::*;
use std::collections::HashMap;

/// Test basic round-trip with simple valid data
#[test]
fn test_basic_round_trip() {
    let json = r#"
    {
      "esm": "0.1.0",
      "metadata": {
        "name": "test_model"
      },
      "models": {
        "simple": {
          "variables": {},
          "equations": []
        }
      }
    }
    "#;

    let parsed: EsmFile = load(json).expect("Failed to parse basic JSON");
    let serialized = save(&parsed).expect("Failed to serialize back to JSON");
    let reparsed: EsmFile = load(&serialized).expect("Failed to reparse serialized output");

    assert_eq!(parsed.esm, reparsed.esm);
    assert_eq!(parsed.metadata.name, reparsed.metadata.name);
}

/// Test schema validation with missing esm version
#[test]
fn test_missing_esm_version() {
    let json = r#"
    {
      "metadata": {
        "name": "test_model"
      }
    }
    "#;

    let result = load(json);
    assert!(
        result.is_err(),
        "Expected parsing to fail for missing ESM version"
    );

    if let Err(EsmError::SchemaValidation(error)) = result {
        assert!(error.contains("esm") || error.to_lowercase().contains("required"));
    } else {
        panic!("Expected schema validation error");
    }
}

/// Test schema validation with wrong data types
#[test]
fn test_wrong_data_types() {
    let json = r#"
    {
      "esm": 123,
      "metadata": {
        "name": "test_model"
      }
    }
    "#;

    let result = load(json);
    assert!(
        result.is_err(),
        "Expected parsing to fail for wrong data type"
    );
}

/// Test structural validation
#[test]
fn test_structural_validation() {
    // Create a model with equations but no variables (should fail structural validation)
    let variables = HashMap::new();
    let model = Model {
        coupletype: None,
        subsystems: None,
        reference: None,
        name: Some("Test Model".to_string()),
        variables,
        equations: vec![Equation {
            lhs: Expr::Variable("x".to_string()),
            rhs: Expr::Number(1.0),
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

    let mut models = HashMap::new();
    models.insert("test".to_string(), model);

    let esm_file = EsmFile {
        domain: None,
        index_sets: None,
        esm: "0.1.0".to_string(),
        metadata: Metadata {
            name: Some("Test".to_string()),
            description: None,
            authors: None,
            created: None,
            modified: None,
            license: None,
            tags: None,
            references: None,
            system_class: None,
            dae_info: None,
            discretized_from: None,
        },
        models: Some(models),
        reaction_systems: None,
        data_loaders: None,
        operators: None,
        enums: None,

        coupling: None,
        function_tables: None,
    };

    let validation_result = validate(&esm_file);
    assert!(
        !validation_result.structural_errors.is_empty(),
        "Expected structural validation to find errors"
    );
}

/// Test expression operations
#[test]
fn test_expression_operations() {
    let expr = Expr::Operator(ExpressionNode {
        op: "+".to_string(),
        args: vec![Expr::Variable("x".to_string()), Expr::Number(5.0)],
        wrt: None,
        dim: None,
        ..Default::default()
    });

    // Test free variables
    let vars = free_variables(&expr);
    assert!(vars.contains("x"));
    assert_eq!(vars.len(), 1);

    // Test evaluation
    let mut context = HashMap::new();
    context.insert("x".to_string(), 10.0);

    let result = fold_constant_expr(&expr, &context).expect("Failed to evaluate expression");
    assert_eq!(result, 15.0);

    // Test substitution
    let mut substitutions = HashMap::new();
    substitutions.insert("x".to_string(), Expr::Number(20.0));

    let substituted = substitute_in_expression(&expr, &substitutions);
    if let Expr::Operator(node) = substituted
        && let Expr::Number(val) = &node.args[0]
    {
        assert_eq!(*val, 20.0);
    }
}

/// Test stoichiometric matrix generation
#[test]
fn test_stoichiometric_matrix() {
    let mut species = HashMap::new();
    species.insert(
        "A".to_string(),
        Species {
            units: Some("mol/L".to_string()),
            default: Some(1.0),
            description: None,
            constant: None,
        },
    );
    species.insert(
        "B".to_string(),
        Species {
            units: Some("mol/L".to_string()),
            default: Some(0.0),
            description: None,
            constant: None,
        },
    );

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
        rate: Expr::Variable("k".to_string()),
        reference: None,
    }];

    let rs = ReactionSystem {
        subsystems: None,
        coupletype: None,
        reference: None,
        species,
        parameters: HashMap::new(),
        reactions,
        constraint_equations: None,
        discrete_events: None,
        continuous_events: None,
    };

    let matrix = stoichiometric_matrix(&rs);
    assert_eq!(matrix.len(), 2);
    assert_eq!(matrix[0].len(), 1);
    assert_eq!(matrix[0][0], -1.0); // A consumed
    assert_eq!(matrix[1][0], 1.0); // B produced
}

/// Test component graph generation
#[test]
fn test_component_graph() {
    let metadata = Metadata {
        name: Some("Test".to_string()),
        description: None,
        authors: None,
        created: None,
        modified: None,
        license: None,
        tags: None,
        references: None,
        system_class: None,
        dae_info: None,
        discretized_from: None,
    };

    let model = Model {
        coupletype: None,
        subsystems: None,
        reference: None,
        name: Some("TestModel".to_string()),
        variables: HashMap::new(),
        equations: vec![],
        discrete_events: None,
        continuous_events: None,
        description: None,
        tolerance: None,
        tests: None,
        initialization_equations: None,
        guesses: None,
        system_kind: None,
    };

    let mut models = HashMap::new();
    models.insert("test_model".to_string(), model);

    let esm_file = EsmFile {
        domain: None,
        index_sets: None,
        esm: "0.1.0".to_string(),
        metadata,
        models: Some(models),
        reaction_systems: None,
        data_loaders: None,
        operators: None,
        enums: None,

        coupling: None,
        function_tables: None,
    };

    let graph = component_graph(&esm_file);
    assert_eq!(graph.nodes.len(), 1);

    // Test exports
    let dot_output = graph.to_dot();
    assert!(!dot_output.is_empty());
    assert!(dot_output.contains("digraph ComponentGraph"));

    let mermaid_output = graph.to_mermaid();
    assert!(!mermaid_output.is_empty());
}

/// Test pretty printing
#[test]
fn test_pretty_printing() {
    let test_strings = ["H2O", "CO2", "CH4", "NO2", "D", "*", "+"];

    for input in &test_strings {
        // Create simple expressions to test display functions
        let expr = Expr::Variable(input.to_string());

        let unicode_result = to_unicode(&expr);
        let latex_result = to_latex(&expr);
        let ascii_result = to_ascii(&expr);

        assert!(!unicode_result.is_empty());
        assert!(!latex_result.is_empty());
        assert!(!ascii_result.is_empty());
    }
}

/// Test editing operations
#[test]
fn test_editing() {
    let model = Model {
        coupletype: None,
        subsystems: None,
        reference: None,
        name: Some("Test Model".to_string()),
        variables: HashMap::new(),
        equations: vec![],
        discrete_events: None,
        continuous_events: None,
        description: None,
        tolerance: None,
        tests: None,
        initialization_equations: None,
        guesses: None,
        system_kind: None,
    };

    // Test adding variables
    let new_var = ModelVariable {
        var_type: VariableType::Parameter,
        units: Some("s^-1".to_string()),
        default: Some(0.1),
        description: Some("Test rate constant".to_string()),
        expression: None,
        shape: None,
        location: None,
        noise_kind: None,
        correlation_group: None,
    };

    let updated_model = add_variable(&model, "k", new_var).expect("Failed to add variable");
    assert!(updated_model.variables.contains_key("k"));
    assert_eq!(updated_model.variables.len(), 1);
}

/// Test FunctionalAffect structure has all required fields
#[test]
fn test_functional_affect_fields() {
    use serde_json;

    // Test that FunctionalAffect has all required fields
    let functional_affect = FunctionalAffect {
        handler_id: "test_handler".to_string(),
        read_vars: vec!["var1".to_string(), "var2".to_string()],
        read_params: vec!["param1".to_string()],
        modified_params: Some(vec!["param2".to_string()]),
        config: Some(serde_json::json!({
            "threshold": 0.5,
            "update_frequency": 10
        })),
    };

    // Test serialization
    let json = serde_json::to_string_pretty(&functional_affect)
        .expect("Failed to serialize FunctionalAffect");

    // Verify JSON contains required fields
    assert!(json.contains("handler_id"));
    assert!(json.contains("read_vars"));
    assert!(json.contains("read_params"));
    assert!(json.contains("modified_params"));
    assert!(json.contains("config"));

    // Test deserialization
    let deserialized: FunctionalAffect =
        serde_json::from_str(&json).expect("Failed to deserialize FunctionalAffect");

    assert_eq!(deserialized.handler_id, "test_handler");
    assert_eq!(deserialized.read_vars, vec!["var1", "var2"]);
    assert_eq!(deserialized.read_params, vec!["param1"]);
    assert_eq!(
        deserialized.modified_params,
        Some(vec!["param2".to_string()])
    );
    assert!(deserialized.config.is_some());
}

/// Test FunctionalAffect with minimal fields
#[test]
fn test_functional_affect_minimal() {
    use serde_json;

    // Test with only required fields
    let functional_affect = FunctionalAffect {
        handler_id: "minimal_handler".to_string(),
        read_vars: vec!["var1".to_string()],
        read_params: vec!["param1".to_string()],
        modified_params: None,
        config: None,
    };

    // Test serialization - should not include None fields due to skip_serializing_if
    let json = serde_json::to_string_pretty(&functional_affect)
        .expect("Failed to serialize minimal FunctionalAffect");

    // Verify JSON has required fields but not optional ones
    assert!(json.contains("handler_id"));
    assert!(json.contains("read_vars"));
    assert!(json.contains("read_params"));
    // These should be skipped
    assert!(!json.contains("modified_params"));
    assert!(!json.contains("config"));

    // Test deserialization
    let deserialized: FunctionalAffect =
        serde_json::from_str(&json).expect("Failed to deserialize minimal FunctionalAffect");

    assert_eq!(deserialized.handler_id, "minimal_handler");
    assert_eq!(deserialized.read_vars, vec!["var1"]);
    assert_eq!(deserialized.read_params, vec!["param1"]);
    assert_eq!(deserialized.modified_params, None);
    assert_eq!(deserialized.config, None);
}
