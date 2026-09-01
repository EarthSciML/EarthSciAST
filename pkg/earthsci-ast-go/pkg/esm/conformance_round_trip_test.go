package esm

// Conformance harness adapter — round-trip category (Go binding).
//
// The oracle is the AUTHORED FIXTURE. The shared harness used to compare emit
// pass 2 against emit pass 3, with F itself never a participant — the
// self-comparing shape described in tests/conformance/README.md, blind to any
// field lost on the FIRST load because the second emit forgets exactly what the
// first forgot. esm-spec 9.6.4 rule 5 now states BOTH halves normatively
// ("Load preservation" and "Idempotence") and neither implies the other, so
// both are asserted here.
//
// This is the CROSS-BINDING adapter, driven by the shared manifest at
// tests/conformance/round_trip/manifest.json. It is distinct from
// round_trip_fidelity_test.go, which sweeps tests/valid/** with Go-local
// exclusions; this one runs the shared list every binding runs, including the
// tiers outside tests/valid that the local sweep never reaches.
//
// See tests/conformance/README.md for the contract: the five normalizations,
// the two exemption ledgers (load_transforms for spec-mandated rewrites,
// known_divergences for the defect ratchet), and the preserved_keys field-loss
// check that runs on EVERY fixture, excused or not.

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

const conformanceBinding = "go"

type conformanceManifest struct {
	Category         string   `json:"category"`
	PreservedKeys    []string `json:"preserved_keys"`
	KnownDivergences []struct {
		ID            string   `json:"id"`
		Fixtures      []string `json:"fixtures"`
		Nonconformant []string `json:"nonconformant"`
	} `json:"known_divergences"`
	Fixtures []struct {
		ID             string            `json:"id"`
		Path           string            `json:"path"`
		LoadTransforms []json.RawMessage `json:"load_transforms"`
	} `json:"fixtures"`
}

// conformanceNormalize is applied to BOTH sides, so no relaxation can hide a
// drop. It implements the five normalizations in tests/conformance/README.md
// (admissions 1 and 2 of esm-spec 9.6.4 rule 5).
func conformanceNormalize(v any, parent string) any {
	switch t := v.(type) {
	case map[string]any:
		out := map[string]any{}
		for k, x := range t {
			y := conformanceNormalize(x, k)
			if m, ok := y.(map[string]any); ok && len(m) == 0 {
				continue
			}
			if a, ok := y.([]any); ok && len(a) == 0 {
				continue
			}
			if k == "expect_cadence" {
				continue
			}
			if k == "independent_variable" && parent == "domain" && y == "t" {
				continue
			}
			if k == "initial_offset" {
				if n, ok := y.(json.Number); ok {
					if f, err := n.Float64(); err == nil && f == 0 {
						continue
					}
				}
			}
			out[k] = y
		}
		return out
	case []any:
		out := make([]any, 0, len(t))
		for _, x := range t {
			out = append(out, conformanceNormalize(x, parent))
		}
		return out
	}
	return v
}

// conformanceDroppedKeys records (wireKey, jsonPath) for every mapping key in
// orig absent from emitted.
func conformanceDroppedKeys(orig, emitted any, path string, out *[][2]string) {
	switch o := orig.(type) {
	case map[string]any:
		e, ok := emitted.(map[string]any)
		if !ok {
			return
		}
		for _, k := range diffSortedKeys(o) {
			here := path + "." + k
			if ev, present := e[k]; present {
				conformanceDroppedKeys(o[k], ev, here, out)
			} else {
				*out = append(*out, [2]string{k, here})
			}
		}
	case []any:
		e, ok := emitted.([]any)
		if !ok {
			return
		}
		n := len(o)
		if len(e) < n {
			n = len(e)
		}
		for i := 0; i < n; i++ {
			conformanceDroppedKeys(o[i], e[i], fmt.Sprintf("%s[%d]", path, i), out)
		}
	}
}

func conformanceRepoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	return root
}

