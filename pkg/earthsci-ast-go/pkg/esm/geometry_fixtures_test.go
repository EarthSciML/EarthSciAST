package esm

import (
	"errors"
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
// geodesic} set is SCHEMA-VALID on purpose — the §9.6.1 scalar-field
// substitution-site widening lets the schema admit any string there, so a
// template `body` may name a parameter in that slot — and is caught instead by
// the POST-EXPANSION validator (`geometry_manifold_invalid`, esm-spec §9.6.4),
// which the Go binding DOES implement.
//
// So every geometry fixture is rejected: Load returns a non-nil error in both
// cases. This is where geometry parts company with TestAggregateInvalidFixtures
// — a `resolver_only` pin means the defect survives JSON-Schema, not that Go
// lets it through. Go runs the §9.6.4 validators, so a resolver_only geometry
// fixture must be REJECTED carrying exactly the code the corpus pinned in
// `resolver_error_code`; the aggregate fixtures pin resolver checks Go does not
// run, and those it must accept.
func TestGeometryInvalidFixtures(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	resolverPins := resolverOnlyPins(t, repoRoot)
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
			_, err := Load(path)
			if err == nil {
				t.Fatalf("expected %s to be rejected, but it validated", name)
			}
			want, isResolverOnly := resolverPins[name]
			if !isResolverOnly {
				return
			}
			if want == "" {
				t.Fatalf("fixture %s is pinned resolver_only but names no resolver_error_code; "+
					"the code Go must raise is unverifiable", name)
			}
			var de DiagnosticError
			if !errors.As(err, &de) {
				t.Fatalf("resolver-only fixture %s: Load error %v carries no diagnostic code, want %q",
					name, err, want)
			}
			if got := de.DiagnosticCode(); got != want {
				t.Fatalf("resolver-only fixture %s: Load raised code %q, want pinned %q",
					name, got, want)
			}
		})
	}
}
