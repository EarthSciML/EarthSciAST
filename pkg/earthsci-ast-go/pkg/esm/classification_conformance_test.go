package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// classification_conformance_test.go drives the CROSS-LANGUAGE oracle for the
// esm-spec §6.3.1 classification API: tests/conformance/classification/, a
// manifest plus five fixtures with authored goldens.
//
// The format declares two variable types and derives everything else, so five
// bindings deriving it independently is five chances to disagree about which
// unknowns are ODE states and which parameters fold. These goldens pin one
// answer; Go is listed in the manifest's `bindings_required`.

type classificationGolden struct {
	Models map[string]struct {
		ODEStates          []string `json:"ode_states"`
		ObservedUnknowns   []string `json:"observed_unknowns"`
		AlgebraicUnknowns  []string `json:"algebraic_unknowns"`
		BrownianParameters []string `json:"brownian_parameters"`
		DiscreteParameters []string `json:"discrete_parameters"`
		SampledParameters  []string `json:"sampled_parameters"`
		ConstantParameters []string `json:"constant_parameters"`
		SystemKind         string   `json:"system_kind"`
		DeclaredSystemKind *string  `json:"declared_system_kind"`
	} `json:"models"`
}

type classificationManifest struct {
	BindingsRequired []string `json:"bindings_required"`
	Fixtures         []struct {
		ID      string `json:"id"`
		Fixture string `json:"fixture"`
		Golden  string `json:"golden"`
		Pins    string `json:"pins"`
	} `json:"fixtures"`
}

// classificationModelNodes walks a document's models and their subsystems,
// returning every MODEL NODE keyed by its dot-path from the document root
// ("Parent", "Parent.Child"). Classification is per node: a binding that
// flattens the document first and classifies once returns one merged answer
// where the golden has two scoped ones.
func classificationModelNodes(t *testing.T, file *ESMFile) map[string]*Model {
	t.Helper()
	out := map[string]*Model{}
	var walk func(path string, m *Model)
	walk = func(path string, m *Model) {
		out[path] = m
		for _, name := range sortedKeys(m.Subsystems) {
			raw, err := json.Marshal(m.Subsystems[name])
			if err != nil {
				t.Fatalf("re-encode subsystem %s: %v", name, err)
			}
			var child Model
			if err := json.Unmarshal(raw, &child); err != nil {
				t.Fatalf("decode subsystem %s: %v", name, err)
			}
			childCopy := child
			walk(path+"."+name, &childCopy)
		}
	}
	for _, name := range sortedKeys(file.Models) {
		m := file.Models[name]
		walk(name, &m)
	}
	return out
}

func TestClassificationConformanceGoldens(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	base := filepath.Join(repoRoot, "tests", "conformance", "classification")

	raw, err := os.ReadFile(filepath.Join(base, "manifest.json"))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	var man classificationManifest
	if err := json.Unmarshal(raw, &man); err != nil {
		t.Fatalf("decode manifest: %v", err)
	}
	requiresGo := false
	for _, b := range man.BindingsRequired {
		if b == "go" {
			requiresGo = true
		}
	}
	if !requiresGo {
		t.Fatalf("the classification manifest no longer lists go in bindings_required: %v", man.BindingsRequired)
	}
	if len(man.Fixtures) == 0 {
		t.Fatal("manifest lists no fixtures")
	}

	for _, fx := range man.Fixtures {
		fx := fx
		t.Run(fx.ID, func(t *testing.T) {
			file, err := Load(filepath.Join(base, fx.Fixture))
			if err != nil {
				t.Fatalf("load fixture: %v", err)
			}
			goldenRaw, err := os.ReadFile(filepath.Join(base, fx.Golden))
			if err != nil {
				t.Fatalf("read golden: %v", err)
			}
			var golden classificationGolden
			if err := json.Unmarshal(goldenRaw, &golden); err != nil {
				t.Fatalf("decode golden: %v", err)
			}

			nodes := classificationModelNodes(t, file)
			if len(nodes) != len(golden.Models) {
				t.Errorf("model nodes = %v, golden has %d (%s)",
					sortedKeys(nodes), len(golden.Models), fx.Pins)
			}
			for path, want := range golden.Models {
				model, ok := nodes[path]
				if !ok {
					t.Errorf("golden names model node %q, which the document does not have", path)
					continue
				}
				check := func(label string, got, want []string) {
					t.Helper()
					if want == nil {
						want = []string{}
					}
					if got == nil {
						got = []string{}
					}
					if !reflect.DeepEqual(got, want) {
						t.Errorf("%s: %s = %v, want %v", path, label, got, want)
					}
				}
				check("ode_states", ODEStates(model), want.ODEStates)
				check("observed_unknowns", ObservedUnknowns(model), want.ObservedUnknowns)
				check("algebraic_unknowns", AlgebraicUnknowns(model), want.AlgebraicUnknowns)
				check("brownian_parameters", BrownianParameters(model), want.BrownianParameters)
				check("discrete_parameters", DiscreteParameters(model), want.DiscreteParameters)
				check("sampled_parameters", SampledParameters(model), want.SampledParameters)
				check("constant_parameters", ConstantParameters(model), want.ConstantParameters)

				if got := SystemKind(model, file.Domain); got != want.SystemKind {
					t.Errorf("%s: system_kind = %q, want %q", path, got, want.SystemKind)
				}
				// declared_system_kind is the model's explicit field, or null.
				var declared *string
				if model.SystemKind != nil {
					declared = model.SystemKind
				}
				switch {
				case want.DeclaredSystemKind == nil && declared != nil:
					t.Errorf("%s: declared_system_kind = %q, want null", path, *declared)
				case want.DeclaredSystemKind != nil && declared == nil:
					t.Errorf("%s: declared_system_kind = null, want %q", path, *want.DeclaredSystemKind)
				case want.DeclaredSystemKind != nil && *declared != *want.DeclaredSystemKind:
					t.Errorf("%s: declared_system_kind = %q, want %q", path, *declared, *want.DeclaredSystemKind)
				}

				// IsODEState is the membership test for the first set, and must
				// agree with it name for name.
				for _, n := range want.ODEStates {
					if !IsODEState(model, n) {
						t.Errorf("%s: IsODEState(%q) = false, want true", path, n)
					}
				}
				for _, n := range append(append([]string{}, want.ObservedUnknowns...), want.AlgebraicUnknowns...) {
					if IsODEState(model, n) {
						t.Errorf("%s: IsODEState(%q) = true, want false", path, n)
					}
				}

				assertClassificationPartitions(t, path, model)
			}
		})
	}
}

