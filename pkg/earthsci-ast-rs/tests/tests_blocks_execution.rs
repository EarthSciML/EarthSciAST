//! Execution runner for inline `tests` blocks on the tests/simulation/*.esm
//! physics fixtures (gt-l1fk). Mirrors the Julia reference at
//! pkg/EarthSciAST.jl/test/tests_blocks_execution_test.jl.
//!
//! For every model that carries an inline `tests` block the runner:
//!   1. Builds a single-model subset [`EsmFile`] so unrelated dynamics from
//!      other components in the same fixture don't couple into the solve.
//!   2. Compiles it via [`Compiled::from_file`].
//!   3. Runs [`Compiled::simulate`] with output_times = each assertion's
//!      `time`, so state values are interpolated directly at the assertion
//!      points (no separate np.interp pass).
//!   4. Verifies each assertion against the resolved tolerance
//!      (assertion → test → model, fallback rtol=1e-6).
//!
//! The [`SIMULATION_SKIP`] map records fixtures that exercise binding gaps
//! (continuous events that don't propagate into the Rust solver, discrete
//! events, etc.) — each entry carries the bead ID blocking execution.
//! Fixtures without any inline `tests` block pass silently.
//!
//! Gated on `not(target_arch = "wasm32")` because the simulate module is
//! native-only.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::types::{EsmFile, Metadata};
use earthsci_ast::{Compiled, SimulateOptions, SolverChoice, Tolerance, load_path};
use std::collections::HashMap;
use std::path::PathBuf;

mod common;

fn simulation_dir() -> PathBuf {
    common::repo_fixture("simulation")
}

/// Fixtures skipped from numerical execution in the Rust binding. Each entry
/// carries the bead ID blocking execution. Empty value means "not yet
/// diagnosed".
fn simulation_skip(name: &str) -> Option<&'static str> {
    match name {
        // Rust simulate rejects continuous events (see
        // simulate_tests.rs::test_error_continuous_events_rejected) so
        // fixtures that depend on them for dynamics can't run through the
        // current backend. Tracked alongside Julia's MTK SymbolicContinuousCallback skip.
        "bouncing_ball.esm" => Some("gt-2ta2"),
        // Discrete events similarly rejected.
        "periodic_dosing.esm" => Some("gt-2ta2"),
        _ => None,
    }
}

/// Per-fixture solver override. Default is `Bdf` (stiff-capable, matches the
/// Rust binding's default). Fixtures whose analytical references come from a
/// non-stiff explicit reference solver (e.g. Julia's Tsit5 for the SciPy
/// integration cases) use `Erk` so the numerical trajectory stays within the
/// fixture's relative tolerance at long horizons — gt-su6u tracked Bdf drift
/// on ExponentialDecay at t=3000 that Erk (Tsit5) resolves.
fn per_fixture_solver(name: &str) -> SolverChoice {
    match name {
        "python_scipy_integration.esm" => SolverChoice::Erk,
        _ => SolverChoice::Bdf,
    }
}

fn empty_metadata() -> Metadata {
    Metadata {
        name: None,
        description: None,
        authors: None,
        license: None,
        created: None,
        modified: None,
        tags: None,
        references: None,
        system_class: None,
        dae_info: None,
        discretized_from: None,
    }
}

fn model_only_subset(file: &EsmFile, model_key: &str) -> EsmFile {
    let mut models = std::collections::HashMap::new();
    if let Some(all) = &file.models
        && let Some(m) = all.get(model_key)
    {
        models.insert(model_key.to_string(), m.clone());
    }
    EsmFile {
        expression_templates: None,
        metaparameters: None,
        coupling_roles: None,
        domain: None,
        index_sets: None,
        esm: file.esm.clone(),
        metadata: empty_metadata(),
        models: Some(models),
        reaction_systems: None,
        data_loaders: None,
        operators: None,
        enums: None,

        coupling: None,
        function_tables: None,
    }
}

fn reaction_system_only_subset(file: &EsmFile, rs_key: &str) -> EsmFile {
    let mut rs = std::collections::HashMap::new();
    if let Some(all) = &file.reaction_systems
        && let Some(r) = all.get(rs_key)
    {
        rs.insert(rs_key.to_string(), r.clone());
    }
    EsmFile {
        expression_templates: None,
        metaparameters: None,
        coupling_roles: None,
        domain: None,
        index_sets: None,
        esm: file.esm.clone(),
        metadata: empty_metadata(),
        models: None,
        reaction_systems: Some(rs),
        data_loaders: None,
        operators: None,
        enums: None,

        coupling: None,
        function_tables: None,
    }
}

fn resolve_tol(
    model_tol: Option<&Tolerance>,
    test_tol: Option<&Tolerance>,
    assertion_tol: Option<&Tolerance>,
) -> (f64, f64) {
    if let Some(cand) = [assertion_tol, test_tol, model_tol]
        .into_iter()
        .flatten()
        .next()
    {
        return (cand.rel.unwrap_or(0.0), cand.abs.unwrap_or(0.0));
    }
    (1e-6, 0.0)
}

fn find_state_index(state_names: &[String], component: &str, local: &str) -> Option<usize> {
    let namespaced = format!("{component}.{local}");
    if let Some(i) = state_names.iter().position(|n| n == &namespaced) {
        return Some(i);
    }
    state_names.iter().position(|n| n == local)
}

