package esm

// `table_lookup` → `interp.linear` / `interp.bilinear` / `index` lowering
// (esm-spec §9.5.3).
//
// A `table_lookup` node is SUGAR. It names a `function_tables` entry plus one
// input expression per declared axis, and §9.5.3 gives the exact §9.2
// closed-function tree it stands for. Nothing downstream of the loader
// evaluated it: `table_lookup` is in expression.go's closedNonScalarOps, so the
// scalar evaluator refused it with `unsupported_operator` (since renamed
// `unevaluable_operator`) while the SAME lookup
// spelled by hand in the lowered form evaluated fine. The lowering existed only
// inside function_tables_lowering_test.go's harness — never on a path a caller
// could reach (issue #188).
//
// WHERE THIS RUNS, AND WHY NOT AT LOAD. §9.5.4 makes `function_tables` and
// `table_lookup` first-class AUTHORED constructs that must survive parse →
// emit, and this binding serializes the typed ESMFile it loaded; rewriting in
// parse.go (where LowerEnums runs) would emit the lowered `fn` form and break
// the round trip. §9.5.3 admits either an in-memory transformation or a thin
// evaluator that dispatches on `table_lookup` directly, so this binding lowers
// IN MEMORY on the way into EVALUATION — (*ESMFile).Evaluate and
// (*FlattenedSystem).Evaluate below — leaving the loaded image, and therefore
// every emit path, authored-as-written.
//
// It is deliberately NOT wired into Flatten. A FlattenedSystem is a serialized
// cross-language contract (tests/conformance/flatten/cases.json, whose corpus
// includes the two function-table fixtures) that renders equations through
// ToASCII: lowering there would replace `sigma_O3_298[lambda_idx=…]` with
// `interp.linear(…)` in the flattened form of a document that authored a table.
// The flattened system instead CARRIES the merged table registry — which is
// what FlattenedSystem.FunctionTables has always been for — and resolves the
// surviving `table_lookup` at evaluation.
//
// Bit-equivalence with the hand-written inline-`const` lookup (§9.5's central
// promise) comes for free: the lowered tree drives the very same
// registered_functions.go `interp.linear` / `interp.bilinear` implementations an
// author would have invoked by hand.
//
// `out_of_bounds: "error"` is REFUSED, not silently clamped — see
// CodeTableOutOfBoundsUnsupported and esm-spec §9.5.3a.
//
// EVERYTHING HERE IS UNEXPORTED except the diagnostic codes. The lowering is an
// implementation detail of evaluation, not a knob a caller reaches for: the
// public surface of the fix is the two Evaluate methods, which hang off types
// this package already exports. Every binding keeps its pass off the public
// entry point for the same reason — Rust's is `pub(crate)`, and Julia's,
// Python's and TypeScript's are absent from their module/package exports — so
// Go declaring three extra symbols in api-surface.json would have been an
// asymmetry produced by this package's surface test being the strictest, not by
// a design decision. The codes stay public: a caller matching on an error
// genuinely needs them, they are the cross-binding §9.5.5 vocabulary every
// binding's registry now carries, and every other Code* constant here is
// declared the same way.

import (
	"encoding/json"
	"fmt"
	"math"
	"strings"
)

// tableLookupError is raised by the §9.5.3 lowering. Code carries one of the
// esm-spec §9.5.5 diagnostic codes (the Code* block in codes.go).
type tableLookupError struct {
	Code    string
	Message string
}

func (e *tableLookupError) Error() string {
	return fmt.Sprintf("[%s] %s", e.Code, e.Message)
}

// DiagnosticCode returns the stable diagnostic code (DiagnosticError).
func (e *tableLookupError) DiagnosticCode() string { return e.Code }

func newTableLookupError(code, format string, a ...any) *tableLookupError {
	return &tableLookupError{Code: code, Message: fmt.Sprintf(format, a...)}
}