// assertClassificationPartitions checks the two PARTITION claims of esm-spec
// §6.3.1 directly: the three unknown sets cover the model's unknowns exactly
// once each, and the four parameter sets cover its parameters exactly once each.
// A binding can match every golden list and still have a latent overlap on a
// document the goldens do not cover, so the property is asserted rather than
// inferred.
func assertClassificationPartitions(t *testing.T, path string, model *Model) {
	t.Helper()

	var unknowns, parameters []string
	for name, v := range model.Variables {
		switch v.Type {
		case VarTypeUnknown:
			unknowns = append(unknowns, name)
		case VarTypeParameter:
			parameters = append(parameters, name)
		default:
			t.Errorf("%s: variable %q declares type %q; esm 1.0.0 has only %q and %q",
				path, name, v.Type, VarTypeUnknown, VarTypeParameter)
		}
	}
	sort.Strings(unknowns)
	sort.Strings(parameters)

	assertPartition(t, path, "unknowns", unknowns, map[string][]string{
		"ode_states":         ODEStates(model),
		"observed_unknowns":  ObservedUnknowns(model),
		"algebraic_unknowns": AlgebraicUnknowns(model),
	})
	assertPartition(t, path, "parameters", parameters, map[string][]string{
		"brownian_parameters": BrownianParameters(model),
		"discrete_parameters": DiscreteParameters(model),
		"sampled_parameters":  SampledParameters(model),
		"constant_parameters": ConstantParameters(model),
	})
}

func assertPartition(t *testing.T, path, label string, universe []string, parts map[string][]string) {
	t.Helper()
	owner := map[string]string{}
	var all []string
	for _, setName := range sortedKeys(parts) {
		for _, n := range parts[setName] {
			if prev, dup := owner[n]; dup {
				t.Errorf("%s: %s %q is in BOTH %s and %s — the sets must be disjoint",
					path, label, n, prev, setName)
			}
			owner[n] = setName
			all = append(all, n)
		}
	}
	sort.Strings(all)
	if !reflect.DeepEqual(all, universe) {
		if len(all) == 0 && len(universe) == 0 {
			return
		}
		t.Errorf("%s: the %s partition covers %v, want exactly %v",
			path, label, all, universe)
	}
}

