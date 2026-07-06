//! Reaction system analysis and ODE generation (esm-spec §7.4).
//!
//! Two public surfaces: the stoichiometric-matrix builders
//! ([`stoichiometric_matrix`] and friends) and mass-action ODE derivation
//! ([`derive_reaction_odes`], §4.7.5), which turns a [`ReactionSystem`]'s
//! reactions into per-species `D(sp, t) = Σ ±coeff·rate·Π substrates`
//! equations mirroring the Julia (Catalyst) and Python references.

use crate::{
    Equation, Expr, ExpressionNode, Model, ModelVariable, ReactionSystem, Species, VariableType,
};
use std::collections::HashMap;
use thiserror::Error;

/// Error type for ODE derivation operations
#[derive(Error, Debug)]
pub enum DeriveError {
    /// Unit conversion error
    #[error("Unit conversion error: {0}")]
    UnitConversion(String),

    /// Invalid stoichiometry
    #[error("Invalid stoichiometry: {0}")]
    InvalidStoichiometry(String),

    /// Missing rate law
    #[error("Missing or invalid rate law: {0}")]
    InvalidRateLaw(String),

    /// Constraint equation error
    #[error("Constraint equation error: {0}")]
    ConstraintEquation(String),

    /// Generic derivation error
    #[error("Derivation error: {0}")]
    Other(String),
}

/// Lower a reaction network to an ODE equation list.
///
/// Produces one `D(species, t) = Σ(net_stoichiometry · rate)` equation per species
/// per spec §4.7.5 step 1. Reusable from both [`derive_odes`] and
/// [`crate::flatten::flatten`] so the reaction-to-equation core lives in one place.
///
/// Each reaction's base rate is enhanced with mass-action concentration factors
/// per spec §7.4 (the `rate` field is the coefficient; the runner always
/// multiplies by the substrate product). Net stoichiometry combines substrate
/// and product contributions for each species.
pub fn lower_reactions_to_equations(
    reactions: &[crate::Reaction],
    species: &HashMap<String, Species>,
) -> Result<Vec<Equation>, DeriveError> {
    // Validate system has species if there are reactions
    if species.is_empty() && !reactions.is_empty() {
        return Err(DeriveError::InvalidStoichiometry(
            "Reaction system has reactions but no species defined".to_string(),
        ));
    }

    // Validate reactions and their stoichiometry. Coefficients are f64
    // (fractional stoichiometries are allowed); non-negativity is enforced
    // upstream by the schema (`exclusiveMinimum: 0`) and the parse-level
    // stoichiometry check, so only species references are checked here.
    for (reaction_idx, reaction) in reactions.iter().enumerate() {
        for substrate in reaction.substrates.iter().flatten() {
            if !species.contains_key(&substrate.species) {
                return Err(DeriveError::InvalidStoichiometry(format!(
                    "Unknown substrate species '{}' in reaction {}",
                    substrate.species, reaction_idx
                )));
            }
        }

        for product in reaction.products.iter().flatten() {
            if !species.contains_key(&product.species) {
                return Err(DeriveError::InvalidStoichiometry(format!(
                    "Unknown product species '{}' in reaction {}",
                    product.species, reaction_idx
                )));
            }
        }

        let no_substrates = reaction.substrates.as_ref().is_none_or(|v| v.is_empty());
        let no_products = reaction.products.as_ref().is_none_or(|v| v.is_empty());
        if no_substrates && no_products {
            return Err(DeriveError::InvalidStoichiometry(format!(
                "Reaction {reaction_idx} has no substrates or products"
            )));
        }
    }

    let mut equations = Vec::with_capacity(species.len());

    let mut species_names: Vec<&String> = species.keys().collect();
    species_names.sort();
    for sp_name in species_names {
        let mut rate_terms = Vec::new();

        for reaction in reactions {
            // v0.2.x allows fractional stoichiometries; accumulate in f64 so
            // products like `0.87 CH2O` survive the ODE lowering unchanged.
            let mut net_stoichiometry: f64 = 0.0;

            for substrate in reaction.substrates.iter().flatten() {
                if &substrate.species == sp_name {
                    net_stoichiometry -= substrate.coefficient;
                }
            }
            for product in reaction.products.iter().flatten() {
                if &product.species == sp_name {
                    net_stoichiometry += product.coefficient;
                }
            }

            if net_stoichiometry != 0.0 {
                let enhanced_rate = enhance_rate_with_mass_action(
                    &reaction.rate,
                    reaction.substrates.as_deref().unwrap_or(&[]),
                )?;

                if net_stoichiometry == 1.0 {
                    rate_terms.push(enhanced_rate);
                } else {
                    // Covers -1.0 too: `Number(net_stoichiometry)` is exactly
                    // `Number(-1.0)` when the coefficient is -1.
                    rate_terms.push(Expr::Operator(ExpressionNode {
                        op: "*".to_string(),
                        args: vec![Expr::Number(net_stoichiometry), enhanced_rate],
                        wrt: None,
                        dim: None,
                        ..Default::default()
                    }));
                }
            }
        }

        let rhs = if rate_terms.is_empty() {
            Expr::Number(0.0)
        } else if rate_terms.len() == 1 {
            rate_terms.into_iter().next().unwrap()
        } else {
            Expr::Operator(ExpressionNode {
                op: "+".to_string(),
                args: rate_terms,
                wrt: None,
                dim: None,
                ..Default::default()
            })
        };

        let lhs = Expr::Operator(ExpressionNode {
            op: "D".to_string(),
            args: vec![Expr::Variable(sp_name.clone())],
            wrt: Some("t".to_string()),
            dim: None,
            ..Default::default()
        });

        equations.push(Equation {
            lhs,
            rhs,
        });
    }

    Ok(equations)
}

