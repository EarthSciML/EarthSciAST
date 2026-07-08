package esm

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
)

// Error codes per discretization RFC §5.4.6 / §5.4.7.
var (
	ErrCanonicalNonFinite = errors.New("E_CANONICAL_NONFINITE")
	ErrCanonicalDivByZero = errors.New("E_CANONICAL_DIVBY_ZERO")
)

// Canonicalize applies RFC §5.4 canonical form to an expression tree.
//
// Returns ErrCanonicalNonFinite if the tree contains NaN or ±Inf, and
// ErrCanonicalDivByZero for 0/0. Input is not mutated; callers receive a new
// tree built from the same leaf values.
func Canonicalize(expr Expression) (Expression, error) {
	switch e := expr.(type) {
	case nil:
		return nil, fmt.Errorf("nil expression")
	case int:
		return int64(e), nil
	case int32:
		return int64(e), nil
	case int64:
		return e, nil
	case float32:
		return canonFloat(float64(e))
	case float64:
		return canonFloat(e)
	case string:
		return e, nil
	case ExprNode:
		return canonOp(e)
	case *ExprNode:
		return canonOp(*e)
	default:
		return nil, fmt.Errorf("unknown expression type: %T", expr)
	}
}

func canonFloat(f float64) (Expression, error) {
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return nil, ErrCanonicalNonFinite
	}
	return f, nil
}

func canonOp(node ExprNode) (Expression, error) {
	// Step 1: recursively canonicalize every child.
	newArgs := make([]interface{}, len(node.Args))
	for i, a := range node.Args {
		ca, err := Canonicalize(a)
		if err != nil {
			return nil, err
		}
		newArgs[i] = ca
	}
	work := ExprNode{
		Op:    node.Op,
		Args:  newArgs,
		Wrt:   node.Wrt,
		Dim:   node.Dim,
		// `Fn` carries the boundary-condition kind on synthetic `bc` nodes
		// (esm-spec §9.2); preserve it through canonicalization so the kind
		// survives into the canonical form (symmetric with `Dim`, ess-tox/G8).
		Fn:    node.Fn,
		Name:  node.Name,
		Value: node.Value,
	}

	// Step 2: operator-specific rewrites.
	switch work.Op {
	case "+":
		return canonAdd(work)
	case "*":
		return canonMul(work)
	case "-":
		return canonSub(work)
	case "/":
		return canonDiv(work)
	case "neg":
		return canonNeg(work)
	default:
		return work, nil
	}
}

// canonAdd: flatten, eliminate zeros (type-preserving), order, collapse singletons.
func canonAdd(node ExprNode) (Expression, error) {
	flat := flattenSameOp(node.Args, "+")
	others, hadIntZero, hadFloatZero := partitionIdentity(flat, 0)
	_ = hadIntZero
	// Float-zero is only safe to drop when all survivors are float literals
	// (otherwise we lose the float-promotion hint). If unsafe, keep one 0.0.
	if hadFloatZero && !allFloatLiterals(others) {
		others = append(others, 0.0)
	}
	if len(others) == 0 {
		if hadFloatZero {
			return 0.0, nil
		}
		return int64(0), nil
	}
	if len(others) == 1 {
		return others[0], nil
	}
	sortArgs(others)
	return ExprNode{Op: "+", Args: others}, nil
}

// canonMul: flatten, zero-annihilation, identity elim (type-preserving), order.
func canonMul(node ExprNode) (Expression, error) {
	flat := flattenSameOp(node.Args, "*")
	// Zero annihilation (§5.4.4): preserve the numeric type of the zero.
	for _, a := range flat {
		if exprIsZeroInt(a) {
			return int64(0), nil
		}
		if exprIsZeroFloat(a) {
			if f, ok := a.(float64); ok {
				return f * 0.0, nil // preserves -0.0 signbit
			}
			return 0.0, nil
		}
	}
	others, hadIntOne, hadFloatOne := partitionIdentity(flat, 1)
	_ = hadIntOne
	if hadFloatOne && !allFloatLiterals(others) {
		others = append(others, 1.0)
	}
	if len(others) == 0 {
		if hadFloatOne {
			return 1.0, nil
		}
		return int64(1), nil
	}
	if len(others) == 1 {
		return others[0], nil
	}
	sortArgs(others)
	return ExprNode{Op: "*", Args: others}, nil
}

