package esm

import (
	"math"
	"sort"
)

// esm 2.5.0: the one classification of initialization equations (esm-spec
// §11.4, §11.4.3) every caller shares — the loader's migration and `ic` check,
// validate's main balance and over-determination count, and flatten's split
// into FieldICs and InitializationEquations:
//
//   - an initialization equation mentions `ic` anywhere, on either side;
//   - an explicit initial condition has one side exactly ic(u), u a name, while
//     the other side mentions no `ic` (the mirrored e ~ ic(u) is one too).
//
// Also the counts validate takes (esm-spec §11.4.3, "What validate reports"):
// an equation's scalar size and a variable's cells.
//
// The functions take an expression in any of its in-memory spellings: a
// decoded map[string]any (the loader's wire view), an ExprNode or *ExprNode.

// exprChildren is every child of an operator node reachable through an
// expression-valued field: args, values, expr, filter, lower, upper, key and
// the values of bindings (in sorted key order). Nil for a leaf.
func exprChildren(e any) []any {
	switch v := e.(type) {
	case map[string]any:
		if _, isOp := v["op"].(string); !isOp {
			return nil
		}
		var out []any
		for _, k := range []string{"args", "values"} {
			if xs, ok := v[k].([]any); ok {
				out = append(out, xs...)
			}
		}
		for _, k := range []string{"expr", "filter", "lower", "upper", "key"} {
			if x, ok := v[k]; ok && x != nil {
				out = append(out, x)
			}
		}
		if b, ok := v["bindings"].(map[string]any); ok {
			for _, k := range sortedKeys(b) {
				out = append(out, b[k])
			}
		}
		return out
	case ExprNode:
		return typedExprChildren(&v)
	case *ExprNode:
		if v == nil {
			return nil
		}
		return typedExprChildren(v)
	}
	return nil
}

func typedExprChildren(n *ExprNode) []any {
	out := append(append([]any{}, n.Args...), n.Values...)
	for _, x := range []any{n.Expr, n.Filter, n.Lower, n.Upper, n.Key} {
		if x != nil {
			out = append(out, x)
		}
	}
	for _, k := range sortedKeys(n.Bindings) {
		out = append(out, n.Bindings[k])
	}
	return out
}

// exprOp is the op of an operator node in any spelling, "" for a leaf.
func exprOp(e any) string {
	switch v := e.(type) {
	case map[string]any:
		op, _ := v["op"].(string)
		return op
	case ExprNode:
		return v.Op
	case *ExprNode:
		if v != nil {
			return v.Op
		}
	}
	return ""
}

// exprArgs is the args of an operator node in any spelling.
func exprArgs(e any) []any {
	switch v := e.(type) {
	case map[string]any:
		a, _ := v["args"].([]any)
		return a
	case ExprNode:
		return v.Args
	case *ExprNode:
		if v != nil {
			return v.Args
		}
	}
	return nil
}

// icArgsOf collects the argument list of every `ic` node of e, in walk order.
func icArgsOf(e any, out [][]any) [][]any {
	if exprOp(e) == "ic" {
		out = append(out, exprArgs(e))
	}
	for _, c := range exprChildren(e) {
		out = icArgsOf(c, out)
	}
	return out
}

// mentionsIc reports whether e mentions `ic` anywhere.
func mentionsIc(e any) bool {
	if exprOp(e) == "ic" {
		return true
	}
	for _, c := range exprChildren(e) {
		if mentionsIc(c) {
			return true
		}
	}
	return false
}

// isInitializationEquation reports whether lhs ~ rhs mentions `ic`.
func isInitializationEquation(lhs, rhs any) bool {
	return mentionsIc(lhs) || mentionsIc(rhs)
}

// icTarget is u when side is exactly ic(u), u a name.
func icTarget(side any) (string, bool) {
	if exprOp(side) != "ic" {
		return "", false
	}
	args := exprArgs(side)
	if len(args) != 1 {
		return "", false
	}
	u, ok := args[0].(string)
	return u, ok
}

// explicitInitialCondition is the target and value of the explicit initial
// condition ic(u) ~ e or e ~ ic(u), e mentioning no `ic`; ok is false for any
// other equation.
func explicitInitialCondition(lhs, rhs any) (target string, value any, ok bool) {
	if u, isIc := icTarget(lhs); isIc && !mentionsIc(rhs) {
		return u, rhs, true
	}
	if u, isIc := icTarget(rhs); isIc && !mentionsIc(lhs) {
		return u, lhs, true
	}
	return "", nil, false
}

// indexSetSize is the size of a declared index set; ok is false when it has
// none or is not declared.
func indexSetSize(name any, sets map[string]IndexSet) (int, bool) {
	s, isName := name.(string)
	if !isName {
		return 0, false
	}
	set, ok := sets[s]
	switch {
	case !ok:
		return 0, false
	case set.Size != nil:
		return *set.Size, true
	case set.Members != nil:
		return len(set.Members), true
	}
	return 0, false
}

