//! Scratch probe (issue #220): which ops does the SCALAR path answer for?
#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{EsmFile, SolveOptions, run_pde_tests};
use serde_json::json;

#[test]
fn probe_scalar_op_outcomes() {
    let ops: Vec<serde_json::Value> = vec![
        json!({ "op": "neg", "args": ["p"] }),
        json!({ "op": "const", "args": [], "value": 3.0 }),
        json!({ "op": "true", "args": [] }),
        json!({ "op": "skolem", "args": ["p"] }),
        json!({ "op": "rank", "args": ["p"] }),
        json!({ "op": "distinct", "args": ["p"] }),
        json!({ "op": "argmin", "args": [], "arg": "i", "ranges": { "i": [1, 3] }, "expr": "p" }),
        json!({ "op": "argmax", "args": [], "arg": "i", "ranges": { "i": [1, 3] }, "expr": "p" }),
        json!({ "op": "ic", "args": ["p"] }),
        json!({ "op": "enum", "args": ["colors", "red"] }),
        json!({ "op": "table_lookup", "args": [] }),
        json!({ "op": "apply_expression_template", "args": [], "name": "tmpl" }),
        json!({ "op": "intersect_polygon", "args": ["p", "p"] }),
        json!({ "op": "polygon_intersection_area", "args": ["p", "p"] }),
        json!({ "op": "reshape", "args": ["p"] }),
        json!({ "op": "transpose", "args": ["p"] }),
        json!({ "op": "concat", "args": ["p"] }),
        json!({ "op": "makearray", "args": [] }),
        json!({ "op": "index", "args": ["p"] }),
        json!({ "op": "broadcast", "args": ["p"], "fn": "+" }),
        json!({ "op": "Pre", "args": ["p"] }),
        json!({ "op": "D", "args": ["p"], "wrt": "t" }),
    ];
    for body in ops {
        let op = body["op"].as_str().unwrap().to_string();
        let doc = json!({
            "esm": "1.0.0",
            "metadata": { "name": "Probe" },
            "models": { "M": {
                "variables": {
                    "p": { "type": "parameter", "default": 2.0 },
                    "y": { "type": "unknown" }
                },
                "equations": [
                    { "lhs": "y", "rhs": body }
                ],
                "tests": [ { "id": "probe", "time_span": { "start": 0.0, "end": 0.0 },
                             "assertions": [ { "variable": "y", "time": 0.0,
                                               "expected": 12345.0 } ] } ]
            }}
        });
        let file: EsmFile = match serde_json::from_value(doc) {
            Ok(f) => f,
            Err(e) => {
                println!("{op:>28}  PARSE-ERR {e}");
                continue;
            }
        };
        let results = run_pde_tests(&file, Some("M"), &SolveOptions::default());
        for r in &results {
            println!(
                "{op:>28}  passed={} actual={:?} msg={}",
                r.passed, r.actual, r.message
            );
        }
        if results.is_empty() {
            println!("{op:>28}  NO RESULTS");
        }
    }
}
