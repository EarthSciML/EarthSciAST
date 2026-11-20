//! One reader for every document a load reaches by reference (esm-spec §4.7
//! reference formats): a mounted leaf, a template library, a coupling library,
//! and the read-only scan that collects what a mount tree declares.
//!
//! Every reference goes through the same sequence: expand `${VAR}`, look the
//! ref up in the bundled standard library, refuse a remote URL, resolve a path
//! against the referencing document's directory, read, parse. Each caller keeps
//! its own diagnostic wording by mapping [`RefError`].
//!
//! The parse step is [`decode_document`], the esm-spec §1.2.1 read of a
//! document's text by its file extension (Markdown, Typst or JSON). Every other
//! place that reads a document from a path (the root of a load from a path, the
//! problem front door, the inline-test re-read of a source file) uses it too.
//!
//! # File identity
//!
//! A file's identity — the key of every cycle check and of the parse cache —
//! is its `canonicalize()`d path (symlinks resolved), or a bundled file's
//! `esm:std/<name>`. Two spellings of one file, through `..` or a symlink, are
//! therefore one file, so a cycle through a symlink is still a cycle.
//!
//! # Parse cache
//!
//! Within a [`ParseCacheScope`] (one per top-level load), each file is read and
//! parsed once; later reads of the same identity get a clone of the parsed
//! document. Outside a scope every read goes to the file.

use serde_json::Value;
use std::cell::RefCell;
use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};

/// A located reference: where it is, and what it is called.
pub(crate) struct Located {
    /// The file's identity (see the module docs).
    pub(crate) identity: PathBuf,
    /// The directory the file's own relative refs resolve against.
    pub(crate) dir: PathBuf,
    /// The bundled text, for a standard-library file.
    bundled: Option<&'static str>,
}

/// Why a reference could not be read.
pub(crate) enum RefError {
    /// A standard-library ref that names no bundled file.
    Bundled(String),
    /// An `http(s)://` ref; this crate does not fetch.
    Remote,
    /// The path does not resolve to an existing file. `path` is the lexically
    /// normalized join, for messages.
    Missing { path: PathBuf, err: std::io::Error },
    /// The file exists but could not be read.
    Read { path: PathBuf, err: std::io::Error },
    /// The file does not decode in the format its extension names
    /// ([`decode_document`]).
    Parse { path: PathBuf, err: DecodeError },
}

/// Why a document's text did not decode ([`decode_document`]).
#[derive(Debug)]
pub(crate) enum DecodeError {
    /// JSON text that does not parse.
    Json(serde_json::Error),
    /// A Markdown or Typst source document its reader refused: code
    /// `parse_error`, or `removed_op` for a removed operator.
    Source(crate::diagnostic::DiagnosticError),
}

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DecodeError::Json(e) => write!(f, "{e}"),
            DecodeError::Source(e) => write!(f, "{e}"),
        }
    }
}

impl From<DecodeError> for crate::EsmError {
    /// The root's refusal: unparseable JSON as [`crate::EsmError::JsonParse`],
    /// a refused source document as its coded diagnostic (`parse_error` or
    /// `removed_op`).
    fn from(e: DecodeError) -> Self {
        match e {
            DecodeError::Json(e) => crate::EsmError::JsonParse(e),
            DecodeError::Source(d) => crate::EsmError::schema(d),
        }
    }
}

/// The source format a document read from `location` is in (esm-spec §1.2.1):
/// a path, or a URL's path (query and fragment ignored), ending in `.md` is a
/// Markdown source document, one ending in `.typ` a Typst source document, and
/// every other name JSON (`None`). The match is exact and case-sensitive.
pub(crate) fn source_format(location: &Path) -> Option<crate::DocumentFormat> {
    let location = location.to_string_lossy();
    let name: &str = if is_remote(&location) {
        let after_scheme = location.split_once("://").map_or("", |(_, rest)| rest);
        let end = after_scheme.find(['?', '#']).unwrap_or(after_scheme.len());
        &after_scheme[..end]
    } else {
        &location
    };
    if name.ends_with(".md") {
        Some(crate::DocumentFormat::Markdown)
    } else if name.ends_with(".typ") {
        Some(crate::DocumentFormat::Typst)
    } else {
        None
    }
}

