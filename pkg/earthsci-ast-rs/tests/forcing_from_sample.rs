//! `forcing_from_sample` (API_SPEC §5.8, "Forcing sets"): a slot's buffer
//! built from a provider sample is, bit for bit, the buffer `esm_problem` and
//! `rhs_program` build from the same sample, and the two accept and refuse the
//! same samples.
//!
//! Each agreement case builds a Problem with providers, takes its program's
//! default forcing set (the Problem's forcing when the program was built),
//! samples a second copy of each provider, and compares `forcing_from_sample`
//! of that sample with the set's buffer on the f64 bits: a gridded parameter,
//! a scalar one, a parameter whose first dimension is a two-record axis, and
//! (feature `esio`) parameters whose source declares a `unit_conversion`. A
//! DISCRETE provider's `refresh(t)` sample is pinned to the same layout through
//! a solve, and a sample of the wrong shape is refused by `esm_problem` (a
//! const provider) and by `solve` (a discrete one).

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::provider::{CadenceProvider, NativeField, ProviderError};
use earthsci_ast::{
    Compiler, ForcingSlot, ProblemOptions, RhsProgram, SlotKind, esm_problem, forcing_from_sample,
    rhs_program,
};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};
use std::collections::HashMap;

fn bits(values: &[f64]) -> Vec<u64> {
    values.iter().map(|v| v.to_bits()).collect()
}

/// A const provider delivering one fixed field.
#[derive(Clone)]
struct Fixed {
    key: String,
    array: ArrayD<f64>,
}

impl Fixed {
    fn sample(&self) -> HashMap<String, NativeField> {
        HashMap::from([(self.key.clone(), NativeField::new(self.array.clone()))])
    }
}

impl CadenceProvider for Fixed {
    fn materialize(&mut self) -> Result<HashMap<String, NativeField>, ProviderError> {
        Ok(self.sample())
    }
    fn refresh(&mut self, _t: f64) -> Result<Option<HashMap<String, NativeField>>, ProviderError> {
        Ok(None)
    }
    fn refresh_times(&self) -> Vec<f64> {
        Vec::new()
    }
}

/// A field whose every element differs, so a transposed or reordered buffer
/// cannot pass.
fn field(shape: &[usize], base: f64) -> ArrayD<f64> {
    let n: usize = shape.iter().product();
    let values: Vec<f64> = (0..n).map(|k| base + k as f64 / 7.0).collect();
    ArrayD::from_shape_vec(IxDyn(shape), values).expect("field")
}

/// `u[x]` forced by a gridded `E[x, y]`, a scalar `s` and `R[rec, x]`, whose
/// first dimension holds two records, all fed by one data source.
fn fed_doc(nx: usize, ny: usize) -> Value {
    let fed = |fv: &str| json!({"kind": "data", "source": "met", "from": {"file_variable": fv}});
    let idx = |v: &str, args: Vec<Value>| {
        let mut a = vec![json!(v)];
        a.extend(args);
        json!({"op": "index", "args": a})
    };
    let i = || json!("i");
    json!({
        "esm": "2.0.0",
        "metadata": {"name": "forcing_from_sample", "authors": ["test"]},
        "index_sets": {
            "x": {"kind": "interval", "size": nx},
            "y": {"kind": "interval", "size": ny},
            "rec": {"kind": "interval", "size": 2}
        },
        "data_sources": {"met": {"kind": "grid", "source": {"url_template": "file:///met.nc"}}},
        "models": {"M": {
            "variables": {
                "u": {"type": "unknown", "units": "1", "shape": ["x"], "default": 1.0},
                "E": {"type": "parameter", "units": "1", "shape": ["x", "y"], "default": 0.5,
                      "update": fed("E")},
                "s": {"type": "parameter", "units": "1", "shape": [], "default": 2.0,
                      "update": fed("s")},
                "R": {"type": "parameter", "units": "1", "shape": ["rec", "x"], "default": 0.0,
                      "update": fed("R")},
                "k": {"type": "parameter", "units": "1", "default": 0.25}
            },
            "equations": [{
                "lhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                        "expr": {"op": "D", "args": [idx("u", vec![i()])], "wrt": "t"}},
                "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "x"}},
                        "expr": {"op": "+", "args": [
                            {"op": "*", "args": ["s", idx("E", vec![i(), json!(2)])]},
                            idx("R", vec![json!(1), i()]),
                            idx("R", vec![json!(2), i()]),
                            {"op": "*", "args": [-1, "k", idx("u", vec![i()])]}
                        ]}}
            }]
        }}
    })
}

