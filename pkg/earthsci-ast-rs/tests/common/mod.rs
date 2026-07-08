//! Shared helpers for the integration-test suite.
//!
//! Fixture files live in the REPO-ROOT `tests/` tree (shared across the five
//! language bindings), two directories above this crate. Every test file
//! previously re-implemented this path climb under a different helper name
//! (`fixture_dir`, `fixture_path`, `fixtures_root`, `fixtures_dir`, ...);
//! use these instead.
//!
//! Each integration-test binary compiles its own copy of this module, so
//! helpers a given binary does not use are expected — hence the allow.
#![allow(dead_code)]

use std::path::PathBuf;

/// The repo-root `tests/` directory (the cross-binding fixture tree).
pub fn repo_tests_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests")
}

/// Absolute path of a fixture given its path relative to the repo-root
/// `tests/` directory (e.g. `"valid/units_conversions.esm"`).
pub fn repo_fixture(rel: &str) -> PathBuf {
    repo_tests_dir().join(rel)
}

/// Read and `load()` a fixture given its repo-root-relative `tests/` path,
/// panicking with the offending path on failure.
pub fn load_repo_fixture(rel: &str) -> earthsci_ast::EsmFile {
    let path = repo_fixture(rel);
    let content = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read fixture {}: {e}", path.display()));
    earthsci_ast::load(&content)
        .unwrap_or_else(|e| panic!("fixture {} does not load: {e}", path.display()))
}
