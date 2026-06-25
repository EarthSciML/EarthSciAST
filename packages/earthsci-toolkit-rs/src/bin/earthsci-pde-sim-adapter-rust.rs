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
use std::path::{Path, PathBuf};

use earthsci_toolkit::simulate_array::ArrayCompiled;
use earthsci_toolkit::{load, simulate, SimulateOptions, SolverChoice};
use serde_json::{json, Map, Value};

/// Strip a leading `Model.` namespace so element names match across bindings.
fn bare(name: &str) -> &str {
    name.split_once('.').map(|x| x.1).unwrap_or(name)
}

/// Trajectory time key; the Python harness re-normalizes every key via
/// `float(k):g`, so this only needs to round-trip as a float.
fn time_key(t: f64) -> String {
    format!("{t}")
}

fn solver_from(name: &str) -> SolverChoice {
    match name {
        "Bdf" | "bdf" => SolverChoice::Bdf,
        "Sdirk" | "sdirk" => SolverChoice::Sdirk,
        _ => SolverChoice::Erk,
    }
}

fn parse_args() -> Result<(PathBuf, PathBuf), String> {
    let mut manifest = None;
    let mut output = None;
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--manifest" => {
                manifest = args.get(i + 1).cloned();
                i += 2;
            }
            "--output" => {
                output = args.get(i + 1).cloned();
                i += 2;
            }
            _ => i += 1,
        }
    }
    Ok((
        PathBuf::from(manifest.ok_or("--manifest is required")?),
        PathBuf::from(output.ok_or("--output is required")?),
    ))
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
    let sol = simulate(&file, (t0, t1), &params, &ics, &opts).map_err(|e| format!("simulate: {e:?}"))?;

    let mut traj = Map::new();
    for &t in &out_times {
        // output_times pins the sample grid, but match defensively by closest time.
        let idx = (0..sol.time.len())
            .min_by(|&a, &b| {
                (sol.time[a] - t)
                    .abs()
                    .partial_cmp(&(sol.time[b] - t).abs())
                    .unwrap()
            })
            .ok_or("empty solution time grid")?;
        let mut m = Map::new();
        for (row, n) in sol.state_variable_names.iter().enumerate() {
            m.insert(bare(n).to_string(), json!(sol.state[row][idx]));
        }
        traj.insert(time_key(t), Value::Object(m));
    }

    Ok(json!({ "rhs": Value::Object(rhs), "trajectory": Value::Object(traj) }))
}

fn main() {
    let (manifest_path, output_path) = match parse_args() {
        Ok(v) => v,
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(2);
        }
    };
    let manifest: Value = match fs::read_to_string(&manifest_path)
        .map_err(|e| e.to_string())
        .and_then(|s| serde_json::from_str(&s).map_err(|e| e.to_string()))
    {
        Ok(v) => v,
        Err(e) => {
            eprintln!("failed to read manifest: {e}");
            std::process::exit(2);
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
        let entry = match run_fixture(fx, base, &integ) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("fixture {id}: {e}");
                json!({ "error": e })
            }
        };
        fixtures.insert(id, entry);
    }

    let payload = json!({ "binding": "rust", "fixtures": Value::Object(fixtures) });
    if let Err(e) = fs::write(&output_path, serde_json::to_string_pretty(&payload).unwrap()) {
        eprintln!("failed to write output: {e}");
        std::process::exit(1);
    }
}
