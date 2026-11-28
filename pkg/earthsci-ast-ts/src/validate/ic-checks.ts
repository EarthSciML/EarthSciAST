/**
 * esm 2.5.0 (esm-spec §11.4.3, "What `validate` reports"): the one balance
 * finding a document shows by itself. The initialization equations of a model
 * that are not explicit initial conditions, at least one scalar equation each,
 * against the distinct starting values they mention that no explicit initial
 * condition sets, each counted by its declared element count. More equations
 * than starting values is `ic_system_unbalanced`. Everything else in the
 * balance depends on supplied values and classification and is checked at
 * build. Mirrors the Julia, Rust, Python and Go checks.
 */

import { ERROR_CODES } from '../errors.js'
import type { StructuralError } from './types.js'

type Obj = Record<string, unknown>
const isObj = (v: unknown): v is Obj => v !== null && typeof v === 'object' && !Array.isArray(v)

/** The `ic` nodes of an expression, in walk order. */
function icNodes(e: unknown, out: Obj[] = []): Obj[] {
  if (Array.isArray(e)) {
    for (const x of e) icNodes(x, out)
  } else if (isObj(e)) {
    if (e.op === 'ic') out.push(e)
    for (const [k, v] of Object.entries(e)) {
      if (k === 'args' || k === 'expr' || k === 'filter' || k === 'values') icNodes(v, out)
    }
  }
  return out
}

/** `u` when `side` is exactly `ic(u)`, `u` a name. */
function icTarget(side: unknown): string | null {
  if (!isObj(side) || side.op !== 'ic' || !Array.isArray(side.args) || side.args.length !== 1) {
    return null
  }
  const a = side.args[0]
  return typeof a === 'string' ? a : null
}

/** The explicit initial condition's target, or null: `ic(u) ~ e` or `e ~ ic(u)`, `e` free of `ic`. */
function explicitTarget(lhs: unknown, rhs: unknown): string | null {
  const l = icTarget(lhs)
  if (l !== null && icNodes(rhs).length === 0) return l
  const r = icTarget(rhs)
  if (r !== null && icNodes(lhs).length === 0) return r
  return null
}

/** The element count of a declared shape, or Infinity when a set does not resolve. */
function elementCount(shape: unknown, indexSets: Obj): number {
  if (!Array.isArray(shape) || shape.length === 0) return 1
  let n = 1
  for (const name of shape) {
    const set = typeof name === 'string' ? indexSets[name] : undefined
    if (!isObj(set)) return Infinity
    if (typeof set.size === 'number') n *= set.size
    else if (Array.isArray(set.members)) n *= set.members.length
    else return Infinity
  }
  return n
}

export function validateInitializationOverdetermination(
  model: unknown,
  modelPath: string,
  esmFile: unknown,
): StructuralError[] {
  if (!isObj(model) || !Array.isArray(model.equations)) return []
  const indexSets = isObj(esmFile) && isObj(esmFile.index_sets) ? esmFile.index_sets : {}
  const vars = isObj(model.variables) ? model.variables : {}
  const explicit = new Set<string>()
  const system: Obj[] = []
  for (const eq of model.equations) {
    if (!isObj(eq)) continue
    if (icNodes(eq.lhs).length === 0 && icNodes(eq.rhs).length === 0) continue
    const t = explicitTarget(eq.lhs, eq.rhs)
    if (t !== null) explicit.add(t)
    else system.push(eq)
  }
  if (system.length === 0) return []
  const mentioned = new Set<string>()
  for (const eq of system) {
    for (const node of [...icNodes(eq.lhs), ...icNodes(eq.rhs)]) {
      const a = Array.isArray(node.args) ? node.args[0] : undefined
      // `ic(D(x))` reads whatever x's tendency reads: unbounded here.
      if (typeof a !== 'string') return []
      if (!explicit.has(a)) mentioned.add(a)
    }
  }
  let starting = 0
  for (const name of mentioned) {
    const v = vars[name]
    // A scoped or undeclared name: its size is not known here.
    if (!isObj(v)) return []
    starting += elementCount(v.shape, indexSets)
  }
  if (system.length <= starting) return []
  return [
    {
      path: `${modelPath}/equations`,
      code: ERROR_CODES.IC_SYSTEM_UNBALANCED,
      message:
        `the initialization system is over-determined: ${system.length} initialization ` +
        `equation(s) that are not explicit initial conditions mention ${starting} starting ` +
        'value(s) that no explicit initial condition sets (esm-spec §11.4.3)',
      details: {
        direction: 'over-determined',
        equations: system.length,
        unknowns: [...mentioned].sort(),
      },
    },
  ]
}
