//! An [`OutputPlan`] really does drive EarthSciIO's Zarr v3 writer.
//!
//! This is the proof that the derivation in `src/data_output.rs` produces the
//! *consumer's* shape, not merely a self-consistent one: the plan is converted
//! into `earthsciio::format::OutputSchema` — mechanically, in `to_schema`
//! below, which is the whole of the adapter a runner needs — written with
//! `write_zarr_v3` under the browser-loadable `wasm` codec profile, and read
//! back through EarthSciIO's ordinary `Provider` path. The decoded array must
//! come back **row-major over `[time, lon, lat]`** with the values the flat,
//! column-major solver state held, which is exactly the transposition §7
//! specifies.
//!
//! Gated on the pre-existing opt-in `esio` feature (`cargo test --features
//! esio`); `earthsci-ast` does not link EarthSciIO on the default path, so the
//! conversion deliberately lives here in the test rather than in the crate.

#![cfg(feature = "esio")]

use std::collections::BTreeMap;
use std::sync::Arc;

use earthsci_ast::data_output::{GridPlan, OutputPlan};
use earthsci_ast::simulate_array::ArrayCompiled;
use earthsci_ast::{EsmFile, derive_output_plan, load};
use earthsciio::format::{
    ArrayData, NativeField, OutputSchema, WriteCoord, WriteVar, write_zarr_v3,
};
use earthsciio::{Cache, DataLoader, Provider};

const GRID_COORDS: &str =
    include_str!("../../EarthSciAST.jl/test/fixtures/streaming_decay_grid_coords.esm");

/// The whole adapter: a [`GridPlan`] plus the record times and the per-record
/// flat states becomes an `OutputSchema`. Everything it needs is already on the
/// plan — dims, coordinates, CF attributes, and the flat→gridded scatter.
fn to_schema(grid: &GridPlan, times: &[f64], flat_states: &[Vec<f64>]) -> OutputSchema {
    let n = times.len();

    // `OutputSchema::dims` is the record axis followed by the grid's spatial
    // axes; `GridPlan::dims` deliberately omits the record count so one plan
    // stays valid however many records get written.
    let mut dims: Vec<(String, usize)> = vec![(grid.time_dim.clone(), n)];
    dims.extend(grid.dims.iter().cloned());

    // Whole spatial extent x one time step per inner chunk; one shard covers
    // the run (the default the RFC §7 chunking policy describes).
    let mut chunk_shape: BTreeMap<String, usize> = BTreeMap::new();
    let mut shard_shape: BTreeMap<String, usize> = BTreeMap::new();
    chunk_shape.insert(grid.time_dim.clone(), 1);
    shard_shape.insert(grid.time_dim.clone(), n);
    for (d, len) in &grid.dims {
        chunk_shape.insert(d.clone(), *len);
        shard_shape.insert(d.clone(), *len);
    }

    let mut coords = vec![WriteCoord {
        name: grid.time_dim.clone(),
        values: times.to_vec(),
        attrs: serde_json::Map::new(),
    }];
    coords.extend(grid.coords.iter().map(|c| WriteCoord {
        name: c.name.clone(),
        values: c.values.clone(),
        attrs: c.attrs.clone(),
    }));

    let vars = grid
        .vars
        .iter()
        .map(|v| {
            let mut data = vec![0.0f64; n * v.values_per_record()];
            for (r, u) in flat_states.iter().enumerate() {
                v.gridding
                    .scatter_record(u, &mut data, r)
                    .expect("record scatters");
            }
            WriteVar {
                name: v.name.clone(),
                dims: v.dims.clone(),
                attrs: v.attrs.clone(),
                data,
            }
        })
        .collect();

    OutputSchema {
        dims,
        time_dim: grid.time_dim.clone(),
        chunk_shape,
        shard_shape,
        coords,
        vars,
        group_attrs: serde_json::Map::new(),
        // Both earthscilab tiers write the browser-loadable profile.
        profile: "wasm".to_string(),
    }
}

#[test]
fn a_derived_plan_writes_and_reads_back_through_zarr_v3() {
    let doc: EsmFile = load(GRID_COORDS).expect("fixture loads");
    let slots = ArrayCompiled::from_file(&doc)
        .expect("compiles")
        .state_variable_names()
        .to_vec();

    let plan: OutputPlan = derive_output_plan(&doc, &slots, &[]).expect("plan derives");
    assert_eq!(plan.grids.len(), 1);
    let grid = &plan.grids[0];

    // Two records of synthetic flat state, in the COLUMN-major slot order the
    // solver produces: u = 100*record + 10*i + j at cell (i, j) (1-based).
    let times = vec![0.0, 3600.0];
    let flat: Vec<Vec<f64>> = (0..2)
        .map(|r| {
            slots
                .iter()
                .map(|name| {
                    let (_, idx) = earthsci_ast::parse_cell_key(name).expect("cell key");
                    (100 * r + 10 * idx[0] + idx[1]) as f64
                })
                .collect()
        })
        .collect();

    let schema = to_schema(grid, &times, &flat);
    let scratch = tempfile::tempdir().expect("tempdir");
    let store = scratch.path().join("out.zarr");
    write_zarr_v3(&store, &schema).expect("write zarr v3 store");

    // Read back through EarthSciIO's ordinary Provider path.
    let var_name = grid.vars[0].name.clone();
    let base_url = format!("file://{}", store.display());
    let cache = Arc::new(
        Cache::builder()
            .data_dir(scratch.path().join("cache"))
            .build()
            .expect("cache"),
    );
    let loader = DataLoader::new("plan-roundtrip", "zarr", &base_url).variables([
        var_name.as_str(),
        "time",
        "lon",
        "lat",
    ]);
    let mut provider = Provider::new(loader, cache, None).expect("provider");
    let buffers = provider.materialize().expect("materialize");

    // Dimension-labeled, correctly shaped, C-order.
    let got = &buffers[var_name.as_str()];
    assert_eq!(got.dims, vec!["time", "lon", "lat"]);
    assert_eq!(got.shape, vec![2, 3, 2]);

    // The transposition survived the round trip: reading the store row-major
    // reproduces cell (i, j) at C offset ((r*3 + i)*2 + j).
    let decoded = f64s(got);
    for r in 0..2usize {
        for i in 0..3usize {
            for j in 0..2usize {
                let want = (100 * r + 10 * (i + 1) + (j + 1)) as f64;
                let at = (r * 3 + i) * 2 + j;
                assert!(
                    (decoded[at] - want).abs() < 1e-12,
                    "record {r} cell ({i},{j}): got {} want {want}",
                    decoded[at]
                );
            }
        }
    }

    // CF dimension coordinates round-trip with their values.
    assert_eq!(f64s(&buffers["lon"]), vec![-100.0, -90.0, -80.0]);
    assert_eq!(f64s(&buffers["lat"]), vec![30.0, 40.0]);
    assert_eq!(f64s(&buffers["time"]), times);
}

/// Decoded `float64` payload of a read-back field.
fn f64s(field: &NativeField) -> Vec<f64> {
    match &field.data {
        ArrayData::F64(v) => v.clone(),
        other => panic!("expected float64 data, got {other:?}"),
    }
}
