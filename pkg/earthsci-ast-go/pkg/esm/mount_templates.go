package esm

import (
	"sort"
	"strings"
)

// mount_templates.go: template registries across a §4.7 mount (esm-spec §9.6.4
// rules 1 and 7, §10.7; esm-libraries-spec §4.7.5 steps 2 and 4).
//
// A mounted leaf is lowered in its own file and keeps its references; each of
// its components keeps its match-less definitions (mountedRegistries). When the
// mounting document lowers a top-level component, the blocks its subsystems
// carry join the component's own registry by the registry merge
// (hoistMountedTemplates / mergeFlatRegistry), with their bodies unchanged: a
// body's free names are read in the scope of the subsystem that owns the
// reference. Flatten closes every carried body first (tplExplicitFree), so one
// definition can serve several subsystems.

// registryBlock is one owner's block in a registry merge: the owner path (a
// component name, or a subsystem path below the mounting component such as
// `Sub` or `Sub.Inner`) and its entries in declaration order.
type registryBlock struct {
	path  string
	block *orderedMap
}

// mergeFlatRegistry merges the owners' blocks, in the order given, into one
// registry (esm-spec §9.6.4 rule 7, §10.7; esm-libraries-spec §4.7.5 step 4).
// A name whose occurrences are all deep-equal (and reference no colliding
// name, registryCollisionNames) is kept once under its bare name. For a
// colliding name, callees first, each owner's entry with its nested references
// renamed to that owner's entries is grouped by deep equality: a group is ONE
// entry named `<first owner's path>.<name>`, so a definition two owners carry
// identically (a leaf mounted twice) stays one definition. Returns the merged
// registry and each owner's rename map (path => old name => new name), which
// the caller applies to that owner's reference sites. Mirrors the Julia
// `_merge_flat_registry`.
func mergeFlatRegistry(blocks []registryBlock) (*orderedMap, map[string]map[string]string) {
	merged := newOrderedMap()
	rename := map[string]map[string]string{}
	type occurrence struct {
		path string
		decl any
	}
	byname := map[string][]occurrence{}
	var order []string
	for _, b := range blocks {
		if b.block == nil {
			continue
		}
		for _, name := range b.block.keys {
			if _, seen := byname[name]; !seen {
				order = append(order, name)
			}
			byname[name] = append(byname[name], occurrence{path: b.path, decl: b.block.get(name)})
		}
	}
	grouped := newOrderedMap()
	for _, name := range order {
		occ := make([]any, 0, len(byname[name]))
		for _, o := range byname[name] {
			occ = append(occ, [2]any{o.path, o.decl})
		}
		grouped.set(name, occ)
	}
	collide := registryCollisionNames(grouped)

	type group struct {
		name string
		decl any
	}
	groups := map[string][]group{}
	settled := map[string]bool{}
	var settle func(name string)
	settle = func(name string) {
		if settled[name] {
			return
		}
		settled[name] = true
		var gs []group
		for _, o := range byname[name] {
			rn := map[string]string{}
			var callees []string
			collectApplyNames(&callees, o.decl)
			for _, c := range callees {
				if !collide[c] || c == name {
					continue
				}
				settle(c)
				if nn, ok := rename[o.path][c]; ok {
					rn[c] = nn
				}
			}
			d := o.decl
			if len(rn) > 0 {
				d = renameApplyRefs(d, rn)
			}
			idx := -1
			for i, g := range gs {
				if jsonEqual(g.decl, d) {
					idx = i
					break
				}
			}
			if idx < 0 {
				gs = append(gs, group{name: o.path + "." + name, decl: d})
				idx = len(gs) - 1
			}
			if rename[o.path] == nil {
				rename[o.path] = map[string]string{}
			}
			rename[o.path][name] = gs[idx].name
		}
		groups[name] = gs
	}
	for _, name := range order {
		if collide[name] {
			settle(name)
		}
	}
	for _, name := range order {
		if collide[name] {
			for _, g := range groups[name] {
				merged.set(g.name, g.decl)
			}
			continue
		}
		merged.set(name, byname[name][0].decl)
	}
	return merged, rename
}

// matchlessBlock is a raw `operators` block's match-less entries, in
// declaration order `order` (names absent from it follow, sorted).
func matchlessBlock(tpl map[string]any, order []string) *orderedMap {
	out := newOrderedMap()
	for _, n := range orderedTemplateNames(tpl, order) {
		if d, ok := tpl[n].(map[string]any); ok && declHasMatch(d) {
			continue
		}
		// Each entry records the defined operator it defines under the key it
		// was declared with, before a collision rename (esm-spec §9.6.12
		// "Provenance").
		out.set(n, withDefines(n, tpl[n]))
	}
	return out
}

