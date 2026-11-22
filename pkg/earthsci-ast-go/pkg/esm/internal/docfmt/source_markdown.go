package docfmt

// The Markdown container: CommonMark with `$…$` / `$$…$$` LaTeX math, fenced
// blocks, YAML front matter and remark directives. Port of
// formal/Esm/Document/Source/Markdown.lean, namespace `Source.Md` (Rust:
// document/source/markdown.rs); prefix `md`.
//
// The lexer reads a construct where one starts and otherwise drops one
// character of prose; a code span is skipped whole. The Lean fuel is dropped:
// every step consumes a character.

import (
	"strings"
	"unicode/utf8"
)

// ## Spellings

const (
	mdFenceEsm = "```esm:"
	mdFence    = "```"
	mdDD       = "$$"
	mdDModel   = "::model["
	mdDRs      = "::reaction-system["
	mdDashes   = "---"
	mdDescInfo = "description"
	mdDPlot    = "::plot{"
	mdDRxn     = "$$\\ce{"
	mdDInit    = ":::initialization"
	mdDCons    = ":::constraints"
	mdDEnd     = ":::"
	mdDSub     = "::subsystem["
)

var (
	mdFenceR = []rune(mdFence)
	mdDDR    = []rune(mdDD)
)

// mdDRole is `Md.dRole`.
func mdDRole(r Role) string {
	switch r {
	case RoleInit:
		return mdDInit
	case RoleCons:
		return mdDCons
	}
	return mdDEnd
}

// mdDkw is `Md.dkw`: the directive keyword of a declaration.
func mdDkw(k DKind) string {
	switch k {
	case DKParam:
		return "param"
	case DKSpecies:
		return "species"
	case DKSub:
		return "subsystem"
	}
	return "var"
}

func pushS(out []rune, s string) []rune {
	for _, c := range s {
		out = append(out, c)
	}
	return out
}

// ## Path-block keys

// mdEscKey is `Md.escKey`: the JSON escape, and the backtick as `.
func mdEscKey(c rune, out []rune) []rune {
	if c == '`' {
		out = append(out, '\\', 'u')
		return append(out, strHex4(uint32(c))...)
	}
	return strEscChar(false, c, out)
}

// mdKeyMd is `Md.keyMd`: a path block's key in the fence's info string.
func mdKeyMd(k string) []rune {
	kc := []rune(k)
	if strIsIdent(kc) && k != mdDescInfo {
		return kc
	}
	out := []rune{'"'}
	for _, c := range kc {
		out = mdEscKey(c, out)
	}
	return append(out, '"')
}

// mdParseKeyMd is `Md.parseKeyMd`: a path block's key from the whole info
// string.
func mdParseKeyMd(info []rune) (string, bool) {
	if len(info) > 0 && info[0] == '"' {
		k, r, ok := strParseQuoted(false, info)
		if ok && len(r) == 0 {
			return k, true
		}
		return "", false
	}
	if strIsIdent(info) && string(info) != mdDescInfo {
		return string(info), true
	}
	return "", false
}

// ## Declarations

// mdNameLatex is `Md.nameLatex`: a declared name as LaTeX math under the empty
// symbol table.
func mdNameLatex(n string) []rune { return []rune(mathPrintLatex(symEmpty, n)) }

// ## Attribute values: YAML scalars and flow collections

// mdFlow is `Md.flow`: a value as a YAML scalar or flow collection.
func mdFlow(v Json, out []rune) []rune {
	switch x := v.(type) {
	case []Json:
		if len(x) > 0 {
			out = append(out, '[')
			for i, e := range x {
				if i > 0 {
					out = append(out, ',', ' ')
				}
				out = mdFlow(e, out)
			}
			return append(out, ']')
		}
	case Obj:
		if len(x) > 0 {
			out = append(out, '{')
			for i, kv := range x {
				if i > 0 {
					out = append(out, ',', ' ')
				}
				out = append(out, strPrintKey(false, yamlReserved, kv.K)...)
				out = append(out, ':', ' ')
				out = mdFlow(kv.V, out)
			}
			return append(out, '}')
		}
	}
	return append(out, yamlInline(v)...)
}

// mdPFlow is `Md.pFlow`: a flow collection at `[` or `{`, else a scalar.
func mdPFlow(lim *Lim, s []rune) (Json, []rune, bool) {
	if !lim.enter() {
		return nil, nil, false
	}
	defer lim.leave()
	if len(s) == 0 {
		return nil, nil, false
	}
	switch s[0] {
	case '[':
		r := s[1:]
		if len(r) > 0 && r[0] == ']' {
			return []Json{}, r[1:], true
		}
		x, r1, ok := mdPFlow(lim, r)
		if !ok {
			return nil, nil, false
		}
		xs, r2, ok := mdPItemsF(lim, r1)
		if !ok {
			return nil, nil, false
		}
		return append([]Json{x}, xs...), r2, true
	case '{':
		r := s[1:]
		if len(r) > 0 && r[0] == '}' {
			return Obj{}, r[1:], true
		}
		e, r1, ok := mdPEntryF(lim, r)
		if !ok {
			return nil, nil, false
		}
		es, r2, ok := mdPEntriesF(lim, r1)
		if !ok {
			return nil, nil, false
		}
		return append(Obj{e}, es...), r2, true
	}
	return yamlPInline(s)
}

// mdPItemsF is `Md.pItemsF`: the elements after the first, each after `, `,
// up to `]`.
func mdPItemsF(lim *Lim, s []rune) ([]Json, []rune, bool) {
	var out []Json
	for {
		if len(s) > 0 && s[0] == ']' {
			return out, s[1:], true
		}
		if !hasPrefix(s, ", ") {
			return nil, nil, false
		}
		x, r1, ok := mdPFlow(lim, s[2:])
		if !ok {
			return nil, nil, false
		}
		out = append(out, x)
		s = r1
	}
}

