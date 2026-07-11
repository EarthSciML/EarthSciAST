package esm

import (
	"fmt"
	"strings"
)

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
func nameMap(raw any, field, where string) (map[string]string, error) {
	out := map[string]string{}
	if raw == nil {
		return out, nil
	}
	obj, ok := raw.(map[string]any)
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
func renameWalk(x any, varmap, isetmap, tplmap map[string]string) any {
	switch v := x.(type) {
	case string:
		if n, ok := varmap[v]; ok {
			return n
		}
		return v
	case []any:
		out := make([]any, len(v))
		for i, c := range v {
			out[i] = renameWalk(c, varmap, isetmap, tplmap)
		}
		return out
	case map[string]any:
		isApply := false
		if op, ok := v["op"].(string); ok && op == applyExpressionTemplateOp {
			isApply = true
		}
		out := make(map[string]any, len(v))
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
				if w, ok := val.(map[string]any); ok {
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
func renameWhere(whr map[string]any, isetmap map[string]string) map[string]any {
	out := make(map[string]any, len(whr))
	for p, cobj := range whr {
		cmap, ok := cobj.(map[string]any)
		if !ok {
			out[p] = deepCopyJSON(cobj)
			continue
		}
		cout := make(map[string]any, len(cmap))
		for ck, cv := range cmap {
			if ck == "shape" {
				if arr, ok := cv.([]any); ok {
					shape := make([]any, len(arr))
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
func renameDecl(decl any, varmap, isetmap, tplmap map[string]string) any {
	declObj, ok := decl.(map[string]any)
	if !ok {
		return renameWalk(decl, varmap, isetmap, tplmap)
	}
	v2, i2 := varmap, isetmap
	if params, ok := declObj["params"].([]any); ok && len(params) > 0 {
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
func collectBoundSyms(out map[string]struct{}, x any) {
	switch v := x.(type) {
	case []any:
		for _, c := range v {
			collectBoundSyms(out, c)
		}
	case map[string]any:
		if op, _ := v["op"].(string); op == "aggregate" {
			if oi, ok := v["output_idx"].([]any); ok {
				for _, e := range oi {
					if es, ok := e.(string); ok {
						out[es] = struct{}{}
					}
				}
			}
			if rg, ok := v["ranges"].(map[string]any); ok {
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
func collectRefNames(out map[string]struct{}, x any, shadowed map[string]struct{}) {
	switch v := x.(type) {
	case string:
		if _, sh := shadowed[v]; !sh {
			out[v] = struct{}{}
		}
	case []any:
		for _, c := range v {
			collectRefNames(out, c, shadowed)
		}
	case map[string]any:
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
func applyEdgeRenames(scope *templateScope, entry map[string]any, origin, ref string) (*templateScope, error) {
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
	free, bound, paramsAll := scopeNameInventory(scope)

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
	if err := checkRenameFreshness(scope, free, bound, paramsAll, rebind, metamap, where); err != nil {
		return nil, err
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
		if ndObj, ok := nd.(map[string]any); ok {
			if of, ok := ndObj["of"].([]any); ok {
				newOf := make([]any, len(of))
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

// scopeNameInventory inventories the free and bound bare names of a surviving
// export scope (esm-spec §9.7.7): `free` are the variable-reference-position
// names (minus each template's own `params` shadow set, and minus the scope's
// declared metaparameter names) plus index-set `offsets`/`values` references;
// `bound` are the aggregate bound index symbols (`output_idx` / `ranges` keys);
// `paramsAll` are all template param names. These feed the rebind occurs-check
// and the rename/rebind freshness (collision) guard.
func scopeNameInventory(scope *templateScope) (free, bound, paramsAll map[string]struct{}) {
	free = map[string]struct{}{}
	bound = map[string]struct{}{}
	paramsAll = map[string]struct{}{}
	for _, n := range scope.templates.keys {
		d := scope.templates.get(n)
		collectBoundSyms(bound, d)
		shadowed := map[string]struct{}{}
		if declObj, ok := d.(map[string]any); ok {
			if params, ok := declObj["params"].([]any); ok {
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
		if d, ok := scope.indexSets.get(n).(map[string]any); ok {
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
	return free, bound, paramsAll
}

// checkRenameFreshness is the §9.7.7 freshness guard: every NEW bare name minted
// by this edge (a renamed metaparameter or a `rebind` target that differs from
// its key) must not collide with a name still in use inside the imported
// declarations — a remaining free name (other than the one being rebound), a
// bound index symbol, a template param, or another rename/rebind target. A
// collision is `template_import_rename_collision`.
func checkRenameFreshness(scope *templateScope, free, bound, paramsAll map[string]struct{}, rebind, metamap map[string]string, where string) error {
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
			return newETErr("template_import_rename_collision",
				fmt.Sprintf("%s: renamed/rebound name '%s' collides with a name still in use inside the imported declarations (a remaining free name, a bound index symbol, a template param, or another rename/rebind target; esm-spec §9.7.7)", where, tk))
		}
		taken[tk] = struct{}{}
	}
	return nil
}
