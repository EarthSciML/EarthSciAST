package esm

import "testing"

// spatialUnitEnv builds a unit environment with a `c` field in mol/m^3 and an
// `x` coordinate in metres — the exact setup the retired grad-units rule used to
// divide operand-by-coordinate over. It exists to prove that division no longer
// happens: grad/div/laplacian are ordinary open-tier rewrite targets now.
func spatialUnitEnv(t *testing.T) map[string]Unit {
	t.Helper()
	units := func(s string) *string { return &s }
	m := &Model{Variables: map[string]ModelVariable{
		"c": {Type: VarTypeState, Units: units("mol/m^3")},
		"x": {Type: VarTypeParameter, Units: units("m")},
	}}
	env, _ := buildModelUnitEnv(m)
	return env
}

func spatialNode(op, operand, dim string) ExprNode {
	return ExprNode{Op: op, Args: []any{operand}, Dim: &dim}
}

// TestSpatialOperatorDimensionsAreIndeterminate pins the DESPECIALIZED contract
// (esm-spec §4.2 / §9.6.8): grad/div/laplacian carry NO privileged dimensional
// rule. Their dimension is UNDETERMINABLE until a discretization rewrite lowers
// them, so dimensional analysis reports an indeterminate (nil) result and no
// error — even when the coordinate `dim` names a declared, unit-bearing
// variable. The retired rule divided operand by coordinate (twice for the
// laplacian); it no longer exists.
func TestSpatialOperatorDimensionsAreIndeterminate(t *testing.T) {
	env := spatialUnitEnv(t)
	for _, op := range []string{"grad", "div", "laplacian"} {
		t.Run(op, func(t *testing.T) {
			got, err := PropagateDimension(spatialNode(op, "c", "x"), env)
			if err != nil {
				t.Fatalf("%s: unexpected error %v — an open-tier rewrite target must not raise a dimensional finding", op, err)
			}
			if got != nil {
				t.Errorf("%s(c) over x = %s; want indeterminate (nil): the operator has no modeled dimensional rule", op, got.Dim)
			}
		})
	}
}

// TestSpatialOperatorTreatedLikeUnregisteredOp pins that grad/div/laplacian are
// indistinguishable from any other open-tier op the units layer does not model:
// each propagates to the SAME indeterminate dimension as an unregistered user op
// such as `godunov_hamiltonian`. No op-name gating remains.
func TestSpatialOperatorTreatedLikeUnregisteredOp(t *testing.T) {
	env := spatialUnitEnv(t)
	ref, err := PropagateDimension(ExprNode{Op: "godunov_hamiltonian", Args: []any{"c"}}, env)
	if err != nil || ref != nil {
		t.Fatalf("baseline unregistered op: got (%v, %v); want (nil, nil)", ref, err)
	}
	for _, op := range []string{"grad", "div", "laplacian"} {
		got, err := PropagateDimension(spatialNode(op, "c", "x"), env)
		if err != nil || got != nil {
			t.Errorf("%s: got (%v, %v); want (nil, nil) — identical to an unregistered user op", op, got, err)
		}
	}
}
