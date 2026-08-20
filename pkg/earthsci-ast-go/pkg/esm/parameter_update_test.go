package esm

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// parameter_update_test.go replaces functional_affect_test.go. The event
// `functional_affect` is GONE in esm 1.0.0: a handler had exactly one write
// channel — `modified_params` — so it now lives ON the parameter it writes, as
// `update.handler` (esm-spec §5.5), and needs no write list at all. Events
// affect UNKNOWNS only.
//
// These tests cover the replacement surface: the ParameterUpdateSpec union (a
// lone rule as an object, two or more as an ordered array), the three value
// forms, and the handler.

func TestFunctionalUpdateRoundTrip(t *testing.T) {
	handler := FunctionalUpdate{
		HandlerID:  "PIDController",
		ReadVars:   []string{"T", "T_setpoint", "error_integral"},
		ReadParams: []string{"Kp", "Ki", "Kd"},
		Config: map[string]any{
			"anti_windup":   true,
			"sampling_rate": 60.0,
		},
	}
	data, err := json.Marshal(handler)
	if err != nil {
		t.Fatalf("marshal FunctionalUpdate: %v", err)
	}
	// The 0.x write list must NOT reappear: a handler writes exactly the
	// parameter whose update carries it.
	if strings.Contains(string(data), "modified_params") {
		t.Errorf("FunctionalUpdate must not carry `modified_params`: %s", data)
	}
	var back FunctionalUpdate
	if err := json.Unmarshal(data, &back); err != nil {
		t.Fatalf("unmarshal FunctionalUpdate: %v", err)
	}
	if !reflect.DeepEqual(handler, back) {
		t.Errorf("FunctionalUpdate round-trip: got %+v want %+v", back, handler)
	}
}

// The parameter a handler used to be pointed at by `modified_params` now OWNS
// the handler. The whole PID example of esm-spec §5.5, decoded from the wire.
func TestHandlerUpdateOnParameter(t *testing.T) {
	const src = `{
	  "type": "parameter",
	  "units": "W",
	  "shape": [],
	  "default": 0.0,
	  "update": {
	    "kind": "schedule",
	    "interval": 60.0,
	    "handler": {
	      "handler_id": "PIDController",
	      "read_vars": ["T", "T_setpoint", "error_integral"],
	      "read_params": ["Kp", "Ki", "Kd"],
	      "config": {"anti_windup": true, "output_clamp": [0.0, 100.0]}
	    }
	  }
	}`
	var v ModelVariable
	if err := json.Unmarshal([]byte(src), &v); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	rules := v.UpdateRules()
	if len(rules) != 1 {
		t.Fatalf("UpdateRules = %+v, want exactly one", rules)
	}
	if rules[0].Kind != UpdateKindSchedule {
		t.Errorf("kind = %q, want %q", rules[0].Kind, UpdateKindSchedule)
	}
	if rules[0].Interval == nil || *rules[0].Interval != 60.0 {
		t.Errorf("interval = %v, want 60", rules[0].Interval)
	}
	if rules[0].Handler == nil || rules[0].Handler.HandlerID != "PIDController" {
		t.Fatalf("handler = %+v, want PIDController", rules[0].Handler)
	}
	// A schedule update REQUIRES `shape`, and the authored empty array must
	// survive the round-trip or the re-emitted document is schema-invalid.
	if v.Shape == nil {
		t.Fatal("an authored `shape: []` must be retained, not folded into omission")
	}
	// Compare through the CANONICAL emitter, which is what writes .esm files:
	// plain json.Marshal renders float64(0) as "0" and so loses the int/float
	// wire shape the loader restores, which would make a byte comparison fail for
	// reasons that have nothing to do with the update block.
	out, err := marshalCanonical(v, false)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(out), `"shape":[]`) {
		t.Errorf("re-emitted variable dropped the empty shape: %s", out)
	}
	var back ModelVariable
	if err := json.Unmarshal(out, &back); err != nil {
		t.Fatalf("re-unmarshal: %v", err)
	}
	out2, err := marshalCanonical(back, false)
	if err != nil {
		t.Fatalf("re-marshal: %v", err)
	}
	if string(out) != string(out2) {
		t.Errorf("handler update lost information on round-trip:\n got=%s\nwant=%s", out2, out)
	}
}

