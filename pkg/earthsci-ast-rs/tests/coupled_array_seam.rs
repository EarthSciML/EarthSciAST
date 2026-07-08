//! Coupled-array seam: `ArrayCompiled::from_flattened` (ess-14f.8).
//!
//! The array runtime historically only had `ArrayCompiled::from_file`, which
//! rejects `models.len() != 1` because it consumes a raw single `Model` and
//! has no coupling machinery. Coupling is already solved one layer up by
//! `flatten::flatten()`, which merges every component into a single
//! dot-namespaced `FlattenedSystem`. These tests exercise the new seam that
//! lets the array runtime consume that flatten output directly, so a coupled
//! *discretized* (array-shaped) system compiles and evaluates end-to-end.
//!
//! Two properties are pinned:
//!   1. Flattening preserves `arrayop` structure. The pre-seam `namespace_expr`
//!      rebuilt operator nodes with `..Default::default()`, silently dropping
//!      `expr`/`ranges`/`output_idx`/… — corrupting every array node. The fix
//!      preserves all fields, namespaces the body's free variables, and leaves
//!      loop indices alone.
//!   2. A coupled two-model array system compiles via `from_flattened` and via
//!      the top-level `simulate()` dispatcher, matching a closed-form solution.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::flatten::flatten;
use earthsci_ast::simulate_array::ArrayCompiled;
use earthsci_ast::types::Expr;
use earthsci_ast::{SimulateOptions, SolverChoice, load, simulate};
use std::collections::HashMap;

/// Two coupled array-shaped models.
///
/// `Src.u[i]` decays (`D(u[i]) = -u[i]`); `Snk.w[i]` integrates the source
/// field it reads across the component boundary (`D(w[i]) = Src.u[i]`, a dotted
/// cross-system reference inside an `arrayop` body). Both equations are written
/// as `arrayop`s over `i ∈ [1, 3]`, so flattening must carry the array
/// structure through namespacing for either model to compile.
///
/// Closed form with `u(0) = [1, 2, 3]`, `w(0) = 0`:
///   `u[i](t) = u0[i]·e^{-t}`,  `w[i](t) = u0[i]·(1 - e^{-t})`.
const COUPLED_ARRAY_JSON: &str = r#"{
 "esm": "0.1.0",
 "metadata": {"name": "coupled_array_seam"},
 "models": {
  "Src": {
   "variables": {"u": {"type": "state", "shape": ["i"]}},
   "equations": [
    {
     "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
             "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
             "expr": {"op": "*", "args": [-1, {"op": "index", "args": ["u", "i"]}]}}
    }
   ]
  },
  "Snk": {
   "variables": {"w": {"type": "state", "shape": ["i"]}},
   "equations": [
    {
     "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
             "expr": {"op": "D", "args": [{"op": "index", "args": ["w", "i"]}], "wrt": "t"}},
     "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
             "expr": {"op": "index", "args": ["Src.u", "i"]}}
    }
   ]
  }
 }
}"#;

fn fast_opts(final_t: f64) -> SimulateOptions {
    SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-10,
        reltol: 1e-8,
        max_steps: 100_000,
        output_times: Some(vec![final_t]),
    }
}

