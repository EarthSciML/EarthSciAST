package esm

import (
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestValidateValidModel(t *testing.T) {
	esmFile := &ESMFile{
		ESM: "0.1.0",
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
						LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
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
	esmFile := &ESMFile{
		ESM: "0.1.0",
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
						LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
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

// TestValidationPathsAreJSONPointer pins that structural-error Paths are emitted
// as RFC 6901 JSON Pointers (as SchemaError.Path and the shared invalid-fixture
// goldens are), not the legacy JSONPath-ish "$.models.x.equations[0]" dialect.
func TestValidationPathsAreJSONPointer(t *testing.T) {
	esmFile := &ESMFile{
		ESM:      "0.1.0",
		Metadata: Metadata{Name: "TestModel", Authors: []string{"Test Author"}},
		Models: map[string]Model{
			"TestModel": {
				Variables: map[string]ModelVariable{"x": {Type: "state"}},
				Equations: []Equation{{
					LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
					RHS: "unknown_var",
				}},
			},
		},
	}

	result := ValidateStructuralWithCodes(esmFile)
	require.NotEmpty(t, result.StructuralErrors)
	for _, se := range result.StructuralErrors {
		assert.Truef(t, strings.HasPrefix(se.Path, "/"), "path %q must start with '/'", se.Path)
		assert.NotContainsf(t, se.Path, "$", "path %q must not use the '$' JSONPath root", se.Path)
		assert.NotContainsf(t, se.Path, "[", "path %q must use '/index', not '[index]'", se.Path)
		assert.Containsf(t, se.Path, "/models/TestModel", "path %q must locate the model", se.Path)
	}
}

func TestValidateObservedVariableWithoutExpression(t *testing.T) {
	esmFile := &ESMFile{
		ESM: "0.1.0",
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
						LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
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
	esmFile := &ESMFile{
		ESM: "0.1.0",
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

// TestDuplicateSpeciesWarningBothTracks pins that a duplicated reaction species
// is surfaced as an advisory warning on BOTH validation surfaces (previously the
// coded track lacked it) and that the warning does NOT invalidate the document.
func TestDuplicateSpeciesWarningBothTracks(t *testing.T) {
	esmFile := &ESMFile{
		ESM:      "0.1.0",
		Metadata: Metadata{Name: "TestReactions", Authors: []string{"Test Author"}},
		ReactionSystems: map[string]ReactionSystem{
			"TestReactions": {
				Species:    map[string]Species{"A": {Units: strPtr("mol/mol")}, "B": {Units: strPtr("mol/mol")}},
				Parameters: map[string]Parameter{"k": {Units: strPtr("1/s")}},
				Reactions: []Reaction{{
					ID:         "R1",
					Substrates: []SubstrateProduct{{Species: "A", Stoichiometry: 1}, {Species: "A", Stoichiometry: 1}},
					Products:   []SubstrateProduct{{Species: "B", Stoichiometry: 1}},
					Rate:       "k",
				}},
			},
		},
	}

	// Coded surface: warning present, code stable, document still valid.
	coded := ValidateStructuralWithCodes(esmFile)
	assert.True(t, coded.Valid, "an advisory duplicate-species warning must not invalidate the document")
	var found *StructuralError
	for i := range coded.StructuralErrors {
		if coded.StructuralErrors[i].Code == CodeDuplicateReactionSpecies {
			found = &coded.StructuralErrors[i]
		}
	}
	require.NotNil(t, found, "coded track must surface the duplicate-species warning")
	assert.Equal(t, "warning", found.Level)
	assert.Equal(t, "/reaction_systems/TestReactions/reactions/0/substrates", found.Path)

	// Legacy surface: same finding rendered as a warning-level message.
	legacy := Validate(esmFile)
	assert.True(t, legacy.Valid)
	sawWarning := false
	for _, m := range legacy.Messages {
		if m.Level == "warning" && strings.Contains(m.Message, "appears multiple times") {
			sawWarning = true
		}
	}
	assert.True(t, sawWarning, "legacy track must still surface the duplicate-species warning")
}

func TestValidateReactionWithUnknownSpecies(t *testing.T) {
	esmFile := &ESMFile{
		ESM: "0.1.0",
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
	esmFile := &ESMFile{
		ESM: "0.1.0",
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
						LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
						RHS: ExprNode{
							Op: "*",
							Args: []any{
								"k",
								ExprNode{Op: "+", Args: []any{"x", "y"}},
							},
						},
					},
					{
						LHS: ExprNode{Op: "D", Args: []any{"y"}, Wrt: strPtr("t")},
						RHS: ExprNode{
							Op: "*",
							Args: []any{
								"k",
								ExprNode{Op: "-", Args: []any{"x", "y"}},
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
	esmFile := &ESMFile{
		ESM: "0.1.0",
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
						LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
				},
				DiscreteEvents: []DiscreteEvent{
					{
						Trigger: DiscreteEventTrigger{
							Type:       "condition",
							Expression: ExprNode{Op: ">", Args: []any{"x", 10.0}},
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
	esmFile := &ESMFile{
		ESM: "0.1.0",
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
						LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
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
	esmFile := &ESMFile{
		ESM: "0.1.0",
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
						LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
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
						LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
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
						LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
						RHS: ExprNode{Op: "*", Args: []any{"k", "y"}},
					},
					{
						LHS: ExprNode{Op: "D", Args: []any{"y"}, Wrt: strPtr("t")},
						RHS: ExprNode{Op: "*", Args: []any{"k", "x"}},
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
						LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
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
						LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
					{
						LHS: ExprNode{Op: "D", Args: []any{"k"}, Wrt: strPtr("t")},
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
						LHS: ExprNode{Op: "D", Args: []any{"k"}, Wrt: strPtr("t")},
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
					"y": {Type: "observed", Expression: ExprNode{Op: "*", Args: []any{"x", 2.0}}},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
					{
						// This is not an ODE, it's an algebraic constraint
						LHS: "y",
						RHS: ExprNode{Op: "*", Args: []any{"x", 2.0}},
					},
				},
			},
			expectedValid: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			esmFile := &ESMFile{
				ESM: "0.1.0",
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

// TestUndefinedVariableInAggregateBodyFlagged pins that a reference-checking walk
// descends the non-`args` child fields of an operator node. An undefined variable
// hidden in an `aggregate` `expr` body (a field the historical args-only walker
// never visited, so the document was silently accepted) is now reported as an
// ErrorUndefinedVariable at the aggregate's `/expr` sub-path.
func TestUndefinedVariableInAggregateBodyFlagged(t *testing.T) {
	esmFile := &ESMFile{
		ESM:      "0.8.0",
		Metadata: Metadata{Name: "AggBody", Authors: []string{"Test Author"}},
		IndexSets: map[string]IndexSet{
			"cells": {Kind: "interval"},
		},
		Models: map[string]Model{
			"AggBody": {
				Variables: map[string]ModelVariable{
					"total": {Type: "state"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []any{"total"}, Wrt: strPtr("t")},
						// aggregate contracts over loop index `i` (bound via
						// ranges) but its body references an undeclared variable.
						RHS: ExprNode{
							Op:        "aggregate",
							Args:      []any{},
							OutputIdx: []any{},
							Ranges:    map[string]any{"i": map[string]any{"from": "cells"}},
							Expr:      "undefined_var",
						},
					},
				},
			},
		},
	}

	result := ValidateStructuralWithCodes(esmFile)

	var found *StructuralError
	for i := range result.StructuralErrors {
		if result.StructuralErrors[i].Code == ErrorUndefinedVariable {
			found = &result.StructuralErrors[i]
			break
		}
	}
	require.NotNil(t, found, "undefined variable in aggregate expr body must be flagged; got %+v", result.StructuralErrors)
	assert.Equal(t, "undefined_var", found.Details["variable"])
	assert.Truef(t, strings.HasSuffix(found.Path, "/rhs/expr"), "path %q should point at the aggregate body", found.Path)
	assert.False(t, result.Valid)
}

// TestBoundLoopIndexInAggregateNotFlagged pins that a name introduced ONLY as a
// bound loop index — the `i` an aggregate contracts over and then uses via
// `index(u, i)` in its body — is treated as in-scope for the full-child descent
// and is NOT mis-reported as an undefined variable. Without bound-symbol
// filtering the deeper descent would false-flag `i`.
func TestBoundLoopIndexInAggregateNotFlagged(t *testing.T) {
	esmFile := &ESMFile{
		ESM:      "0.8.0",
		Metadata: Metadata{Name: "AggIdx", Authors: []string{"Test Author"}},
		IndexSets: map[string]IndexSet{
			"cells": {Kind: "interval"},
		},
		Models: map[string]Model{
			"AggIdx": {
				Variables: map[string]ModelVariable{
					"total": {Type: "state"},
					"u":     {Type: "parameter"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []any{"total"}, Wrt: strPtr("t")},
						RHS: ExprNode{
							Op:        "aggregate",
							Args:      []any{},
							OutputIdx: []any{},
							Ranges:    map[string]any{"i": map[string]any{"from": "cells"}},
							// body references the array `u` at bound index `i`.
							Expr: ExprNode{Op: "index", Args: []any{"u", "i"}},
						},
					},
				},
			},
		},
	}

	result := ValidateStructuralWithCodes(esmFile)
	for _, se := range result.StructuralErrors {
		assert.NotEqualf(t, ErrorUndefinedVariable, se.Code,
			"bound loop index / declared array must not be flagged: %+v", se)
	}
	assert.True(t, result.Valid, "valid aggregate should pass: %+v", result.StructuralErrors)
}

// TestUnparseableUnitIsAHardError pins the units-severity policy for a declared
// unit string that denotes NO REAL UNIT.
//
// It is a HARD ERROR (`unit_inconsistency`), not an advisory warning: if a
// declared unit is not a unit, the defect is in the FILE, not in the checker's
// ability to reach a conclusion. (This reverses the earlier leniency, which this
// test previously pinned — see the UnitFinding* policy in units.go.)
//
// The variable is still treated as UNKNOWN for propagation — never coerced to
// dimensionless — so no *second*, bogus dimension-mismatch is manufactured on
// top of it: `D(x) = x` with an unknown-dimension `x` must not also report a
// mismatch.
func TestUnparseableUnitIsAHardError(t *testing.T) {
	esmFile := &ESMFile{
		ESM:      "0.1.0",
		Metadata: Metadata{Name: "BadUnit", Authors: []string{"Test Author"}},
		Models: map[string]Model{
			"BadUnit": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state", Units: strPtr("notaunit")},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
						RHS: "x",
					},
				},
			},
		},
	}

	result := ValidateStructuralWithCodes(esmFile)

	// The finding is recorded, and CODED as unparseable (not as an analysis
	// limit) ...
	var sawParseFinding, sawMismatch bool
	for _, w := range result.UnitWarnings {
		if strings.Contains(w.Message, "could not parse unit") {
			sawParseFinding = true
			assert.Equal(t, UnitFindingUnparseable, w.Code)
			assert.Equal(t, "/models/BadUnit/variables/x/units", w.Path)
		}
		if strings.Contains(w.Message, "does not match") {
			sawMismatch = true
		}
	}
	assert.True(t, sawParseFinding, "unparseable unit must surface a finding: %+v", result.UnitWarnings)
	// ... the variable is treated as UNKNOWN, so no false mismatch is piled on ...
	assert.False(t, sawMismatch, "unknown-unit variable must not manufacture a dimension mismatch: %+v", result.UnitWarnings)

	// ... and it IS a hard error that invalidates the document.
	var sawHardError bool
	for _, se := range result.StructuralErrors {
		if se.Code == ErrorUnitInconsistency {
			sawHardError = true
			assert.Empty(t, se.Level, "a provable unit defect must be error-level, not a warning")
		}
	}
	assert.True(t, sawHardError, "unparseable unit must be a hard unit_inconsistency: %+v", result.StructuralErrors)
	assert.False(t, result.Valid, "a file with an unreal unit is invalid")
}
