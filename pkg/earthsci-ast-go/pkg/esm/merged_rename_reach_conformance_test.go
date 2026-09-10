package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
)

// merged_rename_reach_conformance_test.go drives the SHARED manifest at
// tests/conformance/merged_rename_reach/ (esm-libraries-spec §4.7.1 step 4 and
// §4.7.5 step 3 ordering; EarthSciML/EarthSciAST#230).
//
// An `operator_compose` renaming match folds `B.x` into `A.x`, deleting `B.x`
// and rewriting every equation off it. That rewrite reaches equation ASTs and
// nothing else, and `operator_compose` entries run BEFORE `couple` and
// `variable_map` -- so a later entry's From/To, plain scoped-reference STRINGS
// on the entry object, could still name a spelling that no longer exists. This
// pins that they RESOLVE to the survivor.
//
// Only the `flatten` surface binds here: the manifest excludes Go from the
// `override_keys` surface, because this binding has no simulator and so no
// override-key surface at all.

type reachCase struct {
	ID                    string            `json:"id"`
	Path                  string            `json:"path"`
	Surface               string            `json:"surface"`
	MergedVariableRenames map[string]string `json:"merged_variable_renames"`
	StateVariables        []string          `json:"state_variables"`
	TendencyOf            string            `json:"tendency_of"`
	TendencyReferences    []string          `json:"tendency_references"`
	NoEquationReferences  []string          `json:"no_equation_references"`
}

type reachSurface struct {
	Bindings      []string          `json:"bindings"`
	ScopeExcluded map[string]string `json:"scope_excluded"`
}

type reachManifest struct {
	Surfaces                   map[string]reachSurface `json:"surfaces"`
	MergedVariableRenamesField map[string]string       `json:"merged_variable_renames_field"`
	Cases                      []reachCase             `json:"cases"`
}

func loadReachManifest(t *testing.T) (reachManifest, string) {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolving repo root: %v", err)
	}
	dir := filepath.Join(repoRoot, "tests", "conformance", "merged_rename_reach")
	raw, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		// A missing manifest is a hard failure, not a skip -- the manifest IS
		// the contract this file exists to enforce.
		t.Fatalf("reading merged_rename_reach manifest: %v", err)
	}
	var m reachManifest
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("parsing merged_rename_reach manifest: %v", err)
	}
	return m, dir
}

func reachFlattenCases(m reachManifest) []reachCase {
	var out []reachCase
	for _, c := range m.Cases {
		if c.Surface == "flatten" {
			out = append(out, c)
		}
	}
	return out
}

func TestMergedRenameReachManifestNamesThisBinding(t *testing.T) {
	m, _ := loadReachManifest(t)
	cases := reachFlattenCases(m)
	if len(cases) == 0 {
		// Zero cases would make every subtest below vacuously green.
		t.Fatal("the merged_rename_reach manifest recorded no flatten cases")
	}
	if !slices.Contains(m.Surfaces["flatten"].Bindings, "go") {
		t.Error("the flatten surface must bind Go: the rewrite is a pure structural transform")
	}
	// Both RUNTIME halves are out of scope here: this binding has no simulator,
	// so it has neither an override-key surface nor a result object to read by
	// name. Asserting the exclusion is what keeps it from quietly becoming a gap.
	for _, surface := range []string{"override_keys", "output_selection"} {
		if slices.Contains(m.Surfaces[surface].Bindings, "go") {
			t.Errorf("Go has no simulator, so it cannot implement the %s surface", surface)
		}
		if m.Surfaces[surface].ScopeExcluded["go"] == "" {
			t.Errorf("the %s exclusion must record a REASON for Go", surface)
		}
	}
	if got := m.MergedVariableRenamesField["go"]; got != "FlattenMetadata.MergedVariableRenames" {
		t.Errorf("manifest names the Go rename-map field %q; the code calls it "+
			"FlattenMetadata.MergedVariableRenames", got)
	}
}

func TestMergedRenameReachFlattenCases(t *testing.T) {
	m, dir := loadReachManifest(t)
	for _, tc := range reachFlattenCases(m) {
		t.Run(tc.ID, func(t *testing.T) {
			file, err := LoadPath(filepath.Join(dir, tc.Path))
			if err != nil {
				t.Fatalf("loading %s: %v", tc.Path, err)
			}
			flat, err := Flatten(file)
			if err != nil {
				t.Fatalf("flattening %s: %v", tc.Path, err)
			}

			// (1) The merge RECORDS which names it deleted. That map is what a
			// consumer addressing a state by name resolves through, so it is
			// part of the flattened form's contract, not a private detail.
			got := flat.Metadata.MergedVariableRenames
			if got == nil {
				got = map[string]string{}
			}
			if !reflect.DeepEqual(got, tc.MergedVariableRenames) {
				t.Errorf("merged renames = %v, want %v", got, tc.MergedVariableRenames)
			}

			// (2) The merged-away name survives NOWHERE -- not in the variable
			// tables, not in any equation. A reference left behind is a
			// reference to nothing.
			var stateNames []string
			for _, v := range flat.StateVariables {
				stateNames = append(stateNames, v.Name)
			}
			if !reflect.DeepEqual(stateNames, tc.StateVariables) {
				t.Errorf("state variables = %v, want %v", stateNames, tc.StateVariables)
			}
			for _, gone := range tc.NoEquationReferences {
				for _, v := range flat.StateVariables {
					if v.Name == gone {
						t.Errorf("merged-away %q is still a state variable", gone)
					}
				}
				for _, v := range flat.Parameters {
					if v.Name == gone {
						t.Errorf("merged-away %q is still a parameter", gone)
					}
				}
				for _, eq := range flat.Equations {
					rendered := ToASCII(eq.LHS) + " = " + ToASCII(eq.RHS)
					if strings.Contains(rendered, gone) {
						t.Errorf("equation still references the merged-away %q: %s", gone, rendered)
					}
				}
			}

			// (3) The later entry LANDED, on the survivor. This is the
			// non-vacuity anchor for (2): dropping the entry's reference
			// outright would satisfy "the dead name survives nowhere" by doing
			// nothing at all.
			var rhs string
			found := false
			for _, eq := range flat.Equations {
				if lhsDependentVar(eq.LHS) == tc.TendencyOf {
					rhs = ToASCII(eq.RHS)
					found = true
					break
				}
			}
			if !found {
				t.Fatalf("no equation defines %s", tc.TendencyOf)
			}
			for _, name := range tc.TendencyReferences {
				if !strings.Contains(rhs, name) {
					t.Errorf("D(%s) must reference %q, got %s", tc.TendencyOf, name, rhs)
				}
			}
		})
	}
}
