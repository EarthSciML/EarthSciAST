package esm

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
)

// TestClosedFunctionsConformance drives every fixture under
// tests/closed_functions/<module>/<name>/{canonical.esm, expected.json}.
//
// For each fixture:
//  1. Load canonical.esm (exercises the parser's `fn`-op handling).
//  2. For each scenario in expected.json, evaluate the named closed
//     function with the given inputs and assert agreement with the
//     reference output within the declared tolerance.
//  3. For interp.searchsorted, drive `error_scenarios` and assert the
//     spec-pinned diagnostic code surfaces.
//
// All five bindings MUST run the same fixtures (esm-spec §9.4 / esm-aia).
func TestClosedFunctionsConformance(t *testing.T) {
	root := closedFunctionsFixturesDir(t)
	entries, err := walkClosedFnDirs(root)
	if err != nil {
		t.Fatalf("walk fixtures: %v", err)
	}
	if len(entries) == 0 {
		t.Fatalf("no closed-function fixtures under %s", root)
	}
	for _, e := range entries {
		e := e
		t.Run(e.label, func(t *testing.T) {
			// Step 1: load the canonical.esm. We only need the parser to
			// accept it — every fixture's RHS is a single `fn` invocation
			// of the function we're testing.
			if _, err := LoadPath(e.canonical); err != nil {
				t.Fatalf("LoadPath(%s): %v", e.canonical, err)
			}

			// Step 2 + 3: drive expected.json against EvaluateClosedFunction.
			raw, err := os.ReadFile(e.expected)
			if err != nil {
				t.Fatalf("read %s: %v", e.expected, err)
			}
			var fixture closedFnFixture
			if err := json.Unmarshal(raw, &fixture); err != nil {
				t.Fatalf("parse %s: %v", e.expected, err)
			}
			if fixture.Function == "" {
				t.Fatalf("%s: missing `function` field", e.expected)
			}
			if !IsClosedFunction(fixture.Function) {
				// Spec-first phased rollout (esm-94w and similar): a new
				// closed-function fixture lands in the spec PR before this
				// binding's implementation. Skip rather than fail; the
				// per-language [Impl] bead adds the function to the registry
				// and the fixture starts running automatically.
				t.Skipf("fixture function %q not yet implemented in this binding", fixture.Function)
			}
			for _, sc := range fixture.Scenarios {
				sc := sc
				t.Run("ok/"+sc.Name, func(t *testing.T) {
					args, err := normalizeFixtureArgs(sc.Inputs)
					if err != nil {
						t.Fatalf("normalize inputs: %v", err)
					}
					out, err := EvaluateClosedFunction(fixture.Function, args)
					if err != nil {
						t.Fatalf("EvaluateClosedFunction(%s, %v): %v", fixture.Function, args, err)
					}
					if err := assertCloseEnough(out, sc.Expected, fixture.Tolerance); err != nil {
						t.Fatalf("scenario %s (%s): %v", sc.Name, sc.Description, err)
					}
					// A success scenario passes the load-time argument check.
					if node, ok := fixtureFnNode(fixture.Function, args); ok {
						if err := checkClosedFnArgs(node); err != nil {
							t.Fatalf("load-time argument check rejected a success scenario: %v", err)
						}
					}
				})
			}
			for _, sc := range fixture.ErrorScenarios {
				sc := sc
				t.Run("err/"+sc.Name, func(t *testing.T) {
					args, err := normalizeFixtureArgs(sc.Inputs)
					if err != nil {
						t.Fatalf("normalize inputs: %v", err)
					}
					_, err = EvaluateClosedFunction(fixture.Function, args)
					if err == nil {
						t.Fatalf("expected error %q, got nil", sc.ExpectedErrorCode)
					}
					cfErr, ok := err.(*ClosedFunctionError)
					if !ok {
						t.Fatalf("expected *ClosedFunctionError, got %T: %v", err, err)
					}
					if cfErr.Code != sc.ExpectedErrorCode {
						t.Fatalf("error code mismatch: got %q, want %q (%s)",
							cfErr.Code, sc.ExpectedErrorCode, sc.Description)
					}
					// The same inputs as a `fn` node with `const` array
					// arguments must fail the LOAD-TIME argument check with the
					// same code (esm-spec §9.2, ruling Q-106).
					if node, ok := fixtureFnNode(fixture.Function, args); ok {
						var de DiagnosticError
						if err := checkClosedFnArgs(node); !errors.As(err, &de) ||
							de.DiagnosticCode() != sc.ExpectedErrorCode {
							t.Fatalf("load-time argument check = %v, want code %q",
								err, sc.ExpectedErrorCode)
						}
					}
				})
			}
		})
	}
}