// mountedRegistries keeps, on each component of a lowered mounted leaf, the
// `operators` block the mounting document merges: its match-less
// entries only (the `match` rules have fired in the leaf), and none on a
// component no reference reads. Mutates view. Mirrors the Julia
// `_mounted_registries!`.
func mountedRegistries(view map[string]any) {
	for _, kind := range templateComponentKinds {
		comps, _ := view[kind].(map[string]any)
		for _, cname := range sortedKeys(comps) {
			comp, ok := comps[cname].(map[string]any)
			if !ok {
				continue
			}
			tpl, ok := comp["operators"].(map[string]any)
			if !ok {
				continue
			}
			keep := map[string]any{}
			for n, d := range tpl {
				if dm, ok := d.(map[string]any); ok && declHasMatch(dm) {
					continue
				}
				keep[n] = d
			}
			used := false
			for k, v := range comp {
				if k != "operators" && containsApplyOp(v) {
					used = true
					break
				}
			}
			if len(keep) == 0 || !used {
				delete(comp, "operators")
			} else {
				comp["operators"] = keep
			}
		}
	}
}

// mountedBlock is a subsystem below a top-level component that carries its own
// `operators` block, with its path below the component and the JSON
// pointer it sits at (for its declaration order).
type mountedBlock struct {
	path string
	ptr  string
	sub  map[string]any
}

// collectMountedBlocks lists the subsystems below node that carry a block, in
// declaration order. A mount point's own subtree is its block's (merged when
// that model was lowered in its own file), so the walk stops there. Mirrors
// the Julia `_collect_mounted_blocks!`.
func collectMountedBlocks(out []mountedBlock, node map[string]any, prefix, ptr string, orders map[string][]string) []mountedBlock {
	subs, ok := node["subsystems"].(map[string]any)
	if !ok {
		return out
	}
	for _, k := range orderedKeysOf(subs, orders[ptr+"/subsystems"]) {
		sub, ok := subs[k].(map[string]any)
		if !ok {
			continue
		}
		path := k
		if prefix != "" {
			path = prefix + "." + k
		}
		subPtr := ptr + "/subsystems/" + k
		if _, ok := sub["operators"].(map[string]any); ok {
			out = append(out, mountedBlock{path: path, ptr: subPtr, sub: sub})
		} else {
			out = collectMountedBlocks(out, sub, path, subPtr, orders)
		}
	}
	return out
}

// renameOutsideMounts renames, by rn, the references of node's subsystems that
// lie outside every mount point (a subsystem carrying its own block). Mirrors
// the Julia `_rename_outside_mounts!`.
func renameOutsideMounts(node map[string]any, rn map[string]string) {
	subs, ok := node["subsystems"].(map[string]any)
	if !ok {
		return
	}
	for _, k := range sortedKeys(subs) {
		sub, ok := subs[k].(map[string]any)
		if !ok {
			continue
		}
		if _, ok := sub["operators"].(map[string]any); ok {
			continue
		}
		for _, f := range sortedKeys(sub) {
			if f == "subsystems" {
				continue
			}
			sub[f] = renameApplyRefs(sub[f], rn)
		}
		renameOutsideMounts(sub, rn)
	}
}

// mergeMountedBlocks merges the component cname's block `own` (raw, or nil;
// declaration order ownOrder) with each mounted block, by mergeFlatRegistry.
// Each mounted subsystem's own references are renamed here, in place; the
// caller applies the returned rename (or nil) to the component's other sites.
// own's `match` rules are kept, ahead of the merged entries. Mirrors the Julia
// `_merge_mounted_blocks`.
func mergeMountedBlocks(own map[string]any, ownOrder []string, cname string, mounts []mountedBlock, orders map[string][]string) (*orderedMap, map[string]string) {
	blocks := []registryBlock{{path: cname, block: matchlessBlock(own, ownOrder)}}
	for _, m := range mounts {
		tpl, _ := m.sub["operators"].(map[string]any)
		blocks = append(blocks, registryBlock{path: m.path, block: matchlessBlock(tpl, orders[m.ptr+"/operators"])})
	}
	merged, rename := mergeFlatRegistry(blocks)
	for _, m := range mounts {
		rm := rename[m.path]
		if rm == nil {
			continue
		}
		for _, k := range sortedKeys(m.sub) {
			if k == "operators" {
				continue
			}
			m.sub[k] = renameApplyRefs(m.sub[k], rm)
		}
	}
	rn := rename[cname]
	newblock := newOrderedMap()
	for _, n := range orderedTemplateNames(own, ownOrder) {
		d, ok := own[n].(map[string]any)
		if !ok || !declHasMatch(d) {
			continue
		}
		if rn != nil {
			newblock.set(n, renameApplyRefs(d, rn))
		} else {
			newblock.set(n, d)
		}
	}
	for _, n := range merged.keys {
		newblock.set(n, merged.get(n))
	}
	return newblock, rn
}

