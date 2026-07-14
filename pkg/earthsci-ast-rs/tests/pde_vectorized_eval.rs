//! Verification of the no-scalarization contract for the Rust PDE tier
//! (ess-bdm). These tests assert the structural property the bead requires —
//! the discretized spatial RHS is evaluated as **whole-array kernels**, not a
//! per-cell scalar loop — rather than just a numeric trajectory (the inline
//! analytic assertions in `arrayop_simulate_tests` already cover the latter).
//!
//! Three properties are checked:
//!   1. The vectorized path is actually *taken* for 1-D and 2-D diffusion
//!      (not silently falling back to the oracle).
//!   2. The vectorized whole-array result is bit-equivalent to the per-cell
//!      oracle (the vectorized path is a verified-equivalent overlay).
//!   3. The number of evaluated kernel ops is **independent of the grid size
//!      N** — the same 1-D heat stencil on a 4-cell and an 8-cell grid visits
//!      the same number of array kernels. A per-cell strategy would scale with
//!      N; a vectorized one does not.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::simulate_array::ArrayCompiled;
use earthsci_ast::{SimulateOptions, SolverChoice, load, simulate};
use std::collections::HashMap;
use std::path::PathBuf;

mod common;

fn fixture(name: &str) -> PathBuf {
    common::repo_fixture("fixtures/arrayop").join(name)
}

fn compile_fixture(name: &str) -> ArrayCompiled {
    let text = std::fs::read_to_string(fixture(name)).expect("read fixture");
    let file = load(&text).expect("load fixture");
    ArrayCompiled::from_file(&file).expect("compile fixture")
}

/// A deterministic, non-trivial state vector of length `n`.
fn sample_state(n: usize) -> Vec<f64> {
    (0..n).map(|k| (0.7 * k as f64 + 0.3).sin()).collect()
}

/// A discretized 1-D heat equation on `n` cells, encoded exactly like
/// `fixtures/arrayop/15_discretized_1d_heat.esm` (interior + two ghost
/// regions) but parameterized by grid size, so the same stencil AST can be
/// evaluated at two different N.
fn heat1d_json(n: usize) -> String {
    const TEMPLATE: &str = r#"{
 "esm": "0.1.0",
 "metadata": {"name": "heat1d_param"},
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

fn compile_json(json: &str) -> ArrayCompiled {
    let file = load(json).expect("load json model");
    ArrayCompiled::from_file(&file).expect("compile json model")
}

#[test]
fn vectorized_path_is_taken_for_1d_and_2d_diffusion() {
    for name in ["15_discretized_1d_heat.esm", "16_discretized_2d_heat.esm"] {
        let compiled = compile_fixture(name);
        let n = compiled.state_variable_names().len();
        let state = sample_state(n);
        let (_dy, stats) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), false);
        assert_eq!(
            stats.vectorized_rules, 1,
            "{name}: expected the spatial derivative to evaluate via the vectorized \
             whole-array path, got stats={stats:?}"
        );
        assert_eq!(
            stats.scalar_rules, 0,
            "{name}: spatial derivative fell back to the per-cell oracle, got stats={stats:?}"
        );
        assert!(
            stats.kernel_ops > 0,
            "{name}: vectorized path recorded no kernel ops"
        );
    }
}

#[test]
fn vectorized_matches_per_cell_oracle() {
    // The whole-array path must be numerically identical to the per-cell
    // reference (it is a perf/architecture overlay, not a new numeric method).
    // Covers all four discretized-PDE stencil shapes the vectorizer handles:
    // 1-D/2-D affine-ghost diffusion (15/16), the einsum-contraction form (19),
    // and the periodic-wrap lat-lon form (17). The vectorized vs oracle equality
    // is bit-exact (≤1e-12 is slack for the identical-fp left-fold).
    for name in [
        "15_discretized_1d_heat.esm",
        "16_discretized_2d_heat.esm",
        "17_discretized_latlon_heat.esm",
        "19_einsum_1d_stencil.esm",
    ] {
        let compiled = compile_fixture(name);
        let n = compiled.state_variable_names().len();
        let state = sample_state(n);
        let (dy_vec, vstats) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), false);
        let (dy_scalar, sstats) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), true);
        assert_eq!(vstats.vectorized_rules, 1, "{name}: not vectorized");
        assert_eq!(
            vstats.scalar_rules, 0,
            "{name}: vectorized run hit the oracle"
        );
        assert_eq!(
            sstats.scalar_rules, 1,
            "{name}: force_scalar did not use oracle"
        );
        assert_eq!(dy_vec.len(), dy_scalar.len());
        for (k, (a, b)) in dy_vec.iter().zip(dy_scalar.iter()).enumerate() {
            assert!(
                (a - b).abs() <= 1e-12,
                "{name}: vectorized vs oracle mismatch at slot {k}: {a} vs {b}"
            );
        }
    }
}

