/**
 * esm-spec §6.6.4 — tolerance resolution, as this binding implements it.
 *
 * The §6.6.3 PREDICATE is pinned cross-binding by the shared
 * `assertion_tolerance` conformance category
 * (`assertion-tolerance-conformance.test.ts`). §6.6.4 RESOLUTION has no shared
 * category yet, so these are this binding's own statement of the rule — and in
 * particular of the per-field fallthrough, which every binding originally got
 * wrong in the same way (EarthSciML/EarthSciAST#228) and which no fixture in the
 * corpus reaches, because no `.esm` fixture declares a tolerance at more than
 * one level.
 */

import { describe, it, expect } from 'vitest'
import { DEFAULT_REL_TOL, resolveTolerance } from './assertion-tolerance.js'

describe('resolveTolerance (esm-spec §6.6.4)', () => {
  it('takes each bound from the innermost level that declares it', () => {
    // The case #228 is about: neither level declares both bounds, and the
    // wholesale rule would return the assertion block alone and zero `rel`.
    expect(resolveTolerance({ rel: 1e-6 }, undefined, { abs: 1e-9 })).toEqual({
      rel: 1e-6,
      abs: 1e-9,
    })
    expect(resolveTolerance({ abs: 1e-3 }, { rel: 1e-4 }, undefined)).toEqual({
      rel: 1e-4,
      abs: 1e-3,
    })
  })

  it('lets the inner level override a bound the outer one also declares', () => {
    expect(resolveTolerance({ rel: 1e-2, abs: 1e-2 }, { rel: 1e-4 }, { abs: 1e-9 })).toEqual({
      rel: 1e-4,
      abs: 1e-9,
    })
  })

  it('treats an explicit 0 as a declaration that stops the fallthrough', () => {
    // "no bound of this kind", not "absent". The recurrence fixtures pin a
    // bit-exact contract with a model-level {rel: 0, abs: 0}; reading either as
    // absent would run them at a tolerance and still show green.
    expect(resolveTolerance({ rel: 1e-6, abs: 1e-6 }, undefined, { rel: 0 })).toEqual({
      rel: 0,
      abs: 1e-6,
    })
    expect(resolveTolerance({ rel: 0, abs: 0 }, undefined, undefined)).toEqual({ rel: 0, abs: 0 })
  })

  it('reads a null bound as absent, never as a declared 0', () => {
    // Non-conforming input — the schema types both bounds as `number` — but a
    // lenient parser must fall through rather than pin the bound at zero.
    expect(resolveTolerance({ rel: 1e-6 }, undefined, { rel: null, abs: 1e-9 })).toEqual({
      rel: 1e-6,
      abs: 1e-9,
    })
  })

  it('merges the implementation default as a fourth level, per field', () => {
    // Nothing declared anywhere: both fields reach level 4.
    expect(resolveTolerance(undefined, undefined, undefined)).toEqual({
      rel: DEFAULT_REL_TOL,
      abs: 0,
    })
    expect(resolveTolerance({}, {}, {})).toEqual({ rel: DEFAULT_REL_TOL, abs: 0 })
    // Only `abs` declared: `rel` falls through to the default like any other
    // undeclared field, rather than the assertion running with no relative
    // bound at all.
    expect(resolveTolerance(undefined, undefined, { abs: 1e-4 })).toEqual({
      rel: DEFAULT_REL_TOL,
      abs: 1e-4,
    })
    // An explicit 0 is how a document turns the relative bound OFF, and level 4
    // must not override it.
    expect(resolveTolerance(undefined, undefined, { rel: 0, abs: 1e-4 })).toEqual({
      rel: 0,
      abs: 1e-4,
    })
  })
})
