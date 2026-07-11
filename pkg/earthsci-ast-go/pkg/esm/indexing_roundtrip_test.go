package esm

// Round-trip coverage for `index` used in scalar expression contexts
// outside of `arrayop.expr`, per RFC discretization §5.1 (bead gt-5s48).
//
// This test exercises the Go binding's ability to preserve `{op:"index",
// ...}` nodes (with both integer-literal and composite-arithmetic index
// arguments) through a load → save → load cycle. It deliberately does
// NOT exercise `arrayop` round-tripping, which the Go binding does not
// yet structurally support (ExprNode lacks OutputIdx/Expr/Ranges fields)
// — that gap predates this RFC and is tracked separately.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestIndexOutsideArrayopFixtureParses confirms the Go binding can load
// the shared cross-binding fixture at tests/indexing/idx_outside_arrayop.esm,
// which is the conformance artifact for RFC §5.1.
func TestIndexOutsideArrayopFixtureParses(t *testing.T) {
	wd, err := os.Getwd()
	require.NoError(t, err)
	repoRoot := filepath.Join(wd, "..", "..", "..", "..")
	fixturePath := filepath.Join(repoRoot, "tests", "indexing", "idx_outside_arrayop.esm")

	parsed, err := Load(fixturePath)
	require.NoError(t, err, "Load must accept `index` outside arrayop (RFC §5.1)")
	require.NotNil(t, parsed)
	require.NotNil(t, parsed.Models)

	model, ok := parsed.Models["IdxOutsideArrayop"]
	require.True(t, ok, "fixture model must parse")
	require.Len(t, model.Equations, 3,
		"fixture must carry three equations: the array ODE and two scalar ODEs driven by `index`")
}

// TestIndexOutsideArrayopScalarRoundTrip drives the load → save → load
// cycle on a scalar-only model that uses `{op:"index", ...}` on the RHS
// of ODEs — the exact contract RFC §5.1 pins down. Using an in-Go
// ESMFile keeps this test isolated from the independent `arrayop`
// serialization gap in the Go binding.
func TestIndexOutsideArrayopScalarRoundTrip(t *testing.T) {
	original := &ESMFile{
		ESM: "0.1.0",
		Metadata: Metadata{
			Name:    "index_scalar_rhs",
			Authors: []string{"EarthSciAST/polecats/chrome"},
		},
		Models: map[string]Model{
			"M": {
				Variables: map[string]ModelVariable{
					"u":           {Type: "state"},
					"s_literal":   {Type: "state"},
					"s_composite": {Type: "state"},
				},
				Equations: []Equation{
					{
						// D(s_literal) = index(u, 2)
						LHS: ExprNode{Op: "D", Args: []any{"s_literal"}, Wrt: strPtr("t")},
						RHS: ExprNode{Op: "index", Args: []any{"u", 2}},
					},
					{
						// D(s_composite) = index(u, 1+2)
						LHS: ExprNode{Op: "D", Args: []any{"s_composite"}, Wrt: strPtr("t")},
						RHS: ExprNode{
							Op: "index",
							Args: []any{
								"u",
								ExprNode{Op: "+", Args: []any{1, 2}},
							},
						},
					},
				},
			},
		},
	}

	first, err := Serialize(original)
	require.NoError(t, err, "Save must succeed on scalar `index` RHS")

	reparsed, err := LoadString(first)
	require.NoError(t, err, "LoadString must accept re-serialized scalar `index` RHS")

	second, err := Serialize(reparsed)
	require.NoError(t, err, "Save must succeed on reparsed payload")

	var firstVal, secondVal any
	require.NoError(t, json.Unmarshal([]byte(first), &firstVal))
	require.NoError(t, json.Unmarshal([]byte(second), &secondVal))
	assert.Equal(t, firstVal, secondVal,
		"serializer must be idempotent on scalar `index` RHS")

	// Semantic anchor: after the round-trip the two equations still carry
	// {op:"index", ...} on the RHS, with the integer-literal and
	// composite-arithmetic index arguments preserved.
	var final map[string]any
	require.NoError(t, json.Unmarshal([]byte(second), &final))
	model := final["models"].(map[string]any)["M"].(map[string]any)
	eqs := model["equations"].([]any)
	require.Len(t, eqs, 2)

	rhs0 := eqs[0].(map[string]any)["rhs"].(map[string]any)
	assert.Equal(t, "index", rhs0["op"])
	args0 := rhs0["args"].([]any)
	assert.Equal(t, "u", args0[0])
	// Integer literal: JSON unmarshal yields float64 in Go.
	assert.Equal(t, float64(2), args0[1])

	rhs1 := eqs[1].(map[string]any)["rhs"].(map[string]any)
	assert.Equal(t, "index", rhs1["op"])
	args1 := rhs1["args"].([]any)
	composite, ok := args1[1].(map[string]any)
	require.True(t, ok, "composite index arg must survive as an ExprNode map")
	assert.Equal(t, "+", composite["op"])
}
