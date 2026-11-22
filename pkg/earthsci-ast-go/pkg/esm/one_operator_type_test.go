package esm

// esm 2.4.0 "one operator type" (esm-spec §4.2, §4.8.3, §9.6.1–9.6.3, §9.6.6,
// §9.6.12; CONFORMANCE_SPEC §5.61): calls of defined operators resolve to
// definitions and become references, old spellings are read at the wire
// boundary, core names are reserved, arity is checked at load, unit
// expressions type a call. Fixtures under tests/conformance/expression_templates/.
// Mirrors pkg/EarthSciAST.jl/test/one_operator_type_test.jl.

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// ootStderr runs f and returns what it wrote to stderr.
func ootStderr(t *testing.T, f func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	saved := os.Stderr
	os.Stderr = w
	done := make(chan string)
	go func() {
		b, _ := io.ReadAll(r)
		done <- string(b)
	}()
	f()
	os.Stderr = saved
	_ = w.Close()
	out := <-done
	_ = r.Close()
	return out
}

func TestOneOperatorType_EmittedGoldens(t *testing.T) {
	for _, dir := range []string{"operator_call_by_name", "placeholder_call", "partial_wrt_param_instance", "old_names"} {
		t.Run(dir, func(t *testing.T) {
			got := oolEmit(t, dir, "fixture.esm")
			if want := mustRead(t, dir, "emitted.esm"); got != want {
				t.Errorf("emit != emitted.esm (byte for byte)\n--- got ---\n%s\n--- want ---\n%s", got, want)
			}
		})
	}
}

func TestOneOperatorType_OldSpellingsEmitAsNew(t *testing.T) {
	strip := func(s string) string {
		var d map[string]any
		if err := json.Unmarshal([]byte(s), &d); err != nil {
			t.Fatal(err)
		}
		delete(d, "metadata")
		return tiCanonJSON(t, d)
	}
	if a, b := strip(oolEmit(t, "old_names", "fixture.esm")), strip(oolEmit(t, "old_names", "new_names.esm")); a != b {
		t.Errorf("old spellings emit differently from the new ones:\n old=%s\n new=%s", a, b)
	}
}

func TestOneOperatorType_ExpandedGoldens(t *testing.T) {
	core := func(doc map[string]any) string {
		out := map[string]any{}
		for _, k := range []string{"models", "reaction_systems", "coupling", "index_sets"} {
			if v, ok := doc[k]; ok {
				out[k] = v
			}
		}
		return tiCanonJSON(t, out)
	}
	for _, dir := range []string{"operator_call_by_name", "partial_wrt_param_instance"} {
		t.Run(dir, func(t *testing.T) {
			p := oolConf(dir, "fixture.esm")
			src, err := os.ReadFile(p)
			if err != nil {
				t.Fatal(err)
			}
			out, err := ResolveAndLower(string(src), filepath.Dir(p), nil)
			if err != nil {
				t.Fatalf("resolve+lower: %v", err)
			}
			var got, want map[string]any
			if err := json.Unmarshal([]byte(out), &got); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal([]byte(mustRead(t, dir, "expanded.esm")), &want); err != nil {
				t.Fatal(err)
			}
			if g, w := core(got), core(want); g != w {
				t.Errorf("Expand(load) != expanded.esm:\n got=%s\nwant=%s", g, w)
			}
		})
	}
}

func TestOneOperatorType_LoadErrorsByCode(t *testing.T) {
	for _, c := range []struct{ dir, fixture, errf string }{
		{"operator_arity_mismatch", "fixture.esm", "error.json"},
		{"operator_defines_core_op", "fixture.esm", "error.json"},
		{"operator_defines_core_op", "explicit_defines.esm", "error_explicit_defines.json"},
	} {
		t.Run(c.dir+"/"+c.fixture, func(t *testing.T) {
			var want struct{ Code string }
			if err := json.Unmarshal([]byte(mustRead(t, c.dir, c.errf)), &want); err != nil {
				t.Fatal(err)
			}
			_, err := LoadPath(oolConf(c.dir, c.fixture))
			if got := tiErrCode(t, err); got != want.Code {
				t.Errorf("code = %q; want %q (%v)", got, want.Code, err)
			}
		})
	}
	// A rule whose match is rooted at a core op defines no callable name.
	if _, err := LoadPath(oolConf("operator_defines_core_op", "compound_rule_exempt.esm")); err != nil {
		t.Errorf("compound_rule_exempt.esm: %v", err)
	}
}

