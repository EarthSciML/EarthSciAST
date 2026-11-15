package esm

import (
	"path/filepath"
	"testing"
)

// The flatten corpus pins what esm-spec §4.2's right-hand-side `D` resolution
// PRODUCES; these pin what it must leave standing. A cyclic chain is the case
// that makes the active-name guard load-bearing: without it Flatten does not
// fail here, it recurses without end.
func TestFlattenLeavesUnresolvableRHSTimeDerivatives(t *testing.T) {
	dir := filepath.Join("..", "..", "..", "..", "tests", "conformance", "rhs_time_derivative", "fixtures")
	for _, fixture := range []string{"d_of_cycle.esm", "d_of_unsupported.esm"} {
		t.Run(fixture, func(t *testing.T) {
			file, err := LoadPath(filepath.Join(dir, fixture))
			if err != nil {
				t.Fatal(err)
			}
			flat, err := Flatten(file)
			if err != nil {
				t.Fatal(err)
			}
			structural := 0
			for _, eq := range flat.Equations {
				if hasStructuralTimeDerivative(eq.RHS) {
					structural++
				}
			}
			if structural == 0 {
				t.Fatalf("every right-hand-side D was rewritten; an unresolvable one must stay standing")
			}
		})
	}
}

func TestFlattenResolvesRHSTimeDerivativeRules(t *testing.T) {
	dir := filepath.Join("..", "..", "..", "..", "tests", "conformance", "rhs_time_derivative", "fixtures")
	negKX := map[string]any{"op": "*", "args": []any{map[string]any{"op": "-", "args": []any{"M.k"}}, "M.x"}}
	for _, tc := range []struct {
		fixture, lhs string
		want         any
	}{
		// Chain rule through an observed's definition.
		{"d_of_observed.esm", "M.dcombo", map[string]any{"op": "*", "args": []any{negKX, 2}}},
		// Product rule, with the parameter factor's derivative folded away.
		{"d_of_compound.esm", "M.dscaled", map[string]any{"op": "*", "args": []any{negKX, "M.scale"}}},
		// A time-invariant name is the literal 0.
		{"d_of_parameter.esm", "M.dk", 0},
	} {
		t.Run(tc.fixture, func(t *testing.T) {
			file, err := LoadPath(filepath.Join(dir, tc.fixture))
			if err != nil {
				t.Fatal(err)
			}
			flat, err := Flatten(file)
			if err != nil {
				t.Fatal(err)
			}
			for _, eq := range flat.Equations {
				if s, ok := eq.LHS.(string); ok && s == tc.lhs {
					if !sameExpression(eq.RHS, tc.want) {
						t.Fatalf("%s: got %s, want %s", tc.lhs, showJSON(eq.RHS), showJSON(tc.want))
					}
					return
				}
			}
			t.Fatalf("no equation defines %s", tc.lhs)
		})
	}
}
