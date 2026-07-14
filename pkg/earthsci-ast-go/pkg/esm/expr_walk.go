package esm

import "encoding/json"

// expr_walk.go provides the single, field-preserving traversal primitive for
// the ExprNode operator tree. It exists to end the "N hand-rolled walkers, each
// covering a different subset of fields" hazard called out in the audit and
// already fixed on the Julia side by commit 20f632fd (route lowering through a
// field-preserving map_children). Every pass that rebuilds ExprNodes
// (canonicalize, substitute, lower_enums, expression folding, variable
// collection, …) should route its recursion through mapExprChildren so it can
// NEVER silently strip a field again.

// asExprNode normalizes the THREE on-heap spellings of an operator node — a
// value ExprNode, a *ExprNode, and a raw decoded map[string]interface{} that
// carries a string "op" — to a value ExprNode.
//
// It returns (node, true) for any of those and (ExprNode{}, false) for every
// other Expression shape: a bare string, a json.Number, an int64/float64, a
// bool, nil, a typed-nil *ExprNode, or a non-operator object. Callers use the
// bool to decide whether an Expression is an operator node worth recursing
// into, collapsing the paired `case ExprNode:` / `case *ExprNode:` switch arms
// that were scattered across the package.
//
// The raw-map arm matters for HAND-BUILT trees. UnmarshalExpression normalizes
// every expression-bearing field of a decoded document (see decode.go), so a
// loaded file never presents an operator node as a map — but a tree assembled
// in Go code, or one round-tripped through a generic map, still can. Accepting
// it here means no walker built on asExprNode/mapExprChildren can be blind to a
// subtree merely because of how it was spelled (audit G1/G3/G11/G15).
func asExprNode(e Expression) (ExprNode, bool) {
	switch v := e.(type) {
	case ExprNode:
		return v, true
	case *ExprNode:
		if v == nil {
			return ExprNode{}, false
		}
		return *v, true
	case map[string]any:
		if !isOperatorMap(v) {
			return ExprNode{}, false
		}
		b, err := json.Marshal(v)
		if err != nil {
			return ExprNode{}, false
		}
		expr, err := UnmarshalExpression(b)
		if err != nil {
			return ExprNode{}, false
		}
		node, ok := expr.(ExprNode)
		return node, ok
	default:
		return ExprNode{}, false
	}
}

