package esm

import (
	"path/filepath"
	"testing"
)

// TestCadenceValidFixtures asserts every tests/valid/cadence/*.esm fixture
// parses and schema-validates cleanly through the Go loader. These are the
// three RFC semiring-faq-unified-ir §6.1 dependency-partition (cadence)
// fixtures — mixed_stencil, pure_topology, pure_pointwise — each carrying an
// `expect_cadence` assertion on every meaningful node. They exercise the
// additive `expect_cadence` enum on ExpressionNode (the partition pass's
// author-assertion / diagnostic hook). Validation only — the Go binding does no
// partition-pass evaluation; the cross-binding class / materialization-point /
// CONST-fold golden is asserted by scripts/run-cadence-conformance.py
// (CONFORMANCE_SPEC.md §5.7). Cross-binding conformance bead ess-my4.3.6.
func TestCadenceValidFixtures(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	pattern := filepath.Join(repoRoot, "tests", "valid", "cadence", "*.esm")
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
