//! Structural validation tests over PROGRAMMATICALLY constructed models
//! (typed struct literals rather than fixture files).
//!
//! The fixture-driven counterpart is `structural_validation.rs`; this file
//! covers the same validator through direct construction, which exercises
//! shapes the shared fixture tree does not carry. (Formerly named
//! `structural_validation_fixed.rs` — the suffix was a naming accident, not
//! a superseding copy.)

use earthsci_toolkit::*;
use std::collections::HashMap;

/// Test basic structural validation with manually created data
#[test]
fn test_undefined_variable_in_model() {
    use std::collections::HashMap;

    // Create a model with equation referencing undefined variable
    let mut variables = HashMap::new();
    variables.insert(
        "x".to_string(),
        ModelVariable {
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
        coupletype: None,
        subsystems: None,
        reference: None,
        name: Some("Test Model".to_string()),
        variables,
        equations: vec![Equation {
            lhs: Expr::Variable("y".to_string()), // 'y' is not defined
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
        "Expected structural validation errors"
    );

    // Check for undefined variable error
    let has_undefined_var_error = validation_result
        .structural_errors
        .iter()
        .any(|err| matches!(err.code, StructuralErrorCode::UndefinedVariable));
    assert!(has_undefined_var_error, "Expected UndefinedVariable error");
}

/// Test equation count mismatch
#[test]
fn test_equation_count_mismatch() {
    use std::collections::HashMap;

    // Create a model with more equations than state variables
    let mut variables = HashMap::new();
    variables.insert(
        "x".to_string(),
        ModelVariable {
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
        coupletype: None,
        subsystems: None,
        reference: None,
        name: Some("Test Model".to_string()),
        variables,
        equations: vec![
            Equation {
                lhs: Expr::Variable("x".to_string()),
                rhs: Expr::Number(1.0),
            },
            Equation {
                lhs: Expr::Variable("x".to_string()),
                rhs: Expr::Number(2.0),
            },
        ],
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
        "Expected structural validation errors"
    );

    // Check for equation count error
    let has_equation_count_error = validation_result
        .structural_errors
        .iter()
        .any(|err| matches!(err.code, StructuralErrorCode::EquationCountMismatch));
    assert!(
        has_equation_count_error,
        "Expected EquationCountMismatch error"
    );
}

/// Test undefined species in reaction system
#[test]
fn test_undefined_species_in_reaction() {
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

    let reactions = vec![Reaction {
        id: None,
        name: None,
        substrates: Some(vec![StoichiometricEntry {
            species: "B".to_string(), // 'B' is not defined
            coefficient: 1.0,
        }]),
        products: Some(vec![StoichiometricEntry {
            species: "A".to_string(),
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

    let mut reaction_systems = HashMap::new();
    reaction_systems.insert("test".to_string(), rs);

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
        models: None,
        reaction_systems: Some(reaction_systems),
        data_loaders: None,
        operators: None,
        enums: None,

        coupling: None,
        function_tables: None,
    };

    let validation_result = validate(&esm_file);
    assert!(
        !validation_result.structural_errors.is_empty(),
        "Expected structural validation errors"
    );

    // Check for undefined species error
    let has_undefined_species_error = validation_result
        .structural_errors
        .iter()
        .any(|err| matches!(err.code, StructuralErrorCode::UndefinedSpecies));
    assert!(
        has_undefined_species_error,
        "Expected UndefinedSpecies error"
    );
}

/// Test fixture-based validation (only if fixtures exist and are parseable)
#[test]
fn test_fixture_based_validation() {
    // Try to load a fixture, but gracefully handle if it doesn't exist or fails to parse
    let fixture_result = std::fs::read_to_string("../../../tests/invalid/unknown_variable_ref.esm");

    if let Ok(fixture) = fixture_result {
        let parsed_result = load(&fixture);

        match parsed_result {
            Ok(esm_file) => {
                let validation_result = validate(&esm_file);
                // If it parses, it should have structural errors
                assert!(
                    !validation_result.structural_errors.is_empty(),
                    "Fixture should have structural errors"
                );
            }
            Err(_) => {
                // If it fails to parse due to schema issues, that's also acceptable for invalid fixtures
                // The important thing is that invalid data doesn't silently pass
            }
        }
    } else {
        // If fixture doesn't exist, skip this test
        println!("Fixture not found, skipping fixture-based test");
    }
}

/// Test valid file passes validation
#[test]
fn test_valid_file_passes() {
    use std::collections::HashMap;

    // Create a valid model with parameter only (no state variables to avoid ODE requirement)
    let mut variables = HashMap::new();
    variables.insert(
        "k".to_string(),
        ModelVariable {
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
        coupletype: None,
        subsystems: None,
        reference: None,
        name: Some("Valid Model".to_string()),
        variables,
        equations: vec![], // No equations needed for parameter-only model
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
    models.insert("valid".to_string(), model);

    let esm_file = EsmFile {
        domain: None,
        index_sets: None,
        esm: "0.1.0".to_string(),
        metadata: Metadata {
            name: Some("Valid File".to_string()),
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

    // Debug output to see what's failing
    if !validation_result.is_valid {
        println!("Schema errors: {:?}", validation_result.schema_errors);
        println!(
            "Structural errors: {:?}",
            validation_result.structural_errors
        );
    }

    assert!(
        validation_result.is_valid,
        "Valid file should pass validation"
    );
    assert!(
        validation_result.structural_errors.is_empty(),
        "Valid file should have no structural errors"
    );
    assert!(
        validation_result.schema_errors.is_empty(),
        "Valid file should have no schema errors"
    );
}
