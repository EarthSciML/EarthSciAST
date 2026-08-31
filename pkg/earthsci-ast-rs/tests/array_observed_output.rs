//! An ARRAY-shaped observed reaches the output, labeled.
//!
//! `derive_output_plan` inverts a flat, column-major solver state into
//! dimension-labeled, row-major output arrays with CF coordinates — but it can
//! only grid a variable the runner put a SLOT there for, and the array runtime
//! used to expose scalar observeds only. A gridded observed (an emissions or
//! flux field) was therefore unwritable and undiffable: it left no trace in a
//! `Solution`, and asking the plan for it could only ever raise
//! `OutputError::UnknownObserved`.
//!
//! These tests pin both halves of the seam that closes that:
//! `SolveOptions::output_observed` making the runner append the field as cell
//! rows, and `derive_output_plan` gridding those rows onto the same emergent
//! grid as the state they were computed from.
//!
//! **Every expected value is an oracle over the solution's OWN state rows**,
//! never a recorded number. The fixture's observed is
//! `flux[i,j] = k * c[i,j] * (i + 10*j)`: a weight distinct in every cell and
//! asymmetric across the two axes. A plan that transposed lon against lat, or
//! walked the flat cells row-major instead of column-major, permutes those
//! weights and the comparison fails — which a uniform field, or a golden array
//! compared against itself, would both hide.

#![cfg(feature = "solve")]

use std::collections::HashMap;
use std::path::Path;

use earthsci_ast::{
    EsmFile, OutputError, ProblemInput, ProblemOptions, SolveOptions, derive_output_plan,
    esm_problem, load_string, solve,
};

const GRID: &str = "tests/fixtures/output/array_observed_grid.esm";
/// A pure-SCALAR document whose `total_rate` is an observed of two states.
const SCALAR: &str = "../../tests/valid/full_model_specification.esm";

const N_LON: usize = 3;
const N_LAT: usize = 2;
/// The fixture's `k` default.
const K: f64 = 0.001;

fn doc(path: &str) -> EsmFile {
    load_string(&std::fs::read_to_string(path).unwrap_or_else(|e| panic!("reading {path}: {e}")))
        .unwrap_or_else(|e| panic!("loading {path}: {e}"))
}

/// Solve the grid fixture, asking for `observed`.
fn run(observed: &[&str]) -> earthsci_ast::Solution {
    let prob = esm_problem(
        ProblemInput::Path(Path::new(GRID)),
        (0.0, 10.0),
        ProblemOptions {
            compile: earthsci_ast::Compile::Always,
            ..Default::default()
        },
    )
    .expect("the grid fixture builds");
    let opts = SolveOptions {
        output_observed: observed.iter().map(|s| (*s).to_string()).collect(),
        ..Default::default()
    };
    solve(&prob, &opts).expect("the grid fixture solves")
}

/// The fixture's per-cell weight, `i + 10*j` at 1-based `(i, j)`.
fn weight(i: usize, j: usize) -> f64 {
    (i + 10 * j) as f64
}

/// The row of `sol` named exactly `name`.
fn row<'s>(sol: &'s earthsci_ast::Solution, name: &str) -> &'s [f64] {
    let i = sol
        .state_variable_names
        .iter()
        .position(|n| n == name)
        .unwrap_or_else(|| {
            panic!(
                "no row named '{name}'; rows are {:?}",
                sol.state_variable_names
            )
        });
    &sol.state[i]
}

#[test]
fn an_array_observed_leaves_no_trace_unless_it_is_asked_for() {
    let sol = run(&[]);
    assert!(
        !sol.state_variable_names
            .iter()
            .any(|n| n.starts_with("flux")),
        "an unrequested array observed must not be materialized: {:?}",
        sol.state_variable_names
    );

    // …and the plan says so, naming the field, rather than dropping it.
    let err = derive_output_plan(&doc(GRID), &sol.state_variable_names, &["flux".to_string()])
        .expect_err("an unmaterialized observed has no slot to grid");
    assert_eq!(
        err,
        OutputError::UnknownObserved {
            name: "flux".to_string()
        }
    );
}

