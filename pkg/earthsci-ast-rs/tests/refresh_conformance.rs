//! Cross-language REFRESH-PATH conformance (CONFORMANCE_SPEC.md §5.10). Shared
//! fixture + analytic golden live under `tests/conformance/refresh/`; the Julia
//! (`refresh_conformance_test.jl`) and Python (`test_refresh_conformance.py`)
//! runners reproduce the same golden.
//!
//! A discretized, COUPLED, non-PDE model reads forcing from data loaders at a
//! discrete cadence and REGRIDS it from the coarse 6-cell native grid onto the
//! 3-cell sim grid — IN-MODEL, as a const-`W` coupling contraction
//! (`F_tgt[j] = sum_i W[i,j]*F_src[i]`), NOT through a regrid seam (the obsolete
//! `Regrid`/`IdentityRegrid` seam was removed in v0.8.0). `F_src` is DISCRETE
//! (loader `emis` has a `temporal` block); `scale_src` is CONST (loader `factors`,
//! no temporal). `D(c[j]) = scale_tgt[j]*F_tgt[j]`, `D(d[j]) = c[j]`.
//!
//! TWO-VIEW contract: the loader-fed `F_src`/`scale_src` are declared
//! `discrete`+`data_ingest` for the cadence classifier ([`RefreshExecutor`] reads
//! the RAW doc), but the typed RHS compiler has no Discrete VariableType — this
//! adapter STRIPS them (and `data_loaders`) from the doc for the simulate view, so
//! they resolve through the forcing buffer the executor writes. The native 6-cell
//! forcing lands in the buffer unchanged; the in-model `W` contraction regrids it
//! in the RHS. Two bands are asserted: the regridded fields (`F_tgt`/`scale_tgt`,
//! via [`BuildInspection`]) and the integrated trajectory.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::flatten::flatten;
use earthsci_ast::provider::{
    CadenceProvider, ForcingBuffer, NativeField, ProviderError, RefreshExecutor,
};
use earthsci_ast::simulate_array::{ArrayCompiled, BuildInspection};
use earthsci_ast::{SimulateOptions, Solution, SolverChoice, load};
use ndarray::{ArrayD, IxDyn};
use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

mod common;
const FIELD_RTOL: f64 = 1e-9;
const FIELD_ATOL: f64 = 1e-11;
const TRAJ_RTOL: f64 = 1e-4;
const TRAJ_ATOL: f64 = 1e-6;

fn fixture_dir() -> PathBuf {
    common::repo_fixture("conformance/refresh")
}

fn read_json(path: &PathBuf) -> Value {
    let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {path:?}: {e}"))
}

fn approximately_equal(actual: f64, expected: f64, rel: f64, abs: f64) -> bool {
    let diff = (actual - expected).abs();
    diff <= abs || diff <= rel * expected.abs().max(actual.abs())
}

fn f64_vec(v: &Value) -> Vec<f64> {
    v.as_array()
        .unwrap()
        .iter()
        .map(|x| x.as_f64().unwrap())
        .collect()
}

/// The `src` snapshot at an anchor from a golden `by_anchor` map (keys like "0.0").
fn by_anchor(field: &Value, anchor: f64) -> Vec<f64> {
    let m = field["by_anchor"].as_object().unwrap();
    let key = format!("{anchor:.1}");
    f64_vec(m.get(&key).unwrap_or_else(|| panic!("no anchor {key:?}")))
}

/// An offline provider seeded from the golden's `native_fields`, standing in for
/// the EarthSciIO provider. A DISCRETE loader has per-anchor fields; a CONST
/// loader has a single materialize baseline. `out_key` is the namespaced
/// forcing-buffer key the RHS reads (e.g. `"M.F_src"`).
struct GoldenProvider {
    out_key: String,
    const_value: Option<Vec<f64>>,
    schedule: Vec<(f64, Vec<f64>)>,
}

fn native(v: &[f64]) -> NativeField {
    NativeField::new(ArrayD::from_shape_vec(IxDyn(&[v.len()]), v.to_vec()).unwrap())
}