// faqRangeLength is the length of one `faq` range, {from: set} or a literal
// [lo, hi]; ok is false when it cannot be read.
func faqRangeLength(r any, sets map[string]IndexSet) (int, bool) {
	switch v := r.(type) {
	case map[string]any:
		if from, has := v["from"]; has {
			return indexSetSize(from, sets)
		}
	case []any:
		if len(v) != 2 {
			return 0, false
		}
		lo, ok1 := asNumber(v[0])
		hi, ok2 := asNumber(v[1])
		if ok1 && ok2 && lo == math.Trunc(lo) && hi == math.Trunc(hi) {
			return max(0, int(hi-lo)+1), true
		}
	}
	return 0, false
}

// faqCells is the number of cells of side when it is a `faq` with output
// indices (the product of its output ranges' lengths). isFaq is false when
// side is no such `faq`; ok is false when a range cannot be read.
func faqCells(side any, sets map[string]IndexSet) (n int, isFaq, ok bool) {
	if exprOp(side) != "faq" {
		return 0, false, false
	}
	var outIdx []any
	var ranges map[string]any
	switch v := side.(type) {
	case map[string]any:
		outIdx, _ = v["output_idx"].([]any)
		ranges, _ = v["ranges"].(map[string]any)
	case ExprNode:
		outIdx, ranges = v.OutputIdx, v.Ranges
	case *ExprNode:
		outIdx, ranges = v.OutputIdx, v.Ranges
	}
	if len(outIdx) == 0 {
		return 0, false, false
	}
	n = 1
	for _, idx := range outIdx {
		name, isName := idx.(string)
		if !isName {
			return 0, true, false
		}
		l, readable := faqRangeLength(ranges[name], sets)
		if !readable {
			return 0, true, false
		}
		n *= l
	}
	return n, true, true
}

// scalarEquationCount is the number of scalar equations lhs ~ rhs counts for
// (esm-spec §11.4.3): one per cell of a side that is a `faq` with output
// indices, else one. ok is false when that faq's ranges cannot be read.
func scalarEquationCount(lhs, rhs any, sets map[string]IndexSet) (int, bool) {
	if n, isFaq, ok := faqCells(lhs, sets); isFaq {
		return n, ok
	}
	if n, isFaq, ok := faqCells(rhs, sets); isFaq {
		return n, ok
	}
	return 1, true
}

// variableCells is the number of cells of a variable with the given shape;
// ok is false when an index set of it has no size.
func variableCells(shape *[]string, sets map[string]IndexSet) (int, bool) {
	n := 1
	if shape == nil {
		return n, true
	}
	for _, s := range *shape {
		size, ok := indexSetSize(s, sets)
		if !ok {
			return 0, false
		}
		n *= size
	}
	return n, true
}

// overdeterminedInitialization is validate's over-determination count for one
// model (esm-spec §11.4.3, "What validate reports"): its initialization
// equations that are not explicit initial conditions, counted in scalar
// equations, against the cells of the starting values they mention. A
// starting value counts all its cells unless an explicit initial condition of
// the model sets every one of them (an explicit faq over some cells removes
// none). validate cannot tell observeds, so ic(y) ~ 4 counts as explicit. ok is
// false when there is no finding: equations do not outnumber cells, or a
// needed extent cannot be read (an index set without a size, a scoped or
// undeclared name, ic(D(x))).
func overdeterminedInitialization(model *Model, sets map[string]IndexSet) (equations, cells int, unknowns []string, ok bool) {
	cellsOf := func(name string) (int, bool) {
		v, declared := model.Variables[name]
		if !declared {
			return 0, false
		}
		return variableCells(v.Shape, sets)
	}
	covered := map[string]bool{}
	var system []Equation
	for _, eq := range model.Equations {
		if !isInitializationEquation(eq.LHS, eq.RHS) {
			continue
		}
		target, value, explicit := explicitInitialCondition(eq.LHS, eq.RHS)
		if !explicit {
			system = append(system, eq)
			continue
		}
		n, isFaq, readable := faqCells(value, sets)
		if !isFaq {
			covered[target] = true
		} else if all, known := cellsOf(target); readable && known && n == all {
			covered[target] = true
		}
	}
	if len(system) == 0 {
		return 0, 0, nil, false
	}
	mentioned := map[string]bool{}
	for _, eq := range system {
		n, readable := scalarEquationCount(eq.LHS, eq.RHS, sets)
		if !readable {
			return 0, 0, nil, false
		}
		equations += n
		for _, args := range icArgsOf(eq.RHS, icArgsOf(eq.LHS, nil)) {
			name, isName := "", false
			if len(args) == 1 {
				name, isName = args[0].(string)
			}
			if !isName {
				return 0, 0, nil, false // ic(D(x)) reads whatever x's tendency reads
			}
			if !covered[name] {
				mentioned[name] = true
			}
		}
	}
	for name := range mentioned {
		n, known := cellsOf(name)
		if !known {
			return 0, 0, nil, false
		}
		cells += n
	}
	if equations <= cells {
		return 0, 0, nil, false
	}
	unknowns = make([]string, 0, len(mentioned))
	for name := range mentioned {
		unknowns = append(unknowns, name)
	}
	sort.Strings(unknowns)
	return equations, cells, unknowns, true
}
