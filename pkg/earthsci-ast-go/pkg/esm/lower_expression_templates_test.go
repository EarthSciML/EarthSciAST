package esm

// Unit tests for expression_templates / apply_expression_template
// (esm-spec §9.6, docs/rfcs/ast-expression-templates.md, esm-giy).

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func readFileFromTestDir(relPath string) ([]byte, error) {
	return os.ReadFile(relPath)
}

const arrheniusFixture = `{
  "esm": "0.4.0",
  "metadata": {"name": "expr_template_smoke", "authors": ["esm-giy"]},
  "reaction_systems": {
    "chem": {
      "species": {"A": {"default": 1.0}, "B": {"default": 0.5}},
      "parameters": {"T": {"default": 298.15}, "num_density": {"default": 2.5e19}},
      "expression_templates": {
        "arrhenius": {
          "params": ["A_pre", "Ea"],
          "body": {
            "op": "*",
            "args": [
              "A_pre",
              {"op": "exp", "args": [
                {"op": "/", "args": [{"op": "-", "args": ["Ea"]}, "T"]}
              ]},
              "num_density"
            ]
          }
        }
      },
      "reactions": [
        {"id": "R1",
         "substrates": [{"species": "A", "stoichiometry": 1}],
         "products": [{"species": "B", "stoichiometry": 1}],
         "rate": {"op": "apply_expression_template", "args": [],
                  "name": "arrhenius",
                  "bindings": {"A_pre": 1.8e-12, "Ea": 1500}}}
      ]
    }
  }
}`

func decodeFixture(t *testing.T, s string) map[string]interface{} {
	t.Helper()
	var v map[string]interface{}
	dec := json.NewDecoder(strings.NewReader(s))
	dec.UseNumber()
	if err := dec.Decode(&v); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	return v
}

func TestLowerExpressionTemplates_StripsBlock(t *testing.T) {
	v := decodeFixture(t, arrheniusFixture)
	if err := LowerExpressionTemplates(v); err != nil {
		t.Fatalf("expansion failed: %v", err)
	}
	chem := v["reaction_systems"].(map[string]interface{})["chem"].(map[string]interface{})
	if _, ok := chem["expression_templates"]; ok {
		t.Errorf("expression_templates block was not stripped")
	}
	rate := chem["reactions"].([]interface{})[0].(map[string]interface{})["rate"].(map[string]interface{})
	if rate["op"] != "*" {
		t.Errorf("expanded rate op = %v; want '*'", rate["op"])
	}
}

func TestLowerExpressionTemplates_RejectsUnknownTemplate(t *testing.T) {
	v := decodeFixture(t, arrheniusFixture)
	rate := v["reaction_systems"].(map[string]interface{})["chem"].(map[string]interface{})["reactions"].([]interface{})[0].(map[string]interface{})["rate"].(map[string]interface{})
	rate["name"] = "missing"
	err := LowerExpressionTemplates(v)
	etErr, ok := err.(*ExpressionTemplateError)
	if !ok {
		t.Fatalf("expected ExpressionTemplateError, got %T (%v)", err, err)
	}
	if etErr.Code != "apply_expression_template_unknown_template" {
		t.Errorf("code = %s; want apply_expression_template_unknown_template", etErr.Code)
	}
}

func TestLowerExpressionTemplates_RejectsMissingBinding(t *testing.T) {
	v := decodeFixture(t, arrheniusFixture)
	bindings := v["reaction_systems"].(map[string]interface{})["chem"].(map[string]interface{})["reactions"].([]interface{})[0].(map[string]interface{})["rate"].(map[string]interface{})["bindings"].(map[string]interface{})
	delete(bindings, "Ea")
	err := LowerExpressionTemplates(v)
	etErr, ok := err.(*ExpressionTemplateError)
	if !ok {
		t.Fatalf("expected ExpressionTemplateError, got %T", err)
	}
	if etErr.Code != "apply_expression_template_bindings_mismatch" {
		t.Errorf("code = %s; want apply_expression_template_bindings_mismatch", etErr.Code)
	}
}

