//! Top-level validation surface for ESM files.
//!
//! This module owns the public [`ValidationResult`] / [`SchemaError`] /
//! [`StructuralError`] types and the orchestrator entry points
//! ([`validate`], [`validate_complete`], [`validate_with_schema`]). The
//! actual checks are delegated to:
//!
//! - [`crate::structural`] — equation balance, model references, reactions,
//!   discrete events, and inter-model dependency cycles.
//! - [`crate::coupling`] — coupling-entry well-formedness and scoped
//!   references between systems.
//!
//! The [`SystemInfo`] map produced by [`build_system_reference_map`] is the
//! shared input both submodules consume.

use crate::EsmFile;
use crate::parse::{load, validate_schema};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};

/// Result of structural validation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ValidationResult {
    /// Schema validation errors
    pub schema_errors: Vec<SchemaError>,
    /// Structural validation errors
    pub structural_errors: Vec<StructuralError>,
    /// Unit validation warnings (non-fatal issues)
    pub unit_warnings: Vec<String>,
    /// Whether validation passed (no schema or structural errors)
    pub is_valid: bool,
}

impl ValidationResult {
    /// Check if there are any errors (schema or structural)
    pub fn has_errors(&self) -> bool {
        !self.schema_errors.is_empty() || !self.structural_errors.is_empty()
    }

    /// Structural errors, cloned (legacy shim: prefer reading
    /// `structural_errors` — and `schema_errors`, which this does NOT
    /// include — directly).
    #[deprecated(note = "read the structural_errors / schema_errors fields directly")]
    pub fn errors(&self) -> Vec<StructuralError> {
        self.structural_errors.clone()
    }
}

/// A schema validation error
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SchemaError {
    /// Path to the problematic element
    pub path: String,
    /// Error message
    pub message: String,
    /// Keyword that failed (e.g., "required", "type", "enum")
    pub keyword: String,
}

/// A structural validation error
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StructuralError {
    /// Path to the problematic element
    pub path: String,
    /// Error code (matching spec codes)
    pub code: StructuralErrorCode,
    /// Error message
    pub message: String,
    /// Additional error details
    pub details: serde_json::Value,
}

/// Error codes for structural validation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum StructuralErrorCode {
    /// Undefined variable reference
    UndefinedVariable,
    /// Number of equations doesn't match state variables
    EquationCountMismatch,
    /// Undefined species in reactions
    UndefinedSpecies,
    /// Undefined parameter in expressions
    UndefinedParameter,
    /// Reaction with both substrates and products null
    NullReaction,
    /// Observed variable missing expression
    MissingObservedExpr,
    /// Scoped reference cannot be resolved
    UnresolvedScopedRef,
    /// Variable in event is not declared
    EventVarUndeclared,
    /// Operator referenced but not declared
    UndefinedOperator,
    /// Discrete parameter not properly declared
    InvalidDiscreteParam,
    /// System referenced but not declared
    UndefinedSystem,
    /// Data loader variable not provided
    DataLoaderVariableMissing,
    /// Operator variable not available
    OperatorVariableMissing,
    /// Circular dependency detected
    CircularDependency,
    /// Reaction rate expression has incompatible units for reaction stoichiometry
    UnitInconsistency,
    /// An `ic`-op equation placed inside a reaction system's `constraint_equations`
    IcInReactionSystem,
    /// A `variable_map` expression transform carries a `factor` (esm-spec
    /// §10.4: the expression spells its own arithmetic — fold scaling into it)
    FactorWithExpressionTransform,
}

impl std::fmt::Display for StructuralErrorCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            Self::UndefinedVariable => "undefined_variable",
            Self::EquationCountMismatch => "equation_count_mismatch",
            Self::UndefinedSpecies => "undefined_species",
            Self::UndefinedParameter => "undefined_parameter",
            Self::NullReaction => "null_reaction",
            Self::MissingObservedExpr => "missing_observed_expr",
            Self::UnresolvedScopedRef => "unresolved_scoped_ref",
            Self::EventVarUndeclared => "event_var_undeclared",
            Self::UndefinedOperator => "undefined_operator",
            Self::InvalidDiscreteParam => "invalid_discrete_param",
            Self::UndefinedSystem => "undefined_system",
            Self::DataLoaderVariableMissing => "data_loader_variable_missing",
            Self::OperatorVariableMissing => "operator_variable_missing",
            Self::CircularDependency => "circular_dependency",
            Self::UnitInconsistency => "unit_inconsistency",
            Self::IcInReactionSystem => "ic_in_reaction_system",
            Self::FactorWithExpressionTransform => "factor_with_expression_transform",
        };
        write!(f, "{s}")
    }
}

