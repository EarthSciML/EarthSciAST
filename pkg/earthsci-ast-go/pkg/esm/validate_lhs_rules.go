package esm

import (
	"encoding/json"
	"fmt"
	"strings"
)

// esm-spec §6.3.1 "What a left-hand side may name": an equation never defines
// a parameter (`equation_defines_parameter`), and an index symbol on a
// left-hand side must be bound by a `faq` there or, for the bare-index
// definition `index(V, k) ~ faq{k}(…)`, by the right-hand side's `output_idx`
// (`unbound_index_symbol`). Both are decided per equation from the model's own
// declarations, and walk inline subsystems too (held as raw JSON).

// lhsScope is one model's view for the two checks: each declared variable's
// type, its inline subsystems, and its equations.
type lhsScope struct {
	varType map[string]string
	subs    map[string]any
	lhs     []Expression
	rhs     []Expression
}

func lhsScopeOfModel(model *Model) lhsScope {
	sc := lhsScope{varType: map[string]string{}, subs: model.Subsystems}
	for name, v := range model.Variables {
		sc.varType[name] = v.Type
	}
	for _, eq := range model.Equations {
		sc.lhs = append(sc.lhs, eq.LHS)
		sc.rhs = append(sc.rhs, eq.RHS)
	}
	return sc
}

func lhsScopeOfRaw(raw map[string]any) lhsScope {
	sc := lhsScope{varType: map[string]string{}}
	if vars, ok := raw["variables"].(map[string]any); ok {
		for name, v := range vars {
			if vm, ok := v.(map[string]any); ok {
				t, _ := vm["type"].(string)
				sc.varType[name] = t
			}
		}
	}
	sc.subs, _ = raw["subsystems"].(map[string]any)
	if eqs, ok := raw["equations"].([]any); ok {
		for _, e := range eqs {
			em, ok := e.(map[string]any)
			if !ok {
				continue
			}
			sc.lhs = append(sc.lhs, em["lhs"])
			sc.rhs = append(sc.rhs, em["rhs"])
		}
	}
	return sc
}

// declaredType is the type of `name` as a local variable or as a scoped
// reference into an inline subsystem (optionally led by the model's own name),
// or "" when it names neither.
func (sc lhsScope) declaredType(modelName, name string) string {
	if t, ok := sc.varType[name]; ok {
		return t
	}
	parts := strings.Split(name, ".")
	if len(parts) > 1 && parts[0] == modelName {
		parts = parts[1:]
	}
	if len(parts) < 2 {
		return ""
	}
	subs := sc.subs
	var sub map[string]any
	for _, p := range parts[:len(parts)-1] {
		next, ok := subs[p].(map[string]any)
		if !ok {
			return ""
		}
		sub = next
		subs, _ = sub["subsystems"].(map[string]any)
	}
	vars, _ := sub["variables"].(map[string]any)
	v, _ := vars[parts[len(parts)-1]].(map[string]any)
	t, _ := v["type"].(string)
	return t
}

// lhsBaseName strips the `faq` / `index` addressing wrappers from a
// left-hand side and returns the variable it names, with whether a `D` or `ic`
// was met on the way (those define dynamics or an initial value, not the
// variable itself).
func lhsBaseName(e Expression) (string, bool) {
	for {
		if s, ok := e.(string); ok {
			return s, false
		}
		n, ok := asExprNode(e)
		if !ok {
			return "", false
		}
		switch n.Op {
		case "faq", "aggregate":
			e = n.Expr
		case "index":
			if len(n.Args) == 0 {
				return "", false
			}
			e = n.Args[0]
		case "D", "ic":
			return "", true
		default:
			return "", false
		}
	}
}

// lhsDefinedName is the variable a left-hand side defines, looking through
// `D` and `ic` as well as the addressing wrappers, for naming it in a message.
func lhsDefinedName(e Expression) string {
	for {
		if s, ok := e.(string); ok {
			return s
		}
		n, ok := asExprNode(e)
		if !ok {
			return ""
		}
		switch n.Op {
		case "faq", "aggregate":
			e = n.Expr
		case "index", "D", "ic":
			if len(n.Args) == 0 {
				return ""
			}
			e = n.Args[0]
		default:
			return ""
		}
	}
}

