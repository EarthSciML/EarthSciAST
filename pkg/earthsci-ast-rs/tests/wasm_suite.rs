//! WebAssembly test suite — exercises the wasm-supported surface of the toolkit
//! in a real wasm runtime (Node.js). Run with:
//!
//! ```bash
//! cargo test --target wasm32-unknown-unknown --test wasm_suite
//! ```
//!
//! (requires `wasm-bindgen-test-runner`; see `.cargo/config.toml`). This lives in
//! its own integration-test target on purpose: `cargo test --test wasm_suite`
//! builds only the library plus this file, NOT the native-only unit tests and
//! the other 40-odd integration tests — those read fixtures off disk, use
//! tempfiles, and call the native s2 C++ kernel, none of which compile or run on
//! `wasm32-unknown-unknown`. Fixtures are embedded with `include_str!` since wasm
//! has no filesystem.
#![cfg(target_arch = "wasm32")]

use std::collections::HashMap;
use wasm_bindgen_test::*;

use earthsci_ast::{
    Manifold, SimulateOptions, SolverChoice, component_graph, free_variables, intersect_polygon,
    load, polygon_area, save, shoelace_area, simulate, stoichiometric_matrix, validate,
};

/// Scalar exponential-decay ODE: `dx/dt = k·x`, `k = -1`, `x(0) = 1` ⇒
/// `x(t) = e^{-t}`. Exercises the pure-ODE (diffsol/Faer) path in wasm.
const SCALAR_ODE: &str = r#"{
  "esm": "0.1.0",
  "metadata": { "name": "decay", "description": "scalar exponential decay" },
  "models": {
    "Decay": {
      "variables": {
        "x": { "type": "state", "default": 1.0 },
        "k": { "type": "parameter", "default": -1.0 }
      },
      "equations": [
        { "lhs": { "op": "D", "args": ["x"], "wrt": "t" }, "rhs": { "op": "*", "args": ["k", "x"] } }
      ]
    }
  }
}"#;

/// Discretized 1D heat equation (method-of-lines, 4 cells, Dirichlet BCs) — a
/// geometry-free array PDE. Shared cross-language conformance fixture.
const HEAT_1D: &str = include_str!("../../../tests/fixtures/arrayop/15_discretized_1d_heat.esm");

/// Minimal reaction system `A → B` for the stoichiometry subsystem.
const REACTIONS: &str = r#"{
  "esm": "0.1.0",
  "metadata": { "name": "chem", "description": "minimal A -> B reaction" },
  "reaction_systems": {
    "Chem": {
      "species": { "A": { "default": 1.0 }, "B": { "default": 0.0 } },
      "parameters": {},
      "reactions": [
        {
          "id": "R1",
          "substrates": [{ "species": "A", "stoichiometry": 1 }],
          "products": [{ "species": "B", "stoichiometry": 1 }],
          "rate": { "op": "*", "args": [0.5, "A"] }
        }
      ]
    }
  }
}"#;

// --- parse / validate / serialize -------------------------------------------

#[wasm_bindgen_test]
fn loads_validates_and_roundtrips() {
    let file = load(SCALAR_ODE).expect("load scalar ODE");
    let result = validate(&file);
    assert!(
        result.is_valid,
        "model should validate: schema={:?} structural={:?}",
        result.schema_errors, result.structural_errors
    );

    // save → load round-trips to an equivalent, still-valid document.
    let json = save(&file).expect("save");
    let reloaded = load(&json).expect("reload saved JSON");
    assert!(
        validate(&reloaded).is_valid,
        "round-tripped model must validate"
    );
}

#[wasm_bindgen_test]
fn expression_analysis() {
    let file = load(SCALAR_ODE).expect("load");
    let rhs = &file.models.as_ref().unwrap()["Decay"].equations[0].rhs; // k * x
    let fv = free_variables(rhs);
    assert!(
        fv.contains("k") && fv.contains("x"),
        "free vars of k*x = {fv:?}"
    );
    assert_eq!(fv.len(), 2, "exactly {{k, x}}: {fv:?}");
}

// --- simulation --------------------------------------------------------------

fn find_state<'a>(sol: &'a earthsci_ast::Solution, name: &str) -> &'a [f64] {
    let row = sol
        .state_variable_names
        .iter()
        .position(|n| n == name || n.ends_with(&format!(".{name}")))
        .unwrap_or_else(|| panic!("{name} not in {:?}", sol.state_variable_names));
    &sol.state[row]
}

