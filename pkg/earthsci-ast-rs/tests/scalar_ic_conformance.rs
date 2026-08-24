//! Cross-language conformance: 0-D (`scalar`) `ic` equations seed their state
//! (esm-spec §11.4 "Initial conditions (the `ic` op)", its "Run-time
//! overrides", §6.6.5 "Build-time evaluation scope").
//!
//! Shared fixtures + Julia-minted goldens live under
//! `tests/conformance/scalar_ic/` (repo root); the Julia runner
//! (`conformance_scalar_ic_test.jl`) and the Python runner
//! (`test_scalar_ic_conformance.py`) gate the same goldens.
//!
//! The Rust ARRAY runtime folds a 0-D `ic` correctly, but the SCALAR
//! interpreter in `simulate.rs` used to drop it: an `ic` LHS matched neither
//! `state_lhs_name` nor `observed_lhs_name` in `classify_equations`, so the
//! equation fell off the end of the classification loop and the state silently
//! started at its declared `default`. Every state in `scalar_ic.esm` declares a
//! `default` that DIFFERS from its `ic` so that substitution cannot hide, and
//! `y` integrates `D(y)/dt = u` so the seeded value must reach the trajectory
//! too. `scalar_ic_in_array_model.esm` re-runs the contract inside the array
//! runtime.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::pde_inline_tests::run_pde_tests_with_base_dir;
use earthsci_ast::{SimulateOptions, SolverChoice, load_string, simulate};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

mod common;

fn category_dir() -> PathBuf {
    common::repo_fixture("conformance/scalar_ic")
}

fn read_json(path: &PathBuf) -> serde_json::Value {
    let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

fn manifest_opts(manifest: &serde_json::Value) -> SimulateOptions {
    let rs = &manifest["integrators"]["rust"];
    assert_eq!(rs["solver"].as_str(), Some("Erk"));
    SimulateOptions {
        solver: SolverChoice::Erk,
        reltol: rs["reltol"].as_f64().expect("reltol"),
        abstol: rs["abstol"].as_f64().expect("abstol"),
        ..Default::default()
    }
}

#[test]
fn scalar_ic_matches_golden() {
    let dir = category_dir();
    let manifest = read_json(&dir.join("manifest.json"));
    assert_eq!(manifest["category"].as_str(), Some("scalar_ic"));
    assert_eq!(manifest["reference_binding"].as_str(), Some("julia"));
    let required: Vec<&str> = manifest["bindings_required"]
        .as_array()
        .expect("bindings_required")
        .iter()
        .map(|v| v.as_str().expect("binding name"))
        .collect();
    for b in ["julia", "python", "rust"] {
        assert!(required.contains(&b), "manifest must require {b}");
    }

    let rtol = manifest["tolerances"]["assertion_rtol"]
        .as_f64()
        .expect("rtol");
    let atol = manifest["tolerances"]["assertion_atol"]
        .as_f64()
        .expect("atol");
    let opts = manifest_opts(&manifest);

    for fx in manifest["fixtures"].as_array().expect("fixtures") {
        let esm_path = dir.join(fx["path"].as_str().expect("path"));
        let golden = read_json(&dir.join(fx["golden"].as_str().expect("golden")));
        assert_eq!(golden["reference_binding"].as_str(), Some("julia"));

        let text =
            fs::read_to_string(&esm_path).unwrap_or_else(|e| panic!("read {esm_path:?}: {e}"));
        let file = load_string(&text)
            .unwrap_or_else(|e| panic!("fixture {esm_path:?} does not load: {e}"));
        let results =
            run_pde_tests_with_base_dir(&file, fx["model"].as_str(), &opts, Some(dir.as_path()));

        let expected = golden["assertions"].as_array().expect("golden assertions");
        assert_eq!(results.len(), expected.len());

        for g in expected {
            let test_id = g["test_id"].as_str().expect("test_id");
            let idx = g["assertion_idx"].as_u64().expect("assertion_idx") as usize;
            let r = results
                .iter()
                .find(|r| r.test_id == test_id && r.assertion_idx == idx)
                .unwrap_or_else(|| panic!("missing assertion {test_id}#{idx}"));
            assert!(r.passed, "{test_id}#{idx}: {}", r.message);
            let actual = r
                .actual
                .unwrap_or_else(|| panic!("{test_id}#{idx}: no actual"));
            let want = g["actual"].as_f64().expect("golden actual");
            let diff = (actual - want).abs();
            assert!(
                diff <= atol || diff <= rtol * want.abs().max(actual.abs()),
                "{test_id}#{idx}: actual {actual} vs golden {want}"
            );
        }
    }
}

/// Direct coverage of the esm-spec §11.4 seeding precedence on the scalar
/// interpreter: an explicit `initial_conditions` entry wins, else the state's
/// own `ic` equation (parameters bound to their override-or-default values,
/// §6.6.5), else the declared `default`.
#[test]
fn scalar_ic_seeding_precedence() {
    let dir = category_dir();
    let path = dir.join("fixtures/scalar_ic.esm");
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    let file = load_string(&text).expect("fixture loads");
    let opts = SimulateOptions {
        solver: SolverChoice::Erk,
        reltol: 1e-12,
        abstol: 1e-14,
        output_times: Some(vec![0.0]),
        ..Default::default()
    };

    let at0 = |sol: &earthsci_ast::Solution, name: &str| -> f64 {
        let i = sol
            .state_variable_names
            .iter()
            .position(|n| n == name)
            .unwrap_or_else(|| panic!("no state {name} in {:?}", sol.state_variable_names));
        sol.state[i][0]
    };

    // (1) Defaults: each state takes its own ic; `z` declares none and takes 7.
    let sol = simulate(&file, (0.0, 1.0), &HashMap::new(), &HashMap::new(), &opts)
        .expect("defaults simulate");
    assert_eq!(at0(&sol, "M.u"), 3.0);
    assert_eq!(at0(&sol, "M.q"), 2.0);
    assert_eq!(at0(&sol, "M.w"), 4.0);
    assert_eq!(at0(&sol, "M.z"), 7.0);

    // (2) A parameter override reaches the ic's build-time scope, under either
    // spelling of the key (§6.6.2).
    for key in ["A", "M.A"] {
        let params = HashMap::from([(key.to_string(), 10.0)]);
        let sol = simulate(&file, (0.0, 1.0), &params, &HashMap::new(), &opts)
            .unwrap_or_else(|e| panic!("{key}: simulate failed: {e}"));
        assert_eq!(at0(&sol, "M.w"), 20.0, "{key}");
        assert_eq!(at0(&sol, "M.u"), 3.0, "{key}: parameter-free ic moved");
    }

    // (3) A run-time `initial_conditions` entry beats the ic equation.
    for key in ["u", "M.u"] {
        let ics = HashMap::from([(key.to_string(), 9.0)]);
        let sol = simulate(&file, (0.0, 1.0), &HashMap::new(), &ics, &opts)
            .unwrap_or_else(|e| panic!("{key}: simulate failed: {e}"));
        assert_eq!(at0(&sol, "M.u"), 9.0, "{key}");
        assert_eq!(at0(&sol, "M.w"), 4.0, "{key}: unnamed state lost its ic");
    }
}
