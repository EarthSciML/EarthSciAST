package docfmt

// The YAML subset of front matter and container bodies. Port of
// formal/Esm/Document/Yaml.lean (Rust: document/yaml.rs); prefix `yaml`.
//
// The printed text is block-style YAML 1.2:
//
//   - a non-empty object is one `key: value` line per entry, a non-empty array
//     one `- item` line per element, at the current indentation;
//   - a scalar, `[]` or `{}` follows its `key: ` or `- ` on the same line;
//   - a non-empty container under a key starts on the next line, two spaces
//     deeper; a non-empty object as an array element starts on the `- ` line,
//     its other entries aligned with its first key; a non-empty array as an
//     element starts on the next line, two spaces deeper.
//
// Strings are always double-quoted with JSON-style escapes, so a math leaf
// (path blocks only, `Source.mathify`) is the plain scalar `$…$`, its text up
// to the next `$` (`Json.mathOK`); a key is bare when
// it is an identifier and not one of YAML's special plain scalars in any
// letter case; a key longer than 1024 characters uses the explicit `? "key"`
// form. The reader accepts only this layout and well-formed values.

import "strings"

// yamlSpecialWords is `Yaml.specialWords`.
var yamlSpecialWords = []string{"true", "false", "null", "yes", "no", "on", "off", "y", "n"}

// yamlReserved is `Yaml.reserved`: a key equal (in any ASCII letter case) to a
// special plain scalar.
func yamlReserved(k string) bool {
	if len(k) > 5 {
		return false
	}
	lower := strings.Map(func(c rune) rune {
		if c >= 'A' && c <= 'Z' {
			return c + 32
		}
		return c
	}, k)
	for _, w := range yamlSpecialWords {
		if w == lower {
			return true
		}
	}
	return false
}

// yamlLongKey is `Yaml.longKey`.
func yamlLongKey(k string) bool {
	if len(k) <= 1022/6 {
		// even fully escaped, a key this short prints within 1024 characters
		return false
	}
	return 1024 < len(strPrintKey(false, yamlReserved, k))
}

// yamlKeyPart is `Yaml.keyPart`: the key of an entry at indentation m, up to
// its `:`.
func yamlKeyPart(m int, k string, out []rune) []rune {
	if yamlLongKey(k) {
		out = append(out, '?', ' ')
		out = append(out, strQuote(false, k)...)
		out = append(out, '\n')
		return appendSpaces(out, m)
	}
	return append(out, strPrintKey(false, yamlReserved, k)...)
}

// yamlInline is `Yaml.inline`: the one-line spelling of a scalar or an empty
// container.
func yamlInline(v Json) []rune {
	switch x := v.(type) {
	case nil:
		return []rune("null")
	case bool:
		if x {
			return []rune("true")
		}
		return []rune("false")
	case JNum:
		return numPrint(x)
	case string:
		return strQuote(false, x)
	case Math:
		out := append([]rune{'$'}, []rune(x.Text)...)
		return append(out, '$')
	case []Json:
		return []rune("[]")
	case Obj:
		return []rune("{}")
	}
	return nil
}

// yamlInlineLine is the scalar case of itemBody/valBody: ` value` and the
// newline.
func yamlInlineLine(v Json, out []rune) []rune {
	out = append(out, ' ')
	out = append(out, yamlInline(v)...)
	return append(out, '\n')
}

// yamlEncItems is `Yaml.encItems`: the lines of a non-empty array at
// indentation m.
func yamlEncItems(m int, vs []Json, out []rune) []rune {
	for _, v := range vs {
		out = appendSpaces(out, m)
		out = append(out, '-')
		out = yamlItemBody(m, v, out)
	}
	return out
}

// yamlItemBody is `Yaml.itemBody`: what follows the `-` of an array element.
func yamlItemBody(m int, v Json, out []rune) []rune {
	switch x := v.(type) {
	case []Json:
		if len(x) > 0 {
			out = append(out, '\n')
			return yamlEncItems(m+2, x, out)
		}
	case Obj:
		if len(x) > 0 {
			out = append(out, ' ')
			out = yamlKeyPart(m+2, x[0].K, out)
			out = append(out, ':')
			out = yamlValBody(m+2, x[0].V, out)
			return yamlEncEntries(m+2, x[1:], out)
		}
	}
	return yamlInlineLine(v, out)
}

