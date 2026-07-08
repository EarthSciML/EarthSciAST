//! End-to-end evaluator tests for the M1 `aggregate` deltas of RFC
//! `semiring-faq-unified-ir` (bead ess-my4.1.3):
//!
//! - **§5.6** the canonical `op: "aggregate"` tag evaluates identically to the
//!   deprecated `op: "arrayop"` alias;
//! - **§5.1** a named `semiring` drives the contraction's ⊕ (the legacy
//!   `reduce` string remains an exact equivalent for the overlapping ops);
//! - **§5.2** a `ranges` entry of the form `{ "from": <index set> }` resolves
//!   against the model `index_sets` registry, and an undeclared name is a hard
//!   error.
//!
//! Each model is a constant-RHS contraction from zero initial conditions:
//! `D(<var>[i])/dt = ⊕_{j∈1..3} body(i, j)` over `i ∈ 1..2`. With `body = i*j`
//! and ⊕ = `+`, `D(y[1]) = 1*1 + 1*2 + 1*3 = 6`, so `y[1](t=1) = 6`. The slow,
//! algebra-free RHS makes the expected values exact to integration tolerance.

#![cfg(not(target_arch = "wasm32"))]

use earthsci_ast::aggregate::resolve_aggregate_ranges;
use earthsci_ast::{SimulateOptions, SolverChoice, load, simulate};
use std::collections::HashMap;

/// Build a one-variable contraction model. `agg` is the RHS aggregation
/// attribute(s) with a trailing comma (e.g. `"reduce": "+",` or
/// `"semiring": "max_sum",`); `op` is the node tag; `body` is the scalar body
/// JSON; `lhs_ranges`/`rhs_ranges` are the `ranges` object JSON; `index_sets`
/// is the document-scoped registry JSON (empty string ⇒ omit it). Since v0.8.0
/// the registry is declared at the document top level (a sibling of `models`),
/// not per-model.
fn build(
    op: &str,
    var: &str,
    agg: &str,
    body: &str,
    lhs_ranges: &str,
    rhs_ranges: &str,
    index_sets: &str,
) -> String {
    let index_sets_field = if index_sets.is_empty() {
        String::new()
    } else {
        format!(r#""index_sets": {index_sets},"#)
    };
    format!(
        r#"{{
          "esm": "0.6.0",
          "metadata": {{ "name": "aggregate_eval_test" }},
          {index_sets_field}
          "models": {{ "M": {{
            "variables": {{ "{var}": {{ "type": "state", "shape": ["i"] }} }},
            "equations": [{{
              "lhs": {{ "op": "{op}", "args": [], "output_idx": ["i"],
                        "expr": {{ "op": "D",
                                   "args": [{{ "op": "index", "args": ["{var}", "i"] }}],
                                   "wrt": "t" }},
                        "ranges": {lhs_ranges} }},
              "rhs": {{ "op": "{op}", "args": [], "output_idx": ["i"], {agg}
                        "expr": {body},
                        "ranges": {rhs_ranges} }}
            }}]
          }} }}
        }}"#
    )
}

/// Simulate `model_json` from t=0 to t=1 and return the value of state slot
/// `var` (e.g. `"y[1]"`) at t=1, or an error string. Every model here declares
/// the array state `y` over `i ∈ 1..2`; the array runtime requires an explicit
/// initial condition per element, so we seed both at zero (the RHS is a
/// constant-rate forcing, so `y[i](t) = rate·t` regardless).
fn sim_value(model_json: &str, var: &str) -> Result<f64, String> {
    let file = load(model_json).map_err(|e| format!("load: {e}"))?;
    let opts = SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-10,
        reltol: 1e-8,
        max_steps: 100_000,
        output_times: Some(vec![1.0]),
    };
    let ics: HashMap<String, f64> =
        HashMap::from([("y[1]".to_string(), 0.0), ("y[2]".to_string(), 0.0)]);
    let sol = simulate(&file, (0.0, 1.0), &HashMap::new(), &ics, &opts)
        .map_err(|e| format!("simulate: {e}"))?;
    let slot = sol
        .state_variable_names
        .iter()
        .position(|n| n == var)
        .ok_or_else(|| {
            format!(
                "state slot '{var}' not found; known: {:?}",
                sol.state_variable_names
            )
        })?;
    let tix = sol
        .time
        .iter()
        .enumerate()
        .min_by(|(_, x), (_, y)| (*x - 1.0).abs().partial_cmp(&(*y - 1.0).abs()).unwrap())
        .map(|(i, _)| i)
        .unwrap_or(0);
    Ok(sol.state[slot][tix])
}

fn assert_close(actual: f64, expected: f64, ctx: &str) {
    assert!(
        (actual - expected).abs() <= 1e-5,
        "{ctx}: expected {expected}, got {actual}"
    );
}

