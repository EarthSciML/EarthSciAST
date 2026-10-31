//! A document whose build ingests data may hold more than one model.
//!
//! The build pipeline — the route every document with a `kind: data`
//! parameter (or a caller's `build_providers` / `const_arrays`) takes — picked
//! ONE model, defaulted to the only one, and refused a document of several
//! with none selected: `document holds several models; pass model_name`. So
//! the day a two-model document ingested anything, every assertion in it
//! errored, including assertions on a model that reads no data, after
//! `validate` had passed. Every other route builds such a document WHOLE (the
//! compile path and the state-free static evaluation `flatten` it, and so do
//! the Julia and Python `esm_problem`), and now this one does too: one
//! dot-namespaced system, `Model.var`, with a cross-model reference bound the
//! way the flattener binds it.
//!
//! An explicit `model_name` still builds that model alone, with names in its
//! own scope — the control below pins that it is unchanged.

#![cfg(not(target_arch = "wasm32"))]

use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};

use earthsci_ast::{
    Compiler, InlineTestOptions, PrepareError, PrepareProvider, ProblemOptions, esm_problem,
    load_string, observed_field, run_inline_tests_with_options,
};

struct MockConst(Vec<f64>);

impl PrepareProvider for MockConst {
    fn sample(&mut self) -> Result<ArrayD<f64>, PrepareError> {
        Ok(ArrayD::from_shape_vec(IxDyn(&[self.0.len()]), self.0.clone()).unwrap())
    }
}

/// A model with one data-fed column `p` over `rows` and its sum `total`.
fn ingesting_model() -> Value {
    json!({
        "variables": {
            "p": {
                "type": "parameter", "units": "1", "default": 0.0,
                "shape": ["rows"],
                "update": {"kind": "data", "source": "src", "from": {"file_variable": "p"}}
            },
            "total": {"type": "unknown", "units": "1"}
        },
        "equations": [{
            "lhs": "total",
            "rhs": {
                "op": "faq", "args": [], "semiring": "sum_product", "output_idx": [],
                "ranges": {"r": {"from": "rows"}},
                "expr": {"op": "index", "args": ["p", "r"]}
            }
        }],
        "tests": [{
            "id": "reads_its_column",
            "time_span": {"start": 0.0, "end": 0.0},
            "assertions": [{"variable": "total", "time": 0.0, "expected": 8.0}]
        }]
    })
}

/// `1 + 1`, plus `cross = Ingest.total + two` when `cross` is set: a model
/// that reads no data, and optionally names a sibling's variable.
fn bystander(cross: bool) -> Value {
    let mut m = json!({
        "variables": {"two": {"type": "unknown", "units": "1"}},
        "equations": [{
            "lhs": "two",
            "rhs": {"op": "+", "args": [
                {"op": "const", "args": [], "value": 1.0},
                {"op": "const", "args": [], "value": 1.0}
            ]}
        }],
        "tests": [{
            "id": "arithmetic",
            "time_span": {"start": 0.0, "end": 0.0},
            "assertions": [{"variable": "two", "time": 0.0, "expected": 2.0}]
        }]
    });
    if cross {
        m["variables"]["cross"] = json!({"type": "unknown", "units": "1"});
        m["equations"].as_array_mut().unwrap().push(json!({
            "lhs": "cross",
            "rhs": {"op": "+", "args": ["Ingest.total", "two"]}
        }));
        m["tests"][0]["assertions"]
            .as_array_mut()
            .unwrap()
            .push(json!({"variable": "cross", "time": 0.0, "expected": 10.0}));
    }
    m
}

fn document(models: Value) -> Value {
    json!({
        "esm": "1.2.0",
        "metadata": {"name": "multi_model_ingest"},
        "index_sets": {"rows": {"kind": "interval", "size": 2}},
        "data_sources": {
            "src": {"kind": "static", "source": {"url_template": "never-read.parquet"}}
        },
        "models": models
    })
}

type Providers = Vec<(String, Box<dyn PrepareProvider>)>;

fn providers(cols: &[(&str, &[f64])]) -> Providers {
    cols.iter()
        .map(|(k, v)| {
            (
                (*k).to_string(),
                Box::new(MockConst(v.to_vec())) as Box<dyn PrepareProvider>,
            )
        })
        .collect()
}

