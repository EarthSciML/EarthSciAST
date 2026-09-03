package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// assertion_nonfinite_scope_test.go is Go's read of the SHARED
// `assertion_nonfinite` conformance manifest (CONFORMANCE_SPEC §5.20,
// tests/conformance/assertion_nonfinite/manifest.json).
//
// Go cannot run that category: the contract is the §6.6.3 pass predicate for a
// non-finite ACTUAL, and Go has no simulator and no assertion comparison — it
// parses a `tests` block as data and never evaluates one. The manifest says so
// in `scope_excluded`, and this test is what keeps that claim honest.
//
// Why a test rather than a line in a document. A shared corpus that only some
// bindings read is the failure this suite has already had once: a rejection
// corpus was being consumed by two of five bindings, and the three that ignored
// it could have diverged silently for as long as nobody looked. An exclusion is
// the same hazard one level down — it is invisible by construction. So every
// binding reads this manifest, and the two that cannot execute it assert their
// own exclusion: if someone drops Go from `scope_excluded` (or adds it to
// `bindings_required`) without giving Go a runner, this goes red instead of the
// category quietly covering one binding fewer than it claims.
func TestAssertionNonfiniteExcludesGoWithAReason(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	path := filepath.Join(repoRoot, "tests", "conformance", "assertion_nonfinite", "manifest.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}

	var manifest struct {
		Category         string            `json:"category"`
		ReferenceBinding string            `json:"reference_binding"`
		BindingsRequired []string          `json:"bindings_required"`
		ScopeExcluded    map[string]string `json:"scope_excluded"`
		Fixtures         []struct {
			Path  string `json:"path"`
			Cases []struct {
				AssertionIdx int    `json:"assertion_idx"`
				ActualClass  string `json:"actual_class"`
				Passed       bool   `json:"passed"`
			} `json:"cases"`
		} `json:"fixtures"`
	}
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatalf("parse %s: %v", path, err)
	}

	if manifest.Category != "assertion_nonfinite" {
		t.Fatalf("category = %q, want assertion_nonfinite", manifest.Category)
	}
	for _, b := range manifest.BindingsRequired {
		if b == "go" {
			t.Fatal("the manifest requires Go, but Go has no assertion comparison to gate; " +
				"either give Go an inline-test runner or keep it in scope_excluded")
		}
	}
	if reason, ok := manifest.ScopeExcluded["go"]; !ok || reason == "" {
		t.Fatal("the manifest must say, in scope_excluded, WHY Go does not run this category")
	}

	// The fixture the other three bindings run must be present and loadable as
	// an ESM document by this binding, even though Go cannot evaluate its
	// assertions: a category whose fixture Go cannot even parse would be a
	// format divergence hiding behind a scope exclusion.
	if len(manifest.Fixtures) == 0 {
		t.Fatal("the manifest declares no fixtures")
	}
	for _, fx := range manifest.Fixtures {
		fixturePath := filepath.Join(repoRoot, "tests", "conformance", "assertion_nonfinite", fx.Path)
		doc, err := LoadPath(fixturePath)
		if err != nil {
			t.Fatalf("load %s: %v", fixturePath, err)
		}
		if len(doc.Models) == 0 {
			t.Fatalf("%s declares no models", fixturePath)
		}
		if len(fx.Cases) == 0 {
			t.Fatalf("%s has no declared cases", fx.Path)
		}
		// Non-vacuity, checkable without a simulator: the category must carry
		// at least one non-finite case that MUST FAIL and at least one finite
		// case that MUST PASS. A manifest of nothing but failures would be
		// satisfiable by a binding that failed every assertion.
		var mustFailNonFinite, mustPassFinite int
		for _, c := range fx.Cases {
			if c.ActualClass != "finite" && !c.Passed {
				mustFailNonFinite++
			}
			if c.ActualClass == "finite" && c.Passed {
				mustPassFinite++
			}
		}
		if mustFailNonFinite == 0 || mustPassFinite == 0 {
			t.Fatalf("%s: %d must-fail non-finite and %d must-pass finite cases; "+
				"the category needs both to be non-vacuous", fx.Path, mustFailNonFinite, mustPassFinite)
		}
	}
}
