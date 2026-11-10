package esm

// The datetime.* and interp.* scenarios of tests/closed_functions run through
// the pure-AST templates of lib/calendar.esm and lib/interp.esm that replace
// the closed functions. Only each scenario's inputs are read; the Go evaluator
// has no rule for `faq`, so these tests check the expansion, not its value
// (Julia, Python and Rust check the values).

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
)

// templateScenarioFixture is the part of a tests/closed_functions
// expected.json these tests read.
type templateScenarioFixture struct {
	Scenarios []struct {
		Name   string `json:"name"`
		Inputs []any  `json:"inputs"`
	} `json:"scenarios"`
}

func closedFunctionsFixturesDir(t *testing.T) string {
	t.Helper()
	_, thisFile, _, _ := runtime.Caller(0)
	// pkg/esm/<this file> -> repo root is 4 levels up.
	repoRoot := filepath.Join(filepath.Dir(thisFile), "..", "..", "..", "..")
	return filepath.Join(repoRoot, "tests", "closed_functions")
}

// TestInterpScenariosThroughLibraryTemplates runs the success scenarios of the
// interp fixtures through the pure-AST templates of lib/interp.esm. The Go
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
			var fixture templateScenarioFixture
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

// TestDatetimeScenariosThroughCalendarTemplates runs the datetime fixtures
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
			var fixture templateScenarioFixture
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
