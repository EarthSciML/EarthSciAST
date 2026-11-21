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
func typDocOneT(lim *Lim, s *Sym, hasC bool, c string, body []rune) ([]Eqn, bool) {
	if j, ok := mathParseTypst(lim, s, string(body)); ok {
		if l, r, ok := eqnEqSides(j); ok {
			return []Eqn{{HasComment: hasC, Comment: c, Lhs: l, Rhs: r}}, true
		}
	}
	ts, ok := typLex(lim, body)
	if !ok {
		return nil, false
	}
	es, ok := mlCookRows(lim, SfTypst, s, false, ts)
	if !ok {
		return nil, false
	}
	return mdDocWithComment(hasC, c, es), true
}

// typDocCkT is `Typ.ckT`: read the math text of a display equation.
func typDocCkT(lim *Lim, s *Sym, raw string) ([]Eqn, bool) {
	cs := []rune(raw)
	if r, ok := cutPrefix(cs, "// "); ok {
		c, rest := textSplitLine(r)
		return typDocOneT(lim, s, true, string(c), rest)
	}
	return typDocOneT(lim, s, false, "", cs)
}

// typDocPrTx is `Typ.prTx`.
func typDocPrTx(s *Sym, m *MC) MR { return itemsPrMx(typDocPrT, mathPrintTypst, s, m) }

// typDocCkTx is `Typ.ckTx`.
func typDocCkTx(lim *Lim, s *Sym, m *MR) ([]MC, bool) {
	return itemsCkMx(lim, typDocCkT, mathParseTypst, s, m)
}

// capsT is `Typ.capsT`: the Typst container's predicates.
type capsT struct{}

func (capsT) frontKey(k string) bool { return strBareKey(tdictReserved, k) }

func (capsT) desc(string) bool { return true }

func (capsT) compName(string) bool { return true }

func (capsT) declName(n string) bool {
	return exprNameOk(n) && !containsRune(stypNameTyp(n), '$')
}

func (capsT) attr(a KV) bool { return strBareKey(tdictReserved, a.K) }

func (capsT) eqn(lim *Lim, s *Sym, e *Eqn) bool {
	t := typDocTypOf(s, e)
	if !mdDocCommentOk(e.HasComment, e.Comment) || containsRune(t, '$') || textPreS("//", t) {
		return false
	}
	_, _, _, ok := stypTmLexT(lim, []rune(typDocPrT(s, e)))
	return !ok
}

func (capsT) rxn(s *Sym, x *Rxn[Json]) bool {
	return stypRxnOk(&Rxn[string]{
		ID: x.ID, HasSubs: x.HasSubs, Subs: x.Subs, HasProds: x.HasProds, Prods: x.Prods,
		Rate: mathPrintTypst(s, x.Rate), Attrs: x.Attrs,
	})
}

func (capsT) plot(a Obj) bool { return stypArgsOk(a) }

func (capsT) tm(lim *Lim, s *Sym, t *Tm[Json]) bool {
	rt := Tm[string]{Name: t.Name, Params: t.Params, HasLhs: t.HasLhs, Body: mathPrintTypst(s, t.Body), Attrs: t.Attrs}
	if t.HasLhs {
		rt.Lhs = mathPrintTypst(&Sym{Names: s.Names}, t.Lhs)
	}
	return stypItemOk(lim, &RItem{K: RITm, Tm: rt})
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
func typDocPrintTyp(lim *Lim, d Json) string {
	doc := skToDoc(lim, capsT{}, d)
	out := typDocHeaderT(doc.Front)
	r0 := itemsRawDoc(typDocPrTx, &doc)
	raw := itemsMathifyDoc(mathPrintTypst, &r0)
	out = append(out, stypRender(typDocCanonSegs(itemsItems(&raw)))...)
	return string(out)
}

// typDocLexDoc is `Typ.lexDoc`: read the header and the constructs.
func typDocLexDoc(lim *Lim, s []rune) (Obj, []RItem, bool) {
	if !textPreS(stypHeader, s) {
		return nil, nil, false
	}
	front, r, ok := stypPArgsFirst(lim, s[utf8.RuneCountInString(stypHeader):])
	if !ok {
		return nil, nil, false
	}
	r1, ok := stypLineEnd(r)
	if !ok {
		return nil, nil, false
	}
	its, ok := stypLex(lim, true, r1)
	if !ok {
		return nil, nil, false
	}
	return front, its, true
}

// typDocParseTyp is `Typ.parseTyp`: read a Typst document, after decodeText.
func typDocParseTyp(lim *Lim, s string) (Json, bool) {
	front, its, ok := typDocLexDoc(lim, linesDecodeText([]rune(s)))
	if !ok {
		return nil, false
	}
	return typDocParseItemsT(lim, front, its)
}

// typDocParseItemsT is `Typ.parseItemsT`.
func typDocParseItemsT(lim *Lim, front Obj, its []RItem) (Json, bool) {
	r, ok := itemsUnitems(front, its)
	if !ok {
		return nil, false
	}
	r1, ok := itemsCookDocBlocks(lim, mathParseTypst, &r)
	if !ok {
		return nil, false
	}
	d, ok := itemsCookDoc(lim, typDocCkTx, &r1)
	if !ok {
		return nil, false
	}
	return skOfDoc(&d)
}