func TestLowerExpressionTemplates_RejectsExtraBinding(t *testing.T) {
	v := decodeFixture(t, arrheniusFixture)
	bindings := v["reaction_systems"].(map[string]interface{})["chem"].(map[string]interface{})["reactions"].([]interface{})[0].(map[string]interface{})["rate"].(map[string]interface{})["bindings"].(map[string]interface{})
	bindings["bogus"] = json.Number("99")
	err := LowerExpressionTemplates(v)
	etErr, ok := err.(*ExpressionTemplateError)
	if !ok {
		t.Fatalf("expected ExpressionTemplateError, got %T", err)
	}
	if etErr.Code != "apply_expression_template_bindings_mismatch" {
		t.Errorf("code = %s; want apply_expression_template_bindings_mismatch", etErr.Code)
	}
}

func TestLowerExpressionTemplates_RejectsRecursiveBody(t *testing.T) {
	v := decodeFixture(t, arrheniusFixture)
	tplArrh := v["reaction_systems"].(map[string]interface{})["chem"].(map[string]interface{})["expression_templates"].(map[string]interface{})["arrhenius"].(map[string]interface{})
	tplArrh["body"] = map[string]interface{}{
		"op":       "apply_expression_template",
		"args":     []interface{}{},
		"name":     "arrhenius",
		"bindings": map[string]interface{}{"A_pre": json.Number("1"), "Ea": json.Number("1")},
	}
	err := LowerExpressionTemplates(v)
	etErr, ok := err.(*ExpressionTemplateError)
	if !ok {
		t.Fatalf("expected ExpressionTemplateError, got %T", err)
	}
	if etErr.Code != "apply_expression_template_recursive_body" {
		t.Errorf("code = %s; want apply_expression_template_recursive_body", etErr.Code)
	}
}

func TestLowerExpressionTemplates_RejectsPreV04(t *testing.T) {
	v := decodeFixture(t, arrheniusFixture)
	v["esm"] = "0.3.5"
	err := LowerExpressionTemplates(v)
	etErr, ok := err.(*ExpressionTemplateError)
	if !ok {
		t.Fatalf("expected ExpressionTemplateError, got %T", err)
	}
	if etErr.Code != "apply_expression_template_version_too_old" {
		t.Errorf("code = %s; want apply_expression_template_version_too_old", etErr.Code)
	}
}

func TestLowerExpressionTemplates_NoTemplatesIsNoOp(t *testing.T) {
	noTemplates := `{
      "esm": "0.4.0",
      "metadata": {"name": "no_templates", "authors": ["t"]},
      "reaction_systems": {
        "chem": {
          "species": {"A": {}},
          "parameters": {"k": {"default": 1.0}},
          "reactions": [{
            "id": "R1",
            "substrates": [{"species": "A", "stoichiometry": 1}],
            "products": null,
            "rate": "k"
          }]
        }
      }
    }`
	v := decodeFixture(t, noTemplates)
	if err := LowerExpressionTemplates(v); err != nil {
		t.Fatalf("expansion failed: %v", err)
	}
	rate := v["reaction_systems"].(map[string]interface{})["chem"].(map[string]interface{})["reactions"].([]interface{})[0].(map[string]interface{})["rate"]
	if rate != "k" {
		t.Errorf("rate = %v; want 'k'", rate)
	}
}

func TestLowerExpressionTemplates_ASTValuedBindings(t *testing.T) {
	v := decodeFixture(t, arrheniusFixture)
	bindings := v["reaction_systems"].(map[string]interface{})["chem"].(map[string]interface{})["reactions"].([]interface{})[0].(map[string]interface{})["rate"].(map[string]interface{})["bindings"].(map[string]interface{})
	bindings["Ea"] = map[string]interface{}{
		"op":   "*",
		"args": []interface{}{json.Number("3"), "T"},
	}
	if err := LowerExpressionTemplates(v); err != nil {
		t.Fatalf("expansion failed: %v", err)
	}
	rate := v["reaction_systems"].(map[string]interface{})["chem"].(map[string]interface{})["reactions"].([]interface{})[0].(map[string]interface{})["rate"].(map[string]interface{})
	expNode := rate["args"].([]interface{})[1].(map[string]interface{})
	if expNode["op"] != "exp" {
		t.Errorf("expected exp node, got op=%v", expNode["op"])
	}
}

