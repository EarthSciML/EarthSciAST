package esm

import (
	"fmt"
	"math"
	"strconv"
)

// EvaluationError is raised by the scalar evaluator when an expression cannot be
// evaluated. The Code field carries a stable diagnostic code — in particular
// `unlowered_operator` when a rewrite-target op (a spatial/RHS `D`, or
// grad/div/laplacian/integral sugar) reaches evaluation without having been
// lowered to a stencil by a rewrite rule (esm-spec §4.2 / §9.6.8). The gate fires
// before evaluation, not at load: loading such a file stays permissive.
type EvaluationError struct {
	Code    string
	Message string
}

func (e *EvaluationError) Error() string {
	return fmt.Sprintf("[%s] %s", e.Code, e.Message)
}

// FreeVariables returns the set of all variable names that appear in an expression
func FreeVariables(expr Expression) map[string]bool {
	variables := make(map[string]bool)
	collectVariables(expr, variables)
	return variables
}

// collectVariables recursively collects variable names from an expression
func collectVariables(expr Expression, variables map[string]bool) {
	switch e := expr.(type) {
	case string:
		// String is a variable name
		variables[e] = true
	case float64, int, int64:
		// Numbers don't contribute variables
		return
	case ExprNode:
		// Recursively collect from all arguments
		for _, arg := range e.Args {
			collectVariables(arg, variables)
		}
		// Include wrt variable for derivatives
		if e.Wrt != nil {
			variables[*e.Wrt] = true
		}
		// Include dim variable for gradients
		if e.Dim != nil {
			variables[*e.Dim] = true
		}
	case *ExprNode:
		collectVariables(*e, variables)
	}
}

// Contains checks if a specific variable appears anywhere in an expression
func Contains(expr Expression, varName string) bool {
	variables := FreeVariables(expr)
	return variables[varName]
}

// Simplify performs constant folding and basic algebraic simplification
func Simplify(expr Expression) Expression {
	switch e := expr.(type) {
	case string, float64, int, int64:
		// Atomic expressions are already simplified
		return expr
	case ExprNode:
		return simplifyExprNode(e)
	case *ExprNode:
		return simplifyExprNode(*e)
	default:
		return expr
	}
}

// simplifyExprNode performs simplification on an expression node.
//
// Children are recursively simplified through the shared field-preserving
// walker so a non-arithmetic node (integral, table_lookup, aggregate, …) keeps
// EVERY field — the old rebuild copied only Op/Args/Wrt/Dim and silently
// stripped Var/Lower/Upper/axes/output/…
func simplifyExprNode(node ExprNode) Expression {
	simplified, _ := mapExprChildren(node, func(child Expression) (Expression, error) {
		return Simplify(child), nil
	})

	switch node.Op {
	case "+":
		return simplifyAddition(simplified)
	case "-":
		return simplifySubtraction(simplified)
	case "*":
		return simplifyMultiplication(simplified)
	case "/":
		return simplifyDivision(simplified)
	case "^":
		return simplifyExponentiation(simplified)
	default:
		if result, ok := tryConstantFolding(simplified); ok {
			return result
		}
		return simplified
	}
}

// simplifyAddition handles addition simplification
func simplifyAddition(node ExprNode) Expression {
	if result, ok := tryConstantFolding(node); ok {
		return result
	}

	// Filter out zeros and collect non-zero terms
	nonZeroArgs := make([]interface{}, 0, len(node.Args))
	for _, arg := range node.Args {
		if !isZero(arg) {
			nonZeroArgs = append(nonZeroArgs, arg)
		}
	}

	switch len(nonZeroArgs) {
	case 0:
		return 0.0
	case 1:
		return nonZeroArgs[0]
	default:
		return ExprNode{Op: "+", Args: nonZeroArgs}
	}
}

// simplifySubtraction handles subtraction simplification
func simplifySubtraction(node ExprNode) Expression {
	if len(node.Args) == 1 {
		// Unary minus
		if isZero(node.Args[0]) {
			return 0.0
		}
		return node
	}

	if len(node.Args) == 2 {
		if result, ok := tryConstantFolding(node); ok {
			return result
		}

		// x - 0 = x
		if isZero(node.Args[1]) {
			return node.Args[0]
		}
	}

	return node
}

