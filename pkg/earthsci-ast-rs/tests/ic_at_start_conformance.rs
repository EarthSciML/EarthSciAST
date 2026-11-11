//! The `ic_at_start` conformance suite (`tests/conformance/ic_at_start/`;
//! esm-spec §11.4.2, CONFORMANCE_SPEC §5.56): an `ic` right-hand side is
//! evaluated once, at `tspan[0]`, and may read `t`, data-fed parameters at
//! their value there, shaped parameters and observeds over them, but no state.
//!
//! Each case builds its fixture with the case's `tspan`, `p`, providers and
//! `sample_time`, and checks the initial state against `expected` through the
//! public accessor and through a solve's first saved point, bit for bit
//! between the two; a refusal case checks the construction error's code.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;
use std::path::PathBuf;

use earthsci_ast::provider::{CadenceProvider, NativeField, ProviderError};
use earthsci_ast::{
    Compiler, ProblemOptions, SolveOptions, esm_problem, initial_state, remake, solve,
};
use ndarray::{ArrayD, IxDyn};
use serde_json::Value;

fn suite_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/ic_at_start")
        .canonicalize()
        .expect("suite directory")
}

fn floats(v: &Value) -> Vec<f64> {
    v.as_array()
        .expect("an array")
        .iter()
        .map(|x| x.as_f64().expect("a number"))
        .collect()
}

fn numbers(v: &Value) -> HashMap<String, f64> {
    v.as_object()
        .map(|o| {
            o.iter()
                .map(|(k, x)| (k.clone(), x.as_f64().expect("a number")))
                .collect()
        })
        .unwrap_or_default()
}

/// One field, `base + slope * t` elementwise (the manifest's `provider`).
struct Linear {
    key: String,
    times: Vec<f64>,
    shape: Vec<usize>,
    /// Row-major.
    base: Vec<f64>,
    slope: f64,
}

impl Linear {
    fn from_manifest(p: &Value) -> Self {
        fn flatten(v: &Value, out: &mut Vec<f64>) {
            match v {
                Value::Array(a) => a.iter().for_each(|x| flatten(x, out)),
                x => out.push(x.as_f64().expect("a number")),
            }
        }
        let mut base = Vec::new();
        flatten(&p["base"], &mut base);
        Linear {
            key: p["key"].as_str().unwrap().to_string(),
            times: floats(&p["refresh_times"]),
            shape: p["shape"]
                .as_array()
                .unwrap()
                .iter()
                .map(|d| d.as_u64().unwrap() as usize)
                .collect(),
            base,
            slope: p["slope"].as_f64().unwrap(),
        }
    }

    fn at(&self, t: f64) -> HashMap<String, NativeField> {
        let values = self.base.iter().map(|b| b + self.slope * t).collect();
        let a = ArrayD::from_shape_vec(IxDyn(&self.shape), values).expect("field");
        HashMap::from([(self.key.clone(), NativeField::new(a))])
    }
}

impl CadenceProvider for Linear {
    fn materialize(&mut self) -> Result<HashMap<String, NativeField>, ProviderError> {
        assert!(self.slope == 0.0, "only a const provider is materialized");
        Ok(self.at(0.0))
    }
    fn refresh(&mut self, t: f64) -> Result<Option<HashMap<String, NativeField>>, ProviderError> {
        Ok(Some(self.at(t)))
    }
    fn refresh_times(&self) -> Vec<f64> {
        self.times.clone()
    }
}

fn build(
    c: &Value,
    tspan: (f64, f64),
) -> Result<earthsci_ast::EsmProblem, earthsci_ast::SimulateError> {
    let providers: HashMap<String, Box<dyn CadenceProvider>> = c["providers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| {
            let p = Linear::from_manifest(p);
            (p.key.clone(), Box::new(p) as Box<dyn CadenceProvider>)
        })
        .collect();
    let path = suite_dir().join(c["fixture"].as_str().unwrap());
    esm_problem(
        path.as_path(),
        tspan,
        ProblemOptions {
            compiler: Some(Compiler::Native),
            providers,
            p: numbers(&c["p"]),
            sample_time: c["sample_time"].as_f64(),
            ..Default::default()
        },
    )
}

fn manifest() -> Value {
    serde_json::from_str(&std::fs::read_to_string(suite_dir().join("manifest.json")).unwrap())
        .unwrap()
}

