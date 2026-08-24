package esm

import (
	"fmt"
	"strings"
)

// flatten_lift.go — the pointwise spatial lift (esm-spec §10.5) and the merged
// expression-template registry (esm-spec §9.6.4 rule 7, §10.7), the two step-4
// passes that run over the ASSEMBLED system rather than per component.

// ============================================================================
// Pointwise spatial lift (esm-spec §10.5)
// ============================================================================
//
// Reaction ODE-gen and coupling both run at the AST level and IN THAT ORDER
// (reactions -> a generic `D(sp) = Σ terms`; then `operator_compose` merges each
// species' reaction ODE with the spatial operator's advection makearray). What
// operator_compose does NOT do is array-ify the result: the merged
// `D(sp) = <reaction> + <-u·makearray(grad(sp))>` still has a SCALAR `sp` while
// its advection makearray indexes `sp` per grid cell. This pass performs the
// `lifting: "pointwise"` promotion — wrapping each merged state ODE in an
// `aggregate` over the grid, indexing the bare reaction species per cell and each
// operator makearray per cell, and recording the species' concrete grid shape.

// collectMakearrays returns every `makearray` node reachable from expr,
// pre-order.
func collectMakearrays(expr Expression) []ExprNode {
	var out []ExprNode
	walkExprNodes(expr, func(n ExprNode) {
		if n.Op == "makearray" {
			out = append(out, n)
		}
	})
	return out
}

// indexArgLoop returns the first bare-name leaf in an index-position expression
// (its loop variable), or "" for a constant position.
func indexArgLoop(expr Expression) string {
	if s, ok := expr.(string); ok {
		return s
	}
	node, ok := asExprNode(expr)
	if !ok {
		return ""
	}
	for _, a := range node.Args {
		if v := indexArgLoop(a); v != "" {
			return v
		}
	}
	return ""
}

// detectLiftLoops reads the ordered spatial loop variables of a lowered operator
// makearray off an `index(<lifted species>, a1, …, aRank)` gather whose every
// position carries a loop variable (the interior stencil). Returns nil when none
// is found.
func detectLiftLoops(ma ExprNode, lifted map[string]bool, rank int) []string {
	var found []string
	walkExprNodes(ma, func(n ExprNode) {
		if found != nil || n.Op != "index" || len(n.Args) == 0 {
			return
		}
		head, ok := n.Args[0].(string)
		if !ok || !lifted[head] || len(n.Args)-1 != rank {
			return
		}
		loops := make([]string, 0, rank)
		for _, a := range n.Args[1:] {
			lv := indexArgLoop(a)
			if lv == "" {
				return
			}
			loops = append(loops, lv)
		}
		found = loops
	})
	return found
}

// makearrayExtents is the per-dimension grid extent of a lowered operator
// makearray: the largest cell index addressed in each `regions` dimension.
func makearrayExtents(ma ExprNode) []int {
	if len(ma.Regions) == 0 || len(ma.Regions[0]) == 0 {
		return nil
	}
	rank := len(ma.Regions[0])
	ext := make([]int, rank)
	for _, region := range ma.Regions {
		if len(region) != rank {
			continue
		}
		for d := 0; d < rank; d++ {
			if len(region[d]) < 2 {
				continue
			}
			if hi, ok := exprNumber(region[d][1]); ok && int(hi) > ext[d] {
				ext[d] = int(hi)
			}
		}
	}
	return ext
}

// liftRHSToCell rewrites a scalar (merged reaction + operator) RHS into its
// per-cell form over the spatial `loops`: a bare reference to an array variable
// becomes `index(var, loops…)`, and each spatial-operator `makearray` becomes
// `index(makearray, loops…)` (its region values already index per cell).
// Self-contained nodes (index / aggregate / arrayop) are left untouched;
// elementwise ops recurse.
func liftRHSToCell(expr Expression, arrayvars map[string]bool, loops []string) Expression {
	if s, ok := expr.(string); ok {
		if arrayvars[s] {
			return ExprNode{Op: "index", Args: indexArgs(s, loops)}
		}
		return s
	}
	node, ok := asExprNode(expr)
	if !ok {
		return expr
	}
	switch node.Op {
	case "makearray":
		// Tag the makearray with its loop symbols so an evaluator binds each
		// region's own arange when materializing the field (esm-spec §10.5);
		// otherwise a per-cell gather would read the stencil out of bounds.
		ma := node
		ma.OutputIdx = make([]any, len(loops))
		for i, l := range loops {
			ma.OutputIdx[i] = l
		}
		return ExprNode{Op: "index", Args: indexArgs(ma, loops)}
	case "index", "aggregate", "arrayop":
		return node
	}
	out := node
	args := make([]any, len(node.Args))
	for i, a := range node.Args {
		args[i] = liftRHSToCell(a, arrayvars, loops)
	}
	out.Args = args
	return out
}

