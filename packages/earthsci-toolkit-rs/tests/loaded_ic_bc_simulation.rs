//! End-to-end conformance for the pre-discretization + data-loader PDE pipeline
//! (`tests/conformance/pde_simulation_pipeline/DESIGN.md`).
//!
//! Drives `tests/valid/advection_reaction_loaded_ic_bc.esm` through the full Rust
//! lowering pipeline (reaction-gen → expression-template `match` → `operator_compose`
//! merge → pointwise-lift → scoped-`ic` fold) and the diffsol array simulator, with
//! every loaded field injected **through the data-Provider seam** — never as a raw
//! const array keyed by an internal consumer name (DESIGN §2, R1/R2).
//!
//! A static stub [`CadenceProvider`] serves the manifest `inputs`
//! (`tests/conformance/pde_simulation_pipeline/manifest.json`), keyed
//! `<Loader>.<variable>`. Its CONST fields are materialized once into the model's
//! forcing buffer; the scoped-`ic` equations then fold `InitialConditions.*` into
//! `u0` cell-by-cell at build time, the `variable_map` couplings route
//! `Meteorology.u_wind` / `BoundaryConditions.*_inflow` to the Advection operator,
//! and the run reproduces the fixture's inline `tests` assertions.
//!
//! Grid convention: `[lon, lat]` = row=lon, col=lat; indices are 1-based in state
//! names (`Chemistry.O3[1,1]`), 0-based internally.

use earthsci_toolkit::flatten::flatten;
use earthsci_toolkit::load_path;
use earthsci_toolkit::provider::{CadenceProvider, NativeField, ProviderError};
use earthsci_toolkit::simulate_array::ArrayCompiled;
use earthsci_toolkit::{SimulateOptions, Solution, SolverChoice};
use ndarray::{ArrayD, IxDyn};
use std::collections::HashMap;

const FIXTURE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../tests/valid/advection_reaction_loaded_ic_bc.esm"
);

/// A `[lon, lat]` grid field from a slice of `[lat0, lat1]` rows (row=lon).
fn grid(rows: &[[f64; 2]]) -> ArrayD<f64> {
    let nlon = rows.len();
    let mut data = Vec::with_capacity(nlon * 2);
    for r in rows {
        data.push(r[0]);
        data.push(r[1]);
    }
    ArrayD::from_shape_vec(IxDyn(&[nlon, 2]), data).unwrap()
}

/// A `[lat]` boundary field.
fn line(v: &[f64]) -> ArrayD<f64> {
    ArrayD::from_shape_vec(IxDyn(&[v.len()]), v.to_vec()).unwrap()
}

/// The manifest `inputs`, keyed `<Loader>.<variable>` exactly as declared in the
/// fixture's `data_loaders`.
fn manifest_inputs() -> HashMap<String, ArrayD<f64>> {
    let mut m = HashMap::new();
    m.insert(
        "InitialConditions.O3_init".to_string(),
        grid(&[[38.0, 42.0], [39.0, 43.0], [41.0, 45.0], [43.0, 47.0]]),
    );
    m.insert(
        "InitialConditions.NO_init".to_string(),
        grid(&[[0.10, 0.12], [0.11, 0.13], [0.09, 0.14], [0.12, 0.15]]),
    );
    m.insert(
        "InitialConditions.NO2_init".to_string(),
        grid(&[[1.0, 1.2], [1.1, 1.3], [0.9, 1.4], [1.2, 1.5]]),
    );
    m.insert(
        "Meteorology.u_wind".to_string(),
        grid(&[[2.0, 2.2], [2.1, 2.3], [2.2, 2.4], [2.3, 2.5]]),
    );
    m.insert(
        "BoundaryConditions.O3_inflow".to_string(),
        line(&[35.0, 36.0]),
    );
    m.insert(
        "BoundaryConditions.NO_inflow".to_string(),
        line(&[0.20, 0.25]),
    );
    m.insert(
        "BoundaryConditions.NO2_inflow".to_string(),
        line(&[1.5, 1.6]),
    );
    m
}

/// Static stub provider serving the manifest `inputs`. All fields are CONST
/// (materialized once at setup); no discrete refresh.
struct StubProvider {
    fields: HashMap<String, ArrayD<f64>>,
}

impl CadenceProvider for StubProvider {
    fn materialize(&mut self) -> Result<HashMap<String, NativeField>, ProviderError> {
        Ok(self
            .fields
            .iter()
            .map(|(k, v)| (k.clone(), NativeField::new(v.clone())))
            .collect())
    }
    fn refresh(&mut self, _t: f64) -> Result<Option<HashMap<String, NativeField>>, ProviderError> {
        Ok(None)
    }
    fn refresh_times(&self) -> Vec<f64> {
        Vec::new()
    }
}

