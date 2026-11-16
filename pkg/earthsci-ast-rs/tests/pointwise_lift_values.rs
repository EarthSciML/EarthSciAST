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

use crate::common;

fn fixture(name: &str) -> PathBuf {
    common::repo_fixture("conformance/pointwise_lift/values").join(name)
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

/// An author's per-cell tendency for a declared-shape state is not a lifted
/// equation: an observed `r[i] ~ D(c[i])` reading it is left unresolved, as in
/// every other binding, rather than resolved against the authored `faq`
/// (esm-libraries-spec §4.7.5 step 3a reads only the lift's own equations).
#[test]
fn authored_per_cell_tendency_is_not_a_lifted_one() {
    let doc = r#"{
      "esm": "2.2.0",
      "metadata": {"name": "Authored", "authors": ["t"]},
      "index_sets": {"x": {"kind": "interval", "size": 3}},
      "models": {"M": {
        "variables": {
          "c": {"type": "unknown", "units": "1", "default": 1.0, "shape": ["x"]},
          "k": {"type": "parameter", "units": "1/s", "default": 0.1},
          "r": {"type": "unknown", "units": "1/s", "shape": ["x"]}
        },
        "equations": [
          {"lhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                   "expr": {"op": "D", "args": [{"op": "index", "args": ["c", "i"]}], "wrt": "t"}},
           "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                   "expr": {"op": "*", "args": [{"op": "-", "args": ["k"]}, {"op": "index", "args": ["c", "i"]}]}}},
          {"lhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                   "expr": {"op": "index", "args": ["r", "i"]}},
           "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                   "expr": {"op": "D", "args": [{"op": "index", "args": ["c", "i"]}], "wrt": "t"}}}
        ]
      }}
    }"#;
    let file = earthsci_ast::load_string(doc).expect("loads");
    let flat = earthsci_ast::flatten(&file).expect("flattens");
    assert!(flat.lifted_shapes.is_empty(), "{:?}", flat.lifted_shapes);
    let r = flat
        .equations
        .iter()
        .map(|eq| {
            (
                crate::common::canon(&eq.lhs).to_string(),
                crate::common::canon(&eq.rhs).to_string(),
            )
        })
        .find(|(lhs, _)| lhs.contains(r#""M.r""#))
        .expect("an equation for M.r");
    assert!(
        r.1.contains(r#""op":"D""#) && r.1.contains(r#""M.c""#),
        "M.r resolved against an authored tendency: {r:?}"
    );
}
