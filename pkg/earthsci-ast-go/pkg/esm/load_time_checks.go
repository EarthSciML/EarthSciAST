package esm

// Load-time closed-function argument checks, function-table checks and
// table_lookup checks — esm-spec §9.2 "When the argument checks run" and
// §9.5.5 "When the table checks run" (rulings Q-106..Q-113).
//
// Both run during load (parse.go, after template expansion and enum lowering,
// so an `fn` node inside an expression-template body is checked where the
// template is applied) and in validate() (collectStructuralErrors). They cover
// EVERY `function_tables` entry, referenced or not, then EVERY `fn` node naming
// interp.searchsorted / interp.linear / interp.bilinear and EVERY
// `table_lookup` node wherever it appears, evaluated or not.
// A document that fails one does not load. The lowering of a `table_lookup`
// and the evaluator repeat the checks for trees built in memory.

import (
	"errors"
	"fmt"
	"sort"
)

// interpArrayArg is one array-valued argument position of an interp.* function:
// its index in `args`, its name in diagnostics, and the code a non-`const` or
// wrong-rank argument there is refused with.
type interpArrayArg struct {
	index int
	role  string
	code  string
}

// interpArrayArgs lists, for each interp.* closed function, its arity and its
// array-valued argument positions in argument order (esm-spec §9.2).
var interpArrayArgs = map[string]struct {
	arity int
	args  []interpArrayArg
}{
	"interp.searchsorted": {2, []interpArrayArg{{1, "xs", CodeInterpAxisNotConst}}},
	"interp.linear": {3, []interpArrayArg{
		{0, "table", codeInterpTableNotConst},
		{1, "axis", CodeInterpAxisNotConst},
	}},
	"interp.bilinear": {5, []interpArrayArg{
		{0, "table", codeInterpTableNotConst},
		{1, "axis_x", CodeInterpAxisNotConst},
		{2, "axis_y", CodeInterpAxisNotConst},
	}},
}

// checkInterpArgsAreConst is the AST half of the §9.2 argument checks, for
// the evaluator: every array-valued argument of an interp.* `fn` node must be
// a `const`-op node — a variable reference or any other expression is
// `interp_axis_not_const` (an axis, searchsorted's xs) or
// `interp_table_not_const` (a table). It must be decided on the AST:
// evaluateFnArg would reduce a variable reference to a scalar, which would
// then be indistinguishable from a `const` scalar. A node with the wrong
// argument count is left to EvaluateClosedFunction's arity check, and the
// ranks to EvaluateClosedFunction itself.
func checkInterpArgsAreConst(node ExprNode) error {
	if node.Name == nil {
		return nil
	}
	spec, ok := interpArrayArgs[*node.Name]
	if !ok || len(node.Args) != spec.arity {
		return nil
	}
	for _, a := range spec.args {
		if err := interpArgNotConst(*node.Name, a, node.Args[a.index]); err != nil {
			return err
		}
	}
	return nil
}

// interpArgNotConst refuses an array-valued interp.* argument that is not a
// `const`-op node, with the code of its position.
func interpArgNotConst(name string, a interpArrayArg, arg Expression) error {
	if node, ok := asExprNode(arg); ok && node.Op == OpConst {
		return nil
	}
	return newClosedFunctionError(a.code, fmt.Sprintf(
		"%s: %s must be a `const`-op array, got %s (esm-spec §9.2)",
		name, a.role, describeFnArg(arg)))
}

// constArgValue is the `value` of an argument interpArgNotConst has already
// found to be a `const` node.
func constArgValue(arg Expression) any {
	node, _ := asExprNode(arg)
	return node.Value
}

