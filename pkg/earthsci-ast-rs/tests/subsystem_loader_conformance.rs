//! Subsystem-loader consumption — pure-I/O data loader MOUNTED AS A MODEL
//! SUBSYSTEM, consumed by the owning model's OWN equations (RFC
//! `pure-io-data-loaders` §4.3; CONFORMANCE_SPEC.md §5.11).
//!
//! Shared fixture + analytic golden live under
//! `tests/conformance/subsystem_loader/`. Model `Box` mounts a static (CONST)
//! loader `raw` (vars `k`, `wind`) and its single ODE consumes both a
//! BARE-SCALAR reference `raw.k` and a GATHER `index(raw.wind, 2)`, integrating
//! `D(c) = (raw.k + wind[2]) - c`, c(0)=0. With the offline CONST provider
//! (k=2, wind[2]=5) the forcing `F = 7` is constant, so `c(t) = 7 (1 - e^-t)`
//! is analytic.
//!
//! ## What this locks for the Rust binding
//!
//! Previously the Rust flattener left `Model.subsystems` opaque, so a
//! DataSource-subsystem field was never materialized/bound. `flatten` now lowers
//! each loader variable to a const-array-backed observed `Box.raw.<var>` with no
//! defining expression, and namespaces the owner's bare `raw.<var>` references to
//! `Box.raw.<var>`. Both then resolve at the RHS through the same
//! data-Provider forcing seam the top-level-loader fixtures use
//! (`loaded_ic_bc_simulation.rs`): a bare-scalar field is seeded as a 0-D
//! forcing array (read back as a scalar); a gathered field as a 1-D array.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::flatten::flatten;
use earthsci_ast::load_path;
use earthsci_ast::simulate_array::ArrayCompiled;
use earthsci_ast::{SimulateOptions, Solution, SolverChoice};
use ndarray::{ArrayD, IxDyn};
use std::collections::HashMap;
use std::path::PathBuf;

mod common;

/// Manifest trajectory band (`manifest.json` `tolerances`).
const TRAJ_RTOL: f64 = 1e-4;
const TRAJ_ATOL: f64 = 1e-6;

fn fixture_dir() -> PathBuf {
    common::repo_fixture("conformance/subsystem_loader")
}

