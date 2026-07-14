package esm

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"reflect"
	"sort"
	"strconv"
	"strings"
)

// Error codes per discretization RFC §5.4.6 / §5.4.7.
var (
	ErrCanonicalNonFinite = errors.New("E_CANONICAL_NONFINITE")
	ErrCanonicalDivByZero = errors.New("E_CANONICAL_DIVBY_ZERO")
	// ErrCanonicalUnsupportedField is returned by CanonicalJSON when a node
	// carries a set field outside the closed emissible set
	// {op,args,wrt,dim,fn,name,value} (arg/bindings tolerated) — the node has
	// no faithful canonical JSON in the pinned encoding. Matches the Julia
	// reference's E_CANONICAL_UNSUPPORTED_FIELD (see canonicalize.jl).
	ErrCanonicalUnsupportedField = errors.New("E_CANONICAL_UNSUPPORTED_FIELD")
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
	case *ExprNode:
		// Guarded, not dereferenced: a typed-nil *ExprNode used to panic here
		// (no audit ID; found while fixing G3). Substitute/asExprNode already treat it
		// as "not a node".
		if e == nil {
			return nil, fmt.Errorf("nil expression")
		}
		return canonOp(*e)
	case ExprNode:
		return canonOp(e)
	default:
		if node, ok := asExprNode(expr); ok {
			return canonOp(node)
		}
		return nil, fmt.Errorf("unknown expression type: %T", expr)
	}
}

func canonFloat(f float64) (Expression, error) {
	if math.IsNaN(f) || math.IsInf(f, 0) {
		return nil, ErrCanonicalNonFinite
	}
	return f, nil
}

// canonicalizeChild is the TOTAL child function handed to mapExprChildren by
// canonOp. It canonicalizes every shape that belongs to the canonicalizable
// tier — numbers, strings, and operator nodes in ANY spelling (value, pointer,
// or a raw decoded map carrying a string "op") — and passes EVERYTHING ELSE
// through unchanged.
//
// The raw-map arm is part of the fix for audit G3: a non-`args` subtree spelled as a
// map used to fall into the `default:` pass-through, so `Canonicalize` left it
// completely un-canonicalized (an integral's `upper: {+: [0, "a"]}` stayed
// instead of folding to "a"). mapExprChildren still walks fields that hold raw
// NON-operator JSON (Attrs/Ranges/Regions bound pairs — json.Number, bool,
// slices, nil), and those are not canonicalizable, so they must ride through
// as-is to honor the walker's totality contract.
func canonicalizeChild(child Expression) (Expression, error) {
	switch child.(type) {
	case int, int32, int64, float32, float64, string, ExprNode, *ExprNode:
		return Canonicalize(child)
	}
	if _, ok := asExprNode(child); ok {
		return Canonicalize(child)
	}
	return child, nil
}