// A parameter may carry SEVERAL rules, applied in declaration order. The array
// form exists because before 1.0.0 any number of events could write one
// parameter, and collapsing that onto the parameter must not cost the
// expressiveness (esm-spec §5.4).
func TestParameterUpdateArrayPreservesOrder(t *testing.T) {
	const src = `{
	  "type": "parameter",
	  "units": "1",
	  "default": 1.0,
	  "update": [
	    {"kind": "condition", "when": {"op": "==", "args": ["season", 1]}, "expression": "spring_modifier"},
	    {"kind": "condition", "when": {"op": "==", "args": ["season", 2]}, "expression": "summer_modifier"}
	  ]
	}`
	var v ModelVariable
	if err := json.Unmarshal([]byte(src), &v); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	rules := v.UpdateRules()
	if len(rules) != 2 {
		t.Fatalf("UpdateRules = %d, want 2", len(rules))
	}
	if rules[0].Expression != "spring_modifier" || rules[1].Expression != "summer_modifier" {
		t.Errorf("declaration order not preserved: %+v", rules)
	}
	// An update ARRAY still means DISCRETE, never Brownian: the schema forbids
	// `wiener` inside an array.
	model := &Model{Variables: map[string]ModelVariable{"m": v}}
	if got := BrownianParameters(model); len(got) != 0 {
		t.Errorf("BrownianParameters = %v, want none for an array update", got)
	}
	if got, want := DiscreteParameters(model), []string{"m"}; !reflect.DeepEqual(got, want) {
		t.Errorf("DiscreteParameters = %v, want %v", got, want)
	}

	// The array spelling must survive re-emission: a one-element array is
	// invalid, so the two spellings are not interchangeable.
	out, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(out), `"update":[`) {
		t.Errorf("array update re-emitted in the object form: %s", out)
	}
}

// A one-element array has no legal meaning (esm-spec §5.4: "a single rule MUST
// be the object form"), so accepting it would give one update set two spellings
// and break the round-trip.
func TestParameterUpdateSingletonArrayRejected(t *testing.T) {
	const src = `{"type":"parameter","units":"1","default":1.0,
	  "update":[{"kind":"condition","when":{"op":">","args":["x",1]},"expression":0.5}]}`
	var v ModelVariable
	err := json.Unmarshal([]byte(src), &v)
	if err == nil {
		t.Fatal("a one-element update array must be rejected")
	}
	if !strings.Contains(err.Error(), "at least two rules") {
		t.Errorf("unexpected error: %v", err)
	}
}

// `wiener` is object-form only: a driving noise process IS the parameter's whole
// value, so combining it with scheduled writes is incoherent.
func TestWienerInsideArrayRejected(t *testing.T) {
	const src = `{"type":"parameter","units":"1",
	  "distribution":{"kind":"normal","mean":0.0,"std":1.0},
	  "update":[{"kind":"wiener"},{"kind":"condition","when":{"op":">","args":["x",1]},"expression":0.5}]}`
	var v ModelVariable
	err := json.Unmarshal([]byte(src), &v)
	if err == nil {
		t.Fatal("a `wiener` rule inside an update array must be rejected")
	}
	if !strings.Contains(err.Error(), "object-form only") {
		t.Errorf("unexpected error: %v", err)
	}
}