#[test]
fn vectorized_path_is_taken_for_einsum_and_periodic_wrap() {
    // The two shapes ess-p9s adds: the contracted einsum stencil (19) and the
    // periodic-wrap lat-lon stencil (17) must each evaluate via the vectorized
    // whole-array path, not the per-cell oracle.
    for name in ["17_discretized_latlon_heat.esm", "19_einsum_1d_stencil.esm"] {
        let compiled = compile_fixture(name);
        let n = compiled.state_variable_names().len();
        let state = sample_state(n);
        let (_dy, stats) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), false);
        assert_eq!(
            stats.vectorized_rules, 1,
            "{name}: spatial derivative did not take the vectorized path, got {stats:?}"
        );
        assert_eq!(
            stats.scalar_rules, 0,
            "{name}: spatial derivative fell back to the oracle, got {stats:?}"
        );
        assert!(stats.kernel_ops > 0, "{name}: no kernel ops recorded");
    }
}

#[test]
fn kernel_op_count_is_independent_of_grid_size() {
    // The bead's load-bearing assertion: a fixture at two grid sizes must
    // exercise the *same* kernel structure. The vectorized evaluator walks the
    // stencil AST once regardless of N, so kernel_ops is identical at N=4 and
    // N=8 even though the state vector (and the work the kernels do internally)
    // grows. A per-cell strategy would record O(N) body walks.
    let state4 = sample_state(4);
    let state8 = sample_state(8);
    let c4 = compile_json(&heat1d_json(4));
    let c8 = compile_json(&heat1d_json(8));

    assert_eq!(c4.state_variable_names().len(), 4);
    assert_eq!(c8.state_variable_names().len(), 8);

    let (_dy4, s4) = c4.debug_eval_rhs(&state4, 0.0, &HashMap::new(), false);
    let (_dy8, s8) = c8.debug_eval_rhs(&state8, 0.0, &HashMap::new(), false);

    assert_eq!(s4.vectorized_rules, 1, "N=4 not vectorized: {s4:?}");
    assert_eq!(s8.vectorized_rules, 1, "N=8 not vectorized: {s8:?}");
    assert_eq!(s4.scalar_rules, 0, "N=4 fell back: {s4:?}");
    assert_eq!(s8.scalar_rules, 0, "N=8 fell back: {s8:?}");
    assert_eq!(
        s4.kernel_ops, s8.kernel_ops,
        "kernel-op count must be independent of grid size N \
         (N=4 -> {}, N=8 -> {}); an O(N) per-cell strategy is leaking through",
        s4.kernel_ops, s8.kernel_ops
    );
}

/// A 1-D linear upwind advection `∂u/∂t = -v ∂u/∂x` discretized first-order
/// upwind (v>0): `D(u[i]) = -(v/dx)*(u[i] - u[i-1])`, `i ∈ [1, n]`, with a zero
/// inflow at the left edge (the `u[i-1]` read at `i=1` falls on the ghost cell
/// → 0). A bare-arithmetic pure-map arrayop (no makearray) — the second stencil
/// shape the vectorized evaluator must handle.
fn advection1d_json(n: usize, c: f64) -> String {
    const TEMPLATE: &str = r#"{
 "esm": "0.1.0",
 "metadata": {"name": "advection1d"},
 "models": {
  "Adv1D": {
   "variables": {"u": {"type": "state", "shape": ["i"]}},
   "equations": [
    {
     "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, __N__]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "ranges": {"i": [1, __N__]},
             "expr": {"op": "*", "args": [__NEGC__, {"op": "-", "args": [
                {"op": "index", "args": ["u", "i"]},
                {"op": "index", "args": ["u", {"op": "-", "args": ["i", 1]}]}
             ]}]}}
    }
   ]
  }
 }
}"#;
    TEMPLATE
        .replace("__N__", &n.to_string())
        .replace("__NEGC__", &format!("{}", -c))
}