// hoistMountedTemplates merges into the top-level component comp's
// `operators` block the blocks its subsystems carry (a mounted
// leaf's, or an authored subsystem's own), esm-spec §9.6.4 rule 1. Owner
// paths: comp's own match-less entries under cname, each subsystem block under
// its subsystem path below comp. Bodies are taken unchanged. Each mounted
// subtree's references follow its own owner's renames; comp's other sites
// (its own fields and its subsystems without a block) follow comp's. The
// subsystem blocks are deleted. `ptr` is comp's JSON pointer; `orders` (may be
// nil) supplies declaration order and receives the merged block's. Mirrors the
// Julia `_hoist_mounted_templates!`.
func hoistMountedTemplates(comp map[string]any, cname, ptr string, orders map[string][]string) {
	mounts := collectMountedBlocks(nil, comp, "", ptr, orders)
	if len(mounts) == 0 {
		return
	}
	own, _ := comp["operators"].(map[string]any)
	ownOrder := orders[ptr+"/operators"]
	newblock, rn := mergeMountedBlocks(own, ownOrder, cname, mounts, orders)
	if rn != nil {
		for _, k := range sortedKeys(comp) {
			if k == "operators" || k == "subsystems" {
				continue
			}
			comp[k] = renameApplyRefs(comp[k], rn)
		}
		renameOutsideMounts(comp, rn)
	}
	for _, m := range mounts {
		delete(m.sub, "operators")
	}
	block := make(map[string]any, newblock.len())
	for _, n := range newblock.keys {
		block[n] = newblock.get(n)
	}
	comp["operators"] = block
	if orders != nil {
		orders[ptr+"/operators"] = append([]string(nil), newblock.keys...)
	}
}

// ---------------------------------------------------------------------------
// Closing a block's bodies (esm-spec §10.7; esm-libraries-spec §4.7.5 step 2)
// ---------------------------------------------------------------------------

// tplExplicitFree returns block with every match-less body's free names made
// explicit parameters: a name a body reads from its caller (a variable leaf,
// or a `join` key column or overlap envelope factor, that it does not bind and
// that is not one of its parameters, read directly or through a nested
// reference) is appended, sorted, to its `params`, and every
// nested reference in a body binds its callee's added parameters to the same
// names (tplBindExplicit). `added` maps each changed template to the
// parameters it gained. Entries are visited in block order, callees first.
// The input is not mutated. Mirrors the Julia `_tpl_explicit_free`.
func tplExplicitFree(block *orderedMap) (*orderedMap, map[string][]string) {
	added := map[string][]string{}
	if block == nil {
		return block, added
	}
	newdecl := map[string]any{}
	visiting := map[string]bool{}
	var visit func(name string)
	visit = func(name string) {
		if _, done := newdecl[name]; done || visiting[name] {
			return
		}
		visiting[name] = true
		decl := block.get(name)
		dm, ok := decl.(map[string]any)
		body, hasBody := dm["body"]
		if !ok || !hasBody || body == nil || declHasMatch(dm) {
			newdecl[name] = decl
			return
		}
		var callees []string
		collectApplyNames(&callees, body)
		for _, c := range callees {
			if block.has(c) {
				visit(c)
			}
		}
		bound, changed := tplBindExplicit(body, added)
		params := templateParams(dm)
		pset := map[string]bool{}
		for _, p := range params {
			pset[p] = true
		}
		leaves := map[string]bool{}
		tplFreeLeaves(bound, map[string]bool{}, leaves)
		var free []string
		for n := range leaves {
			if !pset[n] {
				free = append(free, n)
			}
		}
		sort.Strings(free)
		if !changed && len(free) == 0 {
			newdecl[name] = decl
			return
		}
		nd := cloneMapAny(dm)
		if changed {
			nd["body"] = bound
		}
		if len(free) > 0 {
			ps := make([]any, 0, len(params)+len(free))
			for _, p := range params {
				ps = append(ps, p)
			}
			for _, f := range free {
				ps = append(ps, f)
			}
			nd["params"] = ps
			added[name] = free
		}
		newdecl[name] = nd
	}
	for _, n := range block.keys {
		visit(n)
	}
	out := newOrderedMap()
	for _, n := range block.keys {
		out.set(n, newdecl[n])
	}
	return out, added
}

