package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// TestCanonicalConformanceFixtures consumes tests/conformance/canonical/*.json
// and asserts CanonicalJSON(input) == expected byte-for-byte. The same
// fixtures are run by every binding's test suite — passing here means this
// binding produces canonical output that matches the cross-binding contract.
func TestCanonicalConformanceFixtures(t *testing.T) {
	dir := canonicalFixturesDir(t)
	manifestPath := filepath.Join(dir, "manifest.json")
	manifestBytes, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	var manifest struct {
		Fixtures []struct {
			ID   string `json:"id"`
			Path string `json:"path"`
		} `json:"fixtures"`
	}
	if err := json.Unmarshal(manifestBytes, &manifest); err != nil {
		t.Fatalf("parse manifest: %v", err)
	}
	if len(manifest.Fixtures) == 0 {
		t.Fatal("manifest has no fixtures")
	}
	for _, f := range manifest.Fixtures {
		f := f
		t.Run(f.ID, func(t *testing.T) {
			fixturePath := filepath.Join(dir, f.Path)
			raw, err := os.ReadFile(fixturePath)
			if err != nil {
				t.Fatalf("read fixture: %v", err)
			}
			var fixture struct {
				ID       string          `json:"id"`
				Input    json.RawMessage `json:"input"`
				Expected string          `json:"expected"`
			}
			if err := json.Unmarshal(raw, &fixture); err != nil {
				t.Fatalf("parse fixture: %v", err)
			}
			expr, err := UnmarshalExpression(fixture.Input)
			if err != nil {
				t.Fatalf("unmarshal input: %v", err)
			}
			got, err := CanonicalJSON(expr)
			if err != nil {
				t.Fatalf("CanonicalJSON: %v", err)
			}
			if string(got) != fixture.Expected {
				t.Errorf("\n   id: %s\n  got: %s\n want: %s", f.ID, got, fixture.Expected)
			}
		})
	}
}

func canonicalFixturesDir(t *testing.T) string {
	t.Helper()
	_, thisFile, _, _ := runtime.Caller(0)
	// pkg/esm/canonical_conformance_test.go -> repo root is 4 levels up.
	pkgDir := filepath.Dir(thisFile)
	repoRoot := filepath.Join(pkgDir, "..", "..", "..", "..")
	return filepath.Join(repoRoot, "tests", "conformance", "canonical")
}