// TestConformanceRoundTripManifest is the shared cross-binding gate.
func TestConformanceRoundTripManifest(t *testing.T) {
	root := conformanceRepoRoot(t)
	testsDir := filepath.Join(root, "tests")
	manifestPath := filepath.Join(testsDir, "conformance", "round_trip", "manifest.json")

	raw, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatalf("conformance manifest not found at %s: %v", manifestPath, err)
	}
	var man conformanceManifest
	if err := json.Unmarshal(raw, &man); err != nil {
		t.Fatalf("manifest is not JSON: %v", err)
	}
	if man.Category != "round_trip" {
		t.Fatalf("manifest category = %q, want round_trip", man.Category)
	}
	if len(man.Fixtures) == 0 {
		t.Fatal("manifest lists no fixtures")
	}

	preserved := map[string]bool{}
	for _, k := range man.PreservedKeys {
		preserved[k] = true
	}

	// Fixture id -> the divergence entry naming THIS binding non-conformant. A
	// binding listed conformant, or in neither column, stays held to full
	// equality: that is what makes the ledger a ratchet rather than a licence.
	excused := map[string]string{}
	for _, d := range man.KnownDivergences {
		for _, b := range d.Nonconformant {
			if b != conformanceBinding {
				continue
			}
			for _, f := range d.Fixtures {
				excused[f] = d.ID
			}
		}
	}

	var stale []string

	for _, fixture := range man.Fixtures {
		fixture := fixture
		t.Run(fixture.ID, func(t *testing.T) {
			path := filepath.Join(testsDir, fixture.Path)
			authoredText, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read fixture: %v", err)
			}
			// LoadPath, not LoadString: relative `ref` and template-library
			// paths resolve against the fixture's own directory.
			file, err := LoadPath(path)
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			firstJSON, err := file.ToJSON()
			if err != nil {
				t.Fatalf("save: %v", err)
			}

			authored := conformanceNormalize(decodeJSONNumbers(t, "authored", authoredText), "")
			emitted := conformanceNormalize(decodeJSONNumbers(t, "emitted", firstJSON), "")

			divergence, hasDivergence := excused[fixture.ID]
			isExcused := len(fixture.LoadTransforms) > 0 || hasDivergence

			var diffs []string
			jsonDiff("", authored, emitted, &diffs)

			// 1. LOAD PRESERVATION (esm-spec 9.6.4 rule 5).
			if !isExcused {
				if len(diffs) > 0 {
					t.Errorf("save(load(F)) differs from F in %d place(s) — either a field "+
						"is being dropped/invented, or a spec-REQUIRED load-time transform "+
						"needs a `load_transforms` entry citing its clause. Do NOT add one "+
						"to silence a drop.\n  %s", len(diffs), strings.Join(diffs, "\n  "))
				}
			} else if len(diffs) == 0 {
				// Improving, not failing: README adapter contract item 8.
				stale = append(stale, fixture.ID)
			}

			// 2. FIELD LOSS — runs on EVERY fixture, excused or not. A load-time
			//    transform rewrites a CONSTRUCT; it does not licence dropping the
			//    document around it.
			var dropped [][2]string
			conformanceDroppedKeys(authored, emitted, "", &dropped)
			var lost []string
			for _, d := range dropped {
				if preserved[d[0]] {
					lost = append(lost, d[1])
				}
			}
			if len(lost) > 0 {
				sort.Strings(lost)
				t.Errorf("dropped preserved field(s) at %v", lost)
			}

			// 3. IDEMPOTENCE (esm-spec 9.6.4 rule 5) — still required, no longer
			//    alone. A ledger-excused fixture whose emit is not RE-LOADABLE (a
			//    drop that removed a schema-required field) is recorded as a known
			//    failure naming the ledger entry — never a silent pass.
			reloaded, err := LoadString(string(firstJSON))
			if err != nil {
				if hasDivergence {
					t.Logf("KNOWN FAILURE: emit is not re-loadable (%v); "+
						"known_divergence %q", err, divergence)
					return
				}
				t.Fatalf("emit is not re-loadable: %v", err)
			}
			secondJSON, err := reloaded.ToJSON()
			if err != nil {
				t.Fatalf("second save: %v", err)
			}
			var a, b any
			_ = json.Unmarshal(firstJSON, &a)
			_ = json.Unmarshal(secondJSON, &b)
			var idem []string
			jsonDiff("", a, b, &idem)
			if len(idem) > 0 {
				t.Errorf("emit is not a fixed point:\n  %s", strings.Join(idem, "\n  "))
			}
		})
	}

	if len(stale) > 0 {
		t.Logf("note: excused fixtures that now round-trip cleanly in %s "+
			"(ledger entry may be stale — trim by hand; NOT a failure): %v",
			conformanceBinding, stale)
	}
}