// partitionIdentity splits args into (non-identity, hadIntIdentity, hadFloatIdentity)
// where identityValue is 0 (for +) or 1 (for *).
func partitionIdentity(args []interface{}, identityValue int64) (others []interface{}, hadInt, hadFloat bool) {
	others = make([]interface{}, 0, len(args))
	for _, a := range args {
		switch v := a.(type) {
		case int64:
			if v == identityValue {
				hadInt = true
				continue
			}
		case float64:
			if v == float64(identityValue) {
				hadFloat = true
				continue
			}
		}
		others = append(others, a)
	}
	return others, hadInt, hadFloat
}

func allFloatLiterals(args []interface{}) bool {
	if len(args) == 0 {
		return false
	}
	for _, a := range args {
		if !exprIsFloat(a) {
			return false
		}
	}
	return true
}

// canonSub: kept as distinct op, preserve arg order, apply identity rules.
// Convert {-, 0, x} to {neg, x} when x is not a literal.
func canonSub(node ExprNode) (Expression, error) {
	if len(node.Args) == 1 {
		// Unary form is typically spelled `neg` on the wire, but tolerate.
		return canonNeg(ExprNode{Op: "neg", Args: node.Args})
	}
	if len(node.Args) == 2 {
		a, b := node.Args[0], node.Args[1]
		// -(0, x) -> neg(x) (with type-preserving: -(0, x_literal) folds to negated literal)
		if exprIsZeroAny(a) {
			return canonNeg(ExprNode{Op: "neg", Args: []interface{}{b}})
		}
		// -(x, 0) -> x, type-preserving: if 0 is float and x is int literal, promote.
		if exprIsZeroAny(b) {
			if exprIsZeroFloat(b) && exprIsIntLiteral(a) {
				return float64(a.(int64)), nil
			}
			return a, nil
		}
	}
	return node, nil
}

// canonDiv: kept as distinct op, preserve order, identity rules, 0/0 error.
func canonDiv(node ExprNode) (Expression, error) {
	if len(node.Args) != 2 {
		return node, nil
	}
	a, b := node.Args[0], node.Args[1]
	if exprIsZeroAny(a) && exprIsZeroAny(b) {
		return nil, ErrCanonicalDivByZero
	}
	// /(x, 1) -> x, with type-preserving.
	if exprIsOneAny(b) {
		if exprIsOneFloat(b) && exprIsIntLiteral(a) {
			return float64(a.(int64)), nil
		}
		return a, nil
	}
	// /(0, x) -> 0 when x != 0 (literally-zero test only; structural x is unknown).
	if exprIsZeroAny(a) && !exprIsZeroAny(b) {
		if exprIsZeroFloat(a) {
			return 0.0, nil
		}
		return int64(0), nil
	}
	return node, nil
}

// canonNeg: neg(neg(x))->x, neg(literal)->negated literal, neg(0)->0.
func canonNeg(node ExprNode) (Expression, error) {
	if len(node.Args) != 1 {
		return node, nil
	}
	x := node.Args[0]
	switch v := x.(type) {
	case int64:
		return -v, nil
	case float64:
		return -v, nil
	case ExprNode:
		if v.Op == "neg" && len(v.Args) == 1 {
			return v.Args[0], nil
		}
	case *ExprNode:
		if v.Op == "neg" && len(v.Args) == 1 {
			return v.Args[0], nil
		}
	}
	return ExprNode{Op: "neg", Args: []interface{}{x}}, nil
}

// flattenSameOp inlines nested same-op children.
func flattenSameOp(args []interface{}, op string) []interface{} {
	out := make([]interface{}, 0, len(args))
	for _, a := range args {
		switch v := a.(type) {
		case ExprNode:
			if v.Op == op {
				out = append(out, v.Args...)
				continue
			}
		case *ExprNode:
			if v.Op == op {
				out = append(out, v.Args...)
				continue
			}
		}
		out = append(out, a)
	}
	return out
}

func exprIsFloat(a interface{}) bool {
	_, ok := a.(float64)
	return ok
}