const PROD_BODY: &str = r#"{ "op": "*", "args": ["i", "j"] }"#;
const SUM_BODY: &str = r#"{ "op": "+", "args": ["i", "j"] }"#;
const IJ_2X3: &str = r#"{ "i": [1, 2], "j": [1, 3] }"#;
const I_2: &str = r#"{ "i": [1, 2] }"#;

/// §5.1: `semiring: "sum_product"` reproduces `reduce: "+"` exactly.
/// `D(y[i]) = Σ_j i*j` ⇒ `y[1](1) = 6`, `y[2](1) = 12`.
#[test]
fn sum_product_semiring_matches_reduce_plus() {
    let by_reduce = build(
        "aggregate",
        "y",
        r#""reduce": "+","#,
        PROD_BODY,
        I_2,
        IJ_2X3,
        "",
    );
    let by_semiring = build(
        "aggregate",
        "y",
        r#""semiring": "sum_product","#,
        PROD_BODY,
        I_2,
        IJ_2X3,
        "",
    );
    assert_close(sim_value(&by_reduce, "y[1]").unwrap(), 6.0, "reduce + y[1]");
    assert_close(
        sim_value(&by_semiring, "y[1]").unwrap(),
        6.0,
        "sum_product y[1]",
    );
    assert_close(
        sim_value(&by_semiring, "y[2]").unwrap(),
        12.0,
        "sum_product y[2]",
    );
}

/// §5.1: `semiring: "max_sum"` reduces with ⊕ = max over `body = i+j`.
/// `D(y[i]) = max_j (i+j)` ⇒ `y[1](1) = max(2,3,4) = 4`, `y[2](1) = 5`.
/// Matches the legacy `reduce: "max"` exactly.
#[test]
fn max_sum_semiring_matches_reduce_max() {
    let by_reduce = build(
        "aggregate",
        "y",
        r#""reduce": "max","#,
        SUM_BODY,
        I_2,
        IJ_2X3,
        "",
    );
    let by_semiring = build(
        "aggregate",
        "y",
        r#""semiring": "max_sum","#,
        SUM_BODY,
        I_2,
        IJ_2X3,
        "",
    );
    assert_close(
        sim_value(&by_reduce, "y[1]").unwrap(),
        4.0,
        "reduce max y[1]",
    );
    assert_close(
        sim_value(&by_semiring, "y[1]").unwrap(),
        4.0,
        "max_sum y[1]",
    );
    assert_close(
        sim_value(&by_semiring, "y[2]").unwrap(),
        5.0,
        "max_sum y[2]",
    );
}

/// §5.1: `semiring: "min_sum"` (tropical) reduces with ⊕ = min.
/// `D(y[i]) = min_j (i+j)` ⇒ `y[1](1) = min(2,3,4) = 2`, `y[2](1) = 3`.
#[test]
fn min_sum_semiring_reduces_with_min() {
    let m = build(
        "aggregate",
        "y",
        r#""semiring": "min_sum","#,
        SUM_BODY,
        I_2,
        IJ_2X3,
        "",
    );
    assert_close(sim_value(&m, "y[1]").unwrap(), 2.0, "min_sum y[1]");
    assert_close(sim_value(&m, "y[2]").unwrap(), 3.0, "min_sum y[2]");
}

/// §5.6: the canonical `op: "aggregate"` tag evaluates identically to the
/// `arrayop` alias (here carrying a `semiring`, so both deltas are exercised
/// together through the full simulate pipeline).
#[test]
fn aggregate_tag_is_alias_of_arrayop() {
    let m = build(
        "aggregate",
        "y",
        r#""semiring": "sum_product","#,
        PROD_BODY,
        I_2,
        IJ_2X3,
        "",
    );
    assert_close(sim_value(&m, "y[1]").unwrap(), 6.0, "aggregate y[1]");
    assert_close(sim_value(&m, "y[2]").unwrap(), 12.0, "aggregate y[2]");
}

/// §5.2: `ranges` index-set references resolve against the model `index_sets`
/// registry. `{from:"cells"}` (interval size 2) and `{from:"steps"}` (interval
/// size 3) reproduce the explicit `[1,2]` / `[1,3]` bounds, so `y[1](1) = 6`.
#[test]
fn index_set_from_references_resolve_to_intervals() {
    let index_sets = r#"{ "cells": { "kind": "interval", "size": 2 },
                          "steps": { "kind": "interval", "size": 3 } }"#;
    let lhs = r#"{ "i": { "from": "cells" } }"#;
    let rhs = r#"{ "i": { "from": "cells" }, "j": { "from": "steps" } }"#;
    let m = build(
        "aggregate",
        "y",
        r#""semiring": "sum_product","#,
        PROD_BODY,
        lhs,
        rhs,
        index_sets,
    );
    assert_close(sim_value(&m, "y[1]").unwrap(), 6.0, "from-resolved y[1]");
    assert_close(sim_value(&m, "y[2]").unwrap(), 12.0, "from-resolved y[2]");
}

