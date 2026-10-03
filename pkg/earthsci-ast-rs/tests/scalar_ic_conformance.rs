//! Cross-language conformance: 0-D (`scalar`) `ic` equations seed their state
//! (esm-spec §11.4 "Initial conditions (the `ic` op)", its "Run-time
//! overrides", §6.6.5 "Build-time evaluation scope").
//!
//! Shared fixtures + Julia-minted goldens live under
//! `tests/conformance/scalar_ic/` (repo root); the Julia runner
//! (`conformance_scalar_ic_test.jl`) and the Python runner
//! (`test_scalar_ic_conformance.py`) gate the same goldens.
//!
//! A binding that drops a 0-D `ic` does not error: the state silently starts
//! at its declared `default`. Every state in `scalar_ic.esm` declares a
//! `default` that DIFFERS from its `ic` so that substitution cannot hide, and
//! `y` integrates `D(y)/dt = u` so the seeded value must reach the trajectory
//! too. `scalar_ic_in_array_model.esm` re-runs the contract inside the array
//! runtime.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::run_inline_tests_with_base_dir;
use earthsci_ast::{Alg, SolveOptions, load_string};
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

fn manifest_opts(manifest: &serde_json::Value) -> SolveOptions {
    let rs = &manifest["integrators"]["rust"];
    assert_eq!(rs["solver"].as_str(), Some("Erk"));
    SolveOptions {
        alg: Alg::Erk,
        reltol: Some(rs["reltol"].as_f64().expect("reltol")),
        abstol: Some(rs["abstol"].as_f64().expect("abstol")),
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
            run_inline_tests_with_base_dir(&file, fx["model"].as_str(), &opts, Some(dir.as_path()));

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
    let opts = SolveOptions {
        alg: Alg::Erk,
        reltol: Some(1e-12),
        abstol: Some(1e-14),
        saveat: Some(vec![0.0]),
        ..Default::default()
    };

    let at0 = |sol: &earthsci_ast::Solution, name: &str| -> f64 {
        // See `Solution::index_of`: either spelling resolves.
        let i = sol
            .index_of(name)
            .unwrap_or_else(|| panic!("no state {name} in {:?}", sol.state_variable_names));
        sol.state[i][0]
    };

    // (1) Defaults: each state takes its own ic; `z` declares none and takes 7.
    let sol = earthsci_ast::esm_problem(
        &file,
        (0.0, 1.0),
        earthsci_ast::ProblemOptions {
            p: HashMap::new().clone(),
            u0: HashMap::new().clone(),
            rhs: earthsci_ast::Rhs::Always,
            ..Default::default()
        },
    )
    .and_then(|prob| earthsci_ast::solve(&prob, &opts))
    .expect("defaults simulate");
    assert_eq!(at0(&sol, "M.u"), 3.0);
    assert_eq!(at0(&sol, "M.q"), 2.0);
    assert_eq!(at0(&sol, "M.w"), 4.0);
    assert_eq!(at0(&sol, "M.z"), 7.0);

    // (2) A parameter override reaches the ic's build-time scope, under either
    // spelling of the key (§6.6.2).
    for key in ["A", "M.A"] {
        let params = HashMap::from([(key.to_string(), 10.0)]);
        let sol = earthsci_ast::esm_problem(
            &file,
            (0.0, 1.0),
            earthsci_ast::ProblemOptions {
                p: params.clone(),
                u0: HashMap::new().clone(),
                rhs: earthsci_ast::Rhs::Always,
                ..Default::default()
            },
        )
        .and_then(|prob| earthsci_ast::solve(&prob, &opts))
        .unwrap_or_else(|e| panic!("{key}: simulate failed: {e}"));
        assert_eq!(at0(&sol, "M.w"), 20.0, "{key}");
        assert_eq!(at0(&sol, "M.u"), 3.0, "{key}: parameter-free ic moved");
    }

    // (3) A run-time `initial_conditions` entry beats the ic equation.
    for key in ["u", "M.u"] {
        let ics = HashMap::from([(key.to_string(), 9.0)]);
        let sol = earthsci_ast::esm_problem(
            &file,
            (0.0, 1.0),
            earthsci_ast::ProblemOptions {
                p: HashMap::new().clone(),
                u0: ics.clone(),
                rhs: earthsci_ast::Rhs::Always,
                ..Default::default()
            },
        )
        .and_then(|prob| earthsci_ast::solve(&prob, &opts))
        .unwrap_or_else(|e| panic!("{key}: simulate failed: {e}"));
        assert_eq!(at0(&sol, "M.u"), 9.0, "{key}");
        assert_eq!(at0(&sol, "M.w"), 4.0, "{key}: unnamed state lost its ic");
    }
}

/// esm-spec §6.2: `faq`-valued initialization equations seed the initial state
/// in document order, a body reading a state reads the value seeded so far
/// (the declared default, a caller override, an earlier equation's result),
/// and a cell the caller names keeps the caller's value. Both compilers build
/// the same `u0`, bit for bit; the interpreter walks each `faq` cell by cell
/// and `native` evaluates it whole.
#[test]
fn faq_initialization_equations_seed_in_order_on_both_compilers() {
    use earthsci_ast::{Compiler, ProblemOptions, Rhs, esm_problem, solve};
    let faq = |ranges: serde_json::Value, expr: serde_json::Value| {
        serde_json::json!({"op": "faq", "args": [], "output_idx": ["i"],
                           "ranges": ranges, "expr": expr})
    };
    let idx = |v: &str| serde_json::json!({"op": "index", "args": [v, "i"]});
    let d = |v: &str| serde_json::json!({"op": "D", "wrt": "t", "args": [idx(v)]});
    let all = serde_json::json!({"i": [1, 4]});
    let doc = serde_json::json!({
        "esm": "1.1.0",
        "metadata": {"name": "faq_init_order"},
        "index_sets": {"x": {"kind": "interval", "size": 4}},
        "models": {"M": {
            "variables": {
                "A": {"type": "parameter", "units": "1", "default": 0.25},
                "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0},
                "v": {"type": "unknown", "units": "1", "shape": ["x"], "default": 2.0}
            },
            "equations": [
                {"lhs": faq(all.clone(), d("u")), "rhs": faq(all.clone(), serde_json::json!(0))},
                {"lhs": faq(all.clone(), d("v")), "rhs": faq(all.clone(), serde_json::json!(0))}
            ],
            "initialization_equations": [
                // u = A*i + v, reading v's default (or the caller's value).
                {"lhs": "u", "rhs": faq(all.clone(), serde_json::json!(
                    {"op": "+", "args": [{"op": "*", "args": ["A", "i"]}, idx("v")]}))},
                // v = 3*u over cells 2..3, reading the u just seeded.
                {"lhs": "v", "rhs": faq(serde_json::json!({"i": [2, 3]}), serde_json::json!(
                    {"op": "*", "args": [3.0, idx("u")]}))}
            ]
        }}
    });
    let file = load_string(&doc.to_string()).expect("document loads");
    let u0_of = |compiler: Compiler, u0: &[(&str, f64)]| -> Vec<(String, u64)> {
        let prob = esm_problem(
            &file,
            (0.0, 1.0),
            ProblemOptions {
                rhs: Rhs::Always,
                compiler: Some(compiler),
                u0: u0.iter().map(|&(k, v)| (k.to_string(), v)).collect(),
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("{compiler:?} builds: {e}"));
        let sol = solve(
            &prob,
            &SolveOptions {
                saveat: Some(vec![0.0]),
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("{compiler:?} solves: {e}"));
        sol.state_variable_names
            .iter()
            .zip(&sol.state)
            .map(|(n, row)| (n.clone(), row[0].to_bits()))
            .collect()
    };
    let value = |rows: &[(String, u64)], name: &str| -> f64 {
        let (_, b) = rows
            .iter()
            .find(|(n, _)| n == name || n.ends_with(&format!(".{name}")))
            .unwrap_or_else(|| panic!("no state {name}: {rows:?}"));
        f64::from_bits(*b)
    };
    for u0 in [&[][..], &[("v[1]", 10.0), ("u[3]", -1.0)][..]] {
        let native = u0_of(Compiler::Native, u0);
        let interp = u0_of(Compiler::Interpreter, u0);
        assert_eq!(
            native, interp,
            "native and the interpreter seed the same u0 ({u0:?})"
        );
        let v1 = if u0.is_empty() { 2.0 } else { 10.0 };
        let u3 = if u0.is_empty() { 0.75 + 2.0 } else { -1.0 };
        assert_eq!(value(&native, "u[1]"), 0.25 + v1);
        assert_eq!(value(&native, "u[2]"), 0.5 + 2.0);
        assert_eq!(value(&native, "u[3]"), u3);
        assert_eq!(value(&native, "v[1]"), v1, "outside v's ranges");
        assert_eq!(value(&native, "v[2]"), 3.0 * 2.5, "reads the seeded u");
        assert_eq!(value(&native, "v[3]"), 3.0 * u3);
        assert_eq!(value(&native, "v[4]"), 2.0, "outside v's ranges");
    }
}
