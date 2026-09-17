//! esm-spec §4.2: on a `D` node an ABSENT `wrt` MEANS `t`.
//!
//! Regression for EarthSciAST#407. `simulate::lhs::state_lhs_name` matched
//! `wrt == Some("t")`, so it did not recognize `{"op": "D", "args": ["z"]}` as
//! the derivative of `z` at all. The ARRAY pathway classifies its LHS through
//! [`earthsci_ast::classification`], which had always applied the default, so a
//! SHAPED state written in the short form simulated while the SCALAR one built
//! a system with no derivative equation and was refused at interpreter build:
//!
//! ```text
//! State variable 'WrtProbe.z' has no D(WrtProbe.z, t) = ... equation
//! in flat.equations. Cannot simulate.
//! ```
//!
//! The diagnostic names a missing equation, which is downstream of the
//! unapplied default, so the failure read as an authoring error in a document
//! that is correct per §4.2.
//!
//! Both shapes are exercised, each against its explicitly-spelled twin, so the
//! asymmetry cannot come back in either direction. The numbers live in two
//! shared fixtures, split by which backend can execute them:
//! `tests/simulation/wrt_default_omitted.esm` holds the scalar pair, and
//! `tests/fixtures/faq/28_wrt_default_omitted_shaped.esm` (registered in the
//! `simulate_faq` conformance manifest) holds the shaped pair, whose sum-`faq`
//! observed the scalar backend has no evaluator for.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Alg, SolveOptions, load_path, run_inline_tests};

mod common;

/// Every inline-test assertion of one model of the shared fixture, as
/// `(variable, time, actual)`. Panics if any assertion did not pass.
fn run_model(fixture: &str, model: &str) -> Vec<(String, f64, f64)> {
    let path = common::repo_fixture(fixture);
    let file = load_path(path.to_str().unwrap()).expect("fixture loads");
    let opts = SolveOptions {
        alg: Alg::Erk,
        reltol: Some(1e-12),
        abstol: Some(1e-14),
        ..Default::default()
    };
    let results = run_inline_tests(&file, Some(model), &opts);
    assert!(
        !results.is_empty(),
        "{model}: the fixture declares inline tests but none ran"
    );
    results
        .into_iter()
        .map(|r| {
            assert!(
                r.passed,
                "{model}/{}[{}] ({}@t={}) failed: {}",
                r.test_id, r.assertion_idx, r.variable, r.time, r.message
            );
            let actual = r
                .actual
                .unwrap_or_else(|| panic!("{model}: assertion produced no value"));
            (r.variable, r.time, actual)
        })
        .collect()
}

/// The two spellings must agree sample for sample, not merely both land close
/// enough to the closed form.
fn assert_spellings_agree(fixture: &str, omitted: &str, explicit: &str) {
    let a = run_model(fixture, omitted);
    let b = run_model(fixture, explicit);
    assert_eq!(
        a.len(),
        b.len(),
        "{omitted} and {explicit} declare different numbers of assertions"
    );
    for ((va, ta, xa), (vb, tb, xb)) in a.iter().zip(b.iter()) {
        assert_eq!((va, ta), (vb, tb), "the paired assertions are not aligned");
        assert!(
            (xa - xb).abs() <= 1e-9 * xb.abs().max(1.0),
            "`wrt` omitted and `wrt: t` disagree for {va} at t={ta}: {xa} vs {xb}"
        );
    }
}

#[test]
fn a_scalar_state_integrates_with_wrt_omitted_exactly_as_with_it() {
    assert_spellings_agree(
        "simulation/wrt_default_omitted.esm",
        "ScalarWrtOmitted",
        "ScalarWrtExplicit",
    );
}

#[test]
fn a_shaped_state_integrates_with_wrt_omitted_exactly_as_with_it() {
    assert_spellings_agree(
        "fixtures/faq/28_wrt_default_omitted_shaped.esm",
        "ShapedWrtOmitted",
        "ShapedWrtExplicit",
    );
}

/// The display path reads the same default: `D(x)` prints as `∂x/∂t`, exactly
/// as the explicitly-spelled node does. Requiring `Some(_)` printed the bare
/// call form `D(x)` for a node Julia, Python and TypeScript all print as
/// `∂x/∂t` — the same missing default, on a consumer the issue did not name.
#[test]
fn the_display_path_applies_the_same_default() {
    use earthsci_ast::{to_ascii, to_latex, to_unicode};

    let omitted: earthsci_ast::Expr =
        serde_json::from_value(serde_json::json!({"op": "D", "args": ["x"]})).unwrap();
    let explicit: earthsci_ast::Expr =
        serde_json::from_value(serde_json::json!({"op": "D", "args": ["x"], "wrt": "t"})).unwrap();

    assert_eq!(to_unicode(&omitted), "∂x/∂t");
    assert_eq!(to_unicode(&omitted), to_unicode(&explicit));
    assert_eq!(to_latex(&omitted), to_latex(&explicit));
    assert_eq!(to_ascii(&omitted), to_ascii(&explicit));
}
