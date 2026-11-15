package docfmt

// Lexical pieces shared by the YAML and Typst codecs. Port of
// formal/Esm/Document/Strings.lean (Rust: document/strings.rs); prefix `str`.
//
// Double-quoted strings with JSON-style escapes (YAML writes the hex escape
// `\uXXXX`, Typst `\u{XXXX}`; braces selects the Typst spelling), bare
// identifier keys, and the characters a number or a key never starts with.

import "unicode/utf8"

// hasPrefix reports whether input starts with the characters of p.
func hasPrefix(input []rune, p string) bool {
	i := 0
	for _, c := range p {
		if i >= len(input) || input[i] != c {
			return false
		}
		i++
	}
	return true
}

// cutPrefix is input after the prefix p, when input starts with it.
func cutPrefix(input []rune, p string) ([]rune, bool) {
	if !hasPrefix(input, p) {
		return input, false
	}
	return input[utf8.RuneCountInString(p):], true
}

// strHexChar is `Strings.hexChar`: a lowercase hex digit.
func strHexChar(d uint32) rune {
	if d < 10 {
		return rune(48 + d)
	}
	return rune(87 + d)
}

// strHexVal is `Strings.hexVal`: the value of a hex digit (either case).
func strHexVal(c rune) (uint32, bool) {
	switch {
	case c >= '0' && c <= '9':
		return uint32(c - 48), true
	case c >= 'a' && c <= 'f':
		return uint32(c - 87), true
	case c >= 'A' && c <= 'F':
		return uint32(c - 55), true
	}
	return 0, false
}

// strHex4 is `Strings.hex4`.
func strHex4(n uint32) []rune {
	return []rune{strHexChar(n / 4096 % 16), strHexChar(n / 256 % 16), strHexChar(n / 16 % 16), strHexChar(n % 16)}
}

// strHex4Val is `Strings.hex4Val`.
func strHex4Val(a, b, c, d rune) (uint32, bool) {
	va, ok1 := strHexVal(a)
	vb, ok2 := strHexVal(b)
	vc, ok3 := strHexVal(c)
	vd, ok4 := strHexVal(d)
	if !ok1 || !ok2 || !ok3 || !ok4 {
		return 0, false
	}
	return va*4096 + vb*256 + vc*16 + vd, true
}

// strNeedsHex is `Strings.needsHex`: characters written as a hex escape.
func strNeedsHex(c rune) bool {
	n := uint32(c)
	return n < 0x20 || n == 0x7F || (n >= 0x80 && n <= 0x9F) || n == 0x2028 || n == 0x2029 ||
		n == 0xFEFF || n == 0xFFFE || n == 0xFFFF
}

// strEscChar is `Strings.escChar`.
func strEscChar(braces bool, c rune, out []rune) []rune {
	switch c {
	case '"':
		return append(out, '\\', '"')
	case '\\':
		return append(out, '\\', '\\')
	case '\n':
		return append(out, '\\', 'n')
	case '\t':
		return append(out, '\\', 't')
	case '\r':
		return append(out, '\\', 'r')
	}
	if strNeedsHex(c) {
		out = append(out, '\\', 'u')
		if braces {
			out = append(out, '{')
			out = append(out, strHex4(uint32(c))...)
			return append(out, '}')
		}
		return append(out, strHex4(uint32(c))...)
	}
	return append(out, c)
}

// strEscape is `Strings.escape`: the escaped characters, without the quotes.
func strEscape(braces bool, cs []rune) []rune {
	out := make([]rune, 0, len(cs))
	for _, c := range cs {
		out = strEscChar(braces, c, out)
	}
	return out
}

// strQuote is `Strings.quote`: a double-quoted string literal.
func strQuote(braces bool, s string) []rune {
	out := []rune{'"'}
	out = append(out, strEscape(braces, []rune(s))...)
	return append(out, '"')
}

// strCharOf is Lean's `Char.ofNat`: a surrogate code point becomes '\0'.
func strCharOf(n uint32) rune {
	if (n >= 0xD800 && n <= 0xDFFF) || n > 0x10FFFF {
		return 0
	}
	return rune(n)
}

