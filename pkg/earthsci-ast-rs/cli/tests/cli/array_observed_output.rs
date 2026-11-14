//! `esm simulate --observed <array observed> --format grid` writes the field
//! gridded and labeled. The library half of the seam (`SolveOptions::
//! output_observed` and `derive_output_plan`) is pinned by
//! `earthsci-ast`'s `tests/array_observed_output.rs`; this is the CLI end of it.
//!
//! Every expected value is an oracle over the run's OWN state, never a recorded
//! number: the fixture's observed is `flux[i,j] = k * c[i,j] * (i + 10*j)`, a
//! weight distinct in every cell and asymmetric across the two axes, so a
//! transposed or row-major-on-disk layout fails.
//!
//! Gated on this crate's `diffsol` feature: a build with no time integrator
//! refuses `esm simulate`.

#![cfg(feature = "diffsol")]

const GRID: &str = "../tests/fixtures/output/array_observed_grid.esm";

const N_LON: usize = 3;
const N_LAT: usize = 2;
/// The fixture's `k` default.
const K: f64 = 0.001;

/// The fixture's per-cell weight, `i + 10*j` at 1-based `(i, j)`.
fn weight(i: usize, j: usize) -> f64 {
    (i + 10 * j) as f64
}

/// The CLI surface, end to end: `esm simulate --observed flux --format grid`
/// writes the derived plan, and the file that lands is diffable — every value
/// carries the axis names and coordinate values that say which cell it is.
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
    let flux = var("Grid.flux");
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
    let (c_data, f_data) = (nums(&var("Grid.c")["data"]), nums(&flux["data"]));
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
