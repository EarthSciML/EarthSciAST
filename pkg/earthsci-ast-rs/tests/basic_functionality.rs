//! Basic functionality tests
//!
//! Tests basic parsing, serialization, and core functionality with simple valid examples.

use earthsci_ast::*;
use indexmap::IndexMap;
use std::collections::HashMap;

/// Test basic round-trip with simple valid data
#[test]
fn test_basic_round_trip() {
    let json = r#"
    {
      "esm": "1.0.0",
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

    let parsed: EsmFile = load_string(json).expect("Failed to parse basic JSON");
    let serialized = to_json(&parsed).expect("Failed to serialize back to JSON");
    let reparsed: EsmFile = load_string(&serialized).expect("Failed to reparse serialized output");

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

    let result = load_string(json);
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

    let result = load_string(json);
    assert!(
        result.is_err(),
        "Expected parsing to fail for wrong data type"
    );
}

/// Test structural validation
#[test]
fn test_structural_validation() {
    // Create a model with equations but no variables (should fail structural validation)
    let variables = IndexMap::new();
    let model = Model {
        analyses: None,
        subsystems: None,
        reference: None,
        name: Some("Test Model".to_string()),
        variables,
        equations: vec![Equation {
            comment: None,
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

    let mut models = IndexMap::new();
    models.insert("test".to_string(), model);

    let esm_file = EsmFile {
        component_templates: None,
        coordinates: None,
        expression_templates: None,
        metaparameters: None,
        coupling_roles: None,
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
            x_esd: None,
        },
        models: Some(models),
        reaction_systems: None,
        data_sources: None,
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
    let expr = Expr::operator(ExpressionNode {
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

    let substituted = substitute(&expr, &substitutions);
    if let Expr::Operator(node) = substituted
        && let Expr::Number(val) = &node.args[0]
    {
        assert_eq!(*val, 20.0);
    }
}

/// Test stoichiometric matrix generation
#[test]
fn test_stoichiometric_matrix() {
    let mut species = IndexMap::new();
    species.insert(
        "A".to_string(),
        Species {
            default_units: None,
            units: Some("mol/L".to_string()),
            default: Some(1.0),
            description: None,
            constant: None,
        },
    );
    species.insert(
        "B".to_string(),
        Species {
            default_units: None,
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
        x_esd: None,
    };

    let model = Model {
        analyses: None,
        subsystems: None,
        reference: None,
        name: Some("TestModel".to_string()),
        variables: IndexMap::new(),
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

    let mut models = IndexMap::new();
    models.insert("test_model".to_string(), model);

    let esm_file = EsmFile {
        component_templates: None,
        coordinates: None,
        expression_templates: None,
        metaparameters: None,
        coupling_roles: None,
        domain: None,
        index_sets: None,
        esm: "0.1.0".to_string(),
        metadata,
        models: Some(models),
        reaction_systems: None,
        data_sources: None,
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
        analyses: None,
        subsystems: None,
        reference: None,
        name: Some("Test Model".to_string()),
        variables: IndexMap::new(),
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
        element_type: None,
        default_units: None,
        var_type: VariableType::Parameter,
        units: Some("s^-1".to_string()),
        default: Some(0.1),
        description: Some("Test rate constant".to_string()),
        shape: None,
        location: None,
        distribution: None,
        update: None,
    };

    let updated_model = add_variable(&model, "k", new_var).expect("Failed to add variable");
    assert!(updated_model.variables.contains_key("k"));
    assert_eq!(updated_model.variables.len(), 1);
}

/// A coupling `event` entry carrying either of the two keys esm 1.0.0 removed
/// (RFC unified-variable-model D5) must be REJECTED, not silently dropped.
///
/// The schema's `CouplingEvent` def is `additionalProperties: false` and lists
/// neither `functional_affect` nor `discrete_parameters`, so the refusal lands
/// at the schema layer inside `load_string` — the same layer the Julia oracle
/// refuses them at (`pkg/EarthSciAST.jl/src/coupling_imports.jl` notes the
/// construct is gone; `scripts/migrate-0x-to-1.0.0.py` records either key as a
/// migration BLOCKER rather than rewriting it).
#[test]
fn test_coupling_event_rejects_removed_0x_keys() {
    fn doc(extra: &str) -> String {
        format!(
            r#"{{
              "esm": "1.0.0",
              "metadata": {{ "name": "removed_event_keys" }},
              "models": {{
                "a": {{
                  "variables": {{ "x": {{ "type": "unknown", "units": "1" }} }},
                  "equations": [
                    {{ "lhs": {{ "op": "D", "args": ["x"] }}, "rhs": 1.0 }}
                  ]
                }}
              }},
              "coupling": [
                {{
                  "type": "event",
                  "event_type": "continuous",
                  "conditions": [{{ "op": ">", "args": ["a.x", 1.0] }}],
                  "affects": [{{ "lhs": "a.x", "rhs": 0.0 }}]{extra}
                }}
              ]
            }}"#
        )
    }

    // Control: the same document without either key loads cleanly, so a
    // failure below is attributable to the key and nothing else.
    load_string(&doc("")).expect("baseline coupling event should load");

    for (key, extra) in [
        (
            "functional_affect",
            r#","functional_affect": {"handler_id": "h", "read_vars": [], "read_params": []}"#,
        ),
        ("discrete_parameters", r#","discrete_parameters": ["k"]"#),
    ] {
        let text = doc(extra);

        // (a) `load_string` refuses the document outright.
        let err = load_string(&text)
            .err()
            .unwrap_or_else(|| panic!("coupling event carrying `{key}` must be rejected"));
        assert!(
            matches!(err, EsmError::SchemaValidation(_)),
            "`{key}` should be refused at the schema layer, got: {err:?}"
        );

        // (b) `validate_text` reports it as a per-violation record: the
        // `additionalProperties` keyword at the offending entry's own JSON
        // pointer, naming that key and nothing else. This is the pin — the
        // `oneOf` umbrella record beside it merely quotes the whole instance.
        let result = validate_text(&text, None);
        assert!(
            !result.is_valid,
            "document carrying `{key}` must be invalid"
        );
        let expected = format!("Additional properties are not allowed ('{key}' was unexpected)");
        assert!(
            result.schema_errors.iter().any(|e| e.path == "/coupling/0"
                && e.keyword == "additionalProperties"
                && e.message == expected),
            "expected an additionalProperties record at /coupling/0 naming `{key}`, got: {:?}",
            result.schema_errors
        );
    }
}
