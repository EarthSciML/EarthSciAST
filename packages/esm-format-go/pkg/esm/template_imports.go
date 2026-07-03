package esm

// Load-time resolution for esm-spec §9.7: template-library files, cross-file
// `expression_template_imports`, and load-time `metaparameters`
// (docs/content/rfcs/template-library-imports.md; esm-libraries-spec §2.1c).
//
// Everything here resolves BEFORE the §9.6.3 rewrite fixpoint
// (lower_expression_templates.go) and before the typed struct sees the tree.
// Per document the order is innermost-first (esm-spec §9.7.6):
//
//  1. resolve imports (recursively, depth-first post-order, instantiating the
//     imported subtree with the edge's metaparameter `bindings` at each edge);
//  2. merge imported `index_sets` into the document registry;
//  3. close and fold this document's metaparameters (loader-API bindings, then
//     defaults; `metaparameter_unbound` if still open);
//  4. §9.7.3 registration-time body composition (composeTemplateBodies,
//     invoked per component from lowerExpressionTemplatesOrdered);
//  5. the §9.6.3 fixpoint on fully-concrete trees.
//
// Round-trip is Option A: `expression_template_imports`, `metaparameters`, and
// top-level `expression_templates` do not survive parse → emit; the emitted
// form is the expanded, folded document.
//
// Because a decoded map[string]interface{} loses key order — and the §9.7.4
// effective declaration order is normative for the §9.6.3 tie-break — the
// resolver tracks explicit ordered key lists (recovered from the raw JSON via
// extractTemplateOrders) and publishes each component's effective template
// sequence back into the `orders` map consumed by
// lowerExpressionTemplatesOrdered.
//
// All diagnostics are raised as *ExpressionTemplateError with the stable
// §9.6.6 codes. Mirrors the Julia reference implementation
// EarthSciSerialization.jl/src/template_imports.jl.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// MaxTemplateExpansionDepth is the maximum template-body reference-chain depth
// (counted in TEMPLATES along the longest chain, so a 33-template chain is
// rejected and a 32-template chain is accepted) before a file is rejected with
// `template_body_expansion_too_deep` (esm-spec §9.7.3). Pinned identically
// across all bindings.
const MaxTemplateExpansionDepth = 32

var templateComponentKinds = []string{"models", "reaction_systems"}

// A template-library file MUST NOT declare any of these (esm-spec §9.7.1).
var libraryForbiddenKeys = []string{
	"models", "reaction_systems", "data_loaders", "coupling", "domain",
}

// ---------------------------------------------------------------------------
// Ordered-map helper (Go maps are unordered; declaration order is normative)
// ---------------------------------------------------------------------------

type orderedMap struct {
	keys []string
	m    map[string]interface{}
}

func newOrderedMap() *orderedMap {
	return &orderedMap{m: map[string]interface{}{}}
}

// orderedMapFrom builds an orderedMap over `src`, honouring `order` first
// (keys recovered from the raw JSON) and appending any remaining keys in
// sorted-name order so the result is always deterministic.
func orderedMapFrom(src map[string]interface{}, order []string) *orderedMap {
	om := newOrderedMap()
	for _, k := range orderedKeysOf(src, order) {
		om.set(k, src[k])
	}
	return om
}

func (o *orderedMap) has(k string) bool { _, ok := o.m[k]; return ok }

func (o *orderedMap) get(k string) interface{} { return o.m[k] }

func (o *orderedMap) set(k string, v interface{}) {
	if _, ok := o.m[k]; !ok {
		o.keys = append(o.keys, k)
	}
	o.m[k] = v
}

func (o *orderedMap) delete(k string) {
	if _, ok := o.m[k]; !ok {
		return
	}
	delete(o.m, k)
	for i, key := range o.keys {
		if key == k {
			o.keys = append(o.keys[:i], o.keys[i+1:]...)
			break
		}
	}
}

func (o *orderedMap) len() int { return len(o.m) }

// orderedKeysOf returns m's keys, honouring `order` first and appending any
// keys absent from `order` in sorted-name order.
func orderedKeysOf(m map[string]interface{}, order []string) []string {
	seen := make(map[string]bool, len(m))
	keys := make([]string, 0, len(m))
	for _, k := range order {
		if _, ok := m[k]; ok && !seen[k] {
			keys = append(keys, k)
			seen[k] = true
		}
	}
	rest := make([]string, 0, len(m))
	for k := range m {
		if !seen[k] {
			rest = append(rest, k)
		}
	}
	sort.Strings(rest)
	return append(keys, rest...)
}

// ---------------------------------------------------------------------------
// Spec-version gate (esm-spec §9.6.5)
// ---------------------------------------------------------------------------

// RejectTemplateImportsPreV08 rejects the §9.7 constructs in files declaring
// esm < 0.8.0: `expression_template_imports`, top-level `expression_templates`
// (template-library files), and `metaparameters` arrive at esm 0.8.0; files
// declaring an earlier version that carry any of them are rejected with
// `template_import_version_too_old` (esm-spec §9.6.5). Mirrors
// RejectExpressionTemplatesPreV04 for the §9.7 constructs.
func RejectTemplateImportsPreV08(view map[string]interface{}) error {
	if view == nil {
		return nil
	}
	esmRaw, ok := view["esm"].(string)
	if !ok {
		return nil
	}
	m := semverRe.FindStringSubmatch(esmRaw)
	if m == nil {
		return nil
	}
	major, _ := strconv.Atoi(m[1])
	minor, _ := strconv.Atoi(m[2])
	if major != 0 || minor >= 8 {
		return nil
	}
	offences := []string{}
	if _, has := view["expression_templates"]; has {
		offences = append(offences, "/expression_templates")
	}
	if _, has := view["metaparameters"]; has {
		offences = append(offences, "/metaparameters")
	}
	if _, has := view["expression_template_imports"]; has {
		offences = append(offences, "/expression_template_imports")
	}
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]interface{})
		if !ok {
			continue
		}
		for _, cname := range sortedKeys(comps) {
			if compObj, ok := comps[cname].(map[string]interface{}); ok {
				if _, has := compObj["expression_template_imports"]; has {
					offences = append(offences,
						fmt.Sprintf("/%s/%s/expression_template_imports", kind, cname))
				}
			}
		}
	}
	if len(offences) > 0 {
		return newETErr(
			"template_import_version_too_old",
			fmt.Sprintf("expression_template_imports / top-level expression_templates / metaparameters require esm >= 0.8.0; file declares %s. Offending paths: %s",
				esmRaw, strings.Join(offences, ", ")),
		)
	}
	return nil
}

// isTemplateLibraryDoc reports whether `view` has the template-library-file
// FORM (top-level `expression_templates`, esm-spec §9.7.1). Purity (no models
// / reaction systems / loaders / coupling / domain) is checked separately at
// import edges.
func isTemplateLibraryDoc(view map[string]interface{}) bool {
	if view == nil {
		return false
	}
	_, has := view["expression_templates"]
	return has
}

// ---------------------------------------------------------------------------
// Metaparameters (esm-spec §9.7.6)
// ---------------------------------------------------------------------------

// metaparamInt coerces a JSON value to an exact int64 metaparameter value.
// json.Number tokens must have integer grammar (no '.', 'e', 'E'); native ints
// pass through; anything else (floats, bools, strings, objects) is
// `metaparameter_type_error`. A float64 is accepted only when integral —
// a plain-decoded (non-UseNumber) view cannot distinguish 4 from 4.0.
func metaparamInt(v interface{}, ctx string) (int64, error) {
	switch n := v.(type) {
	case json.Number:
		if !strings.ContainsAny(string(n), ".eE") {
			if i, err := n.Int64(); err == nil {
				return i, nil
			}
		}
	case int:
		return int64(n), nil
	case int32:
		return int64(n), nil
	case int64:
		return n, nil
	case float64:
		if n == math.Trunc(n) && n >= math.MinInt64 && n <= math.MaxInt64 {
			return int64(n), nil
		}
	}
	return 0, newETErr(
		"metaparameter_type_error",
		fmt.Sprintf("%s: value %v is not an integer (esm-spec §9.7.6)", ctx, v),
	)
}

func collectMetaparamDecls(raw map[string]interface{}, origin string, order []string) (*orderedMap, error) {
	out := newOrderedMap()
	mpRaw, has := raw["metaparameters"]
	if !has || mpRaw == nil {
		return out, nil
	}
	mp, ok := mpRaw.(map[string]interface{})
	if !ok {
		return nil, newETErr("metaparameter_type_error",
			fmt.Sprintf("%s: `metaparameters` must be an object", origin))
	}
	for _, name := range orderedKeysOf(mp, order) {
		decl, ok := mp[name].(map[string]interface{})
		if !ok {
			return nil, newETErr("metaparameter_type_error",
				fmt.Sprintf("%s: metaparameters.%s must be an object with `type: \"integer\"`", origin, name))
		}
		if t, _ := decl["type"].(string); t != "integer" {
			return nil, newETErr("metaparameter_type_error",
				fmt.Sprintf("%s: metaparameters.%s: `type` must be \"integer\" (the only kind)", origin, name))
		}
		if d, has := decl["default"]; has && d != nil {
			if _, err := metaparamInt(d, fmt.Sprintf("%s: metaparameters.%s default", origin, name)); err != nil {
				return nil, err
			}
		}
		out.set(name, deepCopyJSON(decl))
	}
	return out, nil
}

