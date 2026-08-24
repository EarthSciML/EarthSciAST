package esm

import (
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
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
			result, err := Substitute(tt.input, tt.bindings)
			assert.NoError(t, err)
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
				Args: []any{"x", "y"},
			},
			bindings: map[string]Expression{"x": 5.0},
			expected: ExprNode{
				Op:   "+",
				Args: []any{5.0, "y"},
			},
		},
		{
			name: "substitute multiple variables",
			input: ExprNode{
				Op:   "*",
				Args: []any{"k", "T"},
			},
			bindings: map[string]Expression{"T": 298.15},
			expected: ExprNode{
				Op:   "*",
				Args: []any{"k", 298.15},
			},
		},
		{
			name: "substitute in nested expression",
			input: ExprNode{
				Op: "exp",
				Args: []any{
					ExprNode{
						Op:   "/",
						Args: []any{-1370, "T"},
					},
				},
			},
			bindings: map[string]Expression{"T": 298.15},
			expected: ExprNode{
				Op: "exp",
				Args: []any{
					ExprNode{
						Op:   "/",
						Args: []any{-1370, 298.15},
					},
				},
			},
		},
		{
			name: "substitute in derivative",
			input: ExprNode{
				Op:   "D",
				Args: []any{"_var"},
				Wrt:  strPtr("t"),
			},
			bindings: map[string]Expression{"_var": "O3"},
			expected: ExprNode{
				Op:   "D",
				Args: []any{"O3"},
				Wrt:  strPtr("t"),
			},
		},
		{
			name: "substitute all variables",
			input: ExprNode{
				Op:   "+",
				Args: []any{"a", "b", "c"},
			},
			bindings: map[string]Expression{"a": 1.0, "c": 3.0},
			expected: ExprNode{
				Op:   "+",
				Args: []any{1.0, "b", 3.0},
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := Substitute(tt.input, tt.bindings)
			assert.NoError(t, err)
			assert.Equal(t, tt.expected, result)
		})
	}
}

func TestSubstituteRecursive(t *testing.T) {
	input := ExprNode{
		Op: "*",
		Args: []any{
			"x",
			ExprNode{
				Op:   "+",
				Args: []any{"x", 1},
			},
		},
	}

	bindings := map[string]Expression{"x": 2.0}

	expected := ExprNode{
		Op: "*",
		Args: []any{
			2.0,
			ExprNode{
				Op:   "+",
				Args: []any{2.0, 1},
			},
		},
	}

	result, err := Substitute(input, bindings)
	assert.NoError(t, err)
	assert.Equal(t, expected, result)
}

func TestSubstituteInEquation(t *testing.T) {
	eq := Equation{
		LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
		RHS: ExprNode{Op: "*", Args: []any{"k", "x"}},
	}

	bindings := map[string]Expression{"k": 0.5}

	expected := Equation{
		LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
		RHS: ExprNode{Op: "*", Args: []any{0.5, "x"}},
	}

	result, err := SubstituteInEquation(eq, bindings)
	assert.NoError(t, err)
	assert.Equal(t, expected, result)
}

func TestSubstituteInAffectEquation(t *testing.T) {
	affect := AffectEquation{
		LHS: "x",
		RHS: ExprNode{Op: "+", Args: []any{"y", 1}},
	}

	bindings := map[string]Expression{"y": 5.0}

	expected := AffectEquation{
		LHS: "x", // LHS should not change
		RHS: ExprNode{Op: "+", Args: []any{5.0, 1}},
	}

	result, err := SubstituteInAffectEquation(affect, bindings)
	assert.NoError(t, err)
	assert.Equal(t, expected, result)
}

func TestSubstituteInModel(t *testing.T) {
	// `y` is an observed unknown; its definition is an EQUATION from esm 1.0.0,
	// and `p` is a parameter whose `update` carries the remaining Expression
	// positions a variable can hold.
	model := Model{
		Variables: map[string]ModelVariable{
			"x": {Type: "unknown"},
			"y": {Type: "unknown"},
			"p": {
				Type: "parameter",
				Update: ParameterUpdate{
					Kind:       UpdateKindCondition,
					When:       ExprNode{Op: ">", Args: []any{"x", "k"}},
					Expression: ExprNode{Op: "*", Args: []any{"k", 2.0}},
				},
			},
		},
		Equations: []Equation{
			{
				LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
				RHS: ExprNode{Op: "*", Args: []any{"k", "x"}},
			},
			{
				LHS: "y",
				RHS: ExprNode{Op: "+", Args: []any{"x", "k"}},
			},
		},
	}

	bindings := map[string]Expression{"k": 0.1}

	result, err := SubstituteInModel(model, bindings)
	assert.NoError(t, err)

	// Check equation substitution
	expectedEqRHS := ExprNode{Op: "*", Args: []any{0.1, "x"}}
	assert.Equal(t, expectedEqRHS, result.Equations[0].RHS)

	// The observed unknown's DEFINING EQUATION is substituted along with the
	// rest — it is an ordinary equation now.
	def, ok := ObservedDefinition(&result, "y")
	assert.True(t, ok, "y should still have a defining equation")
	assert.Equal(t, ExprNode{Op: "+", Args: []any{"x", 0.1}}, def)

	// Both Expression positions of the parameter update are substituted.
	rules := result.Variables["p"].UpdateRules()
	assert.Len(t, rules, 1)
	assert.Equal(t, ExprNode{Op: ">", Args: []any{"x", 0.1}}, rules[0].When)
	assert.Equal(t, ExprNode{Op: "*", Args: []any{0.1, 2.0}}, rules[0].Expression)
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
				Rate:       ExprNode{Op: "*", Args: []any{"k1", "temperature"}},
			},
		},
	}

	bindings := map[string]Expression{"temperature": 298.15}

	result, err := SubstituteInReactionSystem(system, bindings)
	assert.NoError(t, err)

	expectedRate := ExprNode{Op: "*", Args: []any{"k1", 298.15}}
	assert.Equal(t, expectedRate, result.Reactions[0].Rate)
}