/// Read state `name` at the output time closest to `t`.
fn value_at(sol: &Solution, name: &str, t: f64) -> f64 {
    let vi = sol
        .state_variable_names
        .iter()
        .position(|n| n == name)
        .unwrap_or_else(|| panic!("solution has no state '{name}'"));
    let ti = sol
        .time
        .iter()
        .enumerate()
        .min_by(|(_, a), (_, b)| (**a - t).abs().partial_cmp(&(**b - t).abs()).unwrap())
        .map(|(i, _)| i)
        .expect("solution has output times");
    sol.state[vi][ti]
}

fn close(actual: f64, expected: f64, abs: f64, rel: f64) -> bool {
    (actual - expected).abs() <= abs + rel * expected.abs()
}

#[test]
fn loaded_ic_bc_simulation_provider_injection() {
    // ---- Full lowering pipeline (no pre-discretized shortcut) ----------------
    let file = load_path(FIXTURE).expect("load fixture");
    let flat = flatten(&file).expect("flatten");

    // The scoped-`ic` equations were classified out of the ODE set.
    assert_eq!(
        flat.field_ics.len(),
        3,
        "expected 3 scoped-reference ic equations (O3, NO, NO2), got {:?}",
        flat.field_ics
    );

    let compiled = ArrayCompiled::from_flattened(&flat).expect("compile coupled array system");

    // ---- Install the static stub provider and materialize its CONST fields ---
    // Every loaded field enters through the provider seam, keyed `<Loader>.<var>`.
    let mut provider = StubProvider {
        fields: manifest_inputs(),
    };
    let materialized = provider.materialize().expect("materialize const fields");
    {
        let forcing = compiled.forcing_handle();
        let mut buf = forcing.borrow_mut();
        for (k, f) in materialized {
            buf.insert(k, f.array);
        }
    }

    // ---- Simulate 0 -> 600 ---------------------------------------------------
    let opts = SimulateOptions {
        solver: SolverChoice::Erk,
        abstol: 1e-12,
        reltol: 1e-10,
        max_steps: 10_000_000,
        output_times: Some(vec![0.0, 600.0]),
    };
    let sol = compiled
        .simulate((0.0, 600.0), &HashMap::new(), &HashMap::new(), &opts)
        .expect("simulate the loaded-IC/BC system");

    // ---- Assertions: the fixture's inline `tests` block ----------------------
    // (variable, time, expected, abs_tol, rel_tol). Names map `O3 -> Chemistry.O3`.
    struct A(&'static str, f64, f64, f64, f64);
    let assertions = [
        // t = 0 pins the loaded initial fields (scoped-`ic` fold from the provider).
        A("Chemistry.O3[1,1]", 0.0, 38.0, 1e-9, 0.0),
        A("Chemistry.O3[4,2]", 0.0, 47.0, 1e-9, 0.0),
        A("Chemistry.NO[1,1]", 0.0, 0.1, 1e-9, 0.0),
        A("Chemistry.NO2[3,1]", 0.0, 0.9, 1e-9, 0.0),
        // t = 600 pins the coupled reaction + advection trajectory.
        A("Chemistry.O3[1,1]", 600.0, 34.797506781720664, 1e-4, 1e-5),
        A("Chemistry.O3[4,2]", 600.0, 35.66089795504217, 1e-4, 1e-5),
        A("Chemistry.NO[1,1]", 600.0, 0.01641470334161223, 1e-6, 1e-4),
        A("Chemistry.NO2[1,1]", 600.0, 1.6832850160453867, 1e-4, 1e-5),
        A("Chemistry.NO2[3,1]", 600.0, 1.7093366875798413, 1e-4, 1e-5),
    ];

    let mut passed = 0usize;
    let mut failures: Vec<String> = Vec::new();
    for A(name, t, expected, abs, rel) in assertions {
        let actual = value_at(&sol, name, t);
        if close(actual, expected, abs, rel) {
            passed += 1;
        } else {
            failures.push(format!(
                "{name} @ t={t}: got {actual}, expected {expected} (abs {abs}, rel {rel})"
            ));
        }
    }

    assert!(
        failures.is_empty(),
        "{}/{} assertions passed; failures:\n{}",
        passed,
        passed + failures.len(),
        failures.join("\n")
    );
    assert_eq!(passed, 9, "all 9 inline `tests` assertions must pass");
}
