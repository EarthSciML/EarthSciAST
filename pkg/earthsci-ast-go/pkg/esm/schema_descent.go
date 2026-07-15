package esm

import (
	"encoding/json"
	"regexp"
	"strconv"
	"strings"
	"sync"

	"github.com/xeipuuv/gojsonschema"
)

// schema_descent.go recovers the DEEP sub-branch schema errors that gojsonschema
// discards when a `oneOf`/`anyOf` fails.
//
// gojsonschema surfaces a composition failure only as a shallow record at the
// branch point ("Must validate one and only one schema (oneOf)") — it throws
// away the errors from the individual branches, so a `required`/`const`/`type`
// violation INSIDE a failing branch is unproducible. AJV (the reference
// producer) and the Rust/Julia bindings surface them, and the shared corpus
// pins several (bare_reference_errors, coupling_resolution_errors,
// event_error_conditions, scoped_reference_resolution_errors).
//
// The fix mirrors the Rust binding (src/parse.rs collect_schema_errors): descend
// the schema MANUALLY and use gojsonschema as a leaf oracle. For each failing
// composition, navigate to the `oneOf`/`anyOf` array governing the offending
// instance subtree, compile every branch sub-schema standalone (with the
// document `$defs` injected so its internal `$ref`s resolve), re-validate the
// subtree against it, and emit the branch's own (recursively descended) errors
// at their absolute JSON Pointer. gojsonschema exposes the offending INSTANCE
// path (JsonContext) but not the SCHEMA path, so the composition array is located
// by navigating the schema in parallel with the instance path rather than by the
// crate's schema pointer (which the Rust crate provides and this one does not).
//
// Extra errors are harmless — the cross-language comparator is a required-subset
// — so every branch is explored; identical records are de-duplicated at the end.

// schemaDescentCap bounds the branch-descent recursion. Deep enough for the ESM
// schema's real nesting (document → model → event → trigger), bounded so a
// self-referential `$ref` (e.g. Expression) cannot recurse without end.
const schemaDescentCap = 16

// schemaRootCache holds the parsed schema document (and its `$defs`) so the
// descent does not re-parse the embedded schema for every validated file.
var (
	schemaRootOnce sync.Once
	schemaRootMap  map[string]any
	schemaDefsMap  map[string]any
)

func schemaRoot() (root, defs map[string]any) {
	schemaRootOnce.Do(func() {
		_ = json.Unmarshal(embeddedSchema, &schemaRootMap)
		if schemaRootMap != nil {
			schemaDefsMap, _ = schemaRootMap["$defs"].(map[string]any)
		}
	})
	return schemaRootMap, schemaDefsMap
}

// gojsonSummary is an owned projection of one gojsonschema error, decoupled from
// the *Result so a compiled branch schema can be released before recursing.
type gojsonSummary struct {
	instancePath  string // RFC-6901 pointer relative to the validated instance root
	keyword       string
	message       string
	isComposition bool
}

// summarizeGojson projects gojsonschema errors to owned summaries.
func summarizeGojson(errs []gojsonschema.ResultError) []gojsonSummary {
	out := make([]gojsonSummary, 0, len(errs))
	for _, desc := range errs {
		t := desc.Type()
		out = append(out, gojsonSummary{
			instancePath:  jsonPointerFromContext(desc.Context()),
			keyword:       schemaKeyword(t),
			message:       desc.Description(),
			isComposition: t == "number_one_of" || t == "number_any_of",
		})
	}
	return out
}

// collectSchemaErrorsWithDescent emits one SchemaError per top-level violation
// (identical to the shallow behaviour) and, for each `oneOf`/`anyOf` failure,
// the deep branch errors recovered by descending the composition. topErrors are
// the errors from validating the whole document against the full schema.
func collectSchemaErrorsWithDescent(jsonStr string, topErrors []gojsonschema.ResultError) []SchemaError {
	root, defs := schemaRoot()
	summaries := summarizeGojson(topErrors)

	// Without a parsed schema the descent cannot run; fall back to the shallow
	// records so behaviour never regresses.
	if root == nil {
		out := make([]SchemaError, 0, len(summaries))
		for _, s := range summaries {
			out = append(out, SchemaError{Path: s.instancePath, Message: s.message, Keyword: s.keyword})
		}
		return out
	}

	var doc any
	_ = json.Unmarshal([]byte(jsonStr), &doc)

	cache := map[string]*gojsonschema.Schema{}
	var out []SchemaError
	descendSchemaErrors(root, defs, cache, root, doc, "", summaries, 0, &out)
	return dedupSchemaErrors(out)
}