func TestPartialSubstitute(t *testing.T) {
	input := ExprNode{
		Op:   "+",
		Args: []any{"a", "b", "c"},
	}

	bindings := map[string]Expression{
		"a": 1.0,
		"b": 2.0,
		"c": 3.0,
	}

	keepSymbolic := []string{"b"} // Keep 'b' as symbolic

	expected := ExprNode{
		Op:   "+",
		Args: []any{1.0, "b", 3.0}, // 'b' should remain as variable
	}

	result, err := PartialSubstitute(input, bindings, keepSymbolic)
	assert.NoError(t, err)
	assert.Equal(t, expected, result)
}

func TestSubstituteWithComplexExpressionAsReplacement(t *testing.T) {
	input := ExprNode{
		Op:   "*",
		Args: []any{"rate", "concentration"},
	}

	complexExpr := ExprNode{
		Op:   "exp",
		Args: []any{ExprNode{Op: "/", Args: []any{-1000, "T"}}},
	}

	bindings := map[string]Expression{
		"rate": complexExpr,
		"T":    298.15,
	}

	result, err := Substitute(input, bindings)
	assert.NoError(t, err)

	// 'rate' is replaced with the complex expression VERBATIM. The "T" inside
	// that replacement is NOT substituted, even though the bindings also bind
	// "T": substitution is single-pass (CONFORMANCE_SPEC.md §2.2.3 rule 1), so a
	// binding applies to the variables of the INPUT, never to the variables of a
	// replacement it just inserted. The "T" binding has no occurrence to act on
	// here because the input mentions only "rate" and "concentration".
	expected := ExprNode{
		Op: "*",
		Args: []any{
			ExprNode{
				Op:   "exp",
				Args: []any{ExprNode{Op: "/", Args: []any{-1000, "T"}}},
			},
			"concentration",
		},
	}

	assert.Equal(t, expected, result)
}

// A self-referential binding {x -> f(x)} is NOT an error. Substitution is
// single-pass (CONFORMANCE_SPEC.md §2.2.3 rule 1): the replacement is inserted
// verbatim and never re-substituted, so the walk terminates on its own and the
// inner "x" survives.
func TestSubstituteSelfReferentialBindingIsSinglePass(t *testing.T) {
	bindings := map[string]Expression{
		"x": ExprNode{Op: "f", Args: []any{"x"}},
	}
	out, err := Substitute("x", bindings)
	require.NoError(t, err)
	assert.Equal(t, ExprNode{Op: "f", Args: []any{"x"}}, out)
}

// A mutually-referential binding set {x -> y, y -> x} is likewise not an
// error: substituting "x" yields "y", exactly as the normative contract spells
// out. This is what makes a binding map usable as a simultaneous SWAP rename.
func TestSubstituteMutuallyReferentialBindingIsSinglePass(t *testing.T) {
	bindings := map[string]Expression{
		"x": "y",
		"y": "x",
	}
	out, err := Substitute("x", bindings)
	require.NoError(t, err)
	assert.Equal(t, "y", out)
}

// A chained binding set {a -> b, b -> c} renames a to b — NOT to c. Transitive
// expansion here would silently corrupt every chained rename that goes through
// renameRawExpr (edit.go).
func TestSubstituteChainedBindingIsNotTransitive(t *testing.T) {
	bindings := map[string]Expression{
		"a": "b",
		"b": "c",
	}
	out, err := Substitute("a", bindings)
	require.NoError(t, err)
	assert.Equal(t, "b", out)
}

// A binding whose replacement mentions a variable twice in sibling positions
// (not its own key) substitutes cleanly.
func TestSubstituteRepeatedVariableNotACycle(t *testing.T) {
	bindings := map[string]Expression{
		"x": ExprNode{Op: "*", Args: []any{"a", "a"}}, // a appears twice, no cycle
	}
	out, err := Substitute("x", bindings)
	require.NoError(t, err)
	assert.Equal(t, ExprNode{Op: "*", Args: []any{"a", "a"}}, out)
}

func TestSubstituteWithDerivativeWrtParameter(t *testing.T) {
	input := ExprNode{
		Op:   "D",
		Args: []any{"x"},
		Wrt:  strPtr("time_var"),
	}

	bindings := map[string]Expression{
		"time_var": "t",
	}

	result, err := Substitute(input, bindings)
	assert.NoError(t, err)

	expected := ExprNode{
		Op:   "D",
		Args: []any{"x"},
		Wrt:  strPtr("t"),
	}

	assert.Equal(t, expected, result)
}