// lowerTableLookups returns a copy of file in which every `table_lookup` node
// has been rewritten to its esm-spec §9.5.3 closed-function form. The argument
// is NOT modified, so the caller's document keeps the authored form §9.5.4
// requires it to emit.
//
// A document that declares no `function_tables` cannot contain a resolvable
// lookup, so it is returned AS IS — not even walked, and not cloned: there is
// nothing to lower and nothing that could be observed through the alias.
//
// Returns a *tableLookupError naming the offending construct if any lookup
// cannot be lowered; the returned document is nil in that case, so a caller
// cannot mistake a partially-lowered value for a lowered one.
//
// This is the DOCUMENT-level form the §9.5.6 conformance contract names ("the
// materialized AST a binding produces from a `table_lookup`"), and the tests
// are what read it; evaluation goes through lowerExprTableLookups one
// expression at a time, because that is the granularity Evaluate works at.
// Both drive the same node rewrite, so they cannot disagree.
func lowerTableLookups(file *ESMFile) (*ESMFile, error) {
	if file == nil || len(file.FunctionTables) == 0 {
		return file, nil
	}
	out := cloneForExprLowering(file)
	if err := lowerTableLookupsMut(out); err != nil {
		return nil, err
	}
	return out, nil
}

// lowerTableLookupsMut is lowerTableLookups applied IN PLACE.
//
// Idempotent: one pass leaves no `table_lookup` node behind, so a second finds
// nothing to rewrite. On error the file is left PARTIALLY lowered — the pass
// writes as it walks and does not roll back. A caller that cannot tolerate that
// wants lowerTableLookups.
func lowerTableLookupsMut(file *ESMFile) error {
	if file == nil || len(file.FunctionTables) == 0 {
		return nil
	}
	tables := file.FunctionTables
	return mapFileExprs(file, func(expr Expression) (Expression, error) {
		return lowerExprTableLookups(expr, tables)
	})
}

// Evaluate numerically evaluates expr with THIS DOCUMENT's §9.5 function tables
// in scope: every `table_lookup` is lowered to its §9.5.3 closed-function form
// first, then the ordinary scalar evaluator runs.
//
// It is the document-scoped counterpart of the package-level Evaluate, which
// takes only an expression and therefore cannot resolve a `table_lookup` at all
// — the table registry lives in the document. Reaching for the package-level
// one on a document's own equation is what made a `table_lookup` observed
// unevaluable while its hand-lowered twin worked (issue #188).
func (e *ESMFile) Evaluate(expr Expression, bindings map[string]float64) (float64, error) {
	if e == nil {
		return Evaluate(expr, bindings)
	}
	return evaluateWithTables(expr, e.FunctionTables, bindings)
}

// Evaluate numerically evaluates expr with the flattened system's merged
// function-table registry in scope. Flattening does not lower `table_lookup`
// (see the file header), so this is what resolves the surviving node against
// the FunctionTables the flattened system carries for exactly that purpose.
func (f *FlattenedSystem) Evaluate(expr Expression, bindings map[string]float64) (float64, error) {
	if f == nil {
		return Evaluate(expr, bindings)
	}
	tables := make(map[string]FunctionTable, len(f.FunctionTables))
	for _, ft := range f.FunctionTables {
		tables[ft.Name] = ft.Table
	}
	return evaluateWithTables(expr, tables, bindings)
}

// evaluateWithTables is the shared "lower, then evaluate" step. The lowering
// short-circuits on an expression carrying no `table_lookup`, so the ordinary
// case pays one structural scan and allocates nothing.
func evaluateWithTables(expr Expression, tables map[string]FunctionTable,
	bindings map[string]float64) (float64, error) {
	lowered, err := lowerExprTableLookups(expr, tables)
	if err != nil {
		return 0, err
	}
	return Evaluate(lowered, bindings)
}