fn read_json(path: &PathBuf) -> serde_json::Value {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

fn approximately_equal(actual: f64, expected: f64, rel: f64, abs: f64) -> bool {
    let diff = (actual - expected).abs();
    diff <= abs || diff <= rel * expected.abs().max(actual.abs())
}

/// Linear interpolation of `series` (sampled at `times`) at `t`, clamped to the
/// endpoints — the Rust analogue of the Python runner's `np.interp`.
fn interp(times: &[f64], series: &[f64], t: f64) -> f64 {
    if t <= times[0] {
        return series[0];
    }
    if t >= times[times.len() - 1] {
        return series[series.len() - 1];
    }
    for w in 1..times.len() {
        if t <= times[w] {
            let f = (t - times[w - 1]) / (times[w] - times[w - 1]);
            return series[w - 1] + f * (series[w] - series[w - 1]);
        }
    }
    series[series.len() - 1]
}

fn value_at(sol: &Solution, name: &str, t: f64) -> f64 {
    let vi = sol
        .state_variable_names
        .iter()
        .position(|n| n == name)
        .unwrap_or_else(|| {
            panic!(
                "solution has no state '{name}'; vars: {:?}",
                sol.state_variable_names
            )
        });
    interp(&sol.time, &sol.state[vi], t)
}

/// Since 1.0.0 a data source is a document-scoped registry entry, not a
/// component: it cannot be mounted as a subsystem, so there is no
/// `Box.raw.<var>` observed any more. The owning model declares a PARAMETER per
/// consumed field carrying `update: {kind: "data", source, from}`, and the
/// flattener lowers each to `Box.<var>` in the DISCRETE bucket. Its value still
/// arrives at the RHS through the provider forcing seam, so nothing defines it
/// and it is not integrated.
#[test]
fn source_backed_parameters_flatten_to_discrete_inputs() {
    let file =
        load_path(fixture_dir().join("fixtures/subsystem_loader_ode.esm")).expect("load fixture");
    let flat = flatten(&file).expect("flatten");

    for name in ["Box.k", "Box.wind"] {
        let var = flat.discrete_variables.get(name).unwrap_or_else(|| {
            panic!(
                "{name} must be a discrete (source-refreshed) parameter; got {:?}",
                flat.discrete_variables.keys().collect::<Vec<_>>()
            )
        });
        let update = var.update.as_ref().unwrap_or_else(|| {
            panic!("{name} must carry the `update` that makes it source-backed")
        });
        assert!(
            update.rules().iter().all(|r| r.source() == Some("raw")),
            "{name} must refresh from the declared source 'raw'"
        );
        assert!(
            !update.is_brownian(),
            "{name} is a data input, not a noise source"
        );

        // Not an integrated state, not an observed, and no equation defines it
        // (the value is injected at the RHS through the provider seam).
        assert!(
            !flat.state_variables.contains_key(name),
            "{name} must not be an integrated state"
        );
        assert!(
            !flat.observed_variables.contains_key(name),
            "{name} must not be an observed"
        );
        assert!(
            !flat
                .equations
                .iter()
                .any(|eq| matches!(&eq.lhs, earthsci_ast::Expr::Variable(v) if v == name)),
            "{name} must have no defining equation"
        );
    }
    // The owner's own state is the only integrated variable.
    assert!(flat.state_variables.contains_key("Box.c"));
}

/// Integrate the subsystem-loader ODE end-to-end with the loader fields served
/// through the provider forcing seam, and assert every golden trajectory
/// time-point's `Box.c` within the manifest trajectory band.
#[test]
fn subsystem_loader_trajectory_matches_golden() {
    let file =
        load_path(fixture_dir().join("fixtures/subsystem_loader_ode.esm")).expect("load fixture");
    let golden = read_json(&fixture_dir().join("golden/subsystem_loader_ode.json"));

    let flat = flatten(&file).expect("flatten");
    let compiled = ArrayCompiled::from_flattened(&flat).expect("compile subsystem-loader system");

    // Seed one OFFLINE CONST provider field per loader variable from the
    // golden's `native` values, keyed by the flattened observed name. A
    // bare-scalar field is a 0-D array (read back as a scalar); a gathered field
    // is a 1-D array. This is the provider seam the RHS reads each step.
    {
        let forcing = compiled.forcing_handle();
        let mut buf = forcing.borrow_mut();
        for (name, spec) in golden["loaders"].as_object().unwrap() {
            let native: Vec<f64> = spec["native"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_f64().unwrap())
                .collect();
            let consumption = spec["consumption"].as_str().unwrap();
            let arr = if consumption.starts_with("bare-scalar") {
                ArrayD::from_elem(IxDyn(&[]), native[0]) // 0-D → scalar at the RHS
            } else {
                ArrayD::from_shape_vec(IxDyn(&[native.len()]), native).unwrap()
            };
            buf.insert(name.clone(), arr);
        }
    }

    let tspan = &golden["cadence"]["tspan"];
    let (t0, t1) = (tspan[0].as_f64().unwrap(), tspan[1].as_f64().unwrap());

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
        output_times: Some(want_times),
        progress: None,
    };
    let sol = compiled
        .simulate((t0, t1), &HashMap::new(), &HashMap::new(), &opts)
        .expect("simulate the subsystem-loader system");

    assert_eq!(
        sol.state_variable_names,
        golden["state_order"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap().to_string())
            .collect::<Vec<_>>(),
        "state order must match the golden"
    );

    for (tk, expected) in traj {
        if tk == "comment" {
            continue;
        }
        let t: f64 = tk.parse().unwrap();
        let want = expected["Box.c"].as_f64().unwrap();
        let got = value_at(&sol, "Box.c", t);
        assert!(
            approximately_equal(got, want, TRAJ_RTOL, TRAJ_ATOL),
            "Box.c @ t={t}: expected {want}, got {got} (rtol={TRAJ_RTOL}, atol={TRAJ_ATOL})"
        );
    }
}
