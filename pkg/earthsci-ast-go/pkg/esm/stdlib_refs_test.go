package esm

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"testing/fstest"
)

// Standard-library refs, esm-spec §4.7: `esm:std/<file>.esm` resolves to the
// bundle embedded from pkg/esm/stdlib/. The shared cases live in
// tests/conformance/stdlib_refs/.

func stdlibRefsDir(t *testing.T) string {
	t.Helper()
	dir, err := filepath.Abs(filepath.Join("..", "..", "..", "..", "tests", "conformance", "stdlib_refs"))
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

type stdlibRefsCase struct {
	ID      string            `json:"id"`
	Fixture string            `json:"fixture"`
	Twin    string            `json:"twin"`
	Expect  string            `json:"expect"`
	Code    string            `json:"code"`
	Driver  string            `json:"driver"`
	Env     map[string]string `json:"env"`
}

// stdErrCode is the stable diagnostic code an error carries.
func stdErrCode(err error) string {
	if err == nil {
		return "NO_ERROR"
	}
	var et *ExpressionTemplateError
	if errors.As(err, &et) {
		return et.Code
	}
	var dc interface{ DiagnosticCode() string }
	if errors.As(err, &dc) {
		return dc.DiagnosticCode()
	}
	return "<" + err.Error() + ">"
}

// blankRefs replaces every string value of a `ref` key by one placeholder.
func blankRefs(v any) any {
	switch n := v.(type) {
	case map[string]any:
		for k, c := range n {
			if _, isStr := c.(string); isStr && k == "ref" {
				n[k] = "<ref>"
			} else {
				n[k] = blankRefs(c)
			}
		}
	case []any:
		for i, c := range n {
			n[i] = blankRefs(c)
		}
	}
	return v
}

func loadedDocument(t *testing.T, path string) any {
	t.Helper()
	f, err := LoadPath(path)
	if err != nil {
		t.Fatalf("load %s: %v", path, err)
	}
	// Load keeps a mount reference-preserving; resolve it in place so the
	// mounted content is part of what is compared.
	if err := ResolveSubsystemRefs(f, filepath.Dir(path)); err != nil {
		t.Fatalf("resolve mounts of %s: %v", path, err)
	}
	text, err := ToJSON(f)
	if err != nil {
		t.Fatalf("serialize %s: %v", path, err)
	}
	var doc any
	if err := json.Unmarshal([]byte(text), &doc); err != nil {
		t.Fatal(err)
	}
	// Go serializes a loaded document reference-preserving, so the resolved
	// content is compared through the flattened system.
	flat, err := Flatten(f)
	if err != nil {
		t.Fatalf("flatten %s: %v", path, err)
	}
	flatJSON, err := json.Marshal(flat)
	if err != nil {
		t.Fatal(err)
	}
	var flatDoc any
	if err := json.Unmarshal(flatJSON, &flatDoc); err != nil {
		t.Fatal(err)
	}
	return []any{blankRefs(doc), flatDoc}
}

func TestStdlibRefsConformance(t *testing.T) {
	dir := stdlibRefsDir(t)
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

// A document with no location of its own still reaches the library.
func TestStdlibRefFromStringWithNoBase(t *testing.T) {
	data, err := os.ReadFile(filepath.Join(stdlibRefsDir(t), "import_interp.esm"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := LoadString(string(data)); err != nil {
		t.Fatalf("load from string: %v", err)
	}
}

func TestClassifyStdRef(t *testing.T) {
	t.Setenv("ESM_STD_CLASSIFY", "esm:std/x.esm")
	cases := []struct {
		ref, base, identity string
		valid, isStd        bool
	}{
		{"esm:std/interp.esm", "/any", "esm:std/interp.esm", true, true},
		{"esm:std/./interp.esm", "/any", "esm:std/interp.esm", true, true},
		{"esm:std/../interp.esm", "/any", "esm:std/../interp.esm", false, true},
		{"esm:std/a/b.esm", "/any", "esm:std/a/b.esm", false, true},
		{"esm:other/x.esm", "/any", "esm:other/x.esm", false, true},
		{"${ESM_STD_CLASSIFY}", "/any", "esm:std/x.esm", true, true},
		{"calendar.esm", stdlibBaseDir, "esm:std/calendar.esm", true, true},
		{"./calendar.esm", stdlibBaseDir, "esm:std/calendar.esm", true, true},
		{"../x.esm", stdlibBaseDir, "esm:std/../x.esm", false, true},
		{"calendar.esm", "/any", "", false, false},
		{"https://example.com/x.esm", stdlibBaseDir, "", false, false},
	}
	for _, c := range cases {
		id, valid, isStd := classifyStdRef(c.ref, c.base)
		if id != c.identity || valid != c.valid || isStd != c.isStd {
			t.Errorf("classifyStdRef(%q, %q) = (%q, %v, %v); want (%q, %v, %v)",
				c.ref, c.base, id, valid, isStd, c.identity, c.valid, c.isStd)
		}
	}
}

// withStdlib substitutes the bundle for one test.
func withStdlib(t *testing.T, files map[string]string) {
	t.Helper()
	m := fstest.MapFS{}
	for name, text := range files {
		m[name] = &fstest.MapFile{Data: []byte(text)}
	}
	saved := stdlibFS
	stdlibFS = m
	t.Cleanup(func() { stdlibFS = saved })
}

func stdTemplateLib(name, importRef string) string {
	imports := ""
	if importRef != "" {
		imports = `"expression_template_imports": [{"ref": "` + importRef + `"}],`
	}
	return `{"esm": "1.1.0", "metadata": {"name": "` + name + `"}, ` + imports + `
  "expression_templates": {"` + name + `_twice": {"params": ["x"],
    "body": {"op": "*", "args": [2, "x"]}}}}`
}

const stdConsumer = `{"esm": "1.1.0", "metadata": {"name": "consumer"},
  "models": {"M": {
    "expression_template_imports": [{"ref": "esm:std/a.esm"}],
    "variables": {"x": {"type": "unknown", "units": "1", "default": 1.0},
                  "y": {"type": "unknown", "units": "1"}},
    "equations": [
      {"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": {"op": "-", "args": ["x"]}},
      {"lhs": "y", "rhs": {"op": "apply_expression_template", "args": [], "name": "b_twice",
        "bindings": {"x": "x"}}}]}}}`

func TestStdlibSiblingRefs(t *testing.T) {
	for _, ref := range []string{"b.esm", "./b.esm", "esm:std/b.esm"} {
		t.Run(ref, func(t *testing.T) {
			withStdlib(t, map[string]string{
				"a.esm": stdTemplateLib("a", ref),
				"b.esm": stdTemplateLib("b", ""),
			})
			if _, err := LoadString(stdConsumer); err != nil {
				t.Fatalf("sibling import %q: %v", ref, err)
			}
		})
	}
}

func TestStdlibRefLeavingTheBundleIsUnresolved(t *testing.T) {
	withStdlib(t, map[string]string{
		"a.esm": stdTemplateLib("a", "../b.esm"),
		"b.esm": stdTemplateLib("b", ""),
	})
	_, err := LoadString(stdConsumer)
	if code := stdErrCode(err); code != "template_import_unresolved" {
		t.Fatalf("code = %s; want template_import_unresolved", code)
	}
}

func TestStdlibRefCycleByIdentity(t *testing.T) {
	withStdlib(t, map[string]string{
		"a.esm": stdTemplateLib("a", "esm:std/b.esm"),
		"b.esm": stdTemplateLib("b", "./a.esm"),
	})
	_, err := LoadString(stdConsumer)
	if code := stdErrCode(err); code != "template_import_cycle" {
		t.Fatalf("code = %s; want template_import_cycle", code)
	}
}

func TestStdlibSubsystemMountsSibling(t *testing.T) {
	withStdlib(t, map[string]string{
		"outer.esm": `{"esm": "1.1.0", "metadata": {"name": "outer"},
  "models": {"Outer": {
    "subsystems": {"Inner": {"ref": "inner.esm"}},
    "variables": {"z": {"type": "unknown", "units": "1"}},
    "equations": [{"lhs": "z", "rhs": {"op": "*", "args": [2, "Inner.w"]}}]}}}`,
		"inner.esm": `{"esm": "1.1.0", "metadata": {"name": "inner"},
  "models": {"Inner": {
    "variables": {"w": {"type": "unknown", "units": "1", "default": 1.0}},
    "equations": [{"lhs": {"op": "D", "args": ["w"], "wrt": "t"}, "rhs": {"op": "-", "args": ["w"]}}]}}}`,
	})
	doc := `{"esm": "1.1.0", "metadata": {"name": "mounter"},
  "models": {"Top": {
    "subsystems": {"Outer": {"ref": "esm:std/outer.esm"}},
    "variables": {"q": {"type": "unknown", "units": "1"}},
    "equations": [{"lhs": "q", "rhs": "Outer.z"}]}}}`
	f, err := LoadString(doc)
	if err != nil {
		t.Fatalf("mount: %v", err)
	}
	if err := ResolveSubsystemRefs(f, ""); err != nil {
		t.Fatalf("resolve mounts: %v", err)
	}
	flat, err := Flatten(f)
	if err != nil {
		t.Fatalf("flatten: %v", err)
	}
	text, err := json.Marshal(flat)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(text), "Top.Outer.Inner.w") {
		t.Errorf("nested sibling mount not resolved: %s", text)
	}
}
