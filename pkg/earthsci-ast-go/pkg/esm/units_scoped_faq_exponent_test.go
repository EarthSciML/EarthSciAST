package esm

import (
	"path/filepath"
	"testing"
)

// Tests for three unit-checker rules (EarthSciAST#414 and constant exponents):
//
//   R1  a scoped reference carries its target's declared units, across both
//       mount forms (esm-spec §4.8.4);
//   R2  an faq's `filter` and `expr` are walked (esm-spec §4.8.3);
//   R3  a constant-expression exponent folds to an exact rational (esm-spec
//       §4.8.3 `^`).

// ---------------------------------------------------------------------------
// R1: scoped references
// ---------------------------------------------------------------------------

func TestScopedReferenceUnitsEnv(t *testing.T) {
	s := func(v string) *string { return &v }
	file := &ESMFile{
		Models: map[string]Model{
			"Top": {
				Variables: map[string]ModelVariable{
					"a":      {Type: "parameter", Units: s("kg")},
					"noUnit": {Type: "parameter"},
					"bad":    {Type: "parameter", Units: s("not_a_unit_xyz")},
				},
				Subsystems: map[string]any{
					"Inner": map[string]any{
						"variables": map[string]any{
							"b": map[string]any{"type": "parameter", "units": "m"},
						},
						"subsystems": map[string]any{
							"Deep": map[string]any{
								"variables": map[string]any{
									"c": map[string]any{"type": "parameter", "units": "s"},
								},
							},
						},
					},
					// An unresolved {ref} edge contributes nothing.
					"Stub": map[string]any{"ref": "./missing.esm"},
				},
			},
		},
		ReactionSystems: map[string]ReactionSystem{
			"Chem": {
				Species:    map[string]Species{"O3": {Units: s("mol/m^3")}},
				Parameters: map[string]Parameter{"k": {Units: s("1/s")}},
			},
		},
	}
	own := map[string]any{
		// (b) relative to the component's own subsystems; collides with the
		// (a) path "Top.a" and must win.
		"Top": map[string]any{
			"variables": map[string]any{
				"a": map[string]any{"type": "parameter", "units": "K"},
			},
		},
		"Local": map[string]any{
			"species": map[string]any{
				"X": map[string]any{"units": "ppb"},
			},
		},
	}
	env := mkEnv(t, map[string]string{"x": "m", "Local.X": "kg"})
	addScopedReferenceUnits(env, file, own)

	want := map[string]string{
		"Top.Inner.b":      "m",
		"Top.Inner.Deep.c": "s",
		"Chem.O3":          "mol/m^3",
		"Chem.k":           "1/s",
		"Top.a":            "K",  // (b) wins over (a)
		"Local.X":          "kg", // own bare names never overwritten
		"x":                "m",
	}
	for name, us := range want {
		got, ok := env[name]
		if !ok {
			t.Errorf("%s missing from env", name)
			continue
		}
		exp, err := ParseUnit(us)
		if err != nil {
			t.Fatal(err)
		}
		if !got.Dim.Equal(exp.Dim) || !got.Exact.Equal(exp.Exact) {
			t.Errorf("%s: got %s, want %s", name, got.Dim, us)
		}
	}
	for _, absent := range []string{"Top.noUnit", "Top.bad", "Top.Stub.ref"} {
		if _, ok := env[absent]; ok {
			t.Errorf("%s must be absent from env", absent)
		}
	}
}

// A scoped reference into a mounted subsystem decides an equation check that
// was previously skipped.
func TestValidateModelUnitsScopedReference(t *testing.T) {
	s := func(v string) *string { return &v }
	model := Model{
		Variables: map[string]ModelVariable{
			"p": {Type: "unknown", Units: s("kg")},
		},
		Equations: []Equation{{LHS: ExprNode{Op: "D", Args: []any{"p"}, Wrt: strPtr("t")}, RHS: "Leaf.q"}},
		Subsystems: map[string]any{
			"Leaf": map[string]any{
				"variables": map[string]any{
					"q": map[string]any{"type": "parameter", "units": "kg/s"},
					"t": map[string]any{"type": "parameter", "units": "s"},
				},
			},
		},
	}
	model.Variables["t"] = ModelVariable{Type: "parameter", Units: s("s")}
	result := &StructuralValidationResult{}
	validateModelUnits("M", &model, "/models/M", nil, result)
	if len(result.UnitWarnings) != 0 {
		t.Fatalf("consistent scoped reference flagged: %+v", result.UnitWarnings)
	}
	model.Variables["p"] = ModelVariable{Type: "unknown", Units: s("m")}
	result = &StructuralValidationResult{}
	validateModelUnits("M", &model, "/models/M", nil, result)
	if len(result.UnitWarnings) != 1 || result.UnitWarnings[0].Code != UnitFindingDimensionalMismatch {
		t.Fatalf("want one dimensional mismatch through Leaf.q, got %+v", result.UnitWarnings)
	}
}

