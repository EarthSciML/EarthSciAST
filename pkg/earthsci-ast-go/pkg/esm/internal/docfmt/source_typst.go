package docfmt

// The Typst container: markup plus the functions of the `esm` Typst package.
// Port of formal/Esm/Document/Source/Typst.lean, namespace `Source.Typ` (Rust:
// document/source/typst.rs); prefix `styp`.
//
// The lexer reads a construct where one starts at the beginning of a line (a
// declaration anywhere) and otherwise drops one character of prose. The Lean
// fuel is dropped: every step consumes a character.

import (
	"strings"
	"unicode/utf8"
)

// ## Spellings

const (
	stypODesc    = "#description["
	stypOBlock   = "#esm-block("
	stypOModel   = "#model("
	stypORs      = "#reaction-system("
	stypOEq      = "$ "
	stypOVar     = "#var("
	stypOParam   = "#param("
	stypOSpecies = "#species("
	stypOCe      = "#ce["
	stypORxn     = "#reaction("
	stypOInit    = "#initialization["
	stypOCons    = "#constraints["
	stypOPlot    = "#plot("
	stypOSub     = "#subsystem("
	stypOTmpl    = "#template("
	stypORule    = "#rule("
)

// stypORole is `Typ.oRole`.
func stypORole(r Role) string {
	switch r {
	case RoleInit:
		return stypOInit
	case RoleCons:
		return stypOCons
	}
	return stypOEq
}

// stypHeader is `Typ.header`: the header's first line and the start of its
// second.
const stypHeader = "#import \"@preview/esm:0.1.0\": *\n#show: esm-document.with("

// ## Description text

// stypMustEsc is `Typ.mustEsc`: whether a character of a description is
// written escaped. hasNext is false at the end of the text.
func stypMustEsc(bol bool, c rune, next rune, hasNext bool) bool {
	switch c {
	case '\\', '[', ']', '#', '$', '*', '_', '`', '<', '>', '@', '~':
		return true
	case '=', '-', '+':
		if bol {
			return true
		}
	}
	return c == '/' && hasNext && (next == '/' || next == '*')
}

// stypEscT is `Typ.escT`: a description's text in a content block.
func stypEscT(bol bool, cs []rune) []rune {
	out := make([]rune, 0, len(cs))
	b := bol
	for i, c := range cs {
		var next rune
		hasNext := i+1 < len(cs)
		if hasNext {
			next = cs[i+1]
		}
		if stypMustEsc(b, c, next, hasNext) {
			out = append(out, '\\')
		}
		out = append(out, c)
		b = c == '\n'
	}
	return out
}

// stypReadEsc is `Typ.readEsc`: the text of a content block up to its
// unescaped `]`.
func stypReadEsc(s []rune) ([]rune, []rune, bool) {
	var out []rune
	for {
		if len(s) == 0 {
			return nil, nil, false
		}
		switch s[0] {
		case ']':
			return out, s[1:], true
		case '\\':
			if len(s) >= 2 {
				out = append(out, s[1])
				s = s[2:]
				continue
			}
		case '[':
			return nil, nil, false
		}
		out = append(out, s[0])
		s = s[1:]
	}
}

// stypArgT is `Typ.argT`: `key: value`.
func stypArgT(a KV, out []rune) []rune {
	out = pushS(out, a.K)
	out = append(out, ':', ' ')
	return append(out, tdictEncode(a.V)...)
}

// stypPArg is `Typ.pArg`: one named argument at its key.
func stypPArg(lim *Lim, s []rune) (KV, []rune, bool) {
	id, rest := strReadIdent(s)
	k := string(id)
	if !strIsIdent(id) || tdictReserved(k) {
		return KV{}, nil, false
	}
	u, ok := cutPrefix(rest, ": ")
	if !ok {
		return KV{}, nil, false
	}
	v, r, ok := tdictPVal(lim, u)
	if !ok {
		return KV{}, nil, false
	}
	return KV{k, v}, r, true
}

// stypPArgsMore is `Typ.pArgsMore`: `, key: value` repeated, up to `)`.
func stypPArgsMore(lim *Lim, s []rune) (Obj, []rune, bool) {
	var out Obj
	for {
		if len(s) > 0 && s[0] == ')' {
			return out, s[1:], true
		}
		r, ok := cutPrefix(s, ", ")
		if !ok {
			return nil, nil, false
		}
		a, r1, ok := stypPArg(lim, r)
		if !ok {
			return nil, nil, false
		}
		out = append(out, a)
		s = r1
	}
}

