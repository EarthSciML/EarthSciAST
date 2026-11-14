package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"testing"
)

// TestCanonicalDocumentConformanceFixtures consumes
// tests/conformance/canonical_document/*.json: CanonicalizeDocument(input)
// must equal the fixture's expected document, compared as JSON values.
func TestCanonicalDocumentConformanceFixtures(t *testing.T) {
	_, thisFile, _, _ := runtime.Caller(0)
	dir := filepath.Join(filepath.Dir(thisFile), "..", "..", "..", "..", "tests", "conformance", "canonical_document")
	read := func(name string) map[string]any {
		raw, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		var v map[string]any
		if err := json.Unmarshal(raw, &v); err != nil {
			t.Fatalf("parse %s: %v", name, err)
		}
		return v
	}
	fixtures, _ := read("manifest.json")["fixtures"].([]any)
	if len(fixtures) == 0 {
		t.Fatal("manifest has no fixtures")
	}
	for _, f := range fixtures {
		entry := f.(map[string]any)
		t.Run(entry["id"].(string), func(t *testing.T) {
			fixture := read(entry["path"].(string))
			before := read(entry["path"].(string))["input"]
			got := CanonicalizeDocument(fixture["input"])
			if !reflect.DeepEqual(got, fixture["expected"]) {
				gotJSON, _ := json.MarshalIndent(got, "", "  ")
				t.Errorf("canonicalized document differs from expected:\n%s", gotJSON)
			}
			if !reflect.DeepEqual(fixture["input"], before) {
				t.Error("CanonicalizeDocument mutated its input")
			}
		})
	}
}
