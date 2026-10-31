//! Cross-language conformance: the public initial-state accessor
//! (API_SPEC §5.8 `initial_state`, CONFORMANCE_SPEC §5.53).
//!
//! The shared manifest `tests/conformance/initial_state/manifest.json` (repo
//! root) lists a document, the Problem's `p` and `u0`, and the initial state
//! expected for every state element, keyed by flattened name. Each case is
//! also checked against the state a solve starts from (a solve over a
//! zero-length span, the route callers had before the accessor), bit for bit.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{
    ProblemInput, ProblemOptions, SimulateError, SolveOptions, esm_problem, initial_state,
    load_string, solve,
};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

mod common;

fn category_dir() -> PathBuf {
    common::repo_fixture("conformance/initial_state")
}

fn read_json(path: &Path) -> serde_json::Value {
    let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

fn numbers(v: &serde_json::Value) -> HashMap<String, f64> {
    v.as_object()
        .expect("an object of numbers")
        .iter()
        .map(|(k, x)| (k.clone(), x.as_f64().expect("a number")))
        .collect()
}

fn problem(case: &serde_json::Value, tspan: (f64, f64)) -> earthsci_ast::EsmProblem {
    let path = common::repo_fixture("conformance").join(case["fixture"].as_str().unwrap());
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    let file = load_string(&text).unwrap_or_else(|e| panic!("{path:?} does not load: {e}"));
    esm_problem(
        ProblemInput::File(&file),
        tspan,
        ProblemOptions {
            p: numbers(&case["p"]),
            u0: numbers(&case["u0"]),
            base_path: path.parent().map(Path::to_path_buf),
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("{}: the Problem builds: {e}", case["id"]))
}

#[test]
fn initial_state_matches_the_manifest() {
    let manifest = read_json(&category_dir().join("manifest.json"));
    assert_eq!(manifest["category"].as_str(), Some("initial_state"));
    let required: Vec<&str> = manifest["bindings_required"]
        .as_array()
        .expect("bindings_required")
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert!(required.contains(&"rust"));
    let rtol = manifest["tolerances"]["rtol"].as_f64().unwrap();
    let atol = manifest["tolerances"]["atol"].as_f64().unwrap();
    let cases = manifest["cases"].as_array().expect("cases");
    assert!(cases.len() >= 10, "the manifest must not go vacuous");

    for case in cases {
        let id = case["id"].as_str().unwrap();
        let prob = problem(case, (0.0, 1.0));
        let u0 = initial_state(&prob).unwrap_or_else(|e| panic!("{id}: {e}"));
        let names = prob.state_variable_names();
        assert_eq!(u0.len(), names.len(), "{id}: one value per state element");

        let expected = numbers(&case["expected"]);
        let mut got: HashMap<String, f64> = HashMap::new();
        for (n, v) in names.iter().zip(&u0) {
            got.insert(n.clone(), *v);
        }
        let mut want_names: Vec<&String> = expected.keys().collect();
        let mut got_names: Vec<&String> = got.keys().collect();
        want_names.sort();
        got_names.sort();
        assert_eq!(got_names, want_names, "{id}: the state elements");
        for (n, want) in &expected {
            let v = got[n];
            assert!(
                (v - want).abs() <= atol + rtol * want.abs(),
                "{id}: {n} = {v}, expected {want}"
            );
        }

        // The state a solve starts from: a zero-length span answers from the
        // initial state without integrating.
        let zero = problem(case, (0.0, 0.0));
        let sol = solve(
            &zero,
            &SolveOptions {
                saveat: Some(vec![0.0]),
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("{id}: the zero-length solve: {e}"));
        assert_eq!(&sol.state_variable_names[..names.len()], names, "{id}");
        for (k, n) in names.iter().enumerate() {
            assert_eq!(
                sol.state[k][0].to_bits(),
                u0[k].to_bits(),
                "{id}: {n}: the accessor and the solve's initial state differ"
            );
        }
    }
}

/// Repeated calls agree, with each other and with the solve after them.
/// That the accessor leaves construction's resolved field initial conditions
/// for that solve is counted in-crate (`field_ic_memo_tests`).
#[test]
fn accessor_then_solve_agree() {
    let manifest = read_json(&category_dir().join("manifest.json"));
    let case = manifest["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == "coordinate_ic_parameter")
        .expect("the coordinate-ic case");
    let prob = problem(case, (0.0, 1.0));
    let first = initial_state(&prob).unwrap();
    let again = initial_state(&prob).unwrap();
    assert_eq!(first, again);
    let sol = solve(
        &prob,
        &SolveOptions {
            saveat: Some(vec![0.0, 1.0]),
            ..Default::default()
        },
    )
    .unwrap();
    for (k, v) in first.iter().enumerate() {
        assert_eq!(sol.state[k][0].to_bits(), v.to_bits());
    }
}

/// A Problem with nothing to integrate has no initial state, as it has no
/// solve.
#[test]
fn a_static_problem_has_none() {
    let file = load_string(
        r#"{"esm": "1.1.0", "metadata": {"name": "Static"},
            "models": {"S": {
                "variables": {
                    "k": {"type": "parameter", "default": 2.0},
                    "y": {"type": "unknown"}},
                "equations": [{"lhs": "y", "rhs": {"op": "*", "args": [2, "k"]}}]}}}"#,
    )
    .unwrap();
    let prob = esm_problem(
        ProblemInput::File(&file),
        (0.0, 1.0),
        ProblemOptions::default(),
    )
    .unwrap();
    assert!(!prob.is_dynamic());
    assert!(matches!(
        initial_state(&prob),
        Err(SimulateError::NotDynamic { .. })
    ));
}

/// A Float32 document that integrates has no solve, so it has no initial
/// state either: the accessor refuses it as `solve` does.
#[test]
fn a_float32_problem_that_integrates_has_none() {
    let file = load_string(
        r#"{"esm": "1.1.0", "metadata": {"name": "Narrow"},
            "domain": {"element_type": "Float32"},
            "models": {"M": {
                "variables": {"u": {"type": "unknown", "units": "1", "default": 1.0}},
                "equations": [{"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                               "rhs": {"op": "-", "args": ["u"]}}]}}}"#,
    )
    .unwrap();
    let prob = esm_problem(
        ProblemInput::File(&file),
        (0.0, 1.0),
        ProblemOptions::default(),
    )
    .unwrap();
    let refused = |e: SimulateError| e.to_string().contains("time integration");
    assert!(solve(&prob, &SolveOptions::default()).is_err_and(refused));
    assert!(initial_state(&prob).is_err_and(refused));
}
