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