// lowerExprTableLookups rewrites expr BOTTOM-UP: children first, so a
// `table_lookup` nested inside another node's axis input (or body, or filter, …)
// is already an `interp.*` tree by the time its parent is rewritten.
//
// Recursion goes through mapExprChildren, the shared field-preserving walker,
// so a lookup hiding in a sidecar field — an aggregate's `expr`, an integral
// bound, a makearray `values` entry, another lookup's `axes` — is reached and
// every non-expression field of the rebuilt node survives.
func lowerExprTableLookups(expr Expression, tables map[string]FunctionTable) (Expression, error) {
	// The guard that keeps a document whose tables are used in one equation
	// from having its entire AST rebuilt equation by equation — and that makes
	// a second pass over an already-lowered document free.
	if !containsTableLookup(expr) {
		return expr, nil
	}
	if node, ok := asExprNode(expr); ok {
		rebuilt, err := mapExprChildren(node, func(child Expression) (Expression, error) {
			return lowerExprTableLookups(child, tables)
		})
		if err != nil {
			return nil, err
		}
		if rebuilt.Op != OpTableLookup {
			return rebuilt, nil
		}
		return lowerTableLookupNode(rebuilt, tables)
	}
	if list, ok := expr.([]any); ok {
		out := make([]any, len(list))
		for i, el := range list {
			lowered, err := lowerExprTableLookups(el, tables)
			if err != nil {
				return nil, err
			}
			out[i] = lowered
		}
		return out, nil
	}
	return expr, nil
}

// containsTableLookup reports whether expr carries a `table_lookup` anywhere,
// in any expression-bearing field.
func containsTableLookup(expr Expression) bool {
	if node, ok := asExprNode(expr); ok {
		if node.Op == OpTableLookup {
			return true
		}
		found := false
		_, _ = mapExprChildren(node, func(child Expression) (Expression, error) {
			if !found && containsTableLookup(child) {
				found = true
			}
			return child, nil
		})
		return found
	}
	if list, ok := expr.([]any); ok {
		for _, el := range list {
			if containsTableLookup(el) {
				return true
			}
		}
	}
	return false
}

// lowerTableLookupNode is the esm-spec §9.5.3 lowering of ONE `table_lookup`.
func lowerTableLookupNode(node ExprNode, tables map[string]FunctionTable) (Expression, error) {
	if node.Table == nil || *node.Table == "" {
		return nil, newTableLookupError(CodeTableLookupUnknownTable,
			"a `table_lookup` node carries no `table` id (esm-spec §9.5.2)")
	}
	id := *node.Table
	table, ok := tables[id]
	if !ok {
		return nil, newTableLookupError(CodeTableLookupUnknownTable,
			"`table_lookup` references table %q, which the document's `function_tables` "+
				"block does not declare", id)
	}
	// The table itself first (esm-spec §9.5.5, in its pinned order): a lookup
	// into a malformed table is reported for the table, whatever else is wrong
	// with the lookup.
	if err := validateFunctionTable(id, table); err != nil {
		return nil, err
	}
	// esm-spec §9.5.3a. `clamp` (the default) is exactly what interp.linear /
	// interp.bilinear do at the ends, so for it the lowering IS the semantics;
	// `error` has no lowered form at all, and answering it with the clamping
	// one would hand back a number the author did not ask for with nothing in
	// the result to say so.
	if table.OutOfBounds != nil && *table.OutOfBounds == "error" {
		return nil, newTableLookupError(CodeTableOutOfBoundsUnsupported,
			"table %q declares `out_of_bounds: \"error\"`, which this binding does not "+
				"implement; the lookup is refused rather than evaluated under \"clamp\" "+
				"(esm-spec §9.5.3a)", id)
	}
	inputs, err := tableAxisInputs(node, table, id)
	if err != nil {
		return nil, err
	}
	outputIdx, err := tableOutputIndex(node, table, id)
	if err != nil {
		return nil, err
	}
	data := tableOutputSlice(table, outputIdx)

	kind := tableInterpolation(table)
	// validateFunctionTable has already matched the kind to the axis count, so
	// exactly one arm applies.
	switch kind {
	case "bilinear":
		return closedFnNode("interp.bilinear", constNode(data),
			tableAxisConst(table.Axes[0]), tableAxisConst(table.Axes[1]),
			inputs[0], inputs[1]), nil
	case "nearest":
		return nearestLookupNode(data, tableAxisConst(table.Axes[0]), inputs[0],
			len(table.Axes[0].Values)), nil
	default:
		return closedFnNode("interp.linear", constNode(data),
			tableAxisConst(table.Axes[0]), inputs[0]), nil
	}
}