// ---------------------------------------------------------------------------
// R2: faq filter and body
// ---------------------------------------------------------------------------

func TestPropagateDimensionFaqWalksFilterAndBody(t *testing.T) {
	env := mkEnv(t, map[string]string{"x": "m", "y": "m", "z": "kg"})
	cmp := func(a, b string) ExprNode { return ExprNode{Op: "<=", Args: []any{a, b}} }
	faq := func(filter, body any) ExprNode {
		return ExprNode{Op: "faq", Args: []any{}, Filter: filter, Expr: body}
	}

	// Consistent filter and body: no error, and (default reduce "+") the faq
	// has its body's unit.
	u, err := PropagateDimension(faq(cmp("x", "y"), ExprNode{Op: "+", Args: []any{"x", "y"}}), env)
	if err != nil {
		t.Fatalf("consistent faq errored: %v", err)
	}
	if u == nil || !u.Dim.Equal(env["x"].Dim) {
		t.Errorf("faq result must have its body's unit m, got %v", u)
	}

	// Mismatch in the filter.
	if _, err := PropagateDimension(faq(cmp("x", "z"), "x"), env); err == nil || findingCode(err) != UnitFindingDimensionalMismatch {
		t.Errorf("filter x [m] <= z [kg] must be a mismatch, got %v", err)
	}
	// Mismatch in the body, no filter.
	if _, err := PropagateDimension(faq(nil, ExprNode{Op: "+", Args: []any{"x", "z"}}), env); err == nil || findingCode(err) != UnitFindingDimensionalMismatch {
		t.Errorf("body x [m] + z [kg] must be a mismatch, got %v", err)
	}
	// The filter's boolean never contributes a unit: a dimensionless filter
	// over lengths does not make the faq dimensionless, so x * faq(.., x) is m^2.
	u, err = PropagateDimension(ExprNode{Op: "*", Args: []any{"x", faq(cmp("x", "y"), "x")}}, env)
	if err != nil || u == nil || !u.Dim.Equal(env["x"].Dim.Power(2)) {
		t.Errorf("x * faq(x <= y, x) must be m^2 without error, got %v, %v", u, err)
	}
}

// ---------------------------------------------------------------------------
// R3: constant-expression exponents
// ---------------------------------------------------------------------------

func TestConstantExponentValue(t *testing.T) {
	s := func(v string) *string { return &v }
	op := func(o string, args ...any) ExprNode { return ExprNode{Op: o, Args: args} }
	cnst := func(v any, units *string) ExprNode {
		return ExprNode{Op: "const", Args: []any{}, Value: v, Units: units}
	}

	folds := []struct {
		name string
		expr any
		want Rat
	}{
		{"int literal", 2, newRat(2, 1)},
		{"float literal", 0.5, newRat(1, 2)},
		{"int64 literal", int64(-3), newRat(-3, 1)},
		{"const no units", cnst(3.0, nil), newRat(3, 1)},
		{"const units 1", cnst(0.5, s("1")), newRat(1, 2)},
		{"const units empty", cnst(1.5, s("")), newRat(3, 2)},
		{"const units dimensionless", cnst(2.0, s("dimensionless")), newRat(2, 1)},
		{"3/2", op("/", 3, 2), newRat(3, 2)},
		{"unary minus", op("-", 1), newRat(-1, 1)},
		{"left fold minus", op("-", 10, 3, 2), newRat(5, 1)},
		{"sum", op("+", 1, 0.5, 0.25), newRat(7, 4)},
		{"unary plus", op("+", 2), newRat(2, 1)},
		{"product", op("*", 2, 3, 0.5), newRat(3, 1)},
		{"nested", op("/", op("+", 1, 2), op("*", 4, 2)), newRat(3, 8)},
		{"deep", op("-", op("-", op("/", 1, cnst(3.0, nil)))), newRat(1, 3)},
	}
	for _, c := range folds {
		got, ok := constantExponentValue(c.expr)
		if !ok {
			t.Errorf("%s: did not fold", c.name)
			continue
		}
		if !got.Equal(c.want) {
			t.Errorf("%s: got %s, want %s", c.name, got, c.want)
		}
	}

	noFold := []struct {
		name string
		expr any
	}{
		{"variable", "n"},
		{"expression with variable", op("+", "n", 1)},
		{"const percent", cnst(50.0, s("%"))},
		{"const dimensional", cnst(2.0, s("m"))},
		{"const unparseable", cnst(2.0, s("not_a_unit_xyz"))},
		{"other op", op("sqrt", 4)},
		{"division by zero", op("/", 1, 0)},
		{"division by folded zero", op("/", 1, op("-", 2, 2))},
		{"three-operand divide", op("/", 8, 2, 2)},
		{"empty plus", op("+")},
		{"overflow", op("*", 100000, 100000)},
		{"bool", true},
		{"nil", nil},
	}
	for _, c := range noFold {
		if got, ok := constantExponentValue(c.expr); ok {
			t.Errorf("%s: folded to %s, want symbolic", c.name, got)
		}
	}
}

