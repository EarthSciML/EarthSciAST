/**
 * Expression structural operations for the ESM format
 *
 * This module provides utilities for analyzing and manipulating mathematical
 * expressions in the ESM format AST.
 */

import type { Expression, ExpressionNode, Model } from './types.js'
import { isNumericLiteral, numericValue, type NumericLiteral } from './numeric-literal.js'
import { evaluateExpression } from './codegen.js'

/**
 * Type alias for better readability. Widened to accept `NumericLiteral`
 * leaves (per discretization RFC §5.4.1) alongside plain JS numbers.
 */
export type Expr = Expression | NumericLiteral

/**
 * Type guard for operator nodes in the expression AST.
 *
 * Narrows the `Expr` union (`number | string | ExpressionNode1 |
 * NumericLiteral`) to the fully-typed `ExpressionNode` (with `op: string`
 * and `args: Expression[]`). A `NumericLiteral` leaf has `kind`/`value`
 * but never `op`/`args`, so it is correctly excluded at runtime.
 */
export function isExprNode(e: unknown): e is ExpressionNode {
  return typeof e === 'object' && e !== null && 'op' in e && 'args' in e
}

/**
 * Extract all variable references from an expression.
 *
 * Routes through {@link forEachChild} — the ONE walker — so every
 * expression-bearing field is seen, not just `args`. Walking `args` alone made
 * whole sidecar subtrees invisible:
 *
 *   - `table_lookup{axes:{temp:'T_air'}}`      → `[]`      (missed `T_air`)
 *   - `aggregate{args:['A'], expr:{*:['A','w']}}` → `['A']`  (missed `w`)
 *   - `integral{lower:'a', upper:{+:['b',1]}}` → missed `a`, `b`
 *
 * `graph.ts` builds the dependency DAG from this, so every one of those misses
 * was a silently-absent edge.
 */
export function freeVariables(expr: Expr): Set<string> {
  const variables = new Set<string>()

  if (typeof expr === 'string') {
    variables.add(expr)
  } else if (typeof expr === 'number' || isNumericLiteral(expr)) {
    // Numeric literals contain no variables
    return variables
  } else if (isExprNode(expr)) {
    forEachChild(expr, (child) => {
      freeVariables(child).forEach((v) => variables.add(v))
    })
  }

  return variables
}

/**
 * Extract free parameters from an expression within a model context
 * @param expr Expression to analyze
 * @param model Model context to determine parameter vs state variables
 * @returns Set of parameter names referenced in the expression
 */
export function freeParameters(expr: Expr, model: Model): Set<string> {
  const allVars = freeVariables(expr)
  const parameters = new Set<string>()

  for (const varName of allVars) {
    const variable = model.variables[varName]
    if (variable && variable.type === 'parameter') {
      parameters.add(varName)
    }
  }

  return parameters
}

/**
 * Check if an expression contains a specific variable
 * @param expr Expression to search
 * @param varName Variable name to look for
 * @returns True if the variable appears in the expression
 */
export function contains(expr: Expr, varName: string): boolean {
  if (typeof expr === 'string') {
    return expr === varName
  } else if (typeof expr === 'number' || isNumericLiteral(expr)) {
    return false
  } else if (isExprNode(expr)) {
    // Every expression-bearing field, not just `args` — a reference hiding in
    // `expr` / `axes` / `lower` used to read as a false NEGATIVE, which is the
    // dangerous direction: a caller asking "is `y` still referenced?" would be
    // told no and delete `y`'s defining equation.
    let found = false
    forEachChild(expr, (child) => {
      if (!found && contains(child, varName)) found = true
    })
    return found
  }

  return false
}

/**
 * Simplify an expression using basic algebraic rules
 * @param expr Expression to simplify
 * @returns Simplified expression
 */
