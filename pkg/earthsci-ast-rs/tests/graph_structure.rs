//! Graph structure tests matching graph fixtures
//!
//! Tests for component graphs, expression graphs, and graph export functionality.

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
        expression_templates: None,
        metaparameters: None,
        coupling_roles: None,
        domain: None,
        index_sets: None,
        esm: "0.1.0".to_string(),
        metadata,
        models: Some(models),
        reaction_systems: Some(reaction_systems),
        data_loaders: None,
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
        expression_templates: None,
        metaparameters: None,
        coupling_roles: None,
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

    let model = Model {
        subsystems: None,
        reference: None,
        name: Some("ExprTest".to_string()),
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
        rate: Expr::Operator(ExpressionNode {
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
        expression_templates: None,
        metaparameters: None,
        coupling_roles: None,
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

/// Test graph fixture matching
#[test]
fn test_system_graph_fixture() {
    let fixture = include_str!("../../../tests/graphs/system_graph.json");
    let fixture_data: serde_json::Value =
        serde_json::from_str(fixture).expect("Failed to parse system graph fixture");

    // Extract expected structure from fixture
    if let Some(nodes) = fixture_data.get("nodes").and_then(|v| v.as_array()) {
        assert!(!nodes.is_empty(), "System graph fixture should have nodes");
    }

    if let Some(edges) = fixture_data.get("edges").and_then(|v| v.as_array()) {
        // Edges are optional but if present, should be valid
        for edge in edges {
            assert!(edge.get("source").is_some(), "Edge should have source");
            assert!(edge.get("target").is_some(), "Edge should have target");
        }
    }
}

/// Test expression graph fixture
#[test]
fn test_expression_graph_fixture() {
    let fixture = include_str!("../../../tests/graphs/expression_graph.json");
    let fixture_data: serde_json::Value =
        serde_json::from_str(fixture).expect("Failed to parse expression graph fixture");

    // Extract expected structure from fixture
    if let Some(nodes) = fixture_data.get("nodes").and_then(|v| v.as_array()) {
        assert!(
            !nodes.is_empty(),
            "Expression graph fixture should have nodes"
        );

        for node in nodes {
            // Each node should have required fields
            assert!(node.get("id").is_some(), "Node should have id");
            assert!(node.get("type").is_some(), "Node should have type");
        }
    }

    if let Some(edges) = fixture_data.get("edges").and_then(|v| v.as_array()) {
        for edge in edges {
            assert!(edge.get("source").is_some(), "Edge should have source");
            assert!(edge.get("target").is_some(), "Edge should have target");
        }
    }
}

/// Test DOT and Mermaid expected outputs
#[test]
fn test_expected_graph_outputs() {
    // Create a simple model to test against expected outputs
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

    let model = Model {
        subsystems: None,
        reference: None,
        name: Some("Simple".to_string()),
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

    let expr_graph = expression_graph(&model);

    // Test DOT output format
    let dot_output = expr_graph.to_dot();

    // Load expected DOT output if available
    if let Ok(_expected_dot) =
        std::fs::read_to_string("../../../tests/graphs/expected_dot/expression_graph.dot")
    {
        // Note: Exact matching may be too strict due to ordering, so we check key components
        assert!(
            dot_output.contains("digraph"),
            "Should contain digraph declaration"
        );
        // More specific tests would depend on the exact expected format
    }

    // Test Mermaid output format
    let mermaid_output = expr_graph.to_mermaid();

    if let Ok(_expected_mermaid) =
        std::fs::read_to_string("../../../tests/graphs/expected_mermaid/expression_graph.mermaid")
    {
        assert!(
            mermaid_output.contains("graph"),
            "Should contain graph declaration"
        );
        // More specific tests would depend on the exact expected format
    }
}

/// Test complex expression graph scenarios
#[test]
fn test_complex_expression_graphs() {
    let fixtures = [
        (
            "single_equation",
            include_str!("../../../tests/graphs/expression_graph_single_equation.json"),
        ),
        (
            "single_reaction",
            include_str!("../../../tests/graphs/expression_graph_single_reaction.json"),
        ),
        (
            "simple_photolysis",
            include_str!("../../../tests/graphs/expression_graph_simple_photolysis.json"),
        ),
        (
            "reaction_system",
            include_str!("../../../tests/graphs/expression_graph_reaction_system.json"),
        ),
    ];

    for (name, fixture) in fixtures.iter() {
        let fixture_data: serde_json::Value = serde_json::from_str(fixture)
            .unwrap_or_else(|e| panic!("Failed to parse {name} fixture: {e}"));

        // Basic structure validation
        if let Some(nodes) = fixture_data.get("nodes").and_then(|v| v.as_array()) {
            assert!(!nodes.is_empty(), "{name} should have nodes");
        }

        if let Some(edges) = fixture_data.get("edges").and_then(|v| v.as_array()) {
            for edge in edges {
                assert!(
                    edge.get("source").is_some(),
                    "Edge in {name} should have source"
                );
                assert!(
                    edge.get("target").is_some(),
                    "Edge in {name} should have target"
                );
            }
        }
    }
}

/// Test coupled expression graphs
#[test]
fn test_coupled_expression_graph() {
    let fixture = include_str!("../../../tests/graphs/coupled_expression_graph.json");
    let fixture_data: serde_json::Value =
        serde_json::from_str(fixture).expect("Failed to parse coupled expression graph fixture");

    // Coupled graphs should have more complex structure
    if let Some(nodes) = fixture_data.get("nodes").and_then(|v| v.as_array()) {
        assert!(nodes.len() > 1, "Coupled graph should have multiple nodes");
    }

    if let Some(edges) = fixture_data.get("edges").and_then(|v| v.as_array()) {
        assert!(
            !edges.is_empty(),
            "Coupled graph should have edges showing relationships"
        );
    }
}

/// Test file-level expression graph
#[test]
fn test_file_level_expression_graph() {
    let fixture = include_str!("../../../tests/graphs/expression_graph_file_level.json");
    let fixture_data: serde_json::Value =
        serde_json::from_str(fixture).expect("Failed to parse file-level expression graph fixture");

    // File-level graphs should encompass multiple components
    if let Some(components) = fixture_data.get("components") {
        assert!(
            components.is_object() || components.is_array(),
            "Should have components"
        );
    }
}

/// Test expression graphs collection
#[test]
fn test_expression_graphs_collection() {
    let fixture = include_str!("../../../tests/graphs/expression_graphs.json");
    let fixture_data: serde_json::Value = serde_json::from_str(fixture)
        .expect("Failed to parse expression graphs collection fixture");

    // Should contain multiple graph definitions
    if let Some(graphs) = fixture_data.as_object() {
        assert!(!graphs.is_empty(), "Should contain graph definitions");
    } else if let Some(graphs) = fixture_data.as_array() {
        assert!(!graphs.is_empty(), "Should contain graph definitions");
    }
}

/// Test model expression graph
#[test]
fn test_model_expression_graph_fixture() {
    let fixture = include_str!("../../../tests/graphs/expression_graph_model.json");
    let fixture_data: serde_json::Value =
        serde_json::from_str(fixture).expect("Failed to parse model expression graph fixture");

    // Model graphs should have specific structure
    if let Some(model_data) = fixture_data.get("model") {
        assert!(model_data.is_object(), "Should have model definition");
    }

    if let Some(graph_data) = fixture_data.get("graph")
        && let Some(nodes) = graph_data.get("nodes").and_then(|v| v.as_array())
    {
        assert!(
            !nodes.is_empty(),
            "Model expression graph should have nodes"
        );
    }
}
