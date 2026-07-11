package esm

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestEsmFileBasicStructure(t *testing.T) {
	// Test creating a basic ESM file structure
	esmFile := EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:        "TestModel",
			Description: strPtr("A test model"),
			Authors:     []string{"Test Author"},
		},
	}

	// Test validation - this should fail because no models, reaction systems, or data loaders
	err := esmFile.Validate()
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "at least one of 'models', 'reaction_systems', or 'data_loaders' must be present")
}

func TestEsmFileWithDataLoaderOnly(t *testing.T) {
	// Test creating an ESM file whose sole component is a data loader.
	esmFile := EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:    "LoaderOnly",
			Authors: []string{"Test Author"},
		},
		DataLoaders: map[string]DataLoader{
			"ERA5_PL": {
				Kind: "grid",
				Source: DataLoaderSource{
					URLTemplate: "cds://reanalysis-era5-pressure-levels/{date:%Y}/era5_pl_{date:%Y}.nc",
				},
				Variables: map[string]DataLoaderVariable{
					"t": {
						FileVariable: "t",
						Units:        "K",
						Description:  strPtr("Air temperature"),
					},
				},
			},
		},
	}

	// Test validation - this should pass since data_loaders is present.
	err := esmFile.Validate()
	assert.NoError(t, err)
}

func TestEsmFileWithModel(t *testing.T) {
	// Test creating an ESM file with a simple model
	esmFile := EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:    "TestModel",
			Authors: []string{"Test Author"},
		},
		Models: map[string]Model{
			"TestModel": {
				Variables: map[string]ModelVariable{
					"x": {
						Type:    "state",
						Units:   strPtr("m"),
						Default: 0.0,
					},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
				},
			},
		},
	}

	// Test validation - this should pass
	err := esmFile.Validate()
	assert.NoError(t, err)
}

func TestEsmFileWithReactionSystem(t *testing.T) {
	// Test creating an ESM file with a reaction system
	esmFile := EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:    "TestReactions",
			Authors: []string{"Test Author"},
		},
		ReactionSystems: map[string]ReactionSystem{
			"TestReactions": {
				Species: map[string]Species{
					"A": {Units: strPtr("mol/mol"), Default: 1e-9},
					"B": {Units: strPtr("mol/mol"), Default: 1e-9},
				},
				Parameters: map[string]Parameter{
					"k": {Units: strPtr("1/s"), Default: 1e-3},
				},
				Reactions: []Reaction{
					{
						ID:         "R1",
						Substrates: []SubstrateProduct{{Species: "A", Stoichiometry: 1}},
						Products:   []SubstrateProduct{{Species: "B", Stoichiometry: 1}},
						Rate:       "k",
					},
				},
			},
		},
	}

	// Test validation - this should pass
	err := esmFile.Validate()
	assert.NoError(t, err)
}

func TestJSONSerialization(t *testing.T) {
	// Test basic JSON serialization
	esmFile := EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:    "TestModel",
			Authors: []string{"Test Author"},
		},
		Models: map[string]Model{
			"TestModel": {
				Variables: map[string]ModelVariable{
					"x": {
						Type:    "state",
						Units:   strPtr("m"),
						Default: 0.0,
					},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
				},
			},
		},
	}

	// Serialize to JSON
	jsonData, err := esmFile.ToJSON()
	require.NoError(t, err)
	assert.NotEmpty(t, jsonData)

	// Test that we can unmarshal it back
	var parsed EsmFile
	err = json.Unmarshal(jsonData, &parsed)
	require.NoError(t, err)

	// Basic checks
	assert.Equal(t, "0.1.0", parsed.Esm)
	assert.Equal(t, "TestModel", parsed.Metadata.Name)
	assert.Len(t, parsed.Models, 1)
}