// metaSubstSkipKeys: keys whose VALUES are never expression positions —
// metaparameter names are substituted as bare variable-reference strings, so
// structural string fields must not be rewritten. Template `params` shadowing
// is handled separately in substituteMetaparamsDecl.
var metaSubstSkipKeys = map[string]struct{}{
	"metadata": {}, "params": {}, "type": {}, "units": {}, "kind": {},
	"description": {}, "name": {}, "wrt": {},
	"expression_template_imports": {}, "metaparameters": {}, "only": {},
	// `where` match-scoping constraints (esm-spec §9.6.1) carry index-set
	// NAMES, a structural namespace — never expression positions.
	"where": {},
}

// substituteMetaparams substitutes closed metaparameter names — appearing as
// bare strings, the variable-reference surface syntax — with their integer
// values, everywhere except the metaSubstSkipKeys structural fields (esm-spec
// §9.7.6: expression-position substitution; no folding here). Returns a new
// tree; the input is not modified.
func substituteMetaparams(x interface{}, values map[string]int64) interface{} {
	switch v := x.(type) {
	case string:
		if i, ok := values[v]; ok {
			return i
		}
		return v
	case []interface{}:
		out := make([]interface{}, len(v))
		for i, c := range v {
			out[i] = substituteMetaparams(c, values)
		}
		return out
	case map[string]interface{}:
		out := make(map[string]interface{}, len(v))
		for k, c := range v {
			if _, skip := metaSubstSkipKeys[k]; skip {
				out[k] = deepCopyJSON(c)
			} else {
				out[k] = substituteMetaparams(c, values)
			}
		}
		return out
	}
	return x
}

// substituteMetaparamsDecl applies metaparameter substitution over one
// `expression_templates` entry: the template's own `params` shadow like-named
// metaparameters inside its `body` and `match` (a param is the inner binder;
// substitution must not capture it).
func substituteMetaparamsDecl(decl interface{}, values map[string]int64) interface{} {
	declObj, ok := decl.(map[string]interface{})
	if !ok {
		return substituteMetaparams(decl, values)
	}
	shadowed := values
	if params, ok := declObj["params"].([]interface{}); ok {
		shadow := false
		pset := map[string]struct{}{}
		for _, p := range params {
			if ps, ok := p.(string); ok {
				pset[ps] = struct{}{}
				if _, bound := values[ps]; bound {
					shadow = true
				}
			}
		}
		if shadow {
			shadowed = make(map[string]int64, len(values))
			for k, v := range values {
				if _, isParam := pset[k]; !isParam {
					shadowed[k] = v
				}
			}
		}
	}
	return substituteMetaparams(decl, shadowed)
}

func overflowErr(ctx string) error {
	return newETErr("metaparameter_type_error",
		fmt.Sprintf("%s: 64-bit integer overflow while folding a metaparameter expression", ctx))
}

func checkedAdd(a, b int64, ctx string) (int64, error) {
	c := a + b
	if (b > 0 && c < a) || (b < 0 && c > a) {
		return 0, overflowErr(ctx)
	}
	return c, nil
}

func checkedSub(a, b int64, ctx string) (int64, error) {
	c := a - b
	if (b < 0 && c < a) || (b > 0 && c > a) {
		return 0, overflowErr(ctx)
	}
	return c, nil
}

func checkedMul(a, b int64, ctx string) (int64, error) {
	if a == 0 || b == 0 {
		return 0, nil
	}
	if a == math.MinInt64 && b == -1 || b == math.MinInt64 && a == -1 {
		return 0, overflowErr(ctx)
	}
	c := a * b
	if c/b != a {
		return 0, overflowErr(ctx)
	}
	return c, nil
}

func checkedNeg(a int64, ctx string) (int64, error) {
	if a == math.MinInt64 {
		return 0, overflowErr(ctx)
	}
	return -a, nil
}

// tryFold folds a metaparameter expression (integer literal, name, or
// {op, args} over + - * /) to a concrete int64 with exact 64-bit arithmetic
// (esm-spec §9.7.6). folded=false (with err == nil) means the expression still
// contains a bare name (an open metaparameter awaiting a later binding site,
// or a template-param slot inside a rule body) — the site is left symbolic for
// a later pass. Errors carry `metaparameter_type_error`: a non-integer
// literal, an op outside + - * / over concrete args, inexact division, or
// 64-bit overflow.
func tryFold(x interface{}, ctx string) (val int64, folded bool, err error) {
	switch v := x.(type) {
	case string:
		return 0, false, nil
	case json.Number:
		if !strings.ContainsAny(string(v), ".eE") {
			if i, e := v.Int64(); e == nil {
				return i, true, nil
			}
		}
		return 0, false, newETErr("metaparameter_type_error",
			fmt.Sprintf("%s: non-integer literal %v in a structural integer site (esm-spec §9.7.6)", ctx, v))
	case int:
		return int64(v), true, nil
	case int32:
		return int64(v), true, nil
	case int64:
		return v, true, nil
	case float64:
		return 0, false, newETErr("metaparameter_type_error",
			fmt.Sprintf("%s: non-integer literal %v in a structural integer site (esm-spec §9.7.6)", ctx, v))
	case bool:
		return 0, false, newETErr("metaparameter_type_error",
			fmt.Sprintf("%s: non-integer literal %v in a structural integer site (esm-spec §9.7.6)", ctx, v))
	case map[string]interface{}:
		opRaw, hasOp := v["op"]
		argsRaw, hasArgs := v["args"]
		args, argsOk := argsRaw.([]interface{})
		if !hasOp || !hasArgs || !argsOk || len(args) == 0 {
			return 0, false, newETErr("metaparameter_type_error",
				fmt.Sprintf("%s: invalid metaparameter expression (expected {op: +|-|*|/, args: [...]})", ctx))
		}
		vals := make([]int64, len(args))
		for i, a := range args {
			av, af, aerr := tryFold(a, ctx)
			if aerr != nil {
				return 0, false, aerr
			}
			if !af {
				return 0, false, nil
			}
			vals[i] = av
		}
		op, _ := opRaw.(string)
		if op != "+" && op != "-" && op != "*" && op != "/" {
			return 0, false, newETErr("metaparameter_type_error",
				fmt.Sprintf("%s: op '%s' is not allowed in a metaparameter expression (only + - * /)", ctx, op))
		}
		acc := vals[0]
		if op == "-" && len(vals) == 1 {
			n, e := checkedNeg(acc, ctx)
			return n, e == nil, e
		}
		for _, v2 := range vals[1:] {
			switch op {
			case "+":
				acc, err = checkedAdd(acc, v2, ctx)
			case "-":
				acc, err = checkedSub(acc, v2, ctx)
			case "*":
				acc, err = checkedMul(acc, v2, ctx)
			case "/":
				if v2 == 0 {
					return 0, false, newETErr("metaparameter_type_error",
						fmt.Sprintf("%s: division by zero", ctx))
				}
				if acc%v2 != 0 {
					return 0, false, newETErr("metaparameter_type_error",
						fmt.Sprintf("%s: %d / %d does not divide exactly (esm-spec §9.7.6)", ctx, acc, v2))
				}
				acc = acc / v2
			}
			if err != nil {
				return 0, false, err
			}
		}
		return acc, true, nil
	}
	return 0, false, newETErr("metaparameter_type_error",
		fmt.Sprintf("%s: invalid metaparameter expression (expected integer, name, or {op, args})", ctx))
}

func collectMetaNames(out *[]string, x interface{}) {
	switch v := x.(type) {
	case string:
		*out = append(*out, v)
	case []interface{}:
		for _, c := range v {
			collectMetaNames(out, c)
		}
	case map[string]interface{}:
		for _, k := range sortedKeys(v) {
			if k == "op" {
				continue
			}
			collectMetaNames(out, v[k])
		}
	}
}

func isIntToken(v interface{}) bool {
	switch n := v.(type) {
	case json.Number:
		return !strings.ContainsAny(string(n), ".eE")
	case int, int32, int64:
		return true
	}
	return false
}

// foldStructuralSites folds metaparameter expressions in the structural
// integer sites — `aggregate` dense `ranges` tuple entries and `makearray`
// `regions` bound pairs — to concrete integers, in place, wherever they are
// already closed. Entries still carrying a bare name (a template-param slot,
// or an open metaparameter in a not-yet-fully-bound library) are left symbolic
// for a later binding site. Index-set sizes are folded separately by
// foldIndexSetSizes.
func foldStructuralSites(x interface{}, ctx string) error {
	switch v := x.(type) {
	case []interface{}:
		for _, c := range v {
			if err := foldStructuralSites(c, ctx); err != nil {
				return err
			}
		}
		return nil
	case map[string]interface{}:
		op, _ := v["op"].(string)
		if op == "aggregate" {
			if ranges, ok := v["ranges"].(map[string]interface{}); ok {
				for _, k := range sortedKeys(ranges) {
					rv, ok := ranges[k].([]interface{})
					if !ok {
						continue // {from: ...} index-set refs untouched
					}
					for i, entry := range rv {
						if isIntToken(entry) {
							continue
						}
						f, folded, err := tryFold(entry, fmt.Sprintf("%s: aggregate ranges.%s", ctx, k))
						if err != nil {
							return err
						}
						if folded {
							rv[i] = f
						}
					}
				}
			}
		} else if op == "makearray" {
			if regions, ok := v["regions"].([]interface{}); ok {
				for _, regionRaw := range regions {
					region, ok := regionRaw.([]interface{})
					if !ok {
						continue
					}
					for _, boundsRaw := range region {
						bounds, ok := boundsRaw.([]interface{})
						if !ok {
							continue
						}
						for i, entry := range bounds {
							if isIntToken(entry) {
								continue
							}
							f, folded, err := tryFold(entry, ctx+": makearray regions bound")
							if err != nil {
								return err
							}
							if folded {
								bounds[i] = f
							}
						}
					}
				}
			}
		}
		for _, k := range sortedKeys(v) {
			if err := foldStructuralSites(v[k], ctx); err != nil {
				return err
			}
		}
		return nil
	}
	return nil
}

