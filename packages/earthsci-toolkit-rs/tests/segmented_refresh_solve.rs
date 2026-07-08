//! Driver-level segmented-solve harness (bead ess-14f.11 / RS-R3, plan
//! `esio-consumer-rust-plan`; parent ess-14f).
//!
//! # What this is
//!
//! A discrete-cadence Earth-system model forces its RHS with external fields a
//! data loader reads at a cadence (6-hourly meteorology, hourly emissions,
//! boundary-condition slices). The pieces to integrate such a model are already
//! exposed by the library, each a *datum or pure function*, never a solver:
//!
//!   * the **RHS** — [`ArrayCompiled`] built from a flattened, discretized,
//!     coupled model ([`ArrayCompiled::from_flattened`], the PR-3 seam), plus
//!     its live **forcing buffer** ([`ArrayCompiled::forcing_handle`], PR-1);
//!   * the **refresh surface** — [`RefreshExecutor`] (R-1): its
//!     [`refresh_times`](RefreshExecutor::refresh_times) (the cadence anchors),
//!     [`materialize_const`](RefreshExecutor::materialize_const) (CONST load
//!     once), and [`refresh_at`](RefreshExecutor::refresh_at) (DISCRETE refresh
//!     at an anchor, write the buffer).
//!
//! This file is the **driver** that composes them into a segmented time
//! integration — the user-owned harness the plan (§6) deliberately keeps *out*
//! of the library API so `library-exposes-rhs-not-solver` holds. There is no
//! `solve`/`simulate`/`run` added to the library for the refresh case; the
//! driver below is exactly what a user would write, and [`segmented_solve`] is
//! its core loop. A runnable twin lives at `examples/segmented_refresh_solve.rs`.
//!
//! # The cadence contract this harness realizes and asserts
//!
//! 1. **CONST loaded once.** `materialize_const` runs once at setup; the CONST
//!    field never refreshes ([`const_materialized_once_discrete_refreshed_once_per_boundary`]).
//! 2. **DISCRETE anchors drive the segments.** `refresh_times()` ∩ window are
//!    the segment boundaries.
//! 3. **Refresh once per boundary, RHS pure within a segment.** The forcing
//!    buffer is mutated only at boundaries, never inside a solver step, so the
//!    RHS sees one frozen forcing per segment
//!    ([`forcing_is_constant_within_a_segment_so_rhs_is_pure`]).
//! 4. **State threads across segments.** Each segment's final state seeds the
//!    next; dropping that thread changes the answer
//!    ([`state_threading_is_load_bearing`]).
//! 5. **Fresh solver per segment.** Each segment is a fresh [`ArrayCompiled::simulate`]
//!    — a fresh BDF solver whose order restarts at 1, the conservative treatment
//!    of the forcing discontinuity at the boundary (plan §3 / risk R1; the
//!    persistent-solver alternative would `checkpoint()`/`set_state()` for the
//!    same order reset, but that needs the solver object the public API keeps
//!    private — the fresh-`simulate()` restart gets the order reset for free).
//!
//! # The fixture: a discretized, COUPLED, non-PDE forced model
//!
//! Two components over a 3-cell index `i ∈ [1, 3]` (acceptance: a *coupled
//! non-PDE* discretized fixture):
//!
//!   * `Box.c[i]` accumulates a loader-fed source scaled by a const factor:
//!     `D(c[i]) = scale[i]·src[i]`. `scale` is CONST (a static field, loaded
//!     once); `src` is DISCRETE (refreshed at the cadence). Both are
//!     **undeclared** in `variables` — they resolve through the forcing buffer
//!     (`lookup_variable` checks the buffer last, after state/observed/params).
//!   * `Sink.d[i]` integrates the coupled tracer across the component boundary:
//!     `D(d[i]) = Box.c[i]` — a dotted cross-system reference, the coupling the
//!     `from_flattened` seam carries through namespacing.
//!
//! No spatial operator appears (non-PDE): the equations are plain `arrayop`
//! ODEs over a dense `[1, 3]` range. Dense ranges (not `{from: <set>}`) are
//! required on this path — `index_sets` are not carried through flatten yet
//! (ess-14f.13) — and are exactly what a discretized stencil emits.
//!
//! The forcing is piecewise-constant across segments, so the dynamics integrate
//! to a closed form and the run is checkable to solver tolerance.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_toolkit::flatten::flatten;
use earthsci_toolkit::provider::{
    CadenceProvider, ForcingBuffer, NativeField, ProviderError, RefreshExecutor,
};
use earthsci_toolkit::simulate_array::ArrayCompiled;
use earthsci_toolkit::{SimulateOptions, Solution, SolverChoice, load};
use ndarray::{ArrayD, IxDyn};
use serde_json::{Value, json};
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