// stypPArgsFirst is `Typ.pArgsFirst`: arguments directly after `(`.
func stypPArgsFirst(lim *Lim, s []rune) (Obj, []rune, bool) {
	if len(s) > 0 && s[0] == ')' {
		return Obj{}, s[1:], true
	}
	a, r, ok := stypPArg(lim, s)
	if !ok {
		return nil, nil, false
	}
	as, r1, ok := stypPArgsMore(lim, r)
	if !ok {
		return nil, nil, false
	}
	return append(Obj{a}, as...), r1, true
}

// stypArgsMoreT is `Typ.argsMoreT`: each `, key: value`.
func stypArgsMoreT(as Obj, out []rune) []rune {
	for _, a := range as {
		out = append(out, ',', ' ')
		out = stypArgT(a, out)
	}
	return out
}

// stypArgsFirstT is `Typ.argsFirstT`: arguments directly after `(`.
func stypArgsFirstT(as Obj, out []rune) []rune {
	if len(as) > 0 {
		out = stypArgT(as[0], out)
		out = stypArgsMoreT(as[1:], out)
	}
	return out
}

// stypArgOk is `Typ.argOK`: an identifier key that is not a keyword, and a
// well-formed value.
func stypArgOk(a KV) bool { return strBareKey(tdictReserved, a.K) && exprJwf(a.V) }

// ## Constructs

// stypNameTyp is `Typ.nameTyp`: a name as Typst math under the empty symbol
// table.
func stypNameTyp(n string) []rune { return []rune(mathPrintTypst(symEmpty, n)) }

// stypDkw is `Typ.dkw`.
func stypDkw(k DKind) string {
	switch k {
	case DKParam:
		return stypOParam
	case DKSpecies:
		return stypOSpecies
	case DKSub:
		return stypOSub
	}
	return stypOVar
}

// stypDeclT is `Typ.declT`: `#var($N$, default: 100)`.
func stypDeclT(d *Decl) []rune {
	out := []rune(stypDkw(d.Kind))
	out = append(out, '$')
	out = append(out, stypNameTyp(d.Name)...)
	out = append(out, '$')
	out = stypArgsMoreT(d.Attrs, out)
	return append(out, ')')
}

// stypLineEnd is `Typ.lineEnd`: the rest of a construct's line must be blank.
func stypLineEnd(t []rune) ([]rune, bool) {
	l, r := textSplitLine(t)
	if !textBlank(l) {
		return nil, false
	}
	return r, true
}

// ## Reactions

// stypTypR is `Typ.typR`: Typst math under the empty symbol table.
var stypTypR = &RSurf{
	pm:    func(lim *Lim, s string) (Json, bool) { return mathParseTypst(lim, symEmpty, s) },
	prm:   func(j Json) []rune { return []rune(mathPrintTypst(symEmpty, j)) },
	empty: []rune("emptyset"),
}

const (
	stypArrowL = " ->[$"
	stypArrowR = "] "
)

// stypCoreT is `Typ.coreT`: the sides and the rate over the arrow.
func stypCoreT(x *Rxn[string]) []rune {
	out := rxnSideTxt(stypTypR, x.HasSubs, x.Subs)
	out = pushS(out, stypArrowL)
	out = pushS(out, x.Rate)
	out = append(out, '$')
	out = pushS(out, stypArrowR)
	return append(out, rxnSideTxt(stypTypR, x.HasProds, x.Prods)...)
}

// stypRxnT is `Typ.rxnT`: `#ce[…] <id>`, or `#reaction(…)[#ce[…]] <id>`.
func stypRxnT(x *Rxn[string]) []rune {
	var out []rune
	if len(x.Attrs) == 0 {
		out = pushS(out, stypOCe)
		out = append(out, stypCoreT(x)...)
		out = append(out, ']', ' ', '<')
	} else {
		out = pushS(out, stypORxn)
		out = stypArgsFirstT(x.Attrs, out)
		out = pushS(out, ")[#ce[")
		out = append(out, stypCoreT(x)...)
		out = append(out, ']', ']', ' ', '<')
	}
	out = pushS(out, x.ID)
	return append(out, '>', '\n')
}