export function simplify(expr: Expr): Expr {
  if (typeof expr === 'number' || typeof expr === 'string') {
    return expr
  }

  if (isNumericLiteral(expr)) {
    // NumericLiteral leaves carry a kind tag that simplify is not
    // responsible for folding. Canonical int/float folding lives in
    // canonicalize() per RFC §5.4. Return unchanged.
    return expr
  }

  if (isExprNode(expr)) {
    // Simplify EVERY expression-bearing child through the one walker — `args`
    // AND the sidecars (`expr`, `lower`, `upper`, `filter`, `axes`, ...). The
    // old code mapped `args` only, so a subtree living in `aggregate.expr` or
    // `integral.lower` was returned unsimplified (the spread preserved it, so
    // nothing was lost — it was simply never visited).
    const pre = mapChildren(expr, (child) => simplify(child) as Expression)
    const simplifiedArgs = pre.args ?? []

    // Apply simplification rules based on operator
    switch (expr.op) {
      case '+': {
        // Remove zeros: x + 0 -> x
        const nonZeroTerms = simplifiedArgs.filter((arg) => arg !== 0)
        if (nonZeroTerms.length === 0) return 0
        if (nonZeroTerms.length === 1) return nonZeroTerms[0]

        // Separate constants and variables for partial constant folding
        const constants = nonZeroTerms.filter((arg) => typeof arg === 'number') as number[]
        const variables = nonZeroTerms.filter((arg) => typeof arg !== 'number')

        // If all terms are constants, return the sum
        if (variables.length === 0) {
          return constants.reduce((sum, val) => sum + val, 0)
        }

        // If there are constants to fold, combine them
        if (constants.length > 1) {
          const constantSum = constants.reduce((sum, val) => sum + val, 0)
          if (constantSum === 0) {
            // If constant sum is zero, just return variables
            return variables.length === 1
              ? variables[0]
              : { ...pre, args: variables as [Expression, ...Expression[]] }
          } else {
            // Include the folded constant with variables
            const finalTerms = [...variables, constantSum]
            return { ...pre, args: finalTerms as [Expression, ...Expression[]] }
          }
        }

        return { ...pre, args: nonZeroTerms as [Expression, ...Expression[]] }
      }

      case '*': {
        // Zero multiplication: x * 0 -> 0
        if (simplifiedArgs.some((arg) => arg === 0)) return 0

        // Remove ones: x * 1 -> x
        const nonOneFactors = simplifiedArgs.filter((arg) => arg !== 1)
        if (nonOneFactors.length === 0) return 1
        if (nonOneFactors.length === 1) return nonOneFactors[0]

        // Separate constants and variables for partial constant folding
        const constantFactors = nonOneFactors.filter((arg) => typeof arg === 'number') as number[]
        const variableFactors = nonOneFactors.filter((arg) => typeof arg !== 'number')

        // If all factors are constants, return the product
        if (variableFactors.length === 0) {
          return constantFactors.reduce((prod, val) => prod * val, 1)
        }

        // If there are constants to fold, combine them
        if (constantFactors.length > 1) {
          const constantProd = constantFactors.reduce((prod, val) => prod * val, 1)
          if (constantProd === 0) {
            return 0
          } else if (constantProd === 1) {
            // If constant product is one, just return variables
            return variableFactors.length === 1
              ? variableFactors[0]
              : { ...pre, args: variableFactors as [Expression, ...Expression[]] }
          } else {
            // Include the folded constant with variables
            const finalFactors = [...variableFactors, constantProd]
            return { ...pre, args: finalFactors as [Expression, ...Expression[]] }
          }
        }

        return { ...pre, args: nonOneFactors as [Expression, ...Expression[]] }
      }

      case '-':
        if (simplifiedArgs.length === 1) {
          // Unary minus: -(-x) -> x would need deeper analysis
          if (typeof simplifiedArgs[0] === 'number') {
            return -simplifiedArgs[0]
          }
        } else if (simplifiedArgs.length === 2) {
          // Binary subtraction: x - 0 -> x
          if (simplifiedArgs[1] === 0) return simplifiedArgs[0]

          // Constant folding
          if (typeof simplifiedArgs[0] === 'number' && typeof simplifiedArgs[1] === 'number') {
            return simplifiedArgs[0] - simplifiedArgs[1]
          }
        }

        return { ...pre, args: simplifiedArgs as [Expression, ...Expression[]] }

      case '/':
        if (simplifiedArgs.length === 2) {
          // x / 1 -> x
          if (simplifiedArgs[1] === 1) return simplifiedArgs[0]

          // Constant folding. A zero denominator is left unfolded — a pure
          // simplifier must not throw, and 0/0 vs x/0 semantics belong to
          // evaluation, not rewriting.
          if (
            typeof simplifiedArgs[0] === 'number' &&
            typeof simplifiedArgs[1] === 'number' &&
            simplifiedArgs[1] !== 0
          ) {
            return simplifiedArgs[0] / simplifiedArgs[1]
          }
        }

        return { ...pre, args: simplifiedArgs as [Expression, ...Expression[]] }

      case '^':
        if (simplifiedArgs.length === 2) {
          // x^0 -> 1
          if (simplifiedArgs[1] === 0) return 1

          // x^1 -> x
          if (simplifiedArgs[1] === 1) return simplifiedArgs[0]

          // 1^x -> 1 (sound for every finite x)
          if (simplifiedArgs[0] === 1) return 1

          // NOTE: 0^x is NOT folded to 0 — that identity only holds for
          // x > 0, which cannot be assumed for a symbolic exponent.

          // Constant folding
          if (typeof simplifiedArgs[0] === 'number' && typeof simplifiedArgs[1] === 'number') {
            return Math.pow(simplifiedArgs[0], simplifiedArgs[1])
          }
        }

        return { ...pre, args: simplifiedArgs as [Expression, ...Expression[]] }

      default:
        // For other operators, apply constant folding if all args are
        // numeric. Folding goes through the official codegen runner so
        // we share one dispatch table with the per-call evaluator.
        if (simplifiedArgs.every((arg) => typeof arg === 'number')) {
          try {
            const tempBindings = new Map<string, number>()
            return evaluateExpression(
              { ...pre, args: simplifiedArgs as [Expression, ...Expression[]] },
              tempBindings,
            )
          } catch {
            return { ...pre, args: simplifiedArgs as [Expression, ...Expression[]] }
          }
        }

        return { ...pre, args: simplifiedArgs as [Expression, ...Expression[]] }
    }
  }

  return expr
}

