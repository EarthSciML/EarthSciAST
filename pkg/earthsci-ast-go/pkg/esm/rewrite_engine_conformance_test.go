package esm

// Conformance tests for the 0.8.0 outermost-first + priority + bounded-fixpoint
// rewrite engine and the `unlowered_operator` evaluation gate. Mirrors the Julia
// reference testset "expression_templates rewrite engine — 0.8.0 outermost-first
// + fixpoint" (pkg/EarthSciAST.jl/test/expression_templates_test.jl)
// and drives the shared conformance fixtures under
// tests/conformance/expression_templates/. See
// docs/content/rfcs/open-op-namespace-fixpoint-rewrite.md §8.

import (
	"strings"
	"testing"
)

func confFixtureBytes(t *testing.T, name, file string) []byte {
	t.Helper()
	b, err := readFileFromTestDir("../../../../tests/conformance/expression_templates/" + name + "/" + file)
	if err != nil {
		t.Fatalf("read %s/%s: %v", name, file, err)
	}
	return b
}

// lowerConfFixture decodes a fixture and runs the rewrite engine (map path,
// sorted-name declaration-order fallback — for these fixtures the outcome is
// identical to genuine declaration order because equal-priority patterns are
// mutually exclusive).
func lowerConfFixture(t *testing.T, name string) map[string]interface{} {
	t.Helper()
	v := decodeFixture(t, string(confFixtureBytes(t, name, "fixture.esm")))
	if err := LowerExpressionTemplates(v); err != nil {
		t.Fatalf("%s: lowering failed: %v", name, err)
	}
	return v
}

func modelMVariables(t *testing.T, v map[string]interface{}) map[string]interface{} {
	t.Helper()
	models, ok := v["models"].(map[string]interface{})
	if !ok {
		t.Fatalf("models block missing")
	}
	m, ok := models["m"].(map[string]interface{})
	if !ok {
		t.Fatalf("models.m missing")
	}
	vars, ok := m["variables"].(map[string]interface{})
	if !ok {
		t.Fatalf("models.m.variables missing")
	}
	return vars
}

// TestRewriteEngine_GodunovBeatsInnerDerivative is the anti-regression for the
// old innermost-first / bottom-up single pass: the priority:100 compound rule
// must fire on the WHOLE sqrt(D(u,x)^2 + D(u,y)^2) before the priority:0
// central-difference D rule can lower either inner D. The expanded form is
// `godunov_coef * u` — crucially with NO `inv_dx` (which only the per-derivative
// rule emits).
func TestRewriteEngine_GodunovBeatsInnerDerivative(t *testing.T) {
	got := lowerConfFixture(t, "godunov_beats_inner_deriv")
	want := decodeFixture(t, string(confFixtureBytes(t, "godunov_beats_inner_deriv", "expanded.esm")))

	gotVars := mustJSON(t, modelMVariables(t, got))
	wantVars := mustJSON(t, modelMVariables(t, want))
	if gotVars != wantVars {
		t.Errorf("variables diverge from expanded.esm:\n got=%s\nwant=%s", gotVars, wantVars)
	}

	// Guard the rewritten EXPRESSION subtree (the variables dict still declares an
	// `inv_dx` parameter): the compound rule's product appears; the per-derivative
	// rule's `inv_dx` product does not.
	gradMag := modelMVariables(t, got)["grad_mag"].(map[string]interface{})
	exprJSON := mustJSON(t, gradMag["expression"])
	if strings.Contains(exprJSON, "inv_dx") {
		t.Errorf("expanded grad_mag still contains inv_dx (per-derivative rule fired): %s", exprJSON)
	}
	if !strings.Contains(exprJSON, "godunov_coef") {
		t.Errorf("expanded grad_mag missing godunov_coef (compound rule did not fire): %s", exprJSON)
	}
}

// TestRewriteEngine_NestedDerivativeFixpoint exercises the bounded fixpoint:
// laplacian -> D(D(u,x),x)+D(D(u,y),y) (pass 1), then each nested D -> stencil
// (pass 2). A produced body is re-scanned only in a SUBSEQUENT pass.
func TestRewriteEngine_NestedDerivativeFixpoint(t *testing.T) {
	got := lowerConfFixture(t, "fixpoint_nested_deriv")
	want := decodeFixture(t, string(confFixtureBytes(t, "fixpoint_nested_deriv", "expanded.esm")))

	gotVars := mustJSON(t, modelMVariables(t, got))
	wantVars := mustJSON(t, modelMVariables(t, want))
	if gotVars != wantVars {
		t.Errorf("variables diverge from expanded.esm:\n got=%s\nwant=%s", gotVars, wantVars)
	}

	lap := modelMVariables(t, got)["lap"].(map[string]interface{})
	exprJSON := mustJSON(t, lap["expression"])
	if strings.Contains(exprJSON, "laplacian") {
		t.Errorf("expanded lap still contains laplacian: %s", exprJSON)
	}
	if strings.Contains(exprJSON, `"op":"D"`) {
		t.Errorf("expanded lap still contains a nested D op: %s", exprJSON)
	}
}