// checkClosedFnArgs runs every load-time §9.2 argument check on one `fn` node,
// in the order of §9.2 "Order of the argument checks" (ruling Q-110):
//
//  1. closed_function_arity (ruling Q-112: at load, for interp.* only);
//  2. each array-valued argument in argument order — the table first, then
//     the axes — not a `const` node, or a `const` of the wrong rank
//     (`interp_table_not_const` / `interp_axis_not_const`; rulings Q-108,
//     Q-111);
//  3. the function's own checks: searchsorted_nan then
//     searchsorted_non_monotonic; for interp.linear / interp.bilinear the
//     order of validateInterpLinearArgs / validateInterpBilinearArgs.
//
// Any other `fn` passes: its checks are evaluation-time.
func checkClosedFnArgs(node ExprNode) error {
	if node.Name == nil {
		return nil
	}
	name := *node.Name
	spec, ok := interpArrayArgs[name]
	if !ok {
		return nil
	}
	if err := expectArity(name, node.Args, spec.arity); err != nil {
		return err
	}
	rank1 := map[int][]float64{}
	var table2 [][]float64
	for _, a := range spec.args {
		arg := node.Args[a.index]
		if err := interpArgNotConst(name, a, arg); err != nil {
			return err
		}
		value := constArgValue(arg)
		if name == "interp.bilinear" && a.index == 0 {
			t, err := interpRank2Array(name, a.role, a.code, value)
			if err != nil {
				return err
			}
			table2 = t
			continue
		}
		v, err := interpRank1Array(name, a.role, a.code, value)
		if err != nil {
			return err
		}
		rank1[a.index] = v
	}
	switch name {
	case "interp.searchsorted":
		return validateSearchsortedXs(name, rank1[1])
	case "interp.linear":
		return validateInterpLinearArgs(rank1[0], rank1[1])
	case "interp.bilinear":
		return validateInterpBilinearArgs(table2, rank1[1], rank1[2])
	}
	return nil
}

// checkTableLookupNode runs a `table_lookup` node's own checks at load (esm-spec
// §9.5.5 "When the table checks run", ruling Q-112), in the pinned lookup order
// (ruling Q-107): table_lookup_unknown_table; then the named table's ten checks
// (already run on every table before any node, so they pass here); then
// table_lookup_args_nonempty, table_lookup_axis_name_mismatch and
// table_lookup_output_out_of_range. `table_out_of_bounds_unsupported` is NOT
// one of them: it stays where a lookup is lowered (§9.5.3a).
func checkTableLookupNode(node ExprNode, tables map[string]FunctionTable) error {
	if node.Table == nil || *node.Table == "" {
		return newTableLookupError(CodeTableLookupUnknownTable,
			"a `table_lookup` node carries no `table` id (esm-spec §9.5.2)")
	}
	id := *node.Table
	table, ok := tables[id]
	if !ok {
		return newTableLookupError(CodeTableLookupUnknownTable,
			"`table_lookup` references table %q, which the document's `function_tables` "+
				"block does not declare", id)
	}
	if err := validateFunctionTable(id, table); err != nil {
		return err
	}
	if _, err := tableAxisInputs(node, table, id); err != nil {
		return err
	}
	_, err := tableOutputIndex(node, table, id)
	return err
}

// checkExprNodeAtLoad is the load-time check of one expression node: the §9.2
// argument checks of an interp.* `fn` node, or the checks of a `table_lookup`.
func checkExprNodeAtLoad(node ExprNode, tables map[string]FunctionTable) error {
	switch node.Op {
	case OpFn:
		return checkClosedFnArgs(node)
	case OpTableLookup:
		return checkTableLookupNode(node, tables)
	}
	return nil
}

// loadTimeFinding is one failed load-time check: the JSON Pointer of the table
// or of the expression position holding the `fn` node, and the diagnostic.
type loadTimeFinding struct {
	path string
	err  error
}

