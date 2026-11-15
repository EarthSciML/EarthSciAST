package docfmt

// Tests of the math layer: the checks of HandWritten.lean, and the math of
// every expression case of the document-format golden set (Rust:
// document/math/tests.rs, and the unit tests of units.rs).

import (
	"bytes"
	"encoding/json"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func sym(names ...string) *Sym { return &Sym{Names: names} }

func ji(z int64) Json { return IntNum(z) }

func hw() *Sym { return sym("x", "k", "a", "T", "n", "N") }

func readsL(t *testing.T, sy *Sym, text string, e Json) {
	t.Helper()
	got, ok := mathParseLatex(sy, text)
	if !ok || !JsonEqual(got, e) {
		t.Errorf("LaTeX %q: got %v (ok %v), want %s", text, renderOrNil(got, ok), ok, Render(e))
	}
}

func readsT(t *testing.T, sy *Sym, text string, e Json) {
	t.Helper()
	got, ok := mathParseTypst(sy, text)
	if !ok || !JsonEqual(got, e) {
		t.Errorf("Typst %q: got %v (ok %v), want %s", text, renderOrNil(got, ok), ok, Render(e))
	}
}

func renderOrNil(j Json, ok bool) string {
	if !ok {
		return "<refused>"
	}
	return Render(j)
}

func TestHandWrittenMinusAndNegativeLiterals(t *testing.T) {
	sy := hw()
	x, k, a := "x", "k", "a"
	xm1 := prNode("-", []Json{x, ji(1)})
	readsL(t, sy, "x-1", xm1)
	readsL(t, sy, "x - 1", xm1)
	readsL(t, sy, "x -1", xm1)
	readsL(t, sy, "-1", ji(-1))
	readsL(t, sy, "2-x", prNode("-", []Json{ji(2), x}))
	readsL(t, sy, "k-1-x", prNode("-", []Json{prNode("-", []Json{k, ji(1)}), x}))
	readsL(t, sy, "a \\cdot -1", prNode("*", []Json{a, ji(-1)}))
	readsL(t, sy, "a\\cdot-1", prNode("*", []Json{a, ji(-1)}))
	readsL(t, sy, "x^{-1}", prNode("^", []Json{x, ji(-1)}))
	readsL(t, sy, "x = -1", prNode("==", []Json{x, ji(-1)}))
	readsL(t, sy, "k-2x", prNode("-", []Json{k, prNode("*", []Json{ji(2), x})}))
	readsL(t, sy, "k-0", prNode("-", []Json{k, ji(0)}))

	readsT(t, sy, "x-1", xm1)
	readsT(t, sy, "x - 1", xm1)
	readsT(t, sy, "-1", ji(-1))
	readsT(t, sy, "2-x", prNode("-", []Json{ji(2), x}))
	readsT(t, sy, "a dot -1", prNode("*", []Json{a, ji(-1)}))
	readsT(t, sy, "x^(-1)", prNode("^", []Json{x, ji(-1)}))
}

func TestHandWrittenScientificLiterals(t *testing.T) {
	sy := hw()
	th := ji(2000)
	tiny := JNum{Dec: true, Digits: []byte{1, 5}, E10: -12}
	for _, s := range []string{
		"2 \\times 10^{3}", "2\\times 10^{3}", "2\\times10^{3}", "2  \\times  10^{3}",
		"2 \\times 10 ^ { 3 }",
	} {
		readsL(t, sy, s, th)
	}
	readsL(t, sy, "1.5\\times 10^{-12}", tiny)
	readsL(t, sy, "1.5 \\times 10^{-12}", tiny)
	p := prNode("*", []Json{ji(3), prNode("^", []Json{ji(10), "n"})})
	readsL(t, sy, "3 \\times 10^{n}", p)
	for _, s := range []string{"2 times 10^3", "2times 10^3", "2 times 10^( 3 )"} {
		readsT(t, sy, s, th)
	}
	readsT(t, sy, "1.5 times 10^(-12)", tiny)
	readsT(t, sy, "1.5times 10 ^ (-12)", tiny)
	readsT(t, sy, "3 times 10^n", p)
}

func TestHandWrittenThinSpace(t *testing.T) {
	sy := hw()
	meters := Obj{{"args", []Json{}}, {"op", "const"}, {"units", "m"}, {"value", ji(3)}}
	readsL(t, sy, "3\\,\\mathrm{m}", meters)
	readsL(t, sy, "3 \\, \\mathrm{m}", meters)
	readsL(t, sy, "k\\,T", prNode("*", []Json{"k", "T"}))
	readsL(t, sy, "k \\, T", prNode("*", []Json{"k", "T"}))
	readsT(t, sy, "3 thin upright(\"m\")", meters)
}

func TestHandWrittenItalicD(t *testing.T) {
	sd := sym("x")
	sdx := sym("x", "dx", "dt")
	sdx1 := sym("x", "dx")
	dx := psDNode("x", "t")
	readsL(t, sd, "\\frac{dx}{dt}", dx)
	readsL(t, sd, "\\frac{d x}{d t}", dx)
	readsT(t, sd, "(d x)/(d t)", dx)
	q := prNode("/", []Json{"dx", "dt"})
	readsL(t, sdx, "\\frac{dx}{dt}", q)
	readsT(t, sdx, "(dx)/(dt)", q)
	if _, ok := mathParseLatex(sdx1, "\\frac{dx}{dt}"); ok {
		t.Errorf("\\frac{dx}{dt} with dx but not dt declared must be refused")
	}
}

func TestHandWrittenFieldKeys(t *testing.T) {
	sy := hw()
	if r := string(latexRender(prKeyToks(SfLatex, "a%b$"))); r != "\\mathrm{a{\\char037}b{\\char036}}" {
		t.Errorf("key: %s", r)
	}
	readsL(t, sy, "\\operatorname{foo}(x; \\mathrm{a{\\char037}b} = 1)",
		prMkNode("foo", []Json{"x"}, Obj{{"a%b", ji(1)}}))
	odd := Obj{{"a%b$", ji(1)}, {"args", []Json{"x"}}, {"op", "foo"}}
	p := mathPrintLatex(sy, odd)
	if strings.ContainsAny(p, "%$") {
		t.Errorf("unescaped: %s", p)
	}
	readsL(t, sy, p, odd)
}

func TestHandWrittenJsonStrings(t *testing.T) {
	sy := hw()
	strOp := prMkNode("myop", []Json{"k"}, Obj{{"s", "a{b}"}})
	if got := mathPrintLatex(sy, strOp); got != "\\operatorname{myop}(k; \\mathrm{s} = \\text{\"a\\{b\\}\"})" {
		t.Errorf("print: %s", got)
	}
	readsL(t, sy, mathPrintLatex(sy, strOp), strOp)
	odd := prMkNode("myop", []Json{"k"}, Obj{{"s", "x$%é\n\"_~\\ 中"}})
	want := "\\operatorname{myop}(k; \\mathrm{s} = \\text{\"x{\\char036}{\\char037}{\\char233}{\\char010}\"\\_{\\char126}{\\char092} {\\char0020013}\"})"
	if got := mathPrintLatex(sy, odd); got != want {
		t.Errorf("print:\n got  %s\n want %s", got, want)
	}
	readsL(t, sy, mathPrintLatex(sy, odd), odd)
	readsL(t, sy, "\\operatorname{myop}(k; \\mathrm{s} = \"a\\u007Bb\\u007D\")", strOp)
}

func TestUnitsLatexAndTypstRoundTrip(t *testing.T) {
	f := func(s string, p, q int64) Factor { return Factor{s, big.NewRat(p, q)} }
	l := []Factor{f("cm", 3, 1), f("short_ton", 1, 3), f("K", -1, 1), f("mol", -1, 2)}
	if lx := string(unitsLatex(l)); lx != "\\mathrm{cm^{3}\\,short\\_ton^{1/3}/(K\\,mol^{1/2})}" {
		t.Errorf("latex: %s", lx)
	}
	if back, ok := unitsParseLatex(unitsLatex(l)); !ok || !factorsEqual(back, l) {
		t.Errorf("latex round trip")
	}
	ty := string(unitsTypst(l))
	if ty != "upright(\"cm\")^3 thin upright(\"short_ton\")^(1\\/3) thin upright(\"K\")^(-1) thin upright(\"mol\")^(-1\\/2)" {
		t.Errorf("typst: %s", ty)
	}
	if back, ok := unitsParseTypst(unitsTypst(l)); !ok || !factorsEqual(back, l) {
		t.Errorf("typst round trip")
	}
	if back, ok := unitsParseTypst([]rune("1")); !ok || len(back) != 0 {
		t.Errorf("typst 1")
	}
}

func TestFactorsOfCanonicalSpellings(t *testing.T) {
	for _, u := range []string{"m", "mol/(m^3*s)", "1/s", "kg*m^2/s^2", "m^(1/2)", "%", "K^(3/2)/(m*s)"} {
		if l := prFactorsOf(u); len(l) == 0 || prSpellUnitFactors(l) != u {
			t.Errorf("%s: %v", u, l)
		}
	}
	for _, u := range []string{"m*m", "s*m", "1", "", "dimensionless", "m/1", "m s"} {
		if prUnitsOk(SfLatex, u) || prUnitsOk(SfTypst, u) {
			t.Errorf("%s must not print typeset", u)
		}
	}
}

// ## The golden set

func fixtureDir() string {
	return filepath.Join("..", "..", "..", "..", "..", "..", "tests", "conformance", "document_format")
}

func decodeJSON(t *testing.T, b []byte) any {
	t.Helper()
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		t.Fatal(err)
	}
	return v
}

