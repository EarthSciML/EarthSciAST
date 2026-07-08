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

// simplifyExprNode performs simplification on an expression node
func simplifyExprNode(node ExprNode) Expression {
	// First, recursively simplify all arguments
	simplifiedArgs := make([]interface{}, len(node.Args))
	for i, arg := range node.Args {
		simplifiedArgs[i] = Simplify(arg)
	}

	// Create a new node with simplified arguments
	simplified := ExprNode{
		Op:   node.Op,
		Args: simplifiedArgs,
		Wrt:  node.Wrt,
		Dim:  node.Dim,
	}

	// Apply simplification rules based on the operator
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
		return tryConstantFolding(simplified)
	}
}

// simplifyAddition handles addition simplification
func simplifyAddition(node ExprNode) Expression {
	// Try constant folding first
	if result := tryConstantFolding(node); !isSameExprNode(result, node) {
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
		// Try constant folding first
		if result := tryConstantFolding(node); !isSameExprNode(result, node) {
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
	// Try constant folding first
	if result := tryConstantFolding(node); !isSameExprNode(result, node) {
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

	// Try constant folding first
	if result := tryConstantFolding(node); !isSameExprNode(result, node) {
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

	// Try constant folding first
	if result := tryConstantFolding(node); !isSameExprNode(result, node) {
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

// tryConstantFolding attempts to evaluate expressions with all constant arguments
func tryConstantFolding(node ExprNode) Expression {
	// Check if all arguments are numbers
	numbers := make([]float64, len(node.Args))
	for i, arg := range node.Args {
		if num, ok := toFloat64(arg); ok {
			numbers[i] = num
		} else {
			// Not all arguments are numbers, return unchanged
			return node
		}
	}

	// All arguments are constants, try to evaluate
	switch node.Op {
	case "+":
		result := 0.0
		for _, num := range numbers {
			result += num
		}
		return result
	case "-":
		if len(numbers) == 1 {
			return -numbers[0]
		} else if len(numbers) == 2 {
			return numbers[0] - numbers[1]
		}
	case "*":
		result := 1.0
		for _, num := range numbers {
			result *= num
		}
		return result
	case "/":
		if len(numbers) == 2 && numbers[1] != 0 {
			return numbers[0] / numbers[1]
		}
	case "^":
		if len(numbers) == 2 {
			return math.Pow(numbers[0], numbers[1])
		}
	case "exp":
		if len(numbers) == 1 {
			return math.Exp(numbers[0])
		}
	case "log":
		if len(numbers) == 1 && numbers[0] > 0 {
			return math.Log(numbers[0])
		}
	case "sqrt":
		if len(numbers) == 1 && numbers[0] >= 0 {
			return math.Sqrt(numbers[0])
		}
	case "sin":
		if len(numbers) == 1 {
			return math.Sin(numbers[0])
		}
	case "cos":
		if len(numbers) == 1 {
			return math.Cos(numbers[0])
		}
	case "tan":
		if len(numbers) == 1 {
			return math.Tan(numbers[0])
		}
	case "sinh":
		if len(numbers) == 1 {
			return math.Sinh(numbers[0])
		}
	case "cosh":
		if len(numbers) == 1 {
			return math.Cosh(numbers[0])
		}
	case "tanh":
		if len(numbers) == 1 {
			return math.Tanh(numbers[0])
		}
	case "abs":
		if len(numbers) == 1 {
			return math.Abs(numbers[0])
		}
	}

	// If we can't evaluate, return the original node
	return node
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

	// Apply the operation
	switch node.Op {
	case "+":
		result := 0.0
		for _, arg := range args {
			result += arg
		}
		return result, nil
	case "-":
		if len(args) == 1 {
			return -args[0], nil
		} else if len(args) == 2 {
			return args[0] - args[1], nil
		}
		return 0, fmt.Errorf("subtraction requires 1 or 2 arguments, got %d", len(args))
	case "*":
		result := 1.0
		for _, arg := range args {
			result *= arg
		}
		return result, nil
	case "/":
		if len(args) != 2 {
			return 0, fmt.Errorf("division requires 2 arguments, got %d", len(args))
		}
		if args[1] == 0 {
			return 0, fmt.Errorf("division by zero")
		}
		return args[0] / args[1], nil
	case "^", "**":
		if len(args) != 2 {
			return 0, fmt.Errorf("exponentiation requires 2 arguments, got %d", len(args))
		}
		return math.Pow(args[0], args[1]), nil
	case "exp":
		if len(args) != 1 {
			return 0, fmt.Errorf("exp requires 1 argument, got %d", len(args))
		}
		return math.Exp(args[0]), nil
	case "log":
		if len(args) != 1 {
			return 0, fmt.Errorf("log requires 1 argument, got %d", len(args))
		}
		if args[0] <= 0 {
			return 0, fmt.Errorf("log of non-positive number: %f", args[0])
		}
		return math.Log(args[0]), nil
	case "log10":
		if len(args) != 1 {
			return 0, fmt.Errorf("log10 requires 1 argument, got %d", len(args))
		}
		if args[0] <= 0 {
			return 0, fmt.Errorf("log10 of non-positive number: %f", args[0])
		}
		return math.Log10(args[0]), nil
	case "sqrt":
		if len(args) != 1 {
			return 0, fmt.Errorf("sqrt requires 1 argument, got %d", len(args))
		}
		if args[0] < 0 {
			return 0, fmt.Errorf("sqrt of negative number: %f", args[0])
		}
		return math.Sqrt(args[0]), nil
	case "abs":
		if len(args) != 1 {
			return 0, fmt.Errorf("abs requires 1 argument, got %d", len(args))
		}
		return math.Abs(args[0]), nil
	case "sin":
		if len(args) != 1 {
			return 0, fmt.Errorf("sin requires 1 argument, got %d", len(args))
		}
		return math.Sin(args[0]), nil
	case "cos":
		if len(args) != 1 {
			return 0, fmt.Errorf("cos requires 1 argument, got %d", len(args))
		}
		return math.Cos(args[0]), nil
	case "tan":
		if len(args) != 1 {
			return 0, fmt.Errorf("tan requires 1 argument, got %d", len(args))
		}
		return math.Tan(args[0]), nil
	case "asin":
		if len(args) != 1 {
			return 0, fmt.Errorf("asin requires 1 argument, got %d", len(args))
		}
		return math.Asin(args[0]), nil
	case "acos":
		if len(args) != 1 {
			return 0, fmt.Errorf("acos requires 1 argument, got %d", len(args))
		}
		return math.Acos(args[0]), nil
	case "atan":
		if len(args) != 1 {
			return 0, fmt.Errorf("atan requires 1 argument, got %d", len(args))
		}
		return math.Atan(args[0]), nil
	case "atan2":
		if len(args) != 2 {
			return 0, fmt.Errorf("atan2 requires 2 arguments, got %d", len(args))
		}
		return math.Atan2(args[0], args[1]), nil
	case "sinh":
		if len(args) != 1 {
			return 0, fmt.Errorf("sinh requires 1 argument, got %d", len(args))
		}
		return math.Sinh(args[0]), nil
	case "cosh":
		if len(args) != 1 {
			return 0, fmt.Errorf("cosh requires 1 argument, got %d", len(args))
		}
		return math.Cosh(args[0]), nil
	case "tanh":
		if len(args) != 1 {
			return 0, fmt.Errorf("tanh requires 1 argument, got %d", len(args))
		}
		return math.Tanh(args[0]), nil
	case "asinh":
		if len(args) != 1 {
			return 0, fmt.Errorf("asinh requires 1 argument, got %d", len(args))
		}
		return math.Asinh(args[0]), nil
	case "acosh":
		if len(args) != 1 {
			return 0, fmt.Errorf("acosh requires 1 argument, got %d", len(args))
		}
		return math.Acosh(args[0]), nil
	case "atanh":
		if len(args) != 1 {
			return 0, fmt.Errorf("atanh requires 1 argument, got %d", len(args))
		}
		return math.Atanh(args[0]), nil
	case "sign":
		if len(args) != 1 {
			return 0, fmt.Errorf("sign requires 1 argument, got %d", len(args))
		}
		if args[0] > 0 {
			return 1.0, nil
		} else if args[0] < 0 {
			return -1.0, nil
		}
		return 0.0, nil
	case "min":
		// n-ary min (esm-spec §4.2 — arity ≥ 2)
		if len(args) < 2 {
			return 0, fmt.Errorf("min requires at least 2 arguments, got %d", len(args))
		}
		result := args[0]
		for _, a := range args[1:] {
			result = math.Min(result, a)
		}
		return result, nil
	case "max":
		// n-ary max (esm-spec §4.2 — arity ≥ 2)
		if len(args) < 2 {
			return 0, fmt.Errorf("max requires at least 2 arguments, got %d", len(args))
		}
		result := args[0]
		for _, a := range args[1:] {
			result = math.Max(result, a)
		}
		return result, nil
	case "floor":
		if len(args) != 1 {
			return 0, fmt.Errorf("floor requires 1 argument, got %d", len(args))
		}
		return math.Floor(args[0]), nil
	case "ceil":
		if len(args) != 1 {
			return 0, fmt.Errorf("ceil requires 1 argument, got %d", len(args))
		}
		return math.Ceil(args[0]), nil
	default:
		return 0, fmt.Errorf("unknown operation: %s", node.Op)
	}
}

// Helper functions

// toFloat64 converts various numeric types to float64
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

// isZero checks if an expression represents the number zero
func isZero(expr interface{}) bool {
	if num, ok := toFloat64(expr); ok {
		return num == 0.0
	}
	return false
}

// isOne checks if an expression represents the number one
func isOne(expr interface{}) bool {
	if num, ok := toFloat64(expr); ok {
		return num == 1.0
	}
	return false
}

// isPositive checks if an expression represents a positive number
func isPositive(expr interface{}) bool {
	if num, ok := toFloat64(expr); ok {
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

// isSameExprNode checks if an expression is the same ExprNode (avoids struct comparison issues)
func isSameExprNode(expr interface{}, node ExprNode) bool {
	exprNode, ok := expr.(ExprNode)
	if !ok {
		return false
	}
	// Simple check - if it's still an ExprNode with the same operation, it wasn't folded
	return exprNode.Op == node.Op
}