/// Perform structural validation on an ESM file
///
/// **Note**: This function performs ONLY structural validation, not schema validation.
/// For comprehensive validation (both schema and structural), use `validate_complete()` instead.
///
/// This function runs the structural checks (delegating to
/// [`crate::structural`] and [`crate::coupling`]):
/// - All variable references are defined (including scoped refs resolved via
///   the subsystem hierarchy)
/// - Equation-unknown balance (ODE count vs. state variables)
/// - Observed variables carry expressions
/// - Discrete/continuous event references
/// - Reaction species/stoichiometry consistency
/// - Coupling-entry well-formedness
/// - Dimensional consistency of equations — reported as `unit_warnings`,
///   never as errors
///
/// # Arguments
///
/// * `esm_file` - The ESM file to validate (already parsed and schema-validated)
///
/// # Returns
///
/// * `ValidationResult` - Structural validation results (schema_errors will always be empty)
///
/// # Examples
///
/// ```rust
/// use earthsci_toolkit::{validate, load, EsmFile, Metadata};
///
/// let json_str = r#"
/// {
///   "esm": "0.1.0",
///   "metadata": {"name": "test"},
///   "models": {"simple": {"variables": {}, "equations": []}}
/// }
/// "#;
///
/// // First load and parse (includes schema validation)
/// let esm_file = load(json_str).unwrap();
///
/// // Then do structural validation
/// let result = validate(&esm_file);
/// assert!(result.is_valid);
/// assert!(result.schema_errors.is_empty()); // Always empty for this function
/// ```
pub fn validate(esm_file: &EsmFile) -> ValidationResult {
    let schema_errors = Vec::new();
    let mut structural_errors = Vec::new();
    let mut unit_warnings = Vec::new();

    // First validate schema if we have access to JSON
    // Note: In practice, this would be called with the original JSON string
    // For now, we focus on structural validation

    // Build system reference map for scoped reference validation
    let system_refs = build_system_reference_map(esm_file);

    // Validate models
    if let Some(ref models) = esm_file.models {
        for (model_name, model) in models {
            crate::structural::validate_model(
                esm_file,
                model_name,
                model,
                &system_refs,
                &mut structural_errors,
                &mut unit_warnings,
            );
            crate::structural::validate_model_gradient_units(
                esm_file,
                model_name,
                model,
                &mut structural_errors,
            );
        }

        // Check for circular dependencies between models
        crate::structural::check_circular_dependencies_in_models(models, &mut structural_errors);
    }

    // Validate reaction systems
    if let Some(ref reaction_systems) = esm_file.reaction_systems {
        for (rs_name, rs) in reaction_systems {
            crate::structural::validate_reaction_system(
                rs_name,
                rs,
                &system_refs,
                &mut structural_errors,
            );
        }
    }

    // Validate coupling
    if let Some(ref coupling) = esm_file.coupling {
        crate::coupling::validate_coupling(
            coupling,
            &system_refs,
            esm_file,
            &mut structural_errors,
        );
    }

    let is_valid = schema_errors.is_empty() && structural_errors.is_empty();

    ValidationResult {
        schema_errors,
        structural_errors,
        unit_warnings,
        is_valid,
    }
}

/// Validate an ESM file completely (schema + structural validation)
///
/// This is the main validation function that performs both schema and structural validation.
/// Most users should use this function instead of the lower-level `validate()`.
///
/// # Arguments
///
/// * `json_str` - The original JSON string to validate
///
/// # Returns
///
/// * `ValidationResult` - Comprehensive validation results with both schema and structural errors
pub fn validate_complete(json_str: &str) -> ValidationResult {
    // First try to parse the JSON and ESM file
    match load(json_str) {
        Ok(esm_file) => {
            // If parsing/schema validation succeeded, do structural validation
            validate_with_schema(json_str, &esm_file)
        }
        Err(e) => {
            // If parsing failed, return the error as a schema error
            ValidationResult {
                schema_errors: vec![SchemaError {
                    path: "".to_string(),
                    message: format!("Failed to load ESM file: {e}"),
                    keyword: "parse".to_string(),
                }],
                structural_errors: vec![],
                unit_warnings: vec![],
                is_valid: false,
            }
        }
    }
}

