//! `reaction_systems[].tests` reach the inline-test runner (issue #206 item 1).
//!
//! esm-spec §7.2 gives a reaction system a `tests` field whose "semantics,
//! field shape, and tolerance resolution are identical to Section 6.6", and
//! the shared corpus ships documents whose ONLY tests are on a mechanism
//! (`tests/simulation/autocatalytic_reaction.esm`, and EarthSciModels'
//! `superfast.esm`). [`run_pde_tests`] — the runner behind `esm test` —
//! enumerated `file.models` alone, so such a document produced zero assertion
//! rows and the CLI printed "(no inline tests found)": a whole mechanism's
//! test suite silently unexecuted.
//!
//! Sabotage check: drop the `reaction_systems` arm from
//! `test_bearing_components` in `src/pde_inline_tests.rs` and every test here
//! fails with an empty result vector.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{PdeAssertionResult, SolveOptions, load_string, run_pde_tests};
use serde_json::json;

mod common;

fn opts() -> SolveOptions {
    SolveOptions {
        reltol: Some(1e-10),
        abstol: Some(1e-12),
        ..Default::default()
    }
}

fn run(doc: serde_json::Value) -> Vec<PdeAssertionResult> {
    let file = load_string(&doc.to_string()).expect("document loads");
    run_pde_tests(&file, None, &opts())
}

/// A first-order decay mechanism `A -> B` at rate `k`, with the whole test
/// suite on the reaction system and no model in the document at all.
fn decay_mechanism(tests: serde_json::Value) -> serde_json::Value {
    json!({
        "esm": "1.0.0",
        "metadata": {
            "name": "RsOnly",
            "description": "A document whose only inline tests live on a reaction system.",
            "authors": ["issue-206"],
            "created": "2026-09-07T00:00:00Z"
        },
        "reaction_systems": {
            "Chem": {
                "species": {
                    "A": {"units": "mol/mol", "default": 4.0},
                    "B": {"units": "mol/mol", "default": 0.0}
                },
                "parameters": {"k": {"units": "1/s", "default": 0.5}},
                "reactions": [{
                    "id": "R1",
                    "substrates": [{"species": "A", "stoichiometry": 1}],
                    "products": [{"species": "B", "stoichiometry": 1}],
                    "rate": "k"
                }],
                "tests": tests
            }
        },
        "domain": {"temporal": {}}
    })
}

#[test]
fn reaction_system_tests_are_discovered_and_run() {
    let results = run(decay_mechanism(json!([{
        "id": "initial_state",
        "time_span": {"start": 0.0, "end": 1.0},
        "assertions": [
            {"variable": "A", "time": 0.0, "expected": 4.0, "tolerance": {"abs": 1e-12}},
            {"variable": "B", "time": 0.0, "expected": 0.0, "tolerance": {"abs": 1e-12}}
        ]
    }])));

    assert_eq!(
        results.len(),
        2,
        "a reaction system's tests must produce one row per assertion, got {results:?}"
    );
    for r in &results {
        assert_eq!(r.model, "Chem", "rows are attributed to the owning system");
        assert_eq!(r.test_id, "initial_state");
        assert!(r.passed, "{r:?}");
    }
}

/// The species really are integrated — not merely read back at their defaults.
/// `A(t) = A0 · exp(-k t)`, so `A(2) = 4 · exp(-1)`.
#[test]
fn reaction_system_tests_assert_integrated_species() {
    let results = run(decay_mechanism(json!([{
        "id": "decays",
        "time_span": {"start": 0.0, "end": 2.0},
        "tolerance": {"rel": 1e-6},
        "assertions": [
            {"variable": "A", "time": 2.0, "expected": 4.0 * std::f64::consts::E.powf(-1.0)}
        ]
    }])));
    assert_eq!(results.len(), 1);
    assert!(results[0].passed, "{:?}", results[0]);
}

/// A failing assertion on a reaction system reports a real `actual`, so the
/// verdict is the mechanism's answer rather than a row that never ran.
#[test]
fn reaction_system_assertion_failure_carries_the_actual() {
    let results = run(decay_mechanism(json!([{
        "id": "wrong_expectation",
        "time_span": {"start": 0.0, "end": 1.0},
        "assertions": [
            {"variable": "A", "time": 0.0, "expected": 99.0, "tolerance": {"abs": 1e-12}}
        ]
    }])));
    assert_eq!(results.len(), 1);
    assert!(!results[0].passed);
    assert_eq!(results[0].actual, Some(4.0), "{:?}", results[0]);
}

