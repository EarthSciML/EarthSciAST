package esm

import (
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// validate_observed_cycle_test.go pins esm-spec §4.9.6 in Go (issue #181): a
// dependency cycle among a model's observed definitions is a HARD structural
// error at `/models/<M>`, its message NAMES the observeds on the cycle, and the
// §4.3.1.1 recurrence self-edge — and ONLY that self-edge — is exempt.
//
// The negative half matters as much as the positive one. The exemption is gated
// on recurrence CANDIDACY, so the three neighbouring shapes that are NOT
// candidates (a two-variable cycle, a bare array self-mention, a scalar
// self-mention) must still be reported. Those are exactly the cases
// TestCadenceStillReportsNonRecurrenceCycles pins for the cadence-pass
// counterpart; the two checks walk the same graph with the same gate and must
// agree.

// observedCycleErrors runs the FULL structural scan over a document and returns
// only the §4.9.6 findings, so an assertion cannot be satisfied by some other
// validator's error.
func observedCycleErrors(t *testing.T, file *ESMFile) []StructuralError {
	t.Helper()
	var out []StructuralError
	for _, e := range Validate(file).StructuralErrors {
		if e.Code == codeObservedCycle {
			out = append(out, e)
		}
	}
	return out
}

// --- (1) the shared cross-binding fixture ------------------------------------

// TestObservedCycleFixtureRejected pins the shared
// tests/invalid/observed_cycle_array_elementwise.esm: three ARRAY observeds over
// one index set reading each other ELEMENTWISE close the cycle
// `gamfac -> hpbl -> wscale -> gamfac`.
//
// The last assertion is the whole point of issue #181. `in_pbl` is a fourth
// observed — declared, defined and referenced perfectly well — that merely reads
// `hpbl`. It is the name a binding reports when it lets the cycle through to the
// build and then trips over whichever observed its materialization walk reached
// first (Rust's `E_TREEWALK_UNBOUND_NAME: 'in_pbl'`). A cycle report naming the
// innocent bystander is the defect this diagnostic exists to replace, so
// `in_pbl` must appear neither in `details.cycle` nor in the message.
func TestObservedCycleFixtureRejected(t *testing.T) {
	file, _ := loadInvalidFixture(t, "observed_cycle_array_elementwise.esm")
	result := Validate(file)

	// The fixture is pinned schema-valid ("schema_errors": []): nothing in JSON
	// Schema can see a cycle, which is why this is a structural finding.
	if len(result.SchemaErrors) != 0 {
		t.Fatalf("fixture is pinned schema-valid, got: %+v", result.SchemaErrors)
	}
	if result.IsValid {
		t.Fatal("fixture is pinned is_valid:false; Go accepted it")
	}
	if !hasStructuralError(result, codeObservedCycle, "/models/YSU") {
		t.Fatalf("want a hard %s @ /models/YSU, got %+v", codeObservedCycle, result.StructuralErrors)
	}

	found := observedCycleErrors(t, file)
	if len(found) != 1 {
		t.Fatalf("§4.9.6 reports ONE cycle per model, got %d: %+v", len(found), found)
	}
	err := found[0]

	for _, name := range []string{"gamfac", "hpbl", "wscale"} {
		if !strings.Contains(err.Message, name) {
			t.Errorf("message must NAME the observeds on the cycle; %q omits %q", err.Message, name)
		}
	}
	if strings.Contains(err.Message, "in_pbl") {
		t.Errorf("`in_pbl` is on NO cycle and must not be named; got %q", err.Message)
	}

	cycle, ok := err.Details["cycle"].([]string)
	if !ok {
		t.Fatalf("details.cycle must be the path slice, got %T (%v)", err.Details["cycle"], err.Details["cycle"])
	}
	// Traversal order with the entry node repeated to close it. Roots are visited
	// in sorted name order, so `gamfac` is entered first and the path is pinned
	// exactly — a randomized map iteration would make this flake.
	want := []string{"gamfac", "hpbl", "wscale", "gamfac"}
	if !reflect.DeepEqual(cycle, want) {
		t.Errorf("details.cycle = %v; want %v", cycle, want)
	}
	for _, n := range cycle {
		if n == "in_pbl" {
			t.Errorf("`in_pbl` must not appear on the reported cycle: %v", cycle)
		}
	}
}

// TestObservedCycleIsDeterministic re-validates the fixture and demands the SAME
// cycle every time. Go's map iteration is randomized, so a traversal that did
// not sort its roots and successors would name a different cycle from run to run
// on any document carrying more than one — which esm-spec §4.9.6 forbids
// ("sorted roots, sorted successors").
func TestObservedCycleIsDeterministic(t *testing.T) {
	file, _ := loadInvalidFixture(t, "observed_cycle_array_elementwise.esm")
	first := observedCycleErrors(t, file)[0].Details["cycle"]
	for i := 0; i < 25; i++ {
		got := observedCycleErrors(t, file)[0].Details["cycle"]
		if !reflect.DeepEqual(got, first) {
			t.Fatalf("run %d named %v, first run named %v", i, got, first)
		}
	}
}

// --- (2)(3) the non-candidate shapes that ARE cycles -------------------------

// TestObservedCycleNonRecurrenceShapes pins the three shapes the recurrence
// exemption must NOT swallow. Each is a genuine §4.9.6 cycle: none reads itself
// through `index`, so none is a §4.3.1.1 candidate and none has an axis to fold
// along. These mirror TestCadenceStillReportsNonRecurrenceCycles case for case.
func TestObservedCycleNonRecurrenceShapes(t *testing.T) {
	steps := 4
	cases := map[string]struct {
		vars      map[string]ModelVariable
		eqs       []Equation
		wantCycle []string
	}{
		// Two SCALAR observeds defining each other.
		"two-variable scalar cycle": {
			vars: map[string]ModelVariable{
				"a": {Type: VarTypeUnknown, Units: strPtr("1")},
				"b": {Type: VarTypeUnknown, Units: strPtr("1")},
			},
			eqs: []Equation{
				{LHS: "a", RHS: ExprNode{Op: "+", Args: []any{"b", 1.0}}},
				{LHS: "b", RHS: ExprNode{Op: "+", Args: []any{"a", 1.0}}},
			},
			wantCycle: []string{"a", "b", "a"},
		},
		// A SCALAR self-reference: no shape, so no axis to fold along and never a
		// recurrence candidate however it is spelled. A cycle of length one.
		"scalar self-reference": {
			vars: map[string]ModelVariable{
				"x": {Type: VarTypeUnknown, Units: strPtr("1")},
			},
			eqs:       []Equation{{LHS: "x", RHS: ExprNode{Op: "+", Args: []any{"x", 1.0}}}},
			wantCycle: []string{"x", "x"},
		},
		// An ARRAY self-mention read BARE — the whole array, not `index(s, …)` —
		// so there is no self-read to sweep and it is not a candidate either.
		"bare array self-mention": {
			vars: map[string]ModelVariable{
				"s": {Type: VarTypeUnknown, Units: strPtr("1"), Shape: dims("steps")},
			},
			eqs:       []Equation{{LHS: "s", RHS: ExprNode{Op: "+", Args: []any{"s", 1.0}}}},
			wantCycle: []string{"s", "s"},
		},
		// A cycle THROUGH a recurrence candidate. `r` is exempt from its own
		// self-edge, but `r -> z -> r` runs through a second variable and is an
		// ordering between two things, not within one.
		"cycle through a recurrence candidate": {
			vars: map[string]ModelVariable{
				"r": {Type: VarTypeUnknown, Units: strPtr("1"), Shape: dims("steps")},
				"z": {Type: VarTypeUnknown, Units: strPtr("1"), Shape: dims("steps")},
			},
			eqs: []Equation{
				{LHS: "r", RHS: ExprNode{Op: "+", Args: []any{
					stepsAggregate(selfReadOf("r", ExprNode{Op: "-", Args: []any{"k", int64(1)}})),
					"z",
				}}},
				{LHS: "z", RHS: "r"},
			},
			wantCycle: []string{"r", "z", "r"},
		},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			file := recurrenceTestFileWithSets(
				map[string]IndexSet{"steps": {Kind: "interval", Size: &steps}},
				tc.vars, tc.eqs,
			)
			found := observedCycleErrors(t, file)
			if len(found) != 1 {
				t.Fatalf("want one %s, got %d: %+v", codeObservedCycle, len(found), found)
			}
			if found[0].Path != "/models/M" {
				t.Errorf("path = %q; want /models/M (a cycle belongs to no single equation)", found[0].Path)
			}
			if found[0].Level != "" {
				t.Errorf("level = %q; §4.9.6 is a HARD error, not a warning", found[0].Level)
			}
			if got := found[0].Details["cycle"]; !reflect.DeepEqual(got, tc.wantCycle) {
				t.Errorf("details.cycle = %v; want %v", got, tc.wantCycle)
			}
		})
	}
}

