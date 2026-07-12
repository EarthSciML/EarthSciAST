/**
 * Cross-binding conformance for the v0.3.0 closed function registry
 * (esm-spec §9.2). For every fixture under
 * `tests/closed_functions/<module>/<fn>/`, this suite:
 *
 *   1. Parses the canonical .esm file (exercises the `fn` op parser /
 *      schema acceptance).
 *   2. Walks the scenarios in `expected.json`, evaluates the equation
 *      RHS with the parameter bound to the scenario input, and compares
 *      the result against the spec-pinned expected scalar at the
 *      fixture's tolerance.
 *   3. For `interp.searchsorted`, also exercises `error_scenarios` and
 *      asserts the diagnostic code matches.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync, readdirSync, statSync } from 'fs'
import { join } from 'path'
import { load } from './parse.js'
import { evaluateExpression } from './codegen.js'
import {
  ClosedFunctionError,
  validateSearchsortedTable,
  searchsortedFirst,
  interpLinear,
  interpBilinear,
} from './closed-functions.js'
import { fixturesDir } from './test-helpers.js'

const fixturesRoot = fixturesDir('closed_functions')

interface Scenario {
  name: string
  description?: string
  inputs: Array<number | string | unknown[]>
  // `expected` may be the JSON string "NaN" for the NaN-propagation
  // scenarios; decodeInput() converts it to Number.NaN before comparison.
  expected: number | string
}

interface ErrorScenario {
  name: string
  description?: string
  inputs: Array<number | string | unknown[]>
  expected_error_code: string
}

interface ExpectedFile {
  function: string
  tolerance: { abs: number; rel: number }
  scenarios: Scenario[]
  error_scenarios?: ErrorScenario[]
}

// `expected.json` encodes NaN as the JSON string "NaN" (since JSON has no
// NaN). Convert to a real number for evaluation.
function decodeInput(v: unknown): unknown {
  if (v === 'NaN') return Number.NaN
  if (Array.isArray(v)) return v.map(decodeInput)
  return v
}

function listFunctionFixtures(): Array<{ module: string; fn: string; dir: string }> {
  const out: Array<{ module: string; fn: string; dir: string }> = []
  let modules: string[]
  try {
    modules = readdirSync(fixturesRoot)
  } catch {
    return out
  }
  for (const mod of modules) {
    const modDir = join(fixturesRoot, mod)
    if (!statSync(modDir).isDirectory()) continue
    let fns: string[]
    try {
      fns = readdirSync(modDir)
    } catch {
      continue
    }
    for (const fn of fns) {
      const dir = join(modDir, fn)
      try {
        if (statSync(dir).isDirectory()) out.push({ module: mod, fn, dir })
      } catch {
        // skip
      }
    }
  }
  return out
}

describe('Closed function registry — cross-binding conformance', () => {
  const fixtures = listFunctionFixtures()

  if (fixtures.length === 0) {
    it('finds at least one fixture under tests/closed_functions/', () => {
      throw new Error(`no fixtures discovered at ${fixturesRoot}`)
    })
    return
  }

  // Functions whose dispatch this harness directly understands. New
  // closed-function fixtures landed by spec PRs (e.g. esm-94w's
  // interp.linear / interp.bilinear) appear under tests/closed_functions/
  // before the per-language [Impl] beads add binding code; skip those
  // fixtures here until the implementation bead extends this harness with
  // a dispatch arm.
  const harnessKnownFunctions = new Set<string>([
    'datetime.year',
    'datetime.month',
    'datetime.day',
    'datetime.hour',
    'datetime.minute',
    'datetime.second',
    'datetime.day_of_year',
    'datetime.julian_day',
    'datetime.is_leap_year',
    'interp.searchsorted',
    'interp.linear',
    'interp.bilinear',
  ])

  for (const { module: mod, fn, dir } of fixtures) {
    describe(`${mod}.${fn}`, () => {
      const canonicalPath = join(dir, 'canonical.esm')
      const expectedPath = join(dir, 'expected.json')

      const expected: ExpectedFile = JSON.parse(readFileSync(expectedPath, 'utf-8'))
      const fileText = readFileSync(canonicalPath, 'utf-8')

      if (!harnessKnownFunctions.has(expected.function)) {
        it.skip(`fixture function ${expected.function} not yet implemented in this binding`, () => {})
        return
      }

      it('parses the canonical .esm without error', () => {
        const parsed = load(fileText)
        expect(parsed).toBeDefined()
        expect((parsed as any).esm).toBeDefined()
      })

      // Pull the RHS template from the parsed file so we exercise the
      // fn-op evaluator path end-to-end.
      const parsed = load(fileText) as any
      const probe = parsed.models?.Probe ?? Object.values(parsed.models)[0]
      const rhsTemplate = probe.equations[0].rhs

      // For every scenario, bind the parameter to the input value and
      // evaluate. The probe model conventions match the Julia reference:
      //   - datetime.* uses param `t_utc`, single-input scenarios.
      //   - interp.searchsorted uses param `x` (xs is inline const).
      const paramName = `${mod}` === 'datetime' ? 't_utc' : 'x'

      // Spec tolerance per esm-spec §9.2 (matches Julia ref): pass
      // if either |actual−expected| ≤ abs OR ≤ rel·max(1, |expected|).
      // NaN expected matches NaN actual (both must be NaN).
      function withinTolerance(
        got: number,
        exp: number,
        tol: { abs: number; rel: number },
      ): boolean {
        if (Number.isNaN(exp)) return Number.isNaN(got)
        const diff = Math.abs(got - exp)
        return diff <= tol.abs || diff <= tol.rel * Math.max(1, Math.abs(exp))
      }

      for (const scenario of expected.scenarios) {
        it(`scenario ${scenario.name}`, () => {
          const decoded = scenario.inputs.map(decodeInput)
          const tol = expected.tolerance
          const exp = decodeInput(scenario.expected) as number
          if (mod === 'datetime') {
            const bindings = new Map<string, number>()
            bindings.set(paramName, decoded[0] as number)
            const got = evaluateExpression(rhsTemplate, bindings)
            expect(
              withinTolerance(got, exp, tol),
              `${scenario.name}: got ${got}, expected ${exp} (tol abs=${tol.abs}, rel=${tol.rel})`,
            ).toBe(true)
          } else if (expected.function === 'interp.searchsorted') {
            // Drive the function directly with [x, xs] from the scenario
            // (mirrors the Julia ref).
            const x = decoded[0] as number
            const xs = decoded[1] as number[]
            const got = searchsortedFirst(x, xs)
            expect(got).toBe(scenario.expected)
          } else if (expected.function === 'interp.linear') {
            const table = decoded[0] as number[]
            const axis = decoded[1] as number[]
            const x = decoded[2] as number
            const got = interpLinear(table, axis, x)
            expect(
              withinTolerance(got, exp, tol),
              `${scenario.name}: got ${got}, expected ${exp} (tol abs=${tol.abs}, rel=${tol.rel})`,
            ).toBe(true)
          } else if (expected.function === 'interp.bilinear') {
            const table = decoded[0] as number[][]
            const axisX = decoded[1] as number[]
            const axisY = decoded[2] as number[]
            const x = decoded[3] as number
            const y = decoded[4] as number
            const got = interpBilinear(table, axisX, axisY, x, y)
            expect(
              withinTolerance(got, exp, tol),
              `${scenario.name}: got ${got}, expected ${exp} (tol abs=${tol.abs}, rel=${tol.rel})`,
            ).toBe(true)
          } else {
            throw new Error(`unhandled fixture function ${expected.function}`)
          }
        })
      }

      // Error scenarios validate spec-pinned diagnostic codes.
      for (const errorScenario of expected.error_scenarios ?? []) {
        it(`error scenario ${errorScenario.name} → ${errorScenario.expected_error_code}`, () => {
          const decoded = errorScenario.inputs.map(decodeInput)
          try {
            if (expected.function === 'interp.searchsorted') {
              const xs = decoded[1] as number[]
              validateSearchsortedTable(xs)
              searchsortedFirst(decoded[0] as number, xs)
            } else if (expected.function === 'interp.linear') {
              const table = decoded[0] as number[]
              const axis = decoded[1] as number[]
              const x = decoded[2] as number
              interpLinear(table, axis, x)
            } else if (expected.function === 'interp.bilinear') {
              const table = decoded[0] as number[][]
              const axisX = decoded[1] as number[]
              const axisY = decoded[2] as number[]
              const x = decoded[3] as number
              const y = decoded[4] as number
              interpBilinear(table, axisX, axisY, x, y)
            } else {
              throw new Error(`unhandled error-scenario fixture function ${expected.function}`)
            }
            throw new Error(
              `${errorScenario.name}: expected ClosedFunctionError ${errorScenario.expected_error_code}, got success`,
            )
          } catch (e) {
            expect(e, `error must be ClosedFunctionError`).toBeInstanceOf(ClosedFunctionError)
            expect((e as ClosedFunctionError).code).toBe(errorScenario.expected_error_code)
          }
        })
      }
    })
  }
})
