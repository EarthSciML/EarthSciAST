//! The `argmin` / `argmax` templates of `lib/relational.esm` against the
//! `argmin` / `argmax` arg-witness ops.
//!
//! Every scenario of `tests/conformance/relational_templates/scenarios.json`
//! runs through the expanded template, under the interpreter and the strict
//! native tape, and must give the scenario's `expected` 1-based index; the op
//! (value invention, with the candidates as a caller array) must give the
//! same index, except where the scenario pins `op_expected` (a NaN candidate
//! after the first, which the op skips and the template picks). The
//! nearest-generator fixtures, each op node rewritten as the template, give
//! the op's assignment buffer under both compilers.

#![cfg(all(not(target_arch = "wasm32"), feature = "solve"))]

use std::collections::HashMap;
use std::path::PathBuf;

use earthsci_ast::simulate_array::ArrayCompiled;
use earthsci_ast::{
    Compiler, LoadOptions, ProblemOptions, Rhs, esm_problem, load_string_with_options,
    observed_field,
};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};

use crate::common;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn library() -> String {
    repo_root()
        .join("lib/relational.esm")
        .canonicalize()
        .expect("lib/relational.esm")
        .to_string_lossy()
        .into_owned()
}

fn decode(v: &Value) -> f64 {
    match v {
        Value::Number(n) => n.as_f64().expect("a number"),
        Value::String(s) if s == "NaN" => f64::NAN,
        Value::String(s) if s == "Inf" => f64::INFINITY,
        Value::String(s) if s == "-Inf" => f64::NEG_INFINITY,
        other => panic!("unsupported candidate: {other:?}"),
    }
}

/// A candidate as `num / den`, so a non-finite one fits in a `const`.
fn num_den(v: &Value) -> (f64, f64) {
    match v {
        Value::String(s) if s == "NaN" => (0.0, 0.0),
        Value::String(s) if s == "Inf" => (1.0, 0.0),
        Value::String(s) if s == "-Inf" => (-1.0, 0.0),
        _ => (decode(v), 1.0),
    }
}

/// The template's value under the interpreter and the strict native tape.
fn template_values(op: &str, values: &[Value], label: &str) -> [f64; 2] {
    let sym = format!("k_{op}_1");
    let (nums, dens): (Vec<f64>, Vec<f64>) = values.iter().map(num_den).unzip();
    let f = json!({"op": "/", "args": [
        {"op": "index", "args": [{"op": "const", "args": [], "value": nums}, sym]},
        {"op": "index", "args": [{"op": "const", "args": [], "value": dens}, sym]}
    ]});
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "relational_template_probe", "authors": ["test"]},
        "models": {"M": {
            "expression_template_imports": [{"ref": library()}],
            "variables": {"y": {"type": "unknown", "default": 0.0}},
            "equations": [{
                "lhs": {"op": "D", "args": ["y"], "wrt": "t"},
                "rhs": {"op": "apply_expression_template", "args": [], "name": op,
                        "bindings": {"f": f, "n": values.len()}}
            }]
        }}
    })
    .to_string();
    let options = LoadOptions {
        base_path: Some(repo_root()),
        ..Default::default()
    };
    let file =
        load_string_with_options(&doc, &options).unwrap_or_else(|e| panic!("{label}: load: {e}"));
    let compiled =
        ArrayCompiled::from_file(&file).unwrap_or_else(|e| panic!("{label}: compile: {e:?}"));
    let report = compiled.debug_build_tape_report();
    assert!(
        report.fallbacks.is_empty(),
        "{label}: rules left the tape: {:?}",
        report.fallbacks
    );
    let u = vec![0.0; compiled.state_variable_names().len()];
    let (oracle, _) = compiled.debug_eval_rhs(&u, 0.0, &HashMap::new(), true);
    let mut taped = vec![0.0; u.len()];
    let mut scratch = compiled
        .debug_new_scratch_taped()
        .unwrap_or_else(|e| panic!("{label}: strict native: {e}"));
    compiled.debug_eval_rhs_into(
        &u,
        0.0,
        &compiled.debug_resolve_params(&HashMap::new()),
        &mut taped,
        &mut scratch,
        &mut Default::default(),
    );
    [oracle[0], taped[0]]
}

