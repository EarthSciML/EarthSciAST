//! The `provider_forcing` conformance suite
//! (`tests/conformance/provider_forcing/README.md`; API_SPEC §5.8, "Forcing
//! sets"): run-time providers and the forcing they give a Problem and its
//! `rhs_program`. Every case of the manifest, checked bitwise against the
//! values it records.

#![cfg(not(target_arch = "wasm32"))]

use std::collections::HashMap;
use std::path::PathBuf;

use earthsci_ast::provider::{CadenceProvider, NativeField, ProviderError};
use earthsci_ast::{Compiler, ProblemOptions, SlotKind, esm_problem, rhs_program};
use ndarray::{ArrayD, IxDyn};
use serde_json::Value;

fn suite_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/conformance/provider_forcing")
        .canonicalize()
        .expect("suite directory")
}

fn bits(v: &[f64]) -> Vec<u64> {
    v.iter().map(|x| x.to_bits()).collect()
}

fn floats(v: &Value) -> Vec<f64> {
    v.as_array()
        .expect("an array")
        .iter()
        .map(|x| x.as_f64().expect("a number"))
        .collect()
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
        let shape: Vec<usize> = p["shape"]
            .as_array()
            .unwrap()
            .iter()
            .map(|d| d.as_u64().unwrap() as usize)
            .collect();
        let mut base = Vec::new();
        fn flatten(v: &Value, out: &mut Vec<f64>) {
            match v {
                Value::Array(a) => a.iter().for_each(|x| flatten(x, out)),
                x => out.push(x.as_f64().expect("a number")),
            }
        }
        flatten(&p["base"], &mut base);
        Linear {
            key: p["key"].as_str().unwrap().to_string(),
            times: floats(&p["refresh_times"]),
            shape,
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

#[test]
fn provider_forcing_conformance() {
    let dir = suite_dir();
    let m: Value =
        serde_json::from_str(&std::fs::read_to_string(dir.join("manifest.json")).unwrap()).unwrap();
    let doc = dir.join(m["document"].as_str().unwrap());
    let tspan = floats(&m["tspan"]);
    let tspan = (tspan[0], tspan[1]);
    for c in m["cases"].as_array().unwrap() {
        let id = c["id"].as_str().unwrap();
        let providers: HashMap<String, Box<dyn CadenceProvider>> = c["providers"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| {
                let p = Linear::from_manifest(p);
                (p.key.clone(), Box::new(p) as Box<dyn CadenceProvider>)
            })
            .collect();
        let prob = esm_problem(
            doc.as_path(),
            tspan,
            ProblemOptions {
                compiler: Some(Compiler::Native),
                providers,
                sample_time: c["sample_time"].as_f64(),
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("{id}: builds: {e}"));
        let prog = rhs_program(&prob).unwrap_or_else(|e| panic!("{id}: program: {e}"));

        let want: Vec<(String, Vec<usize>, SlotKind)> = c["forcing_slots"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| {
                let kind = match s["kind"].as_str().unwrap() {
                    "forcing" => SlotKind::Forcing,
                    "array_parameter" => SlotKind::ArrayParameter,
                    k => panic!("unknown slot kind {k}"),
                };
                let shape = s["shape"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|d| d.as_u64().unwrap() as usize)
                    .collect();
                (s["name"].as_str().unwrap().to_string(), shape, kind)
            })
            .collect();
        let got: Vec<(String, Vec<usize>, SlotKind)> = prog
            .forcing_slots()
            .iter()
            .map(|s| (s.name.clone(), s.shape.clone(), s.kind))
            .collect();
        assert_eq!(got, want, "{id}: forcing slots");

        let d = prog.default_forcing();
        for (k, s) in prog.forcing_slots().iter().enumerate() {
            assert_eq!(
                bits(d.buffer(k)),
                bits(&floats(&c["default_forcing"][&s.name])),
                "{id}: default forcing of {}: {:?}",
                s.name,
                d.buffer(k)
            );
        }

        let du_want = floats(&c["du_default"]);
        let (u, aux) = prog.default_state();
        let p = prog.parameter_vector(&HashMap::new()).expect("defaults");
        let mut ws = prog.new_workspace();
        let mut du = vec![f64::NAN; prog.n_states()];
        prog.eval_into(&u, &aux, &p, tspan.0, &d, &mut du, &mut ws)
            .expect("eval");
        assert_eq!(bits(&du), bits(&du_want), "{id}: program du {du:?}");

        // The Problem's own right-hand side reads its forcing buffer.
        let compiled = prob.debug_array_compiled().expect("array backend");
        let pv = compiled.debug_resolve_params(&HashMap::new());
        let mut scratch = compiled.debug_new_scratch_taped().expect("taped scratch");
        let y = earthsci_ast::initial_state(&prob).expect("initial state");
        let mut dy = vec![f64::NAN; compiled.n_states()];
        compiled.debug_eval_rhs_into(
            &y,
            tspan.0,
            &pv,
            &mut dy,
            &mut scratch,
            &mut Default::default(),
        );
        assert_eq!(bits(&dy), bits(&du_want), "{id}: Problem du {dy:?}");
    }
}

/// Two providers that feed one parameter, under its full and its bare name,
/// are refused by name rather than one silently replacing the other.
#[test]
fn two_providers_for_one_parameter_are_refused() {
    let dir = suite_dir();
    let doc = dir.join("fixtures/provider_forcing.esm");
    let s = |key: &str| {
        Box::new(Linear {
            key: key.to_string(),
            times: Vec::new(),
            shape: Vec::new(),
            base: vec![3.0],
            slope: 0.0,
        }) as Box<dyn CadenceProvider>
    };
    let providers = HashMap::from([("Fed.s".to_string(), s("Fed.s")), ("s".to_string(), s("s"))]);
    let err = esm_problem(
        doc.as_path(),
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(Compiler::Native),
            providers,
            ..Default::default()
        },
    )
    .expect_err("two providers for Fed.s");
    let msg = err.to_string();
    assert!(
        msg.contains("`Fed.s`") && msg.contains("`s`"),
        "the refusal names both providers: {msg}"
    );
}

/// A scalar provider for `Fed.s` that answers only at its own refresh times
/// (the `CadenceProvider` contract allows `None` anywhere else), logging
/// every time it is asked.
struct Scheduled {
    schedule: Vec<(f64, f64)>,
    log: std::rc::Rc<std::cell::RefCell<Vec<f64>>>,
}

impl CadenceProvider for Scheduled {
    fn materialize(&mut self) -> Result<HashMap<String, NativeField>, ProviderError> {
        unreachable!("a discrete provider is never materialized")
    }
    fn refresh(&mut self, t: f64) -> Result<Option<HashMap<String, NativeField>>, ProviderError> {
        self.log.borrow_mut().push(t);
        Ok(self.schedule.iter().find(|(a, _)| *a == t).map(|&(_, v)| {
            let a = ArrayD::from_shape_vec(IxDyn(&[]), vec![v]).expect("0-d field");
            HashMap::from([("Fed.s".to_string(), NativeField::new(a))])
        }))
    }
    fn refresh_times(&self) -> Vec<f64> {
        self.schedule.iter().map(|&(t, _)| t).collect()
    }
}

/// The problem over `provider_forcing.esm` with `Fed.s` fed by `schedule`,
/// and the log of the times its provider was asked.
fn scheduled_problem(
    schedule: &[(f64, f64)],
    tspan: (f64, f64),
    sample_time: Option<f64>,
) -> (
    Result<earthsci_ast::EsmProblem, earthsci_ast::SimulateError>,
    std::rc::Rc<std::cell::RefCell<Vec<f64>>>,
) {
    let log = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let provider = Scheduled {
        schedule: schedule.to_vec(),
        log: log.clone(),
    };
    let providers = HashMap::from([(
        "Fed.s".to_string(),
        Box::new(provider) as Box<dyn CadenceProvider>,
    )]);
    let prob = esm_problem(
        suite_dir().join("fixtures/provider_forcing.esm").as_path(),
        tspan,
        ProblemOptions {
            compiler: Some(Compiler::Native),
            providers,
            sample_time,
            ..Default::default()
        },
    );
    (prob, log)
}

/// The default forcing set's value of the scalar `s`.
fn default_s(prob: &earthsci_ast::EsmProblem) -> f64 {
    let prog = rhs_program(prob).expect("program");
    let k = prog
        .forcing_slots()
        .iter()
        .position(|s| s.name == "Fed.s" || s.name == "s")
        .expect("a slot for s");
    prog.default_forcing().buffer(k)[0]
}

/// Construction samples the record IN EFFECT at `sample_time`: a provider
/// that answers only at its own refresh times gives the latest one at or
/// before it.
#[test]
fn construction_samples_the_record_in_effect() {
    let (prob, log) = scheduled_problem(&[(0.25, 4.0), (0.75, 8.0)], (0.0, 1.0), Some(0.5));
    let prob = prob.expect("builds");
    assert_eq!(default_s(&prob), 4.0, "the 0.25 record holds at 0.5");
    assert_eq!(*log.borrow(), vec![0.5, 0.25]);
}

/// A provider that delivers nothing at `sample_time` (its first refresh time
/// is later) leaves the declared default, 2.0, in the slot.
#[test]
fn nothing_delivered_at_construction_keeps_the_declared_default() {
    let (prob, _) = scheduled_problem(&[(0.5, 4.0)], (0.0, 1.0), None);
    assert_eq!(default_s(&prob.expect("builds")), 2.0);
}

/// Every refresh time inside the span is a boundary, including one before an
/// explicit `sample_time`, and a solve refreshes at each one whether or not
/// it has an output grid. A Problem remade over a wider span refreshes at
/// that span's refresh times too.
#[test]
fn solve_refreshes_at_every_refresh_time() {
    let schedule = [(0.0, 1.0), (0.1, 2.0), (0.5, 4.0), (1.5, 8.0)];
    let (prob, log) = scheduled_problem(&schedule, (0.0, 1.0), Some(0.25));
    let prob = prob.expect("builds");
    let asked_after = |n: usize| log.borrow()[n..].to_vec();

    for saveat in [None, Some(vec![1.0])] {
        let n = log.borrow().len();
        let sol = earthsci_ast::solve(
            &prob,
            &earthsci_ast::SolveOptions {
                saveat: saveat.clone(),
                ..Default::default()
            },
        )
        .expect("solves");
        assert_eq!(asked_after(n), vec![0.0, 0.1, 0.5], "saveat {saveat:?}");
        assert_eq!(*sol.time.last().unwrap(), 1.0);
    }

    let remade = earthsci_ast::remake(
        &prob,
        &earthsci_ast::Remake {
            tspan: Some((0.0, 2.0)),
            ..Default::default()
        },
    )
    .expect("remakes");
    let n = log.borrow().len();
    earthsci_ast::solve(&remade, &Default::default()).expect("solves");
    assert_eq!(asked_after(n), vec![0.0, 0.1, 0.5, 1.5]);
}
