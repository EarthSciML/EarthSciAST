//! Output-plan derivation over REAL fixture documents and REAL compiler-
//! produced flat state names (streaming-output-sinks RFC §7–§9).
//!
//! The unit tests inside `src/data_output.rs` pin the cell-key inversion
//! against hand-built name lists. These drive the same code from the other
//! end: `ArrayCompiled` builds the flat slot names from a fixture exactly as a
//! run does, and the plan derived from them must carry the fixture's real
//! `index_sets` axis names, its CF coordinates, and its grid decomposition.

use earthsci_ast::data_output::{
    DTYPE_FLOAT64, OutputError, derive_output_meta, derive_output_plan, parse_cell_key,
};
use earthsci_ast::simulate_array::ArrayCompiled;
use earthsci_ast::{EsmFile, load};

/// Wave-3 streaming fixture: one array state `c` over a 3x2 `lon`/`lat` grid
/// plus a `coordinates` registry keyed BY DIM NAME with inline values — the
/// document that exercises real axis names AND CF dimension coordinates.
const GRID_COORDS: &str =
    include_str!("../../EarthSciAST.jl/test/fixtures/streaming_decay_grid_coords.esm");

/// Shared cross-binding corpus fixture: a rectilinear `tracer[lon,lat,lev]`
/// and an unstructured `cell_tracer[cells]` in one document — two emergent
/// grids — with a registry whose entries are all AUXILIARY (keyed by something
/// other than a dim name, or `source`-backed).
const COORDS_REGISTRY: &str = include_str!("../../../tests/valid/coordinates_registry.esm");

fn slot_names(doc: &EsmFile) -> Vec<String> {
    ArrayCompiled::from_file(doc)
        .expect("fixture compiles on the array path")
        .state_variable_names()
        .to_vec()
}

#[test]
fn grid_fixture_yields_real_axis_names_and_cf_dimension_coordinates() {
    let doc: EsmFile = load(GRID_COORDS).expect("fixture loads");
    let slots = slot_names(&doc);
    assert_eq!(slots.len(), 6, "3x2 grid = 6 flat slots: {slots:?}");

    let plan = derive_output_plan(&doc, &slots, &[]).expect("plan derives");
    assert_eq!(plan.grids.len(), 1, "one variable, one grid");
    let grid = &plan.grids[0];

    // Real `index_sets` names in DECLARED order, not positional `c_d0`/`c_d1`.
    assert_eq!(
        grid.dims,
        vec![("lon".to_string(), 3), ("lat".to_string(), 2)]
    );
    assert_eq!(grid.time_dim, "time");

    // CF dimension coordinates from the additive registry (§8.3).
    let names: Vec<&str> = grid.coords.iter().map(|c| c.name.as_str()).collect();
    assert_eq!(names, vec!["lon", "lat"]);
    assert_eq!(grid.coords[0].values, vec![-100.0, -90.0, -80.0]);
    assert_eq!(grid.coords[0].attrs["standard_name"], "longitude");
    assert_eq!(grid.coords[0].attrs["units"], "degrees_east");
    assert_eq!(grid.coords[0].attrs["axis"], "X");
    assert_eq!(grid.coords[1].values, vec![30.0, 40.0]);
    assert_eq!(grid.coords[1].attrs["axis"], "Y");

    // One variable, time-major dims, CF attrs off the document.
    assert_eq!(grid.vars.len(), 1);
    let var = &grid.vars[0];
    assert_eq!(var.dims, vec!["time", "lon", "lat"]);
    assert_eq!(var.dtype, DTYPE_FLOAT64);
    assert_eq!(var.attrs["units"], "kg");
    assert!(
        var.attrs["description"]
            .as_str()
            .unwrap()
            .contains("Gridded tracer")
    );
    assert_eq!(var.values_per_record(), 6);

    // The inversion, against the names the COMPILER produced: give each flat
    // slot the value 10*i + j of its own 1-based cell and read the gridded
    // array back in C order.
    let mut u = vec![0.0f64; slots.len()];
    for (flat, name) in slots.iter().enumerate() {
        let (base, idx) = parse_cell_key(name).unwrap_or_else(|| panic!("cell key: {name}"));
        assert_eq!(base, var.name);
        u[flat] = (10 * idx[0] + idx[1]) as f64;
    }
    let mut out = vec![0.0f64; 6];
    var.gridding.scatter(&u, &mut out).expect("scatter");
    assert_eq!(out, vec![11.0, 12.0, 21.0, 22.0, 31.0, 32.0]);

    // A two-record trajectory buffer places record 1 after record 0.
    let mut traj = vec![0.0f64; 12];
    var.gridding
        .scatter_record(&u, &mut traj, 1)
        .expect("rec 1");
    assert_eq!(&traj[6..], &out[..]);
    assert_eq!(&traj[..6], &[0.0; 6]);
}

