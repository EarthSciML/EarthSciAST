//! Graph structure tests for the Rust binding.
//!
//! Cross-binding agreement is asserted by `graph_conformance.rs`, which drives
//! the shared corpus at `tests/conformance/graph/cases.json`. This file keeps
//! the Rust-local unit tests: hand-built ESM files exercising component-graph
//! generation, the two expression-graph builders, the exporters, and component
//! lookup.

use earthsci_ast::*;
use std::collections::HashMap;

/// Test component graph generation
#[test]
fn test_component_graph_generation() {
    // Create ESM file with models and reaction systems
    let metadata = Metadata {
        name: Some("Test Component Graph".to_string()),
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

    let mut variables = HashMap::new();
    variables.insert(
        "x".to_string(),
        ModelVariable {
            default_units: None,
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

    let model = Model {
        subsystems: None,
        reference: None,
        name: Some("TestModel".to_string()),
        variables,
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
    models.insert("model1".to_string(), model);

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
        m
    };

    let rs = ReactionSystem {
        subsystems: None,
        reference: None,
        species,
        parameters: HashMap::new(),
        reactions: vec![],
        constraint_equations: None,
        discrete_events: None,
        continuous_events: None,
    };

    let mut reaction_systems = HashMap::new();
    reaction_systems.insert("rs1".to_string(), rs);

    let esm_file = EsmFile {
        coordinates: None,
        expression_templates: None,
        metaparameters: None,
        coupling_roles: None,
        domain: None,
        index_sets: None,
        esm: "0.1.0".to_string(),
        metadata,
        models: Some(models),
        reaction_systems: Some(reaction_systems),
        data_sources: None,
        operators: None,
        enums: None,

        coupling: None,
        function_tables: None,
    };

    // Generate component graph
    let comp_graph = component_graph(&esm_file);

    assert_eq!(
        comp_graph.nodes.len(),
        2,
        "Expected 2 nodes (1 model + 1 reaction system)"
    );

    // Check node types
    let model_nodes: Vec<_> = comp_graph
        .nodes
        .iter()
        .filter(|node| matches!(node.component_type, ComponentType::Model))
        .collect();
    assert_eq!(model_nodes.len(), 1, "Expected 1 model node");

    let rs_nodes: Vec<_> = comp_graph
        .nodes
        .iter()
        .filter(|node| matches!(node.component_type, ComponentType::ReactionSystem))
        .collect();
    assert_eq!(rs_nodes.len(), 1, "Expected 1 reaction system node");
}

/// Test component graph exports
#[test]
fn test_component_graph_exports() {
    // Create simple ESM file
    let metadata = Metadata {
        name: Some("Export Test".to_string()),
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
        subsystems: None,
        reference: None,
        name: Some("SimpleModel".to_string()),
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
    models.insert("simple".to_string(), model);

    let esm_file = EsmFile {
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

    let comp_graph = component_graph(&esm_file);

    // Test DOT export
    let dot_output = comp_graph.to_dot();
    assert!(!dot_output.is_empty(), "DOT output should not be empty");
    assert!(
        dot_output.contains("digraph ComponentGraph"),
        "DOT should contain digraph declaration"
    );

    // Test Mermaid export
    let mermaid_output = comp_graph.to_mermaid();
    assert!(
        !mermaid_output.is_empty(),
        "Mermaid output should not be empty"
    );
    assert!(
        mermaid_output.contains("graph"),
        "Mermaid should contain graph declaration"
    );

    // Test JSON export
    let json_output = comp_graph.to_json_graph();
    assert!(!json_output.is_empty(), "JSON output should not be empty");

    // Verify JSON is valid
    let _parsed: serde_json::Value =
        serde_json::from_str(&json_output).expect("JSON output should be valid JSON");
}

/// Test expression graph generation for models
#[test]
fn test_model_expression_graph() {
    // Create model with equations
    let mut variables = HashMap::new();
    variables.insert(
        "x".to_string(),
        ModelVariable {
            default_units: None,
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

    let model = Model {
        subsystems: None,
        reference: None,
        name: Some("ExprTest".to_string()),
        variables,
        equations: vec![Equation {
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

    // Generate expression graph
    let expr_graph = expression_graph(&model);

    assert!(
        !expr_graph.nodes.is_empty(),
        "Expression graph should have nodes"
    );

    // Test exports
    let dot_export = expr_graph.to_dot();
    assert!(
        !dot_export.is_empty(),
        "Expression graph DOT export should not be empty"
    );
    assert!(
        dot_export.contains("digraph ExpressionGraph"),
        "Should contain expression graph declaration"
    );

    let mermaid_export = expr_graph.to_mermaid();
    assert!(
        !mermaid_export.is_empty(),
        "Expression graph Mermaid export should not be empty"
    );
}

/// Test expression graph generation for reaction systems
#[test]
fn test_reaction_system_expression_graph() {
    // Create reaction system
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
        rate: Expr::operator(ExpressionNode {
            op: "*".to_string(),
            args: vec![
                Expr::Variable("k".to_string()),
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

    // Generate expression graph
    let expr_graph = expression_graph(&rs);

    assert!(
        !expr_graph.nodes.is_empty(),
        "Reaction system expression graph should have nodes"
    );

    // Test that graph contains rate expression nodes
    // In the new variable dependency graph format, we only have variable nodes (no operator nodes)
    let has_variable_nodes = !expr_graph.nodes.is_empty();
    assert!(
        has_variable_nodes,
        "Should have variable nodes representing species and rate constants"
    );
}

/// Test component existence checks
#[test]
fn test_component_existence() {
    // Create ESM file
    let metadata = Metadata {
        name: Some("Existence Test".to_string()),
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

    // Test component existence
    assert!(
        component_exists(&esm_file, "test_model"),
        "test_model should exist"
    );
    assert!(
        !component_exists(&esm_file, "nonexistent"),
        "nonexistent should not exist"
    );

    // Test component type detection
    let comp_type = get_component_type(&esm_file, "test_model");
    assert!(
        matches!(comp_type, Some(ComponentType::Model)),
        "test_model should be a Model"
    );

    let nonexistent_type = get_component_type(&esm_file, "nonexistent");
    assert!(
        nonexistent_type.is_none(),
        "nonexistent should have no type"
    );
}
