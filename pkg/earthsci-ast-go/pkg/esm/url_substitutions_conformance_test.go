package esm

// esm-spec §4.7 "Binding a data source's location at the mount", against the
// SHARED pin tests/conformance/url_substitutions/manifest.json.
//
// `cases` pin the edge rule as a document normalization: apply the edge with
// the mounting document's directory, then §8.2.1 resolution with the declaring
// document's. `fixtures` pin it through a real load: a mounted document's
// `data_sources` merge into the mounting document at both mount forms, so the
// root's `hoisted_sources` are checked, and `index_set_sizes` pins an edge's
// `bindings` reaching through an assembly.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

type usCase struct {
	ID               string         `json:"id"`
	BinderURL        string         `json:"binder_url"`
	URLTemplate      string         `json:"url_template"`
	Mirrors          []string       `json:"mirrors"`
	URLSubstitutions map[string]any `json:"url_substitutions"`
	Expect           struct {
		URLTemplate     *dsuPin  `json:"url_template"`
		Mirrors         []dsuPin `json:"mirrors"`
		ErrorCode       string   `json:"error_code"`
		MessageContains []string `json:"message_contains"`
	} `json:"expect"`
}

type usFixture struct {
	ID              string               `json:"id"`
	Path            string               `json:"path"`
	Expect          string               `json:"expect"`
	ErrorCode       string               `json:"error_code"`
	MessageContains []string             `json:"message_contains"`
	HoistedSources  map[string]dsuSource `json:"hoisted_sources"`
	IndexSetSizes   map[string]int64     `json:"index_set_sizes"`
}

type usManifest struct {
	DeclaringDir string      `json:"declaring_dir"`
	BinderDir    string      `json:"binder_dir"`
	Cases        []usCase    `json:"cases"`
	Fixtures     []usFixture `json:"fixtures"`
}

func usSuiteDir(t *testing.T) string {
	return filepath.Join(dsuRepoRoot(t), "tests", "conformance", "url_substitutions")
}

func usLoadManifest(t *testing.T) usManifest {
	t.Helper()
	p := filepath.Join(usSuiteDir(t), "manifest.json")
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("the shared pin %s must be readable: %v", p, err)
	}
	var m usManifest
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("manifest.json must be JSON: %v", err)
	}
	if len(m.Cases) == 0 || len(m.Fixtures) == 0 {
		t.Fatal("the shared manifest must carry cases and fixtures")
	}
	return m
}

// usExpected is dsuExpected with the manifest's stated `repo_path` convention:
// dot segments removed.
func usExpected(t *testing.T, pin dsuPin) string {
	t.Helper()
	if pin.Verbatim != "" {
		return pin.Verbatim
	}
	return "file://" + removeURLDotSegments(filepath.ToSlash(filepath.Join(dsuRepoRoot(t), pin.RepoPath)))
}

// usDiagnosticCode reads the stable code off a load error, whichever wrapper
// carries it.
func usAssertRefused(t *testing.T, id string, err error, code string, needles []string) {
	t.Helper()
	if err == nil {
		t.Fatalf("%s: must be refused with %s, was accepted", id, code)
	}
	msg := err.Error()
	if !strings.Contains(msg, "["+code+"]") {
		t.Errorf("%s: the diagnostic must carry [%s]; got: %s", id, code, msg)
	}
	for _, n := range needles {
		if !strings.Contains(msg, n) {
			t.Errorf("%s: the diagnostic must name %q; got: %s", id, n, msg)
		}
	}
}

func TestURLSubstitutionCasesMatchTheSharedManifest(t *testing.T) {
	m := usLoadManifest(t)
	root := dsuRepoRoot(t)
	declaring := filepath.Join(root, m.DeclaringDir)
	binder := filepath.Join(root, m.BinderDir)
	for _, c := range m.Cases {
		t.Run(c.ID, func(t *testing.T) {
			source := map[string]any{"url_template": c.URLTemplate}
			if c.Mirrors != nil {
				ms := make([]any, len(c.Mirrors))
				for i, s := range c.Mirrors {
					ms[i] = s
				}
				source["mirrors"] = ms
			}
			doc := map[string]any{"data_sources": map[string]any{
				"s": map[string]any{"kind": "static", "source": source},
			}}
			subs := map[string]any{}
			for k, v := range c.URLSubstitutions {
				subs[k] = v
			}
			caseBinder := binder
			if c.BinderURL != "" {
				caseBinder = c.BinderURL
			}
			err := applyMountURLSubstitutions(doc, subs, caseBinder, "case")
			// Then the declaring document's own §8.2.1 resolution.
			var gotTemplate string
			var gotMirrors []string
			if err == nil {
				gotTemplate, err = resolveSourceURL(source["url_template"].(string), declaring)
			}
			if err == nil {
				if ms, ok := source["mirrors"].([]any); ok {
					for _, mv := range ms {
						r, rerr := resolveSourceURL(mv.(string), declaring)
						if rerr != nil {
							err = rerr
							break
						}
						gotMirrors = append(gotMirrors, r)
					}
				}
			}
			if c.Expect.ErrorCode != "" {
				usAssertRefused(t, c.ID, err, c.Expect.ErrorCode, c.Expect.MessageContains)
				return
			}
			if err != nil {
				t.Fatalf("%s: %v", c.ID, err)
			}
			if c.Expect.URLTemplate == nil {
				t.Fatalf("%s: the case pins no url_template", c.ID)
			}
			if want := usExpected(t, *c.Expect.URLTemplate); gotTemplate != want {
				t.Errorf("url_template = %q, want %q", gotTemplate, want)
			}
			if c.Expect.Mirrors != nil {
				want := make([]string, len(c.Expect.Mirrors))
				for i, p := range c.Expect.Mirrors {
					want[i] = usExpected(t, p)
				}
				if !reflect.DeepEqual(gotMirrors, want) {
					t.Errorf("mirrors = %q, want %q", gotMirrors, want)
				}
			}
		})
	}
}

