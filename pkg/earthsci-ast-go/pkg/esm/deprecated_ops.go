package esm

// The `deprecated_op` rewrite (esm-spec §4.2 "Deprecated ops").
//
// `neg` is the word spelling of unary `-` and `pow` the word spelling of `^`.
// Both still load, but the wire boundary (prepareDocumentOps) rewrites each
// well-formed use to its replacement before anything else reads the document:
//
//	{"op": "neg", "args": [x]}     -> {"op": "-", "args": [x]}
//	{"op": "pow", "args": [x, n]}  -> {"op": "^", "args": [x, n]}
//	{"op": "broadcast", "fn": "neg", ...} -> the same node with "fn": "-"
//
// Only the op (or the `fn`) string changes; every other byte of the document,
// key order included, is kept. A use with the wrong operand count is left as
// written, so its arity error is unchanged. The document then loads with one
// `deprecated_op` warning naming every rewritten node's JSON pointer.

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

// deprecatedOps maps each deprecated op spelling to its replacement and the
// operand count a use must have to be rewritten.
var deprecatedOps = map[string]struct {
	Replacement string
	Arity       int
}{
	"neg": {Replacement: "-", Arity: 1},
	"pow": {Replacement: "^", Arity: 2},
}

// deprecatedOpEdit is one string value to replace: the byte span of the JSON
// string literal in the text, its replacement, and the node's JSON pointer.
type deprecatedOpEdit struct {
	start, end  int
	replacement string
	pointer     string
	spelling    string
}

// rewriteDeprecatedOps applies the §4.2 deprecated-op rewrite to one
// document's JSON text. It returns the rewritten text and the JSON pointers of
// the rewritten nodes (each annotated with its old spelling), in document
// order. Text that does not decode is returned unchanged; schema validation
// reports it.
func rewriteDeprecatedOps(jsonStr string) (string, []string) {
	if !strings.Contains(jsonStr, `"neg"`) && !strings.Contains(jsonStr, `"pow"`) {
		// Cheap filter. A spelling written with a JSON escape inside the string
		// is missed and loads unrewritten; it still evaluates as `neg`/`pow`.
		return jsonStr, nil
	}
	dec := json.NewDecoder(strings.NewReader(jsonStr))
	dec.UseNumber()
	w := &deprecatedOpWalker{src: jsonStr, dec: dec}
	if err := w.value(""); err != nil {
		return jsonStr, nil
	}
	if len(w.edits) == 0 {
		return jsonStr, nil
	}
	var b strings.Builder
	prev := 0
	sites := make([]string, 0, len(w.edits))
	for _, e := range w.edits {
		b.WriteString(jsonStr[prev:e.start])
		b.WriteString(`"` + e.replacement + `"`)
		prev = e.end
		where := e.pointer
		if where == "" {
			where = "/"
		}
		sites = append(sites, fmt.Sprintf("%s (%s)", where, e.spelling))
	}
	b.WriteString(jsonStr[prev:])
	return b.String(), sites
}

// warnDeprecatedOps emits the one `deprecated_op` load warning for a document
// whose rewrite touched sites. Written to stderr, like every other Go load
// warning (warnDeprecatedRecordsPerSample).
func warnDeprecatedOps(sites []string) {
	if len(sites) == 0 {
		return
	}
	fmt.Fprintf(os.Stderr,
		"warning: %s: the op spellings `neg` and `pow` are deprecated (esm-spec §4.2); "+
			"they were rewritten on load to unary `-` and `^`, which mean the same. "+
			"Write `-` and `^`. Rewritten at: %s.\n",
		codeDeprecatedOp, strings.Join(sites, ", "))
}

// deprecatedOpWalker walks a JSON token stream, recording the byte span of
// every string it may need to replace.
type deprecatedOpWalker struct {
	src   string
	dec   *json.Decoder
	edits []deprecatedOpEdit
}

