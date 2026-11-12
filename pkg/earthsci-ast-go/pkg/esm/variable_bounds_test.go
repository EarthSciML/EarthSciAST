package esm

import (
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

// Variable bounds `lb` / `ub` (esm-spec §6.3.2): round-trip, the four
// structural rules, the esm 2.1.0 version gate and flattening.

func boundsFixture(t *testing.T, dir, name string) string {
	t.Helper()
	return filepath.Join(dsuRepoRoot(t), "tests", dir, name)
}

// emittedVariables loads path, emits it, and returns the emitted
// `models.<model>.variables` as decoded JSON.
func emittedVariables(t *testing.T, file *ESMFile, model string) map[string]map[string]any {
	t.Helper()
	text, err := ToJSON(file)
	if err != nil {
		t.Fatalf("emit: %v", err)
	}
	var doc struct {
		Models map[string]struct {
			Variables map[string]map[string]any `json:"variables"`
		} `json:"models"`
	}
	if err := json.Unmarshal([]byte(text), &doc); err != nil {
		t.Fatalf("decode emitted: %v", err)
	}
	return doc.Models[model].Variables
}

func TestVariableBoundsRoundTrip(t *testing.T) {
	file, err := LoadPath(boundsFixture(t, "valid", "variable_bounds.esm"))
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	e := file.Models["Salts"].Variables["E"]
	if e.LB == nil || e.LB.Number == nil || *e.LB.Number != 0 || e.LB.Ref != nil {
		t.Fatalf("E.lb = %+v, want the number 0", e.LB)
	}
	if e.UB == nil || e.UB.Ref == nil || *e.UB.Ref != "E_max" || e.UB.Number != nil {
		t.Fatalf("E.ub = %+v, want the reference E_max", e.UB)
	}
	if fm := file.Models["Salts"].Variables["f_max"]; fm.LB != nil || fm.UB != nil {
		t.Fatalf("f_max carries no bounds, got lb=%v ub=%v", fm.LB, fm.UB)
	}

	vars := emittedVariables(t, file, "Salts")
	want := map[string][2]any{
		"E":     {0.0, "E_max"},
		"E_max": {0.0, nil},
		"S":     {0.0, "f_max"},
		"f":     {0.0, 1.0},
		"f_max": {nil, nil},
		"k":     {0.1, 0.1},
		"W":     {-1.5, "Ions.cap"},
	}
	for name, w := range want {
		for i, field := range boundNames {
			got, present := vars[name][field]
			if w[i] == nil {
				if present {
					t.Errorf("%s.%s emitted as %v, want absent", name, field, got)
				}
				continue
			}
			if got != w[i] {
				t.Errorf("%s.%s emitted as %#v, want %#v", name, field, got, w[i])
			}
		}
	}

	// Emit then load is stable: the second emit equals the first.
	first, _ := ToJSON(file)
	again, err := LoadString(first)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	second, _ := ToJSON(again)
	if first != second {
		t.Fatal("emit(load(emit(F))) differs from emit(F)")
	}
}

func TestVariableBoundJSONForms(t *testing.T) {
	for _, tc := range []struct{ in, out string }{
		{`0`, `0`}, {`0.0`, `0`}, {`-1.5`, `-1.5`}, {`"Sub.y"`, `"Sub.y"`},
	} {
		var b VariableBound
		if err := json.Unmarshal([]byte(tc.in), &b); err != nil {
			t.Fatalf("unmarshal %s: %v", tc.in, err)
		}
		got, err := json.Marshal(b)
		if err != nil || string(got) != tc.out {
			t.Errorf("marshal(unmarshal(%s)) = %s, %v; want %s", tc.in, got, err, tc.out)
		}
	}
	var b VariableBound
	if err := json.Unmarshal([]byte(`true`), &b); err == nil {
		t.Error("a boolean bound must not decode")
	}
}

func TestVariableBoundsValidFixturesAreValid(t *testing.T) {
	for _, name := range []string{"variable_bounds.esm", "variable_bounds_shaped.esm", "variable_bounds_coupled.esm"} {
		t.Run(name, func(t *testing.T) {
			file, err := LoadPath(boundsFixture(t, "valid", name))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			if res := ValidateStructuralWithCodes(file); !res.Valid {
				t.Fatalf("valid fixture rejected: %+v", res.StructuralErrors)
			}
		})
	}
	file, err := LoadPath(boundsFixture(t, "version_compatibility", "version_2_1_0_variable_bounds.esm"))
	if err != nil {
		t.Fatalf("load the 2.1.0 compatibility fixture: %v", err)
	}
	if res := ValidateStructuralWithCodes(file); !res.Valid {
		t.Fatalf("2.1.0 compatibility fixture rejected: %+v", res.StructuralErrors)
	}
}

// boundFindings returns the bound-related findings of a validation.
func boundFindings(res *StructuralValidationResult) []StructuralError {
	var out []StructuralError
	for _, e := range res.StructuralErrors {
		if strings.Contains(e.Path, "/variables/") {
			out = append(out, e)
		}
	}
	return out
}

func expectOneFinding(t *testing.T, file *ESMFile, code, path string, details map[string]any) {
	t.Helper()
	res := ValidateStructuralWithCodes(file)
	found := boundFindings(res)
	if len(found) != 1 {
		t.Fatalf("want exactly one finding %s @ %s, got %+v (all: %+v)", code, path, found, res.StructuralErrors)
	}
	got := found[0]
	if got.Code != code || got.Path != path {
		t.Fatalf("got %s @ %s, want %s @ %s (%s)", got.Code, got.Path, code, path, got.Message)
	}
	for k, v := range details {
		if fmt.Sprint(got.Details[k]) != fmt.Sprint(v) {
			t.Errorf("details[%s] = %v, want %v (all %v)", k, got.Details[k], v, got.Details)
		}
	}
}

func TestVariableBoundsInvalidFixtures(t *testing.T) {
	for _, tc := range []struct {
		fixture, code, path string
		details             map[string]any
	}{
		{"variable_bound_unresolved.esm", ErrorUndefinedVariable, "/models/M/variables/x/ub",
			map[string]any{"variable": "x_cap", "bound": "ub"}},
		{"variable_bound_shape_mismatch.esm", CodeVariableBoundShapeMismatch, "/models/M/variables/x/ub",
			map[string]any{"variable": "x", "bound": "ub", "reference": "cap"}},
		{"variable_bound_shape_mismatch_axes.esm", CodeVariableBoundShapeMismatch, "/models/M/variables/Q/lb",
			map[string]any{"variable": "Q", "bound": "lb", "reference": "Q_min"}},
		{"variable_bound_circular_self.esm", CodeVariableBoundCircular, "/models/M/variables/x/lb",
			map[string]any{"variable": "x", "bound": "lb", "reference": "x"}},
		{"variable_bound_circular_observed.esm", CodeVariableBoundCircular, "/models/M/variables/x/ub",
			map[string]any{"variable": "x", "bound": "ub", "reference": "a"}},
		{"variable_bounds_inverted.esm", CodeVariableBoundsInverted, "/models/M/variables/x",
			map[string]any{"variable": "x", "lb": 2, "ub": 1}},
	} {
		t.Run(tc.fixture, func(t *testing.T) {
			file, err := LoadPath(boundsFixture(t, "invalid", tc.fixture))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			expectOneFinding(t, file, tc.code, tc.path, tc.details)
		})
	}

	file, _ := LoadPath(boundsFixture(t, "invalid", "variable_bound_circular_observed.esm"))
	for _, e := range ValidateStructuralWithCodes(file).StructuralErrors {
		if e.Code == CodeVariableBoundCircular && !strings.Contains(e.Message, "a -> b -> x") {
			t.Errorf("the circular finding must name the chain a -> b -> x: %s", e.Message)
		}
	}
}

// boundsDoc is a 2.1.0 document whose model M has the variables and equations
// given, plus an inline subsystem Sub and a second model Other.
func boundsDoc(esm, mVars, mEqs, subVars, subEqs string) string {
	return `{
  "esm": "` + esm + `",
  "metadata": {"name": "bounds_edge"},
  "models": {
    "M": {
      "variables": {` + mVars + `},
      "equations": [` + mEqs + `],
      "subsystems": {"Sub": {"variables": {` + subVars + `}, "equations": [` + subEqs + `]}}
    },
    "Other": {
      "variables": {"p": {"type": "parameter", "units": "1", "default": 3.0}},
      "equations": []
    }
  }
}`
}

const (
	stateX   = `"x": {"type": "unknown", "units": "1", "default": 0.5%s}, "k": {"type": "parameter", "units": "1/s", "default": 0.1}`
	decayX   = `{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": {"op": "*", "args": [{"op": "-", "args": ["k"]}, "x"]}}`
	stateY   = `"y": {"type": "unknown", "units": "1", "default": 0.5%s}, "r": {"type": "parameter", "units": "1/s", "default": 0.1}`
	decayY   = `{"lhs": {"op": "D", "args": ["y"], "wrt": "t"}, "rhs": {"op": "*", "args": [{"op": "-", "args": ["r"]}, "y"]}}`
	subPlain = `"cap": {"type": "parameter", "units": "1", "default": 2.0}`
)

func loadBoundsDoc(t *testing.T, text string) *ESMFile {
	t.Helper()
	file, err := LoadString(text)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	return file
}

func TestVariableBoundsEdgeCases(t *testing.T) {
	sub := func(bounds string) string { return fmt.Sprintf(stateY, bounds) + ", " + subPlain }
	x := func(bounds string) string { return fmt.Sprintf(stateX, bounds) }

	t.Run("dotted reference into a subsystem resolves", func(t *testing.T) {
		file := loadBoundsDoc(t, boundsDoc("2.1.0", x(`, "ub": "Sub.cap"`), decayX, sub(""), decayY))
		if res := ValidateStructuralWithCodes(file); !res.Valid {
			t.Fatalf("rejected: %+v", res.StructuralErrors)
		}
	})
	t.Run("top-level system path resolves", func(t *testing.T) {
		file := loadBoundsDoc(t, boundsDoc("2.1.0", x(`, "ub": "Other.p"`), decayX, sub(""), decayY))
		if res := ValidateStructuralWithCodes(file); !res.Valid {
			t.Fatalf("rejected: %+v", res.StructuralErrors)
		}
	})
	t.Run("unresolved dotted reference", func(t *testing.T) {
		file := loadBoundsDoc(t, boundsDoc("2.1.0", x(`, "ub": "Sub.nope"`), decayX, sub(""), decayY))
		expectOneFinding(t, file, ErrorUndefinedVariable, "/models/M/variables/x/ub",
			map[string]any{"variable": "Sub.nope", "bound": "ub"})
	})
	t.Run("bare name in a subsystem is the subsystem's own", func(t *testing.T) {
		file := loadBoundsDoc(t, boundsDoc("2.1.0", x(""), decayX, sub(`, "ub": "cap"`), decayY))
		if res := ValidateStructuralWithCodes(file); !res.Valid {
			t.Fatalf("rejected: %+v", res.StructuralErrors)
		}
		// `k` is the parent's, not the subsystem's.
		file = loadBoundsDoc(t, boundsDoc("2.1.0", x(""), decayX, sub(`, "lb": "k"`), decayY))
		expectOneFinding(t, file, ErrorUndefinedVariable, "/models/M/subsystems/Sub/variables/y/lb",
			map[string]any{"variable": "k", "bound": "lb"})
	})
	t.Run("circular in a subsystem", func(t *testing.T) {
		file := loadBoundsDoc(t, boundsDoc("2.1.0", x(""), decayX, sub(`, "ub": "y"`), decayY))
		expectOneFinding(t, file, CodeVariableBoundCircular, "/models/M/subsystems/Sub/variables/y/ub",
			map[string]any{"variable": "y", "bound": "ub", "reference": "y"})
	})
	t.Run("inverted in a subsystem", func(t *testing.T) {
		file := loadBoundsDoc(t, boundsDoc("2.1.0", x(""), decayX, sub(`, "lb": 3, "ub": -3`), decayY))
		expectOneFinding(t, file, CodeVariableBoundsInverted, "/models/M/subsystems/Sub/variables/y",
			map[string]any{"variable": "y", "lb": 3, "ub": -3})
	})
	t.Run("equal numeric bounds are legal", func(t *testing.T) {
		file := loadBoundsDoc(t, boundsDoc("2.1.0", x(`, "lb": 1, "ub": 1`), decayX, sub(""), decayY))
		if res := ValidateStructuralWithCodes(file); !res.Valid {
			t.Fatalf("rejected: %+v", res.StructuralErrors)
		}
	})
	t.Run("shaped subsystem reference against a scalar", func(t *testing.T) {
		doc := boundsDoc("2.1.0", x(`, "ub": "Sub.caps"`), decayX,
			sub("")+`, "caps": {"type": "parameter", "units": "1", "shape": ["s"], "default": [1.0, 2.0]}`, decayY)
		doc = strings.Replace(doc, `"models": {`, `"index_sets": {"s": {"kind": "interval", "size": 2}}, "models": {`, 1)
		file := loadBoundsDoc(t, doc)
		expectOneFinding(t, file, CodeVariableBoundShapeMismatch, "/models/M/variables/x/ub",
			map[string]any{"variable": "x", "bound": "ub", "reference": "Sub.caps"})
	})

	// An observed that depends on a DIFFERENT state is a legal bound; one that
	// depends on the bounded state through a subsystem observed is circular.
	obs := `, "o": {"type": "unknown", "units": "1"}`
	t.Run("observed bound on another state", func(t *testing.T) {
		vars := x(`, "ub": "o"`) + obs + `, "w": {"type": "unknown", "units": "1", "default": 1.0}`
		eqs := decayX + `, {"lhs": {"op": "D", "args": ["w"], "wrt": "t"}, "rhs": {"op": "-", "args": ["w"]}}` +
			`, {"lhs": "o", "rhs": {"op": "*", "args": [2, "w"]}}`
		file := loadBoundsDoc(t, boundsDoc("2.1.0", vars, eqs, sub(""), decayY))
		if res := ValidateStructuralWithCodes(file); !res.Valid {
			t.Fatalf("rejected: %+v", res.StructuralErrors)
		}
	})
	t.Run("circular across a subsystem observed", func(t *testing.T) {
		vars := x(`, "ub": "o"`) + obs
		eqs := decayX + `, {"lhs": "o", "rhs": {"op": "+", "args": ["Sub.q", 1]}}`
		subVars := sub("") + `, "q": {"type": "unknown", "units": "1"}`
		subEqs := decayY + `, {"lhs": "q", "rhs": {"op": "*", "args": [2, "M.x"]}}`
		file := loadBoundsDoc(t, boundsDoc("2.1.0", vars, eqs, subVars, subEqs))
		res := ValidateStructuralWithCodes(file)
		var hit *StructuralError
		for i, e := range res.StructuralErrors {
			if e.Code == CodeVariableBoundCircular {
				hit = &res.StructuralErrors[i]
			}
		}
		if hit == nil || hit.Path != "/models/M/variables/x/ub" {
			t.Fatalf("want variable_bound_circular @ /models/M/variables/x/ub, got %+v", res.StructuralErrors)
		}
		if !strings.Contains(hit.Message, "M.o -> M.Sub.q -> M.x") {
			t.Errorf("the chain must be named in full scoped names: %s", hit.Message)
		}
	})
}

func TestVariableBoundsVersionGate(t *testing.T) {
	pins := resolverOnlyPins(t, dsuRepoRoot(t))
	if pins["variable_bounds_version_too_old.esm"] != CodeVariableBoundsVersionTooOld {
		t.Fatalf("expected_errors.json must pin variable_bounds_version_too_old.esm resolver_only with %q",
			CodeVariableBoundsVersionTooOld)
	}
	_, err := LoadPath(boundsFixture(t, "invalid", "variable_bounds_version_too_old.esm"))
	var de DiagnosticError
	if err == nil || !errors.As(err, &de) || de.DiagnosticCode() != CodeVariableBoundsVersionTooOld {
		t.Fatalf("want %s at load, got %v", CodeVariableBoundsVersionTooOld, err)
	}
	if !strings.Contains(err.Error(), "/models/M/variables/x/lb") {
		t.Errorf("the diagnostic must name /models/M/variables/x/lb: %v", err)
	}

	// A bound in a subsystem only: the pointer runs through the subsystem.
	sub := fmt.Sprintf(stateY, `, "ub": "cap"`) + ", " + subPlain
	_, err = LoadString(boundsDoc("2.0.0", fmt.Sprintf(stateX, ""), decayX, sub, decayY))
	if err == nil || !strings.Contains(err.Error(), CodeVariableBoundsVersionTooOld) ||
		!strings.Contains(err.Error(), "/models/M/subsystems/Sub/variables/y/ub") {
		t.Fatalf("want the gate at the subsystem pointer, got %v", err)
	}

	// The same document without bounds loads at 2.0.0.
	plain := fmt.Sprintf(stateY, "") + ", " + subPlain
	if _, err := LoadString(boundsDoc("2.0.0", fmt.Sprintf(stateX, ""), decayX, plain, decayY)); err != nil {
		t.Fatalf("a 2.0.0 document without bounds must load: %v", err)
	}
}

// Each file is held to its own declared version: a 2.0.0 leaf carrying a bound
// is refused under a 2.1.0 root, and a 2.1.0 leaf carrying one loads under a
// 2.0.0 root.
func TestVariableBoundsVersionGatePerFile(t *testing.T) {
	leaf := func(esm string) string {
		return `{"esm": "` + esm + `", "metadata": {"name": "leaf"}, "models": {"Leaf": {
  "variables": {"q": {"type": "parameter", "units": "1", "default": 1.0, "lb": 0}},
  "equations": []}}}`
	}
	root := func(esm string) string {
		return `{"esm": "` + esm + `", "metadata": {"name": "root"}, "models": {"Host": {
  "variables": {"x": {"type": "unknown", "units": "1", "default": 1.0}},
  "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": {"op": "-", "args": ["Leaf.q"]}}],
  "subsystems": {"Leaf": {"ref": "./leaf.esm"}}}}}`
	}

	dir := t.TempDir()
	writePerFileGateDoc(t, dir, "leaf.esm", leaf("2.0.0"))
	r := writePerFileGateDoc(t, dir, "root.esm", root("2.1.0"))
	if _, err := LoadPath(r); err == nil || !strings.Contains(err.Error(), CodeVariableBoundsVersionTooOld) {
		t.Fatalf("a 2.0.0 leaf with a bound must be refused under a 2.1.0 root, got %v", err)
	}

	dir = t.TempDir()
	writePerFileGateDoc(t, dir, "leaf.esm", leaf("2.1.0"))
	r = writePerFileGateDoc(t, dir, "root.esm", root("2.0.0"))
	file, err := LoadPath(r)
	if err != nil {
		t.Fatalf("a 2.1.0 leaf with a bound must load under a 2.0.0 root: %v", err)
	}

	// The assembled document carries the leaf's bound, so its declared version
	// is raised to 2.1.0: emit then reload is accepted.
	if file.ESM != "2.1.0" {
		t.Errorf("resolved esm = %q, want the raised 2.1.0 floor", file.ESM)
	}
	text, err := ToJSON(file)
	if err != nil {
		t.Fatalf("emit: %v", err)
	}
	var probe struct {
		ESM string `json:"esm"`
	}
	if err := json.Unmarshal([]byte(text), &probe); err != nil || probe.ESM != "2.1.0" {
		t.Fatalf("emitted esm = %q (%v), want 2.1.0", probe.ESM, err)
	}
	again, err := LoadString(text)
	if err != nil {
		t.Fatalf("reloading the emitted assembly must succeed: %v", err)
	}
	if again.Models["Host"].Subsystems["Leaf"] == nil {
		t.Fatal("the reloaded assembly lost the mounted leaf")
	}
}

// The emit floor raises only a document that carries a bound and declares
// less than 2.1.0, and only ever raises.
func TestVariableBoundsEsmFloor(t *testing.T) {
	with := boundsDoc("2.0.0", fmt.Sprintf(stateX, `, "lb": 0`), decayX, subPlain, "")
	if got := raiseVariableBoundsEsmFloor(with); !strings.Contains(got, `"esm": "2.1.0"`) {
		t.Errorf("a 2.0.0 document with a bound must be raised to 2.1.0:\n%s", got)
	}
	inSub := boundsDoc("1.3.0", fmt.Sprintf(stateX, ""), decayX, subPlain+`, "z": {"type": "parameter", "units": "1", "default": 1.0, "ub": "cap"}`, "")
	if got := raiseVariableBoundsEsmFloor(inSub); !strings.Contains(got, `"esm": "2.1.0"`) {
		t.Errorf("a bound in a subsystem must raise the floor:\n%s", got)
	}
	without := boundsDoc("2.0.0", fmt.Sprintf(stateX, ""), decayX, subPlain, "")
	if got := raiseVariableBoundsEsmFloor(without); got != without {
		t.Error("a document without bounds must be left unchanged")
	}
	newer := boundsDoc("2.2.0", fmt.Sprintf(stateX, `, "lb": 0`), decayX, subPlain, "")
	if got := raiseVariableBoundsEsmFloor(newer); got != newer {
		t.Error("the floor must never lower a newer declared version")
	}
}

func TestVariableBoundsFlatten(t *testing.T) {
	file, err := LoadPath(boundsFixture(t, "valid", "variable_bounds_coupled.esm"))
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	flat, err := Flatten(file)
	if err != nil {
		t.Fatalf("flatten: %v", err)
	}
	want := map[string][2]any{
		"Chem.x":         {"Chem.x_min", "Met.cap_src"},
		"Chem.z":         {0.0, "Chem.Sub.y"},
		"Chem.Sub.y":     {0.0, "Chem.Sub.y_cap"},
		"Met.cap_src":    {0.0, nil},
		"Chem.x_min":     {nil, nil},
		"Chem.k":         {nil, nil},
		"Chem.Sub.r":     {nil, nil},
		"Chem.Sub.y_cap": {nil, nil},
	}
	seen := map[string]bool{}
	for _, table := range [][]FlattenedVariable{flat.StateVariables, flat.Parameters, flat.ObservedVariables} {
		for _, v := range table {
			seen[v.Name] = true
			w, ok := want[v.Name]
			if !ok {
				t.Errorf("unexpected flattened variable %s", v.Name)
				continue
			}
			for i, got := range []any{goBoundRecord(v.LB), goBoundRecord(v.UB)} {
				if !sameBound(got, w[i]) {
					t.Errorf("%s.%s = %#v, want %#v", v.Name, boundNames[i], got, w[i])
				}
			}
		}
	}
	if seen["Chem.x_cap"] {
		t.Error("the variable_map target Chem.x_cap must leave the flattened system")
	}
	for name := range want {
		if !seen[name] {
			t.Errorf("flattened system lacks %s", name)
		}
	}
}

// A scaled variable_map replacement leaves the replacement expression as the
// flattened bound.
func TestVariableBoundsFlattenScaledReplacement(t *testing.T) {
	doc := `{"esm": "2.1.0", "metadata": {"name": "scaled"},
  "models": {
    "A": {"variables": {
        "x": {"type": "unknown", "units": "1", "default": 0.5, "ub": "cap"},
        "cap": {"type": "parameter", "units": "1", "default": 1.0}},
      "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": {"op": "-", "args": ["x", "cap"]}}]},
    "B": {"variables": {"src": {"type": "parameter", "units": "1", "default": 2.0}}, "equations": []}
  },
  "coupling": [{"type": "variable_map", "from": "B.src", "to": "A.cap", "transform": "conversion_factor", "factor": 2.0}]
}`
	flat, err := Flatten(loadBoundsDoc(t, doc))
	if err != nil {
		t.Fatalf("flatten: %v", err)
	}
	v, ok := flat.Lookup("A.x")
	if !ok {
		t.Fatal("A.x missing")
	}
	if got := ToASCII(v.UB); got != ToASCII(ExprNode{Op: "*", Args: []any{2.0, "B.src"}}) {
		t.Fatalf("A.x ub = %s, want the scaled replacement", got)
	}
}