func TestURLSubstitutionFixturesMatchTheSharedManifest(t *testing.T) {
	m := usLoadManifest(t)
	for _, f := range m.Fixtures {
		t.Run(f.ID, func(t *testing.T) {
			file, err := LoadPath(filepath.Join(usSuiteDir(t), f.Path))
			switch f.Expect {
			case "accepted":
				if err != nil {
					t.Fatalf("%s must load: %v", f.ID, err)
				}
				if f.HoistedSources == nil {
					t.Fatalf("%s: an accepted fixture pins hoisted_sources", f.ID)
				}
				for name, pin := range f.HoistedSources {
					ds, ok := file.DataSources[name]
					if !ok {
						t.Errorf("data_sources.%s must be merged into the root", name)
						continue
					}
					if got, want := ds.Source.URLTemplate, usExpected(t, pin.URLTemplate); got != want {
						t.Errorf("data_sources.%s.source.url_template = %q, want %q", name, got, want)
					}
					if pin.Mirrors == nil {
						continue
					}
					want := make([]string, len(pin.Mirrors))
					for i, p := range pin.Mirrors {
						want[i] = usExpected(t, p)
					}
					if !reflect.DeepEqual(ds.Source.Mirrors, want) {
						t.Errorf("data_sources.%s.source.mirrors = %q, want %q", name, ds.Source.Mirrors, want)
					}
				}
				for axis, size := range f.IndexSetSizes {
					is, ok := file.IndexSets[axis]
					if !ok {
						t.Errorf("index_sets.%s must reach the root", axis)
						continue
					}
					b, _ := json.Marshal(is)
					var raw map[string]any
					_ = json.Unmarshal(b, &raw)
					if got, ok := raw["size"].(float64); !ok || int64(got) != size {
						t.Errorf("index_sets.%s.size = %v, want %d", axis, raw["size"], size)
					}
				}
			case "refused":
				usAssertRefused(t, f.ID, err, f.ErrorCode, f.MessageContains)
			default:
				t.Fatalf("%s: unknown expect %q", f.ID, f.Expect)
			}
		})
	}
}

// The manifest's code strings are this binding's constants.
func TestURLSubstitutionCodesAreRegistered(t *testing.T) {
	if codeURLSubstitutionUnknownName != "url_substitution_unknown_name" {
		t.Fatal("codeURLSubstitutionUnknownName drifted from esm-spec §9.6.6")
	}
}

func TestURLPlaceholdersAreBareIdentifiersOnly(t *testing.T) {
	names := func(s string) []string {
		var out []string
		for _, p := range urlPlaceholders(s) {
			out = append(out, p.name)
		}
		return out
	}
	if got := names("{a}/{b_1}/{date:%Y}/{1x}/{}/{a"); !reflect.DeepEqual(got, []string{"a", "b_1"}) {
		t.Errorf("got %q", got)
	}
	if got := names("x{snapshot}y"); !reflect.DeepEqual(got, []string{"snapshot"}) {
		t.Errorf("got %q", got)
	}
}

func TestAnEdgeWithoutURLSubstitutionsLeavesTheDocumentAlone(t *testing.T) {
	doc := map[string]any{"data_sources": map[string]any{
		"s": map[string]any{"source": map[string]any{"url_template": "{x}/t.nc"}},
	}}
	for _, raw := range []any{nil, map[string]any{}} {
		if err := applyMountURLSubstitutions(doc, raw, "/a", "e"); err != nil {
			t.Fatal(err)
		}
	}
	got := doc["data_sources"].(map[string]any)["s"].(map[string]any)["source"].(map[string]any)["url_template"]
	if got != "{x}/t.nc" {
		t.Errorf("url_template = %q", got)
	}
}

// A non-object map and a non-string value are `data_source_url_unresolved`.
func TestURLSubstitutionsMalformedValuesAreRefused(t *testing.T) {
	for _, raw := range []any{"snapshot", []any{"a"}, map[string]any{"snapshot": 3.0}} {
		doc := map[string]any{"data_sources": map[string]any{
			"s": map[string]any{"source": map[string]any{"url_template": "./{snapshot}/t.nc"}},
		}}
		err := applyMountURLSubstitutions(doc, raw, "/a", "e")
		usAssertRefused(t, "malformed", err, codeDataSourceURLUnresolved, nil)
	}
}

// RFC 3986 §5.2 against a URL-valued mounting directory: read as a directory
// with or without a trailing '/', dot segments removed, query/fragment dropped.
func TestJoinURLDirectory(t *testing.T) {
	for _, c := range []struct{ base, rel, want string }{
		{"https://example.org/models/runs", "../data/./b", "https://example.org/models/data/b"},
		{"https://example.org/models/runs/", "b", "https://example.org/models/runs/b"},
		{"https://example.org", "a/b", "https://example.org/a/b"},
		{"https://example.org/x?q=1#f", "../../y/", "https://example.org/y/"},
	} {
		if got := joinURLDirectory(c.base, c.rel); got != c.want {
			t.Errorf("joinURLDirectory(%q, %q) = %q, want %q", c.base, c.rel, got, c.want)
		}
	}
}
