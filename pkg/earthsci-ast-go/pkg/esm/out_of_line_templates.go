package esm

// Out-of-line expression templates — Option B (reference-preserving), esm 0.9.0.
//
// Implements the RFC out-of-line-expression-templates contract (esm-spec §9.6.4
// rules 1-8, §9.6.9 validation discharge, §9.7.2 `only` closure, §10.7 flatten)
// for the Go binding. Mirrors the Julia reference
// EarthSciAST.jl/src/templates/ (Expand, reference-preserving emit, flatten
// registry merge); the rule-3 per-instance body rewriting is
// template_instances.go.
//
// The load-time rewrite (lower_expression_templates.go) PRESERVES surviving
// `apply_expression_template` references and per-component `expression_templates`
// registries. The typed / numeric build path is Expand-at-build (RFC §7.7):
// LowerExpressionTemplates / ResolveAndLower call Expand once so downstream code
// sees the Option-A image. The reference-preserving form travels only into emit
// (EmitReferencePreserving) and flatten (flattenTemplateRegistries).

import (
	"bytes"
	"encoding/json"
	"fmt"
	"reflect"
	"sort"
	"strconv"
	"strings"
)

// ---------------------------------------------------------------------------
// The rewrite-target op tier T (esm-spec §4.2; RFC §7.2)
// ---------------------------------------------------------------------------

// rewriteTargetOps hand-lists ONLY the tier-T members that ALSO carry an
// evaluable-core meaning and therefore would not be caught by the generic
// `!evaluableCoreOps` fallback in opInT: `D` (evaluable-core in its structural
// equation-LHS role, a rewrite target everywhere else) and the load-eliminated
// forms `enum`/`integral`. Every OTHER open-tier rewrite target — an
// unregistered user op, which carries NO privileged semantics — is NOT in
// evaluableCoreOps and so reaches T through that generic fallback, not this
// hand-list.
// `apply_expression_template` itself is excluded — nested references are handled
// through the §9.7.3 reference DAG, not by op membership. Mirrors the Julia
// `_REWRITE_TARGET_OPS`.
var rewriteTargetOps = map[string]struct{}{
	"D": {}, "integral": {}, "enum": {},
}

// evaluableCoreOps is the evaluable-core operator registry (the Julia
// op_registry.jl `_OP_TABLE` name set). An op absent from this set is an
// open-namespace custom op — a rewrite target no evaluator implements — so it
// is in T (opInT). Kept in lockstep with the reference registry; a new
// evaluable-core op must be added here.
var evaluableCoreOps = map[string]struct{}{
	// Arithmetic
	// `pow` and `neg` are deprecated (esm-spec §4.2): the loader rewrites them
	// to `^` and `-`, but they stay evaluable core for expressions built in code.
	"+": {}, "-": {}, "*": {}, "/": {}, "^": {}, "pow": {}, "neg": {},
	// Comparisons
	"<": {}, "<=": {}, ">": {}, ">=": {}, "==": {}, "!=": {},
	// Logical
	"and": {}, "or": {}, "not": {},
	// Control
	"ifelse": {}, "Pre": {},
	// Elementary
	"sin": {}, "cos": {}, "tan": {}, "asin": {}, "acos": {}, "atan": {}, "atan2": {},
	"sinh": {}, "cosh": {}, "tanh": {}, "asinh": {}, "acosh": {}, "atanh": {},
	"exp": {}, "log": {}, "log10": {}, "sqrt": {}, "abs": {}, "sign": {},
	"floor": {}, "ceil": {}, "min": {}, "max": {},
	// Constants
	"pi": {}, "π": {}, "e": {}, "true": {}, "false": {},
	// Retired closure marker
	"call": {},
	// Const data / enum marker
	"const": {}, "enum": {},
	// Calculus / IC markers. An unregistered user op (`godunov_hamiltonian`)
	// is deliberately absent here and reaches tier T through the generic
	// `!evaluableCoreOps` fallback in opInT.
	"D": {}, "ic": {},
	// Array producers / gathers / reshapes
	"index": {}, "makearray": {}, "broadcast": {}, "reshape": {}, "transpose": {}, "concat": {},
	// Aggregates
	"faq": {},
}

// opInT reports whether op is a member of the rewrite-target tier T (esm-spec
// §9.6.4 rule 3): one of the named rewrite-target ops, or an op with no
// evaluable-core registry entry (an open-namespace custom op). The template
// reference op itself is never in T. Mirrors the Julia `_op_in_T`.
func opInT(op string) bool {
	if op == applyExpressionTemplateOp {
		return false
	}
	if _, ok := rewriteTargetOps[op]; ok {
		return true
	}
	_, known := evaluableCoreOps[op]
	return !known
}

// directOp reports whether node contains, anywhere within it, an object whose
// `op` satisfies pred.
func directOp(node any, pred func(string) bool) bool {
	return directOpSeen(node, pred, map[uintptr]struct{}{})
}

