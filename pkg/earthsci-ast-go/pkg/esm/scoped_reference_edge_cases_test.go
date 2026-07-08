package esm

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestScopedReferenceEdgeCases(t *testing.T) {
	// Create a complex test ESM file with deep nesting and cross-references
	file := &EsmFile{
		Esm: "1.0",
		Metadata: Metadata{
			Name: "Complex Test Model",
		},
		Models: map[string]Model{
			"ModelA": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: stringPtr("t")},
						RHS: "ModelB.y", // Cross-model reference
					},
				},
			},
			"ModelB": {
				Variables: map[string]ModelVariable{
					"y": {Type: "parameter"},
				},
				Subsystems: map[string]interface{}{
					"DeepNest": map[string]interface{}{
						"variables": map[string]interface{}{
							"z": map[string]interface{}{"type": "state"},
						},
						"subsystems": map[string]interface{}{
							"Level3": map[string]interface{}{
								"variables": map[string]interface{}{
									"w": map[string]interface{}{"type": "parameter"},
								},
							},
						},
					},
				},
			},
		},
		ReactionSystems: map[string]ReactionSystem{
			"ChemA": {
				Species: map[string]Species{
					"CO2": {},
				},
				Parameters: map[string]Parameter{
					"k1": {},
				},
				Reactions: []Reaction{
					{
						ID:         "r1",
						Substrates: []SubstrateProduct{{Species: "CO2", Stoichiometry: 1}},
						Products:   []SubstrateProduct{},
						Rate:       "ChemB.k2", // Cross-system reference
					},
				},
			},
			"ChemB": {
				Parameters: map[string]Parameter{
					"k2": {},
				},
			},
		},
	}

	tests := []struct {
		name          string
		scopedRef     string
		currentSystem string
		shouldResolve bool
		description   string
	}{
		{
			name:          "Cross-model reference",
			scopedRef:     "ModelB.y",
			currentSystem: "ModelA",
			shouldResolve: true,
			description:   "Should resolve reference to variable in another model",
		},
		{
			name:          "Deep nested reference",
			scopedRef:     "ModelB.DeepNest.Level3.w",
			currentSystem: "",
			shouldResolve: true,
			description:   "Should resolve deeply nested subsystem reference",
		},
		{
			name:          "Cross-system reaction reference",
			scopedRef:     "ChemB.k2",
			currentSystem: "ChemA",
			shouldResolve: true,
			description:   "Should resolve parameter reference across reaction systems",
		},
		{
			name:          "Invalid deep reference",
			scopedRef:     "ModelB.DeepNest.Level3.NonExistent",
			currentSystem: "",
			shouldResolve: false,
			description:   "Should fail to resolve non-existent variable in deep nesting",
		},
		{
			name:          "Empty scoped reference",
			scopedRef:     "",
			currentSystem: "ModelA",
			shouldResolve: true,
			description:   "Should handle empty reference gracefully",
		},
		{
			name:          "Single dot reference",
			scopedRef:     ".",
			currentSystem: "ModelA",
			shouldResolve: false,
			description:   "Should handle malformed reference",
		},
		{
			name:          "Reference with empty parts",
			scopedRef:     "ModelA..x",
			currentSystem: "",
			shouldResolve: false,
			description:   "Should handle reference with empty parts",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, resolved := resolveScopedReference(tt.scopedRef, file, tt.currentSystem)
			assert.Equal(t, tt.shouldResolve, resolved, tt.description)
		})
	}
}

