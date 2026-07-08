package esm

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestValidateValidModel(t *testing.T) {
	esmFile := &EsmFile{
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
					"y": {
						Type:       "observed",
						Expression: "x",
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

	result := Validate(esmFile)
	assert.True(t, result.Valid)
	assert.Empty(t, result.Messages)
}

func TestValidateModelWithUnknownVariable(t *testing.T) {
	esmFile := &EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:    "TestModel",
			Authors: []string{"Test Author"},
		},
		Models: map[string]Model{
			"TestModel": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
						RHS: "unknown_var", // This variable doesn't exist
					},
				},
			},
		},
	}

	result := Validate(esmFile)
	assert.False(t, result.Valid)
	assert.Len(t, result.Messages, 1)
	assert.Contains(t, result.Messages[0].Message, "Unknown variable 'unknown_var'")
	assert.Equal(t, "error", result.Messages[0].Level)
}

func TestValidateObservedVariableWithoutExpression(t *testing.T) {
	esmFile := &EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:    "TestModel",
			Authors: []string{"Test Author"},
		},
		Models: map[string]Model{
			"TestModel": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
					"y": {Type: "observed"}, // Missing expression
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

	result := Validate(esmFile)
	assert.False(t, result.Valid)
	assert.Len(t, result.Messages, 1)
	assert.Contains(t, result.Messages[0].Message, "Observed variable must have an expression")
}

func TestValidateReactionSystem(t *testing.T) {
	esmFile := &EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:    "TestReactions",
			Authors: []string{"Test Author"},
		},
		ReactionSystems: map[string]ReactionSystem{
			"TestReactions": {
				Species: map[string]Species{
					"A": {Units: strPtr("mol/mol")},
					"B": {Units: strPtr("mol/mol")},
				},
				Parameters: map[string]Parameter{
					"k": {Units: strPtr("1/s")},
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

	result := Validate(esmFile)
	assert.True(t, result.Valid)
	assert.Empty(t, result.Messages)
}

func TestValidateReactionWithUnknownSpecies(t *testing.T) {
	esmFile := &EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:    "TestReactions",
			Authors: []string{"Test Author"},
		},
		ReactionSystems: map[string]ReactionSystem{
			"TestReactions": {
				Species: map[string]Species{
					"A": {Units: strPtr("mol/mol")},
				},
				Parameters: map[string]Parameter{
					"k": {Units: strPtr("1/s")},
				},
				Reactions: []Reaction{
					{
						ID:         "R1",
						Substrates: []SubstrateProduct{{Species: "A", Stoichiometry: 1}},
						Products:   []SubstrateProduct{{Species: "UnknownSpecies", Stoichiometry: 1}},
						Rate:       "k",
					},
				},
			},
		},
	}

	result := Validate(esmFile)
	assert.False(t, result.Valid)
	assert.Len(t, result.Messages, 1)
	assert.Contains(t, result.Messages[0].Message, "Unknown species 'UnknownSpecies'")
}

func TestValidateComplexExpression(t *testing.T) {
	esmFile := &EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:    "TestModel",
			Authors: []string{"Test Author"},
		},
		Models: map[string]Model{
			"TestModel": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
					"y": {Type: "state"},
					"k": {Type: "parameter"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
						RHS: ExprNode{
							Op: "*",
							Args: []interface{}{
								"k",
								ExprNode{Op: "+", Args: []interface{}{"x", "y"}},
							},
						},
					},
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"y"}, Wrt: strPtr("t")},
						RHS: ExprNode{
							Op: "*",
							Args: []interface{}{
								"k",
								ExprNode{Op: "-", Args: []interface{}{"x", "y"}},
							},
						},
					},
				},
			},
		},
	}

	result := Validate(esmFile)
	assert.True(t, result.Valid)
	assert.Empty(t, result.Messages)
}