/// Validate an ESM file including schema validation
///
/// This function combines schema and structural validation.
/// Note: Consider using `validate_complete()` instead for a simpler API.
pub fn validate_with_schema(json_str: &str, esm_file: &EsmFile) -> ValidationResult {
    let mut schema_errors = Vec::new();
    let mut structural_errors = Vec::new();
    let mut unit_warnings = Vec::new();

    // Schema validation
    match serde_json::from_str::<Value>(json_str) {
        Err(e) => {
            schema_errors.push(SchemaError {
                path: "".to_string(),
                message: format!("Invalid JSON: {e}"),
                keyword: "format".to_string(),
            });
        }
        Ok(json_value) => {
            if let Err(e) = validate_schema(&json_value) {
                schema_errors.push(SchemaError {
                    path: "".to_string(),
                    message: e.to_string(),
                    keyword: "schema".to_string(),
                });
            }
        }
    }

    // Continue with structural validation even if schema fails
    let result = validate(esm_file);
    structural_errors.extend(result.structural_errors);
    unit_warnings.extend(result.unit_warnings);

    let is_valid = schema_errors.is_empty() && structural_errors.is_empty();

    ValidationResult {
        schema_errors,
        structural_errors,
        unit_warnings,
        is_valid,
    }
}

/// Build a map of all system references for scoped reference resolution.
///
/// Shared between [`crate::structural`] and [`crate::coupling`]; not part of
/// the public API.
pub(crate) fn build_system_reference_map(esm_file: &EsmFile) -> HashMap<String, SystemInfo> {
    let mut systems = HashMap::new();

    // Add models
    if let Some(ref models) = esm_file.models {
        for (name, model) in models {
            let variables: HashSet<String> = model.variables.keys().cloned().collect();
            systems.insert(
                name.clone(),
                SystemInfo {
                    _system_type: SystemType::Model,
                    variables,
                    species: HashSet::new(),
                    parameters: HashSet::new(),
                },
            );
        }
    }

    // Add reaction systems
    if let Some(ref reaction_systems) = esm_file.reaction_systems {
        for (name, rs) in reaction_systems {
            let species: HashSet<String> = rs.species.keys().cloned().collect();
            systems.insert(
                name.clone(),
                SystemInfo {
                    _system_type: SystemType::ReactionSystem,
                    variables: HashSet::new(),
                    species,
                    parameters: HashSet::new(),
                },
            );
        }
    }

    // Add data loaders. Schema-level variable names (keys of DataLoader.variables)
    // are what coupling `from`/`to` references point at, so they go in `variables`.
    if let Some(ref data_loaders) = esm_file.data_loaders {
        for (name, loader) in data_loaders {
            let variables: HashSet<String> = loader.variables.keys().cloned().collect();
            systems.insert(
                name.clone(),
                SystemInfo {
                    _system_type: SystemType::DataLoader,
                    variables,
                    species: HashSet::new(),
                    parameters: HashSet::new(),
                },
            );
        }
    }

    // Add operators
    if let Some(ref operators) = esm_file.operators {
        for name in operators.keys() {
            systems.insert(
                name.clone(),
                SystemInfo {
                    _system_type: SystemType::Operator,
                    variables: HashSet::new(),
                    species: HashSet::new(),
                    parameters: HashSet::new(),
                },
            );
        }
    }

    systems
}

#[derive(Debug, Clone)]
pub(crate) struct SystemInfo {
    pub(crate) _system_type: SystemType,
    pub(crate) variables: HashSet<String>,
    pub(crate) species: HashSet<String>,
    pub(crate) parameters: HashSet<String>,
}

