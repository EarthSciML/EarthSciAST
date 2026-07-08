package esm

import (
	"math"
	"testing"
)

func TestParseUnitBaseSymbols(t *testing.T) {
	cases := []struct {
		in  string
		dim Dimension
	}{
		{"m", Dimension{dimLength: 1}},
		{"kg", Dimension{dimMass: 1}},
		{"s", Dimension{dimTime: 1}},
		{"mol", Dimension{dimAmount: 1}},
		{"K", Dimension{dimTemperature: 1}},
		{"A", Dimension{dimCurrent: 1}},
		{"cd", Dimension{dimLuminosity: 1}},
		{"rad", Dimension{dimAngle: 1}},
	}
	for _, c := range cases {
		u, err := ParseUnit(c.in)
		if err != nil {
			t.Fatalf("ParseUnit(%q): %v", c.in, err)
		}
		if u.Dim != c.dim {
			t.Errorf("ParseUnit(%q).Dim = %v, want %v", c.in, u.Dim, c.dim)
		}
	}
}

func TestParseUnitDimensionless(t *testing.T) {
	for _, s := range []string{"", "1", "dimensionless"} {
		u, err := ParseUnit(s)
		if err != nil {
			t.Fatalf("ParseUnit(%q): %v", s, err)
		}
		if !u.Dim.IsDimensionless() {
			t.Errorf("ParseUnit(%q).Dim = %v, want dimensionless", s, u.Dim)
		}
	}
}

func TestParseUnitESMSpecific(t *testing.T) {
	for _, s := range []string{"ppm", "ppb", "ppt", "mol/mol", "Dobson", "DU"} {
		if _, err := ParseUnit(s); err != nil {
			t.Errorf("ParseUnit(%q): %v", s, err)
		}
	}

	// ppm and ppb are dimensionless mixing ratios.
	for _, s := range []string{"ppm", "ppb", "ppt"} {
		u, _ := ParseUnit(s)
		if !u.Dim.IsDimensionless() {
			t.Errorf("%s should be dimensionless, got %v", s, u.Dim)
		}
	}

	// mol/mol is dimensionless by cancellation.
	molmol, _ := ParseUnit("mol/mol")
	if !molmol.Dim.IsDimensionless() {
		t.Errorf("mol/mol should be dimensionless, got %v", molmol.Dim)
	}

	// Dobson has dimensions of length^-2 (column density).
	du, _ := ParseUnit("Dobson")
	want := Dimension{dimLength: -2}
	if du.Dim != want {
		t.Errorf("Dobson.Dim = %v, want %v", du.Dim, want)
	}
}

func TestParseUnitCompound(t *testing.T) {
	cases := []struct {
		in  string
		dim Dimension
	}{
		{"m/s", Dimension{dimLength: 1, dimTime: -1}},
		{"m/s^2", Dimension{dimLength: 1, dimTime: -2}},
		{"kg*m/s^2", Dimension{dimMass: 1, dimLength: 1, dimTime: -2}},
		{"kg*m^2/s^3", Dimension{dimMass: 1, dimLength: 2, dimTime: -3}},
		{"cm^3/molec/s", Dimension{dimLength: 3, dimTime: -1}},
		{"1/s", Dimension{dimTime: -1}},
		{"mol/(m^3*s)", Dimension{dimAmount: 1, dimLength: -3, dimTime: -1}},
		{"J/(mol*K)", Dimension{dimMass: 1, dimLength: 2, dimTime: -2, dimAmount: -1, dimTemperature: -1}},
	}
	for _, c := range cases {
		u, err := ParseUnit(c.in)
		if err != nil {
			t.Fatalf("ParseUnit(%q): %v", c.in, err)
		}
		if u.Dim != c.dim {
			t.Errorf("ParseUnit(%q).Dim = %v, want %v", c.in, u.Dim, c.dim)
		}
	}
}

