package esm

// Every diagnostic code this package raises is a registered one.
//
// The code strings are a cross-binding wire contract (esm-spec §9.6.6 calls
// the table "cross-language uniform"), and a code that reaches a raise site
// without a registry constant is exactly how one binding silently drifts from
// the others. This test reads the package's own source with go/parser and
// enforces three things:
//
//  1. A raise site never spells its code as a string literal. A raise site is
//     the first argument of a package constructor whose first parameter is
//     `code string` (newETErr, newClosedFunctionError, ...), a `Code:` /
//     `code:` field in a composite literal, or an assignment to a `.Code` /
//     `.code` field.
//  2. A constant named at a raise site is a registry constant: a package-level
//     string constant whose name begins with Code, code, Error or UnitFinding
//     (codes.go, plus the per-subsystem vocabularies its header lists).
//  3. Every code in the esm-spec §9.6.6 table is registered.
//
// A registry constant that nothing references is reported with t.Logf, not
// failed: CodeSubsystemIndexSetRenameUnsupportedMountForm is kept on purpose so
// the §9.6.6 table stays uniform even though Go never mounts the form that
// raises it.

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// specDiagnosticCodesExempt lists §9.6.6 codes no binding registers yet.
// `unevaluable_operator` is registered across the bindings by the issue #247
// work (branch claude/issue-247-unevaluable-operator); drop it from this set
// when that lands.
var specDiagnosticCodesExempt = map[string]bool{
	"unevaluable_operator": true,
}

var registryConstName = regexp.MustCompile(`^(Code|code|Error|UnitFinding)[A-Z]`)

type parsedPackage struct {
	fset  *token.FileSet
	files map[string]*ast.File
}

func parseEsmPackageSource(t *testing.T) parsedPackage {
	t.Helper()
	fset := token.NewFileSet()
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	files := map[string]*ast.File{}
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		f, err := parser.ParseFile(fset, name, nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", name, err)
		}
		files[name] = f
	}
	if len(files) == 0 {
		t.Fatal("no package source files found")
	}
	return parsedPackage{fset: fset, files: files}
}

// stringConsts maps every package-level constant with a string-literal value
// to that value.
func stringConsts(pkg parsedPackage) map[string]string {
	out := map[string]string{}
	for _, f := range pkg.files {
		for _, decl := range f.Decls {
			gd, ok := decl.(*ast.GenDecl)
			if !ok || gd.Tok != token.CONST {
				continue
			}
			for _, spec := range gd.Specs {
				vs := spec.(*ast.ValueSpec)
				for i, name := range vs.Names {
					if i >= len(vs.Values) {
						continue
					}
					if lit, ok := vs.Values[i].(*ast.BasicLit); ok && lit.Kind == token.STRING {
						if v, err := strconv.Unquote(lit.Value); err == nil {
							out[name.Name] = v
						}
					}
				}
			}
		}
	}
	return out
}

// codeConstructors returns the package functions whose first parameter is
// `code string`: every argument passed in that slot is a raised code.
func codeConstructors(pkg parsedPackage) map[string]bool {
	out := map[string]bool{}
	for _, f := range pkg.files {
		for _, decl := range f.Decls {
			fd, ok := decl.(*ast.FuncDecl)
			if !ok || fd.Recv != nil || fd.Type.Params == nil || len(fd.Type.Params.List) == 0 {
				continue
			}
			first := fd.Type.Params.List[0]
			typ, ok := first.Type.(*ast.Ident)
			if !ok || typ.Name != "string" || len(first.Names) == 0 || first.Names[0].Name != "code" {
				continue
			}
			out[fd.Name.Name] = true
		}
	}
	return out
}

func isCodeField(name string) bool { return name == "Code" || name == "code" }