/// Final-time value of a named scalar state slot (e.g. `"Src.u[1]"`).
fn final_value(sol: &earthsci_ast::Solution, name: &str) -> f64 {
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

/// Does `expr` contain a reference to the variable named `name` anywhere
/// (including inside `arrayop` bodies)?
fn expr_references(expr: &Expr, name: &str) -> bool {
    match expr {
        Expr::Variable(v) => v == name,
        Expr::Number(_) | Expr::Integer(_) => false,
        Expr::Operator(node) => {
            node.args.iter().any(|a| expr_references(a, name))
                || node
                    .expr
                    .as_deref()
                    .is_some_and(|e| expr_references(e, name))
                || node
                    .filter
                    .as_deref()
                    .is_some_and(|e| expr_references(e, name))
        }
    }
}

#[test]
fn flatten_preserves_arrayop_structure_and_namespaces_body() {
    let file = load(COUPLED_ARRAY_JSON).expect("load coupled array file");
    let flat = flatten(&file).expect("flatten coupled array file");

    // Variables from both components are present and dot-namespaced.
    assert!(
        flat.state_variables.contains_key("Src.u"),
        "expected namespaced state Src.u, have {:?}",
        flat.state_variables.keys().collect::<Vec<_>>()
    );
    assert!(
        flat.state_variables.contains_key("Snk.w"),
        "expected namespaced state Snk.w, have {:?}",
        flat.state_variables.keys().collect::<Vec<_>>()
    );

    // Find the Snk equation (the one whose RHS reads the cross-system field).
    let snk_eq = flat
        .equations
        .iter()
        .find(|eq| expr_references(&eq.rhs, "Src.u"))
        .expect("Snk equation reading Src.u survived flattening");

    let Expr::Operator(rhs) = &snk_eq.rhs else {
        panic!(
            "Snk RHS should be an arrayop operator node, got {:?}",
            snk_eq.rhs
        );
    };
    // The arrayop sidecar fields must survive namespacing — the regression the
    // seam fixes is `..Default::default()` wiping exactly these.
    assert_eq!(rhs.op, "aggregate");
    assert_eq!(
        rhs.output_idx.as_deref(),
        Some(&["i".to_string()][..]),
        "output_idx dropped by namespacing"
    );
    assert!(rhs.ranges.is_some(), "ranges dropped by namespacing");
    assert!(
        rhs.expr.is_some(),
        "arrayop body (expr) dropped by namespacing"
    );

    // The body keeps the dotted cross-system reference verbatim (not
    // re-namespaced to `Snk.Src.u`) and does NOT namespace the loop index `i`.
    let body = rhs.expr.as_deref().unwrap();
    assert!(
        expr_references(body, "Src.u"),
        "cross-system reference Src.u must survive un-rewritten in the body"
    );
    assert!(
        expr_references(body, "i"),
        "loop index i must stay un-namespaced (not Snk.i) in the body"
    );
    assert!(
        !expr_references(body, "Snk.Src.u") && !expr_references(body, "Snk.i"),
        "namespacing must not double-prefix dotted refs or capture loop indices"
    );
}

#[test]
fn coupled_array_from_file_still_rejects_raw_multimodel() {
    // The raw single-model convenience guard stays intact: the seam is reached
    // by flattening first, not by relaxing `from_file`.
    let file = load(COUPLED_ARRAY_JSON).expect("load coupled array file");
    let err = match ArrayCompiled::from_file(&file) {
        Ok(_) => panic!("from_file must reject a multi-model file"),
        Err(e) => e,
    };
    let msg = format!("{err:?}");
    assert!(
        msg.contains("single model"),
        "expected the single-model rejection, got: {msg}"
    );
}

#[test]
fn coupled_array_compiles_and_evaluates_via_from_flattened() {
    let file = load(COUPLED_ARRAY_JSON).expect("load coupled array file");
    let flat = flatten(&file).expect("flatten");
    let compiled = ArrayCompiled::from_flattened(&flat).expect("from_flattened compiles coupled");

    // Both components contribute their array slots to the state vector.
    let names = compiled.state_variable_names();
    for slot in ["Src.u[1]", "Src.u[3]", "Snk.w[1]", "Snk.w[3]"] {
        assert!(
            names.iter().any(|n| n == slot),
            "expected state slot {slot}, have {names:?}"
        );
    }

    let ics: HashMap<String, f64> = [
        ("Src.u[1]", 1.0),
        ("Src.u[2]", 2.0),
        ("Src.u[3]", 3.0),
        ("Snk.w[1]", 0.0),
        ("Snk.w[2]", 0.0),
        ("Snk.w[3]", 0.0),
    ]
    .iter()
    .map(|(k, v)| (k.to_string(), *v))
    .collect();

    let sol = compiled
        .simulate((0.0, 1.0), &HashMap::new(), &ics, &fast_opts(1.0))
        .expect("simulate coupled array");

    let decay = (-1.0f64).exp(); // e^{-1}
    let grow = 1.0 - decay; // 1 - e^{-1}
    for (i, u0) in [(1usize, 1.0), (2, 2.0), (3, 3.0)] {
        let u = final_value(&sol, &format!("Src.u[{i}]"));
        let w = final_value(&sol, &format!("Snk.w[{i}]"));
        assert!(
            (u - u0 * decay).abs() < 1e-4,
            "Src.u[{i}](1) = {u}, expected {}",
            u0 * decay
        );
        assert!(
            (w - u0 * grow).abs() < 1e-4,
            "Snk.w[{i}](1) = {w}, expected {} (integral of coupled source)",
            u0 * grow
        );
    }
}

#[test]
fn coupled_array_evaluates_via_top_level_dispatcher() {
    // The user-facing `simulate()` entry point routes a coupled array file
    // through flatten + from_flattened instead of hitting the :579 rejection.
    let file = load(COUPLED_ARRAY_JSON).expect("load coupled array file");
    let ics: HashMap<String, f64> = [
        ("Src.u[1]", 1.0),
        ("Src.u[2]", 2.0),
        ("Src.u[3]", 3.0),
        ("Snk.w[1]", 0.0),
        ("Snk.w[2]", 0.0),
        ("Snk.w[3]", 0.0),
    ]
    .iter()
    .map(|(k, v)| (k.to_string(), *v))
    .collect();

    let sol = simulate(&file, (0.0, 1.0), &HashMap::new(), &ics, &fast_opts(1.0))
        .expect("dispatcher routes coupled array file through the seam");

    let grow = 1.0 - (-1.0f64).exp();
    let w2 = final_value(&sol, "Snk.w[2]");
    assert!(
        (w2 - 2.0 * grow).abs() < 1e-4,
        "Snk.w[2](1) = {w2}, expected {}",
        2.0 * grow
    );
}

#[test]
fn single_model_array_path_unchanged() {
    // A single-model array file keeps the byte-identical `from_file` path: the
    // dispatcher's `model_count > 1` guard leaves it on the raw entry point.
    let json = r#"{
     "esm": "0.1.0",
     "metadata": {"name": "single_array_decay"},
     "models": {
      "Only": {
       "variables": {"u": {"type": "state", "shape": ["i"]}},
       "equations": [
        {
         "lhs": {"op": "aggregate", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
                 "expr": {"op": "D", "args": [{"op": "index", "args": ["u", "i"]}], "wrt": "t"}},
         "rhs": {"op": "aggregate", "args": [], "output_idx": ["i"], "ranges": {"i": [1, 3]},
                 "expr": {"op": "*", "args": [-1, {"op": "index", "args": ["u", "i"]}]}}
        }
       ]
      }
     }
    }"#;
    let file = load(json).expect("load single-model array file");

    // The single-model file is NOT namespaced (one component) and builds via
    // the unchanged raw entry point.
    let compiled = ArrayCompiled::from_file(&file).expect("from_file builds single-model array");
    assert!(compiled.state_variable_names().iter().any(|n| n == "u[1]"));

    let ics: HashMap<String, f64> = [("u[1]", 1.0), ("u[2]", 2.0), ("u[3]", 3.0)]
        .iter()
        .map(|(k, v)| (k.to_string(), *v))
        .collect();
    let sol = simulate(&file, (0.0, 1.0), &HashMap::new(), &ics, &fast_opts(1.0))
        .expect("single-model array simulate");
    let decay = (-1.0f64).exp();
    let u2 = final_value(&sol, "u[2]");
    assert!(
        (u2 - 2.0 * decay).abs() < 1e-4,
        "u[2](1) = {u2}, expected {}",
        2.0 * decay
    );
}
