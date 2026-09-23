package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// esm-spec §4.7 "Working precision crosses a mount" (CONFORMANCE_SPEC
// §5.18.2b): a mounted document's `domain.element_type` does not merge, so the
// mount edge writes it onto the variables of the component it splices in
// whenever it differs from the mounting document's effective precision. The
// fixtures are shared with the other four bindings. This binding has no
// numeric evaluator, so it asserts the loader contract (`loads`,
// `load_errors`) only.

var mountElementTypeDir = filepath.Join("..", "..", "..", "..", "tests", "conformance", "mount_element_type")

type mountElementTypeExpected struct {
	Loads map[string]struct {
		DomainElementType *string            `json:"domain_element_type"`
		ElementTypes      map[string]*string `json:"element_types"`
	} `json:"loads"`
	LoadErrors map[string]string `json:"load_errors"`
}

func readMountElementTypeExpected(t *testing.T) mountElementTypeExpected {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(mountElementTypeDir, "expected.json"))
	if err != nil {
		t.Fatal(err)
	}
	var exp mountElementTypeExpected
	if err := json.Unmarshal(b, &exp); err != nil {
		t.Fatal(err)
	}
	return exp
}

// carriedElementTypes maps every variable (subsystems as `Model.Sub.var`) of an
// emitted document to its `element_type`, nil for none.
func carriedElementTypes(doc map[string]any) map[string]*string {
	out := map[string]*string{}
	var walk func(prefix string, system map[string]any)
	walk = func(prefix string, system map[string]any) {
		vars, _ := system["variables"].(map[string]any)
		for name, raw := range vars {
			decl, _ := raw.(map[string]any)
			if et, ok := decl["element_type"].(string); ok {
				out[prefix+"."+name] = &et
			} else {
				out[prefix+"."+name] = nil
			}
		}
		subs, _ := system["subsystems"].(map[string]any)
		for key, sub := range subs {
			if m, ok := sub.(map[string]any); ok {
				walk(prefix+"."+key, m)
			}
		}
	}
	models, _ := doc["models"].(map[string]any)
	for name, raw := range models {
		if m, ok := raw.(map[string]any); ok {
			walk(name, m)
		}
	}
	return out
}

func emittedDocument(t *testing.T, file *ESMFile) map[string]any {
	t.Helper()
	text, err := ToJSON(file)
	if err != nil {
		t.Fatalf("emit: %v", err)
	}
	var doc map[string]any
	if err := json.Unmarshal([]byte(text), &doc); err != nil {
		t.Fatal(err)
	}
	return doc
}

func show(m map[string]*string) map[string]string {
	out := map[string]string{}
	for k, v := range m {
		if v == nil {
			out[k] = "<none>"
		} else {
			out[k] = *v
		}
	}
	return out
}

func TestMountElementType_WritesExactlyTheLeafsDifferingPrecision(t *testing.T) {
	exp := readMountElementTypeExpected(t)
	for fixture, want := range exp.Loads {
		t.Run(fixture, func(t *testing.T) {
			file, err := LoadPath(filepath.Join(mountElementTypeDir, fixture))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			doc := emittedDocument(t, file)
			var domain *string
			if d, ok := doc["domain"].(map[string]any); ok {
				if et, ok := d["element_type"].(string); ok {
					domain = &et
				}
			}
			if (domain == nil) != (want.DomainElementType == nil) ||
				(domain != nil && *domain != *want.DomainElementType) {
				t.Errorf("domain.element_type = %v, want %v", domain, want.DomainElementType)
			}
			got := show(carriedElementTypes(doc))
			if !reflect.DeepEqual(got, show(want.ElementTypes)) {
				t.Errorf("element types after load:\n got %v\nwant %v", got, show(want.ElementTypes))
			}
			// load -> emit -> load is a fixed point on the written fields.
			text, _ := ToJSON(file)
			again, err := LoadString(text)
			if err != nil {
				t.Fatalf("reload: %v", err)
			}
			if twice := show(carriedElementTypes(emittedDocument(t, again))); !reflect.DeepEqual(twice, got) {
				t.Errorf("round trip changed the written fields:\n got %v\nwant %v", twice, got)
			}
		})
	}
}

func TestMountElementType_AReactionSystemCannotCarryIt(t *testing.T) {
	exp := readMountElementTypeExpected(t)
	for fixture, code := range exp.LoadErrors {
		t.Run(fixture, func(t *testing.T) {
			_, err := LoadPath(filepath.Join(mountElementTypeDir, fixture))
			if err == nil || !strings.Contains(err.Error(), "["+code+"]") {
				t.Fatalf("want [%s], got %v", code, err)
			}
		})
	}
}
