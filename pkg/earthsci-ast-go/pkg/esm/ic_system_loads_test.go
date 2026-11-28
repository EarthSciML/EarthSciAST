package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// TestIcSystemLoads runs the loader half of tests/conformance/ic_system
// (esm 2.5.0, esm-spec §11.4.4, §4.2): a deprecated `initialization_equations`
// block is read as `ic` equations or `guesses`, a malformed `ic` argument is
// refused at load, and `ic` anywhere is valid. Go does not simulate, so the
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
			EquationsTail  []any          `json:"equations_tail"`
			EquationsCount *int           `json:"equations_count"`
			Guesses        map[string]any `json:"guesses"`
			NoField        string         `json:"no_field"`
			LoadError      string         `json:"load_error"`
			ValidateErrors []string       `json:"validate_errors"`
		} `json:"loads"`
	}
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatal(err)
	}
	for _, l := range m.Loads {
		t.Run(l.ID, func(t *testing.T) {
			file, err := LoadPath(filepath.Join(dir, l.Fixture))
			if l.LoadError != "" {
				if err == nil {
					t.Fatalf("expected a load error carrying %q", l.LoadError)
				}
				if !strings.Contains(err.Error(), l.LoadError) {
					t.Fatalf("load error %q does not carry %q", err, l.LoadError)
				}
				return
			}
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			if l.ValidateErrors != nil {
				var unbalanced []string
				codes := map[string]bool{}
				for _, e := range Validate(file).StructuralErrors {
					codes[e.Code] = true
					if e.Code == "ic_system_unbalanced" {
						unbalanced = append(unbalanced, e.Code)
					}
				}
				want := 0
				for _, c := range l.ValidateErrors {
					if !codes[c] {
						t.Errorf("validate does not report %s", c)
					}
					if c == "ic_system_unbalanced" {
						want++
					}
				}
				if len(unbalanced) != want {
					t.Errorf("validate reports %d ic_system_unbalanced, want %d", len(unbalanced), want)
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
		})
	}
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
