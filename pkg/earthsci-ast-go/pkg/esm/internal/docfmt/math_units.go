package docfmt

// Typeset unit spellings: LaTeX and Typst, with no unit package. Port of
// formal/Esm/Units/Typeset.lean (Rust: document/math/units.rs); prefix
// `units`.
//
// LaTeX: the canonical spelling's layout inside `\mathrm{…}`: numerator
// factors joined by `\,`, a denominator after `/` (parenthesized when it has
// more than one factor), exponents as braced superscripts, `_` and `%`
// escaped.
//
// Typst: one `upright("sym")^(exp)` per factor with its signed exponent,
// factors separated by ` thin `.

import "math/big"

// unitsIsDigitC is `Esm.Units.isDigitC`.
func unitsIsDigitC(c rune) bool { return c >= '0' && c <= '9' }

// unitsIsIdent is `Esm.Units.isIdent`: characters that may occur in a symbol
// run.
func unitsIsIdent(c rune) bool { return strIsIdentChar(c) }

// unitsNumFactors is `Esm.Units.numFactors`: the factors with a positive
// exponent.
func unitsNumFactors(l []Factor) []Factor {
	var out []Factor
	for _, f := range l {
		if f.Exp.Sign() > 0 {
			out = append(out, f)
		}
	}
	return out
}

// unitsDenFactors is `Esm.Units.denFactors`: the factors with a nonpositive
// exponent.
func unitsDenFactors(l []Factor) []Factor {
	var out []Factor
	for _, f := range l {
		if f.Exp.Sign() <= 0 {
			out = append(out, f)
		}
	}
	return out
}

// unitsSymRunB is `Esm.Units.symRunB` (Canonical.lean).
func unitsSymRunB(s string) bool {
	if s == "" {
		return false
	}
	allDig := true
	for _, c := range s {
		if !unitsIsIdent(c) {
			return false
		}
		if !unitsIsDigitC(c) {
			allDig = false
		}
	}
	return !allDig
}

// unitsSymOk is `Esm.Units.symOK` (Canonical.lean): `%`, or a symbol run, and
// not `dimensionless`.
func unitsSymOk(s string) bool {
	return (s == "%" || unitsSymRunB(s)) && s != "dimensionless"
}

// unitsDigs is `Esm.Units.digs`: the decimal digits of n (empty for 0).
func unitsDigs(n *big.Int) []rune {
	if n.Sign() == 0 {
		return nil
	}
	return []rune(n.String())
}

// unitsPDigits is `Esm.Units.pDigits`: a nonempty digit run and its value.
func unitsPDigits(cs []rune) (*big.Int, []rune, bool) {
	n := 0
	for n < len(cs) && unitsIsDigitC(cs[n]) {
		n++
	}
	if n == 0 {
		return nil, nil, false
	}
	v, _ := new(big.Int).SetString(string(cs[:n]), 10)
	return v, cs[n:], true
}

// unitsJoinWith is `Esm.Units.joinWith`.
func unitsJoinWith(pr func(Factor) []rune, sep string, l []Factor) []rune {
	var out []rune
	for i, f := range l {
		if i > 0 {
			out = append(out, []rune(sep)...)
		}
		out = append(out, pr(f)...)
	}
	return out
}

// unitsPSepBy is `Esm.Units.pSepBy`: items read by pf, separated by sep (the
// Lean fuel is never exhausted and is dropped).
func unitsPSepBy(pf func([]rune) (Factor, []rune, bool), sep string, cs []rune) ([]Factor, []rune, bool) {
	var out []Factor
	for {
		f, r, ok := pf(cs)
		if !ok {
			return nil, nil, false
		}
		out = append(out, f)
		r2, ok := cutPrefix(r, sep)
		if !ok {
			return out, r, true
		}
		cs = r2
	}
}

// unitsRatio is p / d as Lean's rational division (x / 0 = 0).
func unitsRatio(p *big.Rat, d *big.Int) *big.Rat {
	if d.Sign() == 0 {
		return new(big.Rat)
	}
	return new(big.Rat).Quo(p, new(big.Rat).SetInt(d))
}

func unitsRat(p *big.Int) *big.Rat { return new(big.Rat).SetInt(p) }

func unitsIsOne(q *big.Rat) bool { return q.IsInt() && q.Num().Cmp(big.NewInt(1)) == 0 }

// ## LaTeX

// unitsLatexSym is `Esm.Units.latexSym`: `_` and `%` escaped with a backslash.
func unitsLatexSym(cs []rune) []rune {
	var out []rune
	for _, c := range cs {
		if c == '_' || c == '%' {
			out = append(out, '\\')
		}
		out = append(out, c)
	}
	return out
}

// unitsLatexExp is `Esm.Units.latexExp`: a positive exponent as a braced
// superscript (nothing for 1).
func unitsLatexExp(q *big.Rat) []rune {
	if unitsIsOne(q) {
		return nil
	}
	out := []rune{'^', '{'}
	out = append(out, unitsDigs(new(big.Int).Abs(q.Num()))...)
	if !q.IsInt() {
		out = append(out, '/')
		out = append(out, unitsDigs(q.Denom())...)
	}
	return append(out, '}')
}