func TestValidateDiscreteEvent(t *testing.T) {
	esmFile := &EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:    "TestModel",
			Authors: []string{"Test Author"},
		},
		Models: map[string]Model{
			"TestModel": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
				},
				DiscreteEvents: []DiscreteEvent{
					{
						Trigger: DiscreteEventTrigger{
							Type:       "condition",
							Expression: ExprNode{Op: ">", Args: []interface{}{"x", 10.0}},
						},
						Affects: []AffectEquation{
							{
								LHS: "x",
								RHS: float64(0.0),
							},
						},
					},
				},
			},
		},
	}

	result := Validate(esmFile)
	assert.True(t, result.Valid)
	assert.Empty(t, result.Messages)
}

func TestValidateDataLoaders(t *testing.T) {
	esmFile := &EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:    "TestModel",
			Authors: []string{"Test Author"},
		},
		Models: map[string]Model{
			"TestModel": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
				},
			},
		},
		DataLoaders: map[string]DataLoader{
			"TestLoader": {
				Kind: "grid",
				Source: DataLoaderSource{
					URLTemplate: "https://example.com/{date:%Y%m%d}.nc",
				},
				Variables: map[string]DataLoaderVariable{
					"temperature": {FileVariable: "T", Units: "K"},
				},
			},
		},
	}

	result := Validate(esmFile)
	assert.True(t, result.Valid)
	assert.Empty(t, result.Messages)
}

func TestValidateDataLoaderMissingRequiredFields(t *testing.T) {
	esmFile := &EsmFile{
		Esm: "0.1.0",
		Metadata: Metadata{
			Name:    "TestModel",
			Authors: []string{"Test Author"},
		},
		Models: map[string]Model{
			"TestModel": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
				},
			},
		},
		DataLoaders: map[string]DataLoader{
			"BadLoader": {
				// Missing Kind, Source.URLTemplate, and Variables.
				Variables: map[string]DataLoaderVariable{},
			},
		},
	}

	result := Validate(esmFile)
	assert.False(t, result.Valid)

	// Expect errors for missing kind, url_template, and variables.
	errorCount := 0
	for _, msg := range result.Messages {
		if msg.Level == "error" {
			errorCount++
		}
	}

	assert.GreaterOrEqual(t, errorCount, 3)
}

// Test equation-unknown balance validation
func TestValidateEquationUnknownBalance(t *testing.T) {
	tests := []struct {
		name          string
		model         Model
		expectedValid bool
		expectedError string
	}{
		{
			name: "balanced model with one state variable and one ODE",
			model: Model{
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
				},
			},
			expectedValid: true,
		},
		{
			name: "balanced model with two state variables and two ODEs",
			model: Model{
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
					"y": {Type: "state"},
					"k": {Type: "parameter"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
						RHS: ExprNode{Op: "*", Args: []interface{}{"k", "y"}},
					},
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"y"}, Wrt: strPtr("t")},
						RHS: ExprNode{Op: "*", Args: []interface{}{"k", "x"}},
					},
				},
			},
			expectedValid: true,
		},
		{
			name: "unbalanced model with state variable but no ODE",
			model: Model{
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
					"y": {Type: "state"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
				},
			},
			expectedValid: false,
			expectedError: "state variables without ODE equations: [y]",
		},
		{
			name: "unbalanced model with ODE for non-state variable",
			model: Model{
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
					"k": {Type: "parameter"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"k"}, Wrt: strPtr("t")},
						RHS: float64(2.0),
					},
				},
			},
			expectedValid: false,
			expectedError: "ODE equations for non-state variables: [k]",
		},
		{
			name: "unbalanced model with no state variables but ODEs",
			model: Model{
				Variables: map[string]ModelVariable{
					"k": {Type: "parameter"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"k"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
				},
			},
			expectedValid: false,
			expectedError: "found 0 state variables but 1 ODE equations",
		},
		{
			name: "model with non-derivative equations (should be balanced)",
			model: Model{
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
					"y": {Type: "observed", Expression: ExprNode{Op: "*", Args: []interface{}{"x", 2.0}}},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
					{
						// This is not an ODE, it's an algebraic constraint
						LHS: "y",
						RHS: ExprNode{Op: "*", Args: []interface{}{"x", 2.0}},
					},
				},
			},
			expectedValid: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			esmFile := &EsmFile{
				Esm: "0.1.0",
				Metadata: Metadata{
					Name:    "TestModel",
					Authors: []string{"Test Author"},
				},
				Models: map[string]Model{
					"TestModel": tc.model,
				},
			}

			result := Validate(esmFile)

			assert.Equal(t, tc.expectedValid, result.Valid, "Validation result should match expected")

			if !tc.expectedValid {
				assert.NotEmpty(t, result.Messages, "Should have validation messages")

				found := false
				for _, msg := range result.Messages {
					if tc.expectedError != "" && assert.Contains(t, msg.Message, tc.expectedError) {
						found = true
						break
					}
				}

				if tc.expectedError != "" {
					assert.True(t, found, "Should find expected error message containing: %s", tc.expectedError)
				}
			} else {
				// Check that there are no equation-unknown balance errors
				for _, msg := range result.Messages {
					assert.NotContains(t, msg.Message, "Equation-unknown balance", "Should not have equation-unknown balance errors")
				}
			}
		})
	}
}