/// Keyed by the names a single-model build compiles its forcing under: the
/// bare parameter names, which the program's slots spell `M.E`, `M.s`, `M.R`.
fn fed_providers(nx: usize, ny: usize) -> Vec<Fixed> {
    vec![
        Fixed {
            key: "E".into(),
            array: field(&[nx, ny], 0.1),
        },
        Fixed {
            key: "s".into(),
            array: field(&[], 3.0),
        },
        Fixed {
            key: "R".into(),
            array: field(&[2, nx], -1.3),
        },
    ]
}

/// The Native Problem of [`fed_doc`] over `(0, 1)` with `providers`.
fn fed_problem(
    nx: usize,
    ny: usize,
    providers: HashMap<String, Box<dyn CadenceProvider>>,
) -> Result<earthsci_ast::EsmProblem, earthsci_ast::SimulateError> {
    esm_problem(
        &fed_doc(nx, ny),
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(Compiler::Native),
            providers,
            ..Default::default()
        },
    )
}

fn boxed(providers: Vec<Fixed>) -> HashMap<String, Box<dyn CadenceProvider>> {
    providers
        .into_iter()
        .map(|p| (p.key.clone(), Box::new(p) as Box<dyn CadenceProvider>))
        .collect()
}

fn fed_program(nx: usize, ny: usize) -> RhsProgram {
    let prob =
        fed_problem(nx, ny, boxed(fed_providers(nx, ny))).unwrap_or_else(|e| panic!("builds: {e}"));
    rhs_program(&prob).expect("program")
}

/// Every slot of `prog`, from the matching sample, equals its default buffer.
fn assert_default_is_forcing_from_sample(
    prog: &RhsProgram,
    samples: &HashMap<String, HashMap<String, NativeField>>,
) {
    let d = prog.default_forcing();
    for (k, slot) in prog.forcing_slots().iter().enumerate() {
        let sample = samples
            .get(&slot.name)
            .unwrap_or_else(|| panic!("no sample for slot {}", slot.name));
        let got =
            forcing_from_sample(sample, slot).unwrap_or_else(|e| panic!("{}: {e}", slot.name));
        assert_eq!(
            bits(&got),
            bits(d.buffer(k)),
            "{}: forcing_from_sample {got:?}, the Problem's {:?}",
            slot.name,
            d.buffer(k)
        );
    }
}

#[test]
fn forcing_from_sample_is_the_problems_buffer() {
    let (nx, ny) = (3, 4);
    let prog = fed_program(nx, ny);
    let shapes: Vec<(String, Vec<usize>)> = prog
        .forcing_slots()
        .iter()
        .map(|s| (s.name.clone(), s.shape.clone()))
        .collect();
    assert_eq!(
        shapes,
        vec![
            ("M.E".to_string(), vec![nx, ny]),
            ("M.R".to_string(), vec![2, nx]),
            ("M.s".to_string(), vec![]),
        ]
    );
    let samples: HashMap<String, HashMap<String, NativeField>> = fed_providers(nx, ny)
        .iter()
        .map(|p| (format!("M.{}", p.key), p.sample()))
        .collect();
    assert_default_is_forcing_from_sample(&prog, &samples);

    // Column-major over the declared shape: E[i, j] is element i + nx * j.
    let e = forcing_from_sample(&samples["M.E"], &prog.forcing_slots()[0]).expect("E");
    let a = &fed_providers(nx, ny)[0].array;
    for i in 0..nx {
        for j in 0..ny {
            assert_eq!(e[i + nx * j].to_bits(), a[[i, j]].to_bits());
        }
    }
}

#[test]
fn forcing_from_sample_refuses_a_sample_that_does_not_fit_the_slot() {
    let slot = ForcingSlot {
        name: "M.E".into(),
        shape: vec![3, 4],
        kind: SlotKind::Forcing,
    };
    let wrong = HashMap::from([("M.E".to_string(), NativeField::new(field(&[4, 3], 0.0)))]);
    let err = forcing_from_sample(&wrong, &slot).expect_err("transposed shape");
    assert!(err.to_string().contains("[4, 3]"), "{err}");
    // A one-field sample is the field, whatever it is called, as `esm_problem`
    // binds it.
    let one = HashMap::from([("F".to_string(), NativeField::new(field(&[3, 4], 0.0)))]);
    assert_eq!(
        forcing_from_sample(&one, &slot).expect("one field").len(),
        12
    );
    // More than one field is refused, even when one of them is named after
    // the slot: `esm_problem` binds exactly one.
    let named = HashMap::from([
        ("M.E".to_string(), NativeField::new(field(&[3, 4], 0.0))),
        ("M.G".to_string(), NativeField::new(field(&[3, 4], 0.0))),
    ]);
    let err = forcing_from_sample(&named, &slot).expect_err("two fields");
    assert!(err.to_string().contains("fed 2 fields"), "{err}");
    assert!(forcing_from_sample(&HashMap::new(), &slot).is_err());
    let scalar = ForcingSlot {
        name: "M.s".into(),
        shape: vec![],
        kind: SlotKind::Forcing,
    };
    let two = HashMap::from([("M.s".to_string(), NativeField::new(field(&[2], 0.0)))]);
    assert!(forcing_from_sample(&two, &scalar).is_err());
    let one_value = HashMap::from([("M.s".to_string(), NativeField::new(field(&[1, 1], 4.0)))]);
    assert_eq!(
        bits(&forcing_from_sample(&one_value, &scalar).expect("one value")),
        bits(&[4.0])
    );
}

