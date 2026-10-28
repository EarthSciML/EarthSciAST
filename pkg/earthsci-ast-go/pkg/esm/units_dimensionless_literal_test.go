package esm

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// The esm-spec §4.8.6 warning stage, pinned by
// tests/conformance/dimensionless_literal/golden/expected_warnings.json: every
// listed file stays valid and carries exactly the listed
// units_dimensionless_literal_mismatch warnings.

func dimensionlessLiteralRepoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	return root
}

func dimensionlessLiteralWarnings(t *testing.T, path string) (*ValidationResult, []UnitWarning) {
	t.Helper()
	file, err := LoadPath(path)
	if err != nil {
		t.Fatalf("load %s: %v", path, err)
	}
	result := Validate(file)
	var out []UnitWarning
	for _, w := range result.UnitWarnings {
		if w.Code == UnitFindingDimensionlessLiteral {
			out = append(out, w)
		}
	}
	return result, out
}

func TestDimensionlessLiteralGolden(t *testing.T) {
	root := dimensionlessLiteralRepoRoot(t)
	raw, err := os.ReadFile(filepath.Join(root, "tests", "conformance", "dimensionless_literal", "golden", "expected_warnings.json"))
	if err != nil {
		t.Fatal(err)
	}
	var golden struct {
		Code  string              `json:"code"`
		Files map[string][]string `json:"files"`
	}
	if err := json.Unmarshal(raw, &golden); err != nil {
		t.Fatal(err)
	}
	if golden.Code != UnitFindingDimensionlessLiteral {
		t.Fatalf("golden code %q, want %q", golden.Code, UnitFindingDimensionlessLiteral)
	}
	if len(golden.Files) == 0 {
		t.Fatal("golden lists no files")
	}
	for rel, want := range golden.Files {
		t.Run(rel, func(t *testing.T) {
			result, warnings := dimensionlessLiteralWarnings(t, filepath.Join(root, filepath.FromSlash(rel)))
			if !result.IsValid {
				t.Fatalf("expected valid, got structural errors %+v", result.StructuralErrors)
			}
			got := []string{}
			for _, w := range warnings {
				got = append(got, w.Path)
			}
			sort.Strings(got)
			if want == nil {
				want = []string{}
			}
			if !reflect.DeepEqual(got, want) {
				t.Errorf("warning paths:\n got  %v\n want %v", got, want)
			}
		})
	}
}

func TestDimensionlessLiteralMessage(t *testing.T) {
	root := dimensionlessLiteralRepoRoot(t)
	_, warnings := dimensionlessLiteralWarnings(t, filepath.Join(root, "tests", "conformance", "dimensionless_literal", "fixtures", "dimensionless_literal.esm"))
	for _, w := range warnings {
		if w.Path != "/models/Literals/equations/0" {
			continue
		}
		for _, want := range []string{"/models/Literals/equations/0", "273.15", "const("} {
			if !strings.Contains(w.Message, want) {
				t.Errorf("message %q does not mention %q", w.Message, want)
			}
		}
		return
	}
	t.Fatalf("no warning at /models/Literals/equations/0: %+v", warnings)
}

// Zero stays neutral under the dimensionless-literal rule, in every spelling,
// while a nonzero literal becomes a pure number; the current rule is unchanged.
func TestDimensionlessLiteralTyperZeroStaysNeutral(t *testing.T) {
	m, err := ParseUnit("m")
	if err != nil {
		t.Fatal(err)
	}
	env := map[string]Unit{"x": m}
	rule := unitTyper{dimensionlessLiterals: true}

	zeros := []Expression{
		0.0, 0, math.Copysign(0, -1),
		ExprNode{Op: "-", Args: []any{0.0}},
		ExprNode{Op: "const", Value: 0.0},
	}
	for _, z := range zeros {
		if u, err := rule.propagate(z, env); err != nil || u != nil {
			t.Errorf("zero %#v: got %v, %v; want undeterminable", z, u, err)
		}
		// x + 0 and max(x, 0) adopt x's unit.
		for _, op := range []string{"+", "max"} {
			u, err := rule.propagate(ExprNode{Op: op, Args: []any{"x", z}}, env)
			if err != nil || u == nil || !u.Dim.Equal(m.Dim) {
				t.Errorf("%s(x, %#v): got %v, %v; want m", op, z, u, err)
			}
		}
	}

	for _, lit := range []Expression{1.0, 273.15, ExprNode{Op: "-", Args: []any{2.0}}, ExprNode{Op: "const", Value: 3.0}} {
		u, err := rule.propagate(lit, env)
		if err != nil || u == nil || !isPureNumber(u) {
			t.Errorf("nonzero %#v: got %v, %v; want dimensionless at scale 1", lit, u, err)
		}
		if u, err := propagateDimension(lit, env); err != nil || u != nil {
			t.Errorf("current rule %#v: got %v, %v; want undeterminable", lit, u, err)
		}
	}
	// A unit-bearing const keeps its unit under both rules.
	kelvin := "K"
	if u, err := rule.propagate(ExprNode{Op: "const", Value: 273.15, Units: &kelvin}, env); err != nil || u == nil || isPureNumber(u) {
		t.Errorf("const(273.15, K): got %v, %v", u, err)
	}
	// x + 1 is a mismatch under the new rule only.
	sum := ExprNode{Op: "+", Args: []any{"x", 1.0}}
	if _, err := rule.propagate(sum, env); err == nil || findingCode(err) != UnitFindingDimensionalMismatch {
		t.Errorf("x + 1 under the dimensionless-literal rule: want a mismatch, got %v", err)
	}
	if _, err := propagateDimension(sum, env); err != nil {
		t.Errorf("x + 1 under the current rule: want no finding, got %v", err)
	}
}

// A panic inside the warning pass degrades to one analysis warning; it never
// escapes to the caller of Validate.
func TestDimensionlessLiteralPanicDegradesToWarning(t *testing.T) {
	file := &ESMFile{Models: map[string]Model{"M": {
		Equations: []Equation{{
			LHS: "x",
			// A nil node pointer panics when typed.
			RHS: ExprNode{Op: "+", Args: []any{(*ExprNode)(nil), 2.0}},
		}},
	}}}
	warnings := dimensionlessLiteralFindings(file, nil)
	if len(warnings) != 1 || warnings[0].Code != UnitFindingAnalysis {
		t.Fatalf("got %+v, want one %s warning", warnings, UnitFindingAnalysis)
	}
}
