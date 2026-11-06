/**
 * `circular_dependency` counts only reads of observed or algebraic unknowns
 * (esm-spec §4.9.7). A state's or a parameter's value is known at every
 * right-hand-side evaluation, so a cycle through state reads always has an
 * evaluation order and is not reported.
 */
import { describe, it, expect } from 'vitest'
import { validate } from './validate.js'
import { loadFixture } from './test-helpers.js'

const cycleCodes = (file: ReturnType<typeof loadFixture>) =>
  validate(file).structural_errors.filter((e) => e.code === 'circular_dependency')

describe('circular_dependency (esm-spec §4.9.7)', () => {
  it('reports two models whose observeds read each other', () => {
    const errs = cycleCodes(loadFixture('invalid', 'circular_coupling.esm'))
    expect(errs).toHaveLength(1)
    expect(errs[0].path).toBe('/models')
  })

  it.each(['cross_model_state_reads.esm', 'cross_model_mixing_observed_state_cycle.esm'])(
    'does not report a cycle through state reads (%s)',
    (name) => {
      expect(cycleCodes(loadFixture('valid', name))).toHaveLength(0)
    },
  )
})
