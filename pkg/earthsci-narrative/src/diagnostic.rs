//! Problems found in a narrative document, located at the element that has
//! them.

use std::fmt;

use serde::Serialize;

use crate::element::SourceSpan;

/// How bad a [`Diagnostic`] is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    /// The model cannot be built or run as written.
    Error,
    /// The model builds, but something is probably not what the author meant.
    Warning,
}

impl fmt::Display for Severity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Severity::Error => "error",
            Severity::Warning => "warning",
        })
    }
}

/// A character range within an element's own text (an equation's `text`), so
/// a front end can underline the exact spot.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct TextSpan {
    /// 0-based character offset of the first character.
    pub start: usize,
    /// 0-based character offset just past the last character.
    pub end: usize,
}

/// One problem, attached to the element that has it when there is one.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Diagnostic {
    /// Error or warning.
    pub severity: Severity,
    /// A stable identifier for the kind of problem, e.g. `undeclared_name`.
    /// Problems the core validator finds keep its codes.
    pub code: String,
    /// What is wrong, in a sentence.
    pub message: String,
    /// The index of the element with the problem, when it belongs to one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub element: Option<usize>,
    /// That element's source, copied here for convenience.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<SourceSpan>,
    /// The place in the assembled `.esm` document, as a JSON pointer.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// Where in the element's text the problem is.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub span: Option<TextSpan>,
}

impl Diagnostic {
    /// An error with no location yet.
    pub fn error(code: impl Into<String>, message: impl Into<String>) -> Self {
        Diagnostic {
            severity: Severity::Error,
            code: code.into(),
            message: message.into(),
            element: None,
            source: None,
            path: None,
            span: None,
        }
    }

    /// A warning with no location yet.
    pub fn warning(code: impl Into<String>, message: impl Into<String>) -> Self {
        Diagnostic {
            severity: Severity::Warning,
            ..Diagnostic::error(code, message)
        }
    }

    /// Attach the element at `index`, with its source.
    pub fn at(mut self, index: usize, source: Option<&SourceSpan>) -> Self {
        self.element = Some(index);
        self.source = source.cloned();
        self
    }

    /// Attach a JSON pointer into the assembled document.
    pub fn with_path(mut self, path: impl Into<String>) -> Self {
        self.path = Some(path.into());
        self
    }

    /// Attach a character range within the element's text.
    pub fn with_span(mut self, start: usize, end: usize) -> Self {
        self.span = Some(TextSpan { start, end });
        self
    }

    /// Whether this is an error.
    pub fn is_error(&self) -> bool {
        self.severity == Severity::Error
    }
}

impl fmt::Display for Diagnostic {
    /// `file:line:column: error[code]: message`, like a compiler, with
    /// `element N` standing in for an unknown source.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let place = self
            .source
            .as_ref()
            .map(|s| s.to_string())
            .filter(|s| !s.is_empty())
            .or_else(|| self.element.map(|i| format!("element {i}")));
        if let Some(place) = place {
            write!(f, "{place}: ")?;
        }
        write!(f, "{}[{}]: {}", self.severity, self.code, self.message)
    }
}
