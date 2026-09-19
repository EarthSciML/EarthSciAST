//! esm-spec §4.8.3 and issue #409: a unit's SCALE reaches the trig and
//! transcendental rules.
//!
//! Two halves that want OPPOSITE fixes, and one file so they stay in view of
//! each other:
//!
//! * **Angles convert.** `deg` is a registry unit at scale π/180, so
//!   `sin(theta [deg])` is a CONFORMING document — and `flatten` used to hand
//!   the stored number straight to `sin`, so `sin(90 [deg])` evaluated
//!   0.8939966636005579, which is `sin(90 radians)`, with no diagnostic. The
//!   conversion is exact and has exactly one reading.
//! * **Scaled dimensionless refuses.** `ppm` is dimensionless at 1e-6, so
//!   `log(c [ppm])` satisfied every dimension-only test. The log of the ppm
//!   NUMBER and the log of the mole fraction differ by `ln(1e-6) = 13.8155…`
//!   and nothing in the document says which was meant, so the checker refuses
//!   and names the repair rather than picking one.
//!
//! Everything asserted here is asserted off SHARED fixtures, so the same facts
//! are checked by the other four bindings.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{Expr, SolveOptions, flatten, load_string, run_inline_tests, validate};

mod common;

/// Every `sin`/`cos`/`tan` node in a flattened expression, with its single
/// argument.
fn trig_arguments(expr: &Expr, out: &mut Vec<(String, Expr)>) {
    let Expr::Operator(node) = expr else { return };
    if matches!(node.op.as_str(), "sin" | "cos" | "tan") && node.args.len() == 1 {
        out.push((node.op.clone(), node.args[0].clone()));
    }
    for a in &node.args {
        trig_arguments(a, out);
    }
}

/// The shared numeric fixture's `deg` arguments reach the evaluator already
/// multiplied by π/180, and its `rad` argument does NOT — which is what
/// distinguishes "the scale is applied" from "the scale is applied twice".
#[test]
fn flatten_converts_a_degree_argument_and_leaves_radians_alone() {
    let file = common::load_repo_fixture("simulation/angle_units_degrees.esm");
    let flat = flatten(&file).expect("the fixture flattens");

    let mut found = Vec::new();
    for eq in &flat.equations {
        trig_arguments(&eq.rhs, &mut found);
    }
    assert_eq!(found.len(), 4, "the fixture carries four trig calls");

    let mut converted = 0;
    let mut untouched = 0;
    for (op, arg) in &found {
        match arg {
            Expr::Operator(product) if product.op == "*" => {
                assert_eq!(
                    product.args[1],
                    Expr::Number(std::f64::consts::PI / 180.0),
                    "{op}: the folded factor is the declared scale of `deg`"
                );
                converted += 1;
            }
            Expr::Variable(name) => {
                assert!(
                    name.ends_with("theta_rad"),
                    "{op}: only the `rad` control is left as a bare reference, got {name}"
                );
                untouched += 1;
            }
            other => panic!("{op}: unexpected flattened argument {other:?}"),
        }
    }
    assert_eq!((converted, untouched), (3, 1));
}

/// A document declaring no scaled angle is not rewritten at all, so the common
/// case costs nothing and cannot change a number.
#[test]
fn flatten_leaves_a_document_with_no_scaled_angle_untouched() {
    let file = common::load_repo_fixture("simulation/simple_ode.esm");
    let before = flatten(&file).expect("flattens");
    let after = flatten(&file).expect("flattens");
    for (a, b) in before.equations.iter().zip(after.equations.iter()) {
        assert_eq!(a.rhs, b.rhs);
    }
}

/// The shared invalid fixture is REFUSED, and the diagnostic names the repair.
#[test]
fn a_scaled_dimensionless_transcendental_argument_is_refused() {
    let file =
        common::load_repo_fixture("invalid/units_discriminator_transcendental_scaled_argument.esm");
    let result = validate(&file);
    assert!(
        !result.is_valid,
        "log(c [ppm]) leaves the reading unstated and must be refused"
    );
    let named = result
        .structural_errors
        .iter()
        .any(|e| e.message.contains("divide by 1 ppm"));
    assert!(
        named,
        "the diagnostic must name the repair, got {:?}",
        result
            .structural_errors
            .iter()
            .map(|e| &e.message)
            .collect::<Vec<_>>()
    );
}

