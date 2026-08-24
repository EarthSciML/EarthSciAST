//! Cross-language conformance: a test's `parameter_overrides` reach the
//! BUILD-TIME evaluation scope (esm-spec §6.6.5 "Build-time evaluation scope",
//! §11.4.1 coordinate-expression `ic`, §6.6 "keyed by local parameter name").
//!
//! Shared fixture + Julia-minted golden live under
//! `tests/conformance/pde_inline_ic_param_override/` (repo root); the Julia
//! runner (`conformance_pde_inline_ic_param_override_test.jl`) and the Python
//! runner (`test_pde_inline_ic_param_override_conformance.py`) gate the same
//! golden.
//!
//! Model `M` carries a parameter `A` (default 1.0) that appears ONLY inside
//! `ic(u) = A cos(pi x)` and inside the analytic `reference` of two assertions
//! — never in an equation. So an inline test overriding `A` can change the
//! answer through the build-time scope and through nothing else, which is what
//! makes the three tests (`A` defaulted / overridden to 0 / overridden to 2)
//! discriminate. State `v` is seeded by the parameter-FREE `ic(v) = cos(pi x)`
//! and is the independent anchor the `A`-dependent reference is measured
//! against, so a binding that ignored the override in BOTH the ic and the
//! reference cannot have the two errors cancel and still pass.
//!
//! The Rust array runtime strips the single-model `<namespace>.` prefix from
//! override keys (`Compiled::normalize_override_keys`), so the local spelling
//! already bound here; this suite pins that against the reference binding.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::pde_inline_tests::run_pde_tests_with_base_dir;
use earthsci_ast::{SimulateOptions, SolverChoice, load_string, simulate};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

mod common;

fn category_dir() -> PathBuf {
    common::repo_fixture("conformance/pde_inline_ic_param_override")
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
fn ic_param_override_matches_golden() {
    let dir = category_dir();
    let manifest = read_json(&dir.join("manifest.json"));
    assert_eq!(
        manifest["category"].as_str(),
        Some("pde_inline_ic_param_override")
    );
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
        let file =
            load_string(&text).unwrap_or_else(|e| panic!("fixture {esm_path:?} does not load: {e}"));
        let results =
            run_pde_tests_with_base_dir(&file, fx["model"].as_str(), &opts, Some(dir.as_path()));

        let expected = golden["assertions"].as_array().expect("golden assertions");
        assert_eq!(results.len(), expected.len());

        // Keyed by (test_id, assertion_idx): this category has THREE tests in
        // one model, distinguished only by their `parameter_overrides`.
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

/// Direct coverage of the naming contract the category gates: esm-spec §6.6
/// keys `parameter_overrides` by LOCAL parameter name, while flattening
/// qualifies it (`M.A`). Both spellings must reach the coordinate-expression
/// `ic` seed.
#[test]
fn local_and_qualified_override_keys_both_bind_the_build_scope() {
    let dir = category_dir();
    let path = dir.join("fixtures/ic_param_override.esm");
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    let file = load_string(&text).expect("fixture loads");
    let mut opts = SimulateOptions {
        solver: SolverChoice::Erk,
        reltol: 1e-12,
        abstol: 1e-14,
        ..Default::default()
    };
    opts.output_times = Some(vec![0.0]);

    for key in ["A", "M.A"] {
        let mut params = HashMap::new();
        params.insert(key.to_string(), 0.0);
        let sol = simulate(&file, (0.0, 1.0), &params, &HashMap::new(), &opts)
            .unwrap_or_else(|e| panic!("{key}: simulate failed: {e}"));
        let cells =
            earthsci_ast::pde_inline_tests::state_cells(&sol.state_variable_names, "u", "M");
        assert_eq!(cells.len(), 5);
        for (cell, row) in &cells {
            assert_eq!(sol.state[*row][0], 0.0, "{key}: cell {cell:?} not zeroed");
        }
    }
}
