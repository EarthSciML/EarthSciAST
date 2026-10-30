package esm

// esm-spec §4.8.3 and issue #409: a unit's SCALE reaches the trig and
// transcendental rules.
//
// Two halves that want OPPOSITE fixes, and one file so they stay in view of
// each other:
//
//   - ANGLES CONVERT. `deg` is a registry unit at scale π/180, so
//     `sin(theta [deg])` is a CONFORMING document — and flatten used to hand the
//     stored number straight to `sin`, so `sin(90 [deg])` evaluated
//     0.8939966636005579, which is sin(90 RADIANS), with no diagnostic. The
//     conversion is exact and has exactly one reading.
//   - SCALED DIMENSIONLESS REFUSES. `ppm` is dimensionless at 1e-6, so
//     `log(c [ppm])` satisfied every dimension-only test. The log of the ppm
//     NUMBER and the log of the mole fraction differ by ln(1e-6) = 13.8155…, and
//     nothing in the document says which was meant, so the checker refuses and
//     names the repair rather than picking one.
//
// Everything asserted here is asserted off SHARED fixtures, so the same facts
// are checked by the other four bindings.

import (
	"math"
	"path/filepath"
	"strings"
	"testing"
)

// strictArgumentOps are the ops whose argument esm-spec §4.8.3 requires to be
// dimensionless — the ten strict transcendentals and the three inverse circular
// functions.
var strictArgumentOps = []string{
	"ln", "log", "log10", "exp",
	"sinh", "cosh", "tanh", "asinh", "acosh", "atanh",
	"asin", "acos", "atan",
}

// typeArg types op(x) with x declared in `unit`.
func typeArg(t *testing.T, op, unit string) error {
	t.Helper()
	env, bad := BuildUnitEnv(map[string]string{"x": unit})
	if len(bad) != 0 {
		t.Fatalf("unit %q did not parse: %v", unit, bad)
	}
	_, err := PropagateDimension(ExprNode{Op: op, Args: []any{"x"}}, env)
	return err
}

func TestScaledDimensionlessArgumentIsRefused(t *testing.T) {
	for _, op := range strictArgumentOps {
		err := typeArg(t, op, "ppm")
		if err == nil {
			t.Fatalf("%s(x [ppm]) must be refused: the reading is unstated", op)
		}
		if findingCode(err) != UnitFindingDimensionalMismatch {
			t.Fatalf("%s: want a dimensional mismatch, got code %q", op, findingCode(err))
		}
		msg := err.Error()
		for _, want := range []string{"dimensionless at scale 1", "(ppm)", "divide by 1 ppm"} {
			if !strings.Contains(msg, want) {
				t.Fatalf("%s: the diagnostic must name the repair; %q missing from %q", op, want, msg)
			}
		}
		if err := typeArg(t, op, "1"); err != nil {
			t.Fatalf("%s(x [1]) is a pure number and must stay accepted, got %v", op, err)
		}
	}
	if msg := typeArg(t, "exp", "percent").Error(); !strings.Contains(msg, "divide by 1 percent") {
		t.Fatalf("the percent spelling must be named too, got %q", msg)
	}
}

func TestCircularFunctionTakesAnAngleAtAnyScale(t *testing.T) {
	for _, op := range []string{"sin", "cos", "tan"} {
		for _, ok := range []string{"rad", "deg", "1"} {
			if err := typeArg(t, op, ok); err != nil {
				t.Fatalf("%s(x [%s]) is a conforming document, got %v", op, ok, err)
			}
		}
		// Dimensionless at a scale other than 1 leaves the reading unstated,
		// exactly as it does for `log`. `sr` is rad^2 — no conversion turns a
		// solid angle into a plane one, so accepting it would multiply by
		// `scale` where `scale^2` was meant.
		for _, bad := range []string{"percent", "sr"} {
			if err := typeArg(t, op, bad); err == nil {
				t.Fatalf("%s(x [%s]) must be refused", op, bad)
			}
		}
	}
}

func TestAngleNormalizationFactor(t *testing.T) {
	for _, spelling := range []string{"rad", "1", "ppm", "m", "sr"} {
		env, _ := BuildUnitEnv(map[string]string{"x": spelling})
		if _, ok := angleNormalizationFactor(env["x"]); ok {
			t.Fatalf("%s must not be rewritten", spelling)
		}
	}
	env, _ := BuildUnitEnv(map[string]string{"x": "deg"})
	factor, ok := angleNormalizationFactor(env["x"])
	if !ok || factor != math.Pi/180.0 {
		t.Fatalf("deg must normalize by pi/180, got %v (ok=%v)", factor, ok)
	}
	// 90 deg is exactly a quarter turn under this factor.
	if math.Sin(90.0*factor) != 1.0 {
		t.Fatalf("sin(90 deg) must be exactly 1, got %v", math.Sin(90.0*factor))
	}
}