#[test]
fn advection_1d_integrates_end_to_end_via_vectorized_path() {
    // v = 1, dx = 0.05 -> c = v/dx = 20. Grid of 40 cells; a smooth pulse
    // initially centred at cell 8 advects downstream (toward higher i).
    let n = 40usize;
    let c = 20.0f64;
    let json = advection1d_json(n, c);
    let file = load(&json).expect("load advection model");

    // Gaussian-ish pulse centred at cell 8, well clear of the i=n outflow so
    // negligible mass leaves the domain over the integration window.
    let center0 = 8.0f64;
    let ic: HashMap<String, f64> = (1..=n)
        .map(|k| {
            let x = (k as f64 - center0) / 2.0;
            (format!("u[{k}]"), (-x * x).exp())
        })
        .collect();

    // Confirm the spatial derivative is evaluated via the vectorized path
    // (not the per-cell oracle).
    let compiled = ArrayCompiled::from_file(&file).expect("compile advection");
    let state0: Vec<f64> = (1..=n)
        .map(|k| {
            let x = (k as f64 - center0) / 2.0;
            (-x * x).exp()
        })
        .collect();
    let (_dy, stats) = compiled.debug_eval_rhs(&state0, 0.0, &HashMap::new(), false);
    assert_eq!(
        stats.vectorized_rules, 1,
        "advection RHS must use the vectorized path, got {stats:?}"
    );
    assert_eq!(
        stats.scalar_rules, 0,
        "advection fell back to oracle: {stats:?}"
    );

    // Integrate end-to-end. t=0.1 advects the pulse by v*t/dx = 2 cells.
    let t_end = 0.1f64;
    let opts = SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-10,
        reltol: 1e-8,
        max_steps: 100_000,
        output_times: Some(vec![t_end]),
    };
    let sol = simulate(&file, (0.0, t_end), &HashMap::new(), &ic, &opts)
        .expect("advection simulate failed");

    // Pull the final state in grid order and check the centre of mass moved
    // downstream — the unambiguous signature of advection. `sol.state` is
    // indexed `[variable_index][time_index]`; there is a single output time.
    let mut idx_of = HashMap::new();
    for (j, nm) in sol.state_variable_names.iter().enumerate() {
        idx_of.insert(nm.clone(), j);
    }
    let last_tix = sol.time.len() - 1;
    let mut num0 = 0.0;
    let mut den0 = 0.0;
    let mut numf = 0.0;
    let mut denf = 0.0;
    for k in 1..=n {
        let j = idx_of[&format!("u[{k}]")];
        let u0 = state0[k - 1];
        let uf = sol.state[j][last_tix];
        assert!(uf.is_finite(), "non-finite u[{k}] = {uf}");
        num0 += k as f64 * u0;
        den0 += u0;
        numf += k as f64 * uf;
        denf += uf;
    }
    let centroid0 = num0 / den0;
    let centroidf = numf / denf;
    assert!(
        centroidf > centroid0 + 1.0,
        "advection must move the pulse downstream: centroid {centroid0:.3} -> {centroidf:.3}"
    );
}