// fixtureFnNode builds the `fn` node an interp.* scenario stands for: each
// array-valued argument position (interpArrayArgs) a `const` node holding the
// input whatever its rank, every other input a bare value. ok is false for a
// function with no array arguments or the wrong input count.
func fixtureFnNode(function string, args []any) (ExprNode, bool) {
	spec, ok := interpArrayArgs[function]
	if !ok || len(args) != spec.arity {
		return ExprNode{}, false
	}
	nodeArgs := append([]any(nil), args...)
	for _, a := range spec.args {
		nodeArgs[a.index] = ExprNode{Op: OpConst, Args: []any{}, Value: args[a.index]}
	}
	name := function
	return ExprNode{Op: OpFn, Name: &name, Args: nodeArgs}, true
}

type closedFnFixture struct {
	Function       string                  `json:"function"`
	Tolerance      closedFnTolerance       `json:"tolerance"`
	Scenarios      []closedFnScenario      `json:"scenarios"`
	ErrorScenarios []closedFnErrorScenario `json:"error_scenarios"`
}

type closedFnTolerance struct {
	Abs float64 `json:"abs"`
	Rel float64 `json:"rel"`
}

type closedFnScenario struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	Inputs      []any           `json:"inputs"`
	Expected    json.RawMessage `json:"expected"`
}

type closedFnErrorScenario struct {
	Name              string `json:"name"`
	Description       string `json:"description"`
	Inputs            []any  `json:"inputs"`
	ExpectedErrorCode string `json:"expected_error_code"`
}

type closedFnEntry struct {
	label     string // e.g. "datetime/year"
	canonical string
	expected  string
}

// walkClosedFnDirs returns every <module>/<function> directory under root
// that has both canonical.esm and expected.json.
func walkClosedFnDirs(root string) ([]closedFnEntry, error) {
	var out []closedFnEntry
	modules, err := os.ReadDir(root)
	if err != nil {
		return nil, err
	}
	for _, mod := range modules {
		if !mod.IsDir() {
			continue
		}
		modDir := filepath.Join(root, mod.Name())
		fns, err := os.ReadDir(modDir)
		if err != nil {
			return nil, err
		}
		for _, fn := range fns {
			if !fn.IsDir() {
				continue
			}
			fnDir := filepath.Join(modDir, fn.Name())
			canonical := filepath.Join(fnDir, "canonical.esm")
			expected := filepath.Join(fnDir, "expected.json")
			if _, err := os.Stat(canonical); err != nil {
				continue
			}
			if _, err := os.Stat(expected); err != nil {
				continue
			}
			out = append(out, closedFnEntry{
				label:     mod.Name() + "/" + fn.Name(),
				canonical: canonical,
				expected:  expected,
			})
		}
	}
	return out, nil
}

// normalizeFixtureArgs converts the JSON-decoded input slice into the
// types EvaluateClosedFunction expects: numbers stay as float64; nested
// arrays stay as []interface{}; the literal strings "NaN", "Inf" and "-Inf"
// are converted to math.NaN() and ±math.Inf; other strings are forwarded for
// diagnostic purposes.
func normalizeFixtureArgs(inputs []any) ([]any, error) {
	out := make([]any, len(inputs))
	for i, raw := range inputs {
		out[i] = normalizeFixtureValue(raw)
	}
	return out, nil
}

func normalizeFixtureValue(v any) any {
	switch x := v.(type) {
	case string:
		switch x {
		case "NaN", "nan", "NAN":
			return math.NaN()
		case "Inf":
			return math.Inf(1)
		case "-Inf":
			return math.Inf(-1)
		}
		return x
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = normalizeFixtureValue(e)
		}
		return out
	default:
		return v
	}
}

