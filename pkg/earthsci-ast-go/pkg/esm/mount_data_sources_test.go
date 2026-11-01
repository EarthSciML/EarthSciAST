package esm

// esm-spec §4.7 "Bindings reach through an assembly" across URL refs, and the
// post-splice renormalization of a scheme-led location ("Binding a data
// source's location at the mount").

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A model declaring `n_rows` (default 2) that sizes `rows`.
const forwardOuterDoc = `{
  "esm": "1.0.0",
  "metadata": {"name": "outer"},
  "metaparameters": {"n_rows": {"type": "integer", "default": 2}},
  "index_sets": {"rows": {"kind": "interval", "size": "n_rows"}},
  "models": {"Outer": {
    "variables": {"x": {"type": "parameter", "units": "1", "shape": ["rows"], "default": 0.0}},
    "equations": []
  }}
}`

// A catalogue declaring no metaparameters that mounts ref.
func forwardCatalogueDoc(ref string) string {
	return `{"esm": "1.0.0", "metadata": {"name": "cat"},
  "models": {"Outer": {"ref": "` + ref + `"}}}`
}

// A root whose subsystem edge mounts ref with `bindings: {n_rows: 4}`.
func forwardRootDoc(ref string) string {
	return `{"esm": "1.0.0", "metadata": {"name": "run"},
  "models": {"Run": {"variables": {}, "equations": [],
    "subsystems": {"Snap": {"ref": "` + ref + `", "bindings": {"n_rows": 4}}}}}}`
}

func forwardServer(t *testing.T, docs map[string]string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, ok := docs[r.URL.Path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// forwardLoadRoot writes the root document to a scratch directory and loads it
// by path (LoadString resolves no refs).
func forwardLoadRoot(t *testing.T, doc string) (*ESMFile, error) {
	t.Helper()
	root := filepath.Join(t.TempDir(), "run.esm")
	if err := os.WriteFile(root, []byte(doc), 0o644); err != nil {
		t.Fatal(err)
	}
	return LoadPath(root)
}

func forwardRowsSize(t *testing.T, file *ESMFile) any {
	t.Helper()
	is, ok := file.IndexSets["rows"]
	if !ok {
		t.Fatalf("index_sets.rows must reach the root")
	}
	b, _ := json.Marshal(is)
	var raw map[string]any
	_ = json.Unmarshal(b, &raw)
	return raw["size"]
}

// The walk that decides whether an edge binding the leaf does not declare is
// forwarded follows a URL ref exactly as the loader does: a local catalogue
// mounting a REMOTE model, and a remote catalogue mounting a remote model.
func TestBindingsForwardThroughURLRefs(t *testing.T) {
	var srv *httptest.Server
	docs := map[string]string{"/outer.esm": forwardOuterDoc}
	srv = forwardServer(t, docs)
	docs["/cat.esm"] = forwardCatalogueDoc(srv.URL + "/outer.esm")

	t.Run("local_catalogue_remote_leaf", func(t *testing.T) {
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, "cat.esm"), []byte(forwardCatalogueDoc(srv.URL+"/outer.esm")), 0o644); err != nil {
			t.Fatal(err)
		}
		root := filepath.Join(dir, "run.esm")
		if err := os.WriteFile(root, []byte(forwardRootDoc("cat.esm")), 0o644); err != nil {
			t.Fatal(err)
		}
		file, err := LoadPath(root)
		if err != nil {
			t.Fatalf("must load: %v", err)
		}
		if got := forwardRowsSize(t, file); got != float64(4) {
			t.Errorf("index_sets.rows.size = %v, want 4", got)
		}
	})

	t.Run("remote_catalogue_remote_leaf", func(t *testing.T) {
		file, err := forwardLoadRoot(t, forwardRootDoc(srv.URL+"/cat.esm"))
		if err != nil {
			t.Fatalf("must load: %v", err)
		}
		if got := forwardRowsSize(t, file); got != float64(4) {
			t.Errorf("index_sets.rows.size = %v, want 4", got)
		}
	})
}

// A nested ref the walk cannot read is reported as the unresolved ref it is,
// not as `template_import_unknown_name` for the binding whose declaration the
// walk could not see: the real load reaches the nested edge first. Covers a URL
// that cannot be fetched, and a RELATIVE ref inside a URL-loaded document,
// which this binding does not yet join onto the document's URL directory
// (esm-spec §4.7 "URL (remote) references", current bindings) and so fails to
// resolve in the loader and the walk alike.
func TestBindingForwardingReportsAnUnreadableURLRefAsUnresolved(t *testing.T) {
	docs := map[string]string{"/outer.esm": forwardOuterDoc}
	srv := forwardServer(t, docs)
	docs["/cat_missing.esm"] = forwardCatalogueDoc(srv.URL + "/missing.esm")
	docs["/cat_relative.esm"] = forwardCatalogueDoc("outer.esm")
	for _, c := range []struct{ cat, needle string }{
		{"/cat_missing.esm", "missing.esm"},
		{"/cat_relative.esm", "outer.esm"},
	} {
		t.Run(c.cat, func(t *testing.T) {
			_, err := forwardLoadRoot(t, forwardRootDoc(srv.URL+c.cat))
			if err == nil {
				t.Fatalf("must be refused")
			}
			msg := err.Error()
			if !strings.Contains(msg, CodeUnresolvedSubsystemRef) || !strings.Contains(msg, c.needle) {
				t.Errorf("want %s naming %s; got: %s", CodeUnresolvedSubsystemRef, c.needle, msg)
			}
			if strings.Contains(msg, CodeTemplateImportUnknownName) {
				t.Errorf("an unreadable nested ref must not surface as %s; got: %s", CodeTemplateImportUnknownName, msg)
			}
		})
	}
}

func TestRemoveSchemedURLPathDotSegments(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"https://h/lib/data/../alt/t.parquet", "https://h/lib/alt/t.parquet"},
		{"https://h/q/x/../a/t.parquet?v=./x/../y", "https://h/q/a/t.parquet?v=./x/../y"},
		{"https://h/a/./b/#f/../g", "https://h/a/b/#f/../g"},
		{"https://h/a/b/..", "https://h/a/"},
		{"https://h/../../a", "https://h/a"},
		{"https://h/a//b/../c", "https://h/a//c"},
		{"https://h", "https://h"},
		{"https://h?x=../y", "https://h?x=../y"},
		{"s3://bucket/k/./v/../w", "s3://bucket/k/w"},
	} {
		if got := removeSchemedURLPathDotSegments(c.in); got != c.want {
			t.Errorf("removeSchemedURLPathDotSegments(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}
