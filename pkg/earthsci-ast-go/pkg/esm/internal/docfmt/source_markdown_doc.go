package docfmt

// Markdown documents: printing and parsing. Port of
// formal/Esm/Document/Source/MarkdownDoc.lean (Rust:
// document/source/markdown_doc.rs); prefix `mdDoc`.
//
// The layers compose: the skeleton (skToDoc / skOfDoc), the math entries as
// LaTeX (itemsRawDoc / itemsCookDoc), the construct sequence (itemsItems /
// itemsUnitems), and the text (front matter, then the constructs separated by
// blank lines).

import "strings"

// ## Equations in LaTeX

// mdDocLatexOf is `Md.latexOf`: an equation's LaTeX under the symbol table s.
func mdDocLatexOf(s *Sym, e *Eqn) []rune { return []rune(mathPrintLatex(s, eqnEqExpr(e))) }

// mdDocPrMd is `Md.prMd`: an equation's math text: its `_comment` as a LaTeX
// comment line, then the equation.
func mdDocPrMd(s *Sym, e *Eqn) string {
	var b strings.Builder
	if e.HasComment {
		b.WriteString("% ")
		b.WriteString(e.Comment)
		b.WriteByte('\n')
	}
	b.WriteString(mathPrintLatex(s, eqnEqExpr(e)))
	return b.String()
}

// mdDocEnv is one multi-line environment: its name and whether all rows are
// one equation.
type mdDocEnv struct {
	open, close []rune
	one         bool
}

// mdDocEnvs is `Md.envs`: the multi-line environments.
var mdDocEnvs = func() []mdDocEnv {
	var out []mdDocEnv
	for _, e := range []struct {
		name string
		one  bool
	}{
		{"aligned", false}, {"align", false}, {"align*", false}, {"gathered", false},
		{"split", true}, {"multline", true}, {"multline*", true},
	} {
		out = append(out, mdDocEnv{[]rune("\\begin{" + e.name + "}"), []rune("\\end{" + e.name + "}"), e.one})
	}
	return out
}()

// mdDocIsWsC is `Md.isWsC`.
func mdDocIsWsC(c rune) bool { return c == ' ' || c == '\n' || c == '\t' }

// mdDocEnvOf is `Md.envOf`: a display that is one multi-line environment:
// whether its rows are one equation, and the environment's body.
func mdDocEnvOf(body []rune) (bool, []rune, bool) {
	start := 0
	for start < len(body) && mdDocIsWsC(body[start]) {
		start++
	}
	b := body[start:]
	end := len(b)
	for end > 0 && mdDocIsWsC(b[end-1]) {
		end--
	}
	b = b[:end]
	for _, e := range mdDocEnvs {
		if textPre(e.open, b) && len(b) >= len(e.close) && runesEqual(b[len(b)-len(e.close):], e.close) {
			n := len(b) - (len(e.open) + len(e.close))
			if n < 0 {
				n = 0
			}
			rest := b[len(e.open):]
			if n > len(rest) {
				n = len(rest)
			}
			return e.one, rest[:n], true
		}
	}
	return false, nil, false
}

// mdDocWithComment is `Md.withComment`: the comment goes to the first
// equation of a display.
func mdDocWithComment(has bool, c string, es []Eqn) []Eqn {
	if len(es) > 0 {
		es[0].HasComment, es[0].Comment = has, c
	}
	return es
}

// mdDocOneMd is `Md.oneMd`: one display in LaTeX: a multi-line environment,
// or one equation.
func mdDocOneMd(lim *Lim, s *Sym, hasC bool, c string, body []rune) ([]Eqn, bool) {
	if one, inner, ok := mdDocEnvOf(body); ok {
		ts, ok := latexLex(inner)
		if !ok {
			return nil, false
		}
		es, ok := mlCookRows(lim, SfLatex, s, one, ts)
		if !ok {
			return nil, false
		}
		return mdDocWithComment(hasC, c, es), true
	}
	j, ok := mathParseLatex(lim, s, string(body))
	if !ok {
		return nil, false
	}
	l, r, ok := eqnEqSides(j)
	if !ok {
		return nil, false
	}
	return []Eqn{{HasComment: hasC, Comment: c, Lhs: l, Rhs: r}}, true
}

// mdDocCkMd is `Md.ckMd`: read the math text of a display equation: an
// optional leading comment line `% …`, then the equation.
func mdDocCkMd(lim *Lim, s *Sym, raw string) ([]Eqn, bool) {
	cs := []rune(raw)
	if r, ok := cutPrefix(cs, "% "); ok {
		c, rest := textSplitLine(r)
		return mdDocOneMd(lim, s, true, string(c), rest)
	}
	return mdDocOneMd(lim, s, false, "", cs)
}

// mdDocPrMdx is `Md.prMdx`: a math entry's text.
func mdDocPrMdx(s *Sym, m *MC) MR { return itemsPrMx(mdDocPrMd, mathPrintLatex, s, m) }

// mdDocCkMdx is `Md.ckMdx`: read a math entry's text.
func mdDocCkMdx(lim *Lim, s *Sym, m *MR) ([]MC, bool) {
	return itemsCkMx(lim, mdDocCkMd, mathParseLatex, s, m)
}

// mdDocCommentOk is `Md.commentOK`.
func mdDocCommentOk(has bool, c string) bool {
	return !has || !strings.ContainsAny(c, "\n$")
}

// ## What Markdown spells natively

// mdDocDqOk is `Md.dqOK`: a string whose characters the YAML printer writes
// as themselves and without `&`; any other value.
func mdDocDqOk(v Json) bool {
	s, ok := v.(string)
	if !ok {
		return true
	}
	var e []rune
	for _, c := range s {
		e = strEscChar(false, c, e[:0])
		if len(e) != 1 || e[0] != c || c == '&' {
			return false
		}
	}
	return true
}