// assertCloseEnough compares a closed-function output to its expected
// reference within (abs OR rel) tolerance. Integer-typed outputs are
// promoted to float64 for the comparison; the spec pins zero tolerance
// for every entry except `datetime.julian_day` (≤ 1 ulp).
func assertCloseEnough(got any, expectedRaw json.RawMessage, tol closedFnTolerance) error {
	want, err := decodeExpectedScalar(expectedRaw)
	if err != nil {
		return err
	}
	gf, ok := toFloat64(got)
	if !ok {
		return errf("got non-numeric scalar %T (%v)", got, got)
	}
	if math.IsNaN(want) {
		if math.IsNaN(gf) {
			return nil
		}
		return errf("expected NaN, got %g", gf)
	}
	diff := math.Abs(gf - want)
	if diff <= tol.Abs {
		return nil
	}
	if want != 0 && diff/math.Abs(want) <= tol.Rel {
		return nil
	}
	return errf("got %g, want %g (|diff|=%g, tol=abs %g rel %g)",
		gf, want, diff, tol.Abs, tol.Rel)
}

func decodeExpectedScalar(raw json.RawMessage) (float64, error) {
	s := strings.TrimSpace(string(raw))
	if s == "\"NaN\"" || s == "\"nan\"" || s == "\"NAN\"" {
		return math.NaN(), nil
	}
	var f float64
	if err := json.Unmarshal(raw, &f); err != nil {
		return 0, err
	}
	return f, nil
}

// errf is a tiny formatted-error helper used by the conformance harness.
func errf(format string, args ...any) error {
	return fmt.Errorf(format, args...)
}

func closedFunctionsFixturesDir(t *testing.T) string {
	t.Helper()
	_, thisFile, _, _ := runtime.Caller(0)
	pkgDir := filepath.Dir(thisFile)
	// pkg/esm/closed_functions_test.go -> repo root is 4 levels up.
	repoRoot := filepath.Join(pkgDir, "..", "..", "..", "..")
	return filepath.Join(repoRoot, "tests", "closed_functions")
}

// An `interp.searchsorted` whose `xs` is not a rank-1 `const`-op array is
// `interp_axis_not_const` (esm-spec §9.2), raised by LOAD (ruling Q-106): a
// variable reference, a non-`const` expression, a `const` scalar and a nested
// `const`; and by the evaluator for a tree built in memory, where the rank
// check must beat a NaN in a nested xs.
func TestSearchsortedNonConstXsIsInterpAxisNotConst(t *testing.T) {
	const tmpl = `{
  "esm": "1.0.0",
  "metadata": {"name": "ss", "authors": ["test"]},
  "models": {
    "M": {
      "variables": {
        "y": {"type": "unknown", "default": 0.0},
        "p": {"type": "parameter", "default": 2.5}
      },
      "equations": [
        {"lhs": "y", "rhs": {"op": "fn", "name": "interp.searchsorted", "args": ["p", %s]}}
      ]
    }
  }
}`
	for _, xs := range []string{
		`"p"`,
		`{"op": "+", "args": ["p", 1]}`,
		`{"op": "const", "args": [], "value": 3.0}`,
		`{"op": "const", "args": [], "value": [[1.0, 2.0], [3.0, 4.0]]}`,
	} {
		_, err := LoadString(fmt.Sprintf(tmpl, xs))
		var de DiagnosticError
		if !errors.As(err, &de) || de.DiagnosticCode() != CodeInterpAxisNotConst {
			t.Errorf("xs %s: load = %v, want code %q", xs, err, CodeInterpAxisNotConst)
		}
	}
	// In memory, through the evaluator: a variable reference as xs.
	name := "interp.searchsorted"
	varXs := ExprNode{Op: OpFn, Name: &name, Args: []any{2.0, "p"}}
	_, err := Evaluate(varXs, map[string]float64{"p": 2.5})
	var de DiagnosticError
	if !errors.As(err, &de) || de.DiagnosticCode() != CodeInterpAxisNotConst {
		t.Errorf("variable xs: got %v, want code %q", err, CodeInterpAxisNotConst)
	}
	// The rank check comes before the NaN check.
	nested := ExprNode{Op: OpFn, Name: &name, Args: []any{2.0,
		ExprNode{Op: OpConst, Args: []any{}, Value: []any{[]any{1.0, math.NaN()}, []any{3.0, 4.0}}}}}
	_, err = Evaluate(nested, nil)
	if !errors.As(err, &de) || de.DiagnosticCode() != CodeInterpAxisNotConst {
		t.Errorf("nested xs with a NaN: got %v, want code %q", err, CodeInterpAxisNotConst)
	}
}