// mdPEntryF is `Md.pEntryF`: one entry, `key: value`.
func mdPEntryF(lim *Lim, s []rune) (KV, []rune, bool) {
	k, r, ok := strParseKey(false, yamlReserved, s)
	if !ok || !hasPrefix(r, ": ") {
		return KV{}, nil, false
	}
	v, r1, ok := mdPFlow(lim, r[2:])
	if !ok {
		return KV{}, nil, false
	}
	return KV{k, v}, r1, true
}

// mdPEntriesF is `Md.pEntriesF`: the entries after the first, each after `, `,
// up to `}`.
func mdPEntriesF(lim *Lim, s []rune) (Obj, []rune, bool) {
	var out Obj
	for {
		if len(s) > 0 && s[0] == '}' {
			return out, s[1:], true
		}
		if !hasPrefix(s, ", ") {
			return nil, nil, false
		}
		e, r1, ok := mdPEntryF(lim, s[2:])
		if !ok {
			return nil, nil, false
		}
		out = append(out, e)
		s = r1
	}
}

// mdIsColl is `Md.isColl`.
func mdIsColl(v Json) bool {
	switch v.(type) {
	case []Json, Obj:
		return true
	}
	return false
}

// mdSqEsc is `Md.sqEsc`: `'` as `&#39;` and `&` as `&amp;`.
func mdSqEsc(cs []rune) []rune {
	out := make([]rune, 0, len(cs))
	for _, c := range cs {
		switch c {
		case '\'':
			out = pushS(out, "&#39;")
		case '&':
			out = pushS(out, "&amp;")
		default:
			out = append(out, c)
		}
	}
	return out
}

// mdSqUnesc is `Md.sqUnesc`: undo sqEsc.
func mdSqUnesc(cs []rune) []rune {
	out := make([]rune, 0, len(cs))
	for len(cs) > 0 {
		if r, ok := cutPrefix(cs, "&#39;"); ok {
			out = append(out, '\'')
			cs = r
		} else if r, ok := cutPrefix(cs, "&amp;"); ok {
			out = append(out, '&')
			cs = r
		} else {
			out = append(out, cs[0])
			cs = cs[1:]
		}
	}
	return out
}

// mdAttrVal is `Md.attrVal`: a scalar as its YAML, a list or object
// single-quoted.
func mdAttrVal(v Json) []rune {
	if mdIsColl(v) {
		out := []rune{'\''}
		out = append(out, mdSqEsc(mdFlow(v, nil))...)
		return append(out, '\'')
	}
	return mdFlow(v, nil)
}

// mdAttrMd is `Md.attrMd`: `key=value`.
func mdAttrMd(a KV, out []rune) []rune {
	out = pushS(out, a.K)
	out = append(out, '=')
	return append(out, mdAttrVal(a.V)...)
}

// mdAttrsMd is `Md.attrsMd`: the attributes, separated by spaces.
func mdAttrsMd(attrs Obj, out []rune) []rune {
	for i, a := range attrs {
		if i > 0 {
			out = append(out, ' ')
		}
		out = mdAttrMd(a, out)
	}
	return out
}

// mdDeclMd is `Md.declMd`: `:var[$N$]{default=100 units="mol"}`.
func mdDeclMd(d *Decl) []rune {
	out := []rune{':'}
	out = pushS(out, mdDkw(d.Kind))
	out = append(out, '[', '$')
	out = append(out, mdNameLatex(d.Name)...)
	out = append(out, '$', ']', '{')
	out = mdAttrsMd(d.Attrs, out)
	return append(out, '}')
}

// mdPQuoted is `Md.pQuoted`: a single-quoted value after its opening quote.
func mdPQuoted(lim *Lim, u []rune) (Json, []rune, bool) {
	inner, r := textTakeWhile(u, func(c rune) bool { return c != '\'' })
	if len(r) == 0 {
		return nil, nil, false
	}
	y := mdSqUnesc(inner)
	v, rest, ok := mdPFlow(lim, y)
	if !ok || len(rest) != 0 {
		return nil, nil, false
	}
	return v, r[1:], true
}

// mdPAttr is `Md.pAttr`: one attribute.
func mdPAttr(lim *Lim, s []rune) (KV, []rune, bool) {
	id, rest := strReadIdent(s)
	if !strIsIdent(id) {
		return KV{}, nil, false
	}
	k := string(id)
	if u, ok := cutPrefix(rest, "='"); ok {
		v, r, ok := mdPQuoted(lim, u)
		if !ok {
			return KV{}, nil, false
		}
		return KV{k, v}, r, true
	}
	if len(rest) > 0 && rest[0] == '=' {
		v, r, ok := mdPFlow(lim, rest[1:])
		if !ok {
			return KV{}, nil, false
		}
		return KV{k, v}, r, true
	}
	return KV{}, nil, false
}

// mdPAttrsMore is `Md.pAttrsMore`: the attributes after the first, each after
// a space, up to the closing brace.
func mdPAttrsMore(lim *Lim, s []rune) (Obj, []rune, bool) {
	var out Obj
	for {
		if len(s) == 0 {
			return nil, nil, false
		}
		switch s[0] {
		case '}':
			return out, s[1:], true
		case ' ':
			a, r1, ok := mdPAttr(lim, s[1:])
			if !ok {
				return nil, nil, false
			}
			out = append(out, a)
			s = r1
		default:
			return nil, nil, false
		}
	}
}

