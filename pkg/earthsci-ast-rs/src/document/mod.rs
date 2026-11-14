//! ESM documents as Markdown and Typst source text.
//!
//! An `.esm` document can be written as Markdown (LaTeX math, remark-directive
//! directives, YAML front matter and container bodies) or as Typst (Typst math,
//! `esm` package functions, Typst dictionaries). Both formats are lossless:
//! printing a document and reading it back gives the document again, and prose
//! between the constructs never changes what is read.
//!
//! The specification of both formats is the Lean model in `formal/`:
//! `formal/Esm/Document/Notation.lean` is the notation table, and this module
//! is a port of the executable definitions under `formal/Esm/Document/`, laid
//! out file by file:
//!
//! | Rust | Lean |
//! |---|---|
//! | [`json`] | `Json.lean` (the value type, canonical numbers) |
//! | [`number`] | `Number.lean` |
//! | [`strings`] | `Strings.lean` |
//! | [`yaml`] | `Yaml.lean` |
//! | [`typst_dict`] | `TypstDict.lean` |
//! | [`math`] | `Math/*.lean` |
//! | [`source`] | `Source/*.lean` |
//!
//! The golden set every binding reproduces is
//! `tests/conformance/document_format/` (CONFORMANCE_SPEC §5.58).

pub(crate) mod json;
pub(crate) mod math;
pub(crate) mod number;
pub(crate) mod source;
pub(crate) mod strings;
pub(crate) mod typst_dict;
pub(crate) mod yaml;

use crate::canonicalize::canonicalize_document;
use crate::diagnostic::{DiagnosticError, codes};

/// Which source format a document is written in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DocumentFormat {
    /// Markdown with LaTeX math.
    Markdown,
    /// Typst.
    Typst,
}

/// The document value the printers take: `canonicalize_document` applied, then
/// every object's keys sorted, as the Lean printers require (`Source.canonDoc`).
fn printable(doc: &serde_json::Map<String, serde_json::Value>) -> json::Json {
    let canon = canonicalize_document(&serde_json::Value::Object(doc.clone()));
    json::sort_keys(&json::from_serde(&canon))
}

/// Print an ESM document as Markdown (`Source.Md.printMd`).
///
/// The document is put in canonical form first (`canonicalize_document`), so
/// two documents that canonicalize alike print alike, and
/// `parse_markdown(&print_markdown(d))` is `canonicalize_document(d)`.
pub fn print_markdown(doc: &serde_json::Map<String, serde_json::Value>) -> String {
    source::print_md(&printable(doc))
}

/// Print an ESM document as Typst (`Source.Typ.printTyp`). See
/// [`print_markdown`].
pub fn print_typst(doc: &serde_json::Map<String, serde_json::Value>) -> String {
    source::print_typ(&printable(doc))
}

/// Print an ESM document in the given format.
pub fn print_document(
    doc: &serde_json::Map<String, serde_json::Value>,
    format: DocumentFormat,
) -> String {
    match format {
        DocumentFormat::Markdown => print_markdown(doc),
        DocumentFormat::Typst => print_typst(doc),
    }
}

/// Read a Markdown ESM document (`Source.Md.parseMd`). The result is in
/// canonical form.
///
/// # Errors
///
/// A [`DiagnosticError`] with code `removed_op` when the text uses an operator
/// removed from the format (spec §4.2), and `parse_error` for any other text
/// that is not a Markdown ESM document.
pub fn parse_markdown(text: &str) -> Result<serde_json::Value, DiagnosticError> {
    match source::parse_md(text) {
        Some(d) => Ok(json::to_serde(&d)),
        None => Err(refusal(text, DocumentFormat::Markdown)),
    }
}

/// Read a Typst ESM document (`Source.Typ.parseTyp`). See [`parse_markdown`].
///
/// # Errors
///
/// As [`parse_markdown`].
pub fn parse_typst(text: &str) -> Result<serde_json::Value, DiagnosticError> {
    match source::parse_typ(text) {
        Some(d) => Ok(json::to_serde(&d)),
        None => Err(refusal(text, DocumentFormat::Typst)),
    }
}

/// Read an ESM document written in the given format.
///
/// # Errors
///
/// As [`parse_markdown`].
pub fn parse_document(
    text: &str,
    format: DocumentFormat,
) -> Result<serde_json::Value, DiagnosticError> {
    match format {
        DocumentFormat::Markdown => parse_markdown(text),
        DocumentFormat::Typst => parse_typst(text),
    }
}

/// The diagnostic for a text the reader refused. The Lean reader refuses every
/// bad input alike; the code comes from the specification: a removed operator
/// written in the call form or the escape form is refused by name
/// (CONFORMANCE §7.1), everything else is a parse error.
fn refusal(text: &str, format: DocumentFormat) -> DiagnosticError {
    match removed_op_in(text, format) {
        Some(op) => DiagnosticError {
            code: codes::REMOVED_OP,
            message: format!("`{op}` was removed from the format (esm-spec §4.2)"),
        },
        None => DiagnosticError {
            code: codes::PARSE_ERROR,
            message: match format {
                DocumentFormat::Markdown => "not an ESM Markdown document".to_string(),
                DocumentFormat::Typst => "not an ESM Typst document".to_string(),
            },
        },
    }
}

/// The first removed operator the text writes in a call or escape form:
/// `\operatorname{op}` / `\esm{op}` in LaTeX (with `\_` for `_`), `op("op")` /
/// `esm.node("op"` in Typst.
fn removed_op_in(text: &str, format: DocumentFormat) -> Option<&'static str> {
    let named = |name: &str| math::expr::REMOVED_OPS.iter().copied().find(|o| *o == name);
    match format {
        DocumentFormat::Markdown => ["\\operatorname{", "\\esm{"].iter().find_map(|open| {
            text.match_indices(open).find_map(|(i, _)| {
                let rest = &text[i + open.len()..];
                let body = &rest[..rest.find('}')?];
                named(&body.replace("\\_", "_"))
            })
        }),
        DocumentFormat::Typst => ["op(\"", "esm.node(\""].iter().find_map(|open| {
            text.match_indices(open).find_map(|(i, _)| {
                let rest = &text[i + open.len()..];
                named(&rest[..rest.find('"')?])
            })
        }),
    }
}
