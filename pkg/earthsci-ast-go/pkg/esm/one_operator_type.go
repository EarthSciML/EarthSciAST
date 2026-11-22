package esm

// esm 2.4.0 "one operator type" (esm-spec §4.2, §9.6.1–9.6.3, §9.6.12): every
// `op` is either a CORE operator (the closed §4.2 set every evaluator
// implements) or a DEFINED operator (any other name, given by the definitions
// — entries of an `operators` block — in scope). A call of a defined operator
// resolves at load to a reference to one of its definitions; a name with no
// definition in scope is a placeholder. This file holds the registration-side
// helpers the rewrite engine (lower_expression_templates.go) shares: the core
// set, `defines`, the core-name reservation, call rules, selection order and
// the arity check. Mirrors the Julia `templates/rewrite.jl`.

import (
	"fmt"
	"sort"
	"strings"
)

// coreOps is the closed esm-spec §4.2 core-operator set (the Julia
// op_registry.jl `_OP_TABLE` name set).
var coreOps = func() map[string]struct{} {
	out := map[string]struct{}{"distinct": {}}
	for k := range evaluableCoreOps {
		if k == "call" { // a retired closure marker, not a core op
			continue
		}
		out[k] = struct{}{}
	}
	return out
}()

// isCoreOp reports whether op names a core operator (esm-spec §4.2). Every
// other op names a defined operator (§9.6.12).
func isCoreOp(op string) bool {
	_, ok := coreOps[op]
	return ok
}

// matchRootOp returns the root `op` of a definition's `match`, or "".
func matchRootOp(decl map[string]any) (string, bool) {
	m, ok := decl["match"].(map[string]any)
	if !ok {
		return "", false
	}
	op, ok := m["op"].(string)
	return op, ok
}

// definitionDefines is the defined operator an `operators` entry is a
// definition of (esm-spec §9.6.1 `defines`): its written `defines`; else the
// root `op` of its `match` when that is not a core op; else its key.
func definitionDefines(name string, decl map[string]any) string {
	if d, ok := decl["defines"].(string); ok {
		return d
	}
	if r, ok := matchRootOp(decl); ok && !isCoreOp(r) {
		return r
	}
	return name
}

// checkDefinesNotCore is esm-spec §9.6.12 "Core names are reserved": a
// definition whose `defines`, written or inferred, is a core operator's name
// is `operator_defines_core_op`. A rule whose `match` is rooted at a core op
// defines no callable name, so its `defines` is provenance only and is not
// checked.
func checkDefinesNotCore(name string, decl map[string]any, scope string) error {
	if r, ok := matchRootOp(decl); ok && isCoreOp(r) {
		return nil
	}
	d := definitionDefines(name, decl)
	if isCoreOp(d) {
		return newETErr(codeOperatorDefinesCoreOp, fmt.Sprintf(
			"%s.operators.%s: defines the core operator '%s'; a definition may not define a "+
				"core operator's name (esm-spec §9.6.12, \"Core names are reserved\")", scope, name, d))
	}
	return nil
}

// withDefines returns decl carrying its `defines` (inferred under name when
// absent), as a copy; decl itself when it already carries one.
func withDefines(name string, decl any) any {
	m, ok := decl.(map[string]any)
	if !ok {
		return decl
	}
	if _, has := m["defines"]; has {
		return decl
	}
	nd := cloneMapAny(m)
	nd["defines"] = definitionDefines(name, m)
	return nd
}

// onlyOpArgs reports whether n is a call shape a match-less definition can
// bind: an `op` and `args`, no other field (esm-spec §9.6.3 constraint 2).
func onlyOpArgs(n map[string]any) bool {
	for k := range n {
		if k != "op" && k != "args" {
			return false
		}
	}
	return true
}

// selectionLess is the §9.6.3 selection order: highest `priority`, then a
// definition carrying a `where` before one without (esm 2.4.0), then
// declaration order.
func selectionLess(a, b *matchRule) bool {
	if a.priority != b.priority {
		return a.priority > b.priority
	}
	aw, bw := a.whereC != nil, b.whereC != nil
	if aw != bw {
		return aw
	}
	return a.declIdx < b.declIdx
}

