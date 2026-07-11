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

func writeJSON(t *testing.T, path string, payload any) {
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
	inner := map[string]any{
		"esm": "0.1.0",
		"metadata": map[string]any{
			"name": "inner",
		},
		"models": map[string]any{
			"Inner": map[string]any{
				"variables": map[string]any{
					"x": map[string]any{"type": "state"},
				},
				"equations": []any{},
			},
		},
	}
	writeJSON(t, filepath.Join(dir, "inner.json"), inner)

	file := &EsmFile{
		Models: map[string]Model{
			"Outer": {
				Variables: map[string]ModelVariable{},
				Equations: []Equation{},
				Subsystems: map[string]any{
					"Inner": map[string]any{"ref": "inner.json"},
				},
			},
		},
	}

	if err := ResolveSubsystemRefs(file, dir); err != nil {
		t.Fatalf("ResolveSubsystemRefs: %v", err)
	}

	resolved, ok := file.Models["Outer"].Subsystems["Inner"].(map[string]any)
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
	inner := map[string]any{
		"esm": "0.1.0",
		"metadata": map[string]any{
			"name": "inner-loader",
		},
		"data_loaders": map[string]any{
			"ERA5_PL": map[string]any{
				"kind": "grid",
				"source": map[string]any{
					"url_template": "cds://reanalysis-era5-pressure-levels/{date:%Y}/era5_pl_{date:%Y}.nc",
				},
				"variables": map[string]any{
					"t": map[string]any{
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
				Subsystems: map[string]any{
					"Loader": map[string]any{"ref": "inner.json"},
				},
			},
		},
	}

	if err := ResolveSubsystemRefs(file, dir); err != nil {
		t.Fatalf("ResolveSubsystemRefs: %v", err)
	}

	resolved, ok := file.Models["Outer"].Subsystems["Loader"].(map[string]any)
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
				Subsystems: map[string]any{
					"Missing": map[string]any{"ref": "does-not-exist.json"},
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
	a := map[string]any{
		"esm": "0.1.0",
		"metadata": map[string]any{
			"name": "a",
		},
		"models": map[string]any{
			"A": map[string]any{
				"variables": map[string]any{},
				"equations": []any{},
				"subsystems": map[string]any{
					"Cycle": map[string]any{"ref": "b.json"},
				},
			},
		},
	}
	b := map[string]any{
		"esm": "0.1.0",
		"metadata": map[string]any{
			"name": "b",
		},
		"models": map[string]any{
			"B": map[string]any{
				"variables": map[string]any{},
				"equations": []any{},
				"subsystems": map[string]any{
					"Cycle": map[string]any{"ref": "a.json"},
				},
			},
		},
	}
	writeJSON(t, filepath.Join(dir, "a.json"), a)
	writeJSON(t, filepath.Join(dir, "b.json"), b)

	file := &EsmFile{
		Models: map[string]Model{
			"Root": {
				Subsystems: map[string]any{
					"Start": map[string]any{"ref": "a.json"},
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
	inner := map[string]any{
		"esm": "0.1.0",
		"metadata": map[string]any{
			"name": "remote",
		},
		"models": map[string]any{
			"Remote": map[string]any{
				"variables": map[string]any{},
				"equations": []any{},
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
				Subsystems: map[string]any{
					"Remote": map[string]any{"ref": srv.URL + "/inner.json"},
				},
			},
		},
	}

	if err := ResolveSubsystemRefs(file, "."); err != nil {
		t.Fatalf("ResolveSubsystemRefs: %v", err)
	}

	resolved, ok := file.Models["Outer"].Subsystems["Remote"].(map[string]any)
	if !ok {
		t.Fatalf("Remote not resolved to a map: %T", file.Models["Outer"].Subsystems["Remote"])
	}
	if _, hasRef := resolved["ref"]; hasRef {
		t.Fatalf("Remote still has ref after resolution")
	}
}
