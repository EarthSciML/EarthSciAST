package docfmt

// TEMPORARY: the math fork's copy of the Typst value codec (TypstDict.lean,
// Rust document/typst_dict.rs), which the Typst math lexer and renderer need
// (tdictPVal, tdictEncode). The source fork ports the same module as
// typst_dict.go; DELETE THIS FILE when merging that branch.

import "slices"

var tdictKeywords = []string{
	"none", "auto", "true", "false", "not", "and", "or", "let", "set", "show", "if", "else", "for",
	"in", "while", "break", "continue", "return", "import", "include", "context", "as", "_",
}

func tdictReserved(k string) bool { return slices.Contains(tdictKeywords, k) }

const tdictMinLit = "-9223372036854775807"

func tdictPrintNum(n JNum) []rune {
	if n.IsInt(-1 << 63) {
		return []rune("(-9223372036854775807 - 1)")
	}
	return numPrint(n)
}

func tdictEnc(m int, v Json, out []rune) []rune {
	switch x := v.(type) {
	case nil:
		return append(out, []rune("none")...)
	case bool:
		if x {
			return append(out, []rune("true")...)
		}
		return append(out, []rune("false")...)
	case JNum:
		return append(out, tdictPrintNum(x)...)
	case string:
		return append(out, strQuote(true, x)...)
	case []Json:
		if len(x) == 0 {
			return append(out, '(', ')')
		}
		out = append(out, '(', '\n')
		for _, e := range x {
			out = append(out, strSpaces(m+2)...)
			out = tdictEnc(m+2, e, out)
			out = append(out, ',', '\n')
		}
		out = append(out, strSpaces(m)...)
		return append(out, ')')
	case Obj:
		if len(x) == 0 {
			return append(out, '(', ':', ')')
		}
		out = append(out, '(', '\n')
		for _, kv := range x {
			out = append(out, strSpaces(m+2)...)
			out = append(out, strPrintKey(true, tdictReserved, kv.K)...)
			out = append(out, ':', ' ')
			out = tdictEnc(m+2, kv.V, out)
			out = append(out, ',', '\n')
		}
		out = append(out, strSpaces(m)...)
		return append(out, ')')
	}
	return out
}

func tdictEncode(v Json) []rune { return tdictEnc(0, v, nil) }

func tdictIsWs(c rune) bool { return c == ' ' || c == '\n' || c == '\t' || c == '\r' }

func tdictSkipWs(r []rune) []rune {
	n := 0
	for n < len(r) && tdictIsWs(r[n]) {
		n++
	}
	return r[n:]
}

func tdictIsEntry(input []rune) bool {
	_, r, ok := strParseKey(true, tdictReserved, input)
	if !ok {
		return false
	}
	r = tdictSkipWs(r)
	return len(r) > 0 && r[0] == ':'
}

// tdictPNext: what follows one element: more (`,` and another), or `)` after
// a `,` (comma true) or directly.
func tdictPNext(r []rune) (more, comma bool, rest []rune, ok bool) {
	r = tdictSkipWs(r)
	if len(r) > 0 && r[0] == ',' {
		r1 := tdictSkipWs(r[1:])
		if len(r1) > 0 && r1[0] == ')' {
			return false, true, r1[1:], true
		}
		return true, false, r1, true
	}
	if len(r) > 0 && r[0] == ')' {
		return false, false, r[1:], true
	}
	return false, false, nil, false
}

func tdictPMin(r []rune) ([]rune, bool) {
	r1, ok := cutPrefix(r, tdictMinLit)
	if !ok {
		return nil, false
	}
	for _, c := range []rune{'-', '1', ')'} {
		r1 = tdictSkipWs(r1)
		if len(r1) == 0 || r1[0] != c {
			return nil, false
		}
		r1 = r1[1:]
	}
	return r1, true
}

func tdictPVal(input []rune) (Json, []rune, bool) {
	if len(input) == 0 {
		return nil, nil, false
	}
	switch input[0] {
	case '(':
		r := tdictSkipWs(input[1:])
		if r1, ok := tdictPMin(r); ok {
			return IntNum(-1 << 63), r1, true
		}
		return tdictPParen(r)
	case '"':
		s, r, ok := strParseQuoted(true, input)
		return s, r, ok
	case 'n':
		if r, ok := cutPrefix(input[1:], "one"); ok {
			return nil, r, true
		}
		return nil, nil, false
	case 't':
		if r, ok := cutPrefix(input[1:], "rue"); ok {
			return true, r, true
		}
		return nil, nil, false
	case 'f':
		if r, ok := cutPrefix(input[1:], "alse"); ok {
			return false, r, true
		}
		return nil, nil, false
	}
	n, r, ok := numParse(input)
	if !ok {
		return nil, nil, false
	}
	return n, r, true
}

func tdictPParen(input []rune) (Json, []rune, bool) {
	if len(input) == 0 {
		return nil, nil, false
	}
	switch input[0] {
	case ')':
		return []Json{}, input[1:], true
	case ':':
		r := tdictSkipWs(input[1:])
		if len(r) > 0 && r[0] == ')' {
			return Obj{}, r[1:], true
		}
		return nil, nil, false
	}
	if tdictIsEntry(input) {
		kvs, r, ok := tdictPEntries(input)
		return kvs, r, ok
	}
	xs, r, ok := tdictPItems(input)
	return xs, r, ok
}

func tdictPItems(input []rune) ([]Json, []rune, bool) {
	out := []Json{}
	first := true
	for {
		v, r, ok := tdictPVal(input)
		if !ok {
			return nil, nil, false
		}
		out = append(out, v)
		more, comma, r1, ok := tdictPNext(r)
		if !ok {
			return nil, nil, false
		}
		if !more {
			if first && !comma {
				return nil, nil, false
			}
			return out, r1, true
		}
		input = r1
		first = false
	}
}

func tdictPEntries(input []rune) (Obj, []rune, bool) {
	out := Obj{}
	for {
		k, r, ok := strParseKey(true, tdictReserved, input)
		if !ok {
			return nil, nil, false
		}
		r = tdictSkipWs(r)
		if len(r) == 0 || r[0] != ':' {
			return nil, nil, false
		}
		v, r2, ok := tdictPVal(tdictSkipWs(r[1:]))
		if !ok {
			return nil, nil, false
		}
		out = append(out, KV{k, v})
		more, _, r3, ok := tdictPNext(r2)
		if !ok {
			return nil, nil, false
		}
		if !more {
			return out, r3, true
		}
		input = r3
	}
}
