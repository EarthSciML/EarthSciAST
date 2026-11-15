package esm

import "github.com/EarthSciML/EarthSciAST/pkg/earthsci-ast-go/pkg/esm/internal/unitspell"

// The canonical unit spelling (esm-spec §4.8.2 "Canonical spelling"). The
// lexer, parser and spelling are in internal/unitspell, shared with the
// document printers; what is here is the one rule that needs the unit table.

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
	factors, ok := unitspell.Parse(unit)
	if !ok {
		return unit
	}
	num := unitspell.Side(factors, true)
	den := unitspell.Side(factors, false)
	kept := map[string]bool{}
	for _, f := range append(append([]unitspell.Factor{}, num...), den...) {
		if !unitspell.SymbolOK(f.Sym) {
			return unit
		}
		kept[f.Sym] = true
	}
	for _, f := range factors {
		if _, known := unitRegistry[f.Sym]; !kept[f.Sym] && !known {
			return unit
		}
	}
	return unitspell.Spell(append(num, den...))
}
