package esm

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
)

// intExactCutoff is the magnitude below which every integer-valued float64 is
// representable exactly (2^52 < 1e15 < 2^53). Above it, consecutive integers are
// no longer all representable, so int64(v) could silently misround; such
// coefficients fall back to the general float rendering instead.
const intExactCutoff = 1e15

// formatStoich renders a stoichiometric coefficient using the shortest form
// that round-trips exactly through JSON: integer-valued coefficients emit
// without a decimal (e.g. "2"), fractional coefficients use the canonical
// minimal float representation (e.g. "0.87").
func formatStoich(v float64) string {
	if math.IsInf(v, 0) || math.IsNaN(v) {
		return strconv.FormatFloat(v, 'g', -1, 64)
	}
	if v == math.Trunc(v) && math.Abs(v) < intExactCutoff {
		return strconv.FormatInt(int64(v), 10)
	}
	return strconv.FormatFloat(v, 'g', -1, 64)
}

// FlattenedSystem represents a coupled system flattened into a single system
type FlattenedSystem struct {
	StateVariables    []string          // dot-namespaced state variable names
	Parameters        []string          // dot-namespaced parameter names
	BrownianVariables []string          // dot-namespaced brownian (Wiener) noise variables
	Variables         map[string]string // dot-namespaced variable name -> type
	// InitialValues maps a dot-namespaced reaction-system state variable to its
	// initial concentration, taken from the species' declared scalar `default`
	// (falling back to 0.0 when a species declares no default). Mirrors the
	// per-state `default` the Julia/Rust/Python flatten paths carry.
	InitialValues map[string]float64
	Equations     []FlattenedEquation // all equations with namespaced vars
	Events        []any               // events with namespaced references
	Metadata      FlattenMetadata     // which systems were flattened
}

// FlattenedEquation represents a single equation in the flattened system
type FlattenedEquation struct {
	LHS          string // dot-namespaced variable name
	RHS          string // expression string with namespaced references
	SourceSystem string // which system this equation came from
}

// FlattenMetadata records provenance information about the flattening operation
type FlattenMetadata struct {
	SourceSystems []string // names of systems that were flattened
	CouplingRules []string // descriptions of coupling rules applied
}

// Flatten takes an EsmFile containing multiple models and/or reaction systems
// and returns a FlattenedSystem with dot-namespaced variables.
//
// The algorithm:
//  1. Derives ODE equations from reaction systems (converting reactions to d/dt equations)
//  2. Namespaces all variables: prefix every variable/parameter with SystemName.
//  3. Applies coupling rules (operator_compose, couple, variable_map, operator_apply)
//  4. Collects and returns the unified flattened system
func Flatten(file *EsmFile) (*FlattenedSystem, error) {
	return FlattenWithOptions(file, CouplingImportOptions{})
}