func TestParseUnitDerivedSymbols(t *testing.T) {
	// Newton = kg*m/s^2
	n, err := ParseUnit("N")
	if err != nil {
		t.Fatal(err)
	}
	want := Dimension{dimMass: 1, dimLength: 1, dimTime: -2}
	if n.Dim != want {
		t.Errorf("N.Dim = %v, want %v", n.Dim, want)
	}

	// Pascal = N/m^2 = kg/(m*s^2)
	pa, _ := ParseUnit("Pa")
	wantPa := Dimension{dimMass: 1, dimLength: -1, dimTime: -2}
	if pa.Dim != wantPa {
		t.Errorf("Pa.Dim = %v, want %v", pa.Dim, wantPa)
	}

	// Joule = N*m = kg*m^2/s^2
	j, _ := ParseUnit("J")
	wantJ := Dimension{dimMass: 1, dimLength: 2, dimTime: -2}
	if j.Dim != wantJ {
		t.Errorf("J.Dim = %v, want %v", j.Dim, wantJ)
	}
}

func TestParseUnitDimensionalEquality(t *testing.T) {
	// m/s and km/h have the same dimension (different scale).
	ms, _ := ParseUnit("m/s")
	kmh, _ := ParseUnit("km/h")
	if !ms.Dim.Equal(kmh.Dim) {
		t.Errorf("m/s and km/h should have equal dimension: %v vs %v", ms.Dim, kmh.Dim)
	}
	// Scales differ though — sanity check they are not trivially equal.
	if math.Abs(ms.Scale-kmh.Scale) < 1e-12 {
		t.Errorf("m/s and km/h scales unexpectedly equal: %v vs %v", ms.Scale, kmh.Scale)
	}
}

func TestParseUnitErrors(t *testing.T) {
	for _, s := range []string{"wibble", "m/", "m^", "m^abc", "(m", "m)"} {
		if _, err := ParseUnit(s); err == nil {
			t.Errorf("ParseUnit(%q) expected error, got none", s)
		}
	}
}

func TestDimensionArithmetic(t *testing.T) {
	m := Dimension{dimLength: 1}
	s := Dimension{dimTime: 1}
	v := m.Divide(s) // m/s
	if v != (Dimension{dimLength: 1, dimTime: -1}) {
		t.Errorf("m/s dimension = %v", v)
	}
	a := v.Divide(s) // m/s^2
	if a != (Dimension{dimLength: 1, dimTime: -2}) {
		t.Errorf("m/s^2 dimension = %v", a)
	}
	kg := Dimension{dimMass: 1}
	f := kg.Multiply(a) // kg*m/s^2
	if f != (Dimension{dimMass: 1, dimLength: 1, dimTime: -2}) {
		t.Errorf("kg*m/s^2 dimension = %v", f)
	}
	m2 := m.Power(2)
	if m2 != (Dimension{dimLength: 2}) {
		t.Errorf("m^2 dimension = %v", m2)
	}
}

// Propagation tests — mirror Julia's get_expression_dimensions test cases.

func mkEnv(t *testing.T, pairs map[string]string) map[string]Unit {
	t.Helper()
	env, bad := BuildUnitEnv(pairs)
	for name, err := range bad {
		t.Fatalf("BuildUnitEnv: %s -> %v", name, err)
	}
	return env
}

func TestPropagateDimensionLiteral(t *testing.T) {
	u, err := PropagateDimension(3.14, nil)
	if err != nil {
		t.Fatal(err)
	}
	if u == nil || !u.Dim.IsDimensionless() {
		t.Errorf("literal should be dimensionless, got %v", u)
	}
}

func TestPropagateDimensionVarLookup(t *testing.T) {
	env := mkEnv(t, map[string]string{"x": "m", "t": "s"})
	u, err := PropagateDimension("x", env)
	if err != nil || u == nil {
		t.Fatalf("PropagateDimension(x): %v %v", u, err)
	}
	if u.Dim != (Dimension{dimLength: 1}) {
		t.Errorf("x.Dim = %v", u.Dim)
	}

	// Unknown variable returns (nil, nil) — best-effort.
	u2, err := PropagateDimension("unknown", env)
	if err != nil || u2 != nil {
		t.Errorf("unknown var: %v %v", u2, err)
	}
}

func TestPropagateDimensionAddition(t *testing.T) {
	env := mkEnv(t, map[string]string{"a": "m", "b": "m", "c": "s"})

	// a + b: same dim → m
	ok := ExprNode{Op: "+", Args: []interface{}{"a", "b"}}
	if u, err := PropagateDimension(ok, env); err != nil || u == nil || u.Dim != (Dimension{dimLength: 1}) {
		t.Errorf("a+b: %v %v", u, err)
	}

	// a + c: mismatch → error
	bad := ExprNode{Op: "+", Args: []interface{}{"a", "c"}}
	if _, err := PropagateDimension(bad, env); err == nil {
		t.Error("a+c should have errored")
	}
}