// ===========================================================================
// Fixture
// ===========================================================================

/// The `ArrayCompiled` (simulate) view of the coupled forced model. `scale` and
/// `src` are undeclared forcing names (they namespace to `Box.scale`/`Box.src`
/// post-flatten and resolve through the forcing buffer); `Box.c` is the dotted
/// cross-system reference Sink reads.
const COUPLED_FORCED_JSON: &str = r#"{
 "esm": "0.1.0",
 "metadata": {"name": "segmented_refresh_coupled"},
 "models": {
  "Box": {
   "variables": {"c": {"type": "state", "shape": ["i"], "default": 0.0}},
   "equations": [
    {
     "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
             "expr": {"op": "D", "args": [{"op": "index", "args": ["c", "i"]}], "wrt": "t"}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
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
     "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
             "expr": {"op": "D", "args": [{"op": "index", "args": ["d", "i"]}], "wrt": "t"}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
             "expr": {"op": "index", "args": ["Box.c", "i"]}}
    }
   ]
  }
 }
}"#;

/// The cadence-classification view (raw JSON for [`RefreshExecutor`]). Declares
/// `src` DISCRETE (loader `emis` has a `temporal` block) and `scale` CONST
/// (loader `factors` has none). This is the §2.B sidestep of a `Discrete`
/// `VariableType`: the typed `ArrayCompiled` never sees these declarations (it
/// resolves `Box.src`/`Box.scale` as forcing names); only the executor's
/// raw-JSON classifier does. `classify_loader_bindings` reads raw JSON and
/// never typed-parses, so the two views coexist on one model.
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

/// The CONST factor field `Box.scale` (per-cell, distinct to pin indexing).
const SCALE: [f64; 3] = [1.0, 2.0, 3.0];
/// The DISCRETE source `Box.src` at its three hourly anchors.
const SRC_AT: [(f64, [f64; 3]); 3] = [
    (0.0, [1.0, 1.0, 1.0]),
    (1.0, [2.0, 2.0, 2.0]),
    (2.0, [3.0, 3.0, 3.0]),
];

// ===========================================================================
// An in-memory provider — the test stand-in for the EarthSciIO Rust Provider
// ===========================================================================

/// A hand-built [`CadenceProvider`] feeding ONE forcing variable, standing in
/// for the EarthSciIO Rust Provider (esio-9nb.7) the real driver wraps via a
/// thin adapter. `out_key` is the post-flatten forcing-buffer key the RHS looks
/// up (e.g. `"Box.src"`). It records its `materialize`/`refresh` calls so the
/// harness can assert the cadence contract (CONST once, DISCRETE once per
/// boundary). No I/O — the "testable with a hand-built buffer" contract the plan
/// specifies.
struct ScheduledProvider {
    out_key: String,
    /// CONST baseline returned by `materialize`; `None` for a pure-DISCRETE
    /// loader.
    const_value: Option<Vec<f64>>,
    /// DISCRETE anchors → field. A `refresh(t)` at an anchor returns its field;
    /// off-anchor it returns `None` (the executor then skips the write).
    schedule: Vec<(f64, Vec<f64>)>,
    materialize_calls: Rc<RefCell<usize>>,
    refresh_log: Rc<RefCell<Vec<f64>>>,
}

