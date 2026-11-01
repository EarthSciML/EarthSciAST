//! What an EsmProblem keeps of the build pipeline's ingested DATA-FED
//! parameters (finding F43, `ProblemOptions::retain_data_fields`).
//!
//! An ingested table can be hundreds of MB, so construction keeps only what
//! something reads: the right-hand side's columns are MOVED into the forcing
//! buffer, a column `retain_data_fields` names stays readable through
//! `observed_field`, and every other column is dropped — with a diagnostic that
//! says how to ask for it, rather than calling it unknown.
//!
//! The columns arrive as caller `const_arrays`, which the build pipeline
//! ingests exactly as it does a provider's array.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;

use earthsci_ast::{ProblemOptions, SolveOptions, esm_problem, observed_field, solve};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};

const P: [f64; 4] = [1.0, 2.0, 4.0, 8.0];
const Q: [f64; 4] = [3.0, 5.0, 7.0, 9.0];

/// `p` and `q` are data-fed over `rows`; `total = Σ p`, and — when
/// `integrating` — `D(x) = total` from `x(0) = 0`, so `x(1) = 15`. Nothing
/// reads `q`.
fn document(integrating: bool) -> Value {
    let fed = |what: &str| {
        json!({"type": "parameter", "units": "1", "default": 0.0, "shape": ["rows"],
               "description": what,
               "update": {"kind": "data", "source": "table", "from": {"file_variable": what}}})
    };
    let mut variables = json!({
        "p": fed("p"),
        "q": fed("q"),
        "total": {"type": "unknown", "units": "1", "description": "Σ p = 15"}
    });
    let mut equations = vec![json!({
        "lhs": "total",
        "rhs": {"op": "faq", "args": [], "output_idx": [], "ranges": {"r": {"from": "rows"}},
                "expr": {"op": "index", "args": ["p", "r"]}}
    })];
    if integrating {
        variables["x"] = json!({"type": "unknown", "units": "1", "default": 0.0,
                                "description": "integrates total"});
        equations.push(json!({"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": "total"}));
    }
    json!({
        "esm": "1.2.0",
        "metadata": {"name": "Retention", "description": "Two ingested columns, one read."},
        "data_sources": {"table": {"kind": "static", "source": {"url_template": "./table.parquet"}}},
        "index_sets": {"rows": {"kind": "interval", "size": 4}},
        "models": {"M": {"variables": variables, "equations": equations}}
    })
}

fn build(doc: &Value, retain: &[&str]) -> earthsci_ast::EsmProblem {
    let column = |v: [f64; 4]| ArrayD::from_shape_vec(IxDyn(&[4]), v.to_vec()).unwrap();
    esm_problem(
        doc,
        (0.0, 1.0),
        ProblemOptions {
            const_arrays: HashMap::from([
                ("p".to_string(), column(P)),
                ("q".to_string(), column(Q)),
            ]),
            build_pipeline: true,
            retain_data_fields: retain.iter().map(|s| s.to_string()).collect(),
            ..Default::default()
        },
    )
    .expect("the document builds")
}

fn x_at_end(prob: &earthsci_ast::EsmProblem) -> f64 {
    let sol = solve(
        prob,
        &SolveOptions {
            saveat: Some(vec![1.0]),
            ..Default::default()
        },
    )
    .expect("the document solves");
    *sol.get("M.x").expect("x is a state").last().unwrap()
}

fn assert_dropped_with_remedy(prob: &earthsci_ast::EsmProblem, name: &str) {
    let err = observed_field(prob, name)
        .expect_err("an unretained ingested column is not kept")
        .to_string();
    assert!(
        err.contains("retain_data_fields"),
        "the refusal must say how to keep '{name}': {err}"
    );
}

#[test]
fn a_named_column_reads_back_and_an_unnamed_one_is_dropped_with_a_remedy() {
    let prob = build(&document(false), &["p"]);
    assert_eq!(
        observed_field(&prob, "p")
            .expect("p was named")
            .as_slice()
            .unwrap(),
        P
    );
    assert_dropped_with_remedy(&prob, "q");
}

#[test]
fn the_right_hand_side_reads_a_column_nobody_asked_to_keep() {
    // Moved into the forcing buffer, not copied — and not kept for read-back.
    let prob = build(&document(true), &[]);
    assert!((x_at_end(&prob) - 15.0).abs() < 1e-9);
    assert_dropped_with_remedy(&prob, "p");
    assert_dropped_with_remedy(&prob, "q");
}

#[test]
fn a_column_the_right_hand_side_reads_and_the_caller_named_serves_both() {
    let prob = build(&document(true), &["M.p"]);
    assert!((x_at_end(&prob) - 15.0).abs() < 1e-9);
    assert_eq!(
        observed_field(&prob, "M.p")
            .expect("p was named")
            .as_slice()
            .unwrap(),
        P
    );
}
