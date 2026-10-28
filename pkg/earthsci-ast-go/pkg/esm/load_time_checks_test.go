package esm

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// Every tests/invalid fixture whose basename starts with `closed_fn_` or
// `function_table_` is a schema-valid document pinned resolver_only with a
// `resolver_error_code` (the enum_duplicate_value.esm convention): load MUST
// reject it with exactly that code (esm-spec §9.2 "When the argument checks
// run", §9.5.5 "When the table checks run", ruling Q-106), and validating its
// text MUST say invalid.
func TestClosedFnAndTableInvalidFixtures(t *testing.T) {
	root := dsuRepoRoot(t)
	pins := resolverOnlyPins(t, root)
	dir := filepath.Join(root, "tests", "invalid")
	var files []string
	for _, pattern := range []string{"closed_fn_*.esm", "function_table_*.esm"} {
		matched, err := filepath.Glob(filepath.Join(dir, pattern))
		if err != nil {
			t.Fatal(err)
		}
		files = append(files, matched...)
	}
	sort.Strings(files)
	if len(files) < 30 {
		t.Fatalf("found %d closed_fn_/function_table_ fixtures, want >= 30", len(files))
	}
	for _, path := range files {
		name := filepath.Base(path)
		t.Run(name, func(t *testing.T) {
			want, ok := pins[name]
			if !ok || want == "" {
				t.Fatalf("%s must be pinned resolver_only with a resolver_error_code", name)
			}
			_, err := LoadPath(path)
			var de DiagnosticError
			if !errors.As(err, &de) || de.DiagnosticCode() != want {
				t.Fatalf("load = %v, want code %q", err, want)
			}
			raw, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			res := ValidateText(string(raw), WithBasePath(dir))
			if res.IsValid {
				t.Fatalf("ValidateText accepted %s", name)
			}
			found := false
			for _, se := range res.StructuralErrors {
				if strings.Contains(se.Message, "["+want+"]") {
					found = true
				}
			}
			if !found {
				t.Fatalf("ValidateText findings %v do not name %q", res.StructuralErrors, want)
			}
		})
	}
}

// validate() on a typed document runs the same checks: a table no lookup
// references and an interp.* node in a reaction rate, each reported with its
// code at its path. An empty searchsorted xs is valid (ruling Q-108).
func TestValidateRunsFunctionChecks(t *testing.T) {
	const src = `{
  "esm": "1.0.0",
  "metadata": {"name": "fc", "authors": ["test"]},
  "models": {
    "M": {
      "variables": {
        "y": {"type": "unknown", "default": 0.0},
        "p": {"type": "parameter", "default": 2.5}
      },
      "equations": [
        {"lhs": "y", "rhs": {"op": "fn", "name": "interp.searchsorted",
          "args": ["p", {"op": "const", "args": [], "value": []}]}}
      ]
    }
  }
}`
	file, err := LoadString(src)
	if err != nil {
		t.Fatalf("an empty searchsorted xs must load: %v", err)
	}
	if res := Validate(file); !res.IsValid {
		t.Fatalf("an empty searchsorted xs must validate: %v", res.StructuralErrors)
	}

	file.FunctionTables = map[string]FunctionTable{
		"unused": {Axes: []FunctionTableAxis{{Name: "x", Values: []float64{0, 2, 1}}},
			Data: []any{1.0, 2.0, 3.0}},
	}
	name := "interp.linear"
	m := file.Models["M"]
	m.Equations = append(m.Equations, Equation{LHS: "y", RHS: ExprNode{Op: OpFn, Name: &name,
		Args: []any{ExprNode{Op: OpConst, Args: []any{}, Value: 5.0},
			ExprNode{Op: OpConst, Args: []any{}, Value: []any{0.0, 1.0}}, "p"}}})
	file.Models["M"] = m

	res := Validate(file)
	if res.IsValid {
		t.Fatal("Validate accepted a broken table and a wrong-rank interp.linear table")
	}
	got := map[string]string{}
	for _, se := range res.StructuralErrors {
		got[se.Code] = se.Path
	}
	for code, path := range map[string]string{
		CodeTableAxisNonMonotonic: "/function_tables/unused",
		codeInterpTableNotConst:   "/models/M/equations/1/rhs",
	} {
		if got[code] != path {
			t.Errorf("code %q at %q, want %q (all: %v)", code, got[code], path, res.StructuralErrors)
		}
	}
	var de DiagnosticError
	if err := checkFunctionsAtLoad(file); !errors.As(err, &de) ||
		de.DiagnosticCode() != CodeTableAxisNonMonotonic {
		t.Errorf("load-time gate = %v, want the table's code first", err)
	}
}

