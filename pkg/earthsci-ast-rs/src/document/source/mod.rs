//! ESM documents as Markdown and Typst sources: the skeleton with its
//! path-keyed fallback, the math entries, and the two containers.
//!
//! Port of `formal/Esm/Document/Source/`.

use crate::document::json::Json;

/// `Source.canonDoc` (Skeleton.lean): a JSON object, well formed, with sorted
/// keys at every depth.
pub fn canon_doc(_d: &Json) -> bool {
    todo!("source layer")
}

/// `Source.Md.printMd` (MarkdownDoc.lean).
pub fn print_md(_d: &Json) -> String {
    todo!("source layer")
}

/// `Source.Md.parseMd` (MarkdownDoc.lean).
pub fn parse_md(_text: &str) -> Option<Json> {
    todo!("source layer")
}

/// `Source.Typ.printTyp` (TypstDoc.lean).
pub fn print_typ(_d: &Json) -> String {
    todo!("source layer")
}

/// `Source.Typ.parseTyp` (TypstDoc.lean).
pub fn parse_typ(_text: &str) -> Option<Json> {
    todo!("source layer")
}
