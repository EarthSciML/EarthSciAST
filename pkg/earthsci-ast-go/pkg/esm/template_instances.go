package esm

// Rewriting inside template bodies, once per template instance (esm-spec
// §9.6.4 rule 3). After a component's expression positions reach their §9.6.3
// fixpoint (where every firing wrote a reference, constraint 7), the
// component's rules, and its `enum` lowering, apply inside the bodies of the
// templates its references reach — without expanding any reference.
//
// An instance is a template plus, per parameter, the literal bound to it when
// the parameter sits in a structural position of the body, and otherwise the
// kind of what is bound (a bare variable with its declared shape, a literal,
// any other expression). Each instance's body is rewritten once; inside it a
// parameter is a leaf (bodyView). When every reachable instance of a template
// rewrites to the same body, that body replaces the template's in place —
// unless a registry entry rule 3 leaves as authored still references the
// template, directly or through such entries; otherwise each distinct body
// becomes `<name>.variant<k>`, numbered by
// canonical bytes, and every reference is re-pointed to the entry of its
// instance. Mirrors the Julia reference EarthSciAST.jl/src/templates/instances.jl.

import (
	"fmt"
	"reflect"
	"sort"
	"strings"
)

// ---------------------------------------------------------------------------
// Canonical bytes (CONFORMANCE_SPEC §5.5.3): compact JSON, keys sorted
// ---------------------------------------------------------------------------

// canonicalCompact is the canonical byte form of a raw JSON value
// (CONFORMANCE_SPEC §5.5.3): compact (`,` and `:` separators), object keys
// sorted by UTF-8 bytes at every level, integral int64-representable numbers
// written as integers (§5.5.3.1 rule 1), other numbers in the shortest
// round-trip form the emit writer uses. Orders the variants of §9.6.4 rule 3.
// Mirrors the Julia `_canonical_compact`.
func canonicalCompact(x any) string {
	var b strings.Builder
	canonicalCompactWrite(&b, x)
	return b.String()
}

func canonicalCompactWrite(b *strings.Builder, x any) {
	switch v := x.(type) {
	case map[string]any:
		b.WriteByte('{')
		for i, k := range sortedKeys(v) {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(emitJSONString(k))
			b.WriteByte(':')
			canonicalCompactWrite(b, v[k])
		}
		b.WriteByte('}')
	case *orderedMap:
		keys := append([]string(nil), v.keys...)
		sort.Strings(keys)
		b.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(emitJSONString(k))
			b.WriteByte(':')
			canonicalCompactWrite(b, v.m[k])
		}
		b.WriteByte('}')
	case []any:
		b.WriteByte('[')
		for i, e := range v {
			if i > 0 {
				b.WriteByte(',')
			}
			canonicalCompactWrite(b, e)
		}
		b.WriteByte(']')
	case []string:
		b.WriteByte('[')
		for i, e := range v {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(emitJSONString(e))
		}
		b.WriteByte(']')
	default:
		b.WriteString(emitScalar(x))
	}
}

// ---------------------------------------------------------------------------
// Small raw-JSON helpers
// ---------------------------------------------------------------------------

// isApplyMap reports whether m is an `apply_expression_template` node.
func isApplyMap(m map[string]any) bool {
	op, _ := m["op"].(string)
	return op == applyExpressionTemplateOp
}

// templateParams is a declaration's `params`, in declared order.
func templateParams(decl map[string]any) []string {
	pr, _ := decl["params"].([]any)
	out := make([]string, 0, len(pr))
	for _, p := range pr {
		if ps, ok := p.(string); ok {
			out = append(out, ps)
		}
	}
	return out
}

func mapPtr(m map[string]any) uintptr { return reflect.ValueOf(m).Pointer() }

