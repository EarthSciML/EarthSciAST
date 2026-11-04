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

/// The suite's document as JSON.
fn fixture() -> Value {
    serde_json::from_str(
        &std::fs::read_to_string(suite_dir().join("fixtures/provider_forcing.esm")).unwrap(),
    )
    .unwrap()
}

/// A 0-d provider keyed `key` giving `value` at every time, discrete with
/// `times` (const when empty).
fn constant(key: &str, times: &[f64], value: f64) -> Box<dyn CadenceProvider> {
    Box::new(Linear {
        key: key.to_string(),
        times: times.to_vec(),
        shape: Vec::new(),
        base: vec![value],
        slope: 0.0,
    })
}

fn build(
    doc: &Value,
    providers: Vec<(&str, Box<dyn CadenceProvider>)>,
    const_arrays: &[(&str, f64)],
) -> Result<earthsci_ast::EsmProblem, earthsci_ast::SimulateError> {
    esm_problem(
        doc,
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(Compiler::Native),
            providers: providers
                .into_iter()
                .map(|(k, p)| (k.to_string(), p))
                .collect(),
            const_arrays: const_arrays
                .iter()
                .map(|(k, v)| {
                    (
                        k.to_string(),
                        ArrayD::from_shape_vec(IxDyn(&[1]), vec![*v]).unwrap(),
                    )
                })
                .collect(),
            ..Default::default()
        },
    )
}

/// The default forcing set's value of slot `name`.
fn slot_value(prob: &earthsci_ast::EsmProblem, name: &str) -> f64 {
    let prog = rhs_program(prob).expect("program");
    let k = prog
        .forcing_slots()
        .iter()
        .position(|s| s.name == name)
        .unwrap_or_else(|| panic!("a slot {name}"));
    prog.default_forcing().buffer(k)[0]
}

fn provider_error(e: earthsci_ast::SimulateError) -> (String, String) {
    match e {
        earthsci_ast::SimulateError::ProviderError { name, details } => (name, details),
        e => panic!("not a provider error: {e}"),
    }
}

/// The fixture with a second model, `Other`, that has its own state and,
/// with `shared_s`, its own parameter `s`.
fn two_models(shared_s: bool) -> Value {
    let mut doc = fixture();
    let mut vars = serde_json::json!({
        "y": {"type": "unknown", "units": "1", "default": 1.0},
        "q": {"type": "parameter", "units": "1/s", "default": 1.0}
    });
    if shared_s {
        vars["s"] = serde_json::json!({"type": "parameter", "units": "1/s", "default": 1.0});
    }
    doc["models"]["Other"] = serde_json::json!({
        "variables": vars,
        "equations": [{
            "lhs": {"op": "D", "args": ["y"], "wrt": "t"},
            "rhs": {"op": "*", "args": ["q", "y"]}
        }]
    });
    doc
}

/// An exact key wins over a bare key for the same parameter, whose provider
/// is not read (esm-spec §6.6.2), as in Julia.
#[test]
fn an_exact_key_shadows_a_bare_key() {
    for times in [&[][..], &[0.5][..]] {
        let prob = build(
            &fixture(),
            vec![
                ("s", constant("s", times, 5.0)),
                ("Fed.s", constant("Fed.s", times, 3.0)),
            ],
            &[],
        )
        .expect("builds");
        assert_eq!(slot_value(&prob, "Fed.s"), 3.0, "times {times:?}");
    }
}

/// A discrete provider keyed by a parameter's full name feeds a parameter
/// that declares no default; with nothing in effect at the sample time, the
/// refusal names the provider by the caller's key and says why.
#[test]
fn a_full_name_discrete_provider_feeds_a_parameter_without_default() {
    let mut doc = fixture();
    doc["models"]["Fed"]["variables"]["s"]
        .as_object_mut()
        .unwrap()
        .remove("default");
    let prob = build(
        &doc,
        vec![("Fed.s", constant("Fed.s", &[0.0, 0.5], 3.0))],
        &[],
    )
    .expect("builds");
    assert_eq!(slot_value(&prob, "Fed.s"), 3.0);

    let log = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let late = Scheduled {
        schedule: vec![(0.5, 4.0)],
        log,
    };
    let err = build(&doc, vec![("Fed.s", Box::new(late))], &[]).expect_err("nothing at 0");
    let (name, details) = provider_error(err);
    assert_eq!(name, "Fed.s");
    assert!(details.contains("declares no default"), "{details}");
}

/// A provider that answers `None` at its own refresh time because its
/// record did not change since it last delivered is not asked for an older
/// record in its place.
#[test]
fn unchanged_at_an_own_refresh_time_is_not_replaced() {
    struct Stateful {
        last: Option<usize>,
        log: std::rc::Rc<std::cell::RefCell<Vec<f64>>>,
    }
    const ANCHORS: [f64; 3] = [0.0, 1.0, 2.0];
    impl CadenceProvider for Stateful {
        fn materialize(&mut self) -> Result<HashMap<String, NativeField>, ProviderError> {
            unreachable!()
        }
        fn refresh(
            &mut self,
            t: f64,
        ) -> Result<Option<HashMap<String, NativeField>>, ProviderError> {
            self.log.borrow_mut().push(t);
            let Some(i) = ANCHORS.iter().position(|&a| a == t) else {
                return Ok(None);
            };
            if self.last == Some(i) {
                return Ok(None);
            }
            self.last = Some(i);
            let a = ArrayD::from_shape_vec(IxDyn(&[]), vec![i as f64 + 1.0]).unwrap();
            Ok(Some(HashMap::from([(
                "s".to_string(),
                NativeField::new(a),
            )])))
        }
        fn refresh_times(&self) -> Vec<f64> {
            ANCHORS.to_vec()
        }
    }
    let log = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let provider = Stateful {
        last: None,
        log: log.clone(),
    };
    let prob = esm_problem(
        suite_dir().join("fixtures/provider_forcing.esm").as_path(),
        (1.0, 3.0),
        ProblemOptions {
            compiler: Some(Compiler::Native),
            providers: HashMap::from([(
                "Fed.s".to_string(),
                Box::new(provider) as Box<dyn CadenceProvider>,
            )]),
            ..Default::default()
        },
    )
    .expect("builds");
    assert_eq!(slot_value(&prob, "Fed.s"), 2.0, "the record at 1");
    earthsci_ast::solve(&prob, &Default::default()).expect("solves");
    assert_eq!(*log.borrow(), vec![1.0, 1.0, 2.0]);
}

