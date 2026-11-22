package docfmt

// Typst math: spelling and lexing of tokens. Port of
// formal/Esm/Document/Math/Typst.lean (Rust: document/math/typst.rs); prefix
// `typ`.
//
// Typst has one parenthesis: the lexer reads `(` right after a name, a digit,
// `)` or `"` as a call parenthesis and any other `(` as a grouping one; the
// renderer writes no space between a function name and its `(` and a space
// between an operand and a following grouping `(`.

// ## Spelling

// typTimesTen is `Typst.timesTen`.
const typTimesTen = " times 10^"

// typNumChars is `Typst.numChars`.
func typNumChars(n JNum) []rune {
	if m, e, ok := surfSciSplit(n); ok {
		out := append(m, []rune(typTimesTen)...)
		if e < 0 {
			out = append(out, '(')
			out = append(out, numPrintInt(e)...)
			return append(out, ')')
		}
		return append(out, numPrintInt(e)...)
	}
	return numPrint(n)
}

// typKwTable is `Typst.kwChars` as a table.
var typKwTable = map[Kw]string{
	KwPlus: "+", KwMinus: "-", KwEq: "=", KwNe: "!=", KwLt: "<", KwGt: ">", KwLe: "<=",
	KwGe: ">=", KwLand: "and", KwLor: "or", KwLnot: "not", KwCdot: "dot", KwTimes: "times",
	KwSlash: "/", KwCaret: "^", KwUs: "_", KwLp: "(", KwLpg: "(", KwRp: ")", KwLbk: "[",
	KwRbk: "]", KwComma: ",", KwSemi: ";", KwColon: ":", KwAmp: "&", KwSdot: "\".\"",
	KwSqrt: "sqrt", KwExp: "exp", KwLn: "ln", KwLog: "log", KwSin: "sin", KwCos: "cos",
	KwTan: "tan", KwAsin: "arcsin", KwAcos: "arccos", KwAtan: "arctan", KwSinh: "sinh",
	KwCosh: "cosh", KwTanh: "tanh", KwMin: "min", KwMax: "max", KwAbs: "abs",
	KwFloor: "floor", KwCeil: "ceil", KwPdiff: "partial", KwNabla: "nabla", KwDif: "dif", KwCases: "cases",
	KwEsmnode: "esm.node", KwVec: "vec", KwMat: "mat", KwSum: "sum", KwProd: "product",
	KwInn: "in", KwLimits: "limits", KwLr: "lr", KwNl: "\\",
	KwLset: "{", KwRset: "}",
}

// typKwChars is `Typst.kwChars` (empty for the LaTeX-only keywords).
func typKwChars(k Kw) string { return typKwTable[k] }

// typPieceChars is `Typst.pieceChars`.
func typPieceChars(p UpsPair) []rune {
	out := []rune("upright(")
	out = append(out, strQuote(true, p.A)...)
	out = append(out, ')')
	if p.B != "" {
		out = append(out, '_')
		out = append(out, []rune(p.B)...)
	}
	return out
}

// typUnitChars is `Typst.unitChars`.
func typUnitChars(l []Factor) []rune {
	out := []rune("thin ")
	return append(out, unitsJoinWith(unitsTypstFactor, unitsThinSep, l)...)
}

// typTokChars is `Typst.tokChars`.
func typTokChars(t Tok) []rune {
	call := func(head, s string) []rune {
		out := []rune(head)
		out = append(out, strQuote(true, s)...)
		return append(out, ')')
	}
	switch t.K {
	case TNum:
		return typNumChars(t.N)
	case TLetter:
		return []rune{t.C}
	case TGreek, TWord:
		return []rune(t.S)
	case TIt:
		return call("italic(", t.S)
	case TUps:
		var out []rune
		for _, p := range t.Ups {
			out = append(out, typPieceChars(p)...)
		}
		return out
	case TOpn:
		return call("op(", t.S)
	case TTxt:
		return strQuote(true, t.S)
	case TCode:
		return append([]rune{'#'}, tdictEncode(t.J)...)
	case TUnits:
		return typUnitChars(t.U)
	case TKw:
		return []rune(typKwChars(t.W))
	}
	return nil
}

