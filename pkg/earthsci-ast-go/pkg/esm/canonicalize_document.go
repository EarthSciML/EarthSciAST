package esm

import (
	"encoding/json"
	"math"
	"strconv"
	"strings"
)

// The document-level canonical step (esm-spec §4.8.2 "Canonical spelling").

// documentMapKeys are the object properties whose value is a NAME-KEYED map
// (esm-schema.json): a map's keys are names, never fields, so a variable NAMED
// `units` is not a units string. The same list in every binding.
var documentMapKeys = map[string]bool{
	"bind": true, "bindings": true, "coordinates": true, "coords": true,
	"coupling_roles": true, "data_sources": true, "enums": true,
	"operator_imports": true, "operators": true,
	"guesses": true, "index_set_rename": true, "index_sets": true,
	"initial_conditions": true, "map": true, "metaparameters": true,
	"models": true, "parameter_overrides": true, "parameters": true,
	"pinned_coords": true, "ranges": true, "reaction_systems": true,
	"rebind": true, "rename": true, "species": true, "subsystems": true,
	"translate": true, "url_substitutions": true, "variables": true,
	"where": true,
}

// documentFreeKeys are the free-form objects (schema
// `additionalProperties: true`), never descended.
var documentFreeKeys = map[string]bool{
	"attrs": true, "config": true, "metadata": true, "reader_options": true, "x_esd": true,
}

// CanonicalizeDocument is the document-level canonical step: every units
// string of a decoded document (the JSON value ToJSON writes and LoadDocument
// reads, as produced by encoding/json into `any`) takes the canonical unit
// spelling (esm-spec §4.8.2, Lean `Esm.Units.canon`).
//
// That is every `units` and `default_units` string of a variable, species,
// parameter, coordinate or `const` node, wherever it sits: nested subsystems,
// template bodies, tests, coupling entries. Free-form objects (`metadata`,
// `x_esd`, `attrs`, `config`, `reader_options`) are not respelled, and neither
// are the keys of name-keyed maps. A `const` node whose units spell `1` loses
// them: a scalar one becomes the bare literal, an array one a `const` without
// `units`. The deprecated ops are rewritten (esm-spec §4.2): a `neg` node with
// one argument becomes unary `-`, a `pow` node with two becomes `^`, and a
// `broadcast` of `neg` with one argument maps `-`. Every number, free-form
// objects included, takes its canonical form (CONFORMANCE §5.5.3.1): an integral
// value in Int64 is an int64 (`2.0` is `2`, `-0.0` is `0`), any other finite
// value a float64. A json.Number (a decoder with UseNumber) that is an integer
// token in Int64 is that int64 exactly, past 2^53 too; any other token is read
// as the nearest float64 (one below the smallest subnormal is 0); a token
// beyond the binary64 range (`1e400`) has no nearest float64 and is kept as
// written. The input is not mutated and nothing else changes.
// These are the rules of Lean `Adapter.Doc.spellRules` and `Adapter.Doc.conv`.
func CanonicalizeDocument(doc any) any {
	return canonicalDocumentNumbers(canonicalizeDocumentValue(newSpellingValue(doc), false))
}

// newSpellingValue is doc read in its esm-2.4.0 spelling (esm-spec §9.6.12,
// §4.2 "Reading earlier documents": `expression_templates` as `operators`, a
// spatial `D` as `partial`, …), silently; doc itself when it spells nothing old.
func newSpellingValue(doc any) any {
	switch doc.(type) {
	case map[string]any, []any:
	default:
		return doc
	}
	raw, err := json.Marshal(doc)
	if err != nil {
		return doc
	}
	out := newSpellingText(string(raw))
	if out == string(raw) {
		return doc
	}
	dec := json.NewDecoder(strings.NewReader(out))
	dec.UseNumber()
	var v any
	if err := dec.Decode(&v); err != nil {
		return doc
	}
	return v
}

