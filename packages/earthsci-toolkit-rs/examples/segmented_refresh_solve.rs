//! Driver-level segmented-solve over a discrete-cadence forced model
//! (bead ess-14f.11 / RS-R3, plan `esio-consumer-rust-plan`; parent ess-14f).
//!
//! Run it:
//! ```text
//! cargo run --example segmented_refresh_solve
//! ```
//!
//! # What this shows
//!
//! How a **user** integrates an Earth-system model whose RHS is forced by
//! external fields a data loader reads at a cadence (hourly emissions, 6-hourly
//! meteorology, boundary slices). The library exposes the pieces — each a datum
//! or pure function, never a solver:
//!
//!   * the **RHS**: an [`ArrayCompiled`] built from a flattened, discretized,
//!     coupled model, plus its live **forcing buffer**
//!     ([`ArrayCompiled::forcing_handle`]); and
//!   * the **refresh surface**: a [`RefreshExecutor`] with `refresh_times()`
//!     (the cadence anchors), `materialize_const()` (CONST load once), and
//!     `refresh_at(t)` (DISCRETE refresh + regrid + buffer write).
//!
//! The **segmented-solve loop below is the driver** — user-owned, deliberately
//! NOT in the library API (`library-exposes-rhs-not-solver`). It integrates one
//! segment per cadence interval, refreshing the forcing once at each boundary,
//! threading state across segments, and restarting the solver at each
//! discontinuity (a fresh `simulate()` per segment restarts the BDF order at 1).
//!
//! The rigorous contract assertions (CONST-once, refresh-once-per-boundary, RHS
//! pure within a segment, state-threading-is-load-bearing, closed-form match)
//! live in the twin integration test `tests/segmented_refresh_solve.rs`.
//!
//! # The model
//!
//! Two coupled components over a 3-cell index `i ∈ [1, 3]` (a discretized,
//! COUPLED, non-PDE system — no spatial operator, just `arrayop` ODEs):
//!
//!   * `Box.c[i]`: `D(c[i]) = scale[i]·src[i]` — accumulates a loader-fed
//!     source `src` (DISCRETE, refreshed hourly) scaled by a CONST factor field
//!     `scale` (loaded once). Both are undeclared forcing names resolved through
//!     the forcing buffer.
//!   * `Sink.d[i]`: `D(d[i]) = Box.c[i]` — integrates the coupled tracer across
//!     the component boundary (a dotted cross-system reference).

#![cfg(not(target_arch = "wasm32"))]

use earthsci_toolkit::flatten::flatten;
use earthsci_toolkit::provider::{
    CadenceProvider, ForcingBuffer, NativeField, ProviderError, RefreshExecutor,
};
use earthsci_toolkit::simulate_array::ArrayCompiled;
use earthsci_toolkit::{SimulateOptions, Solution, SolverChoice, load};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};
use std::collections::HashMap;

/// The `ArrayCompiled` (simulate) view: `scale`/`src` are undeclared forcing
/// names (they namespace to `Box.scale`/`Box.src` post-flatten and resolve
/// through the forcing buffer); `Box.c` is the dotted reference Sink couples to.
const COUPLED_FORCED_JSON: &str = r#"{
 "esm": "0.1.0",
 "metadata": {"name": "segmented_refresh_coupled"},
 "models": {
  "Box": {
   "variables": {"c": {"type": "state", "shape": ["i"], "default": 0.0}},
   "equations": [
    {
     "lhs": {"op": "arrayop", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
             "expr": {"op": "D", "args": [{"op": "index", "args": ["c", "i"]}], "wrt": "t"}},
     "rhs": {"op": "arrayop", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
             "expr": {"op": "*", "args": [
                {"op": "index", "args": ["scale", "i"]},
                {"op": "index", "args": ["src", "i"]}
             ]}}
    }
   ]
  },
  "Sink": {
   "variables": {"d": {"type": "state", "shape": ["i"], "default": 0.0}},
   "equations": [
    {
     "lhs": {"op": "arrayop", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
             "expr": {"op": "D", "args": [{"op": "index", "args": ["d", "i"]}], "wrt": "t"}},
     "rhs": {"op": "arrayop", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
             "expr": {"op": "index", "args": ["Box.c", "i"]}}
    }
   ]
  }
 }
}"#;

