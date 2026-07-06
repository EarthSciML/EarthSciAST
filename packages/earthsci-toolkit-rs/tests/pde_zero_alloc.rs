//! Zero-allocation verification for the Rust PDE tier (ess-mro).
//!
//! The vectorized whole-array stencil evaluator (ess-bdm) is algorithmically
//! N-independent, but it used to allocate `O(#AST-nodes)` arrays per RHS call.
//! diffsol's RHS is in-place (`call_inplace` writes the solver-owned `dy`), so
//! there is no allocation floor: a correct closure can be 100% allocation-free.
//! `RhsScratch` carries the reusable per-variable state arrays, the observed
//! container, and a buffer pool across diffsol steps so the steady-state
//! vectorized RHS performs **zero** heap allocations.
//!
//! This test wraps the global allocator with a counter and asserts that, after
//! a warm-up, a tight loop of vectorized RHS evaluations allocates nothing — at
//! **two** grid sizes, so the property is both N-independent and ≈0 (ess-mro
//! acceptance criterion 1). It lives in its own test binary with a single test
//! so no other test thread perturbs the process-wide allocation counter.

#![cfg(not(target_arch = "wasm32"))]

use std::alloc::{GlobalAlloc, Layout, System};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use earthsci_toolkit::load;
use earthsci_toolkit::simulate_array::{ArrayCompiled, RhsStats};

/// A pass-through allocator that counts heap allocations (and reallocations,
/// which may move/grow a block) while `MEASURING` is set. Deallocations are not
/// counted — the metric is "did the hot path request new memory".
struct CountingAlloc;

static ALLOC_COUNT: AtomicUsize = AtomicUsize::new(0);
static MEASURING: AtomicBool = AtomicBool::new(false);

unsafe impl GlobalAlloc for CountingAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if MEASURING.load(Ordering::Relaxed) {
            ALLOC_COUNT.fetch_add(1, Ordering::Relaxed);
        }
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        if MEASURING.load(Ordering::Relaxed) {
            ALLOC_COUNT.fetch_add(1, Ordering::Relaxed);
        }
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static GLOBAL: CountingAlloc = CountingAlloc;

/// A discretized 1-D heat equation on `n` cells (interior + two ghost regions),
/// parameterized by grid size — identical stencil AST at every N. Mirrors
/// `fixtures/arrayop/15_discretized_1d_heat.esm`.
fn heat1d_json(n: usize) -> String {
    const TEMPLATE: &str = r#"{
 "esm": "0.1.0",
 "metadata": {"name": "heat1d_zero_alloc"},
 "models": {
  "Heat1D": {
   "variables": {"u": {"type": "state", "shape": ["i"]}},
   "equations": [
    {
     "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, __N__]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "ranges": {"i": [1, __N__]},
             "expr": {"op": "index", "args": [
               {"op": "makearray", "args": [],
                "regions": [[[1, __N__]], [[1, 1]], [[__N__, __N__]]],
                "values": [
                  {"op": "*", "args": [25, {"op": "+", "args": [
                    {"op": "index", "args": ["u", {"op": "-", "args": ["i", 1]}]},
                    {"op": "*", "args": [-2, {"op": "index", "args": ["u", "i"]}]},
                    {"op": "index", "args": ["u", {"op": "+", "args": ["i", 1]}]}
                  ]}]},
                  {"op": "*", "args": [25, {"op": "+", "args": [
                    {"op": "*", "args": [-2, {"op": "index", "args": ["u", "i"]}]},
                    {"op": "index", "args": ["u", {"op": "+", "args": ["i", 1]}]}
                  ]}]},
                  {"op": "*", "args": [25, {"op": "+", "args": [
                    {"op": "index", "args": ["u", {"op": "-", "args": ["i", 1]}]},
                    {"op": "*", "args": [-2, {"op": "index", "args": ["u", "i"]}]}
                  ]}]}
                ]},
               "i"]}}
    }
   ]
  }
 }
}"#;
    TEMPLATE.replace("__N__", &n.to_string())
}

/// A 1-D heat equation in generalized-einsum form (contracted index `k`),
/// parameterized by grid size — the ess-p9s einsum stencil shape.
fn einsum_heat1d_json(n: usize) -> String {
    const TEMPLATE: &str = r#"{
 "esm": "0.1.0",
 "metadata": {"name": "einsum_heat1d_zero_alloc"},
 "models": {
  "Heat1DEinsum": {
   "variables": {"u": {"type": "state", "shape": ["i"]}},
   "equations": [
    {
     "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, __N__]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "reduce": "+",
             "ranges": {"i": [1, __N__], "k": [-1, 1]},
             "expr": {"op": "*", "args": [
               25,
               {"op": "ifelse", "args": [{"op": "==", "args": ["k", 0]}, -2, 1]},
               {"op": "index", "args": ["u", {"op": "+", "args": ["i", "k"]}]}
             ]}}
    }
   ]
  }
 }
}"#;
    TEMPLATE.replace("__N__", &n.to_string())
}

