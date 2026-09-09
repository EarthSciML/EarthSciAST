package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// tolerance_resolution_scope_test.go is Go's read of the SHARED
// `tolerance_resolution` conformance manifest (CONFORMANCE_SPEC §5.21,
// tests/conformance/tolerance_resolution/manifest.json).
//
// Go cannot run that category: the contract is esm-spec §6.6.4's resolution of
// the assertion / test / model `{abs?, rel?}` blocks into the one `(rel, abs)`
// pair the §6.6.3 predicate is evaluated with, and Go has no inline-test runner
// — it parses a `tolerance` block as data and never resolves one. The manifest
// says so in `scope_excluded`, and this test is what keeps that claim honest,
// exactly as assertion_nonfinite_scope_test.go does for §5.20.
//
// The hazard is specific, not hypothetical: the moment a binding grows a
// §6.6.4 resolver, it can implement the pre-#228 wholesale rule and diverge
// from the other three without anything going red, because a category nobody in
// that binding reads cannot object. So the excluded bindings assert their own
// exclusion: drop Go from `scope_excluded` (or add it to `bindings_required`)
// without giving Go a resolver and this goes red, instead of the category
// quietly covering one binding fewer than it claims.
func TestToleranceResolutionExcludesGoWithAReason(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	path := filepath.Join(repoRoot, "tests", "conformance", "tolerance_resolution", "manifest.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}

	var manifest struct {
		Category         string            `json:"category"`
		BindingsRequired []string          `json:"bindings_required"`
		ScopeExcluded    map[string]string `json:"scope_excluded"`
		Integrators      json.RawMessage   `json:"integrators"`
		Cases            []struct {
			ID     string `json:"id"`
			Levels struct {
				Model     map[string]*float64 `json:"model"`
				Test      map[string]*float64 `json:"test"`
				Assertion map[string]*float64 `json:"assertion"`
			} `json:"levels"`
			Resolved struct {
				Rel float64 `json:"rel"`
				Abs float64 `json:"abs"`
			} `json:"resolved"`
			ChangedBy228 bool `json:"changed_by_228"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}

	if manifest.Category != "tolerance_resolution" {
		t.Fatalf("category = %q, want tolerance_resolution", manifest.Category)
	}
	for _, b := range manifest.BindingsRequired {
		if b == "go" {
			t.Fatal("the manifest requires Go, but Go resolves no §6.6.4 tolerance; " +
				"either give Go an inline-test runner or keep it in scope_excluded")
		}
	}
	if reason, ok := manifest.ScopeExcluded["go"]; !ok || reason == "" {
		t.Fatal("the manifest must say, in scope_excluded, WHY Go does not run this category")
	}

	// Data-only by design (CONFORMANCE_SPEC §5.21.2): resolution is a pure
	// function of the declared blocks, so pinning an integrator here would be a
	// category error. Go can check that without running anything.
	if s := string(manifest.Integrators); s != "null" {
		t.Fatalf("integrators = %s, want null for a data-only category", s)
	}

	// Non-vacuity, checkable without a resolver. The category exists to gate a
	// rule no other tier can see, so it has to carry cases that actually
	// exercise it: distinct ids, at least one level pair where the two blocks
	// each supply a DIFFERENT field (the shape the wholesale rule got wrong),
	// and cases flagged as changed by #228.
	if len(manifest.Cases) < 15 {
		t.Fatalf("thin tier: %d cases", len(manifest.Cases))
	}
	seen := make(map[string]bool, len(manifest.Cases))
	changed, partialPairs := 0, 0
	for _, c := range manifest.Cases {
		if c.ID == "" {
			t.Fatal("a case has no id")
		}
		if seen[c.ID] {
			t.Fatalf("duplicate case id %q", c.ID)
		}
		seen[c.ID] = true
		if c.ChangedBy228 {
			changed++
		}
		declares := func(block map[string]*float64, field string) bool {
			v, ok := block[field]
			return ok && v != nil
		}
		blocks := []map[string]*float64{c.Levels.Assertion, c.Levels.Test, c.Levels.Model}
		for i, inner := range blocks {
			for _, outer := range blocks[i+1:] {
				if declares(inner, "abs") && !declares(inner, "rel") && declares(outer, "rel") {
					partialPairs++
				}
				if declares(inner, "rel") && !declares(inner, "abs") && declares(outer, "abs") {
					partialPairs++
				}
			}
		}
	}
	if changed < 5 {
		t.Fatalf("tier does not exercise the change it exists for: %d cases flagged changed_by_228", changed)
	}
	if partialPairs == 0 {
		t.Fatal("no case has two levels each declaring a DIFFERENT bound; " +
			"without one the tier cannot tell a per-field merge from a wholesale one")
	}
}
