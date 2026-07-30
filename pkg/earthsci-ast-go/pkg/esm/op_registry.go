package esm

import "fmt"

// op_registry.go answers the two OPERATOR-NAME questions the structural
// validator asks about an expression, and answers them from ONE place:
//
//   - What may a `broadcast` node's `fn` name, and with how many operands?
//     (esm-spec §4.3.4 → diagnostic `invalid_broadcast_fn`; checkBroadcastFn.)
//   - Does element alignment descend into a node's operands?
//     (esm-spec §4.3.4 "Broadcast compatibility" → diagnostic
//     `array_shape_mismatch`; isElementwiseNode, consumed by
//     validate_array_shapes.go.)
//
// They are the same question asked of a name and of a node, which is why they
// share one list. Issues #100 and #101 each arrived carrying its own copy of the
// pointwise-operator set; two hand-maintained spellings of one question is
// exactly how they eventually stop agreeing.
//
// ARITY IS NOT RE-DECLARED HERE. It is read from arithOpTable (expression.go),
// the package's stated single source of truth for the scalar-evaluable operator
// set and its bounds, so the `broadcast` rule and the evaluator can never
// disagree about how many operands an operator takes. That is what makes the
// §4.3.4 contract stateable in one line —
//
//	{"op": "broadcast", "fn": F, "args": A}  is legal
//	exactly when  {"op": F, "args": A}  is legal
//
// — instead of a second, hand-maintained arity rule that drifts. In particular
// a ONE-operand `broadcast(fn: "+")` stays legal (`+(x)` is `x`), while
// `broadcast(fn: "min", [x])` and `broadcast(fn: "sin", [a, b])` are rejected
// for precisely the reason the bare `min(x)` / `sin(a, b)` nodes are.
//
// Mirrors Rust `op_registry::is_scalar_operator` / `is_elementwise_node` /
// `check_broadcast_fn` (pkg/earthsci-ast-rs/src/op_registry.rs) and Python
// `index_alignment.ELEMENTWISE_OPS` (earthsci_ast/index_alignment.py).

// CodeInvalidBroadcastFn: a `broadcast` node's `fn` is absent, does not name a
// scalar operator, or is applied to an argument count that operator's §4.2
// arity does not admit (esm-spec §4.3.4, §9.6.6). The value analogue of
// `unknown_closed_function`: `broadcast` is the one op whose OPERATOR is
// carried as data, so no `op`-keyed check reaches it, and an unchecked `fn` was
// discarded silently rather than failing.
const CodeInvalidBroadcastFn = "invalid_broadcast_fn"

// opBroadcast is the element-wise application op whose operator lives in `fn`.
const opBroadcast = "broadcast"

