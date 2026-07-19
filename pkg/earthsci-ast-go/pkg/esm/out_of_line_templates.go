package esm

// Out-of-line expression templates — Option B (reference-preserving), esm 0.9.0.
//
// Implements the RFC out-of-line-expression-templates contract (esm-spec §9.6.4
// rules 1-8, §9.6.9 validation discharge, §9.7.2 `only` closure, §10.7 flatten)
// for the Go binding. Mirrors the Julia reference
// EarthSciAST.jl/src/lower_expression_templates.jl (target-bearing flags, eager
// pre-pass, Expand, reference-preserving emit, flatten registry merge).
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
	"errors"
	"fmt"
	"reflect"
	"sort"
	"strconv"
	"strings"
)

// ---------------------------------------------------------------------------
// Eager-expansion carve-out: the rewrite-target op tier T (esm-spec §9.6.4
// rule 3 / RFC §7.2)
// ---------------------------------------------------------------------------

// rewriteTargetOps hand-lists ONLY the tier-T members that ALSO carry an
// evaluable-core meaning and therefore would not be caught by the generic
// `!evaluableCoreOps` fallback in opInT: `D` (evaluable-core in its structural
// equation-LHS role, a rewrite target everywhere else) and the load-eliminated
// forms `enum`/`table_lookup`/`integral`. Every OTHER open-tier rewrite target —
// an unregistered user op, and the spatial-calculus sugar grad/div/laplacian,
// which carry NO privileged semantics — is NOT in evaluableCoreOps and so
// reaches T through that generic fallback, not this hand-list.
// `apply_expression_template` itself is excluded — nested references are handled
// through the §9.7.3 reference DAG, not by op membership. Mirrors the Julia
// `_REWRITE_TARGET_OPS`.
var rewriteTargetOps = map[string]struct{}{
	"D": {}, "integral": {}, "table_lookup": {}, "enum": {},
}