#[test]
fn ic_at_start_conformance() {
    let m = manifest();
    assert_eq!(m["category"].as_str(), Some("ic_at_start"));
    let rtol = m["tolerances"]["rtol"].as_f64().unwrap();
    let atol = m["tolerances"]["atol"].as_f64().unwrap();
    let cases = m["cases"].as_array().unwrap();
    assert!(cases.len() >= 10, "the manifest must not go vacuous");
    for c in cases {
        let id = c["id"].as_str().unwrap();
        let tspan = floats(&c["tspan"]);
        let tspan = (tspan[0], tspan[1]);
        if let Some(code) = c["error_code"].as_str() {
            let err = match build(c, tspan).and_then(|p| initial_state(&p).map(|_| ())) {
                Ok(()) => panic!("{id}: expected the refusal {code}, but the Problem built"),
                Err(e) => e.to_string(),
            };
            assert!(err.contains(code), "{id}: expected {code}, got: {err}");
            continue;
        }
        let prob = build(c, tspan).unwrap_or_else(|e| panic!("{id}: builds: {e}"));
        let u0 = initial_state(&prob).unwrap_or_else(|e| panic!("{id}: initial state: {e}"));
        let names = prob.state_variable_names();
        let expected = numbers(&c["expected"]);
        let got: HashMap<&str, f64> = names
            .iter()
            .map(String::as_str)
            .zip(u0.iter().copied())
            .collect();
        let mut want_names: Vec<&String> = expected.keys().collect();
        let mut got_names: Vec<&&str> = got.keys().collect();
        want_names.sort();
        got_names.sort();
        assert_eq!(
            got_names.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
            want_names.iter().map(|s| s.to_string()).collect::<Vec<_>>(),
            "{id}: the state elements"
        );
        for (n, want) in &expected {
            let v = got[n.as_str()];
            assert!(
                (v - want).abs() <= atol + rtol * want.abs(),
                "{id}: {n} = {v}, expected {want}"
            );
        }
        // The state a solve starts from, after the accessor ran.
        let sol = solve(
            &prob,
            &SolveOptions {
                saveat: Some(vec![tspan.0]),
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("{id}: solve: {e}"));
        for (k, n) in names.iter().enumerate() {
            assert_eq!(
                sol.state[k][0].to_bits(),
                u0[k].to_bits(),
                "{id}: {n}: the accessor and the solve's initial state differ"
            );
        }
        // After a solve the forcing buffer holds a later record; the initial
        // state still reads the record at tspan[0].
        let again = initial_state(&prob).unwrap_or_else(|e| panic!("{id}: again: {e}"));
        assert_eq!(again, u0, "{id}: the initial state after a solve");
    }
}

/// `remake` with a new `tspan` evaluates the `ic` right-hand sides at the
/// new start (esm-libraries-spec §2.5.5).
#[test]
fn remake_to_a_new_start_reevaluates_the_ic() {
    let m = manifest();
    let c = m["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == "t_at_nonzero_start")
        .expect("the case");
    let prob = build(c, (10.0, 11.0)).unwrap();
    let moved = remake(
        &prob,
        &earthsci_ast::Remake {
            tspan: Some((0.0, 1.0)),
            ..Default::default()
        },
    )
    .unwrap();
    let names = moved.state_variable_names();
    let u0 = initial_state(&moved).unwrap();
    let a = names.iter().position(|n| n == "T.a").unwrap();
    assert_eq!(u0[a], 1.0, "a = 2*0 + 1 at the new start");
}

/// [`Linear`] as a stateful, record-based provider: the record in effect at
/// `t` is the one at its latest refresh time at or before `t`, and it answers
/// `None` ("record unchanged") when that is the record it last delivered, as
/// an EarthSciIO provider does when its record anchor did not move. Counts
/// every ask.
struct Stateful {
    inner: Linear,
    anchor: Option<f64>,
    asks: std::rc::Rc<std::cell::Cell<usize>>,
}

impl CadenceProvider for Stateful {
    fn materialize(&mut self) -> Result<HashMap<String, NativeField>, ProviderError> {
        self.inner.materialize()
    }
    fn refresh(&mut self, t: f64) -> Result<Option<HashMap<String, NativeField>>, ProviderError> {
        self.asks.set(self.asks.get() + 1);
        let Some(a) = self
            .inner
            .times
            .iter()
            .copied()
            .filter(|&a| a <= t)
            .reduce(f64::max)
        else {
            return Ok(None);
        };
        if self.anchor == Some(a) {
            return Ok(None);
        }
        self.anchor = Some(a);
        Ok(Some(self.inner.at(a)))
    }
    fn refresh_times(&self) -> Vec<f64> {
        self.inner.times.clone()
    }
}

/// The case `id` of the manifest.
fn case(id: &str) -> Value {
    manifest()["cases"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == id)
        .cloned()
        .unwrap_or_else(|| panic!("no case {id}"))
}

/// `c`'s fixture (edited by `edit`) built over `tspan` with stateful
/// providers; also returns each provider's ask counter, by key.
#[allow(clippy::type_complexity)]
fn build_stateful(
    c: &Value,
    tspan: (f64, f64),
    edit: impl FnOnce(&mut Value),
) -> (
    earthsci_ast::EsmProblem,
    HashMap<String, std::rc::Rc<std::cell::Cell<usize>>>,
) {
    let mut asks = HashMap::new();
    let providers: HashMap<String, Box<dyn CadenceProvider>> = c["providers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| {
            let mut inner = Linear::from_manifest(p);
            // A record at the start of the run, so the record in effect there
            // is the manifest's value at `t0 = 5`.
            inner.times = vec![5.0, 8.0];
            let count = std::rc::Rc::new(std::cell::Cell::new(0));
            asks.insert(inner.key.clone(), count.clone());
            let key = inner.key.clone();
            let p = Stateful {
                inner,
                anchor: None,
                asks: count,
            };
            (key, Box::new(p) as Box<dyn CadenceProvider>)
        })
        .collect();
    let path = suite_dir().join(c["fixture"].as_str().unwrap());
    let mut doc: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    edit(&mut doc);
    let prob = esm_problem(
        &doc,
        tspan,
        ProblemOptions {
            compiler: Some(Compiler::Native),
            providers,
            p: numbers(&c["p"]),
            sample_time: c["sample_time"].as_f64(),
            ..Default::default()
        },
    )
    .expect("builds");
    (prob, asks)
}

fn expect_start(id: &str, prob: &earthsci_ast::EsmProblem, u0: &[f64], c: &Value) {
    let names = prob.state_variable_names();
    for (n, want) in numbers(&c["expected"]) {
        let k = names.iter().position(|x| *x == n).expect("a state");
        assert_eq!(u0[k], want, "{id}: {n}");
    }
}

/// A provider whose record did not change since construction sampled it
/// answers `None`; the initial state still reads that record.
#[test]
fn initial_state_reads_an_unchanged_record() {
    let c = case("data_fed_discrete_at_start");
    let (prob, _) = build_stateful(&c, (5.0, 9.0), |_| {});
    let u0 = initial_state(&prob).expect("an initial state");
    expect_start("unchanged record", &prob, &u0, &c);
}

/// `initial_state` between two solves leaves the providers able to give the
/// second solve the record in effect at its start, not the first solve's last.
#[test]
fn a_solve_after_initial_state_starts_from_the_record_at_its_start() {
    let c = case("data_fed_discrete_at_start");
    let (prob, _) = build_stateful(&c, (5.0, 9.0), |_| {});
    // The state rows; the observed rows a solution carries after them are not
    // part of the initial state.
    let n = prob.state_variable_names().len();
    let at_start = |sol: &earthsci_ast::Solution| -> Vec<f64> {
        sol.state[..n].iter().map(|row| row[0]).collect()
    };
    let opts = SolveOptions {
        saveat: Some(vec![5.0]),
        ..Default::default()
    };
    let first = solve(&prob, &opts).expect("the first solve");
    let u0 = initial_state(&prob).expect("an initial state");
    expect_start("between solves", &prob, &u0, &c);
    let second = solve(&prob, &opts).expect("the second solve");
    assert_eq!(at_start(&first), u0);
    assert_eq!(at_start(&second), u0);
}

/// `initial_state` asks only the providers whose fields an `ic` reads.
#[test]
fn initial_state_samples_only_the_providers_an_ic_reads() {
    let c = case("data_fed_discrete_sample_time_differs");
    // `s` starts at a constant: no `ic` reads `q` any more.
    let (prob, asks) = build_stateful(&c, (5.0, 9.0), |doc| {
        for eq in doc["models"]["H"]["equations"].as_array_mut().unwrap() {
            if eq["lhs"] == serde_json::json!({"op": "ic", "args": ["s"]}) {
                eq["rhs"] = serde_json::json!(27.5);
            }
        }
    });
    let (f, q) = (asks["H.F"].get(), asks["H.q"].get());
    let u0 = initial_state(&prob).expect("an initial state");
    expect_start("read cone", &prob, &u0, &c);
    assert!(asks["H.F"].get() > f, "F is read by ic(m)");
    assert_eq!(asks["H.q"].get(), q, "no ic reads q");
}

/// An unknown an algebraic `faq` equation defines (no `D`) is an observed
/// (esm-spec §6.3.1): an `ic` reading it is evaluated, not refused.
#[test]
fn an_ic_reads_an_algebraically_defined_unknown() {
    let path = suite_dir().join("fixtures/ic_reads_t.esm");
    let mut doc: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    for eq in doc["models"]["T"]["equations"].as_array_mut().unwrap() {
        if eq["lhs"] == "rate" {
            eq["lhs"] = serde_json::json!({
                "op": "faq", "args": [], "output_idx": ["i"],
                "ranges": {"i": {"from": "x"}},
                "expr": {"op": "index", "args": ["rate", "i"]}
            });
        }
    }
    let prob = esm_problem(
        &doc,
        (10.0, 11.0),
        ProblemOptions {
            compiler: Some(Compiler::Native),
            ..Default::default()
        },
    )
    .expect("builds");
    let u0 = initial_state(&prob).expect("an initial state");
    let names = prob.state_variable_names();
    let u: Vec<f64> = (1..=3)
        .map(|i| {
            let cell = format!("T.u[{i}]");
            u0[names.iter().position(|n| *n == cell).expect("a cell")]
        })
        .collect();
    assert_eq!(u, [6.0, 7.0, 8.0], "u = i + 0.5*10");
}