// typFirstLast are the first and last characters of typTokChars(t), computed
// without building the spelling where that is cheap.
func typFirstLast(t Tok) (first, last rune, ok bool) {
	switch t.K {
	case TLetter:
		return t.C, t.C, true
	case TIt, TOpn:
		// `italic("…")`, `op("…")`
		if t.K == TIt {
			return 'i', ')', true
		}
		return 'o', ')', true
	case TUps:
		if len(t.Ups) == 0 {
			return 0, 0, false
		}
		lp := t.Ups[len(t.Ups)-1]
		if lp.B != "" {
			b := []rune(lp.B)
			return 'u', b[len(b)-1], true
		}
		return 'u', ')', true
	case TTxt:
		return '"', '"', true
	case TKw:
		s := []rune(typKwChars(t.W))
		if len(s) == 0 {
			return 0, 0, false
		}
		return s[0], s[len(s)-1], true
	}
	cs := typTokChars(t)
	if len(cs) == 0 {
		return 0, 0, false
	}
	return cs[0], cs[len(cs)-1], true
}

// ## Spacing

// typIsIdC is `Typst.isIdC`.
func typIsIdC(c rune) bool { return exprIsLetter(c) || exprIsDig(c) }

// typMerges is `Typst.merges`: a space is needed between t and a following
// token starting with c.
func typMerges(t Tok, c rune) bool {
	_, d, ok := typFirstLast(t)
	return (ok && exprIsLetter(d) && typIsIdC(c)) ||
		(t.K == TNum && (typIsIdC(c) || c == '.')) ||
		(t.isKw(KwMinus) && exprIsDig(c)) ||
		(t.K == TUps && (exprIsDig(c) || c == 'u' || c == '_')) ||
		(t.K == TCode && typIsIdC(c)) ||
		(t.K == TUnits && (exprIsDig(c) || c == '^')) ||
		((t.isKw(KwLt) || t.isKw(KwGt)) && c == '=') ||
		(t.isKw(KwSlash) && c == '/')
}

// typCallEnd is `Typst.callEnd`: t ends with a character after which `(` is a
// call parenthesis.
func typCallEnd(t Tok) bool {
	_, d, ok := typFirstLast(t)
	return ok && (typIsIdC(d) || d == ')' || d == '"')
}

// typNeedSpace is `Typst.needSpace`.
func typNeedSpace(t1, t2 Tok) bool {
	switch {
	case t2.isKw(KwLpg):
		return typCallEnd(t1)
	case t2.isKw(KwLp):
		return false
	}
	c, _, ok := typFirstLast(t2)
	return ok && typMerges(t1, c)
}

// typAtomEnd is `Typst.atomEnd`.
func typAtomEnd(t Tok) bool {
	switch t.K {
	case TNum, TLetter, TGreek, TWord, TIt, TUps, TTxt, TCode, TUnits:
		return true
	case TKw:
		return t.W == KwRp || t.W == KwRbk
	}
	return false
}

// typPretty is `Typst.pretty`.
func typPretty(p *Tok, t1, t2 Tok) bool {
	return surfIsBin(t1) || surfIsBin(t2) ||
		t1.isKw(KwComma) || t1.isKw(KwColon) || t1.isKw(KwSemi) ||
		(t2.isKw(KwMinus) && typAtomEnd(t1)) ||
		(t1.isKw(KwMinus) && p != nil && typAtomEnd(*p)) ||
		(typAtomEnd(t1) && psAtomStart(t2)) ||
		t2.K == TUnits
}

// typSp is `Typst.sp`: no space before a call parenthesis, nor before the `[`
// of an index.
func typSp(p *Tok, t1, t2 Tok) bool {
	return typNeedSpace(t1, t2) ||
		(typPretty(p, t1, t2) && !t2.isKw(KwLp) && (!t2.isKw(KwLbk) || !typAtomEnd(t1)))
}

// typRender is `Typst.render` (`renderAux`).
func typRender(ts []Tok) []rune {
	var out []rune
	for i, t := range ts {
		out = append(out, typTokChars(t)...)
		if i+1 < len(ts) {
			var p *Tok
			if i > 0 {
				p = &ts[i-1]
			}
			if typSp(p, t, ts[i+1]) {
				out = append(out, ' ')
			}
		}
	}
	return out
}

// ## Lexing

// typIdRun is `Typst.idRun`: the maximal run of identifier characters.
func typIdRun(cs []rune) ([]rune, []rune) {
	n := 0
	for n < len(cs) && typIsIdC(cs[n]) {
		n++
	}
	return cs[:n], cs[n:]
}