/// The cadence-classification view for [`RefreshExecutor`]: `src` is DISCRETE
/// (loader `emis` has a `temporal` block), `scale` is CONST (loader `factors`
/// has none). The typed `ArrayCompiled` never sees these — only the executor's
/// raw-JSON classifier does.
fn classification_doc() -> Value {
    json!({
        "models": {"Box": {"variables": {
            "src":   {"type": "discrete", "shape": ["i"],
                      "refresh": {"kind": "data_ingest", "source": "emis"}},
            "scale": {"type": "discrete", "shape": ["i"],
                      "refresh": {"kind": "data_ingest", "source": "factors"}}
        }}},
        "data_loaders": {
            "emis":    {"kind": "grid", "temporal": {"frequency": "PT1H"}},
            "factors": {"kind": "static"}
        }
    })
}

/// An in-memory [`CadenceProvider`] feeding ONE forcing variable, standing in
/// for the EarthSciIO Rust Provider a real driver would wrap. `out_key` is the
/// post-flatten forcing-buffer key the RHS looks up (e.g. `"Box.src"`).
struct ScheduledProvider {
    out_key: String,
    const_value: Option<Vec<f64>>,
    schedule: Vec<(f64, Vec<f64>)>,
}

impl ScheduledProvider {
    fn const_loader(out_key: &str, value: [f64; 3]) -> Self {
        Self {
            out_key: out_key.to_string(),
            const_value: Some(value.to_vec()),
            schedule: Vec::new(),
        }
    }
    fn discrete_loader(out_key: &str, schedule: &[(f64, [f64; 3])]) -> Self {
        Self {
            out_key: out_key.to_string(),
            const_value: None,
            schedule: schedule.iter().map(|(t, v)| (*t, v.to_vec())).collect(),
        }
    }
}

impl CadenceProvider for ScheduledProvider {
    fn materialize(&mut self) -> Result<HashMap<String, NativeField>, ProviderError> {
        let v = self.const_value.clone().expect("CONST baseline");
        Ok(HashMap::from([(self.out_key.clone(), field(&v))]))
    }
    fn refresh(&mut self, t: f64) -> Result<Option<HashMap<String, NativeField>>, ProviderError> {
        for (anchor, value) in &self.schedule {
            if *anchor == t {
                return Ok(Some(HashMap::from([(self.out_key.clone(), field(value))])));
            }
        }
        Ok(None)
    }
    fn refresh_times(&self) -> Vec<f64> {
        self.schedule.iter().map(|(t, _)| *t).collect()
    }
}

fn field(v: &[f64]) -> NativeField {
    NativeField::new(ArrayD::from_shape_vec(IxDyn(&[v.len()]), v.to_vec()).unwrap())
}

/// The driver: integrate `compiled` across the DISCRETE cadence anchors,
/// refreshing the forcing buffer once per boundary and threading state across
/// segments. This loop — not anything in the library — is the segmented solve.
fn segmented_solve(
    compiled: &ArrayCompiled,
    exec: &mut RefreshExecutor,
    forcing: &ForcingBuffer,
    tspan: (f64, f64),
    initial_conditions: &HashMap<String, f64>,
    base_opts: &SimulateOptions,
) -> Result<Solution, Box<dyn std::error::Error>> {
    let (t0, t_end) = tspan;
    let params = HashMap::new();

    // (1) CONST forcings: loaded once, before integrating.
    let const_vars = exec.materialize_const(forcing)?;
    println!("setup: materialized CONST forcings once -> {const_vars:?}");

    // (2) DISCRETE anchors -> segment endpoints within the window.
    let mut endpoints = vec![t0];
    for t in exec.refresh_times() {
        if t > t0 && t < t_end {
            endpoints.push(t);
        }
    }
    endpoints.push(t_end);
    println!("cadence anchors -> segment endpoints: {endpoints:?}\n");

    // (3) Integrate segment by segment.
    let mut ics = initial_conditions.clone();
    let mut last: Option<Solution> = None;
    for pair in endpoints.windows(2) {
        let (seg_start, seg_end) = (pair[0], pair[1]);

        // Refresh THIS segment's forcing at its start boundary — once.
        let refreshed = exec.refresh_at(seg_start, forcing)?;
        println!(
            "boundary t={seg_start}: refreshed {refreshed:?} -> Box.src = {:?}",
            buffer_value(forcing, "Box.src")
        );

        // Fresh solver per segment (restarts the order at the discontinuity).
        let mut opts = base_opts.clone();
        opts.output_times = Some(vec![seg_end]);
        let sol = compiled.simulate((seg_start, seg_end), &params, &ics, &opts)?;

        println!(
            "  integrated [{seg_start}, {seg_end}] -> Box.c = {:?}, Sink.d = {:?}",
            states(&sol, "Box.c"),
            states(&sol, "Sink.d")
        );

        // Thread state into the next segment.
        ics = final_state_ics(compiled, &sol);
        last = Some(sol);
    }
    Ok(last.expect("at least one segment"))
}

