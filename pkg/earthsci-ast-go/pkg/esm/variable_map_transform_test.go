package esm

// Tests for the `variable_map.transform` expression widening (esm-schema
// CouplingVariableMap.transform: legacy string kind | ExpressionNode object;
// esm-spec §8.6/§10.4/§10.5 — the regridding form). The Go binding is a
// parse/serialize/validate + rewrite-only port: these tests pin the union
// (un)marshaling, the factor+expression rejection, the load-time
// expression-template expansion of coupling transforms in the RECEIVING
// component's rewrite context, and flatten not crashing. No evaluation.

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

const vmExprTransformEntry = `{
  "type": "variable_map",
  "from": "Src.F",
  "to": "Sink.offset",
  "transform": {"op": "+", "args": [{"op": "*", "args": [2.0, "Src.F"]}, "Sink.offset"]}
}`

// vmCanonJSON normalizes any JSON-marshalable value to a canonical string:
// marshal → plain decode (numbers become float64) → marshal with Go's sorted
// map keys. Both sides of a comparison go through the same normalization, so
// json.Number / int64 / float64 encodings compare equal.
func vmCanonJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var plain any
	if err := json.Unmarshal(b, &plain); err != nil {
		t.Fatalf("re-decode: %v", err)
	}
	out, err := json.Marshal(plain)
	if err != nil {
		t.Fatalf("re-marshal: %v", err)
	}
	return string(out)
}

func TestVariableMapTransform_ExpressionRoundTrip(t *testing.T) {
	entry, err := UnmarshalCouplingEntry([]byte(vmExprTransformEntry))
	if err != nil {
		t.Fatalf("UnmarshalCouplingEntry: %v", err)
	}
	vm, ok := entry.(VariableMapCoupling)
	if !ok {
		t.Fatalf("entry type = %T; want VariableMapCoupling", entry)
	}
	if !vm.TransformIsExpression() {
		t.Fatalf("TransformIsExpression() = false; Transform = %#v", vm.Transform)
	}
	if vm.TransformKind() != "" {
		t.Errorf("TransformKind() = %q; want \"\" for an expression transform", vm.TransformKind())
	}
	node, ok := vm.Transform.(ExprNode)
	if !ok {
		t.Fatalf("Transform type = %T; want ExprNode", vm.Transform)
	}
	if node.Op != "+" || len(node.Args) != 2 {
		t.Fatalf("Transform = %#v; want op '+' with 2 args", node)
	}
	inner, ok := node.Args[0].(ExprNode)
	if !ok || inner.Op != "*" {
		t.Fatalf("Transform.Args[0] = %#v; want ExprNode op '*'", node.Args[0])
	}
	// The 2.0 literal must survive as a float64 (RFC §5.4.6 int/float
	// distinction), so canonical re-marshal spells it "2.0".
	if f, ok := inner.Args[0].(float64); !ok || f != 2.0 {
		t.Fatalf("inner literal = %#v (%T); want float64 2.0", inner.Args[0], inner.Args[0])
	}

	// Lossless round-trip via the package's canonical serialization: the
	// re-marshal is byte-stable, and unmarshal-again yields a deep-equal value.
	b1, err := marshalCanonical(vm, false)
	if err != nil {
		t.Fatalf("marshalCanonical: %v", err)
	}
	if !strings.Contains(string(b1), "2.0") {
		t.Errorf("canonical re-marshal lost the float spelling: %s", b1)
	}
	entry2, err := UnmarshalCouplingEntry(b1)
	if err != nil {
		t.Fatalf("UnmarshalCouplingEntry (round 2): %v", err)
	}
	if !reflect.DeepEqual(entry, entry2) {
		t.Errorf("round-trip not lossless:\n first = %#v\nsecond = %#v", entry, entry2)
	}
	b2, err := marshalCanonical(entry2, false)
	if err != nil {
		t.Fatalf("marshalCanonical (round 2): %v", err)
	}
	if string(b1) != string(b2) {
		t.Errorf("canonical re-marshal not byte-stable:\n b1 = %s\n b2 = %s", b1, b2)
	}
	// And the wire form matches the input document (canonical comparison).
	if got, want := vmCanonJSON(t, json.RawMessage(b1)), vmCanonJSON(t, json.RawMessage(vmExprTransformEntry)); got != want {
		t.Errorf("re-marshal differs from input:\n got = %s\nwant = %s", got, want)
	}
}

func TestVariableMapTransform_LegacyStringRoundTrip(t *testing.T) {
	in := `{"type":"variable_map","from":"A.x","to":"B.y","transform":"conversion_factor","factor":2.5}`
	entry, err := UnmarshalCouplingEntry([]byte(in))
	if err != nil {
		t.Fatalf("UnmarshalCouplingEntry: %v", err)
	}
	vm := entry.(VariableMapCoupling)
	if vm.TransformIsExpression() {
		t.Fatalf("legacy string transform reported as expression: %#v", vm.Transform)
	}
	if vm.TransformKind() != "conversion_factor" {
		t.Errorf("TransformKind() = %q; want 'conversion_factor'", vm.TransformKind())
	}
	if vm.Factor == nil || *vm.Factor != 2.5 {
		t.Errorf("Factor = %v; want 2.5", vm.Factor)
	}
	b, err := marshalCanonical(vm, false)
	if err != nil {
		t.Fatalf("marshalCanonical: %v", err)
	}
	if got, want := vmCanonJSON(t, json.RawMessage(b)), vmCanonJSON(t, json.RawMessage(in)); got != want {
		t.Errorf("re-marshal differs from input:\n got = %s\nwant = %s", got, want)
	}
}