// mapExprChildren returns a COPY of node with f applied to every child
// Expression reachable through an expression-bearing field, writing the results
// back into the copy. The first error f returns is propagated.
//
// Field preservation. The copy starts as `out := node`, so EVERY field is
// preserved by value up-front. Only the expression-bearing fields below are
// rebuilt (into freshly allocated slices/maps, so the input node is never
// mutated). All other fields — the operator name and the structural,
// non-Expression slots — ride through untouched:
//
//	Op, Wrt, Dim, Fn, Var, Name, Value, Table, Manifold, Reduce, Semiring,
//	Distinct, Arg, Shape, Perm, Axis, OutputIdx, Label, ID, ExpectCadence
//
// (Wrt/Dim/Fn/Var/Name/Table/Manifold/Reduce/Semiring/Arg/Label/ID/
// ExpectCadence are *string, Distinct a *bool, Value/Axis raw literals,
// Shape/Perm/OutputIdx structural index slices — none carry child Expressions,
// so f is intentionally NOT applied to them.)
//
// Fields walked (f applied to each child):
//
//	Args       []interface{}          — each element
//	Values     []interface{}          — each element (makearray per-region values)
//	Join       []interface{}          — each element (aggregate join clauses)
//	Lower      interface{}            — scalar (integral lower bound)
//	Upper      interface{}            — scalar (integral upper bound)
//	Output     interface{}            — scalar (table_lookup output selector)
//	Expr       interface{}            — scalar (aggregate/argmin/argmax body)
//	Filter     interface{}            — scalar (aggregate predicate)
//	Key        interface{}            — scalar (aggregate grouping key)
//	TableAxes  map[string]Expression  — each value (keys preserved)
//	Attrs      map[string]interface{} — each value (keys preserved)
//	Bindings   map[string]interface{} — each value (keys preserved)
//	Ranges     map[string]interface{} — each value (keys preserved)
//	Regions    [][][]interface{}      — each innermost bound leaf
//
// Nil fields are left nil. Maps are iterated in sorted-key order so that, when
// more than one child errors, the surfaced error is deterministic across runs
// (Go map iteration is randomized) — matching the sortedKeys discipline used by
// the raw-JSON walkers elsewhere in the package.
//
// Contract on f. Because several of the walked fields (Bindings, Ranges, Attrs,
// Regions, Values, and the aggregate scalars) hold RAW decoded JSON rather than
// UnmarshalExpression-normalized nodes — json.Number leaves, raw
// map[string]interface{}, nested []interface{} — f MUST be TOTAL over the
// Expression union: it must return any value it does not recognize unchanged
// (json.Number, bool, raw maps/slices, ExprNode, *ExprNode, string, the numeric
// leaves) rather than erroring on it. A partial f will misbehave on these
// fields.
//
// WARNING — MAINTENANCE INVARIANT: if a NEW Expression-bearing field is ever
// added to ExprNode (see types.go), it MUST be added to the walked set here,
// otherwise every pass built on mapExprChildren will silently strip it — the
// exact class of bug this helper exists to prevent.
func mapExprChildren(node ExprNode, f func(Expression) (Expression, error)) (ExprNode, error) {
	out := node
	var err error

	// mapSlice applies f to each element of a list-of-Expression field.
	mapSlice := func(s []any) ([]any, error) {
		if s == nil {
			return nil, nil
		}
		res := make([]any, len(s))
		for i, a := range s {
			r, e := f(a)
			if e != nil {
				return nil, e
			}
			res[i] = r
		}
		return res, nil
	}

	// mapStrIface applies f to each value of a map[string]interface{} field,
	// preserving keys and iterating in sorted order for deterministic errors.
	mapStrIface := func(m map[string]any) (map[string]any, error) {
		if m == nil {
			return nil, nil
		}
		res := make(map[string]any, len(m))
		for _, k := range sortedKeys(m) {
			r, e := f(m[k])
			if e != nil {
				return nil, e
			}
			res[k] = r
		}
		return res, nil
	}

	// --- scalar Expression fields (apply f when non-nil) ---
	scalars := []struct {
		src any
		dst *any
	}{
		{node.Lower, &out.Lower},
		{node.Upper, &out.Upper},
		{node.Output, &out.Output},
		{node.Expr, &out.Expr},
		{node.Filter, &out.Filter},
		{node.Key, &out.Key},
	}
	for _, s := range scalars {
		if s.src == nil {
			continue
		}
		var r Expression
		if r, err = f(s.src); err != nil {
			return out, err
		}
		*s.dst = r
	}

	// --- []interface{} (list-of-Expression) fields ---
	if out.Args, err = mapSlice(node.Args); err != nil {
		return out, err
	}
	if out.Values, err = mapSlice(node.Values); err != nil {
		return out, err
	}
	if out.Join, err = mapSlice(node.Join); err != nil {
		return out, err
	}

	// --- map fields (keys preserved) ---
	if node.TableAxes != nil {
		nt := make(map[string]Expression, len(node.TableAxes))
		for _, k := range sortedKeys(node.TableAxes) {
			var r Expression
			if r, err = f(node.TableAxes[k]); err != nil {
				return out, err
			}
			nt[k] = r
		}
		out.TableAxes = nt
	}
	if out.Attrs, err = mapStrIface(node.Attrs); err != nil {
		return out, err
	}
	if out.Bindings, err = mapStrIface(node.Bindings); err != nil {
		return out, err
	}
	if out.Ranges, err = mapStrIface(node.Ranges); err != nil {
		return out, err
	}

	// --- Regions [][][]interface{}: walk each innermost bound leaf ---
	if node.Regions != nil {
		nr := make([][][]any, len(node.Regions))
		for i, region := range node.Regions {
			if region == nil {
				continue
			}
			nreg := make([][]any, len(region))
			for j, pair := range region {
				if pair == nil {
					continue
				}
				npair := make([]any, len(pair))
				for k, b := range pair {
					var r Expression
					if r, err = f(b); err != nil {
						return out, err
					}
					npair[k] = r
				}
				nreg[j] = npair
			}
			nr[i] = nreg
		}
		out.Regions = nr
	}

	return out, nil
}
