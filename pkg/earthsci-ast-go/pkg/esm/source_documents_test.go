package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

// Source documents loaded from files, esm-spec §1.2.1: a document read from a
// path or a URL is Markdown when its name ends in `.md`, Typst when it ends in
// `.typ`, and JSON otherwise, at the root and at every ref site. The shared
// cases live in tests/conformance/source_documents/.

func sourceDocumentsDir(t *testing.T) string {
	t.Helper()
	dir, err := filepath.Abs(filepath.Join("..", "..", "..", "..", "tests", "conformance", "source_documents"))
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestSourceDocumentsConformance(t *testing.T) {
	dir := sourceDocumentsDir(t)
	raw, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var manifest struct {
		Cases []stdlibRefsCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatal(err)
	}
	if len(manifest.Cases) == 0 {
		t.Fatal("no cases in manifest")
	}
	for _, c := range manifest.Cases {
		t.Run(c.ID, func(t *testing.T) {
			for k, v := range c.Env {
				t.Setenv(k, v)
			}
			path := filepath.Join(dir, c.Fixture)
			switch c.Expect {
			case "same_as_twin":
				got := loadedDocument(t, path)
				want := loadedDocument(t, filepath.Join(dir, c.Twin))
				if !reflect.DeepEqual(got, want) {
					t.Errorf("loaded %s differs from its twin", c.Fixture)
				}
			case "ok":
				f, err := LoadPath(path)
				if err == nil && c.Driver == "flatten" {
					_, err = Flatten(f)
				}
				if err != nil {
					t.Errorf("%s through %s: %v", c.Fixture, c.Driver, err)
				}
			case "error":
				f, err := LoadPath(path)
				if err == nil && c.Driver == "flatten" {
					_, err = Flatten(f)
				}
				if code := stdErrCode(err); code != c.Code {
					t.Errorf("code = %s; want %s", code, c.Code)
				}
			default:
				t.Fatalf("unknown expect %q", c.Expect)
			}
		})
	}
}

// The format comes from the name alone: a URL's query and fragment are not
// part of it, and the suffix match is exact and case-sensitive.
func TestDecodeDocumentTextByName(t *testing.T) {
	jsonText := []byte(`{"esm": "1.1.0"}`)
	for _, name := range []string{
		"a.esm", "a.json", "a.MD", "a.Typ", "a.md.esm", "https://example.com/a.esm?x=.md",
		"https://example.com/a.esm#b.typ",
	} {
		got, err := decodeDocumentText(jsonText, name)
		if err != nil || string(got) != string(jsonText) {
			t.Errorf("%s: read as a source document (%q, %v)", name, got, err)
		}
	}
	for _, name := range []string{"a.md", "a.typ", "https://example.com/a.typ?x=1", "https://example.com/a.md#top"} {
		_, err := decodeDocumentText(jsonText, name)
		if code := stdErrCode(err); code != CodeParseError {
			t.Errorf("%s: code = %s; want %s", name, code, CodeParseError)
		}
	}
}