// foldIndexSetSizes folds interval `size` metaparameter expressions in an
// `index_sets` registry. With strict=true (the root document, after its
// metaparameters closed) any remaining bare name is `metaparameter_unbound`;
// with strict=false (a library instantiated at an edge that left some
// metaparameters open) open sizes stay symbolic and close at a later binding
// site.
func foldIndexSetSizes(indexSets *orderedMap, ctx string, strict bool) error {
	for _, name := range indexSets.keys {
		decl, ok := indexSets.m[name].(map[string]interface{})
		if !ok {
			continue
		}
		sz, has := decl["size"]
		if !has || sz == nil || isIntToken(sz) {
			continue
		}
		f, folded, err := tryFold(sz, fmt.Sprintf("%s: index_sets.%s.size", ctx, name))
		if err != nil {
			return err
		}
		if !folded {
			if strict {
				var names []string
				collectMetaNames(&names, sz)
				seen := map[string]bool{}
				uniq := []string{}
				for _, n := range names {
					if !seen[n] {
						uniq = append(uniq, n)
						seen[n] = true
					}
				}
				return newETErr("metaparameter_unbound",
					fmt.Sprintf("%s: index_sets.%s.size references unbound name(s) %s (esm-spec §9.7.6)",
						ctx, name, strings.Join(uniq, ", ")))
			}
			continue
		}
		decl["size"] = f
	}
	return nil
}

// ---------------------------------------------------------------------------
// Registration-time body composition (esm-spec §9.7.3)
// ---------------------------------------------------------------------------

func collectApplyNames(out *[]string, x interface{}) {
	switch v := x.(type) {
	case []interface{}:
		for _, c := range v {
			collectApplyNames(out, c)
		}
	case map[string]interface{}:
		if op, ok := v["op"].(string); ok && op == applyExpressionTemplateOp {
			if nm, ok := v["name"].(string); ok {
				*out = append(*out, nm)
			}
		}
		for _, k := range sortedKeys(v) {
			collectApplyNames(out, v[k])
		}
	}
}

func inlineApplies(node interface{}, templates map[string]interface{}, scope string) (interface{}, error) {
	switch v := node.(type) {
	case []interface{}:
		out := make([]interface{}, len(v))
		for i, c := range v {
			nc, err := inlineApplies(c, templates, scope)
			if err != nil {
				return nil, err
			}
			out[i] = nc
		}
		return out, nil
	case map[string]interface{}:
		out := make(map[string]interface{}, len(v))
		for k, c := range v {
			nc, err := inlineApplies(c, templates, scope)
			if err != nil {
				return nil, err
			}
			out[k] = nc
		}
		if op, ok := out["op"].(string); ok && op == applyExpressionTemplateOp {
			// Referenced bodies are already closed (topological order), so a
			// single expandApply produces an apply-free subtree; the bindings'
			// own sub-ASTs were inlined by the post-order walk above.
			return expandApply(out, templates, scope)
		}
		return out, nil
	}
	return node, nil
}

// composeTemplateBodies performs registration-time body composition (esm-spec
// §9.7.3): template bodies MAY reference other in-scope MATCH-LESS templates
// via `apply_expression_template` nodes. Builds the body-reference graph,
// rejects cycles (`apply_expression_template_recursive_body`) and chains
// deeper than MaxTemplateExpansionDepth templates
// (`template_body_expansion_too_deep`), then inlines dependencies-first by
// pure substitution — confluent, so topological order cannot affect the
// result. Afterwards every `body` is a closed Expression AST with zero
// `apply_expression_template` nodes; runs BEFORE the §9.6.3 fixpoint ever
// consults a `match` rule. Mutates the template declarations in place.
func composeTemplateBodies(templates map[string]interface{}, scope string) error {
	if len(templates) == 0 {
		return nil
	}
	refs := map[string][]string{}
	anyRefs := false
	for name, declRaw := range templates {
		var names []string
		if decl, ok := declRaw.(map[string]interface{}); ok {
			collectApplyNames(&names, decl["body"])
		}
		refs[name] = names
		if len(names) > 0 {
			anyRefs = true
		}
	}
	if !anyRefs {
		return nil
	}

	names := make([]string, 0, len(refs))
	for n := range refs {
		names = append(names, n)
	}
	sort.Strings(names)

	for _, name := range names {
		for _, r := range refs[name] {
			tdeclRaw, ok := templates[r]
			if !ok {
				return newETErr("apply_expression_template_unknown_template",
					fmt.Sprintf("%s.expression_templates.%s: body references undeclared template '%s' (esm-spec §9.7.3)", scope, name, r))
			}
			if tdecl, ok := tdeclRaw.(map[string]interface{}); ok {
				if m, has := tdecl["match"]; has && m != nil {
					return newETErr("apply_expression_template_unknown_template",
						fmt.Sprintf("%s.expression_templates.%s: body references '%s', a `match` rewrite rule — only match-less templates are invocable by name (esm-spec §9.7.3)", scope, name, r))
				}
			}
		}
	}

	// DFS over the reference graph: cycle detection, chain-depth bound, and a
	// dependencies-first (post-) order for inlining.
	state := map[string]int{} // 1 = on stack, 2 = done
	depth := map[string]int{} // templates on the longest chain from this node
	var order []string
	var chain []string
	var visit func(name string) (int, error)
	visit = func(name string) (int, error) {
		switch state[name] {
		case 1:
			idx := 0
			for i, c := range chain {
				if c == name {
					idx = i
					break
				}
			}
			cyc := append(append([]string{}, chain[idx:]...), name)
			return 0, newETErr("apply_expression_template_recursive_body",
				fmt.Sprintf("%s.expression_templates: template-body reference cycle %s (esm-spec §9.7.3)", scope, strings.Join(cyc, " -> ")))
		case 2:
			return depth[name], nil
		}
		state[name] = 1
		chain = append(chain, name)
		d := 1
		for _, r := range refs[name] {
			rd, err := visit(r)
			if err != nil {
				return 0, err
			}
			if 1+rd > d {
				d = 1 + rd
			}
		}
		chain = chain[:len(chain)-1]
		state[name] = 2
		depth[name] = d
		if d > MaxTemplateExpansionDepth {
			return 0, newETErr("template_body_expansion_too_deep",
				fmt.Sprintf("%s.expression_templates.%s: body-reference chain of %d templates exceeds MAX_TEMPLATE_EXPANSION_DEPTH=%d (esm-spec §9.7.3)", scope, name, d, MaxTemplateExpansionDepth))
		}
		order = append(order, name)
		return d, nil
	}
	for _, name := range names {
		if _, err := visit(name); err != nil {
			return err
		}
	}

	for _, name := range order {
		if len(refs[name]) == 0 {
			continue
		}
		decl, ok := templates[name].(map[string]interface{})
		if !ok {
			continue
		}
		body, err := inlineApplies(decl["body"], templates,
			fmt.Sprintf("%s.expression_templates.%s", scope, name))
		if err != nil {
			return err
		}
		decl["body"] = body
	}
	return nil
}

// ---------------------------------------------------------------------------
// Import-edge renaming / namespacing + free-name rebinding (esm-spec §9.7.7)
// ---------------------------------------------------------------------------

// isNameSegment reports whether seg matches [A-Za-z_][A-Za-z0-9_]* — one §4.6
// scoped-reference identifier segment.
func isNameSegment(seg string) bool {
	if seg == "" {
		return false
	}
	for i := 0; i < len(seg); i++ {
		c := seg[i]
		alpha := c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
		digit := c >= '0' && c <= '9'
		if i == 0 {
			if !alpha {
				return false
			}
		} else if !alpha && !digit {
			return false
		}
	}
	return true
}

// isValidDottedName is the grammar for a `prefix` and for `rename`/`rebind`
// TARGETS (esm-spec §9.7.7): one or more [A-Za-z_][A-Za-z0-9_]* segments joined
// by single dots — the §4.6 scoped-reference shape. Keys are never
// grammar-checked: they must match whatever the target actually exports (or
// whatever occurs free).
func isValidDottedName(s string) bool {
	if s == "" {
		return false
	}
	for _, seg := range strings.Split(s, ".") {
		if !isNameSegment(seg) {
			return false
		}
	}
	return true
}

// nameMap normalizes a `rename` / `rebind` object into a name→name map, checking
// the §9.7.7 target grammar (values are valid dotted identifiers; keys are
// non-empty but never grammar-checked). A non-object raises
// `template_import_rename_invalid`.
func nameMap(raw interface{}, field, where string) (map[string]string, error) {
	out := map[string]string{}
	if raw == nil {
		return out, nil
	}
	obj, ok := raw.(map[string]interface{})
	if !ok {
		return nil, newETErr("template_import_rename_invalid",
			fmt.Sprintf("%s: `%s` must be an object mapping names to names (esm-spec §9.7.7)", where, field))
	}
	for _, k := range sortedKeys(obj) {
		if k == "" {
			return nil, newETErr("template_import_rename_invalid",
				fmt.Sprintf("%s: `%s` has an empty key (esm-spec §9.7.7)", where, field))
		}
		vs, ok := obj[k].(string)
		if !ok || !isValidDottedName(vs) {
			return nil, newETErr("template_import_rename_invalid",
				fmt.Sprintf("%s: `%s`.%s target %#v is not a valid dotted identifier (segments [A-Za-z_][A-Za-z0-9_]* joined by single dots; esm-spec §9.7.7)", where, field, k, obj[k]))
		}
		out[k] = vs
	}
	return out, nil
}

