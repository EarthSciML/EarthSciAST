package esm

// esm 2.4.0 "one operator type": the spellings an earlier document wrote, read
// at the wire boundary (esm-spec §9.6.12 "Old names (no refusal)", §4.2
// "Reading earlier documents"). Nothing is refused:
//
//   - the field `expression_templates` is read as `operators` and
//     `expression_template_imports` as `operator_imports` (warning
//     `deprecated_field`), wherever a field of that name appears — never among
//     the keys of a name-keyed map, whose keys are author-chosen names;
//   - the op `apply_expression_template` is read as `apply_operator`, and the
//     spatial derivative — a `D` whose `wrt` is present and is not the literal
//     "t", and the spellings `δ` and `∂` — as `partial`, every other field kept
//     (warning `deprecated_op`). A `D` whose `wrt` names one of the params of
//     the enclosing `operators` entry is left as written: it is decided per
//     definition instance (esm-spec §9.6.4 rule 3; instancePartial).
//
// Like rewriteDeprecatedOps, the rewrite is TEXTUAL: it replaces the spans of
// the renamed key and op strings, so every other byte and the authored key
// order survive. It is idempotent; a second pass is silent.

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
)

// oldFieldSpellings maps an old field spelling to its esm-2.4.0 name.
var oldFieldSpellings = map[string]string{
	"expression_templates":        "operators",
	"expression_template_imports": "operator_imports",
}

// oldApplyOp is the old op spelling of the reference node.
const oldApplyOp = "apply_expression_template"

// partialSpellings are the other spellings of the spatial derivative.
var partialSpellings = map[string]bool{"δ": true, "∂": true}

// opPartial is the defined operator of the spatial (partial) derivative
// (esm-spec §4.2).
const opPartial = "partial"

// oldSpellingNameMaps: objects whose keys are author-chosen names, not
// fields. A field spelling is never renamed among them (a variable may be
// called `expression_templates`), and their direct members are not expression
// nodes.
var oldSpellingNameMaps = func() map[string]struct{} {
	out := map[string]struct{}{"expression_templates": {}}
	for k := range nameKeyedMapKeys {
		out[k] = struct{}{}
	}
	for _, k := range []string{"models", "reaction_systems", "data_sources", "index_sets",
		"enums", "metaparameters", "domains", "coupling_roles"} {
		out[k] = struct{}{}
	}
	return out
}()

type oldSpellingEdit struct {
	start, end  int
	replacement string
	site        string
	field       bool
}

// a `D` whose rewrite waits on the params of its enclosing definition.
type pendingD struct {
	edit  oldSpellingEdit
	entry int    // the enclosing definition's index in oldSpellingWalker.entries, or -1
	wrt   string // the `wrt` string, "" when it is not a string
	isStr bool
}

type oldSpellingWalker struct {
	src     string
	dec     *json.Decoder
	edits   []oldSpellingEdit
	pending []pendingD
	entries []map[string]bool // each definition entry's params (nil: not an array of strings)
	entryAt []string          // each definition entry's pointer
	err     error
}

// rewriteOldSpellings applies the esm-2.4.0 old-spelling reading to one
// document's JSON text. It returns the rewritten text, the `deprecated_field`
// sites and the `deprecated_op` sites (each "<pointer> (<old>)", in document
// order), or an error when an object spells a field both ways. Text that does
// not decode is returned unchanged; schema validation reports it.
func rewriteOldSpellings(jsonStr string) (string, []string, []string, error) {
	if !mayHoldOldSpellings(jsonStr) {
		return jsonStr, nil, nil, nil
	}
	dec := json.NewDecoder(strings.NewReader(jsonStr))
	dec.UseNumber()
	w := &oldSpellingWalker{src: jsonStr, dec: dec}
	if err := w.value("", false, -1); err != nil {
		if w.err != nil {
			return "", nil, nil, w.err
		}
		return jsonStr, nil, nil, nil
	}
	for _, p := range w.pending {
		if p.isStr && p.entry >= 0 && w.entries[p.entry] != nil && w.entries[p.entry][p.wrt] {
			continue // decided per instance
		}
		w.edits = append(w.edits, p.edit)
	}
	if len(w.edits) == 0 {
		return jsonStr, nil, nil, nil
	}
	sort.Slice(w.edits, func(i, j int) bool { return w.edits[i].start < w.edits[j].start })
	var b strings.Builder
	prev := 0
	var fsites, osites []string
	for _, e := range w.edits {
		b.WriteString(jsonStr[prev:e.start])
		b.WriteString(`"` + e.replacement + `"`)
		prev = e.end
		if e.field {
			fsites = append(fsites, e.site)
		} else {
			osites = append(osites, e.site)
		}
	}
	b.WriteString(jsonStr[prev:])
	return b.String(), fsites, osites, nil
}

