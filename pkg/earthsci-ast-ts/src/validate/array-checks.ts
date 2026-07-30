/**
 * The two structural rules that govern an ARRAY-LEVEL expression (esm-spec
 * §4.3.4), both decidable from the document alone:
 *
 *   - {@link validateBroadcastFns} — `invalid_broadcast_fn`. A `broadcast`
 *     node's `fn` must name a scalar operator, applied at an arity that
 *     operator admits.
 *   - {@link validateArrayBroadcastShapes} — `array_shape_mismatch`. An
 *     operand of an array-level expression must be alignable to the result by
 *     index-set NAME.
 *
 * They live together because they share one keystone: {@link isElementwiseNode}
 * / {@link isScalarOperator} from the op registry. The first asks the NAME
 * question ("may this `fn` be applied element-wise?"), the second the NODE
 * question ("do this node's operands sit in element-wise position?"), and both
 * derive their answer — including the legal operand COUNT — from the single
 * registry row for the operator. A second, hand-maintained list of "scalar ops"
 * or "broadcast arities" is exactly how the two would drift.
 *
 * Neither rule needs an evaluator: both shapes and the operator vocabulary are
 * DECLARED, which is why a parse-and-validate binding can and must implement
 * them.
 */

import { isExprNode, forEachChild } from '../expression.js'
import { ERROR_CODES } from '../errors.js'
import { checkBroadcastFn, isElementwiseNode } from '../op-registry.js'
import type { Model, ReactionSystem, Expression, ExpressionNode } from '../types.js'
import type { Expr } from '../expression.js'
import type { StructuralError } from './types.js'
import { forEachExpressionScope } from '../traverse.js'

// ---------------------------------------------------------------------------
// Rule 1 — `invalid_broadcast_fn` (esm-spec §4.3.4)
// ---------------------------------------------------------------------------

/**
 * The equation index a site's JSON Pointer names, when it names one.
 *
 * `details.equation_index` is part of the shared record shape for expression
 * findings (`tests/invalid/expected_errors.json`), and the pointer already
 * carries it — `…/equations/0/rhs`. Reading it back from the pointer keeps the
 * site enumeration in ONE place ({@link forEachExpressionScope}) instead of
 * forcing every checker that wants the index to re-walk the component. Sites
 * outside an equation (an observed `expression`, an event affect) legitimately
 * have none.
 */
function equationIndexOf(path: string): number | undefined {
  const match = /\/(?:equations|initialization_equations|constraint_equations)\/(\d+)\//.exec(path)
  return match ? Number(match[1]) : undefined
}

/**
 * Report every `broadcast` node in a component whose `fn`/`args` pair is not a
 * legal scalar-operator application (esm-spec §4.3.4).
 *
 * This rides {@link forEachExpressionScope} — the same enumeration reference
 * integrity uses — deliberately. `broadcast.fn` is a NAME embedded in an
 * expression, exactly like the variable names that walk resolves, and every
 * expression-bearing field of a component already routes through it: equations,
 * `initialization_equations`, `guesses`, observed `expression`s, event triggers
 * / conditions / affects, and inline-test references. A separate pass would
 * have had to re-enumerate all of them, and would have drifted.
 *
 * The rule itself is delegated wholesale to {@link checkBroadcastFn}, so
 * `validate()` and any future evaluator cannot disagree about which files are
 * acceptable. Both failure shapes become the one `invalid_broadcast_fn` code,
 * because from the file's point of view they are one defect: this `fn`/`args`
 * pair is not a scalar operator application.
 */
export function validateBroadcastFns(
  component: Model | ReactionSystem,
  componentPath: string,
): StructuralError[] {
  const errors: StructuralError[] = []
  forEachExpressionScope(component, componentPath, (scope) => {
    for (const site of scope) {
      const equationIndex = equationIndexOf(site.path)
      visitBroadcastNodes(site.expr, (node) => {
        const violation = checkBroadcastFn(node)
        if (violation === null) return
        errors.push({
          path: site.path,
          code: ERROR_CODES.INVALID_BROADCAST_FN,
          message: violation.message,
          details:
            equationIndex === undefined
              ? violation.details
              : { ...violation.details, equation_index: equationIndex },
        })
      })
    }
  })
  return errors
}

/** Visit every `broadcast` node in an expression tree, at any depth. */
function visitBroadcastNodes(expr: Expression, fn: (node: ExpressionNode) => void): void {
  const visit = (node: Expr): void => {
    if (!isExprNode(node)) return
    if (node.op === 'broadcast') fn(node)
    forEachChild(node, visit)
  }
  visit(expr)
}

// ---------------------------------------------------------------------------
// Rule 2 — `array_shape_mismatch` (esm-spec §4.3.4 "Broadcast compatibility")
// ---------------------------------------------------------------------------

/**
 * A variable's declared `shape` as an axis-NAME list, or `undefined` when it
 * carries no usable name frame.
 *
 * `undefined` — meaning "fall back to positional semantics, check nothing" —
 * for a scalar (no shape, or an empty one) and for a shape that REPEATS an axis
 * name, which no permutation can resolve unambiguously.
 */
function declaredAxes(shape: string[] | undefined | null): string[] | undefined {
  if (!Array.isArray(shape) || shape.length === 0) return undefined
  if (!shape.every((s) => typeof s === 'string')) return undefined
  if (new Set(shape).size !== shape.length) return undefined
  return shape
}