// tplBindExplicit returns node with every reference to a template of `added`
// binding each added parameter to the same name, `n => n`; a binding the
// reference already has is kept. Copy-on-write: unchanged subtrees are
// returned as they are, and `changed` reports whether anything changed.
// Mirrors the Julia `_tpl_bind_explicit`.
func tplBindExplicit(node any, added map[string][]string) (any, bool) {
	if len(added) == 0 {
		return node, false
	}
	switch n := node.(type) {
	case []any:
		var out []any
		for i, v := range n {
			nv, ch := tplBindExplicit(v, added)
			if ch && out == nil {
				out = make([]any, len(n))
				copy(out, n)
			}
			if out != nil {
				out[i] = nv
			}
		}
		if out == nil {
			return n, false
		}
		return out, true
	case map[string]any:
		var out map[string]any
		for _, k := range sortedKeys(n) {
			nv, ch := tplBindExplicit(n[k], added)
			if ch {
				if out == nil {
					out = cloneMapAny(n)
				}
				out[k] = nv
			}
		}
		if op, _ := n["op"].(string); op == applyExpressionTemplateOp {
			if name, ok := n["name"].(string); ok {
				if names := added[name]; len(names) > 0 {
					cur := n
					if out != nil {
						cur = out
					}
					b, _ := cur["bindings"].(map[string]any)
					var nb map[string]any
					for _, a := range names {
						if _, has := b[a]; has {
							continue
						}
						if nb == nil {
							nb = make(map[string]any, len(b)+len(names))
							for k, v := range b {
								nb[k] = v
							}
						}
						nb[a] = a
					}
					if nb != nil {
						if out == nil {
							out = cloneMapAny(n)
						}
						out["bindings"] = nb
					}
				}
			}
		}
		if out == nil {
			return n, false
		}
		return out, true
	}
	return node, false
}

// tplExprChildKeys are the expression-bearing fields of a raw operator node
// (the Julia OPEXPR_FIELD_TABLE rows of kind expr, expr_vec, expr_map and
// ranges). Scalar fields (`wrt`, `dim`, `var`, `output_idx`, `name`, `fn`,
// `value`, `units`, `join`, `regions`, `shape`, `attrs`, ...) are not
// expression children; `join` names are read by tplJoinNames.
var tplExprChildKeys = map[string]bool{
	"args": true, "lower": true, "upper": true, "expr": true, "values": true,
	"filter": true, "key": true, "bindings": true, "ranges": true,
}

// tplJoinNames returns the plain-string names a raw node's `join` clauses
// carry: each `on` clause's key columns and each `overlap` clause's
// `src_env` / `tgt_env` envelope factors. They name variables exactly as a
// leaf does (the names component namespacing scopes); a clause's `syms` are
// binders, not reads. Mirrors the Julia `_tpl_free_join_names`.
func tplJoinNames(n map[string]any) []string {
	var out []string
	strs := func(v any) {
		if items, ok := v.([]any); ok {
			for _, it := range items {
				if s, ok := it.(string); ok {
					out = append(out, s)
				}
			}
		}
	}
	clauses, ok := n["join"].([]any)
	if !ok {
		return nil
	}
	for _, c := range clauses {
		cm, ok := c.(map[string]any)
		if !ok {
			continue
		}
		if on, ok := cm["on"].([]any); ok {
			for _, pair := range on {
				strs(pair)
			}
		}
		if ov, ok := cm["overlap"].(map[string]any); ok {
			strs(ov["src_env"])
			strs(ov["tgt_env"])
		}
	}
	return out
}

