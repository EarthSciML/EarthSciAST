package esm

import (
	"math"
	"path/filepath"
	"testing"
)

// Tests for the cross-binding unit-checker rules agreed in the PR #508 review:
// a component-relative scoped path shadows a top-level one even without units;
// index / reshape / transpose (and faq, makearray, broadcast) walk every
// operand; the top-level scoped units are built once per document; and the
// checked Rat arithmetic behind constant-exponent folding.

func TestScopedUnitIndexUnitlessSubsystemMemberShadows(t *testing.T) {
	file := &ESMFile{
		Models: map[string]Model{
			"B": {Variables: map[string]ModelVariable{
				"x": {Type: "parameter", Units: strPtr("kg")},
				"y": {Type: "parameter", Units: strPtr("s")},
			}},
		},
	}
	own := map[string]any{
		"B": map[string]any{
			"variables": map[string]any{
				"x": map[string]any{"type": "parameter"},
				"z": map[string]any{"type": "parameter", "units": 7.0},
			},
		},
	}
	env := mkEnv(t, map[string]string{"q": "m"})
	newScopedUnitIndex(file).extend(env, own)
	for _, name := range []string{"B.x", "B.z"} {
		if u, ok := env[name]; ok {
			t.Errorf("%s: the unitless subsystem member must shadow, got %s", name, u.Dim)
		}
	}
	// A top-level name the component does not shadow still resolves.
	if u, ok := env["B.y"]; !ok || !u.Dim.Equal(Dimension{dimTime: ratInt(1)}) {
		t.Errorf("B.y: want s, got %+v (present=%v)", u, ok)
	}

	// The same index serves a component without the shadowing subsystem.
	env2 := mkEnv(t, map[string]string{})
	newScopedUnitIndex(file).extend(env2, nil)
	if _, ok := env2["B.x"]; !ok {
		t.Error("B.x: the top-level kg must apply where nothing shadows it")
	}
}

// One index is shared across components and is not mutated by extend.
func TestScopedUnitIndexSharedAcrossComponents(t *testing.T) {
	file := &ESMFile{
		Models: map[string]Model{
			"B": {Variables: map[string]ModelVariable{"x": {Type: "parameter", Units: strPtr("kg")}}},
		},
	}
	ix := newScopedUnitIndex(file)
	shadow := map[string]any{"B": map[string]any{"variables": map[string]any{"x": map[string]any{}}}}
	ix.extend(mkEnv(t, map[string]string{}), shadow)
	env := mkEnv(t, map[string]string{})
	ix.extend(env, nil)
	if _, ok := env["B.x"]; !ok {
		t.Error("a shadowing component must not remove B.x from the shared index")
	}
	// A nil index (no document) still adds the component-relative paths.
	var none *scopedUnitIndex
	env = mkEnv(t, map[string]string{})
	none.extend(env, map[string]any{"S": map[string]any{"variables": map[string]any{"v": map[string]any{"units": "m"}}}})
	if _, ok := env["S.v"]; !ok {
		t.Error("S.v missing with a nil index")
	}
}

func TestValidateModelUnitsUnitlessShadowSkipsCheck(t *testing.T) {
	file := &ESMFile{
		Models: map[string]Model{
			"B": {Variables: map[string]ModelVariable{"x": {Type: "parameter", Units: strPtr("kg")}}},
		},
	}
	model := Model{
		Variables: map[string]ModelVariable{"y": {Type: "unknown", Units: strPtr("m")}},
		Equations: []Equation{{LHS: "y", RHS: "B.x"}},
		Subsystems: map[string]any{
			"B": map[string]any{"variables": map[string]any{"x": map[string]any{"type": "parameter"}}},
		},
	}
	result := &StructuralValidationResult{}
	validateModelUnits("A", &model, "/models/A", newScopedUnitIndex(file), result)
	if len(result.UnitWarnings) != 0 {
		t.Fatalf("y [m] = B.x with a unitless shadowing B.x must not be checked: %+v", result.UnitWarnings)
	}
	// Without the shadowing subsystem, the top-level kg decides the check.
	model.Subsystems = nil
	result = &StructuralValidationResult{}
	validateModelUnits("A", &model, "/models/A", newScopedUnitIndex(file), result)
	if len(result.UnitWarnings) != 1 {
		t.Fatalf("want one mismatch through the top-level B.x, got %+v", result.UnitWarnings)
	}
}