#[wasm_bindgen_test]
fn scalar_ode_matches_analytic() {
    let file = load(SCALAR_ODE).expect("load");
    let opts = SimulateOptions {
        output_times: Some(vec![1.0]),
        ..SimulateOptions::default()
    };
    let sol = simulate(&file, (0.0, 1.0), &HashMap::new(), &HashMap::new(), &opts)
        .expect("scalar ODE simulate in wasm");
    let x = find_state(&sol, "x");
    let last = *x.last().unwrap();
    let want = (-1.0f64).exp(); // e^{-1}
    assert!((last - want).abs() < 1e-4, "x(1) = {last}, want {want}");
}

#[wasm_bindgen_test]
fn array_pde_heat_matches_analytic() {
    let file = load(HEAT_1D).expect("load 1D heat");
    let ic: HashMap<String, f64> = [
        ("u[1]", 0.5877852522924731),
        ("u[2]", 0.9510565162951535),
        ("u[3]", 0.9510565162951536),
        ("u[4]", 0.5877852522924732),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_string(), v))
    .collect();
    let opts = SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-10,
        reltol: 1e-8,
        max_steps: 100_000,
        output_times: Some(vec![0.1]),
    };
    let sol = simulate(&file, (0.0, 0.1), &HashMap::new(), &ic, &opts)
        .expect("array PDE simulate in wasm");

    // Exact discrete-eigenvalue decay at t=0.1 (fixture assertions).
    for (name, want) in [
        ("u[1]", 0.22620612381309183),
        ("u[2]", 0.36600919679294946),
        ("u[3]", 0.36600919679294946),
        ("u[4]", 0.22620612381309183),
    ] {
        let got = *find_state(&sol, name).last().unwrap();
        assert!((got - want).abs() < 1e-3, "{name}: got {got}, want {want}");
    }
}

// --- geometry ----------------------------------------------------------------

#[wasm_bindgen_test]
fn planar_geometry_is_pure_rust() {
    // Planar area needs no s2 — pure-Rust shoelace.
    let tri = [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0)];
    let area = polygon_area(&tri, Manifold::Planar).expect("planar area");
    assert!((area - 0.5).abs() < 1e-12, "triangle area = {area}");

    // Planar clip (Sutherland–Hodgman) of two unit squares offset by (½,½):
    // overlap is a ½×½ square of area ¼.
    let a = [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)];
    let b = [(0.5, 0.5), (1.5, 0.5), (1.5, 1.5), (0.5, 1.5)];
    let clip = intersect_polygon(&a, &b, Manifold::Planar).expect("planar clip");
    assert!(clip.len() >= 3, "clip should be non-empty: {clip:?}");
    assert!(
        (shoelace_area(&clip) - 0.25).abs() < 1e-12,
        "clip area = {}",
        shoelace_area(&clip)
    );
}

#[wasm_bindgen_test]
fn spherical_geometry_errors_without_s2() {
    // No host has installed `globalThis.__earthsci_s2` in the test runner, so the
    // spherical bridge must fail cleanly (a `GeometryError`, not a panic/trap).
    let tri = [(0.0, 0.0), (90.0, 0.0), (0.0, 90.0)];
    let err = polygon_area(&tri, Manifold::Spherical).unwrap_err();
    assert!(
        err.message().contains("s2bindings") || err.message().contains("__earthsci_s2"),
        "expected an s2-missing message, got: {}",
        err.message()
    );
}

// --- reactions ---------------------------------------------------------------

#[wasm_bindgen_test]
fn reaction_stoichiometry() {
    let file = load(REACTIONS).expect("load reactions");
    let rs = &file.reaction_systems.as_ref().expect("reaction_systems")["Chem"];
    let m = stoichiometric_matrix(rs);
    assert_eq!(m.len(), 2, "2 species rows: {m:?}");
    assert_eq!(m[0].len(), 1, "1 reaction column: {m:?}");
    // A → B conserves mass, so the reaction's column sums to 0, with one species
    // consumed (−1) and one produced (+1).
    let mut col: Vec<f64> = m.iter().map(|row| row[0]).collect();
    assert!(
        col.iter().sum::<f64>().abs() < 1e-12,
        "column sums to 0: {col:?}"
    );
    col.sort_by(|a, b| a.partial_cmp(b).unwrap());
    assert!(
        (col[0] + 1.0).abs() < 1e-12 && (col[1] - 1.0).abs() < 1e-12,
        "coeffs should be {{-1, +1}}: {col:?}"
    );
}

// --- graph / metadata --------------------------------------------------------

#[wasm_bindgen_test]
fn component_graph_and_version() {
    let file = load(SCALAR_ODE).expect("load");
    let graph = component_graph(&file);
    assert_eq!(graph.nodes.len(), 1, "one model node");
    assert_eq!(graph.nodes[0].id, "Decay");

    assert!(!earthsci_ast::VERSION.is_empty());
    assert!(!earthsci_ast::SCHEMA_VERSION.is_empty());
}