/// `esm_problem` refuses a const provider whose field does not have the
/// parameter's declared shape, under either spelling of its key, naming it.
#[test]
fn esm_problem_refuses_a_provider_of_the_wrong_shape() {
    let (nx, ny) = (3, 4);
    for key in ["E", "M.E"] {
        let mut providers = fed_providers(nx, ny);
        providers[0] = Fixed {
            key: key.into(),
            array: field(&[ny, nx], 0.1),
        };
        let err = fed_problem(nx, ny, boxed(providers))
            .err()
            .unwrap_or_else(|| panic!("{key}: a transposed field builds"))
            .to_string();
        assert!(err.contains(&format!("{key:?}")), "{key}: {err}");
        assert!(
            err.contains("shape [4, 3]; the parameter's declared shape is [3, 4]"),
            "{key}: {err}"
        );
    }
}

/// A DISCRETE provider: `refresh(t)` returns its field at every time asked,
/// and its refresh times lie outside the solve, so the only refresh is the
/// one `solve` makes at the start.
#[cfg(feature = "solve")]
struct Discrete(Fixed);

#[cfg(feature = "solve")]
impl CadenceProvider for Discrete {
    fn materialize(&mut self) -> Result<HashMap<String, NativeField>, ProviderError> {
        Ok(self.0.sample())
    }
    fn refresh(&mut self, _t: f64) -> Result<Option<HashMap<String, NativeField>>, ProviderError> {
        Ok(Some(self.0.sample()))
    }
    fn refresh_times(&self) -> Vec<f64> {
        vec![10.0]
    }
}

/// `E` fed by a const provider and by a discrete one delivering the same
/// field: the solves agree bit for bit, so the refresh path writes the layout
/// `forcing_from_sample` gives for the refresh sample.
#[cfg(feature = "solve")]
#[test]
fn a_discrete_refresh_sample_is_the_const_buffer() {
    use earthsci_ast::{SolveOptions, solve};
    let (nx, ny) = (3, 4);
    let opts = SolveOptions {
        saveat: Some(vec![0.0, 0.25, 0.5, 1.0]),
        ..Default::default()
    };
    let const_prob = fed_problem(nx, ny, boxed(fed_providers(nx, ny))).expect("const builds");
    let prog = rhs_program(&const_prob).expect("program");
    let want = solve(&const_prob, &opts).expect("const solves");

    let mut providers = fed_providers(nx, ny);
    let e = Discrete(providers.remove(0));
    let mut by_key = boxed(providers);
    let mut refresh_copy = Discrete(e.0.clone());
    by_key.insert("E".into(), Box::new(e));
    let discrete_prob = fed_problem(nx, ny, by_key).expect("discrete builds");
    let got = solve(&discrete_prob, &opts).expect("discrete solves");

    assert_eq!(got.state_variable_names, want.state_variable_names);
    assert_eq!(got.time, want.time);
    for (name, (g, w)) in got
        .state_variable_names
        .iter()
        .zip(got.state.iter().zip(&want.state))
    {
        assert_eq!(bits(g), bits(w), "{name}: discrete {g:?}, const {w:?}");
    }

    let sample = refresh_copy
        .refresh(0.0)
        .expect("refresh")
        .expect("a sample");
    let k = prog
        .forcing_slots()
        .iter()
        .position(|s| s.name == "M.E")
        .expect("E slot");
    let buf = forcing_from_sample(&sample, &prog.forcing_slots()[k]).expect("E");
    assert_eq!(bits(&buf), bits(prog.default_forcing().buffer(k)));
}