/// esm-spec §7.2 / §6.6.4: a reaction system's own `tolerance` is the
/// component level of the precedence chain, exactly as a model's is.
#[test]
fn reaction_system_tolerance_is_the_component_level() {
    let mut doc = decay_mechanism(json!([{
        "id": "loose",
        "time_span": {"start": 0.0, "end": 1.0},
        "assertions": [{"variable": "A", "time": 0.0, "expected": 4.0}]
    }]));
    doc["reaction_systems"]["Chem"]["tolerance"] = json!({"rel": 1e-3, "abs": 1e-4});
    let results = run(doc);
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].rtol, 1e-3, "{:?}", results[0]);
    assert_eq!(results[0].atol, 1e-4, "{:?}", results[0]);
}

/// Both component kinds are enumerated, models first, each sorted by name.
#[test]
fn models_and_reaction_systems_both_run_models_first() {
    let doc = json!({
        "esm": "1.0.0",
        "metadata": {
            "name": "BothKinds", "description": "d", "authors": ["issue-206"],
            "created": "2026-09-07T00:00:00Z"
        },
        "reaction_systems": {
            "Chem": {
                "species": {"A": {"units": "mol/mol", "default": 4.0}},
                "parameters": {"k": {"units": "1/s", "default": 0.5}},
                "reactions": [{
                    "id": "R1",
                    "substrates": [{"species": "A", "stoichiometry": 1}],
                    "products": null,
                    "rate": "k"
                }],
                "tests": [{
                    "id": "rs_test",
                    "time_span": {"start": 0.0, "end": 1.0},
                    "assertions": [
                        {"variable": "A", "time": 0.0, "expected": 4.0, "tolerance": {"abs": 1e-12}}
                    ]
                }]
            }
        },
        "models": {
            "Mdl": {
                "variables": {
                    "y": {"type": "unknown", "units": "dimensionless", "default": 7.0},
                    "c": {"type": "parameter", "units": "1/s", "default": 0.0}
                },
                "equations": [
                    {"lhs": {"op": "D", "args": ["y"], "wrt": "t"},
                     "rhs": {"op": "*", "args": ["c", "y"]}}
                ],
                "tests": [{
                    "id": "model_test",
                    "time_span": {"start": 0.0, "end": 1.0},
                    "assertions": [
                        {"variable": "y", "time": 0.0, "expected": 7.0, "tolerance": {"abs": 1e-12}}
                    ]
                }]
            }
        },
        "domain": {"temporal": {}}
    });
    let results = run(doc);
    let order: Vec<&str> = results.iter().map(|r| r.model.as_str()).collect();
    assert_eq!(
        order,
        vec!["Mdl", "Chem"],
        "models first, then reaction systems"
    );
    assert!(results.iter().all(|r| r.passed), "{results:?}");
}

/// The `--model` selector names a COMPONENT, of either kind.
#[test]
fn component_selector_reaches_a_reaction_system() {
    let file = load_string(
        &decay_mechanism(json!([{
            "id": "initial_state",
            "time_span": {"start": 0.0, "end": 1.0},
            "assertions": [
                {"variable": "A", "time": 0.0, "expected": 4.0, "tolerance": {"abs": 1e-12}}
            ]
        }]))
        .to_string(),
    )
    .expect("document loads");

    assert_eq!(run_pde_tests(&file, Some("Chem"), &opts()).len(), 1);
    assert!(run_pde_tests(&file, Some("NotAComponent"), &opts()).is_empty());
}

/// The shipped corpus fixture the issue names: its whole test suite is on a
/// reaction system, and it produced no rows at all before this change.
#[test]
fn shipped_reaction_system_fixture_produces_rows() {
    let file = common::load_repo_fixture("simulation/autocatalytic_reaction.esm");
    let results = run_pde_tests(&file, None, &opts());
    assert_eq!(
        results.len(),
        3,
        "tests/simulation/autocatalytic_reaction.esm declares 3 assertions on \
         reaction_systems.ChemicalSystem, got {results:?}"
    );
    assert!(results.iter().all(|r| r.passed), "{results:?}");
}
