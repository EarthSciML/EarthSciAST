//! Error types for the ESM format library

use thiserror::Error;

/// Main error type for the ESM format library
#[derive(Error, Debug)]
pub enum EsmError {
    /// JSON parsing error
    #[error("JSON parse error: {0}")]
    JsonParse(#[from] serde_json::Error),

    /// Schema validation error
    #[error("Schema validation error: {0}")]
    SchemaValidation(String),

    /// Structural validation error
    #[error("Structural validation error: {0}")]
    StructuralValidation(String),

    /// Expression evaluation error
    #[error("Expression evaluation error: {0}")]
    ExpressionEvaluation(String),

    /// Unit validation error
    #[error("Unit validation error: {0}")]
    UnitValidation(String),

    /// Failed to read a file from disk (I/O error with the offending path).
    #[error("failed to read {path}: {source}")]
    FileRead {
        /// Path of the file that could not be read.
        path: String,
        /// Underlying I/O error.
        source: std::io::Error,
    },

    /// Generic error with message
    #[error("{0}")]
    Other(String),
}
