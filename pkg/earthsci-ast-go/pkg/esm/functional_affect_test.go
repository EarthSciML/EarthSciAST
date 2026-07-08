package esm

import (
	"encoding/json"
	"testing"
)

func TestFunctionalAffectSerialization(t *testing.T) {
	// Test FunctionalAffect struct serialization
	functionalAffect := FunctionalAffect{
		HandlerID:      "PIDController",
		ReadVars:       []string{"T", "T_setpoint", "error_integral"},
		ReadParams:     []string{"Kp", "Ki", "Kd"},
		ModifiedParams: []string{"heater_power"},
		Config: map[string]interface{}{
			"anti_windup":    true,
			"output_clamp":   []float64{0.0, 100.0},
			"sampling_rate":  60.0,
		},
	}

	// Serialize to JSON
	jsonData, err := json.Marshal(functionalAffect)
	if err != nil {
		t.Fatalf("Failed to serialize FunctionalAffect: %v", err)
	}

	// Deserialize from JSON
	var deserialized FunctionalAffect
	err = json.Unmarshal(jsonData, &deserialized)
	if err != nil {
		t.Fatalf("Failed to deserialize FunctionalAffect: %v", err)
	}

	// Verify all fields
	if deserialized.HandlerID != functionalAffect.HandlerID {
		t.Errorf("HandlerID mismatch: got %s, want %s", deserialized.HandlerID, functionalAffect.HandlerID)
	}

	if len(deserialized.ReadVars) != len(functionalAffect.ReadVars) {
		t.Errorf("ReadVars length mismatch: got %d, want %d", len(deserialized.ReadVars), len(functionalAffect.ReadVars))
	}

	for i, v := range functionalAffect.ReadVars {
		if deserialized.ReadVars[i] != v {
			t.Errorf("ReadVars[%d] mismatch: got %s, want %s", i, deserialized.ReadVars[i], v)
		}
	}

	if len(deserialized.ReadParams) != len(functionalAffect.ReadParams) {
		t.Errorf("ReadParams length mismatch: got %d, want %d", len(deserialized.ReadParams), len(functionalAffect.ReadParams))
	}

	for i, v := range functionalAffect.ReadParams {
		if deserialized.ReadParams[i] != v {
			t.Errorf("ReadParams[%d] mismatch: got %s, want %s", i, deserialized.ReadParams[i], v)
		}
	}

	if len(deserialized.ModifiedParams) != len(functionalAffect.ModifiedParams) {
		t.Errorf("ModifiedParams length mismatch: got %d, want %d", len(deserialized.ModifiedParams), len(functionalAffect.ModifiedParams))
	}

	for i, v := range functionalAffect.ModifiedParams {
		if deserialized.ModifiedParams[i] != v {
			t.Errorf("ModifiedParams[%d] mismatch: got %s, want %s", i, deserialized.ModifiedParams[i], v)
		}
	}

	// Verify config
	if deserialized.Config["anti_windup"] != functionalAffect.Config["anti_windup"] {
		t.Errorf("Config anti_windup mismatch: got %v, want %v",
			deserialized.Config["anti_windup"], functionalAffect.Config["anti_windup"])
	}

	if deserialized.Config["sampling_rate"] != functionalAffect.Config["sampling_rate"] {
		t.Errorf("Config sampling_rate mismatch: got %v, want %v",
			deserialized.Config["sampling_rate"], functionalAffect.Config["sampling_rate"])
	}
}