// FlattenWithOptions is Flatten with control over how `coupling_import` refs are
// resolved (esm-spec §10.10). Only needed when the file uses `coupling_import`;
// a file with no such entries flattens identically under the zero-value options.
func FlattenWithOptions(file *EsmFile, opts CouplingImportOptions) (*FlattenedSystem, error) {
	if file == nil {
		return nil, fmt.Errorf("flatten: input file is nil")
	}

	flat := &FlattenedSystem{
		Variables:     make(map[string]string),
		InitialValues: make(map[string]float64),
		Metadata: FlattenMetadata{
			SourceSystems: make([]string, 0),
			CouplingRules: make([]string, 0),
		},
	}

	// Collect all variable names per system for expression namespacing.
	allVarNames := make(map[string]map[string]bool) // systemName -> set of var names

	// ---------------------------------------------------------------
	// Step 1 & 2: Collect variables and equations from Models
	// ---------------------------------------------------------------
	modelNames := sortedKeys(file.Models)
	for _, systemName := range modelNames {
		model := file.Models[systemName]
		flat.Metadata.SourceSystems = append(flat.Metadata.SourceSystems, systemName)

		varNames := make(map[string]bool)
		for varName := range model.Variables {
			varNames[varName] = true
		}
		allVarNames[systemName] = varNames

		// Register variables with namespaced names
		for varName, variable := range model.Variables {
			nsName := systemName + "." + varName
			flat.Variables[nsName] = variable.Type
			switch variable.Type {
			case "state":
				flat.StateVariables = append(flat.StateVariables, nsName)
			case "parameter":
				flat.Parameters = append(flat.Parameters, nsName)
			case "brownian":
				flat.BrownianVariables = append(flat.BrownianVariables, nsName)
			}
		}

		// Namespace and collect equations
		for _, eq := range model.Equations {
			lhsStr := namespaceExpression(eq.LHS, systemName, varNames)
			rhsStr := namespaceExpression(eq.RHS, systemName, varNames)
			flat.Equations = append(flat.Equations, FlattenedEquation{
				LHS:          lhsStr,
				RHS:          rhsStr,
				SourceSystem: systemName,
			})
		}

		// Collect events with namespaced references
		for _, de := range model.DiscreteEvents {
			flat.Events = append(flat.Events, namespaceDiscreteEvent(de, systemName, varNames))
		}
		for _, ce := range model.ContinuousEvents {
			flat.Events = append(flat.Events, namespaceContinuousEvent(ce, systemName, varNames))
		}
	}

	// ---------------------------------------------------------------
	// Step 1 & 2: Derive ODEs from Reaction Systems, collect variables
	// ---------------------------------------------------------------
	rsNames := sortedKeys(file.ReactionSystems)
	for _, systemName := range rsNames {
		rs := file.ReactionSystems[systemName]
		flat.Metadata.SourceSystems = append(flat.Metadata.SourceSystems, systemName)

		varNames := make(map[string]bool)
		for speciesName := range rs.Species {
			varNames[speciesName] = true
		}
		for paramName := range rs.Parameters {
			varNames[paramName] = true
		}
		allVarNames[systemName] = varNames

		// Register species as state variables, carrying each species' declared
		// scalar `default` through as the state's initial value.
		for speciesName, species := range rs.Species {
			nsName := systemName + "." + speciesName
			flat.Variables[nsName] = "state"
			flat.StateVariables = append(flat.StateVariables, nsName)
			flat.InitialValues[nsName] = speciesInitialValue(species)
		}

		// Register parameters
		for paramName := range rs.Parameters {
			nsName := systemName + "." + paramName
			flat.Variables[nsName] = "parameter"
			flat.Parameters = append(flat.Parameters, nsName)
		}

		// Derive ODE for each species from reactions
		speciesODEs := deriveODEs(rs, systemName, varNames)
		flat.Equations = append(flat.Equations, speciesODEs...)

		// Add constraint equations
		for _, eq := range rs.ConstraintEquations {
			lhsStr := namespaceExpression(eq.LHS, systemName, varNames)
			rhsStr := namespaceExpression(eq.RHS, systemName, varNames)
			flat.Equations = append(flat.Equations, FlattenedEquation{
				LHS:          lhsStr,
				RHS:          rhsStr,
				SourceSystem: systemName,
			})
		}

		// Collect events
		for _, de := range rs.DiscreteEvents {
			flat.Events = append(flat.Events, namespaceDiscreteEvent(de, systemName, varNames))
		}
		for _, ce := range rs.ContinuousEvents {
			flat.Events = append(flat.Events, namespaceContinuousEvent(ce, systemName, varNames))
		}
	}

	// Sort state variables, parameters, and brownians for deterministic output
	sort.Strings(flat.StateVariables)
	sort.Strings(flat.Parameters)
	sort.Strings(flat.BrownianVariables)

	// ---------------------------------------------------------------
	// Step 3: Expand coupling_import entries (esm-spec §10.10.3), then apply
	// the resulting coupling sequence. A file with no coupling_import entries
	// yields its `coupling` slice verbatim and needs no options.
	// ---------------------------------------------------------------
	coupling, err := expandCouplingImports(file, opts)
	if err != nil {
		return nil, fmt.Errorf("flatten: %w", err)
	}
	for _, entry := range coupling {
		if err := applyCouplingRule(flat, entry, allVarNames); err != nil {
			return nil, fmt.Errorf("flatten: coupling error: %w", err)
		}
	}

	return flat, nil
}