/// Generate ODE model from a reaction system
///
/// Converts a reaction system into an ODE model with species as state variables
/// and reactions contributing to their derivatives using mass action kinetics.
///
/// Mass action kinetics: rate law = k * product(substrates^stoichiometry)
/// Net stoichiometry = products - substrates
/// d[species]/dt = sum(net_stoichiometry * rate_law)
///
/// # Arguments
///
/// * `system` - The reaction system to convert
///
/// # Returns
///
/// * `Result<Model, DeriveError>` - ODE model with species as state variables, or error
///
/// # Errors
///
/// Returns `DeriveError` for invalid stoichiometry, missing rate laws, or unit conversion issues.
pub fn derive_odes(system: &ReactionSystem) -> Result<Model, DeriveError> {
    let mut variables = HashMap::new();

    for (species_name, species) in &system.species {
        variables.insert(
            species_name.clone(),
            ModelVariable {
                var_type: VariableType::State,
                units: species.units.clone(),
                default: species.default,
                description: species.description.clone(),
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );
    }

    let equations = lower_reactions_to_equations(&system.reactions, &system.species)?;

    Ok(Model {
        name: None,
        coupletype: system.coupletype.clone(),
        reference: system.reference.clone(),
        variables,
        equations,
        discrete_events: system.discrete_events.clone(),
        continuous_events: system.continuous_events.clone(),
        subsystems: None,
        description: None,
        tolerance: None,
        tests: None,
        initialization_equations: None,
        guesses: None,
        system_kind: None,
    })
}

/// Enhance base rate law with mass action kinetics
///
/// Per `esm-spec.md` §7.4 the `rate` field is the rate COEFFICIENT.
/// The full rate law is always `k * product(substrates^stoichiometry)` — the
/// runner unconditionally multiplies the coefficient by the substrate product.
/// Source reactions (no substrates) return the coefficient unchanged.
fn enhance_rate_with_mass_action(
    rate: &Expr,
    substrates: &[crate::StoichiometricEntry],
) -> Result<Expr, DeriveError> {
    // If no substrates (source reaction), return rate as-is
    if substrates.is_empty() {
        return Ok(rate.clone());
    }

    // Enhance with mass action kinetics (spec §7.4).
    // Stoichiometric coefficients are positive finite numbers — integer coefficients
    // unroll into repeated multiplication (`[A]·[A]·…`), fractional coefficients
    // (e.g. 1.5) lower to a `^` power expression.
    let mut concentration_factors = Vec::new();

    for substrate in substrates {
        let coeff = substrate.coefficient;
        let species_var = Expr::Variable(substrate.species.clone());

        if coeff == 1.0 {
            concentration_factors.push(species_var);
        } else if coeff.fract() == 0.0 && coeff > 0.0 && coeff < 1e6 {
            let n = coeff as u64;
            let mut power_terms = Vec::new();
            for _ in 0..n {
                power_terms.push(species_var.clone());
            }
            concentration_factors.push(Expr::Operator(ExpressionNode {
                op: "*".to_string(),
                args: power_terms,
                wrt: None,
                dim: None,
                ..Default::default()
            }));
        } else {
            concentration_factors.push(Expr::Operator(ExpressionNode {
                op: "^".to_string(),
                args: vec![species_var, Expr::Number(coeff)],
                wrt: None,
                dim: None,
                ..Default::default()
            }));
        }
    }

    // Combine rate coefficient with concentration factors
    let mut all_factors = vec![rate.clone()];
    all_factors.extend(concentration_factors);

    if all_factors.len() == 1 {
        Ok(all_factors.into_iter().next().unwrap())
    } else {
        Ok(Expr::Operator(ExpressionNode {
            op: "*".to_string(),
            args: all_factors,
            wrt: None,
            dim: None,
            ..Default::default()
        }))
    }
}

/// Generate stoichiometric matrix from a reaction system
///
/// Creates a matrix where rows represent species and columns represent reactions.
/// Matrix[i][j] = stoichiometric coefficient of species i in reaction j.
/// Negative values indicate reactants, positive values indicate products.
///
/// # Arguments
///
/// * `system` - The reaction system to analyze
///
/// # Returns
///
/// * `Vec<Vec<f64>>` - Matrix with species as rows and reactions as columns
pub fn stoichiometric_matrix(system: &ReactionSystem) -> Vec<Vec<f64>> {
    let num_species = system.species.len();
    let num_reactions = system.reactions.len();

    // Initialize matrix with zeros
    let mut matrix = vec![vec![0.0f64; num_reactions]; num_species];

    // Build a stable species ordering (sorted by name) so indices are reproducible
    // across runs and match the ordering used by derive_odes / lower_reactions_to_equations.
    let mut sorted_species_names: Vec<&String> = system.species.keys().collect();
    sorted_species_names.sort();
    let species_index: HashMap<String, usize> = sorted_species_names
        .iter()
        .enumerate()
        .map(|(idx, name)| ((*name).clone(), idx))
        .collect();

    // Fill in the matrix
    for (reaction_idx, reaction) in system.reactions.iter().enumerate() {
        // Process substrates (negative coefficients)
        for substrate in reaction.substrates.iter().flatten() {
            if let Some(&species_idx) = species_index.get(&substrate.species) {
                matrix[species_idx][reaction_idx] -= substrate.coefficient;
            }
        }

        // Process products (positive coefficients)
        for product in reaction.products.iter().flatten() {
            if let Some(&species_idx) = species_index.get(&product.species) {
                matrix[species_idx][reaction_idx] += product.coefficient;
            }
        }
    }

    matrix
}

/// Generate a stoichiometric matrix from a reaction system using parallel computation
///
/// This function provides parallel computation for generating stoichiometric matrices,
/// which can significantly improve performance for large reaction systems.
///
/// # Arguments
///
/// * `system` - The reaction system to analyze
///
/// # Returns
///
/// * `Result<Vec<Vec<f64>>, crate::performance::PerformanceError>` - Matrix with species as rows and reactions as columns
///
/// # Features
///
/// This function requires the `parallel` feature to be enabled.
///
/// # Example
///
/// ```rust
/// # #[cfg(feature = "parallel")]
/// # {
/// use earthsci_toolkit::{ReactionSystem, stoichiometric_matrix_parallel};
///
/// // Assuming you have a reaction system
/// let reaction_system = ReactionSystem {
///     coupletype: None,
///     reference: None,
///     species: std::collections::HashMap::new(),
///     parameters: std::collections::HashMap::new(),
///     reactions: vec![],
///     constraint_equations: None,
///     discrete_events: None,
///     continuous_events: None,
///     subsystems: None,
/// };
///
/// let matrix = stoichiometric_matrix_parallel(&reaction_system).unwrap();
/// # }
/// ```
#[cfg(feature = "parallel")]
pub fn stoichiometric_matrix_parallel(
    system: &ReactionSystem,
) -> Result<Vec<Vec<f64>>, crate::performance::PerformanceError> {
    use crate::performance::ParallelEvaluator;

    let evaluator = ParallelEvaluator::new(None)?;
    evaluator.compute_stoichiometric_matrix_parallel(system)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Reaction, Species, StoichiometricEntry};

    fn create_test_species(name: &str) -> (String, Species) {
        (
            name.to_string(),
            Species {
                units: Some("mol/L".to_string()),
                default: Some(0.0),
                description: None,
                constant: None,
            },
        )
    }

    fn create_test_reaction(
        substrates: Vec<(&str, f64)>,
        products: Vec<(&str, f64)>,
        rate: Expr,
    ) -> Reaction {
        Reaction {
            id: None,
            name: None,
            substrates: Some(
                substrates
                    .into_iter()
                    .map(|(species, coeff)| StoichiometricEntry {
                        species: species.to_string(),
                        coefficient: coeff,
                    })
                    .collect(),
            ),
            products: Some(
                products
                    .into_iter()
                    .map(|(species, coeff)| StoichiometricEntry {
                        species: species.to_string(),
                        coefficient: coeff,
                    })
                    .collect(),
            ),
            rate,
            reference: None,
        }
    }

    #[test]
    fn test_derive_odes_simple() {
        let system = ReactionSystem {
            coupletype: None,
            reference: None,
            species: [create_test_species("A"), create_test_species("B")]
                .into_iter()
                .collect::<std::collections::HashMap<_, _>>(),
            parameters: HashMap::new(),
            reactions: vec![
                // A -> B with rate k1 * A
                create_test_reaction(
                    vec![("A", 1.0)],
                    vec![("B", 1.0)],
                    Expr::Operator(ExpressionNode {
                        op: "*".to_string(),
                        args: vec![
                            Expr::Variable("k1".to_string()),
                            Expr::Variable("A".to_string()),
                        ],
                        wrt: None,
                        dim: None,
                        ..Default::default()
                    }),
                ),
            ],
            constraint_equations: None,
            discrete_events: None,
            continuous_events: None,
            subsystems: None,
        };

        let model = derive_odes(&system).expect("Should derive ODEs successfully");

        assert_eq!(model.variables.len(), 2);
        assert!(model.variables.contains_key("A"));
        assert!(model.variables.contains_key("B"));

        assert_eq!(model.equations.len(), 2);

        // Both species should have ODE equations
        let var_names: Vec<String> = model
            .equations
            .iter()
            .map(|eq| match &eq.lhs {
                Expr::Operator(node) if node.op == "D" => match &node.args[0] {
                    Expr::Variable(name) => name.clone(),
                    _ => "unknown".to_string(),
                },
                _ => "unknown".to_string(),
            })
            .collect();

        assert!(var_names.contains(&"A".to_string()));
        assert!(var_names.contains(&"B".to_string()));
    }

    #[test]
    fn test_stoichiometric_matrix() {
        let system = ReactionSystem {
            coupletype: None,
            reference: None,
            species: [
                create_test_species("A"),
                create_test_species("B"),
                create_test_species("C"),
            ]
            .into_iter()
            .collect::<std::collections::HashMap<_, _>>(),
            parameters: HashMap::new(),
            reactions: vec![
                // Reaction 1: A -> B
                create_test_reaction(
                    vec![("A", 1.0)],
                    vec![("B", 1.0)],
                    Expr::Variable("k1".to_string()),
                ),
                // Reaction 2: B -> C
                create_test_reaction(
                    vec![("B", 1.0)],
                    vec![("C", 1.0)],
                    Expr::Variable("k2".to_string()),
                ),
                // Reaction 3: 2A -> C
                create_test_reaction(
                    vec![("A", 2.0)],
                    vec![("C", 1.0)],
                    Expr::Variable("k3".to_string()),
                ),
            ],
            constraint_equations: None,
            discrete_events: None,
            continuous_events: None,
            subsystems: None,
        };

        let matrix = stoichiometric_matrix(&system);

        // Should be 3x3 matrix (3 species, 3 reactions)
        assert_eq!(matrix.len(), 3);
        assert_eq!(matrix[0].len(), 3);
        assert_eq!(matrix[1].len(), 3);
        assert_eq!(matrix[2].len(), 3);

        // Check specific values
        // Species A: [-1, 0, -2] (consumed in reactions 1 and 3)
        assert_eq!(matrix[0], vec![-1.0, 0.0, -2.0]);

        // Species B: [1, -1, 0] (produced in reaction 1, consumed in reaction 2)
        assert_eq!(matrix[1], vec![1.0, -1.0, 0.0]);

        // Species C: [0, 1, 1] (produced in reactions 2 and 3)
        assert_eq!(matrix[2], vec![0.0, 1.0, 1.0]);
    }

    #[test]
    fn test_stoichiometric_matrix_empty() {
        let system = ReactionSystem {
            coupletype: None,
            reference: None,
            species: std::collections::HashMap::new(),
            parameters: HashMap::new(),
            reactions: vec![],
            constraint_equations: None,
            discrete_events: None,
            continuous_events: None,
            subsystems: None,
        };

        let matrix = stoichiometric_matrix(&system);
        assert_eq!(matrix.len(), 0);
    }

    #[test]
    fn test_derive_odes_empty_system() {
        let system = ReactionSystem {
            coupletype: None,
            reference: None,
            species: std::collections::HashMap::new(),
            parameters: HashMap::new(),
            reactions: vec![],
            constraint_equations: None,
            discrete_events: None,
            continuous_events: None,
            subsystems: None,
        };

        let model = derive_odes(&system).expect("Should handle empty system");
        assert_eq!(model.variables.len(), 0);
        assert_eq!(model.equations.len(), 0);
    }

    #[test]
    fn test_derive_odes_unknown_species_error() {
        let system = ReactionSystem {
            coupletype: None,
            reference: None,
            species: [create_test_species("A")]
                .into_iter()
                .collect::<std::collections::HashMap<_, _>>(),
            parameters: HashMap::new(),
            reactions: vec![create_test_reaction(
                vec![("B", 1.0)], // B is not defined in species
                vec![("A", 1.0)],
                Expr::Variable("k1".to_string()),
            )],
            constraint_equations: None,
            discrete_events: None,
            continuous_events: None,
            subsystems: None,
        };

        let result = derive_odes(&system);
        assert!(result.is_err());
        match result {
            Err(DeriveError::InvalidStoichiometry(msg)) => {
                assert!(msg.contains("Unknown substrate species 'B'"));
            }
            _ => panic!("Expected InvalidStoichiometry error"),
        }
    }

    #[test]
    fn test_derive_odes_mass_action_kinetics() {
        let system = ReactionSystem {
            coupletype: None,
            reference: None,
            species: [
                create_test_species("A"),
                create_test_species("B"),
                create_test_species("C"),
            ]
            .into_iter()
            .collect::<std::collections::HashMap<_, _>>(),
            parameters: HashMap::new(),
            reactions: vec![
                // A + B -> C with rate coefficient k1 (should become k1*A*B)
                create_test_reaction(
                    vec![("A", 1.0), ("B", 1.0)],
                    vec![("C", 1.0)],
                    Expr::Variable("k1".to_string()),
                ),
            ],
            constraint_equations: None,
            discrete_events: None,
            continuous_events: None,
            subsystems: None,
        };

        let model = derive_odes(&system).expect("Should derive ODEs successfully");
        assert_eq!(model.variables.len(), 3);
        assert_eq!(model.equations.len(), 3);

        // Check that the rate law includes mass action terms
        // For species C: d[C]/dt = k1 * A * B
        let c_equation = model
            .equations
            .iter()
            .find(|eq| match &eq.lhs {
                Expr::Operator(node) if node.op == "D" => match &node.args[0] {
                    Expr::Variable(name) => name == "C",
                    _ => false,
                },
                _ => false,
            })
            .expect("Should find C equation");

        // The RHS should be a multiplication involving k1, A, and B
        match &c_equation.rhs {
            Expr::Operator(node) if node.op == "*" => {
                assert!(node.args.len() >= 2);
                // Should contain k1, A, and B in some form
            }
            _ => panic!("Expected multiplication for mass action kinetics"),
        }
    }

    #[test]
    fn test_derive_odes_source_reaction() {
        let system = ReactionSystem {
            coupletype: None,
            reference: None,
            species: [create_test_species("A")]
                .into_iter()
                .collect::<std::collections::HashMap<_, _>>(),
            parameters: HashMap::new(),
            reactions: vec![
                // Source reaction: -> A with rate k0 (no substrates)
                create_test_reaction(vec![], vec![("A", 1.0)], Expr::Variable("k0".to_string())),
            ],
            constraint_equations: None,
            discrete_events: None,
            continuous_events: None,
            subsystems: None,
        };

        let model = derive_odes(&system).expect("Should handle source reactions");
        assert_eq!(model.variables.len(), 1);
        assert_eq!(model.equations.len(), 1);

        // For species A: d[A]/dt = k0 (no concentration dependence)
        let a_equation = &model.equations[0];
        match &a_equation.rhs {
            Expr::Variable(name) => assert_eq!(name, "k0"),
            _ => panic!("Expected simple rate constant for source reaction"),
        }
    }

    #[test]
    fn test_derive_odes_sink_reaction() {
        let system = ReactionSystem {
            coupletype: None,
            reference: None,
            species: [create_test_species("A")]
                .into_iter()
                .collect::<std::collections::HashMap<_, _>>(),
            parameters: HashMap::new(),
            reactions: vec![
                // Sink reaction: A -> with rate k_deg (no products)
                create_test_reaction(
                    vec![("A", 1.0)],
                    vec![],
                    Expr::Variable("k_deg".to_string()),
                ),
            ],
            constraint_equations: None,
            discrete_events: None,
            continuous_events: None,
            subsystems: None,
        };

        let model = derive_odes(&system).expect("Should handle sink reactions");
        assert_eq!(model.variables.len(), 1);
        assert_eq!(model.equations.len(), 1);

        // For species A: d[A]/dt = -k_deg * A
        let a_equation = &model.equations[0];
        match &a_equation.rhs {
            Expr::Operator(node) if node.op == "*" => {
                // Should be [-1, k_deg * A] structure
                assert_eq!(node.args.len(), 2);
                // First arg should be -1, second should be k_deg * A
                match &node.args[0] {
                    Expr::Number(n) => assert_eq!(*n, -1.0),
                    _ => panic!("Expected -1 as first argument"),
                }
            }
            _ => panic!(
                "Expected multiplication for sink reaction kinetics, got: {:?}",
                a_equation.rhs
            ),
        }
    }

    #[test]
    fn test_derive_odes_higher_order_reaction() {
        let system = ReactionSystem {
            coupletype: None,
            reference: None,
            species: [create_test_species("A"), create_test_species("B")]
                .into_iter()
                .collect::<std::collections::HashMap<_, _>>(),
            parameters: HashMap::new(),
            reactions: vec![
                // 2A -> B with rate k1 (second order in A)
                create_test_reaction(
                    vec![("A", 2.0)],
                    vec![("B", 1.0)],
                    Expr::Variable("k1".to_string()),
                ),
            ],
            constraint_equations: None,
            discrete_events: None,
            continuous_events: None,
            subsystems: None,
        };

        let model = derive_odes(&system).expect("Should handle higher order reactions");
        assert_eq!(model.variables.len(), 2);
        assert_eq!(model.equations.len(), 2);

        // Check that the rate law includes A^2 term (or A*A)
        let b_equation = model
            .equations
            .iter()
            .find(|eq| match &eq.lhs {
                Expr::Operator(node) if node.op == "D" => match &node.args[0] {
                    Expr::Variable(name) => name == "B",
                    _ => false,
                },
                _ => false,
            })
            .expect("Should find B equation");

        // The RHS should involve k1 and A squared
        match &b_equation.rhs {
            Expr::Operator(node) if node.op == "*" => {
                assert!(node.args.len() >= 2);
                // Should contain k1 and either A*A or pow(A, 2)
            }
            _ => panic!("Expected multiplication for higher order kinetics"),
        }
    }

    #[test]
    fn test_derive_odes_reactions_with_no_substrates_and_products() {
        let system = ReactionSystem {
            coupletype: None,
            reference: None,
            species: [create_test_species("A")]
                .into_iter()
                .collect::<std::collections::HashMap<_, _>>(),
            parameters: HashMap::new(),
            reactions: vec![create_test_reaction(
                vec![], // No substrates
                vec![], // No products
                Expr::Variable("k1".to_string()),
            )],
            constraint_equations: None,
            discrete_events: None,
            continuous_events: None,
            subsystems: None,
        };

        let result = derive_odes(&system);
        assert!(result.is_err());
        match result {
            Err(DeriveError::InvalidStoichiometry(msg)) => {
                assert!(msg.contains("has no substrates or products"));
            }
            _ => panic!("Expected InvalidStoichiometry error"),
        }
    }

    #[test]
    fn test_derive_odes_complex_reaction_network() {
        let system = ReactionSystem {
            coupletype: None,
            reference: None,
            species: [
                create_test_species("A"),
                create_test_species("B"),
                create_test_species("C"),
                create_test_species("D"),
            ]
            .into_iter()
            .collect::<std::collections::HashMap<_, _>>(),
            parameters: HashMap::new(),
            reactions: vec![
                // A + B -> C + D (rate k1)
                create_test_reaction(
                    vec![("A", 1.0), ("B", 1.0)],
                    vec![("C", 1.0), ("D", 1.0)],
                    Expr::Variable("k1".to_string()),
                ),
                // C -> A (rate k2)
                create_test_reaction(
                    vec![("C", 1.0)],
                    vec![("A", 1.0)],
                    Expr::Variable("k2".to_string()),
                ),
                // D -> B (rate k3)
                create_test_reaction(
                    vec![("D", 1.0)],
                    vec![("B", 1.0)],
                    Expr::Variable("k3".to_string()),
                ),
            ],
            constraint_equations: None,
            discrete_events: None,
            continuous_events: None,
            subsystems: None,
        };

        let model = derive_odes(&system).expect("Should handle complex networks");
        assert_eq!(model.variables.len(), 4);
        assert_eq!(model.equations.len(), 4);

        // Each species should have an equation
        for species_name in &["A", "B", "C", "D"] {
            let found = model.equations.iter().any(|eq| match &eq.lhs {
                Expr::Operator(node) if node.op == "D" => match &node.args[0] {
                    Expr::Variable(name) => name == species_name,
                    _ => false,
                },
                _ => false,
            });
            assert!(found, "Should have equation for species {species_name}");
        }
    }

    #[test]
    #[cfg(feature = "parallel")]
    fn test_stoichiometric_matrix_parallel() {
        use std::collections::HashMap;

        let system = ReactionSystem {
            coupletype: None,
            reference: None,
            species: [
                create_test_species("A"),
                create_test_species("B"),
                create_test_species("C"),
            ]
            .into_iter()
            .collect::<std::collections::HashMap<_, _>>(),
            parameters: HashMap::new(),
            reactions: vec![
                // A -> B
                create_test_reaction(
                    vec![("A", 1.0)],
                    vec![("B", 1.0)],
                    Expr::Variable("k1".to_string()),
                ),
                // B -> C
                create_test_reaction(
                    vec![("B", 1.0)],
                    vec![("C", 1.0)],
                    Expr::Variable("k2".to_string()),
                ),
            ],
            constraint_equations: None,
            discrete_events: None,
            continuous_events: None,
            subsystems: None,
        };

        // Test the parallel version
        let parallel_matrix = crate::reactions::stoichiometric_matrix_parallel(&system)
            .expect("Parallel stoichiometric matrix should work");

        // Test the sequential version for comparison
        let sequential_matrix = stoichiometric_matrix(&system);

        // Both should produce the same result
        assert_eq!(parallel_matrix.len(), sequential_matrix.len());
        assert_eq!(parallel_matrix[0].len(), sequential_matrix[0].len());

        for (i, row) in parallel_matrix.iter().enumerate() {
            for (j, &val) in row.iter().enumerate() {
                assert_eq!(
                    val, sequential_matrix[i][j],
                    "Parallel and sequential results should match at position [{i}, {j}]"
                );
            }
        }

        // Verify specific values
        assert_eq!(parallel_matrix[0][0], -1.0, "A consumed in reaction 1");
        assert_eq!(parallel_matrix[1][0], 1.0, "B produced in reaction 1");
        assert_eq!(parallel_matrix[1][1], -1.0, "B consumed in reaction 2");
        assert_eq!(parallel_matrix[2][1], 1.0, "C produced in reaction 2");
    }
}
