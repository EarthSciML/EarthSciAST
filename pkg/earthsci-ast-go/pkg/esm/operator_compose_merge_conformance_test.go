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

// operator_compose_merge_conformance_test.go drives the SHARED manifest at
// tests/conformance/operator_compose_merge/ (esm-libraries-spec §4.7.1 steps 3
// and 5; EarthSciML/EarthSciAST#195).
//
// Three things are pinned, and they are distinct:
//
//  1. An entry that merges NOTHING is operator_compose_no_merge, a hard refusal:
//     such an entry is indistinguishable from one that is not there. A PARTIAL
//     merge stays a warning, because an operator may legitimately contribute
//     states of its own alongside the ones it does merge.
//  2. RequireMatch is TRI-STATE and nil is not false -- nil means "the author has
//     not said" (zero-merge refuses), true makes ANY shortfall fatal, false
//     DECLARES a standalone-contributing operator and silences both. Each state
//     has a non-vacuity anchor, so a binding cannot pass by being uniformly
//     strict or uniformly lax.
//  3. A bare-name match that would unify two STATES is
//     operator_compose_ambiguous_bare_name, a refusal: each carries its own
//     initial condition and the merge keeps one, which is exactly the silent
//     choice that made the `systems` order matter. Where only one side is a state
//     the match is unambiguous and the state owns the quantity.
//
// Like override_key_diagnostics this category carries no golden: it compares
// DIAGNOSTIC OUTCOMES, so this binding asserts its own idiomatic surface -- the
// couplingWarnf hook and the three error types.

type ocMergeCase struct {
	ID               string   `json:"id"`
	Path             string   `json:"path"`
	Outcome          string   `json:"outcome"`
	Code             string   `json:"code"`
	RequireMatch     any      `json:"require_match"`
	Merged           int      `json:"merged"`
	Authored         int      `json:"authored"`
	Unmatched        []string `json:"unmatched"`
	Unified          []string `json:"unified"`
	StateVariables   []string `json:"state_variables"`
	Systems          []string `json:"systems"`
	SurvivingState   string   `json:"surviving_state"`
	SurvivingDefault *float64 `json:"surviving_default"`
}

type ocMergeManifest struct {
	BindingsRequired  []string          `json:"bindings_required"`
	Codes             map[string]string `json:"codes"`
	DiagnosticSurface struct {
		Errors map[string]map[string]string `json:"errors"`
	} `json:"diagnostic_surface"`
	Cases []ocMergeCase `json:"cases"`
}

// ocMergeErrorForCode is the refusal each code maps to in THIS binding --
// asserted against the manifest's Go column rather than assumed.
var ocMergeErrorForCode = map[string]error{
	CodeOperatorComposeNoMerge:               &OperatorComposeNoMergeError{},
	CodeOperatorComposeRequireMatchUnmatched: &OperatorComposeRequireMatchError{},
	CodeOperatorComposeAmbiguousBareName:     &OperatorComposeAmbiguousBareNameError{},
}