func TestPropagateDimensionMultiplication(t *testing.T) {
	env := mkEnv(t, map[string]string{"v": "m/s", "t": "s"})
	// v * t should give m
	node := ExprNode{Op: "*", Args: []interface{}{"v", "t"}}
	u, err := PropagateDimension(node, env)
	if err != nil || u == nil {
		t.Fatalf("v*t: %v %v", u, err)
	}
	if u.Dim != (Dimension{dimLength: 1}) {
		t.Errorf("v*t.Dim = %v, want m", u.Dim)
	}
}

func TestPropagateDimensionDivision(t *testing.T) {
	env := mkEnv(t, map[string]string{"x": "m", "t": "s"})
	node := ExprNode{Op: "/", Args: []interface{}{"x", "t"}}
	u, err := PropagateDimension(node, env)
	if err != nil || u == nil {
		t.Fatalf("x/t: %v %v", u, err)
	}
	if u.Dim != (Dimension{dimLength: 1, dimTime: -1}) {
		t.Errorf("x/t.Dim = %v", u.Dim)
	}
}

func TestPropagateDimensionPower(t *testing.T) {
	env := mkEnv(t, map[string]string{"r": "m"})
	// r^2 → m^2
	node := ExprNode{Op: "^", Args: []interface{}{"r", 2}}
	u, err := PropagateDimension(node, env)
	if err != nil || u == nil || u.Dim != (Dimension{dimLength: 2}) {
		t.Errorf("r^2: %v %v", u, err)
	}

	// Dimensionful exponent → error.
	env["k"] = unitRegistry["s"]
	bad := ExprNode{Op: "^", Args: []interface{}{"r", "k"}}
	if _, err := PropagateDimension(bad, env); err == nil {
		t.Error("r^k (k in seconds) should have errored")
	}
}

func TestPropagateDimensionTranscendental(t *testing.T) {
	env := mkEnv(t, map[string]string{"x": "rad", "t": "s"})

	// sin(x) where x is dimensionless (rad counts as angle, which we allow
	// via the registry — explicit rad is dimensionful here, so require
	// a dimensionless argument).
	//
	// Use a literal: sin(3.14) → dimensionless.
	ok := ExprNode{Op: "sin", Args: []interface{}{3.14}}
	if u, err := PropagateDimension(ok, env); err != nil || u == nil || !u.Dim.IsDimensionless() {
		t.Errorf("sin(3.14): %v %v", u, err)
	}

	// exp(t) with t in seconds → error.
	bad := ExprNode{Op: "exp", Args: []interface{}{"t"}}
	if _, err := PropagateDimension(bad, env); err == nil {
		t.Error("exp(t) should have errored")
	}
}

func TestPropagateDimensionDerivative(t *testing.T) {
	env := mkEnv(t, map[string]string{"x": "m", "t": "s"})
	wrt := "t"
	node := ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: &wrt}
	u, err := PropagateDimension(node, env)
	if err != nil || u == nil {
		t.Fatalf("D(x,t): %v %v", u, err)
	}
	if u.Dim != (Dimension{dimLength: 1, dimTime: -1}) {
		t.Errorf("D(x,t).Dim = %v, want m/s", u.Dim)
	}

	// Default wrt = time in seconds when wrt is absent and env lacks "t".
	env2 := mkEnv(t, map[string]string{"x": "m"})
	node2 := ExprNode{Op: "D", Args: []interface{}{"x"}}
	u2, err := PropagateDimension(node2, env2)
	if err != nil || u2 == nil {
		t.Fatalf("D(x) default: %v %v", u2, err)
	}
	if u2.Dim != (Dimension{dimLength: 1, dimTime: -1}) {
		t.Errorf("D(x).Dim = %v, want m/s", u2.Dim)
	}
}

func TestPropagateDimensionComplexExpression(t *testing.T) {
	// Expression: kinetic energy 1/2 * m * v^2 should have dimension of J.
	env := mkEnv(t, map[string]string{"m": "kg", "v": "m/s"})
	v2 := ExprNode{Op: "^", Args: []interface{}{"v", 2}}
	ke := ExprNode{Op: "*", Args: []interface{}{0.5, "m", v2}}
	u, err := PropagateDimension(ke, env)
	if err != nil || u == nil {
		t.Fatalf("0.5*m*v^2: %v %v", u, err)
	}
	want := Dimension{dimMass: 1, dimLength: 2, dimTime: -2}
	if u.Dim != want {
		t.Errorf("KE.Dim = %v, want %v", u.Dim, want)
	}
}