// A decreasing interp.linear axis is refused at load and by validate() wherever
// the document holds it, including the two positions the walk once skipped: a
// reaction-system parameter's `update` and an `event` coupling's affects.
func TestLoadChecksReachParameterUpdatesAndEventCouplings(t *testing.T) {
	name := "interp.linear"
	decreasing := func() ExprNode {
		return ExprNode{Op: OpFn, Name: &name, Args: []any{
			ExprNode{Op: OpConst, Args: []any{}, Value: []any{300.0, 200.0}},
			ExprNode{Op: OpConst, Args: []any{}, Value: []any{2.0, 1.0}}, "T"}}
	}
	cases := map[string]struct {
		file *ESMFile
		path string
	}{
		"reaction-system parameter update": {
			file: &ESMFile{ESM: "1.0.0", Metadata: Metadata{Name: "rs"}, ReactionSystems: map[string]ReactionSystem{"RS": {
				Parameters: map[string]Parameter{"k": {Update: ParameterUpdate{
					Kind: "condition", When: "c", Expression: decreasing()}}},
			}}},
			path: "/reaction_systems/RS/parameters/k/update/expression",
		},
		"event coupling affect": {
			file: &ESMFile{ESM: "1.0.0", Metadata: Metadata{Name: "ev"},
				Models: map[string]Model{"A": {}}, Coupling: []CouplingEntry{EventCoupling{
					Type: "event", EventType: "discrete", Name: "e",
					Affects: []AffectEquation{{LHS: "A.x", RHS: decreasing()}},
				}}},
			path: "/coupling/0/affects/0/rhs",
		},
	}
	for label, c := range cases {
		t.Run(label, func(t *testing.T) {
			var de DiagnosticError
			if err := checkFunctionsAtLoad(c.file); !errors.As(err, &de) ||
				de.DiagnosticCode() != CodeInterpNonMonotonicAxis {
				t.Fatalf("load-time gate = %v, want %q", err, CodeInterpNonMonotonicAxis)
			}
			res := Validate(c.file)
			found := false
			for _, se := range res.StructuralErrors {
				if se.Code == CodeInterpNonMonotonicAxis && se.Path == c.path {
					found = true
				}
			}
			if !found {
				t.Fatalf("validate() findings %v lack %q at %s", res.StructuralErrors,
					CodeInterpNonMonotonicAxis, c.path)
			}
		})
	}
}

// A non-numeric entry in an interp.* array is the array's rank code, as in the
// other bindings: never closed_function_arity, and a numeric string is not read
// as a number.
func TestInterpArrayNonNumericEntryIsRankCode(t *testing.T) {
	cases := []struct {
		label, code string
		args        []any
	}{
		{"null in table", codeInterpTableNotConst, []any{[]any{1.0, nil}, []any{0.0, 1.0}, 0.5}},
		{"bool in table", codeInterpTableNotConst, []any{[]any{1.0, true}, []any{0.0, 1.0}, 0.5}},
		{"numeric string in axis", CodeInterpAxisNotConst, []any{[]any{1.0, 2.0}, []any{"0", "1"}, 0.5}},
	}
	for _, c := range cases {
		t.Run(c.label, func(t *testing.T) {
			_, err := EvaluateClosedFunction("interp.linear", c.args)
			var de DiagnosticError
			if !errors.As(err, &de) || de.DiagnosticCode() != c.code {
				t.Fatalf("interp.linear = %v, want %q", err, c.code)
			}
		})
	}
	_, err := EvaluateClosedFunction("interp.bilinear", []any{
		[]any{[]any{1.0, nil}, []any{2.0, 3.0}}, []any{0.0, 1.0}, []any{0.0, 1.0}, 0.5, 0.5})
	var de DiagnosticError
	if !errors.As(err, &de) || de.DiagnosticCode() != codeInterpTableNotConst {
		t.Fatalf("interp.bilinear with a null cell = %v, want %q", err, codeInterpTableNotConst)
	}
}

// A subsystem mounted from a remote `{ref}` is inlined by LoadPath's early pass,
// so LoadString's checks see it and a bad interp.* call inside it is refused at
// load (esm-spec §9.5.5: the checks MUST NOT be deferred past load).
func TestLoadPathChecksRemoteMountedSubsystems(t *testing.T) {
	leaf := `{
  "esm": "1.0.0",
  "metadata": {"name": "leaf", "authors": ["test"]},
  "models": {
    "Leaf": {
      "variables": {
        "y": {"type": "unknown", "default": 0.0},
        "T": {"type": "parameter", "default": 250.0}
      },
      "equations": [
        {"lhs": {"op": "D", "args": ["y"], "wrt": "t"},
         "rhs": {"op": "fn", "name": "interp.linear", "args": [
           {"op": "const", "args": [], "value": [1.0, 2.0]},
           {"op": "const", "args": [], "value": [300.0, 200.0]}, "T"]}}
      ]
    }
  }
}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(leaf))
	}))
	defer srv.Close()

	root := `{
  "esm": "1.0.0",
  "metadata": {"name": "root", "authors": ["test"]},
  "models": {
    "Outer": {
      "variables": {"z": {"type": "unknown", "default": 0.0}},
      "equations": [{"lhs": {"op": "D", "args": ["z"], "wrt": "t"}, "rhs": 0.0}],
      "subsystems": {"Remote": {"ref": "` + srv.URL + `/leaf.esm"}}
    }
  }
}`
	path := filepath.Join(t.TempDir(), "root.esm")
	if err := os.WriteFile(path, []byte(root), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := LoadPath(path)
	var de DiagnosticError
	if !errors.As(err, &de) || de.DiagnosticCode() != CodeInterpNonMonotonicAxis {
		t.Fatalf("LoadPath = %v, want %q from the remote leaf", err, CodeInterpNonMonotonicAxis)
	}
}