// scalarOperators is the closed set of SCALAR operators — those whose meaning is
// a POINTWISE map from scalar operands to a scalar result (esm-spec §4.3.4, and
// the `fn` property description in esm-schema.json, which enumerates exactly
// this set).
//
// Everything whose meaning is NOT pointwise is excluded, and each exclusion is
// load-bearing:
//
//   - the array/tensor ops (`aggregate`, `makearray`, `index`, `reshape`,
//     `transpose`, `concat`, and `broadcast` ITSELF) — they RESHAPE, so "apply
//     element-wise" is not defined for them, and a self-referential
//     `fn: "broadcast"` would recurse forever;
//   - the closed-registry invocation `fn` — its callee lives in `name`, not in a
//     `broadcast` node's `fn` field, so it can never legitimately be spelled
//     here;
//   - the form / lowering ops (`D`, `ic`, `Pre`, `const`, `true`, `false`,
//     `enum`, `table_lookup`, `apply_expression_template`) — consumed by system
//     assembly or a lowering pass, never evaluated element-wise;
//   - the build-time relational and geometry ops (`skolem`, `rank`, `distinct`,
//     `argmin`, `argmax`, `intersect_polygon`, `polygon_intersection_area`).
//
// `**` is likewise absent. arithOpTable carries it as an EVALUATOR leniency, but
// the format has no operator aliases (Rust's registry pins that explicitly), so
// it is not a name the format admits here.
//
// Every name here is also a key of arithOpTable: this set only ever CLASSIFIES
// operators the evaluator already knows, it never invents one. That invariant is
// what scalarOpArity relies on, and TestScalarOperatorsAllHaveArity pins it.
var scalarOperators = map[string]struct{}{
	// Arithmetic (§4.2), including the canonical unary negation the
	// canonicalizer emits.
	"+": {}, "-": {}, "*": {}, "/": {}, "^": {}, "neg": {},
	// Elementary functions (§4.2).
	"exp": {}, "log": {}, "ln": {}, "log10": {}, "sqrt": {},
	"abs": {}, "sign": {}, "floor": {}, "ceil": {},
	"sin": {}, "cos": {}, "tan": {}, "asin": {}, "acos": {}, "atan": {},
	"sinh": {}, "cosh": {}, "tanh": {}, "asinh": {}, "acosh": {}, "atanh": {},
	"atan2": {}, "min": {}, "max": {},
	// Comparisons, logic and the pointwise conditional (§4.2).
	"==": {}, "!=": {}, "<": {}, "<=": {}, ">": {}, ">=": {},
	"and": {}, "or": {}, "not": {}, "ifelse": {},
}

// isScalarOperator reports whether op names a scalar (pointwise) operator — the
// NAME question. See scalarOperators.
func isScalarOperator(op string) bool {
	_, ok := scalarOperators[op]
	return ok
}

// scalarOpArity returns the arity bounds the format admits for the scalar
// operator op, sourced from arithOpTable so there is exactly one arity table in
// the package. Reports false for a name that is not a scalar operator, and for
// the (invariant-violating, test-pinned) case of a scalar operator with no
// arithOpTable entry.
func scalarOpArity(op string) (arithOp, bool) {
	if !isScalarOperator(op) {
		return arithOp{}, false
	}
	a, ok := arithOpTable[op]
	return a, ok
}

// isElementwiseNode reports whether element alignment sees THROUGH this node to
// its `args` — i.e. whether the node's operands are in element-wise position
// (esm-spec §4.3.4). This is isScalarOperator lifted from op NAMES to NODES,
// plus the one node whose element-wise-ness lives in a FIELD rather than in its
// name: `broadcast` applies the scalar operator named in `fn` element by
// element, so {"op":"broadcast","fn":"*","args":[w2,z1]} MEANS
// {"op":"*","args":[w2,z1]} and its operands must align exactly as the bare
// spelling's do. Treating `broadcast` as opaque made the two spellings disagree
// — the bare form aligned by index-set name while the `broadcast` form kept a
// positional flatten — which is the divergence issue #100 exists to close.
//
// The node-level / name-level split is exactly why scalarOperators must keep
// EXCLUDING `broadcast`: a `broadcast` NODE is element-wise in its `args`, but
// the STRING "broadcast" is not a kernel name. Ask the node question of a node
// and the name question of a name.
//
// The `fn` guard is deliberately conservative: alignment descends only when `fn`
// names a scalar operator. A `broadcast` carrying any other `fn` has no
// element-wise meaning to preserve — checkBroadcastFn rejects it outright — so
// this arm only decides how an UNVALIDATED document is aligned. An ABSENT `fn`
// likewise keeps the historical `+` classification for that reason.
func isElementwiseNode(node ExprNode) bool {
	if node.Op == opBroadcast {
		fn := "+"
		if node.Fn != nil {
			fn = *node.Fn
		}
		return isScalarOperator(fn)
	}
	return isScalarOperator(node.Op)
}

