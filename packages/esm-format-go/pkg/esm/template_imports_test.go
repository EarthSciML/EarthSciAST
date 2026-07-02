package esm

// Tests for esm-spec §9.7 — template-library files,
// `expression_template_imports`, and load-time `metaparameters`
// (docs/content/rfcs/template-library-imports.md; esm-libraries-spec §2.1c).
//
// Drives the shared conformance fixtures under
// tests/conformance/expression_templates/ and the resolver-level invalid
// fixtures under tests/invalid/template_imports/, mirroring the Julia
// reference testset EarthSciSerialization.jl/test/template_imports_test.jl.

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func tiRepoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	return root
}

func tiConfDir(t *testing.T, parts ...string) string {
	t.Helper()
	return filepath.Join(append([]string{tiRepoRoot(t), "tests", "conformance",
		"expression_templates"}, parts...)...)
}

// tiCanonJSON normalizes any JSON-marshalable value to a canonical string:
// marshal → plain decode (every number becomes float64) → marshal with Go's
// sorted map keys. Both sides of a golden comparison go through the same
// normalization, so json.Number / int64 / float64 encodings compare equal.
// Fixture literals avoid integral-valued floats (conformance README), so the
// float64 round-trip cannot conflate int and float spellings.
func tiCanonJSON(t *testing.T, v interface{}) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var plain interface{}
	if err := json.Unmarshal(b, &plain); err != nil {
		t.Fatalf("re-decode: %v", err)
	}
	out, err := json.Marshal(plain)
	if err != nil {
		t.Fatalf("re-marshal: %v", err)
	}
	return string(out)
}

// tiExpandRaw runs the raw §9.7 pipeline (resolve → lower) over a fixture,
// mirroring the Julia golden generator
// scripts/generate-template-import-goldens.jl.
func tiExpandRaw(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	out, err := resolveAndLowerJSON(string(data), filepath.Dir(path), nil)
	if err != nil {
		t.Fatalf("resolve+lower %s: %v", path, err)
	}
	var v interface{}
	if err := json.Unmarshal([]byte(out), &v); err != nil {
		t.Fatalf("decode expanded: %v", err)
	}
	return tiCanonJSON(t, v)
}

func tiGolden(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden %s: %v", path, err)
	}
	var v interface{}
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatalf("decode golden %s: %v", path, err)
	}
	return tiCanonJSON(t, v)
}

func tiErrCode(t *testing.T, err error) string {
	t.Helper()
	var etErr *ExpressionTemplateError
	if errors.As(err, &etErr) {
		return etErr.Code
	}
	return fmt.Sprintf("<%T: %v>", err, err)
}

// stripVarUnits drops `units` keys for the metaparameter_resolutions golden
// comparison: those goldens are the Julia reference's TYPED round-trip, and
// the Julia serializer does not emit ModelVariable `units`
// (serialize_model_variable omits the field), so the goldens carry none.
// Everything else must match structurally.
func stripVarUnits(x interface{}) interface{} {
	switch v := x.(type) {
	case map[string]interface{}:
		out := make(map[string]interface{}, len(v))
		for k, c := range v {
			if k == "units" {
				continue
			}
			out[k] = stripVarUnits(c)
		}
		return out
	case []interface{}:
		out := make([]interface{}, len(v))
		for i, c := range v {
			out[i] = stripVarUnits(c)
		}
		return out
	}
	return x
}

// ---------------------------------------------------------------------------
// Conformance fixture groups vs the committed Julia goldens
// ---------------------------------------------------------------------------

func TestTemplateImports_ConformanceGoldens(t *testing.T) {
	cases := []struct{ group, fixture, golden string }{
		{"import_smoke", "fixture.esm", "expanded.esm"},
		{"import_diamond", "fixture.esm", "expanded.esm"},
		{"import_order_determinism", "fixture_import_order.esm", "expanded_import_order.esm"},
		{"import_order_determinism", "fixture_priority_override.esm", "expanded_priority_override.esm"},
	}
	for _, tc := range cases {
		t.Run(tc.group+"/"+tc.golden, func(t *testing.T) {
			got := tiExpandRaw(t, tiConfDir(t, tc.group, tc.fixture))
			want := tiGolden(t, tiConfDir(t, tc.group, tc.golden))
			if got != want {
				t.Errorf("expanded form diverges from golden:\n got=%s\nwant=%s", got, want)
			}
		})
	}
}