func TestExpressionTemplates_ConformanceFixture(t *testing.T) {
	// Drives the cross-binding tests/conformance/expression_templates/
	// arrhenius_smoke fixture against its pinned expanded.esm form.
	const fixtureRel = "../../../../tests/conformance/expression_templates/arrhenius_smoke/fixture.esm"
	const expandedRel = "../../../../tests/conformance/expression_templates/arrhenius_smoke/expanded.esm"
	srcBytes, err := readFileBytes(t, fixtureRel)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	expandedBytes, err := readFileBytes(t, expandedRel)
	if err != nil {
		t.Fatalf("read expanded: %v", err)
	}
	v := decodeFixture(t, string(srcBytes))
	if err := LowerExpressionTemplates(v); err != nil {
		t.Fatalf("expansion failed: %v", err)
	}
	expanded := decodeFixture(t, string(expandedBytes))
	gotReactions := mustJSON(t, v["reaction_systems"].(map[string]interface{})["chem"].(map[string]interface{})["reactions"])
	wantReactions := mustJSON(t, expanded["reaction_systems"].(map[string]interface{})["chem"].(map[string]interface{})["reactions"])
	if gotReactions != wantReactions {
		t.Errorf("reactions diverge from expanded.esm:\n got=%s\nwant=%s", gotReactions, wantReactions)
	}
}

func TestExpressionTemplates_CouplingTransformConformanceFixture(t *testing.T) {
	// The v0.8.0 variable_map expression-transform widening (esm-spec
	// §10.4/§10.5): a coupling `transform` invoking a template declared by the
	// RECEIVING component expands at load against that component's registry
	// (§9.6.4). Cross-binding golden: expanded.esm.
	const fixtureRel = "../../../../tests/conformance/expression_templates/coupling_transform_expression/fixture.esm"
	const expandedRel = "../../../../tests/conformance/expression_templates/coupling_transform_expression/expanded.esm"
	srcBytes, err := readFileBytes(t, fixtureRel)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	expandedBytes, err := readFileBytes(t, expandedRel)
	if err != nil {
		t.Fatalf("read expanded: %v", err)
	}
	v := decodeFixture(t, string(srcBytes))
	if err := LowerExpressionTemplates(v); err != nil {
		t.Fatalf("expansion failed: %v", err)
	}
	expanded := decodeFixture(t, string(expandedBytes))
	gotCoupling := mustJSON(t, v["coupling"])
	wantCoupling := mustJSON(t, expanded["coupling"])
	if gotCoupling != wantCoupling {
		t.Errorf("coupling diverges from expanded.esm:\n got=%s\nwant=%s", gotCoupling, wantCoupling)
	}
	gotModels := mustJSON(t, v["models"])
	wantModels := mustJSON(t, expanded["models"])
	if gotModels != wantModels {
		t.Errorf("models diverge from expanded.esm:\n got=%s\nwant=%s", gotModels, wantModels)
	}
}

func readFileBytes(t *testing.T, relPath string) ([]byte, error) {
	t.Helper()
	return readFileFromTestDir(relPath)
}

func mustJSON(t *testing.T, v interface{}) string {
	t.Helper()
	out, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return string(out)
}

