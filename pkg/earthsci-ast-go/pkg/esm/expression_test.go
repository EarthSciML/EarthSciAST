package esm

import (
	"math"
	"reflect"
	"testing"
)

func TestFreeVariables(t *testing.T) {
	tests := []struct {
		name     string
		expr     Expression
		expected map[string]bool
	}{
		{
			name:     "number literal",
			expr:     5.0,
			expected: map[string]bool{},
		},
		{
			name:     "single variable",
			expr:     "x",
			expected: map[string]bool{"x": true},
		},
		{
			name: "addition with variables",
			expr: ExprNode{
				Op:   "+",
				Args: []interface{}{"x", "y"},
			},
			expected: map[string]bool{"x": true, "y": true},
		},
		{
			name: "complex expression",
			expr: ExprNode{
				Op: "*",
				Args: []interface{}{
					ExprNode{Op: "+", Args: []interface{}{"x", 1.0}},
					"y",
				},
			},
			expected: map[string]bool{"x": true, "y": true},
		},
		{
			name: "derivative with wrt",
			expr: ExprNode{
				Op:   "D",
				Args: []interface{}{"x"},
				Wrt:  stringPtr("t"),
			},
			expected: map[string]bool{"x": true, "t": true},
		},
		{
			name: "gradient with dim",
			expr: ExprNode{
				Op:   "grad",
				Args: []interface{}{"u"},
				Dim:  stringPtr("x"),
			},
			expected: map[string]bool{"u": true, "x": true},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := FreeVariables(tt.expr)
			if !reflect.DeepEqual(result, tt.expected) {
				t.Errorf("FreeVariables() = %v, expected %v", result, tt.expected)
			}
		})
	}
}

func TestContains(t *testing.T) {
	expr := ExprNode{
		Op: "*",
		Args: []interface{}{
			ExprNode{Op: "+", Args: []interface{}{"x", 1.0}},
			"y",
		},
	}

	tests := []struct {
		varName  string
		expected bool
	}{
		{"x", true},
		{"y", true},
		{"z", false},
	}

	for _, tt := range tests {
		t.Run(tt.varName, func(t *testing.T) {
			result := Contains(expr, tt.varName)
			if result != tt.expected {
				t.Errorf("Contains(%s) = %v, expected %v", tt.varName, result, tt.expected)
			}
		})
	}
}

func TestSimplify(t *testing.T) {
	tests := []struct {
		name     string
		expr     Expression
		expected Expression
	}{
		{
			name:     "number literal unchanged",
			expr:     5.0,
			expected: 5.0,
		},
		{
			name:     "variable unchanged",
			expr:     "x",
			expected: "x",
		},
		{
			name: "constant addition",
			expr: ExprNode{Op: "+", Args: []interface{}{2.0, 3.0}},
			expected: 5.0,
		},
		{
			name: "addition with zero",
			expr: ExprNode{Op: "+", Args: []interface{}{"x", 0.0}},
			expected: "x",
		},
		{
			name: "zero plus variable",
			expr: ExprNode{Op: "+", Args: []interface{}{0.0, "x"}},
			expected: "x",
		},
		{
			name: "addition all zeros",
			expr: ExprNode{Op: "+", Args: []interface{}{0.0, 0.0, 0.0}},
			expected: 0.0,
		},
		{
			name: "multiplication with one",
			expr: ExprNode{Op: "*", Args: []interface{}{"x", 1.0}},
			expected: "x",
		},
		{
			name: "multiplication with zero",
			expr: ExprNode{Op: "*", Args: []interface{}{"x", 0.0}},
			expected: 0.0,
		},
		{
			name: "constant multiplication",
			expr: ExprNode{Op: "*", Args: []interface{}{2.0, 3.0}},
			expected: 6.0,
		},
		{
			name: "subtraction with zero",
			expr: ExprNode{Op: "-", Args: []interface{}{"x", 0.0}},
			expected: "x",
		},
		{
			name: "constant subtraction",
			expr: ExprNode{Op: "-", Args: []interface{}{5.0, 2.0}},
			expected: 3.0,
		},
		{
			name: "division by one",
			expr: ExprNode{Op: "/", Args: []interface{}{"x", 1.0}},
			expected: "x",
		},
		{
			name: "zero divided by something",
			expr: ExprNode{Op: "/", Args: []interface{}{0.0, "x"}},
			expected: 0.0,
		},
		{
			name: "constant division",
			expr: ExprNode{Op: "/", Args: []interface{}{6.0, 2.0}},
			expected: 3.0,
		},
		{
			name: "power of zero",
			expr: ExprNode{Op: "^", Args: []interface{}{"x", 0.0}},
			expected: 1.0,
		},
		{
			name: "power of one",
			expr: ExprNode{Op: "^", Args: []interface{}{"x", 1.0}},
			expected: "x",
		},
		{
			name: "one to any power",
			expr: ExprNode{Op: "^", Args: []interface{}{1.0, "x"}},
			expected: 1.0,
		},
		{
			name: "zero to positive power",
			expr: ExprNode{Op: "^", Args: []interface{}{0.0, 2.0}},
			expected: 0.0,
		},
		{
			name: "constant exponentiation",
			expr: ExprNode{Op: "^", Args: []interface{}{2.0, 3.0}},
			expected: 8.0,
		},
		{
			name: "nested simplification",
			expr: ExprNode{
				Op: "+",
				Args: []interface{}{
					ExprNode{Op: "*", Args: []interface{}{"x", 1.0}}, // simplifies to x
					0.0, // removed
				},
			},
			expected: "x",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := Simplify(tt.expr)
			if !reflect.DeepEqual(result, tt.expected) {
				t.Errorf("Simplify() = %v, expected %v", result, tt.expected)
			}
		})
	}
}

