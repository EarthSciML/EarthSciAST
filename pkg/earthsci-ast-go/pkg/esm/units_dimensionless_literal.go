package esm

// The esm-spec §4.8.6 warning stage: bare numeric literals read as
// dimensionless.
//
// Every check site is typed under both literal rules (see unitTyper). Where the
// dimensionless-literal rule finds a provable mismatch and the current
// neutral-literal rule does not, the site carries one
// UnitFindingDimensionlessLiteral warning. The warning is never promoted to a
// structural error, so validity is decided by the current rule alone.

import (
	"fmt"
	"strconv"
	"strings"
)

// dimensionlessLiteralFindings returns the §4.8.6 warnings for file, in
// document order (models then reaction systems, each in sorted name order).
//
// The check sites are each equation of every TOP-LEVEL model
// (`/models/<M>/equations/<i>`) and each reaction rate of every TOP-LEVEL
// reaction system (`/reaction_systems/<S>/reactions/<i>`). Each component is
// typed in the unit environment the current-rule check already uses for it:
// its declared units (unparseable declarations skipped) plus its scoped
// references.
func dimensionlessLiteralFindings(file *ESMFile, scoped *scopedUnitIndex) []UnitWarning {
	var out []UnitWarning
	current := unitTyper{}
	candidate := unitTyper{dimensionlessLiterals: true}

	visit := func(pointer string, env map[string]Unit, lhs, rhs Expression, hasLHS bool) {
		found := candidate.siteMismatch(lhs, rhs, hasLHS, env)
		if found == "" || current.siteMismatch(lhs, rhs, hasLHS, env) != "" {
			return
		}
		exprs := []Expression{rhs}
		if hasLHS {
			exprs = []Expression{lhs, rhs}
		}
		named := "(none determinable)"
		if lits := nonzeroLiterals(exprs); len(lits) > 0 {
			named = strings.Join(lits, ", ")
		}
		out = append(out, UnitWarning{
			Path: pointer,
			Code: UnitFindingDimensionlessLiteral,
			Message: fmt.Sprintf("%s: with bare numeric literals read as dimensionless (esm-spec §4.8.6), %s; "+
				"bare literal(s): %s. This becomes an error at the next major esm version; a literal that "+
				`carries a unit is written const(value, units "...") (esm-spec §4.8.5)`, pointer, found, named),
		})
	}

	for _, name := range sortedKeys(file.Models) {
		model := file.Models[name]
		env, _ := buildModelUnitEnv(&model)
		scoped.extend(env, model.Subsystems)
		for i, eq := range model.Equations {
			visit(fmt.Sprintf("/models/%s/equations/%d", escapeJSONPointerSegment(name), i), env, eq.LHS, eq.RHS, true)
		}
	}
	for _, name := range sortedKeys(file.ReactionSystems) {
		system := file.ReactionSystems[name]
		env, _ := buildSystemUnitEnv(&system)
		scoped.extend(env, system.Subsystems)
		for i, rx := range system.Reactions {
			if rx.Rate == nil {
				continue
			}
			visit(fmt.Sprintf("/reaction_systems/%s/reactions/%d", escapeJSONPointerSegment(name), i), env, nil, rx.Rate, false)
		}
	}
	return out
}

// siteMismatch is the first provable mismatch one check site produces under
// ut's literal rule, or "" when the site passes or is skipped. A site is an
// equation (hasLHS: every operator rule inside either side, then the two sides
// compared in dimension and exact scale when both are determinable) or a
// reaction rate (the operator rules inside rhs only). An analysis finding (an
// arity defect, say) is not a mismatch: it leaves that side undeterminable.
func (ut unitTyper) siteMismatch(lhs, rhs Expression, hasLHS bool, env map[string]Unit) string {
	var left *Unit
	if hasLHS {
		u, err := ut.propagate(lhs, env)
		if err != nil && findingCode(err) == UnitFindingDimensionalMismatch {
			return err.Error()
		}
		left = u
	}
	right, err := ut.propagate(rhs, env)
	if err != nil && findingCode(err) == UnitFindingDimensionalMismatch {
		return err.Error()
	}
	if !hasLHS || left == nil || right == nil || err != nil {
		return ""
	}
	if !left.Dim.Equal(right.Dim) {
		return fmt.Sprintf("LHS has dimension %s, RHS has dimension %s", left.Dim, right.Dim)
	}
	if !left.Exact.Equal(right.Exact) {
		return fmt.Sprintf("LHS has dimension %s at scale %s, RHS at scale %s", left.Dim, left.Exact, right.Exact)
	}
	return ""
}

// bareLiteralValue is the value of a bare numeric literal, a `const` without
// `units`, or a unary `+`/`-` of one (nested to any depth).
func bareLiteralValue(expr Expression) (float64, bool) {
	if v, ok := toFloat64Strict(expr); ok {
		return v, true
	}
	var node ExprNode
	switch e := expr.(type) {
	case ExprNode:
		node = e
	case *ExprNode:
		if e == nil {
			return 0, false
		}
		node = *e
	default:
		return 0, false
	}
	if node.Op == "const" && node.Units == nil {
		return toFloat64Strict(node.Value)
	}
	if (node.Op == "+" || node.Op == "-") && len(node.Args) == 1 {
		v, ok := bareLiteralValue(node.Args[0])
		if !ok {
			return 0, false
		}
		if node.Op == "-" {
			return -v, true
		}
		return v, true
	}
	return 0, false
}

// nonzeroLiterals lists the distinct nonzero bare literals in exprs, in walk
// order — what the §4.8.6 warning names.
func nonzeroLiterals(exprs []Expression) []string {
	var out []string
	seen := map[string]bool{}
	var walk func(Expression)
	walk = func(expr Expression) {
		if v, ok := bareLiteralValue(expr); ok {
			if v != 0 {
				text := strconv.FormatFloat(v, 'g', -1, 64)
				if !seen[text] {
					seen[text] = true
					out = append(out, text)
				}
			}
			return
		}
		var node ExprNode
		switch e := expr.(type) {
		case ExprNode:
			node = e
		case *ExprNode:
			if e == nil {
				return
			}
			node = *e
		default:
			return
		}
		for _, a := range node.Args {
			walk(a)
		}
		if node.Expr != nil {
			walk(node.Expr)
		}
		if node.Filter != nil {
			walk(node.Filter)
		}
		for _, v := range node.Values {
			walk(v)
		}
	}
	for _, e := range exprs {
		walk(e)
	}
	return out
}