// renameAxisKeys: scalar Expression-node fields whose string value names an
// AXIS / index set (rewritten by the index-set rename map, param-shadowed like
// §9.6.1).
var renameAxisKeys = map[string]struct{}{"wrt": {}, "dim": {}}

// renameProtectedKeys: object keys whose values are never variable-reference
// positions for the rename walk — the metaparameter skip set plus the remaining
// scalar structural ExpressionNode fields (`op`, closed-registry ids, literal
// enums). `from`, `wrt`/`dim`, apply-`name`, and `of` are handled positionally
// in the walk.
var renameProtectedKeys = func() map[string]struct{} {
	out := map[string]struct{}{}
	for k := range metaSubstSkipKeys {
		out[k] = struct{}{}
	}
	for _, k := range []string{"op", "id", "expect_cadence", "reduce", "semiring",
		"manifold", "fn", "table", "side", "attrs", "members", "from_faq"} {
		out[k] = struct{}{}
	}
	return out
}()

// isetRenamed looks up s in isetmap, returning the renamed axis or s unchanged.
func isetRenamed(s string, isetmap map[string]string) string {
	if n, ok := isetmap[s]; ok {
		return n
	}
	return s
}

// renameWalk is one transitive-substitution pass over an imported declaration
// (esm-spec §9.7.7): `varmap` (renamed open metaparameters + rebound free names)
// rewrites bare strings in variable-reference positions; `isetmap` rewrites
// index-set reference positions (`{"from": …}` values, the `wrt`/`dim` axis
// fields, and the `where.*.shape` match-scoping index-set names, in `body` and
// `match` alike); `tplmap` rewrites `apply_expression_template.name`. Structural
// scalar fields (renameProtectedKeys) and bound-index lists (range `of`) are
// never rewritten. Pure syntactic substitution — no evaluation.
//
// `where` is handled positionally (never by the protected-key copy that
// metaparameter substitution uses, esm-spec §9.7.7): a `where` block is a map
// {paramName: {shape: [indexSetName, …]}}. Rename renames templates, index sets,
// and metaparameters — NOT template-internal param names — so the constraint
// KEYS (param names) are copied verbatim while each constraint's `shape` entries
// are mapped through `isetmap` (an unmapped name stays as spelled). Without this
// the rule body/registry would use the renamed set while `where` still named the
// original, and registration would fail with template_constraint_unknown_index_set.
func renameWalk(x interface{}, varmap, isetmap, tplmap map[string]string) interface{} {
	switch v := x.(type) {
	case string:
		if n, ok := varmap[v]; ok {
			return n
		}
		return v
	case []interface{}:
		out := make([]interface{}, len(v))
		for i, c := range v {
			out[i] = renameWalk(c, varmap, isetmap, tplmap)
		}
		return out
	case map[string]interface{}:
		isApply := false
		if op, ok := v["op"].(string); ok && op == applyExpressionTemplateOp {
			isApply = true
		}
		out := make(map[string]interface{}, len(v))
		for k, val := range v {
			if k == "from" {
				if s, ok := val.(string); ok {
					out[k] = isetRenamed(s, isetmap)
					continue
				}
			}
			if _, isAxis := renameAxisKeys[k]; isAxis {
				if s, ok := val.(string); ok {
					out[k] = isetRenamed(s, isetmap)
					continue
				}
			}
			if k == "name" && isApply {
				if s, ok := val.(string); ok {
					if n, ok2 := tplmap[s]; ok2 {
						out[k] = n
					} else {
						out[k] = s
					}
					continue
				}
			}
			if k == "where" {
				if w, ok := val.(map[string]interface{}); ok {
					out[k] = renameWhere(w, isetmap)
					continue
				}
			}
			if k == "of" {
				out[k] = deepCopyJSON(val)
				continue
			}
			if _, prot := renameProtectedKeys[k]; prot {
				out[k] = deepCopyJSON(val)
				continue
			}
			out[k] = renameWalk(val, varmap, isetmap, tplmap)
		}
		return out
	}
	return x
}

// renameWhere rewrites a `where` match-scoping block (esm-spec §9.6.1) under an
// import-edge index-set rename (esm-spec §9.7.7). Constraint KEYS (param names)
// are copied verbatim — rename never touches template-internal param names — and
// each constraint's `shape` entries (index-set names) are mapped through
// `isetmap`, with any unmapped name left as spelled (the body-reference rule).
func renameWhere(whr map[string]interface{}, isetmap map[string]string) map[string]interface{} {
	out := make(map[string]interface{}, len(whr))
	for p, cobj := range whr {
		cmap, ok := cobj.(map[string]interface{})
		if !ok {
			out[p] = deepCopyJSON(cobj)
			continue
		}
		cout := make(map[string]interface{}, len(cmap))
		for ck, cv := range cmap {
			if ck == "shape" {
				if arr, ok := cv.([]interface{}); ok {
					shape := make([]interface{}, len(arr))
					for i, e := range arr {
						if s, ok := e.(string); ok {
							shape[i] = isetRenamed(s, isetmap)
						} else {
							shape[i] = deepCopyJSON(e)
						}
					}
					cout[ck] = shape
					continue
				}
			}
			cout[ck] = deepCopyJSON(cv)
		}
		out[p] = cout
	}
	return out
}

// renameDecl is renameWalk over one template declaration with the §9.6.1
// shadowing rule: the template's own `params` shadow like-named entries of
// `varmap` and `isetmap` inside its `body`/`match` (a param is the inner binder;
// renaming must not capture it). `tplmap` is never shadowed — params do not bind
// template names.
func renameDecl(decl interface{}, varmap, isetmap, tplmap map[string]string) interface{} {
	declObj, ok := decl.(map[string]interface{})
	if !ok {
		return renameWalk(decl, varmap, isetmap, tplmap)
	}
	v2, i2 := varmap, isetmap
	if params, ok := declObj["params"].([]interface{}); ok && len(params) > 0 {
		pset := map[string]struct{}{}
		for _, p := range params {
			if ps, ok := p.(string); ok {
				pset[ps] = struct{}{}
			}
		}
		shadowV := false
		for p := range pset {
			if _, ok := varmap[p]; ok {
				shadowV = true
				break
			}
		}
		if shadowV {
			v2 = map[string]string{}
			for k, val := range varmap {
				if _, isP := pset[k]; !isP {
					v2[k] = val
				}
			}
		}
		shadowI := false
		for p := range pset {
			if _, ok := isetmap[p]; ok {
				shadowI = true
				break
			}
		}
		if shadowI {
			i2 = map[string]string{}
			for k, val := range isetmap {
				if _, isP := pset[k]; !isP {
					i2[k] = val
				}
			}
		}
	}
	return renameWalk(decl, v2, i2, tplmap)
}

// collectBoundSyms accumulates the bound index symbols of a declaration:
// aggregate `output_idx` entries and `ranges` keys (at any nesting depth).
// Rebinding one would desynchronize the ranges KEYS (object keys, unreachable by
// value substitution) from their `expr` occurrences, so it is rejected outright.
func collectBoundSyms(out map[string]struct{}, x interface{}) {
	switch v := x.(type) {
	case []interface{}:
		for _, c := range v {
			collectBoundSyms(out, c)
		}
	case map[string]interface{}:
		if op, _ := v["op"].(string); op == "aggregate" {
			if oi, ok := v["output_idx"].([]interface{}); ok {
				for _, e := range oi {
					if es, ok := e.(string); ok {
						out[es] = struct{}{}
					}
				}
			}
			if rg, ok := v["ranges"].(map[string]interface{}); ok {
				for k := range rg {
					out[k] = struct{}{}
				}
			}
		}
		for _, c := range v {
			collectBoundSyms(out, c)
		}
	}
}

// collectRefNames accumulates every bare string in a variable-reference position
// of a declaration (the positions `varmap` would rewrite), minus the
// per-template `params` shadow set. Used for the rebind occurs-check and the
// freshness (collision) guard.
func collectRefNames(out map[string]struct{}, x interface{}, shadowed map[string]struct{}) {
	switch v := x.(type) {
	case string:
		if _, sh := shadowed[v]; !sh {
			out[v] = struct{}{}
		}
	case []interface{}:
		for _, c := range v {
			collectRefNames(out, c, shadowed)
		}
	case map[string]interface{}:
		for k, c := range v {
			if k == "from" || k == "of" {
				continue
			}
			if _, isAxis := renameAxisKeys[k]; isAxis {
				continue
			}
			if _, prot := renameProtectedKeys[k]; prot {
				continue
			}
			collectRefNames(out, c, shadowed)
		}
	}
}