fn execute_component(
    label: &str,
    subset: &EsmFile,
    component: &str,
    tests: &[earthsci_ast::ModelTest],
    model_tol: Option<&Tolerance>,
    solver: SolverChoice,
) {
    let compiled =
        Compiled::from_file(subset).unwrap_or_else(|e| panic!("{label}: compile failed: {e}"));

    for t in tests {
        let mut params = HashMap::new();
        if let Some(po) = &t.parameter_overrides {
            for (k, v) in po {
                // Rust's simulate validates against namespaced parameter
                // names, so translate bare names to `component.name`.
                let namespaced = format!("{component}.{k}");
                if compiled.parameter_names().iter().any(|n| n == &namespaced) {
                    params.insert(namespaced, *v);
                } else {
                    params.insert(k.clone(), *v);
                }
            }
        }
        let mut ics = HashMap::new();
        if let Some(ic) = &t.initial_conditions {
            for (k, v) in ic {
                let namespaced = format!("{component}.{k}");
                if compiled
                    .state_variable_names()
                    .iter()
                    .any(|n| n == &namespaced)
                {
                    ics.insert(namespaced, *v);
                } else {
                    ics.insert(k.clone(), *v);
                }
            }
        }

        // output_times covers every assertion's `time` so we get direct
        // dense-output samples without a separate interpolation pass.
        let mut sample_times: Vec<f64> = t.assertions.iter().map(|a| a.time).collect();
        sample_times.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        sample_times.dedup_by(|a, b| (*a - *b).abs() < 0.0);

        let opts = SimulateOptions {
            solver,
            abstol: 1e-15,
            reltol: 1e-10,
            max_steps: 1_000_000,
            output_times: Some(sample_times.clone()),
        };

        let tspan = (t.time_span.start, t.time_span.end);
        let sol = compiled
            .simulate(tspan, &params, &ics, &opts)
            .unwrap_or_else(|e| panic!("{label}/{}: simulate failed: {e:?}", t.id));

        for a in &t.assertions {
            let idx = find_state_index(&sol.state_variable_names, component, &a.variable)
                .unwrap_or_else(|| {
                    panic!(
                        "{label}/{}: variable {:?} not in solution state names ({:?})",
                        t.id, a.variable, sol.state_variable_names
                    )
                });
            // Locate the sample whose time matches this assertion's time.
            // output_times was dedup'd; find the nearest entry.
            let (k, _) = sol
                .time
                .iter()
                .enumerate()
                .min_by(|(_, ta), (_, tb)| {
                    (**ta - a.time)
                        .abs()
                        .partial_cmp(&(**tb - a.time).abs())
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
                .expect("non-empty time grid");
            assert!(
                (sol.time[k] - a.time).abs() < 1e-9,
                "{label}/{}: no sample at t={}",
                t.id,
                a.time
            );
            let actual = sol.state[idx][k];
            let (rel, abs_) = resolve_tol(model_tol, t.tolerance.as_ref(), a.tolerance.as_ref());
            let diff = (actual - a.expected).abs();
            let mut bound = abs_;
            if rel > 0.0 {
                let rbound = rel * a.expected.abs().max(f64::MIN_POSITIVE);
                if rbound > bound {
                    bound = rbound;
                }
            }
            if rel == 0.0 && abs_ == 0.0 {
                bound = 1e-6 * a.expected.abs().max(f64::MIN_POSITIVE);
            }
            assert!(
                diff <= bound,
                "{label}/{} var={} t={}: actual={} expected={} diff={} bound={} rel={} abs={}",
                t.id,
                a.variable,
                a.time,
                actual,
                a.expected,
                diff,
                bound,
                rel,
                abs_
            );
        }
    }
}

#[test]
fn tests_blocks_execution_runner() {
    let dir = simulation_dir();
    let entries =
        std::fs::read_dir(&dir).unwrap_or_else(|e| panic!("read {}: {}", dir.display(), e));

    let mut fixtures: Vec<String> = entries
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().to_string();
            if name.ends_with(".esm") {
                Some(name)
            } else {
                None
            }
        })
        .collect();
    fixtures.sort();
    assert!(
        !fixtures.is_empty(),
        "no .esm fixtures in {}",
        dir.display()
    );

    let mut any_executed = false;

    for name in &fixtures {
        if let Some(bead) = simulation_skip(name) {
            eprintln!("skipping {name}: blocked by {bead}");
            continue;
        }
        let path = dir.join(name);
        let file = load_path(&path).unwrap_or_else(|e| panic!("{name}: load failed: {e}"));

        // Models.
        if let Some(models) = file.models.clone() {
            let solver = per_fixture_solver(name);
            for (mname, model) in &models {
                if model.tests.as_ref().is_none_or(|t| t.is_empty()) {
                    continue;
                }
                let subset = model_only_subset(&file, mname);
                let tests = model.tests.as_ref().unwrap();
                let label = format!("{name}/models/{mname}");
                execute_component(
                    &label,
                    &subset,
                    mname,
                    tests,
                    model.tolerance.as_ref(),
                    solver,
                );
                any_executed = true;
            }
        }

        // Reaction systems — currently no fixture has `tests` on a reaction
        // system (the schema allows it; we wire the walk so new fixtures are
        // picked up automatically). Guarded by a feature-detect: the
        // ReactionSystem struct does not carry a `tests` field in the Rust
        // binding yet, so we do not attempt execution. Future wiring: once
        // the field exists, mirror the model branch.
        let _ = reaction_system_only_subset;
    }

    assert!(
        any_executed,
        "tests/simulation/ fixtures had no executable inline tests (skip list too broad?)"
    );
}