// loadTimeFunctionChecks runs the §9.5.5 table checks on every
// `function_tables` entry (sorted by id), then — every table before any
// expression node (ruling Q-113) — the §9.2 argument checks on every interp.*
// `fn` node and the lookup checks on every `table_lookup` node of the
// document, calling report for each failure. report returns false to stop the
// walk.
func loadTimeFunctionChecks(file *ESMFile, report func(loadTimeFinding) bool) {
	ids := make([]string, 0, len(file.FunctionTables))
	for id := range file.FunctionTables {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		if err := validateFunctionTable(id, file.FunctionTables[id]); err != nil {
			if !report(loadTimeFinding{path: "/function_tables/" + escapeJSONPointerSegment(id), err: err}) {
				return
			}
		}
	}
	visitDocumentExprs(file, func(path string, expr Expression) bool {
		keepGoing := true
		visitExprNodes(expr, func(node ExprNode) bool {
			if err := checkExprNodeAtLoad(node, file.FunctionTables); err != nil {
				keepGoing = report(loadTimeFinding{path: path, err: err})
			}
			return keepGoing
		})
		return keepGoing
	})
}

// checkFunctionsAtLoad is the load-time gate: the first failed table,
// argument or lookup check, as the *TableLookupError / *ClosedFunctionError that carries
// its code, or nil.
func checkFunctionsAtLoad(file *ESMFile) error {
	var first error
	loadTimeFunctionChecks(file, func(f loadTimeFinding) bool {
		first = f.err
		return false
	})
	return first
}

// validateFunctionChecks reports every failed table or argument check as a
// structural error, for validate().
func (s *structuralScan) validateFunctionChecks() {
	loadTimeFunctionChecks(s.file, func(f loadTimeFinding) bool {
		code := ""
		var de DiagnosticError
		if errors.As(f.err, &de) {
			code = de.DiagnosticCode()
		}
		s.addErr(StructuralError{
			Path:    f.path,
			Code:    code,
			Message: f.err.Error(),
			Details: map[string]any{},
		})
		return true
	})
}

// visitExprNodes calls visit on every operator node in expr, in every
// expression-bearing field (mapExprChildren), raw lists and raw objects
// included. visit returns false to stop.
func visitExprNodes(expr Expression, visit func(ExprNode) bool) bool {
	if node, ok := asExprNode(expr); ok {
		if !visit(node) {
			return false
		}
		keepGoing := true
		_, _ = mapExprChildren(node, func(child Expression) (Expression, error) {
			if keepGoing {
				keepGoing = visitExprNodes(child, visit)
			}
			return child, nil
		})
		return keepGoing
	}
	switch v := expr.(type) {
	case []any:
		for _, el := range v {
			if !visitExprNodes(el, visit) {
				return false
			}
		}
	case map[string]any:
		for _, k := range sortedKeys(v) {
			// A template body is checked where it is applied (esm-spec §9.2),
			// never in its declaration.
			if k == "expression_templates" {
				continue
			}
			if !visitExprNodes(v[k], visit) {
				return false
			}
		}
	}
	return true
}

// visitDocumentExprs calls visit on the root of every expression-bearing
// position of the document with its JSON Pointer: the positions mapFileExprs
// rewrites (variable update sites, equations, initialization equations, events,
// reaction rates, constraint equations, connector equations), plus those it
// does not — `guesses`, inline-test assertion `reference`s and per-test
// `initial_conditions` / `parameter_overrides`, a `variable_map` expression
// `transform`, and inline `subsystems` (raw JSON, walked whole). It only reads.
// visit returns false to stop.
func visitDocumentExprs(file *ESMFile, visit func(path string, expr Expression) bool) {
	w := docExprVisitor{visit: visit, ok: true}
	for _, name := range sortedKeys(file.Models) {
		w.model("/models/"+escapeJSONPointerSegment(name), file.Models[name])
	}
	for _, name := range sortedKeys(file.ReactionSystems) {
		w.reactionSystem("/reaction_systems/"+escapeJSONPointerSegment(name), file.ReactionSystems[name])
	}
	for i, entry := range file.Coupling {
		base := fmt.Sprintf("/coupling/%d", i)
		switch c := entry.(type) {
		case CouplingCouple:
			for j, ceq := range c.Connector.Equations {
				if ceq.Expression != nil {
					w.at(fmt.Sprintf("%s/connector/equations/%d/expression", base, j), ceq.Expression)
				}
			}
		case VariableMapCoupling:
			if c.TransformIsExpression() {
				w.at(base+"/transform", c.Transform)
			}
		}
	}
}