// applyEdgeRenames applies one import edge's `prefix` / `rename` / `rebind`
// (esm-spec §9.7.7) to the target's SURVIVING export scope — templates after
// `only`, all index sets, and metaparameters still open after this edge's
// `bindings` — transitively through every occurrence inside the surviving
// declarations (index-set references in `from`/`wrt`/`dim` and registry `of`
// lists, open-metaparameter names in expression positions, keyed-factor and
// other free names in variable-reference positions and registry
// `offsets`/`values`, `apply_expression_template.name` references). Runs after
// `bindings` instantiation and `only` filtering, before the §9.7.4/§9.7.5 merge,
// so dedup and conflict detection operate on post-rename names. Mutates scope in
// place and returns it. Mirrors the Julia reference `_apply_edge_renames!`.
func applyEdgeRenames(scope *templateScope, entry map[string]interface{}, origin, ref string) (*templateScope, error) {
	where := fmt.Sprintf("%s: import of '%s'", origin, ref)
	rename, err := nameMap(entry["rename"], "rename", where)
	if err != nil {
		return nil, err
	}
	rebind, err := nameMap(entry["rebind"], "rebind", where)
	if err != nil {
		return nil, err
	}
	prefix := ""
	hasPfx := false
	if prefixRaw, has := entry["prefix"]; has && prefixRaw != nil {
		ps, ok := prefixRaw.(string)
		if !ok || !isValidDottedName(ps) {
			return nil, newETErr("template_import_rename_invalid",
				fmt.Sprintf("%s: `prefix` %#v is not a valid dotted identifier (segments [A-Za-z_][A-Za-z0-9_]* joined by single dots; esm-spec §9.7.7)", where, prefixRaw))
		}
		prefix = ps
		hasPfx = true
	}
	if !hasPfx && len(rename) == 0 && len(rebind) == 0 {
		return scope, nil
	}

	// --- `rename` keys must name a surviving exported name (typo protection) ---
	exported := map[string]struct{}{}
	for _, n := range scope.templates.keys {
		exported[n] = struct{}{}
	}
	for _, n := range scope.indexSets.keys {
		exported[n] = struct{}{}
	}
	for _, n := range scope.metaparams.keys {
		exported[n] = struct{}{}
	}
	for _, k := range sortedKeys(rename) {
		if _, ok := exported[k]; !ok {
			return nil, newETErr("template_import_rename_unknown_name",
				fmt.Sprintf("%s: `rename` names '%s', which the target does not export at this edge (the surviving exports are templates after `only`, index sets, and metaparameters left open by this edge's `bindings`; esm-spec §9.7.7)", where, k))
		}
	}

	final := func(n string) string {
		if r, ok := rename[n]; ok {
			return r
		}
		if hasPfx {
			return prefix + "." + n
		}
		return n
	}
	tplmap := map[string]string{}
	for _, n := range scope.templates.keys {
		tplmap[n] = final(n)
	}
	isetmap := map[string]string{}
	for _, n := range scope.indexSets.keys {
		isetmap[n] = final(n)
	}
	metamap := map[string]string{}
	for _, n := range scope.metaparams.keys {
		metamap[n] = final(n)
	}

	// --- per-namespace final-name uniqueness ---
	for _, ns := range []struct {
		what string
		keys []string
		m    map[string]string
	}{
		{"template", scope.templates.keys, tplmap},
		{"index set", scope.indexSets.keys, isetmap},
		{"metaparameter", scope.metaparams.keys, metamap},
	} {
		seen := map[string]string{}
		for _, o := range ns.keys {
			n := ns.m[o]
			if prev, ok := seen[n]; ok {
				return nil, newETErr("template_import_rename_collision",
					fmt.Sprintf("%s: %s names '%s' and '%s' both map to '%s' after renaming (esm-spec §9.7.7)", where, ns.what, prev, o, n))
			}
			seen[n] = o
		}
	}

	// --- free / bound name inventory over the surviving declarations ---
	free := map[string]struct{}{}
	bound := map[string]struct{}{}
	paramsAll := map[string]struct{}{}
	for _, n := range scope.templates.keys {
		d := scope.templates.get(n)
		collectBoundSyms(bound, d)
		shadowed := map[string]struct{}{}
		if declObj, ok := d.(map[string]interface{}); ok {
			if params, ok := declObj["params"].([]interface{}); ok {
				for _, p := range params {
					if ps, ok := p.(string); ok {
						shadowed[ps] = struct{}{}
					}
				}
			}
		}
		for k := range shadowed {
			paramsAll[k] = struct{}{}
		}
		collectRefNames(free, d, shadowed)
	}
	for _, n := range scope.indexSets.keys {
		if d, ok := scope.indexSets.get(n).(map[string]interface{}); ok {
			for _, f := range []string{"offsets", "values"} {
				if s, ok := d[f].(string); ok {
					free[s] = struct{}{}
				}
			}
		}
	}
	for _, n := range scope.metaparams.keys { // declared names are not free
		delete(free, n)
	}

	// --- `rebind` keys must denote free names (typo protection) ---
	for _, k := range sortedKeys(rebind) {
		if _, ok := exported[k]; ok {
			return nil, newETErr("template_import_rebind_unknown_name",
				fmt.Sprintf("%s: `rebind` names '%s', a declared name of the target (template / index set / metaparameter) — `rebind` addresses only free names; use `rename` for declared names (esm-spec §9.7.7)", where, k))
		}
		if _, ok := bound[k]; ok {
			return nil, newETErr("template_import_rename_invalid",
				fmt.Sprintf("%s: `rebind` key '%s' is a bound index symbol (`output_idx` / `ranges`) of an imported template, not a free name (esm-spec §9.7.7)", where, k))
		}
		if _, ok := free[k]; !ok {
			return nil, newETErr("template_import_rebind_unknown_name",
				fmt.Sprintf("%s: `rebind` names '%s', which does not occur free in the imported declarations (esm-spec §9.7.7)", where, k))
		}
	}

	// --- freshness guard: new bare names must not capture / merge ---
	taken := map[string]struct{}{}
	for k := range free {
		if _, isReb := rebind[k]; !isReb {
			taken[k] = struct{}{}
		}
	}
	for k := range bound {
		taken[k] = struct{}{}
	}
	for k := range paramsAll {
		taken[k] = struct{}{}
	}
	var newnames []string
	for _, o := range scope.metaparams.keys {
		if n := metamap[o]; o != n {
			newnames = append(newnames, n)
		}
	}
	for _, o := range sortedKeys(rebind) {
		if n := rebind[o]; o != n {
			newnames = append(newnames, n)
		}
	}
	for _, tk := range newnames {
		if _, ok := taken[tk]; ok {
			return nil, newETErr("template_import_rename_collision",
				fmt.Sprintf("%s: renamed/rebound name '%s' collides with a name still in use inside the imported declarations (a remaining free name, a bound index symbol, a template param, or another rename/rebind target; esm-spec §9.7.7)", where, tk))
		}
		taken[tk] = struct{}{}
	}

	// --- apply (identity entries dropped; one simultaneous substitution) ---
	varmap := map[string]string{}
	for _, o := range scope.metaparams.keys {
		if n := metamap[o]; o != n {
			varmap[o] = n
		}
	}
	for o, n := range rebind {
		if o != n {
			varmap[o] = n
		}
	}
	isetChanged := map[string]string{}
	for o, n := range isetmap {
		if o != n {
			isetChanged[o] = n
		}
	}
	tplChanged := map[string]string{}
	for o, n := range tplmap {
		if o != n {
			tplChanged[o] = n
		}
	}

	newT := newOrderedMap()
	for _, n := range scope.templates.keys {
		newT.set(tplmap[n], renameDecl(scope.templates.get(n), varmap, isetChanged, tplChanged))
	}
	scope.templates = newT

	newI := newOrderedMap()
	for _, n := range scope.indexSets.keys {
		nd := renameWalk(scope.indexSets.get(n), varmap, isetChanged, tplChanged)
		if ndObj, ok := nd.(map[string]interface{}); ok {
			if of, ok := ndObj["of"].([]interface{}); ok {
				newOf := make([]interface{}, len(of))
				for i, e := range of {
					if es, ok := e.(string); ok {
						newOf[i] = isetRenamed(es, isetChanged)
					} else {
						newOf[i] = e
					}
				}
				ndObj["of"] = newOf
			}
		}
		newI.set(isetmap[n], nd)
	}
	scope.indexSets = newI

	newM := newOrderedMap()
	for _, n := range scope.metaparams.keys {
		newM.set(metamap[n], scope.metaparams.get(n))
	}
	scope.metaparams = newM
	return scope, nil
}

// ---------------------------------------------------------------------------
// Import-graph resolution (esm-spec §9.7.2 / §9.7.4 / §9.7.5)
// ---------------------------------------------------------------------------

// templateScope is everything one template-library file exports after
// resolution in its OWN scope: its effective template sequence (imports
// depth-first post-order, then own declarations; esm-spec §9.7.4), its
// instantiated `index_sets`, and its still-open metaparameter declarations
// (re-exported to the importer, esm-spec §9.7.6 binding site 2). All three
// maps preserve insertion order — the effective declaration order is
// normative for the §9.6.3 tie-break.
type templateScope struct {
	templates  *orderedMap
	indexSets  *orderedMap
	metaparams *orderedMap
}

func newTemplateScope() *templateScope {
	return &templateScope{
		templates:  newOrderedMap(),
		indexSets:  newOrderedMap(),
		metaparams: newOrderedMap(),
	}
}

func mergeNamed(dst *orderedMap, name string, decl interface{}, code, what, origin string) error {
	if dst.has(name) {
		// Deep-equal redeclaration (a diamond import) dedups at first
		// occurrence; a non-equal collision is a conflict (§9.7.4/§9.7.5).
		if jsonEqual(dst.get(name), decl) {
			return nil
		}
		return newETErr(code,
			fmt.Sprintf("%s: %s '%s' collides with a non-deep-equal existing definition (esm-spec §9.7.4/§9.7.5)", origin, what, name))
	}
	dst.set(name, decl)
	return nil
}

func mergeScope(dst, src *templateScope, origin string) error {
	for _, n := range src.templates.keys {
		if err := mergeNamed(dst.templates, n, src.templates.get(n),
			"template_import_name_conflict", "template", origin); err != nil {
			return err
		}
	}
	for _, n := range src.indexSets.keys {
		if err := mergeNamed(dst.indexSets, n, src.indexSets.get(n),
			"template_import_index_set_conflict", "index set", origin); err != nil {
			return err
		}
	}
	for _, n := range src.metaparams.keys {
		if err := mergeNamed(dst.metaparams, n, src.metaparams.get(n),
			"template_import_name_conflict", "metaparameter", origin); err != nil {
			return err
		}
	}
	return nil
}

