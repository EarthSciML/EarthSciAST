package esm

// esm 2.4.0 units of defined operators (esm-spec §4.2, §4.8.3, §9.6.12
// "Units"):
//
//   - `partial(f, b…; wrt: x)` has the unit [f]/[x] and `integral(f; var: v)`
//     has [f]·[v] — fixed unit expressions that hold resolved or not; a
//     coordinate with no declared unit makes the result undeterminable, and
//     trailing operands are walked for findings only.
//   - A reference to a definition has its body's unit, per instance, without
//     expanding anything; when the definition carries a `units` expression,
//     the call's unit is that expression evaluated from what the call binds,
//     and the body's unit is checked against it (`definition_unit_mismatch`:
//     an error when the body's unit is determinable and differs, a warning
//     when it is undeterminable).
//
// Go's typed load expands references after lowering, so the validator types a
// model equation whose references reach a unit-bearing definition from the
// reference-preserving form the load captured (loweredUnitEquation). Mirrors
// the Julia `_partial_rule`, `_integral_rule`, `_definition_call_unit!`.

import (
	"encoding/json"
	"fmt"
	"sort"
)

// defUnitFinding is one definition-unit finding: an error, or (warning) the
// body's unit being undeterminable.
type defUnitFinding struct {
	msg     string
	warning bool
}

// loweredUnitEquation is a model equation in its reference-preserving
// (lowered) form, with the raw registry entries its references reach.
type loweredUnitEquation struct {
	LHS, RHS Expression
	registry map[string]any
}

// axisUnit is the declared unit of the coordinate named by axis, or nil.
func axisUnit(env map[string]Unit, axis *string) *Unit {
	if axis == nil {
		return nil
	}
	u, ok := env[*axis]
	if !ok {
		return nil
	}
	return &u
}

// partialUnit is the fixed unit of `partial`: [f]/[wrt].
func (ut unitTyper) partialUnit(node ExprNode, env map[string]Unit) (*Unit, error) {
	if len(node.Args) == 0 {
		return nil, nil
	}
	f, err := ut.propagate(node.Args[0], env)
	if err != nil {
		return nil, err
	}
	for _, a := range node.Args[1:] {
		if _, err := ut.propagate(a, env); err != nil {
			return nil, err
		}
	}
	w := axisUnit(env, node.Wrt)
	if f == nil || w == nil {
		return nil, nil
	}
	r, err := f.DivideChecked(*w)
	if err != nil {
		return nil, exponentOverflowErr(node.Op)
	}
	return &r, nil
}

// integralUnit is the fixed unit of `integral`: [f]·[var].
func (ut unitTyper) integralUnit(node ExprNode, env map[string]Unit) (*Unit, error) {
	if len(node.Args) == 0 {
		return nil, nil
	}
	f, err := ut.propagate(node.Args[0], env)
	if err != nil {
		return nil, err
	}
	v := axisUnit(env, node.Var)
	if f == nil || v == nil {
		return nil, nil
	}
	r, err := f.MultiplyChecked(*v)
	if err != nil {
		return nil, exponentOverflowErr(node.Op)
	}
	return &r, nil
}

// rawToExpression converts a raw JSON value (a reference's binding, a
// definition's body) to an Expression.
func rawToExpression(v any) Expression {
	switch t := v.(type) {
	case map[string]any, []any:
		b, err := json.Marshal(t)
		if err != nil {
			return nil
		}
		e, err := UnmarshalExpression(b)
		if err != nil {
			return nil
		}
		return normalizeExpression(e)
	case json.Number:
		return normalizeJSONNumber(t)
	}
	return v
}

func sameUnit(a, b *Unit) bool {
	return a.Dim.Equal(b.Dim) && a.Exact.Equal(b.Exact)
}

func unitText(u *Unit) string {
	if u == nil {
		return "undeterminable"
	}
	return fmt.Sprintf("%s (scale %s)", u.Dim, u.Exact)
}