// ---------------------------------------------------------------------------
// Shared expression-tree walker
//
// `mapChildren` / `forEachChild` are the ONE place that enumerates which
// `ExpressionNode` fields carry child expressions. Every hand-rolled
// traversal that recurses over an expression should go through these instead
// of re-deriving the number/string/NumericLiteral/node leaf discrimination —
// hand-rolled walkers historically each covered a different subset and
// silently skipped children hidden in aggregate bodies (`expr`/`filter`/
// `key`), integral bounds (`lower`/`upper`), `makearray` `values`,
// `table_lookup` `axes`, and template `bindings`. Mirrors the Rust
// `ExpressionNode::map_children` / `for_each_child` (types.rs) and the Python
// `expr_walk` field set for cross-language parity.
// ---------------------------------------------------------------------------

/** `ExpressionNode` fields holding a positional array of child expressions. */
const ARRAY_CHILD_KEYS = ['args', 'values'] as const

/**
 * `ExpressionNode` fields holding a string-keyed MAP of child expressions
 * (`table_lookup.axes`, `apply_expression_template.bindings`).
 */
const MAP_CHILD_KEYS = ['axes', 'bindings'] as const

/** `ExpressionNode` fields holding a single child expression. */
const SCALAR_CHILD_KEYS = ['lower', 'upper', 'expr', 'filter', 'key'] as const

/**
 * The COMPLETE, canonical set of `ExpressionNode` fields that carry child
 * expressions, in deterministic visit order (`args`, the integral/aggregate
 * scalar slots, `values`, `axes`, `key`, `bindings`). This is the single
 * source of truth every traversal in the package trusts.
 *
 * Any field NOT listed here is structural metadata preserved verbatim by
 * `mapChildren`: `op`, `id`, `expect_cadence`, `wrt`, `dim`, `var`, `attrs`,
 * `output_idx`, `reduce`, `semiring`, `ranges`, `join`, `distinct`, `arg`,
 * `manifold`, `regions`, `shape`, `perm`, `axis`, `fn`, `name`, `value`,
 * `table`, `output`, and any field added later. In particular the `const`
 * node's `value` literal and `NumericLiteral` leaves are NOT expression
 * children — the walker never descends into them.
 *
 * Mirrors the Rust `ExpressionNode::for_each_child` / `map_children` and the
 * Python `expr_walk` field set.
 */
export const EXPRESSION_CHILD_KEYS = [
  'args',
  'lower',
  'upper',
  'expr',
  'filter',
  'values',
  'axes',
  'key',
  'bindings',
] as const