// instantiateScope performs per-edge metaparameter instantiation (esm-spec
// §9.7.6 binding site 1): substitute the bound names as integer literals
// throughout the exported templates and index sets, then fold the structural
// sites that are now closed.
func instantiateScope(scope *templateScope, values map[string]int64, ctx string) error {
	newT := newOrderedMap()
	for _, n := range scope.templates.keys {
		nd := substituteMetaparamsDecl(scope.templates.get(n), values)
		if err := foldStructuralSites(nd, ctx); err != nil {
			return err
		}
		newT.set(n, nd)
	}
	scope.templates = newT
	newIS := newOrderedMap()
	for _, n := range scope.indexSets.keys {
		newIS.set(n, substituteMetaparams(scope.indexSets.get(n), values))
	}
	if err := foldIndexSetSizes(newIS, ctx, false); err != nil {
		return err
	}
	scope.indexSets = newIS
	return nil
}

func canonicalImportRef(ref, baseDir string) string {
	if strings.HasPrefix(ref, "http://") || strings.HasPrefix(ref, "https://") {
		return ref
	}
	p := ref
	if !filepath.IsAbs(p) {
		p = filepath.Join(baseDir, p)
	}
	abs, err := filepath.Abs(p)
	if err != nil {
		return p
	}
	return abs
}

// loadImportBytes loads a template-library `ref` (URL or path relative to
// baseDir), returning the raw bytes and the directory anchoring the target's
// own relative refs. Failures are `template_import_unresolved`.
func loadImportBytes(ref, baseDir, origin string) ([]byte, string, error) {
	if strings.HasPrefix(ref, "http://") || strings.HasPrefix(ref, "https://") {
		data, err := fetchRemoteRef(ref)
		if err != nil {
			return nil, "", newETErr("template_import_unresolved",
				fmt.Sprintf("%s: failed to download template-library ref '%s': %v", origin, ref, err))
		}
		// Relative refs inside a remote library have no resolvable base; they
		// fail as unresolved when encountered.
		return data, baseDir, nil
	}
	path := canonicalImportRef(ref, baseDir)
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return nil, "", newETErr("template_import_unresolved",
			fmt.Sprintf("%s: template-library file not found: %s (from ref '%s')", origin, path, ref))
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, "", newETErr("template_import_unresolved",
			fmt.Sprintf("%s: failed to read template-library ref '%s': %v", origin, path, err))
	}
	return data, filepath.Dir(path), nil
}

func decodeJSONView(data []byte) (map[string]interface{}, error) {
	var view map[string]interface{}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := dec.Decode(&view); err != nil {
		return nil, err
	}
	return view, nil
}

// resolveImportEntry resolves ONE `expression_template_imports` entry
// (esm-spec §9.7.2): load the target (path-scoped cycle detection over
// canonical refs, as §4.7), verify library purity, resolve the target
// recursively in its own scope, instantiate at this edge's `bindings`, apply
// `only` visibility filtering, then apply the edge's `prefix`/`rename`/`rebind`
// (esm-spec §9.7.7).
func resolveImportEntry(entry interface{}, baseDir string, stack *[]string, origin string) (*templateScope, error) {
	entryObj, ok := entry.(map[string]interface{})
	if !ok {
		return nil, newETErr("template_import_unresolved",
			fmt.Sprintf("%s: expression_template_imports entries must be objects with a `ref` field", origin))
	}
	ref, ok := entryObj["ref"].(string)
	if !ok || ref == "" {
		return nil, newETErr("template_import_unresolved",
			fmt.Sprintf("%s: expression_template_imports entry requires a non-empty string `ref`", origin))
	}
	canonical := canonicalImportRef(ref, baseDir)
	for i, s := range *stack {
		if s == canonical {
			cyc := append(append([]string{}, (*stack)[i:]...), canonical)
			return nil, newETErr("template_import_cycle",
				fmt.Sprintf("%s: import-graph cycle detected: %s (esm-spec §9.7.2)", origin, strings.Join(cyc, " -> ")))
		}
	}

	data, targetDir, err := loadImportBytes(ref, baseDir, origin)
	if err != nil {
		return nil, err
	}
	view, err := decodeJSONView(data)
	if err != nil {
		return nil, newETErr("template_import_unresolved",
			fmt.Sprintf("%s: template-library ref '%s' is not valid JSON: %v", origin, ref, err))
	}
	if err := RejectExpressionTemplatesPreV04(view); err != nil {
		return nil, err
	}
	if err := RejectTemplateImportsPreV08(view); err != nil {
		return nil, err
	}

	// Library purity (esm-spec §9.7.1): the two reference mechanisms are
	// disjoint — a component/subsystem file is not importable as a library.
	if !isTemplateLibraryDoc(view) {
		return nil, newETErr("template_import_not_library",
			fmt.Sprintf("%s: import target '%s' lacks top-level `expression_templates` — not a template-library file (esm-spec §9.7.1)", origin, ref))
	}
	for _, k := range libraryForbiddenKeys {
		if _, has := view[k]; has {
			return nil, newETErr("template_import_not_library",
				fmt.Sprintf("%s: import target '%s' declares `%s` — not a pure template-library file (esm-spec §9.7.1)", origin, ref, k))
		}
	}
	schemaRes, err := validateJSONSchema(string(data))
	if err != nil {
		return nil, newETErr("template_import_unresolved",
			fmt.Sprintf("%s: import target '%s' failed schema validation: %v", origin, ref, err))
	}
	if !schemaRes.IsValid {
		msg := "schema invalid"
		if len(schemaRes.SchemaErrors) > 0 {
			msg = schemaRes.SchemaErrors[0].Message
		}
		return nil, newETErr("template_import_unresolved",
			fmt.Sprintf("%s: import target '%s' failed schema validation: %s", origin, ref, msg))
	}

	*stack = append(*stack, canonical)
	scope, err := processLibrary(view, extractTemplateOrders(string(data)),
		targetDir, stack, origin+" -> "+ref)
	*stack = (*stack)[:len(*stack)-1]
	if err != nil {
		return nil, err
	}

	// Edge metaparameter bindings (esm-spec §9.7.6 binding site 1).
	values := map[string]int64{}
	if bindingsRaw, ok := entryObj["bindings"].(map[string]interface{}); ok {
		for _, name := range sortedKeys(bindingsRaw) {
			if !scope.metaparams.has(name) {
				return nil, newETErr("template_import_unknown_name",
					fmt.Sprintf("%s: import of '%s' binds metaparameter '%s', which the target neither declares nor re-exports (esm-spec §9.7.6)", origin, ref, name))
			}
			v, err := metaparamInt(bindingsRaw[name],
				fmt.Sprintf("%s: import of '%s', binding '%s'", origin, ref, name))
			if err != nil {
				return nil, err
			}
			values[name] = v
		}
	}
	if len(values) > 0 {
		if err := instantiateScope(scope, values, origin+" -> "+ref); err != nil {
			return nil, err
		}
		for name := range values {
			scope.metaparams.delete(name)
		}
	}

	// `only` visibility filtering (esm-spec §9.7.2) — after the target's own
	// internal wiring resolved in its own scope.
	if onlyRaw, ok := entryObj["only"].([]interface{}); ok {
		keep := map[string]bool{}
		for _, nRaw := range onlyRaw {
			n := fmt.Sprintf("%v", nRaw)
			if !scope.templates.has(n) {
				return nil, newETErr("template_import_unknown_name",
					fmt.Sprintf("%s: `only` names template '%s', which '%s' does not declare (esm-spec §9.7.2)", origin, n, ref))
			}
			keep[n] = true
		}
		filtered := newOrderedMap()
		for _, n := range scope.templates.keys {
			if keep[n] {
				filtered.set(n, scope.templates.get(n))
			}
		}
		scope.templates = filtered
	}

	// Import-edge renaming / namespacing + free-name rebinding (esm-spec
	// §9.7.7) — after `bindings` instantiation and `only` filtering, before
	// the §9.7.4/§9.7.5 merge, so dedup/conflict checks see post-rename names.
	return applyEdgeRenames(scope, entryObj, origin, ref)
}

// processLibrary resolves a template-library document in its OWN scope: its
// imports (depth-first post-order), then its own templates / index sets /
// metaparameters appended in declaration order (esm-spec §9.7.4), then §9.7.3
// body composition — so a BC-layer body reference to an imported interior
// stencil closes here, before any `only` filtering by a downstream importer.
func processLibrary(view map[string]interface{}, fileOrders map[string][]string,
	dir string, stack *[]string, origin string) (*templateScope, error) {
	scope := newTemplateScope()
	if imports, ok := view["expression_template_imports"].([]interface{}); ok {
		for _, entry := range imports {
			sub, err := resolveImportEntry(entry, dir, stack, origin)
			if err != nil {
				return nil, err
			}
			if err := mergeScope(scope, sub, origin); err != nil {
				return nil, err
			}
		}
	}

	if tpl, ok := view["expression_templates"].(map[string]interface{}); ok {
		if err := validateTemplates(tpl, origin); err != nil {
			return nil, err
		}
		for _, n := range orderedKeysOf(tpl, fileOrders["/expression_templates"]) {
			if err := mergeNamed(scope.templates, n, tpl[n],
				"template_import_name_conflict", "template", origin); err != nil {
				return nil, err
			}
		}
	}

	if isets, ok := view["index_sets"].(map[string]interface{}); ok {
		for _, n := range orderedKeysOf(isets, fileOrders["/index_sets"]) {
			if err := mergeNamed(scope.indexSets, n, isets[n],
				"template_import_index_set_conflict", "index set", origin); err != nil {
				return nil, err
			}
		}
	}

	mps, err := collectMetaparamDecls(view, origin, fileOrders["/metaparameters"])
	if err != nil {
		return nil, err
	}
	for _, n := range mps.keys {
		if err := mergeNamed(scope.metaparams, n, mps.get(n),
			"template_import_name_conflict", "metaparameter", origin); err != nil {
			return nil, err
		}
	}

	// §9.7.3 body composition in the library's own scope (decl objects are
	// mutated in place, so scope.templates sees the closed bodies).
	if err := composeTemplateBodies(scope.templates.m, origin); err != nil {
		return nil, err
	}
	return scope, nil
}

