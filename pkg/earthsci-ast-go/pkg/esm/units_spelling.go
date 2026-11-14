package esm

import (
	"math/big"
	"sort"
	"strings"
)

// The canonical unit spelling (esm-spec §4.8.2 "Canonical spelling"). The
// authority is the Lean definition `Esm.Units.canon`
// (formal/Esm/Units/Canonical.lean); this is a port of it, and the
// cross-binding fixture tests/conformance/canonical/unit_spelling.json pins the
// output.
//
// It rewrites the PARSED string; it does not resolve it. Symbols are kept as
// written (`km` stays `km`), no table lookup decides the spelling, and nothing
// cancels across the fraction bar (`mol/mol` stays `mol/mol`). It has its own
// lexer and parser, mirroring the Lean ones, because ParseUnit rejects unknown
// symbols and the spelling keeps them.

// spellTokKind is the kind of one §4.8.2 token.
type spellTokKind int

const (
	spellSym spellTokKind = iota
	spellNum
	spellStar
	spellDStar
	spellSlash
	spellCaret
	spellLParen
	spellRParen
	spellMinus
	spellEOF
)

// spellTok is one token: a symbol's or number's spelling, and a number's exact
// value and whether it is an integer.
type spellTok struct {
	kind  spellTokKind
	text  string
	value *big.Rat
	isInt bool
}

func isSpellIdent(c byte) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

func isDigitRun(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// spellLex reads the §4.8.2 tokens as the Lean lexer `Esm.Units.lex` reads
// them; ok is false when a character is outside the token rules.
func spellLex(s string) (toks []spellTok, ok bool) {
	ops := map[byte]spellTokKind{'/': spellSlash, '^': spellCaret, '(': spellLParen, ')': spellRParen, '-': spellMinus}
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case isUnitSpace(c):
			i++
		case c == '*' && i+1 < len(s) && s[i+1] == '*':
			toks = append(toks, spellTok{kind: spellDStar})
			i += 2
		case c == '*':
			toks = append(toks, spellTok{kind: spellStar})
			i++
		case ops[c] != 0:
			toks = append(toks, spellTok{kind: ops[c]})
			i++
		case c == '%':
			toks = append(toks, spellTok{kind: spellSym, text: "%"})
			i++
		case isSpellIdent(c):
			j := i
			for j < len(s) && isSpellIdent(s[j]) {
				j++
			}
			run := s[i:j]
			switch {
			case !isDigitRun(run):
				toks = append(toks, spellTok{kind: spellSym, text: run})
				i = j
			case j+1 < len(s) && s[j] == '.' && s[j+1] >= '0' && s[j+1] <= '9':
				k := j + 1
				for k < len(s) && isSpellIdent(s[k]) {
					k++
				}
				lit := s[i:k]
				if frac := s[j+1 : k]; isDigitRun(frac) {
					v, _ := new(big.Rat).SetString(lit)
					toks = append(toks, spellTok{kind: spellNum, text: lit, value: v})
				} else {
					// `1.5m` is one symbol, and no table key can match it.
					toks = append(toks, spellTok{kind: spellSym, text: lit})
				}
				i = k
			default:
				v, _ := new(big.Rat).SetString(run)
				toks = append(toks, spellTok{kind: spellNum, text: run, value: v, isInt: true})
				i = j
			}
		default:
			return nil, false
		}
	}
	return toks, true
}

// spellFactor is one factor of a parsed unit: a symbol and its exponent.
type spellFactor struct {
	sym string
	exp *big.Rat
}

// spellParser is the §4.8.2 grammar (`Esm.Units.parse`), building the factor
// list (`UExpr.factors`) as it goes: `*` and juxtaposition concatenate, `/`
// negates the exponents of its right operand, `^q` scales every exponent
// below it, and the atom `1` and the symbol `dimensionless` contribute
// nothing. Each method's ok is false when the tokens do not parse.
type spellParser struct {
	toks []spellTok
	pos  int
}

func (p *spellParser) kind(ahead int) spellTokKind {
	if p.pos+ahead < len(p.toks) {
		return p.toks[p.pos+ahead].kind
	}
	return spellEOF
}

func (p *spellParser) unit() ([]spellFactor, bool) {
	acc, ok := p.term()
	if !ok {
		return nil, false
	}
	for {
		switch p.kind(0) {
		case spellStar, spellSlash:
			divide := p.kind(0) == spellSlash
			p.pos++
			next, ok := p.term()
			if !ok {
				return nil, false
			}
			for _, f := range next {
				if divide {
					f.exp = new(big.Rat).Neg(f.exp)
				}
				acc = append(acc, f)
			}
		case spellSym, spellNum, spellLParen:
			next, ok := p.term()
			if !ok {
				return nil, false
			}
			acc = append(acc, next...)
		default:
			return acc, true
		}
	}
}

func (p *spellParser) term() ([]spellFactor, bool) {
	factors, ok := p.atom()
	if !ok {
		return nil, false
	}
	if k := p.kind(0); k != spellCaret && k != spellDStar {
		return factors, true
	}
	p.pos++
	q, ok := p.exponent()
	if !ok {
		return nil, false
	}
	for i := range factors {
		factors[i].exp = new(big.Rat).Mul(q, factors[i].exp)
	}
	return factors, true
}

