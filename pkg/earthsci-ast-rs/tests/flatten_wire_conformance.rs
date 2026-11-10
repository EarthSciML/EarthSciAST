//! `tests/conformance/flatten_wire/`: the flattened system as this binding
//! writes it out, byte for byte against the shared golden every binding
//! writes (esm-spec §9.6.11, "A flattened system keeps its applications'
//! meaning on the wire"; esm-libraries-spec §4.7.5, "Pointwise lift: operands
//! read per cell"). The golden form is in the case directory's README.

use earthsci_ast::{FlattenedSystem, flatten, format_canonical_float, load_path};
use serde_json::{Value, json};
use std::path::PathBuf;

fn case_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/conformance/flatten_wire")
}

/// `v` as canonical JSON: keys sorted by code point, no whitespace, integers
/// as written, floats through `format_canonical_float`.
fn canonical(v: &Value, out: &mut String) {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => match (n.as_i64(), n.as_u64()) {
            (Some(i), _) => out.push_str(&i.to_string()),
            (None, Some(u)) => out.push_str(&u.to_string()),
            _ => out.push_str(&format_canonical_float(n.as_f64().unwrap())),
        },
        Value::String(s) => out.push_str(&serde_json::to_string(s).unwrap()),
        Value::Array(a) => {
            out.push('[');
            for (i, x) in a.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonical(x, out);
            }
            out.push(']');
        }
        Value::Object(o) => {
            let mut keys: Vec<&String> = o.keys().collect();
            keys.sort();
            out.push('{');
            for (i, k) in keys.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&serde_json::to_string(k).unwrap());
                out.push(':');
                canonical(&o[k], out);
            }
            out.push('}');
        }
    }
}

/// The golden form of `flat`: its equations as they serialize, and every
/// variable's declared shape.
fn wire_form(flat: &FlattenedSystem) -> String {
    let equations: Vec<Value> = flat
        .equations
        .iter()
        .map(|e| {
            json!({
                "lhs": serde_json::to_value(&e.lhs).unwrap(),
                "rhs": serde_json::to_value(&e.rhs).unwrap(),
            })
        })
        .collect();
    let mut shapes = serde_json::Map::new();
    for part in [
        &flat.state_variables,
        &flat.parameters,
        &flat.observed_variables,
    ] {
        for (name, var) in part {
            shapes.insert(name.clone(), json!(var.shape));
        }
    }
    let mut out = String::new();
    canonical(&json!({"equations": equations, "shapes": shapes}), &mut out);
    out.push('\n');
    out
}

#[test]
fn the_flattened_system_on_the_wire_matches_the_shared_golden() {
    let dir = case_dir();
    let cases: Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join("cases.json")).unwrap()).unwrap();
    let cases = cases["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 2);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let file = load_path(dir.join(case["fixture"].as_str().unwrap())).expect(name);
        let flat = flatten(&file).expect(name);
        let got = wire_form(&flat);
        let want = std::fs::read_to_string(dir.join(case["golden"].as_str().unwrap())).unwrap();
        assert!(
            got == want,
            "{name}: the flattened wire form differs from the golden\n got: {got}\nwant: {want}"
        );
    }
}
