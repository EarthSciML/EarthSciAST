package esm

import (
	"strings"
	"testing"
)

// TestConstWithDeclaredUnitsHasThatUnit: a `const` that declares its units has
// that unit, a `const` without units stays undeterminable, and an unresolvable
// declared unit is listed for the structural layer (esm-spec §4.8.5).
func TestConstWithDeclaredUnitsHasThatUnit(t *testing.T) {
	env := scaleTestEnv(t, map[string]string{"speed_mph": "mi/h", "speed_ms": "m/s", "speed_kg": "kg"})
	konst := func(units *string) ExprNode {
		return ExprNode{Op: "const", Args: []any{}, Value: 0.44704, Units: units}
	}
	good := "m*h/(mi*s)"
	rhs := func(units *string) ExprNode { return ExprNode{Op: "*", Args: []any{"speed_mph", konst(units)}} }

	if w := ValidateEquationDimensions(&Equation{LHS: "speed_ms", RHS: rhs(&good)}, env, "/eq"); w != nil {
		t.Errorf("mi/h times a const declared m*h/(mi*s) is exactly m/s, got %+v", w)
	}
	if w := ValidateEquationDimensions(&Equation{LHS: "speed_kg", RHS: rhs(&good)}, env, "/eq"); w == nil {
		t.Error("declared kg against m/s must be a mismatch")
	}
	if w := ValidateEquationDimensions(&Equation{LHS: "speed_kg", RHS: rhs(nil)}, env, "/eq"); w != nil {
		t.Errorf("a const without units is undeterminable, got %+v", w)
	}
	bad := "mph"
	if got := unresolvableConstUnits(rhs(&bad)); len(got) != 1 || got[0] != "mph" {
		t.Errorf("unresolvable const units = %v, want [mph]", got)
	}
	if got := unresolvableConstUnits(rhs(&good)); len(got) != 0 {
		t.Errorf("a resolvable const unit must not be listed, got %v", got)
	}
}

// TestConstUnitsAreGatedAt120 rejects declared units on an expression node in a
// document declaring esm < 1.2.0, naming the node (esm-spec §4.8.5 item 6).
func TestConstUnitsAreGatedAt120(t *testing.T) {
	doc := func(esm string) map[string]any {
		return map[string]any{
			"esm": esm,
			"models": map[string]any{"M": map[string]any{"equations": []any{map[string]any{
				"lhs": "x",
				"rhs": map[string]any{"op": "const", "args": []any{}, "value": 1.0, "units": "m"},
			}}}},
		}
	}
	err := rejectConstUnitsPreV12(doc("1.1.0"))
	if err == nil || !strings.Contains(err.Error(), "const_units_version_too_old") ||
		!strings.Contains(err.Error(), "/models/M/equations/0/rhs") {
		t.Errorf("1.1.0 must be rejected naming the node, got %v", err)
	}
	if err := rejectConstUnitsPreV12(doc("1.2.0")); err != nil {
		t.Errorf("1.2.0 must be accepted, got %v", err)
	}
}