// strUnquoteBody is `Strings.unquoteBody`: the characters up to the closing
// quote, and what follows it.
func strUnquoteBody(braces bool, input []rune) ([]rune, []rune, bool) {
	var out []rune
	for {
		if len(input) == 0 {
			return nil, nil, false
		}
		c := input[0]
		if c == '"' {
			return out, input[1:], true
		}
		if c != '\\' {
			out = append(out, c)
			input = input[1:]
			continue
		}
		if len(input) < 2 {
			return nil, nil, false
		}
		switch input[1] {
		case '"':
			out = append(out, '"')
		case '\\':
			out = append(out, '\\')
		case 'n':
			out = append(out, '\n')
		case 't':
			out = append(out, '\t')
		case 'r':
			out = append(out, '\r')
		case 'u':
			if len(input) >= 8 && input[2] == '{' && input[7] == '}' {
				if !braces {
					return nil, nil, false
				}
				v, ok := strHex4Val(input[3], input[4], input[5], input[6])
				if !ok {
					return nil, nil, false
				}
				out = append(out, strCharOf(v))
				input = input[8:]
				continue
			}
			if braces || len(input) < 6 {
				return nil, nil, false
			}
			v, ok := strHex4Val(input[2], input[3], input[4], input[5])
			if !ok {
				return nil, nil, false
			}
			out = append(out, strCharOf(v))
			input = input[6:]
			continue
		default:
			return nil, nil, false
		}
		input = input[2:]
	}
}

// strParseQuoted is `Strings.parseQuoted`.
func strParseQuoted(braces bool, input []rune) (string, []rune, bool) {
	if len(input) == 0 || input[0] != '"' {
		return "", nil, false
	}
	cs, r, ok := strUnquoteBody(braces, input[1:])
	if !ok {
		return "", nil, false
	}
	return string(cs), r, true
}

// strIsIdentStart is `Strings.isIdentStart` (ASCII letters, as Lean's
// `Char.isAlpha`).
func strIsIdentStart(c rune) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}

// strIsIdentChar is `Strings.isIdentChar`.
func strIsIdentChar(c rune) bool { return strIsIdentStart(c) || (c >= '0' && c <= '9') }

// strIsIdent is `Strings.isIdent`: `[A-Za-z_][A-Za-z0-9_]*`.
func strIsIdent(cs []rune) bool {
	if len(cs) == 0 || !strIsIdentStart(cs[0]) {
		return false
	}
	for _, d := range cs[1:] {
		if !strIsIdentChar(d) {
			return false
		}
	}
	return true
}

// strReadIdent is `Strings.readIdent`: the maximal run of identifier
// characters at the front.
func strReadIdent(input []rune) ([]rune, []rune) {
	n := 0
	for n < len(input) && strIsIdentChar(input[n]) {
		n++
	}
	return input[:n], input[n:]
}

// strBareKey is `Strings.bareKey`: a key prints bare when it is an identifier
// and not one of the codec's reserved words.
func strBareKey(reserved func(string) bool, k string) bool {
	return strIsIdent([]rune(k)) && !reserved(k)
}

// strPrintKey is `Strings.printKey`.
func strPrintKey(braces bool, reserved func(string) bool, k string) []rune {
	if strBareKey(reserved, k) {
		return []rune(k)
	}
	return strQuote(braces, k)
}

// strParseKey is `Strings.parseKey`: quoted, or an identifier that is not a
// reserved word.
func strParseKey(braces bool, reserved func(string) bool, input []rune) (string, []rune, bool) {
	if len(input) == 0 {
		return "", nil, false
	}
	if input[0] == '"' {
		return strParseQuoted(braces, input)
	}
	if strIsIdentStart(input[0]) {
		id, r := strReadIdent(input)
		if reserved(string(id)) {
			return "", nil, false
		}
		return string(id), r, true
	}
	return "", nil, false
}