// visitApplyNodes calls fn on every `apply_expression_template` node of x in
// pre-order (object keys in sorted order), each object identity once,
// descending into every field (a reference's `bindings` included). A non-nil
// error from fn stops the walk.
func visitApplyNodes(x any, fn func(map[string]any) error) error {
	seen := map[uintptr]struct{}{}
	var walk func(x any) error
	walk = func(x any) error {
		switch v := x.(type) {
		case []any:
			for _, c := range v {
				if err := walk(c); err != nil {
					return err
				}
			}
		case map[string]any:
			key := mapPtr(v)
			if _, dup := seen[key]; dup {
				return nil
			}
			seen[key] = struct{}{}
			if isApplyMap(v) {
				if err := fn(v); err != nil {
					return err
				}
			}
			for _, k := range sortedKeys(v) {
				if err := walk(v[k]); err != nil {
					return err
				}
			}
		}
		return nil
	}
	return walk(x)
}

// isJSONNumber reports whether v is a JSON number (json.Number or a native
// numeric type).
func isJSONNumber(v any) bool {
	_, ok := asNumber(v)
	return ok
}

// ---------------------------------------------------------------------------
// Instances
// ---------------------------------------------------------------------------

// shapeEntry is the instance entry of a bare variable with declared shape.
func shapeEntry(shape []string) string { return "V" + canonicalCompact(shape) }

// Fields whose value is an Expression (an operand position): a parameter
// string there is an operand; anywhere else it is structural.
var operandFields = map[string]bool{"expr": true, "filter": true, "key": true, "lower": true, "upper": true}
var operandListFields = map[string]bool{"args": true, "values": true}

// structuralParams is the set of parameters of a template that occur in a
// structural position of `body` (esm-spec §9.6.4 rule 3): anywhere but an
// operand position — a scalar field (`wrt`, `dim`, `fn`, …), a `ranges` bound
// or `from`, an `enum` argument. An operand position is an element of `args` or
// `values` (but not an `enum` op's `args`), the value of `expr`, `filter`,
// `key`, `lower` or `upper`, a value of a nested reference's `bindings`, or
// the body itself. Mirrors the Julia `_structural_params`.
func structuralParams(body any, params []string) map[string]struct{} {
	P := map[string]struct{}{}
	for _, p := range params {
		P[p] = struct{}{}
	}
	out := map[string]struct{}{}
	structuralWalk(out, body, P, true)
	return out
}

func structuralWalk(out map[string]struct{}, x any, P map[string]struct{}, operand bool) {
	switch v := x.(type) {
	case string:
		if _, ok := P[v]; ok && !operand {
			out[v] = struct{}{}
		}
	case []any:
		for _, c := range v {
			structuralWalk(out, c, P, operand)
		}
	case map[string]any:
		op, _ := v["op"].(string)
		for k, c := range v {
			switch {
			case k == "op" || (k == "name" && op == applyExpressionTemplateOp):
				continue
			case k == "bindings" && op == applyExpressionTemplateOp:
				if bm, ok := c.(map[string]any); ok {
					for _, bvv := range bm {
						structuralWalk(out, bvv, P, true)
					}
				} else {
					structuralWalk(out, c, P, false)
				}
			case operandListFields[k] && op != OpEnum:
				structuralWalk(out, c, P, true)
			case operandFields[k]:
				structuralWalk(out, c, P, true)
			default:
				structuralWalk(out, c, P, false)
			}
		}
	}
}

// instanceEntry is the instance entry (esm-spec §9.6.4 rule 3) for one
// parameter bound to `v`: inside a body (`bv`), a binding that is one of the
// body's own parameters forwards the enclosing instance's entry; a structural
// parameter takes the literal bound (`"L"` + canonical bytes); otherwise the
// kind — `"V"` + shape for a bare variable with a declared shape, `"V"` for
// one without, `"N"` for a number or boolean literal, `"E"` for any other
// expression. The second and third results are the value a structural
// position reads, and whether there is one. Mirrors `_instance_entry`.
func instanceEntry(v any, structural bool, L *lowering, bv *bodyView) (string, any, bool) {
	if s, ok := v.(string); ok && bv.isParam(s) {
		lit, has := bv.lit[s]
		return bv.entries[s], lit, has
	}
	_, isStr := v.(string)
	_, isBool := v.(bool)
	isNum := isJSONNumber(v)
	if structural {
		if isStr || isNum || isBool {
			return "L" + canonicalCompact(v), v, true
		}
		return "E", nil, false
	}
	if s, ok := v.(string); ok {
		if shp, ok := L.shapeEnv[s]; ok {
			return shapeEntry(shp), nil, false
		}
		return "V", nil, false
	}
	if isNum || isBool {
		return "N", nil, false
	}
	return "E", nil, false
}

