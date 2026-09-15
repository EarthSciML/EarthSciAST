/**
 * Right-hand-side structural time-derivative resolution (esm-spec §4.2), run by
 * {@link flatten} as esm-libraries-spec §4.7.5 step 3a. Mirrors the Rust
 * `flatten::resolve_rhs_time_derivatives`, the Python
 * `_resolve_rhs_time_derivatives` and the Julia `_resolve_rhs_time_derivatives!`.
 */

import type { Expression, ExpressionNode } from './types.js'
import type { FlattenedSystem } from './flatten.js'
import { numericValue } from './numeric-literal.js'
import { mapChildren } from './expression.js'
import { isRewriteTargetDerivative } from './op-registry.js'

function isNode(e: unknown): e is ExpressionNode {
  return typeof e === 'object' && e !== null && typeof (e as { op?: unknown }).op === 'string'
}

/**
 * The STRUCTURAL time derivative: `D` with `wrt: "t"` or no `wrt`, applied to a
 * single operand. A spatial `D` is a rewrite target (esm-spec §9.6.8), not this.
 */
function isStructuralTimeDerivative(e: unknown): e is ExpressionNode {
  return isNode(e) && e.op === 'D' && e.args?.length === 1 && !isRewriteTargetDerivative(e)
}

/** The bare name a structural `D` differentiates, or `undefined`. */
function derivativeTarget(e: Expression): string | undefined {
  if (!isStructuralTimeDerivative(e)) return undefined
  const arg = e.args[0]
  return typeof arg === 'string' ? arg : undefined
}

/** Does `e` carry a structural `D` anywhere? */
function hasTimeDerivative(e: Expression): boolean {
  if (!isNode(e)) return false
  if (isStructuralTimeDerivative(e)) return true
  let found = false
  mapChildren(e, (child) => {
    if (!found && hasTimeDerivative(child as Expression)) found = true
    return child
  })
  return found
}

interface DerivTables {
  /** `x` -> the right-hand side of its `D(x)/dt ~ …` equation. */
  tendency: Map<string, Expression>
  /** `y` -> the right-hand side of its `y ~ …` defining equation. */
  definition: Map<string, Expression>
  /**
   * Names that do not vary with `t` — the flattened system's parameters. A name
   * in none of the three tables is unresolvable rather than zero.
   */
  timeInvariant: Set<string>
}

/**
 * Rewrite every right-hand-side structural time derivative into the tendency
 * the flattened system already defines for it.
 *
 * A `D(x, t)` over a STATE is `x`'s own `D(x)/dt ~ f`, with any `D` inside `f`
 * resolved in turn; over an OBSERVED `y ~ g` it is the resolution of `g` (the
 * chain rule); over a parameter or a literal it is `0`; and `+`, unary and
 * binary `-`, `neg`, n-ary `*` and binary `/` distribute by the sum, product and
 * quotient rules. Every other shape, and every cyclic chain, resolves to nothing
 * and is left exactly as authored: §4.2 forbids inventing a value for it, in
 * particular `0`. Left-hand sides are never rewritten.
 *
 * It runs after the coupling rules and the pointwise lift, over the equation
 * list as it stands then, because it reads that list: before reaction lowering a
 * scoped `D(Chem.A, t)` names no tendency, before namespacing the tables are
 * keyed by the wrong names, and before `operator_compose` a merged state's
 * tendency is only its first contributing term.
 */
export function resolveRhsTimeDerivatives(flat: FlattenedSystem): void {
  const tables: DerivTables = {
    tendency: new Map(),
    definition: new Map(),
    timeInvariant: new Set(Object.keys(flat.parameters)),
  }
  for (const eq of flat.equations) {
    const target = derivativeTarget(eq.lhs)
    if (target !== undefined) {
      tables.tendency.set(target, eq.rhs)
    } else if (typeof eq.lhs === 'string') {
      // A bare-variable LHS is a DEFINING equation (esm-spec §6.3.1's observed /
      // algebraic form); its right-hand side is what the chain rule
      // differentiates.
      tables.definition.set(eq.lhs, eq.rhs)
    }
  }
  if (tables.tendency.size === 0 && tables.definition.size === 0) return
  for (const eq of flat.equations) {
    if (!hasTimeDerivative(eq.rhs)) continue
    // The quantity this equation DEFINES is not available to substitute into its
    // own right-hand side; seeding `active` with it is what makes
    // `D(x)/dt ~ k*D(x, t)` and `y ~ D(y, t)` terminate as unresolved rather than
    // expand forever.
    const own = derivativeTarget(eq.lhs) ?? (typeof eq.lhs === 'string' ? eq.lhs : undefined)
    const active = own === undefined ? [] : [own]
    eq.rhs = substitute(eq.rhs, tables, active)
  }
}

