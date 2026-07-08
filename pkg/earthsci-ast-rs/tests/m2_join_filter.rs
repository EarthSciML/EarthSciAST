//! M2 join.on + filter integration tests (RFC `semiring-faq-unified-ir` §5.3,
//! bead ess-my4.2.3).
//!
//! Covers the build-time `join` resolution and the `filter` predicate as they
//! flow through the real parse / build / simulate pipeline, complementing the
//! engine-level unit tests in `src/join.rs`:
//!
//! - **Round-trip fidelity.** The two additive M2 fields (`join`, `filter`)
//!   survive parse → serialize on the committed `join_filter.esm` fixture (they
//!   would be silently dropped without the `ExpressionNode` field wiring).
//! - **Degenerate positional join is byte-identical.** A join whose key columns
//!   are the aggregate's loop indices is a no-op: the simulated trajectory is
//!   bit-for-bit identical to the same model with no `join` clause (§5.3).
//! - **Filter gates the reduction.** A `filter` predicate excludes the
//!   combinations for which it is false, which contribute the additive identity
//!   `0̄` — exercised through the array-state derivative reduction path.
//! - **Non-degenerate join is rejected, not mis-evaluated.** A join over a key
//!   column that is not a loop index errors at build (the data-derived
//!   value-equality engine is M3), rather than silently producing the wrong sum.

use earthsci_ast::types::Expr;
use earthsci_ast::{EsmFile, SimulateOptions, SolverChoice, load, save, simulate};
use std::collections::HashMap;

/// Build a `D(y[i]) = aggregate over j of body` contraction model. `rhs_extra`
/// is injected verbatim into the RHS aggregate node (e.g. a `"filter": …,` or
/// `"join": …,` attribute, each with a trailing comma), so the same skeleton
/// serves the no-op / filtered / joined variants. `y` is an array state over
/// `i ∈ 1..2`; the RHS contracts `j ∈ 1..3` with `reduce: "+"`.
fn contraction_model(rhs_extra: &str) -> String {
    format!(
        r#"{{
          "esm": "0.6.0",
          "metadata": {{ "name": "m2_join_filter_test" }},
          "models": {{ "M": {{
            "variables": {{ "y": {{ "type": "state", "shape": ["i"] }} }},
            "equations": [{{
              "lhs": {{ "op": "aggregate", "args": [], "output_idx": ["i"],
                        "expr": {{ "op": "D",
                                   "args": [{{ "op": "index", "args": ["y", "i"] }}],
                                   "wrt": "t" }},
                        "ranges": {{ "i": [1, 2] }} }},
              "rhs": {{ "op": "aggregate", "args": [], "output_idx": ["i"],
                        "reduce": "+",
                        {rhs_extra}
                        "expr": {{ "op": "*", "args": ["i", "j"] }},
                        "ranges": {{ "i": [1, 2], "j": [1, 3] }} }}
            }}]
          }} }}
        }}"#
    )
}

/// Simulate from t=0 to t=1 and return `y[slot]` at t=1. The RHS is a constant
/// forcing, so `y[i](1)` equals that constant rate.
fn sim_y(model_json: &str, slot: &str) -> Result<f64, String> {
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
    let idx = sol
        .state_variable_names
        .iter()
        .position(|n| n == slot)
        .ok_or_else(|| format!("slot '{slot}' not found in {:?}", sol.state_variable_names))?;
    let tix = sol.time.len() - 1;
    Ok(sol.state[idx][tix])
}

/// Pull the RHS aggregate node's `(join, filter)` presence + the first join
/// clause's `on` pairs out of the parsed `EmissionsAggregate` model.
fn rhs_join_on(file: &EsmFile) -> (bool, bool, Vec<[String; 2]>) {
    let models = file.models.as_ref().expect("models");
    let m = models
        .get("EmissionsAggregate")
        .expect("EmissionsAggregate model");
    let Expr::Operator(node) = &m.equations[0].rhs else {
        panic!("rhs is not an operator node");
    };
    let on = node
        .join
        .as_ref()
        .and_then(|j| j.first())
        .map(|c| c.on.clone())
        .unwrap_or_default();
    (node.join.is_some(), node.filter.is_some(), on)
}

