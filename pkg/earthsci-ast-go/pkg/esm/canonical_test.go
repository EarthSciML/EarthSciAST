package esm

import (
	"encoding/json"
	"math"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestCanonicalFloat64String(t *testing.T) {
	// Force runtime addition so the 0.1 + 0.2 case reflects actual IEEE-754
	// behavior (compile-time constant folding collapses this to 0.3 exactly).
	a := 0.1
	b := 0.2
	imprecise := a + b

	cases := []struct {
		in   float64
		want string
	}{
		{1.0, "1.0"},
		{-3.0, "-3.0"},
		{0.0, "0.0"},
		{math.Copysign(0, -1), "-0.0"},
		{2.5, "2.5"},
		{imprecise, "0.30000000000000004"},
		{1e-7, "1e-7"},
		{1e25, "1e25"},
		{-5e300, "-5e300"},
		{3.14e25, "3.14e25"},
		{5e-324, "5e-324"}, // smallest positive subnormal
		{1e21, "1e21"},     // breakpoint — exponent form
		{1e-6, "0.000001"}, // breakpoint — plain decimal
	}
	for _, tc := range cases {
		got, err := canonicalFloat64String(tc.in)
		require.NoError(t, err, "input %v", tc.in)
		assert.Equal(t, tc.want, got, "input %v", tc.in)
	}
}

func TestCanonicalFloat64NonFinite(t *testing.T) {
	_, err := canonicalFloat64String(math.NaN())
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "E_CANONICAL_NONFINITE")

	_, err = canonicalFloat64String(math.Inf(1))
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "E_CANONICAL_NONFINITE")

	_, err = canonicalFloat64String(math.Inf(-1))
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "E_CANONICAL_NONFINITE")
}

// TestSaveEmitsTrailingDotZeroForIntegerFloat verifies RFC §5.4.6 emission:
// an integer-valued float64 literal in an Expression slot must serialize as
// "1.0" (not "1") so that the parse-back rule recovers a float node.
func TestSaveEmitsTrailingDotZeroForIntegerFloat(t *testing.T) {
	file := &ESMFile{
		ESM: "0.1.0",
		Metadata: Metadata{
			Name:    "IntegerFloatEmission",
			Authors: []string{"Test"},
		},
		Models: map[string]Model{
			"m": {
				Variables: map[string]ModelVariable{
					"x": {Type: "state"},
				},
				Equations: []Equation{
					{LHS: "x", RHS: float64(1.0)}, // float node → "1.0"
					{LHS: "y", RHS: int64(1)},     // integer node → "1"
					{LHS: "z", RHS: float64(2.5)}, // non-integer float → "2.5"
					{LHS: "w", RHS: float64(0.0)}, // integer-valued float zero → "0.0"
					{LHS: "v", RHS: ExprNode{Op: "+", Args: []any{float64(1.0), int64(2)}}},
				},
			},
		},
	}

	jsonStr, err := Serialize(file)
	require.NoError(t, err)

	// Re-parse as a generic tree to inspect raw tokens precisely. UseNumber
	// preserves the wire text so we can assert on it.
	dec := json.NewDecoder(strings.NewReader(jsonStr))
	dec.UseNumber()
	var tree map[string]any
	require.NoError(t, dec.Decode(&tree))

	equations := tree["models"].(map[string]any)["m"].(map[string]any)["equations"].([]any)

	// equations[0].rhs: float64(1.0) → "1.0"
	rhs0 := equations[0].(map[string]any)["rhs"].(json.Number)
	assert.Equal(t, "1.0", string(rhs0))

	// equations[1].rhs: int64(1) → "1"
	rhs1 := equations[1].(map[string]any)["rhs"].(json.Number)
	assert.Equal(t, "1", string(rhs1))

	// equations[2].rhs: float64(2.5) → "2.5"
	rhs2 := equations[2].(map[string]any)["rhs"].(json.Number)
	assert.Equal(t, "2.5", string(rhs2))

	// equations[3].rhs: float64(0.0) → "0.0"
	rhs3 := equations[3].(map[string]any)["rhs"].(json.Number)
	assert.Equal(t, "0.0", string(rhs3))

	// equations[4].rhs.args: mixed — [float64(1.0), int64(2)] → ["1.0", "2"]
	rhs4 := equations[4].(map[string]any)["rhs"].(map[string]any)
	args := rhs4["args"].([]any)
	assert.Equal(t, "1.0", string(args[0].(json.Number)))
	assert.Equal(t, "2", string(args[1].(json.Number)))
}