func directOpSeen(node any, pred func(string) bool, seen map[uintptr]struct{}) bool {
	switch n := node.(type) {
	case []any:
		for _, c := range n {
			if directOpSeen(c, pred, seen) {
				return true
			}
		}
	case map[string]any:
		key := reflect.ValueOf(n).Pointer()
		if _, dup := seen[key]; dup {
			return false
		}
		seen[key] = struct{}{}
		if op, ok := n["op"].(string); ok && pred(op) {
			return true
		}
		for _, v := range n {
			if directOpSeen(v, pred, seen) {
				return true
			}
		}
	}
	return false
}

// templateOpBearing computes, for every template in `named`, whether it can
// produce an object whose `op` satisfies pred: its body contains one anywhere
// (including inside nested references' bindings), or it references,
// transitively through the acyclic body-reference DAG, a template that can.
func templateOpBearing(named map[string]any, pred func(string) bool) map[string]bool {
	tb := map[string]bool{}
	inprogress := map[string]bool{}
	var visit func(name string) bool
	visit = func(name string) bool {
		if v, ok := tb[name]; ok {
			return v
		}
		if inprogress[name] {
			// Defensive against a cycle the checker somehow missed.
			return false
		}
		declRaw, ok := named[name]
		if !ok {
			tb[name] = false
			return false
		}
		decl, _ := declRaw.(map[string]any)
		inprogress[name] = true
		body := decl["body"]
		res := body != nil && directOp(body, pred)
		if !res {
			var refs []string
			collectApplyNames(&refs, body)
			for _, r := range refs {
				if _, ok := named[r]; !ok {
					continue
				}
				if visit(r) {
					res = true
					break
				}
			}
		}
		delete(inprogress, name)
		tb[name] = res
		return res
	}
	for name := range named {
		visit(name)
	}
	return tb
}

