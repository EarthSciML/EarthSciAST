package docfmt

// LaTeX math: spelling and lexing of tokens. Port of
// formal/Esm/Document/Math/Latex.lean (Rust: document/math/latex.rs); prefix
// `latex`.
//
// latexRender spells a token list as LaTeX math, writing a space between two
// tokens where the reader needs one (needSpace) and where it reads better
// (pretty); latexLex reads it back, skipping spaces and the spacing commands.

import (
	"slices"
	"strings"
)

// ## Spelling

// `Latex.specials`, `escCharB`, `escCharL` and `quoteL` (the JSON-string
// spelling with hex escapes) have no executable use; the printer writes JSON
// strings with latexStrL. `fixUs` is used only through latexFixUsQuoted.

// latexFixUsQuoted is `Latex.fixUs` (undo the `\_` of `escCharL` up to the
// closing quote) stopped at that quote: the fixed text through the quote, and
// the input after it (ok false when there is none). Lean fixes the whole rest
// of the input; the string read is the same, because fixUs changes nothing
// after the quote, and this does not copy the rest of the input per string.
func latexFixUsQuoted(cs []rune) ([]rune, []rune, bool) {
	var out []rune
	for len(cs) > 0 {
		switch {
		case cs[0] == '\\' && len(cs) >= 2 && cs[1] == '_':
			out = append(out, '_')
			cs = cs[2:]
		case cs[0] == '\\' && len(cs) >= 2:
			out = append(out, '\\', cs[1])
			cs = cs[2:]
		case cs[0] == '"':
			return append(out, '"'), cs[1:], true
		default:
			out = append(out, cs[0])
			cs = cs[1:]
		}
	}
	return out, nil, false
}

// latexStrPlain is `Latex.strPlain`: a character of a JSON string written as
// itself inside `\text{…}`.
func latexStrPlain(c rune) bool {
	return c >= 32 && c <= 126 && !prKeySpecial(c) && c != '_' && c != '{' && c != '}'
}

// latexDig7 is `Latex.dig7`: seven decimal digits.
func latexDig7(n uint32) []rune {
	out := make([]rune, 7)
	p := uint32(1000000)
	for i := range out {
		out[i] = numDigitChar(byte(n / p % 10))
		p /= 10
	}
	return out
}

// latexEscS is `Latex.escS`: the spelling of a JSON string's characters inside
// `\text{"…"}`.
func latexEscS(cs []rune) []rune {
	var out []rune
	for _, c := range cs {
		switch {
		case latexStrPlain(c):
			out = append(out, c)
		case c == '_' || c == '{' || c == '}':
			out = append(out, '\\', c)
		case uint32(c) < 1000:
			out = append(out, []rune("{\\char")...)
			out = append(out, prDig3(uint32(c))...)
			out = append(out, '}')
		default:
			out = append(out, []rune("{\\char")...)
			out = append(out, latexDig7(uint32(c))...)
			out = append(out, '}')
		}
	}
	return out
}

// latexUnescS is `Latex.unescS`: undo latexEscS.
func latexUnescS(cs []rune) []rune {
	var out []rune
	d := prCharDigitNat
	for len(cs) > 0 {
		if len(cs) >= 10 && hasPrefix(cs, "{\\char") && cs[9] == '}' {
			out = append(out, prCharOfNat(100*d(cs[6])+10*d(cs[7])+d(cs[8])))
			cs = cs[10:]
			continue
		}
		if len(cs) >= 14 && hasPrefix(cs, "{\\char") && cs[13] == '}' {
			v := uint64(0)
			for i := 6; i < 13; i++ {
				v = v*10 + d(cs[i])
			}
			out = append(out, prCharOfNat(v))
			cs = cs[14:]
			continue
		}
		if cs[0] == '\\' && len(cs) >= 2 {
			out = append(out, cs[1])
			cs = cs[2:]
			continue
		}
		out = append(out, cs[0])
		cs = cs[1:]
	}
	return out
}

// latexStrL is `Latex.strL`: a JSON string in LaTeX: `\text{"…"}`.
func latexStrL(s string) []rune {
	out := []rune("\\text{\"")
	out = append(out, latexEscS([]rune(s))...)
	return append(out, '"', '}')
}

// latexTextTok is `Latex.textTok`: the token of `\text{raw}`: a JSON string
// when the text is double-quoted, else text.
func latexTextTok(raw []rune) Tok {
	if len(raw) >= 2 && raw[0] == '"' && raw[len(raw)-1] == '"' {
		return tJstr(string(latexUnescS(raw[1 : len(raw)-1])))
	}
	return tTxt(string(raw))
}

