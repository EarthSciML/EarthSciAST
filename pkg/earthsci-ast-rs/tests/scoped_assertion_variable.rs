//! An assertion's `variable` may be a SCOPED reference (issue #263).
//!
//! The schema documents `Assertion.variable` as "the local name (e.g. `"O3"`)
//! or a scoped reference relative to this component (e.g. `"subsystem.X"`)",
//! and the same string already resolves as an equation operand. The runner
//! looked the name up in the asserting component's own `variables` only, so a
//! `coords` or `reduce` assertion on a mounted leaf's field errored with
//! `variable 'Leaf.key' is not declared in model 'Host'`, and with two
//! components answering to `Leaf` a pointwise one read the wrong one.
//!
//! The fixtures are shared with the Julia and Python bindings
//! (`tests/conformance/scoped_assertion_variable/`), which pin the same rule.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{AssertionResult, SolveOptions, load_path, run_inline_tests_with_base_dir};

mod common;

fn run(name: &str) -> Vec<AssertionResult> {
    let path = common::repo_fixture("conformance/scoped_assertion_variable/fixtures").join(name);
    let file = load_path(&path).unwrap_or_else(|e| panic!("{} does not load: {e}", path.display()));
    run_inline_tests_with_base_dir(&file, None, &SolveOptions::default(), path.parent())
}

/// Every assertion passes, and its actual value is `expected` to `rel`.
fn assert_actuals(results: &[AssertionResult], expected: &[f64]) {
    assert_eq!(results.len(), expected.len(), "{results:?}");
    for (r, want) in results.iter().zip(expected) {
        assert!(
            r.passed,
            "{} (assertion {}): {}",
            r.variable, r.assertion_idx, r.message
        );
        let got = r
            .actual
            .expect("a passing assertion carries its actual value");
        assert!(
            (got - want).abs() <= 1e-4 * want.abs(),
            "{}: {got} vs {want}",
            r.variable
        );
    }
}

#[test]
fn the_leaf_alone_passes() {
    let results = run("leaf.esm");
    assert_actuals(&results, &[(-1.0f64).exp(), 9.0]);
}

/// Both mount forms: a sibling top-level `{ref}` (document-absolute) and the
/// asserting model's own `subsystems` mount (component-relative).
#[test]
fn a_mounted_leaf_is_assertable_by_scoped_name() {
    let e = (-1.0f64).exp();
    for name in ["top_level_mount.esm", "nested_mount.esm"] {
        let results = run(name);
        assert_eq!(
            results
                .iter()
                .map(|r| r.variable.as_str())
                .collect::<Vec<_>>(),
            ["w", "Leaf.u", "Leaf.v", "Leaf.key", "Leaf.key"],
            "{name}: {results:?}"
        );
        assert!(
            results.iter().all(|r| r.model == "Host"),
            "{name}: {results:?}"
        );
        assert_actuals(&results, &[3.0 * e, e, 2.0 * e, 7.0, 9.0]);
    }
}

/// The equation binder reads `Leaf.u` in `Host` as `Host`'s own subsystem when
/// it has one; an assertion must read the same component.
#[test]
fn a_subsystem_shadows_a_top_level_component_of_the_same_name() {
    let results = run("shadowed_mount.esm");
    assert_actuals(&results, &[6.0, 2.0, 1.0, 3.0]);
}

/// THREE levels: the owner path runs two mounts below the root, which a runner
/// that strips only one level of it off the spelling the build keyed the row by
/// cannot address.
#[test]
fn a_leaf_two_mounts_down_is_assertable_by_scoped_name() {
    let e = (-1.0f64).exp();
    let results = run("deep_mount.esm");
    assert_eq!(
        results
            .iter()
            .map(|r| r.variable.as_str())
            .collect::<Vec<_>>(),
        [
            "w",
            "Mid.Leaf.u",
            "Mid.Leaf.v",
            "Mid.Leaf.key",
            "Mid.Leaf.key"
        ],
        "{results:?}"
    );
    assert_actuals(&results, &[3.0 * e, e, 2.0 * e, 7.0, 9.0]);
}

/// Only the WRONG component's field is a build product, so a runner that
/// answers a scoped name from the closest materialized field reports the
/// top-level leaf's `[7, 9, 4]` where the subsystem owns `[5, 10, 15]`.
#[test]
fn a_scoped_field_is_never_read_from_another_component() {
    let results = run("shadowed_dynamic_field.esm");
    assert_actuals(&results, &[15.0, 15.0, 5.0]);
}