impl ScheduledProvider {
    fn const_loader(out_key: &str, value: [f64; 3]) -> Self {
        Self {
            out_key: out_key.to_string(),
            const_value: Some(value.to_vec()),
            schedule: Vec::new(),
            materialize_calls: Rc::new(RefCell::new(0)),
            refresh_log: Rc::new(RefCell::new(Vec::new())),
        }
    }
    fn discrete_loader(out_key: &str, schedule: &[(f64, [f64; 3])]) -> Self {
        Self {
            out_key: out_key.to_string(),
            const_value: None,
            schedule: schedule.iter().map(|(t, v)| (*t, v.to_vec())).collect(),
            materialize_calls: Rc::new(RefCell::new(0)),
            refresh_log: Rc::new(RefCell::new(Vec::new())),
        }
    }
}

impl CadenceProvider for ScheduledProvider {
    fn materialize(&mut self) -> Result<HashMap<String, NativeField>, ProviderError> {
        *self.materialize_calls.borrow_mut() += 1;
        let v = self
            .const_value
            .clone()
            .expect("materialize on a provider with no CONST baseline");
        Ok(HashMap::from([(self.out_key.clone(), field(&v))]))
    }
    fn refresh(&mut self, t: f64) -> Result<Option<HashMap<String, NativeField>>, ProviderError> {
        self.refresh_log.borrow_mut().push(t);
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

/// A 1-D native field from a value vector (written straight into the buffer).
fn field(v: &[f64]) -> NativeField {
    NativeField::new(ArrayD::from_shape_vec(IxDyn(&[v.len()]), v.to_vec()).unwrap())
}

// ===========================================================================
// The driver — a user-owned segmented solve (NOT library API)
// ===========================================================================

/// Integrate `compiled` across the DISCRETE cadence anchors, refreshing the
/// forcing buffer once per boundary and threading state across segments. This
/// is the R-3 harness loop — the segmented-solve the plan keeps in user/driver
/// space, composed entirely from the library's exposed RHS + refresh surface.
///
/// Steps (the cadence contract):
///  1. `materialize_const` — CONST forcings, once, before integrating.
///  2. Segment endpoints = `t0`, the interior `refresh_times()` anchors, `t_end`.
///  3. For each segment `[a, b)`: `refresh_at(a)` (initial load at `t0`, then
///     each interior anchor — once per boundary), then `simulate((a, b))` with
///     the forcing frozen for the segment (RHS pure), seeding the next segment
///     with this one's final state (state threaded). A fresh `simulate()` per
///     segment restarts the solver order at the discontinuity.
fn segmented_solve(
    compiled: &ArrayCompiled,
    exec: &mut RefreshExecutor,
    forcing: &ForcingBuffer,
    tspan: (f64, f64),
    initial_conditions: &HashMap<String, f64>,
    params: &HashMap<String, f64>,
    base_opts: &SimulateOptions,
) -> Result<Solution, Box<dyn std::error::Error>> {
    let (t0, t_end) = tspan;

    // (1) CONST forcings: loaded once, before any integration.
    exec.materialize_const(forcing)?;

    // (2) DISCRETE anchors → segment endpoints within the window.
    let mut endpoints = vec![t0];
    for t in exec.refresh_times() {
        if t > t0 && t < t_end {
            endpoints.push(t);
        }
    }
    endpoints.push(t_end);

    // (3) Integrate segment by segment.
    let mut ics = initial_conditions.clone();
    let mut last: Option<Solution> = None;
    for pair in endpoints.windows(2) {
        let (seg_start, seg_end) = (pair[0], pair[1]);

        // Refresh THIS segment's forcing at its start boundary — once. Mutating
        // the buffer only here (between `simulate` calls, never inside a step)
        // is what keeps the RHS pure for the whole segment.
        exec.refresh_at(seg_start, forcing)?;

        // Fresh solver each segment (order restarts at the discontinuity). Pin
        // the single output node to the segment end so threading reads it
        // directly.
        let mut opts = base_opts.clone();
        opts.output_times = Some(vec![seg_end]);
        let sol = compiled.simulate((seg_start, seg_end), params, &ics, &opts)?;

        // Thread state: this segment's final scalar states seed the next.
        ics = final_state_ics(compiled, &sol);
        last = Some(sol);
    }
    Ok(last.expect("at least one segment"))
}

/// The state-threading step: pull each scalar state's final-time value out of a
/// segment [`Solution`], keyed by the slot name [`ArrayCompiled::simulate`]
/// expects as an initial condition.
fn final_state_ics(compiled: &ArrayCompiled, sol: &Solution) -> HashMap<String, f64> {
    compiled
        .state_variable_names()
        .iter()
        .map(|name| (name.clone(), final_value(sol, name)))
        .collect()
}

/// Final-time value of a named scalar state slot (e.g. `"Box.c[1]"`).
fn final_value(sol: &Solution, name: &str) -> f64 {
    let row = sol
        .state_variable_names
        .iter()
        .position(|n| n == name)
        .unwrap_or_else(|| {
            panic!(
                "state slot {name:?} not found; have {:?}",
                sol.state_variable_names
            )
        });
    *sol.state[row].last().expect("at least one output time")
}

// ===========================================================================
// Harness wiring shared by the tests
// ===========================================================================

/// Build the coupled `ArrayCompiled` (flatten → `from_flattened` seam).
fn build_compiled() -> ArrayCompiled {
    let file = load(COUPLED_FORCED_JSON).expect("load coupled forced model");
    let flat = flatten(&file).expect("flatten coupled forced model");
    ArrayCompiled::from_flattened(&flat).expect("from_flattened compiles coupled forced model")
}

/// What [`build_executor`] returns: the wired executor and the model's forcing
/// handle, plus the two providers' call counters the contract tests assert on.
struct Wiring {
    exec: RefreshExecutor,
    forcing: ForcingBuffer,
    /// `factors` (CONST) materialize-call count — asserted == 1.
    const_materialize_calls: Rc<RefCell<usize>>,
    /// `emis` (DISCRETE) refresh-call log — asserted == one entry per boundary.
    discrete_refresh_log: Rc<RefCell<Vec<f64>>>,
}

/// Wire the refresh executor for `compiled`: `emis` (DISCRETE) → `Box.src`,
/// `factors` (CONST) → `Box.scale`.
fn build_executor(compiled: &ArrayCompiled) -> Wiring {
    let doc = classification_doc();

    let emis = ScheduledProvider::discrete_loader("Box.src", &SRC_AT);
    let factors = ScheduledProvider::const_loader("Box.scale", SCALE);
    let discrete_refresh_log = Rc::clone(&emis.refresh_log);
    let const_materialize_calls = Rc::clone(&factors.materialize_calls);

    let providers: HashMap<String, Box<dyn CadenceProvider>> = HashMap::from([
        (
            "emis".to_string(),
            Box::new(emis) as Box<dyn CadenceProvider>,
        ),
        (
            "factors".to_string(),
            Box::new(factors) as Box<dyn CadenceProvider>,
        ),
    ]);

    // No regrid seam: this fixture's native fields are already on the sim grid
    // (shape [3] = i∈[1,3]), so the executor writes them straight into the buffer.
    // A real consumer expresses any native→sim regrid as an in-model coupling
    // contraction the RHS evaluates, not a refresh-time transform.
    let exec = RefreshExecutor::new(&doc["models"]["Box"], &doc, providers)
        .expect("classify + pair providers");

    Wiring {
        exec,
        forcing: compiled.forcing_handle(),
        const_materialize_calls,
        discrete_refresh_log,
    }
}

/// Zero initial conditions over every scalar state slot.
fn zero_ics(compiled: &ArrayCompiled) -> HashMap<String, f64> {
    compiled
        .state_variable_names()
        .iter()
        .map(|n| (n.clone(), 0.0))
        .collect()
}

fn base_opts() -> SimulateOptions {
    SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-10,
        reltol: 1e-8,
        max_steps: 100_000,
        output_times: None, // segmented_solve pins each segment's output node
    }
}

// ===========================================================================
// Tests
// ===========================================================================

/// The acceptance run: a segmented solve over the coupled, discretized, non-PDE
/// forced fixture refreshes the forcing at each anchor and integrates across,
/// threading state — matching the closed form.
///
/// Forcing is piecewise-constant per segment, so the dynamics are exact:
///   rate `r_k = scale · src_k`:  r₀=[1,2,3], r₁=[2,4,6], r₂=[3,6,9].
///   `Box.c(3) = Σ r_k = [6, 12, 18]`  (each segment is Δt = 1).
///   `Sink.d(3) = ∫₀³ c dt = 2.5·r₀ + 1.5·r₁ + 0.5·r₂ = [7, 14, 21]`
///   (c is piecewise-linear, c(k) = Σ_{j<k} r_j, ∫ over a unit segment =
///    c(k) + ½·r_k).
#[test]
fn segmented_run_over_coupled_forced_fixture_matches_closed_form() {
    let compiled = build_compiled();

    // Both coupled components contribute their array slots to the state vector.
    let names = compiled.state_variable_names();
    for slot in ["Box.c[1]", "Box.c[3]", "Sink.d[1]", "Sink.d[3]"] {
        assert!(
            names.iter().any(|n| n == slot),
            "expected coupled state slot {slot}, have {names:?}"
        );
    }

    let Wiring {
        mut exec, forcing, ..
    } = build_executor(&compiled);

    // The driver's tstops are exactly the DISCRETE cadence anchors.
    assert_eq!(
        exec.refresh_times(),
        vec![0.0, 1.0, 2.0],
        "refresh_times is the union of the DISCRETE anchors (CONST adds none)"
    );

    let ics0 = zero_ics(&compiled);
    let sol = segmented_solve(
        &compiled,
        &mut exec,
        &forcing,
        (0.0, 3.0),
        &ics0,
        &HashMap::new(),
        &base_opts(),
    )
    .expect("segmented solve");

    for (i, c_expected, d_expected) in [(1usize, 6.0, 7.0), (2, 12.0, 14.0), (3, 18.0, 21.0)] {
        let c = final_value(&sol, &format!("Box.c[{i}]"));
        let d = final_value(&sol, &format!("Sink.d[{i}]"));
        assert!(
            (c - c_expected).abs() < 1e-4,
            "Box.c[{i}](3) = {c}, expected {c_expected} (accumulated scale·src across segments)"
        );
        assert!(
            (d - d_expected).abs() < 1e-4,
            "Sink.d[{i}](3) = {d}, expected {d_expected} (coupled integral of Box.c)"
        );
    }
}

/// Cadence contract: the CONST field is materialized exactly once, and the
/// DISCRETE field is refreshed exactly once per boundary (the initial load at
/// `t0` plus each interior anchor) — never inside a segment.
#[test]
fn const_materialized_once_discrete_refreshed_once_per_boundary() {
    let compiled = build_compiled();
    let Wiring {
        mut exec,
        forcing,
        const_materialize_calls,
        discrete_refresh_log,
    } = build_executor(&compiled);
    let ics0 = zero_ics(&compiled);

    segmented_solve(
        &compiled,
        &mut exec,
        &forcing,
        (0.0, 3.0),
        &ics0,
        &HashMap::new(),
        &base_opts(),
    )
    .expect("segmented solve");

    assert_eq!(
        *const_materialize_calls.borrow(),
        1,
        "CONST `factors` (Box.scale) materialized exactly once, at setup"
    );
    assert_eq!(
        *discrete_refresh_log.borrow(),
        vec![0.0, 1.0, 2.0],
        "DISCRETE `emis` (Box.src) refreshed once per boundary: t0 load + interior anchors"
    );
}

/// Refresh-once-per-boundary ⇒ the forcing is frozen for a whole segment, so the
/// RHS is pure within it. After loading the segment-[0,1] forcing, the RHS reads
/// the same `scale·src` at every interior time, and it equals the CONST×DISCRETE
/// product the executor wrote — proving both forcings reach the RHS live.
#[test]
fn forcing_is_constant_within_a_segment_so_rhs_is_pure() {
    let compiled = build_compiled();
    let Wiring {
        mut exec, forcing, ..
    } = build_executor(&compiled);

    // Setup as the driver's first boundary does: CONST once, then the t=0 load.
    exec.materialize_const(&forcing).expect("materialize const");
    exec.refresh_at(0.0, &forcing).expect("load segment [0,1]");

    // The RHS reads the SAME forcing anywhere inside the segment — the buffer is
    // not touched again until the next boundary.
    let names = compiled.state_variable_names().to_vec();
    let state = vec![0.0f64; names.len()];
    let params = HashMap::new();
    let (dy_at_0, _) = compiled.debug_eval_rhs(&state, 0.0, &params, false);
    let (dy_at_half, _) = compiled.debug_eval_rhs(&state, 0.5, &params, false);
    assert_eq!(
        dy_at_0, dy_at_half,
        "forcing is frozen within the segment → the RHS is time-invariant here (pure)"
    );

    // D(Box.c[i]) = scale[i]·src[i] = [1,2,3]·[1,1,1] = [1,2,3]; D(Sink.d[i]) =
    // Box.c[i] = 0 at zero state. Both forcings reached the RHS.
    let dy_of = |slot: &str| dy_at_0[names.iter().position(|n| n == slot).unwrap()];
    for (i, expected) in [(1usize, 1.0), (2, 2.0), (3, 3.0)] {
        assert!(
            (dy_of(&format!("Box.c[{i}]")) - expected).abs() < 1e-12,
            "D(Box.c[{i}]) = scale·src = {expected}"
        );
        assert_eq!(
            dy_of(&format!("Sink.d[{i}]")),
            0.0,
            "D(Sink.d[{i}]) = Box.c[{i}] = 0 at zero state"
        );
    }
}

/// State threading is load-bearing: a driver that resets the state at every
/// segment instead of threading it gets a different (wrong) coupled integral.
/// This pins that [`segmented_solve`] actually carries state across boundaries.
#[test]
fn state_threading_is_load_bearing() {
    let compiled = build_compiled();

    // Proper threaded run.
    let Wiring {
        mut exec, forcing, ..
    } = build_executor(&compiled);
    let ics0 = zero_ics(&compiled);
    let threaded = segmented_solve(
        &compiled,
        &mut exec,
        &forcing,
        (0.0, 3.0),
        &ics0,
        &HashMap::new(),
        &base_opts(),
    )
    .expect("threaded solve");
    assert!(
        (final_value(&threaded, "Sink.d[1]") - 7.0).abs() < 1e-4,
        "threaded Sink.d[1](3) = 7"
    );

    // Broken run: identical refresh schedule, but each segment restarts from
    // zero state (no threading). The last segment [2,3] integrates from c=0
    // under src₂=[3,3,3], giving Sink.d[i] = ½·scale·src₂ = ½·[3,6,9] = [1.5,…];
    // far from the threaded 7.
    let Wiring {
        exec: mut exec2,
        forcing: forcing2,
        ..
    } = build_executor(&compiled);
    exec2.materialize_const(&forcing2).unwrap();
    let mut last = None;
    for (seg_start, seg_end) in [(0.0, 1.0), (1.0, 2.0), (2.0, 3.0)] {
        exec2.refresh_at(seg_start, &forcing2).unwrap();
        let mut opts = base_opts();
        opts.output_times = Some(vec![seg_end]);
        // NOTE the bug: zero ICs every segment instead of threading.
        last = Some(
            compiled
                .simulate(
                    (seg_start, seg_end),
                    &HashMap::new(),
                    &zero_ics(&compiled),
                    &opts,
                )
                .unwrap(),
        );
    }
    let broken = last.unwrap();
    let broken_d1 = final_value(&broken, "Sink.d[1]");
    assert!(
        (broken_d1 - 1.5).abs() < 1e-4,
        "un-threaded Sink.d[1](3) = 1.5 (last segment only, from zero state), got {broken_d1}"
    );
    assert!(
        (broken_d1 - 7.0).abs() > 1.0,
        "dropping the state thread changes the answer — threading is load-bearing"
    );
}
