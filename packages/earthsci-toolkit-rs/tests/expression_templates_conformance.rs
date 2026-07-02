//! Conformance tests for the 0.8.0 "open op namespace + fixpoint rewrite"
//! contract (docs/content/rfcs/open-op-namespace-fixpoint-rewrite.md §8).
//!
//! These mirror the Julia reference driver tests
//! (`EarthSciSerialization.jl/test/expression_templates_test.jl` — the
//! "0.8.0 outermost-first + fixpoint" @testset — and `tree_walk_test.jl`) and
//! run the SAME shared fixtures under
//! `tests/conformance/expression_templates/`, so all bindings agree on the
//! byte-identical fixpoint (or the same rejection).

use earthsci_toolkit::lower_expression_templates::{
    ExpressionTemplateError, lower_expression_templates,
};
use serde_json::{Value, json};
use std::path::PathBuf;

/// Repo-root-relative path into the shared conformance fixture directory.
fn conf(fixture: &str) -> PathBuf {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let repo_root = manifest_dir
        .parent()
        .and_then(|p| p.parent())
        .expect("repo root from CARGO_MANIFEST_DIR")
        .to_path_buf();
    repo_root
        .join("tests/conformance/expression_templates")
        .join(fixture)
}

/// Parse `fixture.esm` and run the load-time rewrite engine to a fixpoint.
fn lower_fixture(fixture: &str) -> Result<Value, ExpressionTemplateError> {
    let src = std::fs::read_to_string(conf(fixture).join("fixture.esm")).expect("read fixture.esm");
    let mut value: Value = serde_json::from_str(&src).expect("parse fixture.esm");
    lower_expression_templates(&mut value)?;
    Ok(value)
}

/// The `models.m.variables` sub-tree of the golden `expanded.esm`.
fn expanded_vars(fixture: &str) -> Value {
    let src =
        std::fs::read_to_string(conf(fixture).join("expanded.esm")).expect("read expanded.esm");
    let value: Value = serde_json::from_str(&src).expect("parse expanded.esm");
    value["models"]["m"]["variables"].clone()
}

/// godunov_beats_inner_deriv: the priority:100 compound rule must fire on the
/// WHOLE `sqrt(D(u,x)^2 + D(u,y)^2)` before the priority:0 per-derivative `D`
/// rule can lower either inner `D`. The expanded form is `godunov_coef * u` —
/// crucially with NO `inv_dx` (which only the per-derivative rule emits).
/// Anti-regression for the old bottom-up/innermost-first single pass.
#[test]
fn godunov_compound_rule_beats_inner_derivative() {
    let out = lower_fixture("godunov_beats_inner_deriv").expect("lowering must converge");
    let got = &out["models"]["m"]["variables"];
    assert_eq!(*got, expanded_vars("godunov_beats_inner_deriv"));

    // Guard the rewritten EXPRESSION subtree only (the variables dict still
    // declares an `inv_dx` parameter): the compound rule's product appears; the
    // per-derivative rule's `inv_dx` product does not.
    let expr_json = got["grad_mag"]["expression"].to_string();
    assert!(
        !expr_json.contains("inv_dx"),
        "per-derivative rule must not have fired: {expr_json}"
    );
    assert!(
        expr_json.contains("godunov_coef"),
        "compound rule must have fired: {expr_json}"
    );
}

/// fixpoint_nested_deriv: `laplacian(u)` -> `D(D(u,x),x)+D(D(u,y),y)` (pass 1),
/// then each nested `D(D(f,·),·)` -> stencil (pass 2). Exercises the bounded
/// fixpoint: a produced body is re-scanned only in a SUBSEQUENT pass. Converges
/// to an identical tree in every binding.
#[test]
fn nested_derivative_fixpoint_converges_across_passes() {
    let out = lower_fixture("fixpoint_nested_deriv").expect("lowering must converge");
    let got = &out["models"]["m"]["variables"];
    assert_eq!(*got, expanded_vars("fixpoint_nested_deriv"));

    let expr_json = got["lap"]["expression"].to_string();
    assert!(
        !expr_json.contains("laplacian"),
        "laplacian sugar must be gone: {expr_json}"
    );
    assert!(
        !expr_json.contains("\"D\""),
        "nested D must be lowered: {expr_json}"
    );
}

/// nonterminating_rewrite: a self-reintroducing rule never reaches a fixpoint;
/// the pass bound (`MAX_REWRITE_PASSES = 64`) — not a static pre-check — rejects
/// the file with `rewrite_rule_nonterminating`.
#[test]
fn self_reintroducing_rule_rejected_by_pass_bound() {
    let err = lower_fixture("nonterminating_rewrite").expect_err("must not converge");
    assert_eq!(err.code, "rewrite_rule_nonterminating", "got: {err}");
}