func exprIsIntLiteral(a interface{}) bool {
	_, ok := a.(int64)
	return ok
}

func exprIsZeroAny(a interface{}) bool {
	switch v := a.(type) {
	case int64:
		return v == 0
	case float64:
		return v == 0.0
	}
	return false
}

func exprIsZeroInt(a interface{}) bool {
	v, ok := a.(int64)
	return ok && v == 0
}

func exprIsZeroFloat(a interface{}) bool {
	v, ok := a.(float64)
	return ok && v == 0.0
}

func exprIsOneAny(a interface{}) bool {
	switch v := a.(type) {
	case int64:
		return v == 1
	case float64:
		return v == 1.0
	}
	return false
}

func exprIsOneFloat(a interface{}) bool {
	v, ok := a.(float64)
	return ok && v == 1.0
}

// sortArgs sorts args in place per §5.4.2.
//
//  1. Numeric literals first, ascending value, int-before-float at equal magnitude.
//  2. Bare strings lexicographically.
//  3. Non-leaf nodes by canonical JSON byte compare.
func sortArgs(args []interface{}) {
	// Memoize the canonical JSON for non-leaf nodes to avoid quadratic serialization.
	jsonCache := make(map[int]string)
	getJSON := func(idx int, a interface{}) string {
		if s, ok := jsonCache[idx]; ok {
			return s
		}
		s, _ := emitCanonicalJSON(a)
		jsonCache[idx] = s
		return s
	}
	// Build an index-preserving slice.
	n := len(args)
	idx := make([]int, n)
	for i := range idx {
		idx[i] = i
	}
	sort.SliceStable(idx, func(i, j int) bool {
		return argLess(args[idx[i]], args[idx[j]], idx[i], idx[j], getJSON)
	})
	sorted := make([]interface{}, n)
	for i, k := range idx {
		sorted[i] = args[k]
	}
	copy(args, sorted)
}

func argTier(a interface{}) int {
	switch a.(type) {
	case int64, float64:
		return 0
	case string:
		return 1
	case ExprNode, *ExprNode:
		return 2
	}
	return 3
}

func argLess(a, b interface{}, ia, ib int, getJSON func(int, interface{}) string) bool {
	ta, tb := argTier(a), argTier(b)
	if ta != tb {
		return ta < tb
	}
	switch ta {
	case 0:
		av, bv, af, bf := numericKey(a), numericKey(b), exprIsFloat(a), exprIsFloat(b)
		if av != bv {
			return av < bv
		}
		// At equal magnitude, int before float.
		return !af && bf
	case 1:
		return a.(string) < b.(string)
	case 2:
		return getJSON(ia, a) < getJSON(ib, b)
	}
	return false
}

func numericKey(a interface{}) float64 {
	switch v := a.(type) {
	case int64:
		return float64(v)
	case float64:
		return v
	}
	return 0
}

// CanonicalJSON emits the canonical on-wire JSON form of an expression per
// §5.4.6: keys sorted, no extraneous whitespace, shortest-round-trip float
// literals with trailing-`.0` disambiguation for integer-valued floats, and
// strict lowercase-e exponent notation without a leading `+`.
//
// The input is canonicalized first; pass an already-canonical tree for a
// no-op canonicalization pass.
func CanonicalJSON(expr Expression) ([]byte, error) {
	c, err := Canonicalize(expr)
	if err != nil {
		return nil, err
	}
	s, err := emitCanonicalJSON(c)
	if err != nil {
		return nil, err
	}
	return []byte(s), nil
}

