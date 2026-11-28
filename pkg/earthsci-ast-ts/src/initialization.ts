/**
 * esm 2.5.0: the one classification of initialization equations (esm-spec
 * §11.4, §11.4.3) that every caller shares: the loader's migration and `ic`
 * check, `validate`'s main balance and over-determination count, and
 * `flatten`'s split into `field_ics` and `initialization_equations`.
 *
 * - An **initialization equation** mentions `ic` anywhere, on either side.
 * - An **explicit initial condition** has one side exactly `ic(u)`, `u` a
 *   name, while the other side mentions no `ic`; the mirrored `e ~ ic(u)` is
 *   one too.
 *
 * Also the counts `validate` takes (esm-spec §11.4.3, "What `validate`
 * reports"): an equation's scalar size and a variable's cells.
 *
 * Imports nothing that reaches the loader.
 */

import { forEachChild } from './expression.js'
import { numericValue } from './numeric-literal.js'
import type { Expression, ExpressionNode } from './types.js'

type Obj = Record<string, unknown>

const isObj = (v: unknown): v is Obj => v !== null && typeof v === 'object' && !Array.isArray(v)

/** Whether `e` is an operator node. */
export function isOpNode(e: unknown): e is ExpressionNode {
  return isObj(e) && typeof e.op === 'string'
}

/** The `ic` nodes of an expression, in walk order, through every expression-valued field. */
export function icNodes(e: unknown, out: ExpressionNode[] = []): ExpressionNode[] {
  if (!isOpNode(e)) return out
  if (e.op === 'ic') out.push(e)
  forEachChild(e, (child) => {
    icNodes(child, out)
  })
  return out
}

/** Whether `e` mentions `ic` anywhere. */
export function mentionsIc(e: unknown): boolean {
  return icNodes(e).length > 0
}

/** Whether an equation is an initialization equation: it mentions `ic` on either side. */
export function isInitializationEquation(eq: { lhs?: unknown; rhs?: unknown }): boolean {
  return mentionsIc(eq.lhs) || mentionsIc(eq.rhs)
}

/** `u` when `side` is exactly `ic(u)`, `u` a name; else null. */
export function icTarget(side: unknown): string | null {
  if (!isOpNode(side) || side.op !== 'ic') return null
  const args = side.args
  if (!Array.isArray(args) || args.length !== 1) return null
  return typeof args[0] === 'string' ? args[0] : null
}

/** An explicit initial condition: its target and the side that gives its value. */
export interface ExplicitInitialCondition {
  target: string
  value: Expression
}

/**
 * The explicit initial condition `ic(u) ~ e` or `e ~ ic(u)`, `e` mentioning no
 * `ic`; null for any other equation.
 */
export function explicitInitialCondition(
  lhs: unknown,
  rhs: unknown,
): ExplicitInitialCondition | null {
  const l = icTarget(lhs)
  if (l !== null && !mentionsIc(rhs)) return { target: l, value: rhs as Expression }
  const r = icTarget(rhs)
  if (r !== null && !mentionsIc(lhs)) return { target: r, value: lhs as Expression }
  return null
}

/** The size of a declared index set, or null when it has none (or is not declared). */
function indexSetSize(name: unknown, indexSets: Obj): number | null {
  const set = typeof name === 'string' ? indexSets[name] : undefined
  if (!isObj(set)) return null
  const size = numericValue(set.size)
  if (size !== undefined) return size
  return Array.isArray(set.members) ? set.members.length : null
}

/** The length of one `faq` range: `{from: set}` or a literal `[lo, hi]`; null when unreadable. */
function rangeLength(range: unknown, indexSets: Obj): number | null {
  if (isObj(range) && 'from' in range) return indexSetSize(range.from, indexSets)
  if (Array.isArray(range) && range.length === 2) {
    const lo = numericValue(range[0])
    const hi = numericValue(range[1])
    if (lo !== undefined && hi !== undefined && Number.isInteger(lo) && Number.isInteger(hi)) {
      return Math.max(0, hi - lo + 1)
    }
  }
  return null
}

/**
 * The cells of `side` when it is a `faq` with output indices: the product of
 * its output ranges' lengths. `undefined` when `side` is no such `faq`; null
 * when a range cannot be read.
 */
export function faqCells(side: unknown, indexSets: Obj): number | null | undefined {
  if (!isOpNode(side) || side.op !== 'faq') return undefined
  const out = (side as Obj).output_idx
  if (!Array.isArray(out) || out.length === 0) return undefined
  const ranges = (side as Obj).ranges
  let n = 1
  for (const idx of out) {
    if (typeof idx !== 'string' || !isObj(ranges)) return null
    const len = rangeLength(ranges[idx], indexSets)
    if (len === null) return null
    n *= len
  }
  return n
}

/**
 * The scalar equations an equation counts for (esm-spec §11.4.3): one per
 * cell of a side that is a `faq` with output indices, else one. Null when that
 * `faq`'s ranges cannot be read.
 */
export function scalarEquationCount(
  eq: { lhs?: unknown; rhs?: unknown },
  indexSets: Obj,
): number | null {
  const l = faqCells(eq.lhs, indexSets)
  if (l !== undefined) return l
  const r = faqCells(eq.rhs, indexSets)
  return r === undefined ? 1 : r
}

/** The cells of a variable with declared `shape`; null when an index set has no size. */
export function variableCells(shape: unknown, indexSets: Obj): number | null {
  if (!Array.isArray(shape)) return 1
  let n = 1
  for (const name of shape) {
    const size = indexSetSize(name, indexSets)
    if (size === null) return null
    n *= size
  }
  return n
}
