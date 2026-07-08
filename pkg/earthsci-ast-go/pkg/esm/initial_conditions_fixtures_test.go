package esm

import (
	"path/filepath"
	"testing"
)

// TestInitialConditionsValidFixtures asserts every
// tests/valid/initial_conditions/*.esm fixture parses and schema-validates
// cleanly through the Go loader. These exercise the `expression` initial
// condition type (esm-schema.json $defs/InitialConditions, esm-spec.md §11.4):
// a domain-level map from variable name to an Expression evaluated over the
// spatial grid at t=0 to produce u(x, 0). Validation only — the Go binding
// does no simulation; the cross-binding end-to-end golden is evaluated by the
// Python binding (bead ess-gjn; Julia/Rust e2e deferred).
func TestInitialConditionsValidFixtures(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	pattern := filepath.Join(repoRoot, "tests", "valid", "initial_conditions", "*.esm")
	files, err := filepath.Glob(pattern)
	if err != nil {
		t.Fatalf("glob %s: %v", pattern, err)
	}
	if len(files) == 0 {
		t.Fatalf("no .esm fixtures matched %s", pattern)
	}
	for _, path := range files {
		name := filepath.Base(path)
		t.Run(name, func(t *testing.T) {
			if _, err := Load(path); err != nil {
				t.Fatalf("expected %s to validate, got error: %v", name, err)
			}
		})
	}
}