#[test]
fn a_requested_array_observed_becomes_one_row_per_cell() {
    let sol = run(&["flux"]);

    // One row per cell, in the state's own 1-based column-major cell-key
    // spelling — dim 0 fastest, so lon varies inside lat.
    let want: Vec<String> = (1..=N_LAT)
        .flat_map(|j| (1..=N_LON).map(move |i| format!("flux[{i},{j}]")))
        .collect();
    let got: Vec<String> = sol
        .state_variable_names
        .iter()
        .filter(|n| n.starts_with("flux["))
        .cloned()
        .collect();
    assert_eq!(got, want, "array-observed cell keys");

    // Values, against an oracle over the solution's own `c` rows.
    for j in 1..=N_LAT {
        for i in 1..=N_LON {
            let c = row(&sol, &format!("c[{i},{j}]"));
            let f = row(&sol, &format!("flux[{i},{j}]"));
            assert_eq!(
                f.len(),
                sol.time.len(),
                "flux[{i},{j}] spans the output grid"
            );
            for (k, (&cv, &fv)) in c.iter().zip(f).enumerate() {
                let want = K * cv * weight(i, j);
                assert!(
                    (fv - want).abs() <= 1e-12 * want.abs().max(1.0),
                    "flux[{i},{j}] at output {k}: got {fv}, want {want}"
                );
            }
        }
    }
}

#[test]
fn the_plan_grids_a_requested_observed_alongside_the_state() {
    let sol = run(&["flux"]);
    let plan = derive_output_plan(&doc(GRID), &sol.state_variable_names, &["flux".to_string()])
        .expect("the plan derives once the observed has slots");

    // The observed shares the state's spatial signature, so it is the SAME
    // emergent grid — not a second one named after itself.
    assert_eq!(plan.grids.len(), 1, "one emergent grid");
    let grid = &plan.grids[0];
    assert_eq!(
        grid.dims,
        vec![("lon".to_string(), N_LON), ("lat".to_string(), N_LAT)],
        "real index_set axis names, not positional placeholders"
    );

    // CF dimension coordinates, so a written row is identifiable.
    let coords: Vec<&str> = grid.coords.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(coords, vec!["lon", "lat"]);
    assert_eq!(grid.coords[0].values, vec![-100.0, -90.0, -80.0]);
    assert_eq!(grid.coords[1].values, vec![30.0, 40.0]);
    assert_eq!(
        grid.coords[0]
            .attrs
            .get("standard_name")
            .and_then(|v| v.as_str()),
        Some("longitude")
    );
    assert_eq!(
        grid.coords[1].attrs.get("axis").and_then(|v| v.as_str()),
        Some("Y")
    );

    let names: Vec<&str> = grid.vars.iter().map(|v| v.name.as_str()).collect();
    assert_eq!(names, vec!["c", "flux"], "state PLUS the named observed");

    let flux = plan.var("flux").expect("flux is planned");
    assert_eq!(flux.dims, vec!["time", "lon", "lat"], "record axis leads");
    assert_eq!(
        flux.attrs.get("units").and_then(|v| v.as_str()),
        Some("kg/s"),
        "the observed keeps the document's CF attributes"
    );
    assert_eq!(flux.values_per_record(), N_LON * N_LAT);

    // Scatter the whole trajectory the way a writer would, then read it back
    // as row-major [time, lon, lat] and check every cell against the oracle.
    let n_rec = sol.time.len();
    let n_cells = flux.values_per_record();
    let mut data = vec![0.0f64; n_rec * n_cells];
    let mut flat = vec![0.0f64; sol.state.len()];
    for r in 0..n_rec {
        for (s, slot) in flat.iter_mut().enumerate() {
            *slot = sol.state[s][r];
        }
        flux.gridding
            .scatter_record(&flat, &mut data, r)
            .expect("record scatters");
    }
    for r in 0..n_rec {
        for i in 1..=N_LON {
            for j in 1..=N_LAT {
                // Row-major over (lon, lat): lat is the fastest axis on disk.
                let at = r * n_cells + (i - 1) * N_LAT + (j - 1);
                let want = K * row(&sol, &format!("c[{i},{j}]"))[r] * weight(i, j);
                assert!(
                    (data[at] - want).abs() <= 1e-12 * want.abs().max(1.0),
                    "gridded flux at record {r}, (lon {i}, lat {j}): got {}, want {want}",
                    data[at]
                );
            }
        }
    }
}