/// A 1-D heat equation in generalized-einsum form (mirrors fixture 19's interior
/// stencil but covering every cell with homogeneous-Dirichlet ghosts), so the
/// same contracted-`k` stencil AST can be evaluated at two grid sizes. The body
/// `sum_k 25·ifelse(k==0,-2,1)·u[i+k]` contracts `k ∈ [-1,1]`.
fn einsum_heat1d_json(n: usize) -> String {
    const TEMPLATE: &str = r#"{
 "esm": "0.1.0",
 "metadata": {"name": "einsum_heat1d_param"},
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

/// A lat-lon heat equation with a periodic longitude (`i`, period `nlon`,
/// wrap-indexed) and Dirichlet latitude (`j`, ghost cells), parameterized by
/// grid size — identical stencil AST at every size. Mirrors fixture 17.
fn latlon_heat_json(nlon: usize, nlat: usize) -> String {
    const TEMPLATE: &str = r#"{
 "esm": "0.1.0",
 "metadata": {"name": "latlon_heat_param"},
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

/// A model with a *varying* array observed (state-dependent, so re-materialized
/// every RHS step) whose body uses only vectorizer-covered ops — arithmetic plus
/// `atan2` (newly routed through the whole-array `vec_combine` kernel). The state
/// derivative reads the observed, so the observed materialization is on the hot
/// path. Mirrors the coupled behaviour-stack shape (a spatially-varying algebraic
/// field feeding the spatial derivative) in miniature.
fn varying_array_observed_json(n: usize) -> String {
    const TEMPLATE: &str = r#"{
 "esm": "0.1.0",
 "metadata": {"name": "obs_vec"},
 "models": {
  "ObsVec": {
   "variables": {
     "u": {"type": "state", "shape": ["i"]},
     "w": {"type": "state", "shape": ["i"]}
   },
   "equations": [
    {"lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "index", "args": ["w", "i"]},
             "ranges": {"i": [1, __N__]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"], "ranges": {"i": [1, __N__]},
             "expr": {"op": "+", "args": [
               {"op": "*", "args": [
                 {"op": "index", "args": ["u", "i"]},
                 {"op": "index", "args": ["u", "i"]}]},
               {"op": "atan2", "args": [{"op": "index", "args": ["u", "i"]}, 2]}
             ]}}},
    {"lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, __N__]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"], "ranges": {"i": [1, __N__]},
             "expr": {"op": "index", "args": ["w", "i"]}}}
   ]
  }
 }
}"#;
    TEMPLATE.replace("__N__", &n.to_string())
}

#[test]
fn varying_array_observed_vectorizes_and_matches_oracle() {
    // The structural fix (ess: observed vectorization): an array-shaped observed
    // materializes via the whole-array overlay, not the per-cell oracle, and the
    // result is bit-identical to the oracle. This is the dominant per-step cost
    // for coupled models with a time/space-varying behaviour stack.
    let n = 12usize;
    let compiled = compile_json(&varying_array_observed_json(n));
    let state = sample_state(n);

    let (dy_vec, vstats) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), false);
    let (dy_scalar, sstats) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), true);

    // The observed took the vectorized whole-array path (not the per-cell oracle).
    assert_eq!(
        vstats.obs_vectorized_rules, 1,
        "varying array observed did not vectorize: {vstats:?}"
    );
    assert_eq!(
        vstats.obs_scalar_rules, 0,
        "varying array observed fell back to the oracle: {vstats:?}"
    );
    // force_scalar drives the observed through the per-cell oracle reference.
    assert_eq!(
        sstats.obs_scalar_rules, 1,
        "force_scalar did not run the observed per-cell: {sstats:?}"
    );
    assert_eq!(sstats.obs_vectorized_rules, 0, "force_scalar still vectorized: {sstats:?}");

    // The two materialization strategies are numerically identical (the vectorized
    // path is a verified-equivalent overlay, reusing the same apply_binary kernel).
    assert_eq!(dy_vec.len(), dy_scalar.len());
    for (k, (a, b)) in dy_vec.iter().zip(dy_scalar.iter()).enumerate() {
        assert!(
            (a - b).abs() <= 1e-12,
            "observed vectorized vs oracle mismatch at slot {k}: {a} vs {b}"
        );
    }
}

/// A filtered einsum stencil `D(u[i]) = sum_{k∈[-1,1], k≠0} u[i+k]` — the
/// contraction carries a §5.3 `filter` (`k != 0`) that excludes the self term,
/// yielding `u[i-1] + u[i+1]`. Exercises the filter-masking added to the
/// vectorized contraction fold (`eval_vec_contracted`).
fn filtered_einsum_json(n: usize) -> String {
    const TEMPLATE: &str = r#"{
 "esm": "0.1.0",
 "metadata": {"name": "filtered_einsum"},
 "models": {"M": {
   "variables": {"u": {"type": "state", "shape": ["i"]}},
   "equations": [
    {"lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, __N__]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"], "reduce": "+",
             "ranges": {"i": [1, __N__], "k": [-1, 1]},
             "filter": {"op": "!=", "args": ["k", 0]},
             "expr": {"op": "index", "args": ["u", {"op": "+", "args": ["i", "k"]}]}}}
   ]
 }}
}"#;
    TEMPLATE.replace("__N__", &n.to_string())
}

