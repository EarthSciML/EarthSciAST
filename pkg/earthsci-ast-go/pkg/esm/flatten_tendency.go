package esm

// Right-hand-side structural time-derivative resolution (esm-spec §4.2), run by
// Flatten as esm-libraries-spec §4.7.5 step 3a. Mirrors the Rust
// `flatten::resolve_rhs_time_derivatives`, the Python
// `_resolve_rhs_time_derivatives` and the Julia `_resolve_rhs_time_derivatives!`.

// isStructuralTimeDerivative reports whether node is the STRUCTURAL time
// derivative: `D` with `wrt: "t"` or no `wrt`, applied to a single operand. A
// spatial `D` is a rewrite target (esm-spec §9.6.8) and is not this.
func isStructuralTimeDerivative(node ExprNode) bool {
	return node.Op == OpDerivative && len(node.Args) == 1 && !isRewriteTargetDerivative(node)
}

// structuralDerivativeTarget is the bare name a structural `D` differentiates,
// or "" when expr is not one or its operand is not a bare reference.
func structuralDerivativeTarget(expr Expression) string {
	node, ok := asExprNode(expr)
	if !ok || !isStructuralTimeDerivative(node) {
		return ""
	}
	s, _ := node.Args[0].(string)
	return s
}

// hasStructuralTimeDerivative reports whether expr carries a structural `D`
// anywhere.
func hasStructuralTimeDerivative(expr Expression) bool {
	found := false
	walkExprNodes(expr, func(n ExprNode) {
		if isStructuralTimeDerivative(n) {
			found = true
		}
	})
	return found
}

// resolveRHSTimeDerivatives rewrites every right-hand-side structural time
// derivative into the tendency the flattened system already defines for it.
//
// A `D(x, t)` over a STATE is x's own `D(x)/dt ~ f`, with any `D` inside f
// resolved in turn; over an OBSERVED `y ~ g` it is the resolution of g (the
// chain rule); over a parameter or a literal it is 0; and `+`, unary and binary
// `-`, `neg`, n-ary `*` and binary `/` distribute by the sum, product and
// quotient rules. Every other shape, and every cyclic chain, resolves to
// nothing and is left exactly as authored: §4.2 forbids inventing a value for
// it, in particular 0. Left-hand sides are never rewritten.
//
// It runs after the coupling rules and the pointwise lift, over the equation
// list as it stands then, because it reads that list: before reaction lowering a
// scoped `D(Chem.A, t)` names no tendency, before namespacing the tables are
// keyed by the wrong names, and before `operator_compose` a merged state's
// tendency is only its first contributing term.
func resolveRHSTimeDerivatives(flat *FlattenedSystem) {
	r := derivTables{
		tendency:      map[string]Expression{},
		definition:    map[string]Expression{},
		timeInvariant: map[string]bool{},
	}
	for _, eq := range flat.Equations {
		if name := structuralDerivativeTarget(eq.LHS); name != "" {
			r.tendency[name] = eq.RHS
		} else if name, ok := eq.LHS.(string); ok {
			// A bare-variable LHS is a DEFINING equation (esm-spec §6.3.1's
			// observed / algebraic form); its right-hand side is what the chain
			// rule differentiates.
			r.definition[name] = eq.RHS
		}
	}
	if len(r.tendency) == 0 && len(r.definition) == 0 {
		return
	}
	for _, p := range flat.Parameters {
		r.timeInvariant[p.Name] = true
	}
	for i, eq := range flat.Equations {
		if !hasStructuralTimeDerivative(eq.RHS) {
			continue
		}
		// The quantity this equation DEFINES is not available to substitute into
		// its own right-hand side; seeding `active` with it is what makes
		// `D(x)/dt ~ k*D(x, t)` and `y ~ D(y, t)` terminate as unresolved rather
		// than expand forever.
		var active []string
		if own := structuralDerivativeTarget(eq.LHS); own != "" {
			active = append(active, own)
		} else if own, ok := eq.LHS.(string); ok {
			active = append(active, own)
		}
		flat.Equations[i].RHS = r.substitute(eq.RHS, &active)
	}
}

// derivTables holds what resolveRHSTimeDerivatives reads: each state's
// tendency, each observed's definition, and the names whose derivative is 0.
// A name in none of the three is unresolvable rather than zero.
type derivTables struct {
	tendency      map[string]Expression
	definition    map[string]Expression
	timeInvariant map[string]bool
}

// substitute rewrites every structural `D` inside expr, leaving the ones deriv
// cannot answer exactly as authored.
func (r derivTables) substitute(expr Expression, active *[]string) Expression {
	node, ok := asExprNode(expr)
	if !ok {
		return expr
	}
	if isStructuralTimeDerivative(node) {
		if out, ok := r.deriv(node.Args[0], active); ok {
			return out
		}
		return expr
	}
	out, err := mapExprRefChildren(node, func(child Expression) (Expression, error) {
		return r.substitute(child, active), nil
	})
	if err != nil {
		return expr
	}
	return out
}