// stringSpan returns the byte span of the JSON string literal the decoder
// just read: it ends at InputOffset, and starts at the opening quote whose
// literal decodes to value.
func (w *deprecatedOpWalker) stringSpan(value string) (int, int) {
	end := int(w.dec.InputOffset())
	for start := strings.LastIndexByte(w.src[:end-1], '"'); start >= 0; start = strings.LastIndexByte(w.src[:start], '"') {
		var got string
		if json.Unmarshal([]byte(w.src[start:end]), &got) == nil && got == value {
			return start, end
		}
	}
	return -1, -1
}

// value reads one JSON value at pointer.
func (w *deprecatedOpWalker) value(pointer string) error {
	tok, err := w.dec.Token()
	if err != nil {
		return err
	}
	if d, ok := tok.(json.Delim); ok {
		return w.descend(d, pointer)
	}
	return nil
}

// object reads the members of an object (its '{' already read) and records a
// rewrite when the object is a deprecated-op node or a `broadcast` with a
// deprecated `fn`.
func (w *deprecatedOpWalker) object(pointer string) error {
	var (
		op, fn         string
		opStart, opEnd = -1, -1
		fnStart, fnEnd = -1, -1
		argCount       = -1
	)
	for w.dec.More() {
		keyTok, err := w.dec.Token()
		if err != nil {
			return err
		}
		key, _ := keyTok.(string)
		child := pointer + "/" + escapeJSONPointerSegment(key)
		switch key {
		case "op", "fn":
			tok, err := w.dec.Token()
			if err != nil {
				return err
			}
			switch v := tok.(type) {
			case string:
				s, e := w.stringSpan(v)
				if key == "op" {
					op, opStart, opEnd = v, s, e
				} else {
					fn, fnStart, fnEnd = v, s, e
				}
			case json.Delim:
				// Not a string: walk it as an ordinary value.
				if err := w.descend(v, child); err != nil {
					return err
				}
			}
		case "args":
			n, err := w.array(child)
			if err != nil {
				return err
			}
			argCount = n
		default:
			if err := w.value(child); err != nil {
				return err
			}
		}
	}
	if _, err := w.dec.Token(); err != nil { // '}'
		return err
	}
	if dep, ok := deprecatedOps[op]; ok && argCount == dep.Arity && opStart >= 0 {
		w.addEdit(deprecatedOpEdit{start: opStart, end: opEnd, replacement: dep.Replacement,
			pointer: pointer, spelling: op})
	}
	if op == "broadcast" && fn == "neg" && fnStart >= 0 {
		w.addEdit(deprecatedOpEdit{start: fnStart, end: fnEnd, replacement: "-",
			pointer: pointer, spelling: "fn neg"})
	}
	return nil
}

// addEdit inserts e keeping edits sorted by position (an object's own edit is
// found after its children's).
func (w *deprecatedOpWalker) addEdit(e deprecatedOpEdit) {
	i := len(w.edits)
	for i > 0 && w.edits[i-1].start > e.start {
		i--
	}
	w.edits = append(w.edits, deprecatedOpEdit{})
	copy(w.edits[i+1:], w.edits[i:])
	w.edits[i] = e
}

// array reads an `args` value and returns its element count, or -1 when it is
// not an array.
func (w *deprecatedOpWalker) array(pointer string) (int, error) {
	tok, err := w.dec.Token()
	if err != nil {
		return -1, err
	}
	d, ok := tok.(json.Delim)
	if !ok {
		return -1, nil
	}
	if d == '{' {
		return -1, w.object(pointer)
	}
	return w.elements(pointer)
}

// descend walks a container whose opening delimiter was already read.
func (w *deprecatedOpWalker) descend(d json.Delim, pointer string) error {
	if d == '{' {
		return w.object(pointer)
	}
	_, err := w.elements(pointer)
	return err
}

// elements reads the elements of an array (its '[' already read) and the
// closing ']', returning the element count.
func (w *deprecatedOpWalker) elements(pointer string) (int, error) {
	i := 0
	for w.dec.More() {
		if err := w.value(fmt.Sprintf("%s/%d", pointer, i)); err != nil {
			return -1, err
		}
		i++
	}
	_, err := w.dec.Token() // ']'
	return i, err
}
