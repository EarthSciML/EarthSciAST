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
	for _, tc := range []struct{ fixture, lhs, want string }{
		// Chain rule through an observed's definition.
		{"d_of_observed.esm", "M.dcombo", "(-M.k) * M.x * 2"},
		// Product rule, with the parameter factor's derivative folded away.
		{"d_of_compound.esm", "M.dscaled", "(-M.k) * M.x * M.scale"},
		// A time-invariant name is the literal 0.
		{"d_of_parameter.esm", "M.dk", "0"},
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
					if got := ToASCII(eq.RHS); got != tc.want {
						t.Fatalf("%s: got %q, want %q", tc.lhs, got, tc.want)
					}
					return
				}
			}
			t.Fatalf("no equation defines %s", tc.lhs)
		})
	}
}
