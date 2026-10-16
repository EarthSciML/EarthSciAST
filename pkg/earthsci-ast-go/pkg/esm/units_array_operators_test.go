package esm

import (
	"path/filepath"
	"testing"
)

// Tests for the array-operator unit rules of the checker (esm-spec §4.8.3,
// EarthSciAST#414 follow-up):
//
//	A1  index(a, ...) has a's unit; no args is undeterminable;
//	A2  reshape / transpose have args[0]'s unit; no args is undeterminable;
//	A3  concat's operands agree like those of an n-ary `+`;
//	A4  makearray's region values agree like the operands of `+`;
//	A5  broadcast(fn=F, args) has the unit of {op: F, args};
//	A6  an faq's unit is decided by its ⊕ (semiring, else reduce).

func arrayEnv(t *testing.T) map[string]Unit {
	t.Helper()
	return mkEnv(t, map[string]string{
		"a":   "m",
		"b":   "m",
		"km":  "km",
		"z":   "kg",
		"w":   "1",
		"ppm": "ppm",
	})
}

// wantUnit asserts expr propagates without error to the unit of spelling want
// ("" means undeterminable).
func wantUnit(t *testing.T, label string, expr Expression, env map[string]Unit, want string) {
	t.Helper()
	u, err := PropagateDimension(expr, env)
	if err != nil {
		t.Errorf("%s: unexpected error %v", label, err)
		return
	}
	if want == "" {
		if u != nil {
			t.Errorf("%s: want undeterminable, got %s (scale %s)", label, u.Dim, u.Exact)
		}
		return
	}
	w, perr := ParseUnit(want)
	if perr != nil {
		t.Fatalf("%s: parse %q: %v", label, want, perr)
	}
	if u == nil {
		t.Errorf("%s: want %s, got undeterminable", label, want)
		return
	}
	if !u.Dim.Equal(w.Dim) || !u.Exact.Equal(w.Exact) {
		t.Errorf("%s: want %s, got %s at scale %s", label, want, u.Dim, u.Exact)
	}
}

// wantMismatch asserts expr is a provable dimensional mismatch.
func wantMismatch(t *testing.T, label string, expr Expression, env map[string]Unit) {
	t.Helper()
	_, err := PropagateDimension(expr, env)
	if err == nil || findingCode(err) != UnitFindingDimensionalMismatch {
		t.Errorf("%s: want a dimensional mismatch, got %v", label, err)
	}
}

func TestArrayIndexReshapeTransposeUnits(t *testing.T) {
	env := arrayEnv(t)
	for _, op := range []string{"index", "reshape", "transpose"} {
		wantUnit(t, op+"(a, ...)", ExprNode{Op: op, Args: []any{"a", "i", 2}}, env, "m")
		wantUnit(t, op+"(km)", ExprNode{Op: op, Args: []any{"km"}}, env, "km")
		// No source: undeterminable, NOT dimensionless.
		wantUnit(t, op+"()", ExprNode{Op: op, Args: []any{}}, env, "")
		// An undeterminable source stays undeterminable.
		wantUnit(t, op+"(undeclared)", ExprNode{Op: op, Args: []any{"nope", "i"}}, env, "")
	}
	// The subscripts are not part of the unit.
	wantUnit(t, "index(a, z)", ExprNode{Op: "index", Args: []any{"a", "z"}}, env, "m")
	// index composes: a comparison of two indexed arrays in different
	// dimensions is a mismatch.
	wantMismatch(t, "index(a,i) <= index(z,j)", ExprNode{Op: "<=", Args: []any{
		ExprNode{Op: "index", Args: []any{"a", "i"}},
		ExprNode{Op: "index", Args: []any{"z", "j"}},
	}}, env)
}

func TestArrayConcatUnits(t *testing.T) {
	env := arrayEnv(t)
	concat := func(args ...any) ExprNode { return ExprNode{Op: "concat", Args: args} }
	wantUnit(t, "concat(a, b)", concat("a", "b"), env, "m")
	// Undeterminable operands are skipped.
	wantUnit(t, "concat(1.0, a)", concat(1.0, "a"), env, "m")
	wantUnit(t, "concat(nope, b)", concat("nope", "b"), env, "m")
	// None determinable / no operands: undeterminable.
	wantUnit(t, "concat(1.0, 2.0)", concat(1.0, 2.0), env, "")
	wantUnit(t, "concat()", concat(), env, "")
	// Every determinable operand must agree -- not only args[0].
	wantMismatch(t, "concat(a, z)", concat("a", "z"), env)
	wantMismatch(t, "concat(1.0, a, b, z)", concat(1.0, "a", "b", "z"), env)
	// ... in scale as well as dimension.
	wantMismatch(t, "concat(a, km)", concat("a", "km"), env)
}