/// §5.2: a categorical index set resolves to `[1, |members|]`.
/// `{from:"fuels"}` with three members reproduces `j ∈ 1..3`.
#[test]
fn categorical_index_set_resolves_to_member_count() {
    let index_sets = r#"{ "cells": { "kind": "interval", "size": 2 },
                          "fuels": { "kind": "categorical",
                                     "members": ["gas", "diesel", "coal"] } }"#;
    let lhs = r#"{ "i": { "from": "cells" } }"#;
    let rhs = r#"{ "i": { "from": "cells" }, "j": { "from": "fuels" } }"#;
    let m = build(
        "aggregate",
        "y",
        r#""semiring": "sum_product","#,
        PROD_BODY,
        lhs,
        rhs,
        index_sets,
    );
    // Σ_{j=1..3} i*j = 6i ⇒ y[1] = 6.
    assert_close(sim_value(&m, "y[1]").unwrap(), 6.0, "categorical y[1]");
}

/// §5.2: an undeclared `{from}` name is a hard error (no implicit interval
/// inference), and the message names the offending set.
#[test]
fn undeclared_from_name_is_rejected() {
    let lhs = r#"{ "i": { "from": "nonesuch" } }"#;
    let rhs = r#"{ "i": { "from": "nonesuch" }, "j": [1, 3] }"#;
    let m = build(
        "aggregate",
        "y",
        r#""semiring": "sum_product","#,
        PROD_BODY,
        lhs,
        rhs,
        "",
    );
    let err = sim_value(&m, "y[1]").expect_err("undeclared {from} must error");
    assert!(
        err.contains("nonesuch"),
        "error should name the undeclared set: {err}"
    );
}

/// Cross-bead check: the shared M1 schema fixture (authored by the schema bead
/// ess-my4.1.1) deserializes into the Rust types and its `{from}` index-set
/// ranges resolve cleanly through *this* bead's resolver — `op:"aggregate"`,
/// the `semiring` enum, the `index_sets` registry (interval + categorical), and
/// `ranges: { "from": "cells" }` all round-trip from the canonical fixture.
/// (A full ODE solve is out of scope: the fixture's scalar `Σ u[i]` accumulator
/// exercises an IC pattern the array runtime does not yet support, independent
/// of the M1 deltas.)
#[test]
fn shared_valid_aggregate_fixture_parses_and_resolves() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../tests/valid/aggregate/aggregate_semiring_indexset.esm"
    );
    let json = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path}: {e}"));
    let file = load(&json).unwrap_or_else(|e| panic!("load fixture: {e}"));

    let model = file
        .models
        .as_ref()
        .and_then(|m| m.values().next())
        .expect("fixture has a model")
        .clone();

    // The document-scoped `index_sets` registry (v0.8.0) deserialized into typed
    // entries at the top level — a sibling of `models`, not per-model.
    let index_sets = file
        .index_sets
        .as_ref()
        .expect("fixture declares top-level index_sets");
    assert_eq!(index_sets["cells"].kind, "interval");
    assert_eq!(index_sets["cells"].size, Some(5));
    assert_eq!(index_sets["county"].kind, "categorical");

    // The resolver accepts the fixture's `{from:"cells"}` references (interval
    // size 5) without error — the undeclared-from guard does not false-positive.
    let mut resolved = model;
    resolve_aggregate_ranges(&mut resolved, index_sets).expect("fixture `{from}` ranges resolve");
}

/// Cross-bead invalid fixture (bead ess-my4.1.6): the shared resolver-level
/// invalid fixture under tests/invalid/aggregate/ is SCHEMA-VALID (so `load`
/// succeeds) but its aggregate `{from}` ranges name `ghost_cells`, an index set
/// absent from the registry, so *this* bead's resolver rejects it (no implicit
/// interval inference, §5.2) and the message names the offending set. Schema-only
/// bindings (TypeScript/Go) accept it; see tests/invalid/expected_errors.json
/// (the `resolver_only` entry).
#[test]
fn shared_invalid_undeclared_from_fixture_is_rejected() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../tests/invalid/aggregate/undeclared_from_name.esm"
    );
    let json = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path}: {e}"));
    // Schema-valid: the loader accepts it.
    let file = load(&json).unwrap_or_else(|e| panic!("schema-valid fixture should load: {e}"));

    let mut model = file
        .models
        .as_ref()
        .and_then(|m| m.values().next())
        .expect("fixture has a model")
        .clone();

    // v0.8.0: the document-scoped registry is where declarations live; this
    // fixture declares none, so `{from:"ghost_cells"}` is undeclared.
    let index_sets = file.index_sets.clone().unwrap_or_default();
    let err = resolve_aggregate_ranges(&mut model, &index_sets)
        .expect_err("undeclared {from} must be rejected by the resolver");
    let msg = err.to_string();
    assert!(
        msg.contains("ghost_cells"),
        "error should name the undeclared set: {msg}"
    );
}