// stypCore is what `coreAt` reads: subs, rate, prods, and the text after.
type stypCore struct {
	hasSubs  bool
	subs     []Term
	rate     []rune
	hasProds bool
	prods    []Term
	rest     []rune
}

// stypCoreAt is `Typ.coreAt`.
func stypCoreAt(lim *Lim, u []rune) (stypCore, bool) {
	subs, hs, u1, ok := rxnPSide(lim, stypTypR, u)
	if !ok {
		return stypCore{}, false
	}
	u2, ok := textAfterS(stypArrowL, u1)
	if !ok {
		return stypCore{}, false
	}
	rate, u2b, ok := rxnPPiece(u2)
	if !ok {
		return stypCore{}, false
	}
	u3, ok := textAfterS(stypArrowR, u2b)
	if !ok {
		return stypCore{}, false
	}
	prods, hp, u4, ok := rxnPSide(lim, stypTypR, u3)
	if !ok {
		return stypCore{}, false
	}
	return stypCore{hs, subs, rate, hp, prods, u4}, true
}

// stypLabelAt is `Typ.labelAt`: the label `<id>` and the end of the line.
func stypLabelAt(u []rune) (string, []rune, bool) {
	if len(u) == 0 || u[0] != '<' {
		return "", nil, false
	}
	id, w := textTakeWhile(u[1:], rxnIdChar)
	if len(w) == 0 || w[0] != '>' || len(id) == 0 {
		return "", nil, false
	}
	r, ok := stypLineEnd(w[1:])
	if !ok {
		return "", nil, false
	}
	return string(id), r, true
}

// stypRxnItem builds the reaction construct of a core.
func stypRxnItem(id string, c *stypCore, attrs Obj) RItem {
	return RItem{K: RIRxn, Rxn: Rxn[string]{
		ID: id, HasSubs: c.hasSubs, Subs: c.subs, HasProds: c.hasProds, Prods: c.prods,
		Rate: string(c.rate), Attrs: attrs,
	}}
}

// stypCeAt is `Typ.ceAt`: a reaction after `#ce[`.
func stypCeAt(lim *Lim, u []rune) (RItem, []rune, bool) {
	c, ok := stypCoreAt(lim, u)
	if !ok {
		return RItem{}, nil, false
	}
	u5, ok := textAfterS("] ", c.rest)
	if !ok {
		return RItem{}, nil, false
	}
	id, r, ok := stypLabelAt(u5)
	if !ok {
		return RItem{}, nil, false
	}
	return stypRxnItem(id, &c, nil), r, true
}

// stypRxnAtT is `Typ.rxnAtT`: a reaction after `#reaction(`.
func stypRxnAtT(lim *Lim, u []rune) (RItem, []rune, bool) {
	as, u1, ok := stypPArgsFirst(lim, u)
	if !ok {
		return RItem{}, nil, false
	}
	u2, ok := textAfterS("[#ce[", u1)
	if !ok {
		return RItem{}, nil, false
	}
	c, ok := stypCoreAt(lim, u2)
	if !ok {
		return RItem{}, nil, false
	}
	u5, ok := textAfterS("]] ", c.rest)
	if !ok {
		return RItem{}, nil, false
	}
	id, r, ok := stypLabelAt(u5)
	if !ok {
		return RItem{}, nil, false
	}
	return stypRxnItem(id, &c, as), r, true
}

// ## Templates and rules

const (
	stypTmOp   = "op("
	stypTmPar  = ")("
	stypTmDefT = ") := "
	stypSepD   = ", $"
)

// stypParamsT is `Typ.paramsT`.
func stypParamsT(ps []string, out []rune) []rune {
	for i, p := range ps {
		if i > 0 {
			out = append(out, ',', ' ')
		}
		out = append(out, stypNameTyp(p)...)
	}
	return out
}

// stypTmRawT is `Typ.tmRawT`: the math text of a template display (one line).
func stypTmRawT(t *Tm[string]) []rune {
	out := []rune(stypTmOp)
	out = append(out, strQuote(true, t.Name)...)
	out = pushS(out, stypTmPar)
	out = stypParamsT(t.Params, out)
	out = pushS(out, stypTmDefT)
	return pushS(out, t.Body)
}