func TestArrayOperatorsWalkEveryOperand(t *testing.T) {
	env := arrayEnv(t)
	bad := ExprNode{Op: "+", Args: []any{"a", "z"}} // m + kg
	for _, op := range []string{"index", "reshape", "transpose"} {
		wantMismatch(t, op+"(a, a+z)", ExprNode{Op: op, Args: []any{"a", bad}}, env)
		wantMismatch(t, op+"(a, 1, a+z)", ExprNode{Op: op, Args: []any{"a", 1, bad}}, env)
		// The result is still args[0]'s unit, and a dimensional subscript is
		// not itself an error.
		wantUnit(t, op+"(a, z)", ExprNode{Op: op, Args: []any{"a", "z"}}, env, "m")
		wantUnit(t, op+"(nope, a)", ExprNode{Op: op, Args: []any{"nope", "a"}}, env, "")
	}
	sum := "+"
	wantMismatch(t, "faq args", ExprNode{Op: "faq", Reduce: &sum, Expr: "a", Args: []any{bad}}, env)
	wantMismatch(t, "faq without expr, args", ExprNode{Op: "faq", Args: []any{bad}}, env)
	wantMismatch(t, "makearray args", ExprNode{Op: "makearray", Args: []any{bad}, Values: []any{"a"}}, env)
	wantMismatch(t, "broadcast without fn", ExprNode{Op: "broadcast", Args: []any{bad}}, env)
	wantUnit(t, "broadcast without fn", ExprNode{Op: "broadcast", Args: []any{"a"}}, env, "")
	// As in TypeScript, a missing body leaves the unit unknown whatever the ⊕.
	boolSR := "bool_and_or"
	wantUnit(t, "faq bool_and_or, no expr", ExprNode{Op: "faq", Semiring: &boolSR}, env, "")
}

func TestRatChecked(t *testing.T) {
	if r, ok := newRatChecked(6, -4); !ok || r != (Rat{Num: -3, Den: 2}) {
		t.Errorf("newRatChecked(6,-4) = %v, %v", r, ok)
	}
	if r, ok := newRatChecked(5, 0); !ok || r != (Rat{Num: 5, Den: 1}) {
		t.Errorf("newRatChecked(5,0) = %v, %v", r, ok)
	}
	if _, ok := newRatChecked(math.MaxInt32+1, 1); ok {
		t.Error("numerator overflow must be reported")
	}
	if _, ok := newRatChecked(1, math.MaxInt32+1); ok {
		t.Error("denominator overflow must be reported")
	}
	if _, ok := newRatChecked(math.MinInt32, 1); !ok {
		t.Error("MinInt32 fits")
	}
	// The unchecked forms keep their result on the in-range path.
	big := Rat{Num: 100000, Den: 1}
	if _, ok := big.MulChecked(big); ok {
		t.Error("MulChecked overflow must be reported")
	}
	if s, ok := (Rat{Num: 1, Den: 2}).AddChecked(Rat{Num: 1, Den: 3}); !ok || !s.Equal(newRat(5, 6)) || s != (Rat{1, 2}).Add(Rat{1, 3}) {
		t.Errorf("AddChecked = %v, %v", s, ok)
	}
	if d, ok := (Rat{Num: 1, Den: 2}).SubChecked(Rat{Num: 1, Den: 3}); !ok || d != (Rat{1, 2}).Sub(Rat{1, 3}) || !d.Equal(newRat(1, 6)) {
		t.Errorf("SubChecked = %v, %v", d, ok)
	}
	if _, ok := (Rat{Num: math.MaxInt32, Den: 1}).AddChecked(Rat{Num: 1, Den: 1}); ok {
		t.Error("AddChecked overflow must be reported")
	}
	if _, ok := (Rat{Num: math.MinInt32, Den: 1}).SubChecked(Rat{Num: 1, Den: 1}); ok {
		t.Error("SubChecked overflow must be reported")
	}
	// Folding a divide by a negative number normalises the sign.
	if r, ok := constantExponentValue(ExprNode{Op: "/", Args: []any{3, -6}}); !ok || r != (Rat{Num: -1, Den: 2}) {
		t.Errorf("3 / -6 = %v, %v", r, ok)
	}
}

func TestUnitsReviewFixtures(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	file, err := LoadPath(filepath.Join(repoRoot, "tests", "valid", "units_scoped_reference_unitless_shadow.esm"))
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if result := Validate(file); !result.IsValid {
		t.Errorf("units_scoped_reference_unitless_shadow.esm rejected: %+v", result.StructuralErrors)
	}
	invalid := map[string]string{
		"units_reaction_rate_scoped_reference_mismatch.esm": "/reaction_systems/Chem/reactions/0",
		"units_constant_exponent_angle.esm":                 "/models/Powers/variables/x_sq",
		"units_array_index_subscript_mismatch.esm":          "/models/Probe/variables/T_pick",
	}
	for _, name := range sortedKeys(invalid) {
		t.Run(name, func(t *testing.T) {
			file, err := LoadPath(filepath.Join(repoRoot, "tests", "invalid", name))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			result := Validate(file)
			if result.IsValid {
				t.Fatal("fixture is pinned is_valid:false; Go accepted it")
			}
			if !hasStructuralError(result, ErrorUnitInconsistency, invalid[name]) {
				t.Errorf("want unit_inconsistency @ %s, got %+v", invalid[name], result.StructuralErrors)
			}
		})
	}
}
