//! Inline tests over a parameter fed by a TIME-VARYING data source, through
//! the provider path `esm test` takes for a document's `data_sources`.
//!
//! A parameter shaped over a record axis (`"records": true`, esm-spec §8.5.1)
//! receives the pair of records bracketing `t`; a parameter with no shape
//! receives the record at or before `t`. The build pipeline used to evaluate
//! every observed that reads no state at build time, against a scope holding
//! only the CONST providers' data, so an unknown defined from a record-shaped
//! data-fed parameter (`y ~ Q[1]`) failed with `E_TREEWALK_UNBOUND_NAME: 'Q'`,
//! and a state-free document fed by such a source could not be built at all
//! (`providers require an array/spatial model`). A document with nothing to
//! integrate is now built at its test's `time_span.start` with the record in
//! effect there, and one with state reads the parameter at run time.

#![cfg(not(target_arch = "wasm32"))]

use std::sync::Arc;

use earthsci_ast::{
    AssertionResult, BuildProviderFactory, DataProvider, EsmFile, GateAxis, InlineTestOptions,
    ProblemOptions, ProviderError, ProviderGate, SolveOptions, esm_problem, load_path, load_string,
    observed_field, run_inline_tests_with_options,
};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};

/// The records, one an hour from t = 0.
const RECORDS: [f64; 4] = [10.0, 11.0, 12.0, 13.0];
const HOUR: f64 = 3600.0;

/// A time-varying source of [`RECORDS`]: with `pair`, the record at or before
/// `t` and the next one (a record-shaped parameter's delivery), else the
/// record at or before `t` alone. Answers `None` while the record in effect
/// has not changed since its last delivery, as a real provider does.
struct Records {
    pair: bool,
    last: Option<usize>,
}

impl Records {
    fn field(&self, k: usize) -> ArrayD<f64> {
        if self.pair {
            let next = RECORDS[(k + 1).min(RECORDS.len() - 1)];
            ArrayD::from_shape_vec(IxDyn(&[2]), vec![RECORDS[k], next]).unwrap()
        } else {
            ArrayD::from_elem(IxDyn(&[]), RECORDS[k])
        }
    }
}

impl DataProvider for Records {
    fn sample(&mut self) -> Result<ArrayD<f64>, ProviderError> {
        Ok(self.field(0))
    }

    fn refresh(&mut self, t: f64) -> Result<Option<ArrayD<f64>>, ProviderError> {
        let in_effect = self.refresh_times().iter().rposition(|&b| b <= t);
        match in_effect {
            Some(k) if self.last != Some(k) => {
                self.last = Some(k);
                Ok(Some(self.field(k)))
            }
            _ => Ok(None),
        }
    }

    fn refresh_times(&self) -> Vec<f64> {
        (0..RECORDS.len()).map(|k| k as f64 * HOUR).collect()
    }
}

/// One model reading `M.Q` from an hourly source: `y ~ Q[1]` and
/// `z ~ Q[2]` when `shaped` (Q over the record axis), else `y ~ Q`; with
/// `state`, also `D(x) ~ y` from `x(0) = 0`.
fn document(shaped: bool, state: bool, tests: Value) -> Value {
    let mut q = json!({
        "type": "parameter", "units": "1", "default": 0.0,
        "update": {"kind": "data", "source": "hourly", "from": {"file_variable": "Q"}}
    });
    let mut variables = json!({"y": {"type": "unknown", "units": "1"}});
    let mut equations = vec![];
    if shaped {
        q["shape"] = json!(["rec"]);
        variables["z"] = json!({"type": "unknown", "units": "1"});
        equations.push(json!({"lhs": "y", "rhs": {"op": "index", "args": ["Q", 1]}}));
        equations.push(json!({"lhs": "z", "rhs": {"op": "index", "args": ["Q", 2]}}));
    } else {
        equations.push(json!({"lhs": "y", "rhs": "Q"}));
    }
    if state {
        variables["x"] = json!({"type": "unknown", "units": "1", "default": 0.0});
        equations.push(json!({"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": "y"}));
    }
    variables["Q"] = q;
    json!({
        "esm": "2.0.0",
        "metadata": {"name": "time_varying_data_inline"},
        "domain": {"temporal": {"reference_time": "2000-01-01T00:00:00Z"}},
        "index_sets": {"rec": {"kind": "interval", "size": 2, "records": true}},
        "data_sources": {"hourly": {
            "kind": "grid",
            "source": {"url_template": "never-read.nc"},
            "temporal": {"start": "2000-01-01T00:00:00Z", "end": "2000-01-01T03:00:00Z",
                         "file_period": "P1D", "frequency": "PT1H"}
        }},
        "models": {"M": {"variables": variables, "equations": equations, "tests": tests}}
    })
}