#[test]
fn filtered_contraction_vectorizes_and_matches_oracle() {
    let n = 10usize;
    let compiled = compile_json(&filtered_einsum_json(n));
    let state = sample_state(n);
    let (dy_vec, vstats) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), false);
    let (dy_scalar, sstats) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), true);
    assert_eq!(
        vstats.vectorized_rules, 1,
        "filtered contraction did not vectorize: {vstats:?}"
    );
    assert_eq!(vstats.scalar_rules, 0, "filtered contraction fell back: {vstats:?}");
    assert_eq!(sstats.scalar_rules, 1, "force_scalar did not use oracle: {sstats:?}");
    for (k, (a, b)) in dy_vec.iter().zip(dy_scalar.iter()).enumerate() {
        assert!(
            (a - b).abs() <= 1e-12,
            "filtered-contraction vectorized vs oracle mismatch at {k}: {a} vs {b}"
        );
    }
    // Sanity: interior cell i (2..n-1) is u[i-1]+u[i+1] (self term k=0 filtered).
    for i in 2..n {
        let expect = state[i - 2] + state[i];
        assert!(
            (dy_vec[i - 1] - expect).abs() <= 1e-12,
            "cell {i}: got {} want {expect}",
            dy_vec[i - 1]
        );
    }
}

/// A pure-map stencil with an ARRAY-valued `ifelse` condition
/// `D(u[i]) = ifelse(u[i] > 0.5, 2*u[i], 3*u[i])` — the per-cell mask + branch
/// select exercises the whole-array comparison + `vec_select` path.
fn array_ifelse_json(n: usize) -> String {
    const TEMPLATE: &str = r#"{
 "esm": "0.1.0",
 "metadata": {"name": "array_ifelse"},
 "models": {"M": {
   "variables": {"u": {"type": "state", "shape": ["i"]}},
   "equations": [
    {"lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, __N__]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"], "ranges": {"i": [1, __N__]},
             "expr": {"op": "ifelse", "args": [
               {"op": ">", "args": [{"op": "index", "args": ["u", "i"]}, 0.5]},
               {"op": "*", "args": [2, {"op": "index", "args": ["u", "i"]}]},
               {"op": "*", "args": [3, {"op": "index", "args": ["u", "i"]}]}
             ]}}}
   ]
 }}
}"#;
    TEMPLATE.replace("__N__", &n.to_string())
}

#[test]
fn array_valued_ifelse_vectorizes_and_matches_oracle() {
    let n = 10usize;
    let compiled = compile_json(&array_ifelse_json(n));
    let state = sample_state(n);
    let (dy_vec, vstats) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), false);
    let (dy_scalar, _s) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), true);
    assert_eq!(
        vstats.vectorized_rules, 1,
        "array-valued ifelse did not vectorize: {vstats:?}"
    );
    assert_eq!(vstats.scalar_rules, 0, "array ifelse fell back: {vstats:?}");
    for (k, (a, b)) in dy_vec.iter().zip(dy_scalar.iter()).enumerate() {
        assert!(
            (a - b).abs() <= 1e-12,
            "array-ifelse vectorized vs oracle mismatch at {k}: {a} vs {b}"
        );
        let expect = if state[k] > 0.5 { 2.0 * state[k] } else { 3.0 * state[k] };
        assert!((a - expect).abs() <= 1e-12, "cell {k}: got {a} want {expect}");
    }
}