func TestTemplateImports_ImportSmokeTypedLoad(t *testing.T) {
	f, err := Load(tiConfDir(t, "import_smoke", "fixture.esm"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if f.IndexSets["lon"].Size == nil || *f.IndexSets["lon"].Size != 288 {
		t.Errorf("lon size = %v; want 288", f.IndexSets["lon"].Size)
	}
	if f.IndexSets["lat"].Size == nil || *f.IndexSets["lat"].Size != 181 {
		t.Errorf("lat size = %v; want 181", f.IndexSets["lat"].Size)
	}
}

func TestTemplateImports_DiamondDedupsAtFirstOccurrence(t *testing.T) {
	f, err := Load(tiConfDir(t, "import_diamond", "fixture.esm"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if f.IndexSets["cells"].Size == nil || *f.IndexSets["cells"].Size != 10 {
		t.Errorf("cells size = %v; want 10 (NC default, deduped once)", f.IndexSets["cells"].Size)
	}
}

func TestTemplateImports_EffectiveOrderAndPriority(t *testing.T) {
	// Winner sanity, independent of the goldens: earlier import wins the
	// equal-priority tie (2*x); explicit priority 10 out-ranks it (5*x).
	check := func(fixture string, want string) {
		t.Helper()
		got := tiExpandRaw(t, tiConfDir(t, "import_order_determinism", fixture))
		if !strings.Contains(got, want) {
			t.Errorf("%s: expanded form %s does not contain %s", fixture, got, want)
		}
	}
	check("fixture_import_order.esm", `"args":[2,"x"]`)
	check("fixture_priority_override.esm", `"args":[5,"x"]`)
}

// ---------------------------------------------------------------------------
// Valid suite: library file + minimal consumer
// ---------------------------------------------------------------------------

func TestTemplateImports_ValidSuiteLibraryFile(t *testing.T) {
	libPath := filepath.Join(tiRepoRoot(t), "tests", "valid", "template_import_lib.esm")
	// A model-less template-library document loads (esm-spec §9.7.1);
	// round-trip strips every §9.7 construct, leaving the folded registry.
	lib, err := Load(libPath)
	if err != nil {
		t.Fatalf("Load(lib): %v", err)
	}
	if len(lib.Models) != 0 {
		t.Errorf("library file has models: %v", lib.Models)
	}
	if lib.IndexSets["cells"].Size == nil || *lib.IndexSets["cells"].Size != 8 {
		t.Errorf("cells size = %v; want 8 (size \"N\" folded by default)", lib.IndexSets["cells"].Size)
	}
	// Loader-API binding overrides the default on the library itself.
	lib12, err := Load(libPath, WithMetaparameters(map[string]int64{"N": 12}))
	if err != nil {
		t.Fatalf("Load(lib, N=12): %v", err)
	}
	if lib12.IndexSets["cells"].Size == nil || *lib12.IndexSets["cells"].Size != 12 {
		t.Errorf("cells size = %v; want 12 (API > default)", lib12.IndexSets["cells"].Size)
	}
}

func TestTemplateImports_ValidSuiteMinimalConsumer(t *testing.T) {
	m, err := Load(filepath.Join(tiRepoRoot(t), "tests", "valid", "template_import_minimal.esm"))
	if err != nil {
		t.Fatalf("Load(minimal): %v", err)
	}
	if m.IndexSets["cells"].Size == nil || *m.IndexSets["cells"].Size != 8 {
		t.Errorf("cells size = %v; want 8 (§9.7.5 merge into consumer)", m.IndexSets["cells"].Size)
	}
	y, ok := m.Models["M"].Variables["y"].Expression.(ExprNode)
	if !ok {
		t.Fatalf("y expression is %T; want ExprNode", m.Models["M"].Variables["y"].Expression)
	}
	if y.Op != "*" {
		t.Errorf("y op = %s; want *", y.Op)
	}
	if got := mustJSON(t, y.Args); got != `["x",8]` {
		t.Errorf("y args = %s; want [\"x\",8]", got)
	}
}

// ---------------------------------------------------------------------------
// metaparameter_resolutions: subsystem-ref bindings (§9.7.6 site 3)
// ---------------------------------------------------------------------------

func TestTemplateImports_MetaparameterResolutions(t *testing.T) {
	cases := []struct {
		wrapper, golden string
		n               int64
	}{
		{"wrapper_n4.esm", "expanded_n4.esm", 4},
		{"wrapper_n8.esm", "expanded_n8.esm", 8},
	}
	for _, tc := range cases {
		t.Run(tc.wrapper, func(t *testing.T) {
			f, err := Load(tiConfDir(t, "metaparameter_resolutions", tc.wrapper))
			if err != nil {
				t.Fatalf("Load: %v", err)
			}
			sub, ok := f.Models["Sweep"].Subsystems["Problem"].(map[string]interface{})
			if !ok {
				t.Fatalf("Problem subsystem is %T; want map", f.Models["Sweep"].Subsystems["Problem"])
			}
			vars := sub["variables"].(map[string]interface{})
			// Expression position: bare "N" substituted as an integer literal.
			nptsJSON := mustJSON(t, vars["npts"].(map[string]interface{})["expression"])
			if nptsJSON != fmt.Sprintf("%d", tc.n) {
				t.Errorf("npts expression = %s; want %d", nptsJSON, tc.n)
			}
			// Expression-position division stays an AST division (no folding).
			halfJSON := mustJSON(t, vars["half"].(map[string]interface{})["expression"])
			wantHalf := fmt.Sprintf(`{"args":[%d,2],"op":"/"}`, tc.n)
			if halfJSON != wantHalf {
				t.Errorf("half expression = %s; want %s", halfJSON, wantHalf)
			}
			// Structural site: the aggregate dense range folded exactly.
			ramp := vars["ramp"].(map[string]interface{})["expression"].(map[string]interface{})
			rangesJSON := mustJSON(t, ramp["ranges"])
			wantRanges := fmt.Sprintf(`{"i":[1,%d]}`, tc.n/2)
			if rangesJSON != wantRanges {
				t.Errorf("ramp ranges = %s; want %s", rangesJSON, wantRanges)
			}
			// The models subtree matches the golden structurally (modulo the
			// Julia serializer's ModelVariable-units omission — see
			// stripVarUnits).
			b, err := json.Marshal(f.Models)
			if err != nil {
				t.Fatalf("marshal models: %v", err)
			}
			var gotModels interface{}
			if err := json.Unmarshal(b, &gotModels); err != nil {
				t.Fatalf("re-decode models: %v", err)
			}
			goldenPath := tiConfDir(t, "metaparameter_resolutions", tc.golden)
			goldenBytes, err := os.ReadFile(goldenPath)
			if err != nil {
				t.Fatalf("read golden: %v", err)
			}
			var golden map[string]interface{}
			if err := json.Unmarshal(goldenBytes, &golden); err != nil {
				t.Fatalf("decode golden: %v", err)
			}
			got := tiCanonJSON(t, stripVarUnits(gotModels))
			want := tiCanonJSON(t, golden["models"])
			if got != want {
				t.Errorf("models subtree diverges from %s:\n got=%s\nwant=%s", tc.golden, got, want)
			}
		})
	}
}

func TestTemplateImports_LoaderAPIBindingsAndDefaults(t *testing.T) {
	problem := tiConfDir(t, "metaparameter_resolutions", "problem.esm")
	fdef, err := Load(problem)
	if err != nil {
		t.Fatalf("Load(problem): %v", err)
	}
	nptsDefault := fdef.Models["Problem"].Variables["npts"].Expression
	if got := mustJSON(t, nptsDefault); got != "2" {
		t.Errorf("default npts = %s; want 2", got)
	}
	fapi, err := Load(problem, WithMetaparameters(map[string]int64{"N": 6}))
	if err != nil {
		t.Fatalf("Load(problem, N=6): %v", err)
	}
	if got := mustJSON(t, fapi.Models["Problem"].Variables["npts"].Expression); got != "6" {
		t.Errorf("API npts = %s; want 6 (API > default)", got)
	}
	// Binding a name the document does not declare is an error.
	_, err = Load(problem, WithMetaparameters(map[string]int64{"Q": 1}))
	if code := tiErrCode(t, err); code != "template_import_unknown_name" {
		t.Errorf("unknown API binding code = %s; want template_import_unknown_name", code)
	}
}

func TestTemplateImports_RoundTripEmitsExpandedFoldedForm(t *testing.T) {
	f, err := Load(tiConfDir(t, "import_smoke", "fixture.esm"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	out, err := f.ToJSON()
	if err != nil {
		t.Fatalf("ToJSON: %v", err)
	}
	text := string(out)
	for _, construct := range []string{"expression_template_imports", "metaparameters",
		"expression_templates", "apply_expression_template"} {
		if strings.Contains(text, construct) {
			t.Errorf("round-trip output still contains %s", construct)
		}
	}
}

// ---------------------------------------------------------------------------
// Invalid fixtures: every §9.7 diagnostic code, machine-checked
// ---------------------------------------------------------------------------

func TestTemplateImports_InvalidFixtures(t *testing.T) {
	repoRoot := tiRepoRoot(t)
	invalidDir := filepath.Join(repoRoot, "tests", "invalid", "template_imports")
	expectedPath := filepath.Join(repoRoot, "tests", "invalid", "expected_errors.json")
	expectedBytes, err := os.ReadFile(expectedPath)
	if err != nil {
		t.Fatalf("read expected_errors.json: %v", err)
	}
	var expected map[string]struct {
		ResolverOnly      bool   `json:"resolver_only"`
		ResolverErrorCode string `json:"resolver_error_code"`
	}
	if err := json.Unmarshal(expectedBytes, &expected); err != nil {
		t.Fatalf("parse expected_errors.json: %v", err)
	}

	files, err := filepath.Glob(filepath.Join(invalidDir, "*.esm"))
	if err != nil {
		t.Fatalf("glob: %v", err)
	}
	if len(files) == 0 {
		t.Fatalf("no template_imports invalid fixtures found")
	}

	seenCodes := map[string]bool{}
	for _, path := range files {
		name := filepath.Base(path)
		t.Run(name, func(t *testing.T) {
			entry, ok := expected[name]
			if !ok {
				t.Fatalf("no expected_errors.json entry for %s", name)
			}
			if !entry.ResolverOnly {
				t.Fatalf("%s is not flagged resolver_only", name)
			}
			// The fixtures are SCHEMA-VALID (the §9.7 constructs are legal
			// schema); with the §9.7 resolver in the Go load path they are
			// rejected at load with the stable diagnostic code.
			_, err := Load(path)
			if err == nil {
				t.Fatalf("expected %s to be rejected, but it loaded", name)
			}
			if code := tiErrCode(t, err); code != entry.ResolverErrorCode {
				t.Errorf("%s: code = %s; want %s", name, code, entry.ResolverErrorCode)
			} else {
				seenCodes[code] = true
			}
		})
	}

	// The fixture set exercises the full §9.6.6 §9.7 code table (the 12th,
	// template_import_unresolved, is exercised by the unit tests below — a
	// missing file is not representable as a fixture).
	for _, code := range []string{
		"template_import_version_too_old", "template_import_not_library",
		"subsystem_ref_is_template_library", "template_import_cycle",
		"template_import_name_conflict", "template_import_unknown_name",
		"template_import_index_set_conflict",
		"apply_expression_template_recursive_body",
		"template_body_expansion_too_deep", "metaparameter_unbound",
		"metaparameter_type_error", "metaparameter_name_conflict",
	} {
		if !seenCodes[code] {
			t.Errorf("code %s not exercised by the invalid fixture set", code)
		}
	}
}

// ---------------------------------------------------------------------------
// Unit-level behavior over generated files
// ---------------------------------------------------------------------------

func tiModelJSON(extraModelFields, topFields string) string {
	return fmt.Sprintf(`{
      "esm": "0.8.0",
      "metadata": {"name": "t"},%s
      "models": {
        "M": {%s
          "variables": {"x": {"type": "state", "units": "1", "default": 0.5}},
          "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                         "rhs": {"op": "-", "args": ["x"]}}]
        }
      }
    }`, topFields, extraModelFields)
}

func TestTemplateImports_UnresolvedMissingAndUnparsableRef(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "m.esm")
	writeFileString(t, p, tiModelJSON(
		`"expression_template_imports": [{"ref": "./nope.esm"}],`, ""))
	_, err := Load(p)
	if code := tiErrCode(t, err); code != "template_import_unresolved" {
		t.Errorf("missing ref code = %s; want template_import_unresolved", code)
	}
	writeFileString(t, filepath.Join(dir, "junk.esm"), "{not json")
	writeFileString(t, p, tiModelJSON(
		`"expression_template_imports": [{"ref": "./junk.esm"}],`, ""))
	_, err = Load(p)
	if code := tiErrCode(t, err); code != "template_import_unresolved" {
		t.Errorf("junk ref code = %s; want template_import_unresolved", code)
	}
}

func writeFileString(t *testing.T, path, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func TestTemplateImports_OnlyFiltersVisibilityNotInternalWiring(t *testing.T) {
	dir := t.TempDir()
	writeFileString(t, filepath.Join(dir, "lib.esm"), `{
      "esm": "0.8.0",
      "metadata": {"name": "lib"},
      "expression_templates": {
        "t_inner": {"params": [], "body": 7},
        "t_keep": {"params": [], "body": {"op": "*", "args": [2,
          {"op": "apply_expression_template", "args": [], "name": "t_inner", "bindings": {}}]}},
        "t_drop": {"params": [], "body": 9}
      }
    }`)
	// t_keep's body reference to t_inner resolved in the LIBRARY's own scope,
	// so importing only t_keep still yields 2 * 7.
	src := tiModelJSON(
		`"expression_template_imports": [{"ref": "./lib.esm", "only": ["t_keep"]}],`, "")
	view := decodeFixture(t, src)
	orders := extractTemplateOrders(src)
	if _, err := resolveTemplateMachinery(view, orders, dir, nil); err != nil {
		t.Fatalf("resolve: %v", err)
	}
	tpl := view["models"].(map[string]interface{})["M"].(map[string]interface{})["expression_templates"].(map[string]interface{})
	if len(tpl) != 1 {
		t.Fatalf("expected only t_keep in scope, got %v", sortedKeys(tpl))
	}
	body := tpl["t_keep"].(map[string]interface{})["body"]
	if got := mustJSON(t, body); got != `{"args":[2,7],"op":"*"}` {
		t.Errorf("composed body = %s; want {\"args\":[2,7],\"op\":\"*\"}", got)
	}
	// Referencing a filtered-out name from an expression position fails.
	p2 := filepath.Join(dir, "m2.esm")
	writeFileString(t, p2, tiModelJSON(
		`"expression_template_imports": [{"ref": "./lib.esm", "only": ["t_keep"]}],
         "expression_templates": {"local_uses_drop": {"params": [],
           "body": {"op": "apply_expression_template", "args": [], "name": "t_drop", "bindings": {}}}},`, ""))
	_, err := Load(p2)
	if code := tiErrCode(t, err); code != "apply_expression_template_unknown_template" {
		t.Errorf("filtered-out reference code = %s; want apply_expression_template_unknown_template", code)
	}
}

func TestTemplateImports_DiamondWithConflictingEdgeBindings(t *testing.T) {
	dir := t.TempDir()
	writeFileString(t, filepath.Join(dir, "grid.esm"), `{
      "esm": "0.8.0", "metadata": {"name": "grid"},
      "metaparameters": {"NC": {"type": "integer"}},
      "index_sets": {"cells": {"kind": "interval", "size": "NC"}},
      "expression_templates": {"nc": {"params": [], "body": "NC"}}
    }`)
	p := filepath.Join(dir, "m.esm")
	writeFileString(t, p, tiModelJSON(
		`"expression_template_imports": [
           {"ref": "./grid.esm", "bindings": {"NC": 4}},
           {"ref": "./grid.esm", "bindings": {"NC": 8}}],`, ""))
	_, err := Load(p)
	code := tiErrCode(t, err)
	if code != "template_import_name_conflict" && code != "template_import_index_set_conflict" {
		t.Errorf("conflicting diamond code = %s; want a §9.7.4/§9.7.5 conflict", code)
	}
	// Equal instantiation on both edges dedups cleanly.
	writeFileString(t, p, tiModelJSON(
		`"expression_template_imports": [
           {"ref": "./grid.esm", "bindings": {"NC": 4}},
           {"ref": "./grid.esm", "bindings": {"NC": 4}}],`, ""))
	f, err := Load(p)
	if err != nil {
		t.Fatalf("equal-binding diamond should load: %v", err)
	}
	if f.IndexSets["cells"].Size == nil || *f.IndexSets["cells"].Size != 4 {
		t.Errorf("cells size = %v; want 4", f.IndexSets["cells"].Size)
	}
}

func TestTemplateImports_EdgeBindingUnknownNameAndNonInteger(t *testing.T) {
	dir := t.TempDir()
	writeFileString(t, filepath.Join(dir, "lib.esm"), `{
      "esm": "0.8.0", "metadata": {"name": "lib"},
      "metaparameters": {"N": {"type": "integer", "default": 8}},
      "expression_templates": {"n": {"params": [], "body": "N"}}
    }`)
	p := filepath.Join(dir, "m.esm")
	writeFileString(t, p, tiModelJSON(
		`"expression_template_imports": [{"ref": "./lib.esm", "bindings": {"Q": 1}}],`, ""))
	_, err := Load(p)
	if code := tiErrCode(t, err); code != "template_import_unknown_name" {
		t.Errorf("unknown edge binding code = %s; want template_import_unknown_name", code)
	}
	// A non-integer binding: the resolver-level backstop reports
	// metaparameter_type_error (via the raw resolver; the schema also rejects
	// it in the full load path).
	src := tiModelJSON(
		`"expression_template_imports": [{"ref": "./lib.esm", "bindings": {"N": 2.5}}],`, "")
	view := decodeFixture(t, src)
	_, rerr := resolveTemplateMachinery(view, extractTemplateOrders(src), dir, nil)
	if code := tiErrCode(t, rerr); code != "metaparameter_type_error" {
		t.Errorf("non-integer edge binding code = %s; want metaparameter_type_error", code)
	}
}

func TestTemplateImports_FoldRangesRegionsSizeExact(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "m.esm")
	writeFileString(t, p, `{
      "esm": "0.8.0",
      "metadata": {"name": "fold"},
      "metaparameters": {"N": {"type": "integer", "default": 6}},
      "index_sets": {"cells": {"kind": "interval", "size": {"op": "*", "args": ["N", 2]}}},
      "models": {
        "M": {
          "variables": {
            "x": {"type": "state", "units": "1", "default": 0.5},
            "agg": {"type": "observed", "units": "1",
              "expression": {"op": "aggregate", "output_idx": ["i"], "args": ["x"],
                "ranges": {"i": [1, {"op": "-", "args": ["N", 1]}]},
                "expr": {"op": "*", "args": ["x", "i"]}}},
            "ma": {"type": "observed", "units": "1",
              "expression": {"op": "makearray", "args": [],
                "regions": [[[{"op": "/", "args": ["N", 2]}, "N"]]],
                "values": [1.5]}}
          },
          "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                         "rhs": {"op": "-", "args": ["x"]}}]
        }
      }
    }`)
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	out, err := resolveAndLowerJSON(string(data), dir, nil)
	if err != nil {
		t.Fatalf("resolve+lower: %v", err)
	}
	var doc map[string]interface{}
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got := mustJSON(t, doc["index_sets"]); got != `{"cells":{"kind":"interval","size":12}}` {
		t.Errorf("index_sets = %s; want cells size 12", got)
	}
	vars := doc["models"].(map[string]interface{})["M"].(map[string]interface{})["variables"].(map[string]interface{})
	agg := vars["agg"].(map[string]interface{})["expression"].(map[string]interface{})
	if got := mustJSON(t, agg["ranges"]); got != `{"i":[1,5]}` {
		t.Errorf("agg ranges = %s; want {\"i\":[1,5]}", got)
	}
	ma := vars["ma"].(map[string]interface{})["expression"].(map[string]interface{})
	if got := mustJSON(t, ma["regions"]); got != `[[[3,6]]]` {
		t.Errorf("ma regions = %s; want [[[3,6]]]", got)
	}
	// The typed load also succeeds.
	if _, err := Load(p); err != nil {
		t.Fatalf("typed Load: %v", err)
	}
}

func TestTemplateImports_ExpressionPositionSubstitutionNeverFolds(t *testing.T) {
	src := `{
      "esm": "0.8.0",
      "metadata": {"name": "subst"},
      "metaparameters": {"N": {"type": "integer", "default": 144}},
      "models": {
        "M": {
          "variables": {
            "x": {"type": "state", "units": "1", "default": 0.5},
            "dlon": {"type": "observed", "units": "1",
                     "expression": {"op": "/", "args": [360, "N"]}}
          },
          "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                         "rhs": {"op": "-", "args": ["x"]}}]
        }
      }
    }`
	out, err := resolveAndLowerJSON(src, ".", nil)
	if err != nil {
		t.Fatalf("resolve+lower: %v", err)
	}
	var doc map[string]interface{}
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("decode: %v", err)
	}
	dlon := doc["models"].(map[string]interface{})["M"].(map[string]interface{})["variables"].(map[string]interface{})["dlon"].(map[string]interface{})["expression"]
	if got := mustJSON(t, dlon); got != `{"args":[360,144],"op":"/"}` {
		t.Errorf("dlon = %s; want the un-folded AST division {\"args\":[360,144],\"op\":\"/\"}", got)
	}
}

func tiChainDoc(n int) string {
	var sb strings.Builder
	sb.WriteString(`{"esm": "0.8.0", "metadata": {"name": "chain"}, "models": {"M": {"expression_templates": {`)
	for i := 1; i <= n; i++ {
		if i > 1 {
			sb.WriteString(",")
		}
		if i == n {
			fmt.Fprintf(&sb, `"c_%02d": {"params": [], "body": 1}`, i)
		} else {
			fmt.Fprintf(&sb, `"c_%02d": {"params": [], "body": {"op": "apply_expression_template", "args": [], "name": "c_%02d", "bindings": {}}}`, i, i+1)
		}
	}
	sb.WriteString(`},
      "variables": {"x": {"type": "state", "default": 0.5}},
      "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                     "rhs": {"op": "-", "args": ["x"]}}]}}}`)
	return sb.String()
}

func TestTemplateImports_BodyCompositionDepthBoundIsExact(t *testing.T) {
	// A 3-deep local chain inlines through the §9.6.3 fixpoint untouched.
	src := `{
      "esm": "0.8.0", "metadata": {"name": "chain3"},
      "models": {"M": {
        "expression_templates": {
          "c1": {"params": [], "body": {"op": "+", "args": [1,
            {"op": "apply_expression_template", "args": [], "name": "c2", "bindings": {}}]}},
          "c2": {"params": [], "body": {"op": "+", "args": [2,
            {"op": "apply_expression_template", "args": [], "name": "c3", "bindings": {}}]}},
          "c3": {"params": [], "body": 3}
        },
        "variables": {"x": {"type": "state", "units": "1", "default": 0.5},
                      "y": {"type": "observed", "units": "1",
                            "expression": {"op": "apply_expression_template",
                                           "args": [], "name": "c1", "bindings": {}}}},
        "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                       "rhs": {"op": "-", "args": ["x"]}}]}}}`
	v := decodeFixture(t, src)
	if err := LowerExpressionTemplates(v); err != nil {
		t.Fatalf("lowering failed: %v", err)
	}
	y := v["models"].(map[string]interface{})["M"].(map[string]interface{})["variables"].(map[string]interface{})["y"].(map[string]interface{})
	if got := mustJSON(t, y["expression"]); got != `{"args":[1,{"args":[2,3],"op":"+"}],"op":"+"}` {
		t.Errorf("composed y = %s", got)
	}

	// Exactly MaxTemplateExpansionDepth templates chain: accepted; one more:
	// template_body_expansion_too_deep. The depth counts TEMPLATES on the
	// longest chain — a 33-template chain is rejected, 32 accepted (the
	// shared generated fixture pins the reject side; this pins the boundary).
	okDoc := decodeFixture(t, tiChainDoc(MaxTemplateExpansionDepth))
	if err := LowerExpressionTemplates(okDoc); err != nil {
		t.Errorf("%d-template chain must be accepted, got: %v", MaxTemplateExpansionDepth, err)
	}
	badDoc := decodeFixture(t, tiChainDoc(MaxTemplateExpansionDepth+1))
	err := LowerExpressionTemplates(badDoc)
	if code := tiErrCode(t, err); code != "template_body_expansion_too_deep" {
		t.Errorf("%d-template chain code = %s; want template_body_expansion_too_deep",
			MaxTemplateExpansionDepth+1, code)
	}
}

func TestTemplateImports_BodyMayNotReferenceMatchRule(t *testing.T) {
	src := tiModelJSON(`"expression_templates": {
      "rule": {"params": ["f"], "match": {"op": "lowerme", "args": ["f"]},
               "body": {"op": "*", "args": [2, "f"]}},
      "uses_rule": {"params": [], "body": {"op": "apply_expression_template",
                    "args": [], "name": "rule", "bindings": {"f": 1}}}
    },`, "")
	v := decodeFixture(t, src)
	err := LowerExpressionTemplates(v)
	if code := tiErrCode(t, err); code != "apply_expression_template_unknown_template" {
		t.Errorf("match-rule body reference code = %s; want apply_expression_template_unknown_template", code)
	}
}

func TestTemplateImports_MatchPatternMayNotContainApplyNode(t *testing.T) {
	// esm-spec §9.7.3: match patterns MUST NOT reference templates — the
	// match-with-apply rejection is apply_expression_template_invalid_declaration.
	src := tiModelJSON(`"expression_templates": {
      "frag": {"params": [], "body": 1},
      "rule": {"params": ["f"],
               "match": {"op": "lowerme", "args": [{"op": "apply_expression_template",
                         "args": [], "name": "frag", "bindings": {}}]},
               "body": {"op": "*", "args": [2, "f"]}}
    },`, "")
	v := decodeFixture(t, src)
	err := LowerExpressionTemplates(v)
	if code := tiErrCode(t, err); code != "apply_expression_template_invalid_declaration" {
		t.Errorf("match-with-apply code = %s; want apply_expression_template_invalid_declaration", code)
	}
}

func TestTemplateImports_VersionGateFlagsEveryConstruct(t *testing.T) {
	for _, snippet := range []string{
		`"metaparameters": {"N": {"type": "integer"}},`,
		`"expression_templates": {"t": {"params": [], "body": 1}},`,
	} {
		src := fmt.Sprintf(`{"esm": "0.7.0", "metadata": {"name": "old"},%s
          "models": {"M": {"variables": {"x": {"type": "state", "default": 0.5}},
                           "equations": []}}}`, snippet)
		v := decodeFixture(t, src)
		err := RejectTemplateImportsPreV08(v)
		if code := tiErrCode(t, err); code != "template_import_version_too_old" {
			t.Errorf("gate code for %s = %s; want template_import_version_too_old", snippet, code)
		}
	}
	// 0.8.0 files pass the gate.
	ok := decodeFixture(t, `{"esm": "0.8.0", "metadata": {"name": "new"},
      "metaparameters": {"N": {"type": "integer", "default": 1}},
      "expression_templates": {"t": {"params": [], "body": 1}}}`)
	if err := RejectTemplateImportsPreV08(ok); err != nil {
		t.Errorf("0.8.0 file must pass the gate, got: %v", err)
	}
}

func TestTemplateImports_CrossFileChainsDoNotAccumulateDepth(t *testing.T) {
	// The 32-template depth bound applies per composition scope: an imported
	// library's bodies arrive already CLOSED (composed in the library's own
	// scope, §9.7.3), so they count as depth-1 leaves in the importer — a
	// 32-deep chain in a library plus a consumer template referencing its
	// head is legal, not a 33-deep chain.
	dir := t.TempDir()
	chain := tiChainDoc(MaxTemplateExpansionDepth)
	var chainView map[string]interface{}
	if err := json.Unmarshal([]byte(chain), &chainView); err != nil {
		t.Fatalf("decode chain doc: %v", err)
	}
	tpl := chainView["models"].(map[string]interface{})["M"].(map[string]interface{})["expression_templates"]
	libDoc := map[string]interface{}{
		"esm":                  "0.8.0",
		"metadata":             map[string]interface{}{"name": "chainlib"},
		"expression_templates": tpl,
	}
	libBytes, err := json.Marshal(libDoc)
	if err != nil {
		t.Fatalf("marshal lib: %v", err)
	}
	writeFileString(t, filepath.Join(dir, "chainlib.esm"), string(libBytes))
	p := filepath.Join(dir, "m.esm")
	writeFileString(t, p, tiModelJSON(
		`"expression_template_imports": [{"ref": "./chainlib.esm"}],
         "expression_templates": {"uses_head": {"params": [],
           "body": {"op": "apply_expression_template", "args": [], "name": "c_01", "bindings": {}}}},`, ""))
	if _, err := Load(p); err != nil {
		t.Errorf("cross-file chain must not accumulate depth, got: %v", err)
	}
}

func TestTemplateImports_EffectiveOrderBeatsSortedNameFallback(t *testing.T) {
	// The §9.7.4 effective declaration order is imports (array order) then
	// locals — NOT sorted template names. Here the first import's rule name
	// (`z_rule`) sorts AFTER the second's (`a_rule`), so a sorted-name
	// tie-break would pick the wrong winner; the effective sequence must pin
	// z_rule (2*x). Guards the resolver → engine declaration-order plumbing
	// that Go's unordered maps would otherwise lose.
	dir := t.TempDir()
	writeFileString(t, filepath.Join(dir, "lib_first.esm"), `{
      "esm": "0.8.0", "metadata": {"name": "lib_first"},
      "expression_templates": {
        "z_rule": {"params": ["f"], "match": {"op": "lowerme", "args": ["f"]},
                   "body": {"op": "*", "args": [2, "f"]}}
      }
    }`)
	writeFileString(t, filepath.Join(dir, "lib_second.esm"), `{
      "esm": "0.8.0", "metadata": {"name": "lib_second"},
      "expression_templates": {
        "a_rule": {"params": ["f"], "match": {"op": "lowerme", "args": ["f"]},
                   "body": {"op": "*", "args": [3, "f"]}}
      }
    }`)
	p := filepath.Join(dir, "m.esm")
	writeFileString(t, p, `{
      "esm": "0.8.0", "metadata": {"name": "order"},
      "models": {"M": {
        "expression_template_imports": [
          {"ref": "./lib_first.esm"}, {"ref": "./lib_second.esm"}],
        "variables": {"x": {"type": "state", "units": "1", "default": 1.5},
                      "y": {"type": "observed", "units": "1",
                            "expression": {"op": "lowerme", "args": ["x"]}}},
        "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                       "rhs": {"op": "-", "args": ["x"]}}]}}}`)
	data, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	out, err := resolveAndLowerJSON(string(data), dir, nil)
	if err != nil {
		t.Fatalf("resolve+lower: %v", err)
	}
	var doc map[string]interface{}
	if err := json.Unmarshal([]byte(out), &doc); err != nil {
		t.Fatalf("decode: %v", err)
	}
	y := doc["models"].(map[string]interface{})["M"].(map[string]interface{})["variables"].(map[string]interface{})["y"].(map[string]interface{})
	if got := mustJSON(t, y["expression"]); got != `{"args":[2,"x"],"op":"*"}` {
		t.Errorf("y = %s; want the FIRST import's rule to win the tie (2*x)", got)
	}
}

func TestTemplateImports_ZeroParameterTemplatesAreLegal(t *testing.T) {
	// esm-spec §9.6.1 (0.8.0): params MAY be empty — a zero-parameter
	// template is a named constant fragment.
	src := `{
      "esm": "0.8.0", "metadata": {"name": "zp"},
      "models": {"M": {
        "expression_templates": {"two": {"params": [], "body": 2}},
        "variables": {"x": {"type": "state", "units": "1", "default": 0.5},
                      "y": {"type": "observed", "units": "1",
                            "expression": {"op": "apply_expression_template",
                                           "args": [], "name": "two", "bindings": {}}}},
        "equations": []}}}`
	v := decodeFixture(t, src)
	if err := LowerExpressionTemplates(v); err != nil {
		t.Fatalf("zero-param template must be legal, got: %v", err)
	}
	y := v["models"].(map[string]interface{})["M"].(map[string]interface{})["variables"].(map[string]interface{})["y"].(map[string]interface{})
	if got := mustJSON(t, y["expression"]); got != "2" {
		t.Errorf("y expression = %s; want 2", got)
	}
}
