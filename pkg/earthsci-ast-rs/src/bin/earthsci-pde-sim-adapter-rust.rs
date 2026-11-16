//! Rust adapter for the cross-language PDE-simulation conformance tier (ess-fmw).
//!
//! Drives the shared, pre-discretized method-of-lines fixtures in
//! `tests/conformance/pde_simulation/manifest.json`. For every fixture it
//! builds one Problem under the compiler the stage names (`--compiler`), then:
//!   * evaluates the discretized RHS f(u, t) at each declared probe state on
//!     that Problem's right-hand side, the way the compiler runs it (the tape
//!     under `native`, the per-cell evaluator under `interpreter`), and
//!   * integrates the trajectory from the declared initial conditions with the
//!     pinned diffsol solver (manifest `solver`/`reltol`/`abstol`), sampling at
//!     the declared output times via dense output.
//!
//! A fixture marked `"pipeline": "full"` (the `pde_simulation_pipeline` tier)
//! is built through the whole lowering pipeline with the manifest's inputs in
//! its forcing buffer instead; that route builds no Problem, so it names no
//! compiler.
//!
//! Discovered by the runner via `$EARTHSCI_PDE_SIM_ADAPTER_RUST` or on PATH as
//! `earthsci-pde-sim-adapter-rust`. Emits, to `--output`:
//!   {"binding":"rust","fixtures":{<id>:{"rhs":{<probe>:{name:val}},
//!                                       "trajectory":{<tstr>:{name:val}}}}}
//! with bare `u[i]` / `u[i,j]` element names. A fixture that fails is its own
//! `error` entry and makes the process exit non-zero
//! ([`earthsci_ast::adapter_support::adapter_main`]).

use std::collections::HashMap;
use std::fs;
use std::process::ExitCode;

use earthsci_ast::adapter_support::{
    Answer, Manifest, Tier, adapter_main, bare, nearest_index, number, time_key,
};
use earthsci_ast::flatten;
use earthsci_ast::simulate_array::{ArrayCompiled, RhsStats};
use earthsci_ast::{
    Alg, Compiler, ProblemOptions, Rhs, SolveOptions, esm_problem, load_string, solve,
};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Map, Value, json};

fn solver_from(name: &str) -> Alg {
    match name {
        "Bdf" | "bdf" => Alg::Bdf,
        "Sdirk" | "sdirk" => Alg::Sdirk,
        _ => Alg::Erk,
    }
}

/// Probe states are keyed by BARE element names (`O3[1,1]`), while the
/// compiled evaluator's slot names may carry a `Model.` namespace; look up by
/// either.
fn state_vec(names: &[String], state: &Map<String, Value>) -> Vec<f64> {
    names
        .iter()
        .map(|n| {
            state
                .get(n)
                .or_else(|| state.get(bare(n)))
                .and_then(Value::as_f64)
                .unwrap_or(0.0)
        })
        .collect()
}

/// The compiler this tier NAMES (CONFORMANCE_SPEC §5.44.5).
///
/// Every problem-building stage names its compiler rather than inheriting the
/// library default, so that a change to that default can never change what the
/// stage measures while its goldens still say what it measured before.
///
/// `native` is what this stage names, because every fixture it carries builds
/// under it: all eight were checked, and their numbers are bit-identical to the
/// reference path across the 205 values this adapter reports. That is the
/// stronger of the two choices — the stage keeps exercising the compiled tiers
/// its goldens were minted from, and additionally asserts that none of its
/// fixtures refuses. A stage whose fixtures a strict `native` REFUSES names
/// `interpreter` instead and says why where it names it; this one has no such
/// refusal to record.
///
/// `--compiler` overrides it, which is how these fixtures are checked under
/// another compiler without moving the gate. The compiler-agreement tier
/// (§5.44) remains the only place `native`'s coverage is measured.
const TIER_COMPILER: Compiler = Compiler::Native;

/// This tier under one compiler.
struct PdeSimulation(Compiler);

impl Tier for PdeSimulation {
    fn header(&self) -> Option<(&'static str, &'static str)> {
        None
    }

    fn run_fixture(&self, fx: &Value, manifest: &Manifest) -> Result<Answer, String> {
        if fx.get("pipeline").and_then(Value::as_str) == Some("full") {
            run_fixture_full(fx, manifest)
        } else {
            run_fixture(fx, manifest, self.0)
        }
        .map(Answer::Entry)
    }
}

