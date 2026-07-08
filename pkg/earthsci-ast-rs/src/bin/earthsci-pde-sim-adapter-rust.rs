//! Rust adapter for the cross-language PDE-simulation conformance tier (ess-fmw).
//!
//! Drives the shared, pre-discretized method-of-lines fixtures in
//! `tests/conformance/pde_simulation/manifest.json`. For every fixture it:
//!   * evaluates the discretized RHS f(u, t) at each declared probe state via
//!     the vectorized arrayop evaluator (`ArrayCompiled::debug_eval_rhs`, the
//!     same no-scalarization kernel the simulator uses), and
//!   * integrates the trajectory from the declared initial conditions with the
//!     pinned diffsol solver (manifest `solver`/`reltol`/`abstol`), sampling at
//!     the declared output times via dense output.
//!
//! Discovered by the runner via `$EARTHSCI_PDE_SIM_ADAPTER_RUST` or on PATH as
//! `earthsci-pde-sim-adapter-rust`. Emits, to `--output`:
//!   {"binding":"rust","fixtures":{<id>:{"rhs":{<probe>:{name:val}},
//!                                       "trajectory":{<tstr>:{name:val}}}}}
//! with bare `u[i]` / `u[i,j]` element names.

use std::collections::HashMap;
use std::fs;
use std::path::Path;
use std::process::ExitCode;

use earthsci_ast::adapter_support::{parse_manifest_output_args, write_report};

use earthsci_ast::flatten::flatten;
use earthsci_ast::simulate_array::ArrayCompiled;
use earthsci_ast::{SimulateOptions, SolverChoice, load, simulate};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Map, Value, json};

/// Strip a leading `Model.` namespace so element names match across bindings.
fn bare(name: &str) -> &str {
    name.split_once('.').map(|x| x.1).unwrap_or(name)
}

/// Trajectory time key; the Python harness re-normalizes every key via
/// `float(k):g`, so this only needs to round-trip as a float.
fn time_key(t: f64) -> String {
    format!("{t}")
}

/// Index of the solution sample closest to `t` (`total_cmp`, so a NaN sample
/// cannot panic the comparison). `output_times` pins the sample grid, but the
/// trajectory lookups match defensively by closest time.
fn nearest_index(times: &[f64], t: f64) -> Option<usize> {
    (0..times.len()).min_by(|&a, &b| (times[a] - t).abs().total_cmp(&(times[b] - t).abs()))
}

fn solver_from(name: &str) -> SolverChoice {
    match name {
        "Bdf" | "bdf" => SolverChoice::Bdf,
        "Sdirk" | "sdirk" => SolverChoice::Sdirk,
        _ => SolverChoice::Erk,
    }
}

fn state_vec(names: &[String], state: &Map<String, Value>) -> Vec<f64> {
    // Probe states are keyed by the same bare slot names the evaluator uses.
    names
        .iter()
        .map(|n| state.get(n).and_then(Value::as_f64).unwrap_or(0.0))
        .collect()
}

fn run_fixture(fx: &Value, base: &Path, integ: &Value) -> Result<Value, String> {
    let rel = fx["path"].as_str().ok_or("fixture.path missing")?;
    let json_str = fs::read_to_string(base.join(rel)).map_err(|e| e.to_string())?;
    let file = load(&json_str).map_err(|e| format!("load: {e:?}"))?;
    let params: HashMap<String, f64> = HashMap::new();

    // --- RHS via the vectorized arrayop evaluator -------------------------
    let compiled = ArrayCompiled::from_file(&file).map_err(|e| format!("compile: {e:?}"))?;
    let names: Vec<String> = compiled.state_variable_names().to_vec();
    let mut rhs = Map::new();
    for probe in fx["rhs_probes"].as_array().ok_or("rhs_probes not array")? {
        let pid = probe["id"].as_str().ok_or("probe.id missing")?;
        let state_obj = probe["state"].as_object().ok_or("probe.state missing")?;
        let t = probe["t"].as_f64().unwrap_or(0.0);
        let sv = state_vec(&names, state_obj);
        let (dy, _stats) = compiled.debug_eval_rhs(&sv, t, &params, false);
        let mut m = Map::new();
        for (i, n) in names.iter().enumerate() {
            m.insert(bare(n).to_string(), json!(dy[i]));
        }
        rhs.insert(pid.to_string(), Value::Object(m));
    }

    // --- Trajectory via the pinned diffsol solver -------------------------
    let tr = &fx["trajectory"];
    let t0 = tr["time_span"]["start"].as_f64().ok_or("time_span.start")?;
    let t1 = tr["time_span"]["end"].as_f64().ok_or("time_span.end")?;
    let ics: HashMap<String, f64> = tr["initial_conditions"]
        .as_object()
        .ok_or("initial_conditions missing")?
        .iter()
        .map(|(k, v)| (k.clone(), v.as_f64().unwrap_or(0.0)))
        .collect();
    let out_times: Vec<f64> = tr["output_times"]
        .as_array()
        .ok_or("output_times missing")?
        .iter()
        .map(|v| v.as_f64().unwrap_or(0.0))
        .collect();
    let opts = SimulateOptions {
        solver: solver_from(integ["solver"].as_str().unwrap_or("Erk")),
        abstol: integ["abstol"].as_f64().unwrap_or(1e-12),
        reltol: integ["reltol"].as_f64().unwrap_or(1e-10),
        max_steps: 1_000_000,
        output_times: Some(out_times.clone()),
    };
    let sol =
        simulate(&file, (t0, t1), &params, &ics, &opts).map_err(|e| format!("simulate: {e:?}"))?;

    let mut traj = Map::new();
    for &t in &out_times {
        let idx = nearest_index(&sol.time, t).ok_or("empty solution time grid")?;
        let mut m = Map::new();
        for (row, n) in sol.state_variable_names.iter().enumerate() {
            m.insert(bare(n).to_string(), json!(sol.state[row][idx]));
        }
        traj.insert(time_key(t), Value::Object(m));
    }

    Ok(json!({ "rhs": Value::Object(rhs), "trajectory": Value::Object(traj) }))
}