// TestInterpScenariosThroughLibraryTemplates runs the success scenarios of the
// interp.* fixtures through the pure-AST templates of lib/interp.esm. The Go
// evaluator is scalar-only: it has no rule for `faq` (and reads `index` only
// from a 1-D `const` literal), so it cannot evaluate an expanded template. The
// test checks the expansion instead: the template import resolves, and each
// scenario's right-hand side is the template body with every parameter
// occurrence (including the axis length inside a `faq` `ranges` bound) replaced
// by the scenario's arrays, query and length (esm-spec §9.6.3 constraint 5).
func TestInterpScenariosThroughLibraryTemplates(t *testing.T) {
	fixtures := closedFunctionsFixturesDir(t)
	libraryPath := filepath.Join(fixtures, "..", "..", "lib", "interp.esm")
	libRaw, err := os.ReadFile(libraryPath)
	if err != nil {
		t.Fatalf("read %s: %v", libraryPath, err)
	}
	var library struct {
		Templates map[string]struct {
			Body any `json:"body"`
		} `json:"expression_templates"`
	}
	if err := json.Unmarshal(libRaw, &library); err != nil {
		t.Fatalf("parse %s: %v", libraryPath, err)
	}
	for _, name := range []string{"searchsorted", "linear", "bilinear"} {
		name := name
		t.Run(name, func(t *testing.T) {
			raw, err := os.ReadFile(filepath.Join(fixtures, "interp", name, "expected.json"))
			if err != nil {
				t.Fatal(err)
			}
			var fixture closedFnFixture
			if err := json.Unmarshal(raw, &fixture); err != nil {
				t.Fatal(err)
			}
			tmpl, ok := library.Templates[name]
			if !ok {
				t.Fatalf("%s declares no %q template", libraryPath, name)
			}
			variables := map[string]any{}
			equations := []any{}
			calls := make([]map[string]any, len(fixture.Scenarios))
			for i, sc := range fixture.Scenarios {
				calls[i] = interpTemplateBindings(t, name, sc.Inputs, i)
				variables[fmt.Sprintf("out_%d", i)] = map[string]any{"type": "unknown", "default": 0.0, "units": "1"}
				for _, q := range []string{"x", "y"} {
					if v, ok := calls[i][q].(string); ok {
						variables[v] = map[string]any{"type": "parameter", "default": 0.0, "units": "1"}
					}
				}
				equations = append(equations, map[string]any{
					"lhs": map[string]any{"op": "D", "args": []any{fmt.Sprintf("out_%d", i)}, "wrt": "t"},
					"rhs": map[string]any{
						"op": "apply_expression_template", "args": []any{},
						"name": name, "bindings": calls[i],
					},
				})
			}
			doc := map[string]any{
				"esm":      "1.1.0",
				"metadata": map[string]any{"name": "interp_" + name + "_template"},
				"models": map[string]any{"Probe": map[string]any{
					"expression_template_imports": []any{map[string]any{"ref": libraryPath}},
					"variables":                   variables,
					"equations":                   equations,
				}},
			}
			docJSON, err := json.Marshal(doc)
			if err != nil {
				t.Fatal(err)
			}
			file, err := LoadString(string(docJSON))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			got := file.Models["Probe"].Equations
			if len(got) != len(calls) {
				t.Fatalf("got %d equations, want %d", len(got), len(calls))
			}
			for i, eq := range got {
				s, err := SerializeExpressionCompact(eq.RHS)
				if err != nil {
					t.Fatal(err)
				}
				var gotTree any
				if err := json.Unmarshal([]byte(s), &gotTree); err != nil {
					t.Fatal(err)
				}
				wantTree := jsonRoundTrip(t, substituteTemplateParams(tmpl.Body, calls[i]))
				if !reflect.DeepEqual(gotTree, wantTree) {
					t.Errorf("%s: expanded right-hand side differs from the substituted body\n got: %s", fixture.Scenarios[i].Name, s)
				}
			}
		})
	}
}