func TestArrayMakearrayUnits(t *testing.T) {
	env := arrayEnv(t)
	mk := func(values ...any) ExprNode { return ExprNode{Op: "makearray", Args: []any{}, Values: values} }
	wantUnit(t, "makearray(a, b)", mk("a", "b"), env, "m")
	// A bare-literal region takes the other region's unit.
	wantUnit(t, "makearray(a, 0.0)", mk("a", 0.0), env, "m")
	wantUnit(t, "makearray(0.0, km)", mk(0.0, "km"), env, "km")
	// No determinable value, or no values at all: undeterminable (not
	// dimensionless).
	wantUnit(t, "makearray(0.0, 1.0)", mk(0.0, 1.0), env, "")
	wantUnit(t, "makearray()", mk(), env, "")
	wantUnit(t, "makearray(values=nil)", ExprNode{Op: "makearray", Args: []any{}}, env, "")
	// Regions must share units, in dimension and scale.
	wantMismatch(t, "makearray(a, z)", mk("a", "z"), env)
	wantMismatch(t, "makearray(a, 0.0, km)", mk("a", 0.0, "km"), env)
	// A mismatch INSIDE a region value is reported.
	wantMismatch(t, "makearray(a + z)", mk(ExprNode{Op: "+", Args: []any{"a", "z"}}), env)
}

func TestArrayBroadcastUnits(t *testing.T) {
	env := arrayEnv(t)
	bc := func(fn string, args ...any) ExprNode {
		return ExprNode{Op: "broadcast", Fn: &fn, Args: args}
	}
	wantUnit(t, "broadcast(*, a, z)", bc("*", "a", "z"), env, "m*kg")
	wantUnit(t, "broadcast(+, a, b)", bc("+", "a", "b"), env, "m")
	wantMismatch(t, "broadcast(+, a, z)", bc("+", "a", "z"), env)
	wantMismatch(t, "broadcast(exp, a)", bc("exp", "a"), env)
	// Missing fn: undeterminable.
	wantUnit(t, "broadcast(no fn)", ExprNode{Op: "broadcast", Args: []any{"a"}}, env, "")
}