#[test]
fn two_shape_signatures_become_two_grids() {
    let doc: EsmFile = load(COORDS_REGISTRY).expect("fixture loads");
    let slots = slot_names(&doc);
    // tracer over [lon(4), lat(3), lev(2)] = 24 cells + cell_tracer over
    // [cells(5)] = 5 cells.
    assert_eq!(slots.len(), 29, "{slots:?}");

    let plan = derive_output_plan(&doc, &slots, &[]).expect("plan derives");
    assert_eq!(plan.grids.len(), 2, "grids are emergent (RFC §9)");
    assert_eq!(plan.n_vars(), 2);

    let cellular = plan
        .grids
        .iter()
        .find(|g| g.dims.len() == 1)
        .expect("unstructured grid");
    assert_eq!(cellular.dims, vec![("cells".to_string(), 5)]);
    assert_eq!(cellular.vars[0].dims, vec!["time", "cells"]);

    let rect = plan
        .grids
        .iter()
        .find(|g| g.dims.len() == 3)
        .expect("rectilinear grid");
    assert_eq!(
        rect.dims,
        vec![
            ("lon".to_string(), 4),
            ("lat".to_string(), 3),
            ("lev".to_string(), 2),
        ]
    );
    assert_eq!(rect.vars[0].dims, vec!["time", "lon", "lat", "lev"]);
    assert_eq!(rect.vars[0].values_per_record(), 24);

    // Every registry entry here is auxiliary (`grid_lon`, `level`, `cell_lat`,
    // … are not dim names, or are `source`-backed), so the v1 dimension-
    // coordinate path emits nothing — bare integer axes, exactly as the Julia
    // reference does.
    assert!(plan.grids.iter().all(|g| g.coords.is_empty()));

    // The registry itself IS parsed and carried (it used to be dropped on
    // load), including the `source`/`axis` fields.
    let meta = derive_output_meta(&doc);
    assert_eq!(meta.coordinates.len(), 5);
    assert_eq!(
        meta.coordinates["level"].source.as_deref(),
        Some("lev_pressure")
    );
    assert_eq!(meta.coordinates["level"].axis.as_deref(), Some("Z"));
    assert!(meta.coordinates["cell_lat"].axis.is_none());
    assert_eq!(
        meta.coordinates["grid_lon"].values.as_deref(),
        Some(&[-100.0, -99.0, -98.0, -97.0][..])
    );
}

/// The `coordinates` registry survives a parse → emit → parse round trip. It
/// used to be silently discarded because the Rust `EsmFile` did not model it.
#[test]
fn coordinates_registry_round_trips() {
    let doc: EsmFile = load(COORDS_REGISTRY).expect("fixture loads");
    let json = earthsci_ast::save(&doc).expect("serializes");
    let back: EsmFile = load(&json).expect("reparses");
    let a = derive_output_meta(&doc);
    let b = derive_output_meta(&back);
    assert_eq!(a.coordinates, b.coordinates);
    assert_eq!(a.coordinates.len(), 5);
}

// --------------------------------------------------------------------------
// RFC decision 8: output is state PLUS a caller-named subset of observed.
// --------------------------------------------------------------------------

