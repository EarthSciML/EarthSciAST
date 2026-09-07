/**
 * TypeScript adapter for the SHARED `assertion_tolerance` conformance category
 * (CONFORMANCE_SPEC §5.32, `tests/conformance/assertion_tolerance/`).
 *
 * The category's subject is the esm-spec §6.6.3 pass predicate as a PURE
 * FUNCTION of `(actual, expected, rel, abs)`. Every other assertion category is
 * a simulation category: it computes an actual and then compares it, so it can
 * only exercise the predicate at the pairs an integrator happens to produce —
 * and those all sit in the `|actual| ≤ |expected|` region, where
 * `rel·max(|a|,|e|)` and `rel·|e|` compute the same number. The two readings
 * differ only on an OVERSHOOT, which no fixture in any category reaches. This
 * adapter feeds the discriminating pairs directly.
 *
 * This is why TypeScript is `bindings_required` here while it is
 * `scope_excluded` from `assertion_nonfinite` (§5.20): that category needs a
 * simulator, which this binding does not have, and this one needs only
 * arithmetic, which it does. `checkAssertion` is the same function
 * `units-fixture.test.ts` compares its fixture assertions with — an adapter
 * that re-derived the predicate here would be testing itself, which is the
 * defect the category exists to close.
 */
import * as fs from 'node:fs'
import * as path from 'node:path'
import { describe, it, expect } from 'vitest'
import { checkAssertion } from './assertion-tolerance.js'
import { fixturesDir } from './test-helpers.js'

interface PredicateCase {
  id: string
  actual: number | string
  expected: number | string
  rel: number
  abs: number
  passed: boolean
  why?: string
  discriminates?: string[]
}

interface Golden {
  readings_discriminated: Record<string, number>
  counts: { cases: number; pass: number; fail: number }
  cases: PredicateCase[]
}

interface Manifest {
  category: string
  reference_binding: string
  bindings_required: string[]
  scope_excluded: Record<string, string>
}

const CATEGORY_DIR = fixturesDir('conformance', 'assertion_tolerance')

function readJson<T>(...segments: string[]): T {
  return JSON.parse(fs.readFileSync(path.join(CATEGORY_DIR, ...segments), 'utf8')) as T
}

const NON_FINITE: Record<string, number> = {
  '+inf': Number.POSITIVE_INFINITY,
  '-inf': Number.NEGATIVE_INFINITY,
  nan: Number.NaN,
}

/**
 * A golden `actual`/`expected` is either a JSON number or one of exactly three
 * strings. An unrecognised value is a HARD ERROR: silently skipping a case
 * would let the category shrink without anything going red.
 */
function toNumber(value: number | string, caseId: string, field: string): number {
  if (typeof value === 'number') return value
  const mapped = NON_FINITE[value]
  if (mapped === undefined) {
    throw new Error(
      `${caseId}: ${field} is the string ${JSON.stringify(value)}; the golden's ` +
        `encoding admits only "+inf", "-inf" and "nan"`,
    )
  }
  return mapped
}

describe('conformance: assertion_tolerance (esm-spec §6.6.3)', () => {
  it('requires TypeScript by name, and does not exclude it', () => {
    const m = readJson<Manifest>('manifest.json')
    expect(m.category).toBe('assertion_tolerance')
    expect(m.reference_binding).toBe('analytic')
    // This binding HAS the predicate, so a scope exclusion here would be a
    // claim it cannot honour — the opposite of the assertion_nonfinite case.
    expect(m.bindings_required).toContain('typescript')
    expect(m.scope_excluded?.typescript).toBeUndefined()
  })

  it('matches the golden verdict on every case', () => {
    const golden = readJson<Golden>('golden', 'predicate_verdicts.json')
    expect(golden.cases.length).toBeGreaterThan(0)

    const failures: string[] = []
    let nPass = 0
    for (const c of golden.cases) {
      const actual = toNumber(c.actual, c.id, 'actual')
      const expectedValue = toNumber(c.expected, c.id, 'expected')
      if (c.passed) nPass += 1
      const got = checkAssertion(actual, expectedValue, c.rel, c.abs)
      if (got !== c.passed) {
        failures.push(
          `${c.id}: checkAssertion(${actual}, ${expectedValue}, rel=${c.rel}, ` +
            `abs=${c.abs}) = ${got}, golden says ${c.passed} — ${c.why ?? ''}`,
        )
      }
    }
    expect(failures, failures.join('\n')).toEqual([])
    // Non-vacuity: a golden of one verdict would be satisfied by a constant.
    expect(nPass).toBeGreaterThan(0)
    expect(nPass).toBeLessThan(golden.cases.length)
  })

  it('carries a case list that can still see every known wrong reading', () => {
    // The generator counts, per known WRONG reading of §6.6.3, how many cases
    // change verdict under it. A zero would mean the case list had quietly
    // stopped being able to see that defect — which is how the ~12 ad-hoc
    // harnesses in #223 stayed green for years.
    const d = readJson<Golden>('golden', 'predicate_verdicts.json').readings_discriminated
    for (const reading of ['asymmetric', 'sum_form', 'epsilon_floor', 'no_finiteness_guard']) {
      expect(d[reading], `no case discriminates the \`${reading}\` reading`).toBeGreaterThan(0)
    }
  })
})
