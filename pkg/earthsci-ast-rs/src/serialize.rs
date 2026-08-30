//! JSON serialization for ESM files

use crate::{EsmFile, error::EsmError};
use std::path::Path;

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
/// use earthsci_ast::{EsmFile, Metadata, to_json};
///
/// let esm_file = EsmFile {
///     esm: "1.0.0".to_string(),
///     metadata: Metadata {
///         name: Some("test_model".to_string()),
///         ..Default::default()
///     },
///     ..Default::default()
/// };
///
/// let json = to_json(&esm_file).expect("Failed to serialize ESM file");
/// assert!(json.contains("\"esm\": \"1.0.0\""));
/// ```
pub fn to_json(esm_file: &EsmFile) -> Result<String, EsmError> {
    serde_json::to_string_pretty(esm_file).map_err(EsmError::JsonParse)
}

/// Serialize an ESM file to compact JSON string (no pretty printing)
///
/// This function is similar to [`to_json`] but produces compact JSON without
/// extra whitespace, suitable for storage or transmission. It is a separate
/// function rather than a `to_json(file, opts)` flag because Rust has no
/// default arguments and a one-field options struct plus a
/// `to_json_with_options` twin is heavier than the pair.
///
/// # Arguments
///
/// * `esm_file` - The ESM file to serialize
///
/// # Returns
///
/// * `Ok(String)` - Successfully serialized compact JSON string
/// * `Err(EsmError)` - Serialization error
pub fn to_json_compact(esm_file: &EsmFile) -> Result<String, EsmError> {
    serde_json::to_string(esm_file).map_err(EsmError::JsonParse)
}

/// Write an ESM file to `path` as pretty-printed JSON.
///
/// Returns `Ok(())`, never the payload: no function in this API both writes
/// and hands back the serialized bytes — call [`to_json`] when you want the
/// string. (`save` used to return the string here and in TypeScript while
/// WRITING TO DISK in Julia, under the same name.)
pub fn write_path<P: AsRef<Path>>(esm_file: &EsmFile, path: P) -> Result<(), EsmError> {
    let path = path.as_ref();
    let json = to_json(esm_file)?;
    std::fs::write(path, json).map_err(|e| EsmError::FileWrite {
        path: path.display().to_string(),
        source: e,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::var;
    use crate::types::{Equation, Metadata, ModelVariable, VariableType};
    use crate::{Expr, Model};
    use indexmap::IndexMap;

    #[test]
    fn test_save_minimal_file() {
        let esm_file = EsmFile {
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test_model".to_string()),
                ..Default::default()
            },
            ..Default::default()
        };

        let result = to_json(&esm_file);
        assert!(result.is_ok());

        let json = result.unwrap();
        assert!(json.contains("\"esm\": \"0.1.0\""));
        assert!(json.contains("\"name\": \"test_model\""));
    }

    #[test]
    fn test_save_with_model() {
        let mut models = IndexMap::new();
        let mut variables = IndexMap::new();
        variables.insert(
            "x".to_string(),
            ModelVariable {
                default: Some(0.0),
                ..var(VariableType::Unknown, Some("m"))
            },
        );

        models.insert(
            "test".to_string(),
            Model {
                name: Some("Test Model".to_string()),
                variables,
                equations: vec![Equation {
                    lhs: Expr::Variable("d(x)/dt".to_string()),
                    rhs: Expr::Number(1.0),
                }],
                ..Default::default()
            },
        );

        let esm_file = EsmFile {
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test_model".to_string()),
                ..Default::default()
            },
            models: Some(models),
            ..Default::default()
        };

        let result = to_json(&esm_file);
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
            esm: "0.1.0".to_string(),
            metadata: Metadata {
                name: Some("test_model".to_string()),
                ..Default::default()
            },
            ..Default::default()
        };

        let result = to_json_compact(&esm_file);
        assert!(result.is_ok());

        let json = result.unwrap();
        // Compact JSON shouldn't have extra whitespace
        assert!(!json.contains("  "));
        assert!(json.contains("\"esm\":\"0.1.0\""));
    }
}
