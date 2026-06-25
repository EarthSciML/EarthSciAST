package esm

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeJSON(t *testing.T, path string, payload interface{}) {
	t.Helper()
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
}

func TestResolveSubsystemRefs_NoRefs(t *testing.T) {
	file := &EsmFile{
		Models: map[string]Model{
			"main": {Variables: map[string]ModelVariable{}, Equations: []Equation{}},
		},
	}
	if err := ResolveSubsystemRefs(file, "."); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestResolveSubsystemRefs_LocalFile(t *testing.T) {
	dir := t.TempDir()
	inner := map[string]interface{}{
		"esm": "0.1.0",
		"metadata": map[string]interface{}{
			"name": "inner",
		},
		"models": map[string]interface{}{
			"Inner": map[string]interface{}{
				"variables": map[string]interface{}{
					"x": map[string]interface{}{"type": "state"},
				},
				"equations": []interface{}{},
			},
		},
	}
	writeJSON(t, filepath.Join(dir, "inner.json"), inner)

	file := &EsmFile{
		Models: map[string]Model{
			"Outer": {
				Variables: map[string]ModelVariable{},
				Equations: []Equation{},
				Subsystems: map[string]interface{}{
					"Inner": map[string]interface{}{"ref": "inner.json"},
				},
			},
		},
	}

	if err := ResolveSubsystemRefs(file, dir); err != nil {
		t.Fatalf("ResolveSubsystemRefs: %v", err)
	}

	resolved, ok := file.Models["Outer"].Subsystems["Inner"].(map[string]interface{})
	if !ok {
		t.Fatalf("Inner not resolved to a map: %T", file.Models["Outer"].Subsystems["Inner"])
	}
	if _, hasRef := resolved["ref"]; hasRef {
		t.Fatalf("Inner still has ref after resolution: %#v", resolved)
	}
	if _, hasVars := resolved["variables"]; !hasVars {
		t.Fatalf("Inner missing variables after resolution: %#v", resolved)
	}
}

func TestResolveSubsystemRefs_LoaderOnlyFile(t *testing.T) {
	dir := t.TempDir()
	// A loader-only referenced file: its sole component is a single data loader.
	inner := map[string]interface{}{
		"esm": "0.1.0",
		"metadata": map[string]interface{}{
			"name": "inner-loader",
		},
		"data_loaders": map[string]interface{}{
			"ERA5_PL": map[string]interface{}{
				"kind": "grid",
				"source": map[string]interface{}{
					"url_template": "cds://reanalysis-era5-pressure-levels/{date:%Y}/era5_pl_{date:%Y}.nc",
				},
				"variables": map[string]interface{}{
					"t": map[string]interface{}{
						"file_variable": "t",
						"units":         "K",
						"description":   "Air temperature",
					},
				},
			},
		},
	}
	writeJSON(t, filepath.Join(dir, "inner.json"), inner)

	file := &EsmFile{
		Models: map[string]Model{
			"Outer": {
				Variables: map[string]ModelVariable{},
				Equations: []Equation{},
				Subsystems: map[string]interface{}{
					"Loader": map[string]interface{}{"ref": "inner.json"},
				},
			},
		},
	}

	if err := ResolveSubsystemRefs(file, dir); err != nil {
		t.Fatalf("ResolveSubsystemRefs: %v", err)
	}

	resolved, ok := file.Models["Outer"].Subsystems["Loader"].(map[string]interface{})
	if !ok {
		t.Fatalf("Loader not resolved to a map: %T", file.Models["Outer"].Subsystems["Loader"])
	}
	if _, hasRef := resolved["ref"]; hasRef {
		t.Fatalf("Loader still has ref after resolution: %#v", resolved)
	}
	if kind, _ := resolved["kind"].(string); kind != "grid" {
		t.Fatalf("Loader missing/incorrect kind after resolution: %#v", resolved)
	}
	if _, hasVars := resolved["variables"]; !hasVars {
		t.Fatalf("Loader missing variables after resolution: %#v", resolved)
	}
}

func TestResolveSubsystemRefs_MissingFile(t *testing.T) {
	dir := t.TempDir()
	file := &EsmFile{
		Models: map[string]Model{
			"Outer": {
				Subsystems: map[string]interface{}{
					"Missing": map[string]interface{}{"ref": "does-not-exist.json"},
				},
			},
		},
	}
	err := ResolveSubsystemRefs(file, dir)
	if err == nil {
		t.Fatalf("expected error for missing ref, got nil")
	}
	if !strings.Contains(err.Error(), "failed to read") {
		t.Errorf("unexpected error: %v", err)
	}
}

func TestResolveSubsystemRefs_Circular(t *testing.T) {
	dir := t.TempDir()
	a := map[string]interface{}{
		"esm": "0.1.0",
		"metadata": map[string]interface{}{
			"name": "a",
		},
		"models": map[string]interface{}{
			"A": map[string]interface{}{
				"variables": map[string]interface{}{},
				"equations": []interface{}{},
				"subsystems": map[string]interface{}{
					"Cycle": map[string]interface{}{"ref": "b.json"},
				},
			},
		},
	}
	b := map[string]interface{}{
		"esm": "0.1.0",
		"metadata": map[string]interface{}{
			"name": "b",
		},
		"models": map[string]interface{}{
			"B": map[string]interface{}{
				"variables": map[string]interface{}{},
				"equations": []interface{}{},
				"subsystems": map[string]interface{}{
					"Cycle": map[string]interface{}{"ref": "a.json"},
				},
			},
		},
	}
	writeJSON(t, filepath.Join(dir, "a.json"), a)
	writeJSON(t, filepath.Join(dir, "b.json"), b)

	file := &EsmFile{
		Models: map[string]Model{
			"Root": {
				Subsystems: map[string]interface{}{
					"Start": map[string]interface{}{"ref": "a.json"},
				},
			},
		},
	}

	err := ResolveSubsystemRefs(file, dir)
	if err == nil {
		t.Fatalf("expected circular ref error, got nil")
	}
	if !strings.Contains(err.Error(), "circular") {
		t.Errorf("expected circular error, got: %v", err)
	}
}

func TestResolveSubsystemRefs_RemoteURL(t *testing.T) {
	inner := map[string]interface{}{
		"esm": "0.1.0",
		"metadata": map[string]interface{}{
			"name": "remote",
		},
		"models": map[string]interface{}{
			"Remote": map[string]interface{}{
				"variables": map[string]interface{}{},
				"equations": []interface{}{},
			},
		},
	}
	body, _ := json.Marshal(inner)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(body)
	}))
	defer srv.Close()

	file := &EsmFile{
		Models: map[string]Model{
			"Outer": {
				Subsystems: map[string]interface{}{
					"Remote": map[string]interface{}{"ref": srv.URL + "/inner.json"},
				},
			},
		},
	}

	if err := ResolveSubsystemRefs(file, "."); err != nil {
		t.Fatalf("ResolveSubsystemRefs: %v", err)
	}

	resolved, ok := file.Models["Outer"].Subsystems["Remote"].(map[string]interface{})
	if !ok {
		t.Fatalf("Remote not resolved to a map: %T", file.Models["Outer"].Subsystems["Remote"])
	}
	if _, hasRef := resolved["ref"]; hasRef {
		t.Fatalf("Remote still has ref after resolution")
	}
}