/**
 * The whole-array variable an equation LHS defines: `D(var)` or a bare `var`.
 * `undefined` for an indexed / aggregate / expression LHS — a per-cell equation
 * whose RHS axes are the author's to spell, so it is left alone.
 */
function wholeArrayLhsTarget(lhs: Expression): string | undefined {
  if (typeof lhs === 'string') return lhs
  if (isExprNode(lhs) && lhs.op === 'D') {
    const head = lhs.args?.[0]
    if (typeof head === 'string') return head
  }
  return undefined
}

/**
 * Collect the declared array-shaped variables an expression references in BARE
 * (whole-array, element-wise) position, left-to-right.
 *
 * The descent enters only ELEMENTWISE nodes ({@link isElementwiseNode}) —
 * arithmetic, the elementary functions, the comparisons and conditionals, and a
 * `broadcast` whose `fn` names one of them — because those are the only nodes
 * for which "corresponding elements" is what the expression MEANS. Every other
 * op consumes its operands whole under its own contract: `aggregate` and
 * `makearray` name their own axes, `index` gathers, the §4.3.5 shape ops
 * restructure, and a geometry kernel legitimately returns a result of an
 * entirely unrelated shape.
 *
 * Seeing THROUGH a `broadcast` node is load-bearing, not incidental: the
 * `broadcast` spelling and the bare spelling of the same expression denote the
 * same thing (§4.3.4), so aligning one and not the other is the divergence the
 * rule exists to close.
 */
function collectBareArrayOperands(expr: Expression, axesOf: Map<string, string[]>): string[] {
  const operands: string[] = []
  const visit = (node: Expr): void => {
    if (typeof node === 'string') {
      if (axesOf.has(node)) operands.push(node)
      return
    }
    if (!isExprNode(node)) return
    if (!isElementwiseNode(node)) return
    forEachChild(node, visit)
  }
  visit(expr)
  return operands
}

/**
 * Report every operand of the array-level expression `expr` whose declared
 * index sets are not a SUBSET of the result's.
 *
 * At most one finding per operand: the first unalignable axis names the defect,
 * and listing the rest adds nothing.
 */
function checkOperandAxes(
  expr: Expression,
  target: string,
  axesOf: Map<string, string[]>,
  path: string,
  errors: StructuralError[],
): void {
  const targetAxes = axesOf.get(target)
  if (targetAxes === undefined) return
  for (const operand of collectBareArrayOperands(expr, axesOf)) {
    const operandAxes = axesOf.get(operand)
    if (operandAxes === undefined) continue
    const missing = operandAxes.find((axis) => !targetAxes.includes(axis))
    if (missing === undefined) continue
    errors.push({
      path,
      code: ERROR_CODES.ARRAY_SHAPE_MISMATCH,
      message:
        `Operand '${operand}' of the array-level expression for '${target}' is declared ` +
        `over index set '${missing}', which '${target}' is not shaped over`,
      details: {
        variable: target,
        operand,
        operand_shape: operandAxes,
        result_shape: targetAxes,
        missing_index_set: missing,
      },
    })
  }
}

/**
 * Reject an array-level expression whose operand carries an index set the
 * result does not (esm-spec §4.3.4 "Broadcast compatibility").
 *
 * Operands of an array-level expression align by index-set NAME, never by
 * position: an operand declared over a SUBSET of the result's index sets
 * replicates along the ones it is missing (a `[lat]` operand fills every `lon`
 * and `lev` position of a `[lon,lat,lev]` result), and axis ORDER is immaterial
 * (a `[lat,lon]` operand transposes). An operand carrying an index set the
 * result does NOT have has no axis to align to and no defensible value to
 * contribute.
 *
 * Both shapes are declared, so the check is STATIC — a hard error at validation
 * time, not a runtime size check and not a warning. The alternative, a
 * positional flatten, validates clean and then silently integrates garbage.
 *
 * The check is deliberately CONSERVATIVE, and the limits are the spec's:
 *
 *   - it fires only where BOTH the result and the operand carry declared,
 *     non-repeating index-set names ({@link declaredAxes});
 *   - it descends only through element-wise operators
 *     ({@link collectBareArrayOperands});
 *   - ANONYMOUS shapes — the results of `reshape` / `transpose` / `concat` /
 *     `makearray`, literal arrays, and any variable whose shape was never
 *     declared — name no axes, so they keep the positional convention of
 *     §4.3.4 regime 2 and are not checked here.
 *
 * Checked positions are the two where an operand is combined into a
 * declared-shape result: a whole-array equation LHS (`D(var)` or bare `var`),
 * and a declared array-shaped variable's defining `expression`.
 */
export function validateArrayBroadcastShapes(model: Model, modelPath: string): StructuralError[] {
  const errors: StructuralError[] = []
  const axesOf = new Map<string, string[]>()
  for (const [name, variable] of Object.entries(model.variables ?? {})) {
    const axes = declaredAxes(variable?.shape)
    if (axes !== undefined) axesOf.set(name, axes)
  }
  if (axesOf.size === 0) return errors

  for (const [index, equation] of (model.equations ?? []).entries()) {
    const target = wholeArrayLhsTarget(equation.lhs)
    if (target === undefined || equation.rhs === undefined) continue
    checkOperandAxes(equation.rhs, target, axesOf, `${modelPath}/equations/${index}/rhs`, errors)
  }

  for (const [name, variable] of Object.entries(model.variables ?? {})) {
    const expression = variable?.expression
    if (expression === undefined || expression === null) continue
    checkOperandAxes(expression, name, axesOf, `${modelPath}/variables/${name}/expression`, errors)
  }

  return errors
}
