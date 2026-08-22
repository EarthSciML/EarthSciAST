package esm

// The Go binding's public surface must equal the API manifest.
//
// api-surface.json at the repo root is the cross-language record of what every
// binding exports (see API_SPEC.md). This test pins the Go half: an exported
// package-level identifier the manifest does not list fails, and a Go name in
// the manifest that the package does not export fails too.
//
// Scope: package-level func / type / const / var. Methods on an exported type
// are covered by that type's manifest entry, not listed separately -- the
// manifest records the SYMBOLS a caller can name as esm.X, and a method is
// reachable only through its receiver.
//
// If this test fails you have changed the public API. That is allowed -- but
// regenerate the manifest in the same commit:
//
//	python3 scripts/gen-api-surface.py
//
// and then say in API_SPEC.md which tier the new symbol lands in.

import (
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

type apiManifest struct {
	Symbols []struct {
		Name     string                     `json:"name"`
		Kind     string                     `json:"kind"`
		Tier     string                     `json:"tier"`
		Bindings map[string]json.RawMessage `json:"bindings"`
	} `json:"symbols"`
}

// spellings decodes a binding entry, which is a string or -- when a binding
// exports aliases for one canonical symbol -- a list of strings.
func spellings(raw json.RawMessage) []string {
	var one string
	if err := json.Unmarshal(raw, &one); err == nil {
		return []string{one}
	}
	var many []string
	if err := json.Unmarshal(raw, &many); err == nil {
		return many
	}
	return nil
}

func loadAPIManifest(t *testing.T) apiManifest {
	t.Helper()
	// pkg/esm -> pkg -> earthsci-ast-go -> pkg -> repo root
	path := filepath.Join("..", "..", "..", "..", "api-surface.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading api-surface.json: %v", err)
	}
	var m apiManifest
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("parsing api-surface.json: %v", err)
	}
	if len(m.Symbols) == 0 {
		t.Fatal("api-surface.json declares no symbols")
	}
	return m
}

// exportedSurface walks the non-test files of this package and returns every
// exported package-level identifier, mapped to its declaration kind.
func exportedSurface(t *testing.T) map[string]string {
	t.Helper()
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, ".", func(fi os.FileInfo) bool {
		return !strings.HasSuffix(fi.Name(), "_test.go")
	}, 0)
	if err != nil {
		t.Fatalf("parsing package: %v", err)
	}

	surface := make(map[string]string)
	for _, p := range pkgs {
		if strings.HasSuffix(p.Name, "_test") {
			continue
		}
		for _, f := range p.Files {
			for _, decl := range f.Decls {
				switch d := decl.(type) {
				case *ast.FuncDecl:
					if !d.Name.IsExported() || d.Recv != nil {
						continue // methods belong to their receiver type's entry
					}
					surface[d.Name.Name] = "function"
				case *ast.GenDecl:
					for _, spec := range d.Specs {
						switch s := spec.(type) {
						case *ast.TypeSpec:
							if !s.Name.IsExported() {
								continue
							}
							kind := "type"
							if strings.HasSuffix(s.Name.Name, "Error") ||
								strings.HasSuffix(s.Name.Name, "Exception") {
								kind = "error"
							}
							surface[s.Name.Name] = kind
						case *ast.ValueSpec:
							for _, n := range s.Names {
								if !n.IsExported() {
									continue
								}
								kind := "constant"
								if d.Tok == token.VAR && strings.HasPrefix(n.Name, "Err") {
									kind = "error" // a sentinel error value
								}
								surface[n.Name] = kind
							}
						}
					}
				}
			}
		}
	}
	return surface
}

func declaredGoSurface(m apiManifest) map[string]string {
	declared := make(map[string]string)
	for _, sym := range m.Symbols {
		raw, ok := sym.Bindings["go"]
		if !ok {
			continue
		}
		for _, name := range spellings(raw) {
			declared[name] = sym.Kind
		}
	}
	return declared
}

func sortedAPINames(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func TestAPISurfaceExportsNothingUndeclared(t *testing.T) {
	declared := declaredGoSurface(loadAPIManifest(t))
	var extra []string
	for _, name := range sortedAPINames(exportedSurface(t)) {
		if _, ok := declared[name]; !ok {
			extra = append(extra, name)
		}
	}
	if len(extra) > 0 {
		t.Errorf("exported by package esm but absent from api-surface.json:\n  %s\n"+
			"Add them by re-running `python3 scripts/gen-api-surface.py`, then assign "+
			"each a tier in API_SPEC.md.", strings.Join(extra, "\n  "))
	}
}

func TestAPISurfaceExportsEverythingDeclared(t *testing.T) {
	surface := exportedSurface(t)
	declared := declaredGoSurface(loadAPIManifest(t))
	var missing []string
	for _, name := range sortedAPINames(declared) {
		if _, ok := surface[name]; !ok {
			missing = append(missing, name)
		}
	}
	if len(missing) > 0 {
		t.Errorf("declared for go in api-surface.json but not exported by package esm:\n  %s\n"+
			"Either restore the export or drop it from the manifest -- dropping a "+
			"`stable` symbol is a major-version break (API_SPEC.md §3).",
			strings.Join(missing, "\n  "))
	}
}

func TestAPISurfaceKindsMatch(t *testing.T) {
	surface := exportedSurface(t)
	declared := declaredGoSurface(loadAPIManifest(t))
	var mismatches []string
	for _, name := range sortedAPINames(declared) {
		got, ok := surface[name]
		if !ok {
			continue // reported by TestAPISurfaceExportsEverythingDeclared
		}
		if got != declared[name] {
			mismatches = append(mismatches,
				name+": manifest says "+declared[name]+", package declares "+got)
		}
	}
	if len(mismatches) > 0 {
		t.Errorf("kind mismatches vs api-surface.json:\n  %s", strings.Join(mismatches, "\n  "))
	}
}

func TestAPISurfaceIsNonTrivial(t *testing.T) {
	// Guard against the walk silently finding nothing and the whole suite
	// passing vacuously.
	if n := len(exportedSurface(t)); n < 100 {
		t.Fatalf("package walk found only %d exported identifiers; expected the full surface", n)
	}
}