// stypNameLenT is `Typ.nameLenT`: the length of a parameter name's Typst math:
// up to the first `,` or `)` outside parentheses and string literals.
func stypNameLenT(s []rune) int {
	d, q, n, i := 0, false, 0, 0
	for i < len(s) {
		c := s[i]
		switch {
		case q:
			if c == '\\' {
				if i+1 < len(s) {
					n += 2
					i += 2
				} else {
					return n + 1
				}
			} else {
				n++
				q = c != '"'
				i++
			}
		case c == '"':
			n++
			q = true
			i++
		case c == '(':
			n++
			d++
			i++
		case c == ')':
			if d == 0 {
				return n
			}
			n++
			d--
			i++
		case c == ',' && d == 0:
			return n
		default:
			n++
			i++
		}
	}
	return n
}

// stypPNameT is `Typ.pNameT`: a parameter name in a template header.
func stypPNameT(lim *Lim, s []rune) (string, []rune, bool) {
	k := min(stypNameLenT(s), len(s))
	v, ok := mathParseTypst(lim, symEmpty, string(s[:k]))
	n, isStr := v.(string)
	if !ok || !isStr {
		return "", nil, false
	}
	return n, s[k:], true
}

// stypPParamsT is `Typ.pParamsT`: the parameters up to `) := `.
func stypPParamsT(lim *Lim, s []rune) ([]string, []rune, bool) {
	out := []string{}
	for {
		if r, ok := textAfterS(stypTmDefT, s); ok {
			return out, r, true
		}
		n, r, ok := stypPNameT(lim, s)
		if !ok {
			return nil, nil, false
		}
		out = append(out, n)
		if r1, ok := textAfterS(stypTmDefT, r); ok {
			return out, r1, true
		}
		r1, ok := cutPrefix(r, ", ")
		if !ok {
			return nil, nil, false
		}
		s = r1
	}
}

// stypTmLexT is `Typ.tmLexT`: read the math text of a display as a template:
// its name, parameters and body text.
func stypTmLexT(lim *Lim, raw []rune) (string, []string, []rune, bool) {
	u, ok := textAfterS(stypTmOp, raw)
	if !ok {
		return "", nil, nil, false
	}
	n, u1, ok := strParseQuoted(true, u)
	if !ok {
		return "", nil, nil, false
	}
	u2, ok := textAfterS(stypTmPar, u1)
	if !ok {
		return "", nil, nil, false
	}
	ps, b, ok := stypPParamsT(lim, u2)
	if !ok {
		return "", nil, nil, false
	}
	return n, ps, b, true
}

// stypItemT is `Typ.itemT`: the text of a construct.
func stypItemT(it *RItem) []rune {
	var out []rune
	switch it.K {
	case RIDesc:
		out = pushS(out, stypODesc)
		out = append(out, stypEscT(true, []rune(it.S))...)
		out = append(out, ']', '\n')
	case RIBlock:
		out = pushS(out, stypOBlock)
		out = append(out, strQuote(true, it.S)...)
		out = append(out, ',', ' ')
		out = append(out, tdictEncode(it.V)...)
		out = append(out, ')', '\n')
	case RIComp:
		if it.Kind == KindModel {
			out = pushS(out, stypOModel)
		} else {
			out = pushS(out, stypORs)
		}
		out = append(out, strQuote(true, it.S)...)
		out = append(out, ')', '\n')
	case RIDecl:
		d := &it.Decl
		if d.Kind == DKSub {
			out = pushS(out, stypOSub)
			out = append(out, strQuote(true, d.Name)...)
			out = stypArgsMoreT(d.Attrs, out)
			out = append(out, ')', '\n')
		} else {
			out = stypDeclT(d)
		}
	case RIEqn:
		out = pushS(out, stypOEq)
		out = pushS(out, it.S)
		out = append(out, ' ', '$', '\n')
	case RIEqx:
		out = pushS(out, stypORole(it.Role))
		out = pushS(out, stypOEq)
		out = pushS(out, it.S)
		out = append(out, ' ', '$', ']', '\n')
	case RIRxn:
		out = stypRxnT(&it.Rxn)
	case RIPlot:
		out = pushS(out, stypOPlot)
		out = stypArgsFirstT(it.Plot, out)
		out = append(out, ')', '\n')
	case RITm:
		t := &it.Tm
		switch {
		case t.HasLhs:
			out = pushS(out, stypORule)
			out = append(out, strQuote(true, t.Name)...)
			out = pushS(out, stypSepD)
			out = pushS(out, t.Lhs)
			out = append(out, '$')
			out = pushS(out, stypSepD)
			out = pushS(out, t.Body)
			out = append(out, '$')
			out = stypArgsMoreT(t.Attrs, out)
			out = append(out, ')', '\n')
		case len(t.Attrs) == 0:
			out = pushS(out, stypOEq)
			out = append(out, stypTmRawT(t)...)
			out = append(out, ' ', '$', '\n')
		default:
			out = pushS(out, stypOTmpl)
			out = stypArgsFirstT(t.Attrs, out)
			out = append(out, ')', '[')
			out = pushS(out, stypOEq)
			out = append(out, stypTmRawT(t)...)
			out = append(out, ' ', '$', ']', '\n')
		}
	}
	return out
}

