package esm

import (
	"path/filepath"
	"testing"
)

// TestAggregateValidFixtures asserts every tests/valid/aggregate/*.esm fixture
// parses and schema-validates cleanly through the Go loader. These exercise the
// additive aggregate/semiring schema deltas (op:"aggregate", the closed
// `semiring` enum, `ranges` { "from": <index-set> } references, and the
// model-level `index_sets` registry). Validation/round-trip only — the Go
// binding does no numeric evaluation. Cross-binding conformance bead
// ess-my4.1.5; RFC semiring-faq-unified-ir §5.1 / §5.2.
func TestAggregateValidFixtures(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	pattern := filepath.Join(repoRoot, "tests", "valid", "aggregate", "*.esm")
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

// TestAggregateInvalidFixtures asserts every tests/invalid/aggregate/*.esm
// fixture is REJECTED. Each is a pure schema violation (unregistered semiring,
// ragged index set missing offsets/values, discrete variable missing shape,
// join not an array, join `on` pair wrong arity, refresh on a non-discrete
// variable), so Load returns a non-nil error at schema-validation time.
func TestAggregateInvalidFixtures(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	pattern := filepath.Join(repoRoot, "tests", "invalid", "aggregate", "*.esm")
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
			if _, err := Load(path); err == nil {
				t.Fatalf("expected %s to be rejected, but it validated", name)
			}
		})
	}
}
