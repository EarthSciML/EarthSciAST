//! Discrete-cadence materialization — segmented-refresh array-ODE conformance.
//! Shared fixture + analytic golden live under
//! `tests/conformance/discrete_materialize/` (CONFORMANCE_SPEC.md §5.13).
//!
//! Model `M` mixes a CONST weight matrix `W` (an in-file `const` observed) with a
//! DISCRETE forcing field `src` (a bare, undeclared forcing name resolved through
//! the [`ArrayCompiled`] forcing buffer) inside a conservative-regrid-shaped
//! CONTRACTION `g[j] = sum_i W[i,j]*src[i]` — state-free but forcing-tainted, so
//! it changes only when `src` is refreshed at a cadence boundary. A sibling
//! contraction `k[j] = sum_i W[i,j]*offset` reads only const/parameter data, so it
//! is CONST-cadence and refresh-invariant. The per-cell ODE
//! `D(c[j]) = g[j] + k[j]` couples both into the continuous state.
//!
//! Unlike Julia's `DiscreteMaterializer` cut (which caches `g` once per refresh and
//! gathers it into the hot RHS), the Rust array runtime re-materializes the
//! state-free `g` at each segment's `simulate()` (its static-observed hoist fires
//! once per call, with the forcing frozen for the segment) — so the numeric result
//! matches the Julia materialized path. This suite is the user-owned segmented
//! driver: it writes `src` from the golden's `forcing.by_anchor` snapshots at the
//! golden's `refresh_times`, threads state across segments, and checks the
//! trajectory against the analytic golden within the manifest's trajectory band.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::flatten::flatten;
use earthsci_ast::simulate_array::ArrayCompiled;
use earthsci_ast::{SimulateOptions, SolverChoice, load};
use ndarray::{ArrayD, IxDyn};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

const FIXTURE_DIR: &str = "../../tests/conformance/discrete_materialize";

/// Manifest trajectory band (`manifest.json` `tolerances`).
const TRAJ_RTOL: f64 = 1e-4;
const TRAJ_ATOL: f64 = 1e-6;

/// The forcing-buffer key the RHS looks up for `src` (namespaced post-flatten).
const SRC_KEY: &str = "M.src";

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

/// Segment endpoints within `tspan`: `t0`, the interior `refresh_times` anchors,
/// then `t_end`.
fn segment_endpoints(tspan: (f64, f64), refresh_times: &[f64]) -> Vec<f64> {
    let (t0, t_end) = tspan;
    let mut pts = vec![t0];
    for &t in refresh_times {
        if t > t0 && t < t_end {
            pts.push(t);
        }
    }
    pts.push(t_end);
    pts
}

/// The `src` snapshot to write at an anchor, from the golden's `by_anchor` map.
/// Keys are formatted as the golden writes them (e.g. `"0"` becomes `"0.0"`).
fn snapshot_at(golden: &serde_json::Value, anchor: f64) -> ArrayD<f64> {
    let by_anchor = golden["forcing"][SRC_KEY]["by_anchor"].as_object().unwrap();
    let key = format!("{anchor:.1}");
    let vals = by_anchor
        .get(&key)
        .unwrap_or_else(|| panic!("no forcing snapshot at anchor {key:?}"))
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_f64().unwrap())
        .collect::<Vec<_>>();
    ArrayD::from_shape_vec(IxDyn(&[vals.len()]), vals).unwrap()
}

/// Final-time value of a named scalar state slot (e.g. `"M.c[1]"`).
fn final_value(sol: &earthsci_ast::Solution, name: &str) -> f64 {
    let row = sol
        .state_variable_names
        .iter()
        .position(|n| n == name || n.ends_with(&format!(".{name}")))
        .unwrap_or_else(|| {
            panic!(
                "state slot {name:?} not found; have {:?}",
                sol.state_variable_names
            )
        });
    *sol.state[row].last().expect("at least one output time")
}