/// A test evaluated at the single time `at`, asserting `expected`.
fn at(id: &str, at: f64, expected: &[(&str, f64)]) -> Value {
    span(id, at, at, at, expected)
}

/// A test over `[start, end]` asserting `expected` at `at`.
fn span(id: &str, start: f64, end: f64, at: f64, expected: &[(&str, f64)]) -> Value {
    json!({
        "id": id,
        "time_span": {"start": start, "end": end},
        "tolerance": {"rel": 1e-9},
        "assertions": expected.iter()
            .map(|(v, e)| json!({"variable": v, "time": at, "expected": e}))
            .collect::<Vec<_>>()
    })
}

fn run(doc: &Value, pair: bool) -> Vec<AssertionResult> {
    run_file(
        &load_string(&doc.to_string()).expect("document loads"),
        "M.Q",
        pair,
    )
}

fn run_file(file: &EsmFile, key: &'static str, pair: bool) -> Vec<AssertionResult> {
    run_with(
        file,
        Arc::new(move || {
            Ok(vec![(
                key.to_string(),
                Box::new(Records { pair, last: None }) as Box<dyn DataProvider>,
            )])
        }),
    )
}

fn run_with(file: &EsmFile, make: Arc<BuildProviderFactory<'static>>) -> Vec<AssertionResult> {
    run_inline_tests_with_options(
        file,
        &InlineTestOptions {
            solve: SolveOptions {
                reltol: Some(1e-10),
                abstol: Some(1e-12),
                ..Default::default()
            },
            providers: Some(make),
            ..Default::default()
        },
    )
}

fn assert_all_pass(results: &[AssertionResult]) {
    assert!(!results.is_empty());
    for r in results {
        assert!(
            r.passed,
            "{}[{}] {}: {} (actual {:?}, expected {})",
            r.test_id, r.assertion_idx, r.variable, r.message, r.actual, r.expected
        );
    }
}

/// The reported bug: `y ~ Q[1]` with `Q` over the record axis. At 00:30 the
/// pair is records 0 and 1; at 01:30, records 1 and 2.
#[test]
fn a_record_shaped_parameter_reaches_the_unknowns_it_defines() {
    let doc = document(
        true,
        false,
        json!([
            at(
                "half_past_midnight",
                0.5 * HOUR,
                &[("y", 10.0), ("z", 11.0)]
            ),
            at("half_past_one", 1.5 * HOUR, &[("y", 11.0), ("z", 12.0)]),
        ]),
    );
    assert_all_pass(&run(&doc, true));
}

/// The shapeless counterpart receives the record at or before `t`.
#[test]
fn a_shapeless_parameter_gives_the_record_in_effect() {
    let doc = document(
        false,
        false,
        json!([
            at("half_past_midnight", 0.5 * HOUR, &[("y", 10.0)]),
            at("on_the_hour", 2.0 * HOUR, &[("y", 12.0)]),
        ]),
    );
    assert_all_pass(&run(&doc, false));
}

/// A state-free document's fields are the record in effect at
/// `time_span.start`: an assertion later in the span is refused by name,
/// never answered with the value at the start.
#[test]
fn a_state_free_assertion_away_from_the_start_is_refused() {
    let doc = document(
        true,
        false,
        json!([span("later", 0.0, 2.0 * HOUR, 1.5 * HOUR, &[("y", 11.0)])]),
    );
    let results = run(&doc, true);
    assert_eq!(results.len(), 1);
    let r = &results[0];
    assert!(!r.passed && r.actual.is_none(), "{r:?}");
    assert!(r.message.contains("is a function of `t`"), "{}", r.message);
}

/// The refusal the runner gives an assertion on a value a time-varying
/// source's record at `time_span.start` decided, asked later in the span.
fn assert_refused_as_pinned(r: &AssertionResult) {
    assert!(!r.passed && r.actual.is_none(), "{r:?}");
    assert!(
        r.message.contains("through a time-varying data source"),
        "{}",
        r.message
    );
}