// instRef is one entry of an instanceResult's reference map: the reference
// node (held by identity) and the instance key it names.
type instRef struct {
	node map[string]any
	key  string
}

// instanceResult is one rewritten template instance: the template's `name`,
// the body as rule 3 rewrote it (references not yet re-pointed to variants),
// the instance key of every reference in that body (by node identity), and its
// height — the deepest rewrite depth below the reference that names it (own
// passes, or a written reference's pass plus the height of the instance it
// names). Mirrors the Julia `_InstanceResult`.
type instanceResult struct {
	key    string
	name   string
	body   any
	refs   map[uintptr]instRef
	height int
}

type rule3State struct {
	L          *lowering
	done       map[string]*instanceResult
	active     map[string]bool
	structural map[string]map[string]struct{}
	order      []string
}

// templateStructural is the structural parameters of template `name`
// (structuralParams), plus each parameter forwarded whole into a structural
// parameter of a template its body references (transitively): through the
// reference the parameter reaches a structural position of the expansion.
// Mirrors the Julia `_template_structural!`.
func (st *rule3State) templateStructural(name string, decl map[string]any) map[string]struct{} {
	if r, ok := st.structural[name]; ok {
		return r
	}
	params := templateParams(decl)
	S := structuralParams(decl["body"], params)
	st.structural[name] = S // a cycle reads the direct set
	P := map[string]struct{}{}
	for _, p := range params {
		P[p] = struct{}{}
	}
	_ = visitApplyNodes(decl["body"], func(n map[string]any) error {
		inner, ok := n["name"].(string)
		if !ok {
			return nil
		}
		b, ok := n["bindings"].(map[string]any)
		if !ok {
			return nil
		}
		idecl, ok := st.L.named[inner].(map[string]any)
		if !ok {
			return nil
		}
		IS := st.templateStructural(inner, idecl)
		for k, v := range b {
			vs, ok := v.(string)
			if !ok {
				continue
			}
			if _, inP := P[vs]; !inP {
				continue
			}
			if _, inIS := IS[k]; inIS {
				S[vs] = struct{}{}
			}
		}
		return nil
	})
	return S
}

func nonterminating(scope, msg string) error {
	return newETErr(CodeRewriteRuleNonterminating, fmt.Sprintf("%s: %s (esm-spec §9.6.4 rule 3)", scope, msg))
}

// resolveApplySite is the one call-site resolution: `name` present, declared
// in `templates`, `bindings` an object covering the declaration's `params`
// exactly. `rejectMatchRule` additionally rejects a reference to a `match`
// rewrite rule (only match-less templates are invocable by name, esm-spec
// §9.6.2). Mirrors the Julia `_resolve_apply_site`.
func resolveApplySite(node map[string]any, templates map[string]any, scope string, rejectMatchRule bool) (string, map[string]any, map[string]any, error) {
	if rejectMatchRule {
		if err := validateApplyRef(node, templates, scope); err != nil {
			return "", nil, nil, err
		}
	} else {
		name, ok := node["name"].(string)
		if !ok || name == "" {
			return "", nil, nil, newETErr(CodeApplyExpressionTemplateInvalidDeclaration,
				fmt.Sprintf("%s: apply_expression_template node missing 'name'", scope))
		}
		if _, ok := templates[name]; !ok {
			return "", nil, nil, newETErr(CodeApplyExpressionTemplateUnknownTemplate,
				fmt.Sprintf("%s: apply_expression_template references undeclared template '%s'", scope, name))
		}
		// The bindings check is validateApplyRef's, on a declaration whose
		// `match` it does not look at.
		decl, _ := templates[name].(map[string]any)
		stripped := matchStripped(decl)
		if err := validateApplyRef(node, map[string]any{name: stripped}, scope); err != nil {
			return "", nil, nil, err
		}
	}
	name := node["name"].(string)
	decl, _ := templates[name].(map[string]any)
	b, _ := node["bindings"].(map[string]any)
	return name, decl, b, nil
}