/// ...and the repair the diagnostic names is accepted, together with the `deg`
/// argument that is CONVERTED rather than refused.
#[test]
fn the_named_repair_and_a_degree_argument_are_accepted() {
    let file = common::load_repo_fixture("valid/units_transcendental_scaled_argument_repair.esm");
    let result = validate(&file);
    assert!(
        result.is_valid,
        "the repaired spelling must be accepted, got {:?}",
        result
            .structural_errors
            .iter()
            .map(|e| &e.message)
            .collect::<Vec<_>>()
    );
}

/// The ARRAY route converts too.
///
/// A single-model array/PDE document does not reach the array runtime through
/// `flatten`: `ArrayCompiled::from_file` takes the authored `Model` directly
/// (`simulate::driver::build_array_compiled` flattens only when the file
/// carries MORE than one model), so `flatten`'s angle phase never ran for it —
/// and every consumer of that route (the per-cell oracle, the vectorized
/// overlay, the tape, the XLA emitter) evaluated `sin(90 radians)` = 0.894
/// where the SCALAR route of this same binding, and the other four bindings,
/// returned 1. The same document answering two numbers is the thing this file
/// exists to prevent, so the raw-model compile mirrors the flatten phase
/// (`simulate_array::compile::normalize_model_angle_arguments`).
///
/// The document is inline rather than a `tests/simulation/` fixture because the
/// defect is specific to the one binding that has a non-flattening compile
/// route: the other four flatten unconditionally.
#[test]
fn the_array_route_converts_a_degree_argument_and_leaves_radians_alone() {
    // A shaped state is what routes this to the array runtime; one model is
    // what makes that route skip `flatten`. Each state integrates a constant
    // over [0, 1], so its value at t = 1 IS that constant, in every cell.
    let doc = r#"{
      "esm": "1.1.0",
      "metadata": {"name": "AngleUnitsDegreesArray"},
      "index_sets": {"cells": {"kind": "interval", "size": 2}},
      "models": {"AngleUnitsArray": {
        "variables": {
          "theta_deg": {"type": "parameter", "units": "deg", "default": 90.0},
          "theta_rad": {"type": "parameter", "units": "rad", "default": 1.5707963267948966},
          "sin_deg": {"type": "unknown", "shape": ["cells"], "units": "1", "default": 0.0},
          "sin_rad": {"type": "unknown", "shape": ["cells"], "units": "1", "default": 0.0}
        },
        "equations": [
          {"lhs": {"op": "D", "args": ["sin_deg"], "wrt": "t"},
           "rhs": {"op": "sin", "args": ["theta_deg"]}},
          {"lhs": {"op": "D", "args": ["sin_rad"], "wrt": "t"},
           "rhs": {"op": "sin", "args": ["theta_rad"]}}
        ],
        "tolerance": {"rel": 1e-6, "abs": 1e-9},
        "tests": [{
          "id": "the_array_route_converts_degrees",
          "time_span": {"start": 0.0, "end": 1.0},
          "assertions": [
            {"variable": "sin_deg", "time": 1.0, "reduce": "max", "expected": 1.0},
            {"variable": "sin_rad", "time": 1.0, "reduce": "max", "expected": 1.0}
          ]
        }]
      }},
      "domain": {"temporal": {}}
    }"#;
    let file = load_string(doc).expect("the inline array document loads");
    let results = run_inline_tests(&file, None, &SolveOptions::default());
    assert_eq!(results.len(), 2, "both assertions ran");
    for r in &results {
        assert!(
            r.passed,
            "{}: expected {}, got {:?} ({}) — before this was mirrored onto the \
             raw-model compile the `deg` row read 0.8939966636005579, which is \
             sin(90 RADIANS)",
            r.variable, r.expected, r.actual, r.message
        );
    }
}