func TestOneOperatorType_OldSpellingsWarn(t *testing.T) {
	var err error
	out := ootStderr(t, func() { _, err = LoadPath(oolConf("old_names", "fixture.esm")) })
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	for _, code := range []string{"deprecated_field", "deprecated_op"} {
		if !strings.Contains(out, code) {
			t.Errorf("loading old_names/fixture.esm did not warn %s; stderr:\n%s", code, out)
		}
	}
	out = ootStderr(t, func() { _, err = LoadPath(oolConf("old_names", "new_names.esm")) })
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if strings.Contains(out, "deprecated_field") || strings.Contains(out, "deprecated_op") {
		t.Errorf("new_names.esm warned:\n%s", out)
	}
}

func TestOneOperatorType_BothSpellingsInOneObject(t *testing.T) {
	_, err := LoadString(`{"esm": "2.4.0", "metadata": {"name": "x"}, "models": {"m": {
		"variables": {"y": {"type": "unknown"}}, "equations": [{"lhs": "y", "rhs": 1}],
		"operators": {"f": {"params": [], "body": 1}},
		"expression_templates": {"g": {"params": [], "body": 2}}}}}`)
	if got := tiErrCode(t, err); got != CodeApplyExpressionTemplateInvalidDeclaration {
		t.Errorf("code = %q; want %q (%v)", got, CodeApplyExpressionTemplateInvalidDeclaration, err)
	}
}

func TestOneOperatorType_PlaceholderRefusedOnlyIfEvaluated(t *testing.T) {
	f, err := LoadPath(oolConf("placeholder_call", "fixture.esm"))
	if err != nil {
		t.Fatalf("a placeholder must load: %v", err)
	}
	var want struct{ Code string }
	if err := json.Unmarshal([]byte(mustRead(t, "placeholder_call", "error.json")), &want); err != nil {
		t.Fatal(err)
	}
	for _, eq := range f.Models["m"].Equations {
		_, err := Evaluate(eq.RHS, map[string]float64{"u": 1, "T": 1})
		var de DiagnosticError
		if !errors.As(err, &de) || de.DiagnosticCode() != want.Code {
			t.Errorf("Evaluate(%v) = %v; want %s", eq.RHS, err, want.Code)
		}
	}
}

func TestOneOperatorType_DefinitionUnits(t *testing.T) {
	var exp map[string]json.RawMessage
	if err := json.Unmarshal([]byte(mustRead(t, "definition_units", "expected.json")), &exp); err != nil {
		t.Fatal(err)
	}
	for _, f := range []string{"fixture.esm", "body_mismatch.esm", "call_unit_from_expression.esm"} {
		t.Run(f, func(t *testing.T) {
			var want struct{ Errors, Warnings []string }
			if err := json.Unmarshal(exp[f], &want); err != nil {
				t.Fatal(err)
			}
			file, err := LoadPath(oolConf("definition_units", f))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			r := Validate(file)
			errSet, warnSet := map[string]bool{}, map[string]bool{}
			for _, e := range r.StructuralErrors {
				errSet[e.Code] = true
			}
			for _, w := range r.UnitWarnings {
				if w.Code == codeDefinitionUnitMismatch {
					warnSet[w.Code] = true
				}
			}
			keys := func(m map[string]bool) []string {
				out := []string{}
				for k := range m {
					out = append(out, k)
				}
				sort.Strings(out)
				return out
			}
			sort.Strings(want.Errors)
			sort.Strings(want.Warnings)
			if g, w := strings.Join(keys(errSet), ","), strings.Join(want.Errors, ","); g != w {
				t.Errorf("errors = [%s]; want [%s] (%v)", g, w, r.StructuralErrors)
			}
			if g, w := strings.Join(keys(warnSet), ","), strings.Join(want.Warnings, ","); g != w {
				t.Errorf("warnings = [%s]; want [%s] (%v)", g, w, r.UnitWarnings)
			}
		})
	}
}