// A discrete event still carries ordinary affects; what it no longer carries is
// a `functional_affect` or a `discrete_parameters` list, so neither key may
// appear on the wire.
func TestDiscreteEventCarriesOnlyAffects(t *testing.T) {
	event := DiscreteEvent{
		Name: "simple_event",
		Trigger: DiscreteEventTrigger{
			Type: "condition",
			Expression: ExprNode{
				Op:   "==",
				Args: []any{"t", 100.0},
			},
		},
		Affects: []AffectEquation{{
			LHS: "x",
			RHS: ExprNode{Op: "+", Args: []any{ExprNode{Op: "Pre", Args: []any{"x"}}, 1.0}},
		}},
	}
	data, err := json.Marshal(event)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	for _, gone := range []string{"functional_affect", "discrete_parameters", "modified_params"} {
		if strings.Contains(string(data), gone) {
			t.Errorf("DiscreteEvent must not carry %q: %s", gone, data)
		}
	}
	var back DiscreteEvent
	if err := json.Unmarshal(data, &back); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(back.Affects) != 1 || back.Affects[0].LHS != "x" {
		t.Errorf("affects lost on round-trip: %+v", back.Affects)
	}
}

// The three value forms classify identically: any non-wiener update makes a
// parameter DISCRETE, whether the value comes from an expression, a data
// binding, or a handler.
func TestValueFormsClassifyAlike(t *testing.T) {
	interval := 60.0
	model := &Model{Variables: map[string]ModelVariable{
		"by_expression": {Type: VarTypeParameter, Update: ParameterUpdate{
			Kind: UpdateKindCondition,
			When: ExprNode{Op: ">", Args: []any{"x", 1.0}}, Expression: 1.0}},
		"by_handler": {Type: VarTypeParameter, Shape: dims(), Update: ParameterUpdate{
			Kind: UpdateKindSchedule, Interval: &interval,
			Handler: &FunctionalUpdate{HandlerID: "H"}}},
		"by_from": {Type: VarTypeParameter, Shape: dims(), Update: ParameterUpdate{
			Kind: UpdateKindData, Source: "SRC",
			From: &DataSourceBinding{FileVariable: "T2M"}}},
	}}
	want := []string{"by_expression", "by_from", "by_handler"}
	if got := DiscreteParameters(model); !reflect.DeepEqual(got, want) {
		t.Errorf("DiscreteParameters = %v, want %v", got, want)
	}
}

// A CROSS-SYSTEM event may affect UNKNOWNS ONLY too (esm-spec §5.4). The target
// is a dotted scoped reference, so this pins that the check resolves the owning
// component rather than only looking at model-local affects.
func TestCouplingEventAffectsParameter(t *testing.T) {
	const src = `{
	  "esm": "1.0.0",
	  "metadata": {"name": "cross_event", "authors": ["t"]},
	  "models": {
	    "Chem": {
	      "variables": {"O3": {"type": "unknown", "units": "1", "default": 0.0},
	                    "k": {"type": "parameter", "units": "1/s", "default": 1.0}},
	      "equations": [{"lhs": {"op": "D", "args": ["O3"], "wrt": "t"},
	                     "rhs": {"op": "*", "args": [{"op": "-", "args": ["k"]}, "O3"]}}]},
	    "Emit": {
	      "variables": {"burden": {"type": "unknown", "units": "1", "default": 0.0}},
	      "equations": [{"lhs": {"op": "D", "args": ["burden"], "wrt": "t"}, "rhs": 1.0}]}
	  },
	  "coupling": [{
	    "type": "event", "event_type": "continuous", "name": "cross",
	    "conditions": [{"op": "-", "args": ["Chem.O3", 1.0]}],
	    "affects": [{"lhs": "Chem.k", "rhs": 0.5}]
	  }]
	}`
	file, err := LoadString(src)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	res := ValidateFile(file, src)
	found := false
	for _, e := range res.StructuralErrors {
		if e.Code != ErrorEventAffectsParameter {
			continue
		}
		found = true
		if e.Path != "/coupling/0/affects/0" {
			t.Errorf("path = %q, want /coupling/0/affects/0", e.Path)
		}
		if e.Details["coupling_type"] != "event" {
			t.Errorf("details = %+v, want coupling_type=event", e.Details)
		}
	}
	if !found {
		t.Errorf("want event_affects_parameter for a cross-system event: %+v", res.StructuralErrors)
	}
}
