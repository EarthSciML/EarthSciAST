//! A nested §4.7 `subsystems` mount carries a leaf's `join.on` key columns —
//! end to end, through the real loader and the array runtime.
//!
//! The mount renames every mounted variable to `<key>.<name>` and rewrites the
//! `Expr::Variable` references that read them. A `join.on` key column is not
//! one of those: it is a variable reference encoded as a plain STRING on the
//! aggregate node (CONFORMANCE_SPEC §5.5.6), so `map_children` never saw it and
//! `simulate_array/compile.rs::mount_subsystems` left it naming the leaf's bare
//! `left_key` / `right_key` while the registry held only `Leaf.left_key` /
//! `Leaf.right_key`. The build then failed:
//!
//! ```text
//! Unsupported feature 'value-equality join over data-derived columns':
//! join key column 'left_key' does not resolve to a loop index of this
//! aggregate ({"l", "r"})
//! ```
//!
//! The scalar flatten path never had the hole (`flatten.rs::namespace_join_names`
//! exists precisely for it, gated by `join_namespacing.rs`); this file is the
//! array path's equivalent gate. The per-name rewrite rule itself — binders
//! shadow, envelope factors follow, gate symbols do not — is pinned closer to
//! the code, in `compile.rs`'s `subsystem_ragged_and_inspection_tests`.
//!
//! Reported by the downstream EPA MOVES port as finding F1, where the defect
//! meant no relational calculator could be mounted as a nested subsystem at
//! all — every leaf it writes joins on data columns.

#![cfg(not(target_arch = "wasm32"))]

use std::path::{Path, PathBuf};

use earthsci_ast::{SolveOptions, load_path, run_pde_tests_with_base_dir};

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/subsystem_join")
        .join(name)
}

/// Run a fixture's own inline `tests` block through the library runner — the
/// same route `esm test` takes, including `load_path`, which is what resolves
/// the `{"ref": "./join_leaf.esm"}` mount relative to the host document.
fn assert_inline_tests_pass(path: &Path, expected: f64) {
    let file = load_path(path).unwrap_or_else(|e| panic!("{} does not load: {e}", path.display()));
    let results =
        run_pde_tests_with_base_dir(&file, None, &SolveOptions::default(), path.parent());
    assert_eq!(
        results.len(),
        1,
        "{} carries one inline assertion, got {results:?}",
        path.display()
    );
    let r = &results[0];
    assert!(
        r.passed,
        "{}: {} — actual={:?} expected={} {}",
        path.display(),
        r.variable,
        r.actual,
        r.expected,
        r.message
    );
    assert_eq!(r.actual, Some(expected));
}

/// The leaf standalone. It was always right, and that is what attributes the
/// mounted failure to the mount rather than to the leaf.
#[test]
fn the_leaf_alone_matches_two_pairs() {
    assert_inline_tests_pass(&fixture("join_leaf.esm"), 2.0);
}

/// The same leaf mounted as a nested subsystem: `2 x 2 = 4`. This ERRORED at
/// build before the mount learned to carry the join names.
#[test]
fn a_mounted_leaf_keeps_its_join() {
    assert_inline_tests_pass(&fixture("host_mounts_join_leaf.esm"), 4.0);
}
