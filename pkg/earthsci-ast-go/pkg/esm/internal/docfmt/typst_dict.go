package docfmt

// The Typst value codec: a JSON value as a Typst code-mode value. Port of
// formal/Esm/Document/TypstDict.lean (Rust: document/typst_dict.rs); prefix
// `tdict`.
//
//   - `none`, `true`, `false`; numbers in the canonical spelling, except -2^63,
//     printed `(-9223372036854775807 - 1)` because Typst reads the literal
//     `-9223372036854775808` as a float;
//   - strings with Typst escapes (`\u{XXXX}`);
//   - arrays `(a, b)`, `()` empty; dictionaries `(key: v, "quoted key": v)`,
//     `(:)` empty. A key is bare when it is an identifier and not a Typst
//     keyword;
//   - a math leaf `$…$`, Typst math content: its text up to the next `$`
//     (`Json.mathOK`). Only a path block holds one (`Source.mathify`).
//
// The canonical layout is one element per line, each indented two spaces
// deeper than the opening line and followed by `,`. The reader skips
// whitespace between tokens, accepts a trailing comma or none, and rejects a
// one-element array without its comma (Typst reads `(x)` as `x`).

import "math"

// tdictKeywords is `TypstDict.keywords`: Typst keywords, which cannot be bare
// dictionary keys.
var tdictKeywords = map[string]bool{
	"none": true, "auto": true, "true": true, "false": true, "not": true, "and": true, "or": true,
	"let": true, "set": true, "show": true, "if": true, "else": true, "for": true, "in": true,
	"while": true, "break": true, "continue": true, "return": true, "import": true,
	"include": true, "context": true, "as": true, "_": true,
}

// tdictReserved is `TypstDict.reserved`.
func tdictReserved(k string) bool { return tdictKeywords[k] }

// tdictMinLit is `TypstDict.minLit`: the first operand of the -2^63 expression.
const tdictMinLit = "-9223372036854775807"

// tdictPrintNum is `TypstDict.printNum`.
func tdictPrintNum(n JNum) []rune {
	if n.IsInt(math.MinInt64) {
		return []rune("(-9223372036854775807 - 1)")
	}
	return numPrint(n)
}

// tdictEnc is `TypstDict.enc`: the canonical print of a value whose first line
// is indented by m spaces (the indentation itself is not printed).
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
	case Math:
		out = append(out, '$')
		out = append(out, []rune(x.Text)...)
		return append(out, '$')
	case []Json:
		if len(x) == 0 {
			return append(out, '(', ')')
		}
		out = append(out, '(', '\n')
		for _, e := range x {
			out = appendSpaces(out, m+2)
			out = tdictEnc(m+2, e, out)
			out = append(out, ',', '\n')
		}
		out = appendSpaces(out, m)
		return append(out, ')')
	case Obj:
		if len(x) == 0 {
			return append(out, '(', ':', ')')
		}
		out = append(out, '(', '\n')
		for _, kv := range x {
			out = appendSpaces(out, m+2)
			out = append(out, strPrintKey(true, tdictReserved, kv.K)...)
			out = append(out, ':', ' ')
			out = tdictEnc(m+2, kv.V, out)
			out = append(out, ',', '\n')
		}
		out = appendSpaces(out, m)
		return append(out, ')')
	}
	return out
}

// tdictEncode is `TypstDict.encode`: the canonical Typst spelling of a value.
func tdictEncode(v Json) []rune { return tdictEnc(0, v, nil) }

// tdictIsWs is `TypstDict.isWs`.
func tdictIsWs(c rune) bool { return c == ' ' || c == '\n' || c == '\t' || c == '\r' }

// tdictSkipWs is `TypstDict.skipWs`.
func tdictSkipWs(r []rune) []rune {
	n := 0
	for n < len(r) && tdictIsWs(r[n]) {
		n++
	}
	return r[n:]
}

// tdictIsEntry is `TypstDict.isEntry`: the input starts with a key and a colon.
func tdictIsEntry(input []rune) bool {
	_, r, ok := strParseKey(true, tdictReserved, input)
	if !ok {
		return false
	}
	r = tdictSkipWs(r)
	return len(r) > 0 && r[0] == ':'
}

