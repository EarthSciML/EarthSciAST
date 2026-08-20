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
	file := &ESMFile{
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
					"x": map[string]any{"type": "unknown"},
				},
				"equations": []any{},
			},
		},
	}
	writeJSON(t, filepath.Join(dir, "inner.json"), inner)

	file := &ESMFile{
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

// A data source cannot be mounted as a SUBSYSTEM.
//
// This pin is INVERTED by esm 1.0.0. In 0.x a data loader was a component, so a
// loader-only file was a legal `ref` target and this test asserted the mount
// succeeded. From 1.0.0 a data source is not a component (esm-spec §8): it
// cannot be a subsystem, a coupling endpoint, or a scoped-name path root. A file
// whose only content is `data_sources` therefore contains NO mountable system,
// and §4.7 requires exactly one.
func TestResolveSubsystemRefs_DataSourceOnlyFileIsNotMountable(t *testing.T) {
	dir := t.TempDir()
	inner := map[string]any{
		"esm": "1.0.0",
		"metadata": map[string]any{
			"name": "inner-source",
		},
		"data_sources": map[string]any{
			"ERA5_PL": map[string]any{
				"kind": "grid",
				"source": map[string]any{
					"url_template": "cds://reanalysis-era5-pressure-levels/{date:%Y}/era5_pl_{date:%Y}.nc",
				},
			},
		},
	}
	writeJSON(t, filepath.Join(dir, "inner.json"), inner)

	file := &ESMFile{
		Models: map[string]Model{
			"Outer": {
				Variables: map[string]ModelVariable{},
				Equations: []Equation{},
				Subsystems: map[string]any{
					"Source": map[string]any{"ref": "inner.json"},
				},
			},
		},
	}

	err := ResolveSubsystemRefs(file, dir)
	if err == nil {
		t.Fatal("a data-source-only file is not a mountable subsystem, but the ref resolved")
	}
	if code := tiErrCode(t, err); code != CodeAmbiguousSubsystemRef {
		t.Errorf("code = %s; want %s", code, CodeAmbiguousSubsystemRef)
	}
}

// A file carrying a model AND a data source has exactly ONE mountable system:
// the source does not count toward the §4.7 total, because it is not a
// component. Before 1.0.0 this same file was AMBIGUOUS (two components), so the
// change is observable in both directions.
func TestResolveSubsystemRefs_DataSourceDoesNotMakeRefAmbiguous(t *testing.T) {
	dir := t.TempDir()
	inner := map[string]any{
		"esm": "1.0.0",
		"metadata": map[string]any{
			"name": "inner-mixed",
		},
		"data_sources": map[string]any{
			"ERA5_PL": map[string]any{
				"kind":   "grid",
				"source": map[string]any{"url_template": "cds://era5/{date:%Y}.nc"},
			},
		},
		"models": map[string]any{
			"Inner": map[string]any{
				"variables": map[string]any{
					"x": map[string]any{"type": "unknown", "units": "1"},
				},
				"equations": []any{},
			},
		},
	}
	writeJSON(t, filepath.Join(dir, "inner.json"), inner)

	file := &ESMFile{
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
		t.Fatalf("the model is the single component; the source must not make it ambiguous: %v", err)
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

func TestResolveSubsystemRefs_MissingFile(t *testing.T) {
	dir := t.TempDir()
	file := &ESMFile{
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
	// The failure carries the §4.7 diagnostic code the shared corpus pins
	// (tests/invalid/subsystem_ref_not_found.esm), not an anonymous I/O message.
	if !strings.Contains(err.Error(), CodeUnresolvedSubsystemRef) {
		t.Errorf("want the %s diagnostic code; got: %v", CodeUnresolvedSubsystemRef, err)
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

	file := &ESMFile{
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

	file := &ESMFile{
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