func TestVariableMapTransform_FactorWithExpressionRejected(t *testing.T) {
	in := `{
	  "type": "variable_map",
	  "from": "Src.F",
	  "to": "Sink.offset",
	  "transform": {"op": "*", "args": [2.0, "Src.F"]},
	  "factor": 1.5
	}`
	_, err := UnmarshalCouplingEntry([]byte(in))
	if err == nil {
		t.Fatalf("expected factor + expression transform to be rejected")
	}
	if !strings.Contains(err.Error(), "factor") {
		t.Errorf("error should mention 'factor': %v", err)
	}
}

func TestVariableMapTransform_RejectsNonStringNonObject(t *testing.T) {
	for _, tc := range []string{
		`{"type":"variable_map","from":"A.x","to":"B.y","transform":2.0}`,
		`{"type":"variable_map","from":"A.x","to":"B.y","transform":["identity"]}`,
		`{"type":"variable_map","from":"A.x","to":"B.y","transform":true}`,
	} {
		if _, err := UnmarshalCouplingEntry([]byte(tc)); err == nil {
			t.Errorf("expected rejection of non-string/non-object transform: %s", tc)
		}
	}
}

// couplingTransformFixture: the RECEIVING component (first dot-segment of
// `to`, here models.Sink) declares the template the coupling transform
// invokes; the load-time pass must expand it with Sink's rewrite context.
const couplingTransformFixture = `{
  "esm": "0.4.0",
  "metadata": {"name": "coupling_transform_expansion", "authors": ["esm-go"]},
  "models": {
    "Src": {
      "variables": {"F": {"type": "state"}},
      "equations": []
    },
    "Sink": {
      "variables": {"offset": {"type": "parameter"}},
      "equations": [],
      "expression_templates": {
        "double_plus": {
          "params": ["x", "off"],
          "body": {"op": "+", "args": [{"op": "*", "args": [2.0, "x"]}, "off"]}
        }
      }
    }
  },
  "coupling": [
    {"type": "variable_map", "from": "Src.F", "to": "Sink.offset",
     "transform": {"op": "apply_expression_template", "args": [],
                   "name": "double_plus",
                   "bindings": {"x": "Src.F", "off": "Sink.offset"}}}
  ]
}`

const couplingTransformExpectedAST = `{"op": "+", "args": [{"op": "*", "args": [2.0, "Src.F"]}, "Sink.offset"]}`

func vmCouplingTransformFromJSON(t *testing.T, jsonStr string) any {
	t.Helper()
	var view map[string]any
	dec := json.NewDecoder(strings.NewReader(jsonStr))
	dec.UseNumber()
	if err := dec.Decode(&view); err != nil {
		t.Fatalf("decode expanded JSON: %v", err)
	}
	coupling, ok := view["coupling"].([]any)
	if !ok || len(coupling) == 0 {
		t.Fatalf("expanded document lost the coupling array: %v", view["coupling"])
	}
	entry, ok := coupling[0].(map[string]any)
	if !ok {
		t.Fatalf("coupling[0] is not an object: %#v", coupling[0])
	}
	return entry["transform"]
}

func TestExpressionTemplates_CouplingTransformExpansion(t *testing.T) {
	expanded, err := applyExpressionTemplatesToJSON(couplingTransformFixture)
	if err != nil {
		t.Fatalf("applyExpressionTemplatesToJSON: %v", err)
	}
	transform := vmCouplingTransformFromJSON(t, expanded)
	got := vmCanonJSON(t, transform)
	want := vmCanonJSON(t, json.RawMessage(couplingTransformExpectedAST))
	if got != want {
		t.Errorf("coupling transform not expanded to the template body:\n got = %s\nwant = %s", got, want)
	}
	if strings.Contains(expanded, "apply_expression_template") {
		t.Errorf("expanded document still contains apply_expression_template:\n%s", expanded)
	}
	if strings.Contains(expanded, "expression_templates") {
		t.Errorf("expanded document still contains an expression_templates block:\n%s", expanded)
	}
}

