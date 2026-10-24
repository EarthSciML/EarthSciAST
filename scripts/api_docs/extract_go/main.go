// Command extract_go writes the normalized docstring file for the Go binding
// (docs/api/README.md §2): one entry per Go spelling that api-surface.json
// lists, with signatures and doc comments taken from pkg/esm through go/doc.
//
// It is its own module, so run it with -C; paths are relative to that
// directory unless absolute. scripts/api_docs/go.sh is the normal entry point:
//
//	go -C scripts/api_docs/extract_go run . -root "$PWD" -out "$PWD/build/api-docs/go.json"
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"go/ast"
	"go/build"
	"go/doc"
	"go/doc/comment"
	"go/parser"
	"go/printer"
	"go/token"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
)

const pkgDocsBase = "https://pkg.go.dev/"

type source struct {
	Path string `json:"path"`
	Line int    `json:"line"`
}

type symbol struct {
	Spelling   string   `json:"spelling"`
	Kind       string   `json:"kind"`
	Signatures []string `json:"signatures"`
	Doc        *string  `json:"doc"`
	Source     *source  `json:"source"`
	NativeURL  *string  `json:"native_url"`
	Missing    bool     `json:"missing,omitempty"`
}

type output struct {
	Binding        string   `json:"binding"`
	PackageVersion string   `json:"package_version"`
	Extractor      string   `json:"extractor"`
	Symbols        []symbol `json:"symbols"`
}

type manifest struct {
	BindingProfiles map[string]struct {
		Package string `json:"package"`
	} `json:"binding_profiles"`
	Symbols []struct {
		Name     string                     `json:"name"`
		Kind     string                     `json:"kind"`
		Bindings map[string]json.RawMessage `json:"bindings"`
	} `json:"symbols"`
}

// decl is one package-level declaration found by go/doc.
type decl struct {
	signatures []string
	doc        string // raw Go doc comment text
	pos        token.Pos
}

type extractor struct {
	root       string
	pkgDir     string
	importPath string
	fset       *token.FileSet
	pkg        *doc.Package
	parser     *comment.Parser
	decls      map[string]decl
	methodDocs map[string][]string // type name -> rendered method docs
}

func main() {
	root := flag.String("root", ".", "repository root")
	out := flag.String("out", "build/api-docs/go.json", "output path")
	flag.Parse()
	if err := run(*root, *out); err != nil {
		fmt.Fprintln(os.Stderr, "extract_go:", err)
		os.Exit(1)
	}
}

func readManifest(root string) (*manifest, error) {
	raw, err := os.ReadFile(filepath.Join(root, "api-surface.json"))
	if err != nil {
		return nil, err
	}
	var m manifest
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("api-surface.json: %w", err)
	}
	return &m, nil
}

func run(root, out string) error {
	root, err := filepath.Abs(root)
	if err != nil {
		return err
	}
	m, err := readManifest(root)
	if err != nil {
		return err
	}
	importPath := m.BindingProfiles["go"].Package
	const modulePath = "github.com/EarthSciML/EarthSciAST/"
	if !strings.HasPrefix(importPath, modulePath) {
		return fmt.Errorf("unexpected Go package path %q", importPath)
	}
	pkgDir := filepath.Join(root, filepath.FromSlash(strings.TrimPrefix(importPath, modulePath)))

	ex := &extractor{root: root, pkgDir: pkgDir, importPath: importPath, decls: map[string]decl{}, methodDocs: map[string][]string{}}
	if err := ex.load(); err != nil {
		return err
	}

	res := output{
		Binding:        "go",
		PackageVersion: ex.libraryVersion(),
		Extractor:      "go/doc " + runtime.Version(),
		Symbols:        []symbol{},
	}
	for _, s := range m.Symbols {
		raw, ok := s.Bindings["go"]
		if !ok {
			continue
		}
		// A binding's spelling is a string, or a list for an alias pair.
		var spellings []string
		if err := json.Unmarshal(raw, &spellings); err != nil {
			var one string
			if err := json.Unmarshal(raw, &one); err != nil {
				return fmt.Errorf("%s: go spelling: %w", s.Name, err)
			}
			spellings = []string{one}
		}
		for _, spelling := range spellings {
			res.Symbols = append(res.Symbols, ex.entry(spelling, s.Kind))
		}
	}
	sort.SliceStable(res.Symbols, func(i, j int) bool { return res.Symbols[i].Spelling < res.Symbols[j].Spelling })

	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		return err
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(res); err != nil {
		return err
	}
	return os.WriteFile(out, buf.Bytes(), 0o644)
}

