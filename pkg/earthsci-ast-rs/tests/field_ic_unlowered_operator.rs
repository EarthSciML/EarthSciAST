//! esm-spec §9.6.3 constraint 6 on the array runtime's flattened entry.
//!
//! `flatten` routes every `ic(state) = rhs` equation out of
//! `FlattenedSystem::equations` into `FlattenedSystem::field_ics`, and
//! `ArrayCompiled::from_flattened` builds its synthetic model from the
//! equations alone, attaching the initial conditions afterwards. The build's
//! stage-(0) walk therefore never saw an initial-condition right-hand side: an
//! unlowered op there compiled, and surfaced only at `solve`, as a generic
//! "invalid field initial condition" rather than `unlowered_operator`. The
//! single-model array entry refuses it at build.

use earthsci_ast::simulate_array::ArrayCompiled;
use earthsci_ast::{flatten, load_string};
use serde_json::{Value, json};

fn box_with_ic(ic_rhs: Value) -> earthsci_ast::FlattenedSystem {
    let doc = json!({
        "esm": "1.0.0",
        "metadata": {"name": "FieldIcGate", "authors": ["test"]},
        "models": {"Box": {
            "variables": {"c": {"type": "unknown", "units": "1", "default": 1.0}},
            "equations": [
                {"lhs": {"op": "D", "args": ["c"], "wrt": "t"}, "rhs": 1.0},
                {"lhs": {"op": "ic", "args": ["c"]}, "rhs": ic_rhs}
            ]
        }}
    });
    let file = load_string(&doc.to_string()).expect("loads");
    let flat = flatten(&file).expect("flattens");
    assert_eq!(
        flat.field_ics.len(),
        1,
        "the ic equation is routed to field_ics"
    );
    flat
}

#[test]
fn an_unlowered_op_in_a_field_initial_condition_is_refused_at_build() {
    let flat = box_with_ic(json!({"op": "godunov_hamiltonian", "args": [2.0]}));
    let err = match ArrayCompiled::from_flattened(&flat) {
        Ok(_) => panic!("an unlowered op in a field initial condition must not compile"),
        Err(e) => e.to_string(),
    };
    assert!(
        err.contains("unlowered_operator") && err.contains("godunov_hamiltonian"),
        "expected unlowered_operator naming the op, got: {err}"
    );
}

#[test]
fn a_constant_field_initial_condition_still_compiles() {
    let flat = box_with_ic(json!(2.0));
    assert!(ArrayCompiled::from_flattened(&flat).is_ok());
}