// simplifyMultiplication handles multiplication simplification
func simplifyMultiplication(node ExprNode) Expression {
	if result, ok := tryConstantFolding(node); ok {
		return result
	}

	// Check for zeros - if any argument is zero, result is zero
	for _, arg := range node.Args {
		if isZero(arg) {
			return 0.0
		}
	}

	// Filter out ones
	nonOneArgs := make([]interface{}, 0, len(node.Args))
	for _, arg := range node.Args {
		if !isOne(arg) {
			nonOneArgs = append(nonOneArgs, arg)
		}
	}

	switch len(nonOneArgs) {
	case 0:
		return 1.0
	case 1:
		return nonOneArgs[0]
	default:
		return ExprNode{Op: "*", Args: nonOneArgs}
	}
}

// simplifyDivision handles division simplification
func simplifyDivision(node ExprNode) Expression {
	if len(node.Args) != 2 {
		return node
	}

	if result, ok := tryConstantFolding(node); ok {
		return result
	}

	// 0 / x = 0 (for x != 0)
	if isZero(node.Args[0]) && !isZero(node.Args[1]) {
		return 0.0
	}

	// x / 1 = x
	if isOne(node.Args[1]) {
		return node.Args[0]
	}

	return node
}

// simplifyExponentiation handles exponentiation simplification
func simplifyExponentiation(node ExprNode) Expression {
	if len(node.Args) != 2 {
		return node
	}

	if result, ok := tryConstantFolding(node); ok {
		return result
	}

	base := node.Args[0]
	exponent := node.Args[1]

	// x^0 = 1
	if isZero(exponent) {
		return 1.0
	}

	// x^1 = x
	if isOne(exponent) {
		return base
	}

	// 1^x = 1
	if isOne(base) {
		return 1.0
	}

	// 0^x = 0 (for x > 0)
	if isZero(base) && isPositive(exponent) {
		return 0.0
	}

	return node
}

// arithOp describes a numeric operator: its inclusive arity bounds and a pure
// reduction over already-evaluated float64 arguments. The SAME table drives
// both the scalar evaluator (evaluateExprNode) and constant folding
// (tryConstantFolding), so the two can never again disagree on which ops exist,
// their arity, or how they reduce. maxArgs < 0 means unbounded (n-ary).
//
// apply returns an error on a domain violation (division by zero, log/sqrt of
// an out-of-domain value). The evaluator surfaces that error; folding treats
// ANY apply error (or an arity mismatch) as "cannot fold" and leaves the node
// untouched, so a constant subexpression folds only when it would evaluate
// without error.
type arithOp struct {
	minArgs, maxArgs int
	apply            func(args []float64) (float64, error)
}

func (op arithOp) arityOK(n int) bool {
	return n >= op.minArgs && (op.maxArgs < 0 || n <= op.maxArgs)
}

// arityDesc renders an op's arity bounds for evaluator error messages.
func arityDesc(op arithOp) string {
	switch {
	case op.maxArgs < 0:
		return fmt.Sprintf("at least %d", op.minArgs)
	case op.minArgs == op.maxArgs:
		return strconv.Itoa(op.minArgs)
	default:
		return fmt.Sprintf("%d to %d", op.minArgs, op.maxArgs)
	}
}

// unaryMath wraps a total 1-argument math function as an arithOp.
func unaryMath(fn func(float64) float64) arithOp {
	return arithOp{1, 1, func(a []float64) (float64, error) { return fn(a[0]), nil }}
}

func powApply(a []float64) (float64, error) { return math.Pow(a[0], a[1]), nil }