// mdPAttrs is `Md.pAttrs`: the attributes after the opening brace, up to the
// closing one.
func mdPAttrs(lim *Lim, s []rune) (Obj, []rune, bool) {
	if len(s) > 0 && s[0] == '}' {
		return Obj{}, s[1:], true
	}
	a, r, ok := mdPAttr(lim, s)
	if !ok {
		return nil, nil, false
	}
	as, r1, ok := mdPAttrsMore(lim, r)
	if !ok {
		return nil, nil, false
	}
	return append(Obj{a}, as...), r1, true
}

// mdDeclBody is `Md.declBody`: a declaration after its `[`.
func mdDeclBody(lim *Lim, k DKind, s []rune) (RItem, []rune, bool) {
	if len(s) == 0 || s[0] != '$' {
		return RItem{}, nil, false
	}
	name, rest := textTakeWhile(s[1:], func(c rune) bool { return c != '$' })
	u, ok := cutPrefix(rest, "$]{")
	if !ok {
		return RItem{}, nil, false
	}
	v, ok := mathParseLatex(lim, symEmpty, string(name))
	n, isStr := v.(string)
	if !ok || !isStr {
		return RItem{}, nil, false
	}
	a, r, ok := mdPAttrs(lim, u)
	if !ok {
		return RItem{}, nil, false
	}
	return RItem{K: RIDecl, Decl: Decl{k, n, a}}, r, true
}

// ## Block constructs

// mdFenceItem is `Md.fenceItem`: a fenced block's construct, from its info
// string and body.
func mdFenceItem(lim *Lim, info, body []rune) (RItem, bool) {
	if string(info) == mdDescInfo {
		b, ok := cutTrailingNewline(body)
		if !ok {
			return RItem{}, false
		}
		return RItem{K: RIDesc, S: string(b)}, true
	}
	k, ok := mdParseKeyMd(info)
	if !ok {
		return RItem{}, false
	}
	v, ok := yamlDecode(lim, body)
	if !ok {
		return RItem{}, false
	}
	return RItem{K: RIBlock, S: k, V: v}, true
}

// mdLabelOk is `Md.labelOK`: nothing, or `{#id}`, with spaces around.
func mdLabelOk(sl []rune) bool {
	_, t := textTakeWhile(sl, func(c rune) bool { return c == ' ' })
	if len(t) == 0 {
		return true
	}
	r, ok := cutPrefix(t, "{#")
	if !ok || len(r) == 0 || r[len(r)-1] != '}' {
		return false
	}
	return !containsRune(r[:len(r)-1], '}')
}

// mdFenceAt is `Md.fenceAt`: a fenced block after "```esm:".
func mdFenceAt(lim *Lim, u []rune) (RItem, []rune, bool) {
	info, after := textSplitLine(u)
	body, sl, rest, ok := textUntilStop(mdFenceR, after)
	if !ok || !textBlank(sl) {
		return RItem{}, nil, false
	}
	it, ok := mdFenceItem(lim, info, body)
	if !ok {
		return RItem{}, nil, false
	}
	return it, rest, true
}

// ## Templates and rules

const (
	mdDTmpl     = ":::template{"
	mdDRuleC    = ":::rule{"
	mdTmHeadL   = "\\operatorname{"
	mdTmDef     = ") \\coloneqq "
	mdRuleHeadL = "\\text{rule } \\operatorname{"
	mdRuleSep   = ": \\; "
	mdRuleArrow = " \\Rightarrow "
)

// mdParamsTxt is `Md.paramsTxt`: the parameters of a template header,
// separated by `, `.
func mdParamsTxt(ps []string, out []rune) []rune {
	for i, p := range ps {
		if i > 0 {
			out = append(out, ',', ' ')
		}
		out = append(out, mdNameLatex(p)...)
	}
	return out
}

// mdTmRaw is `Md.tmRaw`: the math text of a template or rule display (one
// line).
func mdTmRaw(t *Tm[string]) []rune {
	name := []rune(t.Name)
	var out []rune
	if !t.HasLhs {
		out = pushS(out, mdTmHeadL)
		out = append(out, prEscT(name)...)
		out = append(out, '}', '(')
		out = mdParamsTxt(t.Params, out)
		out = pushS(out, mdTmDef)
		return pushS(out, t.Body)
	}
	out = pushS(out, mdRuleHeadL)
	out = append(out, prEscT(name)...)
	out = append(out, '}')
	out = pushS(out, mdRuleSep)
	out = pushS(out, t.Lhs)
	out = pushS(out, mdRuleArrow)
	return pushS(out, t.Body)
}

// mdPName is `Md.pName`: one parameter, up to the next `,` or `)`.
func mdPName(lim *Lim, s []rune) (string, []rune, bool) {
	a, rest := textTakeWhile(s, func(c rune) bool { return c != ',' && c != ')' })
	v, ok := mathParseLatex(lim, symEmpty, string(a))
	n, isStr := v.(string)
	if !ok || !isStr {
		return "", nil, false
	}
	return n, rest, true
}

// mdPParams is `Md.pParams`: the parameters after `(`, up to `) \coloneqq `.
func mdPParams(lim *Lim, s []rune) ([]string, []rune, bool) {
	out := []string{}
	for {
		if r, ok := textAfterS(mdTmDef, s); ok {
			return out, r, true
		}
		n, r, ok := mdPName(lim, s)
		if !ok {
			return nil, nil, false
		}
		out = append(out, n)
		if r1, ok := textAfterS(mdTmDef, r); ok {
			return out, r1, true
		}
		r1, ok := cutPrefix(r, ", ")
		if !ok {
			return nil, nil, false
		}
		s = r1
	}
}

