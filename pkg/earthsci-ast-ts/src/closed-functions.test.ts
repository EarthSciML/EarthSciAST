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
import { loadString } from './parse.js'
import { evaluateExpression } from './codegen.js'
import {
  ClosedFunctionError,
  checkClosedFunctionArguments,
  closedFunctionNames,
  CLOSED_FUNCTION_NAMES,
  dispatchClosedFunction,
  validateSearchsortedTable,
  searchsortedFirst,
  interpLinear,
  interpBilinear,
} from './closed-functions.js'
import { fixturesDir, REPO_ROOT } from './test-helpers.js'
import { ERROR_CODES, EsmDiagnosticError } from './errors.js'
import type { Expr, Model } from './types.js'

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

// `expected.json` encodes NaN and ±Inf as the JSON strings "NaN", "Inf" and
// "-Inf" (since JSON has neither). Convert to a real number for evaluation.
function decodeInput(v: unknown): unknown {
  if (v === 'NaN') return Number.NaN
  if (v === 'Inf') return Number.POSITIVE_INFINITY
  if (v === '-Inf') return Number.NEGATIVE_INFINITY
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
        const parsed = loadString(fileText)
        expect(parsed).toBeDefined()
        expect((parsed as any).esm).toBeDefined()
      })

      // Pull the RHS template from the parsed file so we exercise the
      // fn-op evaluator path end-to-end.
      const parsed = loadString(fileText) as any
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

      // Error scenarios validate spec-pinned diagnostic codes — first through
      // the LOAD-time argument check (the one load and validate() run on every
      // `fn` call, ruling Q-106), with the array inputs as `const` arguments,
      // then through evaluation below.
      if (expected.function.startsWith('interp.')) {
        for (const errorScenario of expected.error_scenarios ?? []) {
          it(`error scenario ${errorScenario.name} at load → ${errorScenario.expected_error_code}`, () => {
            const decoded = errorScenario.inputs.map(decodeInput)
            // searchsorted's `xs` is argument 2; every array of linear /
            // bilinear precedes its scalar queries. A scalar in an array
            // position is still written as a `const` (the wrong-rank cases).
            const arrayPositions =
              expected.function === 'interp.searchsorted'
                ? [1]
                : expected.function === 'interp.linear'
                  ? [0, 1]
                  : [0, 1, 2]
            const args = decoded.map((v, i) =>
              arrayPositions.includes(i) ? { op: 'const', args: [], value: v } : `q${i}`,
            )
            let code: string | null = null
            try {
              checkClosedFunctionArguments(expected.function, args)
            } catch (e) {
              expect(e).toBeInstanceOf(ClosedFunctionError)
              code = (e as ClosedFunctionError).code
            }
            expect(code).toBe(errorScenario.expected_error_code)
          })
        }
      }

      for (const errorScenario of expected.error_scenarios ?? []) {
        it(`error scenario ${errorScenario.name} → ${errorScenario.expected_error_code}`, () => {
          const decoded = errorScenario.inputs.map(decodeInput)
          try {
            if (mod === 'datetime') {
              const bindings = new Map<string, number>()
              bindings.set(paramName, decoded[0] as number)
              evaluateExpression(rhsTemplate, bindings)
            } else if (expected.function === 'interp.searchsorted') {
              // Through the registry's own dispatch, which owns the argument
              // contract: the rank check on `xs` (`interp_axis_not_const`) is
              // decided there, so a scalar or nested `xs` reaches it as-is.
              dispatchClosedFunction('interp.searchsorted', decoded)
            } else if (
              expected.function === 'interp.linear' ||
              expected.function === 'interp.bilinear'
            ) {
              // Through the registry's dispatch, which owns the rank checks
              // (`interp_table_not_const` / `interp_axis_not_const`).
              dispatchClosedFunction(expected.function, decoded)
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

describe('closedFunctionNames (API_SPEC.md §8 item 4)', () => {
  it('is a FUNCTION, matching Julia / Rust / Go', () => {
    expect(typeof closedFunctionNames).toBe('function')
    expect(closedFunctionNames()).toContain('datetime.year')
  })

  it('returns exactly the deprecated CLOSED_FUNCTION_NAMES constant', () => {
    expect(closedFunctionNames()).toBe(CLOSED_FUNCTION_NAMES)
  })
})

describe('interp.searchsorted: an xs that is not a rank-1 const array (esm-spec §9.2)', () => {
  const fixturePath = join(fixturesRoot, 'interp', 'searchsorted', 'canonical.esm')

  /** The canonical fixture with its `xs` argument replaced by `xs`. */
  function docWithXs(xs: unknown): string {
    const doc = JSON.parse(readFileSync(fixturePath, 'utf-8'))
    doc.models.Probe.equations[0].rhs.args[1] = xs
    return JSON.stringify(doc)
  }

  /** The canonical fixture with its `xs` argument replaced by `xs`, loaded. */
  function loadWithXs(xs: unknown): Expr {
    const file = loadString(docWithXs(xs))
    return (file.models!.Probe as Model).equations[0].rhs
  }

  function loadCode(xs: unknown): string {
    try {
      loadString(docWithXs(xs))
    } catch (e) {
      if (e instanceof EsmDiagnosticError) return e.code
      throw e
    }
    return 'NO_ERROR'
  }

  function evalCode(rhs: Expr, bindings: Map<string, number>): string {
    try {
      evaluateExpression(rhs, bindings)
    } catch (e) {
      if (e instanceof EsmDiagnosticError) return e.code
      throw e
    }
    return 'NO_ERROR'
  }

  it.each<[string, unknown]>([
    ['a variable reference', 'xs_var'],
    ['a non-const expression', { op: '+', args: [1, 2] }],
    ['a scalar const', { op: 'const', args: [], value: 3 }],
    [
      'a nested const',
      {
        op: 'const',
        args: [],
        value: [
          [1, 2],
          [3, 4],
        ],
      },
    ],
    [
      'a nested const holding a NaN',
      {
        op: 'const',
        args: [],
        value: [
          [1, NaN],
          [3, 4],
        ],
      },
    ],
  ])('rejects %s as `interp_axis_not_const`, at load and at evaluation', (_label, xs) => {
    // The nested-NaN form cannot be written in JSON.
    if (_label !== 'a nested const holding a NaN') {
      expect(loadCode(xs)).toBe(ERROR_CODES.INTERP_AXIS_NOT_CONST)
    }
    // Evaluation repeats the check on a call that never went through a load.
    const rhs = { op: 'fn', name: 'interp.searchsorted', args: ['x', xs] } as Expr
    // `xs_var` is BOUND (to a scalar): the code must not depend on whether the
    // evaluator could have produced a number for it.
    const bound = new Map([
      ['x', 2],
      ['xs_var', 3],
    ])
    expect(evalCode(rhs, bound)).toBe(ERROR_CODES.INTERP_AXIS_NOT_CONST)
    // ...nor on whether it could not.
    expect(evalCode(rhs, new Map([['x', 2]]))).toBe(ERROR_CODES.INTERP_AXIS_NOT_CONST)
  })

  it.each<[string, unknown]>([
    ['a scalar', 3],
    [
      'a nested array',
      [
        [1, Number.NaN],
        [3, 4],
      ],
    ],
  ])('validateSearchsortedTable rejects %s as `interp_axis_not_const`', (_label, xs) => {
    expect(() => validateSearchsortedTable(xs as number[])).toThrow(
      expect.objectContaining({ code: ERROR_CODES.INTERP_AXIS_NOT_CONST }),
    )
  })

  it('still evaluates the rank-1 const xs', () => {
    const rhs = loadWithXs({ op: 'const', args: [], value: [1, 2, 3] })
    expect(evaluateExpression(rhs, new Map([['x', 2]]))).toBe(2)
  })

  it('loads and evaluates an empty xs to 1 (ruling Q-108)', () => {
    const rhs = loadWithXs({ op: 'const', args: [], value: [] })
    expect(evaluateExpression(rhs, new Map([['x', 2]]))).toBe(1)
    expect(evaluateExpression(rhs, new Map([['x', Number.NaN]]))).toBe(1)
  })
})

// The interp scenarios through the pure-AST templates of lib/interp.esm. The
// TypeScript evaluator is scalar-only: it has no rule for `faq` (nor for an
// `index` read), so it cannot evaluate an expanded template. This pass checks
// the expansion instead — the template import resolves, and each scenario's
// right-hand side is the template body with every parameter occurrence
// (including the axis length inside a `faq` `ranges` bound) replaced by the
// scenario's arrays, query and length (esm-spec §9.6.3 constraint 5).
describe('Closed function registry — interp scenarios through lib/interp.esm templates', () => {
  const libraryPath = join(REPO_ROOT, 'lib', 'interp.esm')
  const constArray = (v: unknown): unknown => ({ op: 'const', args: [], value: v })

  // The `apply_expression_template` bindings of one scenario: arrays as `const`
  // nodes, each axis length its integer, queries as parameters `qx_<tag>` /
  // `qy_<tag>` (a NaN query cannot be a JSON literal).
  function templateBindings(name: string, inputs: unknown[], tag: number): Record<string, unknown> {
    const qx = `qx_${tag}`
    const qy = `qy_${tag}`
    if (name === 'searchsorted') {
      const [, xs] = inputs as [unknown, unknown[]]
      return { x: qx, xs: constArray(xs), n: xs.length }
    }
    if (name === 'linear') {
      const [table, axis] = inputs as [unknown, unknown[]]
      return { table: constArray(table), axis: constArray(axis), x: qx, n: axis.length }
    }
    const [table, axisX, axisY] = inputs as [unknown, unknown[], unknown[]]
    return {
      table: constArray(table),
      axis_x: constArray(axisX),
      axis_y: constArray(axisY),
      x: qx,
      y: qy,
      nx: axisX.length,
      ny: axisY.length,
    }
  }

  // Test-local substitution oracle: every string other than an `op` name that
  // equals a parameter is replaced by its binding. The interp templates carry no
  // nested `apply_expression_template`, whose `name` would be exempt.
  function substitute(body: unknown, bindings: Record<string, unknown>): unknown {
    if (typeof body === 'string') return Object.hasOwn(bindings, body) ? bindings[body] : body
    if (Array.isArray(body)) return body.map((v) => substitute(v, bindings))
    if (body !== null && typeof body === 'object') {
      const out: Record<string, unknown> = {}
      for (const [k, v] of Object.entries(body)) out[k] = k === 'op' ? v : substitute(v, bindings)
      return out
    }
    return body
  }

  const library = JSON.parse(readFileSync(libraryPath, 'utf-8'))
  for (const name of ['searchsorted', 'linear', 'bilinear']) {
    it(`expands interp.${name} for every success scenario`, () => {
      const expected: ExpectedFile = JSON.parse(
        readFileSync(join(fixturesRoot, 'interp', name, 'expected.json'), 'utf-8'),
      )
      const calls = expected.scenarios.map((sc, i) => templateBindings(name, sc.inputs, i))
      const variables: Record<string, unknown> = {}
      calls.forEach((b, i) => {
        variables[`out_${i}`] = { type: 'unknown', default: 0.0, units: '1' }
        for (const q of [b.x, b.y]) {
          if (typeof q === 'string') variables[q] = { type: 'parameter', default: 0.0, units: '1' }
        }
      })
      const doc = {
        esm: '1.1.0',
        metadata: { name: `interp_${name}_template` },
        models: {
          Probe: {
            expression_template_imports: [{ ref: libraryPath }],
            variables,
            equations: calls.map((bindings, i) => ({
              lhs: { op: 'D', args: [`out_${i}`], wrt: 't' },
              rhs: { op: 'apply_expression_template', args: [], name, bindings },
            })),
          },
        },
      }
      const equations = (loadString(JSON.stringify(doc)).models!.Probe as Model).equations
      expect(equations).toHaveLength(calls.length)
      const body = library.expression_templates[name].body
      equations.forEach((eq, i) => {
        const got = JSON.parse(JSON.stringify(eq.rhs))
        const want = JSON.parse(JSON.stringify(substitute(body, calls[i]!)))
        expect(got, expected.scenarios[i]!.name).toEqual(want)
      })
    })
  }
})

// The datetime scenarios through the pure-AST templates of lib/calendar.esm.
// TypeScript checks the expansion, not its value (the template values are
// checked in Julia, Python and Rust): the template import resolves, and each
// right-hand side is the template body with every occurrence of its one
// parameter `t` replaced and every nested `civil_*` helper reference expanded
// in turn (esm-spec §9.6.4 rule 2, §9.7.3) — `t` bound to each finite scenario
// instant as a literal, and to a parameter, as a caller with a NaN or infinite
// instant would write it (esm-spec §9.6.3 constraint 5).
describe('Closed function registry — datetime scenarios through lib/calendar.esm templates', () => {
  const libraryPath = join(REPO_ROOT, 'lib', 'calendar.esm')
  const library = JSON.parse(readFileSync(libraryPath, 'utf-8'))
  const templates: Record<string, { params: string[]; body: unknown }> =
    library.expression_templates

  // Test-local expansion oracle: every string other than an `op` name that is
  // a parameter is replaced by its binding, and a nested
  // `apply_expression_template` is replaced by its template's body expanded
  // under its (already substituted) bindings.
  function expand(body: unknown, bindings: Record<string, unknown>): unknown {
    if (typeof body === 'string') return Object.hasOwn(bindings, body) ? bindings[body] : body
    if (Array.isArray(body)) return body.map((v) => expand(v, bindings))
    if (body !== null && typeof body === 'object') {
      const node = body as Record<string, unknown>
      if (node.op === 'apply_expression_template') {
        const inner: Record<string, unknown> = {}
        for (const [k, v] of Object.entries(node.bindings as Record<string, unknown>)) {
          inner[k] = expand(v, bindings)
        }
        return expand(templates[node.name as string]!.body, inner)
      }
      const out: Record<string, unknown> = {}
      for (const [k, v] of Object.entries(node)) out[k] = k === 'op' ? v : expand(v, bindings)
      return out
    }
    return body
  }

  function expandedRhs(name: string, instants: unknown[]): unknown[] {
    const variables: Record<string, unknown> = {
      tu: { type: 'parameter', default: 0.0, units: 's' },
    }
    instants.forEach((_, i) => {
      variables[`out_${i}`] = { type: 'unknown' }
    })
    const doc = {
      esm: '1.2.0',
      metadata: { name: `datetime_${name}_template` },
      models: {
        Probe: {
          expression_template_imports: [{ ref: libraryPath, only: [name] }],
          variables,
          equations: instants.map((t, i) => ({
            lhs: `out_${i}`,
            rhs: { op: 'apply_expression_template', args: [], name, bindings: { t } },
          })),
        },
      },
    }
    const equations = (loadString(JSON.stringify(doc)).models!.Probe as Model).equations
    expect(equations).toHaveLength(instants.length)
    return equations.map((eq) => JSON.parse(JSON.stringify(eq.rhs)))
  }

  const names = [
    'year',
    'month',
    'day',
    'hour',
    'minute',
    'second',
    'day_of_year',
    'julian_day',
    'is_leap_year',
  ]
  it('declares the nine datetime.* templates and seconds_since_midnight, each of one parameter t', () => {
    for (const name of [...names, 'seconds_since_midnight']) {
      expect(templates[name]?.params, name).toEqual(['t'])
    }
    for (const name of Object.keys(templates)) {
      if (![...names, 'seconds_since_midnight'].includes(name)) expect(name).toMatch(/^civil_/)
    }
  })

  for (const name of names) {
    it(`expands datetime.${name} for every scenario`, () => {
      const expected: ExpectedFile = JSON.parse(
        readFileSync(join(fixturesRoot, 'datetime', name, 'expected.json'), 'utf-8'),
      )
      const instants: unknown[] = expected.scenarios
        .map((sc) => sc.inputs[0])
        .filter((v) => typeof v === 'number')
      instants.push('tu')
      expandedRhs(name, instants).forEach((got, i) => {
        const want = JSON.parse(JSON.stringify(expand(templates[name]!.body, { t: instants[i] })))
        expect(got, `t = ${String(instants[i])}`).toEqual(want)
      })
    })
  }

  it('expands seconds_since_midnight', () => {
    const instants: unknown[] = [86399.5, 'tu']
    expandedRhs('seconds_since_midnight', instants).forEach((got, i) => {
      const want = JSON.parse(
        JSON.stringify(expand(templates.seconds_since_midnight!.body, { t: instants[i] })),
      )
      expect(got, `t = ${String(instants[i])}`).toEqual(want)
    })
  })
})