func (p *spellParser) exponent() (*big.Rat, bool) {
	switch {
	case p.kind(0) == spellMinus && p.kind(1) == spellNum:
		p.pos += 2
		return new(big.Rat).Neg(p.toks[p.pos-1].value), true
	case p.kind(0) == spellNum:
		p.pos++
		return p.toks[p.pos-1].value, true
	case p.kind(0) == spellLParen:
		p.pos++
		num, ok := p.signedInteger()
		if !ok || p.kind(0) != spellSlash {
			return nil, false
		}
		p.pos++
		den, ok := p.signedInteger()
		if !ok || p.kind(0) != spellRParen || den.Sign() == 0 {
			return nil, false
		}
		p.pos++
		return new(big.Rat).Quo(num, den), true
	}
	return nil, false
}

func (p *spellParser) signedInteger() (*big.Rat, bool) {
	negative := p.kind(0) == spellMinus
	at := p.pos
	if negative {
		at++
	}
	if at >= len(p.toks) || p.toks[at].kind != spellNum || !p.toks[at].isInt {
		return nil, false
	}
	p.pos = at + 1
	if negative {
		return new(big.Rat).Neg(p.toks[at].value), true
	}
	return p.toks[at].value, true
}

func (p *spellParser) atom() ([]spellFactor, bool) {
	switch p.kind(0) {
	case spellNum:
		// Any number but the literal `1` is a scaling factor.
		p.pos++
		return nil, p.toks[p.pos-1].text == "1"
	case spellSym:
		p.pos++
		name := p.toks[p.pos-1].text
		if name == "dimensionless" {
			return nil, true
		}
		return []spellFactor{{sym: name, exp: big.NewRat(1, 1)}}, true
	case spellLParen:
		p.pos++
		inner, ok := p.unit()
		if !ok || p.kind(0) != spellRParen {
			return nil, false
		}
		p.pos++
		return inner, true
	}
	return nil, false
}

// spellSide is `Esm.Units.norm`: each symbol once with its exponents summed,
// zero sums dropped, sorted by symbol in codepoint order.
func spellSide(factors []spellFactor, numerator bool) []spellFactor {
	total := map[string]*big.Rat{}
	var syms []string
	for _, f := range factors {
		if (f.exp.Sign() > 0) != numerator {
			continue
		}
		if total[f.sym] == nil {
			total[f.sym] = new(big.Rat)
			syms = append(syms, f.sym)
		}
		total[f.sym].Add(total[f.sym], f.exp)
	}
	sort.Strings(syms)
	var out []spellFactor
	for _, s := range syms {
		if total[s].Sign() != 0 {
			out = append(out, spellFactor{sym: s, exp: total[s]})
		}
	}
	return out
}

func spellOne(f spellFactor) string {
	q := new(big.Rat).Abs(f.exp)
	switch {
	case q.Cmp(big.NewRat(1, 1)) == 0:
		return f.sym
	case q.IsInt():
		return f.sym + "^" + q.Num().String()
	default:
		return f.sym + "^(" + q.Num().String() + "/" + q.Denom().String() + ")"
	}
}

func spellJoin(side []spellFactor) string {
	parts := make([]string, len(side))
	for i, f := range side {
		parts[i] = spellOne(f)
	}
	return strings.Join(parts, "*")
}

// spellSymbolOK is `Esm.Units.symOK`: `%`, or an identifier run that is not
// all digits.
func spellSymbolOK(s string) bool {
	if s == "%" {
		return true
	}
	if s == "" || isDigitRun(s) {
		return false
	}
	for i := 0; i < len(s); i++ {
		if !isSpellIdent(s[i]) {
			return false
		}
	}
	return true
}

// canonicalUnitSpelling is the canonical spelling of a unit string (esm-spec
// §4.8.2), a port of the Lean `Esm.Units.canon`.
//
// The numerator is the factors with a positive exponent, each symbol once with
// its exponents summed, sorted by symbol (codepoint order) and joined by `*`.
// The denominator is the factors with a negative exponent, treated the same
// way and written with the exponent's absolute value; it is parenthesized when
// it has more than one factor. Nothing cancels across the bar. An exponent 1
// is omitted, an integer is `^n`, any other rational is `^(p/q)` in lowest
// terms. An empty numerator is `1`, so "", "1" and "dimensionless" all become
// "1".
//
// The string is returned unchanged when it does not lex or parse, when the
// spelling would have to write a symbol containing `.`, and when it would drop
// (exponent 0) a symbol that is not a table key.
func canonicalUnitSpelling(unit string) string {
	if unit == "" {
		return "1"
	}
	toks, ok := spellLex(normalizeUnitString(unit))
	if !ok {
		return unit
	}
	p := &spellParser{toks: toks}
	factors, ok := p.unit()
	if !ok || p.pos != len(toks) {
		return unit
	}
	num := spellSide(factors, true)
	den := spellSide(factors, false)
	kept := map[string]bool{}
	for _, f := range append(append([]spellFactor{}, num...), den...) {
		if !spellSymbolOK(f.sym) {
			return unit
		}
		kept[f.sym] = true
	}
	for _, f := range factors {
		if _, known := unitRegistry[f.sym]; !kept[f.sym] && !known {
			return unit
		}
	}
	spelled := "1"
	if len(num) > 0 {
		spelled = spellJoin(num)
	}
	switch len(den) {
	case 0:
	case 1:
		spelled += "/" + spellOne(den[0])
	default:
		spelled += "/(" + spellJoin(den) + ")"
	}
	return spelled
}
