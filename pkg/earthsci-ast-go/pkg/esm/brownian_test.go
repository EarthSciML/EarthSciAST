package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// Round-trip a brownian (SDE) fixture through parse → serialize → parse
// and verify the brownian type and its sidecar fields survive unchanged.
func TestBrownianRoundTrip(t *testing.T) {
	repoRoot := filepath.Join("..", "..", "..", "..")
	fixture := filepath.Join(repoRoot, "tests", "fixtures", "sde", "ornstein_uhlenbeck.esm")
	raw, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var parsed EsmFile
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("unmarshal fixture: %v", err)
	}
	bw, ok := parsed.Models["OU"].Variables["Bw"]
	if !ok {
		t.Fatalf("Bw variable missing in fixture")
	}
	if bw.Type != "brownian" {
		t.Errorf("Bw.Type = %q, want brownian", bw.Type)
	}
	if bw.NoiseKind != "wiener" {
		t.Errorf("Bw.NoiseKind = %q, want wiener", bw.NoiseKind)
	}

	out, err := json.Marshal(&parsed)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var reparsed EsmFile
	if err := json.Unmarshal(out, &reparsed); err != nil {
		t.Fatalf("unmarshal round-trip: %v", err)
	}
	rbw := reparsed.Models["OU"].Variables["Bw"]
	if !reflect.DeepEqual(bw, rbw) {
		t.Errorf("brownian var lost information on round-trip: got %+v want %+v", rbw, bw)
	}
}

// Flattening a coupled file containing brownian vars must surface them in
// FlattenedSystem.BrownianVariables.
func TestFlattenBrownianVariables(t *testing.T) {
	repoRoot := filepath.Join("..", "..", "..", "..")
	fixture := filepath.Join(repoRoot, "tests", "fixtures", "sde", "correlated_noise.esm")
	raw, err := os.ReadFile(fixture)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var parsed EsmFile
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	flat, err := Flatten(&parsed)
	if err != nil {
		t.Fatalf("flatten: %v", err)
	}
	want := []string{"TwoBody.Bx", "TwoBody.By"}
	if !reflect.DeepEqual(flat.BrownianVariables, want) {
		t.Errorf("BrownianVariables = %v, want %v", flat.BrownianVariables, want)
	}
}