// interpTemplateBindings is the `apply_expression_template` bindings of one
// interp scenario: arrays as `const` nodes, each axis length its integer, and
// the queries as parameters `qx_<tag>` / `qy_<tag>` (a NaN query cannot be a
// JSON literal).
func interpTemplateBindings(t *testing.T, name string, inputs []any, tag int) map[string]any {
	t.Helper()
	constArray := func(v any) map[string]any { return map[string]any{"op": "const", "args": []any{}, "value": v} }
	length := func(v any) int {
		a, ok := v.([]any)
		if !ok {
			t.Fatalf("%s: axis input is not an array: %v", name, v)
		}
		return len(a)
	}
	qx, qy := fmt.Sprintf("qx_%d", tag), fmt.Sprintf("qy_%d", tag)
	switch name {
	case "searchsorted":
		return map[string]any{"x": qx, "xs": constArray(inputs[1]), "n": length(inputs[1])}
	case "linear":
		return map[string]any{"table": constArray(inputs[0]), "axis": constArray(inputs[1]), "x": qx, "n": length(inputs[1])}
	}
	return map[string]any{
		"table": constArray(inputs[0]), "axis_x": constArray(inputs[1]), "axis_y": constArray(inputs[2]),
		"x": qx, "y": qy, "nx": length(inputs[1]), "ny": length(inputs[2]),
	}
}

// substituteTemplateParams is a test-local substitution oracle: every string
// other than an `op` name that equals a parameter is replaced by its binding.
// The interp templates carry no nested `apply_expression_template`, whose
// `name` would be exempt.
func substituteTemplateParams(body any, bindings map[string]any) any {
	switch v := body.(type) {
	case string:
		if b, ok := bindings[v]; ok {
			return b
		}
		return v
	case []any:
		out := make([]any, len(v))
		for i, e := range v {
			out[i] = substituteTemplateParams(e, bindings)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(v))
		for k, e := range v {
			if k == "op" {
				out[k] = e
			} else {
				out[k] = substituteTemplateParams(e, bindings)
			}
		}
		return out
	}
	return body
}

func jsonRoundTrip(t *testing.T, v any) any {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	var out any
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatal(err)
	}
	return out
}