func TestValidateFileSpecCompliant(t *testing.T) {
	// Test the new spec-compliant ValidateFile function
	jsonStr := `{
		"esm": "0.1.0",
		"metadata": {
			"name": "Test",
			"authors": ["Test Author"]
		},
		"models": {
			"TestModel": {
				"variables": {
					"x": {"type": "state", "default": 0.0},
					"y": {"type": "state", "default": 0.0}
				},
				"equations": [
					{
						"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
						"rhs": "y"
					}
				]
			}
		}
	}`

	esmFile, err := LoadString(jsonStr)
	require.NoError(t, err)

	result := ValidateFile(esmFile, jsonStr)

	// Check that result has the correct structure per spec
	assert.NotNil(t, result)
	assert.NotNil(t, result.SchemaErrors)
	assert.NotNil(t, result.StructuralErrors)
	assert.NotNil(t, result.UnitWarnings)

	// Schema should be valid
	assert.Empty(t, result.SchemaErrors, "No schema errors expected for valid JSON")

	// Should have structural error due to equation-unknown balance (2 state vars, 1 ODE equation)
	assert.NotEmpty(t, result.StructuralErrors, "Should have structural error for equation count mismatch")
	assert.False(t, result.IsValid, "Should be invalid due to structural errors")

	// Check that structural error has proper code
	if len(result.StructuralErrors) > 0 {
		foundEquationError := false
		for _, err := range result.StructuralErrors {
			if err.Code == ErrorEquationCountMismatch {
				foundEquationError = true
				assert.Contains(t, err.Message, "Equation-unknown balance")
			}
		}
		assert.True(t, foundEquationError, "Should have equation count mismatch error")
	}
}

func TestValidateFileValidModel(t *testing.T) {
	// Test with a properly balanced model
	jsonStr := `{
		"esm": "0.1.0",
		"metadata": {
			"name": "Test",
			"authors": ["Test Author"]
		},
		"models": {
			"TestModel": {
				"variables": {
					"x": {"type": "state", "default": 0.0},
					"k": {"type": "parameter", "default": 1.0}
				},
				"equations": [
					{
						"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
						"rhs": {"op": "*", "args": ["k", "x"]}
					}
				]
			}
		}
	}`

	esmFile, err := LoadString(jsonStr)
	require.NoError(t, err)

	result := ValidateFile(esmFile, jsonStr)

	// Should be valid - 1 state variable, 1 ODE equation
	assert.Empty(t, result.SchemaErrors)
	assert.Empty(t, result.StructuralErrors)
	assert.True(t, result.IsValid)
}
