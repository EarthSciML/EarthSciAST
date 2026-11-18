//! Zero-allocation verification for the taped right-hand side.
//!
//! diffsol's RHS is in-place (`call_inplace` writes the solver-owned `dy`), so
//! there is no allocation floor: a correct closure can be allocation-free. The
//! tape's slab and executor state are preallocated when it is installed, so a
//! steady-state taped evaluation performs **zero** heap allocations.
//!
//! This test wraps the global allocator with a counter and asserts that, after
//! a warm-up, a tight loop of taped RHS evaluations allocates nothing — at
//! **two** grid sizes, so the property is both N-independent and ≈0. It lives in its own test binary with a single test
//! so no other test thread perturbs the process-wide allocation counter.

#![cfg(not(target_arch = "wasm32"))]

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use earthsci_ast::{Compiler, ProblemOptions, Rhs, esm_problem};

#[path = "portable/rhs.rs"]
mod rhs;
use rhs::ProblemRhs;

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
/// `fixtures/faq/15_discretized_1d_heat.esm`.
fn heat1d_json(n: usize) -> String {
    const TEMPLATE: &str = r#"{
 "esm": "2.0.0",
 "metadata": {"name": "heat1d_zero_alloc"},
 "models": {
  "Heat1D": {
   "variables": {"u": {"type": "unknown", "shape": ["i"]}},
   "equations": [
    {
     "lhs": {"op": "faq", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, __N__]}},
     "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
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
 "esm": "2.0.0",
 "metadata": {"name": "einsum_heat1d_zero_alloc"},
 "models": {
  "Heat1DEinsum": {
   "variables": {"u": {"type": "unknown", "shape": ["i"]}},
   "equations": [
    {
     "lhs": {"op": "faq", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, __N__]}},
     "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
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
 "esm": "2.0.0",
 "metadata": {"name": "latlon_heat_zero_alloc"},
 "models": {
  "HeatLatLon": {
   "variables": {"u": {"type": "unknown", "shape": ["i", "j"]}},
   "equations": [
    {
     "lhs": {"op": "faq", "args": [], "output_idx": ["i", "j"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i", "j"]}], "wrt": "t"},
             "ranges": {"i": [1, __NLON__], "j": [1, __NLAT__]}},
     "rhs": {"op": "faq", "args": [], "output_idx": ["i", "j"],
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

/// The model's right-hand side under `native` through the public program:
/// the strict tape, which refuses the program if any rule leaves it.
fn compile_json(json: &str) -> ProblemRhs {
    // The measured loop passes the state explicitly; any starting value
    // builds the Problem, so every unknown without one starts at 0.
    let mut doc: serde_json::Value = serde_json::from_str(json).expect("parse json model");
    for model in doc["models"].as_object_mut().expect("models").values_mut() {
        for var in model["variables"]
            .as_object_mut()
            .expect("variables")
            .values_mut()
        {
            if var["type"] == "unknown" && var.get("default").is_none() {
                var["default"] = serde_json::json!(0.0);
            }
        }
    }
    let prob = esm_problem(
        &doc,
        (0.0, 1.0),
        ProblemOptions {
            compiler: Some(Compiler::Native),
            rhs: Rhs::Always,
            ..Default::default()
        },
    )
    .expect("build json model");
    ProblemRhs::new(&prob)
}

fn sample_state(n: usize) -> Vec<f64> {
    (0..n).map(|k| (0.7 * k as f64 + 0.3).sin()).collect()
}

/// Warm up the workspace, then measure heap allocations over a tight loop of
/// right-hand-side evaluations. The fences bracket only the measured loop; the
/// counter reads are atomic loads and the evaluation borrows all its buffers,
/// so nothing else allocates between them. Returns the allocation count
/// (expected 0 in steady state).
fn measure_taped_steady_state_allocs(label: &str, rhs: &mut ProblemRhs) -> usize {
    let n = rhs.n_states();
    let state = sample_state(n);
    let mut dy = vec![0.0f64; n];

    for _ in 0..32 {
        rhs.eval_into(&state, 0.0, &mut dy);
    }

    let iters = 200usize;
    let before = ALLOC_COUNT.load(Ordering::Relaxed);
    MEASURING.store(true, Ordering::Relaxed);
    for _ in 0..iters {
        rhs.eval_into(&state, 0.0, &mut dy);
    }
    MEASURING.store(false, Ordering::Relaxed);
    let allocs = ALLOC_COUNT.load(Ordering::Relaxed) - before;
    assert_eq!(
        allocs, 0,
        "{label}: steady-state taped RHS allocated {allocs} times over {iters} calls \
         (expected 0)"
    );
    allocs
}

#[test]
fn taped_rhs_is_allocation_free_in_steady_state() {
    // Each discretized-PDE stencil shape — the affine-ghost makearray stencil,
    // the einsum-contraction fold and the periodic-wrap gather — at two grid
    // sizes. One test only: the allocation counter is process-global, so the
    // cases must run sequentially.
    let mut cases: [(&str, ProblemRhs); 6] = [
        ("makearray N=4", compile_json(&heat1d_json(4))),
        ("makearray N=8", compile_json(&heat1d_json(8))),
        ("einsum N=4", compile_json(&einsum_heat1d_json(4))),
        ("einsum N=8", compile_json(&einsum_heat1d_json(8))),
        ("periodic-wrap 4x2", compile_json(&latlon_heat_json(4, 2))),
        ("periodic-wrap 8x2", compile_json(&latlon_heat_json(8, 2))),
    ];
    for (label, rhs) in &mut cases {
        let allocs = measure_taped_steady_state_allocs(&format!("taped {label}"), rhs);
        assert_eq!(
            allocs, 0,
            "taped {label}: expected zero steady-state allocations"
        );
    }
}