// mdSplitAt is `Md.splitAt`: split at the first occurrence of sep.
func mdSplitAt(sep string, s []rune) ([]rune, []rune, bool) {
	n := utf8.RuneCountInString(sep)
	for i := range s {
		if textPreS(sep, s[i:]) {
			return s[:i], s[i+n:], true
		}
	}
	return nil, nil, false
}

// TmLex is what `tmLex` reads: name, parameters, a rule's left-hand side,
// body.
type TmLex struct {
	Name   string
	Params []string
	HasLhs bool
	Lhs    []rune
	Body   []rune
}

// mdTmLex is `Md.tmLex`: read the math text of a display as a template or
// rule.
func mdTmLex(lim *Lim, raw []rune) (TmLex, bool) {
	if u, ok := textAfterS(mdRuleHeadL, raw); ok {
		nm, u1, ok := prRawB(0, u)
		if !ok {
			return TmLex{}, false
		}
		u2, ok := textAfterS(mdRuleSep, u1)
		if !ok {
			return TmLex{}, false
		}
		l, b, ok := mdSplitAt(mdRuleArrow, u2)
		if !ok {
			return TmLex{}, false
		}
		return TmLex{string(prUnescT(nm)), nil, true, l, b}, true
	}
	u, ok := textAfterS(mdTmHeadL, raw)
	if !ok {
		return TmLex{}, false
	}
	nm, u1, ok := prRawB(0, u)
	if !ok || len(u1) == 0 || u1[0] != '(' {
		return TmLex{}, false
	}
	ps, b, ok := mdPParams(lim, u1[1:])
	if !ok {
		return TmLex{}, false
	}
	return TmLex{string(prUnescT(nm)), ps, false, nil, b}, true
}

// mdMathAt is `Md.mathAt`: a display after its opening `$$`: a template or
// rule when its math reads as one, otherwise an equation (optionally
// labelled).
func mdMathAt(lim *Lim, u []rune) (RItem, []rune, bool) {
	first, after := textSplitLine(u)
	if !textBlank(first) {
		return RItem{}, nil, false
	}
	body, sl, rest, ok := textUntilStop(mdDDR, after)
	if !ok {
		return RItem{}, nil, false
	}
	b, ok := cutTrailingNewline(body)
	if !ok {
		return RItem{}, nil, false
	}
	if tl, ok := mdTmLex(lim, b); ok {
		if !textBlank(sl) {
			return RItem{}, nil, false
		}
		t := Tm[string]{Name: tl.Name, Params: tl.Params, HasLhs: tl.HasLhs, Body: string(tl.Body)}
		if tl.HasLhs {
			t.Lhs = string(tl.Lhs)
		}
		return RItem{K: RITm, Tm: t}, rest, true
	}
	if !mdLabelOk(sl) {
		return RItem{}, nil, false
	}
	return RItem{K: RIEqn, S: string(b)}, rest, true
}

// mdTmContAt is `Md.tmContAt`: a template or rule with other fields, after
// `:::template{` or `:::rule{`.
func mdTmContAt(lim *Lim, u []rune) (RItem, []rune, bool) {
	as, r, ok := mdPAttrs(lim, u)
	if !ok || len(r) == 0 || r[0] != '\n' {
		return RItem{}, nil, false
	}
	r1 := r[1:]
	if !textPreS(mdDD, r1) {
		return RItem{}, nil, false
	}
	it, r2, ok := mdMathAt(lim, r1[2:])
	if !ok || it.K != RITm {
		return RItem{}, nil, false
	}
	l, r3 := textSplitLine(dropN(r2, 3))
	if textPreS(mdDEnd, r2) && textBlank(l) {
		it.Tm.Attrs = as
		return it, r3, true
	}
	return RItem{}, nil, false
}

// mdDirAt is `Md.dirAt`: a component directive after its `[`.
func mdDirAt(k Kind, u []rune) (RItem, []rune, bool) {
	name, rest := textTakeWhile(u, func(c rune) bool { return c != ']' && c != '\n' })
	if len(rest) == 0 || rest[0] != ']' {
		return RItem{}, nil, false
	}
	l, r := textSplitLine(rest[1:])
	if !textBlank(l) {
		return RItem{}, nil, false
	}
	return RItem{K: RIComp, Kind: k, S: string(name)}, r, true
}

// ## Reactions

// mdLatexR is `Md.latexR`: LaTeX under the empty symbol table.
var mdLatexR = &RSurf{
	pm:    func(lim *Lim, s string) (Json, bool) { return mathParseLatex(lim, symEmpty, s) },
	prm:   func(j Json) []rune { return []rune(mathPrintLatex(symEmpty, j)) },
	empty: []rune("\\varnothing"),
}

const (
	mdArrowL = " ->[{$"
	mdArrowR = "}] "
	mdRxnEnd = "}$$ {#"
)

// mdRxnBody is `Md.rxnBody`: the text of a reaction line after `$$\ce{`.
func mdRxnBody(x *Rxn[string]) []rune {
	out := rxnSideTxt(mdLatexR, x.HasSubs, x.Subs)
	out = pushS(out, mdArrowL)
	out = pushS(out, x.Rate)
	out = append(out, '$')
	out = pushS(out, mdArrowR)
	out = append(out, rxnSideTxt(mdLatexR, x.HasProds, x.Prods)...)
	out = pushS(out, mdRxnEnd)
	out = pushS(out, x.ID)
	for _, b := range x.Attrs {
		out = append(out, ' ')
		out = mdAttrMd(b, out)
	}
	return append(out, '}', '\n')
}