/// Probe states in the full-pipeline manifest are keyed by BARE element names
/// (`O3[1,1]`) while the compiled evaluator's slot names carry the `Chemistry.`
/// namespace; look up by either.
fn state_vec_bare(names: &[String], state: &Map<String, Value>) -> Vec<f64> {
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
/// `<Loader>.<var>`, DESIGN §2), and emit the RHS at each probe state plus the
/// trajectory at each checkpoint. Reuses the Phase-1 machinery of
/// `tests/loaded_ic_bc_simulation.rs`.
fn run_fixture_full(fx: &Value, base: &Path, integ: &Value) -> Result<Value, String> {
    let rel = fx["path"].as_str().ok_or("fixture.path missing")?;
    let json_str = fs::read_to_string(base.join(rel)).map_err(|e| e.to_string())?;
    let file = load(&json_str).map_err(|e| format!("load: {e:?}"))?;
    let flat = flatten(&file).map_err(|e| format!("flatten: {e:?}"))?;
    let compiled = ArrayCompiled::from_flattened(&flat).map_err(|e| format!("compile: {e:?}"))?;

    // Install the static stub provider: materialize every manifest input into the
    // forcing buffer under its declared `<Loader>.<var>` name. No field is
    // injected by internal consumer name (R1); the scoped-`ic` fold reads
    // `InitialConditions.*` into u0 (R2) and the lifted gather resolves the wind /
    // inflow forcing from the loader name.
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

    // --- RHS at each probe via the vectorized arrayop evaluator ---------------
    let mut rhs = Map::new();
    for probe in fx["rhs_probes"].as_array().ok_or("rhs_probes not array")? {
        let pid = probe["id"].as_str().ok_or("probe.id missing")?;
        let state_obj = probe["state"].as_object().ok_or("probe.state missing")?;
        let t = probe["t"].as_f64().unwrap_or(0.0);
        let sv = state_vec_bare(&names, state_obj);
        let (dy, _stats) = compiled.debug_eval_rhs(&sv, t, &params, false);
        let mut m = Map::new();
        for (i, n) in names.iter().enumerate() {
            m.insert(bare(n).to_string(), json!(dy[i]));
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
    let opts = SimulateOptions {
        solver: solver_from(integ["solver"].as_str().unwrap_or("Erk")),
        abstol: integ["abstol"].as_f64().unwrap_or(1e-12),
        reltol: integ["reltol"].as_f64().unwrap_or(1e-10),
        max_steps: 10_000_000,
        output_times: Some(checkpoints.clone()),
    };
    let sol = compiled
        .simulate((t0, t1), &params, &HashMap::new(), &opts)
        .map_err(|e| format!("simulate: {e:?}"))?;

    let mut traj = Map::new();
    for &t in &checkpoints {
        let idx = nearest_index(&sol.time, t).ok_or("empty solution time grid")?;
        let mut m = Map::new();
        for (row, n) in sol.state_variable_names.iter().enumerate() {
            m.insert(bare(n).to_string(), json!(sol.state[row][idx]));
        }
        traj.insert(time_key(t), Value::Object(m));
    }

    Ok(json!({ "rhs": Value::Object(rhs), "trajectory": Value::Object(traj) }))
}

fn main() -> ExitCode {
    let args = match parse_manifest_output_args() {
        Ok(a) => a,
        Err(e) => {
            eprintln!("pde-sim-adapter-rust: {e}");
            return ExitCode::FAILURE;
        }
    };
    let (manifest_path, output_path) = (args.manifest, args.output);
    let manifest: Value = match fs::read_to_string(&manifest_path)
        .map_err(|e| e.to_string())
        .and_then(|s| serde_json::from_str(&s).map_err(|e| e.to_string()))
    {
        Ok(v) => v,
        Err(e) => {
            eprintln!("pde-sim-adapter-rust: failed to read manifest: {e}");
            return ExitCode::FAILURE;
        }
    };
    let base = manifest_path.parent().unwrap_or_else(|| Path::new("."));
    let integ = manifest
        .get("integrators")
        .and_then(|i| i.get("rust"))
        .cloned()
        .unwrap_or(Value::Null);

    let empty: Vec<Value> = Vec::new();
    let mut fixtures = Map::new();
    for fx in manifest["fixtures"].as_array().unwrap_or(&empty).iter() {
        let id = fx["id"].as_str().unwrap_or("<unknown>").to_string();
        let result = if fx.get("pipeline").and_then(Value::as_str) == Some("full") {
            run_fixture_full(fx, base, &integ)
        } else {
            run_fixture(fx, base, &integ)
        };
        let entry = match result {
            Ok(v) => v,
            Err(e) => {
                eprintln!("fixture {id}: {e}");
                json!({ "error": e })
            }
        };
        fixtures.insert(id, entry);
    }

    let payload = json!({ "binding": "rust", "fixtures": Value::Object(fixtures) });
    if let Err(e) = write_report(&output_path, &payload) {
        eprintln!("pde-sim-adapter-rust: failed to write output: {e}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}
