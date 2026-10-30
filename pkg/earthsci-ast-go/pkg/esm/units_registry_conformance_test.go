package esm

// The Go adapter for tests/conformance/unit_registry (esm-spec §4.8.1-4.8.2):
// one unit STRING at a time, the same golden the Julia, Python and Rust
// adapters read. The exact-scale half of `accept` is
// TestUnitRegistryGoldenExactScales (units_exact_scale_test.go); this file adds
// the dimension and float-factor half, and the two rejection lists.

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

type unitGoldenEntry struct {
	Units            string   `json:"units"`
	Canonical        string   `json:"canonical"`
	ScaleToCanonical *float64 `json:"scale_to_canonical"`
	Why              string   `json:"why"`
}

func readUnitGolden(t *testing.T) (accept, reject, scaling []unitGoldenEntry) {
	t.Helper()
	_, thisFile, _, _ := runtime.Caller(0)
	path := filepath.Join(filepath.Dir(thisFile), "..", "..", "..", "..",
		"tests", "conformance", "unit_registry", "golden", "unit_verdicts.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden: %v", err)
	}
	var g struct {
		Accept              []unitGoldenEntry `json:"accept"`
		Reject              []unitGoldenEntry `json:"reject"`
		RejectScalingFactor []unitGoldenEntry `json:"reject_scaling_factor"`
	}
	if err := json.Unmarshal(raw, &g); err != nil {
		t.Fatalf("parse golden: %v", err)
	}
	if len(g.Accept) == 0 || len(g.Reject) == 0 || len(g.RejectScalingFactor) == 0 {
		t.Fatal("golden has an empty list")
	}
	return g.Accept, g.Reject, g.RejectScalingFactor
}

func TestUnitRegistryGoldenAcceptsDimensionAndFactor(t *testing.T) {
	accept, _, _ := readUnitGolden(t)
	for _, e := range accept {
		got, err := ParseUnit(e.Units)
		if err != nil {
			t.Errorf("%q must resolve: %v", e.Units, err)
			continue
		}
		want, err := ParseUnit(e.Canonical)
		if err != nil {
			t.Errorf("%q must resolve: %v", e.Canonical, err)
			continue
		}
		if !got.Dim.Equal(want.Dim) {
			t.Errorf("%q must have the dimension of %q: %v vs %v", e.Units, e.Canonical, got.Dim, want.Dim)
		}
		if e.ScaleToCanonical != nil {
			factor := got.Scale / want.Scale
			if math.Abs(factor-*e.ScaleToCanonical) > 1e-12*math.Abs(*e.ScaleToCanonical) {
				t.Errorf("%q -> %q: factor %v, pinned %v", e.Units, e.Canonical, factor, *e.ScaleToCanonical)
			}
		}
	}
}

func TestUnitRegistryGoldenRejects(t *testing.T) {
	_, reject, _ := readUnitGolden(t)
	for _, e := range reject {
		if _, err := ParseUnit(e.Units); err == nil {
			t.Errorf("%q must NOT resolve: %s", e.Units, e.Why)
		}
	}
}

func TestUnitRegistryGoldenRejectsScalingFactorsAndSaysSo(t *testing.T) {
	_, _, scaling := readUnitGolden(t)
	for _, e := range scaling {
		_, err := ParseUnit(e.Units)
		if err == nil {
			t.Errorf("%q must NOT resolve", e.Units)
			continue
		}
		if !strings.Contains(err.Error(), "scaling factor") {
			t.Errorf("%q: diagnostic must name the scaling factor, got %q", e.Units, err)
		}
	}
}