// lhsFreeSymbols collects, in order, the string subscripts of every `index`
// in `e` that are neither declared names nor bound by an enclosing `faq`.
func lhsFreeSymbols(e Expression, bound map[string]bool, declared func(string) bool, out *[]string) {
	n, ok := asExprNode(e)
	if !ok {
		return
	}
	switch n.Op {
	case "faq", "aggregate":
		inner := make(map[string]bool, len(bound)+len(n.Ranges))
		for k := range bound {
			inner[k] = true
		}
		for _, x := range n.OutputIdx {
			if s, ok := x.(string); ok {
				inner[s] = true
			}
		}
		for k := range n.Ranges {
			inner[k] = true
		}
		lhsFreeSymbols(n.Expr, inner, declared, out)
		for _, a := range n.Args {
			lhsFreeSymbols(a, inner, declared, out)
		}
		return
	case "index":
		if len(n.Args) == 0 {
			return
		}
		lhsFreeSymbols(n.Args[0], bound, declared, out)
		for _, a := range n.Args[1:] {
			if s, ok := a.(string); ok {
				if !bound[s] && !declared(s) {
					*out = append(*out, s)
				}
				continue
			}
			lhsFreeSymbols(a, bound, declared, out)
		}
		return
	}
	for _, a := range n.Args {
		lhsFreeSymbols(a, bound, declared, out)
	}
	if n.Expr != nil {
		lhsFreeSymbols(n.Expr, bound, declared, out)
	}
}

// rhsOutputIdx is the `output_idx` of a right-hand-side `faq`, the binder the
// bare-index definition takes its subscripts from.
func rhsOutputIdx(e Expression) map[string]bool {
	out := map[string]bool{}
	n, ok := asExprNode(e)
	if !ok || (n.Op != "faq" && n.Op != "aggregate") {
		return out
	}
	for _, x := range n.OutputIdx {
		if s, ok := x.(string); ok {
			out[s] = true
		}
	}
	return out
}

func (s *structuralScan) metaparameterNames() map[string]bool {
	out := map[string]bool{}
	if s.file == nil || len(s.file.Metaparameters) == 0 {
		return out
	}
	var m map[string]json.RawMessage
	if json.Unmarshal(s.file.Metaparameters, &m) == nil {
		for k := range m {
			out[k] = true
		}
	}
	return out
}

// validateLHSRules runs both checks over one model's equations and, recursively,
// over its inline subsystems.
func (s *structuralScan) validateLHSRules(modelName string, sc lhsScope, basePath string) {
	meta := s.metaparameterNames()
	declared := func(name string) bool {
		if name == s.indep || name == "t" || meta[name] {
			return true
		}
		_, ok := sc.varType[name]
		return ok
	}
	for i, lhs := range sc.lhs {
		path := fmt.Sprintf("%s/equations/%d/lhs", basePath, i)
		if base, dyn := lhsBaseName(lhs); !dyn && base != "" &&
			sc.declaredType(modelName, base) == VarTypeParameter {
			s.addErr(StructuralError{
				Path: path,
				Code: ErrorEquationDefinesParameter,
				Message: fmt.Sprintf("Equation %d defines '%s', which is a parameter; "+
					"an equation defines unknowns only", i, base),
				Details: map[string]any{"variable": base},
			})
		}
		var free []string
		lhsFreeSymbols(lhs, rhsOutputIdx(sc.rhs[i]), declared, &free)
		seen := map[string]bool{}
		for _, sym := range free {
			if seen[sym] {
				continue
			}
			seen[sym] = true
			s.addErr(StructuralError{
				Path: path,
				Code: ErrorUnboundIndexSymbol,
				Message: fmt.Sprintf("Equation %d (defining '%s') subscripts its left-hand side "+
					"with '%s', which no faq binds", i, lhsDefinedName(lhs), sym),
				Details: map[string]any{"symbol": sym, "variable": lhsDefinedName(lhs)},
			})
		}
	}
	for _, name := range sortedKeys(sc.subs) {
		sub, ok := sc.subs[name].(map[string]any)
		if !ok {
			continue
		}
		s.validateLHSRules(name, lhsScopeOfRaw(sub), fmt.Sprintf("%s/subsystems/%s", basePath, name))
	}
}