// refInstance is the rewritten instance a reference `n` names, computed once
// per instance. A reference the author wrote must name a match-less template
// (§9.6.2); one a firing wrote (it has a depth) names its rule. `bv` is the
// enclosing body's view when `n` sits in a template body, nil at a call site.
// Mirrors the Julia `_ref_instance!`.
func (st *rule3State) refInstance(n map[string]any, bv *bodyView, scope string) (*instanceResult, error) {
	_, written := st.L.depthOf(n)
	name, decl, b, err := resolveApplySite(n, st.L.named, scope, !written)
	if err != nil {
		return nil, err
	}
	params := templateParams(decl)
	S := st.templateStructural(name, decl)
	entries := make([]string, 0, len(params))
	lits := map[string]any{}
	for _, p := range params {
		_, isStruct := S[p]
		e, l, has := instanceEntry(b[p], isStruct, st.L, bv)
		entries = append(entries, e)
		if has {
			lits[p] = l
		}
	}
	return st.instance(name, decl, params, entries, lits)
}

func (st *rule3State) instance(name string, decl map[string]any, params, entries []string, lits map[string]any) (*instanceResult, error) {
	key := strings.Join(append([]string{name}, entries...), "\x1f")
	if r, ok := st.done[key]; ok {
		return r, nil
	}
	tscope := st.L.scope + ".expression_templates." + name
	if st.active[key] {
		return nil, nonterminating(tscope, fmt.Sprintf(
			"rewriting template '%s' needs the same template instance again — a `match` rule re-introduces its own pattern through the template's body", name))
	}
	st.active[key] = true
	bv := &bodyView{params: map[string]struct{}{}, lit: lits, entries: map[string]string{}}
	for i, p := range params {
		bv.params[p] = struct{}{}
		bv.entries[p] = entries[i]
	}
	body, err := lowerBodyEnums(decl["body"], bv, st.L.enums)
	if err != nil {
		return nil, err
	}
	rewritten, passes, err := rewriteToFixpoint(body, st.L, tscope, bv)
	if err != nil {
		return nil, err
	}
	refs := map[uintptr]instRef{}
	height := passes
	err = visitApplyNodes(rewritten, func(n map[string]any) error {
		child, err := st.refInstance(n, bv, tscope)
		if err != nil {
			return err
		}
		refs[mapPtr(n)] = instRef{node: n, key: child.key}
		d, _ := st.L.depthOf(n)
		if d+child.height > height {
			height = d + child.height
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if height > MaxRewritePasses {
		return nil, nonterminating(tscope, fmt.Sprintf(
			"a rewrite inside template '%s' has depth %d, beyond MAX_REWRITE_PASSES=%d (depth counts through template bodies)", name, height, MaxRewritePasses))
	}
	delete(st.active, key)
	res := &instanceResult{key: key, name: name, body: rewritten, refs: refs, height: height}
	st.done[key] = res
	st.order = append(st.order, key)
	return res, nil
}

// lowerBodyEnums is the `enum` lowering of esm-spec §9.3 applied inside a
// template body for one instance (§9.6.4 rule 3): an `enum` op whose two
// arguments are strings, or parameters the instance binds to strings, becomes
// its `const`; one still spelled with an unbound parameter stays as written.
// Identity-preserving. Mirrors the Julia `_lower_body_enums`.
func lowerBodyEnums(body any, bv *bodyView, enums map[string]map[string]int) (any, error) {
	var walk func(x any) (any, bool, error)
	walk = func(x any) (any, bool, error) {
		switch v := x.(type) {
		case []any:
			var out []any
			for i, c := range v {
				nc, ch, err := walk(c)
				if err != nil {
					return nil, false, err
				}
				if ch && out == nil {
					out = make([]any, len(v))
					copy(out, v[:i])
				}
				if out != nil {
					out[i] = nc
				}
			}
			if out == nil {
				return v, false, nil
			}
			return out, true, nil
		case map[string]any:
			if op, _ := v["op"].(string); op == OpEnum {
				args, ok := v["args"].([]any)
				if !ok || len(args) != 2 {
					return v, false, nil
				}
				resolved := make([]any, 2)
				for i, a := range args {
					s, isStr := a.(string)
					if isStr && bv.isParam(s) {
						lit, has := bv.lit[s]
						if !has {
							return v, false, nil
						}
						resolved[i] = lit
					} else {
						resolved[i] = a
					}
					if _, ok := resolved[i].(string); !ok {
						return v, false, nil
					}
				}
				n2 := cloneMapAny(v)
				n2["args"] = resolved
				out, err := lowerRawEnumOps(n2, enums, nil)
				if err != nil {
					return nil, false, err
				}
				return out, true, nil
			}
			var out map[string]any
			for _, k := range sortedKeys(v) {
				nv, ch, err := walk(v[k])
				if err != nil {
					return nil, false, err
				}
				if ch {
					if out == nil {
						out = cloneMapAny(v)
					}
					out[k] = nv
				}
			}
			if out == nil {
				return v, false, nil
			}
			return out, true, nil
		}
		return x, false, nil
	}
	out, _, err := walk(body)
	return out, err
}

// repointRefs is `x` with every reference re-pointed to the entry its instance
// was given: `refs` maps a reference node (by identity) to its instance key,
// `final` an instance key to the registry name its body lives under.
// Identity-preserving. Mirrors the Julia `_repoint_refs`.
func repointRefs(x any, refs map[uintptr]instRef, final map[string]string) any {
	memo := map[uintptr]any{}
	var walk func(x any) (any, bool)
	walk = func(x any) (any, bool) {
		switch v := x.(type) {
		case []any:
			var out []any
			for i, c := range v {
				nc, ch := walk(c)
				if ch && out == nil {
					out = make([]any, len(v))
					copy(out, v[:i])
				}
				if out != nil {
					out[i] = nc
				}
			}
			if out == nil {
				return v, false
			}
			return out, true
		case map[string]any:
			key := mapPtr(v)
			if r, hit := memo[key]; hit {
				rm, _ := r.(map[string]any)
				return r, rm == nil || mapPtr(rm) != key
			}
			var out map[string]any
			for _, k := range sortedKeys(v) {
				if k == "name" && isApplyMap(v) {
					continue
				}
				nv, ch := walk(v[k])
				if ch {
					if out == nil {
						out = cloneMapAny(v)
					}
					out[k] = nv
				}
			}
			if isApplyMap(v) {
				if r, ok := refs[key]; ok {
					if newname, ok := final[r.key]; ok && newname != "" {
						if cur, _ := v["name"].(string); cur != newname {
							if out == nil {
								out = cloneMapAny(v)
							}
							out["name"] = newname
						}
					}
				}
			}
			if out == nil {
				memo[key] = v
				return v, false
			}
			memo[key] = out
			return out, true
		}
		return x, false
	}
	out, _ := walk(x)
	return out
}

// matchStripped is a declaration without its `match`, `where` and `priority`:
// how a referenced rule is materialized (esm-spec §9.6.4 rule 3).
func matchStripped(decl map[string]any) map[string]any {
	out := make(map[string]any, len(decl))
	for k, v := range decl {
		if k == "match" || k == "where" || k == "priority" {
			continue
		}
		out[k] = v
	}
	return out
}

func declHasMatch(decl map[string]any) bool {
	m, has := decl["match"]
	return has && m != nil
}

// rule3Multi is the templates whose reached instances rewrite to more than one
// distinct body. Naming each single-bodied template in place or as
// `<name>.variant1` renames every reference to it alike, so which bodies are
// distinct does not depend on that choice: this provisional pass names every
// single-bodied template in place. Mirrors the Julia `_rule3_multi`.
func (st *rule3State) rule3Multi(byTemplate map[string][]string, order []string) map[string]bool {
	final := map[string]string{}
	multi := map[string]bool{}
	for _, t := range order {
		keysT := byTemplate[t]
		canon := make([]string, len(keysT))
		for i, k := range keysT {
			canon[i] = canonicalCompact(repointRefs(st.done[k].body, st.done[k].refs, final))
		}
		set := map[string]bool{}
		var distinct []string
		for _, c := range canon {
			if !set[c] {
				set[c] = true
				distinct = append(distinct, c)
			}
		}
		if len(distinct) == 1 {
			for _, k := range keysT {
				final[k] = t
			}
			continue
		}
		sort.Strings(distinct)
		multi[t] = true
		for i, k := range keysT {
			final[k] = fmt.Sprintf("%s\x1f%d", t, sort.SearchStrings(distinct, canon[i])+1)
		}
	}
	return multi
}

// rule3Exposed is the reached match-less templates whose authored body stays
// reachable from a registry entry that rule 3 does not rewrite under its own
// name (esm-spec §9.6.4 rule 3): a match-less entry no reference reaches, one
// whose instances took variants, and, transitively, any reached template such
// an entry references. Such a template keeps its authored body; a single
// rewritten body is registered as `<name>.variant1` instead. Mirrors the Julia
// `_rule3_exposed`.
func (st *rule3State) rule3Exposed(byTemplate map[string][]string, order []string) map[string]bool {
	named := st.L.named
	matchless := func(n string) bool {
		d, ok := named[n].(map[string]any)
		return ok && !declHasMatch(d)
	}
	memo := map[string][]string{}
	refsOf := func(n string) []string {
		if r, ok := memo[n]; ok {
			return r
		}
		var names []string
		if d, ok := named[n].(map[string]any); ok {
			collectApplyNames(&names, d["body"])
		}
		var r []string
		for _, x := range names {
			if _, reached := byTemplate[x]; reached && matchless(x) {
				r = append(r, x)
			}
		}
		memo[n] = r
		return r
	}
	var stack []string
	for n := range named {
		if _, reached := byTemplate[n]; !reached && matchless(n) {
			stack = append(stack, n)
		}
	}
	needMulti := false
	for t := range byTemplate {
		if matchless(t) && len(refsOf(t)) > 0 {
			needMulti = true
			break
		}
	}
	if needMulti {
		for t := range st.rule3Multi(byTemplate, order) {
			if matchless(t) {
				stack = append(stack, t)
			}
		}
	}
	visible := map[string]bool{}
	for len(stack) > 0 {
		n := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		for _, r := range refsOf(n) {
			if !visible[r] {
				visible[r] = true
				stack = append(stack, r)
			}
		}
	}
	return visible
}

// rule3TemplateOrder is the template-level order in which instances are
// named: a template after every template its instances' bodies reference. A
// cycle is a rule that re-introduces itself through a template body. Mirrors
// the Julia `_rule3_template_order`.
func (st *rule3State) rule3TemplateOrder(templates []string, byTemplate map[string][]string) ([]string, error) {
	deps := map[string][]string{}
	for _, t := range templates {
		seen := map[string]bool{}
		var ds []string
		for _, k := range byTemplate[t] {
			refs := st.done[k].refs
			ptrs := make([]uintptr, 0, len(refs))
			for p := range refs {
				ptrs = append(ptrs, p)
			}
			sort.Slice(ptrs, func(i, j int) bool { return refs[ptrs[i]].key < refs[ptrs[j]].key })
			for _, p := range ptrs {
				dn := st.done[refs[p].key].name
				if !seen[dn] {
					seen[dn] = true
					ds = append(ds, dn)
				}
			}
		}
		deps[t] = ds
	}
	var order []string
	state := map[string]int{}
	var visit func(t string) error
	visit = func(t string) error {
		switch state[t] {
		case 2:
			return nil
		case 1:
			return nonterminating(st.L.scope, fmt.Sprintf(
				"template '%s' reaches itself through the references rules wrote in template bodies", t))
		}
		state[t] = 1
		for _, d := range deps[t] {
			if err := visit(d); err != nil {
				return err
			}
		}
		state[t] = 2
		order = append(order, t)
		return nil
	}
	for _, t := range templates {
		if err := visit(t); err != nil {
			return nil, err
		}
	}
	return order, nil
}

// applyRule3 is esm-spec §9.6.4 rule 3 for one component whose expression
// positions (and the coupling `transforms` it receives, `variable_map`
// entries) have reached the §9.6.3 fixpoint: rewrite the body of every
// template instance their references reach, place each result (in place, or as
// `<name>.variant<k>`), re-point the references, materialize each referenced
// `match` rule without its `match`, `where` and `priority`, and check the
// rewrite depth of every call site. Mirrors the Julia `_apply_rule3!`.
func applyRule3(comp map[string]any, L *lowering, transforms []map[string]any) error {
	st := &rule3State{
		L: L, done: map[string]*instanceResult{}, active: map[string]bool{},
		structural: map[string]map[string]struct{}{},
	}
	type site struct {
		holder map[string]any
		key    string
		scope  string
	}
	var sites []site
	for _, k := range sortedKeys(comp) {
		if k == "expression_templates" || k == "expression_template_imports" {
			continue
		}
		sites = append(sites, site{comp, k, L.scope + "." + k})
	}
	for _, e := range transforms {
		sites = append(sites, site{e, "transform", L.scope + " coupling transform"})
	}
	siteRefs := map[uintptr]instRef{}
	for _, s := range sites {
		err := visitApplyNodes(s.holder[s.key], func(n map[string]any) error {
			res, err := st.refInstance(n, nil, s.scope)
			if err != nil {
				return err
			}
			siteRefs[mapPtr(n)] = instRef{node: n, key: res.key}
			d, _ := L.depthOf(n)
			if d+res.height > MaxRewritePasses {
				return nonterminating(s.scope, fmt.Sprintf(
					"a rewrite through template '%s' has depth %d, beyond MAX_REWRITE_PASSES=%d (depth counts through template bodies)",
					res.name, d+res.height, MaxRewritePasses))
			}
			return nil
		})
		if err != nil {
			return err
		}
	}
	if len(st.order) == 0 {
		return nil
	}

	var templates []string
	byTemplate := map[string][]string{}
	for _, k := range st.order {
		t := st.done[k].name
		if _, ok := byTemplate[t]; !ok {
			templates = append(templates, t)
		}
		byTemplate[t] = append(byTemplate[t], k)
	}
	final := map[string]string{}
	block, ok := comp["expression_templates"].(map[string]any)
	if !ok {
		block = map[string]any{}
		comp["expression_templates"] = block
	}
	taken := map[string]bool{}
	for n := range L.named {
		taken[n] = true
	}
	order, err := st.rule3TemplateOrder(templates, byTemplate)
	if err != nil {
		return err
	}
	exposed := st.rule3Exposed(byTemplate, order)
	for _, t := range order {
		keysT := byTemplate[t]
		bodies := make([]any, len(keysT))
		canon := make([]string, len(keysT))
		for i, k := range keysT {
			bodies[i] = repointRefs(st.done[k].body, st.done[k].refs, final)
			canon[i] = canonicalCompact(bodies[i])
		}
		distinctSet := map[string]bool{}
		var distinct []string
		for _, c := range canon {
			if !distinctSet[c] {
				distinctSet[c] = true
				distinct = append(distinct, c)
			}
		}
		sort.Strings(distinct)
		decl, _ := L.named[t].(map[string]any)
		if len(distinct) == 1 && (!exposed[t] || distinct[0] == canonicalCompact(decl["body"])) {
			for _, k := range keysT {
				final[k] = t
			}
			var nd map[string]any
			if declHasMatch(decl) {
				nd = matchStripped(decl)
			} else {
				nd = cloneMapAny(decl)
			}
			if distinct[0] != canonicalCompact(decl["body"]) {
				nd["body"] = bodies[0]
			} else if !declHasMatch(decl) {
				continue
			}
			L.named[t] = nd
			block[t] = nd
		} else {
			names := map[string]string{}
			for i, c := range distinct {
				vn := fmt.Sprintf("%s.variant%d", t, i+1)
				for taken[vn] {
					vn += "_"
				}
				taken[vn] = true
				names[c] = vn
				nd := matchStripped(decl)
				for j := range canon {
					if canon[j] == c {
						nd["body"] = bodies[j]
						break
					}
				}
				L.named[vn] = nd
				block[vn] = nd
			}
			for i, k := range keysT {
				final[k] = names[canon[i]]
			}
		}
	}
	for _, s := range sites {
		s.holder[s.key] = repointRefs(s.holder[s.key], siteRefs, final)
	}
	return nil
}
