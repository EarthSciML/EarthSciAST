/**
 * esm 2.5.0 (esm-spec §11.4.3, "What `validate` reports"): the one balance
 * finding a document shows by itself, per model. The model's initialization
 * equations that are not explicit initial conditions, counted in scalar
 * equations (one per cell of a side that is a `faq` with output indices, else
 * one), against the cells of the starting values they mention. A starting
 * value counts all its cells unless an explicit initial condition of the same
 * model sets every one of them, so an explicit `faq` over some of its cells
 * removes none. `validate` cannot tell observeds, so `ic(y) ~ 4` counts as
 * explicit here. No finding when a needed extent cannot be read (an index set
 * without a size, a scoped name, `ic(D(x))`). More equations than cells is
 * `ic_system_unbalanced`; everything else in the balance is checked at build.
 * Mirrors the Julia, Rust, Python and Go checks.
 */

import { ERROR_CODES } from '../errors.js'
import {
  explicitInitialCondition,
  faqCells,
  icNodes,
  isInitializationEquation,
  scalarEquationCount,
  variableCells,
} from '../initialization.js'
import type { StructuralError } from './types.js'

type Obj = Record<string, unknown>
const isObj = (v: unknown): v is Obj => v !== null && typeof v === 'object' && !Array.isArray(v)

export function validateInitializationOverdetermination(
  model: unknown,
  modelPath: string,
  esmFile: unknown,
): StructuralError[] {
  if (!isObj(model) || !Array.isArray(model.equations)) return []
  const indexSets = isObj(esmFile) && isObj(esmFile.index_sets) ? esmFile.index_sets : {}
  const vars = isObj(model.variables) ? model.variables : {}
  const cellsOf = (name: string): number | null => {
    const v = Object.prototype.hasOwnProperty.call(vars, name) ? vars[name] : undefined
    return isObj(v) ? variableCells(v.shape, indexSets) : null
  }

  // The starting values every cell of which an explicit initial condition sets.
  const covered = new Set<string>()
  const system: Obj[] = []
  for (const eq of model.equations) {
    if (!isObj(eq) || !isInitializationEquation(eq)) continue
    const explicit = explicitInitialCondition(eq.lhs, eq.rhs)
    if (explicit === null) {
      system.push(eq)
      continue
    }
    const partial = faqCells(explicit.value, indexSets)
    if (partial === undefined || (partial !== null && partial === cellsOf(explicit.target))) {
      covered.add(explicit.target)
    }
  }
  if (system.length === 0) return []

  let equations = 0
  const mentioned = new Set<string>()
  for (const eq of system) {
    const n = scalarEquationCount(eq, indexSets)
    if (n === null) return []
    equations += n
    for (const node of [...icNodes(eq.lhs), ...icNodes(eq.rhs)]) {
      const a = Array.isArray(node.args) ? node.args[0] : undefined
      // `ic(D(x))` reads whatever x's tendency reads: unbounded here.
      if (typeof a !== 'string') return []
      if (!covered.has(a)) mentioned.add(a)
    }
  }
  let cells = 0
  for (const name of mentioned) {
    // A scoped or undeclared name, or an index set without a size.
    const n = cellsOf(name)
    if (n === null) return []
    cells += n
  }
  if (equations <= cells) return []
  return [
    {
      path: `${modelPath}/equations`,
      code: ERROR_CODES.IC_SYSTEM_UNBALANCED,
      message:
        `the initialization system is over-determined: its ${equations} scalar equation(s) ` +
        `that are not explicit initial conditions mention ${cells} starting value cell(s) ` +
        'that no explicit initial condition sets (esm-spec §11.4.3)',
      details: {
        direction: 'over-determined',
        equations,
        unknowns: [...mentioned].sort(),
      },
    },
  ]
}
