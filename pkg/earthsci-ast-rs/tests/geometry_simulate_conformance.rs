//! Conservative-regridding geometry kernel — simulate()-path ODE conformance
//! (bead ess-my4.4.14; the Rust analog of the Python ess-my4.4.13 driver wiring).
//! RFC `semiring-faq-unified-ir` §8.1; `CONFORMANCE_SPEC.md` §5.8.
//!
//! The companion `geometry_conformance.rs` exercises the `intersect_polygon` leaf
//! and the `polygon_area` FAQ at the kernel / `eval_expression` level. This suite
//! closes the loop: it drives the shared `tests/valid/geometry/*.esm` fixtures
//! that carry inline `tests` blocks END-TO-END through [`earthsci_ast::simulate`],
//! exactly as `aggregate_conformance_tests.rs` does for the M1 semiring fixtures
//! and as the Python `test_geometry_simulation.py` does for the same fixtures.
//!
//! A geometry-ODE fixture integrates as a real ODE only because the array-op
//! simulate driver now materializes, in dependency order, each array-valued
//! observed (the clipped overlap ring → the derived `clip_ring` index set, sized
//! at eval time from the `intersect_polygon` node) and each scalar observed
//! (`area = sum_product FAQ(clip)`) into the eval context before the state
//! derivatives — so `D(tracer) = -area·tracer` resolves `area` and integrates.
//!
//! The shared runnable fixture (`intersect_polygon_planar_ode.esm`) uses the
//! dependency-free `planar` manifold; the native Rust build links `s2bindings`
//! unconditionally (it is not feature-gated), so a spherical/geodesic fixture
//! would also run here without a skip (unlike Python, which skips when the
//! optional `spherely` backend is absent). Because Julia/Python/Rust all check
//! the same inline `expected` values baked into the shared fixture, passing here
//! means the Rust geometry-ODE trajectory agrees with the other bindings
//! (tolerance-based per §5.8.2 / Appendix B.5).

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::simulate::Solution;
use earthsci_ast::{
    EsmFile, Model, ModelTest, ModelTestAssertion, SimulateOptions, SolverChoice, Tolerance, load,
    simulate,
};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

mod common;

fn geometry_dir() -> PathBuf {
    common::repo_fixture("valid/geometry")
}

/// Geometry fixtures that carry at least one inline model `tests` block — the
/// ones drivable end-to-end through `simulate` (mirrors the Python
/// `_collect_fixtures`). A fixture that fails to load is surfaced as a panic, not
/// silently skipped, so a regression in the shared schema is caught here too.
fn collect_runnable_fixtures() -> Vec<PathBuf> {
    let dir = geometry_dir();
    let mut out: Vec<PathBuf> = Vec::new();
    let Ok(entries) = fs::read_dir(&dir) else {
        return out;
    };
    let mut paths: Vec<PathBuf> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().and_then(|s| s.to_str()) == Some("esm"))
        .collect();
    paths.sort();
    for path in paths {
        let json = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
        let file = load(&json).unwrap_or_else(|e| panic!("load {path:?}: {e}"));
        if model_iter(&file)
            .iter()
            .any(|(_, m)| m.tests.as_ref().is_some_and(|t| !t.is_empty()))
        {
            out.push(path);
        }
    }
    out
}

fn model_iter(file: &EsmFile) -> Vec<(&String, &Model)> {
    file.models
        .as_ref()
        .map(|m| m.iter().collect::<Vec<_>>())
        .unwrap_or_default()
}

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