func TestPropagateDimensionConstantExponent(t *testing.T) {
	s := func(v string) *string { return &v }
	env := mkEnv(t, map[string]string{"T": "K", "L": "km", "n": "1", "pct": "%"})
	pow := func(base, exp any) ExprNode { return ExprNode{Op: "^", Args: []any{base, exp}} }

	check := func(name string, e ExprNode, wantUnit string) {
		t.Helper()
		got, err := PropagateDimension(e, env)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		want, err := ParseUnit(wantUnit)
		if err != nil {
			t.Fatal(err)
		}
		if got == nil {
			t.Fatalf("%s: undeterminable, want %s", name, wantUnit)
		}
		if !got.Dim.Equal(want.Dim) || !got.Exact.Equal(want.Exact) {
			t.Errorf("%s: got %s at scale %s, want %s", name, got.Dim, got.Exact, wantUnit)
		}
	}
	check("T^(3/2)", pow("T", ExprNode{Op: "/", Args: []any{3, 2}}), "K^(3/2)")
	check("T^-(1)", pow("T", ExprNode{Op: "-", Args: []any{1}}), "1/K")
	// The exact scale is raised too, exactly as for a literal exponent.
	check("L^(const 2)", pow("L", ExprNode{Op: "const", Value: 2.0, Units: s("1")}), "km^2")
	check("L^2 literal", pow("L", 2), "km^2")

	// A SYMBOLIC exponent stays undeterminable, whatever the base.
	for name, e := range map[string]ExprNode{
		"L^n":           pow("L", "n"),
		"L^(n+1)":       pow("L", ExprNode{Op: "+", Args: []any{"n", 1}}),
		"L^(const 50%)": pow("L", ExprNode{Op: "const", Value: 50.0, Units: s("%")}),
		"T^(1/0)":       pow("T", ExprNode{Op: "/", Args: []any{1, 0}}),
	} {
		got, err := PropagateDimension(e, env)
		if err != nil {
			t.Errorf("%s: unexpected error %v", name, err)
		}
		if got != nil {
			t.Errorf("%s: must be undeterminable, got %s", name, got.Dim)
		}
	}

	// The existing "exponent must be dimensionless" rule is unchanged.
	if _, err := PropagateDimension(pow("T", ExprNode{Op: "const", Value: 2.0, Units: s("m")}), env); err == nil {
		t.Error("a dimensional const exponent must still be refused")
	}
}

// ---------------------------------------------------------------------------
// Fixture verdicts through the public entry point
// ---------------------------------------------------------------------------

func TestUnitsScopedFaqExponentFixtures(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	valid := []string{
		"units_mount_leaf.esm",
		"units_mount_subsystem_consistent.esm",
		"units_mount_toplevel_consistent.esm",
		"units_faq_filter_consistent.esm",
		"units_constant_exponent_folding.esm",
		"units_symbolic_exponent_undeterminable.esm",
	}
	for _, name := range valid {
		t.Run("valid/"+name, func(t *testing.T) {
			// LoadPath, so relative `ref` mounts resolve.
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

	invalid := map[string][]string{
		"units_mount_subsystem_wrong_dimension.esm": {"/models/Probe/variables/probe"},
		"units_mount_subsystem_scale_mismatch.esm":  {"/models/Probe/variables/probe"},
		"units_mount_toplevel_wrong_dimension.esm":  {"/models/Probe/variables/probe"},
		"units_mount_toplevel_scale_mismatch.esm":   {"/models/Probe/variables/probe"},
		"units_faq_filter_mismatch.esm":             {"/models/Probe/variables/n_short"},
		"units_faq_body_mismatch.esm":               {"/models/Probe/variables/total"},
		"units_constant_exponent_mismatch.esm": {
			"/models/Powers/variables/T_32",
			"/models/Powers/variables/L_const",
		},
	}
	for _, name := range sortedKeys(invalid) {
		pins := invalid[name]
		t.Run("invalid/"+name, func(t *testing.T) {
			file, err := LoadPath(filepath.Join(repoRoot, "tests", "invalid", name))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			result := Validate(file)
			if result.IsValid {
				t.Fatal("fixture is pinned is_valid:false; Go accepted it")
			}
			for _, p := range pins {
				if !hasStructuralError(result, ErrorUnitInconsistency, p) {
					t.Errorf("want unit_inconsistency @ %s, got %+v", p, result.StructuralErrors)
				}
			}
		})
	}
}
