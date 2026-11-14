//! Values of the pointwise lift on the routes besides the operator
//! `makearray` (esm-spec §10.5; esm-libraries-spec §4.7.5, "Pointwise lift:
//! which states are lifted").
//!
//! Each fixture in `tests/conformance/pointwise_lift/values/` lifts a reaction
//! system onto `[lev]` and asserts, per level, the initial value and the
//! tendency `Tend.dA_dt[k] = D(Mech.A)[k]`, under both compilers. A per-cell
//! `initial_conditions` key (`Mech.A[2]`) and a scoped `ic(Mech.A) ~ A0` with
//! `A0` on `[lev]` each set the lifted species level by level; before the lift
//! reached these routes the species stayed scalar and both were rejected.

use std::path::{Path, PathBuf};

use earthsci_ast::{Compiler, InlineTestOptions, load_path, run_inline_tests_with_options};

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/pointwise_lift/values")
        .join(name)
}

fn assert_passes(name: &str, expected_assertions: usize) {
    let path = fixture(name);
    let file = load_path(&path).unwrap_or_else(|e| panic!("{name} does not load: {e}"));
    for compiler in [Compiler::Native, Compiler::Interpreter] {
        let results = run_inline_tests_with_options(
            &file,
            &InlineTestOptions {
                base_dir: path.parent().map(Path::to_path_buf),
                compiler: Some(compiler),
                ..Default::default()
            },
            None,
        );
        assert_eq!(
            results.len(),
            expected_assertions,
            "{name} under {compiler:?}: {results:?}"
        );
        for r in &results {
            assert!(
                r.passed,
                "{name} under {compiler:?}: {}#{} ({} @ t={}): actual={:?} expected={} {}",
                r.test_id, r.assertion_idx, r.variable, r.time, r.actual, r.expected, r.message
            );
        }
    }
}

/// A `[lev]` temperature reaches the rate model through a `variable_map`;
/// per-cell `initial_conditions` keys set each level, and each level decays
/// at its own rate.
#[test]
fn pointwise_lift_values_variable_map_with_per_cell_initial_conditions() {
    assert_passes("lift_values_ic_keys.esm", 12);
}

/// An operator written elementwise over a `[lev]` coefficient, with the
/// scoped `ic(Mech.A) ~ Column.A0` setting each level.
#[test]
fn pointwise_lift_values_elementwise_operator_with_scoped_initial_condition() {
    assert_passes("lift_values_scoped_ic.esm", 6);
}
