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

// inlineApplies replaces every `apply_expression_template` node in node with the
// referenced template's (already-closed) body by post-order expandApply
// (esm-spec §9.7.3 registration-time body composition). Because referenced
// bodies are inlined dependencies-first, one pass yields an apply-free subtree.
// Returns a new tree; node is not mutated.
func inlineApplies(node any, templates map[string]any, scope string) (any, error) {
	switch v := node.(type) {
	case []any:
		out := make([]any, len(v))
		for i, c := range v {
			nc, err := inlineApplies(c, templates, scope)
			if err != nil {
				return nil, err
			}
			out[i] = nc
		}
		return out, nil
	case map[string]any:
		out := make(map[string]any, len(v))
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

	for _, name := range order {
		if len(refs[name]) == 0 {
			continue
		}
		decl, ok := templates[name].(map[string]any)
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