#[test]
fn the_same_request_reaches_a_scalar_backends_observed() {
    // Bound explicitly, so the oracle below does not have to agree with the
    // document's defaults to be checking anything.
    let (k1, k2) = (0.7, 0.25);
    let prob = esm_problem(
        ProblemInput::Path(Path::new(SCALAR)),
        (0.0, 10.0),
        ProblemOptions {
            p: HashMap::from([("k1".to_string(), k1), ("k2".to_string(), k2)]),
            ..Default::default()
        },
    )
    .expect("the scalar fixture builds");
    let sol = solve(
        &prob,
        &SolveOptions {
            output_observed: vec!["total_rate".to_string()],
            ..Default::default()
        },
    )
    .expect("the scalar fixture solves");

    let rate = row(&sol, "total_rate");
    let x = sol.get("CompleteModel.x").expect("x is a state");
    let y = sol.get("CompleteModel.y").expect("y is a state");
    for (i, (&a, &b)) in x.iter().zip(y).enumerate() {
        let want = k1 * a + k2 * b;
        assert!(
            (rate[i] - want).abs() <= 1e-12 * want.abs().max(1.0),
            "total_rate at {i}: got {}, want {want}",
            rate[i]
        );
    }

    // Unrequested, it stays out — a `Solution` is state rows by default.
    let plain = solve(&prob, &SolveOptions::default()).expect("solves");
    assert!(
        !plain.state_variable_names.iter().any(|n| n == "total_rate"),
        "{:?}",
        plain.state_variable_names
    );
}

/// The CLI surface, end to end: `esm simulate --observed flux --format grid`
/// writes the derived plan, and the file that lands is diffable — every value
/// carries the axis names and coordinate values that say which cell it is.
#[cfg(all(feature = "cli", not(target_arch = "wasm32")))]
#[test]
fn the_cli_writes_a_gridded_array_observed() {
    use serde_json::Value;

    let scratch = tempfile::tempdir().expect("tempdir");
    let out = scratch.path().join("run.json");
    let status = std::process::Command::new(env!("CARGO_BIN_EXE_esm"))
        .args(["simulate", GRID])
        .args(["--time", "10"])
        .args(["--observed", "flux"])
        .args(["--format", "grid"])
        .arg("-o")
        .arg(&out)
        .output()
        .expect("esm runs");
    assert!(
        status.status.success(),
        "esm simulate failed: {}",
        String::from_utf8_lossy(&status.stderr)
    );

    let doc: Value =
        serde_json::from_str(&std::fs::read_to_string(&out).expect("output file")).expect("json");
    let grids = doc["grids"].as_array().expect("grids");
    assert_eq!(grids.len(), 1);
    let grid = &grids[0];

    // The record axis leads, and both spatial axes carry their real names.
    assert_eq!(grid["dims"][1], serde_json::json!(["lon", N_LON]));
    assert_eq!(grid["dims"][2], serde_json::json!(["lat", N_LAT]));
    let n_rec = grid["dims"][0][1].as_u64().expect("record count") as usize;

    // CF coordinates: the record axis plus the two the registry supplies.
    let coords = grid["coords"].as_array().expect("coords");
    let names: Vec<&str> = coords.iter().map(|c| c["name"].as_str().unwrap()).collect();
    assert_eq!(names, vec!["time", "lon", "lat"]);
    assert_eq!(
        coords[1]["values"],
        serde_json::json!([-100.0, -90.0, -80.0])
    );
    assert_eq!(coords[2]["attrs"]["standard_name"], "latitude");

    let vars = grid["vars"].as_array().expect("vars");
    let var = |name: &str| {
        vars.iter()
            .find(|v| v["name"] == name)
            .unwrap_or_else(|| panic!("no var '{name}' in {vars:?}"))
    };
    let flux = var("flux");
    assert_eq!(flux["dims"], serde_json::json!(["time", "lon", "lat"]));
    assert_eq!(flux["attrs"]["units"], "kg/s");
    assert_eq!(flux["dtype"], "float64");

    // The written observed is `k * c * (i + 10*j)` cell by cell, against the
    // state the SAME file wrote — so a transposed or column-major-on-disk
    // layout fails here rather than compiling into a plausible-looking array.
    let nums = |v: &Value| -> Vec<f64> {
        v.as_array()
            .expect("data")
            .iter()
            .map(|x| x.as_f64().expect("f64"))
            .collect()
    };
    let (c_data, f_data) = (nums(&var("c")["data"]), nums(&flux["data"]));
    let n_cells = N_LON * N_LAT;
    assert_eq!(f_data.len(), n_rec * n_cells);
    for r in 0..n_rec {
        for i in 1..=N_LON {
            for j in 1..=N_LAT {
                let at = r * n_cells + (i - 1) * N_LAT + (j - 1);
                let want = K * c_data[at] * weight(i, j);
                assert!(
                    (f_data[at] - want).abs() <= 1e-12 * want.abs().max(1.0),
                    "record {r}, (lon {i}, lat {j}): got {}, want {want}",
                    f_data[at]
                );
            }
        }
    }
}