// referenceUnit types a reference to a definition (esm-spec §9.6.12 "Units"):
// its body's unit with each parameter standing for what the call binds, then
// the definition's unit expression (and the fixed expression of `partial` /
// `integral`), recording definition-unit findings.
func (ut unitTyper) referenceUnit(node ExprNode, env map[string]Unit) (*Unit, error) {
	if node.Name == nil || ut.defs == nil {
		return nil, nil
	}
	decl, ok := ut.defs[*node.Name].(map[string]any)
	if !ok {
		return nil, nil
	}
	params := templateParams(decl)
	pset := map[string]bool{}
	for _, p := range params {
		pset[p] = true
	}
	// The unit each parameter stands for at this call.
	punits := map[string]*Unit{}
	for _, p := range params {
		b, ok := node.Bindings[p]
		if !ok {
			continue
		}
		u, err := ut.propagate(rawToExpression(b), env)
		if err != nil {
			return nil, err
		}
		punits[p] = u
	}
	// The body, in an env where each parameter has its bound unit (and no
	// other: a parameter shadows a component variable of the same name).
	benv := make(map[string]Unit, len(env)+len(params))
	for k, v := range env {
		if !pset[k] {
			benv[k] = v
		}
	}
	for p, u := range punits {
		if u != nil {
			benv[p] = *u
		}
	}
	bodyU, err := ut.propagate(rawToExpression(decl["body"]), benv)
	if err != nil {
		return nil, err
	}
	uexpr, hasU := decl["units"]
	fixed := fixedUnitExpr(decl)
	if (!hasU || uexpr == nil) && fixed == nil {
		return bodyU, nil
	}
	punit := func(p string) *Unit { return punits[p] }
	var declared, fixedU *Unit
	if hasU && uexpr != nil {
		declared = evalUnitExpr(uexpr, pset, punit, env)
	}
	if fixed != nil {
		fixedU = evalUnitExpr(fixed, pset, punit, env)
	}
	defines, _ := decl["defines"].(string)
	type want struct {
		what string
		u    *Unit
	}
	for _, w := range []want{{"its unit expression", declared},
		{fmt.Sprintf("the fixed unit expression of '%s'", defines), fixedU}} {
		if w.u == nil {
			continue
		}
		if bodyU == nil {
			ut.addDefFinding(defUnitFinding{warning: true, msg: fmt.Sprintf(
				"%s (warning): the body of definition '%s' has an undeterminable unit, so it cannot be "+
					"checked against %s ('%s') (esm-spec §9.6.12)",
				codeDefinitionUnitMismatch, *node.Name, w.what, unitText(w.u))})
		} else if !sameUnit(bodyU, w.u) {
			ut.addDefFinding(defUnitFinding{msg: fmt.Sprintf(
				"%s: the body of definition '%s' has unit '%s', but %s gives '%s' (esm-spec §9.6.12)",
				codeDefinitionUnitMismatch, *node.Name, unitText(bodyU), w.what, unitText(w.u))})
		}
	}
	if declared != nil && fixedU != nil && !sameUnit(declared, fixedU) {
		ut.addDefFinding(defUnitFinding{msg: fmt.Sprintf(
			"%s: the unit expression of definition '%s' gives '%s', but the fixed unit expression of "+
				"'%s' gives '%s' (esm-spec §4.2)",
			codeDefinitionUnitMismatch, *node.Name, unitText(declared), defines, unitText(fixedU))})
	}
	if hasU && uexpr != nil && declared != nil {
		return declared, nil
	}
	if fixed != nil && fixedU != nil {
		return fixedU, nil
	}
	return bodyU, nil
}

func (ut unitTyper) addDefFinding(f defUnitFinding) {
	if ut.defFindings == nil {
		return
	}
	for _, g := range *ut.defFindings {
		if g == f {
			return
		}
	}
	*ut.defFindings = append(*ut.defFindings, f)
}

// fixedUnitExpr is the fixed unit expression of `partial` / `integral`
// (esm-spec §4.2) a definition of either must agree with, read off its
// `match` pattern: the pattern's operand over (or times) its axis field.
func fixedUnitExpr(decl map[string]any) any {
	m, ok := decl["match"].(map[string]any)
	if !ok {
		return nil
	}
	args, ok := m["args"].([]any)
	if !ok || len(args) == 0 {
		return nil
	}
	switch m["op"] {
	case opPartial:
		if w, ok := m["wrt"]; ok && w != nil {
			return map[string]any{"op": "/", "args": []any{args[0], w}}
		}
	case "integral":
		if v, ok := m["var"]; ok && v != nil {
			return map[string]any{"op": "*", "args": []any{args[0], v}}
		}
	}
	return nil
}

