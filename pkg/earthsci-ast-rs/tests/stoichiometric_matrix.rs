//! Stoichiometric matrix tests
//!
//! Tests for generating and analyzing stoichiometric matrices from reaction systems.

use earthsci_ast::*;
use std::collections::HashMap;

/// Test simple stoichiometric matrix generation
#[test]
fn test_simple_stoichiometric_matrix() {
    // Simple reaction: A -> B
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

    // Matrix should be 2x1 (2 species, 1 reaction)
    assert_eq!(matrix.len(), 2, "Expected 2 rows (species)");
    assert_eq!(matrix[0].len(), 1, "Expected 1 column (reaction)");

    // A is consumed (-1), B is produced (+1)
    assert_eq!(matrix[0][0], -1.0, "A should be consumed");
    assert_eq!(matrix[1][0], 1.0, "B should be produced");
}

/// Test multiple reaction stoichiometric matrix
#[test]
fn test_multiple_reaction_stoichiometric_matrix() {
    // Reactions: A -> B, B -> C
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
        m.insert(
            "C".to_string(),
            Species {
                units: Some("mol/L".to_string()),
                default: Some(0.0),
                description: None,
                constant: None,
            },
        );
        m
    };

    let reactions = vec![
        Reaction {
            id: None,
            name: Some("R1".to_string()),
            substrates: Some(vec![StoichiometricEntry {
                species: "A".to_string(),
                coefficient: 1.0,
            }]),
            products: Some(vec![StoichiometricEntry {
                species: "B".to_string(),
                coefficient: 1.0,
            }]),
            rate: Expr::Variable("k1".to_string()),
            reference: None,
        },
        Reaction {
            id: None,
            name: Some("R2".to_string()),
            substrates: Some(vec![StoichiometricEntry {
                species: "B".to_string(),
                coefficient: 1.0,
            }]),
            products: Some(vec![StoichiometricEntry {
                species: "C".to_string(),
                coefficient: 1.0,
            }]),
            rate: Expr::Variable("k2".to_string()),
            reference: None,
        },
    ];

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

    // Matrix should be 3x2 (3 species, 2 reactions)
    assert_eq!(matrix.len(), 3, "Expected 3 rows (species)");
    assert_eq!(matrix[0].len(), 2, "Expected 2 columns (reactions)");

    // Reaction 1: A -> B
    assert_eq!(matrix[0][0], -1.0, "A consumed in R1");
    assert_eq!(matrix[1][0], 1.0, "B produced in R1");
    assert_eq!(matrix[2][0], 0.0, "C not involved in R1");

    // Reaction 2: B -> C
    assert_eq!(matrix[0][1], 0.0, "A not involved in R2");
    assert_eq!(matrix[1][1], -1.0, "B consumed in R2");
    assert_eq!(matrix[2][1], 1.0, "C produced in R2");
}

