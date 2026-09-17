package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// const_array_gather_bounds_scope_test.go is Go's read of the SHARED
// `const_array_gather_bounds` conformance manifest (CONFORMANCE_SPEC §5.40,
// tests/conformance/const_array_gather_bounds/manifest.json).
//
// Go cannot run that category: `index` has no scalar evaluator here and there is
// no inline-test runner. The manifest says so in `scope_excluded`, and this test
// keeps that claim honest the same way assertion_nonfinite_scope_test.go does:
// dropping Go from `scope_excluded`, or requiring it, without giving Go a runner
// turns this red.
func TestConstArrayGatherBoundsExcludesGoWithAReason(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	catDir := filepath.Join(repoRoot, "tests", "conformance", "const_array_gather_bounds")
	raw, err := os.ReadFile(filepath.Join(catDir, "manifest.json"))
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}

	var manifest struct {
		Category         string            `json:"category"`
		BindingsRequired []string          `json:"bindings_required"`
		ScopeExcluded    map[string]string `json:"scope_excluded"`
		Fixtures         []struct {
			ID      string `json:"id"`
			Path    string `json:"path"`
			Model   string `json:"model"`
			Outcome string `json:"outcome"`
		} `json:"fixtures"`
	}
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatalf("parse manifest: %v", err)
	}

	if manifest.Category != "const_array_gather_bounds" {
		t.Fatalf("category = %q, want const_array_gather_bounds", manifest.Category)
	}
	for _, b := range manifest.BindingsRequired {
		if b == "go" {
			t.Fatal("the manifest requires Go, but Go has no evaluator for `index`; " +
				"either give Go an inline-test runner or keep it in scope_excluded")
		}
	}
	if reason, ok := manifest.ScopeExcluded["go"]; !ok || reason == "" {
		t.Fatal("the manifest must say, in scope_excluded, WHY Go does not run this category")
	}

	// Every fixture must still load here: a document Go cannot parse would be a
	// format divergence hiding behind the scope exclusion.
	outcomes := map[string]int{}
	for _, fx := range manifest.Fixtures {
		doc, err := LoadPath(filepath.Join(catDir, fx.Path))
		if err != nil {
			t.Fatalf("%s: Go cannot load the fixture: %v", fx.ID, err)
		}
		if _, ok := doc.Models[fx.Model]; !ok {
			t.Fatalf("%s: model %q missing", fx.ID, fx.Model)
		}
		outcomes[fx.Outcome]++
	}
	if outcomes["error"] == 0 || outcomes["pass"] == 0 {
		t.Fatalf("the case list must carry both must-error and must-pass fixtures, got %v", outcomes)
	}
}
