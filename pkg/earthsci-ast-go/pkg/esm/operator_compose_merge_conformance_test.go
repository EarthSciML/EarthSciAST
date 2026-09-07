package esm

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// operator_compose_merge_conformance_test.go drives the SHARED manifest at
// tests/conformance/operator_compose_merge/ (esm-libraries-spec §4.7.1 steps 3
// and 5; EarthSciML/EarthSciAST#195).
//
// Three things are pinned, and they are distinct:
//
//  1. The merge TALLY is reported — operator_compose_no_merge when nothing
//     landed, operator_compose_partial_merge when only some did, both naming the
//     unmatched dependent variables. Step 5 still preserves the equations; it is
//     no longer SILENT about doing so, because silence made "merged everything"
//     and "merged nothing" the same observable outcome.
//  2. `require_match: true` promotes either to a hard refusal, and a PARTIAL
//     match refuses exactly as a zero match does. require_match_satisfied is the
//     non-vacuity anchor that keeps the flag from being simply always-fatal.
//  3. The BARE-NAME fallback's surviving spelling follows the state's OWNER (the
//     component declared first), not Systems[0] — so an entry means the same
//     thing in either argument order.
//
// Like override_key_diagnostics this category carries no golden: it compares
// DIAGNOSTIC OUTCOMES, so this binding asserts its own idiomatic surface — the
// couplingWarnf hook and *OperatorComposeRequireMatchError.

type ocMergeCase struct {
	ID               string   `json:"id"`
	Path             string   `json:"path"`
	Outcome          string   `json:"outcome"`
	Code             string   `json:"code"`
	Merged           int      `json:"merged"`
	Authored         int      `json:"authored"`
	Unmatched        []string `json:"unmatched"`
	StateVariables   []string `json:"state_variables"`
	ModelsDeclared   []string `json:"models_declared"`
	Systems          []string `json:"systems"`
	SurvivingState   string   `json:"surviving_state"`
	SurvivingDefault *float64 `json:"surviving_default"`
}

type ocMergeManifest struct {
	Category         string            `json:"category"`
	BindingsRequired []string          `json:"bindings_required"`
	Codes            map[string]string `json:"codes"`
	Cases            []ocMergeCase     `json:"cases"`
}

func ocMergeCategoryDir(t *testing.T) string {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	return filepath.Join(repoRoot, "tests", "conformance", "operator_compose_merge")
}

func loadOCMergeManifest(t *testing.T) (ocMergeManifest, string) {
	t.Helper()
	dir := ocMergeCategoryDir(t)
	raw, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		// A missing manifest is a hard failure, not a skip: the manifest IS the
		// contract this file exists to enforce.
		t.Fatalf("read manifest: %v", err)
	}
	var m ocMergeManifest
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	if len(m.Cases) == 0 {
		t.Fatal("the operator_compose_merge manifest recorded no cases; every " +
			"subtest below would be vacuously green")
	}
	found := false
	for _, b := range m.BindingsRequired {
		if b == "go" {
			found = true
		}
	}
	if !found {
		t.Fatal("go is not in bindings_required; if this category stops covering " +
			"Go, say so in scope_excluded rather than letting it drift")
	}
	return m, dir
}

// flattenCapturingWarnings runs Flatten with couplingWarnf redirected, so the
// test observes exactly what a caller would see on stderr.
func flattenCapturingWarnings(t *testing.T, path string) (*FlattenedSystem, []string, error) {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	file, err := LoadString(string(raw))
	if err != nil {
		t.Fatalf("load %s: %v", path, err)
	}

	var captured []string
	saved := couplingWarnf
	couplingWarnf = func(format string, args ...any) {
		captured = append(captured, fmt.Sprintf(format, args...))
	}
	defer func() { couplingWarnf = saved }()

	flat, ferr := Flatten(file)
	return flat, captured, ferr
}

func TestOperatorComposeMergeManifestOutcomes(t *testing.T) {
	manifest, dir := loadOCMergeManifest(t)
	for _, tc := range manifest.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			flat, warns, err := flattenCapturingWarnings(t, filepath.Join(dir, tc.Path))

			switch tc.Outcome {
			case "refused":
				var target *OperatorComposeRequireMatchError
				if !errors.As(err, &target) {
					t.Fatalf("expected *OperatorComposeRequireMatchError, got %v", err)
				}
				if target.DiagnosticCode() != tc.Code {
					t.Errorf("code = %q, want %q", target.DiagnosticCode(), tc.Code)
				}
				for _, name := range tc.Unmatched {
					if !strings.Contains(target.Message, name) {
						t.Errorf("the refusal must NAME %q; got %q", name, target.Message)
					}
				}
				return
			case "clean":
				if err != nil {
					t.Fatalf("expected a clean flatten, got %v", err)
				}
				if len(warns) != 0 {
					t.Errorf("expected no diagnostic, got %v", warns)
				}
			case "warning":
				if err != nil {
					t.Fatalf("expected a warning, not a refusal: %v", err)
				}
				if len(warns) != 1 {
					t.Fatalf("expected exactly one diagnostic, got %v", warns)
				}
				if !strings.HasPrefix(warns[0], tc.Code) {
					t.Errorf("expected %q, got %q", tc.Code, warns[0])
				}
				// The tally and the unmatched names are what make the
				// diagnostic actionable; a code with no names is a shrug.
				for _, name := range tc.Unmatched {
					if !strings.Contains(warns[0], name) {
						t.Errorf("the diagnostic must NAME %q; got %q", name, warns[0])
					}
				}
			default:
				t.Fatalf("unknown outcome %q", tc.Outcome)
			}

			if tc.StateVariables != nil {
				got := make([]string, 0, len(flat.StateVariables))
				for _, v := range flat.StateVariables {
					got = append(got, v.Name)
				}
				if strings.Join(got, ",") != strings.Join(tc.StateVariables, ",") {
					t.Errorf("state variables = %v, want %v", got, tc.StateVariables)
				}
			}
		})
	}
}