// deriveODEs converts a reaction system into ODE equations for each species.
// For each species, the ODE RHS is the sum of (stoichiometry * rate) for each
// reaction in which the species participates (positive for products, negative
// for substrates).
func deriveODEs(rs ReactionSystem, systemName string, varNames map[string]bool) []FlattenedEquation {
	// Accumulate per-species terms: speciesName -> list of signed rate terms
	speciesTerms := make(map[string][]string)
	for speciesName := range rs.Species {
		speciesTerms[speciesName] = nil
	}

	for _, reaction := range rs.Reactions {
		rateStr := namespaceExpression(reaction.Rate, systemName, varNames)

		// Substrates are consumed (negative contribution)
		for _, sub := range reaction.Substrates {
			term := rateStr
			if sub.Stoichiometry != 1 {
				term = fmt.Sprintf("%s*%s", formatStoich(sub.Stoichiometry), rateStr)
			}
			speciesTerms[sub.Species] = append(speciesTerms[sub.Species], "-"+term)
		}

		// Products are produced (positive contribution)
		for _, prod := range reaction.Products {
			term := rateStr
			if prod.Stoichiometry != 1 {
				term = fmt.Sprintf("%s*%s", formatStoich(prod.Stoichiometry), rateStr)
			}
			speciesTerms[prod.Species] = append(speciesTerms[prod.Species], "+"+term)
		}
	}

	// Build equations sorted by species name for determinism
	speciesNames := make([]string, 0, len(speciesTerms))
	for name := range speciesTerms {
		speciesNames = append(speciesNames, name)
	}
	sort.Strings(speciesNames)

	var equations []FlattenedEquation
	for _, speciesName := range speciesNames {
		terms := speciesTerms[speciesName]
		nsSpecies := systemName + "." + speciesName
		lhs := fmt.Sprintf("D(%s, t)", nsSpecies)

		var rhs string
		if len(terms) == 0 {
			rhs = "0"
		} else {
			rhs = buildSumExpression(terms)
		}

		equations = append(equations, FlattenedEquation{
			LHS:          lhs,
			RHS:          rhs,
			SourceSystem: systemName,
		})
	}

	return equations
}