/// The right-hand side at every probe of `fx`, evaluated the way `compiler`
/// runs `compiled`: the tape under `native`, the per-cell evaluator under
/// `interpreter`. Another compiler has no probe route here, and saying so is
/// that fixture's error rather than a silent substitute.
fn rhs_at_probes(
    compiled: &ArrayCompiled,
    compiler: Compiler,
    params: &HashMap<String, f64>,
    fx: &Value,
) -> Result<Value, String> {
    let names: Vec<String> = compiled.state_variable_names().to_vec();
    let _precision = compiled.debug_precision_env().enter();
    let mut taped = match compiler {
        Compiler::Native => Some((
            compiled
                .debug_new_scratch_taped()
                .map_err(|e| format!("native: {e}"))?,
            compiled.debug_resolve_params(params),
        )),
        Compiler::Interpreter => None,
        other => {
            return Err(format!(
                "right-hand-side probes run under `native` or `interpreter`, not `{}`",
                other.as_str()
            ));
        }
    };
    let mut rhs = Map::new();
    for probe in fx["rhs_probes"].as_array().ok_or("rhs_probes not array")? {
        let pid = probe["id"].as_str().ok_or("probe.id missing")?;
        let state_obj = probe["state"].as_object().ok_or("probe.state missing")?;
        let t = probe["t"].as_f64().unwrap_or(0.0);
        let sv = state_vec(&names, state_obj);
        let dy = match &mut taped {
            Some((scratch, param_vec)) => {
                let mut dy = vec![0.0; names.len()];
                compiled.debug_eval_rhs_into(
                    &sv,
                    t,
                    param_vec,
                    &mut dy,
                    scratch,
                    &mut RhsStats::default(),
                );
                dy
            }
            None => compiled.debug_eval_rhs(&sv, t, params, true).0,
        };
        let mut m = Map::new();
        for (i, n) in names.iter().enumerate() {
            m.insert(bare(n).to_string(), number(dy[i]));
        }
        rhs.insert(pid.to_string(), Value::Object(m));
    }
    Ok(Value::Object(rhs))
}

fn run_fixture(fx: &Value, manifest: &Manifest, compiler: Compiler) -> Result<Value, String> {
    let integ = manifest.integrator();
    let path = manifest.fixture_path(fx)?;
    let json_str = fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let file = load_string(&json_str).map_err(|e| format!("load: {e:?}"))?;

    let tr = &fx["trajectory"];
    let t0 = tr["time_span"]["start"].as_f64().ok_or("time_span.start")?;
    let t1 = tr["time_span"]["end"].as_f64().ok_or("time_span.end")?;
    let ics: HashMap<String, f64> = tr["initial_conditions"]
        .as_object()
        .ok_or("initial_conditions missing")?
        .iter()
        .map(|(k, v)| (k.clone(), v.as_f64().unwrap_or(0.0)))
        .collect();
    // The MANIFEST key is `output_times`, a shared cross-binding fixture field
    // written by `scripts/gen_pde_sim_fixtures.py` and read as
    // `tr.output_times` by the Julia adapter. It is not the SciML
    // `SolveOptions.saveat` field below.
    let out_times: Vec<f64> = tr["output_times"]
        .as_array()
        .ok_or("output_times missing")?
        .iter()
        .map(|v| v.as_f64().unwrap_or(0.0))
        .collect();
    let opts = SolveOptions {
        alg: solver_from(integ["solver"].as_str().unwrap_or("Erk")),
        abstol: Some(integ["abstol"].as_f64().unwrap_or(1e-12)),
        reltol: Some(integ["reltol"].as_f64().unwrap_or(1e-10)),
        maxiters: Some(1_000_000),
        saveat: Some(out_times.clone()),
        ..Default::default()
    };
    let prob = esm_problem(
        &file,
        (t0, t1),
        ProblemOptions {
            u0: ics,
            rhs: Rhs::Always,
            compiler: Some(compiler),
            ..Default::default()
        },
    )
    .map_err(|e| format!("esm_problem: {e:?}"))?;

    // --- RHS on the Problem's own right-hand side ----------------------------
    let compiled = prob
        .debug_array_compiled()
        .ok_or("the Problem built no array right-hand side")?;
    let rhs = rhs_at_probes(&compiled, compiler, prob.p(), fx)?;

    // --- Trajectory via the pinned diffsol solver ----------------------------
    let sol = solve(&prob, &opts).map_err(|e| format!("solve: {e:?}"))?;
    let mut traj = Map::new();
    for &t in &out_times {
        let idx = nearest_index(&sol.time, t).ok_or("empty solution time grid")?;
        let mut m = Map::new();
        for (row, n) in sol.state_variable_names.iter().enumerate() {
            m.insert(bare(n).to_string(), number(sol.state[row][idx]));
        }
        traj.insert(time_key(t), Value::Object(m));
    }

    Ok(json!({ "rhs": rhs, "trajectory": Value::Object(traj) }))
}

/// Convert a manifest `inputs` value (nested JSON arrays, row=lon/col=lat) into a
/// dense `ArrayD<f64>`: a `[[..],[..]]` grid → an (nrow×ncol) matrix; a `[..]`
/// line → a 1-D array.
fn json_to_field(v: &Value) -> Result<ArrayD<f64>, String> {
    let arr = v.as_array().ok_or("input field is not an array")?;
    if arr.first().map(Value::is_array).unwrap_or(false) {
        let nrow = arr.len();
        let ncol = arr[0]
            .as_array()
            .ok_or("input grid row is not an array")?
            .len();
        let mut data = Vec::with_capacity(nrow * ncol);
        for row in arr {
            let r = row.as_array().ok_or("ragged input grid")?;
            if r.len() != ncol {
                return Err("ragged input grid".to_string());
            }
            for x in r {
                data.push(x.as_f64().ok_or("non-numeric input value")?);
            }
        }
        ArrayD::from_shape_vec(IxDyn(&[nrow, ncol]), data).map_err(|e| e.to_string())
    } else {
        let data: Vec<f64> = arr
            .iter()
            .map(|x| x.as_f64().ok_or("non-numeric input value".to_string()))
            .collect::<Result<_, _>>()?;
        let n = data.len();
        ArrayD::from_shape_vec(IxDyn(&[n]), data).map_err(|e| e.to_string())
    }
}

