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
//
// The pass can never fail validation: a panic inside it is recovered and
// reported as one analysis warning at the document root, after the warnings
// already found.
func dimensionlessLiteralFindings(file *ESMFile, scoped *scopedUnitIndex) (out []UnitWarning) {
	defer func() {
		if r := recover(); r != nil {
			out = append(out, UnitWarning{
				Path:    "",
				Code:    UnitFindingAnalysis,
				Message: fmt.Sprintf("the esm-spec §4.8.6 dimensionless-literal check stopped early: %v", r),
			})
		}
	}()
	current := unitTyper{}
	candidate := unitTyper{dimensionlessLiterals: true}

	// visit judges one site under both literal rules through the validator's
	// own site check (mismatch), recording a warning when only the
	// dimensionless-literal rule finds a provable mismatch.
	visit := func(pointer string, exprs []Expression, mismatch func(unitTyper) *UnitWarning) {
		lits := nonzeroLiterals(exprs)
		// With no nonzero literal the two rules type the site identically.
		if len(lits) == 0 {
			return
		}
		found := mismatch(candidate)
		if !isMismatch(found) || isMismatch(mismatch(current)) {
			return
		}
		out = append(out, UnitWarning{
			Path: pointer,
			Code: UnitFindingDimensionlessLiteral,
			Message: fmt.Sprintf("%s: with bare numeric literals read as dimensionless (esm-spec §4.8.6), %s; "+
				"bare literal(s): %s. This becomes an error at the next major esm version; a literal that "+
				`carries a unit is written const(value, units "...") (esm-spec §4.8.5)`,
				pointer, found.Message, strings.Join(lits, ", ")),
		})
	}
	visitEquations := func(pointer, field string, env map[string]Unit, eqs []Equation) {
		for i := range eqs {
			eq := &eqs[i]
			site := fmt.Sprintf("%s/%s/%d", pointer, field, i)
			visit(site, []Expression{eq.LHS, eq.RHS}, func(ut unitTyper) *UnitWarning {
				return ut.equationFinding(eq, env, site)
			})
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
			rate, site := rx.Rate, fmt.Sprintf("%s/reactions/%d", pointer, i)
			visit(site, []Expression{rate}, func(ut unitTyper) *UnitWarning {
				return ut.rateFinding(rate, env, site)
			})
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

// isMismatch reports whether a site check's finding is a provable mismatch. An
// analysis finding (an arity defect, say) is not one: it leaves the site
// undeterminable.
func isMismatch(w *UnitWarning) bool {
	return w != nil && w.Code == UnitFindingDimensionalMismatch
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
