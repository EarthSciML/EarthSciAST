/**
 * esm-spec §4.2's right-hand-side `D` resolution, run by `flatten` as
 * esm-libraries-spec §4.7.5 step 3a. The shared flatten corpus pins what the
 * resolution PRODUCES for the own-state, chained, scoped and merged shapes;
 * these pin the remaining rules and what it must leave standing. A cyclic chain
 * is the case that makes the active-name guard load-bearing: without it
 * `flatten` does not fail here, it recurses without end.
 */
import { describe, expect, it } from 'vitest'
import { flatten } from './flatten.js'
import { toAscii } from './pretty-print.js'
import { loadFixture } from './test-helpers.js'
import type { Expression } from './types.js'

function flattenRtd(fixture: string) {
  return flatten(loadFixture('conformance', 'rhs_time_derivative', 'fixtures', fixture))
}

function rhsOf(fixture: string, lhs: string): Expression {
  const eq = flattenRtd(fixture).equations.find((e) => e.lhs === lhs)
  expect(eq, `no equation defines ${lhs}`).toBeDefined()
  return eq!.rhs
}

describe('flatten resolves a right-hand-side structural D (esm-spec §4.2)', () => {
  it.each([
    // Chain rule through an observed's definition.
    ['d_of_observed.esm', 'M.dcombo', '(-M.k) * M.x * 2'],
    // Product rule, with the parameter factor's derivative folded away.
    ['d_of_compound.esm', 'M.dscaled', '(-M.k) * M.x * M.scale'],
    // A time-invariant name is the literal 0.
    ['d_of_parameter.esm', 'M.dk', '0'],
  ])('%s', (fixture, lhs, want) => {
    expect(toAscii(rhsOf(fixture, lhs))).toBe(want)
  })

  it.each([
    // A self-referential tendency: the guard stops the substitution.
    ['d_of_cycle.esm', 'M.dx', 'M.k * D(M.x)/Dt'],
    // `^` is outside the closed set the resolution distributes through.
    ['d_of_unsupported.esm', 'M.dsq', 'D(M.x^2)/Dt'],
  ])('%s is left standing', (fixture, lhs, want) => {
    expect(toAscii(rhsOf(fixture, lhs))).toBe(want)
  })
})