#[derive(Debug, Clone)]
pub(crate) enum SystemType {
    Model,
    ReactionSystem,
    DataLoader,
    Operator,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Equation, ExpressionNode, Metadata, ModelVariable, VariableType};
    use crate::{Expr, Model};
    use std::collections::HashMap;

    #[test]
    fn test_validate_empty_file() {
        let esm_file = EsmFile {
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
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
            reaction_systems: None,
            data_loaders: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        let result = validate(&esm_file);
        assert!(result.is_valid);
        assert!(result.structural_errors.is_empty());
        assert!(result.schema_errors.is_empty());
    }

    #[test]
    fn test_validate_model_with_undefined_variable() {
        let mut models = HashMap::new();
        let mut variables = HashMap::new();
        variables.insert(
            "x".to_string(),
            ModelVariable {
                var_type: VariableType::State,
                units: None,
                default: None,
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        models.insert(
            "test".to_string(),
            Model {
                reference: None,
                coupletype: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
                variables,
                equations: vec![Equation {
                    lhs: Expr::Operator(ExpressionNode {
                        op: "D".to_string(),
                        args: vec![Expr::Variable("x".to_string())],
                        wrt: Some("t".to_string()),
                        dim: None,
                        ..Default::default()
                    }),
                    rhs: Expr::Variable("undefined_var".to_string()), // This should cause an error
                }],
                discrete_events: None,
                continuous_events: None,
                description: None,
                tolerance: None,
                tests: None,
                initialization_equations: None,
                guesses: None,
                system_kind: None,
            },
        );

        let esm_file = EsmFile {
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
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

        let result = validate(&esm_file);
        assert!(!result.is_valid);
        assert!(!result.structural_errors.is_empty());
        assert!(
            result.structural_errors[0]
                .message
                .contains("Variable 'undefined_var' referenced in equation is not declared")
        );
        assert!(matches!(
            result.structural_errors[0].code,
            StructuralErrorCode::UndefinedVariable
        ));
    }

    #[test]
    fn test_equation_count_mismatch() {
        let mut models = HashMap::new();
        let mut variables = HashMap::new();

        // Define two state variables
        variables.insert(
            "x".to_string(),
            ModelVariable {
                var_type: VariableType::State,
                units: None,
                default: None,
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );
        variables.insert(
            "y".to_string(),
            ModelVariable {
                var_type: VariableType::State,
                units: None,
                default: None,
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        models.insert(
            "test".to_string(),
            Model {
                reference: None,
                coupletype: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
                variables,
                equations: vec![
                    // Only one equation for two state variables
                    Equation {
                        lhs: Expr::Operator(ExpressionNode {
                            op: "D".to_string(),
                            args: vec![Expr::Variable("x".to_string())],
                            wrt: Some("t".to_string()),
                            dim: None,
                            ..Default::default()
                        }),
                        rhs: Expr::Variable("x".to_string()),
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
            },
        );

        let esm_file = EsmFile {
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
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

        let result = validate(&esm_file);
        assert!(!result.is_valid);
        assert!(!result.structural_errors.is_empty());

        let error = &result.structural_errors[0];
        assert!(matches!(
            error.code,
            StructuralErrorCode::EquationCountMismatch
        ));
        assert!(
            error.message.contains(
                "Number of ODE equations (1) does not match number of state variables (2)"
            )
        );
    }

    #[test]
    fn test_validation_result_structure() {
        // Test that the new ValidationResult structure works as expected
        let esm_file = EsmFile {
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
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
            reaction_systems: None,
            data_loaders: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        let result = validate(&esm_file);

        // Check the new structure
        assert!(result.is_valid);
        assert!(result.schema_errors.is_empty());
        assert!(result.structural_errors.is_empty());
        assert!(result.unit_warnings.is_empty());
    }

    #[test]
    fn test_missing_observed_expression() {
        let mut models = HashMap::new();
        let mut variables = HashMap::new();

        // Observed variable without expression - should cause validation error
        variables.insert(
            "total".to_string(),
            ModelVariable {
                var_type: VariableType::Observed,
                units: None,
                default: None,
                description: None,
                expression: None, // Missing expression
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        models.insert(
            "test".to_string(),
            Model {
                reference: None,
                coupletype: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
                variables,
                equations: vec![], // No equations needed for this test
                discrete_events: None,
                continuous_events: None,
                description: None,
                tolerance: None,
                tests: None,
                initialization_equations: None,
                guesses: None,
                system_kind: None,
            },
        );

        let esm_file = EsmFile {
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
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

        let result = validate(&esm_file);
        // Should fail validation due to missing expression
        assert!(!result.is_valid);
        assert_eq!(result.structural_errors.len(), 1);
        assert!(matches!(
            result.structural_errors[0].code,
            StructuralErrorCode::MissingObservedExpr
        ));
        assert!(
            result.structural_errors[0]
                .message
                .contains("Observed variable \"total\" is missing its expression field")
        );
    }

    #[test]
    fn test_observed_variable_with_expression() {
        let mut models = HashMap::new();
        let mut variables = HashMap::new();

        // State variable
        variables.insert(
            "x".to_string(),
            ModelVariable {
                var_type: VariableType::State,
                units: Some("m".to_string()),
                default: Some(1.0),
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        // Parameter
        variables.insert(
            "k".to_string(),
            ModelVariable {
                var_type: VariableType::Parameter,
                units: Some("1/s".to_string()),
                default: Some(0.1),
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        // Observed variable WITH expression - should pass validation
        variables.insert(
            "rate".to_string(),
            ModelVariable {
                var_type: VariableType::Observed,
                units: Some("m/s".to_string()),
                default: None,
                description: Some("Rate of change".to_string()),
                expression: Some(Expr::Operator(ExpressionNode {
                    op: "*".to_string(),
                    args: vec![
                        Expr::Variable("k".to_string()),
                        Expr::Variable("x".to_string()),
                    ],
                    wrt: None,
                    dim: None,
                    ..Default::default()
                })),
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        models.insert(
            "test".to_string(),
            Model {
                reference: None,
                coupletype: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
                variables,
                equations: vec![Equation {
                    lhs: Expr::Operator(ExpressionNode {
                        op: "D".to_string(),
                        args: vec![Expr::Variable("x".to_string())],
                        wrt: Some("t".to_string()),
                        dim: None,
                        ..Default::default()
                    }),
                    rhs: Expr::Variable("rate".to_string()),
                }],
                discrete_events: None,
                continuous_events: None,
                description: None,
                tolerance: None,
                tests: None,
                initialization_equations: None,
                guesses: None,
                system_kind: None,
            },
        );

        let esm_file = EsmFile {
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
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

        let result = validate(&esm_file);
        // Should pass validation - observed variable has expression
        assert!(
            result.is_valid,
            "Validation failed: {:?}",
            result.structural_errors
        );
        assert!(result.structural_errors.is_empty());
    }

    #[test]
    fn test_json_serialization_with_observed_expression() {
        // Test that we can serialize and deserialize observed variables with expressions
        let json_str = r#"{
            "esm": "0.1.0",
            "metadata": {
                "name": "TestModel",
                "description": "Test observed variables with expressions"
            },
            "models": {
                "TestModel": {
                    "variables": {
                        "x": { "type": "state", "units": "m", "default": 1.0 },
                        "k": { "type": "parameter", "units": "1/s", "default": 0.1 },
                        "rate": {
                            "type": "observed",
                            "units": "m/s",
                            "expression": { "op": "*", "args": ["k", "x"] },
                            "description": "Rate of change"
                        }
                    },
                    "equations": [
                        {
                            "lhs": { "op": "D", "args": ["x"], "wrt": "t" },
                            "rhs": "rate"
                        }
                    ]
                }
            }
        }"#;

        // Parse JSON
        let esm_file: EsmFile = serde_json::from_str(json_str).expect("Failed to parse JSON");

        // Validate the model
        let result = validate(&esm_file);
        assert!(
            result.is_valid,
            "Validation should pass: {:?}",
            result.structural_errors
        );

        // Verify the observed variable has the expression
        let model = esm_file.models.as_ref().unwrap().get("TestModel").unwrap();
        let rate_var = model.variables.get("rate").unwrap();
        assert_eq!(rate_var.var_type, VariableType::Observed);
        assert!(
            rate_var.expression.is_some(),
            "Observed variable should have expression"
        );

        // Test serialization back to JSON
        let serialized =
            serde_json::to_string_pretty(&esm_file).expect("Failed to serialize to JSON");

        // Should be able to parse it again
        let _reparsed: EsmFile =
            serde_json::from_str(&serialized).expect("Failed to reparse serialized JSON");
    }

    #[test]
    fn test_unit_validation() {
        let mut models = HashMap::new();
        let mut variables = HashMap::new();

        // State variable with units
        variables.insert(
            "x".to_string(),
            ModelVariable {
                var_type: VariableType::State,
                units: Some("m".to_string()), // meters
                default: Some(1.0),
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        // Parameter with units
        variables.insert(
            "k".to_string(),
            ModelVariable {
                var_type: VariableType::Parameter,
                units: Some("1/s".to_string()), // per second
                default: Some(0.1),
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        models.insert(
            "test".to_string(),
            Model {
                reference: None,
                coupletype: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
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
            },
        );

        let esm_file = EsmFile {
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
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

        let result = validate(&esm_file);
        // Should pass validation - units are dimensionally consistent
        // LHS: d(m)/dt = m/s, RHS: (1/s) * m = m/s
        assert!(
            result.is_valid,
            "Validation should pass: {:?}",
            result.structural_errors
        );
        assert!(result.structural_errors.is_empty());
        // Unit warnings should be empty since dimensions are consistent
        assert!(
            result.unit_warnings.is_empty(),
            "Unit warnings: {:?}",
            result.unit_warnings
        );
    }

    #[test]
    fn test_unit_validation_mismatch() {
        let mut models = HashMap::new();
        let mut variables = HashMap::new();

        // State variable with units
        variables.insert(
            "x".to_string(),
            ModelVariable {
                var_type: VariableType::State,
                units: Some("m".to_string()), // meters
                default: Some(1.0),
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        // Parameter with incompatible units
        variables.insert(
            "k".to_string(),
            ModelVariable {
                var_type: VariableType::Parameter,
                units: Some("kg".to_string()), // mass units (incompatible)
                default: Some(0.1),
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        models.insert(
            "test".to_string(),
            Model {
                reference: None,
                coupletype: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
                variables,
                equations: vec![Equation {
                    lhs: Expr::Operator(ExpressionNode {
                        op: "D".to_string(),
                        args: vec![Expr::Variable("x".to_string())],
                        wrt: Some("t".to_string()),
                        dim: None,
                        ..Default::default()
                    }),
                    rhs: Expr::Variable("k".to_string()), // Just k, not k*x
                }],
                discrete_events: None,
                continuous_events: None,
                description: None,
                tolerance: None,
                tests: None,
                initialization_equations: None,
                guesses: None,
                system_kind: None,
            },
        );

        let esm_file = EsmFile {
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
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

        let result = validate(&esm_file);
        // Should still be structurally valid (no structural errors)
        assert!(result.is_valid, "Structural validation should pass");
        assert!(result.structural_errors.is_empty());
        // But should have unit warnings
        assert!(
            !result.unit_warnings.is_empty(),
            "Should have unit warnings"
        );
        assert!(
            result.unit_warnings[0].contains("Dimension mismatch"),
            "Should contain dimension mismatch warning"
        );
    }

    #[test]
    fn test_unit_validation_integration() {
        // Test that unit validation warnings are properly returned from the main validate function
        let mut models = HashMap::new();
        let mut variables = HashMap::new();

        // State variable with position units
        variables.insert(
            "position".to_string(),
            ModelVariable {
                var_type: VariableType::State,
                units: Some("m".to_string()),
                default: Some(0.0),
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        // Parameter with velocity units - should be compatible
        variables.insert(
            "velocity".to_string(),
            ModelVariable {
                var_type: VariableType::Parameter,
                units: Some("m/s".to_string()),
                default: Some(1.0),
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        models.insert(
            "test_model".to_string(),
            Model {
                reference: None,
                coupletype: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
                variables,
                equations: vec![Equation {
                    lhs: Expr::Operator(ExpressionNode {
                        op: "D".to_string(),
                        args: vec![Expr::Variable("position".to_string())],
                        wrt: Some("t".to_string()),
                        dim: None,
                        ..Default::default()
                    }),
                    rhs: Expr::Variable("velocity".to_string()),
                }],
                discrete_events: None,
                continuous_events: None,
                description: None,
                tolerance: None,
                tests: None,
                initialization_equations: None,
                guesses: None,
                system_kind: None,
            },
        );

        let esm_file = EsmFile {
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("Unit Test".to_string()),
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

        let result = validate(&esm_file);
        // Should pass validation - LHS: d(position)/dt = m/s, RHS: velocity = m/s
        assert!(
            result.is_valid,
            "Validation should pass: {:?}",
            result.structural_errors
        );
        assert!(result.structural_errors.is_empty());
        assert!(
            result.unit_warnings.is_empty(),
            "No unit warnings expected: {:?}",
            result.unit_warnings
        );
    }

    #[test]
    fn test_transcendental_function_units() {
        let mut models = HashMap::new();
        let mut variables = HashMap::new();

        // State variable with units (should cause warning when used in exp)
        variables.insert(
            "x".to_string(),
            ModelVariable {
                var_type: VariableType::State,
                units: Some("m".to_string()), // meters
                default: Some(1.0),
                description: None,
                expression: None,
                shape: None,
                location: None,
                noise_kind: None,
                correlation_group: None,
            },
        );

        models.insert(
            "test".to_string(),
            Model {
                reference: None,
                coupletype: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
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
                        op: "exp".to_string(),
                        args: vec![Expr::Variable("x".to_string())], // exp(x) where x has units - should warn
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
            },
        );

        let esm_file = EsmFile {
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
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

        let result = validate(&esm_file);
        // Should still be structurally valid
        assert!(
            result.is_valid,
            "Structural validation should pass: {result:?}"
        );
        assert!(result.structural_errors.is_empty());
        // But should have unit warnings about exp requiring dimensionless input
        assert!(
            !result.unit_warnings.is_empty(),
            "Should have unit warnings"
        );
        assert!(
            result.unit_warnings[0].contains("must be dimensionless"),
            "Should warn about dimensionless requirement: {:?}",
            result.unit_warnings
        );
    }

    #[test]
    fn test_validate_vs_validate_complete() {
        // Test to demonstrate the difference between validate() and validate_complete()
        // validate() only does structural validation, validate_complete() does both

        // Create a valid EsmFile structure
        let esm_file = EsmFile {
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test".to_string()),
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
            reaction_systems: None,
            data_loaders: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        // JSON that should fail schema validation (has invalid variable type)
        let invalid_json = r#"
        {
            "esm": "0.1.0",
            "metadata": {
                "name": "test"
            },
            "models": {
                "test_model": {
                    "variables": {
                        "x": {
                            "type": "invalid_type_that_should_fail_schema"
                        }
                    },
                    "equations": []
                }
            }
        }
        "#;

        // The validate() function - only does structural validation
        let result1 = validate(&esm_file);

        // The validate_complete() function - does both schema and structural validation
        let result2 = validate_complete(invalid_json);

        // Correct behavior: validate() should have empty schema_errors (it doesn't check schema)
        assert!(
            result1.schema_errors.is_empty(),
            "validate() should have empty schema_errors because it only does structural validation"
        );
        assert!(
            result1.is_valid,
            "validate() should pass structural validation on valid ESM structure"
        );

        // validate_complete() should find schema errors
        assert!(
            !result2.schema_errors.is_empty(),
            "validate_complete() should find schema errors"
        );
        assert!(
            !result2.is_valid,
            "validate_complete() should fail due to schema errors"
        );

        println!(
            "CORRECT BEHAVIOR: validate() found {} schema errors, validate_complete() found {} schema errors",
            result1.schema_errors.len(),
            result2.schema_errors.len()
        );
    }

    #[test]
    fn test_validate_complete_with_schema_errors() {
        // Test the new validate_complete function that should detect schema errors
        let invalid_json = r#"
        {
            "esm": "0.1.0",
            "metadata": {
                "name": "test"
            },
            "models": {
                "test_model": {
                    "variables": {
                        "x": {
                            "type": "invalid_type_that_should_fail_schema"
                        }
                    },
                    "equations": []
                }
            }
        }
        "#;

        let result = validate_complete(invalid_json);

        // Should detect schema errors
        assert!(
            !result.is_valid,
            "validate_complete should detect schema validation failures"
        );
        assert!(
            !result.schema_errors.is_empty(),
            "validate_complete should find schema errors"
        );

        // Schema error should mention the validation failure
        assert!(
            result.schema_errors[0]
                .message
                .contains("Failed to load ESM file"),
            "Should report load failure: {}",
            result.schema_errors[0].message
        );
    }

    #[test]
    fn test_validate_complete_with_valid_json() {
        // Test validate_complete with valid JSON
        let valid_json = r#"
        {
            "esm": "0.1.0",
            "metadata": {
                "name": "test"
            },
            "models": {
                "test_model": {
                    "variables": {
                        "x": {
                            "type": "state",
                            "units": "m",
                            "default": 1.0
                        }
                    },
                    "equations": [
                        {
                            "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                            "rhs": {"op": "*", "args": [0.1, "x"]}
                        }
                    ]
                }
            }
        }
        "#;

        let result = validate_complete(valid_json);

        // Should pass validation
        assert!(
            result.is_valid,
            "validate_complete should pass with valid JSON: {result:?}"
        );
        assert!(
            result.schema_errors.is_empty(),
            "Should have no schema errors"
        );
        assert!(
            result.structural_errors.is_empty(),
            "Should have no structural errors"
        );
    }
}
