/**
 * Per-term provenance through flatten (esm-libraries-spec §4.7.5, CONFORMANCE_SPEC
 * §5.48, issue #539).
 *
 * The flatten corpus (`flatten-conformance.test.ts`) pins every equation's
 * rendered contribution list. This suite checks what a rendering cannot:
 *
 * - the INVARIANT, by evaluation: the body of each equation evaluates bit for
 *   bit to the LEFT-FOLD sum of its contributions' values at sampled non-default
 *   states. The scalar evaluator binds scalars only, so a pointwise-lifted
 *   equation (an `faq` over a grid) is out of its reach and is skipped;
 * - the `systems`-order pair: the same contributions and origins in both
 *   argument orders, in `rhs_A + rhs_B` order;
 * - non-vacuity: two structurally identical contributions stay two.
 */
import { readdirSync } from 'node:fs'
import { describe, expect, it } from 'vitest'
import { flatten, type FlattenedEquation, type FlattenedSystem } from './flatten.js'
import { equationBody } from './flatten-contributions.js'
import { evaluateExpression } from './codegen.js'
import { freeVariables } from './expression.js'
import { toAscii } from './pretty-print.js'
import { fixturesDir, loadFixture, readFixture } from './test-helpers.js'
import type { Contribution, TermOrigin } from './index.js'

const TP_FIXTURES = readdirSync(fixturesDir('conformance', 'term_provenance', 'fixtures'))
  .filter((f) => f.endsWith('.esm'))
  .sort()
const CORPUS = JSON.parse(readFixture('conformance', 'flatten', 'cases.json')) as {
  cases: Array<{ id: string; fixture: string }>
}

function flattenTp(name: string): FlattenedSystem {
  return flatten(loadFixture('conformance', 'term_provenance', 'fixtures', name))
}

function equation(flat: FlattenedSystem, lhs: string): FlattenedEquation {
  const matches = flat.equations.filter((eq) => toAscii(eq.lhs) === lhs)
  expect(matches).toHaveLength(1)
  return matches[0]
}

const origins = (c: Contribution): TermOrigin[] => c.origins

// --- the invariant, by evaluation --------------------------------------------

/** Independent sampled states per equation: one state can sum to the same bits
 *  in every association by chance; several make that vanishingly unlikely. */
const SAMPLES = 8

/** FNV-1a, so the samples are deterministic. */
function hash(s: string): number {
  let h = 0x811c9dc5
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i)
    h = Math.imul(h, 0x01000193) >>> 0
  }
  return h
}

/** A non-default value for `name` in sample `salt`, spread over many decades so
 *  that summing in another association rounds differently. */
function sample(name: string, salt: number): number {
  const h = hash(`${salt}:${name}`)
  return (1 + (h % 100003) / 100003) * 10 ** (((h >>> 17) % 13) - 6)
}

/** Bit equality of two doubles (`Object.is` also tells `0` from `-0`). */
function sameBits(a: number, b: number): boolean {
  return Object.is(a, b) || (Number.isNaN(a) && Number.isNaN(b))
}

interface InvariantResult {
  evaluated: boolean
  /** Some sampled state sums the contributions to different bits right-nested. */
  discriminating: boolean
}

function checkInvariant(eq: FlattenedEquation): InvariantResult {
  if (eq.lifted === true) return { evaluated: false, discriminating: false }
  const names = new Set<string>()
  for (const c of eq.contributions) for (const n of freeVariables(c.expr)) names.add(n)
  let discriminating = false
  for (let salt = 0; salt < SAMPLES; salt++) {
    const bindings = new Map<string, number>([['t', 0.75]])
    for (const n of names) if (n !== 't') bindings.set(n, sample(n, salt))
    let body: number
    let parts: number[]
    try {
      body = evaluateExpression(equationBody(eq), bindings)
      parts = eq.contributions.map((c) => evaluateExpression(c.expr, bindings))
    } catch {
      // An operator the scalar evaluator cannot run (an undiscretized spatial
      // `D`, an array op, an unresolved `D(x, t)`).
      return { evaluated: false, discriminating: false }
    }
    const fold = parts.slice(1).reduce((acc, p) => acc + p, parts[0])
    expect(
      sameBits(body, fold),
      `${toAscii(eq.lhs)}: body ${body} != left fold ${fold} of [${parts.join(', ')}]`,
    ).toBe(true)
    const right = parts.slice(0, -1).reduceRight((acc, p) => p + acc, parts[parts.length - 1])
    discriminating ||= !sameBits(right, fold)
  }
  return { evaluated: true, discriminating }
}