// capsMd is `Md.capsMd`: the Markdown container's predicates.
type capsMd struct{}

var mdDocDescStops = [][]rune{[]rune("```"), []rune(" ```"), []rune("  ```"), []rune("   ```")}

func (capsMd) frontKey(string) bool { return true }

func (capsMd) desc(s string) bool {
	t := withNl(s)
	for _, stop := range mdDocDescStops {
		if !textNoStop(stop, t) {
			return false
		}
	}
	return !strings.ContainsRune(s, '\r')
}

func (capsMd) compName(n string) bool { return !strings.ContainsAny(n, "]\n") }

func (capsMd) declName(n string) bool {
	return exprNameOk(n) && !containsRune(mdNameLatex(n), '$') && !strings.ContainsAny(n, "]\n")
}

func (capsMd) attr(a KV) bool { return strIsIdent([]rune(a.K)) && mdDocDqOk(a.V) }

func (capsMd) eqn(lim *Lim, s *Sym, e *Eqn) bool {
	l := mdDocLatexOf(s, e)
	if !mdDocCommentOk(e.HasComment, e.Comment) || containsRune(l, '$') || containsRune(l, '\n') ||
		(len(l) > 0 && l[0] == '%') {
		return false
	}
	if _, _, ok := mdDocEnvOf(l); ok {
		return false
	}
	_, ok := mdTmLex(lim, []rune(mdDocPrMd(s, e)))
	return !ok
}

func (capsMd) rxn(s *Sym, x *Rxn[Json]) bool {
	return mdRxnOk(&Rxn[string]{
		ID: x.ID, HasSubs: x.HasSubs, Subs: x.Subs, HasProds: x.HasProds, Prods: x.Prods,
		Rate: mathPrintLatex(s, x.Rate), Attrs: x.Attrs,
	})
}

func (capsMd) plot(a Obj) bool {
	for _, kv := range a {
		if !mdAttrOk(kv) || !mdDocDqOk(kv.V) {
			return false
		}
	}
	return true
}

func (capsMd) tm(lim *Lim, s *Sym, t *Tm[Json]) bool {
	rt := Tm[string]{Name: t.Name, Params: t.Params, HasLhs: t.HasLhs, Body: mathPrintLatex(s, t.Body), Attrs: t.Attrs}
	if t.HasLhs {
		rt.Lhs = mathPrintLatex(&Sym{Names: s.Names}, t.Lhs)
	}
	if !mdItemOk(lim, &RItem{K: RITm, Tm: rt}) {
		return false
	}
	for _, kv := range t.Attrs {
		if !mdDocDqOk(kv.V) {
			return false
		}
	}
	return true
}

// mdDocFrontMd is `Md.frontMd`: the front matter.
func mdDocFrontMd(front Obj) []rune {
	out := []rune(mdDashes)
	out = append(out, '\n')
	out = append(out, yamlEncode(append(Obj{}, front...))...)
	out = pushS(out, mdDashes)
	return append(out, '\n')
}

// mdDocCanonSegs is `Md.canonSegs`: each construct after a blank line, a
// declaration on a line of its own.
func mdDocCanonSegs(its []RItem) []Seg {
	nl := []rune{'\n'}
	out := make([]Seg, 0, 2*len(its))
	for _, it := range its {
		block := mdIsBlock(&it)
		out = append(out, Seg{K: SegProse, Text: nl}, Seg{K: SegItem, Item: it})
		if !block {
			out = append(out, Seg{K: SegProse, Text: nl})
		}
	}
	return out
}

// mdDocPrintMd is `Md.printMd`: print a document as Markdown.
func mdDocPrintMd(lim *Lim, d Json) string {
	doc := skToDoc(lim, capsMd{}, d)
	out := mdDocFrontMd(doc.Front)
	r0 := itemsRawDoc(mdDocPrMdx, &doc)
	raw := itemsMathifyDoc(mathPrintLatex, &r0)
	out = append(out, mdRender(mdDocCanonSegs(itemsItems(&raw)))...)
	return string(out)
}

// mdDocLexDoc is `Md.lexDoc`: read the front matter and the constructs.
func mdDocLexDoc(lim *Lim, s []rune) (Obj, []RItem, bool) {
	r, ok := cutPrefix(s, "---\n")
	if !ok {
		return nil, nil, false
	}
	body, sl, rest, ok := textUntilStop([]rune(mdDashes), r)
	if !ok || !textBlank(sl) {
		return nil, nil, false
	}
	v, ok := yamlDecode(lim, body)
	kvs, isObj := v.(Obj)
	if !ok || !isObj {
		return nil, nil, false
	}
	its, ok := mdLex(lim, true, rest)
	if !ok {
		return nil, nil, false
	}
	return kvs, its, true
}

// mdDocParseMd is `Md.parseMd`: read a Markdown document, after decodeText.
func mdDocParseMd(lim *Lim, s string) (Json, bool) {
	front, its, ok := mdDocLexDoc(lim, linesDecodeText([]rune(s)))
	if !ok {
		return nil, false
	}
	return mdDocParseItemsMd(lim, front, its)
}

// mdDocParseItemsMd is `Md.parseItemsMd`.
func mdDocParseItemsMd(lim *Lim, front Obj, its []RItem) (Json, bool) {
	r, ok := itemsUnitems(front, its)
	if !ok {
		return nil, false
	}
	r1, ok := itemsCookDocBlocks(lim, mathParseLatex, &r)
	if !ok {
		return nil, false
	}
	d, ok := itemsCookDoc(lim, mdDocCkMdx, &r1)
	if !ok {
		return nil, false
	}
	return skOfDoc(&d)
}
