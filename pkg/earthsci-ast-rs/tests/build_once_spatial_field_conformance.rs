//! Build-once spatial-field consumption — simulate()-path array-ODE conformance.
//! Shared fixture + analytic golden live under
//! `tests/conformance/build_once_spatial_field/` (CONFORMANCE_SPEC.md §5.12).
//!
//! Model `Field` declares three const polygon cells (`poly`), derives a per-cell
//! `area[c] = polygon_intersection_area(poly[c], poly[c], planar) = [10, 30, 60]`
//! (a geometry-leaf aggregate), takes a build-once centered first difference
//! authored as the periodic `makearray` stencil a discretization rule lowers `D`
//! to (`darea = [-15, 25, -10]`), and integrates the per-cell ODE
//! `D(u[c]) = darea[c] - u[c]`, u(0)=0. The forcing is CONST, so
//! `u_c(t) = darea_c (1 - e^-t)` is analytic and network-free.
//!
//! Unlike Julia's separate setup-materialization pass, the Rust array runtime
//! resolves the build-once `area`/`darea` observeds at the RHS through the same
//! per-cell array pipeline the ODE uses for `index(darea, c)` — so the numeric
//! result matches the Julia setup-materialized path. This suite drives the
//! composed `polygon_intersection_area` + `makearray` + array-ODE path
//! end-to-end through [`earthsci_ast::simulate`] and checks the trajectory
//! against the analytic golden within the manifest's trajectory band.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{SimulateOptions, SolverChoice, load, simulate};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

const FIXTURE_DIR: &str = "../../tests/conformance/build_once_spatial_field";

/// Manifest trajectory band (`manifest.json` `tolerances`).
const TRAJ_RTOL: f64 = 1e-4;
const TRAJ_ATOL: f64 = 1e-6;

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join(FIXTURE_DIR)
}

fn read_json(path: &PathBuf) -> serde_json::Value {
    let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

fn approximately_equal(actual: f64, expected: f64, rel: f64, abs: f64) -> bool {
    let diff = (actual - expected).abs();
    if diff <= abs {
        return true;
    }
    let scale = expected.abs().max(actual.abs());
    diff <= rel * scale
}

/// Linearly interpolate `series` (sampled at `times`) at `t`, clamping to the
/// endpoints. Mirrors the Python runner's `np.interp`.
fn interp(times: &[f64], series: &[f64], t: f64) -> f64 {
    if t <= times[0] {
        return series[0];
    }
    if t >= times[times.len() - 1] {
        return series[series.len() - 1];
    }
    for w in 1..times.len() {
        if t <= times[w] {
            let (t0, t1) = (times[w - 1], times[w]);
            let (y0, y1) = (series[w - 1], series[w]);
            let f = (t - t0) / (t1 - t0);
            return y0 + f * (y1 - y0);
        }
    }
    series[series.len() - 1]
}

/// Load and flatten the fixture; assert `area`/`darea` are observeds (not
/// integrated states) and `u` is the only state — the Rust analogue of the
/// Python `test_flatten_keeps_field_observeds_and_single_state`.
#[test]
fn build_once_field_flatten_keeps_observeds_and_single_state() {
    use earthsci_ast::flatten;

    let path = fixture_dir().join("fixtures/build_once_spatial_ode.esm");
    let json = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    let file = load(&json).unwrap_or_else(|e| panic!("load {path:?}: {e}"));
    let flat = flatten(&file).unwrap_or_else(|e| panic!("flatten: {e}"));

    assert!(
        flat.observed_variables.contains_key("Field.area"),
        "Field.area must be an observed; observeds: {:?}",
        flat.observed_variables.keys().collect::<Vec<_>>()
    );
    assert!(
        flat.observed_variables.contains_key("Field.darea"),
        "Field.darea must be an observed; observeds: {:?}",
        flat.observed_variables.keys().collect::<Vec<_>>()
    );
    assert!(
        flat.state_variables.contains_key("Field.u"),
        "Field.u must be the integrated state; states: {:?}",
        flat.state_variables.keys().collect::<Vec<_>>()
    );
    assert!(
        !flat.state_variables.contains_key("Field.area"),
        "Field.area must not be an integrated state"
    );
}

/// Integrate the build-once spatial-field ODE end-to-end and assert every golden
/// trajectory time-point's `Field.u[c]` within the manifest trajectory band.
#[test]
fn build_once_spatial_field_trajectory_matches_golden() {
    let fixture = fixture_dir().join("fixtures/build_once_spatial_ode.esm");
    let golden = read_json(&fixture_dir().join("golden/build_once_spatial_ode.json"));

    let json = fs::read_to_string(&fixture).unwrap_or_else(|e| panic!("read {fixture:?}: {e}"));
    let file = load(&json).unwrap_or_else(|e| panic!("load {fixture:?}: {e}"));

    let tspan = &golden["cadence"]["tspan"];
    let (t0, t1) = (tspan[0].as_f64().unwrap(), tspan[1].as_f64().unwrap());

    // Golden trajectory keys are the assertion times; sample the solver there.
    let traj = golden["trajectory"].as_object().unwrap();
    let mut want_times: Vec<f64> = traj
        .keys()
        .filter(|k| *k != "comment")
        .map(|k| k.parse::<f64>().unwrap())
        .collect();
    want_times.sort_by(|a, b| a.partial_cmp(b).unwrap());

    let opts = SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-12,
        reltol: 1e-10,
        max_steps: 1_000_000,
        output_times: Some(want_times.clone()),
    };
    let sol = simulate(&file, (t0, t1), &HashMap::new(), &HashMap::new(), &opts)
        .unwrap_or_else(|e| panic!("simulate failed: {e}"));

    // Locate each state slot `u[c]` (single-model path uses bare slot names).
    let slot_of = |cell: usize| -> usize {
        let bare = format!("u[{cell}]");
        sol.state_variable_names
            .iter()
            .position(|n| n == &bare || n.ends_with(&format!(".{bare}")))
            .unwrap_or_else(|| {
                panic!(
                    "state slot {bare:?} not found; vars: {:?}",
                    sol.state_variable_names
                )
            })
    };

    for (tk, expected) in traj {
        if tk == "comment" {
            continue;
        }
        let t: f64 = tk.parse().unwrap();
        for (cell, key) in [(1usize, "Field.u[1]"), (2, "Field.u[2]"), (3, "Field.u[3]")] {
            let want = expected[key].as_f64().unwrap();
            let series = &sol.state[slot_of(cell)];
            let got = interp(&sol.time, series, t);
            assert!(
                approximately_equal(got, want, TRAJ_RTOL, TRAJ_ATOL),
                "u[{cell}] @ t={t}: expected {want}, got {got} \
                 (rtol={TRAJ_RTOL}, atol={TRAJ_ATOL})"
            );
        }
    }
}
