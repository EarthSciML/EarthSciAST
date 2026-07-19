//! End-to-end SIMULATE of a genuine value-invention (relational OUTPUT) model
//! through the array runtime — the capability that did not exist before the
//! value-invention front door was wired into the compile path
//! (`simulate_array::compile::materialize_vi_outputs_to_data`).
//!
//! Until now the arg-witness reducer `argmin` (RFC `semiring-faq-unified-ir`
//! §5.7 rule 6) was neither stripped by `strip_value_invention` (it is not a
//! skolem producer nor a derived-set-shaped var) nor evaluable by the per-cell
//! oracle (`is_evaluable_op("argmin") == false`), so an `.esm` carrying one could
//! be validated but never simulated in Rust — it raised
//! `UnevaluableOperatorError`. Julia and Python both materialize it live; this
//! closes that gap.
//!
//! The model is the unpruned nearest-generator assignment
//! `assign[i] = argmin_g dist(point_i, gen_g)` over the full points × generators
//! candidate set, with a DELIBERATE equidistant tie at point 3 (1.5 is exactly
//! 0.25 from generators at 1.0 and 2.0) that the §5.7 smallest-generator-id
//! tie-break resolves to the lower generator. The coordinate factors are
//! self-contained `const` observeds (mirroring the geometry `src_poly`/`tgt_poly`
//! fixtures), so the scalar-only `simulate` entry point can drive it. The
//! materialized integer buffer `[1, 2, 2, 3]` is byte-identical to the Julia /
//! Rust / Python `value_invention` front-door goldens.
//!
//! To prove the value flows through a real trajectory (not just a build-time
//! buffer), the argmin output feeds an ODE state: `D(u[i])/dt = assign[i]`, so
//! from `u(0) = 0` the integrated `u(1)` equals the nearest-generator index of
//! each point — non-NaN, correct, and observable in the solution.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::{SimulateOptions, SolverChoice, load, simulate};
use std::collections::HashMap;

/// The squared-Euclidean distance FAQ `(px[i]-gx[g])² + (py[i]-gy[g])²`, the
/// argmin's scalar body (squared so the metric is `*`/`-`/`+` only — argmin is
/// invariant to the monotone square, no `sqrt`; every distance an exact dyadic so
/// the tie is bit-exact).
fn sq_dist() -> &'static str {
    r#"{
        "op": "+",
        "args": [
          { "op": "*", "args": [
            { "op": "-", "args": [ {"op":"index","args":["px","i"]}, {"op":"index","args":["gx","g"]} ] },
            { "op": "-", "args": [ {"op":"index","args":["px","i"]}, {"op":"index","args":["gx","g"]} ] } ] },
          { "op": "*", "args": [
            { "op": "-", "args": [ {"op":"index","args":["py","i"]}, {"op":"index","args":["gy","g"]} ] },
            { "op": "-", "args": [ {"op":"index","args":["py","i"]}, {"op":"index","args":["gy","g"]} ] } ] }
        ]
      }"#
}

/// `argmin_g dist` per point `i` → the nearest-generator INDEX buffer `assign`.
/// Generators on the x-axis at 0,1,2; points at (0,0),(1,0.5),(1.5,0),(2,0) →
/// assign = [1, 2, 2, 3] (point 3 is the equidistant tie → the smaller id 2).
fn argmin_model() -> String {
    format!(
        r#"{{
      "esm": "0.6.0",
      "metadata": {{ "name": "argmin_simulate" }},
      "index_sets": {{
        "points":     {{ "kind": "interval", "size": 4 }},
        "generators": {{ "kind": "interval", "size": 3 }}
      }},
      "models": {{ "M": {{
        "variables": {{
          "gx": {{ "type": "observed", "shape": ["generators"], "expression": {{ "op": "const", "args": [], "value": [0.0, 1.0, 2.0] }} }},
          "gy": {{ "type": "observed", "shape": ["generators"], "expression": {{ "op": "const", "args": [], "value": [0.0, 0.0, 0.0] }} }},
          "px": {{ "type": "observed", "shape": ["points"],     "expression": {{ "op": "const", "args": [], "value": [0.0, 1.0, 1.5, 2.0] }} }},
          "py": {{ "type": "observed", "shape": ["points"],     "expression": {{ "op": "const", "args": [], "value": [0.0, 0.5, 0.0, 0.0] }} }},
          "assign": {{ "type": "state", "shape": ["points"], "description": "nearest-generator index (argmin arg-witness output)" }},
          "u":      {{ "type": "state", "shape": ["points"], "description": "integrated witness: D(u[i]) = assign[i]" }}
        }},
        "equations": [
          {{
            "lhs": {{ "op": "index", "args": ["assign", "i"] }},
            "rhs": {{ "op": "aggregate", "output_idx": ["i"], "ranges": {{ "i": {{ "from": "points" }} }},
                     "args": ["px", "py", "gx", "gy"],
                     "expr": {{ "op": "argmin", "args": ["px", "py", "gx", "gy"], "arg": "g",
                               "ranges": {{ "g": {{ "from": "generators" }} }},
                               "expr": {body} }} }}
          }},
          {{
            "lhs": {{ "op": "aggregate", "args": [], "output_idx": ["i"], "ranges": {{ "i": {{ "from": "points" }} }},
                     "expr": {{ "op": "D", "args": [ {{ "op": "index", "args": ["u", "i"] }} ], "wrt": "t" }} }},
            "rhs": {{ "op": "aggregate", "args": [], "output_idx": ["i"], "ranges": {{ "i": {{ "from": "points" }} }},
                     "expr": {{ "op": "index", "args": ["assign", "i"] }} }}
          }}
        ]
      }} }}
    }}"#,
        body = sq_dist()
    )
}

