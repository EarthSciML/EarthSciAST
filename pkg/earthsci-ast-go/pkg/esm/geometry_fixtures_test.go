package esm

import (
	"path/filepath"
	"testing"
)

// TestGeometryValidFixtures asserts every tests/valid/geometry/*.esm fixture
// parses and schema-validates cleanly through the Go loader. These exercise the
// additive M4 geometry-kernel schema deltas (bead ess-my4.4.2; RFC
// semiring-faq-unified-ir §8.1 / §A.8): the `intersect_polygon` leaf op, its
// required `manifold` flag, the clipped overlap ring exposed as a kind:"derived"
// index set (the ring rides the M3 value-invention machinery), and the
// bin-Skolem spatial-join representation composed from the existing
// `floor`/`skolem`/`join.on` ops. Validation/round-trip only — the Go binding
// does no polygon clipping; the tolerance-based clip conformance is the
// evaluator suites' (CONFORMANCE_SPEC.md §5.8). Mirrors
// TestAggregateValidFixtures.
func TestGeometryValidFixtures(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	pattern := filepath.Join(repoRoot, "tests", "valid", "geometry", "*.esm")
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

// TestGeometryInvalidFixtures asserts every tests/invalid/geometry/*.esm fixture
// is handled correctly. Each is a defect isolated to the intersect_polygon
// node: a missing `manifold` (it is required, no default) and a third operand
// (the clip is strictly binary) are pure schema violations rejected at
// schema-validation time; a `manifold` outside the closed {planar, spherical,
// geodesic} set is rejected by the POST-EXPANSION validator
// (`geometry_manifold_invalid`, esm-spec §9.6.4) — the schema admits any
// string there since the §9.6.1 scalar-field substitution-site widening. In
// both cases Load returns a non-nil error. A resolver_only geometry fixture
// (none today) would be schema-valid and accepted, mirroring
// TestAggregateInvalidFixtures.
func TestGeometryInvalidFixtures(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	resolverOnly := resolverOnlyInvalidFixtures(t, repoRoot)
	pattern := filepath.Join(repoRoot, "tests", "invalid", "geometry", "*.esm")
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
			if resolverOnly[name] {
				if _, err := Load(path); err != nil {
					t.Fatalf("resolver-only fixture %s must pass schema validation, got error: %v", name, err)
				}
				return
			}
			if _, err := Load(path); err == nil {
				t.Fatalf("expected %s to be rejected, but it validated", name)
			}
		})
	}
}