func TestLoadString_ExpandsTemplatesEndToEnd(t *testing.T) {
	esmFile, err := LoadString(arrheniusFixture)
	if err != nil {
		t.Fatalf("LoadString failed: %v", err)
	}
	rs, ok := esmFile.ReactionSystems["chem"]
	if !ok {
		t.Fatalf("reaction_systems['chem'] missing")
	}
	if len(rs.Reactions) == 0 {
		t.Fatalf("no reactions parsed")
	}
	// Re-marshal the parsed file back to JSON and assert no
	// apply_expression_template appears anywhere.
	out, err := json.Marshal(esmFile)
	if err != nil {
		t.Fatalf("re-marshal: %v", err)
	}
	if strings.Contains(string(out), "apply_expression_template") {
		t.Errorf("expanded EsmFile still contains apply_expression_template:\n%s", out)
	}
	if strings.Contains(string(out), "expression_templates") {
		t.Errorf("expanded EsmFile still contains expression_templates block:\n%s", out)
	}
}

// ---------------------------------------------------------------------------
// Scalar-field template-parameter substitution
// (esm-spec §9.6.1 / §9.6.3 constraint 5; mirrors the Julia/Python/TS testsets 1:1)
// ---------------------------------------------------------------------------

func scalarFieldParamDoc(templates, bindings, name string) string {
	return `{
      "esm": "0.8.0",
      "metadata": {"name": "scalar_field_param_unit", "authors": ["t"]},
      "models": {"M": {
        "variables": {
          "pa": {"type": "parameter"},
          "pb": {"type": "parameter"},
          "area": {"type": "observed",
            "expression": {"op": "apply_expression_template", "args": [],
              "name": "` + name + `",
              "bindings": ` + bindings + `}}
        },
        "equations": [],
        "expression_templates": ` + templates + `
      }}
    }`
}

func scalarFieldAreaExpr(t *testing.T, v map[string]interface{}) map[string]interface{} {
	t.Helper()
	return v["models"].(map[string]interface{})["M"].(map[string]interface{})["variables"].(map[string]interface{})["area"].(map[string]interface{})["expression"].(map[string]interface{})
}

// A parameter name appearing as the string value of a scalar Expression-node
// field in `body` is a substitution site (the mirror of the match-side
// scalar-field binding rule, esm-spec §9.6.1).
func TestScalarFieldSubstitution_HappyPath(t *testing.T) {
	doc := scalarFieldParamDoc(
		`{"overlap_area": {
           "params": ["K_manifold", "a", "b"],
           "body": {"op": "polygon_intersection_area",
                    "manifold": "K_manifold", "args": ["a", "b"]}}}`,
		`{"K_manifold": "planar", "a": "pa", "b": "pb"}`,
		"overlap_area",
	)
	v := decodeFixture(t, doc)
	if err := LowerExpressionTemplates(v); err != nil {
		t.Fatalf("expansion failed: %v", err)
	}
	expr := scalarFieldAreaExpr(t, v)
	if expr["op"] != "polygon_intersection_area" || expr["manifold"] != "planar" {
		t.Errorf("expanded expr = %v; want polygon_intersection_area with manifold 'planar'", expr)
	}
	args := expr["args"].([]interface{})
	if len(args) != 2 || args[0] != "pa" || args[1] != "pb" {
		t.Errorf("expanded args = %v; want [pa pb]", args)
	}
}

// A scalar-field param passed through a §9.7.3 registration-time body
// composition (outer body applies inner, forwarding its own param into the
// inner manifold slot) substitutes end-to-end.
func TestScalarFieldSubstitution_ThreadsThroughBodyComposition(t *testing.T) {
	doc := scalarFieldParamDoc(
		`{"inner": {
           "params": ["m", "x", "y"],
           "body": {"op": "polygon_intersection_area", "manifold": "m",
                    "args": ["x", "y"]}},
          "outer": {
           "params": ["K", "p", "q"],
           "body": {"op": "*", "args": [
             {"op": "apply_expression_template", "args": [], "name": "inner",
              "bindings": {"m": "K", "x": "p", "y": "q"}},
             2.0]}}}`,
		`{"K": "spherical", "p": "pa", "q": "pb"}`,
		"outer",
	)
	v := decodeFixture(t, doc)
	if err := LowerExpressionTemplates(v); err != nil {
		t.Fatalf("expansion failed: %v", err)
	}
	expr := scalarFieldAreaExpr(t, v)
	if expr["op"] != "*" {
		t.Fatalf("expanded expr op = %v; want *", expr["op"])
	}
	area := expr["args"].([]interface{})[0].(map[string]interface{})
	if area["op"] != "polygon_intersection_area" || area["manifold"] != "spherical" {
		t.Errorf("inner expr = %v; want polygon_intersection_area with manifold 'spherical'", area)
	}
}