/// A lat-lon heat equation with periodic longitude (wrap-indexed) and Dirichlet
/// latitude, parameterized by grid size — the ess-p9s periodic-wrap shape.
fn latlon_heat_json(nlon: usize, nlat: usize) -> String {
    const TEMPLATE: &str = r#"{
 "esm": "0.1.0",
 "metadata": {"name": "latlon_heat_zero_alloc"},
 "models": {
  "HeatLatLon": {
   "variables": {"u": {"type": "state", "shape": ["i", "j"]}},
   "equations": [
    {
     "lhs": {"op": "aggregate", "args": [], "output_idx": ["i", "j"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i", "j"]}], "wrt": "t"},
             "ranges": {"i": [1, __NLON__], "j": [1, __NLAT__]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i", "j"],
             "ranges": {"i": [1, __NLON__], "j": [1, __NLAT__]},
             "expr": {"op": "*", "args": [0.4, {"op": "+", "args": [
               {"op": "index", "args": ["u",
                 {"op": "ifelse", "args": [
                   {"op": "<", "args": [{"op": "-", "args": ["i", 1]}, 1]},
                   {"op": "+", "args": [{"op": "-", "args": ["i", 1]}, __NLON__]},
                   {"op": "ifelse", "args": [
                     {"op": ">", "args": [{"op": "-", "args": ["i", 1]}, __NLON__]},
                     {"op": "-", "args": [{"op": "-", "args": ["i", 1]}, __NLON__]},
                     {"op": "-", "args": ["i", 1]}
                   ]}
                 ]}, "j"]},
               {"op": "*", "args": [-2, {"op": "index", "args": ["u", "i", "j"]}]},
               {"op": "index", "args": ["u",
                 {"op": "ifelse", "args": [
                   {"op": "<", "args": [{"op": "+", "args": ["i", 1]}, 1]},
                   {"op": "+", "args": [{"op": "+", "args": ["i", 1]}, __NLON__]},
                   {"op": "ifelse", "args": [
                     {"op": ">", "args": [{"op": "+", "args": ["i", 1]}, __NLON__]},
                     {"op": "-", "args": [{"op": "+", "args": ["i", 1]}, __NLON__]},
                     {"op": "+", "args": ["i", 1]}
                   ]}
                 ]}, "j"]}
             ]}]}}
    }
   ]
  }
 }
}"#;
    TEMPLATE
        .replace("__NLON__", &nlon.to_string())
        .replace("__NLAT__", &nlat.to_string())
}

fn compile_json(json: &str) -> ArrayCompiled {
    let file = load(json).expect("load json model");
    ArrayCompiled::from_file(&file).expect("compile json model")
}

fn sample_state(n: usize) -> Vec<f64> {
    (0..n).map(|k| (0.7 * k as f64 + 0.3).sin()).collect()
}

/// Warm up the buffer pool, confirm the RHS takes the vectorized path, then
/// measure heap allocations over a tight loop of RHS evaluations. The fences
/// bracket only the measured loop; the counter reads are atomic loads and
/// `debug_eval_rhs_into` borrows all its buffers, so nothing else allocates
/// between them. Returns the allocation count (expected 0 in steady state).
fn measure_steady_state_allocs(label: &str, compiled: &ArrayCompiled) -> usize {
    let n = compiled.state_variable_names().len();
    let state = sample_state(n);
    let params = compiled.debug_resolve_params(&HashMap::new());
    let mut scratch = compiled.debug_new_scratch();
    let mut dy = vec![0.0f64; n];
    let mut stats = RhsStats::default();

    for _ in 0..32 {
        compiled.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut stats);
    }

    let mut probe = RhsStats::default();
    compiled.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut probe);
    assert_eq!(probe.vectorized_rules, 1, "{label}: RHS did not vectorize");
    assert_eq!(
        probe.scalar_rules, 0,
        "{label}: RHS fell back to the oracle"
    );

    let iters = 200usize;
    let before = ALLOC_COUNT.load(Ordering::Relaxed);
    MEASURING.store(true, Ordering::Relaxed);
    for _ in 0..iters {
        compiled.debug_eval_rhs_into(&state, 0.0, &params, &mut dy, &mut scratch, &mut stats);
    }
    MEASURING.store(false, Ordering::Relaxed);
    let allocs = ALLOC_COUNT.load(Ordering::Relaxed) - before;
    assert_eq!(
        allocs, 0,
        "{label}: steady-state vectorized RHS allocated {allocs} times over {iters} calls \
         (expected 0 — the scratch/pool must recycle every buffer)"
    );
    allocs
}

#[test]
fn vectorized_rhs_is_allocation_free_in_steady_state() {
    // Every discretized-PDE stencil shape the vectorizer handles must be
    // allocation-free in steady state, at two grid sizes each (so the property
    // is both N-independent and ≈0). Covers the affine-ghost makearray stencil
    // (ess-bdm) and the two ess-p9s additions: the einsum-contraction fold and
    // the periodic-wrap gather. One test only — the allocation counter is
    // process-global, so the cases must run sequentially (no parallel threads).
    let cases: [(&str, ArrayCompiled); 6] = [
        ("makearray N=4", compile_json(&heat1d_json(4))),
        ("makearray N=8", compile_json(&heat1d_json(8))),
        ("einsum N=4", compile_json(&einsum_heat1d_json(4))),
        ("einsum N=8", compile_json(&einsum_heat1d_json(8))),
        ("periodic-wrap 4x2", compile_json(&latlon_heat_json(4, 2))),
        ("periodic-wrap 8x2", compile_json(&latlon_heat_json(8, 2))),
    ];
    for (label, compiled) in &cases {
        let allocs = measure_steady_state_allocs(label, compiled);
        assert_eq!(allocs, 0, "{label}: expected zero steady-state allocations");
    }
}