// latexTimesTen is `Latex.timesTen`.
const latexTimesTen = " \\times 10^{"

// latexNumChars is `Latex.numChars`.
func latexNumChars(n JNum) []rune {
	if m, e, ok := surfSciSplit(n); ok {
		out := append(m, []rune(latexTimesTen)...)
		out = append(out, numPrintInt(e)...)
		return append(out, '}')
	}
	return numPrint(n)
}

// latexKwTable is `Latex.kwChars` as a table.
var latexKwTable = map[Kw]string{
	KwPlus: "+", KwMinus: "-", KwEq: "=", KwNe: "\\ne", KwLt: "<", KwGt: ">",
	KwLe: "\\le", KwGe: "\\ge", KwLand: "\\land", KwLor: "\\lor", KwLnot: "\\lnot",
	KwCdot: "\\cdot", KwTimes: "\\times", KwSlash: "/", KwCaret: "^", KwUs: "_",
	KwLp: "(", KwRp: ")", KwLpg: "\\left(", KwRpg: "\\right)", KwLb: "{", KwRb: "}",
	KwLbk: "[", KwRbk: "]", KwComma: ",", KwSemi: ";", KwColon: ":", KwAmp: "&",
	KwNl: "\\\\", KwSdot: ".", KwFrac: "\\frac", KwSqrt: "\\sqrt", KwExp: "\\exp",
	KwLn: "\\ln", KwLog: "\\log", KwSin: "\\sin", KwCos: "\\cos", KwTan: "\\tan",
	KwAsin: "\\arcsin", KwAcos: "\\arccos", KwAtan: "\\arctan", KwSinh: "\\sinh",
	KwCosh: "\\cosh", KwTanh: "\\tanh", KwMin: "\\min", KwMax: "\\max",
	KwLabs: "\\left|", KwRabs: "\\right|", KwLfloor: "\\lfloor", KwRfloor: "\\rfloor",
	KwLceil: "\\lceil", KwRceil: "\\rceil", KwPdiff: "\\partial", KwDotacc: "\\dot", KwNabla: "\\nabla",
	KwBcases: "\\begin{cases}", KwEcases: "\\end{cases}", KwBmat: "\\begin{bmatrix}",
	KwEmat: "\\end{bmatrix}", KwSum: "\\sum", KwProd: "\\prod", KwInn: "\\in",
	KwSubstack: "\\substack", KwLimitsL: "\\limits", KwLbkg: "\\left[", KwRbkg: "\\right]",
	KwBarr: "\\begin{array}{l|l}", KwEarr: "\\end{array}",
	KwLset: "\\{", KwRset: "\\}",
}

// latexKwChars is `Latex.kwChars` (empty for the Typst-only keywords).
func latexKwChars(k Kw) string { return latexKwTable[k] }

// latexTokChars is `Latex.tokChars`.
func latexTokChars(t Tok) []rune {
	wrap := func(open string, body []rune) []rune {
		out := []rune(open)
		out = append(out, body...)
		return append(out, '}')
	}
	esc := func(s string) []rune { return prEscT([]rune(s)) }
	switch t.K {
	case TNum:
		return latexNumChars(t.N)
	case TLetter:
		return []rune{t.C}
	case TGreek:
		return append([]rune{'\\'}, []rune(t.S)...)
	case TWord:
		return []rune(t.S)
	case TIt:
		return wrap("\\mathit{", esc(t.S))
	case TRm:
		return wrap("\\mathrm{", []rune(t.S))
	case TOpn:
		return wrap("\\operatorname{", esc(t.S))
	case TTxt:
		return wrap("\\text{", []rune(t.S))
	case TJstr:
		return latexStrL(t.S)
	case TEsc:
		return wrap("\\esm{", esc(t.S))
	case TUnits:
		return wrap("\\,\\mathrm{", unitsLatexBody(t.U))
	case TKw:
		return []rune(latexKwChars(t.W))
	case TArrC:
		return []rune("\\begin{array}{" + strings.Repeat("c", t.Cols) + "}")
	}
	return nil
}