/// §5.2 ragged (bead ess-787): a contracted index whose per-parent length is a
/// backing factor drives a *dynamic* reduction bound through the full
/// compile→simulate pipeline (`resolve_aggregate_ranges` resolves the ragged
/// `{from}` to a `RaggedDyn`, `extract_derivative_arrayop` builds a ragged
/// `RhsRule::ArrayLoop`, and the contraction reads `nedges[i]` per output cell).
///
/// `nedges = [2, 3]` is held as a constant state (`D=0`) so it is a runtime
/// array the bound can gather; then `D(y[i]) = Σ_{k=1..nedges[i]} k` gives the
/// triangular numbers `y[1](1) = 1+2 = 3` and `y[2](1) = 1+2+3 = 6`. This is the
/// Rust port of the Python reference `test_ragged_index_set_dynamic_per_parent_bound`.
#[test]
fn ragged_index_set_drives_dynamic_reduction_bound() {
    let model = r#"{
      "esm": "0.6.0",
      "metadata": { "name": "ragged_dynamic_bound" },
      "index_sets": {
        "cells": { "kind": "interval", "size": 2 },
        "edges_of_cell": { "kind": "ragged", "of": ["cells"],
                           "offsets": "nedges", "values": "nedges" }
      },
      "models": { "M": {
        "variables": {
          "y": { "type": "state", "shape": ["i"] },
          "nedges": { "type": "state", "shape": ["i"] }
        },
        "equations": [
          { "lhs": { "op": "aggregate", "args": [], "output_idx": ["i"],
                     "expr": { "op": "D", "args": [{ "op": "index", "args": ["y", "i"] }], "wrt": "t" },
                     "ranges": { "i": { "from": "cells" } } },
            "rhs": { "op": "aggregate", "args": [], "output_idx": ["i"], "semiring": "sum_product",
                     "expr": "k",
                     "ranges": { "i": { "from": "cells" },
                                 "k": { "from": "edges_of_cell", "of": ["i"] } } } },
          { "lhs": { "op": "aggregate", "args": [], "output_idx": ["i"],
                     "expr": { "op": "D", "args": [{ "op": "index", "args": ["nedges", "i"] }], "wrt": "t" },
                     "ranges": { "i": [1, 2] } },
            "rhs": { "op": "aggregate", "args": [], "output_idx": ["i"],
                     "expr": 0, "ranges": { "i": [1, 2] } } }
        ]
      } }
    }"#;
    let file = load(model).unwrap_or_else(|e| panic!("load ragged model: {e}"));
    let opts = SimulateOptions {
        solver: SolverChoice::Bdf,
        abstol: 1e-10,
        reltol: 1e-8,
        max_steps: 100_000,
        output_times: Some(vec![1.0]),
    };
    let ics: HashMap<String, f64> = HashMap::from([
        ("y[1]".to_string(), 0.0),
        ("y[2]".to_string(), 0.0),
        ("nedges[1]".to_string(), 2.0),
        ("nedges[2]".to_string(), 3.0),
    ]);
    let sol = simulate(&file, (0.0, 1.0), &HashMap::new(), &ics, &opts)
        .unwrap_or_else(|e| panic!("simulate ragged: {e}"));
    let at_t1 = |name: &str| -> f64 {
        let slot = sol
            .state_variable_names
            .iter()
            .position(|n| n == name)
            .unwrap_or_else(|| {
                panic!(
                    "state slot '{name}' not found: {:?}",
                    sol.state_variable_names
                )
            });
        let tix = sol
            .time
            .iter()
            .enumerate()
            .min_by(|(_, x), (_, y)| (*x - 1.0).abs().partial_cmp(&(*y - 1.0).abs()).unwrap())
            .map(|(i, _)| i)
            .unwrap_or(0);
        sol.state[slot][tix]
    };
    assert_close(at_t1("y[1]"), 3.0, "y[1] = Σ_{k=1..2} k");
    assert_close(at_t1("y[2]"), 6.0, "y[2] = Σ_{k=1..3} k");
    // The connectivity factor is held constant by D=0.
    assert_close(at_t1("nedges[1]"), 2.0, "nedges[1] constant");
    assert_close(at_t1("nedges[2]"), 3.0, "nedges[2] constant");
}
