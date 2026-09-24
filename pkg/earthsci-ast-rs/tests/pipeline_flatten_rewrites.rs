//! The build pipeline reads the authored model rather than a flattened one, so
//! it makes the rewrites `flatten` would have made, as the array runtime's
//! single-model route does: a degree-valued argument of a circular function in
//! radians (esm-spec §4.8.3, issue #409), a self-qualified reference resolved,
//! and a right-hand-side `D` resolved or refused (esm-spec §4.2).

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Compiler, ProblemOptions, SimulateError, esm_problem, observed_field};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};

/// `sin_lat = sin(latitude)` with `latitude = 40 deg`, and
/// `cos_lat[i] = cos(lat[i])` over a shaped `lat` in degrees.
fn doc(lat_default: Option<Value>) -> Value {
    let mut lat = json!({"type": "parameter", "units": "deg", "shape": ["cells"]});
    if let Some(d) = lat_default {
        lat["default"] = d;
    }
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "DegreeArguments"},
        "index_sets": {"cells": {"kind": "interval", "size": 3}},
        "models": {"Deg": {
            "variables": {
                "latitude": {"type": "parameter", "units": "deg", "default": 40.0},
                "lat": lat,
                "sin_lat": {"type": "unknown", "units": "1"},
                "cos_lat": {"type": "unknown", "units": "1", "shape": ["cells"]}
            },
            "equations": [
                {"lhs": "sin_lat", "rhs": {"op": "sin", "args": ["latitude"]}},
                {"lhs": "cos_lat",
                 "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                         "ranges": {"i": {"from": "cells"}},
                         "expr": {"op": "cos", "args": [{"op": "index", "args": ["lat", "i"]}]}}}
            ]
        }}
    })
}

const LAT: [f64; 3] = [0.0, 60.0, 90.0];

fn values(prob: &earthsci_ast::EsmProblem, name: &str) -> Vec<f64> {
    observed_field(prob, name)
        .unwrap_or_else(|e| panic!("{name}: {e}"))
        .iter()
        .copied()
        .collect()
}

fn build(d: &Value, compiler: Compiler, pipeline: bool) -> earthsci_ast::EsmProblem {
    let const_arrays = if pipeline {
        let lat = ArrayD::from_shape_vec(IxDyn(&[3]), LAT.to_vec()).expect("shape");
        [("lat".to_string(), lat)].into_iter().collect()
    } else {
        Default::default()
    };
    esm_problem(
        d,
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(compiler),
            build_pipeline: pipeline,
            const_arrays,
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("[{compiler}] pipeline={pipeline}: {e}"))
}

fn bits(v: &[f64]) -> Vec<u64> {
    v.iter().map(|x| x.to_bits()).collect()
}

/// Through the build pipeline — the route every data-ingesting document takes
/// — the degree-valued arguments are converted, and the answers are the
/// analytic ones and the same bits the route without the pipeline gives.
#[test]
fn the_build_pipeline_takes_a_degree_argument_in_radians() {
    for compiler in [Compiler::Native, Compiler::Interpreter] {
        // `lat` from supplied data (the pipeline), or from its inline default.
        let piped = build(&doc(None), compiler, true);
        let plain = build(&doc(Some(json!(LAT))), compiler, false);

        let sin = values(&piped, "Deg.sin_lat");
        assert!(
            (sin[0] - 40f64.to_radians().sin()).abs() < 1e-15,
            "[{compiler}] sin(40 deg) = {}, not sin(40 rad) = {}",
            sin[0],
            40f64.sin()
        );
        assert_eq!(
            bits(&sin),
            bits(&values(&plain, "Deg.sin_lat")),
            "[{compiler}]"
        );

        let cos = values(&piped, "Deg.cos_lat");
        for (c, d) in cos.iter().zip(LAT) {
            assert!(
                (c - d.to_radians().cos()).abs() < 1e-15,
                "[{compiler}] cos({d} deg) = {c}"
            );
        }
        assert_eq!(
            bits(&cos),
            bits(&values(&plain, "Deg.cos_lat")),
            "[{compiler}]"
        );
    }
}

fn scalar_doc(equations: Value) -> Value {
    json!({
        "esm": "1.1.0",
        "metadata": {"name": "Rewrites"},
        "models": {"M": {
            "variables": {
                "a": {"type": "parameter", "units": "1", "default": 2.0},
                "y": {"type": "unknown", "units": "1"},
                "z": {"type": "unknown", "units": "1"}
            },
            "equations": equations
        }}
    })
}

fn with_pipeline(d: &Value, pipeline: bool) -> Result<earthsci_ast::EsmProblem, SimulateError> {
    esm_problem(
        d,
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(Compiler::Interpreter),
            build_pipeline: pipeline,
            ..Default::default()
        },
    )
}

/// `M.a` written inside model `M` is the local `a` on the pipeline too, where
/// it used to be an unbound name.
#[test]
fn the_build_pipeline_resolves_a_self_qualified_reference() {
    let d = scalar_doc(json!([
        {"lhs": "y", "rhs": {"op": "*", "args": ["M.a", 3.0]}},
        {"lhs": "z", "rhs": {"op": "+", "args": ["y", 1.0]}}
    ]));
    for pipeline in [false, true] {
        let prob =
            with_pipeline(&d, pipeline).unwrap_or_else(|e| panic!("pipeline={pipeline}: {e}"));
        assert_eq!(values(&prob, "M.y"), vec![6.0], "pipeline={pipeline}");
    }
}

/// A right-hand-side `D` the model gives no tendency for is refused on the
/// pipeline, as on the single-model route. It used to evaluate to `NaN`.
#[test]
fn the_build_pipeline_refuses_an_unresolved_right_hand_side_derivative() {
    let d = scalar_doc(json!([
        {"lhs": "y", "rhs": {"op": "*", "args": ["a", "t"]}},
        {"lhs": "z", "rhs": {"op": "D", "args": ["y"], "wrt": "t"}}
    ]));
    let err = with_pipeline(&d, true).expect_err("an unresolved `D` has no value");
    assert!(err.to_string().contains("'D'"), "{err}");
}
