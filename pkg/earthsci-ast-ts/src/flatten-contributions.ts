/**
 * Per-term provenance through flatten (esm-libraries-spec §4.7.5, "Per-term
 * provenance"; issue #539): the types, and the helpers every flatten pass uses
 * to edit a flattened equation through its contribution list.
 *
 * The list lives beside the expression tree, never on a node, so canonical
 * form, structural equality and interning are untouched by it.
 */

import type { Expression, ExpressionNode } from './types.js'
import { numericValue } from './numeric-literal.js'

/**
 * Who authored one contribution to a flattened equation. Exactly one of the two
 * keys is present: `component` is the full dotted path of the model, subsystem
 * or reaction system whose equation contained the expression
 * (`"Atmosphere.Chemistry"`); `coupling` is the 0-based index of the coupling
 * entry that wrote the expression itself, counted in the coupling sequence
 * AFTER `coupling_import` expansion (the sequence `metadata.couplingRules`
 * lists).
 */
export type TermOrigin = { component: string } | { coupling: number }

/**
 * One summand of a flattened equation's right-hand side, with its authors.
 *
 * `origins` is deduplicated in first-appearance order. It has more than one
 * entry only where a non-additive merge (a multiplicative `couple`, or an
 * `operator_compose` `translate` factor applied to a multi-contribution
 * equation) collapsed several contributions into one indivisible expression.
 * Flatten never produces an empty `origins`; an equation built outside flatten
 * may carry one, meaning "author unknown".
 */
export interface Contribution {
  expr: Expression
  origins: TermOrigin[]
}

/**
 * The equation shape the helpers below edit. `lifted` marks an equation the
 * pointwise lift wrapped in an `faq`: its contributions sum to the `faq` body,
 * not to the `faq` itself.
 */
interface ContributedEquation {
  lhs: Expression
  rhs: Expression
  sourceSystem: string
  contributions: Contribution[]
  lifted?: boolean
}

/** Sum two expressions, normalizing the trivial `0 + x` / `x + 0` cases. */
export function addExprs(left: Expression, right: Expression): Expression {
  if (numericValue(left) === 0) return right
  if (numericValue(right) === 0) return left
  return { op: '+', args: [left, right] }
}

/**
 * The right-hand side a contribution list stands for: the LEFT fold of the
 * contribution expressions under binary `+` (the provenance invariant). A
 * literal-zero operand is dropped from the tree; its contribution stays
 * recorded.
 */
export function foldContributions(contributions: readonly Contribution[]): Expression {
  let rhs = contributions[0].expr
  for (const c of contributions.slice(1)) rhs = addExprs(rhs, c.expr)
  return rhs
}

function originKey(o: TermOrigin): string {
  return 'component' in o ? `c:${o.component}` : `k:${o.coupling}`
}

/** Every origin of `contributions`, then `extra`, deduplicated in first-appearance order. */
export function unionOrigins(
  contributions: readonly Contribution[],
  ...extra: TermOrigin[]
): TermOrigin[] {
  const seen = new Set<string>()
  const out: TermOrigin[] = []
  for (const o of [...contributions.flatMap((c) => c.origins), ...extra]) {
    const key = originKey(o)
    if (seen.has(key)) continue
    seen.add(key)
    out.push(o)
  }
  return out
}

/** The body the contributions sum to: `rhs`, or the `faq` body of a lifted equation. */
export function equationBody(eq: ContributedEquation): Expression {
  if (eq.lifted === true) return (eq.rhs as ExpressionNode).expr as Expression
  return eq.rhs
}

/**
 * `eq`'s contribution list, or — when it is empty or missing, as on an
 * equation built outside flatten — the one contribution {@link equationBody}
 * with no origins, so every pass reads a list that folds to the equation's sum.
 */
export function contributionsOf(eq: ContributedEquation): Contribution[] {
  const list = eq.contributions as Contribution[] | undefined
  if (list === undefined || list.length === 0) return [{ expr: equationBody(eq), origins: [] }]
  return list
}

/**
 * `eq` with a new contribution list, its right-hand side REBUILT from that list
 * (left fold, re-wrapped in the lift's `faq` when `eq` is lifted). Every flatten
 * pass that rewrites an equation goes through here, so no term moves across a
 * contribution boundary.
 */
export function equationFrom<E extends ContributedEquation>(
  eq: E,
  contributions: Contribution[],
  lhs: Expression = eq.lhs,
): E {
  if (contributions.length === 0) contributions = contributionsOf(eq)
  const body = foldContributions(contributions)
  const rhs =
    eq.lifted === true ? ({ ...(eq.rhs as ExpressionNode), expr: body } as Expression) : body
  return { ...eq, lhs, rhs, contributions }
}

/** `eq` with `fn` applied inside every contribution, origins unchanged. */
export function mapContributions<E extends ContributedEquation>(
  eq: E,
  fn: (expr: Expression) => Expression,
  lhs: Expression = eq.lhs,
): E {
  return equationFrom(
    eq,
    contributionsOf(eq).map((c) => ({ expr: fn(c.expr), origins: c.origins })),
    lhs,
  )
}