/// Load + flatten the fixture; assert `g`/`k`/`W` are observeds (not integrated
/// states) and `c` is the only state — the Rust analogue of the Python
/// `test_flatten_keeps_contraction_observeds_and_single_state`.
#[test]
fn discrete_materialize_flatten_keeps_observeds_and_single_state() {
    let path = fixture_dir().join("fixtures/discrete_materialize_contraction.esm");
    let json = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    let file = load(&json).unwrap_or_else(|e| panic!("load {path:?}: {e}"));
    let flat = flatten(&file).unwrap_or_else(|e| panic!("flatten: {e}"));

    for obs in ["M.W", "M.g", "M.k"] {
        assert!(
            flat.observed_variables.contains_key(obs),
            "{obs} must be an observed; observeds: {:?}",
            flat.observed_variables.keys().collect::<Vec<_>>()
        );
    }
    assert!(
        flat.state_variables.contains_key("M.c"),
        "M.c must be the integrated state; states: {:?}",
        flat.state_variables.keys().collect::<Vec<_>>()
    );
    assert!(
        !flat.state_variables.contains_key("M.g"),
        "M.g must not be an integrated state (it is a discrete-materialized observed)"
    );
}

/// Drive the segmented refresh solve end-to-end and assert every golden
/// trajectory time-point's `M.c[j]` within the manifest trajectory band. The
/// forcing `src` is refreshed once per segment boundary (the discrete cadence);
/// state threads across segments. A stale (un-refreshed) `src` would give a
/// visibly wrong slope, so the refresh is load-bearing.
#[test]
fn discrete_materialize_trajectory_matches_golden() {
    let fixture = fixture_dir().join("fixtures/discrete_materialize_contraction.esm");
    let golden = read_json(&fixture_dir().join("golden/discrete_materialize_contraction.json"));

    let json = fs::read_to_string(&fixture).unwrap_or_else(|e| panic!("read {fixture:?}: {e}"));
    let file = load(&json).unwrap_or_else(|e| panic!("load {fixture:?}: {e}"));
    let flat = flatten(&file).unwrap_or_else(|e| panic!("flatten: {e}"));
    let compiled =
        ArrayCompiled::from_flattened(&flat).unwrap_or_else(|e| panic!("from_flattened: {e}"));
    let forcing = compiled.forcing_handle();

    let tspan = &golden["cadence"]["tspan"];
    let tspan = (tspan[0].as_f64().unwrap(), tspan[1].as_f64().unwrap());
    let refresh_times: Vec<f64> = golden["cadence"]["refresh_times"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_f64().unwrap())
        .collect();
    let endpoints = segment_endpoints(tspan, &refresh_times);

    let cells = ["M.c[1]", "M.c[2]", "M.c[3]"];
    let params: HashMap<String, f64> = HashMap::new();
    let base_opts = SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-12,
        reltol: 1e-10,
        max_steps: 1_000_000,
        output_times: None,
    };

    // Segment-by-segment: refresh `src` at each boundary (forcing frozen for the
    // segment → RHS pure), integrate, thread the final state into the next.
    let mut ics: HashMap<String, f64> = cells.iter().map(|c| ((*c).to_string(), 0.0)).collect();
    let mut states: HashMap<String, HashMap<String, f64>> = HashMap::new();
    states.insert(format!("{:.1}", endpoints[0]), ics.clone());

    for pair in endpoints.windows(2) {
        let (seg_start, seg_end) = (pair[0], pair[1]);
        forcing
            .borrow_mut()
            .insert(SRC_KEY.to_string(), snapshot_at(&golden, seg_start));

        let mut opts = base_opts.clone();
        opts.output_times = Some(vec![seg_end]);
        let sol = compiled
            .simulate((seg_start, seg_end), &params, &ics, &opts)
            .unwrap_or_else(|e| panic!("simulate segment [{seg_start}, {seg_end}]: {e}"));

        ics = cells
            .iter()
            .map(|c| ((*c).to_string(), final_value(&sol, c)))
            .collect();
        states.insert(format!("{seg_end:.1}"), ics.clone());
    }

    let traj = golden["trajectory"].as_object().unwrap();
    for (tk, expected) in traj {
        if tk == "comment" {
            continue;
        }
        let t: f64 = tk.parse().unwrap();
        let got = states
            .get(&format!("{t:.1}"))
            .unwrap_or_else(|| panic!("no segment-boundary state at t={t}"));
        for cell in cells {
            let want = expected[cell].as_f64().unwrap();
            let g = got[cell];
            assert!(
                approximately_equal(g, want, TRAJ_RTOL, TRAJ_ATOL),
                "{cell} @ t={t}: expected {want}, got {g} (rtol={TRAJ_RTOL}, atol={TRAJ_ATOL})"
            );
        }
    }
}