// mdRxnAt is `Md.rxnAt`: a reaction line after its `$$\ce{`.
func mdRxnAt(lim *Lim, u []rune) (RItem, []rune, bool) {
	subs, hs, u1, ok := rxnPSide(lim, mdLatexR, u)
	if !ok {
		return RItem{}, nil, false
	}
	u2, ok := textAfterS(mdArrowL, u1)
	if !ok {
		return RItem{}, nil, false
	}
	rate, u2b, ok := rxnPPiece(u2)
	if !ok {
		return RItem{}, nil, false
	}
	u3, ok := textAfterS(mdArrowR, u2b)
	if !ok {
		return RItem{}, nil, false
	}
	prods, hp, u4, ok := rxnPSide(lim, mdLatexR, u3)
	if !ok {
		return RItem{}, nil, false
	}
	u5, ok := textAfterS(mdRxnEnd, u4)
	if !ok {
		return RItem{}, nil, false
	}
	id, u5b := textTakeWhile(u5, rxnIdChar)
	attrs, u6, ok := mdPAttrsMore(lim, u5b)
	if !ok {
		return RItem{}, nil, false
	}
	l, r := textSplitLine(u6)
	if len(id) == 0 || !textBlank(l) {
		return RItem{}, nil, false
	}
	return RItem{K: RIRxn, Rxn: Rxn[string]{
		ID: string(id), HasSubs: hs, Subs: subs, HasProds: hp, Prods: prods,
		Rate: string(rate), Attrs: attrs,
	}}, r, true
}

// mdSubAt is `Md.subAt`: a subsystem directive after its `::subsystem[`.
func mdSubAt(lim *Lim, u []rune) (RItem, []rune, bool) {
	name, rest := textTakeWhile(u, func(c rune) bool { return c != ']' && c != '\n' })
	v, ok := cutPrefix(rest, "]{")
	if !ok {
		return RItem{}, nil, false
	}
	a, r, ok := mdPAttrs(lim, v)
	if !ok {
		return RItem{}, nil, false
	}
	l, r1 := textSplitLine(r)
	if !textBlank(l) {
		return RItem{}, nil, false
	}
	return RItem{K: RIDecl, Decl: Decl{DKSub, string(name), a}}, r1, true
}

// mdPlotAt is `Md.plotAt`: a plot directive after its `::plot{`.
func mdPlotAt(lim *Lim, u []rune) (RItem, []rune, bool) {
	a, r, ok := mdPAttrs(lim, u)
	if !ok {
		return RItem{}, nil, false
	}
	l, r1 := textSplitLine(r)
	if !textBlank(l) {
		return RItem{}, nil, false
	}
	return RItem{K: RIPlot, Plot: a}, r1, true
}

// ## Containers of initialization equations and constraints

// mdContBody is `Md.contBody`: the displays of a container, up to its closing
// `:::` line; blank lines between them are skipped.
func mdContBody(lim *Lim, ro Role, s []rune) ([]RItem, []rune, bool) {
	var out []RItem
	for {
		switch {
		case textPreS(mdDEnd, s):
			l, r := textSplitLine(s[3:])
			if !textBlank(l) {
				return nil, nil, false
			}
			return out, r, true
		case textPreS(mdDD, s):
			it, r, ok := mdMathAt(lim, s[2:])
			if !ok || it.K != RIEqn {
				return nil, nil, false
			}
			out = append(out, RItem{K: RIEqx, Role: ro, S: it.S})
			s = r
		case len(s) > 0 && s[0] == '\n':
			s = s[1:]
		default:
			return nil, nil, false
		}
	}
}

// mdContOpen is `Md.contOpen`: a container starts here.
func mdContOpen(s []rune) bool { return textPreS(mdDInit, s) || textPreS(mdDCons, s) }

// mdContAt is `Md.contAt`: a container, at its opening line.
func mdContAt(lim *Lim, s []rune) ([]RItem, []rune, bool) {
	ro, n := RoleCons, len(mdDCons)
	if textPreS(mdDInit, s) {
		ro, n = RoleInit, len(mdDInit)
	}
	l, r := textSplitLine(dropN(s, n))
	if !textBlank(l) {
		return nil, nil, false
	}
	return mdContBody(lim, ro, r)
}

// ## The lexer

// mdBlockOpen is `Md.blockOpen`: a block construct starts here.
func mdBlockOpen(s []rune) bool {
	if len(s) == 0 {
		return false
	}
	switch s[0] {
	case '`':
		return textPreS(mdFenceEsm, s)
	case '$':
		return textPreS(mdDD, s)
	case ':':
		return textPreS(mdDModel, s) || textPreS(mdDRs, s) || textPreS(mdDPlot, s) ||
			textPreS(mdDSub, s) || textPreS(mdDTmpl, s) || textPreS(mdDRuleC, s)
	}
	return false
}

// mdDeclOpen is `Md.declOpen`: a declaration starts here.
func mdDeclOpen(s []rune) bool {
	if len(s) == 0 || s[0] != ':' {
		return false
	}
	return textPreS(":var[", s) || textPreS(":param[", s) || textPreS(":species[", s)
}

// mdBlockAt is `Md.blockAt`: read the block construct that starts here.
func mdBlockAt(lim *Lim, s []rune) (RItem, []rune, bool) {
	switch {
	case textPreS(mdFenceEsm, s):
		return mdFenceAt(lim, dropN(s, 7))
	case textPreS(mdDRxn, s):
		return mdRxnAt(lim, dropN(s, 6))
	case textPreS(mdDD, s):
		return mdMathAt(lim, dropN(s, 2))
	case textPreS(mdDModel, s):
		return mdDirAt(KindModel, dropN(s, 8))
	case textPreS(mdDPlot, s):
		return mdPlotAt(lim, dropN(s, 7))
	case textPreS(mdDSub, s):
		return mdSubAt(lim, dropN(s, 12))
	case textPreS(mdDTmpl, s):
		return mdTmContAt(lim, dropN(s, 12))
	case textPreS(mdDRuleC, s):
		return mdTmContAt(lim, dropN(s, 8))
	}
	return mdDirAt(KindRs, dropN(s, 18))
}

