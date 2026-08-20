package esm

import (
	"encoding/json"
	"reflect"
	"testing"
)

// parameter_update_test.go replaces functional_affect_test.go. The 0.x event
// `functional_affect` is not renamed by esm 1.0.0, it is REMOVED: a handler's
// only write channel was `modified_params`, so it now lives on the parameter it
// writes, as `update.handler`, and needs no write list at all.
//
// These tests cover the successor construct and the two representation rules
// that come with the update array.

// A handler is the escape hatch value form of an update: it computes the
// parameter's new value when the update fires. Compared with FunctionalAffect it
// has LOST `modified_params` -- the parameter it writes is the one it hangs off.
func TestFunctionalUpdateRoundTrip(t *testing.T) {
	handler := FunctionalUpdate{
		HandlerID:  "PIDController",
		ReadVars:   []string{"T", "T_setpoint", "error_integral"},
		ReadParams: []string{"Kp", "Ki", "Kd"},
		Config: map[string]any{
			"anti_windup":  true,
			"output_clamp": []any{0.0, 100.0},
		},
	}
	jsonData, err := json.Marshal(handler)
	if err != nil {
		t.Fatalf("marshal FunctionalUpdate: %v", err)
	}
	var got FunctionalUpdate
	if err := json.Unmarshal(jsonData, &got); err != nil {
		t.Fatalf("unmarshal FunctionalUpdate: %v", err)
	}
	if !reflect.DeepEqual(got, handler) {
		t.Errorf("FunctionalUpdate round-trip: got %+v, want %+v", got, handler)
	}

	// The write list is gone from the wire form, not merely unused.
	var raw map[string]any
	if err := json.Unmarshal(jsonData, &raw); err != nil {
		t.Fatalf("unmarshal raw: %v", err)
	}
	if _, present := raw["modified_params"]; present {
		t.Error("update.handler must not carry modified_params; the parameter it writes is its owner")
	}
}

// The single-rule form is an OBJECT on the wire and must re-emit as one. A
// one-element array is invalid (the schema's minItems: 2), so an emitter that
// wrapped every update in an array would round-trip a valid document into an
// invalid one.
func TestParameterUpdateSingleRuleStaysAnObject(t *testing.T) {
	const src = `{"kind":"condition","when":{"op":">","args":["c",10]},"expression":0.5}`
	var spec ParameterUpdateSpec
	if err := json.Unmarshal([]byte(src), &spec); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if spec.IsArray {
		t.Error("an object on the wire must not be recorded as the array form")
	}
	if len(spec.Rules) != 1 {
		t.Fatalf("want 1 rule, got %d", len(spec.Rules))
	}
	if spec.Rules[0].Kind != UpdateKindCondition {
		t.Errorf("kind = %q, want %q", spec.Rules[0].Kind, UpdateKindCondition)
	}
	out, err := json.Marshal(spec)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if len(out) == 0 || out[0] != '{' {
		t.Errorf("a single rule must re-emit as an object, got %s", out)
	}
}

// The array form carries two or more rules and must re-emit as an array, in
// declaration order: where several rules fire at once they apply in that order,
// so reordering them would change the model.
func TestParameterUpdateArrayKeepsFormAndOrder(t *testing.T) {
	const src = `[{"kind":"schedule","interval":60,"expression":1},` +
		`{"kind":"condition","when":{"op":">","args":["c",1]},"expression":2}]`
	var spec ParameterUpdateSpec
	if err := json.Unmarshal([]byte(src), &spec); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !spec.IsArray {
		t.Error("an array on the wire must be recorded as the array form")
	}
	want := []string{UpdateKindSchedule, UpdateKindCondition}
	got := []string{spec.Rules[0].Kind, spec.Rules[1].Kind}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("rule order = %v, want %v", got, want)
	}
	out, err := json.Marshal(spec)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if len(out) == 0 || out[0] != '[' {
		t.Errorf("an array must re-emit as an array, got %s", out)
	}
}