// arithOpTable is the single source of truth for the scalar-evaluable /
// foldable operator set (esm-spec §4.2). Non-evaluable ops handled before
// argument evaluation (const/enum/fn/D/grad/div/laplacian) are intentionally
// absent.
var arithOpTable = map[string]arithOp{
	"+": {0, -1, func(a []float64) (float64, error) {
		s := 0.0
		for _, x := range a {
			s += x
		}
		return s, nil
	}},
	"*": {0, -1, func(a []float64) (float64, error) {
		p := 1.0
		for _, x := range a {
			p *= x
		}
		return p, nil
	}},
	"-": {1, 2, func(a []float64) (float64, error) {
		if len(a) == 1 {
			return -a[0], nil
		}
		return a[0] - a[1], nil
	}},
	"/": {2, 2, func(a []float64) (float64, error) {
		if a[1] == 0 {
			return 0, fmt.Errorf("division by zero")
		}
		return a[0] / a[1], nil
	}},
	"^":   {2, 2, powApply},
	"**":  {2, 2, powApply}, // §4.2 alias of ^; now folds identically
	"exp": unaryMath(math.Exp),
	"log": {1, 1, func(a []float64) (float64, error) {
		if a[0] <= 0 {
			return 0, fmt.Errorf("log of non-positive number: %g", a[0])
		}
		return math.Log(a[0]), nil
	}},
	"log10": {1, 1, func(a []float64) (float64, error) {
		if a[0] <= 0 {
			return 0, fmt.Errorf("log10 of non-positive number: %g", a[0])
		}
		return math.Log10(a[0]), nil
	}},
	"sqrt": {1, 1, func(a []float64) (float64, error) {
		if a[0] < 0 {
			return 0, fmt.Errorf("sqrt of negative number: %g", a[0])
		}
		return math.Sqrt(a[0]), nil
	}},
	"abs":   unaryMath(math.Abs),
	"sin":   unaryMath(math.Sin),
	"cos":   unaryMath(math.Cos),
	"tan":   unaryMath(math.Tan),
	"asin":  unaryMath(math.Asin),
	"acos":  unaryMath(math.Acos),
	"atan":  unaryMath(math.Atan),
	"atan2": {2, 2, func(a []float64) (float64, error) { return math.Atan2(a[0], a[1]), nil }},
	"sinh":  unaryMath(math.Sinh),
	"cosh":  unaryMath(math.Cosh),
	"tanh":  unaryMath(math.Tanh),
	"asinh": unaryMath(math.Asinh),
	"acosh": unaryMath(math.Acosh),
	"atanh": unaryMath(math.Atanh),
	"sign": {1, 1, func(a []float64) (float64, error) {
		switch {
		case a[0] > 0:
			return 1, nil
		case a[0] < 0:
			return -1, nil
		}
		return 0, nil
	}},
	"min": {2, -1, func(a []float64) (float64, error) {
		r := a[0]
		for _, x := range a[1:] {
			r = math.Min(r, x)
		}
		return r, nil
	}},
	"max": {2, -1, func(a []float64) (float64, error) {
		r := a[0]
		for _, x := range a[1:] {
			r = math.Max(r, x)
		}
		return r, nil
	}},
	"floor": unaryMath(math.Floor),
	"ceil":  unaryMath(math.Ceil),
}

// tryConstantFolding evaluates a node whose op is in arithOpTable and whose
// arguments are all numeric literals, returning (foldedValue, true). It returns
// (node, false) when the op is not foldable, the arity is wrong, an argument is
// non-numeric, or evaluation would error (e.g. log of a non-positive constant —
// left unfolded rather than folded to NaN). Numeric coercion is STRICT: a bare
// string is a variable, never a literal, so a variable named "0" never folds.
func tryConstantFolding(node ExprNode) (Expression, bool) {
	op, ok := arithOpTable[node.Op]
	if !ok || !op.arityOK(len(node.Args)) {
		return node, false
	}
	nums := make([]float64, len(node.Args))
	for i, arg := range node.Args {
		f, isNum := toFloat64Strict(arg)
		if !isNum {
			return node, false
		}
		nums[i] = f
	}
	result, err := op.apply(nums)
	if err != nil {
		return node, false
	}
	return result, true
}

// Evaluate numerically evaluates an expression with variable bindings
func Evaluate(expr Expression, bindings map[string]float64) (float64, error) {
	switch e := expr.(type) {
	case float64:
		return e, nil
	case int:
		return float64(e), nil
	case int64:
		return float64(e), nil
	case string:
		// Variable lookup
		if value, exists := bindings[e]; exists {
			return value, nil
		}
		return 0, fmt.Errorf("unbound variable: %s", e)
	case ExprNode:
		return evaluateExprNode(e, bindings)
	case *ExprNode:
		return evaluateExprNode(*e, bindings)
	default:
		return 0, fmt.Errorf("unknown expression type: %T", expr)
	}
}