// cloneMapAny shallow-copies a map[string]any (values shared by reference).
func cloneMapAny(m map[string]any) map[string]any {
	out := make(map[string]any, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

// expandMemo keys object nodes by map pointer identity. The walks expand
// freshly instantiated template bodies, which become garbage once their result
// is built, and Go may then hand a new map the same address; each entry
// therefore holds its key map (`in`) so the address cannot be recycled while
// the memo is live.
type expandMemo map[uintptr]expandMemoEntry

type expandMemoEntry struct {
	in      map[string]any
	out     any
	changed bool
}

// ---------------------------------------------------------------------------
// Full expansion — Expand (esm-spec §9.6.4 rule 2)
// ---------------------------------------------------------------------------

// expandAll fully expands EVERY `apply_expression_template` node in node by pure
// substitution to a fixpoint (innermost-first: bindings are expanded before the
// body is instantiated, and the instantiated body is re-expanded). Deterministic
// and sharing-preserving. Mirrors the Julia `_expand_all`.
func expandAll(node any, named map[string]any, scope string) (any, error) {
	out, _, err := expandAllShared(node, named, scope, expandMemo{})
	return out, err
}

func expandAllShared(node any, named map[string]any, scope string, memo expandMemo) (any, bool, error) {
	switch n := node.(type) {
	case []any:
		var out []any
		for i, c := range n {
			nc, ch, err := expandAllShared(c, named, scope, memo)
			if err != nil {
				return nil, false, err
			}
			if ch && out == nil {
				out = make([]any, len(n))
				copy(out, n[:i])
			}
			if out != nil {
				out[i] = nc
			}
		}
		if out == nil {
			return n, false, nil
		}
		return out, true, nil
	case map[string]any:
		key := reflect.ValueOf(n).Pointer()
		if e, hit := memo[key]; hit {
			return e.out, e.changed, nil
		}
		op, _ := n["op"].(string)
		if op == applyExpressionTemplateOp {
			newnode := n
			if b, ok := n["bindings"].(map[string]any); ok {
				var nb map[string]any
				for _, bk := range sortedKeys(b) {
					nbv, ch, err := expandAllShared(b[bk], named, scope, memo)
					if err != nil {
						return nil, false, err
					}
					if ch {
						if nb == nil {
							nb = cloneMapAny(b)
						}
						nb[bk] = nbv
					}
				}
				if nb != nil {
					newnode = cloneMapAny(n)
					newnode["bindings"] = nb
				}
			}
			body, err := expandApply(newnode, named, scope)
			if err != nil {
				return nil, false, err
			}
			res, _, err := expandAllShared(body, named, scope, memo)
			if err != nil {
				return nil, false, err
			}
			memo[key] = expandMemoEntry{in: n, out: res, changed: true}
			return res, true, nil
		}
		var out map[string]any
		for _, k := range sortedKeys(n) {
			nv, ch, err := expandAllShared(n[k], named, scope, memo)
			if err != nil {
				return nil, false, err
			}
			if ch {
				if out == nil {
					out = cloneMapAny(n)
				}
				out[k] = nv
			}
		}
		if out == nil {
			memo[key] = expandMemoEntry{in: n, out: n, changed: false}
			return n, false, nil
		}
		memo[key] = expandMemoEntry{in: n, out: out, changed: true}
		return out, true, nil
	}
	return node, false, nil
}

// expandDocument fully expands every surviving `apply_expression_template`
// reference in a loaded (Option B) document, producing the Option-A image:
// every reference replaced by its expansion (§9.6.4 rule 2) and every
// per-component `expression_templates` block stripped. Mutates `view` in place.
// Mirrors the Julia `expand_document`.
func expandDocument(view map[string]any) map[string]any {
	if view == nil {
		return view
	}
	// Capture each component's named registry BEFORE stripping the blocks.
	compNamed := map[[2]string]map[string]any{}
	for _, kind := range templateComponentKinds {
		comps, _ := view[kind].(map[string]any)
		for cname, compRaw := range comps {
			comp, ok := compRaw.(map[string]any)
			if !ok {
				continue
			}
			named := map[string]any{}
			if tpl, ok := comp["expression_templates"].(map[string]any); ok {
				for n, d := range tpl {
					named[n] = d
				}
			}
			compNamed[[2]string{kind, cname}] = named
		}
	}
	for _, kind := range templateComponentKinds {
		comps, _ := view[kind].(map[string]any)
		for cname, compRaw := range comps {
			comp, ok := compRaw.(map[string]any)
			if !ok {
				continue
			}
			named := compNamed[[2]string{kind, cname}]
			scope := kind + "." + cname
			for _, k := range sortedKeys(comp) {
				if k == "expression_templates" || k == "expression_template_imports" {
					continue
				}
				res, err := expandAll(comp[k], named, scope+"."+k)
				if err == nil {
					comp[k] = res
				}
			}
			delete(comp, "expression_templates")
		}
	}
	if coupling, ok := view["coupling"].([]any); ok {
		for idx, entryRaw := range coupling {
			entry, ok := entryRaw.(map[string]any)
			if !ok {
				continue
			}
			if t, _ := entry["type"].(string); t != "variable_map" {
				continue
			}
			tr, ok := entry["transform"].(map[string]any)
			if !ok {
				continue
			}
			to, _ := entry["to"].(string)
			recv := to
			if i := strings.Index(to, "."); i >= 0 {
				recv = to[:i]
			}
			named, ok := compNamed[[2]string{"models", recv}]
			if !ok {
				named, ok = compNamed[[2]string{"reaction_systems", recv}]
			}
			if !ok || named == nil {
				continue
			}
			if res, err := expandAll(tr, named, fmt.Sprintf("coupling[%d].transform", idx)); err == nil {
				entry["transform"] = res
			}
		}
	}
	return view
}

// Expand fully expands every surviving `apply_expression_template` reference in
// a loaded document by pure substitution to the acyclic fixpoint (esm-spec
// §9.6.4 rule 2), producing the Option-A image. Deterministic (the DAG is
// acyclic and substitution confluent) and NON-DESTRUCTIVE — `view` is deep
// copied first. Public alias mirroring the Julia `Expand`.
func Expand(view map[string]any) map[string]any {
	cp, _ := deepCopyJSON(view).(map[string]any)
	return expandDocument(cp)
}

// ---------------------------------------------------------------------------
// Call-site checks for SURVIVING references (esm-spec §9.6.9)
// ---------------------------------------------------------------------------

// validateApplyRef is the call-site check for a SURVIVING (non-expanded)
// `apply_expression_template` reference (esm-spec §9.6.9): the referenced `name`
// must resolve to an in-scope MATCH-LESS template and `bindings` must cover its
// `params` exactly. Same diagnostics as expandApply, but WITHOUT expanding.
// Mirrors the Julia `_validate_apply_ref`.
func validateApplyRef(node map[string]any, templates map[string]any, scope string) error {
	name, ok := node["name"].(string)
	if !ok || name == "" {
		return newETErr(CodeApplyExpressionTemplateInvalidDeclaration,
			fmt.Sprintf("%s: apply_expression_template node missing 'name'", scope))
	}
	declRaw, ok := templates[name]
	if !ok {
		return newETErr(CodeApplyExpressionTemplateUnknownTemplate,
			fmt.Sprintf("%s: apply_expression_template references undeclared template '%s'", scope, name))
	}
	decl, _ := declRaw.(map[string]any)
	if m, has := decl["match"]; has && m != nil {
		return newETErr(CodeApplyExpressionTemplateUnknownTemplate,
			fmt.Sprintf("%s: apply_expression_template references '%s', a `match` rewrite rule — only match-less templates are invocable by name (esm-spec §9.6.2)", scope, name))
	}
	bindingsRaw, ok := node["bindings"].(map[string]any)
	if !ok {
		return newETErr(CodeApplyExpressionTemplateBindingsMismatch,
			fmt.Sprintf("%s: apply_expression_template '%s' missing 'bindings' object", scope, name))
	}
	declared := map[string]struct{}{}
	if pr, ok := decl["params"].([]any); ok {
		for _, p := range pr {
			if ps, ok := p.(string); ok {
				declared[ps] = struct{}{}
				if _, has := bindingsRaw[ps]; !has {
					return newETErr(CodeApplyExpressionTemplateBindingsMismatch,
						fmt.Sprintf("%s: apply_expression_template '%s' missing binding for param '%s'", scope, name, ps))
				}
			}
		}
	}
	for k := range bindingsRaw {
		if _, ok := declared[k]; !ok {
			return newETErr(CodeApplyExpressionTemplateBindingsMismatch,
				fmt.Sprintf("%s: apply_expression_template '%s' supplies unknown param '%s'", scope, name, k))
		}
	}
	return nil
}

// checkSurvivingRefs walks node and runs validateApplyRef on every surviving
// `apply_expression_template` reference it carries (esm-spec §9.6.9 call-site
// checks). Descends into references' bindings too. Mirrors `_check_surviving_refs`.
func checkSurvivingRefs(node any, templates map[string]any, scope string) error {
	return checkSurvivingRefsSeen(node, templates, scope, map[uintptr]struct{}{})
}

func checkSurvivingRefsSeen(node any, templates map[string]any, scope string, seen map[uintptr]struct{}) error {
	switch n := node.(type) {
	case []any:
		for _, c := range n {
			if err := checkSurvivingRefsSeen(c, templates, scope, seen); err != nil {
				return err
			}
		}
	case map[string]any:
		key := reflect.ValueOf(n).Pointer()
		if _, dup := seen[key]; dup {
			return nil
		}
		seen[key] = struct{}{}
		if op, _ := n["op"].(string); op == applyExpressionTemplateOp {
			if err := validateApplyRef(n, templates, scope); err != nil {
				return err
			}
		}
		for _, k := range sortedKeys(n) {
			if err := checkSurvivingRefsSeen(n[k], templates, scope, seen); err != nil {
				return err
			}
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Reference-aware validation discharge (esm-spec §9.6.9, Option B)
// ---------------------------------------------------------------------------

// validateMakearrayRegionsInRegistries discharges `makearray_region_inverted` at
// registration on the composed, metaparameter-folded template bodies — region
// bounds cannot carry template params, so the check is instantiation-independent
// (esm-spec §9.6.9). Mirrors `_validate_makearray_regions_in_registries`.
func validateMakearrayRegionsInRegistries(registries map[string]map[string]any) error {
	cnames := make([]string, 0, len(registries))
	for c := range registries {
		cnames = append(cnames, c)
	}
	sort.Strings(cnames)
	for _, cname := range cnames {
		named := registries[cname]
		for _, tname := range sortedKeys(named) {
			decl, ok := named[tname].(map[string]any)
			if !ok {
				continue
			}
			body := decl["body"]
			if body == nil {
				continue
			}
			if err := validateMakearrayRegions(body, "expression_templates."+tname+"/body"); err != nil {
				return err
			}
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Reference-preserving emit (esm-spec §9.6.4 rule 5, §9.6.7)
// ---------------------------------------------------------------------------

// refClosure is the transitive closure of the templates named by refnames
// (surviving-reference names), following references inside materialized bodies,
// keeping only MATCH-LESS entries (match rules are never materialized). Mirrors
// the Julia `_ref_closure`.
func refClosure(refnames map[string]bool, named map[string]any) map[string]bool {
	out := map[string]bool{}
	var stack []string
	for n := range refnames {
		stack = append(stack, n)
	}
	for len(stack) > 0 {
		n := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		if out[n] {
			continue
		}
		declRaw, ok := named[n]
		if !ok {
			continue
		}
		decl, _ := declRaw.(map[string]any)
		if m, has := decl["match"]; has && m != nil {
			continue // match rules not materialized
		}
		out[n] = true
		var refs []string
		collectApplyNames(&refs, decl["body"])
		stack = append(stack, refs...)
	}
	return out
}

// authoredTemplateNames returns the per-component template names authored
// in-file in origView (in source declaration order via `orders`). Emit keeps
// these in authored position (esm-spec §9.6.4 rule 5): a match-less entry
// always, a `match` rule only when a firing referenced it (it is then
// materialized without `match`, `where` and `priority`); imported/derived
// templates are materialized instead. Mirrors `_authored_template_names`.
func authoredTemplateNames(origView map[string]any, orders map[string][]string) map[string][]string {
	authored := map[string][]string{}
	for _, kind := range templateComponentKinds {
		comps, ok := origView[kind].(map[string]any)
		if !ok {
			continue
		}
		for cname, compRaw := range comps {
			comp, ok := compRaw.(map[string]any)
			if !ok {
				continue
			}
			tpl, ok := comp["expression_templates"].(map[string]any)
			if !ok {
				continue
			}
			order := orders["/"+kind+"/"+cname+"/expression_templates"]
			var names []string
			for _, n := range orderedKeysOf(tpl, order) {
				if _, ok := tpl[n].(map[string]any); !ok {
					continue
				}
				names = append(names, n)
			}
			authored[kind+"."+cname] = names
		}
	}
	return authored
}

// receivedTransformRefs gives, per component ({kind, name}), the template names
// referenced by the `variable_map` transforms it RECEIVES — the receiver
// collectCouplingTransformSites pairs each entry with. The transforms keep
// their references (esm-spec §10.4); the receiving component owns them, so its
// emitted block materializes their closure (§9.6.4 rule 5). Mirrors the Julia
// reference `_received_transform_refs`.
func receivedTransformRefs(view map[string]any) map[[2]string][]string {
	out := map[[2]string][]string{}
	for key, sites := range collectCouplingTransformSites(view) {
		var refs []string
		for _, s := range sites {
			collectApplyNames(&refs, s.entry["transform"])
		}
		out[key] = refs
	}
	return out
}

// materializeComponentBlock computes one Option-B loaded component's emitted
// `expression_templates` block (esm-spec §9.6.4 rule 5): the entries authored
// in-file (`authoredHere`, authored order) first — a `match` rule only once a
// firing referenced it and rule 3 materialized it without `match` — then the
// transitive closure of the component's surviving references not authored
// here, sorted by UTF-8 bytes. Also reports whether the component carries any
// surviving reference and whether any non-authored entry was materialized
// (the §9.6.4 rule 8 version stamp). Shared by emit and the typed load path,
// as the Julia `_materialize_components!` is. `received` names the references
// of the coupling transforms the component receives (receivedTransformRefs),
// which count as its own.
func materializeComponentBlock(comp map[string]any, authoredHere, received []string) (*orderedMap, bool, bool) {
	named := map[string]any{}
	if tpl, ok := comp["expression_templates"].(map[string]any); ok {
		for n, d := range tpl {
			named[n] = d
		}
	}
	refnames := map[string]bool{}
	for _, r := range received {
		refnames[r] = true
	}
	for _, k := range sortedKeys(comp) {
		if k == "expression_templates" || k == "expression_template_imports" {
			continue
		}
		var refs []string
		collectApplyNames(&refs, comp[k])
		for _, r := range refs {
			refnames[r] = true
		}
	}
	materialized := refClosure(refnames, named)
	authoredSet := map[string]bool{}
	for _, n := range authoredHere {
		authoredSet[n] = true
	}
	block := newOrderedMap()
	for _, n := range authoredHere {
		// A `match` rule nothing references still carries its `match` (a
		// referenced one was materialized without it, §9.6.4 rule 3).
		if d, ok := named[n].(map[string]any); ok && !declHasMatch(d) {
			block.set(n, d)
		}
	}
	var matNames []string
	for n := range materialized {
		if !authoredSet[n] {
			matNames = append(matNames, n)
		}
	}
	sort.Strings(matNames)
	for _, n := range matNames {
		block.set(n, named[n])
	}
	return block, len(refnames) > 0, len(matNames) > 0
}

// emitDocument produces the reference-preserving, self-contained emitted
// document (esm-spec §9.6.4 rule 5, RFC §7.5) from a source document. Loads the
// source under Option B, then for every component builds its emitted
// `expression_templates` block — authored match-less entries first in authored
// order, then the materialized transitive closure of its surviving references
// (match-less), lexicographically sorted — drops consumed
// `expression_template_imports`, and raises the `esm` version FLOOR to 0.9.0 when any
// surviving reference or materialized entry remains (§9.6.4 rule 8). Mirrors the
// Julia `emit_document`.
func emitDocument(jsonStr, basePath string, metaparameters map[string]int64) (map[string]any, error) {
	origView, err := decodeJSONView([]byte(jsonStr))
	if err != nil {
		return nil, fmt.Errorf("emit: decode source: %w", err)
	}
	origOrders := extractTemplateOrders(jsonStr)
	authored := authoredTemplateNames(origView, origOrders)

	view, err := loadOptionB(jsonStr, basePath, metaparameters)
	if err != nil {
		return nil, err
	}

	bump := false
	received := receivedTransformRefs(view)
	for _, kind := range templateComponentKinds {
		comps, ok := view[kind].(map[string]any)
		if !ok {
			continue
		}
		for _, cname := range sortedKeys(comps) {
			comp, ok := comps[cname].(map[string]any)
			if !ok {
				continue
			}
			key := kind + "." + cname
			emitBlock, hasRefs, hasMaterialized := materializeComponentBlock(
				comp, authored[key], received[[2]string{kind, cname}])
			if hasRefs || hasMaterialized {
				bump = true
			}

			if emitBlock.len() == 0 {
				delete(comp, "expression_templates")
			} else {
				comp["expression_templates"] = emitBlock
			}
			delete(comp, "expression_template_imports")
		}
	}

	delete(view, "expression_template_imports")
	if bump && esmVersionBelow(view, 0, 9) {
		// esm-spec §9.6.4 rule 6: an emitted document carrying surviving
		// references or a materialized registry declares `esm: 0.9.0` OR LATER.
		// The stamp is a FLOOR, not an assignment — writing it unconditionally
		// DOWNGRADED a 1.0.0 document to 0.9.0 on emit, which changed the meaning
		// of every construct in it and diverged from the committed goldens.
		view["esm"] = "0.9.0"
	}
	return view, nil
}

// loadOptionB resolves the §9.7 machinery and runs the Option-B lowering,
// PRESERVING surviving references and per-component registries (no Expand). This
// is the "loaded" reference-preserving form that emit and flatten consume.
//
// The source passes the same wire boundary a load applies (prepareDocumentOps):
// a removed op is refused, and a deprecated `neg` / `pow` is rewritten with the
// `deprecated_op` warning, so neither spelling survives into the emitted
// document (esm-spec §4.2).
func loadOptionB(jsonStr, basePath string, metaparameters map[string]int64) (map[string]any, error) {
	jsonStr, err := prepareDocumentOps(jsonStr)
	if err != nil {
		return nil, err
	}
	view, err := decodeJSONView([]byte(jsonStr))
	if err != nil {
		return nil, fmt.Errorf("loadOptionB: decode: %w", err)
	}
	orders := extractTemplateOrders(jsonStr)
	if err := applyCouplingInjections(view); err != nil {
		return nil, err
	}
	// The §4.7 mount context of a ROOT document — same two halves the Option-A
	// load path computes, so `emit` and `flatten` refuse the same documents
	// `load` refuses (see rootMountContext).
	mountDeclared, err := rootMountContext(view, basePath, metaparameters)
	if err != nil {
		return nil, err
	}
	if _, err := resolveTemplateMachinery(view, orders, basePath, metaparameters,
		resolveOpts{mountDeclared: mountDeclared}); err != nil {
		return nil, err
	}
	if err := lowerExpressionTemplatesOrdered(view, orders); err != nil {
		return nil, err
	}
	return view, nil
}

// EmitReferencePreserving loads jsonStr under Option B and emits the canonical,
// self-contained reference-preserving document (esm-spec §9.6.4 rule 5, §9.6.7):
// surviving call sites verbatim, materialized template registries, imports
// consumed, `esm: 0.9.0` version stamp. The byte-identity cross-binding surface —
// output is byte-identical to the Julia-generated `emitted.esm` goldens.
func EmitReferencePreserving(jsonStr, basePath string, metaparameters map[string]int64) (string, error) {
	doc, err := emitDocument(jsonStr, basePath, metaparameters)
	if err != nil {
		return "", err
	}
	return emitCanonicalString(doc), nil
}

// ---------------------------------------------------------------------------
// Canonical byte writer (2-space indent, keys sorted EXCEPT the ordered
// expression_templates block) — the cross-binding byte-identity surface.
// Mirrors the Julia `_emit_write` / `emit_esm_string`.
// ---------------------------------------------------------------------------

// emitCanonicalString is the canonical byte serialization of an emitted document
// (esm-spec §9.6.4 rule 5): 2-space indent, object keys sorted lexicographically
// EXCEPT the entries of an `expression_templates` block (an *orderedMap), which
// preserve their authored-first / materialized-sorted order.
func emitCanonicalString(doc any) string {
	var b strings.Builder
	emitWriteValue(&b, doc, 0)
	b.WriteByte('\n')
	return b.String()
}

func emitWriteValue(b *strings.Builder, x any, indent int) {
	pad := strings.Repeat("  ", indent)
	pad1 := strings.Repeat("  ", indent+1)
	switch v := x.(type) {
	case *orderedMap:
		// The expression_templates block: entry order preserved.
		if len(v.keys) == 0 {
			b.WriteString("{}")
			return
		}
		b.WriteString("{\n")
		for i, k := range v.keys {
			b.WriteString(pad1)
			b.WriteString(emitJSONString(k))
			b.WriteString(": ")
			emitWriteValue(b, v.m[k], indent+1)
			if i < len(v.keys)-1 {
				b.WriteByte(',')
			}
			b.WriteByte('\n')
		}
		b.WriteString(pad)
		b.WriteByte('}')
	case map[string]any:
		keys := sortedKeys(v)
		if len(keys) == 0 {
			b.WriteString("{}")
			return
		}
		b.WriteString("{\n")
		for i, k := range keys {
			b.WriteString(pad1)
			b.WriteString(emitJSONString(k))
			b.WriteString(": ")
			emitWriteValue(b, v[k], indent+1)
			if i < len(keys)-1 {
				b.WriteByte(',')
			}
			b.WriteByte('\n')
		}
		b.WriteString(pad)
		b.WriteByte('}')
	case []any:
		if len(v) == 0 {
			b.WriteString("[]")
			return
		}
		b.WriteString("[\n")
		for i, e := range v {
			b.WriteString(pad1)
			emitWriteValue(b, e, indent+1)
			if i < len(v)-1 {
				b.WriteByte(',')
			}
			b.WriteByte('\n')
		}
		b.WriteString(pad)
		b.WriteByte(']')
	default:
		b.WriteString(emitScalar(x))
	}
}

// emitScalar renders a JSON scalar in canonical form: strings JSON-quoted
// (HTML escaping OFF, matching JSON3), numbers per §5.5.3.1 (an integral,
// int64-representable value has no trailing ".0").
func emitScalar(x any) string {
	switch v := x.(type) {
	case nil:
		return "null"
	case string:
		return emitJSONString(v)
	case bool:
		if v {
			return "true"
		}
		return "false"
	case json.Number:
		return emitNumberString(string(v))
	case int64:
		return strconv.FormatInt(v, 10)
	case int:
		return strconv.Itoa(v)
	case float64:
		s, err := canonicalFloat64String(v)
		if err != nil {
			return "null"
		}
		return s
	default:
		blob, err := json.Marshal(x)
		if err != nil {
			return "null"
		}
		return string(blob)
	}
}

// emitNumberString renders a json.Number token in §5.5.3.1 canonical form: an
// integer-grammar token that fits int64 emits verbatim as an integer; otherwise
// the value is rendered via the shared canonical float formatter (an integral
// float narrows to an integer literal).
func emitNumberString(s string) string {
	if !strings.ContainsAny(s, ".eE") {
		if i, err := strconv.ParseInt(s, 10, 64); err == nil {
			return strconv.FormatInt(i, 10)
		}
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return s
	}
	out, err := canonicalFloat64String(f)
	if err != nil {
		return s
	}
	return out
}

// emitJSONString encodes s as a JSON string with HTML escaping disabled, so
// `<`, `>`, `&` emit raw (matching JSON3 / the reference emit bytes).
func emitJSONString(s string) string {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(s); err != nil {
		return strconv.Quote(s)
	}
	return strings.TrimRight(buf.String(), "\n")
}

// ---------------------------------------------------------------------------
// Flatten: template-registry merge (esm-spec §9.6.4 rule 7, §10.7;
// esm-libraries-spec §4.7.5)
// ---------------------------------------------------------------------------

// renameApplyRefs rewrites the `name` of every `apply_expression_template`
// reference in node according to rename (old → new), in lockstep with a registry
// rename. Sharing-preserving. Mirrors the Julia `_rename_apply_refs`.
func renameApplyRefs(node any, rename map[string]string) any {
	switch n := node.(type) {
	case []any:
		var out []any
		for i, v := range n {
			rv := renameApplyRefs(v, rename)
			if rv != nil && !sameRef(rv, v) && out == nil {
				out = make([]any, len(n))
				copy(out, n[:i])
			}
			if out != nil {
				out[i] = rv
			}
		}
		if out == nil {
			return n
		}
		return out
	case map[string]any:
		isApply := false
		if op, _ := n["op"].(string); op == applyExpressionTemplateOp {
			isApply = true
		}
		var out map[string]any
		for _, k := range sortedKeys(n) {
			v := n[k]
			if isApply && k == "name" {
				if vs, ok := v.(string); ok {
					if nn, has := rename[vs]; has {
						if out == nil {
							out = cloneMapAny(n)
						}
						out[k] = nn
						continue
					}
				}
			}
			rv := renameApplyRefs(v, rename)
			if !sameRef(rv, v) {
				if out == nil {
					out = cloneMapAny(n)
				}
				out[k] = rv
			}
		}
		if out == nil {
			return n
		}
		return out
	}
	return node
}

// sameRef reports whether two values are the same underlying container (maps /
// slices by pointer) or equal scalars — used to detect an unchanged rename walk.
func sameRef(a, b any) bool {
	switch av := a.(type) {
	case map[string]any:
		bv, ok := b.(map[string]any)
		return ok && reflect.ValueOf(av).Pointer() == reflect.ValueOf(bv).Pointer()
	case []any:
		bv, ok := b.([]any)
		return ok && reflect.ValueOf(av).Pointer() == reflect.ValueOf(bv).Pointer()
	default:
		return a == b
	}
}

// registryCollisionNames returns the set of template names the flatten-time
// registry merge MUST owner-path rename (esm-spec §9.6.4 rule 7 / §10.7).
// `byname` maps a template name to its per-component occurrences
// `[[path, decl], …]`.
//
// A name collides directly when its occurrences are not all deep-equal. The set
// is then closed under the reference DAG: **if a declaration references a
// colliding name, that declaration collides too**, in every component that
// carries it. That propagation is what makes the rename total.
//
// Without it the common multi-model shape silently breaks. Two components
// import one rule library; the leaf stencil folds differently per component (a
// rebind or a metaparameter) and renames to `A.leaf` / `B.leaf`, while the
// intermediate wrapper that REFERENCES the leaf is byte-identical and would
// dedup under its bare name. That single deduped body then carries a reference the registry no longer
// holds, and expansion fails with `apply_expression_template_unknown_template`
// naming a template no component ever mentioned. Renaming the wrapper per owner
// lets each copy's nested reference be rewritten to its own owner's leaf.
//
// A consequence worth relying on: a name left OUT of the returned set never
// references a name inside it, so deduped entries need no reference rewriting.
//
// Mirrors the Julia reference `_registry_collision_names`.
func registryCollisionNames(byname *orderedMap) map[string]bool {
	collide := map[string]bool{}
	refs := map[string]map[string]bool{}
	for _, name := range byname.keys {
		occ, _ := byname.get(name).([]any)
		first := occ[0].([2]any)[1]
		seen := map[string]bool{}
		for _, o := range occ {
			decl := o.([2]any)[1]
			if !jsonEqual(first, decl) {
				collide[name] = true
			}
			var names []string
			collectApplyNames(&names, decl)
			for _, r := range names {
				seen[r] = true
			}
		}
		refs[name] = seen
	}
	// Close under the reference edges (monotone; <= len(byname.keys) rounds).
	for changed := true; changed; {
		changed = false
		for _, name := range byname.keys {
			if collide[name] {
				continue
			}
			for r := range refs[name] {
				if collide[r] {
					collide[name] = true
					changed = true
					break
				}
			}
		}
	}
	return collide
}

// flattenTemplateRegistries merges every component's `expression_templates`
// registry of an Option-B loaded document into a single document-scoped merged
// registry (esm-spec §9.6.4 rule 7, §10.7; esm-libraries-spec §4.7.5 step 4) by
// mergeFlatRegistry: deep-equal same-name entries are kept once under the bare
// name; a colliding name (registryCollisionNames — non-deep-equal, or reaching
// one that is) keeps one entry per distinct definition, named
// `<first owner's path>.<name>`, with each owner's references rewritten in
// lockstep. Returns the rewritten document and the merged registry (the
// FlattenedSystem's first-class registry field). Match rules are not merged.
//
// Order (esm-libraries-spec §4.7.5 step 4, normative): components in document
// order (models as `source` declares them, then reaction systems), each
// component's block as emit materializes it (materializeComponentBlock:
// authored entries first in authored order, then the materialized ones sorted
// by UTF-8 bytes). `source` is the document text `view` was loaded from; it
// carries the declaration order the decoded view has lost. Mutates `view` in
// place. Mirrors the Julia `flatten_template_registries` over the typed load's
// `component_templates`.
func flattenTemplateRegistries(view map[string]any, source string) (map[string]any, *orderedMap) {
	orders := extractTemplateOrders(source)
	var authored map[string][]string
	if origView, err := decodeJSONView([]byte(source)); err == nil {
		authored = authoredTemplateNames(origView, orders)
	}
	received := receivedTransformRefs(view)
	type compEntry struct {
		path string
		comp map[string]any
	}
	var comps []compEntry
	var blocks []registryBlock
	for _, kind := range templateComponentKinds {
		cs, ok := view[kind].(map[string]any)
		if !ok {
			continue
		}
		for _, cname := range orderedKeysOf(cs, orders["/"+kind]) {
			comp, ok := cs[cname].(map[string]any)
			if !ok {
				continue
			}
			comps = append(comps, compEntry{path: cname, comp: comp})
			if _, ok := comp["expression_templates"].(map[string]any); !ok {
				continue
			}
			mat, _, _ := materializeComponentBlock(
				comp, authored[kind+"."+cname], received[[2]string{kind, cname}])
			if mat.len() > 0 {
				blocks = append(blocks, registryBlock{path: cname, block: mat})
			}
		}
	}
	merged, rename := mergeFlatRegistry(blocks)

	// Rewrite each component's reference sites in lockstep with its renames,
	// then surrender the per-component blocks to the merged registry.
	for _, ce := range comps {
		if rn := rename[ce.path]; rn != nil {
			for _, k := range sortedKeys(ce.comp) {
				if k == "expression_templates" {
					continue
				}
				ce.comp[k] = renameApplyRefs(ce.comp[k], rn)
			}
		}
		delete(ce.comp, "expression_templates")
	}
	return view, merged
}