const ARRAY_CHILD_KEY_SET: ReadonlySet<string> = new Set(ARRAY_CHILD_KEYS)
const MAP_CHILD_KEY_SET: ReadonlySet<string> = new Set(MAP_CHILD_KEYS)
const SCALAR_CHILD_KEY_SET: ReadonlySet<string> = new Set(SCALAR_CHILD_KEYS)

/** Callback receiving each direct child, its slot key, and array/map index. */
type ChildMapper = (child: Expr, key: string, index?: number) => Expr
/** Read-only variant of {@link ChildMapper}. */
type ChildVisitor = (child: Expr, key: string, index?: number) => void

/**
 * Rebuild `node`, replacing every expression-bearing child with
 * `fn(child, key, index)` and PRESERVING every other field verbatim (`op`,
 * `dim`, `wrt`, `reduce`, `join`, `ranges`, `regions`, and any scalar
 * metadata). Field-preserving: any field not in {@link EXPRESSION_CHILD_KEYS}
 * — including ones this walker does not know about — is copied through by the
 * shallow spread.
 *
 * The traversal is ONE level deep: `fn` decides whether to recurse. Children
 * are reported as follows:
 *   - array fields (`args`, `values`): `fn(element, fieldName, arrayIndex)`;
 *   - scalar fields (`lower`, `upper`, `expr`, `filter`, `key`):
 *     `fn(child, fieldName)` with `index` omitted;
 *   - map fields (`axes`, `bindings`): entries are visited in sorted-key
 *     order as `fn(value, entryKey, enumerationIndex)` — `key` is the map's
 *     own axis/param name.
 *
 * `NumericLiteral` leaves are passed to `fn` as ordinary children but are
 * never destructured. Returns a NEW node; `node` is not mutated.
 */
export function mapChildren(node: ExpressionNode, fn: ChildMapper): ExpressionNode {
  // Shallow copy carries every structural / metadata field through untouched;
  // only the expression-bearing keys below are overwritten.
  const out: Record<string, unknown> = { ...node }

  // `args` is OPTIONAL at runtime: a `const` / `enum` node legitimately carries
  // only `value`, and `evalExprNode` explicitly tolerates that shape. Mapping it
  // unconditionally threw `TypeError: Cannot read properties of undefined` for
  // `substitute({op:'const', value:5}, {})`.
  if (node.args !== undefined) out.args = node.args.map((child, i) => fn(child, 'args', i))

  if (node.lower !== undefined) out.lower = fn(node.lower, 'lower')
  if (node.upper !== undefined) out.upper = fn(node.upper, 'upper')
  if (node.expr !== undefined) out.expr = fn(node.expr, 'expr')
  if (node.filter !== undefined) out.filter = fn(node.filter, 'filter')

  if (node.values !== undefined) {
    out.values = node.values.map((child, i) => fn(child, 'values', i))
  }

  if (node.axes !== undefined) out.axes = mapRecordChildren(node.axes, fn)

  if (node.key !== undefined) out.key = fn(node.key, 'key')

  if (node.bindings !== undefined) out.bindings = mapRecordChildren(node.bindings, fn)

  return out as unknown as ExpressionNode
}

/** Rebuild a string-keyed child map, visiting entries in sorted-key order. */
function mapRecordChildren(
  record: { [k: string]: Expression },
  fn: ChildMapper,
): { [k: string]: Expr } {
  const out: { [k: string]: Expr } = {}
  Object.keys(record)
    .sort()
    .forEach((k, i) => {
      out[k] = fn(record[k], k, i)
    })
  return out
}

/**
 * Read-only visitor over the same child set as {@link mapChildren}, in the
 * same deterministic order. `fn` receives `(child, key, index?)` with the
 * same key/index conventions documented on {@link mapChildren}.
 */
export function forEachChild(node: ExpressionNode, fn: ChildVisitor): void {
  // `args` is optional at runtime — see the note in `mapChildren`.
  if (node.args !== undefined) node.args.forEach((child, i) => fn(child, 'args', i))

  if (node.lower !== undefined) fn(node.lower, 'lower')
  if (node.upper !== undefined) fn(node.upper, 'upper')
  if (node.expr !== undefined) fn(node.expr, 'expr')
  if (node.filter !== undefined) fn(node.filter, 'filter')

  if (node.values !== undefined) node.values.forEach((child, i) => fn(child, 'values', i))

  if (node.axes !== undefined) forEachRecordChild(node.axes, fn)

  if (node.key !== undefined) fn(node.key, 'key')

  if (node.bindings !== undefined) forEachRecordChild(node.bindings, fn)
}

