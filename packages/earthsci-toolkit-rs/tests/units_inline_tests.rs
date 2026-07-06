//! Units fixtures consumption runner (gt-dt0o).
//!
//! The three `units_*.esm` files in `tests/valid/` carry inline `tests`
//! blocks (id / parameter_overrides / initial_conditions / time_span /
//! assertions) added in gt-p3v. Schema parse coverage is asserted in
//! `units_fixtures.rs`'s parse suite. This file closes the
//! schema-vs-execution gap: every assertion's target (all of which are
//! observed variables at t = 0) is actually evaluated under the test's
//! bindings and compared against the expected value within the resolved
//! tolerance (assertion → test → model, falling back to rtol = 1e-6).
//!
//! Corrupting an expected value in any fixture — or reverting the
//! `pressure_drop` fix from gt-p3v — must cause this suite to fail.

use earthsci_toolkit::{
    EsmFile, Expr, Model, ModelTest, Tolerance, VariableType, fold_constant_expr, load,
};
use std::collections::HashMap;

const UNITS_FIXTURES: &[(&str, &str)] = &[
    (
        "units_conversions.esm",
        include_str!("../../../tests/valid/units_conversions.esm"),
    ),
    (
        "units_dimensional_analysis.esm",
        include_str!("../../../tests/valid/units_dimensional_analysis.esm"),
    ),
    (
        "units_propagation.esm",
        include_str!("../../../tests/valid/units_propagation.esm"),
    ),
];

/// Evaluate an expression through the canonical scalar runner
/// ([`fold_constant_expr`], which reuses `simulate.rs`'s `interpret` /
/// `eval_op` primitives). Returns `None` when any variable reference is
/// unbound; the caller uses that signal to defer observed resolution.
fn eval_expr(expr: &Expr, bindings: &HashMap<String, f64>) -> Option<f64> {
    fold_constant_expr(expr, bindings).ok()
}

fn resolve_tol(
    model_tol: Option<&Tolerance>,
    test_tol: Option<&Tolerance>,
    assertion_tol: Option<&Tolerance>,
) -> (f64, f64) {
    if let Some(t) = [assertion_tol, test_tol, model_tol]
        .into_iter()
        .flatten()
        .next()
    {
        return (t.rel.unwrap_or(0.0), t.abs.unwrap_or(0.0));
    }
    (1e-6, 0.0)
}

fn resolve_observed(model: &Model, bindings: &mut HashMap<String, f64>) {
    let vars = &model.variables;
    let n = vars.len() + 1;
    for _ in 0..n {
        let mut progress = false;
        for (vname, var) in vars {
            if !matches!(var.var_type, VariableType::Observed) {
                continue;
            }
            if bindings.contains_key(vname) {
                continue;
            }
            let Some(expr) = &var.expression else {
                continue;
            };
            if let Some(val) = eval_expr(expr, bindings) {
                bindings.insert(vname.clone(), val);
                progress = true;
            }
        }
        if !progress {
            return;
        }
    }
}

fn build_bindings(model: &Model, t: &ModelTest) -> HashMap<String, f64> {
    let mut bindings = HashMap::new();
    for (vname, var) in &model.variables {
        if matches!(var.var_type, VariableType::Parameter | VariableType::State)
            && let Some(d) = var.default
        {
            bindings.insert(vname.clone(), d);
        }
    }
    if let Some(ic) = &t.initial_conditions {
        for (k, v) in ic {
            bindings.insert(k.clone(), *v);
        }
    }
    if let Some(po) = &t.parameter_overrides {
        for (k, v) in po {
            bindings.insert(k.clone(), *v);
        }
    }
    bindings
}

fn check_assertion(label: &str, actual: f64, expected: f64, rel: f64, abs_: f64) {
    let diff = (actual - expected).abs();
    let passed = if abs_ > 0.0 && expected == 0.0 {
        diff <= abs_
    } else if rel > 0.0 {
        let bound = (rel * expected.abs().max(f64::MIN_POSITIVE)).max(abs_);
        diff <= bound
    } else {
        diff <= abs_
    };
    assert!(
        passed,
        "{label}: actual={actual} expected={expected} rel={rel} abs={abs_} diff={diff}"
    );
}

#[test]
fn units_fixtures_inline_tests_execute() {
    let mut total_tests = 0usize;
    for (fname, content) in UNITS_FIXTURES {
        let file: EsmFile = load(content).unwrap_or_else(|e| panic!("failed to load {fname}: {e}"));
        let models = file
            .models
            .as_ref()
            .unwrap_or_else(|| panic!("{fname}: expected at least one model"));
        let mut fixture_tests = 0usize;
        for (mname, model) in models {
            let Some(tests) = &model.tests else { continue };
            for t in tests {
                fixture_tests += 1;
                total_tests += 1;
                let mut bindings = build_bindings(model, t);
                resolve_observed(model, &mut bindings);
                for a in &t.assertions {
                    let (rel, abs_) = resolve_tol(
                        model.tolerance.as_ref(),
                        t.tolerance.as_ref(),
                        a.tolerance.as_ref(),
                    );
                    let actual = *bindings.get(&a.variable).unwrap_or_else(|| {
                        panic!(
                            "{}::{}::{}: observed '{}' did not resolve (bindings={:?})",
                            fname, mname, t.id, a.variable, bindings
                        )
                    });
                    let label = format!("{}::{}::{}::{}", fname, mname, t.id, a.variable);
                    check_assertion(&label, actual, a.expected, rel, abs_);
                }
            }
        }
        assert!(
            fixture_tests > 0,
            "{fname}: expected at least one inline test across its models"
        );
    }
    assert!(
        total_tests > 0,
        "expected at least one inline test across the units fixtures"
    );
}