func TestArrayFaqUnitBySemiring(t *testing.T) {
	env := arrayEnv(t)
	s := func(v string) *string { return &v }
	tru := true
	idx := func(name string) ExprNode { return ExprNode{Op: "index", Args: []any{name, "i"}} }
	faq := func(semiring, reduce *string, body Expression) ExprNode {
		return ExprNode{Op: "faq", Args: []any{}, Semiring: semiring, Reduce: reduce, Expr: body}
	}

	// ⊕ = +, max, min: the body's unit.
	for _, sr := range []string{"sum_product", "max_product", "min_sum", "max_sum"} {
		wantUnit(t, "semiring "+sr, faq(s(sr), nil, idx("a")), env, "m")
	}
	for _, r := range []string{"+", "max", "min"} {
		wantUnit(t, "reduce "+r, faq(nil, s(r), idx("km")), env, "km")
	}
	wantUnit(t, "default reduce", faq(nil, nil, idx("a")), env, "m")
	// The semiring supersedes reduce.
	wantUnit(t, "semiring over reduce *", faq(s("sum_product"), s("*"), idx("a")), env, "m")

	// reduce "*": a pure-number body keeps its unit, a dimensional body (or a
	// dimensionless body at a scale other than 1) is undeterminable -- the
	// power is the range length.
	wantUnit(t, "reduce * of a pure number", faq(nil, s("*"), idx("w")), env, "1")
	wantUnit(t, "reduce * of a length", faq(nil, s("*"), idx("a")), env, "")
	wantUnit(t, "reduce * of ppm", faq(nil, s("*"), idx("ppm")), env, "")
	wantUnit(t, "reduce * of an undeterminable body", faq(nil, s("*"), 2.0), env, "")

	// bool_and_or: dimensionless, whatever the body is.
	wantUnit(t, "bool_and_or of a length", faq(s("bool_and_or"), nil, idx("a")), env, "1")
	wantUnit(t, "bool_and_or of a comparison", faq(s("bool_and_or"), nil,
		ExprNode{Op: ">", Args: []any{idx("a"), idx("b")}}), env, "1")

	// Value invention: undeterminable.
	d := faq(s("sum_product"), nil, idx("a"))
	d.Distinct = &tru
	wantUnit(t, "distinct", d, env, "")
	k := faq(nil, nil, idx("a"))
	k.Key = "i"
	wantUnit(t, "key", k, env, "")
	notDistinct := false
	nd := faq(nil, nil, idx("a"))
	nd.Distinct = &notDistinct
	wantUnit(t, "distinct: false", nd, env, "m")

	// No expr, or an unknown ⊕ spelling: undeterminable.
	wantUnit(t, "no expr", faq(s("sum_product"), nil, nil), env, "")
	wantUnit(t, "unknown semiring", faq(s("tropical"), nil, idx("a")), env, "")
	wantUnit(t, "unknown reduce", faq(nil, s("avg"), idx("a")), env, "")

	// filter and expr are ALWAYS walked, whatever the ⊕ decides.
	bad := ExprNode{Op: "+", Args: []any{"a", "z"}}
	wantMismatch(t, "distinct with a bad body", ExprNode{Op: "faq", Args: []any{}, Distinct: &tru, Expr: bad}, env)
	wantMismatch(t, "bool_and_or with a bad body", faq(s("bool_and_or"), nil, bad), env)
	wantMismatch(t, "reduce * with a bad filter", ExprNode{Op: "faq", Args: []any{}, Reduce: s("*"),
		Filter: ExprNode{Op: "<=", Args: []any{idx("a"), idx("z")}}, Expr: idx("w")}, env)
	wantMismatch(t, "no expr with a bad filter", ExprNode{Op: "faq", Args: []any{},
		Filter: ExprNode{Op: "<=", Args: []any{"a", "z"}}}, env)

	// The faq's unit enters its context: cd-valued sum vs a declared m.
	wantMismatch(t, "a + faq(sum of z)", ExprNode{Op: "+", Args: []any{"a", faq(nil, nil, idx("z"))}}, env)
}

// TestArrayOperatorFixtures pins the RULES2 fixture verdicts through LoadPath +
// Validate (so the {ref} mounts resolve).
func TestArrayOperatorFixtures(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	for _, name := range []string{
		"units_array_operators_consistent.esm",
		"units_array_mount_index_faq_consistent.esm",
		"units_array_mount_leaf.esm",
	} {
		t.Run("valid/"+name, func(t *testing.T) {
			file, err := LoadPath(filepath.Join(repoRoot, "tests", "valid", name))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			result := Validate(file)
			if !result.IsValid {
				for _, e := range result.StructuralErrors {
					t.Errorf("[%s] %s: %s", e.Code, e.Path, e.Message)
				}
				t.Fatal("expected a tests/valid fixture to validate")
			}
		})
	}
	invalid := map[string]string{
		"units_array_index_filter_mismatch.esm":    "/models/Probe/variables/p_count",
		"units_array_mount_index_faq_mismatch.esm": "/models/Mount/variables/total",
		"units_array_concat_mismatch.esm":          "/models/Probe/variables/joined",
		"units_array_makearray_mismatch.esm":       "/models/Probe/variables/mixed",
		"units_array_reshape_mismatch.esm":         "/models/Probe/variables/out",
		"units_array_transpose_mismatch.esm":       "/models/Probe/variables/out",
		"units_array_broadcast_mismatch.esm":       "/models/Probe/variables/out",
	}
	for _, name := range sortedKeys(invalid) {
		pin := invalid[name]
		t.Run("invalid/"+name, func(t *testing.T) {
			file, err := LoadPath(filepath.Join(repoRoot, "tests", "invalid", name))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			result := Validate(file)
			if result.IsValid {
				t.Fatal("fixture is pinned is_valid:false; Go accepted it")
			}
			if !hasStructuralError(result, ErrorUnitInconsistency, pin) {
				t.Errorf("want unit_inconsistency @ %s, got %+v", pin, result.StructuralErrors)
			}
		})
	}
}