// mayHoldOldSpellings is the cheap filter: text with none of the old names
// and no `wrt` field has nothing to rewrite.
func mayHoldOldSpellings(s string) bool {
	return strings.Contains(s, "expression_template") || strings.Contains(s, `"wrt"`) ||
		strings.Contains(s, "δ") || strings.Contains(s, "∂")
}

// warnOldSpellings emits the (at most two) load warnings for one document.
func warnOldSpellings(fsites, osites []string) {
	if len(fsites) > 0 {
		fmt.Fprintf(os.Stderr,
			"warning: %s: the fields `expression_templates` and `expression_template_imports` "+
				"are read as `operators` and `operator_imports` (esm 2.4.0, esm-spec §9.6.12). "+
				"Read at: %s.\n", codeDeprecatedField, strings.Join(fsites, ", "))
	}
	if len(osites) > 0 {
		fmt.Fprintf(os.Stderr,
			"warning: %s: `apply_expression_template` is read as `apply_operator`, and a "+
				"spatial `D` (and `δ`, `∂`) as `partial` (esm 2.4.0, esm-spec §4.2, §9.6.12). "+
				"Rewritten at: %s.\n", codeDeprecatedOp, strings.Join(osites, ", "))
	}
}

// readOldSpellings is the wire-boundary step: rewrite, then warn.
func readOldSpellings(jsonStr string) (string, error) {
	out, fsites, osites, err := rewriteOldSpellings(jsonStr)
	if err != nil {
		return "", err
	}
	warnOldSpellings(fsites, osites)
	return out, nil
}

// span returns the byte span of the JSON string literal the decoder just read.
func (w *oldSpellingWalker) span(value string) (int, int) {
	end := int(w.dec.InputOffset())
	for start := strings.LastIndexByte(w.src[:end-1], '"'); start >= 0; start = strings.LastIndexByte(w.src[:start], '"') {
		var got string
		if json.Unmarshal([]byte(w.src[start:end]), &got) == nil && got == value {
			return start, end
		}
	}
	return -1, -1
}

func (w *oldSpellingWalker) value(pointer string, namemap bool, entry int) error {
	tok, err := w.dec.Token()
	if err != nil {
		return err
	}
	if d, ok := tok.(json.Delim); ok {
		return w.descend(d, pointer, namemap, entry)
	}
	return nil
}

func (w *oldSpellingWalker) descend(d json.Delim, pointer string, namemap bool, entry int) error {
	if d == '{' {
		return w.object(pointer, namemap, entry, false)
	}
	i := 0
	for w.dec.More() {
		if err := w.value(fmt.Sprintf("%s/%d", pointer, i), false, entry); err != nil {
			return err
		}
		i++
	}
	_, err := w.dec.Token() // ']'
	return err
}

