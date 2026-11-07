package esm

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// TestRelationalScenariosThroughLibraryTemplates runs every scenario of
// tests/conformance/relational_templates/scenarios.json through the `argmin`
// / `argmax` templates of lib/relational.esm. The Go evaluator has no rule for
// `faq`, so the test checks the expansion: the import resolves, and each
// right-hand side is the template body with `f` (the candidate value over the
// template's loop symbol) and `n` (also inside the `faq` `ranges` bounds)
// replaced by the scenario's binding (esm-spec §9.6.3 constraint 5).
func TestRelationalScenariosThroughLibraryTemplates(t *testing.T) {
	repoRoot := filepath.Join(closedFunctionsFixturesDir(t), "..", "..")
	libraryPath := filepath.Join(repoRoot, "lib", "relational.esm")
	libRaw, err := os.ReadFile(libraryPath)
	if err != nil {
		t.Fatalf("read %s: %v", libraryPath, err)
	}
	var library struct {
		Templates map[string]struct {
			Params []string `json:"params"`
			Body   any      `json:"body"`
		} `json:"expression_templates"`
	}
	if err := json.Unmarshal(libRaw, &library); err != nil {
		t.Fatalf("parse %s: %v", libraryPath, err)
	}
	raw, err := os.ReadFile(filepath.Join(repoRoot, "tests", "conformance", "relational_templates", "scenarios.json"))
	if err != nil {
		t.Fatal(err)
	}
	var spec struct {
		Scenarios []struct {
			Name   string `json:"name"`
			Op     string `json:"op"`
			Values []any  `json:"values"`
		} `json:"scenarios"`
	}
	if err := json.Unmarshal(raw, &spec); err != nil {
		t.Fatal(err)
	}
	constArray := func(v []float64) map[string]any { return map[string]any{"op": "const", "args": []any{}, "value": v} }
	variables := map[string]any{}
	equations := []any{}
	calls := make([]map[string]any, len(spec.Scenarios))
	for i, sc := range spec.Scenarios {
		tmpl, ok := library.Templates[sc.Op]
		if !ok {
			t.Fatalf("%s declares no %q template", libraryPath, sc.Op)
		}
		if !reflect.DeepEqual(tmpl.Params, []string{"f", "n"}) {
			t.Fatalf("%s params = %v, want [f n]", sc.Op, tmpl.Params)
		}
		// A candidate is num / den, so a non-finite one fits in a `const`.
		num := make([]float64, len(sc.Values))
		den := make([]float64, len(sc.Values))
		for k, v := range sc.Values {
			switch v {
			case "NaN":
				num[k], den[k] = 0, 0
			case "Inf":
				num[k], den[k] = 1, 0
			case "-Inf":
				num[k], den[k] = -1, 0
			default:
				num[k], den[k] = v.(float64), 1
			}
		}
		sym := "k_" + sc.Op + "_1"
		calls[i] = map[string]any{
			"f": map[string]any{"op": "/", "args": []any{
				map[string]any{"op": "index", "args": []any{constArray(num), sym}},
				map[string]any{"op": "index", "args": []any{constArray(den), sym}},
			}},
			"n": len(sc.Values),
		}
		out := fmt.Sprintf("out_%d", i)
		variables[out] = map[string]any{"type": "unknown", "default": 0.0, "units": "1"}
		equations = append(equations, map[string]any{
			"lhs": map[string]any{"op": "D", "args": []any{out}, "wrt": "t"},
			"rhs": map[string]any{
				"op": "apply_expression_template", "args": []any{},
				"name": sc.Op, "bindings": calls[i],
			},
		})
	}
	doc := map[string]any{
		"esm":      "1.1.0",
		"metadata": map[string]any{"name": "relational_templates"},
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
		body := library.Templates[spec.Scenarios[i].Op].Body
		wantTree := jsonRoundTrip(t, substituteTemplateParams(body, calls[i]))
		if !reflect.DeepEqual(gotTree, wantTree) {
			t.Errorf("%s: expanded right-hand side differs from the substituted body\n got: %s", spec.Scenarios[i].Name, s)
		}
	}
}

// TestRelationalTemplateTierDocumentsExpand loads the two documents of the
// relational_templates tier: each template reference resolves and none
// survives load.
func TestRelationalTemplateTierDocumentsExpand(t *testing.T) {
	dir := filepath.Join(closedFunctionsFixturesDir(t), "..", "conformance", "relational_templates", "fixtures")
	for _, name := range []string{"argmin_template.esm", "nearest_generator_template_ode.esm"} {
		file, err := LoadPath(filepath.Join(dir, name))
		if err != nil {
			t.Fatalf("%s: load: %v", name, err)
		}
		for mname, m := range file.Models {
			for i, eq := range m.Equations {
				s, err := SerializeExpressionCompact(eq.RHS)
				if err != nil {
					t.Fatal(err)
				}
				if strings.Contains(s, "apply_expression_template") {
					t.Errorf("%s %s equation %d: a template reference survived load", name, mname, i)
				}
			}
		}
	}
}
