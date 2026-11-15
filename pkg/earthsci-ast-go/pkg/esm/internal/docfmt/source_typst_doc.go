package docfmt

// Typst documents: printing and parsing. Port of
// formal/Esm/Document/Source/TypstDoc.lean (Rust:
// document/source/typst_doc.rs); prefix `typDoc`. Composed exactly as the
// Markdown documents (source_markdown_doc.go).

import (
	"strings"
	"unicode/utf8"
)

// typDocTypOf is `Typ.typOf`: an equation's Typst math under the symbol table
// s.
func typDocTypOf(s *Sym, e *Eqn) []rune { return []rune(mathPrintTypst(s, eqnEqExpr(e))) }

// typDocPrT is `Typ.prT`: its `_comment` as a `//` comment line, then the
// equation.
func typDocPrT(s *Sym, e *Eqn) string {
	var b strings.Builder
	if e.HasComment {
		b.WriteString("// ")
		b.WriteString(e.Comment)
		b.WriteByte('\n')
	}
	b.WriteString(mathPrintTypst(s, eqnEqExpr(e)))
	return b.String()
}

// typDocOneT is `Typ.oneT`: one equation, or several rows separated by `\`
// with `&` alignment.
func typDocOneT(s *Sym, hasC bool, c string, body []rune) ([]Eqn, bool) {
	if j, ok := mathParseTypst(s, string(body)); ok {
		if l, r, ok := eqnEqSides(j); ok {
			return []Eqn{{HasComment: hasC, Comment: c, Lhs: l, Rhs: r}}, true
		}
	}
	ts, ok := typLex(body)
	if !ok {
		return nil, false
	}
	es, ok := mlCookRows(SfTypst, s, false, ts)
	if !ok {
		return nil, false
	}
	return mdDocWithComment(hasC, c, es), true
}

// typDocCkT is `Typ.ckT`: read the math text of a display equation.
func typDocCkT(s *Sym, raw string) ([]Eqn, bool) {
	cs := []rune(raw)
	if r, ok := cutPrefix(cs, "// "); ok {
		c, rest := textSplitLine(r)
		return typDocOneT(s, true, string(c), rest)
	}
	return typDocOneT(s, false, "", cs)
}

// typDocPrTx is `Typ.prTx`.
func typDocPrTx(s *Sym, m *MC) MR { return itemsPrMx(typDocPrT, mathPrintTypst, s, m) }

// typDocCkTx is `Typ.ckTx`.
func typDocCkTx(s *Sym, m *MR) ([]MC, bool) { return itemsCkMx(typDocCkT, mathParseTypst, s, m) }

// capsT is `Typ.capsT`: the Typst container's predicates.
type capsT struct{}

func (capsT) frontKey(k string) bool { return strBareKey(tdictReserved, k) }

func (capsT) desc(string) bool { return true }

func (capsT) compName(string) bool { return true }

func (capsT) declName(n string) bool {
	return exprNameOk(n) && !containsRune(stypNameTyp(n), '$')
}

func (capsT) attr(a KV) bool { return strBareKey(tdictReserved, a.K) }

func (capsT) eqn(s *Sym, e *Eqn) bool {
	t := typDocTypOf(s, e)
	if !mdDocCommentOk(e.HasComment, e.Comment) || containsRune(t, '$') || textPreS("//", t) {
		return false
	}
	_, _, _, ok := stypTmLexT([]rune(typDocPrT(s, e)))
	return !ok
}

func (capsT) rxn(s *Sym, x *Rxn[Json]) bool {
	return stypRxnOk(&Rxn[string]{
		ID: x.ID, HasSubs: x.HasSubs, Subs: x.Subs, HasProds: x.HasProds, Prods: x.Prods,
		Rate: mathPrintTypst(s, x.Rate), Attrs: x.Attrs,
	})
}

func (capsT) plot(a Obj) bool { return stypArgsOk(a) }

func (capsT) tm(s *Sym, t *Tm[Json]) bool {
	rt := Tm[string]{Name: t.Name, Params: t.Params, HasLhs: t.HasLhs, Body: mathPrintTypst(s, t.Body), Attrs: t.Attrs}
	if t.HasLhs {
		rt.Lhs = mathPrintTypst(s, t.Lhs)
	}
	return stypItemOk(&RItem{K: RITm, Tm: rt})
}

// typDocHeaderT is `Typ.headerT`.
func typDocHeaderT(front Obj) []rune {
	out := []rune(stypHeader)
	out = stypArgsFirstT(front, out)
	return append(out, ')', '\n')
}

// typDocCanonSegs is `Typ.canonSegs`: each construct after a blank line.
func typDocCanonSegs(its []RItem) []Seg {
	nl := []rune{'\n'}
	out := make([]Seg, 0, 2*len(its))
	for _, it := range its {
		block := stypIsBlock(&it)
		out = append(out, Seg{K: SegProse, Text: nl}, Seg{K: SegItem, Item: it})
		if !block {
			out = append(out, Seg{K: SegProse, Text: nl})
		}
	}
	return out
}

// typDocPrintTyp is `Typ.printTyp`: print a document as Typst.
func typDocPrintTyp(d Json) string {
	doc := skToDoc(capsT{}, d)
	out := typDocHeaderT(doc.Front)
	raw := itemsRawDoc(typDocPrTx, &doc)
	out = append(out, stypRender(typDocCanonSegs(itemsItems(&raw)))...)
	return string(out)
}

// typDocLexDoc is `Typ.lexDoc`: read the header and the constructs.
func typDocLexDoc(s []rune) (Obj, []RItem, bool) {
	if !textPreS(stypHeader, s) {
		return nil, nil, false
	}
	front, r, ok := stypPArgsFirst(s[utf8.RuneCountInString(stypHeader):])
	if !ok {
		return nil, nil, false
	}
	r1, ok := stypLineEnd(r)
	if !ok {
		return nil, nil, false
	}
	its, ok := stypLex(true, r1)
	if !ok {
		return nil, nil, false
	}
	return front, its, true
}

// typDocParseTyp is `Typ.parseTyp`: read a Typst document, after decodeText.
func typDocParseTyp(s string) (Json, bool) {
	front, its, ok := typDocLexDoc(linesDecodeText([]rune(s)))
	if !ok {
		return nil, false
	}
	return typDocParseItemsT(front, its)
}

// typDocParseItemsT is `Typ.parseItemsT`.
func typDocParseItemsT(front Obj, its []RItem) (Json, bool) {
	r, ok := itemsUnitems(front, its)
	if !ok {
		return nil, false
	}
	d, ok := itemsCookDoc(typDocCkTx, &r)
	if !ok {
		return nil, false
	}
	return skOfDoc(&d)
}
