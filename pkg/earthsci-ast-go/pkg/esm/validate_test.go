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
						Type:    "unknown",
						Units:   strPtr("m"),
						Default: 0.0,
					},
					"y": {
						Type: "unknown",
					},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
					{LHS: "y", RHS: "x"},
				},
			},
		},
	}

	result := ValidateStructural(esmFile)
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
					"x": {Type: "unknown"},
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

	result := ValidateStructural(esmFile)
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
				Variables: map[string]ModelVariable{"x": {Type: "unknown"}},
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

// esm 1.0.0 retires `missing_observed_expr`: the variable `expression` field it
// named is gone, and an observed unknown is DEFINED BY AN EQUATION. An unknown
// with nothing defining it is therefore an unbalanced system, reported as
// `equation_count_mismatch` (esm-spec §4.9.4) — which is exactly what
// tests/invalid/unknown_without_equation.esm pins.
func TestValidateUnknownWithoutEquation(t *testing.T) {
	esmFile := &ESMFile{
		ESM: "0.1.0",
		Metadata: Metadata{
			Name:    "TestModel",
			Authors: []string{"Test Author"},
		},
		Models: map[string]Model{
			"TestModel": {
				Variables: map[string]ModelVariable{
					"x": {Type: "unknown"},
					"y": {Type: "unknown"}, // no equation defines it
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

	result := ValidateStructural(esmFile)
	assert.False(t, result.Valid)
	assert.Len(t, result.Messages, 1)
	assert.Contains(t, result.Messages[0].Message,
		"Number of equations (1) does not match number of unknowns (2)")
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

	result := ValidateStructural(esmFile)
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
	legacy := ValidateStructural(esmFile)
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

	result := ValidateStructural(esmFile)
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
					"x": {Type: "unknown"},
					"y": {Type: "unknown"},
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

	result := ValidateStructural(esmFile)
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
					"x": {Type: "unknown"},
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

	result := ValidateStructural(esmFile)
	assert.True(t, result.Valid)
	assert.Empty(t, result.Messages)
}

func TestValidateDataSources(t *testing.T) {
	esmFile := &ESMFile{
		ESM: "0.1.0",
		Metadata: Metadata{
			Name:    "TestModel",
			Authors: []string{"Test Author"},
		},
		Models: map[string]Model{
			"TestModel": {
				Variables: map[string]ModelVariable{
					"x": {Type: "unknown"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
				},
			},
		},
		DataSources: map[string]DataSource{
			"TestSource": {
				Kind: "grid",
				Source: DataSourceLocation{
					URLTemplate: "https://example.com/{date:%Y%m%d}.nc",
				},
			},
		},
	}

	result := ValidateStructural(esmFile)
	assert.True(t, result.Valid)
	assert.Empty(t, result.Messages)
}

// A data source still owes `kind` and `source.url_template`. What it no longer
// owes is a `variables` map: from esm 1.0.0 a source declares no fields at all,
// so the three per-variable checks that used to sit beside these have no subject.
func TestValidateDataSourceMissingRequiredFields(t *testing.T) {
	esmFile := &ESMFile{
		ESM: "0.1.0",
		Metadata: Metadata{
			Name:    "TestModel",
			Authors: []string{"Test Author"},
		},
		Models: map[string]Model{
			"TestModel": {
				Variables: map[string]ModelVariable{
					"x": {Type: "unknown"},
				},
				Equations: []Equation{
					{
						LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
						RHS: float64(1.0),
					},
				},
			},
		},
		DataSources: map[string]DataSource{
			"BadSource": {
				// Missing Kind and Source.URLTemplate.
			},
		},
	}

	result := ValidateStructural(esmFile)
	assert.False(t, result.Valid)

	// Expect errors for the missing kind and url_template.
	errorCount := 0
	for _, msg := range result.Messages {
		if msg.Level == "error" {
			errorCount++
		}
	}

	assert.GreaterOrEqual(t, errorCount, 2)
}

// Equation-unknown balance is UNKNOWNS vs EQUATIONS (esm-spec §4.9.4), not ODE
// states vs time-derivative equations. Since esm 1.0.0 it is also the only thing
// it could be: `unknown` is the declared type, and ODE-state-ness is derived
// from the very equations being counted (§6.3.1).
//
// An equation is credited whichever LHS form it takes — a derivative, a bare
// variable, or an arbitrary EXPRESSION — so an algebraic system is balanced by
// the same rule as a differential one.
func TestValidateEquationUnknownBalance(t *testing.T) {
	tests := []struct {
		name          string
		model         Model
		expectedValid bool
		expectedError string
	}{
		{
			name: "one unknown, one differential equation",
			model: Model{
				Variables: map[string]ModelVariable{
					"x": {Type: "unknown"},
				},
				Equations: []Equation{
					{LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")}, RHS: float64(1.0)},
				},
			},
			expectedValid: true,
		},
		{
			name: "two unknowns, two differential equations",
			model: Model{
				Variables: map[string]ModelVariable{
					"x": {Type: "unknown"},
					"y": {Type: "unknown"},
					"k": {Type: "parameter"},
				},
				Equations: []Equation{
					{LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
						RHS: ExprNode{Op: "*", Args: []any{"k", "y"}}},
					{LHS: ExprNode{Op: "D", Args: []any{"y"}, Wrt: strPtr("t")},
						RHS: ExprNode{Op: "*", Args: []any{"k", "x"}}},
				},
			},
			expectedValid: true,
		},
		{
			name: "an unknown with no defining equation is unbalanced",
			model: Model{
				Variables: map[string]ModelVariable{
					"x": {Type: "unknown"},
					"y": {Type: "unknown"},
				},
				Equations: []Equation{
					{LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")}, RHS: float64(1.0)},
				},
			},
			expectedValid: false,
			expectedError: "Number of equations (1) does not match number of unknowns (2)",
		},
		{
			name: "more equations than unknowns is unbalanced",
			model: Model{
				Variables: map[string]ModelVariable{
					"x": {Type: "unknown"},
					"k": {Type: "parameter"},
				},
				Equations: []Equation{
					{LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")}, RHS: float64(1.0)},
					{LHS: ExprNode{Op: "D", Args: []any{"k"}, Wrt: strPtr("t")}, RHS: float64(2.0)},
				},
			},
			expectedValid: false,
			expectedError: "Number of equations (2) does not match number of unknowns (1)",
		},
		{
			name: "equations but no unknowns at all",
			model: Model{
				Variables: map[string]ModelVariable{
					"k": {Type: "parameter"},
				},
				Equations: []Equation{
					{LHS: ExprNode{Op: "D", Args: []any{"k"}, Wrt: strPtr("t")}, RHS: float64(1.0)},
				},
			},
			expectedValid: false,
			expectedError: "Number of equations (1) does not match number of unknowns (0)",
		},
		{
			name: "a bare-variable (observed) equation counts",
			model: Model{
				Variables: map[string]ModelVariable{
					"x": {Type: "unknown"},
					"y": {Type: "unknown"},
				},
				Equations: []Equation{
					{LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")}, RHS: float64(1.0)},
					{LHS: "y", RHS: ExprNode{Op: "*", Args: []any{"x", 2.0}}},
				},
			},
			expectedValid: true,
		},
		{
			// The ISORROPIA shape: two unknowns determined by one bare-variable
			// equation and one EXPRESSION-LHS constraint. A checker that credits
			// only assignment-shaped LHSs reports "1 equation, 2 unknowns" and
			// rejects a perfectly balanced 2x2 system.
			name: "an expression-LHS algebraic constraint counts",
			model: Model{
				Variables: map[string]ModelVariable{
					"H":   {Type: "unknown"},
					"SO4": {Type: "unknown"},
					"Ksp": {Type: "parameter"},
				},
				Equations: []Equation{
					{LHS: "H", RHS: ExprNode{Op: "*", Args: []any{2.0, "SO4"}}},
					{LHS: ExprNode{Op: "*", Args: []any{"H", "H", "SO4"}}, RHS: "Ksp"},
				},
			},
			expectedValid: true,
		},
		{
			// An `ic` equation PRESCRIBES an initial value; it is not a
			// determining equation and must not inflate the count.
			name: "an ic equation does not count as an equation",
			model: Model{
				Variables: map[string]ModelVariable{
					"x": {Type: "unknown"},
				},
				Equations: []Equation{
					{LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")}, RHS: float64(1.0)},
					{LHS: ExprNode{Op: OpIC, Args: []any{"x"}}, RHS: float64(100.0)},
				},
			},
			expectedValid: true,
		},
		{
			// A Brownian noise source is a PARAMETER in 1.0.0, so it is not an
			// unknown and owes no equation — the balance is the ordinary one.
			name: "a wiener parameter is not an unknown",
			model: Model{
				Variables: map[string]ModelVariable{
					"x": {Type: "unknown"},
					"w": {Type: "parameter",
						Distribution: &Distribution{Kind: DistributionNormal, Mean: 0.0, Std: 1.0},
						Update:       ParameterUpdate{Kind: UpdateKindWiener}},
				},
				Equations: []Equation{
					{LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
						RHS: ExprNode{Op: "*", Args: []any{"x", "w"}}},
				},
			},
			expectedValid: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			esmFile := &ESMFile{
				ESM: "1.0.0",
				Metadata: Metadata{
					Name:    "TestModel",
					Authors: []string{"Test Author"},
				},
				Models: map[string]Model{
					"TestModel": tc.model,
				},
			}

			result := ValidateStructural(esmFile)
			assert.Equal(t, tc.expectedValid, result.Valid, "messages: %+v", result.Messages)
			if tc.expectedError != "" {
				found := false
				for _, msg := range result.Messages {
					if strings.Contains(msg.Message, tc.expectedError) {
						found = true
						break
					}
				}
				assert.True(t, found, "want %q among %+v", tc.expectedError, result.Messages)
			}
		})
	}
}

// `missing_equations_for` is the detail that preserves the discriminating power
// of the removed `missing_observed_expr`: it names exactly the unknowns that
// code used to name.
func TestEquationBalanceNamesUndefinedUnknowns(t *testing.T) {
	model := Model{
		Variables: map[string]ModelVariable{
			"x":     {Type: "unknown"},
			"y":     {Type: "unknown"},
			"total": {Type: "unknown"},
		},
		Equations: []Equation{
			{LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")}, RHS: float64(1.0)},
			{LHS: ExprNode{Op: "D", Args: []any{"y"}, Wrt: strPtr("t")}, RHS: float64(1.0)},
		},
	}
	s := &structuralScan{indep: DefaultIndepVar}
	s.validateEquationUnknownBalance("M", &model, "/models/M")
	require.Len(t, s.errors, 1)
	se := s.errors[0]
	assert.Equal(t, ErrorEquationCountMismatch, se.Code)
	assert.Equal(t, "/models/M", se.Path)
	assert.Equal(t, []string{"total", "x", "y"}, se.Details["unknowns"])
	assert.Equal(t, 2, se.Details["equations"])
	assert.Equal(t, []string{"total"}, se.Details["missing_equations_for"])
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
					"x": {"type": "unknown", "default": 0.0},
					"y": {"type": "unknown", "default": 0.0}
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

	result := Validate(esmFile)

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
				assert.Contains(t, err.Message, "does not match number of unknowns")
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
					"x": {"type": "unknown", "default": 0.0},
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

	result := Validate(esmFile)

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
					"total": {Type: "unknown"},
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
	// The reference is inside the aggregate body (`expr` sidecar), but the pointer
	// names the containing expression FIELD, not the leaf position: §7.1.2 carries
	// a reference-integrity defect at the equation `rhs`, and the shared corpus
	// (undefined_variable_in_aggregate_expr.esm) and TypeScript pin `/rhs`.
	assert.Equal(t, "/models/AggBody/equations/0/rhs", found.Path,
		"reference-integrity finding must point at the rhs field, not the aggregate-body leaf")
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
					"total": {Type: "unknown"},
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
					"x": {Type: "unknown", Units: strPtr("notaunit")},
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
			// The finding points at the VARIABLE, not its `units` scalar — §7.1.2
			// carries the defect on the declaration and the shared corpus pins the
			// promoted unit_parse_error at `/models/M/variables/<name>`.
			assert.Equal(t, "/models/BadUnit/variables/x", w.Path)
		}
		if strings.Contains(w.Message, "does not match") {
			sawMismatch = true
		}
	}
	assert.True(t, sawParseFinding, "unparseable unit must surface a finding: %+v", result.UnitWarnings)
	// ... the variable is treated as UNKNOWN, so no false mismatch is piled on ...
	assert.False(t, sawMismatch, "unknown-unit variable must not manufacture a dimension mismatch: %+v", result.UnitWarnings)

	// ... and it IS a hard error that invalidates the document. The code is
	// `unit_parse_error` — a unit string that denotes NO real unit — which the
	// shared corpus pins separately from `unit_inconsistency` (a provable
	// mismatch between two units that DO resolve); see
	// tests/invalid/unparseable_unit.esm.
	var sawHardError bool
	for _, se := range result.StructuralErrors {
		if se.Code == ErrorUnitParseError {
			sawHardError = true
			assert.Empty(t, se.Level, "a provable unit defect must be error-level, not a warning")
		}
	}
	assert.True(t, sawHardError, "unparseable unit must be a hard unit_parse_error: %+v", result.StructuralErrors)
	assert.False(t, result.Valid, "a file with an unreal unit is invalid")
}

// hasReservedError reports whether an ERROR-level structural error with the
// given code sits at the given JSON Pointer. Peer of hasStructuralError in
// units_fixtures_test.go, over the coded structural surface's error slice.
func hasReservedError(errs []StructuralError, code, path string) bool {
	for _, e := range errs {
		if e.Code == code && e.Path == path && e.Level == "" {
			return true
		}
	}
	return false
}

// TestReservedDeclarationNameIsRejected pins esm-spec §4.9.1.1: a DECLARATION
// spelled with a globally-scoped name — the document's independent variable or
// the §6.4 `_var` placeholder — is a hard `reserved_variable_name` error at the
// offending key.
//
// The declaration never wins. creditIndependentVariable puts the independent
// variable into scope BY NAME, ahead of the declaration maps, so the implicit
// symbol shadows the declaration rather than the other way round: the reported
// document (issue #200) validated clean, then handed every reader of `t` the
// simulation clock in place of a fuel time-lag constant.
func TestReservedDeclarationNameIsRejected(t *testing.T) {
	esmFile := &ESMFile{
		ESM:      "1.0.0",
		Metadata: Metadata{Name: "FuelMoistureProbe"},
		Models: map[string]Model{
			"FuelMoisture": {
				Variables: map[string]ModelVariable{
					"m":    {Type: "unknown", Units: strPtr("1")},
					"t":    {Type: "unknown", Units: strPtr("s")},
					"_var": {Type: "parameter", Units: strPtr("1")},
					"tau":  {Type: "parameter", Units: strPtr("s")},
				},
				Equations: []Equation{
					{LHS: ExprNode{Op: "D", Args: []any{"m"}, Wrt: strPtr("t")}, RHS: "m"},
					{LHS: "t", RHS: "tau"},
				},
			},
		},
	}

	result := ValidateStructuralWithCodes(esmFile)

	assert.False(t, result.Valid, "a document declaring the independent variable is invalid")
	assert.True(t,
		hasReservedError(result.StructuralErrors, ErrorReservedVariableName, "/models/FuelMoisture/variables/t"),
		"want reserved_variable_name @ /models/FuelMoisture/variables/t, got %+v",
		result.StructuralErrors)
	assert.True(t,
		hasReservedError(result.StructuralErrors, ErrorReservedVariableName, "/models/FuelMoisture/variables/_var"),
		"want reserved_variable_name @ /models/FuelMoisture/variables/_var, got %+v",
		result.StructuralErrors)
	for _, se := range result.StructuralErrors {
		if se.Code == ErrorReservedVariableName && se.Path == "/models/FuelMoisture/variables/t" {
			assert.Equal(t, "independent_variable", se.Details["reserved_as"])
		}
	}
}

// TestReservedDeclarationNameCoversReactionSystems pins that a species and a
// reaction parameter are held to the same rule: both become symbols of the
// derived ODE system exactly as a `variables` entry does (esm-spec §7.4).
func TestReservedDeclarationNameCoversReactionSystems(t *testing.T) {
	esmFile := &ESMFile{
		ESM:      "1.0.0",
		Metadata: Metadata{Name: "ReactionProbe"},
		ReactionSystems: map[string]ReactionSystem{
			"R": {
				Species: map[string]Species{
					"t": {Units: strPtr("mol/mol")},
					"P": {Units: strPtr("mol/mol")},
				},
				Parameters: map[string]Parameter{"t": {Units: strPtr("K")}},
				Reactions: []Reaction{{
					ID:         "R1",
					Substrates: []SubstrateProduct{{Species: "t", Stoichiometry: 1}},
					Products:   []SubstrateProduct{{Species: "P", Stoichiometry: 1}},
					Rate:       1.0,
				}},
			},
		},
	}

	result := ValidateStructuralWithCodes(esmFile)

	assert.True(t,
		hasReservedError(result.StructuralErrors, ErrorReservedVariableName, "/reaction_systems/R/species/t"),
		"want reserved_variable_name @ /reaction_systems/R/species/t, got %+v",
		result.StructuralErrors)
	assert.True(t,
		hasReservedError(result.StructuralErrors, ErrorReservedVariableName, "/reaction_systems/R/parameters/t"),
		"want reserved_variable_name @ /reaction_systems/R/parameters/t, got %+v",
		result.StructuralErrors)
}

// TestReservedDeclarationNameFollowsTheDocument pins that the reserved set is
// `domain.independent_variable`, not the literal "t". Renaming the independent
// variable MOVES the rejection onto the new name and FREES `t`, which is then
// an ordinary name — the same contract the sibling `reserved_index_symbol`
// binder rule follows, both reading their reserved set from §4.9.1.1.
func TestReservedDeclarationNameFollowsTheDocument(t *testing.T) {
	build := func(declared string) *ESMFile {
		return &ESMFile{
			ESM:      "1.0.0",
			Metadata: Metadata{Name: "Renamed"},
			Domain:   &Domain{IndependentVariable: strPtr("s")},
			Models: map[string]Model{
				"M": {
					SystemKind: strPtr(SystemKindNonlinear),
					Variables: map[string]ModelVariable{
						"y":      {Type: "unknown", Units: strPtr("1")},
						declared: {Type: "parameter", Units: strPtr("K")},
					},
					Equations: []Equation{{LHS: "y", RHS: 1.0}},
				},
			},
		}
	}

	renamed := ValidateStructuralWithCodes(build("s"))
	assert.True(t,
		hasReservedError(renamed.StructuralErrors, ErrorReservedVariableName, "/models/M/variables/s"),
		"the rename must move the rejection onto 's': %+v", renamed.StructuralErrors)

	freed := ValidateStructuralWithCodes(build("t"))
	for _, se := range freed.StructuralErrors {
		assert.NotEqual(t, ErrorReservedVariableName, se.Code,
			"renaming the independent variable frees 't': %+v", freed.StructuralErrors)
	}
}