// indexArgs builds the `index` argument list: the gathered operand followed by
// one loop symbol per dimension.
func indexArgs(head any, loops []string) []any {
	args := make([]any, 0, len(loops)+1)
	args = append(args, head)
	for _, l := range loops {
		args = append(args, l)
	}
	return args
}

// applyPointwiseLift promotes every state ODE that `operator_compose` merged
// with a spatial operator (its merged RHS carries an operator `makearray`) from
// a 0-D scalar to the operator's grid shape, and rewrites the equation into an
// `aggregate` over the grid. No-op when no coupling entry requests pointwise
// lifting, or no merged equation carries a spatial-operator makearray.
func applyPointwiseLift(flat *FlattenedSystem, coupling []CouplingEntry) error {
	requested := false
	for _, c := range coupling {
		if oc, ok := c.(OperatorComposeCoupling); ok && oc.Lifting != nil && *oc.Lifting == "pointwise" {
			requested = true
			break
		}
	}
	if !requested {
		return nil
	}

	dTarget := func(lhs Expression) string {
		node, ok := asExprNode(lhs)
		if !ok || node.Op != OpDerivative || len(node.Args) == 0 {
			return ""
		}
		s, _ := node.Args[0].(string)
		return s
	}

	// A species is lifted iff its state ODE's merged RHS carries a
	// spatial-operator makearray (the advection contribution operator_compose
	// added).
	lifted := map[string]bool{}
	for _, eq := range flat.Equations {
		target := dTarget(eq.LHS)
		if target == "" {
			continue
		}
		if len(collectMakearrays(eq.RHS)) > 0 {
			lifted[target] = true
		}
	}
	if len(lifted) == 0 {
		return nil
	}

	// Operands to index per cell: the lifted species plus any already
	// array-shaped parameter / observed / state (a grid-shaped wind field bound
	// from a loader, say).
	arrayvars := map[string]bool{}
	for name := range lifted {
		arrayvars[name] = true
	}
	for _, table := range [][]FlattenedVariable{flat.Parameters, flat.ObservedVariables, flat.StateVariables} {
		for _, v := range table {
			if len(v.Shape) > 0 {
				arrayvars[v.Name] = true
			}
		}
	}

	var out []FlattenedEquation
	for _, eq := range flat.Equations {
		target := dTarget(eq.LHS)
		if target == "" || !lifted[target] {
			out = append(out, eq)
			continue
		}
		mas := collectMakearrays(eq.RHS)
		if len(mas) == 0 || len(mas[0].Regions) == 0 {
			out = append(out, eq)
			continue
		}
		rank := len(mas[0].Regions[0])
		var loops []string
		for _, ma := range mas {
			if loops = detectLiftLoops(ma, lifted, rank); loops != nil {
				break
			}
		}
		if loops == nil {
			return &DimensionPromotionError{Message: fmt.Sprintf(
				"flatten: pointwise lift: could not determine the spatial loop variables for species %q from its operator makearray",
				target)}
		}

		extents := makearrayExtents(mas[0])
		ranges := make(map[string]any, rank)
		outputIdx := make([]any, rank)
		for d := 0; d < rank; d++ {
			ranges[loops[d]] = []any{int64(1), int64(extents[d])}
			outputIdx[d] = loops[d]
		}
		flat.LiftedShapes = append(flat.LiftedShapes, LiftedShape{Name: target, Shape: extents})

		wrt := DefaultIndepVar
		idxSpecies := ExprNode{Op: "index", Args: indexArgs(target, loops)}
		out = append(out, FlattenedEquation{
			LHS: ExprNode{
				Op: "aggregate", OutputIdx: outputIdx, Ranges: ranges,
				Expr: ExprNode{Op: OpDerivative, Args: []any{idxSpecies}, Wrt: &wrt},
			},
			RHS: ExprNode{
				Op: "aggregate", OutputIdx: outputIdx, Ranges: ranges,
				Expr: liftRHSToCell(eq.RHS, arrayvars, loops),
			},
			SourceSystem: eq.SourceSystem,
		})
	}
	flat.Equations = out
	return nil
}