// Equation consistency tests.

func TestValidateEquationDimensionsConsistent(t *testing.T) {
	env := mkEnv(t, map[string]string{"x": "m", "t": "s", "v": "m/s"})
	// D(x, t) = v
	wrt := "t"
	eq := &Equation{
		LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: &wrt},
		RHS: "v",
	}
	if w := ValidateEquationDimensions(eq, env, "$"); w != nil {
		t.Errorf("expected no warning, got %+v", w)
	}
}

func TestValidateEquationDimensionsInconsistent(t *testing.T) {
	env := mkEnv(t, map[string]string{"x": "m", "t": "s", "v": "kg"})
	wrt := "t"
	eq := &Equation{
		LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: &wrt},
		RHS: "v",
	}
	w := ValidateEquationDimensions(eq, env, "$")
	if w == nil {
		t.Fatal("expected a unit warning")
	}
	if w.LhsUnits == "" || w.RhsUnits == "" {
		t.Errorf("warning missing dims: %+v", w)
	}
}

func TestValidateEquationDimensionsMissingAnnotations(t *testing.T) {
	// No units known at all — should silently pass (best-effort semantics
	// matching Python/Julia: missing annotations are not a warning).
	eq := &Equation{LHS: "x", RHS: "y"}
	if w := ValidateEquationDimensions(eq, map[string]Unit{}, "$"); w != nil {
		t.Errorf("unknown vars should not warn, got %+v", w)
	}
}

// Integration: validateModelUnits fires on load.

func TestValidateModelUnitsIntegration(t *testing.T) {
	units := func(s string) *string { return &s }
	model := Model{
		Variables: map[string]ModelVariable{
			"x": {Type: "state", Units: units("m")},
			"v": {Type: "state", Units: units("m/s")},
			"t": {Type: "parameter", Units: units("s")},
		},
		Equations: []Equation{
			// Consistent: dx/dt = v
			{LHS: ExprNode{Op: "D", Args: []interface{}{"x"}, Wrt: strPtr("t")}, RHS: "v"},
			// Inconsistent: dv/dt = x (should be m/s^2 = m/s; mismatch m/s^2 vs m/s)
			{LHS: ExprNode{Op: "D", Args: []interface{}{"v"}, Wrt: strPtr("t")}, RHS: "x"},
		},
	}
	result := &StructuralValidationResult{}
	validateModelUnits("M", &model, "$.models.M", nil, result)
	if len(result.UnitWarnings) != 1 {
		t.Fatalf("expected 1 unit warning, got %d: %+v", len(result.UnitWarnings), result.UnitWarnings)
	}
	w := result.UnitWarnings[0]
	if w.Path != "$.models.M.equations[1]" {
		t.Errorf("wrong path: %s", w.Path)
	}
}

func TestValidateFileUnitsEndToEnd(t *testing.T) {
	// LoadString → ValidateFile populates UnitWarnings from dim analysis.
	jsonStr := `{
		"esm": "0.1.0",
		"metadata": {"name": "T", "authors": ["x"]},
		"models": {
			"M": {
				"variables": {
					"x": {"type": "state", "default": 0.0, "units": "m"},
					"k": {"type": "parameter", "default": 1.0, "units": "kg"}
				},
				"equations": [
					{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": "k"}
				]
			}
		}
	}`
	file, err := LoadString(jsonStr)
	if err != nil {
		t.Fatal(err)
	}
	result := ValidateFile(file, jsonStr)
	if len(result.UnitWarnings) == 0 {
		t.Fatal("expected dimensional mismatch warning, got none")
	}
	found := false
	for _, w := range result.UnitWarnings {
		if w.Path == "$.models.M.equations[0]" {
			found = true
			if w.LhsUnits == w.RhsUnits {
				t.Errorf("mismatch warning has matching dims: %+v", w)
			}
		}
	}
	if !found {
		t.Errorf("warning not emitted at expected path: %+v", result.UnitWarnings)
	}
}
