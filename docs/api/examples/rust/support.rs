//! Shared by every example: locate the `.esm` documents in
//! `docs/api/examples/fixtures/`, relative to this crate rather than the
//! process's working directory.

use std::path::PathBuf;

/// The path of the shared fixture `name` (for example `"decay.esm"`).
pub fn fixture(name: &str) -> PathBuf {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../fixtures")
        .join(name);
    assert!(path.exists(), "fixture {} is missing", path.display());
    path
}