// speciesInitialValue returns a species' initial concentration for the
// flattened initial-state vector: its declared scalar `default` when present,
// or 0.0 as a sensible fallback when the species declares no default. The
// parser decodes JSON numbers with UseNumber (json.Number), so that case is
// handled alongside the float64/int forms produced when structs are built
// directly in code.
func speciesInitialValue(s Species) float64 {
	switch v := s.Default.(type) {
	case nil:
		return 0.0
	case float64:
		return v
	case float32:
		return float64(v)
	case int:
		return float64(v)
	case int64:
		return float64(v)
	case json.Number:
		if f, err := v.Float64(); err == nil {
			return f
		}
	case string:
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return 0.0
}

// buildSumExpression combines signed terms into a single expression string.
func buildSumExpression(terms []string) string {
	if len(terms) == 0 {
		return "0"
	}

	var b strings.Builder
	for i, term := range terms {
		if i == 0 {
			// First term: write as-is but trim leading "+" if present
			if strings.HasPrefix(term, "+") {
				b.WriteString(term[1:])
			} else {
				b.WriteString(term)
			}
		} else {
			if strings.HasPrefix(term, "-") {
				b.WriteString(" - ")
				b.WriteString(term[1:])
			} else if strings.HasPrefix(term, "+") {
				b.WriteString(" + ")
				b.WriteString(term[1:])
			} else {
				b.WriteString(" + ")
				b.WriteString(term)
			}
		}
	}
	return b.String()
}

// namespaceExpression converts an Expression tree to a string representation
// with all variable references prefixed by "systemName.".
func namespaceExpression(expr Expression, systemName string, varNames map[string]bool) string {
	return renderNamespacedExpr(expr, func(v string) string {
		if varNames[v] {
			return systemName + "." + v
		}
		// Already scoped or an independent variable like "t".
		return v
	}, true)
}

// renderNamespacedExpr renders an Expression tree to an infix string, resolving
// bare variable leaves through `resolve`. It is the single renderer behind both
// namespaceExpression (equation rendering, parens=true) and
// namespaceConnectorExpression (connector rendering, parens=false).
//
// The `parens` flag selects between two DELIBERATELY divergent rendering modes
// that cross-language flatten fixtures pin — do not converge them:
//
//   - parens=true: parenthesizes add/sub operands inside `*`, complex
//     denominators inside `/`, and complex/pow bases inside `^`; renders
//     `D(x, wrt)` specially; emits `-(?)` / `/(?)` / `^(?)` placeholders for
//     malformed-arity arithmetic nodes.
//   - parens=false: never parenthesizes; renders n-ary `-` as a chained
//     subtraction; lets malformed-arity `/`, `^`, and `D` fall through to the
//     generic `op(args...)` form.
func renderNamespacedExpr(expr Expression, resolve func(string) string, parens bool) string {
	switch e := expr.(type) {
	case string:
		return resolve(e)
	case float64:
		return fmt.Sprintf("%g", e)
	case int:
		return fmt.Sprintf("%d", e)
	case ExprNode:
		return renderNamespacedNode(e, resolve, parens)
	case *ExprNode:
		if e == nil {
			return ""
		}
		return renderNamespacedNode(*e, resolve, parens)
	default:
		return fmt.Sprintf("%v", expr)
	}
}

// renderNamespacedNode renders one operator node to an infix string; see
// renderNamespacedExpr for the meaning of `parens`.
func renderNamespacedNode(node ExprNode, resolve func(string) string, parens bool) string {
	render := func(e Expression) string { return renderNamespacedExpr(e, resolve, parens) }
	op := node.Op

	// D(var, wrt) is rendered specially only in the parenthesizing (equation)
	// mode; the connector renderer lets it fall through to the generic form.
	if parens && op == "D" {
		if len(node.Args) >= 1 {
			wrt := "t"
			if node.Wrt != nil {
				wrt = *node.Wrt
			}
			return fmt.Sprintf("D(%s, %s)", render(node.Args[0]), wrt)
		}
		return "D(?)"
	}

	switch op {
	case "+":
		parts := make([]string, len(node.Args))
		for i, arg := range node.Args {
			parts[i] = render(arg)
		}
		return strings.Join(parts, " + ")

	case "-":
		if len(node.Args) == 1 {
			return "-" + render(node.Args[0])
		}
		if len(node.Args) == 2 {
			return render(node.Args[0]) + " - " + render(node.Args[1])
		}
		if parens {
			return "-(?)"
		}
		// parens=false: chain an n-ary subtraction.
		parts := make([]string, len(node.Args))
		for i, arg := range node.Args {
			parts[i] = render(arg)
		}
		return strings.Join(parts, " - ")

	case "*":
		parts := make([]string, len(node.Args))
		for i, arg := range node.Args {
			s := render(arg)
			// Parenthesize additions/subtractions inside multiplication.
			if parens && isAddSub(arg) {
				s = "(" + s + ")"
			}
			parts[i] = s
		}
		return strings.Join(parts, "*")

	case "/":
		if len(node.Args) == 2 {
			left := render(node.Args[0])
			right := render(node.Args[1])
			if parens && needsParens(node.Args[1]) {
				right = "(" + right + ")"
			}
			return left + "/" + right
		}
		if parens {
			return "/(?)"
		}
		// parens=false: fall through to the generic form.

	case "^", "**":
		if len(node.Args) == 2 {
			base := render(node.Args[0])
			exp := render(node.Args[1])
			// `^` reads left-to-right in the rendered string, so an arithmetic
			// OR pow base must be parenthesized: (a^b)^c must not render as
			// a^b^c (which reparses right-associatively as a^(b^c)).
			if parens && (needsParens(node.Args[0]) || isPowNode(node.Args[0])) {
				base = "(" + base + ")"
			}
			return base + "^" + exp
		}
		if parens {
			return "^(?)"
		}
		// parens=false: fall through to the generic form.
	}

	// Generic function call: op(arg1, arg2, ...)
	argStrs := make([]string, len(node.Args))
	for i, arg := range node.Args {
		argStrs[i] = render(arg)
	}
	return op + "(" + strings.Join(argStrs, ", ") + ")"
}

// isAddSub returns true if expr is an addition or binary subtraction node.
func isAddSub(expr any) bool {
	if n, ok := expr.(ExprNode); ok {
		return n.Op == "+" || (n.Op == "-" && len(n.Args) == 2)
	}
	return false
}

// needsParens reports whether expr is an arithmetic node (+, -, *, /) that must
// be parenthesized when it appears as a `/` denominator or a `^` base.
func needsParens(expr any) bool {
	if n, ok := expr.(ExprNode); ok {
		return n.Op == "+" || n.Op == "-" || n.Op == "*" || n.Op == "/"
	}
	return false
}

// isPowNode reports whether expr is an exponentiation node (^ / **). A pow base
// must be parenthesized because rendered `^` is read left-to-right.
func isPowNode(expr any) bool {
	if n, ok := expr.(ExprNode); ok {
		return n.Op == "^" || n.Op == "**"
	}
	return false
}

// namespaceDiscreteEvent creates a copy of a DiscreteEvent with namespaced variable references.
func namespaceDiscreteEvent(de DiscreteEvent, systemName string, varNames map[string]bool) DiscreteEvent {
	nsEvent := de

	// Namespace trigger expression
	if de.Trigger.Type == "condition" && de.Trigger.Expression != nil {
		nsExpr := namespaceExpressionTree(de.Trigger.Expression, systemName, varNames)
		nsEvent.Trigger.Expression = nsExpr
	}

	// Namespace affects
	nsEvent.Affects = namespaceAffects(de.Affects, systemName, varNames)

	// Namespace discrete parameters
	if len(de.DiscreteParameters) > 0 {
		nsParams := make([]string, len(de.DiscreteParameters))
		for i, p := range de.DiscreteParameters {
			if varNames[p] {
				nsParams[i] = systemName + "." + p
			} else {
				nsParams[i] = p
			}
		}
		nsEvent.DiscreteParameters = nsParams
	}

	return nsEvent
}

// namespaceContinuousEvent creates a copy of a ContinuousEvent with namespaced variable references.
func namespaceContinuousEvent(ce ContinuousEvent, systemName string, varNames map[string]bool) ContinuousEvent {
	nsEvent := ce

	// Namespace conditions
	nsConditions := make([]Expression, len(ce.Conditions))
	for i, cond := range ce.Conditions {
		nsConditions[i] = namespaceExpressionTree(cond, systemName, varNames)
	}
	nsEvent.Conditions = nsConditions

	// Namespace affects and affect_neg
	nsEvent.Affects = namespaceAffects(ce.Affects, systemName, varNames)
	nsEvent.AffectNeg = namespaceAffects(ce.AffectNeg, systemName, varNames)

	return nsEvent
}

// namespaceAffects returns a copy of affects with each affect's LHS variable
// (when it names a known variable) and RHS expression namespaced under
// systemName. Shared by the discrete/continuous event namespacers.
func namespaceAffects(affects []AffectEquation, systemName string, varNames map[string]bool) []AffectEquation {
	out := make([]AffectEquation, len(affects))
	for i, affect := range affects {
		lhs := affect.LHS
		if varNames[lhs] {
			lhs = systemName + "." + lhs
		}
		out[i] = AffectEquation{
			LHS: lhs,
			RHS: namespaceExpressionTree(affect.RHS, systemName, varNames),
		}
	}
	return out
}

// namespaceExpressionTree walks an Expression tree and returns a new tree with
// variable references namespaced. Unlike namespaceExpression, this preserves
// the tree structure rather than converting to a string.
func namespaceExpressionTree(expr Expression, systemName string, varNames map[string]bool) Expression {
	switch e := expr.(type) {
	case string:
		if varNames[e] {
			return systemName + "." + e
		}
		return e
	case float64, int:
		return e
	case ExprNode:
		newArgs := make([]any, len(e.Args))
		for i, arg := range e.Args {
			newArgs[i] = namespaceExpressionTree(arg, systemName, varNames)
		}
		newNode := ExprNode{Op: e.Op, Args: newArgs, Wrt: e.Wrt, Dim: e.Dim}
		// Namespace wrt if applicable
		if e.Wrt != nil && varNames[*e.Wrt] {
			ns := systemName + "." + *e.Wrt
			newNode.Wrt = &ns
		}
		if e.Dim != nil && varNames[*e.Dim] {
			ns := systemName + "." + *e.Dim
			newNode.Dim = &ns
		}
		return newNode
	case *ExprNode:
		if e == nil {
			return nil
		}
		result := namespaceExpressionTree(*e, systemName, varNames)
		return result
	default:
		return expr
	}
}

// applyCouplingRule applies a single coupling entry to the flattened system.
func applyCouplingRule(flat *FlattenedSystem, entry any, allVarNames map[string]map[string]bool) error {
	switch c := entry.(type) {
	case OperatorComposeCoupling:
		return applyOperatorCompose(flat, c)
	case CouplingCouple:
		return applyCoupleConnector(flat, c, allVarNames)
	case VariableMapCoupling:
		return applyVariableMap(flat, c)
	case OperatorApplyCoupling:
		return applyOperatorApply(flat, c)
	default:
		// Other coupling types (callback, event) are recorded but not transformed
		flat.Metadata.CouplingRules = append(flat.Metadata.CouplingRules,
			fmt.Sprintf("passthrough: %T", entry))
		return nil
	}
}

// applyOperatorCompose merges two systems by unifying their equation sets.
// The translate map renames variables from one system's namespace into the other's.
func applyOperatorCompose(flat *FlattenedSystem, c OperatorComposeCoupling) error {
	desc := fmt.Sprintf("operator_compose(%s, %s)", c.Systems[0], c.Systems[1])

	// Apply variable translations if specified
	if len(c.Translate) > 0 {
		for fromVar, toVal := range c.Translate {
			toVar, ok := toVal.(string)
			if !ok {
				continue
			}
			// Rewrite equations: replace whole-token occurrences of fromVar
			// with toVar (token-aware so "A.x" does not corrupt "A.x2"/"BA.x").
			for i, eq := range flat.Equations {
				flat.Equations[i].LHS = replaceVarToken(eq.LHS, fromVar, toVar)
				flat.Equations[i].RHS = replaceVarToken(eq.RHS, fromVar, toVar)
			}
		}
		desc += fmt.Sprintf(" with translations: %v", c.Translate)
	}

	flat.Metadata.CouplingRules = append(flat.Metadata.CouplingRules, desc)
	return nil
}

// applyCoupleConnector applies bidirectional coupling via connector equations.
// Each connector equation adds a new term to an existing equation's RHS.
func applyCoupleConnector(flat *FlattenedSystem, c CouplingCouple, allVarNames map[string]map[string]bool) error {
	desc := fmt.Sprintf("couple(%s, %s)", c.Systems[0], c.Systems[1])

	// Collect all variable names across both systems for namespacing connector expressions
	combinedVars := make(map[string]bool)
	for _, sysName := range c.Systems {
		if vars, ok := allVarNames[sysName]; ok {
			for v := range vars {
				combinedVars[sysName+"."+v] = true
			}
		}
	}

	for _, ceq := range c.Connector.Equations {
		// The From and To fields in connector equations use scoped references (System.Var)
		fromRef := ceq.From
		toRef := ceq.To

		// Build the connector expression string
		connExprStr := namespaceConnectorExpression(ceq.Expression, c.Systems, allVarNames)

		// Apply the transform to the target equation
		switch ceq.Transform {
		case "additive":
			// Add the connector expression to the RHS of the equation for toRef
			for i, eq := range flat.Equations {
				if lhsMentionsVar(eq.LHS, toRef) {
					flat.Equations[i].RHS = eq.RHS + " + " + connExprStr
				}
			}
		case "multiplicative":
			for i, eq := range flat.Equations {
				if lhsMentionsVar(eq.LHS, toRef) {
					flat.Equations[i].RHS = "(" + eq.RHS + ")*" + connExprStr
				}
			}
		case "replacement":
			for i, eq := range flat.Equations {
				if lhsMentionsVar(eq.LHS, toRef) {
					flat.Equations[i].RHS = connExprStr
				}
			}
		}

		desc += fmt.Sprintf("; connector %s->%s (%s)", fromRef, toRef, ceq.Transform)
	}

	flat.Metadata.CouplingRules = append(flat.Metadata.CouplingRules, desc)
	return nil
}

// applyVariableMap applies a variable mapping coupling rule.
// It replaces all occurrences of the "from" variable with a transformed expression
// based on the "to" variable.
func applyVariableMap(flat *FlattenedSystem, c VariableMapCoupling) error {
	replacement := c.To
	if c.Factor != nil {
		replacement = fmt.Sprintf("%g*%s", *c.Factor, c.To)
	}

	for i, eq := range flat.Equations {
		flat.Equations[i].LHS = replaceVarToken(eq.LHS, c.From, replacement)
		flat.Equations[i].RHS = replaceVarToken(eq.RHS, c.From, replacement)
	}

	// Transform is a union: a legacy string kind, or a widened Expression AST
	// (rendered as the fixed token "expression" — this Go port rewrites and
	// serializes but never evaluates transforms).
	transform := c.TransformKind()
	if c.TransformIsExpression() {
		transform = "expression"
	}
	desc := fmt.Sprintf("variable_map(%s -> %s, transform=%s)", c.From, c.To, transform)
	if c.Factor != nil {
		desc += fmt.Sprintf(", factor=%g", *c.Factor)
	}
	flat.Metadata.CouplingRules = append(flat.Metadata.CouplingRules, desc)
	return nil
}

// applyOperatorApply records an operator application coupling. Since operators
// are runtime-specific constructs, we record the intent rather than transforming
// equations.
func applyOperatorApply(flat *FlattenedSystem, c OperatorApplyCoupling) error {
	desc := fmt.Sprintf("operator_apply(%s)", c.Operator)
	flat.Metadata.CouplingRules = append(flat.Metadata.CouplingRules, desc)
	return nil
}

// namespaceConnectorExpression namespaces an expression tree used in a connector,
// where variables may belong to either of the two coupled systems. It shares the
// single infix renderer with namespaceExpression but selects the non-parenthesizing
// mode (parens=false) whose divergent output cross-language fixtures pin.
func namespaceConnectorExpression(expr Expression, systems [2]string, allVarNames map[string]map[string]bool) string {
	return renderNamespacedExpr(expr, func(v string) string {
		// Check both systems for this variable.
		for _, sysName := range systems {
			if vars, ok := allVarNames[sysName]; ok && vars[v] {
				return sysName + "." + v
			}
		}
		return v
	}, false)
}

// lhsMentionsVar reports whether the flattened LHS string mentions varRef as a
// substring. The connector-target match is intentionally a loose substring test
// (not the token-aware replaceVarToken): the target `Sys.v` must be found inside
// a derivative LHS like "D(Sys.v, t)", where it is not a standalone token.
func lhsMentionsVar(lhs, varRef string) bool {
	return strings.Contains(lhs, varRef)
}

// isIdentChar reports whether c can appear inside a flattened variable token — a
// dot-namespaced identifier of letters, digits, underscores, and the dot segment
// separator. It defines the token boundary replaceVarToken uses.
func isIdentChar(c byte) bool {
	return c == '_' || c == '.' ||
		(c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		(c >= '0' && c <= '9')
}

// replaceVarToken replaces every WHOLE-TOKEN occurrence of `from` in s with
// `to`, leaving matches that are merely a substring of a longer variable token
// untouched. Flattened variable names are dot-namespaced identifiers, so a naive
// strings.ReplaceAll of "A.x" would also corrupt "A.x2" and "BA.x" (esm audit):
// a match counts only when neither the character before nor the character after
// it is an identifier char. Scanning resumes past each replacement, so the
// inserted `to` text is never itself rewritten.
func replaceVarToken(s, from, to string) string {
	if from == "" || !strings.Contains(s, from) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); {
		if strings.HasPrefix(s[i:], from) {
			beforeOK := i == 0 || !isIdentChar(s[i-1])
			after := i + len(from)
			afterOK := after == len(s) || !isIdentChar(s[after])
			if beforeOK && afterOK {
				b.WriteString(to)
				i = after
				continue
			}
		}
		b.WriteByte(s[i])
		i++
	}
	return b.String()
}

// sortedKeys returns the sorted keys of a map.
func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
