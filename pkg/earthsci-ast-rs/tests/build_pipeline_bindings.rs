//! The bindings a caller hands `esm_problem` reach the build pipeline exactly
//! as they reach the static route: metaparameters size the compiled model too,
//! a partially qualified parameter key designates what the static route says
//! it does, observeds are evaluated at the start of the time span, and a baked
//! parameter refuses a `remake` under any spelling of its name.

use std::collections::{BTreeMap, HashMap};

use earthsci_ast::{
    ProblemOptions, Remake, SimulateError, esm_problem, initial_state, observed_field, remake,
};
use serde_json::{Value, json};

fn pipeline(p: &[(&str, f64)]) -> ProblemOptions {
    ProblemOptions {
        build_pipeline: true,
        p: p.iter().map(|(k, v)| (k.to_string(), *v)).collect(),
        ..Default::default()
    }
}

fn scalar(prob: &earthsci_ast::EsmProblem, name: &str) -> f64 {
    let a = observed_field(prob, name).unwrap_or_else(|e| panic!("observed {name}: {e}"));
    *a.iter().next().expect("one value")
}

/// A state over an index set a metaparameter sizes.
fn sized_by_metaparameter() -> Value {
    json!({
        "esm": "2.0.0",
        "metadata": {"name": "sized_by_metaparameter"},
        "metaparameters": {"N": {"type": "integer", "default": 2}},
        "index_sets": {"i": {"kind": "interval", "size": "N"}},
        "models": {"M": {
            "variables": {
                "x": {"type": "unknown", "units": "1", "shape": ["i"], "default": 1.0},
                "k": {"type": "parameter", "units": "1/s", "default": 0.5}
            },
            "equations": [{
                "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                "rhs": {"op": "*", "args": ["k", "x"]}
            }]
        }}
    })
}

#[test]
fn caller_metaparameters_size_the_compiled_model_after_the_build_pipeline() {
    let doc = sized_by_metaparameter();
    let mut opts = pipeline(&[]);
    opts.metaparameters = BTreeMap::from([("N".to_string(), 4)]);
    let prob = esm_problem(&doc, (0.0, 1.0), opts).expect("build");
    let static_route = esm_problem(
        &doc,
        (0.0, 1.0),
        ProblemOptions {
            metaparameters: BTreeMap::from([("N".to_string(), 4)]),
            ..Default::default()
        },
    )
    .expect("static build");
    assert_eq!(initial_state(&static_route).expect("u0").len(), 4);
    assert_eq!(initial_state(&prob).expect("u0").len(), 4);
}

/// Two models, so the build is the whole document; `P` mounts `sub`.
fn whole_document() -> Value {
    json!({
        "esm": "2.0.0",
        "metadata": {"name": "whole_document_keys"},
        "models": {
            "P": {
                "variables": {"y": {"type": "unknown", "units": "1"}},
                "equations": [{"lhs": "y", "rhs": {"op": "*", "args": [2.0, "sub.g"]}}],
                "subsystems": {"sub": {
                    "variables": {"g": {"type": "parameter", "units": "1", "default": 1.0}},
                    "equations": []
                }}
            },
            "Q": {
                "variables": {"h": {"type": "parameter", "units": "1", "default": 3.0},
                              "z": {"type": "unknown", "units": "1"}},
                "equations": [{"lhs": "z", "rhs": "h"}]
            }
        }
    })
}

#[test]
fn a_partially_qualified_key_reaches_its_parameter_in_a_whole_document_build() {
    let doc = whole_document();
    let static_route = esm_problem(
        &doc,
        (0.0, 1.0),
        ProblemOptions {
            p: HashMap::from([("sub.g".to_string(), 5.0)]),
            ..Default::default()
        },
    )
    .expect("static build");
    assert_eq!(scalar(&static_route, "P.y"), 10.0);
    let prob = esm_problem(&doc, (0.0, 1.0), pipeline(&[("sub.g", 5.0)])).expect("build");
    assert_eq!(scalar(&prob, "P.y"), 10.0);
}

#[test]
fn observeds_are_evaluated_at_the_start_of_the_time_span() {
    let doc = json!({
        "esm": "2.0.0",
        "metadata": {"name": "observed_at_start"},
        "models": {"M": {
            "variables": {
                "c": {"type": "parameter", "units": "s", "default": 1.0},
                "y": {"type": "unknown", "units": "s"}
            },
            "equations": [{"lhs": "y", "rhs": {"op": "+", "args": ["t", "c"]}}]
        }}
    });
    let static_route = esm_problem(&doc, (5.0, 6.0), ProblemOptions::default()).expect("static");
    assert_eq!(scalar(&static_route, "y"), 6.0);
    let prob = esm_problem(&doc, (5.0, 6.0), pipeline(&[])).expect("build");
    assert_eq!(scalar(&prob, "y"), 6.0);
}

#[test]
fn a_baked_parameter_refuses_a_remake_under_its_other_spelling() {
    let doc = json!({
        "esm": "2.0.0",
        "metadata": {"name": "baked_spellings"},
        "models": {"M": {
            "variables": {
                "x": {"type": "unknown", "units": "1", "default": 1.0},
                "k": {"type": "parameter", "units": "1/s", "default": 0.5}
            },
            "equations": [{
                "lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                "rhs": {"op": "*", "args": ["k", "x"]}
            }]
        }}
    });
    for (built, remade) in [("M.k", "k"), ("k", "M.k")] {
        let prob = esm_problem(&doc, (0.0, 1.0), pipeline(&[(built, 2.0)])).expect("build");
        let r = remake(
            &prob,
            &Remake {
                p: HashMap::from([(remade.to_string(), 3.0)]),
                ..Default::default()
            },
        );
        assert!(
            matches!(r, Err(SimulateError::UnsubstitutableBinding { .. })),
            "built with '{built}', remade with '{remade}': {:?}",
            r.err()
        );
    }
}