// evaluableCoreOps is the evaluable-core operator registry (the Julia
// op_registry.jl `_OP_TABLE` name set). An op absent from this set is an
// open-namespace custom op — a rewrite target no evaluator implements — so it
// is in T (opInT). Kept in lockstep with the reference registry; a new
// evaluable-core op must be added here.
var evaluableCoreOps = map[string]struct{}{
	// Arithmetic
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
	// Functions / retired closure marker
	"fn": {}, "call": {},
	// Const data / enum marker
	"const": {}, "enum": {},
	// Calculus / IC markers. NOTE: grad/div/laplacian are NOT evaluable-core —
	// they are ordinary open-tier rewrite-target sugar (esm-spec §4.2 / §9.6.8)
	// with no privileged semantics, so they are deliberately absent here and
	// reach tier T through the generic `!evaluableCoreOps` fallback in opInT,
	// exactly like an unregistered user op (`godunov_hamiltonian`).
	"D": {}, "ic": {},
	// Array producers / gathers / reshapes
	"index": {}, "makearray": {}, "broadcast": {}, "reshape": {}, "transpose": {}, "concat": {},
	// Aggregates
	"arrayop": {}, "aggregate": {},
	// Geometry kernel leaves / value invention
	"intersect_polygon": {}, "polygon_intersection_area": {}, "skolem": {},
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

// directTOp reports whether node contains, ANYWHERE within it (descending
// through every field, including the `bindings` of nested apply nodes), an
// object whose `op` is in T (opInT). Does NOT follow references to other
// templates — that transitive step is templateTargetBearing. Mirrors the Julia
// `_direct_T_op`.
func directTOp(node any) bool {
	return directTOpSeen(node, map[uintptr]struct{}{})
}

func directTOpSeen(node any, seen map[uintptr]struct{}) bool {
	switch n := node.(type) {
	case []any:
		for _, c := range n {
			if directTOpSeen(c, seen) {
				return true
			}
		}
	case map[string]any:
		key := reflect.ValueOf(n).Pointer()
		if _, dup := seen[key]; dup {
			return false
		}
		seen[key] = struct{}{}
		if op, ok := n["op"].(string); ok && opInT(op) {
			return true
		}
		for _, v := range n {
			if directTOpSeen(v, seen) {
				return true
			}
		}
	}
	return false
}

// templateTargetBearing computes, for every template in `named`, its
// target-bearing flag (esm-spec §9.6.4 rule 3): a template is target-bearing iff
// its body contains an op in T anywhere (including inside nested references'
// bindings), OR it references — transitively through the §9.7.3-checked acyclic
// DAG — a target-bearing template. Mirrors the Julia `_template_target_bearing`.
func templateTargetBearing(named map[string]any) map[string]bool {
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
		res := body != nil && directTOp(body)
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

// refIsEager reports whether an `apply_expression_template` node is eager
// (esm-spec §9.6.4 rule 3): its referenced template is target-bearing, OR any of
// its `bindings` values contains an op in T. After innermost-first eager
// expansion of the bindings, a "nested eager reference" always manifests as a
// T-op in the bindings, so this subsumes that clause. Mirrors `_ref_is_eager`.
func refIsEager(node map[string]any, targetBearing map[string]bool) bool {
	name, ok := node["name"].(string)
	if !ok {
		return false
	}
	if targetBearing[name] {
		return true
	}
	b := node["bindings"]
	if b == nil {
		return false
	}
	return directTOp(b)
}

// cloneMapAny shallow-copies a map[string]any (values shared by reference).
func cloneMapAny(m map[string]any) map[string]any {
	out := make(map[string]any, len(m))
	for k, v := range m {
		out[k] = v
	}
	return out
}

// ---------------------------------------------------------------------------
// Eager-expansion pre-pass (esm-spec §9.6.4 rule 3)
// ---------------------------------------------------------------------------

type expandMemo map[uintptr]expandMemoEntry

type expandMemoEntry struct {
	out     any
	changed bool
}

// expandEager expands — by pure substitution, innermost-first — every EAGER
// `apply_expression_template` node, and only eager nodes. Non-eager (surviving)
// references are returned intact. Consumes no MaxRewritePasses budget (it is a
// separate pre-pass). Sharing is preserved via a pointer-identity memo. Mirrors
// the Julia `_expand_eager`.
func expandEager(node any, named map[string]any, targetBearing map[string]bool, scope string) (any, error) {
	out, _, err := expandEagerShared(node, named, targetBearing, scope, expandMemo{})
	return out, err
}

func expandEagerShared(node any, named map[string]any, targetBearing map[string]bool, scope string, memo expandMemo) (any, bool, error) {
	switch n := node.(type) {
	case []any:
		var out []any
		for i, c := range n {
			nc, ch, err := expandEagerShared(c, named, targetBearing, scope, memo)
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
			// Innermost-first: expand eager references inside the bindings first.
			newnode := n
			if b, ok := n["bindings"].(map[string]any); ok {
				var nb map[string]any
				for _, bk := range sortedKeys(b) {
					nbv, ch, err := expandEagerShared(b[bk], named, targetBearing, scope, memo)
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
			if refIsEager(newnode, targetBearing) {
				body, err := expandApply(newnode, named, scope)
				if err != nil {
					return nil, false, err
				}
				res, _, err := expandEagerShared(body, named, targetBearing, scope, memo)
				if err != nil {
					return nil, false, err
				}
				memo[key] = expandMemoEntry{out: res, changed: true}
				return res, true, nil
			}
			memo[key] = expandMemoEntry{out: newnode, changed: newnode != nil && !mapPtrEqual(newnode, n)}
			return newnode, !mapPtrEqual(newnode, n), nil
		}
		var out map[string]any
		for _, k := range sortedKeys(n) {
			nv, ch, err := expandEagerShared(n[k], named, targetBearing, scope, memo)
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
			memo[key] = expandMemoEntry{out: n, changed: false}
			return n, false, nil
		}
		memo[key] = expandMemoEntry{out: out, changed: true}
		return out, true, nil
	}
	return node, false, nil
}

// mapPtrEqual reports whether two map[string]any share the same underlying
// pointer (identity), used to detect whether a rebuild happened.
func mapPtrEqual(a, b map[string]any) bool {
	return reflect.ValueOf(a).Pointer() == reflect.ValueOf(b).Pointer()
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
			memo[key] = expandMemoEntry{out: res, changed: true}
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
			memo[key] = expandMemoEntry{out: n, changed: false}
			return n, false, nil
		}
		memo[key] = expandMemoEntry{out: out, changed: true}
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
		return newETErr("apply_expression_template_invalid_declaration",
			fmt.Sprintf("%s: apply_expression_template node missing 'name'", scope))
	}
	declRaw, ok := templates[name]
	if !ok {
		return newETErr("apply_expression_template_unknown_template",
			fmt.Sprintf("%s: apply_expression_template references undeclared template '%s'", scope, name))
	}
	decl, _ := declRaw.(map[string]any)
	if m, has := decl["match"]; has && m != nil {
		return newETErr("apply_expression_template_unknown_template",
			fmt.Sprintf("%s: apply_expression_template references '%s', a `match` rewrite rule — only match-less templates are invocable by name (esm-spec §9.6.2)", scope, name))
	}
	bindingsRaw, ok := node["bindings"].(map[string]any)
	if !ok {
		return newETErr("apply_expression_template_bindings_mismatch",
			fmt.Sprintf("%s: apply_expression_template '%s' missing 'bindings' object", scope, name))
	}
	declared := map[string]struct{}{}
	if pr, ok := decl["params"].([]any); ok {
		for _, p := range pr {
			if ps, ok := p.(string); ok {
				declared[ps] = struct{}{}
				if _, has := bindingsRaw[ps]; !has {
					return newETErr("apply_expression_template_bindings_mismatch",
						fmt.Sprintf("%s: apply_expression_template '%s' missing binding for param '%s'", scope, name, ps))
				}
			}
		}
	}
	for k := range bindingsRaw {
		if _, ok := declared[k]; !ok {
			return newETErr("apply_expression_template_bindings_mismatch",
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

// templateManifoldBearing reports which templates can produce a geometry-kernel
// node (geometryManifoldOps) — directly in the body or transitively through a
// referenced template. Only references to these templates need per-instantiation
// manifold validation (§9.6.9). Mirrors `_template_manifold_bearing`.
func templateManifoldBearing(named map[string]any) map[string]bool {
	var direct func(node any, seen map[uintptr]struct{}) bool
	direct = func(node any, seen map[uintptr]struct{}) bool {
		switch n := node.(type) {
		case []any:
			for _, c := range n {
				if direct(c, seen) {
					return true
				}
			}
		case map[string]any:
			key := reflect.ValueOf(n).Pointer()
			if _, dup := seen[key]; dup {
				return false
			}
			seen[key] = struct{}{}
			if op, ok := n["op"].(string); ok {
				if _, geo := geometryManifoldOps[op]; geo {
					return true
				}
			}
			for _, v := range n {
				if direct(v, seen) {
					return true
				}
			}
		}
		return false
	}
	mb := map[string]bool{}
	inprog := map[string]bool{}
	var visit func(name string) bool
	visit = func(name string) bool {
		if v, ok := mb[name]; ok {
			return v
		}
		if inprog[name] {
			return false
		}
		declRaw, ok := named[name]
		if !ok {
			mb[name] = false
			return false
		}
		decl, _ := declRaw.(map[string]any)
		inprog[name] = true
		body := decl["body"]
		res := body != nil && direct(body, map[uintptr]struct{}{})
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
		delete(inprog, name)
		mb[name] = res
		return res
	}
	for name := range named {
		visit(name)
	}
	return mb
}

// validateGeometryManifoldsRefaware discharges `geometry_manifold_invalid`
// per-instantiation (a `manifold` may be a template param), memoized (esm-spec
// §9.6.9). Direct geometry nodes in the reference-preserving tree are checked as
// before; every surviving reference whose template can produce a geometry kernel
// is additionally expanded ONCE and its expansion validated. The diagnostic
// names the call-site path and template. Mirrors `_validate_geometry_manifolds_refaware`.
func validateGeometryManifoldsRefaware(view map[string]any, registries map[string]map[string]any) error {
	if err := validateGeometryManifolds(view, ""); err != nil {
		return err
	}
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
			named, ok := registries[cname]
			if !ok {
				continue
			}
			mb := templateManifoldBearing(named)
			anyMB := false
			for _, v := range mb {
				if v {
					anyMB = true
					break
				}
			}
			if !anyMB {
				continue
			}
			memo := map[uintptr]struct{}{}
			for _, k := range sortedKeys(comp) {
				if k == "expression_templates" {
					continue
				}
				if err := validateManifoldsInRefs(comp[k], named, mb,
					fmt.Sprintf("%s.%s.%s", kind, cname, k), memo); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

func validateManifoldsInRefs(node any, named map[string]any, mb map[string]bool, path string, memo map[uintptr]struct{}) error {
	switch n := node.(type) {
	case []any:
		for i, c := range n {
			if err := validateManifoldsInRefs(c, named, mb, fmt.Sprintf("%s/%d", path, i), memo); err != nil {
				return err
			}
		}
	case map[string]any:
		key := reflect.ValueOf(n).Pointer()
		if _, dup := memo[key]; dup {
			return nil
		}
		memo[key] = struct{}{}
		name := ""
		if op, _ := n["op"].(string); op == applyExpressionTemplateOp {
			name, _ = n["name"].(string)
		}
		if name != "" && mb[name] {
			expansion, err := expandAll(n, named, path)
			if err == nil {
				if verr := validateGeometryManifolds(expansion, ""); verr != nil {
					var et *ExpressionTemplateError
					if errors.As(verr, &et) && et.Code == "geometry_manifold_invalid" {
						return newETErr("geometry_manifold_invalid",
							fmt.Sprintf("%s: instantiation of template '%s' — %s (esm-spec §9.6.9; per-instantiation manifold check)", path, name, et.Message))
					}
					return verr
				}
			}
		}
		for _, k := range sortedKeys(n) {
			if err := validateManifoldsInRefs(n[k], named, mb, path+"/"+k, memo); err != nil {
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
		for _, r := range refs {
			stack = append(stack, r)
		}
	}
	return out
}

// authoredTemplateNames returns the per-component MATCH-LESS template names
// authored in-file in origView (in source declaration order via `orders`). Emit
// keeps these verbatim as authored entries (esm-spec §9.6.4 rule 5). Mirrors
// `_authored_template_names`.
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
				d, ok := tpl[n].(map[string]any)
				if !ok {
					continue
				}
				if m, has := d["match"]; has && m != nil {
					continue
				}
				names = append(names, n)
			}
			authored[kind+"."+cname] = names
		}
	}
	return authored
}

// emitDocument produces the reference-preserving, self-contained emitted
// document (esm-spec §9.6.4 rule 5, RFC §7.5) from a source document. Loads the
// source under Option B, then for every component builds its emitted
// `expression_templates` block — authored match-less entries first in authored
// order, then the materialized transitive closure of its surviving references
// (match-less), lexicographically sorted — drops consumed
// `expression_template_imports`, and version-stamps `esm: 0.9.0` when any
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
			named := map[string]any{}
			if tpl, ok := comp["expression_templates"].(map[string]any); ok {
				for n, d := range tpl {
					named[n] = d
				}
			}
			refnames := map[string]bool{}
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
			if len(refnames) > 0 {
				bump = true
			}
			materialized := refClosure(refnames, named)
			authoredHere := authored[key]
			authoredSet := map[string]bool{}
			for _, n := range authoredHere {
				authoredSet[n] = true
			}

			emitBlock := newOrderedMap()
			for _, n := range authoredHere {
				if d, ok := named[n]; ok {
					emitBlock.set(n, d)
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
				emitBlock.set(n, named[n])
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
	if bump {
		view["esm"] = "0.9.0"
	}
	return view, nil
}

// loadOptionB resolves the §9.7 machinery and runs the Option-B lowering,
// PRESERVING surviving references and per-component registries (no Expand). This
// is the "loaded" reference-preserving form that emit and flatten consume.
func loadOptionB(jsonStr, basePath string, metaparameters map[string]int64) (map[string]any, error) {
	view, err := decodeJSONView([]byte(jsonStr))
	if err != nil {
		return nil, fmt.Errorf("loadOptionB: decode: %w", err)
	}
	orders := extractTemplateOrders(jsonStr)
	if err := applyCouplingInjections(view); err != nil {
		return nil, err
	}
	if _, err := resolveTemplateMachinery(view, orders, basePath, metaparameters); err != nil {
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

// flattenTemplateRegistries merges every component's `expression_templates`
// registry of an Option-B loaded document into a single document-scoped merged
// registry (esm-spec §9.6.4 rule 7, §10.7; esm-libraries-spec §4.7.5 step 4):
// deep-equal same-name entries dedupe at first occurrence; a non-deep-equal
// same-name collision renames BOTH to `<ComponentPath>.<name>` with references
// rewritten in lockstep. Returns the rewritten document and the merged registry
// (the FlattenedSystem's first-class registry field). Match rules are not merged.
// Mutates `view` in place. Mirrors the Julia `flatten_template_registries`.
func flattenTemplateRegistries(view map[string]any) (map[string]any, *orderedMap) {
	type compEntry struct {
		path  string
		comp  map[string]any
		named map[string]any
	}
	var comps []compEntry
	for _, kind := range templateComponentKinds {
		cs, ok := view[kind].(map[string]any)
		if !ok {
			continue
		}
		for _, cname := range sortedKeys(cs) {
			comp, ok := cs[cname].(map[string]any)
			if !ok {
				continue
			}
			named := map[string]any{}
			if tpl, ok := comp["expression_templates"].(map[string]any); ok {
				for n, d := range tpl {
					if dm, ok := d.(map[string]any); ok {
						if m, has := dm["match"]; has && m != nil {
							continue // match rules not merged
						}
					}
					named[n] = d
				}
			}
			comps = append(comps, compEntry{path: cname, comp: comp, named: named})
		}
	}

	// Group each template name across components (preserving first-seen order).
	byname := newOrderedMap()
	for _, ce := range comps {
		for _, n := range sortedKeys(ce.named) {
			var occ []any
			if ex, ok := byname.get(n).([]any); ok {
				occ = ex
			}
			occ = append(occ, [2]any{ce.path, ce.named[n]})
			byname.set(n, occ)
		}
	}

	merged := newOrderedMap()
	rename := map[string]map[string]string{} // path => (old => new)
	names := append([]string(nil), byname.keys...)
	sort.Strings(names)
	for _, name := range names {
		occ, _ := byname.get(name).([]any)
		alleq := true
		first := occ[0].([2]any)[1]
		for _, o := range occ {
			if !jsonEqual(first, o.([2]any)[1]) {
				alleq = false
				break
			}
		}
		if alleq {
			merged.set(name, first)
			continue
		}
		for _, o := range occ {
			path := o.([2]any)[0].(string)
			decl := o.([2]any)[1]
			newname := path + "." + name
			merged.set(newname, decl)
			if rename[path] == nil {
				rename[path] = map[string]string{}
			}
			rename[path][name] = newname
		}
	}

	// Rewrite reference sites in lockstep (component expression positions and the
	// carried bodies of the renamed entries), then surrender the per-component
	// blocks to the merged registry.
	for _, ce := range comps {
		rn := rename[ce.path]
		if rn != nil {
			for _, k := range sortedKeys(ce.comp) {
				if k == "expression_templates" {
					continue
				}
				ce.comp[k] = renameApplyRefs(ce.comp[k], rn)
			}
			for _, newname := range rn {
				if merged.has(newname) {
					merged.set(newname, renameApplyRefs(merged.get(newname), rn))
				}
			}
		}
		delete(ce.comp, "expression_templates")
	}

	return view, merged
}