// stypEqnLabeled is `Typ.eqnLabeled`: a display equation with a label after
// it.
func stypEqnLabeled(raw string, label []rune) []rune {
	out := []rune(stypOEq)
	out = pushS(out, raw)
	out = append(out, ' ', '$')
	out = append(out, label...)
	return append(out, '\n')
}

// stypLabelOk is `Typ.labelOK`: nothing, or `<id>`, with spaces around.
func stypLabelOk(sl []rune) bool {
	_, t := textTakeWhile(sl, func(c rune) bool { return c == ' ' })
	if len(t) == 0 {
		return true
	}
	if t[0] != '<' {
		return false
	}
	r := t[1:]
	if len(r) == 0 || r[len(r)-1] != '>' {
		return false
	}
	inner := r[:len(r)-1]
	return !containsRune(inner, '>') && !containsRune(inner, '<')
}

// ## The lexer

var stypBlockOpeners = []string{
	stypODesc, stypOBlock, stypOModel, stypORs, stypOEq, stypOCe, stypORxn, stypOInit,
	stypOCons, stypOPlot, stypOSub, stypOTmpl, stypORule,
}

// stypBlockOpen is `Typ.blockOpen`.
func stypBlockOpen(s []rune) bool {
	if len(s) == 0 || (s[0] != '#' && s[0] != '$') {
		return false
	}
	for _, o := range stypBlockOpeners {
		if textPreS(o, s) {
			return true
		}
	}
	return false
}

// stypDeclOpen is `Typ.declOpen`.
func stypDeclOpen(s []rune) bool {
	if len(s) == 0 || s[0] != '#' {
		return false
	}
	return textPreS(stypOVar, s) || textPreS(stypOParam, s) || textPreS(stypOSpecies, s)
}

// stypDescAt is `Typ.descAt`.
func stypDescAt(u []rune) (RItem, []rune, bool) {
	t, r, ok := stypReadEsc(u)
	if !ok {
		return RItem{}, nil, false
	}
	r1, ok := stypLineEnd(r)
	if !ok {
		return RItem{}, nil, false
	}
	return RItem{K: RIDesc, S: string(t)}, r1, true
}

// stypBlockAtT is `Typ.blockAtT`: a path block after `#esm-block(`.
func stypBlockAtT(lim *Lim, u []rune) (RItem, []rune, bool) {
	k, r, ok := strParseQuoted(true, u)
	if !ok {
		return RItem{}, nil, false
	}
	w, ok := cutPrefix(r, ", ")
	if !ok {
		return RItem{}, nil, false
	}
	v, r2, ok := tdictPVal(lim, w)
	if !ok || len(r2) == 0 || r2[0] != ')' {
		return RItem{}, nil, false
	}
	r3, ok := stypLineEnd(r2[1:])
	if !ok {
		return RItem{}, nil, false
	}
	return RItem{K: RIBlock, S: k, V: v}, r3, true
}

