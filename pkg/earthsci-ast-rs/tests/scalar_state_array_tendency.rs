//! A SCALAR state whose tendency reads an array is `array_shape_mismatch`
//! (esm-spec §4.3.4, §10.5; issue #715).
//!
//! A coupling can carry a 0-D system's inputs onto a grid without carrying its
//! states: a pointwise `variable_map` lifts the rate a reaction system reads,
//! or an `operator_compose` `translate` names only some of its species. The
//! states then stay scalar while their tendencies are arrays. The build used to
//! evaluate each such scalar slot at one element of the array, a plausible
//! wrong number; the inline-test runner then also refused every array initial
//! condition on those states. Translating EVERY state onto a shaped state of
//! the column is the route that carries the states, and stays green.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Alg, SolveOptions, load_string};
use std::collections::HashMap;

fn run(doc: &serde_json::Value) -> Result<earthsci_ast::Solution, String> {
    let file = load_string(&doc.to_string()).map_err(|e| format!("load: {e}"))?;
    let opts = SolveOptions {
        alg: Alg::Bdf,
        reltol: Some(1e-12),
        abstol: Some(1e-14),
        saveat: Some(vec![0.0, 1.0]),
        ..Default::default()
    };
    earthsci_ast::esm_problem(
        &file,
        (0.0, 1.0),
        earthsci_ast::ProblemOptions {
            p: HashMap::new(),
            u0: HashMap::new(),
            rhs: earthsci_ast::Rhs::Always,
            ..Default::default()
        },
    )
    .and_then(|prob| earthsci_ast::solve(&prob, &opts))
    .map_err(|e| format!("{e}"))
}

fn assert_refused(doc: &serde_json::Value, state: &str, operand: &str) {
    let err = run(doc).expect_err("a scalar state with an array tendency must be refused");
    assert!(
        err.contains(&format!("array_shape_mismatch: state '{state}' is scalar"))
            && err.contains(&format!("reads '{operand}'")),
        "{err}"
    );
}

/// A column `Col` with states over `c`, and an inline 0-D mechanism
/// `A -> B` at rate `k`, composed by `translate` (`map` keys are `Col`'s).
fn column(
    translate: serde_json::Value,
    extra_coupling: Vec<serde_json::Value>,
) -> serde_json::Value {
    let mut coupling = vec![serde_json::json!({
        "type": "operator_compose", "systems": ["Col", "Mech"], "translate": translate
    })];
    coupling.extend(extra_coupling);
    serde_json::json!({
        "esm": "2.0.0", "metadata": {"name": "lift_states"},
        "index_sets": {"c": {"kind": "interval", "size": 3}},
        "models": {"Col": {
            "variables": {
                "T": {"type": "parameter", "units": "1/s", "shape": ["c"],
                      "default": [0.001, 0.002, 0.004]},
                "A": {"type": "unknown", "units": "1", "shape": ["c"],
                      "default": [1.0, 2.0, 4.0]},
                "B": {"type": "unknown", "units": "1", "shape": ["c"],
                      "default": [0.5, 0.1, 1.0]}
            },
            "equations": [
                {"lhs": {"op": "D", "args": ["A"], "wrt": "t"}, "rhs": 0.0},
                {"lhs": {"op": "D", "args": ["B"], "wrt": "t"}, "rhs": 0.0}
            ]
        }},
        "reaction_systems": {"Mech": {
            "species": {"A": {"units": "1", "default": 1.0}, "B": {"units": "1", "default": 0.5}},
            "parameters": {"k": {"units": "1/s", "default": 0.001}},
            "reactions": [{"id": "R1",
                "substrates": [{"species": "A", "stoichiometry": 1}],
                "products": [{"species": "B", "stoichiometry": 1}],
                "rate": "k"}]
        }},
        "coupling": coupling
    })
}

#[test]
fn a_scalar_state_reading_a_shaped_parameter_is_refused() {
    let doc = serde_json::json!({
        "esm": "2.0.0", "metadata": {"name": "scalar_state"},
        "index_sets": {"c": {"kind": "interval", "size": 3}},
        "models": {"M": {
            "variables": {
                "k": {"type": "parameter", "units": "1/s", "shape": ["c"], "default": [1.0, 2.0, 3.0]},
                "x": {"type": "unknown", "units": "1", "default": 1.0}
            },
            "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                "rhs": {"op": "*", "args": [{"op": "-", "args": ["k"]}, "x"]}}]
        }}
    });
    assert_refused(&doc, "x", "k");
}

#[test]
fn every_species_translated_onto_the_column_is_lifted() {
    // Positive control: both species are the column's, so both are `[c]`.
    let doc = column(
        serde_json::json!({"Col.A": "Mech.A", "Col.B": "Mech.B"}),
        vec![],
    );
    let sol = run(&doc).expect("full translate runs");
    assert!(!sol.time.is_empty());
}

#[test]
fn a_species_a_partial_translate_leaves_scalar_is_refused() {
    // Only A is translated: Mech.B stays 0-D while its production k * Col.A
    // is an array over `c`.
    let mut doc = column(serde_json::json!({"Col.A": "Mech.A"}), vec![]);
    // The column has no B of its own, so B cannot merge by its bare name.
    let col = &mut doc["models"]["Col"];
    col["variables"].as_object_mut().unwrap().remove("B");
    col["equations"].as_array_mut().unwrap().truncate(1);
    assert_refused(&doc, "Mech.B", "Col.A");
}

#[test]
fn a_mechanism_whose_rate_alone_is_lifted_is_refused() {
    // The rate is lifted onto `c` by a pointwise `variable_map`; the species
    // are not composed with the column at all, so they stay 0-D.
    let mut doc = column(
        serde_json::json!({"Col.A": "Mech.A", "Col.B": "Mech.B"}),
        vec![],
    );
    doc["coupling"] = serde_json::json!([{
        "type": "variable_map", "from": "Col.T", "to": "Mech.k",
        "transform": "param_to_var", "lifting": "pointwise"
    }]);
    assert_refused(&doc, "Mech.A", "Col.T");
}