/// Test stoichiometric coefficients
#[test]
fn test_stoichiometric_coefficients() {
    // Reaction: 2A + B -> 3C
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
                default: Some(1.0),
                description: None,
                constant: None,
            },
        );
        m.insert(
            "C".to_string(),
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
        substrates: Some(vec![
            StoichiometricEntry {
                species: "A".to_string(),
                coefficient: 2.0,
            },
            StoichiometricEntry {
                species: "B".to_string(),
                coefficient: 1.0,
            },
        ]),
        products: Some(vec![StoichiometricEntry {
            species: "C".to_string(),
            coefficient: 3.0,
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

    // Check coefficients
    assert_eq!(matrix[0][0], -2.0, "2 A consumed");
    assert_eq!(matrix[1][0], -1.0, "1 B consumed");
    assert_eq!(matrix[2][0], 3.0, "3 C produced");
}

/// Test reversible reactions
#[test]
fn test_reversible_reactions() {
    // Forward: A -> B, Reverse: B -> A
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

    let reactions = vec![
        Reaction {
            id: None,
            name: Some("Forward".to_string()),
            substrates: Some(vec![StoichiometricEntry {
                species: "A".to_string(),
                coefficient: 1.0,
            }]),
            products: Some(vec![StoichiometricEntry {
                species: "B".to_string(),
                coefficient: 1.0,
            }]),
            rate: Expr::Variable("kf".to_string()),
            reference: None,
        },
        Reaction {
            id: None,
            name: Some("Reverse".to_string()),
            substrates: Some(vec![StoichiometricEntry {
                species: "B".to_string(),
                coefficient: 1.0,
            }]),
            products: Some(vec![StoichiometricEntry {
                species: "A".to_string(),
                coefficient: 1.0,
            }]),
            rate: Expr::Variable("kr".to_string()),
            reference: None,
        },
    ];

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

    // Matrix should be 2x2
    assert_eq!(matrix.len(), 2);
    assert_eq!(matrix[0].len(), 2);

    // Forward reaction: A -> B
    assert_eq!(matrix[0][0], -1.0, "A consumed in forward");
    assert_eq!(matrix[1][0], 1.0, "B produced in forward");

    // Reverse reaction: B -> A
    assert_eq!(matrix[0][1], 1.0, "A produced in reverse");
    assert_eq!(matrix[1][1], -1.0, "B consumed in reverse");
}

/// Test complex reaction network
#[test]
fn test_complex_reaction_network() {
    // Network: A + B -> C, C -> D + E, D -> A
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
                default: Some(1.0),
                description: None,
                constant: None,
            },
        );
        m.insert(
            "C".to_string(),
            Species {
                units: Some("mol/L".to_string()),
                default: Some(0.0),
                description: None,
                constant: None,
            },
        );
        m.insert(
            "D".to_string(),
            Species {
                units: Some("mol/L".to_string()),
                default: Some(0.0),
                description: None,
                constant: None,
            },
        );
        m.insert(
            "E".to_string(),
            Species {
                units: Some("mol/L".to_string()),
                default: Some(0.0),
                description: None,
                constant: None,
            },
        );
        m
    };

    let reactions = vec![
        // A + B -> C
        Reaction {
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
            rate: Expr::Variable("k1".to_string()),
            reference: None,
        },
        // C -> D + E
        Reaction {
            id: None,
            name: Some("R2".to_string()),
            substrates: Some(vec![StoichiometricEntry {
                species: "C".to_string(),
                coefficient: 1.0,
            }]),
            products: Some(vec![
                StoichiometricEntry {
                    species: "D".to_string(),
                    coefficient: 1.0,
                },
                StoichiometricEntry {
                    species: "E".to_string(),
                    coefficient: 1.0,
                },
            ]),
            rate: Expr::Variable("k2".to_string()),
            reference: None,
        },
        // D -> A
        Reaction {
            id: None,
            name: Some("R3".to_string()),
            substrates: Some(vec![StoichiometricEntry {
                species: "D".to_string(),
                coefficient: 1.0,
            }]),
            products: Some(vec![StoichiometricEntry {
                species: "A".to_string(),
                coefficient: 1.0,
            }]),
            rate: Expr::Variable("k3".to_string()),
            reference: None,
        },
    ];

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

    // Matrix should be 5x3 (5 species, 3 reactions)
    assert_eq!(matrix.len(), 5);
    assert_eq!(matrix[0].len(), 3);

    // R1: A + B -> C
    assert_eq!(matrix[0][0], -1.0, "A consumed in R1");
    assert_eq!(matrix[1][0], -1.0, "B consumed in R1");
    assert_eq!(matrix[2][0], 1.0, "C produced in R1");
    assert_eq!(matrix[3][0], 0.0, "D not in R1");
    assert_eq!(matrix[4][0], 0.0, "E not in R1");

    // R2: C -> D + E
    assert_eq!(matrix[0][1], 0.0, "A not in R2");
    assert_eq!(matrix[1][1], 0.0, "B not in R2");
    assert_eq!(matrix[2][1], -1.0, "C consumed in R2");
    assert_eq!(matrix[3][1], 1.0, "D produced in R2");
    assert_eq!(matrix[4][1], 1.0, "E produced in R2");

    // R3: D -> A
    assert_eq!(matrix[0][2], 1.0, "A produced in R3");
    assert_eq!(matrix[1][2], 0.0, "B not in R3");
    assert_eq!(matrix[2][2], 0.0, "C not in R3");
    assert_eq!(matrix[3][2], -1.0, "D consumed in R3");
    assert_eq!(matrix[4][2], 0.0, "E not in R3");
}

/// Test empty reaction system
#[test]
fn test_empty_reaction_system() {
    let rs = ReactionSystem {
        subsystems: None,
        coupletype: None,
        reference: None,
        species: std::collections::HashMap::new(),
        parameters: HashMap::new(),
        reactions: vec![],
        constraint_equations: None,
        discrete_events: None,
        continuous_events: None,
    };

    let matrix = stoichiometric_matrix(&rs);
    assert!(
        matrix.is_empty(),
        "Empty reaction system should produce empty matrix"
    );
}

/// Test reaction system with no reactions
#[test]
fn test_no_reactions() {
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
        coupletype: None,
        reference: None,
        species,
        parameters: HashMap::new(),
        reactions: vec![],
        constraint_equations: None,
        discrete_events: None,
        continuous_events: None,
    };

    let matrix = stoichiometric_matrix(&rs);
    assert_eq!(matrix.len(), 1, "Should have 1 row for 1 species");
    assert_eq!(matrix[0].len(), 0, "Should have 0 columns for 0 reactions");
}

// Note: fractional coefficient test removed; schema requires integer ≥ 1 stoichiometry.

/// Test default coefficient handling
#[test]
fn test_default_coefficients() {
    // Reaction with no explicit coefficients should default to 1.0
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
            coefficient: 1.0, // Default
        }]),
        products: Some(vec![StoichiometricEntry {
            species: "B".to_string(),
            coefficient: 1.0, // Default
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

    assert_eq!(
        matrix[0][0], -1.0,
        "Default coefficient should be -1 for substrate"
    );
    assert_eq!(
        matrix[1][0], 1.0,
        "Default coefficient should be 1 for product"
    );
}
