package unitspell

import (
	"strings"
	"unicode/utf8"
)

// Normalize rewrites the non-ASCII and alternate spellings the shared
// corpus uses into the ASCII grammar of esm-spec §4.8.2. It is a pure
// spelling normalization — no unit is invented here, each target already exists
// in the registry — and it runs before the byte-level scanner, which only
// recognizes ASCII bytes:
//
//   - SUPERSCRIPT DIGITS ⁰¹²³⁴⁵⁶⁷⁸⁹ → "^n", and superscript minus ⁻ → "^-" only
//     right before superscript digits
//     ("W/m²" → "W/m^2", "cm³" → "cm^3", "m⁻³" → "m^-3"). A RUN of superscript
//     digits is one exponent, so "m¹⁰" is m^10, not m^1*0.
//   - MIDDOT · (U+00B7) and DOT OPERATOR ⋅ (U+22C5) → "*" ("J/(kg·K)",
//     "kg⋅m/s"). Both are multiplication in SI typography.
//   - U+00B5 MICRO SIGN and U+03BC GREEK SMALL LETTER MU → "u" ("μg" → "ug")
//   - "°C"/"°F" → degC/degF. Nothing else involving a degree sign is
//     rewritten: a bare "°" (or "°K") stays an unexpected character, so the
//     string does not resolve (esm-spec §4.8.2 maps only these two).
//   - Ω (U+03A9 GREEK CAPITAL OMEGA) and Ω (U+2126 OHM SIGN) → "Ohm"
//
// These spellings are pervasive in tests/libraries and the spec's own
// examples, and an unresolvable unit string is an error.
func Normalize(s string) string {
	if isASCIIString(s) {
		return s
	}
	runes := []rune(s)
	var b strings.Builder
	b.Grow(len(s) + 4)
	for i := 0; i < len(runes); i++ {
		r := runes[i]
		// A run of superscript DIGITS is one exponent ("m¹²" is m^12), and a
		// superscript minus is rewritten only together with the digits right
		// after it ("m⁻³" is m^-3). A minus anywhere else stays an unexpected
		// character, so "s⁻1" does not resolve, and "m²⁻¹" is the two
		// exponents m^2^-1, not one exponent -21 (esm-spec §4.8.2, Lean
		// `normalize`).
		minus := r == '⁻' && i+1 < len(runes) && isSuperscriptDigit(runes[i+1])
		if minus || isSuperscriptDigit(r) {
			b.WriteByte('^')
			if minus {
				b.WriteByte('-')
				i++
			}
			for i < len(runes) && isSuperscriptDigit(runes[i]) {
				b.WriteByte(superscriptASCII(runes[i]))
				i++
			}
			i-- // the outer loop advances past the last consumed rune
			continue
		}
		switch r {
		case '·', '⋅': // MIDDLE DOT, DOT OPERATOR
			b.WriteByte('*')
		case 'µ', 'μ': // MICRO SIGN, GREEK SMALL LETTER MU
			b.WriteByte('u')
		case 'Ω', 'Ω': // GREEK CAPITAL OMEGA, OHM SIGN
			b.WriteString("Ohm")
		case '°': // DEGREE SIGN
			if i+1 < len(runes) {
				switch runes[i+1] {
				case 'C':
					b.WriteString("degC")
					i++
					continue
				case 'F':
					b.WriteString("degF")
					i++
					continue
				}
			}
			b.WriteRune(r)
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// isASCIIString reports whether s needs no Unicode normalization.
func isASCIIString(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= utf8.RuneSelf {
			return false
		}
	}
	return true
}

// superscriptTable maps every superscript rune to the ASCII byte it denotes.
var superscriptTable = map[rune]byte{
	'⁰': '0', '¹': '1', '²': '2', '³': '3', '⁴': '4',
	'⁵': '5', '⁶': '6', '⁷': '7', '⁸': '8', '⁹': '9',
	'⁻': '-',
}

func isSuperscriptRune(r rune) bool {
	_, ok := superscriptTable[r]
	return ok
}

func superscriptASCII(r rune) byte { return superscriptTable[r] }

// isSuperscriptDigit reports a superscript digit (a superscript rune other
// than the minus).
func isSuperscriptDigit(r rune) bool { return r != '⁻' && isSuperscriptRune(r) }