fn opts() -> SimulateOptions {
    SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-10,
        reltol: 1e-8,
        max_steps: 100_000,
        output_times: Some(vec![1.0]),
    }
}

/// The argmin/nearest-generator assignment simulates end-to-end and produces the
/// correct, non-NaN buffer `[1, 2, 2, 3]` (integrated into `u` over `t ∈ [0,1]`).
#[test]
fn argmin_nearest_generator_simulates_end_to_end() {
    let file = load(&argmin_model()).expect("argmin model loads");
    let ics: HashMap<String, f64> = ["u[1]", "u[2]", "u[3]", "u[4]"]
        .into_iter()
        .map(|k| (k.to_string(), 0.0))
        .collect();

    let sol = simulate(&file, (0.0, 1.0), &HashMap::new(), &ics, &opts())
        .expect("value-invention argmin model must SIMULATE (not UnevaluableOperatorError)");

    // Final time index.
    let tix = sol
        .time
        .iter()
        .enumerate()
        .min_by(|(_, a), (_, b)| (**a - 1.0).abs().partial_cmp(&(**b - 1.0).abs()).unwrap())
        .map(|(i, _)| i)
        .expect("at least one output node");

    // u(1) = u0 + assign·1 = the nearest-generator index of each point.
    let expected = [1.0, 2.0, 2.0, 3.0];
    for (p, want) in expected.iter().enumerate() {
        let slot = format!("u[{}]", p + 1);
        let idx = sol
            .state_variable_names
            .iter()
            .position(|n| n == &slot)
            .unwrap_or_else(|| {
                panic!(
                    "state slot '{slot}' not found; known: {:?}",
                    sol.state_variable_names
                )
            });
        let got = sol.state[idx][tix];
        assert!(got.is_finite(), "u[{}] must be non-NaN, got {got}", p + 1);
        assert!(
            (got - want).abs() < 1e-6,
            "nearest-generator argmin: u[{}](1) = {got}, expected {want} (assign = [1,2,2,3])",
            p + 1
        );
    }
}

