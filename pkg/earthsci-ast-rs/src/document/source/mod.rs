//! ESM documents as Markdown and Typst sources: the skeleton with its
//! path-keyed fallback, the math entries, and the two containers.
//!
//! Port of `formal/Esm/Document/Source/`, one module per Lean file with
//! executable definitions (`Facts.lean`, `SkeletonRT.lean` and
//! `YamlLines.lean` hold only proofs):
//!
//! | Rust | Lean |
//! |---|---|
//! | [`keys`] | `Keys.lean` |
//! | [`lines`] | `Lines.lean` |
//! | [`text`] | `Text.lean` |
//! | [`skeleton`] | `Skeleton.lean` |
//! | [`items`] | `Items.lean` |
//! | [`reaction`] | `Reaction.lean` |
//! | [`equation`] | `Equation.lean` |
//! | [`multi_line`] | `MultiLine.lean` |
//! | [`markdown`] | `Markdown.lean` |
//! | [`markdown_doc`] | `MarkdownDoc.lean` |
//! | [`typst`] | `Typst.lean` |
//! | [`typst_doc`] | `TypstDoc.lean` |
//!
//! [`sources`] has no Lean counterpart: it runs the same readers keeping where
//! each construct is written, for tools that show a document's source.

pub mod equation;
pub mod items;
pub mod keys;
pub mod lines;
pub mod markdown;
pub mod markdown_doc;
pub mod multi_line;
pub mod reaction;
pub mod skeleton;
pub mod sources;
pub mod text;
pub mod typst;
pub mod typst_doc;

use crate::document::json::Json;

/// `Source.Md.printMd` (MarkdownDoc.lean).
pub fn print_md(d: &Json) -> String {
    markdown_doc::print_md(d)
}

/// `Source.Md.parseMd` (MarkdownDoc.lean).
pub fn parse_md(text: &str) -> Option<Json> {
    markdown_doc::parse_md(text)
}

/// `Source.Typ.printTyp` (TypstDoc.lean).
pub fn print_typ(d: &Json) -> String {
    typst_doc::print_typ(d)
}

/// `Source.Typ.parseTyp` (TypstDoc.lean).
pub fn parse_typ(text: &str) -> Option<Json> {
    typst_doc::parse_typ(text)
}

/// [`parse_md`], with each construct's JSON pointer and byte range
/// ([`sources::read_sourced`]).
pub fn parse_md_sourced(text: &str) -> Option<sources::Sourced> {
    sources::read_sourced(
        text,
        markdown_doc::lex_doc_spanned,
        &|s, raw| crate::document::math::parse_latex(s, raw),
        &markdown_doc::ck_mdx,
    )
}

/// [`parse_typ`], with each construct's JSON pointer and byte range.
pub fn parse_typ_sourced(text: &str) -> Option<sources::Sourced> {
    sources::read_sourced(
        text,
        typst_doc::lex_doc_spanned,
        &|s, raw| crate::document::math::parse_typst(s, raw),
        &typst_doc::ck_tx,
    )
}
