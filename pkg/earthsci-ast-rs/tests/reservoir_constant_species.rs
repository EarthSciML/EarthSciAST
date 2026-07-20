//! End-to-end coverage for esm-spec §7.4 reservoir (`constant: true`) species
//! in a reaction system: the reservoir is held fixed (a parameter, no ODE)
//! while still contributing as a mass-action concentration factor.
//!
//! Loads the shared cross-binding conformance fixture
//! `tests/simulation/reservoir_reactant_held_fixed.esm` and checks BOTH the
//! state/parameter split AND the analytic A/B trajectory it implies.
//!
//! The generic `tests_blocks_execution.rs` runner walks `tests/simulation/`
//! but only executes `models` inline `tests` blocks — the Rust `ReactionSystem`
//! type carries no `tests` field yet, so a `reaction_systems` fixture's inline
//! assertions are silently skipped there. This dedicated test provides the
//! numerical coverage for the reservoir fix in the Rust binding.
//!
//! Gated off wasm32 because the simulate module is native-only.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Compiled, SimulateOptions, SolverChoice, load_path};
use std::collections::HashMap;

mod common;

#[test]
fn reservoir_reactant_held_fixed() {
    let path = common::repo_fixture("simulation/reservoir_reactant_held_fixed.esm");
    let file = load_path(&path).unwrap_or_else(|e| panic!("fixture {} does not load: {e}", path.display()));

    let compiled = Compiled::from_file(&file).expect("compile failed");

    // R (`constant: true`) is a reservoir: it must be a PARAMETER, not a state,
    // and only A and B are integrated.
    let states = compiled.state_variable_names();
    let params = compiled.parameter_names();
    assert!(
        !states.iter().any(|n| n == "ReservoirHeldFixed.R"),
        "reservoir R must NOT be a state variable; states = {states:?}"
    );
    assert!(
        params.iter().any(|n| n == "ReservoirHeldFixed.R"),
        "reservoir R must be a parameter; params = {params:?}"
    );
    assert!(states.iter().any(|n| n == "ReservoirHeldFixed.A"));
    assert!(states.iter().any(|n| n == "ReservoirHeldFixed.B"));
    assert_eq!(states.len(), 2, "only A and B are states; got {states:?}");

    // With R held at its default (2.0) and k = 0.5, the effective rate law is
    // v = k*R*A = A, so A(t) = exp(-t) and B(t) = 1 - exp(-t) exactly, and R
    // never moves. A binding that consumed R as a state would give a strictly
    // slower A decay (e.g. A(1) ~= 0.4353 vs 0.3679) and miss these.
    let mut par = HashMap::new();
    par.insert("ReservoirHeldFixed.k".to_string(), 0.5);
    let mut ic = HashMap::new();
    ic.insert("ReservoirHeldFixed.A".to_string(), 1.0);
    ic.insert("ReservoirHeldFixed.B".to_string(), 0.0);

    let sample_times = vec![1.0, 2.0, 3.0];
    let opts = SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-14,
        reltol: 1e-10,
        max_steps: 1_000_000,
        output_times: Some(sample_times.clone()),
    };
    let sol = compiled
        .simulate((0.0, 3.0), &par, &ic, &opts)
        .expect("simulate failed");

    let a_idx = sol
        .state_variable_names
        .iter()
        .position(|n| n == "ReservoirHeldFixed.A")
        .expect("A in solution");
    let b_idx = sol
        .state_variable_names
        .iter()
        .position(|n| n == "ReservoirHeldFixed.B")
        .expect("B in solution");

    for &t in &sample_times {
        let (i, _) = sol
            .time
            .iter()
            .enumerate()
            .min_by(|(_, ta), (_, tb)| {
                (**ta - t)
                    .abs()
                    .partial_cmp(&(**tb - t).abs())
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .expect("non-empty time grid");
        assert!(
            (sol.time[i] - t).abs() < 1e-9,
            "no output sample at t={t}"
        );
        let expected_a = (-t).exp();
        let expected_b = 1.0 - expected_a;
        let a = sol.state[a_idx][i];
        let b = sol.state[b_idx][i];
        assert!(
            (a - expected_a).abs() < 1e-6,
            "A(t={t}) = {a}, expected {expected_a} (reservoir R must be held fixed)"
        );
        assert!(
            (b - expected_b).abs() < 1e-6,
            "B(t={t}) = {b}, expected {expected_b} (reservoir R must be held fixed)"
        );
    }
}
