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

	"github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm/internal/unitspell"
)

func sym(names ...string) *Sym { return &Sym{Names: names} }

func ji(z int64) Json { return IntNum(z) }

func hw() *Sym { return sym("x", "k", "a", "T", "n", "N") }

func readsL(t *testing.T, sy *Sym, text string, e Json) {
	t.Helper()
	got, ok := mathParseLatex(&Lim{}, sy, text)
	if !ok || !JsonEqual(got, e) {
		t.Errorf("LaTeX %q: got %v (ok %v), want %s", text, renderOrNil(got, ok), ok, Render(e))
	}
}

func readsT(t *testing.T, sy *Sym, text string, e Json) {
	t.Helper()
	got, ok := mathParseTypst(&Lim{}, sy, text)
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
	if _, ok := mathParseLatex(&Lim{}, sdx1, "\\frac{dx}{dt}"); ok {
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

func TestHandWrittenArrayNotation(t *testing.T) {
	sy := hw()
	// A bare `\operatorname{n}` is a template applied with no bindings; with
	// `()` it is an open operator with no operands.
	readsL(t, sy, "\\operatorname{dlon}", psTNode("dlon", Obj{}))
	readsL(t, sy, "\\operatorname{dlon}()", prNode("dlon", []Json{}))
	readsT(t, sy, "op(\"dlon\")", psTNode("dlon", Obj{}))
	readsT(t, sy, "op(\"dlon\")()", prNode("dlon", []Json{}))
	// `\times [` outside a region is still a product with a bracket group.
	prod := prNode("*", []Json{"a", prNode("+", []Json{"x", ji(1)})})
	readsL(t, sy, "a \\times [x + 1]", prod)
	readsL(t, sy, "a \\times[x + 1]", prod)
	readsT(t, sy, "a times [x + 1]", prod)
	// A makearray table, the region product spaced any way.
	table := prMkJson(MkForm{
		regions: [][]Pair{{{ji(1), "N"}}, {{ji(1), ji(1)}, {ji(2), ji(2)}}},
		values:  []Json{"x", ji(0)},
	})
	readsL(t, sy, "\\left[\\begin{array}{l|l} x & [1, N] \\\\ 0 & [1, 1]\\times[2, 2] \\end{array}\\right]", table)
	readsT(t, sy, "mat(delim: \"[\", augment: #1, x, [1, N]; 0, [1, 1] times [2, 2])", table)
	readsL(t, sy, mathPrintLatex(sy, table), table)
	readsT(t, sy, mathPrintTypst(sy, table), table)
	// A lone equality filter followed by a superscript set is the filter,
	// not a dense range.
	filtSet := Obj{{"args", []Json{"a"}}, {"expr", "x"}, {"filter", prNode("==", []Json{"k", ji(1)})},
		{"op", "faq"}, {"output_idx", []Json{}}}
	readsL(t, sy, "\\sum_{k = 1}^{\\{a\\}} x", filtSet)
	readsL(t, sy, mathPrintLatex(sy, filtSet), filtSet)
}

func refusedL(t *testing.T, sy *Sym, text string) {
	t.Helper()
	if got, ok := mathParseLatex(&Lim{}, sy, text); ok {
		t.Errorf("LaTeX %q: read as %s, want refused", text, Render(got))
	}
}

func refusedT(t *testing.T, sy *Sym, text string) {
	t.Helper()
	if got, ok := mathParseTypst(&Lim{}, sy, text); ok {
		t.Errorf("Typst %q: read as %s, want refused", text, Render(got))
	}
}

// roundTrips checks that e prints and reads back in both surfaces, and
// returns the LaTeX and Typst spellings.
func roundTrips(t *testing.T, sy *Sym, e Json) (string, string) {
	t.Helper()
	l, ty := mathPrintLatex(sy, e), mathPrintTypst(sy, e)
	readsL(t, sy, l, e)
	readsT(t, sy, ty, e)
	return l, ty
}

func TestMarkedReductionSetRefused(t *testing.T) {
	sy := sym("x", "i", "a", "N")
	marked := Obj{{"args", []Json{"x"}}, {"expr", prNode("index", []Json{"x", "i"})},
		{"op", "faq"}, {"output_idx", []Json{}}, {"ranges", Obj{{"i", []Json{ji(1), "N"}}}}}
	markedOut := Obj{{"args", []Json{"x"}}, {"expr", prNode("index", []Json{"x", "i"})},
		{"op", "faq"}, {"output_idx", []Json{"i"}}, {"ranges", Obj{{"i", []Json{ji(1), "N"}}}}}
	// rank 0: `\limits` with a superscript set
	readsL(t, sy, "\\sum\\limits_{1 \\le i \\le N} x_{i}", marked)
	refusedL(t, sy, "\\sum\\limits_{1 \\le i \\le N}^{\\{a\\}} x_{i}")
	readsT(t, sy, "limits(sum)_(1 <= i <= N) x_i", marked)
	refusedT(t, sy, "limits(sum)_(1 <= i <= N)^({a}) x_i")
	// the plain head keeps its set
	set := Obj{{"args", []Json{"a"}}, {"expr", prNode("index", []Json{"x", "i"})},
		{"op", "faq"}, {"output_idx", []Json{}}, {"ranges", Obj{{"i", []Json{ji(1), "N"}}}}}
	l, ty := roundTrips(t, sy, set)
	if !strings.Contains(l, "^{\\{a\\}}") || !strings.Contains(ty, "^({a})") {
		t.Errorf("set not printed: %s | %s", l, ty)
	}
	// output form: a set on the bracket of a marked head
	readsL(t, sy, "\\left[\\sum\\limits_{1 \\le i \\le N} x_{i}\\right]_{i}", markedOut)
	refusedL(t, sy, "\\left[\\sum\\limits_{1 \\le i \\le N} x_{i}\\right]^{\\{a\\}}_{i}")
	readsT(t, sy, "lr([limits(sum)_(1 <= i <= N) x_i])_(i)", markedOut)
	refusedT(t, sy, "lr([limits(sum)_(1 <= i <= N) x_i])^({a})_(i)")
}

func TestOutputFormSetOnBracketOnly(t *testing.T) {
	sy := sym("x", "i", "j", "a", "b", "N")
	e := Obj{{"args", []Json{"a"}}, {"expr", prNode("index", []Json{"x", "i", "j"})},
		{"op", "faq"}, {"output_idx", []Json{"i"}},
		{"ranges", Obj{{"i", []Json{ji(1), "N"}}, {"j", []Json{ji(1), "N"}}}}}
	l, ty := roundTrips(t, sy, e)
	// the printer writes the set on the bracket
	if !strings.Contains(l, "\\right]^{\\{a\\}}") || !strings.Contains(ty, "])^({a})") {
		t.Fatalf("set not on the bracket: %s | %s", l, ty)
	}
	// the same set on the reduction inside the bracket is refused, with or
	// without a bracket set
	inner := strings.Replace(l, "\\right]^{\\{a\\}}", "\\right]", 1)
	inner = strings.Replace(inner, "x_{i, j}", "^{\\{a\\}} x_{i, j}", 1)
	if inner == l {
		t.Fatalf("test rewrite failed: %s", l)
	}
	refusedL(t, sy, inner)
	both := strings.Replace(inner, "\\right]", "\\right]^{\\{b\\}}", 1)
	refusedL(t, sy, both)
	innerT := strings.Replace(ty, "])^({a})", "])", 1)
	innerT = strings.Replace(innerT, "x_(i, j)", "^({a}) x_(i, j)", 1)
	if innerT == ty {
		t.Fatalf("test rewrite failed: %s", ty)
	}
	refusedT(t, sy, innerT)
}

func TestDelimAugmentAreWords(t *testing.T) {
	sy := sym("x", "t", "delim", "augment")
	readsT(t, sy, "x = delim + 1", prNode("==", []Json{"x", prNode("+", []Json{"delim", ji(1)})}))
	readsT(t, sy, "augment dot delim", prNode("*", []Json{"augment", "delim"}))
	roundTrips(t, sy, prNode("+", []Json{"delim", "augment"}))
	roundTrips(t, sy, Obj{{"args", []Json{"augment"}}, {"op", "D"}, {"wrt", "t"}})
	// the makearray table head still prints and reads
	table := prMkJson(MkForm{regions: [][]Pair{{{ji(1), ji(2)}}}, values: []Json{"delim"}})
	_, ty := roundTrips(t, sy, table)
	if ty != "mat(delim: \"[\", augment: #1, italic(\"delim\"), [1, 2])" {
		t.Errorf("table: %s", ty)
	}
}

func TestCallFormCanonicalOnly(t *testing.T) {
	sy := sym("x", "y")
	// an annotation field sends the node to the escape form
	refusedL(t, sy, "\\operatorname{broadcast}(x; \\mathrm{id} = \\text{\"s\"}, \\mathrm{fn} = \\text{\"+\"})")
	refusedT(t, sy, "op(\"broadcast\")(x; upright(\"expect_cadence\") = #\"daily\")")
	// a core operator without a call form
	refusedL(t, sy, "\\operatorname{index}(x; \\mathrm{a} = 1)")
	// a const with a native spelling prints natively
	refusedL(t, sy, "\\operatorname{const}(; \\mathrm{value} = [1, 2])")
	refusedT(t, sy, "op(\"const\")(; upright(\"value\") = #(1, 2))")
	// a faq with a native spelling prints natively
	faq := Obj{{"args", []Json{}}, {"expr", "x"}, {"op", "faq"}, {"output_idx", []Json{}}}
	if l := mathPrintLatex(sy, faq); strings.Contains(l, "operatorname") {
		t.Fatalf("faq printed in the call form: %s", l)
	}
	refusedL(t, sy, "\\operatorname{faq}(; \\mathrm{expr} = x, \\mathrm{output\\_idx} = [])")
	// repeated keys, or a key `op` / `args`, are refused
	refusedL(t, sy, "\\operatorname{foo}(x; \\mathrm{k} = 1, \\mathrm{k} = 2)")
	refusedL(t, sy, "\\operatorname{foo}(x; \\mathrm{op} = \\text{\"bar\"})")
	refusedL(t, sy, "\\operatorname{foo}(x; \\mathrm{args} = [1])")
	refusedT(t, sy, "op(\"foo\")(x; upright(\"k\") = 1, upright(\"k\") = 2)")
	// an open operator keeps its annotation fields in the call form
	ann := prMkNode("foo", []Json{"x"}, Obj{{"id", "a"}})
	l, _ := roundTrips(t, sy, ann)
	if !strings.HasPrefix(l, "\\operatorname{foo}(x;") {
		t.Errorf("annotated open operator: %s", l)
	}
	readsL(t, sy, "\\operatorname{foo}(x; \\mathrm{id} = a)", ann)
	// what the printer writes in the call form still reads
	open := prMkNode("foo", []Json{"x"}, Obj{{"k", ji(1)}})
	l, _ = roundTrips(t, sy, open)
	if !strings.HasPrefix(l, "\\operatorname{foo}(") {
		t.Errorf("open operator: %s", l)
	}
	bc := prMkNode("broadcast", []Json{"x", "y"}, Obj{{"fn", "+"}})
	l, _ = roundTrips(t, sy, bc)
	if !strings.HasPrefix(l, "\\operatorname{broadcast}(") {
		t.Errorf("broadcast: %s", l)
	}
}

func TestBareTemplateName(t *testing.T) {
	none := sym("x")
	zero := &Sym{Names: []string{"x"}, Templates: []TemplateParams{{Name: "g"}}}
	one := &Sym{Names: []string{"x"}, Templates: []TemplateParams{{Name: "g", Params: []string{"p"}}}}
	bare := psTNode("g", Obj{})
	// out of scope, or in scope with parameters: bare
	for _, sy := range []*Sym{none, one} {
		l, ty := roundTrips(t, sy, bare)
		if l != "\\operatorname{g}" || ty != "op(\"g\")" {
			t.Errorf("bare: %s | %s", l, ty)
		}
		readsL(t, sy, "\\operatorname{g} + x", prNode("+", []Json{bare, "x"}))
	}
	// in scope with no parameters: the printer writes `g()`, so bare is refused
	l, ty := roundTrips(t, zero, bare)
	if l != "\\operatorname{g}()" || ty != "op(\"g\")()" {
		t.Errorf("zero-parameter: %s | %s", l, ty)
	}
	refusedL(t, zero, "\\operatorname{g}")
	refusedL(t, zero, "\\operatorname{g} + x")
	refusedT(t, zero, "op(\"g\")")
}

func TestRegionTimesIsTwoTokens(t *testing.T) {
	sy := sym("x", "a", "N")
	toks, ok := latexLex([]rune("[1, 1] \\times [2, 2]"))
	if !ok || len(toks) < 7 || !toks[5].isKw(KwTimes) || !toks[6].isKw(KwLbk) {
		t.Fatalf("lex: %v %v", toks, ok)
	}
	table := prMkJson(MkForm{
		regions: [][]Pair{{{ji(1), "N"}, {ji(1), ji(2)}}, {{ji(1), ji(1)}, {ji(2), ji(2)}}},
		values:  []Json{"x", prNode("*", []Json{"a", ji(2)})},
	})
	l, ty := roundTrips(t, sy, table)
	if !strings.Contains(l, "[1, N] \\times [1, 2]") || !strings.Contains(ty, "[1, N] times [1, 2]") {
		t.Errorf("region spacing: %s | %s", l, ty)
	}
	// inside a region `\times [` continues the region, also after a value
	// that is a product
	readsL(t, sy, "\\left[\\begin{array}{l|l} x & [1, N] \\times [1, 2] \\\\ a \\times 2 & [1, 1] \\times [2, 2] \\end{array}\\right]", table)
	// outside a region it is a product with a bracket group
	prod := prNode("*", []Json{"a", prNode("+", []Json{"x", ji(1)})})
	readsL(t, sy, "a \\times [x + 1]", prod)
	readsT(t, sy, "a times [x + 1]", prod)
	roundTrips(t, sy, prod)
}

func TestWideConstMatrix(t *testing.T) {
	sy := sym("x")
	mat := func(cols int) Json {
		rows := make([]Json, 2)
		for i := range rows {
			r := make([]Json, cols)
			for j := range r {
				r[j] = ji(int64(i*cols + j + 1))
			}
			rows[i] = r
		}
		return Obj{{"args", []Json{}}, {"op", "const"}, {"value", rows}}
	}
	l, _ := roundTrips(t, sy, mat(11))
	want := "\\left[\\begin{array}{ccccccccccc}1 & 2 & 3 & 4 & 5 & 6 & 7 & 8 & 9 & 10 & 11 \\\\ " +
		"12 & 13 & 14 & 15 & 16 & 17 & 18 & 19 & 20 & 21 & 22 \\end{array}\\right]"
	if l != want {
		t.Errorf("wide matrix:\n got %s\nwant %s", l, want)
	}
	l10, _ := roundTrips(t, sy, mat(10))
	if !strings.HasPrefix(l10, "\\begin{bmatrix}") {
		t.Errorf("10 columns: %s", l10)
	}
	col := Obj{{"args", []Json{}}, {"op", "const"}, {"value", []Json{ji(1), ji(2), ji(3), ji(4), ji(5), ji(6), ji(7), ji(8), ji(9), ji(10), ji(11), ji(12)}}}
	lc, _ := roundTrips(t, sy, col)
	if !strings.HasPrefix(lc, "\\begin{bmatrix}") {
		t.Errorf("column: %s", lc)
	}
	// a bmatrix wider than 10 columns, a column count that disagrees with the
	// rows, and an array of at most 10 columns are refused
	refusedL(t, sy, "\\begin{bmatrix}1 & 2 & 3 & 4 & 5 & 6 & 7 & 8 & 9 & 10 & 11\\end{bmatrix}")
	refusedL(t, sy, "\\left[\\begin{array}{cccccccccccc}1 & 2 & 3 & 4 & 5 & 6 & 7 & 8 & 9 & 10 & 11 \\end{array}\\right]")
	refusedL(t, sy, "\\left[\\begin{array}{cc}1 & 2 \\end{array}\\right]")
	// a wide matrix with units
	withU := Obj{{"args", []Json{}}, {"op", "const"}, {"units", "m"}, {"value", mat(11).(Obj)[2].V}}
	roundTrips(t, sy, withU)
}

func TestUnitsLatexAndTypstRoundTrip(t *testing.T) {
	f := func(s string, p, q int64) Factor { return Factor{Sym: s, Exp: big.NewRat(p, q)} }
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
		if l := prFactorsOf(u); len(l) == 0 || unitspell.Spell(l) != u {
			t.Errorf("%s: %v", u, l)
		}
	}
	// Any spelling the binding's unit parser reads gives its normalized list.
	for u, want := range map[string]string{"m s^-1": "m/s", "W/m²": "W/m^2", "(mol/m^3)^(1/2)*m": "m*mol^(1/2)/m^(3/2)", "kg·m/s/s": "kg*m/s^2"} {
		if got := unitspell.Spell(prFactorsOf(u)); got != want {
			t.Errorf("%s: %s, want %s", u, got, want)
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
	// The definition blocks, `operators` (or the old `expression_templates`).
	var templates []TemplateParams
	for _, k := range []string{"operators", "expression_templates"} {
		templates = append(templates, templatesOf(doc[k])...)
		templates = append(templates, templatesOf(c[k])...)
	}
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
			if got, ok := mathParseLatex(&Lim{}, sy, lx); !ok || !JsonEqual(got, e) {
				t.Errorf("%s: parse_latex %s\n  got %s", id, lx, renderOrNil(got, ok))
			}
			if pt := mathPrintTypst(sy, e); pt != ty {
				t.Errorf("%s: print_typst\n  got  %s\n  want %s", id, pt, ty)
			}
			if got, ok := mathParseTypst(&Lim{}, sy, ty); !ok || !JsonEqual(got, e) {
				t.Errorf("%s: parse_typst %s\n  got %s", id, ty, renderOrNil(got, ok))
			}
		}
	}
	if n < 79 {
		t.Errorf("only %d math cases found", n)
	}
}