// evalUnitExpr evaluates a definition's unit expression (raw JSON over
// params, names, unit-bearing `const`, `*`, `/` (binary) and `^` with a
// numeric exponent). nil when undeterminable.
func evalUnitExpr(x any, params map[string]bool, punit func(string) *Unit, env map[string]Unit) *Unit {
	switch v := x.(type) {
	case string:
		if params[v] {
			return punit(v)
		}
		if u, ok := env[v]; ok {
			return &u
		}
		return nil
	case bool:
		return nil
	case map[string]any:
		op, _ := v["op"].(string)
		if op == OpConst {
			if us, ok := v["units"].(string); ok {
				u, err := ParseUnit(us)
				if err != nil {
					return nil
				}
				return &u
			}
			return &Unit{Scale: 1}
		}
		args, ok := v["args"].([]any)
		if !ok {
			return nil
		}
		switch op {
		case "*", "/":
			if len(args) == 0 || (op == "/" && len(args) != 2) {
				return nil
			}
			vals := make([]*Unit, len(args))
			for i, a := range args {
				vals[i] = evalUnitExpr(a, params, punit, env)
				if vals[i] == nil {
					return nil
				}
			}
			r := *vals[0]
			for _, u := range vals[1:] {
				var err error
				if op == "*" {
					r, err = r.MultiplyChecked(*u)
				} else {
					r, err = r.DivideChecked(*u)
				}
				if err != nil {
					return nil
				}
			}
			return &r
		case "^":
			if len(args) != 2 {
				return nil
			}
			b := evalUnitExpr(args[0], params, punit, env)
			e, isNum := asNumber(args[1])
			if b == nil || !isNum {
				return nil
			}
			rat, err := ratFromFloat(e)
			if err != nil {
				return nil
			}
			r, err := b.PowerRatChecked(rat)
			if err != nil {
				return nil
			}
			return &r
		}
		return nil
	}
	if _, ok := asNumber(x); ok {
		return &Unit{Scale: 1}
	}
	return nil
}

// definitionUnitBearing reports whether any definition the references of
// expr reach (transitively through bodies) carries a unit expression or a
// fixed unit expression.
func definitionUnitBearing(expr any, registry map[string]any) bool {
	reached := map[string]bool{}
	reachedDefinitions(reached, expr, registry)
	for n := range reached {
		d, _ := registry[n].(map[string]any)
		if _, has := d["units"]; has {
			return true
		}
		if fixedUnitExpr(d) != nil {
			return true
		}
	}
	return false
}

// captureLoweredUnitEquations records, from the lowered (reference-preserving)
// view, every top-level model equation whose references reach a unit-bearing
// definition, keyed by its JSON pointer, with the reached registry entries.
func captureLoweredUnitEquations(view map[string]any) map[string]loweredUnitEquation {
	models, _ := view["models"].(map[string]any)
	var out map[string]loweredUnitEquation
	for _, mname := range sortedKeys(models) {
		comp, ok := models[mname].(map[string]any)
		if !ok {
			continue
		}
		reg, _ := comp["operators"].(map[string]any)
		if len(reg) == 0 {
			continue
		}
		eqs, _ := comp["equations"].([]any)
		for i, raw := range eqs {
			eq, ok := raw.(map[string]any)
			if !ok || !definitionUnitBearing(eq, reg) {
				continue
			}
			reached := map[string]bool{}
			reachedDefinitions(reached, eq, reg)
			names := make([]string, 0, len(reached))
			for n := range reached {
				names = append(names, n)
			}
			sort.Strings(names)
			sub := make(map[string]any, len(names))
			for _, n := range names {
				sub[n] = deepCopyJSON(reg[n])
			}
			if out == nil {
				out = map[string]loweredUnitEquation{}
			}
			out[fmt.Sprintf("/models/%s/equations/%d", mname, i)] = loweredUnitEquation{
				LHS:      rawToExpression(deepCopyJSON(eq["lhs"])),
				RHS:      rawToExpression(deepCopyJSON(eq["rhs"])),
				registry: sub,
			}
		}
	}
	return out
}

// definitionUnitFindings files the definition-unit findings of one equation
// site: errors as `definition_unit_mismatch` structural errors, warnings as
// `definition_unit_mismatch` unit warnings.
func definitionUnitFindings(findings []defUnitFinding, path string, result *StructuralValidationResult) {
	for _, f := range findings {
		if f.warning {
			result.UnitWarnings = append(result.UnitWarnings, UnitWarning{
				Path: path, Code: codeDefinitionUnitMismatch, Message: f.msg,
			})
			continue
		}
		result.StructuralErrors = append(result.StructuralErrors, StructuralError{
			Path: path, Code: codeDefinitionUnitMismatch, Message: f.msg, Details: map[string]any{},
		})
	}
}