const SCALAR_UNREACHABLE = new Set(['placeholder_expansion.esm', 'pointwise_lift.esm'])

describe('the body is the left fold of the contributions (§4.7.5 invariant)', () => {
  it.each(TP_FIXTURES)('%s', (fixture) => {
    const flat = flattenTp(fixture)
    let evaluated = 0
    for (const eq of flat.equations) {
      const result = checkInvariant(eq)
      if (!result.evaluated) continue
      evaluated += 1
      // With three or more contributions the check must be able to see the order.
      if (eq.contributions.length >= 3) {
        expect(result.discriminating, `${toAscii(eq.lhs)} cannot tell sum orders apart`).toBe(true)
      }
    }
    // Out of the scalar evaluator's reach entirely: `grad` with no
    // discretization, and the lifted `faq` over a grid.
    if (!SCALAR_UNREACHABLE.has(fixture)) expect(evaluated).toBeGreaterThan(0)
  })

  it.each(CORPUS.cases.map((c) => [c.id, c.fixture] as const))(
    'corpus case %s, where the scalar evaluator reaches',
    (_id, fixture) => {
      const flat = flatten(loadFixture(...fixture.split('/')))
      for (const eq of flat.equations) checkInvariant(eq)
    },
  )

  it('every flattened contribution has a non-empty, deduplicated origin list', () => {
    for (const { fixture } of CORPUS.cases) {
      const flat = flatten(loadFixture(...fixture.split('/')))
      for (const eq of flat.equations) {
        expect(eq.contributions.length).toBeGreaterThan(0)
        for (const c of eq.contributions) {
          expect(c.origins.length).toBeGreaterThan(0)
          const keys = c.origins.map((o) => JSON.stringify(o))
          expect(new Set(keys).size).toBe(keys.length)
        }
      }
    }
  })
})

// --- rows of the step table a rendering cannot state -------------------------

describe('per-term provenance rows', () => {
  it('systems order changes the order of the contributions, not their origins', () => {
    const pairs = (eq: FlattenedEquation) =>
      eq.contributions.map((c) => [toAscii(c.expr), origins(c)] as const)
    const ab = pairs(equation(flattenTp('systems_order_ab.esm'), 'D(Chem.O3)/Dt'))
    const ba = pairs(equation(flattenTp('systems_order_ba.esm'), 'D(Chem.O3)/Dt'))
    const key = (p: readonly [string, TermOrigin[]]) => JSON.stringify(p)
    expect(ab.map(key).sort()).toEqual(ba.map(key).sort())
    expect(ab.map(([, o]) => o)).toEqual([[{ component: 'Chem' }], [{ component: 'Sink' }]])
    expect(ba.map(([, o]) => o)).toEqual([[{ component: 'Sink' }], [{ component: 'Chem' }]])
  })

  it('two structurally identical contributions stay two', () => {
    const eq = equation(flattenTp('non_vacuity.esm'), 'D(Chem.O3)/Dt')
    const tail = eq.contributions.slice(1)
    expect(tail.map((c) => toAscii(c.expr))).toEqual(['Emis.flux', 'Emis.flux'])
    expect(tail.map(origins)).toEqual([[{ component: 'OpA' }], [{ component: 'OpB' }]])
  })

  it('the pointwise lift indexes inside each contribution and wraps their sum', () => {
    const lifted = flattenTp('pointwise_lift.esm').equations.filter((e) => e.lifted === true)
    expect(lifted).toHaveLength(1)
    const eq = lifted[0]
    expect((eq.rhs as { op: string }).op).toBe('faq')
    expect(equationBody(eq)).toBe((eq.rhs as { expr: unknown }).expr)
    expect(eq.contributions.map(origins)).toEqual(
      ['Chem', 'Src', 'Adv'].map((component) => [{ component }]),
    )
  })
})