// The §6.3.1 worked example, asserted directly against the spec text so a
// regression shows up as a spec disagreement and not only as a golden diff.
func TestClassificationSpecWorkedExample(t *testing.T) {
	const src = `{
	  "esm": "1.0.0",
	  "metadata": {"name": "worked", "authors": ["spec"]},
	  "models": {"M": {
	    "variables": {
	      "c":     {"type": "unknown",   "units": "kg"},
	      "v_dep": {"type": "unknown",   "units": "m/s"},
	      "SO4":   {"type": "unknown",   "units": "mol"},
	      "k":     {"type": "parameter", "units": "1/s", "default": 0.1},
	      "eps":   {"type": "parameter", "units": "1/s^0.5",
	                "distribution": {"kind": "normal", "mean": 0.0, "std": 1.0},
	                "update": {"kind": "wiener"}}
	    },
	    "equations": [
	      {"lhs": {"op": "D", "args": ["c"], "wrt": "t"},
	       "rhs": {"op": "*", "args": ["k", "c", "eps"]}},
	      {"lhs": "v_dep", "rhs": {"op": "/", "args": [1, "k"]}},
	      {"lhs": {"op": "*", "args": ["SO4", "SO4"]}, "rhs": "k"}
	    ]}}}`
	file, err := LoadString(src)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	model := file.Models["M"]
	for _, tc := range []struct {
		label string
		got   []string
		want  []string
	}{
		{"ode_states", ODEStates(&model), []string{"c"}},
		{"observed_unknowns", ObservedUnknowns(&model), []string{"v_dep"}},
		{"algebraic_unknowns", AlgebraicUnknowns(&model), []string{"SO4"}},
		{"brownian_parameters", BrownianParameters(&model), []string{"eps"}},
		{"constant_parameters", ConstantParameters(&model), []string{"k"}},
	} {
		if !reflect.DeepEqual(tc.got, tc.want) {
			t.Errorf("%s = %v, want %v", tc.label, tc.got, tc.want)
		}
	}
	if got := SystemKind(&model, file.Domain); got != SystemKindSDE {
		t.Errorf("system_kind = %q, want %q", got, SystemKindSDE)
	}
}

// A derivative LHS may be WRAPPED and still credits its base variable: `D(u)`,
// `D(u[i])`, and an `aggregate` whose `expr` is a `D(...)` all name `u` an ODE
// state. A binding that recognises only the bare form calls every arrayed model
// state-free — which is what made Go reject two dozen aggregate fixtures.
func TestODEStatesSeeThroughWrappedDerivatives(t *testing.T) {
	cases := map[string]Expression{
		"bare":      ExprNode{Op: OpDerivative, Args: []any{"u"}, Wrt: strPtr("t")},
		"indexed":   ExprNode{Op: OpDerivative, Args: []any{ExprNode{Op: "index", Args: []any{"u", "i"}}}, Wrt: strPtr("t")},
		"aggregate": ExprNode{Op: "aggregate", OutputIdx: []any{"i"}, Args: []any{"u"}, Expr: ExprNode{Op: OpDerivative, Args: []any{ExprNode{Op: "index", Args: []any{"u", "i"}}}, Wrt: strPtr("t")}},
	}
	for label, lhs := range cases {
		t.Run(label, func(t *testing.T) {
			model := &Model{
				Variables: map[string]ModelVariable{"u": {Type: VarTypeUnknown}},
				Equations: []Equation{{LHS: lhs, RHS: "u"}},
			}
			if got := ODEStates(model); !reflect.DeepEqual(got, []string{"u"}) {
				t.Errorf("ODEStates = %v, want [u]", got)
			}
			if !IsODEState(model, "u") {
				t.Error("IsODEState(u) = false, want true")
			}
			if got := ObservedUnknowns(model); len(got) != 0 {
				t.Errorf("ObservedUnknowns = %v, want none", got)
			}
		})
	}
}

// A SPATIAL derivative is a rewrite target, not a time derivative: it must not
// make its operand an ODE state, or every PDE leaf would classify as one.
func TestODEStatesIgnoreSpatialDerivatives(t *testing.T) {
	model := &Model{
		Variables: map[string]ModelVariable{"u": {Type: VarTypeUnknown}},
		Equations: []Equation{{
			LHS: ExprNode{Op: OpDerivative, Args: []any{"u"}, Wrt: strPtr("x")},
			RHS: "u",
		}},
	}
	if got := ODEStates(model); len(got) != 0 {
		t.Errorf("ODEStates = %v, want none (a spatial D is not a time derivative)", got)
	}
	if got := SystemKind(model, nil); got != SystemKindNonlinear {
		t.Errorf("system_kind = %q, want %q (no time-derivative equation at all)", got, SystemKindNonlinear)
	}
}

// `system_kind_mismatch` fires when a DECLARED kind contradicts the derivation.
func TestSystemKindMismatchIsReported(t *testing.T) {
	kind := SystemKindNonlinear
	file := &ESMFile{
		ESM:      "1.0.0",
		Metadata: Metadata{Name: "mismatch", Authors: []string{"t"}},
		Models: map[string]Model{"M": {
			SystemKind: &kind,
			Variables:  map[string]ModelVariable{"x": {Type: VarTypeUnknown}},
			Equations: []Equation{{
				LHS: ExprNode{Op: OpDerivative, Args: []any{"x"}, Wrt: strPtr("t")},
				RHS: 1.0,
			}},
		}},
	}
	res := ValidateStructuralWithCodes(file)
	found := false
	for _, e := range res.StructuralErrors {
		if e.Code == ErrorSystemKindMismatch {
			found = true
			if !strings.Contains(e.Path, "/system_kind") {
				t.Errorf("path = %q, want the declaring field", e.Path)
			}
		}
	}
	if !found {
		t.Errorf("want system_kind_mismatch (declared nonlinear, derives ode): %+v", res.StructuralErrors)
	}
}
