package esm

// Load-time closed-function argument checks and function-table checks —
// esm-spec §9.2 "When the argument checks run" and §9.5.5 "When the table
// checks run" (rulings Q-106..Q-109).
//
// Both run during load (parse.go, after template expansion and enum lowering,
// so an `fn` node inside an expression-template body is checked where the
// template is applied) and in validate() (collectStructuralErrors). They cover
// EVERY `function_tables` entry, referenced or not, and EVERY `fn` node naming
// interp.searchsorted / interp.linear / interp.bilinear wherever it appears.
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

// checkInterpArgsAreConst is the AST half of the §9.2 argument checks: every
// array-valued argument of an interp.* `fn` node must be a `const`-op node — a
// variable reference or any other expression is `interp_axis_not_const` (an
// axis, searchsorted's xs) or `interp_table_not_const` (a table). It must be
// decided on the AST: evaluateFnArg would reduce a variable reference to a
// scalar, which would then be indistinguishable from a `const` scalar. A node
// with the wrong argument count is left to EvaluateClosedFunction's arity check.
func checkInterpArgsAreConst(node ExprNode) error {
	if node.Name == nil {
		return nil
	}
	spec, ok := interpArrayArgs[*node.Name]
	if !ok || len(node.Args) != spec.arity {
		return nil
	}
	for _, a := range spec.args {
		if arg, ok := asExprNode(node.Args[a.index]); ok && arg.Op == OpConst {
			continue
		}
		return newClosedFunctionError(a.code, fmt.Sprintf(
			"%s: %s must be a `const`-op array, got %s (esm-spec §9.2)",
			*node.Name, a.role, describeFnArg(node.Args[a.index])))
	}
	return nil
}

// constArgValue is the `value` of an argument checkInterpArgsAreConst has
// already found to be a `const` node.
func constArgValue(arg Expression) any {
	node, _ := asExprNode(arg)
	return node.Value
}

// checkClosedFnArgs runs every load-time §9.2 argument check on one `fn` node:
// the AST half (checkInterpArgsAreConst), then the rank of each `const` array
// (`interp_table_not_const` / `interp_axis_not_const`, ruling Q-108), then the
// function's own checks — searchsorted_nan before searchsorted_non_monotonic;
// for interp.linear / interp.bilinear the order of validateInterpLinearArgs /
// validateInterpBilinearArgs. Any other `fn`, or one with the wrong argument
// count, passes: arity is an evaluation-time check.
func checkClosedFnArgs(node ExprNode) error {
	if err := checkInterpArgsAreConst(node); err != nil {
		return err
	}
	if node.Name == nil {
		return nil
	}
	name := *node.Name
	spec, ok := interpArrayArgs[name]
	if !ok || len(node.Args) != spec.arity {
		return nil
	}
	switch name {
	case "interp.searchsorted":
		xs, err := interpRank1Array(name, "xs", CodeInterpAxisNotConst, constArgValue(node.Args[1]))
		if err != nil {
			return err
		}
		return validateSearchsortedXs(name, xs)
	case "interp.linear":
		table, err := interpRank1Array(name, "table", codeInterpTableNotConst, constArgValue(node.Args[0]))
		if err != nil {
			return err
		}
		axis, err := interpRank1Array(name, "axis", CodeInterpAxisNotConst, constArgValue(node.Args[1]))
		if err != nil {
			return err
		}
		return validateInterpLinearArgs(table, axis)
	case "interp.bilinear":
		table, err := interpRank2Array(name, "table", codeInterpTableNotConst, constArgValue(node.Args[0]))
		if err != nil {
			return err
		}
		axisX, err := interpRank1Array(name, "axis_x", CodeInterpAxisNotConst, constArgValue(node.Args[1]))
		if err != nil {
			return err
		}
		axisY, err := interpRank1Array(name, "axis_y", CodeInterpAxisNotConst, constArgValue(node.Args[2]))
		if err != nil {
			return err
		}
		return validateInterpBilinearArgs(table, axisX, axisY)
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
// `function_tables` entry (sorted by id), then the §9.2 argument checks on
// every interp.* `fn` node of the document, calling report for each failure.
// report returns false to stop the walk.
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
		visitFnNodes(expr, func(node ExprNode) bool {
			if err := checkClosedFnArgs(node); err != nil {
				keepGoing = report(loadTimeFinding{path: path, err: err})
			}
			return keepGoing
		})
		return keepGoing
	})
}

// checkFunctionsAtLoad is the load-time gate: the first failed table or
// argument check, as the *TableLookupError / *ClosedFunctionError that carries
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

// visitFnNodes calls visit on every `fn` node in expr, in every
// expression-bearing field (mapExprChildren), raw lists and raw objects
// included. visit returns false to stop.
func visitFnNodes(expr Expression, visit func(ExprNode) bool) bool {
	if node, ok := asExprNode(expr); ok {
		if node.Op == OpFn && !visit(node) {
			return false
		}
		keepGoing := true
		_, _ = mapExprChildren(node, func(child Expression) (Expression, error) {
			if keepGoing {
				keepGoing = visitFnNodes(child, visit)
			}
			return child, nil
		})
		return keepGoing
	}
	switch v := expr.(type) {
	case []any:
		for _, el := range v {
			if !visitFnNodes(el, visit) {
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
			if !visitFnNodes(v[k], visit) {
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
