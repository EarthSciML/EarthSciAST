//! Issue #207: two spellings of the same table must give the same number.
//!
//! The reported symptom is a coupled document (top-level `{ref}` mounts chained
//! by `variable_map` `param_to_var`) whose leaf gathers from a table declared as
//! a bare `const` array, at an index computed from the coupled-in temperature:
//!
//! ```text
//! E_TREEWALK_CONSTARRAY_OOB: const array 'Rtrn.totplnk' index -159
//! ```
//!
//! Wrapping the same table in an `aggregate` makes it evaluate correctly. The
//! two spellings are semantically identical, so they must agree.
//!
//! The issue attributes this to the gather being folded BEFORE the document
//! couplings apply. [`coupling_reaches_the_gather_index`] shows that diagnosis
//! is wrong: the flattened system already reads the coupled variable, so the
//! coupling has landed before anything is built. And
//! [`the_defect_does_not_need_a_coupling`] shows the same failure in a single
//! model with no `coupling` block and no mounts at all — the fault is in the
//! array runtime, not in when couplings are applied.

#![cfg(not(target_arch = "wasm32"))]

use std::path::{Path, PathBuf};

use earthsci_ast::{SolveOptions, flatten, load_path, run_pde_tests_with_base_dir};

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/coupled_const_fold")
        .join(name)
}

/// Run a fixture's own inline tests through the library runner — the route
/// `esm test` takes, including the `{ref}` mount resolution.
fn run(name: &str) -> Vec<earthsci_ast::PdeAssertionResult> {
    let path = fixture(name);
    let file = load_path(&path).unwrap_or_else(|e| panic!("{name} does not load: {e}"));
    run_pde_tests_with_base_dir(&file, None, &SolveOptions::default(), path.parent())
}

/// The one assertion each fixture carries: the gather picks `totplnk[4] = 40`.
///
/// 40 is reachable only from the coupled temperature (163). The coupling
/// target's own declared default (161) would gather 20, and an unbound read
/// (0) indexes -159 — the index the issue reports.
fn assert_gathers_40(name: &str) {
    let results = run(name);
    assert_eq!(
        results.len(),
        1,
        "{name} carries one assertion: {results:?}"
    );
    let r = &results[0];
    assert!(
        r.passed,
        "{name}: {} — actual={:?} expected={} {}",
        r.variable, r.actual, r.expected, r.message
    );
}

/// The spelling the issue reports as WORKING. Control: a failure here would
/// mean the fixtures, not the runtime, are at fault.
#[test]
fn the_aggregate_spelling_gathers_the_coupled_row() {
    assert_gathers_40("probe_chain_constagg.esm");
}

/// The spelling the issue reports as BROKEN. Same chain, same table, same index
/// expression — only the `aggregate` wrapper differs, so the answer must not.
#[test]
fn the_bare_const_spelling_gathers_the_same_row() {
    assert_gathers_40("probe_chain_const.esm");
}

/// No mounts, no `coupling` block, one model — and the same failure. This is
/// what attributes the defect to the array runtime rather than to coupling
/// resolution.
#[test]
fn the_defect_does_not_need_a_coupling() {
    assert_gathers_40("probe_single_model_const.esm");
}

/// The couplings ARE applied before anything is built: flatten rewrites the
/// gather's index to read the chain's source variable, and the parameter the
/// chain replaced is gone from the flattened parameter set.
///
/// This is the assertion that rules out the issue's own diagnosis, so it is
/// pinned rather than left as a claim in prose.
#[test]
fn coupling_reaches_the_gather_index() {
    let file = load_path(fixture("probe_chain_const.esm")).expect("host document loads");
    let flat = flatten(&file).expect("the coupled document flattens");
    assert!(
        !flat.parameters.contains_key("Rtrn.T"),
        "`param_to_var` removes the target parameter: {:?}",
        flat.parameters.keys().collect::<Vec<_>>()
    );
    let plnk = flat
        .equations
        .iter()
        .find(|eq| eq.lhs.to_string() == "Rtrn.plnk")
        .expect("the flattened system defines Rtrn.plnk");
    let rhs = plnk.rhs.to_string();
    assert!(
        rhs.contains("Atm.T"),
        "the gather index must read the coupled variable, not the removed \
         parameter; got `{rhs}`"
    );
}