func emitCanonicalJSON(a interface{}) (string, error) {
	switch v := a.(type) {
	case int64:
		return strconv.FormatInt(v, 10), nil
	case float64:
		if math.IsNaN(v) || math.IsInf(v, 0) {
			return "", ErrCanonicalNonFinite
		}
		return formatCanonicalFloat(v), nil
	case string:
		b, err := json.Marshal(v)
		if err != nil {
			return "", err
		}
		return string(b), nil
	case ExprNode:
		return emitExprNodeJSON(v)
	case *ExprNode:
		return emitExprNodeJSON(*v)
	case bool:
		if v {
			return "true", nil
		}
		return "false", nil
	case nil:
		return "null", nil
	}
	// Fall back to encoding/json for other types (kept for safety; not
	// expected in canonical ASTs).
	b, err := json.Marshal(a)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func emitExprNodeJSON(n ExprNode) (string, error) {
	// Collect key-value pairs then sort by key.
	kv := make([][2]string, 0, 4)
	// op
	opJSON, err := json.Marshal(n.Op)
	if err != nil {
		return "", err
	}
	kv = append(kv, [2]string{"op", string(opJSON)})
	// args
	argParts := make([]string, len(n.Args))
	for i, a := range n.Args {
		s, err := emitCanonicalJSON(a)
		if err != nil {
			return "", err
		}
		argParts[i] = s
	}
	kv = append(kv, [2]string{"args", "[" + strings.Join(argParts, ",") + "]"})
	// Optional fields (only emit when set).
	if n.Wrt != nil {
		b, _ := json.Marshal(*n.Wrt)
		kv = append(kv, [2]string{"wrt", string(b)})
	}
	if n.Dim != nil {
		b, _ := json.Marshal(*n.Dim)
		kv = append(kv, [2]string{"dim", string(b)})
	}
	if n.Fn != nil {
		// `fn` carries the boundary-condition kind on synthetic `bc` nodes
		// (esm-spec §9.2). Emit it symmetrically with `dim`/`wrt` so the kind
		// is preserved in the canonical form — otherwise bc(u,dirichlet,xmin)
		// and bc(u,neumann,xmin) collapse to the same canonical JSON, making
		// the kind/side matcher's canonical equality kind-blind (ess-tox/G8).
		b, _ := json.Marshal(*n.Fn)
		kv = append(kv, [2]string{"fn", string(b)})
	}
	if n.Name != nil {
		b, _ := json.Marshal(*n.Name)
		kv = append(kv, [2]string{"name", string(b)})
	}
	if n.Value != nil {
		s, err := emitCanonicalJSON(n.Value)
		if err != nil {
			return "", err
		}
		kv = append(kv, [2]string{"value", s})
	}
	sort.Slice(kv, func(i, j int) bool { return kv[i][0] < kv[j][0] })
	var buf bytes.Buffer
	buf.WriteByte('{')
	for i, p := range kv {
		if i > 0 {
			buf.WriteByte(',')
		}
		kb, _ := json.Marshal(p[0])
		buf.Write(kb)
		buf.WriteByte(':')
		buf.WriteString(p[1])
	}
	buf.WriteByte('}')
	return buf.String(), nil
}

// formatCanonicalFloat renders a finite float64 per §5.4.6: shortest
// round-trip decimal; plain decimal when 1e-6 <= |x| < 1e21 (with trailing
// `.0` added for integer-valued magnitudes); exponent notation with lowercase
// `e` and no leading `+` otherwise. Negative zero emits as `-0.0`.
func formatCanonicalFloat(f float64) string {
	if f == 0 {
		if math.Signbit(f) {
			return "-0.0"
		}
		return "0.0"
	}
	abs := math.Abs(f)
	useExp := abs < 1e-6 || abs >= 1e21
	if useExp {
		s := strconv.FormatFloat(f, 'e', -1, 64)
		// Go emits e.g. "1e+21", "3e-7"; spec requires no leading + on exp.
		if i := strings.IndexByte(s, 'e'); i != -1 {
			mant := s[:i]
			exp := s[i+1:]
			exp = strings.TrimPrefix(exp, "+")
			// Strip leading zeros on the exponent while preserving the sign:
			// Go emits e.g. "1e-07" for very small numbers on some platforms;
			// ECMAScript emits "1e-7".
			negExp := false
			if strings.HasPrefix(exp, "-") {
				negExp = true
				exp = exp[1:]
			}
			exp = strings.TrimLeft(exp, "0")
			if exp == "" {
				exp = "0"
			}
			if negExp {
				exp = "-" + exp
			}
			s = mant + "e" + exp
		}
		return s
	}
	// Plain decimal form.
	s := strconv.FormatFloat(f, 'f', -1, 64)
	if !strings.ContainsAny(s, ".eE") {
		s += ".0"
	}
	return s
}
