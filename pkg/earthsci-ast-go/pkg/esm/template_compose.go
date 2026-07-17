package esm

import (
	"fmt"
	"sort"
	"strings"
)

// ---------------------------------------------------------------------------
// Registration-time body composition (esm-spec §9.7.3)
// ---------------------------------------------------------------------------

// collectApplyNames accumulates the `name` of every
// `apply_expression_template` node reachable in x into out. Used by
// composeTemplateBodies to build the template-body reference graph (esm-spec
// §9.7.3).
func collectApplyNames(out *[]string, x any) {
	switch v := x.(type) {
	case []any:
		for _, c := range v {
			collectApplyNames(out, c)
		}
	case map[string]any:
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

// composeTemplateBodies performs registration-time body CHECKING (esm-spec
// §9.7.3, Option B / esm 0.9.0): template bodies MAY reference other in-scope
// MATCH-LESS templates via `apply_expression_template` nodes. Builds the
// body-reference graph, rejects cycles
// (`apply_expression_template_recursive_body`), references to undeclared or
// `match`-bearing templates (`apply_expression_template_unknown_template`), and
// chains deeper than MaxTemplateExpansionDepth templates
// (`template_body_expansion_too_deep`).
//
// From esm 0.9.0 (RFC out-of-line-expression-templates §7.1 step 4) bodies are
// **NOT inlined** — the references are preserved uninlined and denote their
// expansion (§9.6.4 rule 2). Target-bearing flags (§9.6.4 rule 3) are computed
// separately by templateTargetBearing. This runs BEFORE the §9.6.3 fixpoint
// ever consults a `match` rule; it now only validates the DAG. Mirrors the
// Julia reference `_compose_template_bodies!`.
func composeTemplateBodies(templates map[string]any, scope string) error {
	if len(templates) == 0 {
		return nil
	}
	refs := map[string][]string{}
	anyRefs := false
	for name, declRaw := range templates {
		var names []string
		if decl, ok := declRaw.(map[string]any); ok {
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
			if tdecl, ok := tdeclRaw.(map[string]any); ok {
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

	// esm 0.9.0 (Option B): DO NOT inline. The DAG has been checked (acyclic,
	// depth-bounded, references resolve to match-less templates); the bodies are
	// left with their `apply_expression_template` references intact. Expand
	// (§9.6.4 rule 2) or the eager pre-pass (§9.6.4 rule 3) consume them later.
	_ = order
	return nil
}