// specDiagnosticCodes reads the code column of the esm-spec §9.6.6 table.
func specDiagnosticCodes(t *testing.T) []string {
	t.Helper()
	raw, err := os.ReadFile("../../../../esm-spec.md")
	if err != nil {
		t.Fatalf("read esm-spec.md: %v", err)
	}
	text := string(raw)
	start := strings.Index(text, "\n#### 9.6.6 ")
	if start < 0 {
		t.Fatal("esm-spec.md has no §9.6.6 heading")
	}
	section := text[start+1:]
	if end := strings.Index(section, "\n#### "); end >= 0 {
		section = section[:end]
	}
	row := regexp.MustCompile("(?m)^\\| `([a-z][a-z0-9_]*)` \\|")
	var codes []string
	for _, m := range row.FindAllStringSubmatch(section, -1) {
		codes = append(codes, m[1])
	}
	// Guard the extraction itself: a heading or table-layout change that
	// matched nothing would pass the membership check vacuously.
	if len(codes) < 30 {
		t.Fatalf("extracted only %d codes from the §9.6.6 table; the parser no longer matches the spec layout", len(codes))
	}
	return codes
}

func TestEveryRaisedDiagnosticCodeIsRegistered(t *testing.T) {
	pkg := parseEsmPackageSource(t)
	consts := stringConsts(pkg)
	registry := map[string]string{} // constant name -> code
	for name, value := range consts {
		if registryConstName.MatchString(name) {
			registry[name] = value
		}
	}
	constructors := codeConstructors(pkg)

	var violations []string
	checked := 0
	check := func(expr ast.Expr, context string) {
		pos := pkg.fset.Position(expr.Pos())
		where := pos.Filename + ":" + strconv.Itoa(pos.Line)
		switch e := expr.(type) {
		case *ast.BasicLit:
			if e.Kind != token.STRING {
				return
			}
			checked++
			violations = append(violations, where+": "+context+" raises the literal code "+e.Value+"; name a registry constant (codes.go) instead")
		case *ast.Ident:
			if _, isConst := consts[e.Name]; !isConst {
				return // a variable or parameter passing a code through
			}
			checked++
			if _, ok := registry[e.Name]; !ok {
				violations = append(violations, where+": "+context+" raises "+e.Name+", which is not a registry constant (Code*/Error*/UnitFinding*)")
			}
		}
	}

	for _, name := range registryKeysSorted(pkg.files) {
		ast.Inspect(pkg.files[name], func(n ast.Node) bool {
			switch node := n.(type) {
			case *ast.CallExpr:
				if fn, ok := node.Fun.(*ast.Ident); ok && constructors[fn.Name] && len(node.Args) > 0 {
					check(node.Args[0], fn.Name+"()")
				}
			case *ast.CompositeLit:
				for _, elt := range node.Elts {
					if kv, ok := elt.(*ast.KeyValueExpr); ok {
						if key, ok := kv.Key.(*ast.Ident); ok && isCodeField(key.Name) {
							check(kv.Value, key.Name+": field")
						}
					}
				}
			case *ast.AssignStmt:
				for i, lhs := range node.Lhs {
					if sel, ok := lhs.(*ast.SelectorExpr); ok && isCodeField(sel.Sel.Name) && i < len(node.Rhs) {
						check(node.Rhs[i], "."+sel.Sel.Name+" assignment")
					}
				}
			}
			return true
		})
	}

	// Guard the scan: a layout drift that matched no raise site would pass
	// vacuously.
	if checked < 100 {
		t.Fatalf("scanned only %d raise sites; the raise-site patterns no longer match the source", checked)
	}
	sort.Strings(violations)
	for _, v := range violations {
		t.Error(v)
	}

	registered := map[string]bool{}
	for _, value := range registry {
		registered[value] = true
	}
	for _, code := range specDiagnosticCodes(t) {
		if !registered[code] && !specDiagnosticCodesExempt[code] {
			t.Errorf("esm-spec §9.6.6 code %q has no registry constant in this binding", code)
		}
	}

	// Registered but never referenced: advisory only. The declaration itself
	// is one occurrence of the name, so a referenced constant occurs twice.
	occurrences := map[string]int{}
	for _, f := range pkg.files {
		ast.Inspect(f, func(n ast.Node) bool {
			if id, ok := n.(*ast.Ident); ok {
				occurrences[id.Name]++
			}
			return true
		})
	}
	for _, name := range registryKeysSorted(registry) {
		if occurrences[name] < 2 {
			t.Logf("warning: registry constant %s (%q) is never raised", name, registry[name])
		}
	}
}

func registryKeysSorted[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