// mdDeclAt is `Md.declAt`: read the declaration that starts here.
func mdDeclAt(lim *Lim, s []rune) (RItem, []rune, bool) {
	switch {
	case textPreS(":var[", s):
		return mdDeclBody(lim, DKVar, dropN(s, 5))
	case textPreS(":param[", s):
		return mdDeclBody(lim, DKParam, dropN(s, 7))
	}
	return mdDeclBody(lim, DKSpecies, dropN(s, 9))
}

// ## The declarations table (an accepted input variant)

// mdTableOpen is `Md.tableOpen`.
const mdTableOpen = "| decl | name |"

// mdTrimCell is `Md.trimCell`: a cell without its surrounding spaces.
func mdTrimCell(s string) string { return strings.Trim(s, " ") }

// mdHeaderCells is `Md.headerCells`: the line split at `|`, each cell trimmed.
func mdHeaderCells(s []rune) []string {
	line, _ := textTakeWhile(s, func(c rune) bool { return c != '\n' })
	parts := strings.Split(string(line), "|")
	for i := range parts {
		parts[i] = mdTrimCell(parts[i])
	}
	return parts
}

// mdRateTable is `Md.rateTable`: a line starting with `|` that has a cell
// `rate`.
func mdRateTable(s []rune) bool {
	if len(s) == 0 || s[0] != '|' {
		return false
	}
	for _, c := range mdHeaderCells(s) {
		if c == "rate" {
			return true
		}
	}
	return false
}

// mdPCols is `Md.pCols`: the attribute columns of the header, up to its
// newline.
func mdPCols(s []rune) ([]string, []rune, bool) {
	var out []string
	for {
		if len(s) == 0 {
			return nil, nil, false
		}
		switch s[0] {
		case '\n':
			return out, s[1:], true
		case ' ':
			id, rest := strReadIdent(s[1:])
			if !strIsIdent(id) {
				return nil, nil, false
			}
			u, ok := cutPrefix(rest, " |")
			if !ok {
				return nil, nil, false
			}
			out = append(out, string(id))
			s = u
		default:
			return nil, nil, false
		}
	}
}

// mdPCell is `Md.pCell`: ` value |`, or ` |` when the attribute is absent.
func mdPCell(lim *Lim, s []rune) (Json, bool, []rune, bool) {
	if r, ok := cutPrefix(s, " |"); ok {
		return nil, false, r, true
	}
	if len(s) > 0 && s[0] == ' ' {
		v, r, ok := mdPFlow(lim, s[1:])
		if !ok {
			return nil, false, nil, false
		}
		r1, ok := cutPrefix(r, " |")
		if !ok {
			return nil, false, nil, false
		}
		return v, true, r1, true
	}
	return nil, false, nil, false
}

// mdPCells is `Md.pCells`: the cells of a row, one per attribute column.
func mdPCells(lim *Lim, cols []string, s []rune) (Obj, []rune, bool) {
	out := Obj{}
	for _, k := range cols {
		v, has, r, ok := mdPCell(lim, s)
		if !ok {
			return nil, nil, false
		}
		if has {
			out = append(out, KV{k, v})
		}
		s = r
	}
	return out, s, true
}

// mdKindOf is `Md.kindOf`: the directive keyword of a row.
func mdKindOf(w []rune) (DKind, bool) {
	switch string(w) {
	case "var":
		return DKVar, true
	case "param":
		return DKParam, true
	case "species":
		return DKSpecies, true
	case "subsystem":
		return DKSub, true
	}
	return 0, false
}

// mdPRow is `Md.pRow`: `| var | $N$ |` and the cells, then a newline.
func mdPRow(lim *Lim, cols []string, s []rune) (Decl, []rune, bool) {
	r, ok := cutPrefix(s, "| ")
	if !ok {
		return Decl{}, nil, false
	}
	w, rest := strReadIdent(r)
	k, ok := mdKindOf(w)
	if !ok {
		return Decl{}, nil, false
	}
	u, ok := cutPrefix(rest, " | $")
	if !ok {
		return Decl{}, nil, false
	}
	name, rest2 := textTakeWhile(u, func(c rune) bool { return c != '$' })
	v, ok := cutPrefix(rest2, "$ |")
	if !ok {
		return Decl{}, nil, false
	}
	j, ok := mathParseLatex(lim, symEmpty, string(name))
	n, isStr := j.(string)
	if !ok || !isStr {
		return Decl{}, nil, false
	}
	a, r1, ok := mdPCells(lim, cols, v)
	if !ok || len(r1) == 0 || r1[0] != '\n' {
		return Decl{}, nil, false
	}
	return Decl{k, n, a}, r1[1:], true
}

// mdPRows is `Md.pRows`: the rows, as long as lines start with `| `.
func mdPRows(lim *Lim, cols []string, s []rune) ([]Decl, []rune, bool) {
	var out []Decl
	for textPreS("| ", s) {
		d, r, ok := mdPRow(lim, cols, s)
		if !ok {
			return nil, nil, false
		}
		out = append(out, d)
		s = r
	}
	return out, s, true
}

// mdSepOk is `Md.sepOK`: the separator row.
func mdSepOk(l []rune) bool {
	for _, c := range l {
		if c != '|' && c != '-' && c != ' ' && c != ':' {
			return false
		}
	}
	return true
}