#[test]
fn join_filter_fixture_round_trips_both_m2_fields() {
    // The committed M2 schema fixture carries both a `join` and a `filter`.
    let fixture = include_str!("../../../tests/valid/aggregate/join_filter.esm");
    let parsed = load(fixture).expect("parse join_filter.esm");

    // Parsed AST carries both additive M2 fields with their full structure —
    // without the ExpressionNode wiring they would be dropped as unknown fields.
    let (has_join, has_filter, on) = rhs_join_on(&parsed);
    assert!(has_join, "join not parsed");
    assert!(has_filter, "filter not parsed");
    assert_eq!(
        on,
        vec![
            ["src".to_string(), "sourceType".to_string()],
            ["fuel".to_string(), "fuelType".to_string()],
        ],
        "join.on key-column pairs not preserved"
    );

    // They survive serialize → reparse intact (string idempotence is not
    // asserted: the document's `index_sets`/`variables` are HashMap-backed and
    // serialize in arbitrary order — a pre-existing property unrelated to M2).
    let serialized = save(&parsed).expect("serialize");
    assert!(
        serialized.contains("\"join\""),
        "join field lost on serialize"
    );
    assert!(
        serialized.contains("\"filter\""),
        "filter field lost on serialize"
    );
    let reparsed = load(&serialized).expect("reparse");
    let (has_join2, has_filter2, on2) = rhs_join_on(&reparsed);
    assert!(has_join2 && has_filter2, "join/filter lost on round-trip");
    assert_eq!(on, on2, "join.on changed across round-trip");
}

#[test]
fn baseline_contraction_sum_is_six_i() {
    // y[i] = i·(1+2+3) = 6i — the no-join, no-filter reference.
    assert!((sim_y(&contraction_model(""), "y[1]").unwrap() - 6.0).abs() < 1e-9);
    assert!((sim_y(&contraction_model(""), "y[2]").unwrap() - 12.0).abs() < 1e-9);
}

#[test]
fn degenerate_positional_join_is_byte_identical_to_no_join() {
    // The join key column `j` IS the aggregate's contracted loop index ⇒ the
    // degenerate positional case ⇒ a structural no-op. The simulated values
    // must be bit-for-bit identical to the no-join model.
    let no_join = contraction_model("");
    let with_join = contraction_model(r#""join": [{ "on": [["j", "jcol"]] }],"#);
    for slot in ["y[1]", "y[2]"] {
        let a = sim_y(&no_join, slot).unwrap();
        let b = sim_y(&with_join, slot).unwrap();
        assert_eq!(
            a.to_bits(),
            b.to_bits(),
            "degenerate join changed {slot}: {a} vs {b}"
        );
    }
}

#[test]
fn filter_excludes_false_combinations() {
    // filter j>1 keeps only j∈{2,3}: y[i] = i·(2+3) = 5i (vs 6i unfiltered).
    let filtered = contraction_model(r#""filter": { "op": ">", "args": ["j", 1] },"#);
    assert!(
        (sim_y(&filtered, "y[1]").unwrap() - 5.0).abs() < 1e-9,
        "y[1] should be 5"
    );
    assert!(
        (sim_y(&filtered, "y[2]").unwrap() - 10.0).abs() < 1e-9,
        "y[2] should be 10"
    );
}

#[test]
fn filter_with_no_matches_yields_additive_identity() {
    // filter j>100 excludes every combination ⇒ empty ⊕-reduction ⇒ 0̄ = 0.
    let none = contraction_model(r#""filter": { "op": ">", "args": ["j", 100] },"#);
    assert!((sim_y(&none, "y[1]").unwrap() - 0.0).abs() < 1e-9);
    assert!((sim_y(&none, "y[2]").unwrap() - 0.0).abs() < 1e-9);
}

#[test]
fn degenerate_join_and_filter_compose() {
    // A degenerate join plus a filter: the join is a no-op, the filter applies.
    let both = contraction_model(
        r#""join": [{ "on": [["j", "jcol"]] }], "filter": { "op": ">", "args": ["j", 1] },"#,
    );
    assert!((sim_y(&both, "y[1]").unwrap() - 5.0).abs() < 1e-9);
    assert!((sim_y(&both, "y[2]").unwrap() - 10.0).abs() < 1e-9);
}

#[test]
fn non_degenerate_join_is_rejected_at_build() {
    // Key column `notaloop` is not a loop index ⇒ the value-equality engine
    // over data-derived columns is required (M3) ⇒ a clear build error, never
    // a silently wrong sum.
    let bad = contraction_model(r#""join": [{ "on": [["notaloop", "x"]] }],"#);
    let err = sim_y(&bad, "y[1]").unwrap_err();
    assert!(
        err.contains("value-equality join") || err.contains("notaloop"),
        "expected an unsupported-join error, got: {err}"
    );
}