// stypCompAt is `Typ.compAt`.
func stypCompAt(k Kind, u []rune) (RItem, []rune, bool) {
	n, r, ok := strParseQuoted(true, u)
	if !ok || len(r) == 0 || r[0] != ')' {
		return RItem{}, nil, false
	}
	r1, ok := stypLineEnd(r[1:])
	if !ok {
		return RItem{}, nil, false
	}
	return RItem{K: RIComp, Kind: k, S: n}, r1, true
}

// stypDispItem is `Typ.dispItem`: a template when the display reads as one,
// else an equation.
func stypDispItem(lim *Lim, raw []rune) RItem {
	if n, ps, b, ok := stypTmLexT(lim, raw); ok {
		return RItem{K: RITm, Tm: Tm[string]{Name: n, Params: ps, Body: string(b)}}
	}
	return RItem{K: RIEqn, S: string(raw)}
}

// cutTrailingSpace splits a text ending in a space into the text before it.
func cutTrailingSpace(s []rune) ([]rune, bool) {
	if len(s) == 0 || s[len(s)-1] != ' ' {
		return nil, false
	}
	return s[:len(s)-1], true
}

// stypEqAt is `Typ.eqAt`: a display after its `$ `.
func stypEqAt(lim *Lim, u []rune) (RItem, []rune, bool) {
	body, r := textTakeWhile(u, func(c rune) bool { return c != '$' })
	if len(r) == 0 {
		return RItem{}, nil, false
	}
	l, rest := textSplitLine(r[1:])
	b, ok := cutTrailingSpace(body)
	if !ok || !stypLabelOk(l) {
		return RItem{}, nil, false
	}
	return stypDispItem(lim, b), rest, true
}

// stypTmplAtT is `Typ.tmplAtT`: a template with other fields, after
// `#template(`.
func stypTmplAtT(lim *Lim, u []rune) (RItem, []rune, bool) {
	as, u1, ok := stypPArgsFirst(lim, u)
	if !ok {
		return RItem{}, nil, false
	}
	u2, ok := cutPrefix(u1, "[$ ")
	if !ok {
		return RItem{}, nil, false
	}
	p, r0, ok := rxnPPiece(u2)
	if !ok {
		return RItem{}, nil, false
	}
	b, ok := cutTrailingSpace(p)
	if !ok || len(r0) == 0 || r0[0] != ']' {
		return RItem{}, nil, false
	}
	n, ps, bd, ok := stypTmLexT(lim, b)
	if !ok {
		return RItem{}, nil, false
	}
	r1, ok := stypLineEnd(r0[1:])
	if !ok {
		return RItem{}, nil, false
	}
	return RItem{K: RITm, Tm: Tm[string]{Name: n, Params: ps, Body: string(bd), Attrs: as}}, r1, true
}

// stypRuleAtT is `Typ.ruleAtT`: a rule, after `#rule(`.
func stypRuleAtT(lim *Lim, u []rune) (RItem, []rune, bool) {
	n, r, ok := strParseQuoted(true, u)
	if !ok {
		return RItem{}, nil, false
	}
	r1, ok := textAfterS(stypSepD, r)
	if !ok {
		return RItem{}, nil, false
	}
	l, r2, ok := rxnPPiece(r1)
	if !ok {
		return RItem{}, nil, false
	}
	r3, ok := textAfterS(stypSepD, r2)
	if !ok {
		return RItem{}, nil, false
	}
	b, r4, ok := rxnPPiece(r3)
	if !ok {
		return RItem{}, nil, false
	}
	as, r5, ok := stypPArgsMore(lim, r4)
	if !ok {
		return RItem{}, nil, false
	}
	r6, ok := stypLineEnd(r5)
	if !ok {
		return RItem{}, nil, false
	}
	return RItem{K: RITm, Tm: Tm[string]{Name: n, HasLhs: true, Lhs: string(l), Body: string(b), Attrs: as}}, r6, true
}

// stypEqxAt is `Typ.eqxAt`: an equation in a container after its opener:
// `$ … $]`.
func stypEqxAt(ro Role, u []rune) (RItem, []rune, bool) {
	v, ok := textAfterS(stypOEq, u)
	if !ok {
		return RItem{}, nil, false
	}
	p, r0, ok := rxnPPiece(v)
	if !ok {
		return RItem{}, nil, false
	}
	b, ok := cutTrailingSpace(p)
	if !ok || len(r0) == 0 || r0[0] != ']' {
		return RItem{}, nil, false
	}
	r1, ok := stypLineEnd(r0[1:])
	if !ok {
		return RItem{}, nil, false
	}
	return RItem{K: RIEqx, Role: ro, S: string(b)}, r1, true
}

