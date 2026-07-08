//! End-to-end simulate() conformance for the coupled wildfire-atmosphere-ocean
//! regrid fixture (`tests/valid/wildfire_atmosphere_ocean.esm`), the Rust analog
//! of the Julia inline `tests` driver.
//!
//! The fixture is a COUPLED multi-model system (atmosphere + wildfire + ocean +
//! algebraic fire/flux calculators) whose air-sea coupling remaps a spatially-
//! varying atmosphere-grid flux onto a different ocean grid by an INLINE
//! conservative regrid (`polygon_intersection_area` narrow phase + a bin-skolem
//! broad phase). It exercises, through the array runtime:
//!   * coupled flatten → `ArrayCompiled::from_flattened` with the document
//!     `index_sets` registry carried through;
//!   * a whole-array `D(SST)` lifted to per-cell integration over `ocean_cells`;
//!   * `ic`-only array/scalar states (`u_ocean`, `phi`, `wind_*`) held at ic with
//!     zero derivative (so `phi` feeding `heat_release` cannot drift);
//!   * the inline regrid: `polygon_intersection_area` over `[cells, verts, coord]`
//!     geometry with partial indexing, the value-invention bin scaffolding dropped
//!     and its inert broad-phase `join.on` elided (the dense narrow phase is
//!     numerically identical — pruned pairs have zero overlap area).
//!
//! It asserts the OceanDynamics inline `tests` block (SST at t=0 / t=3600) plus
//! the constant 0-D states, so a wrong regrid weight matrix (which would move the
//! surface_heat_flux = [100, 283.33, 350] W/m^2) fails here.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::simulate::Solution;
use earthsci_ast::{EsmFile, Model, ModelTest, SimulateOptions, SolverChoice, load, simulate};
use std::collections::HashMap;
use std::fs;

const FIXTURE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../tests/valid/wildfire_atmosphere_ocean.esm"
);

fn model<'a>(file: &'a EsmFile, name: &str) -> &'a Model {
    file.models
        .as_ref()
        .and_then(|m| m.get(name))
        .unwrap_or_else(|| panic!("fixture has no model {name}"))
}

/// Value of `var` at the output node nearest `time`. `var` may be the bare
/// model-local name (`SST[1]`) or a namespaced state (`OceanDynamics.SST[1]`).
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
    let ti = sol
        .time
        .iter()
        .enumerate()
        .min_by(|(_, a), (_, b)| (**a - time).abs().partial_cmp(&(**b - time).abs()).unwrap())
        .map(|(i, _)| i)
        .unwrap();
    sol.state[slot][ti]
}

fn run(file: &EsmFile, test: &ModelTest) -> Solution {
    let mut times: Vec<f64> = test.assertions.iter().map(|a| a.time).collect();
    times.push(test.time_span.start);
    times.push(test.time_span.end);
    times.sort_by(|a, b| a.partial_cmp(b).unwrap());
    times.dedup_by(|a, b| (*a - *b).abs() < 1e-12);
    let opts = SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-12,
        reltol: 1e-10,
        max_steps: 1_000_000,
        output_times: Some(times),
    };
    let ics = test.initial_conditions.clone().unwrap_or_default();
    simulate(
        file,
        (test.time_span.start, test.time_span.end),
        &HashMap::new(),
        &ics,
        &opts,
    )
    .unwrap_or_else(|e| panic!("simulate failed: {e}"))
}

/// Drive the OceanDynamics inline `tests` block through `simulate` and assert
/// every assertion within its declared tolerance.
#[test]
fn wildfire_ocean_inline_tests() {
    let json = fs::read_to_string(FIXTURE).expect("read fixture");
    let file = load(&json).expect("load fixture");
    let ocean = model(&file, "OceanDynamics");
    let tests = ocean
        .tests
        .as_ref()
        .filter(|t| !t.is_empty())
        .expect("OceanDynamics has an inline tests block");

    let mut checked = 0usize;
    for test in tests {
        assert!(
            !test.assertions.is_empty(),
            "test {} has no assertions",
            test.id
        );
        let sol = run(&file, test);
        for a in &test.assertions {
            let actual = lookup(&sol, &a.variable, a.time);
            let abs = a.tolerance.as_ref().and_then(|t| t.abs).unwrap_or(0.0);
            let rel = a.tolerance.as_ref().and_then(|t| t.rel).unwrap_or(1e-6);
            let tol = abs + rel * a.expected.abs();
            assert!(
                (actual - a.expected).abs() <= tol,
                "[{}] {} @ t={}: got {actual}, expected {} (tol {tol})",
                test.id,
                a.variable,
                a.time,
                a.expected
            );
            checked += 1;
        }
    }
    assert!(
        checked >= 6,
        "expected >= 6 inline assertions, got {checked}"
    );
}