// ============================================================================
// The merged expression-template registry (esm-spec §9.6.4 rule 7, §10.7)
// ============================================================================

// scopeTemplateBody component-scopes one carried template body: it prefixes
// exactly the references that name one of the OWNING component's locals.
//
// This is the "post-step-2 scoping" esm-libraries-spec §4.7.5 step 4 calls an
// ordering requirement rather than a parenthetical. A body's FREE variables are
// resolved in its owner's scope, so two components importing one library carry
// byte-identical bodies whose free `inv_dx` denotes a DIFFERENT variable in each;
// deduplicating them pre-scoping keeps one body that is correct for neither.
// Scoping also makes them non-deep-equal, which is what routes them into the
// collision rename and keeps an entry per component.
//
// Unlike namespaceExprTree (which prefixes every bare reference except an
// explicit leave-alone set) this is a WHITELIST: a body legitimately references
// its own formal `params`, loop symbols, and document-scoped index sets, none of
// which are component locals and none of which may be prefixed. The caller
// removes the template's `params` from `localNames` before calling.
func scopeTemplateBody(raw any, prefix string, localNames, bound map[string]bool) any {
	switch v := raw.(type) {
	case string:
		if bound[v] {
			return v
		}
		if head, _, found := strings.Cut(v, "."); found {
			if localNames[head] {
				return prefix + "." + v
			}
			return v
		}
		if localNames[v] {
			return prefix + "." + v
		}
		return v
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = scopeTemplateBody(item, prefix, localNames, bound)
		}
		return out
	case map[string]any:
		if _, isNode := v["op"]; !isNode {
			// Not an expression node (a `ranges` spec, a `join` clause, ...):
			// recurse structurally without treating its strings as references.
			return v
		}
		localBound := bound
		if v["op"] == "aggregate" {
			localBound = map[string]bool{}
			for k, b := range bound {
				localBound[k] = b
			}
			if idx, ok := v["output_idx"].([]any); ok {
				for _, s := range idx {
					if name, ok := s.(string); ok {
						localBound[name] = true
					}
				}
			}
			if rng, ok := v["ranges"].(map[string]any); ok {
				for name := range rng {
					localBound[name] = true
				}
			}
		}
		out := make(map[string]any, len(v))
		for k, val := range v {
			switch k {
			case "op", "wrt", "dim", "fn", "name", "value", "table", "output",
				"reduce", "semiring", "manifold", "label", "attrs", "ranges",
				"regions", "output_idx", "distinct", "shape", "perm", "axis", "id":
				// Sidecar / non-reference slots: carried verbatim, exactly the
				// slots a reference rewrite must not touch (see
				// mapExprRefChildren).
				out[k] = val
			case "join":
				binders := map[string]bool{}
				if idx, ok := v["output_idx"].([]any); ok {
					for _, s := range idx {
						if name, ok := s.(string); ok {
							binders[name] = true
						}
					}
				}
				if rng, ok := v["ranges"].(map[string]any); ok {
					for name := range rng {
						binders[name] = true
					}
				}
				if clauses, ok := val.([]any); ok {
					out[k] = namespaceJoinNames(clauses, binders, prefix, localNames)
				} else {
					out[k] = val
				}
			default:
				out[k] = scopeTemplateBody(val, prefix, localNames, localBound)
			}
		}
		return out
	default:
		return raw
	}
}

