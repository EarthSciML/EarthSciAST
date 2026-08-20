package esm

import "fmt"

// validate_array_shapes.go implements the esm-spec §4.3.4 "Broadcast
// compatibility" rule (issue #100): the operands of an ARRAY-LEVEL expression
// align by index-set NAME, not by position.
//
// A **bare** array-level expression is one written over whole arrays with no
// explicit index symbols — `D(dp) ~ w2 * z1`, `p3 ~ w2 * z1`, and the equivalent
// `broadcast` spelling — as opposed to the `aggregate` form, where the author
// names the axes and there is nothing to infer. Its operands align by name:
//
//   - An operand whose declared index sets are a SUBSET of the result's
//     broadcasts along the ones it is missing (a `[lat]` operand replicates
//     along `lon` and `lev` in a `[lon,lat,lev]` result).
//   - Axis ORDER is immaterial — a `[lat,lon]` operand TRANSPOSES into a
//     `[lon,lat]` result; it is never reinterpreted positionally.
//   - An operand carrying an index set the result does NOT have has no axis to
//     align to and no defensible value to contribute. That is a hard structural
//     error, `array_shape_mismatch`.
//
// Both shapes are DECLARED (ModelVariable.Shape plus the document `index_sets`
// registry), so the finding is fully static — which is why a parse-and-validate
// binding can and must make it. The alternative, a positional flatten, validates
// clean and then integrates zero-padded garbage.
//
// The check is deliberately CONSERVATIVE, matching Rust
// (structural.rs `validate_array_broadcast_shapes`) and Python
// (index_alignment.py) exactly:
//
//   - It fires only where BOTH the result and the operand carry declared,
//     non-repeating index-set names. ANONYMOUS shapes — the results of
//     `reshape`/`transpose`/`concat`/`makearray`, literal arrays, and variables
//     whose shape was never declared — name no axes, so they keep the positional
//     regime of §4.3.4 case 2 and are not checked here.
//   - It descends only through ELEMENTWISE nodes (isElementwiseNode,
//     op_registry.go), because those are the only ones for which "corresponding
//     elements" is what the expression means. `aggregate` and `makearray` name
//     their own axes, `index` gathers, the §4.3.5 shape ops restructure, and a
//     geometry kernel legitimately returns a result of an unrelated shape.
//   - It DOES see through a `broadcast` NODE to its `args` when the node's `fn`
//     names a scalar operator, because that node MEANS the bare spelling. Not
//     doing so was the live bug: the bare form aligned by name while the
//     `broadcast` form silently kept the positional flatten.
//   - Checked positions are the whole-array equation LHSs (`D(var)` and bare
//     `var`) and array-shaped observed expressions. An INDEXED LHS
//     (`D(var[i]) ~ …`) is a per-cell equation whose RHS axes are the author's
//     to spell, so it is left alone.

// CodeArrayShapeMismatch: an operand of a bare array-level expression carries a
// declared index set that the expression's result is not shaped over, so there
// is no axis to align it to (esm-spec §4.3.4, §9.6.6; CONFORMANCE_SPEC §7.1).
const CodeArrayShapeMismatch = "array_shape_mismatch"

// validateArrayBroadcastShapes reports every operand of a model's bare
// array-level expressions whose declared index sets are not a subset of the
// result's. See the file comment for the rule and its deliberate limits.
func (s *structuralScan) validateArrayBroadcastShapes(model *Model, basePath string) {
	declaredAxes := make(map[string][]string, len(model.Variables))
	for name, variable := range model.Variables {
		if dims := variable.Dims(); len(dims) > 0 {
			declaredAxes[name] = dims
		}
	}
	if len(declaredAxes) == 0 {
		return
	}

	// Equations whose LHS names a WHOLE array: `D(var) ~ rhs` and `var ~ rhs`.
	for i, eq := range model.Equations {
		target, ok := wholeArrayLHSTarget(eq.LHS)
		if !ok {
			continue
		}
		s.checkOperandAxes(eq.RHS, target, declaredAxes,
			fmt.Sprintf("%s/equations/%d/rhs", basePath, i))
	}

	// An array-shaped OBSERVED unknown's defining expression is the same bare
	// array-level form under the same alignment rule. From esm 1.0.0 that
	// expression IS one of the equations walked above (a bare-variable LHS), so
	// it needs no second pass here — checking it twice would report one defect at
	// two pointers.
}

// wholeArrayLHSTarget returns the whole-array variable an equation LHS defines —
// `D(var, t)` or a bare `var` — and false for an indexed / aggregate /
// expression LHS, which defines cells rather than the whole array.
func wholeArrayLHSTarget(lhs Expression) (string, bool) {
	if name, ok := lhs.(string); ok {
		return name, true
	}
	node, ok := asExprNode(lhs)
	if !ok || node.Op != OpDerivative || len(node.Args) == 0 {
		return "", false
	}
	name, ok := node.Args[0].(string)
	return name, ok
}

// checkOperandAxes reports every operand of the bare array-level expression
// `expr` whose declared index sets are not a subset of `target`'s, at `path` —
// the containing expression FIELD.
func (s *structuralScan) checkOperandAxes(expr Expression, target string, declaredAxes map[string][]string, path string) {
	targetAxes, ok := declaredAxes[target]
	if !ok {
		return
	}
	// A REPEATED axis name gives no unambiguous position to align to, so the
	// positional lowering stands there and this rule says nothing.
	if hasRepeatedName(targetAxes) {
		return
	}
	inTarget := make(map[string]bool, len(targetAxes))
	for _, axis := range targetAxes {
		inTarget[axis] = true
	}

	for _, operand := range collectBareArrayOperands(expr, declaredAxes) {
		operandAxes := declaredAxes[operand]
		for _, axis := range operandAxes {
			if inTarget[axis] {
				continue
			}
			s.addErr(StructuralError{
				Path: path,
				Code: CodeArrayShapeMismatch,
				Message: fmt.Sprintf(
					"Operand '%s' of the array-level expression for '%s' is declared over "+
						"index set '%s', which '%s' is not shaped over",
					operand, target, axis, target),
				Details: map[string]any{
					"variable":          target,
					"operand":           operand,
					"operand_shape":     operandAxes,
					"result_shape":      targetAxes,
					"missing_index_set": axis,
				},
			})
			// One finding per operand: the first unalignable axis already
			// establishes that this operand has no frame in the result.
			break
		}
	}
}

// collectBareArrayOperands returns, in traversal order and without repeats, the
// declared array-shaped variables `expr` references in BARE (whole-array,
// element-wise) position. The descent enters only elementwise nodes — see the
// file comment.
func collectBareArrayOperands(expr Expression, declaredAxes map[string][]string) []string {
	var out []string
	seen := map[string]bool{}
	var walk func(Expression)
	walk = func(e Expression) {
		if name, ok := e.(string); ok {
			if _, declared := declaredAxes[name]; declared && !seen[name] {
				seen[name] = true
				out = append(out, name)
			}
			return
		}
		if list, ok := e.([]any); ok {
			for _, el := range list {
				walk(el)
			}
			return
		}
		node, ok := asExprNode(e)
		if !ok || !isElementwiseNode(node) {
			return
		}
		_, _ = mapExprChildren(node, func(child Expression) (Expression, error) {
			walk(child)
			return child, nil
		})
	}
	walk(expr)
	return out
}

// hasRepeatedName reports whether names contains the same entry twice.
func hasRepeatedName(names []string) bool {
	seen := make(map[string]bool, len(names))
	for _, n := range names {
		if seen[n] {
			return true
		}
		seen[n] = true
	}
	return false
}