/// The conservatively-regridded flux drives SST to exactly the hand-derived
/// closed form (surface_heat_flux = [100, 283.33, 350] W/m^2, u_ocean = 0 so
/// advection vanishes and SST(t) = 290 + t*flux/4.18e6), and every coupled 0-D
/// / ic-only state stays constant (a drift in `phi` would corrupt `T` via
/// `heat_release`).
#[test]
fn wildfire_regrid_trajectory_and_constant_states() {
    let json = fs::read_to_string(FIXTURE).expect("read fixture");
    let file = load(&json).expect("load fixture");
    let opts = SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-12,
        reltol: 1e-10,
        max_steps: 1_000_000,
        output_times: Some(vec![0.0, 3600.0]),
    };
    let sol = simulate(
        &file,
        (0.0, 3600.0),
        &HashMap::new(),
        &HashMap::new(),
        &opts,
    )
    .expect("simulate the coupled regrid fixture");

    // SST(3600) = 290 + 3600 * surface_heat_flux / 4_180_000.
    let expected_sst = [290.0861244019, 290.2440191388, 290.3014354067];
    for (o, exp) in expected_sst.iter().enumerate() {
        let got = lookup(&sol, &format!("SST[{}]", o + 1), 3600.0);
        assert!(
            (got - exp).abs() <= 1e-6 * exp.abs(),
            "SST[{}](3600): got {got}, expected {exp}",
            o + 1
        );
        // SST starts exactly at its ic.
        let got0 = lookup(&sol, &format!("SST[{}]", o + 1), 0.0);
        assert!((got0 - 290.0).abs() <= 1e-9, "SST[{}](0) != 290", o + 1);
    }

    // Recover surface_heat_flux from the discretized derivative and check the
    // conservative regrid weights precisely: [100, 283.333…, 350], Σ = 800.
    let flux: Vec<f64> = (0..3)
        .map(|o| (lookup(&sol, &format!("SST[{}]", o + 1), 3600.0) - 290.0) / 3600.0 * 4_180_000.0)
        .collect();
    let expected_flux = [100.0, 283.3333333333, 350.0];
    for (o, exp) in expected_flux.iter().enumerate() {
        assert!(
            (flux[o] - exp).abs() <= 1e-3,
            "surface_heat_flux[{}]: got {}, expected {exp}",
            o + 1,
            flux[o]
        );
    }
    // Conservative regrid: the AREA-WEIGHTED total is preserved. With ocean
    // cell areas A_o = [2, 1.5, 0.5], Σ_o A_o·flux_o = Σ_a A_a·flux_atmos_a =
    // 1·(50+150+250+350) = 800 (the source cells are unit squares).
    let area_o = [2.0, 1.5, 0.5];
    let weighted: f64 = flux.iter().zip(area_o.iter()).map(|(f, a)| f * a).sum();
    assert!(
        (weighted - 800.0).abs() <= 1e-2,
        "regrid must conserve area-weighted flux (Σ A_o·flux_o = 800), got {weighted}"
    );

    // Coupled 0-D / ic-only states are held constant.
    assert!(
        (lookup(&sol, "T", 3600.0) - 288.0).abs() <= 1e-9,
        "T drifted"
    );
    assert!(
        (lookup(&sol, "phi", 3600.0) - 1.0).abs() <= 1e-9,
        "phi drifted"
    );
    assert!(
        (lookup(&sol, "fuel", 3600.0) - 10.0).abs() <= 1e-9,
        "fuel drifted"
    );
    assert!(
        (lookup(&sol, "wind_u", 3600.0)).abs() <= 1e-9,
        "wind_u drifted"
    );
    assert!(
        (lookup(&sol, "wind_v", 3600.0)).abs() <= 1e-9,
        "wind_v drifted"
    );
    for o in 1..=3 {
        assert!(
            lookup(&sol, &format!("u_ocean[{o}]"), 3600.0).abs() <= 1e-9,
            "u_ocean[{o}] drifted"
        );
    }
}
