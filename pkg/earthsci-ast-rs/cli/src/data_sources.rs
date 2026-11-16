//! Reading the files a document's `data_sources` name, for `simulate` and
//! `test`: the library's [`earthsci_ast::bind_data_sources`], with the cache
//! directory this tool uses.

use std::path::PathBuf;

/// Where EarthSciIO's content-addressed cache lives for a CLI run.
///
/// Overridable so a batch runner can point it at fast local scratch; the
/// default is a stable per-user directory rather than a fresh temporary one, so
/// re-running `esm test` over the same sources re-reads bytes it already has.
pub(crate) fn cache_root() -> PathBuf {
    match std::env::var_os("ESM_CACHE_DIR") {
        Some(dir) => PathBuf::from(dir),
        None => std::env::temp_dir().join("earthsci-esm-cache"),
    }
}