fn arr(v: &[f64]) -> ArrayD<f64> {
    ArrayD::from_shape_vec(IxDyn(&[v.len()]), v.to_vec()).unwrap()
}

/// `name`'s field of `doc` under both compilers (they must agree bit for bit).
fn field_both(doc: &Value, arrays: &[(&str, Vec<f64>)], name: &str, label: &str) -> Vec<f64> {
    let mut out: Vec<Vec<f64>> = Vec::new();
    for c in [Compiler::Interpreter, Compiler::Native] {
        let mut doc = doc.clone();
        common::supply_state_defaults(&mut doc);
        let opts = ProblemOptions {
            compiler: Some(c),
            rhs: Rhs::Auto,
            const_arrays: arrays
                .iter()
                .map(|(k, v)| (k.to_string(), arr(v)))
                .collect(),
            ..Default::default()
        };
        let prob = esm_problem(&doc, (0.0, 1.0), opts)
            .unwrap_or_else(|e| panic!("{label} [{}]: {e}", c.as_str()));
        let f = observed_field(&prob, name)
            .unwrap_or_else(|e| panic!("{label} [{}] {name}: {e}", c.as_str()));
        out.push(f.iter().copied().collect());
    }
    let bits = |v: &[f64]| v.iter().map(|x| x.to_bits()).collect::<Vec<_>>();
    assert_eq!(
        bits(&out[0]),
        bits(&out[1]),
        "{label} {name}: compilers disagree"
    );
    out.pop().unwrap()
}

fn op_value(op: &str, values: &[Value], label: &str) -> f64 {
    let doc = json!({
        "esm": "1.1.0",
        "metadata": {"name": "relational_op_probe", "authors": ["test"]},
        "index_sets": {
            "points": {"kind": "interval", "size": 1},
            "cands": {"kind": "interval", "size": values.len()}
        },
        "models": {"M": {
            "variables": {
                "c": {"type": "parameter", "shape": ["cands"]},
                "a": {"type": "unknown", "shape": ["points"]}
            },
            "equations": [{
                "lhs": {"op": "index", "args": ["a", "i"]},
                "rhs": {"op": "faq", "output_idx": ["i"], "args": ["c"],
                        "ranges": {"i": {"from": "points"}},
                        "expr": {"op": op, "args": ["c"], "arg": "g",
                                 "ranges": {"g": {"from": "cands"}},
                                 "expr": {"op": "index", "args": ["c", "g"]}}}
            }]
        }}
    });
    let c: Vec<f64> = values.iter().map(decode).collect();
    let got = field_both(&doc, &[("c", c)], "a", label);
    assert_eq!(got.len(), 1);
    got[0]
}

#[test]
fn relational_template_scenarios_match_the_op() {
    let path = repo_root().join("tests/conformance/relational_templates/scenarios.json");
    let spec: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    for s in spec["scenarios"].as_array().unwrap() {
        let name = s["name"].as_str().unwrap();
        let op = s["op"].as_str().unwrap();
        let values = s["values"].as_array().unwrap();
        let expected = s["expected"].as_f64().unwrap();
        for (who, got) in ["interpreter", "native"]
            .iter()
            .zip(template_values(op, values, name))
        {
            assert_eq!(
                got.to_bits(),
                expected.to_bits(),
                "{name} ({who}): template gives {got:?}, expected {expected}"
            );
        }
        let op_expected = s
            .get("op_expected")
            .and_then(Value::as_f64)
            .unwrap_or(expected);
        let got = op_value(op, values, name);
        assert_eq!(
            got, op_expected,
            "{name}: op gives {got}, expected {op_expected}"
        );
    }
}

fn rename(e: &Value, from: &str, to: &str) -> Value {
    match e {
        Value::String(s) if s == from => Value::String(to.to_string()),
        Value::Array(a) => Value::Array(a.iter().map(|x| rename(x, from, to)).collect()),
        Value::Object(o) => Value::Object(
            o.iter()
                .map(|(k, v)| (k.clone(), rename(v, from, to)))
                .collect(),
        ),
        other => other.clone(),
    }
}