func TestEvaluate(t *testing.T) {
	bindings := map[string]float64{
		"x": 2.0,
		"y": 3.0,
		"z": 4.0,
	}

	tests := []struct {
		name      string
		expr      Expression
		expected  float64
		expectErr bool
	}{
		{
			name:     "number literal",
			expr:     5.0,
			expected: 5.0,
		},
		{
			name:     "integer literal",
			expr:     5,
			expected: 5.0,
		},
		{
			name:     "variable lookup",
			expr:     "x",
			expected: 2.0,
		},
		{
			name:      "unbound variable",
			expr:      "unknown",
			expectErr: true,
		},
		{
			name: "addition",
			expr: ExprNode{Op: "+", Args: []interface{}{"x", "y"}},
			expected: 5.0,
		},
		{
			name: "subtraction",
			expr: ExprNode{Op: "-", Args: []interface{}{"x", "y"}},
			expected: -1.0,
		},
		{
			name: "unary minus",
			expr: ExprNode{Op: "-", Args: []interface{}{"x"}},
			expected: -2.0,
		},
		{
			name: "multiplication",
			expr: ExprNode{Op: "*", Args: []interface{}{"x", "y"}},
			expected: 6.0,
		},
		{
			name: "division",
			expr: ExprNode{Op: "/", Args: []interface{}{"y", "x"}},
			expected: 1.5,
		},
		{
			name:      "division by zero",
			expr:      ExprNode{Op: "/", Args: []interface{}{"x", 0.0}},
			expectErr: true,
		},
		{
			name: "exponentiation",
			expr: ExprNode{Op: "^", Args: []interface{}{"x", "y"}},
			expected: 8.0, // 2^3
		},
		{
			name: "exponential function",
			expr: ExprNode{Op: "exp", Args: []interface{}{1.0}},
			expected: math.E,
		},
		{
			name: "natural logarithm",
			expr: ExprNode{Op: "log", Args: []interface{}{math.E}},
			expected: 1.0,
		},
		{
			name:      "log of non-positive",
			expr:      ExprNode{Op: "log", Args: []interface{}{0.0}},
			expectErr: true,
		},
		{
			name: "square root",
			expr: ExprNode{Op: "sqrt", Args: []interface{}{4.0}},
			expected: 2.0,
		},
		{
			name:      "sqrt of negative",
			expr:      ExprNode{Op: "sqrt", Args: []interface{}{-1.0}},
			expectErr: true,
		},
		{
			name: "absolute value",
			expr: ExprNode{Op: "abs", Args: []interface{}{-3.0}},
			expected: 3.0,
		},
		{
			name: "sine",
			expr: ExprNode{Op: "sin", Args: []interface{}{0.0}},
			expected: 0.0,
		},
		{
			name: "cosine",
			expr: ExprNode{Op: "cos", Args: []interface{}{0.0}},
			expected: 1.0,
		},
		{
			name: "tangent",
			expr: ExprNode{Op: "tan", Args: []interface{}{0.0}},
			expected: 0.0,
		},
		{
			name: "sign positive",
			expr: ExprNode{Op: "sign", Args: []interface{}{5.0}},
			expected: 1.0,
		},
		{
			name: "sign negative",
			expr: ExprNode{Op: "sign", Args: []interface{}{-5.0}},
			expected: -1.0,
		},
		{
			name: "sign zero",
			expr: ExprNode{Op: "sign", Args: []interface{}{0.0}},
			expected: 0.0,
		},
		{
			name: "complex expression",
			expr: ExprNode{
				Op: "+",
				Args: []interface{}{
					ExprNode{Op: "*", Args: []interface{}{"x", "y"}}, // 2 * 3 = 6
					1.0,
				},
			},
			expected: 7.0,
		},
		{
			name: "n-ary addition",
			expr: ExprNode{Op: "+", Args: []interface{}{"x", "y", "z"}},
			expected: 9.0, // 2 + 3 + 4
		},
		{
			name: "n-ary multiplication",
			expr: ExprNode{Op: "*", Args: []interface{}{"x", "y", 2.0}},
			expected: 12.0, // 2 * 3 * 2
		},
		// n-ary min/max (esm-spec §4.2 — arity ≥ 2; esm-2is)
		{
			name:     "n-ary min",
			expr:     ExprNode{Op: "min", Args: []interface{}{"x", "y", "z"}},
			expected: 2.0, // min(2, 3, 4)
		},
		{
			name:     "n-ary max",
			expr:     ExprNode{Op: "max", Args: []interface{}{"x", "y", "z"}},
			expected: 4.0, // max(2, 3, 4)
		},
		{
			name:     "binary min",
			expr:     ExprNode{Op: "min", Args: []interface{}{"x", 5.0}},
			expected: 2.0,
		},
		{
			name:     "binary max",
			expr:     ExprNode{Op: "max", Args: []interface{}{"x", 5.0}},
			expected: 5.0,
		},
		{
			name:      "min single arg rejected",
			expr:      ExprNode{Op: "min", Args: []interface{}{"x"}},
			expectErr: true,
		},
		{
			name:      "max single arg rejected",
			expr:      ExprNode{Op: "max", Args: []interface{}{"x"}},
			expectErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result, err := Evaluate(tt.expr, bindings)

			if tt.expectErr {
				if err == nil {
					t.Errorf("Evaluate() expected error but got none")
				}
				return
			}

			if err != nil {
				t.Errorf("Evaluate() unexpected error: %v", err)
				return
			}

			if math.Abs(result-tt.expected) > 1e-10 {
				t.Errorf("Evaluate() = %v, expected %v", result, tt.expected)
			}
		})
	}
}

// Helper function for tests
func stringPtr(s string) *string {
	return &s
}