// stypSubAtT is `Typ.subAtT`: a subsystem directive after `#subsystem(`.
func stypSubAtT(lim *Lim, u []rune) (RItem, []rune, bool) {
	n, r, ok := strParseQuoted(true, u)
	if !ok {
		return RItem{}, nil, false
	}
	a, r1, ok := stypPArgsMore(lim, r)
	if !ok {
		return RItem{}, nil, false
	}
	r2, ok := stypLineEnd(r1)
	if !ok {
		return RItem{}, nil, false
	}
	return RItem{K: RIDecl, Decl: Decl{DKSub, n, a}}, r2, true
}

// stypPlotAtT is `Typ.plotAtT`: a plot directive after `#plot(`.
func stypPlotAtT(lim *Lim, u []rune) (RItem, []rune, bool) {
	a, r, ok := stypPArgsFirst(lim, u)
	if !ok {
		return RItem{}, nil, false
	}
	r1, ok := stypLineEnd(r)
	if !ok {
		return RItem{}, nil, false
	}
	return RItem{K: RIPlot, Plot: a}, r1, true
}

// stypBlockAt is `Typ.blockAt`: read the block construct that starts here.
func stypBlockAt(lim *Lim, s []rune) (RItem, []rune, bool) {
	d := func(o string) []rune { return s[utf8.RuneCountInString(o):] }
	switch {
	case textPreS(stypODesc, s):
		return stypDescAt(d(stypODesc))
	case textPreS(stypOBlock, s):
		return stypBlockAtT(lim, d(stypOBlock))
	case textPreS(stypOModel, s):
		return stypCompAt(KindModel, d(stypOModel))
	case textPreS(stypORs, s):
		return stypCompAt(KindRs, d(stypORs))
	case textPreS(stypOCe, s):
		return stypCeAt(lim, d(stypOCe))
	case textPreS(stypORxn, s):
		return stypRxnAtT(lim, d(stypORxn))
	case textPreS(stypOInit, s):
		return stypEqxAt(RoleInit, d(stypOInit))
	case textPreS(stypOCons, s):
		return stypEqxAt(RoleCons, d(stypOCons))
	case textPreS(stypOPlot, s):
		return stypPlotAtT(lim, d(stypOPlot))
	case textPreS(stypOSub, s):
		return stypSubAtT(lim, d(stypOSub))
	case textPreS(stypOTmpl, s):
		return stypTmplAtT(lim, d(stypOTmpl))
	case textPreS(stypORule, s):
		return stypRuleAtT(lim, d(stypORule))
	}
	return stypEqAt(lim, dropN(s, len(stypOEq)))
}

// stypDeclBody is `Typ.declBody`: a declaration after its opener.
func stypDeclBody(lim *Lim, k DKind, s []rune) (RItem, []rune, bool) {
	if len(s) == 0 || s[0] != '$' {
		return RItem{}, nil, false
	}
	name, rest := textTakeWhile(s[1:], func(c rune) bool { return c != '$' })
	if len(rest) == 0 {
		return RItem{}, nil, false
	}
	v, ok := mathParseTypst(lim, symEmpty, string(name))
	n, isStr := v.(string)
	if !ok || !isStr {
		return RItem{}, nil, false
	}
	a, r, ok := stypPArgsMore(lim, rest[1:])
	if !ok {
		return RItem{}, nil, false
	}
	return RItem{K: RIDecl, Decl: Decl{k, n, a}}, r, true
}

// stypDeclAt is `Typ.declAt`.
func stypDeclAt(lim *Lim, s []rune) (RItem, []rune, bool) {
	switch {
	case textPreS(stypOVar, s):
		return stypDeclBody(lim, DKVar, s[len(stypOVar):])
	case textPreS(stypOParam, s):
		return stypDeclBody(lim, DKParam, s[len(stypOParam):])
	}
	return stypDeclBody(lim, DKSpecies, dropN(s, len(stypOSpecies)))
}

