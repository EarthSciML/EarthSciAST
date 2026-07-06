//! Shared `{code, message}` diagnostic error for the load-time lowering
//! passes (expression templates / template imports, enum lowering).
//!
//! The `code` field is a STABLE cross-binding diagnostic identifier (e.g.
//! `template_import_unknown_name`, `unknown_enum`) that the conformance
//! fixtures match on — bindings must agree on codes, while `message` prose is
//! binding-local. The per-pass public names (`ExpressionTemplateError`,
//! `EnumLoweringError`) are aliases of this one type so each pass keeps its
//! documented API surface without duplicating the struct and its impls.

/// A lowering-pass diagnostic: stable `code` plus human-readable `message`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiagnosticError {
    /// Stable cross-binding diagnostic code (snake_case).
    pub code: &'static str,
    /// Human-readable description (binding-local prose).
    pub message: String,
}

impl std::fmt::Display for DiagnosticError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "[{}] {}", self.code, self.message)
    }
}

impl std::error::Error for DiagnosticError {}

/// Shorthand constructor used throughout the lowering passes.
pub(crate) fn err(code: &'static str, message: impl Into<String>) -> DiagnosticError {
    DiagnosticError {
        code,
        message: message.into(),
    }
}
