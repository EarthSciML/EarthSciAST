package esm

import (
	"math"
	"testing"
)

// dim builds a Dimension from (index, integer-exponent) pairs — the test
// spelling of what used to be a bare `Dimension{dimLength: 1}` literal, now
// that an exponent is a rational rather than an int8.
func dim(pairs ...int) Dimension {
	var d Dimension
	for i := 0; i+1 < len(pairs); i += 2 {
		d[pairs[i]] = ratInt(pairs[i+1])
	}
	return d
}

// dimRat builds a Dimension from (index, num, den) triples.
func dimRat(triples ...int) Dimension {
	var d Dimension
	for i := 0; i+2 < len(triples); i += 3 {
		d[triples[i]] = newRat(int64(triples[i+1]), int64(triples[i+2]))
	}
	return d
}

func TestParseUnitBaseSymbols(t *testing.T) {
	cases := []struct {
		in  string
		dim Dimension
	}{
		{"m", dim(dimLength, 1)},
		{"kg", dim(dimMass, 1)},
		{"s", dim(dimTime, 1)},
		{"mol", dim(dimAmount, 1)},
		{"K", dim(dimTemperature, 1)},
		{"A", dim(dimCurrent, 1)},
		{"cd", dim(dimLuminosity, 1)},
		{"rad", dim(dimAngle, 1)},
	}
	for _, c := range cases {
		u, err := ParseUnit(c.in)
		if err != nil {
			t.Fatalf("ParseUnit(%q): %v", c.in, err)
		}
		if !u.Dim.Equal(c.dim) {
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
	want := dim(dimLength, -2)
	if !du.Dim.Equal(want) {
		t.Errorf("Dobson.Dim = %v, want %v", du.Dim, want)
	}
}

func TestParseUnitCompound(t *testing.T) {
	cases := []struct {
		in  string
		dim Dimension
	}{
		{"m/s", dim(dimLength, 1, dimTime, -1)},
		{"m/s^2", dim(dimLength, 1, dimTime, -2)},
		{"kg*m/s^2", dim(dimMass, 1, dimLength, 1, dimTime, -2)},
		{"kg*m^2/s^3", dim(dimMass, 1, dimLength, 2, dimTime, -3)},
		{"cm^3/molec/s", dim(dimLength, 3, dimTime, -1)},
		{"1/s", dim(dimTime, -1)},
		{"mol/(m^3*s)", dim(dimAmount, 1, dimLength, -3, dimTime, -1)},
		{"J/(mol*K)", dim(dimMass, 1, dimLength, 2, dimTime, -2, dimAmount, -1, dimTemperature, -1)},
	}
	for _, c := range cases {
		u, err := ParseUnit(c.in)
		if err != nil {
			t.Fatalf("ParseUnit(%q): %v", c.in, err)
		}
		if !u.Dim.Equal(c.dim) {
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
	want := dim(dimMass, 1, dimLength, 1, dimTime, -2)
	if !n.Dim.Equal(want) {
		t.Errorf("N.Dim = %v, want %v", n.Dim, want)
	}

	// Pascal = N/m^2 = kg/(m*s^2)
	pa, _ := ParseUnit("Pa")
	wantPa := dim(dimMass, 1, dimLength, -1, dimTime, -2)
	if !pa.Dim.Equal(wantPa) {
		t.Errorf("Pa.Dim = %v, want %v", pa.Dim, wantPa)
	}

	// Joule = N*m = kg*m^2/s^2
	j, _ := ParseUnit("J")
	wantJ := dim(dimMass, 1, dimLength, 2, dimTime, -2)
	if !j.Dim.Equal(wantJ) {
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

// The US customary family, all four EXACT by definition and all four asserted
// against a table entry they are defined in terms of rather than against an
// independently typed literal -- so none of them can drift. Their SCALES are
// the contract, not just their dimensions: mechanical and metric horsepower
// share a dimension and are 1.4% apart, as do the US and imperial gallons at
// 20%, and a dimension-only check cannot tell either pair apart.
//
// They are here because EPA MOVES is written in them: link.linkLength in
// miles, link.linkAvgSpeed in mi/h, nrsourceusetype.hpAvg in horsepower, every
// nremissionrate row in g/(hp*h), fueltype.fuelDensity in g/gal, and
// brake-specific fuel consumption in lb/(hp*h).
func TestParseUnitUSCustomary(t *testing.T) {
	ft, _ := ParseUnit("ft")
	mi, err := ParseUnit("mi")
	if err != nil {
		t.Fatalf("ParseUnit(\"mi\"): %v", err)
	}
	if !mi.Dim.Equal(ft.Dim) {
		t.Errorf("mi must carry the length dimension, got %v", mi.Dim)
	}
	if mi.Scale != 5280*ft.Scale {
		t.Errorf("mi = %v, want EXACTLY 5280 ft = %v", mi.Scale, 5280*ft.Scale)
	}
	if mi.Scale != 1609.344 {
		t.Errorf("the international mile is 1609.344 m, got %v", mi.Scale)
	}

	lb, err := ParseUnit("lb")
	if err != nil {
		t.Fatalf("ParseUnit(\"lb\"): %v", err)
	}
	st, _ := ParseUnit("short_ton")
	if st.Scale != 2000*lb.Scale {
		t.Errorf("short_ton is DEFINED as 2000 lb: %v vs %v", st.Scale, 2000*lb.Scale)
	}

	hp, err := ParseUnit("hp")
	if err != nil {
		t.Fatalf("ParseUnit(\"hp\"): %v", err)
	}
	w, _ := ParseUnit("W")
	if !hp.Dim.Equal(w.Dim) {
		t.Errorf("hp must carry the power dimension, got %v", hp.Dim)
	}
	if hp.Scale != 550*ft.Scale*lb.Scale*9.80665 {
		t.Errorf("hp must be exactly 550 ft*lbf/s, got %v", hp.Scale)
	}
	// The decimal too, not only the product: the product alone would still hold
	// if ft and lb were both wrong, or if a map-ordering change left one of them
	// reading back the zero Unit. This is the value the golden pins.
	if hp.Scale != 745.6998715822702 {
		t.Errorf("hp must be 745.6998715822702 W, got %v", hp.Scale)
	}
	if math.Abs(hp.Scale-735.49875) < 1 {
		t.Errorf("hp must be MECHANICAL horsepower, not metric (PS): %v", hp.Scale)
	}

	gal, err := ParseUnit("gal")
	if err != nil {
		t.Fatalf("ParseUnit(\"gal\"): %v", err)
	}
	l, _ := ParseUnit("L")
	if !gal.Dim.Equal(l.Dim) {
		t.Errorf("gal must be a volume, got %v", gal.Dim)
	}
	if math.Abs(gal.Scale/l.Scale-3.785411784) > 1e-12 {
		t.Errorf("gal must be the US LIQUID gallon, 3.785411784 L, got %v L", gal.Scale/l.Scale)
	}

	// The compounds these exist to make spellable. None is a table entry --
	// they fall out of the grammar, which is why the BASE units were added and
	// not the compounds.
	mph, _ := ParseUnit("mi/h")
	if mph.Scale != 0.44704 {
		t.Errorf("1 mi/h is exactly 0.44704 m/s (MOVES's own constant), got %v", mph.Scale)
	}
	for _, c := range []string{"g/(hp*h)", "lb/(hp*h)", "g/gal", "g/mi", "kJ/gal"} {
		if _, err := ParseUnit(c); err != nil {
			t.Errorf("ParseUnit(%q): %v", c, err)
		}
	}

	// The deliberate absences. `mph` is a fused spelling of a compound the
	// grammar already builds; `in` and `yd` have no corpus user; `hp-hr` is
	// MOVES's OWN spelling of horsepower-hour and is unparseable because `-`
	// is not an operator.
	for _, c := range []string{"mph", "in", "yd", "miles", "hp-hr"} {
		if _, err := ParseUnit(c); err == nil {
			t.Errorf("ParseUnit(%q) must NOT resolve", c)
		}
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
	m := dim(dimLength, 1)
	s := dim(dimTime, 1)
	v := m.Divide(s) // m/s
	if !v.Equal(dim(dimLength, 1, dimTime, -1)) {
		t.Errorf("m/s dimension = %v", v)
	}
	a := v.Divide(s) // m/s^2
	if !a.Equal(dim(dimLength, 1, dimTime, -2)) {
		t.Errorf("m/s^2 dimension = %v", a)
	}
	kg := dim(dimMass, 1)
	f := kg.Multiply(a) // kg*m/s^2
	if !f.Equal(dim(dimMass, 1, dimLength, 1, dimTime, -2)) {
		t.Errorf("kg*m/s^2 dimension = %v", f)
	}
	m2 := m.Power(2)
	if !m2.Equal(dim(dimLength, 2)) {
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

// A BARE NUMERIC LITERAL is INDETERMINATE, not dimensionless: nothing in the
// AST says whether 3.14 is a pure number, a molar volume, or a unit-conversion
// factor. Since dimensional findings are now hard errors, the checker must not
// fabricate a dimension it cannot know.
func TestPropagateDimensionLiteral(t *testing.T) {
	u, err := PropagateDimension(3.14, nil)
	if err != nil {
		t.Fatal(err)
	}
	if u != nil {
		t.Errorf("a bare literal must have an INDETERMINATE dimension, got %v", u.Dim)
	}
}

// Where a literal's meaning IS determined, it still behaves correctly: an
// all-literal sum is a pure number, and additively a literal adopts its
// sibling's dimension rather than forcing it to be dimensionless.
func TestPropagateDimensionLiteralNeutrality(t *testing.T) {
	env := mkEnv(t, map[string]string{"T": "K"})

	sum := ExprNode{Op: "+", Args: []any{1.0, 2.0}}
	u, err := PropagateDimension(sum, env)
	if err != nil {
		t.Fatal(err)
	}
	if u == nil || !u.Dim.IsDimensionless() {
		t.Errorf("1 + 2 must be dimensionless, got %v", u)
	}

	// T - 273.15 is kelvin, not a mismatch.
	offset := ExprNode{Op: "-", Args: []any{"T", 273.15}}
	u, err = PropagateDimension(offset, env)
	if err != nil {
		t.Fatalf("T - 273.15 must not be a mismatch: %v", err)
	}
	if u == nil || !u.Dim.Equal(dim(dimTemperature, 1)) {
		t.Errorf("T - 273.15 must be K, got %v", u)
	}
}

func TestPropagateDimensionVarLookup(t *testing.T) {
	env := mkEnv(t, map[string]string{"x": "m", "t": "s"})
	u, err := PropagateDimension("x", env)
	if err != nil || u == nil {
		t.Fatalf("PropagateDimension(x): %v %v", u, err)
	}
	if !u.Dim.Equal(dim(dimLength, 1)) {
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
	ok := ExprNode{Op: "+", Args: []any{"a", "b"}}
	if u, err := PropagateDimension(ok, env); err != nil || u == nil || !u.Dim.Equal(dim(dimLength, 1)) {
		t.Errorf("a+b: %v %v", u, err)
	}

	// a + c: mismatch → error
	bad := ExprNode{Op: "+", Args: []any{"a", "c"}}
	if _, err := PropagateDimension(bad, env); err == nil {
		t.Error("a+c should have errored")
	}
}

func TestPropagateDimensionMultiplication(t *testing.T) {
	env := mkEnv(t, map[string]string{"v": "m/s", "t": "s"})
	// v * t should give m
	node := ExprNode{Op: "*", Args: []any{"v", "t"}}
	u, err := PropagateDimension(node, env)
	if err != nil || u == nil {
		t.Fatalf("v*t: %v %v", u, err)
	}
	if !u.Dim.Equal(dim(dimLength, 1)) {
		t.Errorf("v*t.Dim = %v, want m", u.Dim)
	}
}

func TestPropagateDimensionDivision(t *testing.T) {
	env := mkEnv(t, map[string]string{"x": "m", "t": "s"})
	node := ExprNode{Op: "/", Args: []any{"x", "t"}}
	u, err := PropagateDimension(node, env)
	if err != nil || u == nil {
		t.Fatalf("x/t: %v %v", u, err)
	}
	if !u.Dim.Equal(dim(dimLength, 1, dimTime, -1)) {
		t.Errorf("x/t.Dim = %v", u.Dim)
	}
}

func TestPropagateDimensionPower(t *testing.T) {
	env := mkEnv(t, map[string]string{"r": "m"})
	// r^2 → m^2
	node := ExprNode{Op: "^", Args: []any{"r", 2}}
	u, err := PropagateDimension(node, env)
	if err != nil || u == nil || !u.Dim.Equal(dim(dimLength, 2)) {
		t.Errorf("r^2: %v %v", u, err)
	}

	// Dimensionful exponent → error.
	env["k"] = unitRegistry["s"]
	bad := ExprNode{Op: "^", Args: []any{"r", "k"}}
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
	ok := ExprNode{Op: "sin", Args: []any{3.14}}
	if u, err := PropagateDimension(ok, env); err != nil || u == nil || !u.Dim.IsDimensionless() {
		t.Errorf("sin(3.14): %v %v", u, err)
	}

	// exp(t) with t in seconds → error.
	bad := ExprNode{Op: "exp", Args: []any{"t"}}
	if _, err := PropagateDimension(bad, env); err == nil {
		t.Error("exp(t) should have errored")
	}
}

func TestPropagateDimensionDerivative(t *testing.T) {
	env := mkEnv(t, map[string]string{"x": "m", "t": "s"})
	wrt := "t"
	node := ExprNode{Op: "D", Args: []any{"x"}, Wrt: &wrt}
	u, err := PropagateDimension(node, env)
	if err != nil || u == nil {
		t.Fatalf("D(x,t): %v %v", u, err)
	}
	if !u.Dim.Equal(dim(dimLength, 1, dimTime, -1)) {
		t.Errorf("D(x,t).Dim = %v, want m/s", u.Dim)
	}

	// An UNDECLARED independent variable leaves the derivative's dimension
	// UNKNOWN. Defaulting to seconds was a false-positive factory: in a
	// nondimensionalized model (state and RHS both "1", `t` undeclared) it
	// manufactured 1/s on the left against 1 on the right. Coverage is preserved
	// by the equation-level rule — see TestDerivativeTimeMismatchStillCaught.
	env2 := mkEnv(t, map[string]string{"x": "m"})
	node2 := ExprNode{Op: "D", Args: []any{"x"}}
	u2, err := PropagateDimension(node2, env2)
	if err != nil {
		t.Fatalf("D(x) with undeclared t: %v", err)
	}
	if u2 != nil {
		t.Errorf("D(x) with an undeclared independent variable must be INDETERMINATE, got %v", u2.Dim)
	}
}

// The derivative rule that replaces the seconds assumption: with `t` undeclared,
// an equation is provably wrong only when NO time unit could reconcile it.
func TestDerivativeTimeMismatchStillCaught(t *testing.T) {
	env := mkEnv(t, map[string]string{"x": "m", "k": "kg", "v": "m/s"})
	wrt := "t"

	// D(x) = k — metres per (unknown) time against kilograms. No time unit
	// reconciles those, so this is still a hard dimensional mismatch.
	bad := Equation{LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: &wrt}, RHS: "k"}
	w := ValidateEquationDimensions(&bad, env, "/models/M/equations/0")
	if w == nil {
		t.Fatal("D(x) = k must still be a dimensional mismatch")
	}
	if w.Code != UnitFindingDimensionalMismatch {
		t.Errorf("want dimensional_mismatch, got %q", w.Code)
	}
	if w.Path != "/models/M/equations/0" {
		t.Errorf("want the EQUATION pointer, got %q", w.Path)
	}

	// D(x) = v — metres per unknown time against m/s. Their ratio IS a power of
	// time, so some time unit reconciles them: not a mismatch.
	ok := Equation{LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: &wrt}, RHS: "v"}
	if w := ValidateEquationDimensions(&ok, env, "/models/M/equations/1"); w != nil {
		t.Errorf("D(x) = v is reconcilable by a time unit, got %+v", w)
	}
}

func TestPropagateDimensionComplexExpression(t *testing.T) {
	// Kinetic energy m*v^2 has the dimension of J: '^' reads its exponent by
	// VALUE, so the square is exact.
	env := mkEnv(t, map[string]string{"m": "kg", "v": "m/s"})
	v2 := ExprNode{Op: "^", Args: []any{"v", 2}}
	ke := ExprNode{Op: "*", Args: []any{"m", v2}}
	u, err := PropagateDimension(ke, env)
	if err != nil || u == nil {
		t.Fatalf("m*v^2: %v %v", u, err)
	}
	want := dim(dimMass, 1, dimLength, 2, dimTime, -2)
	if !u.Dim.Equal(want) {
		t.Errorf("KE.Dim = %v, want %v", u.Dim, want)
	}

	// A LITERAL COEFFICIENT makes the product indeterminate. This is deliberate
	// and is the price of hard-failing on mismatches: the AST cannot distinguish
	// the pure ½ of ½mv² from the unit-carrying 1.23 of a ppb→µg/m³ conversion,
	// so multiplying by a literal yields "unknown" rather than a fabricated
	// dimension. Treating literals as dimensionless here reported `conc_ppb*1.23`
	// as dimensionless and falsely rejected tests/valid/units_conversions.esm.
	keHalf := ExprNode{Op: "*", Args: []any{0.5, "m", v2}}
	u, err = PropagateDimension(keHalf, env)
	if err != nil {
		t.Fatalf("0.5*m*v^2 must not error: %v", err)
	}
	if u != nil {
		t.Errorf("a product with a literal factor must be INDETERMINATE, got %v", u.Dim)
	}
}

// A SYMBOLIC exponent leaves the result indeterminate — its dimension depends on
// the exponent's runtime value, so the checker cannot know it.
func TestPropagateDimensionSymbolicExponent(t *testing.T) {
	env := mkEnv(t, map[string]string{"x": "mol/L", "alpha": "dimensionless"})
	u, err := PropagateDimension(ExprNode{Op: "^", Args: []any{"x", "alpha"}}, env)
	if err != nil {
		t.Fatalf("x^alpha must not error: %v", err)
	}
	if u != nil {
		t.Errorf("x^alpha must be INDETERMINATE, got %v", u.Dim)
	}
}

// Equation consistency tests.

func TestValidateEquationDimensionsConsistent(t *testing.T) {
	env := mkEnv(t, map[string]string{"x": "m", "t": "s", "v": "m/s"})
	// D(x, t) = v
	wrt := "t"
	eq := &Equation{
		LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: &wrt},
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
		LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: &wrt},
		RHS: "v",
	}
	w := ValidateEquationDimensions(eq, env, "$")
	if w == nil {
		t.Fatal("expected a unit warning")
	}
	if w.LHSUnits == "" || w.RHSUnits == "" {
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
			"x": {Type: "unknown", Units: units("m")},
			"v": {Type: "unknown", Units: units("m/s")},
			"t": {Type: "parameter", Units: units("s")},
		},
		Equations: []Equation{
			// Consistent: dx/dt = v
			{LHS: ExprNode{Op: "D", Args: []any{"x"}, Wrt: strPtr("t")}, RHS: "v"},
			// Inconsistent: dv/dt = x (should be m/s^2 = m/s; mismatch m/s^2 vs m/s)
			{LHS: ExprNode{Op: "D", Args: []any{"v"}, Wrt: strPtr("t")}, RHS: "x"},
		},
	}
	result := &StructuralValidationResult{}
	validateModelUnits("M", &model, "/models/M", nil, result)
	if len(result.UnitWarnings) != 1 {
		t.Fatalf("expected 1 unit warning, got %d: %+v", len(result.UnitWarnings), result.UnitWarnings)
	}
	w := result.UnitWarnings[0]
	if w.Path != "/models/M/equations/1" {
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
					"x": {"type": "unknown", "default": 0.0, "units": "m"},
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
	result := Validate(file)
	if len(result.UnitWarnings) == 0 {
		t.Fatal("expected dimensional mismatch warning, got none")
	}
	found := false
	for _, w := range result.UnitWarnings {
		if w.Path == "/models/M/equations/0" {
			found = true
			if w.LHSUnits == w.RHSUnits {
				t.Errorf("mismatch warning has matching dims: %+v", w)
			}
		}
	}
	if !found {
		t.Errorf("warning not emitted at expected path: %+v", result.UnitWarnings)
	}
}