// --- (4) the legal recurrence still validates clean ---------------------------

// TestObservedCycleAdmitsRecurrences pins the exemption from the other side: the
// shared tests/valid/recurrence_causal_self_reference.esm, and the in-memory
// recurrence spellings, must raise NO §4.9.6 finding. Rejecting a legal document
// is the same category of failure as admitting an illegal one
// (CONFORMANCE_SPEC §5.19.5).
func TestObservedCycleAdmitsRecurrences(t *testing.T) {
	t.Run("tests/valid/recurrence_causal_self_reference.esm", func(t *testing.T) {
		path := filepath.Join(repoTestsDir(t), "valid", "recurrence_causal_self_reference.esm")
		file, err := LoadPath(path)
		if err != nil {
			t.Fatalf("load: %v", err)
		}
		result := Validate(file)
		if !result.IsValid {
			t.Fatalf("a VALID fixture was rejected: %+v", result.StructuralErrors)
		}
		for _, e := range result.StructuralErrors {
			if e.Code == codeObservedCycle {
				t.Errorf("a legal recurrence must not be a §4.9.6 cycle: %+v", e)
			}
		}
	})

	// The canonical spelling: `s[k] ~ 2 * s[k-1]`, guarded at the base case.
	t.Run("well-founded self-read", func(t *testing.T) {
		file := recurrenceTestFile(4, stepsAggregate(guarded(
			ExprNode{Op: "*", Args: []any{2.0, selfRead(ExprNode{Op: "-", Args: []any{"k", int64(1)}})}},
		)))
		if found := observedCycleErrors(t, file); len(found) != 0 {
			t.Errorf("well-founded recurrence reported as a cycle: %+v", found)
		}
	})

	// THE GATE, stated as a test. This self-read is ILL FOUNDED — `s[k+1]` reads
	// a cell the sweep has not written — so it is a candidate whose VERDICT is
	// "not well founded". The exemption is gated on CANDIDACY, so its self-edge
	// is still dropped and `recurrence_not_wellfounded` gets to be the diagnosis.
	// Gating on the verdict instead would fire §4.9.6 here and bury the named
	// diagnosis this construct exists to provide (esm-spec §4.3.1.1,
	// CONFORMANCE_SPEC §5.19.5).
	t.Run("ill-founded self-read keeps its own diagnosis", func(t *testing.T) {
		file := recurrenceTestFile(4, stepsAggregate(guarded(
			ExprNode{Op: "*", Args: []any{2.0, selfRead(ExprNode{Op: "+", Args: []any{"k", int64(1)}})}},
		)))
		if found := observedCycleErrors(t, file); len(found) != 0 {
			t.Errorf("the exemption is gated on CANDIDACY, not on the verdict; got %+v", found)
		}
		var codes []string
		for _, e := range Validate(file).StructuralErrors {
			codes = append(codes, e.Code)
		}
		if !containsString(codes, codeRecurrenceNotWellfounded) {
			t.Errorf("want %s to survive, got codes %v", codeRecurrenceNotWellfounded, codes)
		}
	})
}