impl CadenceProvider for GoldenProvider {
    fn materialize(&mut self) -> Result<HashMap<String, NativeField>, ProviderError> {
        let v = self
            .const_value
            .clone()
            .expect("materialize on a provider with no CONST baseline");
        Ok(HashMap::from([(self.out_key.clone(), native(&v))]))
    }
    fn refresh(&mut self, t: f64) -> Result<Option<HashMap<String, NativeField>>, ProviderError> {
        for (anchor, value) in &self.schedule {
            if (*anchor - t).abs() < 1e-9 {
                return Ok(Some(HashMap::from([(self.out_key.clone(), native(value))])));
            }
        }
        Ok(None)
    }
    fn refresh_times(&self) -> Vec<f64> {
        self.schedule.iter().map(|(t, _)| *t).collect()
    }
}

/// The simulate view: strip the loader-fed `discrete` declarations (`F_src`,
/// `scale_src`) and the `data_loaders` block so the typed compiler resolves them
/// as forcing names. Returns the stripped JSON string.
fn simulate_view(raw: &Value) -> String {
    let mut doc = raw.clone();
    let vars = doc["models"]["M"]["variables"].as_object_mut().unwrap();
    vars.remove("F_src");
    vars.remove("scale_src");
    doc.as_object_mut().unwrap().remove("data_loaders");
    serde_json::to_string(&doc).unwrap()
}

/// Wire the two offline providers (emis→DISCRETE `M.F_src`, factors→CONST
/// `M.scale_src`) into a fresh executor over the raw (classifier-view) doc.
fn build_executor(raw: &Value, golden: &Value) -> RefreshExecutor {
    let nf = &golden["native_fields"];
    let anchors: Vec<f64> = nf["M.F_src"]["by_anchor"]
        .as_object()
        .unwrap()
        .keys()
        .map(|k| k.parse::<f64>().unwrap())
        .collect();
    let emis = GoldenProvider {
        out_key: "M.F_src".to_string(),
        const_value: None,
        schedule: anchors
            .iter()
            .map(|&a| (a, by_anchor(&nf["M.F_src"], a)))
            .collect(),
    };
    let factors = GoldenProvider {
        out_key: "M.scale_src".to_string(),
        const_value: Some(f64_vec(&nf["M.scale_src"]["values"])),
        schedule: Vec::new(),
    };
    let providers: HashMap<String, Box<dyn CadenceProvider>> = HashMap::from([
        ("emis".to_string(), Box::new(emis) as Box<dyn CadenceProvider>),
        (
            "factors".to_string(),
            Box::new(factors) as Box<dyn CadenceProvider>,
        ),
    ]);
    RefreshExecutor::new(&raw["models"]["M"], raw, providers).expect("classify + pair providers")
}

fn final_value(sol: &Solution, name: &str) -> f64 {
    let row = sol
        .state_variable_names
        .iter()
        .position(|n| n == name || n.ends_with(&format!(".{name}")))
        .unwrap_or_else(|| panic!("state slot {name:?} not found in {:?}", sol.state_variable_names));
    *sol.state[row].last().expect("at least one output time")
}

fn base_opts() -> SimulateOptions {
    SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-10,
        reltol: 1e-8,
        max_steps: 1_000_000,
        output_times: None,
    }
}