func TestDiscreteEventWithFunctionalAffect(t *testing.T) {
	// Test DiscreteEvent with FunctionalAffect
	discreteEvent := DiscreteEvent{
		Name: "complex_controller",
		Trigger: DiscreteEventTrigger{
			Type:     "periodic",
			Interval: &[]float64{60.0}[0],
		},
		FunctionalAffect: &FunctionalAffect{
			HandlerID:      "PIDController",
			ReadVars:       []string{"T", "T_setpoint", "error_integral"},
			ReadParams:     []string{"Kp", "Ki", "Kd"},
			ModifiedParams: []string{"heater_power"},
			Config: map[string]interface{}{
				"anti_windup":   true,
				"output_clamp":  []float64{0.0, 100.0},
			},
		},
		Reinitialize: &[]bool{true}[0],
		Description:  &[]string{"PID temperature controller, updates heater power every 60s"}[0],
	}

	// Serialize to JSON
	jsonData, err := json.Marshal(discreteEvent)
	if err != nil {
		t.Fatalf("Failed to serialize DiscreteEvent with FunctionalAffect: %v", err)
	}

	// Deserialize from JSON
	var deserialized DiscreteEvent
	err = json.Unmarshal(jsonData, &deserialized)
	if err != nil {
		t.Fatalf("Failed to deserialize DiscreteEvent with FunctionalAffect: %v", err)
	}

	// Verify basic fields
	if deserialized.Name != discreteEvent.Name {
		t.Errorf("Name mismatch: got %s, want %s", deserialized.Name, discreteEvent.Name)
	}

	if deserialized.Trigger.Type != discreteEvent.Trigger.Type {
		t.Errorf("Trigger type mismatch: got %s, want %s", deserialized.Trigger.Type, discreteEvent.Trigger.Type)
	}

	// Verify FunctionalAffect
	if deserialized.FunctionalAffect == nil {
		t.Fatal("FunctionalAffect is nil after deserialization")
	}

	if deserialized.FunctionalAffect.HandlerID != discreteEvent.FunctionalAffect.HandlerID {
		t.Errorf("FunctionalAffect HandlerID mismatch: got %s, want %s",
			deserialized.FunctionalAffect.HandlerID, discreteEvent.FunctionalAffect.HandlerID)
	}

	if len(deserialized.FunctionalAffect.ReadVars) != len(discreteEvent.FunctionalAffect.ReadVars) {
		t.Errorf("FunctionalAffect ReadVars length mismatch: got %d, want %d",
			len(deserialized.FunctionalAffect.ReadVars), len(discreteEvent.FunctionalAffect.ReadVars))
	}

	// Verify that Affects is empty/nil when FunctionalAffect is used
	if len(deserialized.Affects) > 0 {
		t.Errorf("Expected empty Affects when FunctionalAffect is used, got %d affects", len(deserialized.Affects))
	}
}

func TestDiscreteEventWithRegularAffects(t *testing.T) {
	// Test that regular affects still work
	discreteEvent := DiscreteEvent{
		Name: "simple_event",
		Trigger: DiscreteEventTrigger{
			Type: "condition",
			Expression: ExprNode{
				Op:   "==",
				Args: []interface{}{"t", 100.0},
			},
		},
		Affects: []AffectEquation{
			{
				LHS: "x",
				RHS: ExprNode{
					Op:   "+",
					Args: []interface{}{
						ExprNode{Op: "Pre", Args: []interface{}{"x"}},
						1.0,
					},
				},
			},
		},
		Description: &[]string{"Simple event that increments x by 1"}[0],
	}

	// Serialize to JSON
	jsonData, err := json.Marshal(discreteEvent)
	if err != nil {
		t.Fatalf("Failed to serialize DiscreteEvent with regular affects: %v", err)
	}

	// Deserialize from JSON
	var deserialized DiscreteEvent
	err = json.Unmarshal(jsonData, &deserialized)
	if err != nil {
		t.Fatalf("Failed to deserialize DiscreteEvent with regular affects: %v", err)
	}

	// Verify that regular affects work correctly
	if len(deserialized.Affects) != 1 {
		t.Errorf("Expected 1 affect, got %d", len(deserialized.Affects))
	}

	if deserialized.Affects[0].LHS != "x" {
		t.Errorf("Affect LHS mismatch: got %s, want x", deserialized.Affects[0].LHS)
	}

	// Verify that FunctionalAffect is nil
	if deserialized.FunctionalAffect != nil {
		t.Errorf("Expected nil FunctionalAffect when using regular affects")
	}
}

func TestFunctionalAffectJSONSchemaCompliance(t *testing.T) {
	// Test minimal FunctionalAffect that should pass JSON schema validation
	minimalFunctionalAffect := FunctionalAffect{
		HandlerID:  "MinimalHandler",
		ReadVars:   []string{"var1"},
		ReadParams: []string{"param1"},
	}

	jsonData, err := json.Marshal(minimalFunctionalAffect)
	if err != nil {
		t.Fatalf("Failed to serialize minimal FunctionalAffect: %v", err)
	}

	var deserialized FunctionalAffect
	err = json.Unmarshal(jsonData, &deserialized)
	if err != nil {
		t.Fatalf("Failed to deserialize minimal FunctionalAffect: %v", err)
	}

	// Verify required fields are present
	if deserialized.HandlerID != "MinimalHandler" {
		t.Errorf("HandlerID mismatch: got %s, want MinimalHandler", deserialized.HandlerID)
	}

	if len(deserialized.ReadVars) != 1 || deserialized.ReadVars[0] != "var1" {
		t.Errorf("ReadVars mismatch: got %v, want [var1]", deserialized.ReadVars)
	}

	if len(deserialized.ReadParams) != 1 || deserialized.ReadParams[0] != "param1" {
		t.Errorf("ReadParams mismatch: got %v, want [param1]", deserialized.ReadParams)
	}

	// Optional fields should be empty/nil
	if len(deserialized.ModifiedParams) != 0 {
		t.Errorf("Expected empty ModifiedParams, got %v", deserialized.ModifiedParams)
	}

	if len(deserialized.Config) != 0 {
		t.Errorf("Expected empty/nil Config, got %v", deserialized.Config)
	}
}