// TestRoundTripPreservesIntFloatDistinction exercises the canonical
// invariant: canonicalize(parse(emit(A))) == A. A float node parsed in,
// emitted, and re-parsed must remain a float node; likewise for int.
func TestRoundTripPreservesIntFloatDistinction(t *testing.T) {
	input := `{
  "esm": "0.1.0",
  "metadata": {"name": "roundtrip", "authors": ["Test"]},
  "models": {
    "m": {
      "variables": {"x": {"type": "state"}, "y": {"type": "state"}},
      "equations": [
        {"lhs": "x", "rhs": 1.0},
        {"lhs": "y", "rhs": 1},
        {"lhs": "x", "rhs": {"op": "+", "args": [1, 2.5, -0.0]}}
      ]
    }
  }
}`

	parsed, err := LoadString(input)
	require.NoError(t, err)

	jsonStr, err := Serialize(parsed)
	require.NoError(t, err)

	reparsed, err := LoadString(jsonStr)
	require.NoError(t, err)

	m := reparsed.Models["m"]

	// rhs was 1.0 on the wire → float64 after parse
	_, ok := m.Equations[0].RHS.(float64)
	assert.True(t, ok, "equations[0].rhs should round-trip as float64, got %T", m.Equations[0].RHS)

	// rhs was 1 on the wire → int64 after parse
	_, ok = m.Equations[1].RHS.(int64)
	assert.True(t, ok, "equations[1].rhs should round-trip as int64, got %T", m.Equations[1].RHS)

	// Nested op node args: int, float, negative-zero-float
	node := m.Equations[2].RHS.(ExprNode)
	_, ok = node.Args[0].(int64)
	assert.True(t, ok, "args[0] int64, got %T", node.Args[0])
	_, ok = node.Args[1].(float64)
	assert.True(t, ok, "args[1] float64, got %T", node.Args[1])
	_, ok = node.Args[2].(float64)
	assert.True(t, ok, "args[2] float64, got %T", node.Args[2])
}

// TestSaveTypedFloatFields verifies that typed float64 fields (not just
// interface{} slots) also emit canonical form. *float64 pointers like
// VariableMapCoupling.Factor are a common case.
func TestSaveTypedFloatFields(t *testing.T) {
	factor := 2.0
	file := &ESMFile{
		ESM: "0.1.0",
		Metadata: Metadata{
			Name:    "TypedFloats",
			Authors: []string{"Test"},
		},
		Models: map[string]Model{
			"m": {
				Variables: map[string]ModelVariable{"x": {Type: "state"}},
				Equations: []Equation{{LHS: "x", RHS: int64(0)}},
			},
		},
		Coupling: []CouplingEntry{
			VariableMapCoupling{Type: "variable_map", From: "a.x", To: "b.y", Transform: "multiplicative", Factor: &factor},
		},
	}

	jsonStr, err := Serialize(file)
	require.NoError(t, err)

	// *float64 factor emits with trailing .0
	assert.Contains(t, jsonStr, `"factor": 2.0`)
}

// TestSaveRejectsNonFiniteFloat verifies that NaN/Inf are rejected with
// E_CANONICAL_NONFINITE per RFC §5.4.6.
func TestSaveRejectsNonFiniteFloat(t *testing.T) {
	file := &ESMFile{
		ESM: "0.1.0",
		Metadata: Metadata{
			Name:    "NonFinite",
			Authors: []string{"Test"},
		},
		Models: map[string]Model{
			"m": {
				Variables: map[string]ModelVariable{"x": {Type: "state"}},
				Equations: []Equation{{LHS: "x", RHS: math.NaN()}},
			},
		},
	}

	_, err := Serialize(file)
	require.Error(t, err)
	assert.Contains(t, err.Error(), "E_CANONICAL_NONFINITE")
}