// ---------------------------------------------------------------------------
// Root-document resolution (the load-time entry point)
// ---------------------------------------------------------------------------

func hasImportMachinery(view map[string]interface{}) bool {
	if view == nil {
		return false
	}
	if _, has := view["expression_templates"]; has {
		return true
	}
	if _, has := view["metaparameters"]; has {
		return true
	}
	if _, has := view["expression_template_imports"]; has {
		return true
	}
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]interface{})
		if !ok {
			continue
		}
		for _, compRaw := range comps {
			if compObj, ok := compRaw.(map[string]interface{}); ok {
				if _, has := compObj["expression_template_imports"]; has {
					return true
				}
			}
		}
	}
	return false
}

// resolveTemplateMachinery resolves every esm-spec §9.7 construct of the ROOT
// document `view`, IN PLACE (relative import refs resolve against `baseDir`):
// imports recursively with per-edge instantiation, `index_sets` merge,
// metaparameter close (`metaparameters` is the loader-API binding site 4;
// already-closed edge bindings win, then API bindings, then defaults) and
// fold, expression-position substitution, and — for a root library file —
// §9.7.3 body composition.
//
// `orders` is the path → key-order map recovered from the raw JSON
// (extractTemplateOrders); the resolver reads the root's declaration orders
// from it and WRITES each component's effective template sequence back into
// it, so the subsequent lowerExpressionTemplatesOrdered pass breaks
// declaration-order ties by the §9.7.4 effective sequence. After resolution
// no `expression_template_imports`, `metaparameters`, or top-level
// `expression_templates` key remains (Option A round-trip). Returns false
// when the document carries no §9.7 machinery (the legacy fast path).
func resolveTemplateMachinery(view map[string]interface{}, orders map[string][]string,
	baseDir string, metaparameters map[string]int64) (bool, error) {
	if !hasImportMachinery(view) {
		if len(metaparameters) > 0 {
			names := make([]string, 0, len(metaparameters))
			for k := range metaparameters {
				names = append(names, k)
			}
			sort.Strings(names)
			return false, newETErr("template_import_unknown_name",
				fmt.Sprintf("loader API binds metaparameter(s) %s but the document declares none (esm-spec §9.7.6)", strings.Join(names, ", ")))
		}
		return false, nil
	}
	if orders == nil {
		orders = map[string][]string{}
	}
	stack := []string{}

	docMeta, err := collectMetaparamDecls(view, "document", orders["/metaparameters"])
	if err != nil {
		return false, err
	}
	docIsets := newOrderedMap()
	if isets, ok := view["index_sets"].(map[string]interface{}); ok {
		for _, n := range orderedKeysOf(isets, orders["/index_sets"]) {
			docIsets.set(n, isets[n])
		}
	}

	// --- top-level templates + imports (root template-library file) ---
	_, isLibrary := view["expression_templates"]
	topTemplates := newOrderedMap()
	if isLibrary {
		topscope := newTemplateScope()
		if imports, ok := view["expression_template_imports"].([]interface{}); ok {
			for _, entry := range imports {
				sub, err := resolveImportEntry(entry, baseDir, &stack, "document")
				if err != nil {
					return false, err
				}
				if err := mergeScope(topscope, sub, "document"); err != nil {
					return false, err
				}
			}
		}
		if tpl, ok := view["expression_templates"].(map[string]interface{}); ok {
			if err := validateTemplates(tpl, "document"); err != nil {
				return false, err
			}
			for _, n := range orderedKeysOf(tpl, orders["/expression_templates"]) {
				if err := mergeNamed(topscope.templates, n, tpl[n],
					"template_import_name_conflict", "template", "document"); err != nil {
					return false, err
				}
			}
		}
		for _, n := range topscope.indexSets.keys {
			if err := mergeNamed(docIsets, n, topscope.indexSets.get(n),
				"template_import_index_set_conflict", "index set", "document"); err != nil {
				return false, err
			}
		}
		for _, n := range topscope.metaparams.keys {
			if err := mergeNamed(docMeta, n, topscope.metaparams.get(n),
				"template_import_name_conflict", "metaparameter", "document"); err != nil {
				return false, err
			}
		}
		topTemplates = topscope.templates
	}

	// --- per-component imports (models / reaction systems, §9.7.2) ---
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]interface{})
		if !ok {
			continue
		}
		for _, cname := range orderedKeysOf(comps, orders["/"+kind]) {
			comp, ok := comps[cname].(map[string]interface{})
			if !ok {
				continue
			}
			importsRaw, present := comp["expression_template_imports"]
			if !present || importsRaw == nil {
				continue
			}
			cscope := newTemplateScope()
			corigin := kind + "." + cname
			if imports, ok := importsRaw.([]interface{}); ok {
				for _, entry := range imports {
					sub, err := resolveImportEntry(entry, baseDir, &stack, corigin)
					if err != nil {
						return false, err
					}
					if err := mergeScope(cscope, sub, corigin); err != nil {
						return false, err
					}
				}
			}
			tplPath := "/" + kind + "/" + cname + "/expression_templates"
			if tpl, ok := comp["expression_templates"].(map[string]interface{}); ok {
				if err := validateTemplates(tpl, corigin); err != nil {
					return false, err
				}
				for _, n := range orderedKeysOf(tpl, orders[tplPath]) {
					if err := mergeNamed(cscope.templates, n, tpl[n],
						"template_import_name_conflict", "template", corigin); err != nil {
						return false, err
					}
				}
			}
			for _, n := range cscope.indexSets.keys {
				if err := mergeNamed(docIsets, n, cscope.indexSets.get(n),
					"template_import_index_set_conflict", "index set", corigin); err != nil {
					return false, err
				}
			}
			for _, n := range cscope.metaparams.keys {
				if err := mergeNamed(docMeta, n, cscope.metaparams.get(n),
					"template_import_name_conflict", "metaparameter", corigin); err != nil {
					return false, err
				}
			}
			// The effective sequence (imports depth-first post-order, then
			// local declarations) becomes the component's template block; the
			// published key order IS the §9.6.3 declaration order.
			comp["expression_templates"] = cscope.templates.m
			orders[tplPath] = cscope.templates.keys
			delete(comp, "expression_template_imports")
		}
	}

	// --- close this document's metaparameters (§9.7.6 sites 4-5) ---
	apiNames := make([]string, 0, len(metaparameters))
	for k := range metaparameters {
		apiNames = append(apiNames, k)
	}
	sort.Strings(apiNames)
	for _, k := range apiNames {
		if !docMeta.has(k) {
			return false, newETErr("template_import_unknown_name",
				fmt.Sprintf("loader API binds metaparameter '%s', which the document does not declare (esm-spec §9.7.6)", k))
		}
	}
	values := map[string]int64{}
	var openNames []string
	for _, name := range docMeta.keys {
		if v, ok := metaparameters[name]; ok {
			values[name] = v
			continue
		}
		decl, _ := docMeta.get(name).(map[string]interface{})
		d, has := decl["default"]
		if !has || d == nil {
			openNames = append(openNames, name)
			continue
		}
		dv, err := metaparamInt(d, fmt.Sprintf("metaparameters.%s default", name))
		if err != nil {
			return false, err
		}
		values[name] = dv
	}
	if len(openNames) > 0 {
		return false, newETErr("metaparameter_unbound",
			fmt.Sprintf("metaparameter(s) %s still open after edge bindings, loader-API bindings, and defaults (esm-spec §9.7.6)", strings.Join(openNames, ", ")))
	}

	// --- §9.7.6 name-collision check: no shadowing of visible names ---
	if docMeta.len() > 0 {
		visible := map[string]bool{}
		for _, n := range docIsets.keys {
			visible[n] = true
		}
		for _, kind := range templateComponentKinds {
			comps, ok := view[kind].(map[string]interface{})
			if !ok {
				continue
			}
			for _, compRaw := range comps {
				compObj, ok := compRaw.(map[string]interface{})
				if !ok {
					continue
				}
				for _, blk := range []string{"variables", "species", "parameters"} {
					if b, ok := compObj[blk].(map[string]interface{}); ok {
						for vn := range b {
							visible[vn] = true
						}
					}
				}
			}
		}
		for _, name := range docMeta.keys {
			if visible[name] {
				return false, newETErr("metaparameter_name_conflict",
					fmt.Sprintf("metaparameter '%s' collides with a visible variable/parameter/species/index-set name (esm-spec §9.7.6)", name))
			}
		}
	}

	// --- expression-position substitution of the closed values ---
	if len(values) > 0 {
		for _, kind := range templateComponentKinds {
			comps, ok := view[kind].(map[string]interface{})
			if !ok {
				continue
			}
			for cname, compRaw := range comps {
				comp, ok := compRaw.(map[string]interface{})
				if !ok {
					continue
				}
				for _, k := range sortedKeys(comp) {
					if k == "expression_templates" {
						if tpl, ok := comp[k].(map[string]interface{}); ok {
							for tn, td := range tpl {
								tpl[tn] = substituteMetaparamsDecl(td, values)
							}
							continue
						}
					}
					comp[k] = substituteMetaparams(comp[k], values)
				}
				comps[cname] = comp
			}
		}
		for _, tn := range topTemplates.keys {
			topTemplates.m[tn] = substituteMetaparamsDecl(topTemplates.get(tn), values)
		}
		for _, n := range docIsets.keys {
			docIsets.m[n] = substituteMetaparams(docIsets.get(n), values)
		}
	}

	// --- fold structural sites on the closed document ---
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]interface{})
		if !ok {
			continue
		}
		for _, cname := range sortedKeys(comps) {
			if comp, ok := comps[cname].(map[string]interface{}); ok {
				if err := foldStructuralSites(comp, kind+"."+cname); err != nil {
					return false, err
				}
			}
		}
	}
	for _, tn := range topTemplates.keys {
		if err := foldStructuralSites(topTemplates.get(tn), "document.expression_templates."+tn); err != nil {
			return false, err
		}
	}
	if err := foldIndexSetSizes(docIsets, "document", true); err != nil {
		return false, err
	}

	// --- root library file: compose bodies (validation), then strip; no §9.7
	//     construct survives parse → emit (esm-spec §9.7.6 round-trip) ---
	if isLibrary {
		if err := composeTemplateBodies(topTemplates.m, "document"); err != nil {
			return false, err
		}
		delete(view, "expression_templates")
	}
	delete(view, "expression_template_imports")
	delete(view, "metaparameters")
	if docIsets.len() > 0 {
		view["index_sets"] = docIsets.m
	}
	return true, nil
}