// tableInterpolation is the table's `interpolation`, defaulting to "linear".
func tableInterpolation(table FunctionTable) string {
	if table.Interpolation != nil {
		return *table.Interpolation
	}
	return "linear"
}

// validateFunctionTable runs the esm-spec §9.5.5 checks on one table and
// returns the FIRST rule it breaks, in the spec's pinned order (the order of
// Esm.Closed.Tables.validateTable in formal/). Each step covers every axis
// before the next begins:
//
//  1. table_axis_duplicate_name
//  2. table_outputs_duplicate_name
//  3. table_interpolation_axes_mismatch
//  4. table_axis_nan (any axis)
//  5. table_axis_non_monotonic (any axis)
//  6. table_axis_too_short (any axis)
//  7. table_outputs_length_mismatch (outputs declared, data an array)
//  8. table_data_shape_mismatch (the nesting of data)
//  9. table_data_nan
//  10. table_data_shape_mismatch (the `shape` assertion)
//
// It is the ONE place this binding checks a table: load and validate() run it
// on every `function_tables` entry (load_time_checks.go), and the lowering
// repeats it as soon as a lookup's table id resolves. A non-finite axis value
// or data leaf (NaN, +Inf or -Inf) is refused under the NaN code (esm-spec §9.5.5, ruling
// Q-109). One reading of this binding's own: a data leaf that is not a number
// is a nesting mismatch (step 8), since it is not the scalar the implied shape
// puts there.
func validateFunctionTable(id string, table FunctionTable) error {
	// 1.
	seenAxis := make(map[string]bool, len(table.Axes))
	for _, axis := range table.Axes {
		if seenAxis[axis.Name] {
			return newTableLookupError(CodeTableAxisDuplicateName,
				"table %q declares the axis name %q more than once (esm-spec §9.5.1)",
				id, axis.Name)
		}
		seenAxis[axis.Name] = true
	}
	// 2.
	seenOutput := make(map[string]bool, len(table.Outputs))
	for _, name := range table.Outputs {
		if seenOutput[name] {
			return newTableLookupError(CodeTableOutputsDuplicateName,
				"table %q declares the output name %q more than once (esm-spec §9.5.1)",
				id, name)
		}
		seenOutput[name] = true
	}
	// 3.
	kind := tableInterpolation(table)
	want := map[string]int{"linear": 1, "nearest": 1, "bilinear": 2}
	if n, ok := want[kind]; !ok || n != len(table.Axes) {
		return newTableLookupError(CodeTableInterpolationAxesMismatch,
			"table %q declares `interpolation: %q` over %d axes; `linear` and `nearest` "+
				"require 1, `bilinear` requires 2 (esm-spec §9.5.1)",
			id, kind, len(table.Axes))
	}
	// 4.
	for _, axis := range table.Axes {
		for i, v := range axis.Values {
			if math.IsNaN(v) || math.IsInf(v, 0) {
				return newTableLookupError(CodeTableAxisNaN,
					"table %q: axis %q value %d is %v, which is not finite; axis `values` "+
						"must be strictly-increasing FINITE floats (esm-spec §9.5.1)",
					id, axis.Name, i+1, v)
			}
		}
	}
	// 5.
	for _, axis := range table.Axes {
		for i := 1; i < len(axis.Values); i++ {
			if !(axis.Values[i-1] < axis.Values[i]) {
				return newTableLookupError(CodeTableAxisNonMonotonic,
					"table %q: axis %q is not strictly increasing (value %d = %v, "+
						"value %d = %v) (esm-spec §9.5.1)",
					id, axis.Name, i, axis.Values[i-1], i+1, axis.Values[i])
			}
		}
	}
	// 6.
	for _, axis := range table.Axes {
		if len(axis.Values) < 2 {
			return newTableLookupError(CodeTableAxisTooShort,
				"table %q: axis %q has %d values; an axis needs at least 2 (esm-spec §9.5.1)",
				id, axis.Name, len(axis.Values))
		}
	}
	// 7.
	if len(table.Outputs) > 0 {
		if rows, ok := asTableArray(table.Data); ok && len(rows) != len(table.Outputs) {
			return newTableLookupError(CodeTableOutputsLengthMismatch,
				"table %q: `data` has %d rows but the table declares %d outputs; its "+
					"leading dimension must equal `len(outputs)` (esm-spec §9.5.1)",
				id, len(rows), len(table.Outputs))
		}
	}
	// 8.
	shape := tableImpliedShape(table)
	if !tableDataHasShape(table.Data, shape) {
		return newTableLookupError(CodeTableDataShapeMismatch,
			"table %q: the nesting of `data` is not the shape %v that its axes (and "+
				"outputs, when declared) imply (esm-spec §9.5.1)", id, shape)
	}
	// 9.
	if tableDataNonFinite(table.Data) {
		return newTableLookupError(CodeTableDataNaN,
			"table %q: a leaf of `data` is not finite (NaN or ±Inf); table data must be "+
				"finite (esm-spec §9.5.1)", id)
	}
	// 10.
	if table.Shape != nil && !equalInts(table.Shape, shape) {
		return newTableLookupError(CodeTableDataShapeMismatch,
			"table %q: the `shape` assertion %v differs from the shape %v that the "+
				"table implies (esm-spec §9.5.1)", id, table.Shape, shape)
	}
	return nil
}

