package esm

import (
	"errors"
	"math"
	"strings"
	"testing"
)

// TestAssembleSystemDeduplicatesSameEquation pins the cross-system dedup in
// assembleSystem: two systems that give the same variable the same equation
// keep one copy, where "the same" treats a `D` with no `wrt` as `wrt: "t"`,
// ignores the annotations `id`, `attrs` and `expect_cadence`, and holds for a
// NaN constant; a different right-hand side is still a conflict.
func TestAssembleSystemDeduplicatesSameEquation(t *testing.T) {
	lhs := ExprNode{Op: "D", Args: []any{"A.x"}, Wrt: strPtr("t")}
	cases := []struct {
		name     string
		rhsA     Expression
		rhsB     Expression
		conflict bool
	}{
		{
			name: "absent wrt is t",
			rhsA: ExprNode{Op: "D", Args: []any{"A.y"}},
			rhsB: ExprNode{Op: "D", Args: []any{"A.y"}, Wrt: strPtr("t")},
		},
		{
			name: "annotations ignored",
			rhsA: ExprNode{Op: "*", Args: []any{"k", "A.x"}, ID: strPtr("n1"), ExpectCadence: strPtr("const")},
			rhsB: ExprNode{Op: "*", Args: []any{"k", "A.x"}, Attrs: map[string]any{"a": 1.0}},
		},
		{
			name: "NaN constant equals itself",
			rhsA: ExprNode{Op: "+", Args: []any{math.NaN(), "A.x"}},
			rhsB: ExprNode{Op: "+", Args: []any{math.NaN(), "A.x"}},
		},
		{
			name:     "different wrt conflicts",
			rhsA:     ExprNode{Op: "D", Args: []any{"A.y"}},
			rhsB:     ExprNode{Op: "D", Args: []any{"A.y"}, Wrt: strPtr("z")},
			conflict: true,
		},
		{
			name:     "different constant conflicts",
			rhsA:     ExprNode{Op: "+", Args: []any{math.NaN(), "A.x"}},
			rhsB:     ExprNode{Op: "+", Args: []any{1.5, "A.x"}},
			conflict: true,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			a, b := newComponentSystem("A"), newComponentSystem("B")
			a.equations = []FlattenedEquation{{LHS: lhs, RHS: c.rhsA, SourceSystem: "A"}}
			b.equations = []FlattenedEquation{{LHS: lhs, RHS: c.rhsB, SourceSystem: "B"}}
			flat, err := assembleSystem(&ESMFile{},
				map[string]*componentSystem{"A": a, "B": b}, []string{"A", "B"}, FlattenMetadata{})
			if c.conflict {
				var conflict *ConflictingDerivativeError
				if !errors.As(err, &conflict) {
					t.Fatalf("err = %v, want a ConflictingDerivativeError", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("assembleSystem: %v", err)
			}
			if len(flat.Equations) != 1 {
				t.Fatalf("got %d equations, want the duplicate dropped", len(flat.Equations))
			}
		})
	}
}

// TestPrintMathTypedValueInsideMap pins that PrintMath decodes a typed value
// held inside a map, not only one at the top level.
func TestPrintMathTypedValueInsideMap(t *testing.T) {
	names := []string{"k", "x"}
	typed := map[string]any{"lhs": "x", "rhs": ExprNode{Op: "*", Args: []any{"k", "x"}}}
	decoded := map[string]any{"lhs": "x", "rhs": map[string]any{"op": "*", "args": []any{"k", "x"}}}
	for _, f := range documentFormats {
		got, want := PrintMath(typed, names, f), PrintMath(decoded, names, f)
		if got != want {
			t.Errorf("PrintMath %s = %q, want %q", f, got, want)
		}
		if strings.Contains(got, "null") {
			t.Errorf("PrintMath %s = %q prints the typed right-hand side as null", f, got)
		}
	}
	slice := []any{ExprNode{Op: "*", Args: []any{"k", "x"}}}
	if got := ExpressionNames(slice); len(got) != 2 {
		t.Errorf("ExpressionNames = %v, want [k x]", got)
	}
}