// TestOperatorComposeBareNameSurvivesUnderItsOwnersSpelling is issue #195's
// Symptom 1 in the form that fails under the old rule: two fixtures with
// identical models in identical declaration order, differing ONLY in the
// `systems` array's order, must agree on the surviving state and its initial
// condition. The tendency is arithmetically identical either way, so that name
// and that default are the entire observable difference — which is why they are
// compared between the two RUNS rather than only against the manifest's recorded
// values: this fails on disagreement even if both were re-recorded.
func TestOperatorComposeBareNameSurvivesUnderItsOwnersSpelling(t *testing.T) {
	manifest, dir := loadOCMergeManifest(t)
	byID := map[string]ocMergeCase{}
	for _, c := range manifest.Cases {
		byID[c.ID] = c
	}

	surviving := func(id string) (string, float64) {
		t.Helper()
		tc, ok := byID[id]
		if !ok {
			t.Fatalf("manifest has no case %q", id)
		}
		flat, _, err := flattenCapturingWarnings(t, filepath.Join(dir, tc.Path))
		if err != nil {
			t.Fatalf("%s: %v", id, err)
		}
		if len(flat.StateVariables) != 1 {
			t.Fatalf("%s: expected one surviving state, got %d", id, len(flat.StateVariables))
		}
		v := flat.StateVariables[0]
		// The INITIAL CONDITION is half of what used to change with argument
		// order, so a state that reached here without one is a failure, not a
		// case to skip.
		def, ok := toFloat64(v.Default)
		if !ok {
			t.Fatalf("%s: surviving state %q lost its default (%v)", id, v.Name, v.Default)
		}
		return v.Name, def
	}

	aName, aDefault := surviving("owner_rename_operator_first")
	bName, bDefault := surviving("owner_rename_mechanism_listed_first")
	if aName != bName || aDefault != bDefault {
		t.Errorf("flipping `systems` changed the surviving state: %s@%v vs %s@%v",
			aName, aDefault, bName, bDefault)
	}

	// The companion, and what keeps the above from being trivial: the same
	// `systems` order with the models declared the other way round must produce
	// the OTHER name. A binding that hard-coded either answer fails one of these.
	cName, cDefault := surviving("owner_rename_mechanism_declared_first")
	if cName == aName {
		t.Errorf("declaration order must decide the surviving spelling; both gave %s", cName)
	}
	if cName != "Chem.O3" || cDefault != 30.0 {
		t.Errorf("mechanism-declared-first surviving state = %s@%v, want Chem.O3@30", cName, cDefault)
	}
}

// TestOperatorComposeRequireMatchRoundTrips pins that `require_match` reaches the
// emitted document — a flag that silently vanished on save would make the
// refusal unreproducible from the file the author kept — and that the schema
// DEFAULT is not written out, which would put a key on every existing fixture
// and break load preservation.
func TestOperatorComposeRequireMatchRoundTrips(t *testing.T) {
	_, dir := loadOCMergeManifest(t)
	emitted := func(name string) map[string]any {
		t.Helper()
		raw, err := os.ReadFile(filepath.Join(dir, "fixtures", name))
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		file, err := LoadString(string(raw))
		if err != nil {
			t.Fatalf("load %s: %v", name, err)
		}
		out, err := ToJSON(file)
		if err != nil {
			t.Fatalf("serialize %s: %v", name, err)
		}
		var doc struct {
			Coupling []map[string]any `json:"coupling"`
		}
		if err := json.Unmarshal([]byte(out), &doc); err != nil {
			t.Fatalf("parse emitted %s: %v", name, err)
		}
		if len(doc.Coupling) == 0 {
			t.Fatalf("%s: emitted document has no coupling entries", name)
		}
		return doc.Coupling[0]
	}

	if got := emitted("require_match_unmatched.esm")["require_match"]; got != true {
		t.Errorf("require_match did not survive the round trip: %v", got)
	}
	if _, present := emitted("no_merge.esm")["require_match"]; present {
		t.Error("the `false` default must NOT be emitted")
	}
}