// mdTableAt is `Md.tableAt`: a declarations table, at its `| decl | name |`.
func mdTableAt(lim *Lim, s []rune) ([]RItem, []rune, bool) {
	cols, r, ok := mdPCols(dropN(s, len(mdTableOpen)))
	if !ok {
		return nil, nil, false
	}
	l, r1 := textSplitLine(r)
	if !mdSepOk(l) {
		return nil, nil, false
	}
	ds, r2, ok := mdPRows(lim, cols, r1)
	if !ok {
		return nil, nil, false
	}
	out := make([]RItem, len(ds))
	for i, d := range ds {
		out[i] = RItem{K: RIDecl, Decl: d}
	}
	return out, r2, true
}

// ## Code spans

// mdAfterRun is `Md.afterRun`: the text after the first occurrence of n
// backticks.
func mdAfterRun(n int, s []rune) ([]rune, bool) {
	run := 0
	for i, c := range s {
		if c == '`' {
			run++
			if run >= n {
				// the first occurrence starts at i-n+1
				return s[i+1:], true
			}
		} else {
			run = 0
		}
	}
	if n == 0 && len(s) > 0 {
		return s, true
	}
	return nil, false
}

// mdSkipCode is `Md.skipCode`: the text after the code span that starts here.
func mdSkipCode(s []rune) []rune {
	run, rest := textTakeWhile(s, func(c rune) bool { return c == '`' })
	if r, ok := mdAfterRun(len(run), rest); ok {
		return r
	}
	return rest
}

// mdLex is `Md.lex`: the constructs of a text, skipping prose one character
// at a time and code spans whole. A malformed construct is an error.
func mdLex(lim *Lim, bol bool, s []rune) ([]RItem, bool) {
	var out []RItem
	for len(s) > 0 {
		c := s[0]
		switch {
		case bol && mdBlockOpen(s):
			it, rest, ok := mdBlockAt(lim, s)
			if !ok {
				return nil, false
			}
			out = append(out, it)
			s, bol = rest, true
		case mdDeclOpen(s):
			it, rest, ok := mdDeclAt(lim, s)
			if !ok {
				return nil, false
			}
			out = append(out, it)
			s, bol = rest, false
		case bol && textPreS(mdTableOpen, s):
			its, rest, ok := mdTableAt(lim, s)
			if !ok {
				return nil, false
			}
			out = append(out, its...)
			s, bol = rest, true
		case bol && mdContOpen(s):
			its, rest, ok := mdContAt(lim, s)
			if !ok {
				return nil, false
			}
			out = append(out, its...)
			s, bol = rest, true
		case bol && mdRateTable(s):
			return nil, false
		case c == '`':
			s, bol = mdSkipCode(s), false
		default:
			bol = c == '\n'
			s = s[1:]
		}
	}
	return out, true
}

// ## What each construct needs to read back

// mdAttrOk is `Md.attrOK`.
func mdAttrOk(a KV) bool { return strIsIdent([]rune(a.K)) && exprJwf(a.V) }

// mdDeclOk is `Md.declOK`.
func mdDeclOk(d *Decl) bool {
	if !exprNameOk(d.Name) || containsRune(mdNameLatex(d.Name), '$') {
		return false
	}
	for _, a := range d.Attrs {
		if !mdAttrOk(a) {
			return false
		}
	}
	return true
}

// mdMhchemOk is `Md.mhchemOK`: no escaped brace anywhere inside `\ce{…}`.
func mdMhchemOk(x *Rxn[string]) bool {
	t := rxnSideTxt(mdLatexR, x.HasSubs, x.Subs)
	t = pushS(t, x.Rate)
	t = append(t, rxnSideTxt(mdLatexR, x.HasProds, x.Prods)...)
	return !textHasSub([]rune("\\{"), t) && !textHasSub([]rune("\\}"), t)
}

// mdRxnOk is `Md.rxnOK`: a reaction the Markdown syntax can hold.
func mdRxnOk(x *Rxn[string]) bool {
	if !rxnSideOk(mdLatexR, x.HasSubs, x.Subs) || !rxnSideOk(mdLatexR, x.HasProds, x.Prods) ||
		strings.ContainsAny(x.Rate, "$\n") || !rxnIdOk(x.ID) {
		return false
	}
	for _, a := range x.Attrs {
		if !mdAttrOk(a) {
			return false
		}
	}
	return mdMhchemOk(x)
}

// mdSubMd is `Md.subMd`.
func mdSubMd(d *Decl) []rune {
	out := []rune(mdDSub)
	out = pushS(out, d.Name)
	out = append(out, ']', '{')
	out = mdAttrsMd(d.Attrs, out)
	return append(out, '}', '\n')
}

// mdSubOk is `Md.subOK`.
func mdSubOk(d *Decl) bool {
	if strings.ContainsAny(d.Name, "]\n") {
		return false
	}
	for _, a := range d.Attrs {
		if !mdAttrOk(a) {
			return false
		}
	}
	return true
}