/// A shapeless `Q` with `y ~ Q` is a scalar observed graph, which the runner
/// evaluates per asserted time rather than from the build's fields. That
/// graph holds the record in effect at the start too, so at 01:30 it would
/// answer 10, the record of 00:00: refused instead.
#[test]
fn a_static_graph_assertion_later_in_the_span_is_refused() {
    let doc = document(
        false,
        false,
        json!([span("later", 0.0, 2.0 * HOUR, 1.5 * HOUR, &[("y", 11.0)])]),
    );
    let results = run(&doc, false);
    assert_eq!(results.len(), 1);
    assert_refused_as_pinned(&results[0]);
}

/// The data-fed parameter itself is read from the build's ingested data,
/// which is the record in effect at `time_span.start`: asserted there it
/// passes, asserted later it is refused.
#[test]
fn an_assertion_on_the_data_fed_parameter_later_in_the_span_is_refused() {
    let doc = document(
        true,
        false,
        json!([
            at("at_the_start", 0.0, &[("Q[1]", 10.0), ("Q[2]", 11.0)]),
            span("later", 0.0, 2.0 * HOUR, 1.5 * HOUR, &[("Q[1]", 11.0)]),
        ]),
    );
    let results = run(&doc, true);
    assert_eq!(results.len(), 3, "{results:#?}");
    assert_all_pass(&results[..2]);
    assert_refused_as_pinned(&results[2]);
}

/// With nothing to integrate and no record yet in effect at the start (the
/// span starts half an hour before the first record), the parameter holds its
/// declared default, as it does at a solve's start (esm-spec §11.4.2).
#[test]
fn before_the_first_record_the_declared_default_holds() {
    let mut doc = document(
        false,
        false,
        json!([at("before_the_data", -0.5 * HOUR, &[("y", 5.0)])]),
    );
    doc["models"]["M"]["variables"]["Q"]["default"] = json!(5.0);
    assert_all_pass(&run(&doc, false));
}

/// ... and one that declares no default is refused, naming the parameter.
#[test]
fn before_the_first_record_a_parameter_without_a_default_is_refused() {
    let mut doc = document(
        false,
        false,
        json!([at("before_the_data", -0.5 * HOUR, &[("y", 5.0)])]),
    );
    doc["models"]["M"]["variables"]["Q"]
        .as_object_mut()
        .unwrap()
        .remove("default");
    let results = run(&doc, false);
    assert_eq!(results.len(), 1);
    let r = &results[0];
    assert!(!r.passed && r.actual.is_none(), "{r:?}");
    assert!(
        r.message.contains("no record in effect") && r.message.contains("declares no default"),
        "{}",
        r.message
    );
}

/// An hourly source of whole fields, `records[k]` from `k` hours, with an
/// optional gate of its own and an optional extent metaparameter.
struct Hourly {
    records: Vec<Vec<f64>>,
    last: Option<usize>,
    gate: Option<ProviderGate>,
    extent: Option<&'static str>,
}

impl Hourly {
    fn new(records: Vec<Vec<f64>>) -> Self {
        Hourly {
            records,
            last: None,
            gate: None,
            extent: None,
        }
    }

    fn field(&self, k: usize) -> ArrayD<f64> {
        let r = &self.records[k];
        ArrayD::from_shape_vec(IxDyn(&[r.len()]), r.clone()).unwrap()
    }
}

impl DataProvider for Hourly {
    fn sample(&mut self) -> Result<ArrayD<f64>, ProviderError> {
        Ok(self.field(0))
    }

    fn refresh(&mut self, t: f64) -> Result<Option<ArrayD<f64>>, ProviderError> {
        match self.refresh_times().iter().rposition(|&b| b <= t) {
            Some(k) if self.last != Some(k) => {
                self.last = Some(k);
                Ok(Some(self.field(k)))
            }
            _ => Ok(None),
        }
    }

    fn refresh_times(&self) -> Vec<f64> {
        (0..self.records.len()).map(|k| k as f64 * HOUR).collect()
    }

    fn gate_spec(&self) -> Option<ProviderGate> {
        self.gate.clone()
    }

    fn extent_metaparameter(&self) -> Option<String> {
        self.extent.map(str::to_string)
    }
}

/// `models` (and `extra` top-level members) over the hourly source.
fn hourly_document(models: Value, extra: Value) -> Value {
    let mut doc = document(false, false, json!([]));
    doc["models"] = models;
    for (k, v) in extra.as_object().unwrap() {
        doc[k] = v.clone();
    }
    doc
}