/// Decode a document's `text` in the format its `location` names
/// ([`source_format`]); the format is never guessed from the text.
pub(crate) fn decode_document(text: &str, location: &Path) -> Result<Value, DecodeError> {
    match source_format(location) {
        Some(format) => crate::parse_document(text, format).map_err(DecodeError::Source),
        None => serde_json::from_str(text).map_err(DecodeError::Json),
    }
}

/// The §4.7 spelling step on a ref as authored: `${VAR}` expansion (a
/// standard-library ref is taken as written).
pub(crate) fn expand(ref_str: &str) -> String {
    crate::stdlib::expand_ref(ref_str).into_owned()
}

/// Locate an EXPANDED ref against `base`, the referencing document's
/// directory.
pub(crate) fn locate(expanded: &str, base: &Path) -> Result<Located, RefError> {
    match crate::stdlib::resolve(expanded, base) {
        Some(Ok((identity, text))) => {
            let identity = PathBuf::from(identity);
            Ok(Located {
                dir: parent_dir(&identity, base),
                identity,
                bundled: Some(text),
            })
        }
        Some(Err(why)) => Err(RefError::Bundled(why)),
        None => {
            if is_remote(expanded) {
                return Err(RefError::Remote);
            }
            let joined = base.join(expanded);
            let identity = joined.canonicalize().map_err(|err| RefError::Missing {
                path: lexical_normalize(&joined),
                err,
            })?;
            Ok(Located {
                dir: parent_dir(&identity, base),
                identity,
                bundled: None,
            })
        }
    }
}

/// The identity `expanded` would locate to, for a cycle check made before the
/// read: the located identity, or the lexically normalized join when the ref
/// does not locate (the read then reports why).
pub(crate) fn identity_key(expanded: &str, base: &Path) -> PathBuf {
    match locate(expanded, base) {
        Ok(located) => located.identity,
        Err(_) => lexical_normalize(&base.join(expanded)),
    }
}

/// Read and parse a located file, through the parse cache when one is open.
pub(crate) fn read(located: &Located) -> Result<Value, RefError> {
    if let Some(hit) = PARSE_CACHE.with(|c| {
        c.borrow()
            .as_ref()
            .and_then(|m| m.get(&located.identity).cloned())
    }) {
        return Ok(hit);
    }
    let parsed = match located.bundled {
        Some(text) => parse(text, &located.identity)?,
        None => {
            let text =
                std::fs::read_to_string(&located.identity).map_err(|err| RefError::Read {
                    path: located.identity.clone(),
                    err,
                })?;
            parse(&text, &located.identity)?
        }
    };
    PARSE_CACHE.with(|c| {
        if let Some(m) = c.borrow_mut().as_mut() {
            m.insert(located.identity.clone(), parsed.clone());
        }
    });
    Ok(parsed)
}

/// Why a referenced document could not be opened.
pub(crate) enum OpenError {
    /// It could not be read ([`read`]).
    Ref(RefError),
    /// The wire-boundary op checks refused it (`parse::prepare_document_ops`).
    Wire(crate::EsmError),
    /// A version gate for its kind refused it.
    Gate(crate::diagnostic::DiagnosticError),
}

/// The passes every document a load reaches by reference runs first, in
/// order, whatever its kind: read and parse ([`read`]), the wire-boundary op
/// checks (`parse::prepare_document_ops`: removed ops, the `faq` gate, the
/// deprecated-op rewrite), and the version gates its kind gets
/// ([`crate::version_gates::check_file_gates`]). Each kind's own passes follow
/// at its caller:
///
/// * a mounted leaf ([`crate::version_gates::DocKind::MountedLeaf`],
///   `ref_loading::resolve_mount_edge`): the library-target refusals, the edge
///   close, its nested mounts, the edge injection, its §9.7 machinery,
///   lowering and expansion, enum lowering, the nested merge, the edge's
///   index-set rename, its data sources;
/// * a template library (`template_imports::resolve_import_entry`): the
///   library-purity checks, schema validation, its own imports, the edge
///   bindings and `only` filter;
/// * a coupling library (`coupling_imports`): its §10.11 validation and
///   expansion.
///
/// The root document runs the same three first passes in `parse::load_value`,
/// with its version gates in three groups among its other passes.
pub(crate) fn open(
    located: &Located,
    kind: crate::version_gates::DocKind,
) -> Result<Value, OpenError> {
    let mut doc = read(located).map_err(OpenError::Ref)?;
    let authored = crate::parse::prepare_document_ops_scanned(&mut doc).map_err(OpenError::Wire)?;
    crate::version_gates::check_file_gates(&doc, kind, None, &authored).map_err(OpenError::Gate)?;
    Ok(doc)
}