// --- the graph's own edge rules ----------------------------------------------

// TestObservedCycleEdgeRules pins the two ways an edge must NOT be drawn: to a
// name that is not an observed of this model, and to a binder-introduced symbol
// that merely SHARES an observed's spelling.
func TestObservedCycleEdgeRules(t *testing.T) {
	steps := 4

	// A chain, not a cycle: `c -> b -> a`, plus a parameter leaf. Nothing closes.
	t.Run("acyclic chain", func(t *testing.T) {
		file := recurrenceTestFileWithSets(nil,
			map[string]ModelVariable{
				"p": {Type: VarTypeParameter, Units: strPtr("1"), Default: 1.0},
				"a": {Type: VarTypeUnknown, Units: strPtr("1")},
				"b": {Type: VarTypeUnknown, Units: strPtr("1")},
				"c": {Type: VarTypeUnknown, Units: strPtr("1")},
			},
			[]Equation{
				{LHS: "a", RHS: ExprNode{Op: "+", Args: []any{"p", 1.0}}},
				{LHS: "b", RHS: ExprNode{Op: "*", Args: []any{"a", 2.0}}},
				{LHS: "c", RHS: ExprNode{Op: "*", Args: []any{"b", "a"}}},
			},
		)
		if found := observedCycleErrors(t, file); len(found) != 0 {
			t.Errorf("an acyclic definition chain must raise nothing, got %+v", found)
		}
	})

	// A binder symbol spelled like an observed. `i` here is an aggregate range
	// key, not a reference to the scalar observed `i`, so `q -> i` is not an edge
	// and there is no cycle to report.
	t.Run("binder symbol shadowing an observed name", func(t *testing.T) {
		file := recurrenceTestFileWithSets(
			map[string]IndexSet{"steps": {Kind: "interval", Size: &steps}},
			map[string]ModelVariable{
				"q": {Type: VarTypeUnknown, Units: strPtr("1"), Shape: dims("steps")},
				"i": {Type: VarTypeUnknown, Units: strPtr("1")},
			},
			[]Equation{
				{LHS: "q", RHS: ExprNode{
					Op:        opAggregate,
					Args:      []any{},
					OutputIdx: []any{"i"},
					Ranges:    map[string]any{"i": map[string]any{"from": "steps"}},
					Expr:      ExprNode{Op: "*", Args: []any{"i", 2.0}},
				}},
				{LHS: "i", RHS: ExprNode{Op: "*", Args: []any{"q", 0.0}}},
			},
		)
		if found := observedCycleErrors(t, file); len(found) != 0 {
			t.Errorf("a bound index symbol must not manufacture an edge, got %+v", found)
		}
	})
}

// containsString is `slices.Contains` spelled locally, matching this package's
// existing test helpers rather than adding an import for one call.
func containsString(haystack []string, needle string) bool {
	for _, s := range haystack {
		if s == needle {
			return true
		}
	}
	return false
}