// checkBroadcastFnNode records the `invalid_broadcast_fn` structural error a
// malformed `broadcast` node warrants, at `path` — the CONTAINING expression
// FIELD (`/models/M/equations/0/rhs`), the pointer granularity §7.1.2 and the
// shared corpus pin.
//
// The rule itself is delegated wholesale to checkBroadcastFn, so the structural
// scan and any other caller cannot disagree about which files are acceptable.
// Both failure shapes it returns become the one `invalid_broadcast_fn` code,
// because from the file's point of view they are one defect: this `fn`/`args`
// pair is not a scalar-operator application.
//
// Note the deliberately NARROW scope. This is not a general op-registry sweep
// inside the structural scan: the arities of ordinary `op` nodes are still
// checked only by the evaluator. `broadcast.fn` is singled out because it is the
// one operator name that no `op`-keyed check can ever see, and because getting
// it wrong is silent (issue #101) rather than loud.
func (s *structuralScan) checkBroadcastFnNode(node ExprNode, path string) {
	finding := checkBroadcastFn(node)
	if finding == nil {
		return
	}
	details := finding.details
	details["equation_index"] = s.eqIndex
	s.addErr(StructuralError{
		Path:    path,
		Code:    CodeInvalidBroadcastFn,
		Message: finding.message,
		Details: details,
	})
}

// broadcastFnFinding is the single `invalid_broadcast_fn` diagnostic a malformed
// `broadcast` node warrants: the human-readable reason plus the machine-readable
// context that goes into StructuralError.Details.
type broadcastFnFinding struct {
	message string
	details map[string]any
}

// checkBroadcastFn validates a `broadcast` node's `fn` field (esm-spec §4.3.4),
// returning nil when the node is well-formed.
//
// `broadcast` is the one op whose OPERATOR is data: the node says `broadcast`
// but the arithmetic it performs is named by a sibling string field. Nothing
// checked that string, so three distinct defects were accepted silently and all
// three produced a plausible wrong number rather than a diagnostic (issue #101):
//
//  1. A MISSING `fn`. Evaluators defaulted it to "+". There is no default in the
//     spec, and inventing one turns a truncated node into a silent sum.
//  2. An `fn` that NAMES NO SCALAR OPERATOR — a typo ("not_a_real_op") or a
//     non-pointwise op ("aggregate"). One branch covers both: from the file's
//     point of view they are the same defect.
//  3. An `fn`/`args` ARITY MISMATCH, reported against the `fn` NAME because it
//     is literally the same defect the bare node would have.
//
// Note what (3) does NOT reject: a one-operand `broadcast` whose `fn` is
// genuinely n-ary or unary. `broadcast(fn:"+", [x])` and `broadcast(fn:"-",[x])`
// stay legal, because `+(x)` and `-(x)` are legal bare nodes (identity and
// negation). That is the whole point of deriving the rule from arithOpTable
// rather than hard-coding "at least 2".
func checkBroadcastFn(node ExprNode) *broadcastFnFinding {
	if node.Fn == nil {
		return &broadcastFnFinding{
			message: "'broadcast' is missing its 'fn': the field names the scalar operator " +
				"to apply element-wise and has no default (esm-spec §4.3.4)",
			details: map[string]any{"broadcast_fn": nil},
		}
	}
	fnName := *node.Fn
	arity, ok := scalarOpArity(fnName)
	if !ok {
		return &broadcastFnFinding{
			message: fmt.Sprintf(
				"'broadcast' fn '%s' does not name a scalar operator (esm-spec §4.3.4)", fnName),
			details: map[string]any{"broadcast_fn": fnName},
		}
	}
	if !arity.arityOK(len(node.Args)) {
		return &broadcastFnFinding{
			message: fmt.Sprintf(
				"'broadcast' fn '%s' takes %s argument(s), got %d (esm-spec §4.3.4)",
				fnName, arityDesc(arity), len(node.Args)),
			details: map[string]any{
				"broadcast_fn": fnName,
				"got":          len(node.Args),
				"expected":     arityDesc(arity),
			},
		}
	}
	return nil
}
