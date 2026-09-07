//! Cross-language conformance: a SHAPED variable's INLINE ARRAY DATA reaches
//! the run (esm-spec §6.6.2 "Shaped values", §6.3, §11.4
//! state-free-array-observed `ic`).
//!
//! Shared fixtures + Julia-minted goldens live under
//! `tests/conformance/pde_inline_array_overrides/` (repo root); the Julia
//! runner (`conformance_pde_inline_array_overrides_test.jl`) and the Python
//! runner (`test_pde_inline_array_overrides_conformance.py`) gate the same
//! goldens.
//!
//! Before this, a shaped variable's `default` and a test's
//! `parameter_overrides` / `initial_conditions` values were `number`-only in
//! `esm-schema.json`, and an `ic` whose RHS names a state-free array observed
//! was rejected at build. A §6.6 inline test therefore could not supply a
//! SHAPED input at all — which is exactly what a column-physics test replaying
//! a Fortran kernel dump needs, its inputs being columns (θ, q_v, u, v, p, dz,
//! K profiles). Each fixture here is ONE shared component whose regimes are
//! ordinary tests of the same document.
//!
//! The Rust array runtime lowers a shaped parameter's inline column into the
//! `const` observed channel (`simulate_array::lower_inline_array_parameters`),
//! expands an array-valued `initial_conditions` entry into the per-cell `u0`
//! keys (`inline_tests::expand_array_initial_conditions`), and materializes
//! the state-free observeds an `ic` reads (`ArrayCompiled::ic_scope_defs`).
//! This suite pins all three against the reference binding.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::run_inline_tests_with_base_dir;
use earthsci_ast::{Alg, SolveOptions, load_string};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

mod common;

fn category_dir() -> PathBuf {
    common::repo_fixture("conformance/pde_inline_array_overrides")
}

fn read_json(path: &PathBuf) -> serde_json::Value {
    let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

fn manifest_opts(manifest: &serde_json::Value) -> SolveOptions {
    let rs = &manifest["integrators"]["rust"];
    assert_eq!(rs["solver"].as_str(), Some("Erk"));
    SolveOptions {
        alg: Alg::Erk,
        reltol: rs["reltol"].as_f64().expect("reltol"),
        abstol: rs["abstol"].as_f64().expect("abstol"),
        ..Default::default()
    }
}

#[test]
fn array_overrides_match_golden() {
    let dir = category_dir();
    let manifest = read_json(&dir.join("manifest.json"));
    assert_eq!(
        manifest["category"].as_str(),
        Some("pde_inline_array_overrides")
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
        let file = load_string(&text)
            .unwrap_or_else(|e| panic!("fixture {esm_path:?} does not load: {e}"));
        let results =
            run_inline_tests_with_base_dir(&file, fx["model"].as_str(), &opts, Some(dir.as_path()));

        let expected = golden["assertions"].as_array().expect("golden assertions");
        assert_eq!(results.len(), expected.len());

        // Keyed by (test_id, assertion_idx): each fixture carries several tests
        // of ONE model, distinguished only by their inline array data.
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

/// The nesting order of §6.6.2, pinned directly rather than through the runner:
/// axis 1 of `shape` is the OUTER JSON array, so `data[i][j]` is the element at
/// `(i, j)`. The fixture's 2x3 slab has unequal extents and pairwise-distinct
/// values, so a column-major read disagrees on every off-diagonal cell instead
/// of coincidentally agreeing.
#[test]
fn rank2_inline_array_is_read_row_major() {
    let dir = category_dir();
    let path = dir.join("fixtures/slab_array_overrides_rank2.esm");
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    let file = load_string(&text).expect("fixture loads");

    let declared = file.models.as_ref().expect("models")["Slab"].variables["kprof"]
        .default
        .as_ref()
        .expect("kprof carries a default");
    let (shape, values) = declared.to_dense().expect("dense inline array");
    assert_eq!(shape, vec![2, 3]);

    let opts = SolveOptions {
        alg: Alg::Erk,
        reltol: 1e-12,
        abstol: 1e-14,
        saveat: Some(vec![0.0]),
        ..Default::default()
    };
    let sol = earthsci_ast::esm_problem(
        &file,
        (0.0, 1.0),
        earthsci_ast::ProblemOptions {
            compile: earthsci_ast::Compile::Always,
            ..Default::default()
        },
    )
    .and_then(|prob| earthsci_ast::solve(&prob, &opts))
    .unwrap_or_else(|e| panic!("simulate failed: {e}"));

    // `state_cells` returns (1-based multi-index, row) pairs whether the single-
    // model path kept the bare name or the flattened one qualified it.
    let row_of: HashMap<Vec<i64>, usize> =
        earthsci_ast::state_cells(&sol.state_variable_names, "a", "Slab")
            .into_iter()
            .collect();
    assert_eq!(row_of.len(), 6, "the 2x3 slab must enumerate six cells");
    for i in 0..2usize {
        for j in 0..3usize {
            let cell = vec![i as i64 + 1, j as i64 + 1];
            let row = row_of
                .get(&cell)
                .unwrap_or_else(|| panic!("no state cell a{cell:?}"));
            assert_eq!(
                sol.state[*row][0],
                values[i * 3 + j],
                "cell a{cell:?} read out of row-major order"
            );
        }
    }
}

/// esm-spec §6.6.2: the array MUST match the declared shape after metaparameter
/// folding, and a mismatch is a load-time error — never a silently truncated or
/// broadcast column.
#[test]
fn inline_array_shape_mismatch_is_a_build_error() {
    let dir = category_dir();
    let path = dir.join("fixtures/column_array_overrides.esm");
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    let mut file = load_string(&text).expect("fixture loads");
    file.models.as_mut().expect("models")["Column"]
        .variables
        .get_mut("theta0")
        .expect("theta0")
        .default = Some(earthsci_ast::InlineValue::Array(vec![
        earthsci_ast::InlineValue::Scalar(1.0),
        earthsci_ast::InlineValue::Scalar(2.0),
    ]));

    let err = earthsci_ast::esm_problem(
        &file,
        (0.0, 1.0),
        earthsci_ast::ProblemOptions {
            compile: earthsci_ast::Compile::Always,
            ..Default::default()
        },
    )
    .expect_err("a 2-element column for a lev=4 parameter must be rejected");
    let msg = err.to_string();
    assert!(
        msg.contains("does not match the declared shape"),
        "diagnostic must name the shape mismatch, got: {msg}"
    );
}