type docExprVisitor struct {
	visit func(string, Expression) bool
	ok    bool
}

func (w *docExprVisitor) at(path string, expr Expression) {
	if w.ok && expr != nil {
		w.ok = w.visit(path, expr)
	}
}

func (w *docExprVisitor) model(base string, m Model) {
	for _, name := range sortedKeys(m.Variables) {
		v := m.Variables[name]
		for _, site := range VariableExprSites(&v) {
			w.at(base+"/variables/"+escapeJSONPointerSegment(name)+site.Path, site.Expr)
		}
	}
	w.equations(base+"/equations", m.Equations)
	w.equations(base+"/initialization_equations", m.InitializationEquations)
	for _, name := range sortedKeys(m.Guesses) {
		w.at(base+"/guesses/"+escapeJSONPointerSegment(name), m.Guesses[name])
	}
	w.discreteEvents(base+"/discrete_events", m.DiscreteEvents)
	w.continuousEvents(base+"/continuous_events", m.ContinuousEvents)
	w.tests(base+"/tests", m.Tests)
	for _, name := range sortedKeys(m.Subsystems) {
		w.at(base+"/subsystems/"+escapeJSONPointerSegment(name), m.Subsystems[name])
	}
}

func (w *docExprVisitor) reactionSystem(base string, rs ReactionSystem) {
	for i, r := range rs.Reactions {
		w.at(fmt.Sprintf("%s/reactions/%d/rate", base, i), r.Rate)
	}
	w.equations(base+"/constraint_equations", rs.ConstraintEquations)
	w.discreteEvents(base+"/discrete_events", rs.DiscreteEvents)
	w.continuousEvents(base+"/continuous_events", rs.ContinuousEvents)
	w.tests(base+"/tests", rs.Tests)
	for _, name := range sortedKeys(rs.Subsystems) {
		w.at(base+"/subsystems/"+escapeJSONPointerSegment(name), rs.Subsystems[name])
	}
}

func (w *docExprVisitor) equations(base string, eqs []Equation) {
	for i, eq := range eqs {
		w.at(fmt.Sprintf("%s/%d/lhs", base, i), eq.LHS)
		w.at(fmt.Sprintf("%s/%d/rhs", base, i), eq.RHS)
	}
}

func (w *docExprVisitor) affects(base string, affects []AffectEquation) {
	for i, a := range affects {
		w.at(fmt.Sprintf("%s/%d/rhs", base, i), a.RHS)
	}
}

func (w *docExprVisitor) discreteEvents(base string, events []DiscreteEvent) {
	for i, ev := range events {
		p := fmt.Sprintf("%s/%d", base, i)
		w.at(p+"/trigger/expression", ev.Trigger.Expression)
		w.affects(p+"/affects", ev.Affects)
	}
}

func (w *docExprVisitor) continuousEvents(base string, events []ContinuousEvent) {
	for i, ev := range events {
		p := fmt.Sprintf("%s/%d", base, i)
		for j, c := range ev.Conditions {
			w.at(fmt.Sprintf("%s/conditions/%d", p, j), c)
		}
		w.affects(p+"/affects", ev.Affects)
		w.affects(p+"/affect_neg", ev.AffectNeg)
	}
}

func (w *docExprVisitor) tests(base string, tests []Test) {
	for i, t := range tests {
		p := fmt.Sprintf("%s/%d", base, i)
		for _, name := range sortedKeys(t.InitialConditions) {
			w.at(p+"/initial_conditions/"+escapeJSONPointerSegment(name), t.InitialConditions[name])
		}
		for _, name := range sortedKeys(t.ParameterOverrides) {
			w.at(p+"/parameter_overrides/"+escapeJSONPointerSegment(name), t.ParameterOverrides[name])
		}
		for j, a := range t.Assertions {
			w.at(fmt.Sprintf("%s/assertions/%d/reference", p, j), a.Reference)
		}
	}
}
