package esm

import (
	"strings"
	"testing"
)

// spatialModel builds a model whose coordinate `x` carries the given units
// ("" = declared WITHOUT units), plus a `c` field in mol/m^3 and a `T` field in K.
func spatialModel(t *testing.T, xUnits string) (map[string]Unit, map[string]*Unit) {
	t.Helper()
	units := func(s string) *string { return &s }
	m := &Model{Variables: map[string]ModelVariable{
		"c": {Type: VarTypeState, Units: units("mol/m^3")},
		"T": {Type: VarTypeState, Units: units("K")},
	}}
	if xUnits == "" {
		m.Variables["x"] = ModelVariable{Type: VarTypeParameter} // declared, NO units
	} else {
		m.Variables["x"] = ModelVariable{Type: VarTypeParameter, Units: units(xUnits)}
	}
	env, _ := buildModelUnitEnv(m)
	return env, buildModelCoordEnv(m)
}

func spatialNode(op, operand, dim string) ExprNode {
	return ExprNode{Op: op, Args: []any{operand}, Dim: &dim}
}

// TestSpatialOperatorDimensions pins the §7.1.2 rules: each spatial operator
// divides its operand by the coordinate's dimension, and LAPLACIAN DIVIDES TWICE
// (it is D(D(u,x),x)). Go previously never divided at all — every caller passed a
// nil coordinate table, so the grad/div/laplacian branch was dead code — and when
// it did run it divided only ONCE for all three operators.
func TestSpatialOperatorDimensions(t *testing.T) {
	env, coordEnv := spatialModel(t, "m")

	cases := []struct {
		op      string
		operand string
		want    string // expected dimension string
	}{
		{OpGrad, "c", "mol/m^3 / m"},        // mol·m^-4
		{OpDivergence, "c", "mol/m^3 / m"},  // mol·m^-4
		{OpLaplacian, "c", "mol/m^3 / m^2"}, // mol·m^-5 — the SQUARE
	}
	for _, tc := range cases {
		t.Run(tc.op, func(t *testing.T) {
			got, err := propagateDimensionWithCoords(spatialNode(tc.op, tc.operand, "x"), env, coordEnv)
			if err != nil {
				t.Fatalf("%s: unexpected error: %v", tc.op, err)
			}
			if got == nil {
				t.Fatalf("%s: dimension is indeterminate; want %s", tc.op, tc.want)
			}

			// Build the expectation from first principles: operand / x (twice for
			// the laplacian).
			operand := env[tc.operand]
			x := env["x"]
			want := operand.Divide(x)
			if tc.op == OpLaplacian {
				want = want.Divide(x)
			}
			if !got.Dim.Equal(want.Dim) {
				t.Errorf("%s(%s) over x = %s; want %s (%s)", tc.op, tc.operand, got.Dim, want.Dim, tc.want)
			}
		})
	}

	// The laplacian must NOT equal the gradient — the bug this pins is a single
	// division shared by all three operators.
	grad, _ := propagateDimensionWithCoords(spatialNode(OpGrad, "T", "x"), env, coordEnv)
	lap, _ := propagateDimensionWithCoords(spatialNode(OpLaplacian, "T", "x"), env, coordEnv)
	if grad == nil || lap == nil {
		t.Fatal("grad/laplacian dimensions are indeterminate over a coordinate WITH units")
	}
	if grad.Dim.Equal(lap.Dim) {
		t.Errorf("laplacian has the same dimension as grad (%s): the coordinate must divide TWICE", lap.Dim)
	}
}

// TestSpatialOperatorCoordinateWithoutUnits pins the defect
// tests/invalid/units_gradient_operator_mismatch.esm demonstrates: a coordinate
// the model DECLARES but leaves unit-less makes the operator's dimension
// undecidable, and the file is wrong to ask for it.
func TestSpatialOperatorCoordinateWithoutUnits(t *testing.T) {
	env, coordEnv := spatialModel(t, "") // x declared, no units

	for _, op := range []string{OpGrad, OpDivergence, OpLaplacian} {
		t.Run(op, func(t *testing.T) {
			got, err := propagateDimensionWithCoords(spatialNode(op, "c", "x"), env, coordEnv)
			if err == nil {
				t.Fatalf("%s over a units-less coordinate was accepted (dim=%v); want a dimensional "+
					"mismatch", op, got)
			}
			if code := findingCode(err); code != UnitFindingDimensionalMismatch {
				t.Errorf("finding code = %q; want %q (it must PROMOTE to unit_inconsistency)",
					code, UnitFindingDimensionalMismatch)
			}
			if !strings.Contains(err.Error(), "x") {
				t.Errorf("message does not name the offending coordinate: %v", err)
			}
		})
	}
}

// TestSpatialOperatorUndeclaredDimIsIndeterminate pins the NO-FABRICATION rule.
//
// A `dim` naming no declared variable is an INDEX-SET AXIS lowered by a
// discretization rewrite rule (§9.6.8), not a physical coordinate. There is
// nothing to divide by — and inventing a metre denominator (the fallback TS had
// and removed) would manufacture a dimension, which under hard-error severity
// turns into a FALSE REJECTION of a valid file. Indeterminate is the only honest
// answer: no dimension, and no complaint.
func TestSpatialOperatorUndeclaredDimIsIndeterminate(t *testing.T) {
	env, coordEnv := spatialModel(t, "m")

	for _, op := range []string{OpGrad, OpDivergence, OpLaplacian} {
		t.Run(op, func(t *testing.T) {
			// "cell" is an index-set axis: it is NOT among the model's declared
			// variables.
			got, err := propagateDimensionWithCoords(spatialNode(op, "c", "cell"), env, coordEnv)
			if err != nil {
				t.Fatalf("%s over an index-set axis was REJECTED: %v — a dim that names no declared "+
					"variable is not a coordinate and must not be flagged", op, err)
			}
			if got != nil {
				t.Errorf("%s over an index-set axis produced dimension %s; want indeterminate (nil). "+
					"A fabricated denominator is a false-rejection factory.", op, got.Dim)
			}
		})
	}
}

// TestBuildModelCoordEnvIsThreeState pins the distinction the whole check rests
// on: "declared without units" (a defect) must be representable separately from
// "not declared at all" (an index-set axis). A two-state map[string]Unit collapses
// them and cannot tell the fixture's `x` from a discretization axis.
func TestBuildModelCoordEnvIsThreeState(t *testing.T) {
	units := func(s string) *string { return &s }
	m := &Model{Variables: map[string]ModelVariable{
		"x": {Type: VarTypeParameter, Units: units("m")},
		"y": {Type: VarTypeParameter}, // declared, NO units
	}}
	coords := buildModelCoordEnv(m)

	if u, ok := coords["x"]; !ok || u == nil {
		t.Errorf(`coords["x"] = (%v, %v); want a non-nil unit (declared WITH units)`, u, ok)
	}
	if u, ok := coords["y"]; !ok || u != nil {
		t.Errorf(`coords["y"] = (%v, %v); want (nil, true) — declared WITHOUT units`, u, ok)
	}
	if _, ok := coords["cell"]; ok {
		t.Error(`coords["cell"] is present; an undeclared name must be ABSENT, not nil`)
	}
}