// yamlEncEntries is `Yaml.encEntries`: the lines of a non-empty object at
// indentation m.
func yamlEncEntries(m int, es Obj, out []rune) []rune {
	for _, e := range es {
		out = appendSpaces(out, m)
		out = yamlKeyPart(m, e.K, out)
		out = append(out, ':')
		out = yamlValBody(m, e.V, out)
	}
	return out
}

// yamlValBody is `Yaml.valBody`: what follows the `:` of an entry whose key is
// at indentation m.
func yamlValBody(m int, v Json, out []rune) []rune {
	switch x := v.(type) {
	case []Json:
		if len(x) > 0 {
			out = append(out, '\n')
			return yamlEncItems(m+2, x, out)
		}
	case Obj:
		if len(x) > 0 {
			out = append(out, '\n')
			return yamlEncEntries(m+2, x, out)
		}
	}
	return yamlInlineLine(v, out)
}

// yamlEncode is `Yaml.encode`: the canonical YAML spelling of a value.
func yamlEncode(v Json) []rune {
	var out []rune
	switch x := v.(type) {
	case []Json:
		if len(x) > 0 {
			return yamlEncItems(0, x, out)
		}
	case Obj:
		if len(x) > 0 {
			return yamlEncEntries(0, x, out)
		}
	}
	out = append(out, yamlInline(v)...)
	return append(out, '\n')
}

// ## Reader

// yamlDropSp is `Yaml.dropSp`: drop exactly n leading spaces.
func yamlDropSp(n int, l []rune) ([]rune, bool) {
	if len(l) < n {
		return nil, false
	}
	for i := 0; i < n; i++ {
		if l[i] != ' ' {
			return nil, false
		}
	}
	return l[n:], true
}

// yamlParseKeyAt is `Yaml.parseKeyAt`: an explicit `? "key"` line followed by
// the indentation of the `:` line, or a plain key.
func yamlParseKeyAt(m int, input []rune) (string, []rune, bool) {
	if len(input) == 0 {
		return "", nil, false
	}
	if input[0] == '?' {
		r := input[1:]
		if len(r) == 0 || r[0] != ' ' {
			return "", nil, false
		}
		k, r2, ok := strParseQuoted(false, r[1:])
		if !ok || len(r2) == 0 || r2[0] != '\n' {
			return "", nil, false
		}
		r3, ok := yamlDropSp(m, r2[1:])
		if !ok {
			return "", nil, false
		}
		return k, r3, true
	}
	return strParseKey(false, yamlReserved, input)
}

