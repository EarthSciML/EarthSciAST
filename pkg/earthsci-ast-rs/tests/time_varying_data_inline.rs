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
    AssertionResult, BuildProviderFactory, DataProvider, EsmFile, InlineTestOptions, ProviderError,
    SolveOptions, load_path, load_string, run_inline_tests_with_options,
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
    let make: Arc<BuildProviderFactory<'static>> = Arc::new(move || {
        Ok(vec![(
            key.to_string(),
            Box::new(Records { pair, last: None }) as Box<dyn DataProvider>,
        )])
    });
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
            "tests": [at("half_past_one", 1.5 * HOUR, &[("y", 11.0)])]
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
    assert_all_pass(&run_file(&file, "Data.Q", true));
}
