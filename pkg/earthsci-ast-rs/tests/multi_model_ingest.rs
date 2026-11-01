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
    AxisSel, Compiler, GateAxis, InlineTestOptions, PrepareError, PrepareProvider, ProblemOptions,
    ProviderGate, esm_problem, load_string, observed_field, run_inline_tests_with_options,
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

// --------------------------------------------------------------------------- //
// Names in the whole-document build are spelled `Model.var`: provider keys,
// gate targets, supplied arrays and scalar overrides all reach them by that
// spelling, and a bare key reaches one only when it names exactly one.
// --------------------------------------------------------------------------- //

/// A provider that declares a gate on the derived set `cells` and serves the
/// slab `full`, fetched pre-sliced to the invented members.
struct MockGated {
    full: Vec<f64>,
}

impl PrepareProvider for MockGated {
    fn sample(&mut self) -> Result<ArrayD<f64>, PrepareError> {
        Ok(ArrayD::from_shape_vec(IxDyn(&[self.full.len()]), self.full.clone()).unwrap())
    }

    fn supports_selection(&self) -> bool {
        true
    }

    fn sample_with_selection(
        &mut self,
        selection: &[AxisSel],
    ) -> Result<ArrayD<f64>, PrepareError> {
        let AxisSel::Indices(idx) = &selection[0] else {
            return Err(PrepareError("expected an index selection".to_string()));
        };
        let v: Vec<f64> = idx.iter().map(|&i| self.full[i]).collect();
        Ok(ArrayD::from_shape_vec(IxDyn(&[v.len()]), v).unwrap())
    }

    fn gate_spec(&self) -> Option<ProviderGate> {
        Some(ProviderGate {
            axes: vec![GateAxis::GatedBy("cells".to_string())],
            applies_to: vec!["sr".to_string()],
        })
    }
}

/// A model that invents the cell set `cells` from the ids `[1, 3, 1, 1]`
/// (members `[1, 3]`) and sums a gated data-fed parameter `sr` over it.
fn gated_model() -> Value {
    json!({
        "variables": {
            "cell_id": {"type": "unknown", "units": "1", "shape": ["rows4"]},
            "present": {"type": "unknown", "units": "1", "shape": ["cells"]},
            "sr": {
                "type": "parameter", "units": "1", "default": 0.0,
                "shape": ["cells"],
                "update": {"kind": "data", "source": "src", "from": {"file_variable": "sr"}}
            },
            "total_sr": {"type": "unknown", "units": "1"}
        },
        "equations": [
            {"lhs": "cell_id",
             "rhs": {"op": "const", "args": [], "value": [1, 3, 1, 1]}},
            {"lhs": {"op": "index", "args": ["present", "e"]},
             "rhs": {"op": "faq", "id": "cell_set", "args": [],
                     "semiring": "bool_and_or", "distinct": true,
                     "output_idx": ["e"], "ranges": {"n": {"from": "rows4"}},
                     "key": {"op": "skolem", "label": "cell",
                             "args": [{"op": "index", "args": ["cell_id", "n"]}]},
                     "filter": {"op": "true", "args": []},
                     "expr": {"op": "true", "args": []}}},
            {"lhs": "total_sr",
             "rhs": {"op": "faq", "args": [], "semiring": "sum_product", "output_idx": [],
                     "ranges": {"e": {"from": "cells"}},
                     "expr": {"op": "index", "args": ["sr", "e"]}}}
        ]
    })
}

