package esm

import (
	"testing"
	"time"

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
	model := Model{
		Variables: map[string]ModelVariable{
			"x": {
				Type: "state",
			},
			"y": {
				Type:       "observed",
				Expression: ExprNode{Op: "+", Args: []any{"x", "k"}},
			},
		},
		Equations: []Equation{
			{
				LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")},
				RHS: ExprNode{Op: "*", Args: []any{"k", "x"}},
			},
		},
	}

	bindings := map[string]Expression{"k": 0.1}

	result, err := SubstituteInModel(model, bindings)
	assert.NoError(t, err)

	// Check equation substitution
	expectedEqRHS := ExprNode{Op: "*", Args: []any{0.1, "x"}}
	assert.Equal(t, expectedEqRHS, result.Equations[0].RHS)

	// Check observed variable expression substitution
	expectedObsExpr := ExprNode{Op: "+", Args: []any{"x", 0.1}}
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

	// The result should have 'rate' replaced with the complex expression
	// and 'T' within that expression should be substituted with 298.15
	expected := ExprNode{
		Op: "*",
		Args: []any{
			ExprNode{
				Op:   "exp",
				Args: []any{ExprNode{Op: "/", Args: []any{-1000, 298.15}}},
			},
			"concentration",
		},
	}

	assert.Equal(t, expected, result)
}

// A cyclic binding (x → f(x)) must not stack-overflow: cycle detection halts
// the recursion and returns a SubstitutionError instead of panicking or looping.
func TestSubstituteCyclicBindingErrors(t *testing.T) {
	bindings := map[string]Expression{
		"x": ExprNode{Op: "f", Args: []any{"x"}},
	}
	type res struct {
		out Expression
		err error
	}
	done := make(chan res, 1)
	go func() {
		out, err := Substitute("x", bindings) // must return, not crash or hang
		done <- res{out, err}
	}()
	select {
	case r := <-done:
		var se *SubstitutionError
		require.ErrorAs(t, r.err, &se, "cyclic binding must surface a SubstitutionError")
		assert.Equal(t, codeCyclicSubstitution, se.DiagnosticCode())
	case <-time.After(10 * time.Second):
		t.Fatal("Substitute did not terminate on a cyclic binding")
	}
}

// A transitive cycle (x → y, y → x) is detected the same way.
func TestSubstituteTransitiveCycleErrors(t *testing.T) {
	bindings := map[string]Expression{
		"x": ExprNode{Op: "+", Args: []any{"y", 1.0}},
		"y": ExprNode{Op: "+", Args: []any{"x", 1.0}},
	}
	_, err := Substitute("x", bindings)
	var se *SubstitutionError
	require.ErrorAs(t, err, &se)
}

// A binding whose replacement mentions a variable twice in sibling positions
// (not its own key) substitutes cleanly without a false-positive cycle.
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