// tableImpliedShape is `[len(outputs)] ++ [len(axis.values) for each axis]`,
// without the leading entry when `outputs` is absent (esm-spec §9.5.1).
// The slice grows by append rather than from a precomputed capacity, so no
// size arithmetic on document-controlled lengths feeds an allocation.
func tableImpliedShape(table FunctionTable) []int {
	var shape []int
	if len(table.Outputs) > 0 {
		shape = append(shape, len(table.Outputs))
	}
	for _, axis := range table.Axes {
		shape = append(shape, len(axis.Values))
	}
	return shape
}

// asTableArray views a `data` (sub)literal as an array of its elements: the
// []any a decoded document holds, or a []float64 built in memory.
func asTableArray(v any) ([]any, bool) {
	switch a := v.(type) {
	case []any:
		return a, true
	case []float64:
		out := make([]any, len(a))
		for i, f := range a {
			out[i] = f
		}
		return out, true
	}
	return nil, false
}

// tableLeaf reads a `data` leaf as a number; ok is false for anything that is
// not one (an array, a string, nil, ...).
func tableLeaf(v any) (float64, bool) {
	if n, ok := v.(json.Number); ok {
		f, err := n.Float64()
		return f, err == nil
	}
	return toFloat64Strict(v)
}

// tableDataHasShape reports whether the nesting of v is EXACTLY shape: a
// number at shape [], and an array of shape[0] elements each of shape[1:].
func tableDataHasShape(v any, shape []int) bool {
	if len(shape) == 0 {
		_, ok := tableLeaf(v)
		return ok
	}
	elems, ok := asTableArray(v)
	if !ok || len(elems) != shape[0] {
		return false
	}
	for _, e := range elems {
		if !tableDataHasShape(e, shape[1:]) {
			return false
		}
	}
	return true
}

// tableDataNonFinite reports whether some numeric leaf of v is NaN or infinite.
func tableDataNonFinite(v any) bool {
	if elems, ok := asTableArray(v); ok {
		for _, e := range elems {
			if tableDataNonFinite(e) {
				return true
			}
		}
		return false
	}
	f, ok := tableLeaf(v)
	return ok && (math.IsNaN(f) || math.IsInf(f, 0))
}