/// Regrid band — the in-model `W` contraction reproduces the golden regridded
/// fields. For each anchor, seed the forcing buffer (CONST `scale_src` once +
/// DISCRETE `F_src` at the anchor) and read the state-free observeds `M.F_tgt` /
/// `M.scale_tgt` that the RHS materializes, via [`BuildInspection`].
#[test]
fn refresh_regrid_band_matches_golden() {
    let raw = read_json(&fixture_dir().join("fixtures/coupled_refresh_regrid.esm"));
    let golden = read_json(&fixture_dir().join("golden/coupled_refresh_regrid.json"));

    let file = load(&simulate_view(&raw)).expect("load simulate view");
    let flat = flatten(&file).expect("flatten");
    let compiled = ArrayCompiled::from_flattened(&flat).expect("from_flattened");
    let forcing: ForcingBuffer = compiled.forcing_handle();
    let mut exec = build_executor(&raw, &golden);
    exec.materialize_const(&forcing).expect("materialize const");

    let anchors: Vec<f64> = {
        let mut a: Vec<f64> = golden["native_fields"]["M.F_src"]["by_anchor"]
            .as_object()
            .unwrap()
            .keys()
            .map(|k| k.parse::<f64>().unwrap())
            .collect();
        a.sort_by(|x, y| x.partial_cmp(y).unwrap());
        a
    };
    let scale_tgt_want = f64_vec(&golden["regridded_fields"]["M.scale_tgt"]);

    let assert_field = |name: &str, want: &[f64], insp: &BuildInspection, at: f64| {
        let got = insp
            .setup_arrays
            .get(name)
            .unwrap_or_else(|| panic!("{name} not in setup_arrays at t={at}"));
        let got: Vec<f64> = got.iter().copied().collect();
        assert_eq!(got.len(), want.len(), "{name} @ {at}: shape");
        for (g, w) in got.iter().zip(want) {
            assert!(
                approximately_equal(*g, *w, FIELD_RTOL, FIELD_ATOL),
                "{name} @ {at}: got {got:?}, want {want:?}"
            );
        }
    };

    for &a in &anchors {
        exec.refresh_at(a, &forcing).expect("refresh_at");
        let mut insp = BuildInspection::default();
        let mut opts = base_opts();
        opts.output_times = Some(vec![a]);
        compiled
            .simulate_inspect((a, a + 1.0), &HashMap::new(), &HashMap::new(), &opts, Some(&mut insp))
            .expect("simulate_inspect");
        assert_field("M.F_tgt", &by_anchor(&golden["regridded_fields"]["M.F_tgt"], a), &insp, a);
        assert_field("M.scale_tgt", &scale_tgt_want, &insp, a);
    }
}

/// Trajectory band — the segmented refresh solve reproduces the golden trajectory.
/// materialize_const once; segment boundaries = refresh_times ∩ tspan; at each
/// boundary refresh the DISCRETE forcing, integrate the segment, thread state.
#[test]
fn refresh_trajectory_band_matches_golden() {
    let raw = read_json(&fixture_dir().join("fixtures/coupled_refresh_regrid.esm"));
    let golden = read_json(&fixture_dir().join("golden/coupled_refresh_regrid.json"));

    let file = load(&simulate_view(&raw)).expect("load simulate view");
    let flat = flatten(&file).expect("flatten");
    let compiled = ArrayCompiled::from_flattened(&flat).expect("from_flattened");
    let forcing: ForcingBuffer = compiled.forcing_handle();
    let mut exec = build_executor(&raw, &golden);
    exec.materialize_const(&forcing).expect("materialize const");

    let tspan = &golden["cadence"]["tspan"];
    let (t0, t_end) = (tspan[0].as_f64().unwrap(), tspan[1].as_f64().unwrap());
    let mut endpoints = vec![t0];
    for t in exec.refresh_times() {
        if t > t0 && t < t_end {
            endpoints.push(t);
        }
    }
    endpoints.push(t_end);

    let cells: Vec<String> = ["c", "d"]
        .iter()
        .flat_map(|s| (1..=3).map(move |j| format!("M.{s}[{j}]")))
        .collect();
    let mut ics: HashMap<String, f64> = cells.iter().map(|c| (c.clone(), 0.0)).collect();
    let mut states: HashMap<String, HashMap<String, f64>> = HashMap::new();
    states.insert(format!("{t0:.1}"), ics.clone());

    for pair in endpoints.windows(2) {
        let (a, b) = (pair[0], pair[1]);
        exec.refresh_at(a, &forcing).expect("refresh_at");
        let mut opts = base_opts();
        opts.output_times = Some(vec![b]);
        let sol = compiled
            .simulate((a, b), &HashMap::new(), &ics, &opts)
            .unwrap_or_else(|e| panic!("simulate segment [{a},{b}]: {e}"));
        ics = cells
            .iter()
            .map(|c| (c.clone(), final_value(&sol, c)))
            .collect();
        states.insert(format!("{b:.1}"), ics.clone());
    }

    let traj = golden["trajectory"].as_object().unwrap();
    for (tk, expected) in traj {
        if tk == "comment" {
            continue;
        }
        let t: f64 = tk.parse().unwrap();
        let got = states
            .get(&format!("{t:.1}"))
            .unwrap_or_else(|| panic!("no boundary state at t={t}"));
        for cell in &cells {
            let want = expected[cell].as_f64().unwrap();
            assert!(
                approximately_equal(got[cell], want, TRAJ_RTOL, TRAJ_ATOL),
                "{cell} @ t={t}: got {}, want {want}",
                got[cell]
            );
        }
    }
}