// unitsLatexFactor is `Esm.Units.latexFactor`: one factor, with the absolute
// value of its exponent.
func unitsLatexFactor(f Factor) []rune {
	out := unitsLatexSym([]rune(f.Sym))
	return append(out, unitsLatexExp(new(big.Rat).Abs(f.Exp))...)
}

// unitsLatexSep is `Esm.Units.latexSep`.
const unitsLatexSep = "\\,"

// unitsLatexBody is `Esm.Units.latexBody`: the body of `\mathrm{…}`.
func unitsLatexBody(l []Factor) []rune {
	nf := unitsNumFactors(l)
	var out []rune
	if len(nf) == 0 {
		out = []rune{'1'}
	} else {
		out = unitsJoinWith(unitsLatexFactor, unitsLatexSep, nf)
	}
	df := unitsDenFactors(l)
	switch len(df) {
	case 0:
	case 1:
		out = append(out, '/')
		out = append(out, unitsLatexFactor(df[0])...)
	default:
		out = append(out, '/', '(')
		out = append(out, unitsJoinWith(unitsLatexFactor, unitsLatexSep, df)...)
		out = append(out, ')')
	}
	return out
}

// unitsMathrmOpen is `Esm.Units.mathrmOpen`.
const unitsMathrmOpen = "\\mathrm{"

// unitsLatex is `Esm.Units.latex`: the LaTeX form of a canonical factor list.
func unitsLatex(l []Factor) []rune {
	out := []rune(unitsMathrmOpen)
	out = append(out, unitsLatexBody(l)...)
	return append(out, '}')
}

// unitsPLSym is `Esm.Units.pLSym`: identifier characters, `%`, and the
// escapes `\_`, `\%`.
func unitsPLSym(cs []rune) ([]rune, []rune) {
	var out []rune
	for {
		switch {
		case len(cs) > 0 && (unitsIsIdent(cs[0]) || cs[0] == '%'):
			out = append(out, cs[0])
			cs = cs[1:]
		case len(cs) > 1 && cs[0] == '\\' && (cs[1] == '_' || cs[1] == '%'):
			out = append(out, cs[1])
			cs = cs[2:]
		default:
			return out, cs
		}
	}
}

// unitsPLExp is `Esm.Units.pLExp`: a braced superscript, or nothing
// (exponent 1).
func unitsPLExp(cs []rune) (*big.Rat, []rune, bool) {
	r, ok := cutPrefix(cs, "^{")
	if !ok {
		return big.NewRat(1, 1), cs, true
	}
	p, r1, ok := unitsPDigits(r)
	if !ok || len(r1) == 0 {
		return nil, nil, false
	}
	switch r1[0] {
	case '}':
		return unitsRat(p), r1[1:], true
	case '/':
		d, r3, ok := unitsPDigits(r1[1:])
		if ok && len(r3) > 0 && r3[0] == '}' {
			return unitsRatio(unitsRat(p), d), r3[1:], true
		}
	}
	return nil, nil, false
}

// unitsPLFactor is `Esm.Units.pLFactor`.
func unitsPLFactor(cs []rune) (Factor, []rune, bool) {
	s, r := unitsPLSym(cs)
	if len(s) == 0 {
		return Factor{}, nil, false
	}
	q, r2, ok := unitsPLExp(r)
	if !ok {
		return Factor{}, nil, false
	}
	return Factor{Sym: string(s), Exp: q}, r2, true
}

// unitsPLDen is `Esm.Units.pLDen`: a LaTeX denominator (after the `/`).
func unitsPLDen(r []rune) ([]Factor, bool) {
	if len(r) > 0 && r[0] == '(' {
		den, rest, ok := unitsPSepBy(unitsPLFactor, unitsLatexSep, r[1:])
		if ok && len(rest) == 1 && rest[0] == ')' {
			return den, true
		}
		return nil, false
	}
	den, rest, ok := unitsPSepBy(unitsPLFactor, unitsLatexSep, r)
	if ok && len(rest) == 0 && len(den) == 1 {
		return den, true
	}
	return nil, false
}

// unitsParseLatex is `Esm.Units.parseLatex`: a LaTeX unit back to its
// two-sided factor list.
func unitsParseLatex(s []rune) ([]Factor, bool) {
	body, ok := cutPrefix(s, unitsMathrmOpen)
	if !ok || len(body) == 0 || body[len(body)-1] != '}' {
		return nil, false
	}
	b := body[:len(body)-1]
	num, rest, ok := unitsPSepBy(unitsPLFactor, unitsLatexSep, b)
	if !ok {
		return nil, false
	}
	if len(num) == 1 && num[0].Sym == "1" && unitsIsOne(num[0].Exp) {
		num = nil
	}
	if len(rest) == 0 {
		if num == nil {
			num = []Factor{}
		}
		return num, true
	}
	if rest[0] != '/' {
		return nil, false
	}
	den, ok := unitsPLDen(rest[1:])
	if !ok {
		return nil, false
	}
	out := append([]Factor{}, num...)
	for _, f := range den {
		out = append(out, Factor{Sym: f.Sym, Exp: new(big.Rat).Neg(f.Exp)})
	}
	return out, true
}