/// A conservative-regrid-shaped contraction `D(u[j]) = sum_i A[i,j]·F[i]`: a
/// weight table `A` gathered by the contraction index `i` (fixed per term) AND
/// the output index `j` (`index(A, i, j)`), times a source vector gathered
/// entirely by the contraction index (`index(F, i)` → a broadcast scalar). This
/// is the table-gather pattern the level-set / behaviour-stack regrid uses;
/// before, `eval_vec_index` bailed (index-arg count ≠ output rank) and the whole
/// regrid walked per-cell. `A`/`F` are held-at-ic state (no `D`), so they are
/// constant per RHS call and read as plain source arrays.
fn regrid_gather_json(ni: usize, nj: usize) -> String {
    const TEMPLATE: &str = r#"{
 "esm": "0.1.0",
 "metadata": {"name": "regrid_gather"},
 "models": {"M": {
   "variables": {
     "u": {"type": "state", "shape": ["j"]},
     "A": {"type": "state", "shape": ["i", "j"]},
     "F": {"type": "state", "shape": ["i"]}
   },
   "equations": [
    {"lhs": {"op": "aggregate", "args": [], "output_idx": ["j"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "j"]}], "wrt": "t"},
             "ranges": {"j": [1, __NJ__]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["j"], "reduce": "+",
             "ranges": {"j": [1, __NJ__], "i": [1, __NI__]},
             "expr": {"op": "*", "args": [
               {"op": "index", "args": ["A", "i", "j"]},
               {"op": "index", "args": ["F", "i"]}
             ]}}}
   ]
 }}
}"#;
    TEMPLATE
        .replace("__NI__", &ni.to_string())
        .replace("__NJ__", &nj.to_string())
}

#[test]
fn regrid_table_gather_vectorizes_and_matches_oracle() {
    let (ni, nj) = (3usize, 4usize);
    let compiled = compile_json(&regrid_gather_json(ni, nj));
    let n = compiled.state_variable_names().len();
    assert_eq!(n, nj + ni * nj + ni, "state layout: u[j] + A[i,j] + F[i]");
    let state = sample_state(n);
    let (dy_vec, vstats) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), false);
    let (dy_scalar, sstats) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), true);
    assert_eq!(
        vstats.vectorized_rules, 1,
        "regrid table-gather did not vectorize: {vstats:?}"
    );
    assert_eq!(vstats.scalar_rules, 0, "regrid gather fell back: {vstats:?}");
    assert_eq!(sstats.scalar_rules, 1, "force_scalar did not use oracle: {sstats:?}");
    for (k, (a, b)) in dy_vec.iter().zip(dy_scalar.iter()).enumerate() {
        assert!(
            (a - b).abs() <= 1e-12,
            "regrid-gather vectorized vs oracle mismatch at {k}: {a} vs {b}"
        );
    }
}

#[test]
fn einsum_kernel_op_count_is_independent_of_grid_size() {
    // The contracted-`k` stencil walks its body once per contraction value
    // regardless of N, so kernel_ops is identical at N=4 and N=8.
    let c4 = compile_json(&einsum_heat1d_json(4));
    let c8 = compile_json(&einsum_heat1d_json(8));
    assert_eq!(c4.state_variable_names().len(), 4);
    assert_eq!(c8.state_variable_names().len(), 8);

    let (_d4, s4) = c4.debug_eval_rhs(&sample_state(4), 0.0, &HashMap::new(), false);
    let (_d8, s8) = c8.debug_eval_rhs(&sample_state(8), 0.0, &HashMap::new(), false);

    assert_eq!(s4.vectorized_rules, 1, "N=4 einsum not vectorized: {s4:?}");
    assert_eq!(s8.vectorized_rules, 1, "N=8 einsum not vectorized: {s8:?}");
    assert_eq!(s4.scalar_rules, 0, "N=4 einsum fell back: {s4:?}");
    assert_eq!(s8.scalar_rules, 0, "N=8 einsum fell back: {s8:?}");
    assert_eq!(
        s4.kernel_ops, s8.kernel_ops,
        "einsum kernel-op count must be independent of N (N=4 -> {}, N=8 -> {})",
        s4.kernel_ops, s8.kernel_ops
    );
}