// typIdentKw is `Typst.identKw`.
var typIdentKw = map[string]Kw{
	"and": KwLand, "or": KwLor, "not": KwLnot, "dot": KwCdot, "times": KwTimes,
	"sqrt": KwSqrt, "exp": KwExp, "ln": KwLn, "log": KwLog, "sin": KwSin, "cos": KwCos,
	"tan": KwTan, "arcsin": KwAsin, "arccos": KwAcos, "arctan": KwAtan, "sinh": KwSinh,
	"cosh": KwCosh, "tanh": KwTanh, "min": KwMin, "max": KwMax, "abs": KwAbs,
	"floor": KwFloor, "ceil": KwCeil, "partial": KwPdiff, "nabla": KwNabla, "dif": KwDif, "cases": KwCases,
	"vec": KwVec, "mat": KwMat, "sum": KwSum, "product": KwProd, "in": KwInn,
	"limits": KwLimits, "lr": KwLr,
}

// typQuotedArg is `Typst.quotedArg`: `("…")` after a function name.
func typQuotedArg(r []rune) (string, []rune, bool) {
	if len(r) == 0 || r[0] != '(' {
		return "", nil, false
	}
	s, r1, ok := strParseQuoted(true, r[1:])
	if !ok || len(r1) == 0 || r1[0] != ')' {
		return "", nil, false
	}
	return s, r1[1:], true
}

// typUprightPieces is `Typst.pieces`: adjacent `upright("…")` pieces, each with
// an optional digit subscript.
func typUprightPieces(cs []rune) ([]UpsPair, []rune) {
	var out []UpsPair
	for {
		r, ok := surfDropP("upright", cs)
		if !ok {
			return out, cs
		}
		s, r1, ok := typQuotedArg(r)
		if !ok {
			return out, cs
		}
		var d []rune
		rest := r1
		if len(r1) > 0 && r1[0] == '_' {
			q, r3 := exprDigRun(r1[1:])
			if len(q) > 0 {
				d, rest = q, r3
			}
		}
		out = append(out, UpsPair{s, string(d)})
		cs = rest
	}
}

// typIsWsT is `Typst.isWsT`.
func typIsWsT(c rune) bool { return c == ' ' || c == '\n' || c == '\t' || c == '\r' }

func typSkip(cs []rune) []rune {
	n := 0
	for n < len(cs) && typIsWsT(cs[n]) {
		n++
	}
	return cs[n:]
}

// typSciExp is `Typst.sciExp`: the scientific tail `times 10^exponent` after a
// mantissa (the exponent bare or in parentheses), with any white space between
// its parts.
func typSciExp(r []rune) (int64, []rune, bool) {
	r1, ok := surfDropP("times", typSkip(r))
	if !ok || (len(r1) > 0 && typIsIdC(r1[0])) {
		return 0, nil, false
	}
	r2, ok := surfDropP("10", typSkip(r1))
	if !ok {
		return 0, nil, false
	}
	r3 := typSkip(r2)
	if len(r3) == 0 || r3[0] != '^' {
		return 0, nil, false
	}
	r4 := typSkip(r3[1:])
	if len(r4) > 0 && r4[0] == '(' {
		z, r5, ok := numParseInt(typSkip(r4[1:]))
		if !ok {
			return 0, nil, false
		}
		r6 := typSkip(r5)
		if len(r6) == 0 || r6[0] != ')' {
			return 0, nil, false
		}
		return z, r6[1:], true
	}
	return numParseInt(r4)
}

// typPunct is `Typst.punct`.
func typPunct(c rune) (Kw, bool) {
	switch c {
	case '+':
		return KwPlus, true
	case '-':
		return KwMinus, true
	case '=':
		return KwEq, true
	case '<':
		return KwLt, true
	case '>':
		return KwGt, true
	case '/':
		return KwSlash, true
	case '^':
		return KwCaret, true
	case '_':
		return KwUs, true
	case ')':
		return KwRp, true
	case '[':
		return KwLbk, true
	case ']':
		return KwRbk, true
	case ',':
		return KwComma, true
	case ';':
		return KwSemi, true
	case ':':
		return KwColon, true
	case '&':
		return KwAmp, true
	case '.':
		return KwSdot, true
	case '\\':
		return KwNl, true
	case '{':
		return KwLset, true
	case '}':
		return KwRset, true
	}
	return 0, false
}

