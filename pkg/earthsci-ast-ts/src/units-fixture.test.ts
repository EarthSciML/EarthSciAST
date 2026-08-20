/**
 * Units fixtures consumption runner (gt-dt0o).
 *
 * The three `units_*.esm` files in `tests/valid/` carry inline `tests`
 * blocks (id / parameter_overrides / initial_conditions / time_span /
 * assertions) added in gt-p3v. Schema parse coverage is asserted in
 * `units.test.ts`'s Cross-binding units fixtures suite. This file closes
 * the schema-vs-execution gap: every assertion's target (all of which
 * are observed variables at t = 0) is actually evaluated under the
 * test's bindings and compared against the expected value within the
 * resolved tolerance (assertion → test → model, falling back to
 * rtol = 1e-6).
 *
 * Corrupting an expected value in any fixture — or reverting the
 * `pressure_drop` fix from gt-p3v — must cause this suite to fail.
 */

import { describe, it, expect } from 'vitest'
import { evaluateExpression } from './codegen.js'
import { observedDefinitions, odeStates } from './classification.js'
import { readFixture } from './test-helpers.js'
import type { EsmFile, Expr, Model, ModelVariable, Test, Assertion } from './types.js'

const FIXTURES = [
  'units_conversions.esm',
  'units_dimensional_analysis.esm',
  'units_propagation.esm',
]

type AnyTol = { abs?: number; rel?: number } | undefined

function resolveTol(
  modelTol: AnyTol,
  testTol: AnyTol,
  assertionTol: AnyTol,
): { rel: number; abs: number } {
  for (const cand of [assertionTol, testTol, modelTol]) {
    if (cand === undefined || cand === null) continue
    return { rel: cand.rel ?? 0, abs: cand.abs ?? 0 }
  }
  return { rel: 1e-6, abs: 0 }
}

/**
 * Resolve every observed variable in `model` into `bindings` by iterated
 * substitution. The codegen runner throws on the first unbound
 * variable; we swallow that as "dependencies not yet resolved" and
 * retry. Cycle-free fixtures converge in at most one pass per observed
 * variable.
 *
 * From esm 1.0.0 an observed variable is not a declared type and carries no
 * `expression`: it is an unknown whose defining equation has a bare-variable
 * LHS, so the set to resolve and the expression to evaluate both come from
 * `observedDefinitions` rather than from a `variables[v].type`/`.expression`
 * pair (esm-spec §6.3.1).
 */
function resolveObserved(model: Model, bindings: Map<string, number>): void {
  const definitions = [...observedDefinitions(model)]
  for (let pass = 0; pass <= definitions.length; pass++) {
    let progress = false
    for (const [vname, expression] of definitions) {
      if (bindings.has(vname)) continue
      try {
        bindings.set(vname, evaluateExpression(expression as Expr, bindings))
        progress = true
      } catch (err) {
        if (err instanceof Error && err.message.startsWith('Unbound variable')) {
          continue
        }
        throw err
      }
    }
    if (!progress) return
  }
}

function assertWithTolerance(
  label: string,
  actual: number,
  expected: number,
  rel: number,
  abs: number,
): void {
  if (abs > 0 && expected === 0) {
    expect(Math.abs(actual - expected), label).toBeLessThanOrEqual(abs)
    return
  }
  if (rel > 0) {
    const bound = Math.max(rel * Math.max(Math.abs(expected), 1e-300), abs)
    expect(Math.abs(actual - expected), label).toBeLessThanOrEqual(bound)
    return
  }
  expect(Math.abs(actual - expected), label).toBeLessThanOrEqual(abs)
}

/**
 * Seed the bindings with every value that is GIVEN rather than computed:
 * parameters, and the unknowns that are ODE states (their `default` is the
 * initial condition at t = 0). Observed unknowns are deliberately excluded so
 * `resolveObserved` computes them from their defining equation — under 1.0.0
 * both categories declare `type: 'unknown'`, so the split that used to be
 * `'parameter' | 'state'` vs `'observed'` is now the derived `odeStates` set.
 */
function buildBindings(model: Model, t: Test): Map<string, number> {
  const bindings = new Map<string, number>()
  const states = new Set(odeStates(model))
  for (const [vname, vraw] of Object.entries(model.variables ?? {})) {
    const variable = vraw as ModelVariable
    if (
      (variable.type === 'parameter' || states.has(vname)) &&
      typeof variable.default === 'number'
    ) {
      bindings.set(vname, variable.default)
    }
  }
  for (const [k, v] of Object.entries(t.initial_conditions ?? {})) {
    bindings.set(k, v as number)
  }
  for (const [k, v] of Object.entries(t.parameter_overrides ?? {})) {
    bindings.set(k, v as number)
  }
  return bindings
}

describe('Units fixtures inline tests execution (gt-dt0o)', () => {
  for (const fname of FIXTURES) {
    describe(fname, () => {
      const raw = readFixture('valid', fname)
      const file = JSON.parse(raw) as EsmFile
      const models = file.models ?? {}
      const modelEntries = Object.entries(models)

      it('has at least one inline test across its models', () => {
        const count = modelEntries.reduce(
          (sum, [, m]) => sum + ((m as Model).tests?.length ?? 0),
          0,
        )
        expect(count).toBeGreaterThan(0)
      })

      for (const [mname, m] of modelEntries) {
        const model = m as Model
        for (const t of model.tests ?? []) {
          it(`${mname}/${t.id}`, () => {
            const bindings = buildBindings(model, t)
            resolveObserved(model, bindings)
            for (const a of t.assertions as Assertion[]) {
              const { rel, abs } = resolveTol(
                model.tolerance as AnyTol,
                t.tolerance as AnyTol,
                a.tolerance as AnyTol,
              )
              expect(
                bindings.has(a.variable),
                `${fname}::${mname}::${t.id}: ${a.variable} not resolved`,
              ).toBe(true)
              assertWithTolerance(
                `${fname}::${mname}::${t.id}::${a.variable}`,
                bindings.get(a.variable)!,
                a.expected!,
                rel,
                abs,
              )
            }
          })
        }
      }
    })
  }
})
