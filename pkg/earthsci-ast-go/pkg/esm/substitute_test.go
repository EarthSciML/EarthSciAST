package esm

import (
	"testing"

	"github.com/stretchr/testify/assert"
)

func TestSubstituteSimpleVariable(t *testing.T) {
	tests := []struct {
		name     string
		input    Expression
		bindings map[string]Expression
		expected Expression
	}{
		{
			name:     "substitute string variable with number",
			input:    "x",
			bindings: map[string]Expression{"x": 5.0},
			expected: 5.0,
		},
		{
			name:     "substitute string variable with string",
			input:    "old_var",
			bindings: map[string]Expression{"old_var": "new_var"},
			expected: "new_var",
		},
		{
			name:     "no substitution needed",
			input:    "y",
			bindings: map[string]Expression{"x": 5.0},
			expected: "y",
		},
		{
			name:     "number literal unchanged",
			input:    42.0,
			bindings: map[string]Expression{"x": 5.0},
			expected: 42.0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := Substitute(tt.input, tt.bindings)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestSubstituteExprNode(t *testing.T) {
	tests := []struct {
		name     string
		input    Expression
		bindings map[string]Expression
		expected Expression
	}{
		{
			name: "substitute in addition",
			input: ExprNode{
				Op:   "+",
				Args: []interface{}{"x", "y"},
			},
			bindings: map[string]Expression{"x": 5.0},
			expected: ExprNode{
				Op:   "+",
				Args: []interface{}{5.0, "y"},
			},
		},
		{
			name: "substitute multiple variables",
			input: ExprNode{
				Op:   "*",
				Args: []interface{}{"k", "T"},
			},
			bindings: map[string]Expression{"T": 298.15},
			expected: ExprNode{
				Op:   "*",
				Args: []interface{}{"k", 298.15},
			},
		},
		{
			name: "substitute in nested expression",
			input: ExprNode{
				Op: "exp",
				Args: []interface{}{
					ExprNode{
						Op:   "/",
						Args: []interface{}{-1370, "T"},
					},
				},
			},
			bindings: map[string]Expression{"T": 298.15},
			expected: ExprNode{
				Op: "exp",
				Args: []interface{}{
					ExprNode{
						Op:   "/",
						Args: []interface{}{-1370, 298.15},
					},
				},
			},
		},
		{
			name: "substitute in derivative",
			input: ExprNode{
				Op:   "D",
				Args: []interface{}{"_var"},
				Wrt:  strPtr("t"),
			},
			bindings: map[string]Expression{"_var": "O3"},
			expected: ExprNode{
				Op:   "D",
				Args: []interface{}{"O3"},
				Wrt:  strPtr("t"),
			},
		},
		{
			name: "substitute all variables",
			input: ExprNode{
				Op:   "+",
				Args: []interface{}{"a", "b", "c"},
			},
			bindings: map[string]Expression{"a": 1.0, "c": 3.0},
			expected: ExprNode{
				Op:   "+",
				Args: []interface{}{1.0, "b", 3.0},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := Substitute(tt.input, tt.bindings)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestSubstituteRecursive(t *testing.T) {
	input := ExprNode{
		Op: "*",
		Args: []interface{}{
			"x",
			ExprNode{
				Op:   "+",
				Args: []interface{}{"x", 1},
			},
		},
	}

	bindings := map[string]Expression{"x": 2.0}

	expected := ExprNode{
		Op: "*",
		Args: []interface{}{
			2.0,
			ExprNode{
				Op:   "+",
				Args: []interface{}{2.0, 1},
			},
		},
	}

	result := Substitute(input, bindings)
	assert.Equal(t, expected, result)
}

func TestSubstituteInEquation(t *testing.T) {
	eq := Equation{
		LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
		RHS: ExprNode{Op: "*", Args: []interface{}{"k", "x"}},
	}

	bindings := map[string]Expression{"k": 0.5}

	expected := Equation{
		LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
		RHS: ExprNode{Op: "*", Args: []interface{}{0.5, "x"}},
	}

	result := SubstituteInEquation(eq, bindings)
	assert.Equal(t, expected, result)
}

func TestSubstituteInAffectEquation(t *testing.T) {
	affect := AffectEquation{
		LHS: "x",
		RHS: ExprNode{Op: "+", Args: []interface{}{"y", 1}},
	}

	bindings := map[string]Expression{"y": 5.0}

	expected := AffectEquation{
		LHS: "x", // LHS should not change
		RHS: ExprNode{Op: "+", Args: []interface{}{5.0, 1}},
	}

	result := SubstituteInAffectEquation(affect, bindings)
	assert.Equal(t, expected, result)
}

func TestSubstituteInModel(t *testing.T) {
	model := Model{
		Variables: map[string]ModelVariable{
			"x": {
				Type: "state",
			},
			"y": {
				Type:       "observed",
				Expression: ExprNode{Op: "+", Args: []interface{}{"x", "k"}},
			},
		},
		Equations: []Equation{
			{
				LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")},
				RHS: ExprNode{Op: "*", Args: []interface{}{"k", "x"}},
			},
		},
	}

	bindings := map[string]Expression{"k": 0.1}

	result := SubstituteInModel(model, bindings)

	// Check equation substitution
	expectedEqRHS := ExprNode{Op: "*", Args: []interface{}{0.1, "x"}}
	assert.Equal(t, expectedEqRHS, result.Equations[0].RHS)

	// Check observed variable expression substitution
	expectedObsExpr := ExprNode{Op: "+", Args: []interface{}{"x", 0.1}}
	assert.Equal(t, expectedObsExpr, result.Variables["y"].Expression)
}

func TestSubstituteInReactionSystem(t *testing.T) {
	system := ReactionSystem{
		Species: map[string]Species{
			"A": {},
			"B": {},
		},
		Parameters: map[string]Parameter{
			"k1": {},
		},
		Reactions: []Reaction{
			{
				ID:         "R1",
				Substrates: []SubstrateProduct{{Species: "A", Stoichiometry: 1}},
				Products:   []SubstrateProduct{{Species: "B", Stoichiometry: 1}},
				Rate:       ExprNode{Op: "*", Args: []interface{}{"k1", "temperature"}},
			},
		},
	}

	bindings := map[string]Expression{"temperature": 298.15}

	result := SubstituteInReactionSystem(system, bindings)

	expectedRate := ExprNode{Op: "*", Args: []interface{}{"k1", 298.15}}
	assert.Equal(t, expectedRate, result.Reactions[0].Rate)
}

func TestPartialSubstitute(t *testing.T) {
	input := ExprNode{
		Op:   "+",
		Args: []interface{}{"a", "b", "c"},
	}

	bindings := map[string]Expression{
		"a": 1.0,
		"b": 2.0,
		"c": 3.0,
	}

	keepSymbolic := []string{"b"} // Keep 'b' as symbolic

	expected := ExprNode{
		Op:   "+",
		Args: []interface{}{1.0, "b", 3.0}, // 'b' should remain as variable
	}

	result := PartialSubstitute(input, bindings, keepSymbolic)
	assert.Equal(t, expected, result)
}

func TestSubstituteWithComplexExpressionAsReplacement(t *testing.T) {
	input := ExprNode{
		Op:   "*",
		Args: []interface{}{"rate", "concentration"},
	}

	complexExpr := ExprNode{
		Op:   "exp",
		Args: []interface{}{ExprNode{Op: "/", Args: []interface{}{-1000, "T"}}},
	}

	bindings := map[string]Expression{
		"rate": complexExpr,
		"T":    298.15,
	}

	result := Substitute(input, bindings)

	// The result should have 'rate' replaced with the complex expression
	// and 'T' within that expression should be substituted with 298.15
	expected := ExprNode{
		Op: "*",
		Args: []interface{}{
			ExprNode{
				Op:   "exp",
				Args: []interface{}{ExprNode{Op: "/", Args: []interface{}{-1000, 298.15}}},
			},
			"concentration",
		},
	}

	assert.Equal(t, expected, result)
}

func TestSubstituteWithDerivativeWrtParameter(t *testing.T) {
	input := ExprNode{
		Op:   "D",
		Args: []interface{}{"x"},
		Wrt:  strPtr("time_var"),
	}

	bindings := map[string]Expression{
		"time_var": "t",
	}

	result := Substitute(input, bindings)

	expected := ExprNode{
		Op:   "D",
		Args: []interface{}{"x"},
		Wrt:  strPtr("t"),
	}

	assert.Equal(t, expected, result)
}