fn parse(text: &str, path: &Path) -> Result<Value, RefError> {
    decode_document(text, path).map_err(|err| RefError::Parse {
        path: path.to_path_buf(),
        err,
    })
}

/// Is `expanded` an `http(s)://` URL?
pub(crate) fn is_remote(expanded: &str) -> bool {
    expanded.starts_with("http://") || expanded.starts_with("https://")
}

fn parent_dir(identity: &Path, fallback: &Path) -> PathBuf {
    identity
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| fallback.to_path_buf())
}

thread_local! {
    static PARSE_CACHE: RefCell<Option<HashMap<PathBuf, Value>>> = const { RefCell::new(None) };
}

/// Opens the per-load parse cache for the current thread while alive. Nested
/// scopes share the outermost one's cache; the outermost drop closes it.
pub(crate) struct ParseCacheScope {
    outermost: bool,
}

impl ParseCacheScope {
    pub(crate) fn on() -> Self {
        let outermost = PARSE_CACHE.with(|c| {
            let mut c = c.borrow_mut();
            if c.is_none() {
                *c = Some(HashMap::new());
                true
            } else {
                false
            }
        });
        ParseCacheScope { outermost }
    }
}

impl Drop for ParseCacheScope {
    fn drop(&mut self) {
        if self.outermost {
            PARSE_CACHE.with(|c| *c.borrow_mut() = None);
        }
    }
}

/// Collapse `.` and `..` components without touching the filesystem.
///
/// `PathBuf::pop` succeeds on a trailing `..`, so a naive `if !out.pop()`
/// wrongly collapses consecutive parent segments (`../../x` → `x`). Only a real
/// (normal) tail is popped; if `out` is empty or already ends in `..`, the `..`
/// escapes the base and survives.
pub(crate) fn lexical_normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for comp in path.components() {
        match comp {
            Component::CurDir => {}
            Component::ParentDir => {
                if matches!(out.components().next_back(), Some(Component::Normal(_))) {
                    out.pop();
                } else {
                    out.push("..");
                }
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn two_spellings_of_one_file_are_one_identity() {
        let dir = tempfile::TempDir::new().unwrap();
        std::fs::create_dir(dir.path().join("sub")).unwrap();
        std::fs::write(dir.path().join("a.esm"), "{}").unwrap();
        let direct = locate("a.esm", dir.path()).ok().unwrap().identity;
        let dotted = locate("sub/../a.esm", dir.path()).ok().unwrap().identity;
        assert_eq!(direct, dotted);
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(dir.path().join("a.esm"), dir.path().join("link.esm"))
                .unwrap();
            let linked = locate("link.esm", dir.path()).ok().unwrap().identity;
            assert_eq!(direct, linked, "a symlink is the file it points at");
        }
    }

    #[test]
    fn the_cache_serves_a_second_read_within_a_scope_only() {
        let dir = tempfile::TempDir::new().unwrap();
        let file = dir.path().join("a.esm");
        std::fs::write(&file, r#"{"v": 1}"#).unwrap();
        {
            let _scope = ParseCacheScope::on();
            let loc = locate("a.esm", dir.path()).ok().unwrap();
            assert_eq!(read(&loc).ok().unwrap()["v"], 1);
            std::fs::write(&file, r#"{"v": 2}"#).unwrap();
            assert_eq!(read(&loc).ok().unwrap()["v"], 1, "cached within the scope");
        }
        let loc = locate("a.esm", dir.path()).ok().unwrap();
        assert_eq!(read(&loc).ok().unwrap()["v"], 2, "no cache outside a scope");
    }
}