/// Build `doc` (with `model_name`, if any) and read each of `vars`.
fn build_and_read(
    doc: &Value,
    model_name: Option<&str>,
    cols: &[(&str, &[f64])],
    vars: &[&str],
) -> Result<Vec<f64>, String> {
    let file = load_string(&doc.to_string()).map_err(|e| e.to_string())?;
    let prob = esm_problem(
        &file,
        (0.0, 0.0),
        ProblemOptions {
            compiler: Some(Compiler::Interpreter),
            model_name: model_name.map(str::to_string),
            build_providers: providers(cols),
            ..Default::default()
        },
    )
    .map_err(|e| e.to_string())?;
    vars.iter()
        .map(|var| {
            let arr = observed_field(&prob, var).map_err(|e| e.to_string())?;
            arr.iter()
                .next()
                .copied()
                .ok_or_else(|| format!("{var} evaluated to an empty field"))
        })
        .collect()
}

/// The finding: two models, one ingesting, none selected. Both build.
#[test]
fn an_ingesting_document_of_two_models_builds_both() {
    let doc = document(json!({"Ingest": ingesting_model(), "Bystander": bystander(false)}));
    let got = build_and_read(
        &doc,
        None,
        &[("Ingest.p", &[3.0, 5.0])],
        &["Ingest.total", "Bystander.two"],
    )
    .unwrap_or_else(|e| panic!("the two-model ingesting document did not build: {e}"));
    assert_eq!(got, vec![8.0, 2.0]);
}

/// A sibling's name resolves as the flattener resolves it: `Ingest.total`
/// inside `Bystander` is the ingesting model's sum.
#[test]
fn a_cross_model_reference_reads_the_ingested_value() {
    let doc = document(json!({"Ingest": ingesting_model(), "Bystander": bystander(true)}));
    let got = build_and_read(
        &doc,
        None,
        &[("Ingest.p", &[3.0, 5.0])],
        &["Bystander.cross"],
    )
    .unwrap_or_else(|e| panic!("did not build: {e}"));
    assert_eq!(got, vec![10.0]);
}

/// Two models each ingesting a same-named parameter keep their own columns:
/// each provider key is the flattened name it feeds.
#[test]
fn same_named_data_parameters_in_two_models_keep_their_own_columns() {
    let doc = document(json!({"A": ingesting_model(), "B": ingesting_model()}));
    let got = build_and_read(
        &doc,
        None,
        &[("A.p", &[3.0, 5.0]), ("B.p", &[100.0, 200.0])],
        &["A.total", "B.total"],
    )
    .unwrap_or_else(|e| panic!("did not build: {e}"));
    assert_eq!(got, vec![8.0, 300.0]);
}

/// Control, unchanged by the fix: an explicit selection builds that model
/// alone, its names model-local.
#[test]
fn an_explicit_model_name_still_builds_that_model_alone() {
    let doc = document(json!({"Ingest": ingesting_model(), "Bystander": bystander(true)}));
    let got = build_and_read(
        &doc,
        Some("Ingest"),
        &[("Ingest.p", &[3.0, 5.0])],
        &["total"],
    )
    .unwrap_or_else(|e| panic!("did not build: {e}"));
    assert_eq!(got, vec![8.0]);
}

/// Through the inline-test runner, the route `esm test` takes: every
/// assertion of both models passes, including the one on the model that
/// reads no data and the cross-model one.
#[test]
fn every_inline_assertion_of_a_two_model_ingesting_document_passes() {
    let doc = document(json!({"Ingest": ingesting_model(), "Bystander": bystander(true)}));
    let file = load_string(&doc.to_string()).unwrap();
    let factory = || -> Result<Providers, String> { Ok(providers(&[("Ingest.p", &[3.0, 5.0])])) };
    let results = run_inline_tests_with_options(
        &file,
        &InlineTestOptions {
            compiler: Some(Compiler::Interpreter),
            ..Default::default()
        },
        Some(&factory),
    );
    assert_eq!(results.len(), 3, "{results:#?}");
    for r in &results {
        assert!(
            r.passed,
            "{}/{} `{}`: {}",
            r.model, r.test_id, r.variable, r.message
        );
    }
}