// latexFirstChar is the first character of latexTokChars(t), without
// building the whole spelling where that is cheap.
func latexFirstChar(t Tok) (rune, bool) {
	switch t.K {
	case TLetter:
		return t.C, true
	case TGreek, TIt, TRm, TOpn, TTxt, TJstr, TEsc, TUnits, TArrC:
		return '\\', true
	case TWord:
		for _, c := range t.S {
			return c, true
		}
		return 0, false
	case TKw:
		for _, c := range latexKwChars(t.W) {
			return c, true
		}
		return 0, false
	case TNum:
		cs := latexNumChars(t.N)
		if len(cs) == 0 {
			return 0, false
		}
		return cs[0], true
	}
	return 0, false
}

// ## Spacing

// latexEndsAlpha is `Latex.endsAlpha`: t ends with letters a following letter
// would extend.
func latexEndsAlpha(t Tok) bool {
	switch t.K {
	case TLetter, TWord, TGreek:
		return true
	case TKw:
		s := latexKwChars(t.W)
		return s != "" && exprIsLetter(rune(s[len(s)-1]))
	}
	return false
}

// latexMerges is `Latex.merges`: a space is needed between t and a following
// token starting with c.
func latexMerges(t Tok, c rune) bool {
	return (latexEndsAlpha(t) && exprIsLetter(c)) ||
		(t.K == TNum && (exprIsDig(c) || c == '.' || c == 'e')) ||
		(t.isKw(KwMinus) && exprIsDig(c))
}

// latexNeedSpace is `Latex.needSpace`.
func latexNeedSpace(t1, t2 Tok) bool {
	c, ok := latexFirstChar(t2)
	return ok && latexMerges(t1, c)
}

// latexAtomEnd is `Latex.atomEnd`: tokens that end an operand.
func latexAtomEnd(t Tok) bool {
	switch t.K {
	case TNum, TLetter, TGreek, TWord, TIt, TRm, TUps, TTxt, TJstr, TCode, TUnits:
		return true
	case TKw:
		switch t.W {
		case KwRp, KwRpg, KwRb, KwRbk, KwRabs, KwRfloor, KwRceil, KwEcases:
			return true
		}
	}
	return false
}

// latexPretty is `Latex.pretty`: spacing for reading.
func latexPretty(p *Tok, t1, t2 Tok) bool {
	return surfIsBin(t1) || surfIsBin(t2) ||
		t1.isKw(KwComma) || t1.isKw(KwColon) || t1.isKw(KwSemi) ||
		(t2.isKw(KwMinus) && latexAtomEnd(t1)) ||
		(t1.isKw(KwMinus) && p != nil && latexAtomEnd(*p)) ||
		(latexAtomEnd(t1) && psAtomStart(t2) && !t2.isKw(KwLp) && !t2.isKw(KwLbk)) ||
		t1.isKw(KwBarr) || t2.isKw(KwEarr)
}

// latexSp is `Latex.sp`.
func latexSp(p *Tok, t1, t2 Tok) bool { return latexNeedSpace(t1, t2) || latexPretty(p, t1, t2) }

// latexRender is `Latex.render`: the LaTeX spelling of a token list
// (`renderAux`).
func latexRender(ts []Tok) []rune {
	var out []rune
	for i, t := range ts {
		out = append(out, latexTokChars(t)...)
		if i+1 < len(ts) {
			var p *Tok
			if i > 0 {
				p = &ts[i-1]
			}
			if latexSp(p, t, ts[i+1]) {
				out = append(out, ' ')
			}
		}
	}
	return out
}

// ## Lexing

// latexCtrlKw is `Latex.ctrlKw`: control words that are keywords, with the
// variants read on input.
var latexCtrlKw = map[string]Kw{
	"ne": KwNe, "neq": KwNe, "le": KwLe, "leq": KwLe, "ge": KwGe, "geq": KwGe,
	"land": KwLand, "lor": KwLor, "lnot": KwLnot, "cdot": KwCdot, "times": KwTimes,
	"frac": KwFrac, "sqrt": KwSqrt, "exp": KwExp, "ln": KwLn, "log": KwLog,
	"sin": KwSin, "cos": KwCos, "tan": KwTan, "arcsin": KwAsin, "arccos": KwAcos,
	"arctan": KwAtan, "sinh": KwSinh, "cosh": KwCosh, "tanh": KwTanh, "min": KwMin,
	"max": KwMax, "lfloor": KwLfloor, "rfloor": KwRfloor, "lceil": KwLceil,
	"rceil": KwRceil, "partial": KwPdiff, "nabla": KwNabla, "dot": KwDotacc, "sum": KwSum,
	"prod": KwProd, "in": KwInn, "substack": KwSubstack, "limits": KwLimitsL,
}

