package esm

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestResolveScopedReference(t *testing.T) {
	// Create a test ESM file with models and subsystems
	file := &EsmFile{
		Models: map[string]Model{
			"MainModel": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
					"y": {Type: "parameter"},
				},
				Subsystems: map[string]interface{}{
					"SubsystemA": map[string]interface{}{
						"variables": map[string]interface{}{
							"temp": map[string]interface{}{"type": "state"},
							"pressure": map[string]interface{}{"type": "parameter"},
						},
						"subsystems": map[string]interface{}{
							"NestedSub": map[string]interface{}{
								"variables": map[string]interface{}{
									"depth": map[string]interface{}{"type": "state"},
								},
							},
						},
					},
				},
			},
		},
		ReactionSystems: map[string]ReactionSystem{
			"ChemSystem": {
				Species: map[string]Species{
					"CO2": {},
					"H2O": {},
				},
				Parameters: map[string]Parameter{
					"rate_const": {},
				},
				Subsystems: map[string]interface{}{
					"FastReactions": map[string]interface{}{
						"species": map[string]interface{}{
							"OH": map[string]interface{}{},
						},
						"parameters": map[string]interface{}{
							"k_fast": map[string]interface{}{},
						},
					},
				},
			},
		},
	}

	tests := []struct {
		name           string
		scopedRef      string
		currentSystem  string
		expectedVar    string
		expectedFound  bool
	}{
		{
			name:          "Direct variable in model",
			scopedRef:     "x",
			currentSystem: "MainModel",
			expectedVar:   "x",
			expectedFound: true,
		},
		{
			name:          "Scoped reference to model subsystem",
			scopedRef:     "MainModel.SubsystemA.temp",
			currentSystem: "",
			expectedVar:   "temp",
			expectedFound: true,
		},
		{
			name:          "Nested scoped reference",
			scopedRef:     "MainModel.SubsystemA.NestedSub.depth",
			currentSystem: "",
			expectedVar:   "depth",
			expectedFound: true,
		},
		{
			name:          "Scoped reference to reaction system species",
			scopedRef:     "ChemSystem.CO2",
			currentSystem: "",
			expectedVar:   "CO2",
			expectedFound: true,
		},
		{
			name:          "Scoped reference to reaction system parameter",
			scopedRef:     "ChemSystem.rate_const",
			currentSystem: "",
			expectedVar:   "rate_const",
			expectedFound: true,
		},
		{
			name:          "Scoped reference to reaction system subsystem",
			scopedRef:     "ChemSystem.FastReactions.OH",
			currentSystem: "",
			expectedVar:   "OH",
			expectedFound: true,
		},
		{
			name:          "Invalid scoped reference",
			scopedRef:     "NonExistentModel.var",
			currentSystem: "",
			expectedVar:   "NonExistentModel.var",
			expectedFound: false,
		},
		{
			name:          "Invalid variable in valid system",
			scopedRef:     "MainModel.nonexistent_var",
			currentSystem: "",
			expectedVar:   "nonexistent_var",
			expectedFound: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			resolvedVar, found := resolveScopedReference(tt.scopedRef, file, tt.currentSystem)
			assert.Equal(t, tt.expectedFound, found, "Expected found to be %v", tt.expectedFound)
			if tt.expectedFound {
				assert.Equal(t, tt.expectedVar, resolvedVar, "Expected resolved variable to be %s", tt.expectedVar)
			}
		})
	}
}

func TestGetAllAvailableVariables(t *testing.T) {
	// Create a test ESM file
	file := &EsmFile{
		Models: map[string]Model{
			"MainModel": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
					"y": {Type: "parameter"},
				},
				Subsystems: map[string]interface{}{
					"SubsystemA": map[string]interface{}{
						"variables": map[string]interface{}{
							"temp": map[string]interface{}{"type": "state"},
						},
					},
				},
			},
			"OtherModel": {
				Variables: map[string]ModelVariable{
					"z": {Type: "state"},
				},
			},
		},
	}

	allVars := getAllAvailableVariables(file, "MainModel")

	// Should include direct variables from MainModel
	assert.True(t, allVars["x"], "Should include direct variable 'x'")
	assert.True(t, allVars["y"], "Should include direct variable 'y'")

	// Should include subsystem variables with proper scoping
	assert.True(t, allVars["SubsystemA.temp"], "Should include scoped subsystem variable")

	// Should include variables from other systems with full scoping
	assert.True(t, allVars["OtherModel.z"], "Should include cross-system scoped variable")

	// Should not include non-existent variables
	assert.False(t, allVars["nonexistent"], "Should not include non-existent variable")
}

func TestValidationWithScopedReferences(t *testing.T) {
	// Create a test ESM file with scoped references in equations
	file := &EsmFile{
		Esm: "1.0",
		Metadata: Metadata{
			Name: "Test Model",
		},
		Models: map[string]Model{
			"MainModel": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
					"y": {Type: "parameter"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: stringPtr("t")},
						RHS: "SubsystemA.temp", // Scoped reference
					},
				},
				Subsystems: map[string]interface{}{
					"SubsystemA": map[string]interface{}{
						"variables": map[string]interface{}{
							"temp": map[string]interface{}{"type": "state"},
						},
					},
				},
			},
		},
	}

	// Test validation
	result := ValidateStructural(file)

	// Validation should pass because the scoped reference should be resolved
	assert.True(t, result.Valid, "Validation should pass with resolved scoped references")
	if !result.Valid {
		for _, msg := range result.Messages {
			t.Logf("Validation message: %s", msg.Message)
		}
	}
}

func TestSubstitutionWithScopedReferences(t *testing.T) {
	// Create a test ESM file
	file := &EsmFile{
		Models: map[string]Model{
			"MainModel": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
				},
				Subsystems: map[string]interface{}{
					"SubsystemA": map[string]interface{}{
						"variables": map[string]interface{}{
							"temp": map[string]interface{}{"type": "state"},
						},
					},
				},
			},
		},
	}

	// Test expression with scoped reference
	expr := ExprNode{
		Op:   "+",
		Args: []interface{}{"x", "SubsystemA.temp"},
	}

	// Bindings map
	bindings := map[string]Expression{
		"temp": float64(25.0), // Binding for resolved variable
		"x":    float64(10.0),
	}

	// Perform substitution with scoped reference support
	result := SubstituteWithScoped(expr, bindings, file, "MainModel")

	// Verify the result
	resultNode, ok := result.(ExprNode)
	assert.True(t, ok, "Result should be an ExprNode")
	assert.Equal(t, "+", resultNode.Op)
	assert.Equal(t, float64(10.0), resultNode.Args[0])

	// The scoped reference should be resolved and substituted
	assert.Equal(t, float64(25.0), resultNode.Args[1])
}

