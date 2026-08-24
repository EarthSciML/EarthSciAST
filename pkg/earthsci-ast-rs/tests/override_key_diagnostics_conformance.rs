//! Cross-language conformance: unrecognized `parameter_overrides` keys raise
//! (esm-spec §6.6.2 "Unrecognized override keys").
//!
//! Shared fixture + manifest live under
//! `tests/conformance/override_key_diagnostics/` (repo root); the Julia runner
//! (`conformance_override_key_diagnostics_test.jl`) and the Python runner
//! (`test_override_key_diagnostics_conformance.py`) drive the same cases.
//!
//! The category carries no numeric golden — it compares DIAGNOSTIC OUTCOMES.
//! Each binding raises its own idiomatic error type (the manifest's
//! `error_surface` records which); what must agree across the three is the
//! *classification* of each key: resolved, ambiguous, or unknown.
//!
//! Rust is the reference here: it already raised `InvalidParameter` for an
//! unknown key while Julia and Python ignored it silently. What Rust gained is
//! the AMBIGUOUS case as a distinct diagnostic — before the §6.6.2
//! canonicalization it had no local-name resolution at all, so a bare `gain`
//! was simply "invalid" and a bare `solo` was rejected too, even though §6.6
//! mandates exactly that spelling.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::simulate::SimulateError;
use earthsci_ast::{SimulateOptions, SolverChoice, load_string, simulate};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

mod common;

fn category_dir() -> PathBuf {
    common::repo_fixture("conformance/override_key_diagnostics")
}

fn read_json(path: &PathBuf) -> serde_json::Value {
    let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

fn opts() -> SimulateOptions {
    SimulateOptions {
        solver: SolverChoice::Erk,
        reltol: 1e-12,
        abstol: 1e-14,
        output_times: Some(vec![1.0]),
        ..Default::default()
    }
}

#[test]
fn override_key_outcomes_match_the_manifest() {
    let dir = category_dir();
    let manifest = read_json(&dir.join("manifest.json"));
    assert_eq!(
        manifest["category"].as_str(),
        Some("override_key_diagnostics")
    );
    let required: Vec<&str> = manifest["bindings_required"]
        .as_array()
        .expect("bindings_required")
        .iter()
        .map(|v| v.as_str().expect("binding name"))
        .collect();
    for b in ["julia", "python", "rust"] {
        assert!(required.contains(&b), "manifest must require {b}");
    }

    let fx = &manifest["fixtures"][0];
    let esm_path = dir.join(fx["path"].as_str().expect("path"));
    let text = fs::read_to_string(&esm_path).unwrap_or_else(|e| panic!("read {esm_path:?}: {e}"));
    let file = load_string(&text).unwrap_or_else(|e| panic!("fixture {esm_path:?} does not load: {e}"));

    let rtol = manifest["tolerances"]["trajectory_rtol"]
        .as_f64()
        .expect("rtol");
    let atol = manifest["tolerances"]["trajectory_atol"]
        .as_f64()
        .expect("atol");
    let close = |got: f64, want: f64| (got - want).abs() <= atol.max(rtol * want.abs());

    let at_t1 = |sol: &earthsci_ast::Solution, name: &str| -> f64 {
        let i = sol
            .state_variable_names
            .iter()
            .position(|n| n == name)
            .unwrap_or_else(|| panic!("no state {name} in {:?}", sol.state_variable_names));
        *sol.state[i].last().expect("a sample at t=1")
    };

    // All three outcomes must be exercised, or the category proves nothing
    // about ambiguous-vs-unknown being distinct.
    let cases = fx["cases"].as_array().expect("cases");
    let outcomes: std::collections::HashSet<&str> = cases
        .iter()
        .map(|c| c["outcome"].as_str().expect("outcome"))
        .collect();
    for want in ["resolved", "ambiguous", "unknown"] {
        assert!(outcomes.contains(want), "no {want} case in the manifest");
    }

    // Non-vacuity: the fixture integrates on its own, so every rejection below
    // is about the KEY and not about the document.
    let base = simulate(&file, (0.0, 1.0), &HashMap::new(), &HashMap::new(), &opts())
        .expect("defaults simulate");
    for (name, want) in fx["defaults_at_t1"].as_object().expect("defaults_at_t1") {
        let want = want.as_f64().expect("default value");
        assert!(close(at_t1(&base, name), want), "defaults: {name}");
    }

    for case in cases {
        let key = case["key"].as_str().expect("key");
        let value = case["value"].as_f64().expect("value");
        let outcome = case["outcome"].as_str().expect("outcome");
        let params = HashMap::from([(key.to_string(), value)]);
        let got = simulate(&file, (0.0, 1.0), &params, &HashMap::new(), &opts());

        match outcome {
            "resolved" => {
                let sol = got.unwrap_or_else(|e| panic!("{key}: expected a run, got {e}"));
                for (name, want) in case["trajectory_at_t1"]
                    .as_object()
                    .unwrap_or_else(|| panic!("{key}: manifest case has no trajectory_at_t1"))
                {
                    let want = want.as_f64().expect("expected value");
                    assert!(close(at_t1(&sol, name), want), "{key}: {name}");
                }
            }
            "ambiguous" => match got {
                Err(SimulateError::AmbiguousParameter { name, candidates }) => {
                    assert_eq!(name, key);
                    let want: Vec<String> = case["candidates"]
                        .as_array()
                        .expect("candidates")
                        .iter()
                        .map(|v| v.as_str().expect("candidate").to_string())
                        .collect();
                    // The diagnostic must carry EVERY candidate, or it does not
                    // tell the author how to qualify the name.
                    assert_eq!(candidates, want, "{key}");
                }
                other => panic!("{key}: expected AmbiguousParameter, got {other:?}"),
            },
            "unknown" => match got {
                // UNKNOWN must not be reported as the ambiguous case.
                Err(SimulateError::InvalidParameter { name }) => assert_eq!(name, key),
                other => panic!("{key}: expected InvalidParameter, got {other:?}"),
            },
            other => panic!("unhandled outcome {other:?}"),
        }
    }
}