func TestOneOperatorType_CodeAliases(t *testing.T) {
	for old, want := range map[string]string{
		"template_import_cycle":                      "operator_import_cycle",
		"apply_expression_template_unknown_template": "operator_unknown_definition",
		"operator_import_cycle":                      "operator_import_cycle",
	} {
		if got := canonicalErrorCode(old); got != want {
			t.Errorf("canonicalErrorCode(%q) = %q; want %q", old, got, want)
		}
	}
}

func TestOneOperatorType_OldSpellingsIdempotent(t *testing.T) {
	src := mustRead(t, "old_names", "fixture.esm")
	once, f1, o1, err := rewriteOldSpellings(src)
	if err != nil || len(f1) == 0 || len(o1) == 0 {
		t.Fatalf("first pass: err=%v fields=%v ops=%v", err, f1, o1)
	}
	twice, f2, o2, err := rewriteOldSpellings(once)
	if err != nil || len(f2) != 0 || len(o2) != 0 || twice != once {
		t.Errorf("second pass not silent: err=%v fields=%v ops=%v", err, f2, o2)
	}
}

// A key repeated verbatim is not an old/new spelling pair: the old-spelling
// reading leaves it alone and the load decodes it as any duplicate key (the
// last occurrence wins), as the Julia reference does.
func TestOneOperatorType_DuplicateKeyIsNotBothSpellings(t *testing.T) {
	f, err := LoadString(`{"esm": "2.4.0", "metadata": {"name": "x", "name": "y"}, "models": {"m": {
		"variables": {"u": {"type": "unknown"}, "x": {"type": "parameter", "default": 1.0}},
		"equations": [{"lhs": {"op": "D", "args": ["u"], "wrt": "t"}, "rhs": "x"}]}}}`)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if f.Metadata.Name != "y" {
		t.Errorf("metadata.name = %q; want the last occurrence, \"y\"", f.Metadata.Name)
	}
	// A repeated old spelling is still read as the new one.
	out, fs, _, err := rewriteOldSpellings(`{"models": {"m": {"expression_templates": {}, "expression_templates": {}}}}`)
	if err != nil || len(fs) != 2 || strings.Contains(out, "expression_templates") {
		t.Errorf("repeated old spelling: out=%s fields=%v err=%v", out, fs, err)
	}
}

// The keys of an `operators` block are definition names, never field
// spellings: a definition named `expression_templates` keeps its name, and one
// block may hold definitions named both `operators` and `expression_templates`.
func TestOneOperatorType_DefinitionNamesAreNotRenamed(t *testing.T) {
	src := `{"esm": "2.4.0", "metadata": {"name": "x"}, "models": {"m": {
		"variables": {"u": {"type": "unknown"}, "x": {"type": "parameter", "default": 1.0}},
		"equations": [{"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
			"rhs": {"op": "+", "args": [{"op": "operators", "args": ["x"]}, {"op": "expression_templates", "args": ["x"]}]}}],
		"operators": {
			"operators": {"params": ["q"], "body": {"op": "*", "args": [2, "q"]}},
			"expression_templates": {"params": ["q"], "body": {"op": "*", "args": [3, "q"]}}}}}}`
	out, fs, _, err := rewriteOldSpellings(src)
	if err != nil {
		t.Fatalf("rewrite: %v", err)
	}
	if len(fs) != 0 || out != src {
		t.Errorf("definition names were rewritten: fields=%v\n%s", fs, out)
	}
	f, err := LoadString(src)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	got, err := Evaluate(f.Models["m"].Equations[0].RHS, map[string]float64{"x": 1})
	if err != nil || got != 5 {
		t.Errorf("rhs = %v, %v; want 5 (2x + 3x at x = 1)", got, err)
	}
}