// trigArguments collects every sin/cos/tan node's single argument.
func trigArguments(expr Expression, out *[]struct {
	Op  string
	Arg Expression
}) {
	node, ok := asExprNode(expr)
	if !ok {
		return
	}
	if (node.Op == "sin" || node.Op == "cos" || node.Op == "tan") && len(node.Args) == 1 {
		*out = append(*out, struct {
			Op  string
			Arg Expression
		}{node.Op, node.Args[0]})
	}
	for _, a := range node.Args {
		trigArguments(a, out)
	}
}

func TestFlattenConvertsDegreesAndLeavesRadiansAlone(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	file, err := LoadPath(filepath.Join(repoRoot, "tests", "simulation", "angle_units_degrees.esm"))
	if err != nil {
		t.Fatalf("load the shared angle fixture: %v", err)
	}
	flat, err := Flatten(file)
	if err != nil {
		t.Fatalf("flatten: %v", err)
	}
	var found []struct {
		Op  string
		Arg Expression
	}
	for _, eq := range flat.Equations {
		trigArguments(eq.RHS, &found)
	}
	if len(found) != 4 {
		t.Fatalf("the fixture carries four trig calls, found %d", len(found))
	}
	converted, untouched := 0, 0
	for _, f := range found {
		if node, ok := asExprNode(f.Arg); ok {
			if node.Op != "*" {
				t.Fatalf("%s: expected the folded product, got %q", f.Op, node.Op)
			}
			if node.Args[1] != math.Pi/180.0 {
				t.Fatalf("%s: the factor must be the declared scale of `deg`, got %v", f.Op, node.Args[1])
			}
			converted++
			continue
		}
		name, ok := f.Arg.(string)
		if !ok || !strings.HasSuffix(name, "theta_rad") {
			t.Fatalf("%s: only the `rad` control stays a bare reference, got %#v", f.Op, f.Arg)
		}
		untouched++
	}
	if converted != 3 || untouched != 1 {
		t.Fatalf("want 3 converted and 1 untouched, got %d and %d", converted, untouched)
	}
}

// TestFlattenConvertsADegreeArrayElement pins that an array element carries its
// array's unit on the evaluation path, so cos(index(lat, i)) with lat in deg
// converts like cos(lat) does. The rewrite reads the argument with the
// checker's own rules, which type index and faq (esm-spec §4.8.3); it once
// read it with rules that had none, and left every array element unconverted.
func TestFlattenConvertsADegreeArrayElement(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	path := filepath.Join(repoRoot, "tests", "conformance", "scalar_operator_semantics",
		"fixtures", "angle_array_element.esm")
	file, err := LoadPath(path)
	if err != nil {
		t.Fatalf("load the shared array-element fixture: %v", err)
	}
	flat, err := Flatten(file)
	if err != nil {
		t.Fatalf("flatten: %v", err)
	}
	args := map[string]Expression{}
	var walk func(name string, e Expression)
	walk = func(name string, e Expression) {
		node, ok := asExprNode(e)
		if !ok {
			return
		}
		if (node.Op == "sin" || node.Op == "cos" || node.Op == "tan") && len(node.Args) == 1 {
			args[name] = node.Args[0]
		}
		for _, a := range node.Args {
			walk(name, a)
		}
		if node.Expr != nil {
			walk(name, node.Expr)
		}
	}
	for _, eq := range flat.Equations {
		if lhs, ok := eq.LHS.(string); ok {
			walk(lhs[strings.LastIndex(lhs, ".")+1:], eq.RHS)
		}
	}
	if len(args) != 5 {
		t.Fatalf("the fixture carries five trig calls, found %d: %v", len(args), args)
	}
	for _, name := range []string{"cos_lat", "sin_colat", "sin_sum"} {
		node, ok := asExprNode(args[name])
		if !ok || node.Op != "*" {
			t.Fatalf("%s: expected the folded product, got %#v", name, args[name])
		}
		inner, ok := asExprNode(node.Args[0])
		if !ok || inner.Op != "index" {
			t.Fatalf("%s: the element comes first, got %#v", name, node.Args[0])
		}
		if node.Args[1] != math.Pi/180.0 {
			t.Fatalf("%s: the factor must be the declared scale of `deg`, got %v", name, node.Args[1])
		}
	}
	if node, ok := asExprNode(args["sin_scalar"]); !ok || node.Op != "*" {
		t.Fatalf("sin_scalar: expected the folded product, got %#v", args["sin_scalar"])
	}
	if node, ok := asExprNode(args["cos_lat_rad"]); !ok || node.Op != "index" {
		t.Fatalf("cos_lat_rad: the `rad` control is never touched, got %#v", args["cos_lat_rad"])
	}
	// The checker still reads the authored spelling and still accepts it.
	if r := Validate(file); !r.IsValid {
		t.Fatalf("the fixture must stay valid, got %+v", r.StructuralErrors)
	}
	// And the checker gives an array element its array's unit, the same one
	// the rewrite read.
	deg, err := ParseUnit("deg")
	if err != nil {
		t.Fatalf("parse deg: %v", err)
	}
	env := map[string]Unit{"lat": deg}
	if u, err := propagateDimension(ExprNode{Op: "index", Args: []any{"lat", 1.0}}, env); err != nil || u == nil ||
		!u.Dim.Equal(deg.Dim) || !u.Exact.Equal(deg.Exact) {
		t.Fatalf("the checker must give index(lat, 1) lat's unit deg, got %v, %v", u, err)
	}
}