// yamlPInline is `Yaml.pInline`: a scalar or an empty container.
func yamlPInline(input []rune) (Json, []rune, bool) {
	if len(input) == 0 {
		return nil, nil, false
	}
	switch input[0] {
	case 'n':
		if r, ok := cutPrefix(input, "null"); ok {
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
	case '[':
		if r, ok := cutPrefix(input, "[]"); ok {
			return []Json{}, r, true
		}
		return nil, nil, false
	case '{':
		if r, ok := cutPrefix(input, "{}"); ok {
			return Obj{}, r, true
		}
		return nil, nil, false
	case '"':
		s, r, ok := strParseQuoted(false, input)
		if !ok {
			return nil, nil, false
		}
		return s, r, true
	case '$':
		return jsonPMath(input[1:])
	}
	n, r, ok := numParse(input)
	if !ok {
		return nil, nil, false
	}
	return n, r, true
}

// yamlPScalarLine is `Yaml.pScalarLine`: a scalar and the end of its line.
func yamlPScalarLine(input []rune) (Json, []rune, bool) {
	v, r, ok := yamlPInline(input)
	if !ok || len(r) == 0 || r[0] != '\n' {
		return nil, nil, false
	}
	return v, r[1:], true
}

// yamlIsItemLine is `Yaml.isItemLine`.
func yamlIsItemLine(m int, input []rune) bool {
	r, ok := yamlDropSp(m, input)
	return ok && len(r) > 0 && r[0] == '-'
}

// yamlIsEntryLine is `Yaml.isEntryLine`.
func yamlIsEntryLine(m int, input []rune) bool {
	r, ok := yamlDropSp(m, input)
	if !ok || len(r) == 0 {
		return false
	}
	c := r[0]
	return c == '"' || c == '?' || strIsIdentStart(c)
}

// yamlPItems is `Yaml.pItems`: array elements at indentation m.
func yamlPItems(lim *Lim, m int, input []rune) ([]Json, []rune, bool) {
	out := []Json{}
	for yamlIsItemLine(m, input) {
		v, r, ok := yamlPItemBody(lim, m, input[m+1:])
		if !ok {
			return nil, nil, false
		}
		out = append(out, v)
		input = r
	}
	return out, input, true
}

// yamlPItemBody is `Yaml.pItemBody`: after the `-` of an element at
// indentation m.
func yamlPItemBody(lim *Lim, m int, input []rune) (Json, []rune, bool) {
	if !lim.enter() {
		return nil, nil, false
	}
	defer lim.leave()
	if len(input) == 0 {
		return nil, nil, false
	}
	switch input[0] {
	case '\n':
		xs, r, ok := yamlPItems(lim, m+2, input[1:])
		if !ok {
			return nil, nil, false
		}
		return xs, r, true
	case ' ':
		r := input[1:]
		if e, r1, ok := yamlPEntry(lim, m+2, r); ok {
			es, r2, ok := yamlPEntries(lim, m+2, r1)
			if !ok {
				return nil, nil, false
			}
			return append(Obj{e}, es...), r2, true
		}
		return yamlPScalarLine(r)
	}
	return nil, nil, false
}

// yamlPEntries is `Yaml.pEntries`: object entries at indentation m.
func yamlPEntries(lim *Lim, m int, input []rune) (Obj, []rune, bool) {
	out := Obj{}
	for yamlIsEntryLine(m, input) {
		e, r, ok := yamlPEntry(lim, m, input[m:])
		if !ok {
			return nil, nil, false
		}
		out = append(out, e)
		input = r
	}
	return out, input, true
}

// yamlPEntry is `Yaml.pEntry`: one entry, at its key.
func yamlPEntry(lim *Lim, m int, input []rune) (KV, []rune, bool) {
	k, r, ok := yamlParseKeyAt(m, input)
	if !ok || len(r) == 0 || r[0] != ':' {
		return KV{}, nil, false
	}
	v, r, ok := yamlPValBody(lim, m, r[1:])
	if !ok {
		return KV{}, nil, false
	}
	return KV{k, v}, r, true
}

// yamlPValBody is `Yaml.pValBody`: after the `:` of an entry whose key is at
// indentation m.
func yamlPValBody(lim *Lim, m int, input []rune) (Json, []rune, bool) {
	if !lim.enter() {
		return nil, nil, false
	}
	defer lim.leave()
	if len(input) == 0 {
		return nil, nil, false
	}
	switch input[0] {
	case ' ':
		return yamlPScalarLine(input[1:])
	case '\n':
		r := input[1:]
		if yamlIsItemLine(m+2, r) {
			xs, r, ok := yamlPItems(lim, m+2, r)
			if !ok {
				return nil, nil, false
			}
			return xs, r, true
		}
		es, r, ok := yamlPEntries(lim, m+2, r)
		if !ok {
			return nil, nil, false
		}
		return es, r, true
	}
	return nil, nil, false
}

// yamlTopIsArray is `Yaml.topIsArray`.
func yamlTopIsArray(input []rune) bool {
	return yamlIsItemLine(0, input) && len(input) >= 2 && (input[1] == ' ' || input[1] == '\n')
}

// yamlPTop is `Yaml.pTop`: an array, an object, or one scalar line.
func yamlPTop(lim *Lim, input []rune) (Json, []rune, bool) {
	if yamlTopIsArray(input) {
		xs, r, ok := yamlPItems(lim, 0, input)
		if !ok {
			return nil, nil, false
		}
		return xs, r, true
	}
	if e, r, ok := yamlPEntry(lim, 0, input); ok {
		es, r, ok := yamlPEntries(lim, 0, r)
		if !ok {
			return nil, nil, false
		}
		return append(Obj{e}, es...), r, true
	}
	return yamlPScalarLine(input)
}

// yamlDecode is `Yaml.decode`: all of the input consumed, and the value well
// formed, math leaves allowed (`Json.WFm`).
func yamlDecode(lim *Lim, s []rune) (Json, bool) {
	v, r, ok := yamlPTop(lim, s)
	if !ok || len(r) != 0 || !jsonWfmb(v) {
		return nil, false
	}
	return v, true
}
