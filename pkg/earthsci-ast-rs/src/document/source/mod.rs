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

pub mod equation;
pub mod items;
pub mod keys;
pub mod lines;
pub mod markdown;
pub mod markdown_doc;
pub mod multi_line;
pub mod reaction;
pub mod skeleton;
pub mod text;
pub mod typst;
pub mod typst_doc;

use crate::document::json::Json;

/// `Source.canonDoc` (Skeleton.lean): a JSON object, well formed, with sorted
/// keys at every depth.
#[allow(dead_code)] // part of the contract with `document`; the readers check it via `of_doc`
pub fn canon_doc(d: &Json) -> bool {
    skeleton::canon_doc(d)
}

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