// evaluateExprNode evaluates an expression node
func evaluateExprNode(node ExprNode, bindings map[string]float64) (float64, error) {
	// `const` and `fn` carry inline literals / typed payloads that the
	// scalar-only fast path below would reject (a `const` array is not a
	// float; a closed-fn arg may legally be one). Handle them first.
	switch node.Op {
	case "const":
		f, ok := toFloat64(node.Value)
		if !ok {
			return 0, fmt.Errorf("const-op node has non-numeric value (%T): scalar evaluator cannot reduce", node.Value)
		}
		return f, nil
	case "enum":
		// `enum` MUST have been lowered to `const` at load time
		// (esm-spec §9.3). Reaching it here is a bug in the loader.
		return 0, fmt.Errorf("enum op encountered at evaluation time — should have been lowered at load (esm-spec §9.3)")
	case "fn":
		return evaluateFnNode(node, bindings)
	case "D":
		// esm-spec §4.2 / §9.6.8 (open-op-namespace RFC, Change B): `D` is an
		// evaluable-core op only in its STRUCTURAL equation-LHS role. A `D`
		// reaching the evaluator — a spatial `D`, or any `D` in an RHS / observed
		// / rate position — is an unlowered rewrite-target: a discretization rule
		// must lower it to a stencil before evaluation. The gate fires here,
		// before evaluation, with the uniform `unlowered_operator` code.
		wrtDesc := ""
		if node.Wrt != nil {
			wrtDesc = fmt.Sprintf(" (wrt=%s)", *node.Wrt)
		}
		return 0, &EvaluationError{
			Code: "unlowered_operator",
			Message: fmt.Sprintf("unlowered derivative operator 'D'%s reached evaluation: a spatial or "+
				"right-hand-side `D` must be lowered to a stencil by a rewrite rule before evaluation "+
				"(esm-spec §4.2 / §9.6.8).", wrtDesc),
		}
	case "grad", "div", "laplacian":
		// esm-spec §4.2 / §9.6.8 (open-op-namespace RFC, Change D):
		// grad/div/laplacian are NOT evaluable-core ops — they are optional
		// rewrite-target sugar over `D` that a discretization rule must lower to a
		// stencil before evaluation. One reaching the evaluator means no rule
		// lowered it. This format ships no discretization rules; the std-lib lives
		// in EarthSciDiscretizations. Uniform `unlowered_operator` code (mirrors
		// the Julia reference `_compile` grad/div/laplacian arm).
		return 0, &EvaluationError{
			Code: "unlowered_operator",
			Message: fmt.Sprintf("unlowered rewrite-target operator '%s' reached evaluation: no rewrite rule "+
				"lowered it to a stencil (esm-spec §4.2 / §9.6.8). Discretization rules live in "+
				"EarthSciDiscretizations, not this format.", node.Op),
		}
	}
	// Evaluate all arguments first
	args := make([]float64, len(node.Args))
	for i, arg := range node.Args {
		val, err := Evaluate(arg, bindings)
		if err != nil {
			return 0, err
		}
		args[i] = val
	}

	// Apply the operation via the shared op-spec table (the same table that
	// drives constant folding, so the two never diverge on op set / arity).
	op, ok := arithOpTable[node.Op]
	if !ok {
		return 0, fmt.Errorf("unknown operation: %s", node.Op)
	}
	if !op.arityOK(len(args)) {
		return 0, fmt.Errorf("%s: got %d argument(s), expected %s", node.Op, len(args), arityDesc(op))
	}
	return op.apply(args)
}

// Helper functions