#[test]
fn periodic_wrap_kernel_op_count_is_independent_of_grid_size() {
    // The periodic-wrap stencil walks its body once regardless of the periodic
    // dimension's size: kernel_ops is identical at nlon=4 and nlon=8.
    let c4 = compile_json(&latlon_heat_json(4, 2));
    let c8 = compile_json(&latlon_heat_json(8, 2));
    assert_eq!(c4.state_variable_names().len(), 8);
    assert_eq!(c8.state_variable_names().len(), 16);

    let (_d4, s4) = c4.debug_eval_rhs(&sample_state(8), 0.0, &HashMap::new(), false);
    let (_d8, s8) = c8.debug_eval_rhs(&sample_state(16), 0.0, &HashMap::new(), false);

    assert_eq!(s4.vectorized_rules, 1, "nlon=4 wrap not vectorized: {s4:?}");
    assert_eq!(s8.vectorized_rules, 1, "nlon=8 wrap not vectorized: {s8:?}");
    assert_eq!(s4.scalar_rules, 0, "nlon=4 wrap fell back: {s4:?}");
    assert_eq!(s8.scalar_rules, 0, "nlon=8 wrap fell back: {s8:?}");
    assert_eq!(
        s4.kernel_ops, s8.kernel_ops,
        "periodic-wrap kernel-op count must be independent of grid size \
         (nlon=4 -> {}, nlon=8 -> {})",
        s4.kernel_ops, s8.kernel_ops
    );
}

// ============================================================================
// Oracle / vectorized equivalence on the shapes where the two paths used to
// DISAGREE (audit 2026-07-14, findings R3 and R4).
//
// The two evaluators are supposed to be one semantics with two
// implementations. They were not. `fold_scalar` (oracle) special-cased arity —
// `NaN` for `-`/`/`/`^` unless binary, `NaN` for `min`/`max` unless n >= 2 —
// while the vectorized overlay left-folded ANY arity through `apply_binary`.
// And an array-valued `filter` was a per-cell MASK on the vectorized path but
// "exclude every cell" on the oracle. In both cases the answer you got depended
// on whether the enclosing body happened to vectorize, which is an
// implementation detail.
//
// The illegal arities are now rejected before evaluation (see
// `op_registry`), so what remains to prove is the other half of the contract:
// for every arity that IS legal, the two paths compute the same number.
// ============================================================================

/// Every legal arity of the ops that used to diverge, in one vectorizable body.
fn all_legal_arities_json(n: usize) -> String {
    const TEMPLATE: &str = r#"{
 "esm": "0.1.0",
 "metadata": {"name": "arity_matrix"},
 "models": {
  "ArityMatrix": {
   "variables": {"u": {"type": "state", "shape": ["i"]}},
   "equations": [
    {
     "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, __N__]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "ranges": {"i": [1, __N__]},
             "expr": {"op": "+", "args": [
               {"op": "-",     "args": [{"op": "index", "args": ["u", "i"]}, 1]},
               {"op": "-",     "args": [{"op": "index", "args": ["u", "i"]}]},
               {"op": "neg",   "args": [{"op": "index", "args": ["u", "i"]}]},
               {"op": "/",     "args": [{"op": "index", "args": ["u", "i"]}, 2]},
               {"op": "^",     "args": [{"op": "index", "args": ["u", "i"]}, 2]},
               {"op": "min",   "args": [{"op": "index", "args": ["u", "i"]}, 1, 2]},
               {"op": "max",   "args": [{"op": "index", "args": ["u", "i"]}, 0]},
               {"op": "atan2", "args": [{"op": "index", "args": ["u", "i"]}, 2]},
               {"op": "and",   "args": [{"op": "index", "args": ["u", "i"]}, 1]},
               {"op": "or",    "args": [{"op": "index", "args": ["u", "i"]}, 0]},
               {"op": "*",     "args": [{"op": "index", "args": ["u", "i"]}, 2, 3]}
             ]}}
    }
   ]
  }
 }
}"#;
    TEMPLATE.replace("__N__", &n.to_string())
}