// tdictNext is `TypstDict.Next`: what follows one element.
type tdictNext uint8

const (
	tdictMore       tdictNext = iota // `,` and another element
	tdictCloseComma                  // `)` after a `,`
	tdictClose                       // `)` directly
)

// tdictPNext is `TypstDict.pNext`.
func tdictPNext(r []rune) (tdictNext, []rune, bool) {
	r = tdictSkipWs(r)
	if len(r) == 0 {
		return 0, nil, false
	}
	switch r[0] {
	case ',':
		r2 := tdictSkipWs(r[1:])
		if len(r2) > 0 && r2[0] == ')' {
			return tdictCloseComma, r2[1:], true
		}
		return tdictMore, r2, true
	case ')':
		return tdictClose, r[1:], true
	}
	return 0, nil, false
}

// tdictPMin is `TypstDict.pMin`: after `(` and any whitespace, the rest of
// `(-9223372036854775807 - 1)`.
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

// tdictPVal is `TypstDict.pVal`: a value, at its first character.
func tdictPVal(lim *Lim, input []rune) (Json, []rune, bool) {
	if !lim.enter() {
		return nil, nil, false
	}
	defer lim.leave()
	if len(input) == 0 {
		return nil, nil, false
	}
	switch input[0] {
	case '(':
		r := tdictSkipWs(input[1:])
		if r1, ok := tdictPMin(r); ok {
			return IntNum(math.MinInt64), r1, true
		}
		return tdictPParen(lim, r)
	case '"':
		s, r, ok := strParseQuoted(true, input)
		if !ok {
			return nil, nil, false
		}
		return s, r, true
	case '$':
		return jsonPMath(input[1:])
	case 'n':
		if r, ok := cutPrefix(input, "none"); ok {
			return nil, r, true
		}
		return nil, nil, false
	case 't':
		if r, ok := cutPrefix(input, "true"); ok {
			return true, r, true
		}
		return nil, nil, false
	case 'f':
		if r, ok := cutPrefix(input, "false"); ok {
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

// tdictPParen is `TypstDict.pParen`: after `(` and any whitespace.
func tdictPParen(lim *Lim, input []rune) (Json, []rune, bool) {
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
		kvs, r, ok := tdictPEntries(lim, input)
		if !ok {
			return nil, nil, false
		}
		return kvs, r, true
	}
	xs, r, ok := tdictPItems(lim, input)
	if !ok {
		return nil, nil, false
	}
	return xs, r, true
}

// tdictPItems is `TypstDict.pItems`: array elements; the first needs a `,`
// after it even when it is the last.
func tdictPItems(lim *Lim, input []rune) ([]Json, []rune, bool) {
	out := []Json{}
	first := true
	for {
		v, r, ok := tdictPVal(lim, input)
		if !ok {
			return nil, nil, false
		}
		out = append(out, v)
		nx, r1, ok := tdictPNext(r)
		if !ok {
			return nil, nil, false
		}
		switch nx {
		case tdictClose:
			if first {
				return nil, nil, false
			}
			return out, r1, true
		case tdictCloseComma:
			return out, r1, true
		}
		input = r1
		first = false
	}
}

// tdictPEntries is `TypstDict.pEntries`: dictionary entries, at the first key.
func tdictPEntries(lim *Lim, input []rune) (Obj, []rune, bool) {
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
		v, r2, ok := tdictPVal(lim, tdictSkipWs(r[1:]))
		if !ok {
			return nil, nil, false
		}
		out = append(out, KV{k, v})
		nx, r3, ok := tdictPNext(r2)
		if !ok {
			return nil, nil, false
		}
		if nx != tdictMore {
			return out, r3, true
		}
		input = r3
	}
}

// tdictDecode is `TypstDict.decode`: whitespace, the value, whitespace, end of
// input. The value must be well formed, math leaves allowed (`Json.WFm`).
func tdictDecode(lim *Lim, s []rune) (Json, bool) {
	v, r, ok := tdictPVal(lim, tdictSkipWs(s))
	if !ok || len(tdictSkipWs(r)) != 0 || !jsonWfmb(v) {
		return nil, false
	}
	return v, true
}
