/**
 * The esm-spec §4.8.6 warning stage: a bare numeric literal read as
 * dimensionless at scale 1 (the literal zero excepted).
 *
 * Gates `tests/conformance/dimensionless_literal/`: every file in the golden is
 * VALID, and carries exactly the pinned `units_dimensionless_literal_mismatch`
 * warnings, at the pinned JSON Pointers.
 */

import { readFileSync } from 'node:fs'
import * as path from 'node:path'
import { describe, expect, it } from 'vitest'
import { ERROR_CODES } from './errors.js'
import { REPO_ROOT, fixturesDir } from './test-helpers.js'
import { checkDimensions, parseUnit } from './units.js'
import { validateText } from './validate.js'
import { floatLit, intLit } from './numeric-literal.js'
import type { Expression } from './types.js'

const GOLDEN = JSON.parse(
  readFileSync(
    fixturesDir('conformance', 'dimensionless_literal', 'golden', 'expected_warnings.json'),
    'utf-8',
  ),
) as { code: string; files: Record<string, string[]> }

const FIXTURE = 'tests/conformance/dimensionless_literal/fixtures/dimensionless_literal.esm'

function validateRel(rel: string) {
  const abs = path.join(REPO_ROOT, rel)
  return validateText(readFileSync(abs, 'utf-8'), { basePath: path.dirname(abs) })
}

function literalWarnings(rel: string) {
  return validateRel(rel).unit_warnings.filter(
    (w) => w.code === ERROR_CODES.UNITS_DIMENSIONLESS_LITERAL_MISMATCH,
  )
}

describe('units_dimensionless_literal_mismatch (esm-spec §4.8.6)', () => {
  it('the golden names the registered code', () => {
    expect(GOLDEN.code).toBe(ERROR_CODES.UNITS_DIMENSIONLESS_LITERAL_MISMATCH)
  })

  it.each(Object.keys(GOLDEN.files).sort())(
    '%s: the warnings are pinned and validity is unchanged',
    (rel) => {
      const result = validateRel(rel)
      expect(result.structural_errors.map((e) => `[${e.code}] ${e.path}`)).toEqual([])
      expect(result.is_valid).toBe(true)
      const got = result.unit_warnings
        .filter((w) => w.code === ERROR_CODES.UNITS_DIMENSIONLESS_LITERAL_MISMATCH)
        .map((w) => w.location ?? '')
        .sort()
      expect(got).toEqual(GOLDEN.files[rel])
    },
  )

  it('the warning names the pointer, the literal and the repair', () => {
    const byPath = new Map(literalWarnings(FIXTURE).map((w) => [w.location, w.message]))
    const message = byPath.get('/models/Literals/equations/0')
    expect(message).toBeDefined()
    expect(message).toContain('/models/Literals/equations/0')
    expect(message).toContain('273.15')
    expect(message).toContain('K')
    expect(message).toContain('const(')
  })
})

describe('the dimensionless-literal rule in checkDimensions', () => {
  const minus = (arg: Expression): Expression => ({ op: '-', args: [arg] }) as Expression
  const lit = (l: ReturnType<typeof intLit>): Expression => l as unknown as Expression
  const unitless = (value: number): Expression =>
    ({ op: 'const', args: [], value }) as unknown as Expression

  it.each<[string, Expression]>([
    ['0', 0],
    ['0.0', lit(floatLit(0))],
    ['-0.0', -0],
    ['int 0', lit(intLit(0))],
    ['-(0)', minus(0)],
    ['const 0', unitless(0)],
  ])('zero (%s) stays neutral under both rules', (_label, expr) => {
    const bindings = new Map()
    expect(checkDimensions(expr, bindings).dimensions).toBeNull()
    expect(checkDimensions(expr, bindings, { dimensionlessLiterals: true }).dimensions).toBeNull()
  })

  it.each<[string, Expression]>([
    ['2', 2],
    ['-1.5', -1.5],
    ['int 3', lit(intLit(3))],
    ['-(2)', minus(2)],
    ['const 0.5', unitless(0.5)],
  ])('a nonzero literal (%s) is dimensionless only under the new rule', (_label, expr) => {
    const bindings = new Map()
    expect(checkDimensions(expr, bindings).dimensions).toBeNull()
    const typed = checkDimensions(expr, bindings, { dimensionlessLiterals: true }).dimensions
    expect(typed).not.toBeNull()
    expect(typed!.dims).toEqual({})
    expect(typed!.exact.isOne()).toBe(true)
  })

  it('a zero summand still adopts its sibling under the new rule; a nonzero one does not', () => {
    const bindings = new Map([['x', parseUnit('m')]])
    const opts = { dimensionlessLiterals: true }
    const zero = checkDimensions({ op: '+', args: ['x', 0] } as Expression, bindings, opts)
    expect(zero.diagnostics).toEqual([])
    expect(zero.dimensions!.dims).toEqual({ m: 1 })
    const one = checkDimensions({ op: '+', args: ['x', 1] } as Expression, bindings, opts)
    expect(one.diagnostics.map((d) => d.code)).toContain(ERROR_CODES.DIMENSIONAL_MISMATCH)
    // The current rule is unchanged.
    expect(
      checkDimensions({ op: '+', args: ['x', 1] } as Expression, bindings).diagnostics,
    ).toEqual([])
  })

  it('a unit-bearing const keeps its declared unit under both rules', () => {
    const k = { op: 'const', args: [], value: 273.15, units: 'K' } as unknown as Expression
    for (const opts of [{}, { dimensionlessLiterals: true }]) {
      expect(checkDimensions(k, new Map(), opts).dimensions!.dims).toEqual({ K: 1 })
    }
  })
})