// ===================================================================
// Scope-directed template injection (esm-spec §9.7.10)
//
// The consuming surface — a §4.7 subsystem-ref edge (form A), a §10 coupling
// entry (form B), or a §6.6/§6.7 test/example (form C) — may register imports
// into a TARGET component's own scope without editing the leaf. Forms A/B are
// applied at the raw-view level BEFORE resolveTemplateMachinery: each widens
// the target component's `expression_template_imports` in the §9.7.10 merge
// order (the target's own imports first, then the injected list), so the
// ordinary import resolver + §9.6.3 fixpoint lower the target's rewrite-targets
// with no engine change. Form A is threaded through subsystem-ref resolution
// (subsystem_ref.go); form B runs on the root view inside resolveAndLowerJSON.
// Form C survives parse → emit as authored per-run config (the Test / Example
// typed field) and is consumed only by an ephemeral per-run build — which this
// binding does not perform (no numeric PDE solver). Mirrors the Julia reference
// EarthSciSerialization.jl/src/template_imports.jl.
// ===================================================================

// appendComponentImports appends raw §9.7.2 import entries to a component's own
// `expression_template_imports` (esm-spec §9.7.10 merge order: the target's own
// imports first, then the injected list). `comp` is a mutable raw view.
func appendComponentImports(comp map[string]interface{}, imports []interface{}) {
	var base []interface{}
	if existing, ok := comp["expression_template_imports"].([]interface{}); ok {
		base = append(base, existing...)
	}
	base = append(base, imports...)
	comp["expression_template_imports"] = base
}

// applySubsystemRefInjection performs esm-spec §9.7.10 form A: append the
// subsystem-ref edge's injected §9.7.2 import entries to the single top-level
// component's own `expression_template_imports`, so the referenced document is
// lowered under the assembler-chosen discretization. `view` is the referenced
// file's mutable raw view; a §4.7 subsystem file holds exactly one top-level
// model or reaction system, which is the implicit target. A data-loader-only
// referenced file has no expression positions, so the injection finds no home
// and the mount fails cleanly downstream. Mirrors the Julia reference
// `_apply_subsystem_ref_injection!`.
func applySubsystemRefInjection(view map[string]interface{}, injected []interface{}) {
	if len(injected) == 0 {
		return
	}
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]interface{})
		if !ok || len(comps) == 0 {
			continue
		}
		// Exactly one component (§4.7); sortedKeys makes the pick deterministic.
		for _, cname := range sortedKeys(comps) {
			comp, ok := comps[cname].(map[string]interface{})
			if !ok {
				continue
			}
			appendComponentImports(comp, injected)
			return
		}
	}
}

// couplingReferencedSystems collects, for one coupling entry, the set of system
// names it references (esm-spec §10.8): `operator_compose`/`couple` → members of
// `systems`; `variable_map` → the owning systems of `from`/`to`; `event` →
// owning systems of any scoped reference in the entry. A `callback` references
// none. Mirrors the Julia reference `_coupling_referenced_systems`.
func couplingReferencedSystems(entry map[string]interface{}) map[string]bool {
	out := map[string]bool{}
	ctype, _ := entry["type"].(string)
	switch ctype {
	case "operator_compose", "couple":
		if sys, ok := entry["systems"].([]interface{}); ok {
			for _, s := range sys {
				ss, ok := s.(string)
				if !ok {
					continue
				}
				out[ss] = true
				out[strings.SplitN(ss, ".", 2)[0]] = true
			}
		}
	case "variable_map":
		for _, k := range []string{"from", "to"} {
			if v, ok := entry[k].(string); ok {
				out[strings.SplitN(v, ".", 2)[0]] = true
			}
		}
	case "event":
		collectScopedOwners(out, entry)
	}
	return out
}

// collectScopedOwners walks `x` and adds the owning-system segment of every
// scoped reference (a string of the form "System.var") to `out`. Used for
// `event` entries whose system references are spread across conditions/affects.
// Mirrors the Julia reference `_collect_scoped_owners!`.
func collectScopedOwners(out map[string]bool, x interface{}) {
	switch v := x.(type) {
	case string:
		if strings.Contains(v, ".") {
			out[strings.SplitN(v, ".", 2)[0]] = true
		}
	case map[string]interface{}:
		for _, c := range v {
			collectScopedOwners(out, c)
		}
	case []interface{}:
		for _, c := range v {
			collectScopedOwners(out, c)
		}
	}
}

// applyCouplingInjections performs esm-spec §9.7.10 form B / §10.8: for each
// `coupling` entry carrying an `expression_template_imports` map
// `{ <target>: [imports...] }`, resolve each target key to a top-level system
// and append its imports to that system's own `expression_template_imports`
// (merge order §9.7.10). The map is consumed here (deleted from the entry) so
// form B does not survive parse → emit.
//
// Diagnostics (esm-spec §9.6.6): a key naming no system the entry references is
// `template_inject_target_unknown`; a key resolving to a data loader is
// `template_inject_target_is_loader`; a key resolving to neither model, reaction
// system, nor loader is `template_inject_target_not_component`. Only top-level
// system targets are resolved by this binding — a nested `Parent.Child` key is
// out of scope and reported as `template_inject_target_not_component`. Mirrors
// the Julia reference `_apply_coupling_injections!`.
func applyCouplingInjections(view map[string]interface{}) error {
	coupling, ok := view["coupling"].([]interface{})
	if !ok {
		return nil
	}
	models, _ := view["models"].(map[string]interface{})
	rsystems, _ := view["reaction_systems"].(map[string]interface{})
	loaders, _ := view["data_loaders"].(map[string]interface{})
	topComp := func(d map[string]interface{}, k string) (map[string]interface{}, bool) {
		if d == nil {
			return nil, false
		}
		c, has := d[k]
		if !has {
			return nil, false
		}
		cm, ok := c.(map[string]interface{})
		return cm, ok
	}
	for _, entryRaw := range coupling {
		entry, ok := entryRaw.(map[string]interface{})
		if !ok {
			continue
		}
		injRaw, has := entry["expression_template_imports"]
		if !has || injRaw == nil {
			continue
		}
		inj, ok := injRaw.(map[string]interface{})
		if !ok {
			return newETErr("template_inject_target_not_component",
				"coupling entry `expression_template_imports` must be a map from a target system name to a list of imports (esm-spec §9.7.10 / §10.8)")
		}
		referenced := couplingReferencedSystems(entry)
		for _, tname := range sortedKeys(inj) {
			if !referenced[tname] {
				refList := "(none)"
				if len(referenced) > 0 {
					names := make([]string, 0, len(referenced))
					for n := range referenced {
						names = append(names, n)
					}
					sort.Strings(names)
					refList = strings.Join(names, ", ")
				}
				return newETErr("template_inject_target_unknown",
					fmt.Sprintf("coupling entry `expression_template_imports` key '%s' names no system referenced by that entry (esm-spec §9.7.10 / §10.8). The entry references: %s.", tname, refList))
			}
			var comp map[string]interface{}
			if c, ok := topComp(models, tname); ok {
				comp = c
			} else if c, ok := topComp(rsystems, tname); ok {
				comp = c
			} else if _, ok := loaders[tname]; ok {
				return newETErr("template_inject_target_is_loader",
					fmt.Sprintf("coupling entry `expression_template_imports` key '%s' resolves to a data loader, which is pure I/O with no expression positions to rewrite (esm-spec §9.7.10 / §14).", tname))
			} else {
				return newETErr("template_inject_target_not_component",
					fmt.Sprintf("coupling entry `expression_template_imports` key '%s' resolves to neither a top-level model, reaction system, nor data loader (esm-spec §9.7.10). Nested `Parent.Child` targets are out of scope.", tname))
			}
			importsList, ok := inj[tname].([]interface{})
			if !ok {
				return newETErr("template_import_not_library",
					fmt.Sprintf("coupling entry `expression_template_imports` value for '%s' must be a list of §9.7.2 import entries (esm-spec §9.7.10 / §10.8).", tname))
			}
			appendComponentImports(comp, importsList)
		}
		delete(entry, "expression_template_imports")
	}
	return nil
}
