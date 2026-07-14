#![allow(deprecated)] // exercises the deprecated `substitute_in_expression` alias on purpose
use earthsci_ast::*;

#[test]
fn test_analysis_features_integration() {
    // Use a simpler test that bypasses schema validation
    use std::collections::HashMap;

    let metadata = crate::types::Metadata {
        name: Some("test_model".to_string()),
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
        name: Some("Simple Model".to_string()),
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

    let mut models = HashMap::new();
    models.insert("simple".to_string(), model);

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

    let mut reaction_systems = HashMap::new();
    reaction_systems.insert("simple_rs".to_string(), rs);

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

    // Test component graph
    let comp_graph = component_graph(&esm_file);
    assert_eq!(comp_graph.nodes.len(), 2); // 1 model + 1 reaction system

    // Test export formats
    let dot_export = comp_graph.to_dot();
    assert!(!dot_export.is_empty());
    assert!(dot_export.contains("digraph ComponentGraph"));

    let mermaid_export = comp_graph.to_mermaid();
    assert!(!mermaid_export.is_empty());
    assert!(mermaid_export.contains("graph LR"));

    let json_export = comp_graph.to_json_graph();
    assert!(!json_export.is_empty());

    // Test expression graph for model
    if let Some(ref models) = esm_file.models
        && let Some(model) = models.get("simple")
    {
        let expr_graph = expression_graph(model);
        assert!(!expr_graph.nodes.is_empty());

        let expr_dot = expr_graph.to_dot();
        assert!(!expr_dot.is_empty());
        assert!(expr_dot.contains("digraph ExpressionGraph"));
    }

    // Test reaction system analysis
    if let Some(ref reaction_systems) = esm_file.reaction_systems
        && let Some(rs) = reaction_systems.get("simple_rs")
    {
        // Test stoichiometric matrix
        let matrix = stoichiometric_matrix(rs);
        assert_eq!(matrix.len(), 2); // 2 species
        assert_eq!(matrix[0].len(), 1); // 1 reaction
        assert_eq!(matrix[0][0], -1.0); // A consumed
        assert_eq!(matrix[1][0], 1.0); // B produced

        // Test ODE derivation
        let ode_model = derive_odes(rs).expect("Should derive ODEs successfully");
        assert_eq!(ode_model.variables.len(), 2); // A and B
        assert_eq!(ode_model.equations.len(), 2); // d[A]/dt and d[B]/dt

        // Test expression graph for reaction system
        let rs_expr_graph = expression_graph(rs);
        assert!(!rs_expr_graph.nodes.is_empty());
    }
}

#[test]
fn test_editing_operations() {
    use std::collections::HashMap;

    // Create a simple model
    let model = Model {
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
        default_units: None,
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

    let updated_model = add_variable(&model, "test_k", new_var).expect("Failed to add variable");
    assert!(updated_model.variables.contains_key("test_k"));
    assert_eq!(updated_model.variables.len(), 1);

    // Test adding equations
    let new_eq = Equation {
        lhs: Expr::Variable("test_var".to_string()),
        rhs: Expr::Number(42.0),
    };

    let model_with_eq = add_equation(&updated_model, new_eq).expect("Failed to add equation");
    assert_eq!(model_with_eq.equations.len(), 1);

    // Test variable substitution
    let expr = Expr::Operator(ExpressionNode {
        op: "+".to_string(),
        args: vec![Expr::Variable("x".to_string()), Expr::Number(1.0)],
        wrt: None,
        dim: None,
        ..Default::default()
    });

    let mut substitutions = HashMap::new();
    substitutions.insert("x".to_string(), Expr::Number(5.0));

    let result = substitute_in_expression(&expr, &substitutions);

    if let Expr::Operator(node) = result {
        assert_eq!(node.op, "+");
        if let Expr::Number(val) = &node.args[0] {
            assert_eq!(*val, 5.0);
        } else {
            panic!("Expected substituted value");
        }
    } else {
        panic!("Expected operator expression");
    }
}