// load parses the non-test Go files that build on the default context and
// indexes every exported package-level declaration by name.
func (ex *extractor) load() error {
	bp, err := build.Default.ImportDir(ex.pkgDir, 0)
	if err != nil {
		return err
	}
	ex.fset = token.NewFileSet()
	var files []*ast.File
	for _, name := range bp.GoFiles {
		f, err := parser.ParseFile(ex.fset, filepath.Join(ex.pkgDir, name), nil, parser.ParseComments)
		if err != nil {
			return err
		}
		files = append(files, f)
	}
	ex.pkg, err = doc.NewFromFiles(ex.fset, files, ex.importPath, doc.PreserveAST)
	if err != nil {
		return err
	}
	ex.parser = ex.pkg.Parser()

	addFuncs := func(fs []*doc.Func) {
		for _, f := range fs {
			ex.decls[f.Name] = decl{signatures: []string{ex.funcSig(f.Decl)}, doc: f.Doc, pos: f.Decl.Pos()}
		}
	}
	addValues := func(vs []*doc.Value, keyword string) {
		for _, v := range vs {
			ex.addValues(v, keyword)
		}
	}
	addFuncs(ex.pkg.Funcs)
	addValues(ex.pkg.Consts, "const")
	addValues(ex.pkg.Vars, "var")
	for _, t := range ex.pkg.Types {
		ex.addType(t)
		addFuncs(t.Funcs)
		addValues(t.Consts, "const")
		addValues(t.Vars, "var")
	}
	return nil
}

func (ex *extractor) node(n any) string {
	var buf bytes.Buffer
	cfg := printer.Config{Mode: printer.UseSpaces | printer.TabIndent, Tabwidth: 4}
	if err := cfg.Fprint(&buf, ex.fset, n); err != nil {
		panic(err)
	}
	return buf.String()
}

func (ex *extractor) funcSig(fd *ast.FuncDecl) string {
	cp := *fd
	cp.Doc, cp.Body = nil, nil
	return ex.node(&cp)
}

func (ex *extractor) addType(t *doc.Type) {
	var spec *ast.TypeSpec
	for _, s := range t.Decl.Specs {
		if ts, ok := s.(*ast.TypeSpec); ok && ts.Name.Name == t.Name {
			spec = ts
		}
	}
	if spec == nil {
		return
	}
	cp := *spec
	cp.Doc, cp.Comment = nil, nil
	sigs := []string{"type " + ex.node(&cp)}
	text := t.Doc
	var methods []string
	for _, m := range t.Methods {
		sig := ex.funcSig(m.Decl)
		sigs = append(sigs, sig)
		md := "```go\n" + sig + "\n```"
		if body := strings.TrimSpace(ex.markdown(m.Doc)); body != "" {
			md += "\n\n" + body
		}
		methods = append(methods, md)
	}
	d := decl{signatures: sigs, doc: text, pos: spec.Pos()}
	ex.decls[t.Name] = d
	if len(methods) > 0 {
		ex.methodDocs[t.Name] = methods
	}
}

func (ex *extractor) addValues(v *doc.Value, keyword string) {
	for _, s := range v.Decl.Specs {
		vs, ok := s.(*ast.ValueSpec)
		if !ok {
			continue
		}
		for i, n := range vs.Names {
			if !n.IsExported() {
				continue
			}
			sig := keyword + " " + n.Name
			if vs.Type != nil {
				sig += " " + ex.node(vs.Type)
			}
			if len(vs.Values) == len(vs.Names) {
				sig += " = " + ex.node(vs.Values[i])
			}
			// A value's own comment (leading, else trailing) comes first; the
			// enclosing group's comment describes the family it belongs to.
			var parts []string
			if vs.Doc != nil {
				parts = append(parts, vs.Doc.Text())
			} else if vs.Comment != nil {
				parts = append(parts, vs.Comment.Text())
			}
			if strings.TrimSpace(v.Doc) != "" {
				parts = append(parts, v.Doc)
			}
			ex.decls[n.Name] = decl{signatures: []string{sig}, doc: strings.Join(parts, "\n"), pos: n.Pos()}
		}
	}
}

func (ex *extractor) libraryVersion() string {
	for _, v := range ex.pkg.Consts {
		for _, s := range v.Decl.Specs {
			vs := s.(*ast.ValueSpec)
			for i, n := range vs.Names {
				if n.Name == "LibraryVersion" && i < len(vs.Values) {
					if lit, ok := vs.Values[i].(*ast.BasicLit); ok {
						if u, err := strconv.Unquote(lit.Value); err == nil {
							return u
						}
					}
				}
			}
		}
	}
	return ""
}

func (ex *extractor) entry(spelling, kind string) symbol {
	d, ok := ex.decls[spelling]
	if !ok {
		return symbol{Spelling: spelling, Kind: kind, Signatures: []string{}, Missing: true}
	}
	p := ex.fset.Position(d.pos)
	rel, err := filepath.Rel(ex.root, p.Filename)
	if err != nil {
		rel = p.Filename
	}
	url := pkgDocsBase + ex.importPath + "#" + spelling
	s := symbol{
		Spelling:   spelling,
		Kind:       kind,
		Signatures: d.signatures,
		Source:     &source{Path: filepath.ToSlash(rel), Line: p.Line},
		NativeURL:  &url,
	}
	body := strings.TrimSpace(ex.markdown(d.doc))
	if methods := ex.methodDocs[spelling]; len(methods) > 0 {
		if body != "" {
			body += "\n\n"
		}
		body += "**Methods**\n\n" + strings.Join(methods, "\n\n")
	}
	if body != "" {
		s.Doc = &body
	}
	return s
}