/// Locate an assertion's variable in the solution, matching either the bare name
/// or a namespaced `model.var` suffix, and return its value at the output node
/// nearest the assertion time. `area` resolves here because the array driver now
/// exposes scalar observed trajectories alongside the states.
fn lookup(sol: &Solution, var: &str, time: f64) -> f64 {
    let slot = sol
        .state_variable_names
        .iter()
        .position(|n| n == var || n.ends_with(&format!(".{var}")))
        .unwrap_or_else(|| {
            panic!(
                "variable {var:?} not in solution vars: {:?}",
                sol.state_variable_names
            )
        });
    let tix = sol
        .time
        .iter()
        .enumerate()
        .min_by(|(_, x), (_, y)| (*x - time).abs().partial_cmp(&(*y - time).abs()).unwrap())
        .map(|(i, _)| i)
        .unwrap_or(0);
    sol.state[slot][tix]
}

fn run_model_test(fixture: &str, model_name: &str, file: &EsmFile, model: &Model, t: &ModelTest) {
    let mut times: Vec<f64> = t.assertions.iter().map(|a| a.time).collect();
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    times.dedup_by(|a, b| (*a - *b).abs() < 1e-12);

    let opts = SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-10,
        reltol: 1e-8,
        max_steps: 100_000,
        output_times: Some(times),
    };
    let params: HashMap<String, f64> = HashMap::new();
    let ics: HashMap<String, f64> = t.initial_conditions.as_ref().cloned().unwrap_or_default();

    let sol = simulate(
        file,
        (t.time_span.start, t.time_span.end),
        &params,
        &ics,
        &opts,
    )
    .unwrap_or_else(|e| panic!("[{fixture}/{model_name}/{}] simulate failed: {e}", t.id));

    for a in &t.assertions {
        check_assertion(fixture, model_name, model, t, a, &sol);
    }
}

fn check_assertion(
    fixture: &str,
    model_name: &str,
    model: &Model,
    t: &ModelTest,
    a: &ModelTestAssertion,
    sol: &Solution,
) {
    let actual = lookup(sol, &a.variable, a.time);
    let (rel, abs) = effective_tolerance(
        a.tolerance.as_ref(),
        t.tolerance.as_ref(),
        model.tolerance.as_ref(),
    );
    assert!(
        approximately_equal(actual, a.expected, rel, abs),
        "[{fixture}/{model_name}/{}] assertion failed: {} @ t={} expected {} got {} \
         (rel_tol={rel}, abs_tol={abs})",
        t.id,
        a.variable,
        a.time,
        a.expected,
        actual
    );
}

/// At least one geometry fixture must be drivable end-to-end through `simulate`,
/// otherwise the simulate()-path geometry ODE is silently unexercised.
#[test]
fn at_least_one_runnable_geometry_fixture() {
    let fixtures = collect_runnable_fixtures();
    assert!(
        !fixtures.is_empty(),
        "no executable geometry fixtures (inline `tests`) under {:?}; the simulate()-path \
         geometry ODE is unexercised",
        geometry_dir()
    );
}

/// Drive every inline test of every runnable geometry fixture through `simulate`
/// and check each assertion within its declared tolerance.
#[test]
fn geometry_fixtures_simulate_conformance() {
    let mut checked = 0usize;
    for path in collect_runnable_fixtures() {
        let fixture = path.file_name().unwrap().to_string_lossy().into_owned();
        let json = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
        let file = load(&json).unwrap_or_else(|e| panic!("load {path:?}: {e}"));
        for (model_name, model) in model_iter(&file) {
            let Some(tests) = model.tests.as_ref() else {
                continue;
            };
            for t in tests {
                assert!(
                    !t.assertions.is_empty(),
                    "[{fixture}/{model_name}/{}] inline test has no assertions",
                    t.id
                );
                run_model_test(&fixture, model_name, &file, model, t);
                checked += t.assertions.len();
            }
        }
    }
    assert!(checked > 0, "no geometry assertions were checked");
}