/// R3: for every arity the spec calls LEGAL, the per-cell oracle and the
/// vectorized overlay must compute the same value — including the n-ary
/// `+`/`*`/`min`, the unary-vs-binary `-`, and the n-ary `and`/`or` whose fold
/// is a strict 1.0/0.0 flag rather than a raw operand.
#[test]
fn vectorized_matches_oracle_on_every_legal_arity() {
    let compiled = compile_json(&all_legal_arities_json(6));
    let state = sample_state(6);
    let (dy_vec, vstats) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), false);
    let (dy_scalar, sstats) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), true);

    assert_eq!(
        vstats.vectorized_rules, 1,
        "the arity matrix must actually take the vectorized path, else this \
         test proves nothing: {vstats:?}"
    );
    assert_eq!(sstats.scalar_rules, 1, "force_scalar must use the oracle");
    assert_eq!(dy_vec.len(), dy_scalar.len());
    for (k, (a, b)) in dy_vec.iter().zip(dy_scalar.iter()).enumerate() {
        assert!(
            (a - b).abs() <= 1e-12,
            "oracle/vectorized divergence at slot {k}: vectorized={a} oracle={b}"
        );
        assert!(
            a.is_finite(),
            "slot {k} is not finite ({a}) — a legal arity must not produce the \
             NaN sentinel that `fold_scalar` used to return"
        );
    }
}

/// The `mask = [1, 0, 1]` / `filter: mask > 0.5` / `body = 10` document from
/// audit finding R4, with a body that vectorizes.
fn array_filter_json() -> String {
    r#"{
 "esm": "0.1.0",
 "metadata": {"name": "array_filter"},
 "models": {
  "ArrayFilter": {
   "variables": {
     "u":    {"type": "state", "shape": ["i"]},
     "mask": {"type": "state", "shape": ["i"]}
   },
   "equations": [
    {
     "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, 3]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "ranges": {"i": [1, 3]},
             "filter": {"op": ">", "args": ["mask", 0.5]},
             "expr": 10}
    },
    {
     "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "expr": {"op": "D", "args": [{"op": "index", "args": ["mask", "i"]}], "wrt": "t"},
             "ranges": {"i": [1, 3]}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"],
             "ranges": {"i": [1, 3]},
             "expr": 0}
    }
   ]
  }
 }
}"#
    .to_string()
}

/// R4: an ARRAY-valued `filter` is a per-cell mask on BOTH paths.
///
/// This test pins the *value*, not merely the agreement — `[0, 0, 0]` on both
/// paths would satisfy an equality-only assertion while still being the wrong
/// answer (it is precisely the bug: the oracle coerced the non-scalar filter to
/// `0.0` and excluded every cell). The intended reading, the one the vectorized
/// path's `vec_select` already implemented and its doc-comments advertise, is a
/// genuine per-cell gate.
#[test]
fn array_valued_filter_is_a_per_cell_mask_on_both_paths() {
    let compiled = compile_json(&array_filter_json());
    let names = compiled.state_variable_names();
    assert_eq!(names.len(), 6, "expected u[3] + mask[3], got {names:?}");

    // Slot order follows `state_variable_names`; build the state from it so the
    // test does not hard-code a layout.
    let state: Vec<f64> = names
        .iter()
        .map(|n| {
            if !n.contains("mask") {
                return 0.0;
            }
            // mask = [1, 0, 1] — the middle cell is gated OFF.
            if n.contains("[2]") { 0.0 } else { 1.0 }
        })
        .collect();

    let (dy_vec, _) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), false);
    let (dy_scalar, _) = compiled.debug_eval_rhs(&state, 0.0, &HashMap::new(), true);

    let u_of = |dy: &[f64]| -> Vec<f64> {
        names
            .iter()
            .zip(dy.iter())
            .filter(|(n, _)| !n.contains("mask"))
            .map(|(_, v)| *v)
            .collect()
    };
    let (u_vec, u_scalar) = (u_of(&dy_vec), u_of(&dy_scalar));

    assert_eq!(
        u_vec, u_scalar,
        "the two paths disagree on an array-valued filter: vectorized={u_vec:?} \
         oracle={u_scalar:?}"
    );
    assert_eq!(
        u_vec,
        vec![10.0, 0.0, 10.0],
        "an array filter must gate PER CELL (mask=[1,0,1] => [10,0,10]); \
         [0,0,0] means the filter was coerced to a false scalar and every cell \
         was dropped, which is the R4 bug"
    );
}