// stypLex is `Typ.lex`: the constructs of a text, skipping prose one character
// at a time.
func stypLex(lim *Lim, bol bool, s []rune) ([]RItem, bool) {
	var out []RItem
	for len(s) > 0 {
		c := s[0]
		switch {
		case bol && stypBlockOpen(s):
			it, rest, ok := stypBlockAt(lim, s)
			if !ok {
				return nil, false
			}
			out = append(out, it)
			s, bol = rest, true
		case stypDeclOpen(s):
			it, rest, ok := stypDeclAt(lim, s)
			if !ok {
				return nil, false
			}
			out = append(out, it)
			s, bol = rest, false
		default:
			bol = c == '\n'
			s = s[1:]
		}
	}
	return out, true
}

// ## What each construct needs to read back

// stypTypsiumOk is `Typ.typsiumOK`: no `//` or `/*` in the chemistry.
func stypTypsiumOk(x *Rxn[string]) bool {
	t := rxnSideTxt(stypTypR, x.HasSubs, x.Subs)
	t = pushS(t, x.Rate)
	t = append(t, rxnSideTxt(stypTypR, x.HasProds, x.Prods)...)
	return !textHasSub([]rune("//"), t) && !textHasSub([]rune("/*"), t)
}

// stypRxnOk is `Typ.rxnOK`: a reaction the Typst syntax can hold.
func stypRxnOk(x *Rxn[string]) bool {
	if !rxnSideOk(stypTypR, x.HasSubs, x.Subs) || !rxnSideOk(stypTypR, x.HasProds, x.Prods) ||
		strings.ContainsAny(x.Rate, "$\n") || !rxnIdOk(x.ID) {
		return false
	}
	for _, a := range x.Attrs {
		if !stypArgOk(a) {
			return false
		}
	}
	return stypTypsiumOk(x)
}

// stypDeclOk is `Typ.declOK`.
func stypDeclOk(d *Decl) bool {
	if !exprNameOk(d.Name) || containsRune(stypNameTyp(d.Name), '$') {
		return false
	}
	return stypArgsOk(d.Attrs)
}

func stypArgsOk(as Obj) bool {
	for _, a := range as {
		if !stypArgOk(a) {
			return false
		}
	}
	return true
}

// stypSegText is `Typ.segText` (a Typst document has no code segments).
func stypSegText(s *Seg) []rune {
	switch s.K {
	case SegItem:
		return stypItemT(&s.Item)
	case SegLabeled:
		return stypEqnLabeled(s.Raw, s.Text)
	}
	return s.Text
}

// stypRender is `Typ.render`.
func stypRender(segs []Seg) []rune {
	var out []rune
	for i := range segs {
		out = append(out, stypSegText(&segs[i])...)
	}
	return out
}

// stypIsBlock is `Typ.isBlock`.
func stypIsBlock(it *RItem) bool {
	if it.K == RIDecl {
		return it.Decl.Kind == DKSub
	}
	return true
}

// stypItemOk is `Typ.itemOK`: what each construct's content must satisfy for
// its text to read back.
func stypItemOk(lim *Lim, it *RItem) bool {
	switch it.K {
	case RIDesc, RIComp:
		return true
	case RIBlock:
		return jsonWfmb(it.V)
	case RIDecl:
		if it.Decl.Kind == DKSub {
			return stypArgsOk(it.Decl.Attrs)
		}
		return stypDeclOk(&it.Decl)
	case RIEqn:
		if strings.ContainsRune(it.S, '$') {
			return false
		}
		_, _, _, ok := stypTmLexT(lim, []rune(it.S))
		return !ok
	case RIEqx:
		return it.Role != RoleEqn && !strings.ContainsRune(it.S, '$')
	case RIRxn:
		return stypRxnOk(&it.Rxn)
	case RIPlot:
		return stypArgsOk(it.Plot)
	case RITm:
		t := &it.Tm
		if !stypArgsOk(t.Attrs) {
			return false
		}
		if t.HasLhs {
			return !strings.ContainsRune(t.Lhs, '$') && !strings.ContainsRune(t.Body, '$') && len(t.Params) == 0
		}
		raw := stypTmRawT(t)
		if containsRune(raw, '$') {
			return false
		}
		n, ps, b, ok := stypTmLexT(lim, raw)
		return ok && n == t.Name && stringsEqual(ps, t.Params) && string(b) == t.Body
	}
	return false
}