/// A gated slab binds under the name the flattened expressions read
/// (`Gated.sr`), and the observed reading it is evaluated after the fetch, so
/// it sums the fetched cells (`10 + 30`) rather than the inline default.
#[test]
fn a_gated_slab_binds_under_its_qualified_name_in_a_whole_document_build() {
    let mut doc = document(json!({"Gated": gated_model(), "Bystander": bystander(false)}));
    doc["index_sets"]["rows4"] = json!({"kind": "interval", "size": 4});
    doc["index_sets"]["cells"] = json!({"kind": "derived", "from_faq": "cell_set"});
    let file = load_string(&doc.to_string()).unwrap();
    let prob = esm_problem(
        &file,
        (0.0, 0.0),
        ProblemOptions {
            compiler: Some(Compiler::Interpreter),
            build_providers: vec![(
                "Gated.sr".to_string(),
                Box::new(MockGated {
                    full: vec![10.0, 20.0, 30.0, 40.0],
                }) as Box<dyn PrepareProvider>,
            )],
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("did not build: {e}"));
    let total = observed_field(&prob, "Gated.total_sr").unwrap();
    assert_eq!(total.iter().copied().collect::<Vec<_>>(), vec![40.0]);
}

/// Two models, each with a scalar parameter `k` and an observed `y = k`.
fn scalar_k_model(k: f64) -> Value {
    json!({
        "variables": {
            "k": {"type": "parameter", "units": "1", "default": k},
            "y": {"type": "unknown", "units": "1"}
        },
        "equations": [{"lhs": "y", "rhs": "k"}]
    })
}

fn build_with_p(doc: &Value, p: &[(&str, f64)]) -> Result<earthsci_ast::EsmProblem, String> {
    let file = load_string(&doc.to_string()).map_err(|e| e.to_string())?;
    esm_problem(
        &file,
        (0.0, 0.0),
        ProblemOptions {
            compiler: Some(Compiler::Interpreter),
            build_pipeline: true,
            p: p.iter().map(|(k, v)| ((*k).to_string(), *v)).collect(),
            ..Default::default()
        },
    )
    .map_err(|e| e.to_string())
}

fn scalar(prob: &earthsci_ast::EsmProblem, name: &str) -> f64 {
    observed_field(prob, name)
        .unwrap_or_else(|e| panic!("{name}: {e}"))
        .iter()
        .copied()
        .next()
        .unwrap()
}

/// A bare override key that two models' parameters answer to is refused,
/// naming both qualified spellings, rather than applied to both.
#[test]
fn a_bare_override_naming_two_models_parameters_is_refused() {
    let doc = document(json!({"A": scalar_k_model(1.0), "B": scalar_k_model(1.0)}));
    let msg = match build_with_p(&doc, &[("k", 2.0)]) {
        Ok(prob) => panic!(
            "built, with A.y = {} and B.y = {}",
            scalar(&prob, "A.y"),
            scalar(&prob, "B.y")
        ),
        Err(e) => e,
    };
    assert!(
        msg.contains("qualify it as one of") && msg.contains("A.k") && msg.contains("B.k"),
        "{msg}"
    );
}

/// A bare key one model's parameter answers to still reaches it, and a
/// qualified key reaches only its own model.
#[test]
fn a_bare_override_naming_one_parameter_and_a_qualified_one_still_apply() {
    let mut other = scalar_k_model(1.0);
    other["variables"]["m"] = other["variables"]["k"].take();
    other["variables"].as_object_mut().unwrap().remove("k");
    other["equations"][0]["rhs"] = json!("m");
    let doc = document(json!({"A": scalar_k_model(1.0), "B": other}));
    let prob = build_with_p(&doc, &[("k", 2.0)]).unwrap();
    assert_eq!((scalar(&prob, "A.y"), scalar(&prob, "B.y")), (2.0, 1.0));

    let doc = document(json!({"A": scalar_k_model(1.0), "B": scalar_k_model(1.0)}));
    let prob = build_with_p(&doc, &[("A.k", 3.0)]).unwrap();
    assert_eq!((scalar(&prob, "A.y"), scalar(&prob, "B.y")), (3.0, 1.0));
}

/// `ingesting_model` with `p` given inline rather than read from a source.
fn inline_p_model() -> Value {
    let mut m = ingesting_model();
    m["variables"]["p"]
        .as_object_mut()
        .unwrap()
        .remove("update");
    m
}

fn build_with_arrays(
    doc: &Value,
    key: &str,
    build_pipeline: bool,
) -> Result<earthsci_ast::EsmProblem, String> {
    let file = load_string(&doc.to_string()).map_err(|e| e.to_string())?;
    esm_problem(
        &file,
        (0.0, 0.0),
        ProblemOptions {
            compiler: Some(Compiler::Interpreter),
            build_pipeline,
            const_arrays: [(
                key.to_string(),
                ArrayD::from_shape_vec(IxDyn(&[2]), vec![3.0, 5.0]).unwrap(),
            )]
            .into_iter()
            .collect(),
            ..Default::default()
        },
    )
    .map_err(|e| e.to_string())
}

/// A bare `const_arrays` key that only one model's shaped parameter answers to
/// reaches it in the whole-document build, so the build-time observeds read
/// the caller's array, as the compiled model does.
#[test]
fn a_bare_const_array_key_reaches_the_one_parameter_it_names() {
    let doc = document(json!({"Ingest": inline_p_model(), "Bystander": bystander(true)}));
    let prob = build_with_arrays(&doc, "p", true).unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(scalar(&prob, "Ingest.total"), 8.0);
    assert_eq!(scalar(&prob, "Bystander.cross"), 10.0);
}

/// A document of several models given only `const_arrays` reads them the
/// same way whether or not the build pipeline is asked for.
#[test]
fn const_arrays_on_several_models_agree_with_and_without_the_pipeline() {
    let doc = document(json!({"Ingest": inline_p_model(), "Bystander": bystander(true)}));
    for key in ["p", "Ingest.p"] {
        for pipeline in [false, true] {
            let prob = build_with_arrays(&doc, key, pipeline)
                .unwrap_or_else(|e| panic!("{key}, pipeline {pipeline}: {e}"));
            assert_eq!(
                (
                    scalar(&prob, "Ingest.total"),
                    scalar(&prob, "Bystander.cross")
                ),
                (8.0, 10.0),
                "{key}, pipeline {pipeline}"
            );
        }
    }
}
