//! Error types for the ESM format library

use thiserror::Error;

/// Main error type for the ESM format library
#[derive(Error, Debug)]
pub enum EsmError {
    /// JSON parsing error
    #[error("JSON parse error: {0}")]
    JsonParse(#[from] serde_json::Error),

    /// A Markdown or Typst source document its reader refused as malformed
    /// (esm-spec §1.2.1): the source-format counterpart of
    /// [`EsmError::JsonParse`].
    #[error("Source document parse error: {message}")]
    SourceParse {
        /// Stable cross-binding diagnostic code (`parse_error`).
        code: &'static str,
        /// The rendered message.
        message: String,
    },

    /// Schema validation error
    #[error("Schema validation error: {0}")]
    SchemaValidation(String),

    /// Structural validation error
    #[error("Structural validation error: {0}")]
    StructuralValidation(String),

    /// Failed to read a file from disk (I/O error with the offending path).
    #[error("failed to read {path}: {source}")]
    FileRead {
        /// Path of the file that could not be read.
        path: String,
        /// Underlying I/O error.
        source: std::io::Error,
    },

    /// Failed to write a file to disk (I/O error with the offending path).
    #[error("failed to write {path}: {source}")]
    FileWrite {
        /// Path of the file that could not be written.
        path: String,
        /// Underlying I/O error.
        source: std::io::Error,
    },

    /// A schema-stage load refusal that carries its stable diagnostic code
    /// (`ERROR_CODES`). Renders exactly as [`EsmError::SchemaValidation`]
    /// does with the same message.
    #[error("Schema validation error: {message}")]
    SchemaDiagnostic {
        /// Stable cross-binding diagnostic code (snake_case).
        code: &'static str,
        /// The rendered message.
        message: String,
        /// The structured `(code, path)` findings the refusal located, if any
        /// (a mount edge that does not resolve, at its pointer).
        findings: Vec<crate::validate::StructuralError>,
    },

    /// A structural-stage load refusal that carries its stable diagnostic
    /// code. Renders exactly as [`EsmError::StructuralValidation`] does with
    /// the same message.
    #[error("Structural validation error: {message}")]
    StructuralDiagnostic {
        /// Stable cross-binding diagnostic code (snake_case).
        code: &'static str,
        /// The rendered message.
        message: String,
        /// The structured `(code, path)` findings the refusal located, if any
        /// (an undeclared event variable, an unresolvable coupling reference
        /// or a cross-scope dependency cycle, each at its pointer).
        findings: Vec<crate::validate::StructuralError>,
    },
}

impl EsmError {
    /// A schema-stage refusal from a coded diagnostic, rendered as
    /// `[code] message`.
    pub(crate) fn schema(e: crate::diagnostic::DiagnosticError) -> Self {
        EsmError::SchemaDiagnostic {
            code: e.code,
            message: e.to_string(),
            findings: Vec::new(),
        }
    }

    /// A structural-stage refusal from a coded diagnostic, rendered as
    /// `[code] message`.
    pub(crate) fn structural(e: crate::diagnostic::DiagnosticError) -> Self {
        EsmError::StructuralDiagnostic {
            code: e.code,
            message: e.to_string(),
            findings: Vec::new(),
        }
    }

    /// The stable diagnostic code of a coded refusal, or `None` for an error
    /// that carries none.
    pub fn code(&self) -> Option<&'static str> {
        match self {
            EsmError::SchemaDiagnostic { code, .. }
            | EsmError::StructuralDiagnostic { code, .. }
            | EsmError::SourceParse { code, .. } => Some(code),
            _ => None,
        }
    }

    /// The structured `(code, path)` findings a load refusal located; empty
    /// when it located none.
    pub fn findings(&self) -> &[crate::validate::StructuralError] {
        match self {
            EsmError::SchemaDiagnostic { findings, .. }
            | EsmError::StructuralDiagnostic { findings, .. } => findings,
            _ => &[],
        }
    }
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

impl MessageError {
    /// An error carrying `msg`.
    pub fn new(msg: impl Into<String>) -> Self {
        MessageError(msg.into())
    }
}

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
            crate::value_invention::ValueInventionError::new("v").to_string(),
            "ValueInventionError: v"
        );
    }
}