/// unlowered_operator: a spatial `D(u, wrt=x)` in a right-hand side with no
/// lowering rule LOADS cleanly (the op namespace is open, esm-spec §4.2) but is
/// rejected with the uniform `unlowered_operator` code when the model reaches
/// evaluation/compilation. The gate fires before evaluation, not at load.
#[test]
fn unlowered_spatial_d_loads_but_is_gated_before_evaluation() {
    let fixture_path = conf("unlowered_operator").join("fixture.esm");

    // (1) Loads clean — parse + schema + structural validation + lowering all
    //     tolerate the unlowered spatial `D`.
    let file =
        earthsci_toolkit::load_path(&fixture_path).expect("fixture must load under open namespace");

    // (2) Reaching compilation, the spatial `D` is rejected with the uniform
    //     `unlowered_operator` code.
    let err = earthsci_toolkit::Compiled::from_file(&file)
        .expect_err("spatial D must be rejected before evaluation");
    assert!(
        err.to_string().contains("unlowered_operator"),
        "expected uniform `unlowered_operator` code, got: {err}"
    );
}

/// attrs on a rewrite-target op bind as scalar metavariables (esm-spec §4.2 open
/// tier / RFC Change A): a `match` pattern's `attrs.<key>` set to a bare param
/// binds it to the matched literal. This falls out of generic structural
/// matching — no special-casing in the engine.
#[test]
fn attrs_on_rewrite_target_op_bind_as_scalar_metavariables() {
    let src = r#"
    {
      "esm": "0.8.0",
      "metadata": {"name": "attrs_match", "authors": ["t"]},
      "models": {"m": {
        "variables": {
          "u": {"type": "state", "units": "1", "default": 0.0},
          "y": {"type": "observed", "units": "1",
            "expression": {"op": "custom_scheme", "args": ["u"], "attrs": {"gamma": 1.4}}}
        },
        "equations": [],
        "expression_templates": {
          "lower_custom": {
            "params": ["f", "g"],
            "match": {"op": "custom_scheme", "args": ["f"], "attrs": {"gamma": "g"}},
            "body": {"op": "*", "args": ["g", "f"]}
          }
        }
      }}
    }
    "#;
    let mut v: Value = serde_json::from_str(src).expect("parse attrs source");
    lower_expression_templates(&mut v).expect("lowering must converge");
    let expr = &v["models"]["m"]["variables"]["y"]["expression"];
    assert_eq!(*expr, json!({"op": "*", "args": [1.4, "u"]}));
}

/// Drives tests/conformance/expression_templates/scalar_field_param — the
/// scalar-field substitution site rule (esm-spec §9.6.1) instantiated twice
/// (planar / spherical) — against its pinned Julia-generated expanded.esm.
#[test]
fn scalar_field_param_conformance_fixture_matches_expanded() {
    let out = lower_fixture("scalar_field_param").expect("lowering must converge");
    let src = std::fs::read_to_string(conf("scalar_field_param").join("expanded.esm"))
        .expect("read expanded.esm");
    let expanded: Value = serde_json::from_str(&src).expect("parse expanded.esm");
    assert_eq!(out["models"], expanded["models"]);
    let vars = &out["models"]["Overlap"]["variables"];
    assert_eq!(vars["area_planar"]["expression"]["manifold"], "planar");
    assert_eq!(vars["area_spherical"]["expression"]["manifold"], "spherical");
}

// ---------------------------------------------------------------------------
// Static match-scoping constraints (`where`, esm-spec §9.6.1/§9.6.2/§9.6.3;
// docs/content/rfcs/match-pattern-scoping-constraints.md)
// ---------------------------------------------------------------------------

/// constrained_match_scope: one shape-constrained `div` rule
/// (`where: {F: {shape: [edges]}}`) in a document with two shaped variables.
/// The rule fires on `div(F_edge)` (shape [edges]) and is constraint-excluded
/// on `div(F_cell)` (shape [cells]) — which survives lowering intact. Both cases
/// in one byte-identical expanded golden.
#[test]
fn constrained_match_scope_matches_golden() {
    let out = lower_fixture("constrained_match_scope").expect("lowering must converge");
    assert_eq!(
        out["models"]["m"]["variables"],
        expanded_vars("constrained_match_scope")
    );
}

/// per_variable_scheme_literal_args: `where` constraints select which scheme
/// rewrites which variable when several rules share a pattern head.
#[test]
fn per_variable_scheme_literal_args_matches_golden() {
    let out = lower_fixture("per_variable_scheme_literal_args").expect("lowering must converge");
    assert_eq!(
        out["models"]["m"]["variables"],
        expanded_vars("per_variable_scheme_literal_args")
    );
}

/// two_div_two_meshes: two shape-constrained rules over two meshes, each firing
/// only on its own mesh's field.
#[test]
fn two_div_two_meshes_matches_golden() {
    let out = lower_fixture("two_div_two_meshes").expect("lowering must converge");
    assert_eq!(
        out["models"]["m"]["variables"],
        expanded_vars("two_div_two_meshes")
    );
}

/// constraint_unknown_index_set: a `where.F.shape` naming an index set the
/// consuming document does not declare is rejected at rule registration with
/// the stable `template_constraint_unknown_index_set` code (esm-spec §9.6.6).
#[test]
fn constraint_unknown_index_set_rejected() {
    let err = lower_fixture("constraint_unknown_index_set").expect_err("must reject at registration");
    assert_eq!(err.code, "template_constraint_unknown_index_set", "got: {err}");
}