// selectDefinition is the definition that resolves node n (esm-spec §9.6.3
// constraint 2, §9.6.12): among the `match` rules whose pattern matches and
// the match-less definitions of the defined operator op that take n's
// operands, those whose `where` holds, the first in selection order.
func selectDefinition(L *lowering, n map[string]any, op string, bv *bodyView) (*matchRule, map[string]any) {
	var best *matchRule
	var bestB map[string]any
	for i := range L.rules {
		rule := &L.rules[i]
		b := map[string]any{}
		if matchPattern(rule.pattern, n, rule.params, b, bv) && whereSatisfied(rule.whereC, b, L.shapeEnv, bv) {
			best, bestB = rule, b
			break
		}
	}
	if op == "" {
		return best, bestB
	}
	calls := L.callRules[op]
	if len(calls) == 0 || !onlyOpArgs(n) {
		return best, bestB
	}
	for i := range calls {
		rule := &calls[i]
		if best != nil && selectionLess(best, rule) {
			break
		}
		b := map[string]any{}
		if matchPattern(rule.pattern, n, rule.params, b, bv) && whereSatisfied(rule.whereC, b, L.shapeEnv, bv) {
			best, bestB = rule, b
			break
		}
	}
	return best, bestB
}

// checkCallArity is esm-spec §9.6.12 "Arity": a call of a defined operator N
// that survives the fixpoint, when definitions of N are in scope and none
// takes the call's operand count, is `operator_arity_mismatch` at load. A name
// with no definition in scope is a placeholder, whatever its arity.
func checkCallArity(node any, arities map[string]map[int]bool, scope string) error {
	if len(arities) == 0 {
		return nil
	}
	var err error
	seen := map[uintptr]struct{}{}
	var walk func(x any)
	walk = func(x any) {
		if err != nil {
			return
		}
		switch v := x.(type) {
		case []any:
			for _, c := range v {
				walk(c)
			}
		case map[string]any:
			p := mapPtr(v)
			if _, dup := seen[p]; dup {
				return
			}
			seen[p] = struct{}{}
			if op, ok := v["op"].(string); ok {
				if counts, has := arities[op]; has && !isCoreOp(op) {
					k := 0
					if args, ok := v["args"].([]any); ok {
						k = len(args)
					}
					if !counts[k] {
						ks := make([]int, 0, len(counts))
						for c := range counts {
							ks = append(ks, c)
						}
						sort.Ints(ks)
						strs := make([]string, len(ks))
						for i, c := range ks {
							strs[i] = fmt.Sprint(c)
						}
						err = newETErr(codeOperatorArityMismatch, fmt.Sprintf(
							"%s: a call of the defined operator '%s' carries %d operand(s), but its "+
								"definitions in scope take %s (esm-spec §9.6.12)",
							scope, op, k, strings.Join(strs, ", ")))
						return
					}
				}
			}
			for _, k := range sortedKeys(v) {
				walk(v[k])
			}
		}
	}
	walk(node)
	return err
}

// reachedDefinitions adds to out the registry entries node's references
// reach, transitively through bodies.
func reachedDefinitions(out map[string]bool, node any, named map[string]any) {
	_ = visitApplyNodes(node, func(n map[string]any) error {
		r, _ := n["name"].(string)
		if r == "" || out[r] {
			return nil
		}
		d, ok := named[r].(map[string]any)
		if !ok {
			return nil
		}
		out[r] = true
		reachedDefinitions(out, d["body"], named)
		return nil
	})
}

// checkComponentArity runs checkCallArity over a component's fields (all but
// `operators`), the coupling transforms it receives, and the bodies of every
// registry entry those reach (sorted by name), as the Julia reference does
// after rule 3 and the surviving-reference checks.
func checkComponentArity(comp map[string]any, L *lowering, transforms []map[string]any) error {
	if len(L.arities) == 0 {
		return nil
	}
	reached := map[string]bool{}
	for _, k := range sortedKeys(comp) {
		if k == "operators" {
			continue
		}
		if err := checkCallArity(comp[k], L.arities, L.scope+"."+k); err != nil {
			return err
		}
		reachedDefinitions(reached, comp[k], L.named)
	}
	for _, entry := range transforms {
		if err := checkCallArity(entry["transform"], L.arities, L.scope+" coupling transform"); err != nil {
			return err
		}
		reachedDefinitions(reached, entry["transform"], L.named)
	}
	names := make([]string, 0, len(reached))
	for r := range reached {
		names = append(names, r)
	}
	sort.Strings(names)
	for _, r := range names {
		d, _ := L.named[r].(map[string]any)
		if err := checkCallArity(d["body"], L.arities, L.scope+".operators."+r); err != nil {
			return err
		}
	}
	return nil
}