func TestExpressionTemplates_CouplingTransformMatchRule(t *testing.T) {
	// A `match` rewrite rule of the receiving component fires inside the
	// coupling transform to fixpoint, exactly as it would in a model field.
	fixture := `{
	  "esm": "0.4.0",
	  "metadata": {"name": "coupling_transform_match", "authors": ["esm-go"]},
	  "models": {
	    "Src": {"variables": {"F": {"type": "state"}}, "equations": []},
	    "Sink": {
	      "variables": {"offset": {"type": "parameter"}},
	      "equations": [],
	      "expression_templates": {
	        "double_rule": {
	          "params": ["x"],
	          "match": {"op": "double", "args": ["x"]},
	          "body": {"op": "*", "args": [2.0, "x"]}
	        }
	      }
	    }
	  },
	  "coupling": [
	    {"type": "variable_map", "from": "Src.F", "to": "Sink.offset",
	     "transform": {"op": "+", "args": [{"op": "double", "args": ["Src.F"]}, "Sink.offset"]}}
	  ]
	}`
	expanded, err := applyExpressionTemplatesToJSON(fixture)
	if err != nil {
		t.Fatalf("applyExpressionTemplatesToJSON: %v", err)
	}
	transform := vmCouplingTransformFromJSON(t, expanded)
	got := vmCanonJSON(t, transform)
	want := vmCanonJSON(t, json.RawMessage(couplingTransformExpectedAST))
	if got != want {
		t.Errorf("match rule did not fire in coupling transform:\n got = %s\nwant = %s", got, want)
	}
}

func TestExpressionTemplates_CouplingTransformTemplateLessReceiverUnchanged(t *testing.T) {
	// The receiving component declares no templates: the transform is left
	// unrewritten even though another component's templates run the pass.
	fixture := `{
	  "esm": "0.4.0",
	  "metadata": {"name": "coupling_transform_untouched", "authors": ["esm-go"]},
	  "models": {
	    "Src": {"variables": {"F": {"type": "state"}}, "equations": []},
	    "Sink": {"variables": {"offset": {"type": "parameter"}}, "equations": []},
	    "Other": {
	      "variables": {"z": {"type": "state"}},
	      "equations": [],
	      "expression_templates": {
	        "shrink": {
	          "params": ["x"],
	          "match": {"op": "+", "args": ["x", "Sink.offset"]},
	          "body": "x"
	        }
	      }
	    }
	  },
	  "coupling": [
	    {"type": "variable_map", "from": "Src.F", "to": "Sink.offset",
	     "transform": {"op": "+", "args": ["Src.F", "Sink.offset"]}}
	  ]
	}`
	expanded, err := applyExpressionTemplatesToJSON(fixture)
	if err != nil {
		t.Fatalf("applyExpressionTemplatesToJSON: %v", err)
	}
	transform := vmCouplingTransformFromJSON(t, expanded)
	got := vmCanonJSON(t, transform)
	want := vmCanonJSON(t, json.RawMessage(`{"op": "+", "args": ["Src.F", "Sink.offset"]}`))
	if got != want {
		t.Errorf("template-less receiver's coupling transform was rewritten:\n got = %s\nwant = %s", got, want)
	}
}

func TestLoadString_CouplingTransformExpansionEndToEnd(t *testing.T) {
	esmFile, err := LoadString(couplingTransformFixture)
	if err != nil {
		t.Fatalf("LoadString: %v", err)
	}
	if len(esmFile.Coupling) != 1 {
		t.Fatalf("coupling entries = %d; want 1", len(esmFile.Coupling))
	}
	vm, ok := esmFile.Coupling[0].(VariableMapCoupling)
	if !ok {
		t.Fatalf("coupling[0] type = %T; want VariableMapCoupling", esmFile.Coupling[0])
	}
	if !vm.TransformIsExpression() {
		t.Fatalf("loaded transform is not an expression: %#v", vm.Transform)
	}
	got := vmCanonJSON(t, mustCanonicalRaw(t, vm.Transform))
	want := vmCanonJSON(t, json.RawMessage(couplingTransformExpectedAST))
	if got != want {
		t.Errorf("loaded transform:\n got = %s\nwant = %s", got, want)
	}
}

func mustCanonicalRaw(t *testing.T, v any) json.RawMessage {
	t.Helper()
	b, err := marshalCanonical(v, false)
	if err != nil {
		t.Fatalf("marshalCanonical: %v", err)
	}
	return json.RawMessage(b)
}

func TestFlatten_ExpressionTransformDoesNotError(t *testing.T) {
	file := &ESMFile{
		Models: map[string]Model{
			"Src": {
				Variables: map[string]ModelVariable{"F": {Type: "state"}},
				Equations: []Equation{},
			},
			"Sink": {
				Variables: map[string]ModelVariable{"offset": {Type: "parameter"}},
				Equations: []Equation{},
			},
		},
		Coupling: []CouplingEntry{
			VariableMapCoupling{
				Type: "variable_map",
				From: "Src.F",
				To:   "Sink.offset",
				Transform: ExprNode{Op: "+", Args: []any{
					ExprNode{Op: "*", Args: []any{2.0, "Src.F"}},
					"Sink.offset",
				}},
			},
		},
	}

	flat, err := Flatten(file)
	if err != nil {
		t.Fatalf("Flatten with expression transform: %v", err)
	}
	found := false
	for _, rule := range flat.Metadata.CouplingRules {
		if strings.Contains(rule, "transform=expression") {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("expected a variable_map rule with transform=expression, got %v", flat.Metadata.CouplingRules)
	}
}
