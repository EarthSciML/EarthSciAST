package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

// esm-spec §11.3.3 P8: validation warns, on its non-unit Warnings channel,
// about an unspecified variable used directly as an equality or join key.
// Fixtures shared with the other four bindings.

var precisionSourceDir = filepath.Join("..", "..", "..", "..", "tests", "conformance", "precision_source")

type precisionWarningPair struct {
	Code string `json:"code"`
	Path string `json:"path"`
}

func sortedWarningPairs(in []precisionWarningPair) []precisionWarningPair {
	out := append([]precisionWarningPair{}, in...)
	sort.Slice(out, func(i, j int) bool {
		return out[i].Code+" "+out[i].Path < out[j].Code+" "+out[j].Path
	})
	return out
}

func TestKeyPrecisionUnspecifiedWarning(t *testing.T) {
	b, err := os.ReadFile(filepath.Join(precisionSourceDir, "expected.json"))
	if err != nil {
		t.Fatal(err)
	}
	var exp struct {
		LegacyVersion string                            `json:"legacy_version"`
		Warnings      map[string][]precisionWarningPair `json:"warnings"`
	}
	if err := json.Unmarshal(b, &exp); err != nil {
		t.Fatal(err)
	}
	for fixture, want := range exp.Warnings {
		t.Run(fixture, func(t *testing.T) {
			text, err := os.ReadFile(filepath.Join(precisionSourceDir, fixture))
			if err != nil {
				t.Fatal(err)
			}
			file, err := LoadString(string(text))
			if err != nil {
				t.Fatal(err)
			}
			result := Validate(file)
			if !result.IsValid {
				t.Fatalf("invalid: %+v", result.StructuralErrors)
			}
			var got []precisionWarningPair
			for _, w := range result.Warnings {
				got = append(got, precisionWarningPair{w.Code, w.Path})
			}
			if !reflect.DeepEqual(sortedWarningPairs(got), sortedWarningPairs(want)) {
				t.Errorf("warnings: got %+v, want %+v", got, want)
			}
			for _, w := range result.UnitWarnings {
				if w.Code == CodeKeyPrecisionUnspecified {
					t.Errorf("a precision finding on unit_warnings: %+v", w)
				}
			}

			var doc map[string]any
			if err := json.Unmarshal(text, &doc); err != nil {
				t.Fatal(err)
			}
			doc["esm"] = exp.LegacyVersion
			legacyText, _ := json.Marshal(doc)
			legacy, err := LoadString(string(legacyText))
			if err != nil {
				t.Fatal(err)
			}
			if ws := Validate(legacy).Warnings; len(ws) != 0 {
				t.Errorf("a root below the gate warned: %+v", ws)
			}
		})
	}
}