// toFloat64 is the LENIENT numeric coercion: it converts the numeric Go types
// AND parses numeric strings (via strconv.ParseFloat, which also accepts
// "NaN"/"Inf"). It exists for TABLE / closed-function extraction
// (registered_functions.go) and `const`-value coercion, where an argument may
// legitimately arrive as a numeric string literal. It MUST NOT be used to test
// whether an expression is a numeric literal for Simplify/folding, because a
// bare string there is a variable reference, not a number — use
// toFloat64Strict instead.
func toFloat64(value interface{}) (float64, bool) {
	switch v := value.(type) {
	case float64:
		return v, true
	case int:
		return float64(v), true
	case float32:
		return float64(v), true
	case int64:
		return float64(v), true
	case int32:
		return float64(v), true
	case string:
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f, true
		}
		return 0, false
	default:
		return 0, false
	}
}

// toFloat64Strict is the STRICT numeric coercion: it accepts only the numeric
// Go types and never parses strings. Simplify/Evaluate identity predicates
// (isZero/isOne/isPositive) and constant folding use it so that a variable
// literally named "0" or "1" is treated as a symbol, never as the number it
// spells.
func toFloat64Strict(value interface{}) (float64, bool) {
	switch v := value.(type) {
	case float64:
		return v, true
	case int:
		return float64(v), true
	case float32:
		return float64(v), true
	case int64:
		return float64(v), true
	case int32:
		return float64(v), true
	default:
		return 0, false
	}
}

// isZero checks if an expression represents the number zero
func isZero(expr interface{}) bool {
	if num, ok := toFloat64Strict(expr); ok {
		return num == 0.0
	}
	return false
}

// isOne checks if an expression represents the number one
func isOne(expr interface{}) bool {
	if num, ok := toFloat64Strict(expr); ok {
		return num == 1.0
	}
	return false
}

// isPositive checks if an expression represents a positive number
func isPositive(expr interface{}) bool {
	if num, ok := toFloat64Strict(expr); ok {
		return num > 0.0
	}
	return false
}

// evaluateFnNode dispatches a closed-registry `fn` op (esm-spec §4.4 / §9.2).
// Each argument is normally evaluated as a scalar; a `const`-op array
// argument (e.g. the `xs` table to `interp.searchsorted`) is passed
// through to the closed function as []float64 without reduction.
//
// The result is lifted to float64 so the rest of the scalar evaluator can
// continue with no special casing — integer outputs of datetime.* widen
// losslessly (≤ 31-bit per the §9.2 contract).
func evaluateFnNode(node ExprNode, bindings map[string]float64) (float64, error) {
	if node.Name == nil || *node.Name == "" {
		return 0, fmt.Errorf("fn op missing required `name` field (esm-spec §4.4)")
	}
	args := make([]interface{}, len(node.Args))
	for i, raw := range node.Args {
		v, err := evaluateFnArg(raw, bindings)
		if err != nil {
			return 0, err
		}
		args[i] = v
	}
	out, err := EvaluateClosedFunction(*node.Name, args)
	if err != nil {
		return 0, err
	}
	switch v := out.(type) {
	case float64:
		return v, nil
	case int32:
		return float64(v), nil
	case int64:
		return float64(v), nil
	default:
		return 0, fmt.Errorf("closed function %q returned unsupported scalar type %T", *node.Name, out)
	}
}

// evaluateFnArg evaluates a single argument to a `fn` op. Most args are
// reduced to scalar float64 via the standard evaluator. A `const`-op
// child carrying an array Value is passed through as []interface{} so
// that closed functions like `interp.searchsorted` receive the table.
func evaluateFnArg(arg interface{}, bindings map[string]float64) (interface{}, error) {
	switch a := arg.(type) {
	case ExprNode:
		if a.Op == "const" {
			return constNodeValue(a)
		}
	case *ExprNode:
		if a != nil && a.Op == "const" {
			return constNodeValue(*a)
		}
	}
	// Scalar path.
	return Evaluate(arg, bindings)
}

// constNodeValue returns the typed payload of a `const`-op node. Numeric
// values come back as float64 / int64 (the parser's normalized literal
// types); arrays come back as []interface{}.
func constNodeValue(node ExprNode) (interface{}, error) {
	if node.Value == nil {
		return nil, fmt.Errorf("const op missing required `value` field (esm-spec §4.2)")
	}
	return node.Value, nil
}