// ## Typst

const (
	unitsUprightOpen  = "upright(\""
	unitsUprightClose = "\")"
	unitsThinSep      = " thin "
)

// unitsTypstExp is `Esm.Units.typstExp`: a signed exponent: nothing for 1,
// `^n`, `^(-n)`, `^(p\/q)`, `^(-p\/q)`.
func unitsTypstExp(q *big.Rat) []rune {
	if unitsIsOne(q) {
		return nil
	}
	n := unitsDigs(new(big.Int).Abs(q.Num()))
	if q.IsInt() {
		if q.Sign() > 0 {
			return append([]rune{'^'}, n...)
		}
		out := append([]rune{'^', '(', '-'}, n...)
		return append(out, ')')
	}
	out := []rune{'^', '('}
	if q.Sign() < 0 {
		out = append(out, '-')
	}
	out = append(out, n...)
	out = append(out, '\\', '/')
	out = append(out, unitsDigs(q.Denom())...)
	return append(out, ')')
}

// unitsTypstFactor is `Esm.Units.typstFactor`: `upright("sym")` and its
// signed exponent.
func unitsTypstFactor(f Factor) []rune {
	out := []rune(unitsUprightOpen)
	out = append(out, []rune(f.Sym)...)
	out = append(out, []rune(unitsUprightClose)...)
	return append(out, unitsTypstExp(f.Exp)...)
}

// unitsTypst is `Esm.Units.typst`: the Typst form of a canonical factor list
// (`1` when empty).
func unitsTypst(l []Factor) []rune {
	if len(l) == 0 {
		return []rune{'1'}
	}
	ordered := append(unitsNumFactors(l), unitsDenFactors(l)...)
	return unitsJoinWith(unitsTypstFactor, unitsThinSep, ordered)
}

// unitsPTParen is `Esm.Units.pTParen`: after `^(`:
// `'-'? digits (')' | '\/' digits ')')`.
func unitsPTParen(cs []rune) (*big.Rat, []rune, bool) {
	neg := len(cs) > 0 && cs[0] == '-'
	cs2 := cs
	if neg {
		cs2 = cs[1:]
	}
	p, r, ok := unitsPDigits(cs2)
	if !ok {
		return nil, nil, false
	}
	sp := unitsRat(p)
	if neg {
		sp.Neg(sp)
	}
	if len(r) > 0 && r[0] == ')' {
		return sp, r[1:], true
	}
	if r2, ok := cutPrefix(r, "\\/"); ok {
		d, r3, ok := unitsPDigits(r2)
		if ok && len(r3) > 0 && r3[0] == ')' {
			return unitsRatio(sp, d), r3[1:], true
		}
	}
	return nil, nil, false
}

// unitsPTExp is `Esm.Units.pTExp`: an optional exponent (none means 1).
func unitsPTExp(cs []rune) (*big.Rat, []rune, bool) {
	if len(cs) == 0 || cs[0] != '^' {
		return big.NewRat(1, 1), cs, true
	}
	r := cs[1:]
	if len(r) == 0 {
		return nil, nil, false
	}
	if r[0] == '(' {
		return unitsPTParen(r[1:])
	}
	p, r2, ok := unitsPDigits(r)
	if !ok {
		return nil, nil, false
	}
	return unitsRat(p), r2, true
}

// unitsPTFactor is `Esm.Units.pTFactor`.
func unitsPTFactor(cs []rune) (Factor, []rune, bool) {
	r, ok := cutPrefix(cs, unitsUprightOpen)
	if !ok {
		return Factor{}, nil, false
	}
	n := 0
	for n < len(r) && r[n] != '"' {
		n++
	}
	sym, rest := r[:n], r[n:]
	r2, ok := cutPrefix(rest, unitsUprightClose)
	if !ok {
		return Factor{}, nil, false
	}
	q, r3, ok := unitsPTExp(r2)
	if !ok {
		return Factor{}, nil, false
	}
	return Factor{Sym: string(sym), Exp: q}, r3, true
}

// unitsParseTypst is `Esm.Units.parseTypst`: a Typst unit back to its
// two-sided factor list.
func unitsParseTypst(s []rune) ([]Factor, bool) {
	if len(s) == 1 && s[0] == '1' {
		return []Factor{}, true
	}
	fs, rest, ok := unitsPSepBy(unitsPTFactor, unitsThinSep, s)
	if ok && len(rest) == 0 {
		return fs, true
	}
	return nil, false
}
