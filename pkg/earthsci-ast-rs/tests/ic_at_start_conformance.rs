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