func TestValidationWithComplexScopedReferences(t *testing.T) {
	// Test validation with the complex file structure
	file := &EsmFile{
		Esm: "1.0",
		Metadata: Metadata{
			Name: "Complex Test Model",
		},
		Models: map[string]Model{
			"ModelA": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: stringPtr("t")},
						RHS: ExprNode{
							Op:   "+",
							Args: []interface{}{"ModelB.y", "ModelB.DeepNest.z"},
						},
					},
				},
			},
			"ModelB": {
				Variables: map[string]ModelVariable{
					"y": {Type: "parameter"},
				},
				Subsystems: map[string]interface{}{
					"DeepNest": map[string]interface{}{
						"variables": map[string]interface{}{
							"z": map[string]interface{}{"type": "state"},
						},
					},
				},
			},
		},
	}

	// Test validation
	result := ValidateStructural(file)

	// Validation should pass because all scoped references should be resolved
	assert.True(t, result.Valid, "Validation should pass with complex scoped references")
	if !result.Valid {
		for _, msg := range result.Messages {
			t.Logf("Validation message: %s", msg.Message)
		}
	}
}

func TestSubstitutionWithComplexScopedReferences(t *testing.T) {
	// Test substitution with complex scoped references
	file := &EsmFile{
		Esm: "1.0",
		Metadata: Metadata{
			Name: "Complex Test Model",
		},
		Models: map[string]Model{
			"ModelA": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
				},
				Subsystems: map[string]interface{}{
					"SubA": map[string]interface{}{
						"variables": map[string]interface{}{
							"temp": map[string]interface{}{"type": "state"},
						},
					},
				},
			},
			"ModelB": {
				Variables: map[string]ModelVariable{
					"y": {Type: "parameter"},
				},
			},
		},
	}

	// Test expression with mixed scoped references
	expr := ExprNode{
		Op: "+",
		Args: []interface{}{
			"x",                        // Direct variable in current system
			"SubA.temp",               // Relative scoped reference
			"ModelB.y",                // Absolute cross-model reference
			ExprNode{
				Op:   "*",
				Args: []interface{}{"SubA.temp", float64(2.0)},
			},
		},
	}

	// Bindings map with resolved variable names
	bindings := map[string]Expression{
		"x":    float64(10.0),
		"temp": float64(25.0),
		"y":    float64(5.0),
	}

	// Perform substitution with scoped reference support
	result := SubstituteWithScoped(expr, bindings, file, "ModelA")

	// Verify the result
	resultNode, ok := result.(ExprNode)
	assert.True(t, ok, "Result should be an ExprNode")
	assert.Equal(t, "+", resultNode.Op)
	assert.Len(t, resultNode.Args, 4)

	// Check individual arguments
	assert.Equal(t, float64(10.0), resultNode.Args[0]) // x
	assert.Equal(t, float64(25.0), resultNode.Args[1]) // SubA.temp resolved to temp
	assert.Equal(t, float64(5.0), resultNode.Args[2])  // ModelB.y resolved to y

	// Check nested expression
	nestedNode, ok := resultNode.Args[3].(ExprNode)
	assert.True(t, ok, "Fourth argument should be an ExprNode")
	assert.Equal(t, "*", nestedNode.Op)
	assert.Equal(t, float64(25.0), nestedNode.Args[0]) // SubA.temp resolved to temp
	assert.Equal(t, float64(2.0), nestedNode.Args[1])  // Unchanged literal
}

func TestValidationErrorsForUnresolvedScopedReferences(t *testing.T) {
	// Test that validation properly reports errors for unresolved scoped references
	file := &EsmFile{
		Esm: "1.0",
		Metadata: Metadata{
			Name: "Test Model with Errors",
		},
		Models: map[string]Model{
			"ModelA": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: stringPtr("t")},
						RHS: "NonExistent.Model.var", // Invalid scoped reference
					},
				},
			},
		},
	}

	// Test validation
	result := ValidateStructural(file)

	// Validation should fail
	assert.False(t, result.Valid, "Validation should fail with unresolved scoped references")

	// Should have an error message about unresolved scoped reference
	found := false
	for _, msg := range result.Messages {
		if strings.Contains(msg.Message, "Unresolved scoped reference") {
			found = true
			break
		}
	}
	assert.True(t, found, "Should have error message about unresolved scoped reference")
}