// deriv is d/dt of expr, with ok false when this format does not define it.
func (r derivTables) deriv(expr Expression, active *[]string) (Expression, bool) {
	if name, ok := expr.(string); ok {
		for _, a := range *active {
			if a == name {
				return nil, false // a cycle: stop here and leave the node standing
			}
		}
		if f, ok := r.tendency[name]; ok {
			*active = append(*active, name)
			out := r.substitute(f, active)
			*active = (*active)[:len(*active)-1]
			return out, true
		}
		if g, ok := r.definition[name]; ok {
			// CHAIN RULE: an observed's total time derivative is its defining
			// right-hand side differentiated by this same rule, one level down.
			*active = append(*active, name)
			out, ok := r.deriv(g, active)
			*active = (*active)[:len(*active)-1]
			return out, ok
		}
		if r.timeInvariant[name] {
			return derivZero(), true
		}
		return nil, false
	}
	if _, ok := exprNumber(expr); ok {
		return derivZero(), true
	}
	node, ok := asExprNode(expr)
	if !ok {
		return nil, false
	}
	args := node.Args
	switch {
	case node.Op == "+":
		terms := make([]Expression, 0, len(args))
		for _, a := range args {
			da, ok := r.deriv(a, active)
			if !ok {
				return nil, false
			}
			terms = append(terms, da)
		}
		return derivSum(terms), true
	case node.Op == "-" && len(args) == 1, node.Op == "neg" && len(args) == 1:
		da, ok := r.deriv(args[0], active)
		if !ok {
			return nil, false
		}
		return derivNegate(da), true
	case node.Op == "-" && len(args) == 2:
		da, ok := r.deriv(args[0], active)
		if !ok {
			return nil, false
		}
		db, ok := r.deriv(args[1], active)
		if !ok {
			return nil, false
		}
		return derivDifference(da, db), true
	case node.Op == "*":
		// Product rule over an n-ary `*`: one term per factor, that factor
		// differentiated and the others left alone.
		terms := make([]Expression, 0, len(args))
		for i, a := range args {
			da, ok := r.deriv(a, active)
			if !ok {
				return nil, false
			}
			if isNumericZero(da) {
				continue
			}
			factors := []Expression{da}
			for j, b := range args {
				if i != j {
					factors = append(factors, b)
				}
			}
			terms = append(terms, derivProduct(factors))
		}
		return derivSum(terms), true
	case node.Op == "/" && len(args) == 2:
		u, v := args[0], args[1]
		du, ok := r.deriv(u, active)
		if !ok {
			return nil, false
		}
		dv, ok := r.deriv(v, active)
		if !ok {
			return nil, false
		}
		if isNumericZero(dv) {
			// v is constant in t, so (u/v)' = u'/v, which keeps the common
			// `D(x, t)/c` shape small.
			return derivQuotient(du, v), true
		}
		num := derivDifference(derivProduct([]Expression{du, v}), derivProduct([]Expression{u, dv}))
		return derivQuotient(num, derivProduct([]Expression{v, v})), true
	}
	return nil, false
}

// The folding constructors below keep the derivative expressions identical to
// the other bindings'. Folding is not cosmetic: a parameter and a literal both
// differentiate to 0, so an unfolded product rule would emit `0*x` terms and
// `D(k, t)` would be a sum of zeros rather than the literal 0.

func derivZero() Expression { return 0.0 }

func derivSum(terms []Expression) Expression {
	kept := make([]any, 0, len(terms))
	for _, t := range terms {
		if !isNumericZero(t) {
			kept = append(kept, t)
		}
	}
	switch len(kept) {
	case 0:
		return derivZero()
	case 1:
		return kept[0]
	}
	return ExprNode{Op: "+", Args: kept}
}

func derivNegate(a Expression) Expression {
	if isNumericZero(a) {
		return derivZero()
	}
	if v, ok := exprNumber(a); ok {
		return -v
	}
	// Unary `-`, not `neg`: both spell negation, and this is the spelling the
	// other bindings emit.
	return ExprNode{Op: "-", Args: []any{a}}
}

func derivDifference(a, b Expression) Expression {
	if isNumericZero(b) {
		return a
	}
	if isNumericZero(a) {
		return derivNegate(b)
	}
	return ExprNode{Op: "-", Args: []any{a, b}}
}

func derivProduct(factors []Expression) Expression {
	for _, f := range factors {
		if isNumericZero(f) {
			return derivZero()
		}
	}
	kept := make([]any, 0, len(factors))
	for _, f := range factors {
		if !isNumericOne(f) {
			kept = append(kept, f)
		}
	}
	switch len(kept) {
	case 0:
		return 1.0
	case 1:
		return kept[0]
	}
	return ExprNode{Op: "*", Args: kept}
}

func derivQuotient(a, b Expression) Expression {
	if isNumericZero(a) {
		return derivZero()
	}
	return ExprNode{Op: "/", Args: []any{a, b}}
}