// Validators run on the expanded form (esm-spec §9.6.4): a template invocation
// binding the manifold parameter to a non-member literal is rejected with
// `geometry_manifold_invalid`.
func TestScalarFieldSubstitution_InvalidManifoldRejected(t *testing.T) {
	doc := scalarFieldParamDoc(
		`{"overlap_area": {
           "params": ["K_manifold", "a", "b"],
           "body": {"op": "polygon_intersection_area",
                    "manifold": "K_manifold", "args": ["a", "b"]}}}`,
		`{"K_manifold": "bogus", "a": "pa", "b": "pb"}`,
		"overlap_area",
	)
	v := decodeFixture(t, doc)
	err := LowerExpressionTemplates(v)
	if err == nil {
		t.Fatalf("expected geometry_manifold_invalid, got nil error")
	}
	if !strings.Contains(err.Error(), "geometry_manifold_invalid") {
		t.Errorf("error = %v; want code geometry_manifold_invalid", err)
	}
}

// Pinned shadowing resolution (esm-spec §9.6.1): a declared param name shadows
// a coincident field literal inside `body` — the param wins. Authors must not
// name params after field literals; the engine substitutes anyway.
func TestScalarFieldSubstitution_ParamsShadowLiterals(t *testing.T) {
	doc := scalarFieldParamDoc(
		`{"shadowed": {
           "params": ["planar", "x", "y"],
           "body": {"op": "polygon_intersection_area",
                    "manifold": "planar", "args": ["x", "y"]}}}`,
		`{"planar": "spherical", "x": "pa", "y": "pb"}`,
		"shadowed",
	)
	v := decodeFixture(t, doc)
	if err := LowerExpressionTemplates(v); err != nil {
		t.Fatalf("expansion failed: %v", err)
	}
	expr := scalarFieldAreaExpr(t, v)
	if expr["manifold"] != "spherical" {
		t.Errorf("manifold = %v; want 'spherical' (params shadow literals)", expr["manifold"])
	}
}

// Drives tests/conformance/expression_templates/scalar_field_param — the
// scalar-field substitution site rule (esm-spec §9.6.1) instantiated twice
// (planar / spherical) — against its pinned Julia-generated expanded.esm.
func TestExpressionTemplates_ScalarFieldParamConformanceFixture(t *testing.T) {
	const fixtureRel = "../../../../tests/conformance/expression_templates/scalar_field_param/fixture.esm"
	const expandedRel = "../../../../tests/conformance/expression_templates/scalar_field_param/expanded.esm"
	srcBytes, err := readFileBytes(t, fixtureRel)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	expandedBytes, err := readFileBytes(t, expandedRel)
	if err != nil {
		t.Fatalf("read expanded: %v", err)
	}
	v := decodeFixture(t, string(srcBytes))
	if err := LowerExpressionTemplates(v); err != nil {
		t.Fatalf("expansion failed: %v", err)
	}
	expanded := decodeFixture(t, string(expandedBytes))
	got := mustJSON(t, v["models"])
	want := mustJSON(t, expanded["models"])
	if got != want {
		t.Errorf("models diverge from expanded.esm:\n got=%s\nwant=%s", got, want)
	}
	vars := v["models"].(map[string]interface{})["Overlap"].(map[string]interface{})["variables"].(map[string]interface{})
	planar := vars["area_planar"].(map[string]interface{})["expression"].(map[string]interface{})
	spherical := vars["area_spherical"].(map[string]interface{})["expression"].(map[string]interface{})
	if planar["manifold"] != "planar" || spherical["manifold"] != "spherical" {
		t.Errorf("manifolds = %v / %v; want planar / spherical", planar["manifold"], spherical["manifold"])
	}
}