// mdItemMd is `Md.itemMd`: the text of a construct.
func mdItemMd(it *RItem) []rune {
	var out []rune
	switch it.K {
	case RIDesc:
		out = pushS(out, mdFenceEsm)
		out = pushS(out, mdDescInfo)
		out = append(out, '\n')
		out = pushS(out, it.S)
		out = append(out, '\n')
		out = pushS(out, mdFence)
		out = append(out, '\n')
	case RIBlock:
		out = pushS(out, mdFenceEsm)
		out = append(out, mdKeyMd(it.S)...)
		out = append(out, '\n')
		out = append(out, yamlEncode(it.V)...)
		out = pushS(out, mdFence)
		out = append(out, '\n')
	case RIComp:
		if it.Kind == KindModel {
			out = pushS(out, mdDModel)
		} else {
			out = pushS(out, mdDRs)
		}
		out = pushS(out, it.S)
		out = append(out, ']', '\n')
	case RIDecl:
		if it.Decl.Kind == DKSub {
			out = mdSubMd(&it.Decl)
		} else {
			out = mdDeclMd(&it.Decl)
		}
	case RIEqn:
		out = pushS(out, mdDD)
		out = append(out, '\n')
		out = pushS(out, it.S)
		out = append(out, '\n')
		out = pushS(out, mdDD)
		out = append(out, '\n')
	case RIEqx:
		out = pushS(out, mdDRole(it.Role))
		out = append(out, '\n')
		out = pushS(out, mdDD)
		out = append(out, '\n')
		out = pushS(out, it.S)
		out = append(out, '\n')
		out = pushS(out, mdDD)
		out = append(out, '\n')
		out = pushS(out, mdDEnd)
		out = append(out, '\n')
	case RIRxn:
		out = pushS(out, mdDRxn)
		out = append(out, mdRxnBody(&it.Rxn)...)
	case RIPlot:
		out = pushS(out, mdDPlot)
		out = mdAttrsMd(it.Plot, out)
		out = append(out, '}', '\n')
	case RITm:
		t := &it.Tm
		if len(t.Attrs) == 0 {
			out = pushS(out, mdDD)
			out = append(out, '\n')
			out = append(out, mdTmRaw(t)...)
			out = append(out, '\n')
			out = pushS(out, mdDD)
			out = append(out, '\n')
		} else {
			if !t.HasLhs {
				out = pushS(out, mdDTmpl)
			} else {
				out = pushS(out, mdDRuleC)
			}
			out = mdAttrsMd(t.Attrs, out)
			out = append(out, '}', '\n')
			out = pushS(out, mdDD)
			out = append(out, '\n')
			out = append(out, mdTmRaw(t)...)
			out = append(out, '\n')
			out = pushS(out, mdDD)
			out = append(out, '\n')
			out = pushS(out, mdDEnd)
			out = append(out, '\n')
		}
	}
	return out
}

// mdEqnLabeled is `Md.eqnLabeled`: a display equation with an equation label
// after it.
func mdEqnLabeled(raw string, label []rune) []rune {
	out := []rune(mdDD)
	out = append(out, '\n')
	out = pushS(out, raw)
	out = append(out, '\n')
	out = pushS(out, mdDD)
	out = append(out, label...)
	return append(out, '\n')
}

// SegKind says which variant a Seg is.
type SegKind uint8

// The segment variants.
const (
	SegItem SegKind = iota
	SegLabeled
	SegProse
	SegCode
)

// Seg is `Md.Seg`: a piece of a Markdown document.
type Seg struct {
	K    SegKind
	Item RItem  // SegItem
	Raw  string // SegLabeled
	Text []rune // SegLabeled label, SegProse text, SegCode body
}

// mdSegText is `Md.segText`.
func mdSegText(s *Seg) []rune {
	switch s.K {
	case SegItem:
		return mdItemMd(&s.Item)
	case SegLabeled:
		return mdEqnLabeled(s.Raw, s.Text)
	case SegProse:
		return s.Text
	}
	out := []rune{'`'}
	out = append(out, s.Text...)
	return append(out, '`')
}

// mdRender is `Md.render`: the text of a document body.
func mdRender(segs []Seg) []rune {
	var out []rune
	for i := range segs {
		out = append(out, mdSegText(&segs[i])...)
	}
	return out
}

// mdIsBlock is `Md.isBlock`: a construct that must start a line (all but
// declarations).
func mdIsBlock(it *RItem) bool {
	if it.K == RIDecl {
		return it.Decl.Kind == DKSub
	}
	return true
}

func withNl(s string) []rune {
	v := []rune(s)
	return append(v, '\n')
}

// mdItemOk is `Md.itemOK`: what each construct's content must satisfy for its
// text to read back.
func mdItemOk(lim *Lim, it *RItem) bool {
	switch it.K {
	case RIDesc:
		return textNoStop(mdFenceR, withNl(it.S))
	case RIBlock:
		return jsonWfmb(it.V)
	case RIComp:
		return !strings.ContainsAny(it.S, "]\n")
	case RIDecl:
		if it.Decl.Kind == DKSub {
			return mdSubOk(&it.Decl)
		}
		return mdDeclOk(&it.Decl)
	case RIEqn, RIEqx:
		if it.K == RIEqx && it.Role == RoleEqn {
			return false
		}
		if !textNoStop(mdDDR, withNl(it.S)) {
			return false
		}
		_, ok := mdTmLex(lim, []rune(it.S))
		return !ok
	case RIRxn:
		return mdRxnOk(&it.Rxn)
	case RIPlot:
		for _, a := range it.Plot {
			if !mdAttrOk(a) {
				return false
			}
		}
		return true
	case RITm:
		t := &it.Tm
		raw := mdTmRaw(t)
		rn := append(append([]rune(nil), raw...), '\n')
		if !textNoStop(mdDDR, rn) || containsRune(raw, '\n') {
			return false
		}
		tl, ok := mdTmLex(lim, raw)
		if !ok || tl.Name != t.Name || tl.HasLhs != t.HasLhs || string(tl.Body) != t.Body ||
			(t.HasLhs && string(tl.Lhs) != t.Lhs) || !stringsEqual(tl.Params, t.Params) {
			return false
		}
		for _, a := range t.Attrs {
			if !mdAttrOk(a) {
				return false
			}
		}
		return true
	}
	return false
}

// stringsEqual is equality of two string lists (nil and empty alike).
func stringsEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
