// Package unitspell is the canonical unit spelling (esm-spec §4.8.2
// "Canonical spelling"): the unit-string lexer and parser that build a unit's
// factor list, the normalization of that list, and its spelling. The authority
// is the Lean definition `Esm.Units.canon` (formal/Esm/Units/Canonical.lean);
// this is a port of it, and the cross-binding fixture
// tests/conformance/canonical/unit_spelling.json pins the output.
//
// It reads the string; it does not resolve it. Symbols are kept as written
// (`km` stays `km`), no table lookup decides the spelling, and nothing cancels
// across the fraction bar (`mol/mol` stays `mol/mol`). It has its own lexer and
// parser, mirroring the Lean ones, because package esm's ParseUnit rejects
// unknown symbols and the spelling keeps them. Package esm (the canonicalizer)
// and package docfmt (the document printers and readers) share it.
package unitspell

import (
	"math/big"
	"sort"
	"strings"
)

// IsSpace reports the §4.8.2 whitespace bytes: space, tab, CR, LF.
func IsSpace(c byte) bool { return c == ' ' || c == '\t' || c == '\r' || c == '\n' }

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
		case IsSpace(c):
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

// Factor is one factor of a parsed unit: a symbol and its exponent.
type Factor struct {
	Sym string
	Exp *big.Rat
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

func (p *spellParser) unit() ([]Factor, bool) {
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
					f.Exp = new(big.Rat).Neg(f.Exp)
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

func (p *spellParser) term() ([]Factor, bool) {
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
		factors[i].Exp = new(big.Rat).Mul(q, factors[i].Exp)
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

func (p *spellParser) atom() ([]Factor, bool) {
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
		return []Factor{{Sym: name, Exp: big.NewRat(1, 1)}}, true
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

// Parse reads a unit string (after Normalize) with the §4.8.2 grammar and
// returns its factors as written, in order, `/` having negated the exponents
// of its right operand; ok is false when it does not lex or parse. The empty
// string does not parse.
func Parse(unit string) (factors []Factor, ok bool) {
	toks, ok := spellLex(Normalize(unit))
	if !ok {
		return nil, false
	}
	p := &spellParser{toks: toks}
	factors, ok = p.unit()
	if !ok || p.pos != len(toks) {
		return nil, false
	}
	return factors, true
}

// Side is `Esm.Units.norm` on one side of the fraction bar, the factors with a
// positive exponent when numerator is true and the others when it is false:
// each symbol once with its exponents summed, zero sums dropped, sorted by
// symbol in codepoint order.
func Side(factors []Factor, numerator bool) []Factor {
	total := map[string]*big.Rat{}
	var syms []string
	for _, f := range factors {
		if (f.Exp.Sign() > 0) != numerator {
			continue
		}
		if total[f.Sym] == nil {
			total[f.Sym] = new(big.Rat)
			syms = append(syms, f.Sym)
		}
		total[f.Sym].Add(total[f.Sym], f.Exp)
	}
	sort.Strings(syms)
	var out []Factor
	for _, s := range syms {
		if total[s].Sign() != 0 {
			out = append(out, Factor{Sym: s, Exp: total[s]})
		}
	}
	return out
}

// TwoSided is the normalized two-sided factor list of a unit string: the
// numerator's factors (Side true), then the denominator's (Side false). It is
// nil when the string does not parse.
func TwoSided(unit string) []Factor {
	factors, ok := Parse(unit)
	if !ok {
		return nil
	}
	return append(Side(factors, true), Side(factors, false)...)
}

func spellOne(f Factor) string {
	q := new(big.Rat).Abs(f.Exp)
	switch {
	case q.Cmp(big.NewRat(1, 1)) == 0:
		return f.Sym
	case q.IsInt():
		return f.Sym + "^" + q.Num().String()
	default:
		return f.Sym + "^(" + q.Num().String() + "/" + q.Denom().String() + ")"
	}
}

// Spell is the canonical spelling of a factor list (`Esm.Units.spell`): the
// factors with a positive exponent joined by `*` (`1` when there are none),
// then `/` and the others, in order, with their exponents' absolute values,
// parenthesized when there is more than one. An exponent 1 is omitted, an
// integer is `^n`, any other rational is `^(p/q)` in lowest terms.
func Spell(l []Factor) string {
	var num, den []string
	for _, f := range l {
		if f.Exp.Sign() > 0 {
			num = append(num, spellOne(f))
		} else {
			den = append(den, spellOne(f))
		}
	}
	out := "1"
	if len(num) > 0 {
		out = strings.Join(num, "*")
	}
	switch len(den) {
	case 0:
	case 1:
		out += "/" + den[0]
	default:
		out += "/(" + strings.Join(den, "*") + ")"
	}
	return out
}

// SymbolOK is `Esm.Units.symOK`: `%`, or an identifier run that is not all
// digits.
func SymbolOK(s string) bool {
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
