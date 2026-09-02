package esm

// esm-spec §8.2.1 data-source location resolution, against the SHARED pin.
//
// Reads tests/conformance/data_source_url/manifest.json -- the one place the
// expected resolution is written down -- and asserts this binding against it.
// Every binding's own suite reads the same file, so a path rule that differed
// between bindings (which would silently make documents non-portable, the
// defect §8.2.1 closes) fails here rather than downstream.
//
// Expectations are repo-relative paths, not literal URLs: the resolved form is
// a machine-specific absolute file:// URL and a golden holding one would only
// pass on the machine that wrote it.
//
// This binding has no ingest, and asserts the rule anyway: §8.2.1 is a document
// normalization, observable through parse -> emit, and a validate-only binding
// that skipped it would emit a document whose url_template means something
// different from the same document loaded elsewhere.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type dsuPin struct {
	Verbatim string `json:"verbatim"`
	RepoPath string `json:"repo_path"`
}

type dsuSource struct {
	URLTemplate dsuPin   `json:"url_template"`
	Mirrors     []dsuPin `json:"mirrors"`
}

type dsuFixture struct {
	ID              string               `json:"id"`
	Path            string               `json:"path"`
	Expect          string               `json:"expect"`
	Sources         map[string]dsuSource `json:"sources"`
	ErrorCode       string               `json:"error_code"`
	MessageContains []string             `json:"message_contains"`
}

type dsuManifest struct {
	Fixtures []dsuFixture `json:"fixtures"`
}

// dsuRepoRoot: this file sits at <repo>/pkg/earthsci-ast-go/pkg/esm/.
func dsuRepoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", "..", ".."))
	if err != nil {
		t.Fatalf("cannot locate the repository root: %v", err)
	}
	return root
}

func dsuSuiteDir(t *testing.T) string {
	return filepath.Join(dsuRepoRoot(t), "tests", "conformance", "data_source_url")
}

func dsuLoadManifest(t *testing.T) dsuManifest {
	t.Helper()
	p := filepath.Join(dsuSuiteDir(t), "manifest.json")
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("the shared pin %s must be readable: %v", p, err)
	}
	var m dsuManifest
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("manifest.json must be JSON: %v", err)
	}
	return m
}

func dsuFixtureByID(t *testing.T, m dsuManifest, id string) dsuFixture {
	t.Helper()
	for _, f := range m.Fixtures {
		if f.ID == id {
			return f
		}
	}
	t.Fatalf("no fixture %q in the shared manifest", id)
	return dsuFixture{}
}

func dsuExpected(t *testing.T, pin dsuPin) string {
	t.Helper()
	if pin.Verbatim != "" {
		return pin.Verbatim
	}
	return "file://" + filepath.ToSlash(filepath.Join(dsuRepoRoot(t), pin.RepoPath))
}

func TestDataSourceURLResolutionMatchesTheSharedPin(t *testing.T) {
	m := dsuLoadManifest(t)
	f := dsuFixtureByID(t, m, "relative_catalog")

	file, err := LoadPath(filepath.Join(dsuSuiteDir(t), f.Path))
	if err != nil {
		t.Fatalf("the catalog must load: %v", err)
	}
	for name, pin := range f.Sources {
		ds, ok := file.DataSources[name]
		if !ok {
			t.Fatalf("data_sources.%s must survive load", name)
		}
		if got, want := ds.Source.URLTemplate, dsuExpected(t, pin.URLTemplate); got != want {
			t.Errorf("data_sources.%s.source.url_template = %q, want %q", name, got, want)
		}
		if pin.Mirrors == nil {
			continue
		}
		if len(ds.Source.Mirrors) != len(pin.Mirrors) {
			t.Fatalf("data_sources.%s.source.mirrors has %d entries, want %d",
				name, len(ds.Source.Mirrors), len(pin.Mirrors))
		}
		for i, mp := range pin.Mirrors {
			if got, want := ds.Source.Mirrors[i], dsuExpected(t, mp); got != want {
				t.Errorf("data_sources.%s.source.mirrors[%d] = %q, want %q", name, i, got, want)
			}
		}
	}
}

// A second resolution pass, anchored somewhere else entirely, must change
// nothing: the resolved form is scheme-led, which is what keeps
// parse -> emit -> parse stable.
func TestDataSourceURLResolutionIsIdempotent(t *testing.T) {
	m := dsuLoadManifest(t)
	f := dsuFixtureByID(t, m, "relative_catalog")
	file, err := LoadPath(filepath.Join(dsuSuiteDir(t), f.Path))
	if err != nil {
		t.Fatalf("the catalog must load: %v", err)
	}
	for name, ds := range file.DataSources {
		again, err := resolveSourceURL(ds.Source.URLTemplate, "/somewhere/else")
		if err != nil {
			t.Fatalf("data_sources.%s: a resolved URL must re-resolve cleanly: %v", name, err)
		}
		if again != ds.Source.URLTemplate {
			t.Errorf("data_sources.%s: re-resolving %q gave %q", name, ds.Source.URLTemplate, again)
		}
	}
}

// Not merely "it does not resolve": the diagnostic has to NAME the entry and
// the template. Treating ${MOVES_SNAPSHOTS} as a directory name yields an I/O
// error about a path nobody wrote, one step away from a source that delivers a
// consuming parameter's default and compares nothing.
func TestDataSourceURLUnresolvableIsRefusedAndNamed(t *testing.T) {
	m := dsuLoadManifest(t)
	for _, id := range []string{"env_var_catalog", "env_var_mirror_catalog"} {
		f := dsuFixtureByID(t, m, id)
		_, err := LoadPath(filepath.Join(dsuSuiteDir(t), f.Path))
		if err == nil {
			t.Fatalf("%s must be REFUSED at load, not accepted", id)
		}
		if f.ErrorCode != codeDataSourceURLUnresolved {
			t.Fatalf("the manifest pins %q; this binding's constant is %q",
				f.ErrorCode, codeDataSourceURLUnresolved)
		}
		msg := err.Error()
		if !strings.Contains(msg, f.ErrorCode) {
			t.Errorf("%s: the diagnostic must carry [%s]; got: %s", id, f.ErrorCode, msg)
		}
		for _, needle := range f.MessageContains {
			if !strings.Contains(msg, needle) {
				t.Errorf("%s: the diagnostic must name %q; got: %s", id, needle, msg)
			}
		}
	}
}

// §8.2.1: a template carrying a {date:...} substitution names a file per
// timestep, none of which exists at load time, so dot-segment removal is
// lexical and never touches the filesystem.
func TestDataSourceURLDotSegmentsAreLexical(t *testing.T) {
	for _, c := range []struct{ template, base, want string }{
		{"./a/../b/./c.nc", "/x/y", "file:///x/y/b/c.nc"},
		{"/../c.nc", "/x/y", "file:///c.nc"},
		{"{archive_root}/x.nc", "/x/y", "{archive_root}/x.nc"},
		{"s3://bucket/x.nc", "/x/y", "s3://bucket/x.nc"},
	} {
		got, err := resolveSourceURL(c.template, c.base)
		if err != nil {
			t.Fatalf("resolveSourceURL(%q, %q): %v", c.template, c.base, err)
		}
		if got != c.want {
			t.Errorf("resolveSourceURL(%q, %q) = %q, want %q", c.template, c.base, got, c.want)
		}
	}
}