fn final_state_ics(compiled: &ArrayCompiled, sol: &Solution) -> HashMap<String, f64> {
    compiled
        .state_variable_names()
        .iter()
        .map(|name| (name.clone(), final_value(sol, name)))
        .collect()
}

fn final_value(sol: &Solution, name: &str) -> f64 {
    let row = sol
        .state_variable_names
        .iter()
        .position(|n| n == name)
        .unwrap_or_else(|| panic!("slot {name:?} not in {:?}", sol.state_variable_names));
    *sol.state[row].last().expect("an output time")
}

/// Final-time values of the three cells of an array state (e.g. `"Box.c"`).
fn states(sol: &Solution, base: &str) -> Vec<f64> {
    (1..=3)
        .map(|i| final_value(sol, &format!("{base}[{i}]")))
        .collect()
}

/// A forcing-buffer field's values (for printing the live forcing).
fn buffer_value(forcing: &ForcingBuffer, var: &str) -> Vec<f64> {
    forcing
        .borrow()
        .get(var)
        .map(|a| a.iter().copied().collect())
        .unwrap_or_default()
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Build the coupled, discretized RHS: flatten merges the two components into
    // one namespaced system; the `from_flattened` seam compiles that array system.
    let file = load(COUPLED_FORCED_JSON)?;
    let flat = flatten(&file)?;
    let compiled = ArrayCompiled::from_flattened(&flat)?;

    // Wire the refresh executor: emis (DISCRETE, hourly) -> Box.src, factors
    // (CONST) -> Box.scale, identity regrid (the native grid is the sim grid).
    let doc = classification_doc();
    let scale: [f64; 3] = [1.0, 2.0, 3.0];
    let src_at: [(f64, [f64; 3]); 3] = [
        (0.0, [1.0, 1.0, 1.0]),
        (1.0, [2.0, 2.0, 2.0]),
        (2.0, [3.0, 3.0, 3.0]),
    ];
    let providers: HashMap<String, Box<dyn CadenceProvider>> = HashMap::from([
        (
            "emis".to_string(),
            Box::new(ScheduledProvider::discrete_loader("Box.src", &src_at))
                as Box<dyn CadenceProvider>,
        ),
        (
            "factors".to_string(),
            Box::new(ScheduledProvider::const_loader("Box.scale", scale))
                as Box<dyn CadenceProvider>,
        ),
    ]);
    let mut exec = RefreshExecutor::new(&doc["models"]["Box"], &doc, providers)?;

    // The forcing buffer the RHS reads live, and zero initial conditions.
    let forcing = compiled.forcing_handle();
    let ics0: HashMap<String, f64> = compiled
        .state_variable_names()
        .iter()
        .map(|n| (n.clone(), 0.0))
        .collect();

    let opts = SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-10,
        reltol: 1e-8,
        max_steps: 100_000,
        output_times: None,
    };

    println!("=== Segmented discrete-cadence solve (coupled, forced, non-PDE) ===\n");
    let sol = segmented_solve(&compiled, &mut exec, &forcing, (0.0, 3.0), &ics0, &opts)?;

    let c = states(&sol, "Box.c");
    let d = states(&sol, "Sink.d");
    println!("\nfinal state at t=3:");
    println!("  Box.c  = {c:?}   (Σ scale·src across segments)");
    println!("  Sink.d = {d:?}   (coupled integral of Box.c)");

    // Stay honest: the closed form (piecewise-constant forcing integrates exactly).
    let expect_c = [6.0, 12.0, 18.0];
    let expect_d = [7.0, 14.0, 21.0];
    for i in 0..3 {
        assert!(
            (c[i] - expect_c[i]).abs() < 1e-4,
            "Box.c mismatch at cell {i}"
        );
        assert!(
            (d[i] - expect_d[i]).abs() < 1e-4,
            "Sink.d mismatch at cell {i}"
        );
    }
    println!("\nclosed-form check passed.");
    Ok(())
}