/// A state-free model that invents the cell set `cells` from the ids
/// `[1, 3, 1, 1]` (members 1 and 3) and sums the data-fed `sr` over it. `sr`
/// comes from a time-varying provider that gates on `cells`: the build
/// fetches the record in effect at the start, sliced to the members, so the
/// sum at 01:30 is `20 + 60`, not the sum of every cell of that record.
#[test]
fn a_gated_time_varying_source_is_sliced_to_its_gate() {
    let model = json!({
        "variables": {
            "cell_id": {"type": "unknown", "units": "1", "shape": ["rows4"]},
            "present": {"type": "unknown", "units": "1", "shape": ["cells"]},
            "sr": {
                "type": "parameter", "units": "1", "default": 0.0, "shape": ["cells"],
                "update": {"kind": "data", "source": "hourly", "from": {"file_variable": "sr"}}
            },
            "total_sr": {"type": "unknown", "units": "1"}
        },
        "equations": [
            {"lhs": "cell_id", "rhs": {"op": "const", "args": [], "value": [1, 3, 1, 1]}},
            {"lhs": {"op": "index", "args": ["present", "e"]},
             "rhs": {"op": "faq", "id": "cell_set", "args": [],
                     "semiring": "bool_and_or", "distinct": true,
                     "output_idx": ["e"], "ranges": {"n": {"from": "rows4"}},
                     "key": {"op": "index", "args": ["cell_id", "n"]},
                     "filter": {"op": "true", "args": []},
                     "expr": {"op": "true", "args": []}}},
            {"lhs": "total_sr",
             "rhs": {"op": "faq", "args": [], "semiring": "sum_product", "output_idx": [],
                     "ranges": {"e": {"from": "cells"}},
                     "expr": {"op": "index", "args": ["sr", "e"]}}}
        ],
        "tests": [at("half_past_one", 1.5 * HOUR, &[("total_sr", 80.0)])]
    });
    let doc = hourly_document(
        json!({"G": model}),
        json!({"index_sets": {
            "rows4": {"kind": "interval", "size": 4},
            "cells": {"kind": "derived", "from_faq": "cell_set"}
        }}),
    );
    let file = load_string(&doc.to_string()).expect("document loads");
    let results = run_with(
        &file,
        Arc::new(|| {
            let mut p = Hourly::new(
                (1..=3)
                    .map(|k| [10.0, 20.0, 30.0, 40.0].map(|v| v * k as f64).to_vec())
                    .collect(),
            );
            p.gate = Some(ProviderGate {
                axes: vec![GateAxis::GatedBy("cells".to_string())],
                applies_to: vec!["sr".to_string()],
            });
            Ok(vec![(
                "G.sr".to_string(),
                Box::new(p) as Box<dyn DataProvider>,
            )])
        }),
    );
    assert_all_pass(&results);
}

