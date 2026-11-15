package esm

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
)

// TestCanonicalDocumentConformanceFixtures consumes
// tests/conformance/canonical_document/*.json: CanonicalizeDocument(input)
// must equal the fixture's expected document, compared as JSON values with
// numbers compared by type too (`2` is an int64, `2.0` a float64). The fixtures
// are decoded with UseNumber, so an integer token past 2^53 is kept exactly.
func TestCanonicalDocumentConformanceFixtures(t *testing.T) {
	_, thisFile, _, _ := runtime.Caller(0)
	dir := filepath.Join(filepath.Dir(thisFile), "..", "..", "..", "..", "tests", "conformance", "canonical_document")
	read := func(name string) map[string]any {
		raw, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		var v map[string]any
		dec := json.NewDecoder(bytes.NewReader(raw))
		dec.UseNumber()
		if err := dec.Decode(&v); err != nil {
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
			if !reflect.DeepEqual(got, typedJSONNumbers(fixture["expected"])) {
				gotJSON, _ := json.MarshalIndent(got, "", "  ")
				t.Errorf("canonicalized document differs from expected:\n%s", gotJSON)
			}
			if !reflect.DeepEqual(fixture["input"], before) {
				t.Error("CanonicalizeDocument mutated its input")
			}
		})
	}
}

// typedJSONNumbers reads each json.Number of an expected document as the Go
// value CanonicalizeDocument gives it: an integer token as int64, any other as
// float64.
func typedJSONNumbers(value any) any {
	switch v := value.(type) {
	case json.Number:
		if i, err := v.Int64(); err == nil && !strings.ContainsAny(string(v), ".eE") {
			return i
		}
		f, _ := v.Float64()
		return f
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = typedJSONNumbers(item)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(v))
		for k, item := range v {
			out[k] = typedJSONNumbers(item)
		}
		return out
	default:
		return value
	}
}