func canonOp(node ExprNode) (Expression, error) {
	// Step 1: recursively canonicalize every child. Route through the shared
	// field-preserving walker so EVERY field rides through untouched (the copy
	// starts as `out := node`) instead of the old hand-picked
	// Op/Args/Wrt/Dim/Fn/Name/Value subset that silently dropped
	// Var/Lower/Upper/Table/axes/output/… — the confirmed integral bug.
	work, err := mapExprChildren(node, canonicalizeChild)
	if err != nil {
		return nil, err
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
func partitionIdentity(args []any, identityValue int64) (others []any, hadInt, hadFloat bool) {
	others = make([]any, 0, len(args))
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

func allFloatLiterals(args []any) bool {
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
			return canonNeg(ExprNode{Op: "neg", Args: []any{b}})
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
	return ExprNode{Op: "neg", Args: []any{x}}, nil
}

// flattenSameOp inlines nested same-op children.
func flattenSameOp(args []any, op string) []any {
	out := make([]any, 0, len(args))
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

func exprIsFloat(a any) bool {
	_, ok := a.(float64)
	return ok
}

func exprIsIntLiteral(a any) bool {
	_, ok := a.(int64)
	return ok
}

func exprIsZeroAny(a any) bool {
	switch v := a.(type) {
	case int64:
		return v == 0
	case float64:
		return v == 0.0
	}
	return false
}

func exprIsZeroInt(a any) bool {
	v, ok := a.(int64)
	return ok && v == 0
}

func exprIsZeroFloat(a any) bool {
	v, ok := a.(float64)
	return ok && v == 0.0
}

func exprIsOneAny(a any) bool {
	switch v := a.(type) {
	case int64:
		return v == 1
	case float64:
		return v == 1.0
	}
	return false
}

func exprIsOneFloat(a any) bool {
	v, ok := a.(float64)
	return ok && v == 1.0
}

// sortArgs sorts args in place per §5.4.2.
//
//  1. Numeric literals first, ascending value, int-before-float at equal magnitude.
//  2. Bare strings lexicographically.
//  3. Non-leaf nodes by canonical JSON byte compare.
func sortArgs(args []any) {
	// Memoize the canonical JSON for non-leaf nodes to avoid quadratic serialization.
	jsonCache := make(map[int]string)
	getJSON := func(idx int, a any) string {
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
	sorted := make([]any, n)
	for i, k := range idx {
		sorted[i] = args[k]
	}
	copy(args, sorted)
}

func argTier(a any) int {
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

func argLess(a, b any, ia, ib int, getJSON func(int, any) string) bool {
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

func numericKey(a any) float64 {
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
	// Gate the INPUT tree, before any rewriting. The algebraic rewrites
	// (canonAdd/canonMul/canonNeg) legitimately rebuild their node from scratch —
	// the op name, arg list, even the node's very existence can change — and in
	// doing so they DROP every non-`args` field. Screening only the rewritten
	// tree therefore left the fail-closed gate a fiction for exactly the most
	// common ops: a `label` on a `*` node was silently dropped rather than
	// rejected, which is the audit-G9 bug the allow-list exists to prevent.
	// Screening the input makes the gate independent of what the rewrites do.
	if err := validateEmissibleFields(expr); err != nil {
		return nil, err
	}
	c, err := Canonicalize(expr)
	if err != nil {
		return nil, err
	}
	// Fail-closed emissibility gate (twin of Julia's _emit_node_json check).
	// Canonicalize is field-preserving, so a node may still carry a field with
	// no slot in the pinned 7-field canonical encoding; such a node has no
	// faithful canonical JSON and is rejected here rather than emitted lossily.
	if err := validateEmissibleFields(c); err != nil {
		return nil, err
	}
	s, err := emitCanonicalJSON(c)
	if err != nil {
		return nil, err
	}
	return []byte(s), nil
}

// validateEmissibleFields walks a canonicalized tree and returns
// ErrCanonicalUnsupportedField if any ExprNode carries a SET field outside the
// closed emissible set {op, args, wrt, dim, fn, name, value}. `arg` and
// `bindings` are TOLERATED (present, ignored, never emitted), matching the
// Julia reference (canonicalize.jl _CANONICAL_IGNORED_FIELDS). Recurses through
// `args` only — the sole emissible slot that can carry child ExprNodes — exactly
// as the Julia emitter recurses, so every node the emitter would visit is
// screened.
func validateEmissibleFields(a any) error {
	var n ExprNode
	switch v := a.(type) {
	case ExprNode:
		n = v
	case *ExprNode:
		n = *v
	default:
		return nil
	}
	if exprNodeHasNonEmissibleField(n) {
		return ErrCanonicalUnsupportedField
	}
	for _, child := range n.Args {
		if err := validateEmissibleFields(child); err != nil {
			return err
		}
	}
	return nil
}

// canonicalEmissibleFields is the CLOSED set of ExprNode JSON field names the
// pinned canonical encoding (RFC §5.4.6) has a slot for. Extending it is a
// cross-binding format change, never a Go-local edit.
var canonicalEmissibleFields = map[string]struct{}{
	"op": {}, "args": {}, "wrt": {}, "dim": {}, "fn": {}, "name": {}, "value": {},
}

// canonicalIgnoredFields are fields that MAY be present on a node reaching the
// canonical emitter and are silently ignored rather than rejected — they are
// never emitted. Mirrors the Julia reference's _CANONICAL_IGNORED_FIELDS
// (canonicalize.jl).
//
// `id` and `expect_cadence` are here because they are semantically INERT
// annotations: `id` is an external handle (the referent of a derived index set)
// and `expect_cadence` is an author's assertion about update frequency. Neither
// participates in the value the canonical form keys, two nodes differing only in
// them denote the same value, and both appear on ordinary documents
// (tests/valid/cadence/*.esm) — so rejecting them would make CanonicalJSON fail
// on legitimate files. They are dropped from the canonical encoding, not
// rejected. `label` is deliberately NOT here: it is non-emissible and rejected,
// matching TS's E_CANONICAL_UNSUPPORTED_FIELD.
var canonicalIgnoredFields = map[string]struct{}{
	"arg": {}, "bindings": {}, "id": {}, "expect_cadence": {},
}

// exprNodeHasNonEmissibleField reports whether n carries any SET field that the
// canonical encoding has no slot for.
//
// ALLOW-LIST, derived by reflection over the ExprNode struct — the point being
// that it FAILS CLOSED. The previous implementation was a hand-maintained
// DENY-list which claimed "every OTHER field is listed here explicitly" and then
// omitted `label`: a skolem node's documentary relation tag was silently DROPPED
// from the canonical JSON instead of being rejected (audit G9), and `id` /
// `expect_cadence` would have been dropped the same way the moment they were
// modeled. Enumerating the struct's own json tags means a NEW field is
// non-emissible by default and cannot slip through unnoticed — the fail-closed
// discipline Julia gets from deriving its list from `fieldnames(OpExpr)`.
func exprNodeHasNonEmissibleField(n ExprNode) bool {
	v := reflect.ValueOf(n)
	t := v.Type()
	for i := 0; i < t.NumField(); i++ {
		name := jsonFieldName(t.Field(i))
		if name == "" || name == "-" {
			continue
		}
		if _, emissible := canonicalEmissibleFields[name]; emissible {
			continue
		}
		if _, ignored := canonicalIgnoredFields[name]; ignored {
			continue
		}
		if fieldIsSet(v.Field(i)) {
			return true
		}
	}
	return false
}

// jsonFieldName returns the JSON wire name of a struct field (the part of its
// `json:` tag before the first comma), falling back to the Go field name.
func jsonFieldName(f reflect.StructField) string {
	tag, ok := f.Tag.Lookup("json")
	if !ok {
		return f.Name
	}
	if i := strings.IndexByte(tag, ','); i >= 0 {
		tag = tag[:i]
	}
	if tag == "" {
		return f.Name
	}
	return tag
}

// fieldIsSet reports whether a field carries a value: a non-nil pointer /
// interface, or a non-empty slice / map. Scalars other than those are always
// "set" (only `op`, a string, is in that class, and it is emissible).
func fieldIsSet(v reflect.Value) bool {
	switch v.Kind() {
	case reflect.Pointer, reflect.Interface:
		return !v.IsNil()
	case reflect.Slice, reflect.Map:
		return v.Len() > 0
	case reflect.String:
		return v.Len() > 0
	default:
		return !v.IsZero()
	}
}

func emitCanonicalJSON(a any) (string, error) {
	switch v := a.(type) {
	case int64:
		return strconv.FormatInt(v, 10), nil
	case int:
		return strconv.FormatInt(int64(v), 10), nil
	case int32:
		return strconv.FormatInt(int64(v), 10), nil
	case float64:
		if math.IsNaN(v) || math.IsInf(v, 0) {
			return "", ErrCanonicalNonFinite
		}
		return formatCanonicalFloat(v), nil
	case float32:
		f := float64(v)
		if math.IsNaN(f) || math.IsInf(f, 0) {
			return "", ErrCanonicalNonFinite
		}
		return formatCanonicalFloat(f), nil
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
	case []any:
		// Composite payloads (const/makearray arrays, nested value lists) recurse
		// so nested floats keep their §5.4.6 trailing-.0 disambiguation instead of
		// collapsing to bare integers via json.Marshal.
		parts := make([]string, len(v))
		for i, e := range v {
			s, err := emitCanonicalJSON(e)
			if err != nil {
				return "", err
			}
			parts[i] = s
		}
		return "[" + strings.Join(parts, ",") + "]", nil
	case map[string]any:
		return emitCanonicalObject(sortedKeys(v), func(k string) any { return v[k] })
	case bool:
		if v {
			return "true", nil
		}
		return "false", nil
	case nil:
		return "null", nil
	}
	// Fall back to encoding/json for other types (json.Number keeps its raw
	// token; not otherwise expected in canonical ASTs).
	b, err := json.Marshal(a)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// emitCanonicalObject renders a JSON object with keys emitted in `keys` order
// (callers pass sorted keys) and values rendered via emitCanonicalJSON so
// nested floats stay canonical. Shared by the map arm of emitCanonicalJSON and
// by every map-valued field of emitExprNodeJSON.
func emitCanonicalObject(keys []string, get func(string) any) (string, error) {
	var buf bytes.Buffer
	buf.WriteByte('{')
	for i, k := range keys {
		if i > 0 {
			buf.WriteByte(',')
		}
		kb, _ := json.Marshal(k)
		buf.Write(kb)
		buf.WriteByte(':')
		vs, err := emitCanonicalJSON(get(k))
		if err != nil {
			return "", err
		}
		buf.WriteString(vs)
	}
	buf.WriteByte('}')
	return buf.String(), nil
}

// emitExprNodeJSON renders an ExprNode's canonical JSON object, emitting ONLY
// the CLOSED emissible field set the cross-binding canonical encoding pins:
// op, args, wrt, dim, fn, name, value (RFC §5.4.6). `op` and `args` are always
// present (`args` as `[]` when empty); wrt/dim/fn/name emit when their *string
// is non-nil; value emits when non-nil. Keys are emitted in sorted byte order
// to match json.Marshal.
//
// Extending this set is a cross-binding format change, never a Go-local edit.
// A node carrying any NON-emissible set field never reaches here: CanonicalJSON
// screens it up front (validateEmissibleFields → ErrCanonicalUnsupportedField),
// matching the Julia reference's fail-closed _emit_node_json.
func emitExprNodeJSON(n ExprNode) (string, error) {
	kv := make([][2]string, 0, 7)
	appendRaw := func(key, val string) { kv = append(kv, [2]string{key, val}) }
	appendStr := func(key string, p *string) {
		if p != nil {
			b, _ := json.Marshal(*p)
			appendRaw(key, string(b))
		}
	}

	// op (always) and args (always, `[]` when empty).
	opJSON, err := json.Marshal(n.Op)
	if err != nil {
		return "", err
	}
	appendRaw("op", string(opJSON))
	argParts := make([]string, len(n.Args))
	for i, a := range n.Args {
		s, e := emitCanonicalJSON(a)
		if e != nil {
			return "", e
		}
		argParts[i] = s
	}
	appendRaw("args", "["+strings.Join(argParts, ",")+"]")

	// *string emissible slots. `fn` carries the bc kind on synthetic `bc`
	// nodes (§9.2); emitting it symmetrically keeps bc(u,dirichlet,…) and
	// bc(u,neumann,…) distinct in the canonical form (ess-tox/G8).
	appendStr("wrt", n.Wrt)
	appendStr("dim", n.Dim)
	appendStr("fn", n.Fn)
	appendStr("name", n.Name)

	// value: the `const`-op literal payload (§4.2 / §9.3).
	if n.Value != nil {
		s, err := emitCanonicalJSON(n.Value)
		if err != nil {
			return "", err
		}
		appendRaw("value", s)
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
//
// Thin alias for the single shared §5.4.6 renderer
// (formatCanonicalFloatShared in floatfmt.go). Callers reach it only for
// finite floats (emitCanonicalJSON screens NaN/±Inf first), so the shared
// renderer's error is never returned here and is intentionally discarded.
func formatCanonicalFloat(f float64) string {
	s, _ := formatCanonicalFloatShared(f)
	return s
}