// TestDatetimeScenariosThroughCalendarTemplates runs the datetime.* fixtures
// through the pure-AST templates of lib/calendar.esm. Go checks the expansion,
// not its value (the template values are checked in Julia, Python and Rust):
// the template import resolves, and each right-hand side is the template body
// with every occurrence of its one parameter `t` replaced and every nested
// `civil_*` helper reference expanded in turn (esm-spec §9.6.4 rule 2, §9.7.3)
// — `t` bound to each finite scenario instant as a literal, and to a
// parameter, as a caller with a NaN or infinite instant would write it
// (esm-spec §9.6.3 constraint 5).
func TestDatetimeScenariosThroughCalendarTemplates(t *testing.T) {
	fixtures := closedFunctionsFixturesDir(t)
	libraryPath := filepath.Join(fixtures, "..", "..", "lib", "calendar.esm")
	libRaw, err := os.ReadFile(libraryPath)
	if err != nil {
		t.Fatalf("read %s: %v", libraryPath, err)
	}
	var library struct {
		Templates map[string]calendarTemplate `json:"expression_templates"`
	}
	if err := json.Unmarshal(libRaw, &library); err != nil {
		t.Fatalf("parse %s: %v", libraryPath, err)
	}
	names := []string{"year", "month", "day", "hour", "minute", "second", "day_of_year", "julian_day", "is_leap_year"}
	public := append(append([]string{}, names...), "seconds_since_midnight")
	for _, name := range public {
		tmpl, ok := library.Templates[name]
		if !ok {
			t.Fatalf("%s declares no %q template", libraryPath, name)
		}
		if !reflect.DeepEqual(tmpl.Params, []string{"t"}) {
			t.Fatalf("%q params = %v, want [t]", name, tmpl.Params)
		}
	}
	for name := range library.Templates {
		isPublic := false
		for _, p := range public {
			isPublic = isPublic || p == name
		}
		if !isPublic && !strings.HasPrefix(name, "civil_") {
			t.Errorf("%s: template %q is neither public nor a civil_ helper", libraryPath, name)
		}
	}
	check := func(t *testing.T, name string, instants []any) {
		variables := map[string]any{"tu": map[string]any{"type": "parameter", "default": 0.0, "units": "s"}}
		equations := []any{}
		for i, inst := range instants {
			out := fmt.Sprintf("out_%d", i)
			variables[out] = map[string]any{"type": "unknown"}
			equations = append(equations, map[string]any{
				"lhs": out,
				"rhs": map[string]any{
					"op": "apply_expression_template", "args": []any{},
					"name": name, "bindings": map[string]any{"t": inst},
				},
			})
		}
		doc := map[string]any{
			"esm":      "1.2.0",
			"metadata": map[string]any{"name": "datetime_" + name + "_template"},
			"models": map[string]any{"Probe": map[string]any{
				"expression_template_imports": []any{map[string]any{"ref": libraryPath, "only": []any{name}}},
				"variables":                   variables,
				"equations":                   equations,
			}},
		}
		docJSON, err := json.Marshal(doc)
		if err != nil {
			t.Fatal(err)
		}
		file, err := LoadString(string(docJSON))
		if err != nil {
			t.Fatalf("load: %v", err)
		}
		got := file.Models["Probe"].Equations
		if len(got) != len(instants) {
			t.Fatalf("got %d equations, want %d", len(got), len(instants))
		}
		// Match each equation to its instant by its left-hand side: the loader
		// does not promise to keep the authored equation order.
		for _, eq := range got {
			lhs, ok := eq.LHS.(string)
			if !ok {
				t.Fatalf("left-hand side %v is not a variable name", eq.LHS)
			}
			var i int
			if _, err := fmt.Sscanf(lhs, "out_%d", &i); err != nil {
				t.Fatalf("unexpected left-hand side %q", lhs)
			}
			s, err := SerializeExpressionCompact(eq.RHS)
			if err != nil {
				t.Fatal(err)
			}
			var gotTree any
			if err := json.Unmarshal([]byte(s), &gotTree); err != nil {
				t.Fatal(err)
			}
			want := expandCalendarTemplate(library.Templates, library.Templates[name].Body, map[string]any{"t": instants[i]})
			if !reflect.DeepEqual(gotTree, jsonRoundTrip(t, want)) {
				t.Errorf("t = %v: expanded right-hand side differs from the expanded body\n got: %.300s", instants[i], s)
			}
		}
	}
	for _, name := range names {
		name := name
		t.Run(name, func(t *testing.T) {
			raw, err := os.ReadFile(filepath.Join(fixtures, "datetime", name, "expected.json"))
			if err != nil {
				t.Fatal(err)
			}
			var fixture closedFnFixture
			if err := json.Unmarshal(raw, &fixture); err != nil {
				t.Fatal(err)
			}
			instants := []any{}
			for _, sc := range fixture.Scenarios {
				if v, ok := sc.Inputs[0].(float64); ok {
					instants = append(instants, v)
				}
			}
			check(t, name, append(instants, "tu"))
		})
	}
	t.Run("seconds_since_midnight", func(t *testing.T) {
		check(t, "seconds_since_midnight", []any{86399.5, "tu"})
	})
}

type calendarTemplate struct {
	Params []string `json:"params"`
	Body   any      `json:"body"`
}

// expandCalendarTemplate is a test-local expansion oracle: every string other
// than an `op` name that is a parameter is replaced by its binding, and a
// nested `apply_expression_template` is replaced by its template's body
// expanded under its (already substituted) bindings.
func expandCalendarTemplate(templates map[string]calendarTemplate, body any, bindings map[string]any) any {
	switch v := body.(type) {
	case string:
		if b, ok := bindings[v]; ok {
			return b
		}
		return v
	case []any:
		out := make([]any, len(v))
		for i, e := range v {
			out[i] = expandCalendarTemplate(templates, e, bindings)
		}
		return out
	case map[string]any:
		if v["op"] == "apply_expression_template" {
			inner := map[string]any{}
			for k, e := range v["bindings"].(map[string]any) {
				inner[k] = expandCalendarTemplate(templates, e, bindings)
			}
			return expandCalendarTemplate(templates, templates[v["name"].(string)].Body, inner)
		}
		out := make(map[string]any, len(v))
		for k, e := range v {
			if k == "op" {
				out[k] = e
			} else {
				out[k] = expandCalendarTemplate(templates, e, bindings)
			}
		}
		return out
	}
	return body
}
