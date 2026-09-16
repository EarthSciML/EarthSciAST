package esm

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// esm-spec §9.3: an `enum` op in a mounted file resolves against THAT file's
// `enums` block, at either §4.7 mount form, and `enums` do not merge across the
// mount. Issue #260; the fixtures are shared with the other four bindings.

var mountEnumsDir = filepath.Join("..", "..", "..", "..", "tests", "conformance", "mount_enums")

type mountEnumsExpected struct {
	Loads  map[string]map[string]int `json:"loads"`
	Errors map[string]string         `json:"errors"`
}

func readMountEnumsExpected(t *testing.T) mountEnumsExpected {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(mountEnumsDir, "expected.json"))
	if err != nil {
		t.Fatal(err)
	}
	var exp mountEnumsExpected
	if err := json.Unmarshal(b, &exp); err != nil {
		t.Fatal(err)
	}
	return exp
}

// mountEnumsRHS returns the right-hand side of the equation defining the
// variable at the end of path (model, then subsystem keys, then variable).
func mountEnumsRHS(t *testing.T, file *ESMFile, path string) map[string]any {
	t.Helper()
	parts := strings.Split(path, ".")
	b, err := json.Marshal(file.Models[parts[0]])
	if err != nil {
		t.Fatal(err)
	}
	var node map[string]any
	if err := json.Unmarshal(b, &node); err != nil {
		t.Fatal(err)
	}
	for _, sub := range parts[1 : len(parts)-1] {
		subs, _ := node["subsystems"].(map[string]any)
		node, _ = subs[sub].(map[string]any)
		if node == nil {
			t.Fatalf("%s: no subsystem %q", path, sub)
		}
	}
	eqs, _ := node["equations"].([]any)
	for _, raw := range eqs {
		eq, _ := raw.(map[string]any)
		if eq["lhs"] == parts[len(parts)-1] {
			rhs, _ := eq["rhs"].(map[string]any)
			return rhs
		}
	}
	t.Fatalf("%s: no defining equation", path)
	return nil
}

func TestMountEnums_ResolveAgainstTheMountedFilesOwnBlock(t *testing.T) {
	exp := readMountEnumsExpected(t)
	for fixture, values := range exp.Loads {
		t.Run(fixture, func(t *testing.T) {
			file, err := LoadPath(filepath.Join(mountEnumsDir, fixture))
			if err != nil {
				t.Fatalf("load: %v", err)
			}
			for path, want := range values {
				rhs := mountEnumsRHS(t, file, path)
				got, isNum := rhs["value"].(float64)
				if rhs["op"] != OpConst || !isNum || int(got) != want {
					t.Errorf("%s lowers to %v, want the constant %d", path, rhs, want)
				}
			}
		})
	}
}

func TestMountEnums_AssemblyDoesNotSeeALeafsBlock(t *testing.T) {
	exp := readMountEnumsExpected(t)
	for fixture, code := range exp.Errors {
		t.Run(fixture, func(t *testing.T) {
			_, err := LoadPath(filepath.Join(mountEnumsDir, fixture))
			if err == nil || !strings.Contains(err.Error(), "["+code+"]") {
				t.Fatalf("want [%s], got %v", code, err)
			}
		})
	}
}
