package docfmt

// What the Go readers bound that the Lean model leaves unbounded, as the Rust
// readers do (`document::limits`).
//
// The Lean model's numbers, exponents and recursion are unbounded. The readers
// refuse, with `parse_error`, a document past one of these bounds, rather than
// read it as something else or run out of stack:
//
//   - Nesting. At most MaxNesting constructs open at once across the
//     recursive-descent readers: math sub-expressions (a bracket, a fraction,
//     a prefix `-` or `\lnot`, a `cases` row, a JSON value in an escape node),
//     Typst values, YAML blocks and flow collections. Each enters the read's
//     Lim while it reads its contents, at the points the Rust readers hold a
//     `Nest`, so both refuse at the same depth.
//   - Depth. A document read from Markdown or Typst nests at most
//     MaxJSONDepth arrays and objects (the depth serde_json reads). A
//     left-nested chain (`a - b - c - …`, LaTeX `a / b / c`, Typst
//     `a / b / c`) is checked as it grows, since it deepens the value without
//     nesting the reader.
//   - Numbers. A decimal beyond the binary64 range (`1.0e400`) has no value a
//     JSON document can hold (ToGoChecked); a decimal exponent outside int64
//     is not a number token (numMkDec).
//
// Rust keeps this state in a thread-local; here each read carries its own *Lim
// through the readers, so concurrent reads never share it. The readers stay
// ports of the Lean functions, which refuse every bad input alike; the Lim
// collects what a read ran into, so the refusal can say which bound it hit and
// which removed operator its math names.

// MaxNesting is the most constructs a reader holds open at once.
const MaxNesting = 128

// MaxJSONDepth is the deepest nesting of arrays and objects in a read
// document: the most serde_json reads (its recursion limit of 128 counts the
// outermost value too).
const MaxJSONDepth = 127

// Lim is the state of one read: how many constructs are open, and what the
// read ran into besides its result.
type Lim struct {
	depth int
	// TooDeep reports a construct nested past MaxNesting, or a value deeper
	// than MaxJSONDepth.
	TooDeep bool
	// RemovedOp is the first removed operator (esm-spec §4.2) the math parser
	// met in a call or escape form; empty when none.
	RemovedOp string
}

// enter opens a construct: false, recorded as TooDeep, when MaxNesting are
// open already. Each true return is paired with a leave.
func (l *Lim) enter() bool {
	if l.depth < MaxNesting {
		l.depth++
		return true
	}
	l.TooDeep = true
	return false
}

// leave closes a construct enter opened.
func (l *Lim) leave() { l.depth-- }

// noteRemovedOp records a removed operator the math names (the first one is
// kept).
func (l *Lim) noteRemovedOp(op string) {
	if l.RemovedOp == "" {
		l.RemovedOp = op
	}
}

// shallow is j and true when j is no deeper than MaxJSONDepth; otherwise
// false, recorded as TooDeep.
func (l *Lim) shallow(j Json) (Json, bool) {
	if JSONDepth(j) <= MaxJSONDepth {
		return j, true
	}
	l.TooDeep = true
	return nil, false
}

// JSONDepth is the nesting depth of arrays and objects in a value (0 for a
// scalar), found without recursion.
func JSONDepth(j Json) int {
	type item struct {
		v Json
		d int
	}
	maxDepth := 0
	stack := []item{{j, 0}}
	for len(stack) > 0 {
		it := stack[len(stack)-1]
		stack = stack[:len(stack)-1]
		switch x := it.v.(type) {
		case []Json:
			maxDepth = max(maxDepth, it.d+1)
			for _, e := range x {
				stack = append(stack, item{e, it.d + 1})
			}
		case Obj:
			maxDepth = max(maxDepth, it.d+1)
			for _, kv := range x {
				stack = append(stack, item{kv.V, it.d + 1})
			}
		}
	}
	return maxDepth
}