// canonicalDocumentNumber is a JSON number in canonical form (CONFORMANCE
// §5.5.3.1); ok is false when value is not a number.
func canonicalDocumentNumber(value any) (any, bool) {
	var f float64
	switch v := value.(type) {
	case json.Number:
		s := string(v)
		if !strings.ContainsAny(s, ".eE") {
			if i, err := strconv.ParseInt(s, 10, 64); err == nil {
				return i, true
			}
		}
		parsed, err := strconv.ParseFloat(s, 64)
		if err != nil {
			// A token beyond the binary64 range (`1e400`) has no nearest finite
			// value, so it stays as written rather than becoming ±Inf, which no
			// JSON can hold. The Rust binding's JSON reader refuses the literal,
			// as encoding/json does decoding it into a float64.
			return value, true
		}
		f = parsed
	case float64:
		f = v
	case float32:
		f = float64(v)
	case int:
		return int64(v), true
	case int8:
		return int64(v), true
	case int16:
		return int64(v), true
	case int32:
		return int64(v), true
	case int64:
		return v, true
	case uint8:
		return int64(v), true
	case uint16:
		return int64(v), true
	case uint32:
		return int64(v), true
	case uint:
		if uint64(v) <= math.MaxInt64 {
			return int64(v), true
		}
		return float64(v), true
	case uint64:
		if v <= math.MaxInt64 {
			return int64(v), true
		}
		return float64(v), true
	default:
		return value, false
	}
	if f == math.Trunc(f) && f >= -0x1p63 && f < 0x1p63 {
		return int64(f), true
	}
	return f, true
}

// canonicalDocumentNumbers puts every number of a JSON value in canonical form,
// at every depth.
func canonicalDocumentNumbers(value any) any {
	if n, ok := canonicalDocumentNumber(value); ok {
		return n
	}
	switch v := value.(type) {
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = canonicalDocumentNumbers(item)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(v))
		for k, item := range v {
			out[k] = canonicalDocumentNumbers(item)
		}
		return out
	default:
		return value
	}
}

// rewriteDeprecatedDocumentOp rewrites a deprecated op node in place (out is a
// fresh map): `neg` with one argument is unary `-`, `pow` with two is `^`, a
// `broadcast` of `neg` with one argument maps `-` (Lean
// `Adapter.Doc.deprecatedTo`).
func rewriteDeprecatedDocumentOp(out map[string]any) {
	op, isString := out["op"].(string)
	args, isArray := out["args"].([]any)
	if !isString || !isArray {
		return
	}
	if dep, ok := deprecatedOps[op]; ok {
		if len(args) == dep.Arity {
			out["op"] = dep.Replacement
		}
	} else if op == "broadcast" && out["fn"] == "neg" && len(args) == deprecatedOps["neg"].Arity {
		out["fn"] = "-"
	}
}

func canonicalizeDocumentValue(value any, isMap bool) any {
	switch v := value.(type) {
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = canonicalizeDocumentValue(item, false)
		}
		return out
	case map[string]any:
		dropUnits := false
		if units, ok := v["units"].(string); ok && !isMap && v["op"] == "const" && canonicalUnitSpelling(units) == "1" {
			// A dimensionless const drops its units: a scalar becomes the bare
			// literal, an array a unitless const.
			switch v["value"].(type) {
			case float64, json.Number, int, int64:
				return v["value"]
			}
			dropUnits = true
		}
		out := make(map[string]any, len(v))
		for k, item := range v {
			if dropUnits && k == "units" {
				continue
			}
			s, isString := item.(string)
			switch {
			case isMap:
				out[k] = canonicalizeDocumentValue(item, false)
			case (k == "units" || k == "default_units") && isString:
				out[k] = canonicalUnitSpelling(s)
			case documentFreeKeys[k]:
				out[k] = item
			default:
				out[k] = canonicalizeDocumentValue(item, documentMapKeys[k])
			}
		}
		if !isMap {
			rewriteDeprecatedDocumentOp(out)
		}
		return out
	default:
		return value
	}
}