// latexCtrlTok is `Latex.ctrlTok`: after a control word: its token.
func latexCtrlTok(w string, r []rune) (Tok, []rune, bool) {
	switch w {
	case "mathit", "mathrm", "operatorname", "text", "esm":
		if len(r) == 0 || r[0] != '{' {
			return Tok{}, nil, false
		}
		raw, rest, ok := prRawB(0, r[1:])
		if !ok {
			return Tok{}, nil, false
		}
		switch w {
		case "mathit":
			return tIt(string(prUnescT(raw))), rest, true
		case "mathrm":
			return tRm(string(raw)), rest, true
		case "operatorname":
			return tOpn(string(prUnescT(raw))), rest, true
		case "text":
			return latexTextTok(raw), rest, true
		}
		return tEsc(string(prUnescT(raw))), rest, true
	case "left", "bigl", "Bigl":
		if len(r) == 0 {
			return Tok{}, nil, false
		}
		switch r[0] {
		case '(':
			return tKw(KwLpg), r[1:], true
		case '[':
			if w == "left" {
				return tKw(KwLbkg), r[1:], true
			}
			return tKw(KwLbk), r[1:], true
		case '|':
			if w == "left" {
				return tKw(KwLabs), r[1:], true
			}
		}
		return Tok{}, nil, false
	case "right", "bigr", "Bigr":
		if len(r) == 0 {
			return Tok{}, nil, false
		}
		switch r[0] {
		case ')':
			return tKw(KwRpg), r[1:], true
		case ']':
			if w == "right" {
				return tKw(KwRbkg), r[1:], true
			}
			return tKw(KwRbk), r[1:], true
		case '|':
			if w == "right" {
				return tKw(KwRabs), r[1:], true
			}
		}
		return Tok{}, nil, false
	case "begin":
		if r2, ok := surfDropP("{cases}", r); ok {
			return tKw(KwBcases), r2, true
		}
		if r2, ok := surfDropP("{bmatrix}", r); ok {
			return tKw(KwBmat), r2, true
		}
		if r2, ok := surfDropP("{array}{l|l}", r); ok {
			return tKw(KwBarr), r2, true
		}
		if r2, ok := surfDropP("{array}{", r); ok {
			n := 0
			for n < len(r2) && r2[n] == 'c' {
				n++
			}
			if n > 0 && n < len(r2) && r2[n] == '}' {
				return tArrC(n), r2[n+1:], true
			}
		}
		return Tok{}, nil, false
	case "end":
		if r2, ok := surfDropP("{cases}", r); ok {
			return tKw(KwEcases), r2, true
		}
		if r2, ok := surfDropP("{bmatrix}", r); ok {
			return tKw(KwEmat), r2, true
		}
		if r2, ok := surfDropP("{array}", r); ok {
			return tKw(KwEarr), r2, true
		}
		return Tok{}, nil, false
	}
	if slices.Contains(exprGreek, w) {
		return tGreek(w), r, true
	}
	if k, ok := latexCtrlKw[w]; ok {
		return tKw(k), r, true
	}
	return Tok{}, nil, false
}

// latexIsWsL is `Latex.isWsL`: white space.
func latexIsWsL(c rune) bool { return c == ' ' || c == '\n' || c == '\t' || c == '\r' }

// latexSkipSp is `Latex.skipSp`: skip white space and the two-character
// spacing commands, inside a scientific tail.
func latexSkipSp(cs []rune) []rune {
	for {
		switch {
		case len(cs) > 0 && latexIsWsL(cs[0]):
			cs = cs[1:]
		case len(cs) >= 2 && cs[0] == '\\' && (cs[1] == ';' || cs[1] == ':' || cs[1] == '!' || cs[1] == ' ' || cs[1] == ','):
			cs = cs[2:]
		default:
			return cs
		}
	}
}

// latexSciExp is `Latex.sciExp`: the scientific tail `\times 10^{exponent}`
// after a mantissa, with any spacing between its parts.
func latexSciExp(r []rune) (int64, []rune, bool) {
	r1, ok := surfDropP("\\times", latexSkipSp(r))
	if !ok || (len(r1) > 0 && exprIsLetter(r1[0])) {
		return 0, nil, false
	}
	r2, ok := surfDropP("10", latexSkipSp(r1))
	if !ok {
		return 0, nil, false
	}
	r3 := latexSkipSp(r2)
	if len(r3) == 0 || r3[0] != '^' {
		return 0, nil, false
	}
	r4 := latexSkipSp(r3[1:])
	if len(r4) == 0 || r4[0] != '{' {
		return 0, nil, false
	}
	z, r5, ok := numParseInt(latexSkipSp(r4[1:]))
	if !ok {
		return 0, nil, false
	}
	r6 := latexSkipSp(r5)
	if len(r6) == 0 || r6[0] != '}' {
		return 0, nil, false
	}
	return z, r6[1:], true
}