// TestRewriteEngine_NonterminatingRewriteRejected asserts a self-reintroducing
// rule is rejected by the pass bound with `rewrite_rule_nonterminating`
// (esm-spec §9.6.3) — via both the direct map path and the LoadString load path.
func TestRewriteEngine_NonterminatingRewriteRejected(t *testing.T) {
	v := decodeFixture(t, string(confFixtureBytes(t, "nonterminating_rewrite", "fixture.esm")))
	err := LowerExpressionTemplates(v)
	etErr, ok := err.(*ExpressionTemplateError)
	if !ok {
		t.Fatalf("expected *ExpressionTemplateError, got %T (%v)", err, err)
	}
	if etErr.Code != "rewrite_rule_nonterminating" {
		t.Errorf("code = %s; want rewrite_rule_nonterminating", etErr.Code)
	}

	// The load path wires the same bounded fixpoint.
	_, loadErr := LoadString(string(confFixtureBytes(t, "nonterminating_rewrite", "fixture.esm")))
	loadET, ok := loadErr.(*ExpressionTemplateError)
	if !ok {
		t.Fatalf("LoadString: expected *ExpressionTemplateError, got %T (%v)", loadErr, loadErr)
	}
	if loadET.Code != "rewrite_rule_nonterminating" {
		t.Errorf("LoadString code = %s; want rewrite_rule_nonterminating", loadET.Code)
	}
}

// TestUnloweredOperator_LoadsButRejectedAtEvaluation: a spatial D with no
// lowering rule loads cleanly (the op namespace is open, esm-spec §4.2) but is
// rejected with `unlowered_operator` when it reaches evaluation. The gate fires
// before evaluation, not at load.
func TestUnloweredOperator_LoadsButRejectedAtEvaluation(t *testing.T) {
	src := string(confFixtureBytes(t, "unlowered_operator", "fixture.esm"))

	// (1) Loads cleanly under the open namespace.
	f, err := LoadString(src)
	if err != nil {
		t.Fatalf("unlowered_operator fixture must load under the open namespace, got: %v", err)
	}
	m, ok := f.Models["m"]
	if !ok {
		t.Fatalf("model m missing")
	}
	if len(m.Equations) == 0 {
		t.Fatalf("no equations parsed")
	}

	// (2) The RHS spatial D(u, wrt=x) is rejected at evaluation.
	rhs := m.Equations[0].RHS
	_, evalErr := Evaluate(rhs, map[string]float64{"u": 0.0})
	evErr, ok := evalErr.(*EvaluationError)
	if !ok {
		t.Fatalf("expected *EvaluationError at evaluation, got %T (%v)", evalErr, evalErr)
	}
	if evErr.Code != "unlowered_operator" {
		t.Errorf("evaluation code = %s; want unlowered_operator", evErr.Code)
	}
}

// TestRewriteEngine_LoadsCleanlyUnderOpenNamespace: godunov + fixpoint fixtures
// (which fully lower) load end-to-end via LoadString, and re-marshal with no
// residual rewrite-target ops.
func TestRewriteEngine_LoadsCleanlyUnderOpenNamespace(t *testing.T) {
	for _, name := range []string{"godunov_beats_inner_deriv", "fixpoint_nested_deriv"} {
		t.Run(name, func(t *testing.T) {
			if _, err := LoadString(string(confFixtureBytes(t, name, "fixture.esm"))); err != nil {
				t.Fatalf("%s: LoadString failed: %v", name, err)
			}
		})
	}
}

// TestRewriteEngine_AttrsBindAsScalarMetavariables: a custom op carries scheme
// params in `attrs`; a `match` pattern's `attrs.<key>` set to a bare param binds
// it to the matched literal. This falls out of generic structural matching — no
// special-casing in the engine (esm-spec §4.2 open tier / §9.6.1).
func TestRewriteEngine_AttrsBindAsScalarMetavariables(t *testing.T) {
	const src = `{
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
    }`
	v := decodeFixture(t, src)
	if err := LowerExpressionTemplates(v); err != nil {
		t.Fatalf("lowering failed: %v", err)
	}
	y := modelMVariables(t, v)["y"].(map[string]interface{})
	got := mustJSON(t, y["expression"])
	// Go marshals map keys in sorted order: "args" before "op"; the bound
	// gamma literal (1.4) substitutes into the first arg.
	const want = `{"args":[1.4,"u"],"op":"*"}`
	if got != want {
		t.Errorf("attrs-bound expansion = %s; want %s", got, want)
	}
}
