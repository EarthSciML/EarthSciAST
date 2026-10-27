/**
 * Cross-language pin for the EXACT TREE a reaction system lowers to.
 *
 * Drives the shared, hand-written corpus at
 * `tests/conformance/reactions/lowering_form.json`: every binding's
 * `deriveOdes` and `flatten` must produce the same expressions for a reaction
 * network (esm-libraries-spec §4.6.2). Derived documents copy flattened terms
 * verbatim, so a binding that lowers a reaction to a different tree writes
 * different bytes.
 *
 * The other bindings also keep integer and non-integer numbers apart; a
 * JavaScript number has no such kind, so this driver compares numbers by value
 * only (the corpus' `how_to_drive` names this exception). Expressions are
 * compared after a JSON round trip, which is the form a derived document
 * carries.
 */

import { describe, expect, it } from 'vitest'
import { flatten } from './flatten.js'
import { loadDocument } from './parse.js'
import { deriveOdes } from './reactions.js'
import { readFixture } from './test-helpers.js'
import type { ReactionSystem } from './types.js'

interface LoweringCase {
  name: string
  description: string
  system: string
  lifted: boolean
  derive_odes: { lhs: unknown; rhs: unknown }[]
  flatten: { species: string; contribution: unknown }[]
  document: object
}

const corpus = JSON.parse(readFixture('conformance', 'reactions', 'lowering_form.json')) as {
  cases: LoweringCase[]
}

/** The JSON a derived document would carry for `value`. */
const written = (value: unknown): unknown => JSON.parse(JSON.stringify(value)) as unknown

type Node = { op?: string; args?: unknown[]; expr?: Node }

/**
 * The species a flattened left-hand side differentiates: `D(x, t)`, or the
 * lift's `faq` over `D(index(x, ...), t)`.
 */
function speciesOf(lhs: Node): string {
  const derivative = lhs.op === 'faq' ? (lhs.expr as Node) : lhs
  expect(derivative.op).toBe('D')
  const target = derivative.args?.[0]
  return (typeof target === 'string' ? target : (target as Node).args?.[0]) as string
}

describe('reaction lowering form corpus', () => {
  it('reads at least three cases', () => {
    expect(corpus.cases.length).toBeGreaterThanOrEqual(3)
  })

  for (const testCase of corpus.cases) {
    describe(testCase.name, () => {
      it('derive_odes emits the canonical tree', () => {
        const file = loadDocument(testCase.document)
        const system = (file.reaction_systems as Record<string, ReactionSystem>)[testCase.system]
        const equations = deriveOdes(system).equations
        expect(equations.length).toBe(testCase.derive_odes.length)
        equations.forEach((eq, k) => {
          expect(written(eq.lhs), `derive_odes[${k}].lhs`).toStrictEqual(
            testCase.derive_odes[k].lhs,
          )
          expect(written(eq.rhs), `derive_odes[${k}].rhs`).toStrictEqual(
            testCase.derive_odes[k].rhs,
          )
        })
      })

      it('flatten emits the canonical tree', () => {
        const flat = flatten(loadDocument(testCase.document))
        const origin = [{ component: testCase.system }]
        const selected = []
        for (const eq of flat.equations) {
          const mine = eq.contributions.filter(
            (c) => JSON.stringify(written(c.origins)) === JSON.stringify(origin),
          )
          if (mine.length === 0) continue
          expect(mine.length).toBe(1)
          selected.push({ eq, contribution: mine[0] })
        }
        expect(selected.length).toBe(testCase.flatten.length)
        selected.forEach(({ eq, contribution }, k) => {
          const expected = testCase.flatten[k]
          expect(speciesOf(written(eq.lhs) as Node)).toBe(expected.species)
          expect(written(contribution.expr), `flatten[${k}].contribution`).toStrictEqual(
            expected.contribution,
          )
          if (!testCase.lifted) {
            expect(eq.contributions.length).toBe(1)
            expect(written(eq.rhs), `flatten[${k}].rhs`).toStrictEqual(expected.contribution)
            expect(written(eq.lhs)).toStrictEqual({ op: 'D', args: [expected.species], wrt: 't' })
          }
        })
      })
    })
  }
})