func loadOCMergeManifest(t *testing.T) (ocMergeManifest, string) {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	dir := filepath.Join(repoRoot, "tests", "conformance", "operator_compose_merge")
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

func TestOperatorComposeMergeManifestCoversThisBinding(t *testing.T) {
	manifest, _ := loadOCMergeManifest(t)
	if manifest.Codes[CodeOperatorComposePartialMerge] != "warning" {
		t.Errorf("partial merge must be a warning, manifest says %q",
			manifest.Codes[CodeOperatorComposePartialMerge])
	}
	for code, proto := range ocMergeErrorForCode {
		if manifest.Codes[code] != "error" {
			t.Errorf("%s must be an error, manifest says %q", code, manifest.Codes[code])
		}
		// The manifest names an error type per binding per code; reading Go's
		// column back keeps the record from drifting away from the code.
		want := "*esm." + reflect.TypeOf(proto).Elem().Name()
		if got := manifest.DiagnosticSurface.Errors[code]["go"]; got != want {
			t.Errorf("%s: manifest records Go type %q, want %q", code, got, want)
		}
	}
}

func TestOperatorComposeMergeManifestOutcomes(t *testing.T) {
	manifest, dir := loadOCMergeManifest(t)
	for _, tc := range manifest.Cases {
		t.Run(tc.ID, func(t *testing.T) {
			flat, warns, err := flattenCapturingWarnings(t, filepath.Join(dir, tc.Path))

			switch tc.Outcome {
			case "refused":
				proto, ok := ocMergeErrorForCode[tc.Code]
				if !ok {
					t.Fatalf("manifest names an unknown code %q", tc.Code)
				}
				if err == nil {
					t.Fatalf("expected %T, got a clean flatten", proto)
				}
				// The CONCRETE type is the contract, not merely "some error":
				// the three refusals have three different fixes, so a binding
				// that collapsed them would still let a caller route wrong.
				if reflect.TypeOf(err) != reflect.TypeOf(proto) {
					t.Fatalf("expected %T, got %T: %v", proto, err, err)
				}
				coded, ok := err.(interface{ DiagnosticCode() string })
				if !ok {
					t.Fatalf("%T carries no DiagnosticCode", err)
				}
				if coded.DiagnosticCode() != tc.Code {
					t.Errorf("code = %q, want %q", coded.DiagnosticCode(), tc.Code)
				}
				for _, name := range append(append([]string{}, tc.Unmatched...), tc.Unified...) {
					if !strings.Contains(err.Error(), name) {
						t.Errorf("the refusal must NAME %q; got %q", name, err.Error())
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
				tally := fmt.Sprintf("merged %d of %d equations", tc.Merged, tc.Authored)
				if !strings.Contains(warns[0], tally) {
					t.Errorf("missing tally %q in %q", tally, warns[0])
				}
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
			if tc.SurvivingState != "" {
				v, ok := flat.Lookup(tc.SurvivingState)
				if !ok {
					t.Fatalf("surviving state %q is absent", tc.SurvivingState)
				}
				def, ok := toFloat64(v.Default)
				if !ok || def != *tc.SurvivingDefault {
					t.Errorf("surviving default = %v, want %v", v.Default, *tc.SurvivingDefault)
				}
			}
		})
	}
}

// TestOperatorComposeRequireMatchTruthTableIsCovered checks that every cell of
// the tri-state table the manifest records has a case. The table is the whole of
// require_match's meaning, and its three states are three different things an
// author can mean; a column with no case is a column a binding could get wrong
// without failing anything.
func TestOperatorComposeRequireMatchTruthTableIsCovered(t *testing.T) {
	manifest, _ := loadOCMergeManifest(t)
	covered := map[string]bool{}
	for _, c := range manifest.Cases {
		covered[fmt.Sprintf("%v|%s", c.RequireMatch, c.Outcome)] = true
	}
	for _, want := range []string{
		"absent|refused", "absent|warning", "absent|clean",
		"true|refused", "true|clean",
		"false|clean",
	} {
		if !covered[want] {
			t.Errorf("the require_match truth table has no case for %q", want)
		}
	}
	if covered["false|refused"] {
		t.Error("`require_match: false` declares that unmatched equations are expected; " +
			"nothing under it may refuse")
	}
}

// TestOperatorComposeFlippingSystemsChangesNothingObservable is issue #195's
// Symptom 1 in the form that fails under the old rule: two PAIRS of fixtures,
// each differing ONLY in the `systems` array's order, must agree. The tendency is
// arithmetically identical either way, so the surviving name and default (or the
// refusal) are the entire observable difference -- compared between the two RUNS
// rather than against the manifest, so this fails on disagreement even if both
// were re-recorded.
func TestOperatorComposeFlippingSystemsChangesNothingObservable(t *testing.T) {
	manifest, dir := loadOCMergeManifest(t)
	byID := map[string]ocMergeCase{}
	for _, c := range manifest.Cases {
		byID[c.ID] = c
	}

	outcome := func(id string) string {
		t.Helper()
		tc, ok := byID[id]
		if !ok {
			t.Fatalf("manifest has no case %q", id)
		}
		flat, _, err := flattenCapturingWarnings(t, filepath.Join(dir, tc.Path))
		if err != nil {
			return fmt.Sprintf("%T", err)
		}
		parts := make([]string, 0, len(flat.StateVariables))
		for _, v := range flat.StateVariables {
			parts = append(parts, fmt.Sprintf("%s=%v", v.Name, v.Default))
		}
		return strings.Join(parts, ",")
	}

	for _, pair := range [][2]string{
		{"ambiguous_bare_name", "ambiguous_bare_name_flipped"},
		{"owner_rename_state_wins_observed_first", "owner_rename_state_wins_state_first"},
	} {
		a, b := byID[pair[0]], byID[pair[1]]
		if len(a.Systems) != 2 || a.Systems[0] != b.Systems[1] || a.Systems[1] != b.Systems[0] {
			t.Fatalf("%s/%s must differ ONLY in `systems` order", pair[0], pair[1])
		}
		if got, want := outcome(pair[0]), outcome(pair[1]); got != want {
			t.Errorf("flipping `systems` changed the outcome: %s gave %q, %s gave %q",
				pair[0], got, pair[1], want)
		}
	}
}

// TestOperatorComposeAmbiguityIsNotABlanketBan pins the two ways out of an
// ambiguous bare-name match. Without it a binding could pass every refusal by
// refusing the whole bare-name fallback.
func TestOperatorComposeAmbiguityIsNotABlanketBan(t *testing.T) {
	_, dir := loadOCMergeManifest(t)
	for _, tc := range []struct {
		fixture string
		state   string
		def     float64
	}{
		{"ambiguous_resolved_by_translate.esm", "Chem.O3", 30.0},
		{"owner_rename_state_wins_observed_first.esm", "Sink.O3", 40.0},
	} {
		flat, _, err := flattenCapturingWarnings(t, filepath.Join(dir, "fixtures", tc.fixture))
		if err != nil {
			t.Fatalf("%s: %v", tc.fixture, err)
		}
		if len(flat.StateVariables) != 1 || flat.StateVariables[0].Name != tc.state {
			t.Fatalf("%s: states = %v, want [%s]", tc.fixture, flat.StateVariables, tc.state)
		}
		if def, ok := toFloat64(flat.StateVariables[0].Default); !ok || def != tc.def {
			t.Errorf("%s: default = %v, want %v", tc.fixture, flat.StateVariables[0].Default, tc.def)
		}
	}
}

// TestOperatorComposeRequireMatchRoundTrips pins that `require_match` reaches the
// emitted document. The flag is TRI-STATE, so an explicit false must survive --
// dropping it as "the default" would silently re-arm the zero-merge refusal on
// every document that opted out -- and an ABSENT flag must stay absent, for the
// same reason in the other direction.
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
		t.Errorf("an explicit `true` did not survive the round trip: %v", got)
	}
	if got, present := emitted("no_merge_declared.esm")["require_match"]; !present || got != false {
		t.Errorf("an explicit `false` did not survive the round trip: %v (present=%v)", got, present)
	}
	if _, present := emitted("partial_merge.esm")["require_match"]; present {
		t.Error("an ABSENT flag must stay absent")
	}
}