func keysOf(v any) []string {
	m, _ := v.(map[string]any)
	var out []string
	for k := range m {
		out = append(out, k)
	}
	return out
}

func templatesOf(v any) []TemplateParams {
	m, _ := v.(map[string]any)
	var out []TemplateParams
	for k, tv := range m {
		tm, ok := tv.(map[string]any)
		if !ok {
			continue
		}
		var ps []string
		if xs, ok := tm["params"].([]any); ok {
			for _, x := range xs {
				if s, ok := x.(string); ok {
					ps = append(ps, s)
				}
			}
		}
		out = append(out, TemplateParams{k, ps})
	}
	return out
}

// component is the symbol table of the one component of a fixture document
// and its one equation, as Source.symFor and Source.eqExpr build them.
func component(t *testing.T, doc map[string]any) (*Sym, Json) {
	var comps []map[string]any
	for _, k := range []string{"models", "reaction_systems"} {
		if m, ok := doc[k].(map[string]any); ok {
			for _, c := range m {
				comps = append(comps, c.(map[string]any))
			}
		}
	}
	if len(comps) != 1 {
		t.Fatalf("%d components", len(comps))
	}
	c := comps[0]
	var names []string
	names = append(names, keysOf(c["variables"])...)
	names = append(names, keysOf(c["species"])...)
	names = append(names, keysOf(c["parameters"])...)
	names = append(names, keysOf(doc["index_sets"])...)
	templates := append(templatesOf(doc["expression_templates"]), templatesOf(c["expression_templates"])...)
	eq := c["equations"].([]any)[0].(map[string]any)
	e := Obj{{"args", []Json{FromGo(eq["lhs"]), FromGo(eq["rhs"])}}, {"op", "=="}}
	return &Sym{Names: names, Templates: templates}, e
}

