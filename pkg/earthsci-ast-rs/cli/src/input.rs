//! Reading the documents a command is handed: the text, the base directory a
//! document resolves against, and the `.esm` files under a directory.

use std::fs;
use std::path::PathBuf;

/// Read a UTF-8 input document as JSON text, mapping a read failure to a
/// message that names the offending path (a bare `io::Error` would surface as
/// a Debug dump with no filename). The file's extension picks its format
/// (esm-spec §1.2.1): a Markdown (`.md`) or Typst (`.typ`) source document is
/// read and rendered as JSON, so every subcommand loads it as it would the
/// `.esm` file.
pub(crate) fn read_input(path: &std::path::Path) -> Result<String, Box<dyn std::error::Error>> {
    let text =
        fs::read_to_string(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    match earthsci_ast::document_json_text(&text, path)? {
        std::borrow::Cow::Borrowed(_) => Ok(text),
        std::borrow::Cow::Owned(json) => Ok(json),
    }
}

/// The base directory a document loaded FROM `path` must resolve against: its
/// own directory (esm-spec §4.7 for a relative `ref`, §8.2.1 for a relative
/// `data_sources` location), never the process working directory.
pub(crate) fn base_of(path: &std::path::Path) -> earthsci_ast::LoadOptions {
    earthsci_ast::LoadOptions {
        base_path: Some(
            path.parent()
                .filter(|p| !p.as_os_str().is_empty())
                .unwrap_or_else(|| std::path::Path::new("."))
                .to_path_buf(),
        ),
        ..Default::default()
    }
}

/// `load_string`, but anchored on the file the text came FROM.
///
/// Every subcommand here reads a document with [`read_input`] and then loaded
/// it with a bare `load_string`, which defaults the base to the process working
/// directory. That is downstream finding F7 -- recorded against `round-trip`,
/// but in fact true of ~17 subcommands, `convert` and `simulate` among them --
/// and esm-spec §8.2.1 turns it from cosmetic into dangerous. A CWD-anchored
/// relative `ref` fails loudly with "file not found"; a CWD-anchored relative
/// `url_template` can RESOLVE, succeed, and read a different file, which no
/// assertion about errors can see. Measured before this fix: the same document
/// converted from three working directories emitted three different
/// `url_template` values.
///
/// `validate` and `test` were always right because they use `load_path`. This
/// is the same anchoring for every other command that has a path in hand.
pub(crate) fn load_at(
    path: &std::path::Path,
    content: &str,
) -> Result<earthsci_ast::EsmFile, earthsci_ast::EsmError> {
    earthsci_ast::load_string_with_options(content, &base_of(path))
}

/// Collect every `.esm` file under `dir` (recursing when asked), in sorted
/// order per directory.
pub(crate) fn collect_esm_files(
    dir: &std::path::Path,
    recursive: bool,
    out: &mut Vec<PathBuf>,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut entries: Vec<_> = fs::read_dir(dir)
        .map_err(|e| format!("cannot read directory {}: {e}", dir.display()))?
        .collect::<Result<_, _>>()?;
    entries.sort_by_key(|e| e.path());
    for entry in entries {
        let path = entry.path();
        if path.is_dir() {
            if recursive {
                collect_esm_files(&path, recursive, out)?;
            }
        } else if path.extension().and_then(|e| e.to_str()) == Some("esm") {
            out.push(path);
        }
    }
    Ok(())
}
