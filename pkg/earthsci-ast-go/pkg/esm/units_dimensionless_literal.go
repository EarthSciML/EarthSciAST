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
// document order (models then reaction systems, each in sorted name order,
// a component's own sites before its subsystems').
//
// The check sites (esm-spec §4.8.6 "Check sites") are every model's
// `equations` and `initialization_equations` and every reaction system's
// `constraint_equations` and reaction rates, in each top-level component and
// in its inline subsystems at any depth; an unresolved `{ref}` mount is
// skipped. Each component is typed in the unit environment the current-rule
// check uses for it: its declared units (unparseable declarations skipped),
// its scoped references relative to its own subsystems, and the document's
// top-level scoped paths.
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
	visitEquations := func(pointer, field string, env map[string]Unit, eqs []Equation) {
		for i, eq := range eqs {
			visit(fmt.Sprintf("%s/%s/%d", pointer, field, i), env, eq.LHS, eq.RHS, true)
		}
	}

	var walkModel func(pointer string, model *Model)
	walkModel = func(pointer string, model *Model) {
		env, _ := buildModelUnitEnv(model)
		scoped.extend(env, model.Subsystems)
		visitEquations(pointer, "equations", env, model.Equations)
		visitEquations(pointer, "initialization_equations", env, model.InitializationEquations)
		for _, name := range sortedKeys(model.Subsystems) {
			if _, inline := subsystemAsMap(model.Subsystems[name]); !inline {
				continue
			}
			if sub, ok := decodeSubsystemAs[Model](model.Subsystems[name]); ok {
				walkModel(pointer+"/subsystems/"+escapeJSONPointerSegment(name), &sub)
			}
		}
	}
	var walkSystem func(pointer string, system *ReactionSystem)
	walkSystem = func(pointer string, system *ReactionSystem) {
		env, _ := buildSystemUnitEnv(system)
		scoped.extend(env, system.Subsystems)
		visitEquations(pointer, "constraint_equations", env, system.ConstraintEquations)
		for i, rx := range system.Reactions {
			if rx.Rate == nil {
				continue
			}
			visit(fmt.Sprintf("%s/reactions/%d", pointer, i), env, nil, rx.Rate, false)
		}
		for _, name := range sortedKeys(system.Subsystems) {
			if _, inline := subsystemAsMap(system.Subsystems[name]); !inline {
				continue
			}
			if sub, ok := decodeSubsystemAs[ReactionSystem](system.Subsystems[name]); ok {
				walkSystem(pointer+"/subsystems/"+escapeJSONPointerSegment(name), &sub)
			}
		}
	}

	for _, name := range sortedKeys(file.Models) {
		model := file.Models[name]
		walkModel("/models/"+escapeJSONPointerSegment(name), &model)
	}
	for _, name := range sortedKeys(file.ReactionSystems) {
		system := file.ReactionSystems[name]
		walkSystem("/reaction_systems/"+escapeJSONPointerSegment(name), &system)
	}
	return out
}

// siteMismatch is the first provable mismatch one check site produces under
// ut's literal rule, or "" when the site passes or is skipped. A site is an
// equation (hasLHS: every operator rule inside either side, then the two sides
// compared in dimension and exact scale when both are determinable) or a
// reaction rate (the operator rules inside rhs only). A derivative with
// respect to an undeclared independent variable is judged by the
// no-time-unit-reconciles rule instead of the side comparison. An analysis finding (an
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
	if !hasLHS || err != nil {
		return ""
	}
	// `D(x)` with respect to an undeclared independent variable is
	// undeterminable, so the sides are not compared directly; but whatever unit
	// that variable carries contributes only powers of time, so a ratio with
	// any other axis is provably irreconcilable (esm-spec §4.8.4).
	if state, undeclared := ut.derivativeStateDim(lhs, env); undeclared {
		if mismatch := derivativeTimeMismatch(state, right); mismatch != nil {
			return mismatch.Error()
		}
		return ""
	}
	if left == nil || right == nil {
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
