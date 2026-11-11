//! The `argmin` / `argmax` templates of `lib/relational.esm`.
//!
//! Every scenario of `tests/conformance/relational_templates/scenarios.json`
//! runs through the expanded template, under the interpreter and the strict
//! native tape, and must give the scenario's `expected` 1-based index. The
//! nearest-generator fixtures give the expected assignment buffer under both
//! compilers.

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
        "esm": "2.0.0",
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

#[test]
fn relational_template_scenarios_give_the_expected_index() {
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
    }
}

/// Caller arrays by name.
type Arrays = Vec<(&'static str, Vec<f64>)>;

#[test]
fn nearest_generator_fixtures_give_the_assignment_buffer() {
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
        let mut doc: Value = serde_json::from_str(&text).unwrap();
        let only_model = doc["models"][model].clone();
        doc["models"] = json!({ model: only_model });
        let label = format!("{rel} {model}");
        assert_eq!(field_both(&doc, &arrays, "assign", &label), want, "{label}");
    }
}