func equalInts(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// nearestLookupNode builds the esm-spec §9.5.3 `nearest` composition: D at the
// knot nearest x, a tie going to the lower knot, clamped outside the axis, and
// NaN for a NaN query. With j = searchsorted(x, A), lo = max(j-1, 1) and
// hi = min(j, N):
//
//	ifelse(x == x, index(D, ifelse(A[hi]-x < x-A[lo], hi, lo)), x)
//
// The ops and their operand order are exactly the spec's, so every binding
// decides "nearer" and "tie" on the same two binary64 differences. Each use of
// x, A, j, lo and hi is its own copy of the subtree, as the spec writes it.
func nearestLookupNode(data any, axis ExprNode, x Expression, n int) Expression {
	axisConst := func() ExprNode { return constNode(axis.Value) }
	j := func() ExprNode { return closedFnNode("interp.searchsorted", x, axisConst()) }
	lo := func() ExprNode {
		return ExprNode{Op: "max", Args: []any{
			ExprNode{Op: "-", Args: []any{j(), int64(1)}}, int64(1)}}
	}
	hi := func() ExprNode { return ExprNode{Op: "min", Args: []any{j(), int64(n)}} }
	knot := func(k ExprNode) ExprNode { return ExprNode{Op: "index", Args: []any{axisConst(), k}} }
	pick := ExprNode{Op: "ifelse", Args: []any{
		ExprNode{Op: "<", Args: []any{
			ExprNode{Op: "-", Args: []any{knot(hi()), x}},
			ExprNode{Op: "-", Args: []any{x, knot(lo())}},
		}},
		hi(),
		lo(),
	}}
	return ExprNode{Op: "ifelse", Args: []any{
		ExprNode{Op: "==", Args: []any{x, x}},
		ExprNode{Op: "index", Args: []any{constNode(data), pick}},
		x,
	}}
}

// tableAxisInputs returns the node's per-axis input expressions in the table's
// DECLARED axis order — which is the order of `data`'s inner dimensions, and
// therefore the argument order interp.bilinear expects.
func tableAxisInputs(node ExprNode, table FunctionTable, id string) ([]Expression, error) {
	// An absent `args` (nil) is `[]` (esm-spec §9.5.2).
	if len(node.Args) != 0 {
		return nil, newTableLookupError(CodeTableLookupArgsNonempty,
			"`table_lookup` on table %q carries %d positional `args`; the per-axis inputs "+
				"live under `axes` and `args` MUST be empty (esm-spec §9.5.2)",
			id, len(node.Args))
	}
	inputs := make([]Expression, 0, len(table.Axes))
	for _, axis := range table.Axes {
		input, ok := node.TableAxes[axis.Name]
		if !ok {
			return nil, newTableLookupError(CodeTableLookupAxisNameMismatch,
				"`table_lookup` on table %q supplies no input for its declared axis %q",
				id, axis.Name)
		}
		inputs = append(inputs, input)
	}
	// Every declared axis is now accounted for, so a count mismatch here can
	// only mean EXTRA keys — an axis name the table does not declare.
	if len(node.TableAxes) != len(table.Axes) {
		declared := make([]string, len(table.Axes))
		for i, axis := range table.Axes {
			declared[i] = axis.Name
		}
		return nil, newTableLookupError(CodeTableLookupAxisNameMismatch,
			"`table_lookup` on table %q supplies %d axis inputs but the table declares "+
				"%d (%s); the key sets must match exactly (esm-spec §9.5.2)",
			id, len(node.TableAxes), len(declared), strings.Join(declared, ", "))
	}
	return inputs, nil
}

// tableOutputIndex resolves `output` — absent, an integer index, or an output
// name — to a 0-based row of `data`'s leading dimension.
func tableOutputIndex(node ExprNode, table FunctionTable, id string) (int, error) {
	if node.Output == nil {
		return 0, nil
	}
	if name, ok := node.Output.(string); ok {
		if len(table.Outputs) == 0 {
			return 0, newTableLookupError(CodeTableLookupOutputOutOfRange,
				"`table_lookup.output` %q names an output, but table %q declares no "+
					"`outputs` list", name, id)
		}
		for i, declared := range table.Outputs {
			if declared == name {
				return i, nil
			}
		}
		return 0, newTableLookupError(CodeTableLookupOutputOutOfRange,
			"`table_lookup.output` %q is not one of table %q's outputs (%s)",
			name, id, strings.Join(table.Outputs, ", "))
	}
	idx, ok := outputSelectorInt(node.Output)
	if !ok {
		return 0, newTableLookupError(CodeTableLookupOutputOutOfRange,
			"`table_lookup.output` on table %q must be a non-negative integer or an "+
				"output name, not %v (%T)", id, node.Output, node.Output)
	}
	switch {
	case idx < 0:
		return 0, newTableLookupError(CodeTableLookupOutputOutOfRange,
			"`table_lookup.output` on table %q is %d; an integer output index must be ≥ 0",
			id, idx)
	case len(table.Outputs) > 0 && idx >= len(table.Outputs):
		return 0, newTableLookupError(CodeTableLookupOutputOutOfRange,
			"`table_lookup.output` %d on table %q is out of range: the table declares "+
				"%d outputs", idx, id, len(table.Outputs))
	case len(table.Outputs) == 0 && idx != 0:
		// No `outputs` list means the table is single-output and `data` has no
		// leading output dimension at all (§9.5.1), so 0 is the only index that
		// names anything.
		return 0, newTableLookupError(CodeTableLookupOutputOutOfRange,
			"`table_lookup.output` %d on table %q, which declares no `outputs` and is "+
				"therefore single-output", idx, id)
	}
	return idx, nil
}

// outputSelectorInt coerces an integral numeric `output` selector to an int. It
// deliberately does NOT accept strings the way toFloat64 does — a string
// `output` is an output NAME, resolved above — and rejects a fractional value,
// which selects no row.
func outputSelectorInt(v any) (int, bool) {
	if n, ok := v.(json.Number); ok {
		i, err := n.Int64()
		return int(i), err == nil
	}
	f, ok := toFloat64Strict(v)
	if !ok || f != math.Trunc(f) || math.IsInf(f, 0) {
		return 0, false
	}
	return int(f), true
}

// tableOutputSlice returns the `data` sub-array the lowered `const` carries: row
// `output` of the leading dimension for a multi-output table, and the whole
// literal for a single-output one (which has no leading output dimension,
// §9.5.1). The table has passed validateFunctionTable and output has been
// resolved against `outputs`, so the row exists.
func tableOutputSlice(table FunctionTable, output int) any {
	if len(table.Outputs) == 0 {
		return table.Data
	}
	rows, _ := asTableArray(table.Data)
	return rows[output]
}

// tableAxisConst builds the `{"op": "const", "value": <axis values>}` node for
// one declared axis. The values are copied into an []any of float64 — the shape
// a decoded inline-`const` array literal has — so the lowered tree is
// indistinguishable from the hand-written one the author could have typed.
func tableAxisConst(axis FunctionTableAxis) ExprNode {
	values := make([]any, len(axis.Values))
	for i, v := range axis.Values {
		values[i] = v
	}
	return constNode(values)
}

// constNode builds a `const`-op node carrying an inline literal payload.
// `Args` is allocated empty rather than left nil so the node emits the
// `"args": []` the §9.5.3 lowered form spells.
func constNode(value any) ExprNode {
	return ExprNode{Op: OpConst, Args: []any{}, Value: value}
}

// closedFnNode builds a `fn`-op node calling a §9.2 closed-registry function.
func closedFnNode(name string, args ...any) ExprNode {
	return ExprNode{Op: OpFn, Name: &name, Args: args}
}