/** Visit a string-keyed child map's entries in sorted-key order. */
function forEachRecordChild(record: { [k: string]: Expression }, fn: ChildVisitor): void {
  Object.keys(record)
    .sort()
    .forEach((k, i) => fn(record[k], k, i))
}

/**
 * Field-AWARE structural equality for expressions. Two values are equal iff:
 *   - both are numeric leaves (plain `number` or tagged `NumericLiteral`)
 *     with the same value under `Object.is` — the int/float kind tag is
 *     ignored, so `1`, `intLit(1)` and `floatLit(1)` are all equal;
 *   - both are the same variable-reference string;
 *   - both are operator nodes with the same `op`, expression children
 *     (`EXPRESSION_CHILD_KEYS`) equal via this function, AND every other own
 *     field deep-equal structurally (so `{op:'const',value:1}` ≠
 *     `{op:'const',value:2}`, and `D` with `wrt:'t'` ≠ `wrt:'s'`).
 */
export function deepEqualExpr(a: Expr, b: Expr): boolean {
  // Numeric leaves: compare by value (Object.is ⇒ NaN===NaN, +0 !== -0),
  // ignoring the int/float kind tag.
  const na = numericValue(a)
  const nb = numericValue(b)
  if (na !== undefined || nb !== undefined) {
    return na !== undefined && nb !== undefined && Object.is(na, nb)
  }

  // Variable-reference leaves compare by name.
  if (typeof a === 'string' || typeof b === 'string') {
    return a === b
  }

  // Operator nodes: same op, same children, same scalar metadata.
  if (isExprNode(a) && isExprNode(b)) {
    if (a.op !== b.op) return false
    const keysA = ownDefinedKeys(a)
    const keysB = ownDefinedKeys(b)
    if (keysA.length !== keysB.length) return false
    const recB = b as unknown as Record<string, unknown>
    const recA = a as unknown as Record<string, unknown>
    for (const k of keysA) {
      if (!childOrScalarEqual(k, recA[k], recB[k])) return false
    }
    return true
  }

  return false
}

/** Own enumerable keys whose value is not `undefined` (⇒ treated as absent). */
function ownDefinedKeys(o: object): string[] {
  const rec = o as Record<string, unknown>
  return Object.keys(rec).filter((k) => rec[k] !== undefined)
}

/**
 * Compare one field of two nodes: expression-bearing fields recurse through
 * {@link deepEqualExpr}; everything else uses plain structural equality.
 */
function childOrScalarEqual(key: string, av: unknown, bv: unknown): boolean {
  if (ARRAY_CHILD_KEY_SET.has(key)) {
    if (!Array.isArray(av) || !Array.isArray(bv) || av.length !== bv.length) return false
    return av.every((x, i) => deepEqualExpr(x as Expr, bv[i] as Expr))
  }
  if (MAP_CHILD_KEY_SET.has(key)) {
    if (typeof av !== 'object' || av === null || typeof bv !== 'object' || bv === null) return false
    const am = av as Record<string, Expression>
    const bm = bv as Record<string, Expression>
    const km = Object.keys(am)
    if (km.length !== Object.keys(bm).length) return false
    return km.every(
      (k) => Object.prototype.hasOwnProperty.call(bm, k) && deepEqualExpr(am[k], bm[k]),
    )
  }
  if (SCALAR_CHILD_KEY_SET.has(key)) {
    return deepEqualExpr(av as Expr, bv as Expr)
  }
  return scalarDeepEqual(av, bv)
}

/** Plain structural (JSON-shaped) deep equality for non-expression fields. */
function scalarDeepEqual(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true
  if (typeof a !== 'object' || a === null || typeof b !== 'object' || b === null) {
    return false
  }
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false
    return a.every((x, i) => scalarDeepEqual(x, b[i]))
  }
  const ao = a as Record<string, unknown>
  const bo = b as Record<string, unknown>
  const ka = Object.keys(ao)
  if (ka.length !== Object.keys(bo).length) return false
  return ka.every(
    (k) => Object.prototype.hasOwnProperty.call(bo, k) && scalarDeepEqual(ao[k], bo[k]),
  )
}
