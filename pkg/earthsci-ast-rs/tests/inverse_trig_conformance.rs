//! Cross-binding conformance tests for transcendental scalar leaf ops: the
//! inverse-trigonometric family acos / asin / atan / atan2 (bead ess-9x1) and
//! the hyperbolic family sinh / cosh / tanh / asinh / acosh / atanh
//! (bead ess-v9a.1). Both share the generic `run_named` harness below.
//!
//! Loads the shared fixture under `../../tests/valid/scalar_leaves/` that
//! carries inline `tests` / `tolerance` blocks, compiles it through
//! [`earthsci_ast::simulate`], and verifies every assertion within its
//! declared tolerance. Each state variable integrates a CONSTANT inverse-trig
//! RHS from a zero initial condition, so `y(t=1) = rate*1 = rate` exactly.
//!
//! Because Julia (`tree_walk`), Python (`simulate`), and Rust (`simulate`) all
//! check the *same* inline `expected` values baked into the shared fixture,
//! passing here means the Rust evaluator's inverse-trig leaves agree with the
//! other bindings. The fixture uses `atan2(1, -1) = 3*pi/4` (second quadrant)
//! so the assertion exercises the 2-arg quadrant resolution, not a bare ratio.
//! These leaves back the spherical-geometry FAQs (great-circle arc `R*acos`,
//! lat/lon `asin`/`atan2`) consumed by M4 `polygon_area` (ess-my4.4.3) and the
//! ESD-DUO geometry beads.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::simulate::Solution;
use earthsci_ast::{
    Model, ModelTest, ModelTestAssertion, SimulateOptions, SolverChoice, Tolerance, load, simulate,
};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

mod common;

fn effective_tolerance(
    assertion: Option<&Tolerance>,
    test: Option<&Tolerance>,
    model: Option<&Tolerance>,
) -> (f64, f64) {
    for t in [assertion, test, model].into_iter().flatten() {
        let rel = t.rel.unwrap_or(0.0);
        let abs = t.abs.unwrap_or(0.0);
        if rel > 0.0 || abs > 0.0 {
            return (rel, abs);
        }
    }
    (1e-6, 0.0)
}

fn approximately_equal(actual: f64, expected: f64, rel: f64, abs: f64) -> bool {
    if !actual.is_finite() && !expected.is_finite() {
        return true;
    }
    let diff = (actual - expected).abs();
    if diff <= abs {
        return true;
    }
    if rel > 0.0 {
        let scale = expected.abs().max(actual.abs());
        if diff <= rel * scale {
            return true;
        }
    }
    false
}

fn model_iter(file: &earthsci_ast::EsmFile) -> Vec<(&String, &Model)> {
    file.models
        .as_ref()
        .map(|m| m.iter().collect::<Vec<_>>())
        .unwrap_or_default()
}

/// Run every inline test in a fixture; returns the number of models that
/// carried a `tests` block (so the caller can assert discovery worked).
fn run_fixture(path: &PathBuf) -> usize {
    let json_text = fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    let file = match load(&json_text) {
        Ok(f) => f,
        Err(e) => panic!("load {path:?}: {e}"),
    };
    let mname_path = path.file_name().unwrap().to_string_lossy().into_owned();
    let mut ran = 0usize;
    for (mname, model) in model_iter(&file) {
        let Some(tests) = model.tests.as_ref() else {
            continue;
        };
        ran += 1;
        for t in tests {
            run_model_test(&mname_path, mname, &file, model, t);
        }
    }
    ran
}

fn run_model_test(
    fixture_name: &str,
    model_name: &str,
    file: &earthsci_ast::EsmFile,
    model: &Model,
    t: &ModelTest,
) {
    let mut sorted_times: Vec<f64> = t.assertions.iter().map(|a| a.time).collect();
    sorted_times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    sorted_times.dedup_by(|a, b| (*a - *b).abs() < 1e-12);
    let opts = SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-10,
        reltol: 1e-8,
        max_steps: 100_000,
        output_times: Some(sorted_times.clone()),
    };
    let params: HashMap<String, f64> = HashMap::new();
    let initial_conditions: HashMap<String, f64> =
        t.initial_conditions.as_ref().cloned().unwrap_or_default();
    let sol = match simulate(
        file,
        (t.time_span.start, t.time_span.end),
        &params,
        &initial_conditions,
        &opts,
    ) {
        Ok(s) => s,
        Err(e) => panic!(
            "[{fixture_name}/{model_name}/{}] simulate failed: {e}",
            t.id
        ),
    };
    for a in &t.assertions {
        check_assertion(fixture_name, model_name, model, t, a, &sol);
    }
}

fn check_assertion(
    fixture_name: &str,
    model_name: &str,
    model: &Model,
    t: &ModelTest,
    a: &ModelTestAssertion,
    sol: &Solution,
) {
    let slot = match sol
        .state_variable_names
        .iter()
        .position(|n| n == &a.variable)
    {
        Some(i) => i,
        None => panic!(
            "[{fixture_name}/{model_name}/{}] unknown assertion variable '{}'. Known: {:?}",
            t.id, a.variable, sol.state_variable_names
        ),
    };
    let tix = sol
        .time
        .iter()
        .enumerate()
        .min_by(|(_, x), (_, y)| {
            (*x - a.time)
                .abs()
                .partial_cmp(&(*y - a.time).abs())
                .unwrap()
        })
        .map(|(i, _)| i)
        .unwrap_or(0);
    let actual = sol.state[slot][tix];
    let (rel, abs) = effective_tolerance(
        a.tolerance.as_ref(),
        t.tolerance.as_ref(),
        model.tolerance.as_ref(),
    );
    assert!(
        approximately_equal(actual, a.expected, rel, abs),
        "[{fixture_name}/{model_name}/{}] assertion failed: {} @ t={} expected {} got {} (rel_tol={rel}, abs_tol={abs})",
        t.id,
        a.variable,
        a.time,
        a.expected,
        actual
    );
}

fn fixture(name: &str) -> PathBuf {
    common::repo_fixture("valid/scalar_leaves").join(name)
}

/// Assert the named worked-example fixture carries an executable model and
/// every inline assertion matches.
fn run_named(name: &str) {
    let ran = run_fixture(&fixture(name));
    assert!(
        ran >= 1,
        "{name}: expected an inline `tests` block, found none"
    );
}

/// acos / asin / atan / atan2 scalar leaves, integrated as constant RHS from
/// zero ICs: asin(0.5)=pi/6, acos(0.5)=pi/3, atan(1)=pi/4, atan2(1,-1)=3pi/4.
#[test]
fn inverse_trig_leaves() {
    run_named("inverse_trig_leaves.esm");
}

/// sinh / cosh / tanh and inverses asinh / acosh / atanh scalar leaves,
/// integrated as constant RHS from zero ICs: sinh(1)=1.1752…, cosh(1)=1.5431…,
/// tanh(1)=0.7616…, asinh(1)=0.8814…, acosh(2)=1.3170…, atanh(0.5)=0.5493….
#[test]
fn hyperbolic_trig_leaves() {
    run_named("hyperbolic_trig_leaves.esm");
}