/** Rewrite every structural `D` inside `e`, leaving the ones `deriv` cannot answer as authored. */
function substitute(e: Expression, tables: DerivTables, active: string[]): Expression {
  if (!isNode(e)) return e
  if (isStructuralTimeDerivative(e)) {
    return deriv(e.args[0], tables, active) ?? e
  }
  return mapChildren(e, (child) => substitute(child as Expression, tables, active)) as Expression
}

/** d/dt of `e`, or `undefined` when this format does not define it. */
function deriv(e: Expression, tables: DerivTables, active: string[]): Expression | undefined {
  if (typeof e === 'string') {
    // A cycle: stop here and leave the node standing.
    if (active.includes(e)) return undefined
    const f = tables.tendency.get(e)
    if (f !== undefined) {
      active.push(e)
      try {
        return substitute(f, tables, active)
      } finally {
        active.pop()
      }
    }
    const g = tables.definition.get(e)
    if (g !== undefined) {
      // CHAIN RULE: an observed's total time derivative is its defining
      // right-hand side differentiated by this same rule, one level down.
      active.push(e)
      try {
        return deriv(g, tables, active)
      } finally {
        active.pop()
      }
    }
    return tables.timeInvariant.has(e) ? ZERO : undefined
  }
  if (numericValue(e) !== undefined) return ZERO
  if (!isNode(e)) return undefined

  const d = (a: Expression): Expression | undefined => deriv(a, tables, active)
  const args = (e.args ?? []) as Expression[]
  switch (e.op) {
    case '+': {
      const terms: Expression[] = []
      for (const a of args) {
        const da = d(a)
        if (da === undefined) return undefined
        terms.push(da)
      }
      return sum(terms)
    }
    case '-':
    case 'neg': {
      if (args.length === 1) {
        const da = d(args[0])
        return da === undefined ? undefined : negate(da)
      }
      if (e.op === '-' && args.length === 2) {
        const da = d(args[0])
        if (da === undefined) return undefined
        const db = d(args[1])
        return db === undefined ? undefined : difference(da, db)
      }
      return undefined
    }
    case '*': {
      // Product rule over an n-ary `*`: one term per factor, that factor
      // differentiated and the others left alone.
      const terms: Expression[] = []
      for (let i = 0; i < args.length; i++) {
        const da = d(args[i])
        if (da === undefined) return undefined
        if (isZero(da)) continue
        terms.push(product([da, ...args.filter((_, j) => j !== i)]))
      }
      return sum(terms)
    }
    case '/': {
      if (args.length !== 2) return undefined
      const [u, v] = args
      const du = d(u)
      if (du === undefined) return undefined
      const dv = d(v)
      if (dv === undefined) return undefined
      // `v` constant in t: (u/v)' = u'/v, which keeps the common `D(x, t)/c`
      // shape small.
      if (isZero(dv)) return quotient(du, v)
      const num = difference(product([du, v]), product([u, dv]))
      return quotient(num, product([v, v]))
    }
    default:
      return undefined
  }
}

// ---------------------------------------------------------------------------
// Folding constructors. Folding is not cosmetic: a parameter and a literal both
// differentiate to `0`, so an unfolded product rule would emit `0*x` terms and
// `D(k, t)` would be a sum of zeros rather than the literal `0`.
// ---------------------------------------------------------------------------

const ZERO: Expression = 0

const isZero = (e: Expression): boolean => numericValue(e) === 0
const isOne = (e: Expression): boolean => numericValue(e) === 1

function sum(terms: Expression[]): Expression {
  const kept = terms.filter((t) => !isZero(t))
  if (kept.length === 0) return ZERO
  if (kept.length === 1) return kept[0]
  return { op: '+', args: kept }
}

function negate(a: Expression): Expression {
  if (isZero(a)) return ZERO
  const v = numericValue(a)
  if (v !== undefined) return -v
  // Unary `-`, not `neg`: both spell negation, and this is the spelling the
  // other bindings emit.
  return { op: '-', args: [a] }
}

function difference(a: Expression, b: Expression): Expression {
  if (isZero(b)) return a
  if (isZero(a)) return negate(b)
  return { op: '-', args: [a, b] }
}

function product(factors: Expression[]): Expression {
  if (factors.some(isZero)) return ZERO
  const kept = factors.filter((f) => !isOne(f))
  if (kept.length === 0) return 1
  if (kept.length === 1) return kept[0]
  return { op: '*', args: kept }
}

function quotient(a: Expression, b: Expression): Expression {
  if (isZero(a)) return ZERO
  return { op: '/', args: [a, b] }
}