// object walks an object (its '{' already read). namemap: its keys are
// names, not fields. defBlock: it is an `operators` block, each of whose
// members is a definition entry.
func (w *oldSpellingWalker) object(pointer string, namemap bool, entry int, defBlock bool) error {
	var (
		op               string
		opStart, opEnd   = -1, -1
		wrt              string
		wrtStr, wrtFound bool
		seen             = map[string]bool{}
	)
	for w.dec.More() {
		keyTok, err := w.dec.Token()
		if err != nil {
			return err
		}
		key, _ := keyTok.(string)
		field := key
		if !namemap {
			if nk, old := oldFieldSpellings[key]; old {
				ks, ke := w.span(key)
				if ks >= 0 {
					w.edits = append(w.edits, oldSpellingEdit{start: ks, end: ke, replacement: nk,
						site: fmt.Sprintf("%s (%s)", pointer+"/"+escapeJSONPointerSegment(nk), key), field: true})
				}
				field = nk
			}
			if seen[field] {
				w.err = newETErr(CodeApplyExpressionTemplateInvalidDeclaration,
					fmt.Sprintf("%s: an object carries both `%s` and its esm-2.4.0 spelling `%s`; "+
						"write only `%s` (esm-spec §9.6.12)", pointerOrRoot(pointer),
						oldNameOf(field), field, field))
				return w.err
			}
			seen[field] = true
		}
		child := pointer + "/" + escapeJSONPointerSegment(field)
		if defBlock {
			// A definition entry: its own params decide a `D` whose `wrt` names one.
			idx := len(w.entries)
			w.entries = append(w.entries, nil)
			w.entryAt = append(w.entryAt, child)
			if err := w.entryValue(child, idx); err != nil {
				return err
			}
			continue
		}
		if namemap {
			if err := w.value(child, false, entry); err != nil {
				return err
			}
			continue
		}
		switch field {
		case "op":
			tok, err := w.dec.Token()
			if err != nil {
				return err
			}
			switch v := tok.(type) {
			case string:
				op = v
				opStart, opEnd = w.span(v)
			case json.Delim:
				if err := w.descend(v, child, false, entry); err != nil {
					return err
				}
			}
		case "wrt":
			tok, err := w.dec.Token()
			if err != nil {
				return err
			}
			switch v := tok.(type) {
			case json.Delim:
				wrtFound = true
				if err := w.descend(v, child, false, entry); err != nil {
					return err
				}
			case nil:
				// JSON null: no `wrt` (esm-spec §4.2: an absent `wrt` means `t`).
			case string:
				wrtFound, wrtStr, wrt = true, true, v
			default:
				wrtFound = true
			}
		case "params":
			if entry >= 0 && w.entryAt[entry] == pointer {
				if err := w.paramsValue(child, entry); err != nil {
					return err
				}
				continue
			}
			if err := w.value(child, false, entry); err != nil {
				return err
			}
		default:
			tok, err := w.dec.Token()
			if err != nil {
				return err
			}
			if d, ok := tok.(json.Delim); ok {
				if d == '{' && field == "operators" {
					if err := w.object(child, false, entry, true); err != nil {
						return err
					}
				} else {
					_, nm := oldSpellingNameMaps[field]
					if err := w.descend(d, child, nm && d == '{', entry); err != nil {
						return err
					}
				}
			}
		}
	}
	if _, err := w.dec.Token(); err != nil { // '}'
		return err
	}
	if opStart < 0 {
		return nil
	}
	switch {
	case op == oldApplyOp:
		w.edits = append(w.edits, oldSpellingEdit{start: opStart, end: opEnd,
			replacement: applyExpressionTemplateOp, site: fmt.Sprintf("%s (%s)", pointer, op)})
	case partialSpellings[op]:
		w.edits = append(w.edits, oldSpellingEdit{start: opStart, end: opEnd,
			replacement: opPartial, site: fmt.Sprintf("%s (%s)", pointer, op)})
	case op == OpDerivative && wrtFound && !(wrtStr && wrt == "t"):
		w.pending = append(w.pending, pendingD{
			edit: oldSpellingEdit{start: opStart, end: opEnd, replacement: opPartial,
				site: fmt.Sprintf("%s (D)", pointer)},
			entry: entry, wrt: wrt, isStr: wrtStr,
		})
	}
	return nil
}

// entryValue walks one definition entry: an object whose `params` are
// recorded under idx, and whose subtree carries idx as its enclosing entry.
func (w *oldSpellingWalker) entryValue(pointer string, idx int) error {
	tok, err := w.dec.Token()
	if err != nil {
		return err
	}
	d, ok := tok.(json.Delim)
	if !ok {
		return nil
	}
	if d != '{' {
		return w.descend(d, pointer, false, idx)
	}
	return w.object(pointer, false, idx, false)
}

// paramsValue reads an entry's `params` array, recording its string members.
func (w *oldSpellingWalker) paramsValue(pointer string, idx int) error {
	tok, err := w.dec.Token()
	if err != nil {
		return err
	}
	d, ok := tok.(json.Delim)
	if !ok {
		return nil
	}
	if d != '[' {
		return w.descend(d, pointer, false, idx)
	}
	ps := map[string]bool{}
	i := 0
	for w.dec.More() {
		t, err := w.dec.Token()
		if err != nil {
			return err
		}
		switch v := t.(type) {
		case string:
			ps[v] = true
		case json.Delim:
			if err := w.descend(v, fmt.Sprintf("%s/%d", pointer, i), false, idx); err != nil {
				return err
			}
		}
		i++
	}
	if _, err := w.dec.Token(); err != nil {
		return err
	}
	w.entries[idx] = ps
	return nil
}

func pointerOrRoot(p string) string {
	if p == "" {
		return "/"
	}
	return p
}

func oldNameOf(newName string) string {
	for o, n := range oldFieldSpellings {
		if n == newName {
			return o
		}
	}
	return newName
}

// readOldSpellingsView is readOldSpellings over an already-decoded document,
// in place: for entry points handed a map, which has no wire boundary of its
// own. A view that spells nothing old is left untouched.
func readOldSpellingsView(view map[string]any) error {
	if view == nil {
		return nil
	}
	raw, err := json.Marshal(view)
	if err != nil {
		return nil
	}
	out, err := readOldSpellings(string(raw))
	if err != nil {
		return err
	}
	if out == string(raw) {
		return nil
	}
	nv, err := decodeJSONView([]byte(out))
	if err != nil {
		return nil
	}
	for k := range view {
		delete(view, k)
	}
	for k, v := range nv {
		view[k] = v
	}
	return nil
}

// newSpellingText is jsonStr in its esm-2.4.0 spelling, silently: for a
// caller re-reading a source a load has already read (and warned about).
func newSpellingText(jsonStr string) string {
	out, _, _, err := rewriteOldSpellings(jsonStr)
	if err != nil {
		return jsonStr
	}
	return out
}