// descendSchemaErrors emits each summary and, for a composition failure, descends
// every branch of the governing `oneOf`/`anyOf` — validating the offending
// subtree against each branch standalone and recursing on the branch's own
// errors. navSchema is the schema fragment the summaries' instance paths are
// relative to; instance is the value validated against it; base is the absolute
// instance-pointer prefix of that value.
func descendSchemaErrors(root, defs map[string]any, cache map[string]*gojsonschema.Schema,
	navSchema map[string]any, instance any, base string, summaries []gojsonSummary, depth int, out *[]SchemaError) {

	for _, s := range summaries {
		absPath := base + s.instancePath
		// Always emit the error itself — for a composition failure this is the
		// shallow `oneOf`/`anyOf` record, which some pins want exactly (e.g. the
		// root `anyOf` when a document declares no systems).
		*out = append(*out, SchemaError{Path: absPath, Message: s.message, Keyword: s.keyword})

		if !s.isComposition || depth >= schemaDescentCap {
			continue
		}
		segs := jsonPointerSegments(s.instancePath)
		compNode, ok := schemaAtInstancePath(root, navSchema, segs)
		if !ok {
			continue
		}
		branches := compositionBranches(compNode)
		if len(branches) == 0 {
			continue
		}
		subInstance := instancePointerGet(instance, segs)
		for _, branch := range branches {
			branchSchema := resolveSchemaRef(root, branch, 0)
			subSummaries := validateBranch(cache, defs, branchSchema, subInstance)
			descendSchemaErrors(root, defs, cache, branchSchema, subInstance, absPath, subSummaries, depth+1, out)
		}
	}
}

// validateBranch compiles branchSchema standalone (with `$defs` injected) and
// validates instance against it, returning the branch's own error summaries.
func validateBranch(cache map[string]*gojsonschema.Schema, defs, branchSchema map[string]any, instance any) []gojsonSummary {
	compiled := compileBranch(cache, defs, branchSchema)
	if compiled == nil {
		return nil
	}
	res, err := compiled.Validate(gojsonschema.NewGoLoader(instance))
	if err != nil || res.Valid() {
		return nil
	}
	return summarizeGojson(res.Errors())
}

// compileBranch compiles a branch sub-schema standalone, injecting the document
// `$defs` (and `$schema`) so its internal `#/$defs/...` refs resolve. It is
// memoized by the branch's canonical JSON so a repeatedly-tested branch (the
// coupling `oneOf` is re-checked for every failing entry) compiles once. A nil
// cache entry records a branch that could not be compiled.
func compileBranch(cache map[string]*gojsonschema.Schema, defs, branchSchema map[string]any) *gojsonschema.Schema {
	keyb, err := json.Marshal(branchSchema)
	if err != nil {
		return nil
	}
	key := string(keyb)
	if c, ok := cache[key]; ok {
		return c
	}

	wrapper := make(map[string]any, len(branchSchema)+2)
	for k, v := range branchSchema {
		wrapper[k] = v
	}
	if defs != nil {
		if _, has := wrapper["$defs"]; !has {
			wrapper["$defs"] = defs
		}
	}
	if root, _ := schemaRoot(); root != nil {
		if _, has := wrapper["$schema"]; !has {
			if sv, ok := root["$schema"]; ok {
				wrapper["$schema"] = sv
			}
		}
	}

	schema, cerr := gojsonschema.NewSchema(gojsonschema.NewGoLoader(wrapper))
	if cerr != nil {
		cache[key] = nil
		return nil
	}
	cache[key] = schema
	return schema
}

// compositionBranches returns the `oneOf` (preferred) or `anyOf` branch list of
// a schema node, or nil if it is not a composition node.
func compositionBranches(node map[string]any) []map[string]any {
	for _, key := range []string{"oneOf", "anyOf"} {
		if arr, ok := node[key].([]any); ok {
			out := make([]map[string]any, 0, len(arr))
			for _, b := range arr {
				if bm, ok := b.(map[string]any); ok {
					out = append(out, bm)
				}
			}
			return out
		}
	}
	return nil
}

// schemaAtInstancePath navigates navSchema by the instance-path segments to the
// schema node governing that sub-instance (resolving `$ref`s and descending
// through `properties`/`items`/`additionalProperties`/`patternProperties` and,
// where a segment is not directly present, through composition branches). The
// returned node is the one whose `oneOf`/`anyOf` a composition error refers to.
func schemaAtInstancePath(root, navSchema map[string]any, segments []string) (map[string]any, bool) {
	cur := resolveSchemaRef(root, navSchema, 0)
	for _, seg := range segments {
		child, ok := schemaChildForSegment(root, cur, seg, 0)
		if !ok {
			return nil, false
		}
		cur = resolveSchemaRef(root, child, 0)
	}
	return cur, true
}

