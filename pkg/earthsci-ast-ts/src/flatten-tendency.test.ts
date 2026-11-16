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
import { canonicalJson, loadFixture } from './test-helpers.js'
import { loadDocument } from './parse.js'
import type { Expression } from './types.js'

function flattenRtd(fixture: string) {
  return flatten(loadFixture('conformance', 'rhs_time_derivative', 'fixtures', fixture))
}

function rhsOf(fixture: string, lhs: string): Expression {
  const eq = flattenRtd(fixture).equations.find((e) => e.lhs === lhs)
  expect(eq, `no equation defines ${lhs}`).toBeDefined()
  return eq!.rhs
}

const D = (x: unknown) => ({ op: 'D', args: [x], wrt: 't' })
const mul = (...args: unknown[]) => ({ op: '*', args })
const neg = (x: unknown) => ({ op: '-', args: [x] })
const idx = (a: unknown, i: string) => ({ op: 'index', args: [a, i] })
/** A pointwise-lifted `faq` over `lev` with the loop symbol `_p0`. */
const faq = (expr: unknown) => ({
  op: 'faq',
  args: [],
  output_idx: ['_p0'],
  ranges: { _p0: { from: 'lev' } },
  expr,
})

/** Compare two expressions in canonical JSON. */
function expectExpr(actual: unknown, expected: unknown): void {
  expect(canonicalJson(actual)).toEqual(canonicalJson(expected))
}

describe('flatten resolves a right-hand-side structural D (esm-spec §4.2)', () => {
  it.each([
    // Chain rule through an observed's definition.
    ['d_of_observed.esm', 'M.dcombo', mul(mul(neg('M.k'), 'M.x'), 2)],
    // Product rule, with the parameter factor's derivative folded away.
    ['d_of_compound.esm', 'M.dscaled', mul(mul(neg('M.k'), 'M.x'), 'M.scale')],
    // A time-invariant name is the literal 0.
    ['d_of_parameter.esm', 'M.dk', 0],
  ])('%s', (fixture, lhs, want) => {
    expectExpr(rhsOf(fixture, lhs), want)
  })

  it.each([
    // A self-referential tendency: the guard stops the substitution.
    ['d_of_cycle.esm', 'M.dx', mul('M.k', D('M.x'))],
    // `^` is outside the closed set the resolution distributes through.
    ['d_of_unsupported.esm', 'M.dsq', D({ op: '^', args: ['M.x', 2] })],
  ])('%s is left standing', (fixture, lhs, want) => {
    expectExpr(rhsOf(fixture, lhs), want)
  })
})

describe('a lifted state resolves to its lifted right-hand side (esm-libraries-spec §4.7.5 step 3a)', () => {
  // `M.A` reads the [lev] `M.km`, so the whole component `M` lifts onto [lev];
  // `M.B`'s `D(M.A)` is read per cell, `D(index(M.A, _p0))`, and resolves to
  // that cell of `M.A`'s lifted `faq`.
  const doc = {
    esm: '2.2.0',
    metadata: { name: 'percell' },
    index_sets: { lev: { kind: 'interval', size: 3 } },
    models: {
      M: {
        variables: {
          km: { type: 'parameter', units: '1/s', default: 1.0, shape: ['lev'] },
          A: { type: 'unknown', units: '1', default: 1.0 },
          B: { type: 'unknown', units: '1', default: 0.0 },
        },
        equations: [
          {
            lhs: { op: 'D', args: ['A'], wrt: 't' },
            rhs: { op: '*', args: [{ op: '-', args: ['km'] }, 'A'] },
          },
          { lhs: { op: 'D', args: ['B'], wrt: 't' }, rhs: { op: 'D', args: ['A'], wrt: 't' } },
        ],
      },
    },
  }

  it('D(index(x, l)) is that cell of the lifted faq', () => {
    const flat = flatten(loadDocument(doc))
    expect(flat.liftedShapes).toEqual({ 'M.A': [3], 'M.B': [3] })
    const rhsA = faq(mul(neg(idx('M.km', '_p0')), idx('M.A', '_p0')))
    expect(flat.equations).toHaveLength(2)
    expectExpr(flat.equations[0].lhs, faq(D(idx('M.A', '_p0'))))
    expectExpr(flat.equations[0].rhs, rhsA)
    expectExpr(flat.equations[1].lhs, faq(D(idx('M.B', '_p0'))))
    expectExpr(flat.equations[1].rhs, faq(idx(rhsA, '_p0')))
  })
})