// A parameter with an update ARRAY is DISCRETE, never Brownian: the schema
// forbids `wiener` inside an array, because a driving noise process is the
// parameter's whole value and cannot be layered with scheduled writes.
func TestUpdateArrayClassifiesDiscrete(t *testing.T) {
	const src = `{
	  "esm": "1.0.0",
	  "metadata": {"name": "T", "authors": ["A"]},
	  "models": {"M": {
	    "variables": {
	      "c": {"type": "unknown", "units": "1", "default": 1.0},
	      "counter": {
	        "type": "parameter", "units": "1", "default": 0.0,
	        "update": [
	          {"kind": "condition", "when": {"op": ">", "args": ["c", 1.0]}, "expression": 1.0},
	          {"kind": "condition", "when": {"op": "<", "args": ["c", 0.0]}, "expression": 2.0}
	        ]
	      }
	    },
	    "equations": [
	      {"lhs": {"op": "D", "args": ["c"], "wrt": "t"}, "rhs": "counter"}
	    ]
	  }}
	}`
	var file ESMFile
	if err := json.Unmarshal([]byte(src), &file); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	model := file.Models["M"]
	if got := DiscreteParameters(&model); !reflect.DeepEqual(got, []string{"counter"}) {
		t.Errorf("DiscreteParameters = %v, want [counter]", got)
	}
	if got := BrownianParameters(&model); len(got) != 0 {
		t.Errorf("BrownianParameters = %v, want empty", got)
	}
	// No wiener parameter, and a time derivative present, so it is an ODE.
	if got := SystemKind(&model); got != SystemKindODE {
		t.Errorf("SystemKind = %q, want %q", got, SystemKindODE)
	}
}

// An event may affect UNKNOWNS ONLY, so a DiscreteEvent carries neither a
// functional_affect nor a discrete_parameters list on the wire.
func TestDiscreteEventCarriesOnlyAffects(t *testing.T) {
	event := DiscreteEvent{
		Name:    "simple_event",
		Trigger: DiscreteEventTrigger{Type: "condition", Expression: ExprNode{Op: "==", Args: []any{"t", 100.0}}},
		Affects: []AffectEquation{{
			LHS: "x",
			RHS: ExprNode{Op: "+", Args: []any{ExprNode{Op: "Pre", Args: []any{"x"}}, 1.0}},
		}},
	}
	jsonData, err := json.Marshal(event)
	if err != nil {
		t.Fatalf("marshal DiscreteEvent: %v", err)
	}
	var raw map[string]any
	if err := json.Unmarshal(jsonData, &raw); err != nil {
		t.Fatalf("unmarshal raw: %v", err)
	}
	for _, gone := range []string{"functional_affect", "discrete_parameters"} {
		if _, present := raw[gone]; present {
			t.Errorf("DiscreteEvent must not carry %q; it was removed in esm 1.0.0", gone)
		}
	}

	var deserialized DiscreteEvent
	if err := json.Unmarshal(jsonData, &deserialized); err != nil {
		t.Fatalf("unmarshal DiscreteEvent: %v", err)
	}
	if len(deserialized.Affects) != 1 || deserialized.Affects[0].LHS != "x" {
		t.Errorf("affects did not round-trip: %+v", deserialized.Affects)
	}
}

// Both array-form restrictions are SCHEMA-level, and the Go loader must reject
// documents that break them rather than silently accepting a second spelling.
func TestParameterUpdateArrayRestrictionsRejected(t *testing.T) {
	for _, name := range []string{
		"parameter_update_singleton_array.esm",
		"parameter_update_wiener_in_array.esm",
	} {
		t.Run(name, func(t *testing.T) {
			// loadInvalidFixture is not usable here: these two are rejected at the
			// SCHEMA layer, so LoadString returns an error rather than a document,
			// and that error IS the assertion.
			_, _, err := loadInvalidFixtureByPath(t, name)
			if err == nil {
				t.Fatalf("fixture is pinned schema-invalid, but loaded cleanly")
			}
		})
	}
}