func TestGoldenSetMath(t *testing.T) {
	n := 0
	for _, file := range []string{"operators", "names", "units"} {
		b, err := os.ReadFile(filepath.Join(fixtureDir(), file+".json"))
		if err != nil {
			t.Fatal(err)
		}
		v := decodeJSON(t, b).(map[string]any)
		for _, cv := range v["cases"].([]any) {
			cs := cv.(map[string]any)
			m, ok := cs["math"].(map[string]any)
			if !ok {
				continue
			}
			n++
			id := cs["id"].(string)
			sy, e := component(t, cs["esm"].(map[string]any))
			lx, ty := m["latex"].(string), m["typst"].(string)
			if pl := mathPrintLatex(sy, e); pl != lx {
				t.Errorf("%s: print_latex\n  got  %s\n  want %s", id, pl, lx)
			}
			if got, ok := mathParseLatex(sy, lx); !ok || !JsonEqual(got, e) {
				t.Errorf("%s: parse_latex %s\n  got %s", id, lx, renderOrNil(got, ok))
			}
			if pt := mathPrintTypst(sy, e); pt != ty {
				t.Errorf("%s: print_typst\n  got  %s\n  want %s", id, pt, ty)
			}
			if got, ok := mathParseTypst(sy, ty); !ok || !JsonEqual(got, e) {
				t.Errorf("%s: parse_typst %s\n  got %s", id, ty, renderOrNil(got, ok))
			}
		}
	}
	if n < 79 {
		t.Errorf("only %d math cases found", n)
	}
}
