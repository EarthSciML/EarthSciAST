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

/// A single-field, string-wrapped error whose [`Display`](std::fmt::Display) is
/// exactly its inner message (`write!(f, "{}", self.0)`).
///
/// This is the shared newtype behind the crate's bare-string error aliases —
/// [`crate::provider::ProviderError`] and [`crate::cadence::CadenceError`] — which
/// previously each declared their own structurally-identical `pub struct X(pub
/// String)` with a `#[error("{0}")]` (bare) `Display`. They are now `pub type`
/// aliases of this type, so their public names and their rendered messages are
/// unchanged.
///
/// Errors whose `Display` prepends a *prefix* (e.g.
/// [`crate::relational::FloatKeyError`] → `"FloatKeyError: {0}"`,
/// [`crate::value_invention::ValueInventionError`] →
/// `"ValueInventionError: {0}"`) deliberately do **not** alias this type: a shared
/// `Display` would change their cross-binding message bytes.
#[derive(Debug, Clone, thiserror::Error)]
#[error("{0}")]
pub struct MessageError(pub String);

#[cfg(test)]
mod tests {
    use super::MessageError;

    // Cross-binding message stability: the rendered `Display` of every
    // string-wrapped error must stay byte-identical (bare vs. prefixed).
    #[test]
    fn message_error_renders_bare_inner_string() {
        assert_eq!(MessageError("boom".into()).to_string(), "boom");
    }

    #[test]
    fn bare_aliases_render_inner_string_unchanged() {
        // Aliases of MessageError — bare `{0}` Display. Constructed via the
        // underlying newtype (a `pub type` alias is not a constructor) but bound
        // to the alias type, so this exercises the alias identity.
        let p: crate::provider::ProviderError = MessageError("p".into());
        let c: crate::cadence::CadenceError = MessageError("c".into());
        assert_eq!(p.to_string(), "p");
        assert_eq!(c.to_string(), "c");
    }

    #[test]
    fn prefixed_errors_keep_their_prefix() {
        // Left separate on purpose — their Display prepends a type-name prefix.
        assert_eq!(
            crate::relational::FloatKeyError("f".into()).to_string(),
            "FloatKeyError: f"
        );
        assert_eq!(
            crate::value_invention::ValueInventionError("v".into()).to_string(),
            "ValueInventionError: v"
        );
    }
}