func TestUnmarshalExpression(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected interface{}
	}{
		{
			name:     "number",
			input:    "3.14",
			expected: float64(3.14),
		},
		{
			name:     "string",
			input:    `"x"`,
			expected: "x",
		},
		{
			name:  "object",
			input: `{"op": "+", "args": ["a", "b"]}`,
			expected: ExprNode{
				Op:   "+",
				Args: []interface{}{"a", "b"},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := UnmarshalExpression([]byte(tt.input))
			require.NoError(t, err)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestCouplingDeserialization(t *testing.T) {
	// Test JSON with various coupling types
	jsonData := `{
		"esm": "0.1.0",
		"metadata": {
			"name": "TestCoupling",
			"authors": ["Test Author"]
		},
		"models": {
			"model1": {
				"variables": {"x": {"type": "state"}},
				"equations": []
			},
			"model2": {
				"variables": {"y": {"type": "state"}},
				"equations": []
			}
		},
		"coupling": [
			{
				"type": "operator_compose",
				"systems": ["model1", "model2"],
				"description": "Operator composition coupling"
			},
			{
				"type": "variable_map",
				"from": "model1",
				"to": "model2",
				"transform": "identity",
				"factor": 1.0
			},
			{
				"type": "couple",
				"systems": ["model1", "model2"],
				"connector": {
					"equations": [
						{
							"from": "x",
							"to": "y",
							"transform": "additive",
							"expression": 1.0
						}
					]
				}
			},
			{
				"type": "operator_apply",
				"operator": "test_operator",
				"description": "Apply operator coupling"
			}
		]
	}`

	// Unmarshal the JSON
	var esmFile EsmFile
	err := json.Unmarshal([]byte(jsonData), &esmFile)
	require.NoError(t, err)

	// Verify we have the right number of coupling entries
	assert.Len(t, esmFile.Coupling, 4)

	// Check each coupling entry is properly typed
	operatorCompose, ok := esmFile.Coupling[0].(OperatorComposeCoupling)
	require.True(t, ok, "First coupling entry should be OperatorComposeCoupling")
	assert.Equal(t, "operator_compose", operatorCompose.Type)
	assert.Equal(t, [2]string{"model1", "model2"}, operatorCompose.Systems)
	assert.Equal(t, "Operator composition coupling", *operatorCompose.Description)

	variableMap, ok := esmFile.Coupling[1].(VariableMapCoupling)
	require.True(t, ok, "Second coupling entry should be VariableMapCoupling")
	assert.Equal(t, "variable_map", variableMap.Type)
	assert.Equal(t, "model1", variableMap.From)
	assert.Equal(t, "model2", variableMap.To)
	assert.Equal(t, "identity", variableMap.Transform)
	require.NotNil(t, variableMap.Factor)
	assert.Equal(t, 1.0, *variableMap.Factor)

	couple, ok := esmFile.Coupling[2].(CouplingCouple)
	require.True(t, ok, "Third coupling entry should be CouplingCouple")
	assert.Equal(t, "couple", couple.Type)
	assert.Equal(t, [2]string{"model1", "model2"}, couple.Systems)
	assert.Len(t, couple.Connector.Equations, 1)

	operatorApply, ok := esmFile.Coupling[3].(OperatorApplyCoupling)
	require.True(t, ok, "Fourth coupling entry should be OperatorApplyCoupling")
	assert.Equal(t, "operator_apply", operatorApply.Type)
	assert.Equal(t, "test_operator", operatorApply.Operator)
	assert.Equal(t, "Apply operator coupling", *operatorApply.Description)
}

func TestCouplingDeserializationErrors(t *testing.T) {
	tests := []struct {
		name     string
		jsonData string
		errorMsg string
	}{
		{
			name: "missing type field",
			jsonData: `{
				"esm": "0.1.0",
				"metadata": {"name": "Test", "authors": ["Test"]},
				"models": {"model1": {"variables": {"x": {"type": "state"}}, "equations": []}},
				"coupling": [{"systems": ["model1"]}]
			}`,
			errorMsg: "coupling entry missing required 'type' field",
		},
		{
			name: "invalid type field",
			jsonData: `{
				"esm": "0.1.0",
				"metadata": {"name": "Test", "authors": ["Test"]},
				"models": {"model1": {"variables": {"x": {"type": "state"}}, "equations": []}},
				"coupling": [{"type": 123}]
			}`,
			errorMsg: "coupling entry 'type' field must be a string",
		},
		{
			name: "unknown coupling type",
			jsonData: `{
				"esm": "0.1.0",
				"metadata": {"name": "Test", "authors": ["Test"]},
				"models": {"model1": {"variables": {"x": {"type": "state"}}, "equations": []}},
				"coupling": [{"type": "unknown_type"}]
			}`,
			errorMsg: "unknown coupling type: unknown_type",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var esmFile EsmFile
			err := json.Unmarshal([]byte(tt.jsonData), &esmFile)
			require.Error(t, err)
			assert.Contains(t, err.Error(), tt.errorMsg)
		})
	}
}

func TestCouplingValidationWithTypedEntries(t *testing.T) {
	// Test that validation works properly with the new typed coupling entries
	jsonData := `{
		"esm": "0.1.0",
		"metadata": {
			"name": "TestCouplingValidation",
			"authors": ["Test Author"]
		},
		"models": {
			"model1": {
				"variables": {"x": {"type": "state"}},
				"equations": []
			},
			"model2": {
				"variables": {"y": {"type": "state"}},
				"equations": []
			}
		},
		"coupling": [
			{
				"type": "operator_compose",
				"systems": ["model1", "model2"]
			},
			{
				"type": "couple",
				"systems": ["model1", "model3"],
				"connector": {
					"equations": []
				}
			}
		]
	}`

	// Unmarshal the JSON
	var esmFile EsmFile
	err := json.Unmarshal([]byte(jsonData), &esmFile)
	require.NoError(t, err)

	// Verify coupling entries are properly typed
	assert.Len(t, esmFile.Coupling, 2)

	operatorCompose, ok := esmFile.Coupling[0].(OperatorComposeCoupling)
	require.True(t, ok, "First coupling entry should be OperatorComposeCoupling")
	assert.Equal(t, "operator_compose", operatorCompose.Type)

	couple, ok := esmFile.Coupling[1].(CouplingCouple)
	require.True(t, ok, "Second coupling entry should be CouplingCouple")
	assert.Equal(t, "couple", couple.Type)

	// Now test validation - this should detect the reference to non-existent "model3"
	// We'll test the detailed validation since it should now work properly with typed coupling entries
	result := Validate(&esmFile)

	// The validation should still work even with typed coupling entries
	// The validation should find the invalid system reference
	assert.False(t, result.Valid)
	assert.NotEmpty(t, result.Messages)

	// Look for the specific error about unknown system
	foundError := false
	for _, msg := range result.Messages {
		if msg.Level == "error" && strings.Contains(msg.Message, "Unknown system 'model3'") {
			foundError = true
			break
		}
	}
	assert.True(t, foundError, "Should find error about unknown system 'model3' in coupling")
}

// TestEventCouplingPreservesAllFields is a regression test for a decode bug
// where EventCoupling.UnmarshalJSON's temp struct omitted functional_affect,
// affect_neg, root_find, and reinitialize, silently dropping those documented
// fields on load. It asserts each survives a full Load -> Save -> Load cycle.
func TestEventCouplingPreservesAllFields(t *testing.T) {
	jsonData := `{
		"esm": "0.8.0",
		"metadata": {"name": "EventCouplingFields", "authors": ["Test"]},
		"models": {
			"m1": {"variables": {"x": {"type": "state"}}, "equations": []},
			"m2": {"variables": {"y": {"type": "state"}}, "equations": []}
		},
		"coupling": [
			{
				"type": "event",
				"event_type": "continuous",
				"name": "cross_ev",
				"conditions": [{"op": "-", "args": ["m1.x", 1]}],
				"affect_neg": [{"lhs": "m2.y", "rhs": 1}],
				"functional_affect": {
					"handler_id": "h1",
					"read_vars": ["m1.x"],
					"read_params": []
				},
				"root_find": "left",
				"reinitialize": true
			}
		]
	}`

	assertFields := func(t *testing.T, ec EventCoupling) {
		t.Helper()
		require.NotNil(t, ec.FunctionalAffect, "functional_affect dropped")
		assert.Equal(t, "h1", ec.FunctionalAffect.HandlerID)
		require.Len(t, ec.AffectNeg, 1, "affect_neg dropped")
		assert.Equal(t, "m2.y", ec.AffectNeg[0].LHS)
		require.NotNil(t, ec.RootFind, "root_find dropped")
		assert.Equal(t, "left", *ec.RootFind)
		require.NotNil(t, ec.Reinitialize, "reinitialize dropped")
		assert.True(t, *ec.Reinitialize)
	}

	ef, err := LoadString(jsonData)
	require.NoError(t, err)
	require.Len(t, ef.Coupling, 1)
	ec, ok := ef.Coupling[0].(EventCoupling)
	require.True(t, ok, "coupling entry should be EventCoupling")
	assertFields(t, ec)

	// The fields must also survive re-serialization and re-load.
	out, err := Save(ef)
	require.NoError(t, err)
	ef2, err := LoadString(out)
	require.NoError(t, err)
	ec2, ok := ef2.Coupling[0].(EventCoupling)
	require.True(t, ok)
	assertFields(t, ec2)
}

// TestIntegerDefaultRoundTrip is a regression test for the int/float wire
// distinction (RFC §5.4.1): an integer-valued `default` (and `guesses` value)
// must stay an integer through Load -> Save instead of mutating to a float and
// re-emitting as "1.0".
func TestIntegerDefaultRoundTrip(t *testing.T) {
	jsonData := `{
		"esm": "0.8.0",
		"metadata": {"name": "IntDefault", "authors": ["Test"]},
		"models": {
			"m": {
				"variables": {
					"x": {"type": "state", "default": 1},
					"z": {"type": "parameter", "default": 2.0}
				},
				"equations": [{"lhs": "x", "rhs": 0}],
				"guesses": {"x": 3}
			}
		},
		"reaction_systems": {
			"rs": {
				"species": {"A": {"default": 5}},
				"parameters": {"k": {"default": 7}},
				"reactions": [{"id": "R1", "substrates": null, "products": [{"species": "A", "stoichiometry": 1}], "rate": "k"}]
			}
		}
	}`

	ef, err := LoadString(jsonData)
	require.NoError(t, err)

	// Decoded integer default keeps its int64 type; float default stays float64.
	m := ef.Models["m"]
	assert.Equal(t, int64(1), m.Variables["x"].Default, "integer default should decode to int64")
	assert.Equal(t, float64(2.0), m.Variables["z"].Default, "float default should stay float64")
	assert.Equal(t, int64(3), m.Guesses["x"], "integer guess should decode to int64")

	rs := ef.ReactionSystems["rs"]
	assert.Equal(t, int64(5), rs.Species["A"].Default, "integer species default should decode to int64")
	assert.Equal(t, int64(7), rs.Parameters["k"].Default, "integer parameter default should decode to int64")

	// And it must re-emit as an integer literal, not "1.0".
	out, err := Save(ef)
	require.NoError(t, err)
	assert.Contains(t, out, `"default": 1`)
	assert.NotContains(t, out, `"default": 1.0`)
	assert.Contains(t, out, `"default": 5`)
	assert.NotContains(t, out, `"default": 5.0`)

	// Idempotent under a second round-trip.
	ef2, err := LoadString(out)
	require.NoError(t, err)
	assert.Equal(t, int64(1), ef2.Models["m"].Variables["x"].Default)
	assert.Equal(t, int64(5), ef2.ReactionSystems["rs"].Species["A"].Default)
}

// Helper function to get string pointers
func strPtr(s string) *string {
	return &s
}