/// Each `argmin`/`argmax` node (no `join`/`filter`) becomes the template:
/// the op's `arg` renamed to the template's loop symbol, n the size of its
/// candidate set.
fn to_template(e: &Value, index_sets: &Value) -> Value {
    match e {
        Value::Object(o)
            if matches!(
                o.get("op").and_then(Value::as_str),
                Some("argmin" | "argmax")
            ) =>
        {
            assert!(!o.contains_key("join") && !o.contains_key("filter"));
            let op = o["op"].as_str().unwrap();
            let arg = o["arg"].as_str().unwrap();
            let ranges = o["ranges"].as_object().unwrap();
            assert_eq!(ranges.len(), 1);
            let set = ranges[arg]["from"].as_str().unwrap();
            let n = index_sets[set]["size"].as_u64().unwrap();
            json!({"op": "apply_expression_template", "args": [], "name": op,
                   "bindings": {"f": rename(&o["expr"], arg, &format!("k_{op}_1")), "n": n}})
        }
        Value::Object(o) => Value::Object(
            o.iter()
                .map(|(k, v)| (k.clone(), to_template(v, index_sets)))
                .collect(),
        ),
        Value::Array(a) => Value::Array(a.iter().map(|x| to_template(x, index_sets)).collect()),
        other => other.clone(),
    }
}

/// The fixture's model with only its arg-witness equations kept, each
/// rewritten as the template.
fn template_document(rel: &str, model: &str) -> Value {
    let text = std::fs::read_to_string(common::repo_fixture(rel)).unwrap();
    let mut doc: Value = serde_json::from_str(&text).unwrap();
    let isets = doc["index_sets"].clone();
    let m = doc["models"][model].clone();
    let equations: Vec<Value> = m["equations"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|eq| eq["rhs"].to_string().contains("\"argm"))
        .map(|eq| json!({"lhs": eq["lhs"], "rhs": to_template(&eq["rhs"], &isets)}))
        .collect();
    let mut model_out = m.clone();
    model_out["equations"] = Value::Array(equations);
    model_out["expression_template_imports"] = json!([{"ref": library()}]);
    if let Some(vars) = model_out["variables"].as_object_mut() {
        vars.retain(|k, _| !matches!(k.as_str(), "num" | "den" | "centroid"));
    }
    doc["models"] = json!({ model: model_out });
    doc
}

/// Caller arrays by name.
type Arrays = Vec<(&'static str, Vec<f64>)>;

#[test]
fn nearest_generator_fixtures_rewritten_as_the_template_give_the_op_buffer() {
    let generators = [("gx", vec![0., 1., 2.]), ("gy", vec![0., 0., 0.])];
    let cases: Vec<(&str, &str, Arrays, Vec<f64>)> = vec![
        (
            "valid/faq/nearest_generator_argmin.esm",
            "NearestGeneratorArgmin",
            [
                generators.to_vec(),
                vec![("px", vec![0., 1., 1.5, 2.]), ("py", vec![0., 0.5, 0., 0.])],
            ]
            .concat(),
            vec![1., 2., 2., 3.],
        ),
        (
            "valid/faq/nearest_generator_argmin.esm",
            "NearestGeneratorArgmin",
            [
                generators.to_vec(),
                vec![
                    ("px", vec![2., 0.5, 0.5, 1.5]),
                    ("py", vec![0., 0., 1., -0.5]),
                ],
            ]
            .concat(),
            vec![3., 1., 1., 2.],
        ),
        (
            "valid/faq/nearest_generator_centroid.esm",
            "NearestGeneratorCentroid",
            vec![
                ("gx", vec![0., 1., 2.]),
                ("px", vec![0., 0.75, 1.25, 2.]),
                ("rho", vec![1., 1., 3., 4.]),
            ],
            vec![1., 2., 2., 3.],
        ),
    ];
    for (rel, model, arrays, want) in cases {
        let text = std::fs::read_to_string(common::repo_fixture(rel)).unwrap();
        let mut op_doc: Value = serde_json::from_str(&text).unwrap();
        let only_model = op_doc["models"][model].clone();
        op_doc["models"] = json!({ model: only_model });
        let label = format!("{rel} {model}");
        assert_eq!(
            field_both(&op_doc, &arrays, "assign", &label),
            want,
            "{label}: op"
        );
        let t_doc = template_document(rel, model);
        assert_eq!(
            field_both(&t_doc, &arrays, "assign", &label),
            want,
            "{label}: template"
        );
    }
}