/// A solve that starts before its provider's first record integrates from
/// the declared default, whatever an earlier solve of this Problem, or of
/// one remade from it, left in the buffer.
#[test]
fn a_solve_starts_from_the_default_when_nothing_is_in_effect() {
    let (prob, _) = scheduled_problem(&[(0.5, 4.0)], (0.0, 1.0), None);
    let prob = prob.expect("builds");
    let opts = earthsci_ast::SolveOptions {
        saveat: Some(vec![0.25, 1.0]),
        ..Default::default()
    };
    let first = earthsci_ast::solve(&prob, &opts).expect("solves");
    let again = earthsci_ast::solve(&prob, &opts).expect("solves");
    let remade = earthsci_ast::remake(&prob, &Default::default()).expect("remakes");
    let third = earthsci_ast::solve(&remade, &opts).expect("solves");
    let rows = |s: &earthsci_ast::Solution| s.state.iter().map(|r| bits(r)).collect::<Vec<_>>();
    assert_eq!(rows(&again), rows(&first));
    assert_eq!(rows(&third), rows(&first));
}

/// On a document with two models, compiled flattened, a bare key routes to
/// the one parameter that carries it, and is refused when two do.
#[test]
fn a_bare_key_routes_on_the_flattened_path() {
    let prob = build(
        &two_models(false),
        vec![("s", constant("s", &[], 3.0))],
        &[],
    )
    .expect("builds");
    assert_eq!(slot_value(&prob, "Fed.s"), 3.0);
    let prob = build(
        &two_models(false),
        vec![("s", constant("s", &[0.5], 3.0))],
        &[],
    )
    .expect("builds");
    assert_eq!(slot_value(&prob, "Fed.s"), 3.0);

    let err =
        build(&two_models(true), vec![("s", constant("s", &[], 3.0))], &[]).expect_err("ambiguous");
    let (name, details) = provider_error(err);
    assert_eq!(name, "s");
    assert!(details.contains("ambiguous"), "{details}");
}

/// A provider and a `const_arrays` entry for one parameter, under any
/// spellings, are refused, as in Julia; a `const_arrays` key two parameters
/// carry beside a provider for one of them is refused naming both; and the other
/// model's own parameter, named in full, is no overlap.
#[test]
fn a_provider_and_a_const_array_for_one_parameter_are_refused() {
    for (pk, ck) in [("s", "Fed.s"), ("Fed.s", "s"), ("Fed.s", "Fed.s")] {
        let err = build(&fixture(), vec![(pk, constant(pk, &[], 3.0))], &[(ck, 9.0)])
            .expect_err("two sources");
        let (name, details) = provider_error(err);
        assert_eq!(name, pk);
        assert!(
            details.contains("both supply the parameter"),
            "{pk} / {ck}: {details}"
        );
    }
    let err = build(
        &two_models(true),
        vec![("Fed.s", constant("Fed.s", &[], 3.0))],
        &[("s", 9.0)],
    )
    .expect_err("ambiguous const key");
    let msg = err.to_string();
    assert!(msg.contains("Fed.s") && msg.contains("Other.s"), "{msg}");
    build(
        &two_models(true),
        vec![("Fed.s", constant("Fed.s", &[], 3.0))],
        &[("Other.s", 9.0)],
    )
    .expect("no overlap");
}

/// A provider that fails at a refresh inside a solve is named by the key
/// the caller passed it under, as at construction.
#[test]
fn a_solve_time_failure_names_the_callers_key() {
    struct Failing;
    impl CadenceProvider for Failing {
        fn materialize(&mut self) -> Result<HashMap<String, NativeField>, ProviderError> {
            unreachable!()
        }
        fn refresh(
            &mut self,
            t: f64,
        ) -> Result<Option<HashMap<String, NativeField>>, ProviderError> {
            if t == 0.5 {
                return Err(ProviderError {
                    0: "unreadable record".into(),
                });
            }
            let a = ArrayD::from_shape_vec(IxDyn(&[]), vec![3.0]).unwrap();
            Ok(Some(HashMap::from([(
                "s".to_string(),
                NativeField::new(a),
            )])))
        }
        fn refresh_times(&self) -> Vec<f64> {
            vec![0.0, 0.5]
        }
    }
    let prob = build(&fixture(), vec![("Fed.s", Box::new(Failing))], &[]).expect("builds");
    let err = earthsci_ast::solve(&prob, &Default::default()).expect_err("fails at 0.5");
    let (name, details) = provider_error(err);
    assert_eq!(name, "Fed.s");
    assert!(details.contains("unreadable record"), "{details}");
}

/// A discrete provider keyed by a name that is not a parameter the model
/// reads has no default to fall back on and needs none: the Problem builds
/// though the provider delivers nothing at the sample time.
#[test]
fn a_non_parameter_discrete_key_needs_no_record_at_the_sample_time() {
    let log = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let late = Scheduled {
        schedule: vec![(0.5, 4.0)],
        log,
    };
    build(&fixture(), vec![("Zed", Box::new(late))], &[]).expect("builds");
}