/// A discrete provider whose sample is the transposed field: `esm_problem`
/// samples it at construction (esm-libraries-spec §2.5.2) and refuses it there,
/// naming its key.
#[cfg(feature = "solve")]
#[test]
fn esm_problem_refuses_a_discrete_sample_of_the_wrong_shape() {
    let (nx, ny) = (3, 4);
    let mut providers = fed_providers(nx, ny);
    providers.remove(0);
    let mut by_key = boxed(providers);
    by_key.insert(
        "E".into(),
        Box::new(Discrete(Fixed {
            key: "E".into(),
            array: field(&[ny, nx], 0.1),
        })),
    );
    let err = fed_problem(nx, ny, by_key)
        .err()
        .unwrap_or_else(|| panic!("a transposed discrete sample builds"))
        .to_string();
    assert!(
        err.contains("\"E\"")
            && err.contains("shape [4, 3]; the parameter's declared shape is [3, 4]"),
        "{err}"
    );
}

/// A source declaring `unit_conversion`: the provider from
/// `providers_from_document` delivers the converted values, and
/// `forcing_from_sample` of its `materialize()` sample is the Problem's buffer.
#[cfg(feature = "esio")]
#[test]
fn forcing_from_sample_of_a_converted_source_is_the_problems_buffer() {
    use earthsci_ast::esio_provider::providers_from_document;
    use std::path::Path;

    let tests = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests");
    let dir = tests.join("conformance/loader_unit_conversion");
    let mut doc: Value = serde_json::from_str(
        &std::fs::read_to_string(dir.join("fixtures/loader_unit_conversion.esm")).expect("read"),
    )
    .expect("parse");
    // The fixture declares no equations; give it one that reads every
    // parameter, so the Problem has a right-hand side.
    doc["esm"] = json!("1.2.0"); // `faq` needs 1.1.0 or later
    let m = &mut doc["models"]["Stacks_Ingest"];
    m["system_kind"] = json!("ode");
    m["variables"]["h"] =
        json!({"type": "unknown", "units": "1", "shape": ["stacks"], "default": 0.0});
    let ix = |v: &str| json!({"op": "index", "args": [v, "i"]});
    m["equations"] = json!([{
        "lhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "stacks"}},
                "expr": {"op": "D", "args": [ix("h")], "wrt": "t"}},
        "rhs": {"op": "faq", "args": [], "output_idx": ["i"], "ranges": {"i": {"from": "stacks"}},
                "expr": {"op": "+", "args": [ix("annual"), ix("stkhgt"), ix("stkdiam"), ix("stktemp")]}}
    }]);
    let csv = dir
        .join("fixtures/stacks_ff10_point.csv")
        .canonicalize()
        .expect("fixture data");
    let overrides = HashMap::from([("Stacks".to_string(), format!("file://{}", csv.display()))]);
    let tmp = tempfile::tempdir().expect("tmpdir");
    let build = || {
        providers_from_document(
            &doc,
            &tmp.path().join("cache"),
            Some(&["Stacks"]),
            &overrides,
        )
        .expect("providers")
    };
    // The document's providers reach `esm_problem` the way the `esm` command
    // passes them: as build-time providers.
    let build_providers: Vec<(String, Box<dyn earthsci_ast::PrepareProvider>)> = build()
        .into_iter()
        .map(|(k, p)| (k, Box::new(p) as Box<dyn earthsci_ast::PrepareProvider>))
        .collect();
    let prob = esm_problem(
        &doc,
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(Compiler::Native),
            build_providers,
            ..Default::default()
        },
    )
    .unwrap_or_else(|e| panic!("builds: {e}"));
    let prog = rhs_program(&prob).expect("program");
    assert_eq!(prog.forcing_slots().len(), 4);
    let mut samples = HashMap::new();
    for (k, mut p) in build() {
        let s = p.materialize().expect("sample");
        samples.insert(k, s);
    }
    assert_default_is_forcing_from_sample(&prog, &samples);
    // The conversion is in the buffer: feet to metres on `stkhgt`.
    let golden: Value = serde_json::from_str(
        &std::fs::read_to_string(dir.join("golden/ff10_stacks.json")).expect("golden"),
    )
    .expect("golden json");
    let k = prog
        .forcing_slots()
        .iter()
        .position(|s| s.name == "Stacks_Ingest.stkhgt")
        .expect("stkhgt slot");
    let want: Vec<f64> = golden["delivered"]["Stacks_Ingest.stkhgt"]
        .as_array()
        .expect("golden stkhgt")
        .iter()
        .map(|v| v.as_f64().expect("number"))
        .collect();
    assert_eq!(bits(prog.default_forcing().buffer(k)), bits(&want));
}