// typUprightE is `Typst.uprightE`: `upright(e)`, Euler's number written
// without quotes.
func typUprightE(cs []rune) (Tok, []rune, bool) {
	if r, ok := cutPrefix(cs, "(e)"); ok {
		return tUps([]UpsPair{{"e", ""}}), r, true
	}
	return Tok{}, nil, false
}

// typLexIdent is `Typst.lexIdent`: one identifier-started token.
func typLexIdent(cs []rune) (Tok, []rune, bool) {
	w, rest := typIdRun(cs)
	ws := string(w)
	switch ws {
	case "upright":
		if t, r, ok := typUprightE(rest); ok {
			return t, r, true
		}
		ps, r := typUprightPieces(cs)
		if len(ps) == 0 {
			return Tok{}, nil, false
		}
		return tUps(ps), r, true
	case "italic":
		s, r, ok := typQuotedArg(rest)
		if !ok {
			return Tok{}, nil, false
		}
		return tIt(s), r, true
	case "op":
		s, r, ok := typQuotedArg(rest)
		if !ok {
			return Tok{}, nil, false
		}
		return tOpn(s), r, true
	case "thin":
		if len(rest) == 0 || rest[0] != ' ' {
			return Tok{}, nil, false
		}
		l, r2, ok := unitsPSepBy(unitsPTFactor, unitsThinSep, rest[1:])
		if !ok {
			return Tok{}, nil, false
		}
		return tUnits(l), r2, true
	case "esm":
		r, ok := surfDropP(".node", rest)
		if !ok {
			return Tok{}, nil, false
		}
		return tKw(KwEsmnode), r, true
	}
	if k, ok := typIdentKw[ws]; ok {
		return tKw(k), rest, true
	}
	if exprIsGreek(w) {
		return tGreek(ws), rest, true
	}
	if len(w) == 1 {
		return tLetter(w[0]), rest, true
	}
	return tWord(ws), rest, true
}

// typLexOne is `Typst.lexOne`: one token at the front of the input; prev is
// the character just before it, if no space came between (hasPrev).
func typLexOne(lim *Lim, prev rune, hasPrev bool, cs []rune) (Tok, []rune, bool) {
	if len(cs) == 0 {
		return Tok{}, nil, false
	}
	c, r := cs[0], cs[1:]
	switch {
	case c == '(':
		if hasPrev && (typIsIdC(prev) || prev == ')' || prev == '"') {
			return tKw(KwLp), r, true
		}
		return tKw(KwLpg), r, true
	case c == '"':
		s, r2, ok := strParseQuoted(true, cs)
		if !ok {
			return Tok{}, nil, false
		}
		if s == "." {
			return tKw(KwSdot), r2, true
		}
		return tTxt(s), r2, true
	case c == '#':
		v, r2, ok := tdictPVal(lim, r)
		if !ok {
			return Tok{}, nil, false
		}
		return tCode(v), r2, true
	case c == '<' && len(r) > 0 && r[0] == '=':
		return tKw(KwLe), r[1:], true
	case c == '>' && len(r) > 0 && r[0] == '=':
		return tKw(KwGe), r[1:], true
	case c == '!' && len(r) > 0 && r[0] == '=':
		return tKw(KwNe), r[1:], true
	case exprIsDig(c) || (c == '-' && len(r) > 0 && exprIsDig(r[0])):
		return surfLexSigned(typSciExp, cs)
	case exprIsLetter(c):
		return typLexIdent(cs)
	}
	if k, ok := typPunct(c); ok {
		return tKw(k), r, true
	}
	return Tok{}, nil, false
}

// typLex is `Typst.lex`: read Typst math into tokens (`lexAux`). prev is the
// last character of the previous token's canonical spelling when no space came
// between.
func typLex(lim *Lim, cs []rune) ([]Tok, bool) {
	out := []Tok{}
	var prev rune
	hasPrev := false
	for {
		hasPrev2 := hasPrev && (len(cs) == 0 || !typIsWsT(cs[0]))
		cs2 := typSkip(cs)
		if len(cs2) == 0 {
			return out, true
		}
		t, r, ok := typLexOne(lim, prev, hasPrev2, cs2)
		if !ok {
			return nil, false
		}
		_, prev, hasPrev = typFirstLast(t)
		out = append(out, t)
		cs = r
	}
}
