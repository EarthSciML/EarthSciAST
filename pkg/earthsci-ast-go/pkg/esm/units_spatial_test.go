package esm

import "testing"

// spatialUnitEnv builds a unit environment with a `c` field in mol/m^3 and an
// `x` coordinate in metres. A user op that names `x` in its `dim` field must not
// divide operand by coordinate: it is an ordinary open-tier rewrite target.
func spatialUnitEnv(t *testing.T) map[string]Unit {
	t.Helper()
	units := func(s string) *string { return &s }
	m := &Model{Variables: map[string]ModelVariable{
		"c": {Type: VarTypeUnknown, Units: units("mol/m^3")},
		"x": {Type: VarTypeParameter, Units: units("m")},
	}}
	env, _ := buildModelUnitEnv(m)
	return env
}

func spatialNode(op, operand, dim string) ExprNode {
	return ExprNode{Op: op, Args: []any{operand}, Dim: &dim}
}

// TestDimFieldUserOpDimensionsAreIndeterminate pins (esm-spec §4.2 / §9.6.8)
// that a user op carrying a `dim` axis has NO privileged dimensional rule. Its
// dimension is UNDETERMINABLE until a discretization rewrite lowers it, so
// dimensional analysis reports an indeterminate (nil) result and no error, the
// same as the same user op without a `dim` — even when `dim` names a declared,
// unit-bearing variable. No op-name gating remains (the `grad`, `div` and
// `laplacian` ops that once had one were removed at esm 2.4.0).
func TestDimFieldUserOpDimensionsAreIndeterminate(t *testing.T) {
	env := spatialUnitEnv(t)
	ref, err := PropagateDimension(ExprNode{Op: "godunov_hamiltonian", Args: []any{"c"}}, env)
	if err != nil || ref != nil {
		t.Fatalf("baseline unregistered op: got (%v, %v); want (nil, nil)", ref, err)
	}
	for _, op := range []string{"godunov_hamiltonian", "upwind_flux"} {
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
