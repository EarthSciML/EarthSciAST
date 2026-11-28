package esm

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

// TestIcSystemLoads runs every load of tests/conformance/ic_system (esm 2.5.0,
// esm-spec §11.4.4, §4.2, §11.4.3): a deprecated `initialization_equations`
// block is read as `ic` equations or `guesses` with the warning
// `deprecated_field`, a malformed `ic` argument or an `ic` of a parameter is
// refused at load with `ic_invalid_argument`, and validate reports exactly the
// codes each load names. A load error is compared on its DiagnosticCode, the
// warnings and validate's codes exactly. Go does not simulate, so the
// manifest's `cases` are not run here.
func TestIcSystemLoads(t *testing.T) {
	dir := filepath.Join(conformanceRepoRoot(t), "tests", "conformance", "ic_system")
	raw, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var m struct {
		Loads []struct {
			ID             string         `json:"id"`
			Fixture        string         `json:"fixture"`
			Model          string         `json:"model"`
			Warnings       []string       `json:"warnings"`
			EquationsTail  []any          `json:"equations_tail"`
			EquationsCount *int           `json:"equations_count"`
			Guesses        map[string]any `json:"guesses"`
			ParamDefaults  map[string]any `json:"parameter_defaults"`
			NoField        string         `json:"no_field"`
			LoadError      string         `json:"load_error"`
			ValidateErrors []string       `json:"validate_errors"`
		} `json:"loads"`
	}
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	if len(m.Loads) < 22 {
		t.Fatalf("%d loads in the manifest, want at least 22", len(m.Loads))
	}
	for _, l := range m.Loads {
		t.Run(l.ID, func(t *testing.T) {
			file, stderr, err := loadWithStderr(t, filepath.Join(dir, l.Fixture))
			if l.LoadError != "" {
				var de DiagnosticError
				if !errors.As(err, &de) {
					t.Fatalf("expected a load error with code %q, got %v", l.LoadError, err)
				}
				if de.DiagnosticCode() != l.LoadError {
					t.Fatalf("load error code %q, want %q (%v)", de.DiagnosticCode(), l.LoadError, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			if l.Warnings != nil {
				if got := warningCodes(stderr); !reflect.DeepEqual(got, l.Warnings) {
					t.Errorf("warnings %v, want %v", got, l.Warnings)
				}
			}
			if l.ValidateErrors != nil {
				got := []string{}
				for _, e := range Validate(file).StructuralErrors {
					got = append(got, e.Code)
				}
				want := append([]string{}, l.ValidateErrors...)
				sort.Strings(got)
				sort.Strings(want)
				if !reflect.DeepEqual(got, want) {
					t.Errorf("validate reports %v, want %v", got, want)
				}
			}
			if l.Model == "" {
				return
			}
			text, err := ToJSON(file)
			if err != nil {
				t.Fatal(err)
			}
			var doc map[string]any
			if err := json.Unmarshal([]byte(text), &doc); err != nil {
				t.Fatal(err)
			}
			model := doc["models"].(map[string]any)[l.Model].(map[string]any)
			if l.NoField != "" {
				if _, has := model[l.NoField]; has {
					t.Errorf("%s survives the load", l.NoField)
				}
			}
			eqs, _ := model["equations"].([]any)
			if l.EquationsTail != nil {
				if len(eqs) < len(l.EquationsTail) {
					t.Fatalf("%d equations, want at least %d", len(eqs), len(l.EquationsTail))
				}
				got := eqs[len(eqs)-len(l.EquationsTail):]
				if !reflect.DeepEqual(normalizeJSON(t, got), normalizeJSON(t, l.EquationsTail)) {
					t.Errorf("appended equations\n got %v\nwant %v", got, l.EquationsTail)
				}
			}
			if l.EquationsCount != nil && len(eqs) != *l.EquationsCount {
				t.Errorf("%d equations, want %d", len(eqs), *l.EquationsCount)
			}
			if l.Guesses != nil && !reflect.DeepEqual(normalizeJSON(t, model["guesses"]), normalizeJSON(t, l.Guesses)) {
				t.Errorf("guesses %v, want %v", model["guesses"], l.Guesses)
			}
			vars, _ := model["variables"].(map[string]any)
			for k, want := range l.ParamDefaults {
				v, _ := vars[k].(map[string]any)
				if !reflect.DeepEqual(normalizeJSON(t, v["default"]), normalizeJSON(t, want)) {
					t.Errorf("parameter %s has default %v, want %v", k, v["default"], want)
				}
			}
		})
	}
}

// loadWithStderr loads path and returns what the load wrote to stderr.
func loadWithStderr(t *testing.T, path string) (*ESMFile, string, error) {
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
	file, loadErr := LoadPath(path)
	os.Stderr = saved
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	out := <-done
	if err := r.Close(); err != nil {
		t.Fatal(err)
	}
	return file, out, loadErr
}

// warningCodes is the code of every `warning: <code>: ...` line of stderr, in
// order.
func warningCodes(stderr string) []string {
	codes := []string{}
	for _, line := range strings.Split(stderr, "\n") {
		rest, ok := strings.CutPrefix(line, "warning: ")
		if !ok {
			continue
		}
		if code, _, ok := strings.Cut(rest, ":"); ok {
			codes = append(codes, code)
		}
	}
	return codes
}

// normalizeJSON round-trips v through JSON so numbers compare as float64.
func normalizeJSON(t *testing.T, v any) any {
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

// TestInitializationMigrationReachesBindings: the migration rewrites the
// arguments an operator call binds, and leaves an `ic` node and a parameter
// alone (esm-spec §11.4.4).
func TestInitializationMigrationReachesBindings(t *testing.T) {
	view, err := decodeJSONView([]byte(`{"esm": "2.5.0", "models": {"M": {
		"variables": {"x": {"type": "unknown"}, "y": {"type": "unknown"}, "k": {"type": "parameter", "default": 1}},
		"equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": 0}],
		"initialization_equations": [{"lhs": "y", "rhs": {"op": "apply_operator", "name": "f", "args": [],
			"bindings": {"a": "x", "b": "k", "c": {"op": "ic", "args": ["x"]}}}}]}}}`))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := migrateInitializationEquations(view); err != nil {
		t.Fatal(err)
	}
	m := view["models"].(map[string]any)["M"].(map[string]any)
	if _, has := m["initialization_equations"]; has {
		t.Fatal("initialization_equations survives the migration")
	}
	want := map[string]any{
		"lhs": map[string]any{"op": "ic", "args": []any{"y"}},
		"rhs": map[string]any{"op": "apply_operator", "name": "f", "args": []any{}, "bindings": map[string]any{
			"a": map[string]any{"op": "ic", "args": []any{"x"}},
			"b": "k",
			"c": map[string]any{"op": "ic", "args": []any{"x"}},
		}},
	}
	got := m["equations"].([]any)[1]
	if !reflect.DeepEqual(normalizeJSON(t, got), normalizeJSON(t, want)) {
		t.Errorf("migrated equation\n got %v\nwant %v", got, want)
	}
}

// TestCanonicalFormMigratesInitializationEquations: the canonical form (and so
// every printer) carries no `initialization_equations` (esm-spec §9.6.6).
func TestCanonicalFormMigratesInitializationEquations(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join(conformanceRepoRoot(t), "tests", "conformance", "ic_system",
		"fixtures", "migration_steady_state.esm"))
	if err != nil {
		t.Fatal(err)
	}
	doc, err := decodeJSONView(raw)
	if err != nil {
		t.Fatal(err)
	}
	out, err := json.Marshal(CanonicalizeDocument(doc))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(out), "initialization_equations") {
		t.Error("the canonical form carries initialization_equations")
	}
	if strings.Contains(PrintMarkdown(doc), ":::initialization") {
		t.Error("the Markdown printer prints an initialization container")
	}
}
