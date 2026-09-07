//! Issue #207: a gather from a bare `const` array, indexed by a value a
//! document-level coupling supplies, must see the COUPLED value.
//!
//! Two documents that differ only in how the same table is spelled — a bare
//! `const` array against the same table wrapped in an `aggregate` — must
//! produce the same number. They did not: the `const` spelling was folded
//! against the pre-coupling scope and indexed off the end.

#![cfg(not(target_arch = "wasm32"))]

use std::path::{Path, PathBuf};

use earthsci_ast::{SolveOptions, load_path, run_pde_tests_with_base_dir};

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/coupled_const_fold")
        .join(name)
}

fn run(path: &Path) -> Vec<earthsci_ast::PdeAssertionResult> {
    let file = load_path(path).unwrap_or_else(|e| panic!("{} does not load: {e}", path.display()));
    run_pde_tests_with_base_dir(&file, None, &SolveOptions::default(), path.parent())
}

#[test]
fn probe_report() {
    for name in ["probe_chain_constagg.esm", "probe_chain_const.esm"] {
        let results = run(&fixture(name));
        eprintln!("=== {name}: {} result(s)", results.len());
        for r in &results {
            eprintln!(
                "  passed={} var={} actual={:?} expected={} msg={}",
                r.passed, r.variable, r.actual, r.expected, r.message
            );
        }
    }
}