func TestSharedScaledArgumentFixtures(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	bad, err := LoadPath(filepath.Join(repoRoot, "tests", "invalid",
		"units_discriminator_transcendental_scaled_argument.esm"))
	if err != nil {
		t.Fatalf("load the shared invalid fixture: %v", err)
	}
	result := Validate(bad)
	if result.IsValid {
		t.Fatal("log(c [ppm]) leaves the reading unstated and must be refused")
	}
	named := false
	for _, e := range result.StructuralErrors {
		if strings.Contains(e.Message, "divide by 1 ppm") {
			named = true
		}
	}
	if !named {
		t.Fatalf("the diagnostic must name the repair, got %+v", result.StructuralErrors)
	}

	good, err := LoadPath(filepath.Join(repoRoot, "tests", "valid",
		"units_transcendental_scaled_argument_repair.esm"))
	if err != nil {
		t.Fatalf("load the shared repair fixture: %v", err)
	}
	if r := Validate(good); !r.IsValid {
		t.Fatalf("the repaired spelling must be accepted, got %+v", r.StructuralErrors)
	}
}

// esm-spec §4.8.3 "An angle meets a pure number": the rule strips the angle
// axis where an angle meets a pure number, but never makes two different angle
// units agree, with or without a pure number among the operands.
func TestAngleMeetsNumberDoesNotJoinTwoAngleUnits(t *testing.T) {
	env, bad := BuildUnitEnv(map[string]string{"theta": "rad", "omega": "sr", "n": "1"})
	if len(bad) != 0 {
		t.Fatalf("units did not parse: %v", bad)
	}
	accepted := ExprNode{Op: "+", Args: []any{"theta", "n"}}
	if u, err := PropagateDimension(accepted, env); err != nil || u == nil || !u.Dim.IsDimensionless() {
		t.Fatalf("theta [rad] + n [1] must be accepted as a pure number: %v (err %v)", u, err)
	}
	for _, refused := range []ExprNode{
		{Op: "+", Args: []any{"theta", "omega"}},
		{Op: "+", Args: []any{"theta", "omega", "n"}},
		{Op: "+", Args: []any{"n", "theta", "omega"}},
		{Op: "min", Args: []any{"theta", "omega", "n"}},
		{Op: "max", Args: []any{"theta", "omega", "n"}},
	} {
		_, err := PropagateDimension(refused, env)
		if err == nil || findingCode(err) != UnitFindingDimensionalMismatch {
			t.Fatalf("%s(%v) must be a dimensional mismatch: rad against sr, got %v", refused.Op, refused.Args, err)
		}
	}
}

// A scale mismatch where an angle met a pure number names the units the author
// declared, not the angle-stripped unit the comparison used.
func TestAngleMeetsNumberDiagnosticNamesDeclaredUnits(t *testing.T) {
	doc := `{
  "esm": "1.2.0",
  "metadata": {"name": "angle_message"},
  "models": {"M": {
    "variables": {
      "theta": {"type": "parameter", "units": "deg", "default": 1.0},
      "psi": {"type": "unknown", "units": "1"}
    },
    "equations": [{"lhs": "psi", "rhs": "theta"}]
  }}
}`
	file, err := LoadString(doc)
	if err != nil {
		t.Fatal(err)
	}
	// The observed-variable check (psi is defined by its equation).
	var observed string
	for _, w := range Validate(file).UnitWarnings {
		if w.Path == "/models/M/variables/psi" {
			observed = w.Message
		}
	}
	if !strings.Contains(observed, "deg") {
		t.Fatalf("the observed-variable diagnostic must name the declared `deg`, got %q", observed)
	}
	// The equation check, on the same two sides.
	env, _ := BuildUnitEnv(map[string]string{"theta": "deg", "psi": "1"})
	w := ValidateEquationDimensions(&Equation{LHS: "psi", RHS: "theta"}, env, "/eq")
	if w == nil || !strings.Contains(w.Message, "deg") {
		t.Fatalf("the equation diagnostic must name the declared `deg`, got %+v", w)
	}
}
