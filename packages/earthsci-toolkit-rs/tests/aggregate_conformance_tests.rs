//! Cross-binding conformance tests for the M1 semiring / index-set worked
//! examples (bead ess-my4.1.5).
//!
//! Loads the four M1-expressible worked-example fixtures under
//! `../../tests/valid/aggregate/` that carry inline `tests` / `tolerance`
//! blocks (default `sum_product` FVM diffusion, `min_sum` tropical,
//! `max_product` saturation, and a `categorical` index-set contraction),
//! compiles each through [`earthsci_toolkit::simulate`], and verifies every
//! assertion within its declared tolerance. The fixtures are referenced by
//! name (not by globbing the directory) so this suite stays decoupled from
//! sibling fixtures that exercise schema deltas the Rust binding does not yet
//! evaluate (e.g. the `discrete` variable kind).
//!
//! Because Julia, Python, and Rust all check the *same* inline `expected`
//! values baked into the shared fixtures, passing here means the Rust
//! evaluator's semiring trajectories agree with the other bindings. The
//! `fvm_diffusion_sum_product` fixture additionally drives an EMPTY contraction
//! range through `simulate`, pinning the empty-reduction 0̄ identity (0 for
//! sum_product) end-to-end. RFC `semiring-faq-unified-ir` §5.1 / §5.2 / §7.1.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_toolkit::simulate::Solution;
use earthsci_toolkit::{
    Model, ModelTest, ModelTestAssertion, SimulateOptions, SolverChoice, Tolerance, load, simulate,
};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

const FIXTURE_DIR: &str = "../../tests/valid/aggregate";

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

fn model_iter(file: &earthsci_toolkit::EsmFile) -> Vec<(&String, &Model)> {
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
    file: &earthsci_toolkit::EsmFile,
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
        Err(e) => panic!("[{fixture_name}/{model_name}/{}] simulate failed: {e}", t.id),
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
    let slot = match sol.state_variable_names.iter().position(|n| n == &a.variable) {
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
        .min_by(|(_, x), (_, y)| (*x - a.time).abs().partial_cmp(&(*y - a.time).abs()).unwrap())
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
        t.id, a.variable, a.time, a.expected, actual
    );
}

fn fixture(name: &str) -> PathBuf {
    let manifest = env!("CARGO_MANIFEST_DIR");
    PathBuf::from(manifest).join(FIXTURE_DIR).join(name)
}

/// Assert the named worked-example fixture carries an executable model and
/// every inline assertion matches.
fn run_named(name: &str) {
    let ran = run_fixture(&fixture(name));
    assert!(ran >= 1, "{name}: expected an inline `tests` block, found none");
}

/// §7.1 default `sum_product` FVM-diffusion contraction, plus the empty-range
/// 0̄ identity (empty sum_product reduction → 0).
#[test]
fn fvm_diffusion_sum_product() {
    run_named("fvm_diffusion_sum_product.esm");
}

/// §5.1 `min_sum` tropical semiring (⊕ = min over an additive body).
#[test]
fn min_sum_tropical() {
    run_named("min_sum_tropical.esm");
}

/// §5.1 `max_product` saturation semiring (⊕ = max over a product body).
#[test]
fn max_product_saturation() {
    run_named("max_product_saturation.esm");
}

/// §5.2 `categorical` index set resolves to a [1, |members|] contraction.
#[test]
fn categorical_index_set() {
    run_named("categorical_index_set.esm");
}