// latexUnitTok is `Latex.unitTok`: after `\,`: a unit `\mathrm{…}`, with white
// space between.
func latexUnitTok(r []rune) ([]Factor, []rune, bool) {
	n := 0
	for n < len(r) && latexIsWsL(r[n]) {
		n++
	}
	r1, ok := surfDropP(unitsMathrmOpen, r[n:])
	if !ok {
		return nil, nil, false
	}
	raw, r2, ok := prRawB(0, r1)
	if !ok {
		return nil, nil, false
	}
	l, ok := psUnitsOfRaw(raw)
	if !ok {
		return nil, nil, false
	}
	return l, r2, true
}

// latexPunct is `Latex.punct`.
func latexPunct(c rune) (Kw, bool) {
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
	case '(':
		return KwLp, true
	case ')':
		return KwRp, true
	case '{':
		return KwLb, true
	case '}':
		return KwRb, true
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
	}
	return 0, false
}

// latexLexOne is `Latex.lexOne`: one token at the front of the input.
func latexLexOne(cs []rune) (Tok, []rune, bool) {
	if len(cs) == 0 {
		return Tok{}, nil, false
	}
	c := cs[0]
	if c == '\\' && len(cs) >= 2 {
		d, r := cs[1], cs[2:]
		switch {
		case exprIsLetter(d):
			w, rest := exprLetRun(cs[1:])
			return latexCtrlTok(string(w), rest)
		case d == ',':
			l, r2, ok := latexUnitTok(r)
			if !ok {
				return Tok{}, nil, false
			}
			return tUnits(l), r2, true
		case d == '\\':
			return tKw(KwNl), r, true
		case d == '{':
			return tKw(KwLset), r, true
		case d == '}':
			return tKw(KwRset), r, true
		}
		return Tok{}, nil, false
	}
	if c == '"' {
		fixed, rest, ok := latexFixUsQuoted(cs[1:])
		if !ok {
			return Tok{}, nil, false
		}
		body, after, ok := strUnquoteBody(false, fixed)
		if !ok || len(after) != 0 {
			return Tok{}, nil, false
		}
		return tJstr(string(body)), rest, true
	}
	r := cs[1:]
	switch {
	case exprIsDig(c) || (c == '-' && len(r) > 0 && exprIsDig(r[0])):
		return surfLexSigned(latexSciExp, cs)
	case exprIsLetter(c):
		w, rest := exprLetRun(cs)
		if len(w) == 1 {
			return tLetter(w[0]), rest, true
		}
		return tWord(string(w)), rest, true
	}
	if k, ok := latexPunct(c); ok {
		return tKw(k), r, true
	}
	return Tok{}, nil, false
}

// latexSkipWs is `Latex.skipWs`: skip spaces and the spacing commands (`\,`
// too, unless a unit follows it).
func latexSkipWs(cs []rune) []rune {
	for {
		switch {
		case len(cs) > 0 && latexIsWsL(cs[0]):
			cs = cs[1:]
		case len(cs) >= 2 && cs[0] == '\\':
			d, r2 := cs[1], cs[2:]
			switch d {
			case ';', ':', '!', ' ':
				cs = r2
			case ',':
				if _, _, ok := latexUnitTok(r2); ok {
					return cs
				}
				cs = r2
			default:
				w, rest := exprLetRun(cs[1:])
				if s := string(w); s == "quad" || s == "qquad" {
					cs = rest
				} else {
					return cs
				}
			}
		default:
			return cs
		}
	}
}

// latexLex is `Latex.lex`: read LaTeX math into tokens (`lexAux`).
func latexLex(cs []rune) ([]Tok, bool) {
	out := []Tok{}
	for {
		cs2 := latexSkipWs(cs)
		if len(cs2) == 0 {
			return out, true
		}
		t, r, ok := latexLexOne(cs2)
		if !ok {
			return nil, false
		}
		out = append(out, t)
		cs = r
	}
}