/// The SCVT centroid-update STEP (bead ess-2u5, mpas-scvt): grouped `sum_product`
/// reductions whose group KEY is the data-dependent `argmin` assignment buffer,
/// run through the relational `group_aggregate`, plus an elementwise derived
/// buffer `centroid[g] = num[g]/den[g]`. None of these are evaluable by the dense
/// oracle; they materialize to constant data here. Generators at 0,1,2; points at
/// 0,0.75,1.25,2 with density rho = 1,1,3,4 ⇒ assign = [1,2,2,3], num =
/// [0,4.5,8], den = [1,4,4], centroid = [0,1.125,2] (generator 2 moves from its
/// seed at 1.0 to 1.125). The derived centroid feeds an ODE state, so the
/// integrated `cu(1)` equals the next Lloyd/SCVT generator positions — exactly
/// the numbers the `value_invention` front-door goldens assert.
fn centroid_model() -> &'static str {
    r#"{
      "esm": "0.6.0",
      "metadata": { "name": "centroid_simulate" },
      "index_sets": {
        "points":     { "kind": "interval", "size": 4 },
        "generators": { "kind": "interval", "size": 3 }
      },
      "models": { "M": {
        "variables": {
          "gx":  { "type": "observed", "shape": ["generators"], "expression": { "op": "const", "args": [], "value": [0.0, 1.0, 2.0] } },
          "px":  { "type": "observed", "shape": ["points"],     "expression": { "op": "const", "args": [], "value": [0.0, 0.75, 1.25, 2.0] } },
          "rho": { "type": "observed", "shape": ["points"],     "expression": { "op": "const", "args": [], "value": [1.0, 1.0, 3.0, 4.0] } },
          "assign":   { "type": "state", "shape": ["points"] },
          "num":      { "type": "state", "shape": ["generators"] },
          "den":      { "type": "state", "shape": ["generators"] },
          "centroid": { "type": "state", "shape": ["generators"] },
          "cu":       { "type": "state", "shape": ["generators"], "description": "integrated centroid: D(cu[g]) = centroid[g]" }
        },
        "equations": [
          { "lhs": { "op": "index", "args": ["assign", "i"] },
            "rhs": { "op": "aggregate", "output_idx": ["i"], "ranges": { "i": { "from": "points" } },
                     "args": ["px", "gx"],
                     "expr": { "op": "argmin", "args": ["px", "gx"], "arg": "g", "ranges": { "g": { "from": "generators" } },
                               "expr": { "op": "*", "args": [
                                  { "op": "-", "args": [ {"op":"index","args":["px","i"]}, {"op":"index","args":["gx","g"]} ] },
                                  { "op": "-", "args": [ {"op":"index","args":["px","i"]}, {"op":"index","args":["gx","g"]} ] } ] } } } },
          { "lhs": { "op": "index", "args": ["num", "g"] },
            "rhs": { "op": "aggregate", "output_idx": ["g"], "ranges": { "g": { "from": "generators" }, "p": { "from": "points" } },
                     "semiring": "sum_product", "join": [ { "on": [ ["assign", "g"] ] } ], "args": ["assign", "rho", "px"],
                     "expr": { "op": "*", "args": [ {"op":"index","args":["rho","p"]}, {"op":"index","args":["px","p"]} ] } } },
          { "lhs": { "op": "index", "args": ["den", "g"] },
            "rhs": { "op": "aggregate", "output_idx": ["g"], "ranges": { "g": { "from": "generators" }, "p": { "from": "points" } },
                     "semiring": "sum_product", "join": [ { "on": [ ["assign", "g"] ] } ], "args": ["assign", "rho"],
                     "expr": { "op": "index", "args": ["rho", "p"] } } },
          { "lhs": { "op": "index", "args": ["centroid", "g"] },
            "rhs": { "op": "aggregate", "output_idx": ["g"], "ranges": { "g": { "from": "generators" } }, "args": ["num", "den"],
                     "expr": { "op": "/", "args": [ {"op":"index","args":["num","g"]}, {"op":"index","args":["den","g"]} ] } } },
          { "lhs": { "op": "aggregate", "args": [], "output_idx": ["g"], "ranges": { "g": { "from": "generators" } },
                     "expr": { "op": "D", "args": [ { "op": "index", "args": ["cu", "g"] } ], "wrt": "t" } },
            "rhs": { "op": "aggregate", "args": [], "output_idx": ["g"], "ranges": { "g": { "from": "generators" } },
                     "expr": { "op": "index", "args": ["centroid", "g"] } } }
        ]
      } }
    }"#
}

/// The grouped `group_aggregate` (num / den) over the argmin key and the derived
/// centroid simulate end-to-end to the correct, non-NaN buffer `[0, 1.125, 2]`.
#[test]
fn scvt_centroid_group_aggregate_simulates_end_to_end() {
    let file = load(centroid_model()).expect("centroid model loads");
    let ics: HashMap<String, f64> = ["cu[1]", "cu[2]", "cu[3]"]
        .into_iter()
        .map(|k| (k.to_string(), 0.0))
        .collect();

    let sol = simulate(&file, (0.0, 1.0), &HashMap::new(), &ics, &opts())
        .expect("value-invention group_aggregate/centroid model must SIMULATE");

    let tix = sol
        .time
        .iter()
        .enumerate()
        .min_by(|(_, a), (_, b)| (**a - 1.0).abs().partial_cmp(&(**b - 1.0).abs()).unwrap())
        .map(|(i, _)| i)
        .expect("at least one output node");

    let expected = [0.0, 1.125, 2.0];
    for (g, want) in expected.iter().enumerate() {
        let slot = format!("cu[{}]", g + 1);
        let idx = sol
            .state_variable_names
            .iter()
            .position(|n| n == &slot)
            .unwrap_or_else(|| {
                panic!(
                    "state slot '{slot}' not found; known: {:?}",
                    sol.state_variable_names
                )
            });
        let got = sol.state[idx][tix];
        assert!(got.is_finite(), "cu[{}] must be non-NaN, got {got}", g + 1);
        assert!(
            (got - want).abs() < 1e-6,
            "SCVT centroid: cu[{}](1) = {got}, expected {want} (centroid = [0, 1.125, 2])",
            g + 1
        );
    }
}