/// Full-pipeline path (DESIGN pde_simulation_pipeline §7): load the fixture, run
/// the whole Rust lowering pipeline (reaction-gen → template `match` →
/// `operator_compose` → pointwise-lift → scoped-`ic`), install a static stub
/// provider serving the manifest `inputs` into the forcing buffer (keyed
/// `<ModelPath>.<param>`, DESIGN §2), and emit the RHS at each probe state plus the
/// trajectory at each checkpoint. Reuses the Phase-1 machinery of
/// `tests/loaded_ic_bc_simulation.rs`.
fn run_fixture_full(fx: &Value, manifest: &Manifest) -> Result<Value, String> {
    let integ = manifest.integrator();
    let path = manifest.fixture_path(fx)?;
    let json_str = fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
    let file = load_string(&json_str).map_err(|e| format!("load: {e:?}"))?;
    let flat = flatten(&file).map_err(|e| format!("flatten: {e:?}"))?;
    let compiled = ArrayCompiled::from_flattened(&flat).map_err(|e| format!("compile: {e:?}"))?;

    // Install the static stub provider: materialize every manifest input into the
    // forcing buffer under the CONSUMING PARAMETER's flattened name — from esm
    // 1.0.0 the only name a loaded field has, and exactly what the compiled RHS
    // looks up. Everything arrives through this seam, nothing around it (R1);
    // the scoped-`ic` fold reads `ChemistryICs.*_init` into u0 (R2) and the
    // lifted gather resolves the wind / inflow forcing the same way.
    let inputs = fx["inputs"].as_object().ok_or("fixture.inputs missing")?;
    {
        let forcing = compiled.forcing_handle();
        let mut buf = forcing.borrow_mut();
        for (k, v) in inputs {
            buf.insert(k.clone(), json_to_field(v)?);
        }
    }

    let params: HashMap<String, f64> = HashMap::new();
    let names: Vec<String> = compiled.state_variable_names().to_vec();

    // --- RHS at each probe via the vectorized faq evaluator ---------------
    let mut rhs = Map::new();
    for probe in fx["rhs_probes"].as_array().ok_or("rhs_probes not array")? {
        let pid = probe["id"].as_str().ok_or("probe.id missing")?;
        let state_obj = probe["state"].as_object().ok_or("probe.state missing")?;
        let t = probe["t"].as_f64().unwrap_or(0.0);
        let sv = state_vec(&names, state_obj);
        let (dy, _stats) = compiled.debug_eval_rhs(&sv, t, &params, false);
        let mut m = Map::new();
        for (i, n) in names.iter().enumerate() {
            m.insert(bare(n).to_string(), number(dy[i]));
        }
        rhs.insert(pid.to_string(), Value::Object(m));
    }

    // --- Trajectory via the SAME compiled instance (provider forcing in place)-
    let checkpoints: Vec<f64> = fx["trajectory"]["checkpoints"]
        .as_array()
        .ok_or("trajectory.checkpoints missing")?
        .iter()
        .map(|v| v.as_f64().unwrap_or(0.0))
        .collect();
    let t0 = *checkpoints.first().ok_or("empty checkpoints")?;
    let t1 = *checkpoints.last().ok_or("empty checkpoints")?;
    let opts = SolveOptions {
        alg: solver_from(integ["solver"].as_str().unwrap_or("Erk")),
        abstol: Some(integ["abstol"].as_f64().unwrap_or(1e-12)),
        reltol: Some(integ["reltol"].as_f64().unwrap_or(1e-10)),
        maxiters: Some(10_000_000),
        saveat: Some(checkpoints.clone()),
        ..Default::default()
    };
    let sol = compiled
        .solve((t0, t1), &params, &HashMap::new(), &opts)
        .map_err(|e| format!("solve: {e:?}"))?;

    let mut traj = Map::new();
    for &t in &checkpoints {
        let idx = nearest_index(&sol.time, t).ok_or("empty solution time grid")?;
        let mut m = Map::new();
        for (row, n) in sol.state_variable_names.iter().enumerate() {
            m.insert(bare(n).to_string(), number(sol.state[row][idx]));
        }
        traj.insert(time_key(t), Value::Object(m));
    }

    Ok(json!({ "rhs": Value::Object(rhs), "trajectory": Value::Object(traj) }))
}

fn main() -> ExitCode {
    adapter_main("pde-sim-adapter-rust", Some("--compiler"), |v| {
        v.map_or(Ok(TIER_COMPILER), Compiler::parse_named)
            .map(PdeSimulation)
    })
}
