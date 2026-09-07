//! esm-spec §6.6: a component's inline tests do NOT cross a mount edge.
//!
//! A leaf's `tests` are assertions about the leaf under the leaf's OWN
//! standalone conditions. A document that mounts it by a top-level `models`
//! `{ref}` (§4.7 / §9.7.10) may legitimately change those conditions — here a
//! `variable_map` entry replaces the leaf's decay rate `k` with a fivefold
//! forcing — so re-running the leaf's assertions inside the assembly checks a
//! claim its author never made and reports a correct component as broken.
//!
//! Reported against a real coupled assembly as issue #198 item 2, where a leaf
//! that passes standalone contributed 767 ERROR/FAIL rows to the document that
//! mounted it. The fixtures are shared with the Julia and Python bindings
//! (`tests/conformance/mounted_component_tests/`), which pin the same rule.

#![cfg(not(target_arch = "wasm32"))]

use std::path::PathBuf;

use earthsci_ast::{SolveOptions, load_path, run_pde_tests_with_base_dir};

mod common;

fn fixture(name: &str) -> PathBuf {
    common::repo_fixture("conformance/mounted_component_tests/fixtures").join(name)
}

/// Run a fixture's inline tests through the library runner — the route
/// `esm test <file>` takes, `load_path` included, since that is what resolves
/// the mount.
fn run(name: &str) -> Vec<earthsci_ast::PdeAssertionResult> {
    let path = fixture(name);
    let file = load_path(&path).unwrap_or_else(|e| panic!("{} does not load: {e}", path.display()));
    run_pde_tests_with_base_dir(&file, None, &SolveOptions::default(), path.parent())
}

/// The leaf standalone: `k = 1`, so `u(1) = 1/e` and its own assertion holds.
/// This is what attributes a failure inside the assembly to the mount rather
/// than to the leaf.
#[test]
fn the_leaf_alone_passes_its_own_test() {
    let results = run("leaf.esm");
    assert_eq!(results.len(), 1, "leaf carries one assertion: {results:?}");
    assert!(results[0].passed, "{results:?}");
    assert_eq!(results[0].model, "Decay");
}

/// The assembly runs its OWN test and not the mounted leaf's. Before the fix the
/// leaf's assertion ran here too, under `k = 5`, and failed by two orders of
/// magnitude.
#[test]
fn a_mounted_components_tests_do_not_run_in_the_assembly() {
    let results = run("assembly.esm");
    assert_eq!(
        results.iter().map(|r| r.model.as_str()).collect::<Vec<_>>(),
        vec!["Forcing"],
        "only the assembly's own component is asserted on: {results:?}"
    );
    assert!(results[0].passed, "{results:?}");
}

/// The tests are gone from the loaded document, not merely skipped by the
/// runner — the drop happens at the mount, so every consumer of the assembled
/// document agrees about what it asserts.
#[test]
fn the_mount_does_not_carry_the_leafs_tests() {
    let path = fixture("assembly.esm");
    let file = load_path(&path).expect("assembly loads");
    let models = file.models.as_ref().expect("models");
    assert!(
        models["Decay"].tests.as_ref().is_none_or(Vec::is_empty),
        "the mounted leaf's tests must not be spliced in: {:?}",
        models["Decay"].tests
    );
    // The mount is otherwise a faithful splice: the leaf's content is there.
    assert!(models["Decay"].variables.contains_key("u"));
    assert_eq!(
        models["Forcing"].tests.as_ref().map(Vec::len),
        Some(1),
        "the assembly's own tests are untouched"
    );
}
