//! JSON serialization for ESM files

use crate::{EsmFile, error::EsmError};

/// Serialize an ESM file to JSON string
///
/// This function converts an `EsmFile` struct back to a JSON string.
/// The output will be pretty-printed for human readability.
///
/// # Arguments
///
/// * `esm_file` - The ESM file to serialize
///
/// # Returns
///
/// * `Ok(String)` - Successfully serialized JSON string
/// * `Err(EsmError)` - Serialization error
///
/// # Examples
///
/// ```rust
/// use earthsci_ast::{EsmFile, Metadata, save};
///
/// let esm_file = EsmFile {
///     esm: "0.1.0".to_string(),
///     metadata: Metadata {
///         name: Some("test_model".to_string()),
///         description: None,
///         authors: None,
///         created: None,
///         modified: None,
///         license: None,
///         tags: None,
///         references: None,
///         system_class: None,
///         dae_info: None,
///         discretized_from: None,
///     },
///     index_sets: None,
///     models: None,
///     reaction_systems: None,
///     data_loaders: None,
///     operators: None,
///     enums: None,
///     coupling: None,
///     domain: None,
///     function_tables: None,
/// };
///
/// let json = save(&esm_file).expect("Failed to serialize ESM file");
/// assert!(json.contains("\"esm\": \"0.1.0\""));
/// ```
pub fn save(esm_file: &EsmFile) -> Result<String, EsmError> {
    serde_json::to_string_pretty(esm_file).map_err(EsmError::JsonParse)
}

/// Serialize an ESM file to compact JSON string (no pretty printing)
///
/// This function is similar to `save` but produces compact JSON without
/// extra whitespace, suitable for storage or transmission.
///
/// # Arguments
///
/// * `esm_file` - The ESM file to serialize
///
/// # Returns
///
/// * `Ok(String)` - Successfully serialized compact JSON string
/// * `Err(EsmError)` - Serialization error
pub fn save_compact(esm_file: &EsmFile) -> Result<String, EsmError> {
    serde_json::to_string(esm_file).map_err(EsmError::JsonParse)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{Equation, Metadata, ModelVariable, VariableType};
    use crate::{Expr, Model};
    use std::collections::HashMap;

    #[test]
    fn test_save_minimal_file() {
        let esm_file = EsmFile {
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
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
            },
            models: None,
            reaction_systems: None,
            data_loaders: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        let result = save(&esm_file);
        assert!(result.is_ok());

        let json = result.unwrap();
        assert!(json.contains("\"esm\": \"0.1.0\""));
        assert!(json.contains("\"name\": \"test_model\""));
    }

    #[test]
    fn test_save_with_model() {
        let mut models = HashMap::new();
        let mut variables = HashMap::new();
        variables.insert(
            "x".to_string(),
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

        models.insert(
            "test".to_string(),
            Model {
                reference: None,
                coupletype: None,
                subsystems: None,
                name: Some("Test Model".to_string()),
                variables,
                equations: vec![Equation {
                    lhs: Expr::Variable("d(x)/dt".to_string()),
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
            },
        );

        let esm_file = EsmFile {
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
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
            },
            models: Some(models),
            reaction_systems: None,
            data_loaders: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        let result = save(&esm_file);
        assert!(result.is_ok());

        let json = result.unwrap();
        assert!(json.contains("\"models\""));
        assert!(json.contains("\"test\""));
        assert!(json.contains("\"variables\""));
        assert!(json.contains("\"equations\""));
    }

    #[test]
    fn test_save_compact() {
        let esm_file = EsmFile {
            domain: None,
            index_sets: None,
            esm: "0.1.0".to_string(),
            metadata: Metadata {
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
            },
            models: None,
            reaction_systems: None,
            data_loaders: None,
            operators: None,
            enums: None,

            coupling: None,
            function_tables: None,
        };

        let result = save_compact(&esm_file);
        assert!(result.is_ok());

        let json = result.unwrap();
        // Compact JSON shouldn't have extra whitespace
        assert!(!json.contains("  "));
        assert!(json.contains("\"esm\":\"0.1.0\""));
    }
}