/// The fused `polygon_intersection_area` leaf fixture must load, drive through
/// `simulate`, and yield the exact planar overlap area 1.0 — both as the scalar
/// observed `overlap_area` and as the integrated `area_state` at t=1 (esm-spec
/// §8.6.1). This pins the fused leaf's value to `polygon_area(intersect_polygon)`.
#[test]
fn polygon_intersection_area_planar_fixture_area_is_one() {
    let path = geometry_dir().join("polygon_intersection_area_planar.esm");
    let json = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    let file = load(&json).unwrap_or_else(|e| panic!("load {path:?}: {e}"));
    let (model_name, model) = model_iter(&file)
        .into_iter()
        .next()
        .expect("fixture has a model");
    let test = model
        .tests
        .as_ref()
        .and_then(|ts| ts.first())
        .expect("fixture has an inline test");
    let opts = SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-10,
        reltol: 1e-8,
        max_steps: 100_000,
        output_times: Some(vec![0.0, 1.0]),
    };
    let ics: HashMap<String, f64> = test
        .initial_conditions
        .as_ref()
        .cloned()
        .unwrap_or_default();
    let sol = simulate(
        &file,
        (test.time_span.start, test.time_span.end),
        &HashMap::new(),
        &ics,
        &opts,
    )
    .unwrap_or_else(|e| panic!("[{model_name}] polygon_intersection_area simulate failed: {e}"));

    // The fused scalar overlap area is exposed and is exactly 1.0 at every node.
    assert!(
        (lookup(&sol, "overlap_area", 0.0) - 1.0).abs() < 1e-9,
        "overlap_area@t=0 should be 1.0, got {}",
        lookup(&sol, "overlap_area", 0.0)
    );
    // d(area_state)/dt = overlap_area from a zero IC ⇒ area_state(1) = 1.0.
    assert!(
        (lookup(&sol, "area_state", 1.0) - 1.0).abs() < 1e-9,
        "area_state@t=1 should be 1.0, got {}",
        lookup(&sol, "area_state", 1.0)
    );
}

/// The canonical end-to-end fixture must be the runnable planar ODE one, and its
/// scalar `area` observed must be exposed in the solution (the derived-clip-ring
/// materialization is what makes this pass). Guards against the fixture being
/// renamed away from the simulate path or `area` silently dropping out.
#[test]
fn planar_ode_fixture_is_runnable_and_exposes_area() {
    let runnable = collect_runnable_fixtures();
    let planar_ode = runnable
        .iter()
        .find(|p| {
            p.file_name().and_then(|n| n.to_str()) == Some("intersect_polygon_planar_ode.esm")
        })
        .unwrap_or_else(|| {
            panic!(
                "intersect_polygon_planar_ode.esm must be a runnable simulate()-path fixture; \
                 runnable set: {runnable:?}"
            )
        });

    let json = fs::read_to_string(planar_ode).expect("read planar_ode fixture");
    let file = load(&json).expect("load planar_ode fixture");
    let (model_name, model) = model_iter(&file)
        .into_iter()
        .next()
        .expect("planar_ode has a model");
    let test = model
        .tests
        .as_ref()
        .and_then(|ts| ts.first())
        .expect("planar_ode has an inline test");
    let opts = SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-10,
        reltol: 1e-8,
        max_steps: 100_000,
        output_times: Some(vec![0.0, 2.0]),
    };
    let ics: HashMap<String, f64> = test
        .initial_conditions
        .as_ref()
        .cloned()
        .unwrap_or_default();
    let sol = simulate(
        &file,
        (test.time_span.start, test.time_span.end),
        &HashMap::new(),
        &ics,
        &opts,
    )
    .unwrap_or_else(|e| panic!("[{model_name}] planar_ode simulate failed: {e}"));

    assert!(
        sol.state_variable_names.iter().any(|n| n == "area"),
        "scalar observed `area` must be exposed in the solution; got vars {:?}",
        sol.state_variable_names
    );
    // The unit-overlap clip has planar area exactly 1.0 at every node.
    assert!(
        (lookup(&sol, "area", 0.0) - 1.0).abs() < 1e-9,
        "area@t=0 should be 1.0, got {}",
        lookup(&sol, "area", 0.0)
    );
}