/// A state-free model whose record axis `recs` is sized by the metaparameter
/// `N`, which the time-varying provider's own extent closes (esm-spec §8.9):
/// three values per record, the second of record 1 read at 01:30.
#[test]
fn a_time_varying_source_closes_its_extent_metaparameter() {
    let model = json!({
        "variables": {
            "Q": {
                "type": "parameter", "units": "1", "default": 0.0, "shape": ["recs"],
                "update": {"kind": "data", "source": "hourly", "from": {"file_variable": "Q"}}
            },
            "y": {"type": "unknown", "units": "1"}
        },
        "equations": [{"lhs": "y", "rhs": {"op": "index", "args": ["Q", 2]}}],
    });
    let mut doc = hourly_document(
        json!({"M": model}),
        json!({
            "metaparameters": {"N": {"type": "integer", "default": 0}},
            "index_sets": {"recs": {"kind": "interval", "size": "N"}}
        }),
    );
    doc["data_sources"]["hourly"]["extent"] = json!({"metaparameter": "N"});
    let mut p = Hourly::new(
        (0..3)
            .map(|k| (1..=3).map(|i| (10 * k + i) as f64).collect())
            .collect(),
    );
    p.extent = Some("N");
    // The raw document: a typed load would fold `N` at its default first.
    let prob = esm_problem(
        &doc,
        (1.5 * HOUR, 1.5 * HOUR),
        ProblemOptions {
            build_pipeline: true,
            providers: [("M.Q".to_string(), Box::new(p) as Box<dyn DataProvider>)].into(),
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("did not build: {e}"));
    let y = observed_field(&prob, "y").unwrap();
    assert_eq!(y.iter().copied().collect::<Vec<_>>(), vec![12.0]);
}

/// A CONST source of one value.
struct Constant(f64);

impl DataProvider for Constant {
    fn sample(&mut self) -> Result<ArrayD<f64>, ProviderError> {
        Ok(ArrayD::from_elem(IxDyn(&[]), self.0))
    }
}

/// Two models each read a data-fed `Q`: `A.Q` hourly, `B.Q` constant. Each
/// key feeds its own model's `Q` only, so `B.y` holds at every time and is
/// answered later in the span, while `A.y` there is refused.
#[test]
fn a_provider_key_pins_only_the_parameter_it_designates() {
    let model = |tests: Value| {
        json!({
            "variables": {
                "Q": {
                    "type": "parameter", "units": "1", "default": 0.0,
                    "update": {"kind": "data", "source": "hourly", "from": {"file_variable": "Q"}}
                },
                "y": {"type": "unknown", "units": "1"}
            },
            "equations": [{"lhs": "y", "rhs": "Q"}],
            "tests": tests
        })
    };
    let later = |e: f64| json!([span("later", 0.0, 2.0 * HOUR, 1.5 * HOUR, &[("y", e)])]);
    let doc = hourly_document(
        json!({"A": model(later(11.0)), "B": model(later(7.0))}),
        json!({}),
    );
    let file = load_string(&doc.to_string()).expect("document loads");
    let results = run_with(
        &file,
        Arc::new(|| {
            Ok(vec![
                (
                    "A.Q".to_string(),
                    Box::new(Records {
                        pair: false,
                        last: None,
                    }) as Box<dyn DataProvider>,
                ),
                (
                    "B.Q".to_string(),
                    Box::new(Constant(7.0)) as Box<dyn DataProvider>,
                ),
            ])
        }),
    );
    assert_eq!(results.len(), 2, "{results:#?}");
    let of = |m: &str| results.iter().find(|r| r.model == m).unwrap();
    assert_refused_as_pinned(of("A"));
    assert_all_pass(std::slice::from_ref(of("B")));
}

/// With state, the record-shaped parameter is read at run time, refreshed
/// at each record: `D(x) ~ Q[1]` over two hours integrates 10 then 11.
#[test]
fn a_record_shaped_parameter_feeds_an_integrated_state() {
    let doc = document(
        true,
        true,
        json!([span(
            "two_hours",
            0.0,
            2.0 * HOUR,
            2.0 * HOUR,
            &[("x", (10.0 + 11.0) * HOUR)]
        )]),
    );
    assert_all_pass(&run(&doc, true));
}

/// The ingesting build re-parses the document; a relative `coupling_import`
/// still resolves against the importing document's directory (esm-spec
/// §10.10 -> §4.7), not the working directory.
#[test]
fn a_coupling_import_resolves_against_the_document_on_the_ingesting_build() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir(dir.path().join("lib")).unwrap();
    let mut doc = document(true, false, json!([]));
    let q = doc["models"]["M"]["variables"]["Q"].clone();
    doc["models"] = json!({
        "Data": {"variables": {"Q": q}, "equations": []},
        "Use": {
            "variables": {
                "q_rec": {"type": "parameter", "units": "1", "default": 0.0, "shape": ["rec"]},
                "y": {"type": "unknown", "units": "1"}
            },
            "equations": [{"lhs": "y", "rhs": {"op": "index", "args": ["q_rec", 1]}}],
            "tests": [
                at("half_past_one", 1.5 * HOUR, &[("y", 11.0)]),
                span("later", 0.0, 2.0 * HOUR, 1.5 * HOUR, &[("y", 11.0)])
            ]
        }
    });
    doc["coupling"] = json!([{"type": "coupling_import", "ref": "./lib/edges.esm",
                              "bind": {"Src": "Data", "Dst": "Use"}}]);
    let edges = json!({
        "esm": "2.0.0",
        "metadata": {"name": "edges"},
        "coupling_roles": {"Src": {"description": "data"}, "Dst": {"description": "consumer"}},
        "coupling": [{"type": "variable_map", "from": "Src.Q", "to": "Dst.q_rec",
                      "transform": "param_to_var"}]
    });
    std::fs::write(dir.path().join("doc.esm"), doc.to_string()).unwrap();
    std::fs::write(dir.path().join("lib/edges.esm"), edges.to_string()).unwrap();
    let file = load_path(dir.path().join("doc.esm")).expect("document loads");
    let results = run_file(&file, "Data.Q", true);
    assert_eq!(results.len(), 2, "{results:#?}");
    let of = |id: &str| results.iter().find(|r| r.test_id == id).unwrap();
    assert_all_pass(std::slice::from_ref(of("half_past_one")));
    // Fed through the imported edge, `y` still moves with the source.
    assert_refused_as_pinned(of("later"));
}