// tplFreeLeaves adds to out the names a raw expression reads and does not
// bind itself: its variable leaves, and the `join` key columns and overlap
// envelope factors it names (tplJoinNames). A node's binders (`output_idx`
// strings, `ranges` keys, the integral variable `var`) bind all of its
// children and its own `join`; binding values of nested references are reads.
// Mirrors the Julia `_tpl_free_leaves` and `_tpl_free_join_names`.
func tplFreeLeaves(node any, bound map[string]bool, out map[string]bool) {
	switch n := node.(type) {
	case string:
		if !bound[n] && !strings.HasPrefix(n, "\x00") {
			out[n] = true
		}
	case map[string]any:
		if _, isOp := n["op"].(string); !isOp {
			return
		}
		inner := bound
		var binders []string
		if v, ok := n["var"].(string); ok {
			binders = append(binders, v)
		}
		binders = append(binders, exprBinderNames(n)...)
		if len(binders) > 0 {
			inner = make(map[string]bool, len(bound)+len(binders))
			for k := range bound {
				inner[k] = true
			}
			for _, b := range binders {
				inner[b] = true
			}
		}
		for _, j := range tplJoinNames(n) {
			if !inner[j] && !strings.HasPrefix(j, "\x00") {
				out[j] = true
			}
		}
		for k, v := range n {
			if !tplExprChildKeys[k] {
				continue
			}
			switch k {
			case "args", "values":
				if items, ok := v.([]any); ok {
					for _, it := range items {
						tplFreeLeaves(it, inner, out)
					}
				}
			case "bindings":
				if m, ok := v.(map[string]any); ok {
					for _, it := range m {
						tplFreeLeaves(it, inner, out)
					}
				}
			case "ranges":
				// An entry is an index-set name (no reads) or a dense bound
				// vector whose entries may be expressions.
				if m, ok := v.(map[string]any); ok {
					for _, r := range m {
						if items, ok := r.([]any); ok {
							for _, it := range items {
								tplFreeLeaves(it, inner, out)
							}
						}
					}
				}
			default:
				tplFreeLeaves(v, inner, out)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// The typed mount path (ResolveSubsystemRefs on a loaded file)
// ---------------------------------------------------------------------------

// mergeTypedMountedTemplates is the typed mount path's twin of
// hoistMountedTemplates: the blocks the freshly mounted subsystems of the
// top-level component `kind.name` carry join that component's registry in
// esm.componentTemplates by the same merge (mergeMountedBlocks). The typed
// file is this binding's expanded image (the load expands every reference,
// Expand-at-build), so the component's own fields hold no reference, and each
// mounted subtree's references, renamed to the merged registry, are expanded
// against it here, as the load would have expanded them. Mirrors the Julia
// `_merge_typed_mounted_templates!`.
func (esm *ESMFile) mergeTypedMountedTemplates(kind, name string, subsystems map[string]any) error {
	ptr := "/" + kind + "/" + name
	mounts := collectMountedBlocks(nil, map[string]any{"subsystems": subsystems}, "", ptr, esm.keyOrders)
	if len(mounts) == 0 {
		return nil
	}
	key := kind + "." + name
	var own map[string]any
	var ownOrder []string
	if blk := esm.componentTemplates[key]; blk != nil {
		own = make(map[string]any, blk.len())
		for _, n := range blk.keys {
			own[n] = blk.get(n)
		}
		ownOrder = blk.keys
	}
	block, _ := mergeMountedBlocks(own, ownOrder, name, mounts, esm.keyOrders)
	named := make(map[string]any, block.len())
	for _, n := range block.keys {
		named[n] = block.get(n)
	}
	for _, m := range mounts {
		delete(m.sub, "operators")
		for _, k := range sortedKeys(m.sub) {
			res, err := expandAll(m.sub[k], named, key+"."+m.path+"."+k)
			if err != nil {
				return err
			}
			m.sub[k] = res
		}
	}
	if esm.componentTemplates == nil {
		esm.componentTemplates = map[string]*orderedMap{}
	}
	esm.componentTemplates[key] = block
	return nil
}

// landTypedTopLevelTemplates prepares a component a typed top-level mount
// lands (resolved raw, still carrying the leaf's references and its
// match-less block): its block becomes the component's registry in
// esm.componentTemplates (flatten's registry merge takes it from there), and
// its references are expanded against it, as the load expands a top-level
// component's (Expand-at-build). `order` is the block's declaration order.
func (esm *ESMFile) landTypedTopLevelTemplates(section, name string, comp map[string]any, order []string) error {
	tpl, ok := comp["operators"].(map[string]any)
	if !ok {
		return nil
	}
	delete(comp, "operators")
	key := section + "." + name
	for _, k := range sortedKeys(comp) {
		res, err := expandAll(comp[k], tpl, key+"."+k)
		if err != nil {
			return err
		}
		comp[k] = res
	}
	block := matchlessBlock(tpl, order)
	if block.len() == 0 {
		return nil
	}
	if esm.componentTemplates == nil {
		esm.componentTemplates = map[string]*orderedMap{}
	}
	esm.componentTemplates[key] = block
	return nil
}
