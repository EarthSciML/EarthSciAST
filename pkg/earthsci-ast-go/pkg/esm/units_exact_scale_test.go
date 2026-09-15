package esm

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// TestEveryRegistryScaleHasMatchingExactForm checks that every registry entry's
// exact scale is the same number as its float scale. An entry that forgot its
// Exact would default to exactly 1 and fail here.
func TestEveryRegistryScaleHasMatchingExactForm(t *testing.T) {
	for name, u := range unitRegistry {
		got := u.Exact.Float()
		if math.Abs(got-u.Scale) > 1e-12*math.Abs(u.Scale) {
			t.Errorf("%s: exact scale %v disagrees with the float %v", name, got, u.Scale)
		}
	}
}

// TestReconciledRegistryScalesAreExact pins the entries the bindings disagreed
// on, and the scales whose exact form is least obvious (esm-spec §4.8.1).
func TestReconciledRegistryScalesAreExact(t *testing.T) {
	cases := map[string]string{
		"Torr": "20265/152",
		"psi":  "8896443230521/1290320000",
		"degF": "5/9",
		"deg":  "1/180*pi",
		"mi":   "201168/125",
		"hp":   "37284993579113511/50000000000000",
		"DU":   "268670000000000000000",
	}
	for sym, want := range cases {
		u, err := ParseUnit(sym)
		if err != nil {
			t.Fatalf("%s: %v", sym, err)
		}
		got, ok := u.Exact.RatioString()
		if !ok || got != want {
			t.Errorf("%s: exact scale %q, want %q", sym, got, want)
		}
	}
}

// TestUnitRegistryGoldenExactScales consumes tests/conformance/unit_registry:
// every accepted string's exact scale, relative to its canonical unit, must be
// the pinned scale_exact string, with no tolerance.
func TestUnitRegistryGoldenExactScales(t *testing.T) {
	_, thisFile, _, _ := runtime.Caller(0)
	path := filepath.Join(filepath.Dir(thisFile), "..", "..", "..", "..",
		"tests", "conformance", "unit_registry", "golden", "unit_verdicts.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	var golden struct {
		Accept []struct {
			Units      string `json:"units"`
			Canonical  string `json:"canonical"`
			ScaleExact string `json:"scale_exact"`
		} `json:"accept"`
	}
	if err := json.Unmarshal(raw, &golden); err != nil {
		t.Fatalf("parse golden: %v", err)
	}
	if len(golden.Accept) == 0 {
		t.Fatal("golden has no accepted strings")
	}
	for _, e := range golden.Accept {
		got, err := ParseUnit(e.Units)
		if err != nil {
			t.Errorf("%q must resolve: %v", e.Units, err)
			continue
		}
		want, err := ParseUnit(e.Canonical)
		if err != nil {
			t.Errorf("%q must resolve: %v", e.Canonical, err)
			continue
		}
		s, ok := got.Exact.Div(want.Exact).RatioString()
		if !ok || s != e.ScaleExact {
			t.Errorf("%q -> %q: exact scale %q, pinned %q", e.Units, e.Canonical, s, e.ScaleExact)
		}
	}
}

func scaleTestEnv(t *testing.T, units map[string]string) map[string]Unit {
	t.Helper()
	env := make(map[string]Unit, len(units))
	for name, s := range units {
		u, err := ParseUnit(s)
		if err != nil {
			t.Fatalf("%s: %v", s, err)
		}
		env[name] = u
	}
	return env
}

// TestAdditionRequiresEqualScales: both operands are lengths, but metres and
// kilometres are different units (esm-spec §4.8.3).
func TestAdditionRequiresEqualScales(t *testing.T) {
	env := scaleTestEnv(t, map[string]string{"x": "m", "y": "km", "z": "m"})
	_, err := propagateDimension(ExprNode{Op: "+", Args: []any{"x", "y"}}, env)
	if err == nil || findingCode(err) != UnitFindingDimensionalMismatch {
		t.Errorf("m + km must be a scale mismatch, got %v", err)
	}
	if _, err := propagateDimension(ExprNode{Op: "+", Args: []any{"x", "z"}}, env); err != nil {
		t.Errorf("m + m must be accepted, got %v", err)
	}
}

// TestEquationRequiresEqualScales: m/s = mi/h agrees in dimension and not in
// scale, and a quantity declared m*h/(mi*s) makes the scales cancel exactly.
func TestEquationRequiresEqualScales(t *testing.T) {
	env := scaleTestEnv(t, map[string]string{
		"speed_ms": "m/s", "speed_mph": "mi/h", "ms_per_mph": "m*h/(mi*s)",
	})
	w := ValidateEquationDimensions(&Equation{LHS: "speed_ms", RHS: "speed_mph"}, env, "/eq")
	if w == nil || w.Code != UnitFindingDimensionalMismatch {
		t.Errorf("m/s = mi/h must be a scale mismatch, got %+v", w)
	}
	converted := &Equation{LHS: "speed_ms", RHS: ExprNode{Op: "*", Args: []any{"speed_mph", "ms_per_mph"}}}
	if w := ValidateEquationDimensions(converted, env, "/eq"); w != nil {
		t.Errorf("mi/h times m*h/(mi*s) is exactly m/s, got %+v", w)
	}
}