// schemaChildForSegment returns the sub-schema governing instance member seg of
// the value described by node (an object property, an array element, or an
// additional/pattern property). When node is itself a composition it searches
// each branch for one that governs seg. depth guards against a pathological
// self-referential composition.
func schemaChildForSegment(root, node map[string]any, seg string, depth int) (map[string]any, bool) {
	if depth > schemaDescentCap {
		return nil, false
	}
	node = resolveSchemaRef(root, node, 0)

	// Object property.
	if props, ok := node["properties"].(map[string]any); ok {
		if child, ok := props[seg].(map[string]any); ok {
			return child, true
		}
	}
	// Array element: `items` as a single schema (or a tuple list).
	if _, isIndex := arrayIndex(seg); isIndex {
		if items, ok := node["items"].(map[string]any); ok {
			return items, true
		}
		if itemsArr, ok := node["items"].([]any); ok {
			if idx, _ := arrayIndex(seg); idx < len(itemsArr) {
				if child, ok := itemsArr[idx].(map[string]any); ok {
					return child, true
				}
			}
		}
	}
	// Pattern properties.
	if pp, ok := node["patternProperties"].(map[string]any); ok {
		for pat, sub := range pp {
			if matched, _ := regexp.MatchString(pat, seg); matched {
				if child, ok := sub.(map[string]any); ok {
					return child, true
				}
			}
		}
	}
	// Additional properties as a schema (reached only when no named property matched).
	if ap, ok := node["additionalProperties"].(map[string]any); ok {
		return ap, true
	}
	// Composition: the value is governed by one of these branches — return the
	// first branch that has a child for seg.
	for _, key := range []string{"oneOf", "anyOf", "allOf"} {
		if arr, ok := node[key].([]any); ok {
			for _, b := range arr {
				if bm, ok := b.(map[string]any); ok {
					if child, ok := schemaChildForSegment(root, bm, seg, depth+1); ok {
						return child, true
					}
				}
			}
		}
	}
	return nil, false
}

// resolveSchemaRef follows local `#/...` `$ref`s until node is a concrete schema
// object, bounded against a `$ref` cycle.
func resolveSchemaRef(root, node map[string]any, depth int) map[string]any {
	for depth < schemaDescentCap {
		ref, ok := node["$ref"].(string)
		if !ok {
			return node
		}
		target, ok := schemaPointer(root, ref)
		if !ok {
			return node
		}
		node = target
		depth++
	}
	return node
}

// schemaPointer resolves a local JSON-Pointer `$ref` ("#/$defs/CouplingCouple")
// against the schema document.
func schemaPointer(root map[string]any, ref string) (map[string]any, bool) {
	if len(ref) == 0 || ref[0] != '#' {
		return nil, false
	}
	ptr := ref[1:]
	if ptr == "" {
		return root, true
	}
	var cur any = root
	for _, seg := range jsonPointerSegments(ptr) {
		m, ok := cur.(map[string]any)
		if !ok {
			return nil, false
		}
		cur, ok = m[seg]
		if !ok {
			return nil, false
		}
	}
	m, ok := cur.(map[string]any)
	return m, ok
}

// instancePointerGet walks a decoded JSON value by JSON-Pointer segments,
// returning nil if the path does not exist.
func instancePointerGet(instance any, segments []string) any {
	cur := instance
	for _, seg := range segments {
		switch v := cur.(type) {
		case map[string]any:
			cur = v[seg]
		case []any:
			idx, ok := arrayIndex(seg)
			if !ok || idx >= len(v) {
				return nil
			}
			cur = v[idx]
		default:
			return nil
		}
	}
	return cur
}

// jsonPointerSegments splits an RFC-6901 JSON Pointer into its decoded reference
// tokens (`~1` → `/`, `~0` → `~`); "" yields no segments.
func jsonPointerSegments(pointer string) []string {
	if pointer == "" {
		return nil
	}
	raw := pointer
	if raw[0] == '/' {
		raw = raw[1:]
	}
	parts := strings.Split(raw, "/")
	out := make([]string, len(parts))
	for i, p := range parts {
		p = strings.ReplaceAll(p, "~1", "/")
		p = strings.ReplaceAll(p, "~0", "~")
		out[i] = p
	}
	return out
}

// arrayIndex reports whether seg is a non-negative decimal index and its value.
func arrayIndex(seg string) (int, bool) {
	n, err := strconv.Atoi(seg)
	if err != nil || n < 0 {
		return 0, false
	}
	return n, true
}

// dedupSchemaErrors removes exact (path, keyword, message) duplicates that the
// branch sweep produces when several branches fail identically, preserving first
// occurrence order.
func dedupSchemaErrors(errs []SchemaError) []SchemaError {
	seen := make(map[[3]string]bool, len(errs))
	out := errs[:0]
	for _, e := range errs {
		key := [3]string{e.Path, e.Keyword, e.Message}
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, e)
	}
	return out
}
