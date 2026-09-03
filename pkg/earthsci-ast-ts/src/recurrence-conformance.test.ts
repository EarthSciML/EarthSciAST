/**
 * Drives the shared recurrence-rejection corpus
 * (`tests/conformance/recurrence/rejections.json`).
 *
 * The eight malformed causal self-references of esm-spec §4.3.1.1 *Rejections*
 * that EVERY binding must refuse, executing or not (CONFORMANCE_SPEC §5.19.5).
 * TypeScript evaluates no array numerics, so refusing these — with the right
 * code, at the right pointer — is the whole of its implementation of the
 * construct, which makes this suite the one that matters most here.
 *
 * **Why a SHARED corpus and not just this binding's own tests.** Because the
 * failure this pins is invisible locally. Gating the cadence seeder's self-edge
 * exemption on well-foundedness rather than on candidacy silently converts every
 * one of these eight from its specific code into a single `load_error`: the read
 * is ill-founded, so it is by definition not a well-founded recurrence, so the
 * exemption misses it, so the cycle check fires and pre-empts the diagnosis. The
 * document is still rejected, so a suite asserting "it failed" still passes, and
 * a suite asserting only `is_valid === false` still passes. Only an assertion on
 * the CODE catches it. That regression is what this file exists to prevent.
 *
 * **Code and path only — never prose.** The corpus's own `pinned` block says so,
 * and the test below asserts `pinned.message === false` so that line cannot be
 * moved quietly. The same defect legitimately reads differently depending on
 * which check reached it first — an unbound parameter used as a whole index is
 * reported by the coefficient test in some bindings and by the affinity test in
 * others, and both are correct — so pinning wording would make the first
 * reworded message a cross-binding conformance failure.
 */

import { describe, expect, it } from 'vitest'
import { validate } from './validate.js'
import { readFixture } from './test-helpers.js'
import type { EsmFile } from './types.js'

/** The corpus's JSON shape. */
interface RejectionCase {
  id: string
  expected_code: string
  expected_path: string
  why: string
  document: unknown
}
interface RejectionCorpus {
  category: string
  version: string
  pinned: { code: boolean; path: boolean; message: boolean; note?: string }
  cases: RejectionCase[]
}

const corpus: RejectionCorpus = JSON.parse(
  readFixture('conformance', 'recurrence', 'rejections.json'),
) as RejectionCorpus

describe('shared recurrence-rejection corpus (CONFORMANCE_SPEC §5.19.5)', () => {
  it('pins CODE and PATH but not MESSAGE', () => {
    // Asserted rather than merely honoured: if someone flips `message` to true
    // in the corpus, that is a change to the cross-binding contract and it
    // should fail here rather than quietly start pinning this binding's prose.
    expect(corpus.pinned.code).toBe(true)
    expect(corpus.pinned.path).toBe(true)
    expect(corpus.pinned.message).toBe(false)
  })

  it('carries all eight rejection cases', () => {
    // A dropped case would otherwise be silent coverage loss: `it.each` over a
    // shortened list still reports all green.
    expect(corpus.cases).toHaveLength(8)
    expect(new Set(corpus.cases.map((c) => c.id)).size).toBe(8)
  })

  it.each(corpus.cases.map((c) => [c.id, c] as const))(
    'refuses %s with the pinned code and path',
    (_id, testCase) => {
      const result = validate(testCase.document as EsmFile)

      // The pair must come from STRUCTURAL validation. A schema error here would
      // mean the corpus document is malformed JSON-schema-wise rather than
      // malformed as a recurrence, which is a different defect and would let a
      // binding "pass" without implementing §4.3.1.1 at all.
      expect(
        result.schema_errors,
        `${testCase.id}: the corpus document must be schema-valid, so that the ` +
          'finding under test is the recurrence rule and not a shape error',
      ).toEqual([])

      const pairs = result.structural_errors.map((e) => `${e.code} @ ${e.path}`)
      const expected = `${testCase.expected_code} @ ${testCase.expected_path}`

      // Containment, not equality: the corpus pins THIS pair and says nothing
      // about whatever else a binding may legitimately report for the same
      // document. Prose is deliberately not compared — see the file header.
      expect(
        pairs,
        `${testCase.id} — ${testCase.why}\nreported: ${pairs.join(', ') || '(none)'}`,
      ).toContain(expected)
    },
  )

  it('reports a specific recurrence code for every case, never a bare load_error', () => {
    // The regression stated directly, independent of the per-case assertions
    // above. `load_error` is what a cycle check produces when it pre-empts the
    // recurrence diagnosis; seeing one here means the self-edge exemption has
    // been re-gated on well-foundedness instead of candidacy.
    const collapsed = corpus.cases
      .map((c) => ({
        id: c.id,
        codes: validate(c.document as EsmFile).structural_errors.map((e) => e.code),
      }))
      .filter((r) => r.codes.includes('load_error'))
      .map((r) => r.id)
    expect(
      collapsed,
      'these cases collapsed to a load_error, losing their §5.19.5 code — the ' +
        'cadence self-edge exemption must be gated on recurrence CANDIDACY, not ' +
        'on well-foundedness',
    ).toEqual([])
  })
})