const OBSERVED_DOC: &str = r#"{
  "esm": "1.0.0",
  "metadata": { "name": "ObservedGating" },
  "domain": { "independent_variable": "t" },
  "models": {
    "M": {
      "variables": {
        "x":  { "type": "unknown",     "units": "kg",   "default": 1.0 },
        "k":  { "type": "parameter", "units": "1/s",  "default": 0.5 },
        "y":  { "type": "observed",  "units": "kg/s", "description": "flux",
                "expression": { "op": "*", "args": ["k", "x"] } },
        "z":  { "type": "observed",  "units": "kg",
                "expression": { "op": "+", "args": ["x", 1.0] } }
      },
      "equations": [
        { "lhs": { "op": "D", "args": ["x"], "wrt": "t" },
          "rhs": { "op": "*", "args": [{ "op": "-", "args": ["k"] }, "x"] } }
      ]
    }
  }
}"#;

/// The runner's flat rows: the state, plus the observed trajectories it
/// appended (as `Solution::state_variable_names` carries them).
fn observed_slots() -> Vec<String> {
    ["M.x", "M.y", "M.z"].iter().map(|s| (*s).into()).collect()
}

#[test]
fn observed_fields_are_written_only_when_the_caller_names_them() {
    let doc: EsmFile = load(OBSERVED_DOC).expect("doc loads");
    let slots = observed_slots();

    // State only by default — an observed field is NOT output just because the
    // evaluator produced it.
    let plan = derive_output_plan(&doc, &slots, &[]).expect("plan");
    assert_eq!(plan.n_vars(), 1);
    assert!(plan.var("M.x").is_some());
    assert!(plan.var("M.y").is_none());

    // Naming one adds exactly that one, with its own CF attrs.
    let plan = derive_output_plan(&doc, &slots, &["y".to_string()]).expect("plan");
    assert_eq!(plan.n_vars(), 2);
    let y = plan.var("M.y").expect("y is written");
    assert_eq!(y.attrs["units"], "kg/s");
    assert_eq!(y.attrs["description"], "flux");
    // The record axis comes from `domain.independent_variable`.
    assert_eq!(y.dims, vec!["t"]);

    // A model-qualified request name works too.
    let plan = derive_output_plan(&doc, &slots, &["M.z".to_string()]).expect("plan");
    assert_eq!(plan.n_vars(), 2);
    assert!(plan.var("M.z").is_some());

    // Scalars share ONE grid rather than inventing a singleton axis each.
    let plan = derive_output_plan(&doc, &slots, &["y".to_string(), "z".to_string()]).expect("plan");
    assert_eq!(plan.grids.len(), 1);
    assert!(plan.grids[0].dims.is_empty());
    assert_eq!(plan.grids[0].vars.len(), 3);
}

#[test]
fn an_unavailable_observed_request_is_refused() {
    let doc: EsmFile = load(OBSERVED_DOC).expect("doc loads");
    // `z` was never evaluated into the flat rows, so asking for it must fail
    // rather than silently produce a store missing the field.
    let err = derive_output_plan(
        &doc,
        &["M.x".to_string(), "M.y".to_string()],
        &["z".to_string()],
    )
    .unwrap_err();
    assert!(
        matches!(err, OutputError::UnknownObserved { ref name } if name == "z"),
        "{err}"
    );
}

#[test]
fn a_document_state_shape_that_contradicts_the_flat_state_is_refused() {
    let doc: EsmFile = load(GRID_COORDS).expect("fixture loads");
    // The document declares c over [lon(3), lat(2)]; hand the deriver a flat
    // state gridded 3x3 instead. Mislabeling the axis would be silently wrong
    // science, so it must fail loudly.
    let mut slots = Vec::new();
    for j in 1..=3 {
        for i in 1..=3 {
            slots.push(format!("c[{i},{j}]"));
        }
    }
    let err = derive_output_plan(&doc, &slots, &[]).unwrap_err();
    assert!(
        matches!(err, OutputError::DimLengthMismatch { ref dim, .. } if dim == "lat"),
        "{err}"
    );
}