// mergedTemplateRegistry is the MERGED expression-template registry of the
// flattened representation (esm-spec §9.6.4 rule 7, §10.7; esm-libraries-spec
// §4.7.5 step 4). Union of the per-component registries, in this order:
//
//  1. SCOPE, THEN UNION. Each MODEL block's bodies are component-scoped first
//     (scopeTemplateBody), because the dedup below compares POST-scoping bodies.
//     Reaction-system blocks pass through unscoped BY POLICY, mirroring the
//     reference bindings: a rate-law reference is expanded eagerly at collect, so
//     a reaction-system entry is never resolved against the post-flatten scope —
//     it rides along so the reconstituted document round-trips.
//  2. DEEP-EQUAL DEDUP AT FIRST OCCURRENCE — two components importing one
//     stencil keep one entry under the bare name.
//  3. COLLISION RENAME — a same-name entry whose occurrences are not all
//     deep-equal renames to `<ComponentPath>.<name>` in EVERY owning component,
//     and the rename PROPAGATES along the reference DAG (registryCollisionNames)
//     so no surviving body holds a reference the merged registry cannot resolve.
//
// `match` rules are excluded: only match-less templates are referenceable
// (§9.6.2), so only they can be merged. Components are walked in DOCUMENT order
// (models in file order, then reaction systems), which is what makes "first
// occurrence" mean the first occurrence in the file.
func mergedTemplateRegistry(file *ESMFile) []FlattenedTemplate {
	if len(file.componentTemplates) == 0 {
		return nil
	}

	// Document order: models as the file declares them, then reaction systems,
	// then any component key the typed file no longer holds.
	var orderedKeysList []string
	seenKey := map[string]bool{}
	addKey := func(k string) {
		if !seenKey[k] {
			seenKey[k] = true
			orderedKeysList = append(orderedKeysList, k)
		}
	}
	for _, n := range orderedKeys(file.Models, file.declarationOrder("/models")) {
		addKey("models." + n)
	}
	for _, n := range orderedKeys(file.ReactionSystems, file.declarationOrder("/reaction_systems")) {
		addKey("reaction_systems." + n)
	}
	for _, k := range sortedKeys(file.componentTemplates) {
		addKey(k)
	}

	type occurrence struct {
		path string
		decl any
	}
	byname := map[string][]occurrence{}
	var bynameOrder []string
	for _, compKey := range orderedKeysList {
		block, ok := file.componentTemplates[compKey]
		if !ok || block == nil {
			continue
		}
		section, cname, _ := strings.Cut(compKey, ".")
		localNames := map[string]bool{}
		if section == "models" {
			if model, ok := file.Models[cname]; ok {
				for k := range model.Variables {
					localNames[k] = true
				}
				for k := range model.Subsystems {
					localNames[k] = true
				}
			}
		}
		for _, tname := range block.keys {
			decl := block.get(tname)
			declMap, isMap := decl.(map[string]any)
			if isMap {
				if m, has := declMap["match"]; has && m != nil {
					continue // match rules are not referenceable, so not merged
				}
			}
			scoped := decl
			if isMap && section == "models" {
				if body, has := declMap["body"]; has && body != nil {
					scope := map[string]bool{}
					for k := range localNames {
						scope[k] = true
					}
					if params, ok := declMap["params"].([]any); ok {
						for _, p := range params {
							if ps, ok := p.(string); ok {
								delete(scope, ps)
							}
						}
					}
					next := make(map[string]any, len(declMap))
					for k, v := range declMap {
						next[k] = v
					}
					next["body"] = scopeTemplateBody(body, cname, scope, nil)
					scoped = next
				}
			}
			if _, seen := byname[tname]; !seen {
				bynameOrder = append(bynameOrder, tname)
			}
			byname[tname] = append(byname[tname], occurrence{path: cname, decl: scoped})
		}
	}
	if len(bynameOrder) == 0 {
		return nil
	}

	// registryCollisionNames works over the orderedMap shape the Option-B
	// registry merge uses; hand it the same [path, decl] pairs.
	grouped := newOrderedMap()
	for _, name := range bynameOrder {
		occ := make([]any, 0, len(byname[name]))
		for _, o := range byname[name] {
			occ = append(occ, [2]any{o.path, o.decl})
		}
		grouped.set(name, occ)
	}
	collide := registryCollisionNames(grouped)

	merged := newOrderedMap()
	rename := map[string]map[string]string{} // path => (old => new)
	for _, name := range bynameOrder {
		occ := byname[name]
		if !collide[name] {
			merged.set(name, occ[0].decl) // deep-equal dedup at first occurrence
			continue
		}
		for _, o := range occ {
			newname := o.path + "." + name
			merged.set(newname, o.decl)
			if rename[o.path] == nil {
				rename[o.path] = map[string]string{}
			}
			rename[o.path][name] = newname
		}
	}
	// A renamed body's own nested references follow ITS OWNER's map, so a
	// per-owner wrapper reaches its owner's leaf and never the other owner's.
	for _, path := range sortedKeys(rename) {
		for _, oldName := range sortedKeys(rename[path]) {
			newName := rename[path][oldName]
			if merged.has(newName) {
				merged.set(newName, renameApplyRefs(merged.get(newName), rename[path]))
			}
		}
	}

	out := make([]FlattenedTemplate, 0, len(merged.keys))
	for _, name := range merged.keys {
		out = append(out, FlattenedTemplate{Name: name, Declaration: merged.get(name)})
	}
	return out
}
