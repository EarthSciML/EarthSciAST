/**
 * The pointwise lift (esm-spec §10.5, esm-libraries-spec §4.7.5) reads every
 * shaped operand of a lifted right-hand side per cell by index-set NAME
 * (esm-spec §4.3.4), never by position: a lower-rank operand replicates, a
 * permuted one transposes, and an operand on an index set the grid is not
 * shaped over is refused. Mirrors the Rust `pointwise_lift_*` unit tests.
 */
import { describe, expect, it } from 'vitest'
import { applyPointwiseLift, DimensionPromotionError, type FlattenedSystem } from './flatten.js'
import type { CouplingEntry, Expression, ExpressionNode } from './types.js'

/**
 * Lift `D(C) = wrap(<2-D operator makearray over x × y>)`, with the declared
 * index sets x (2), y (3) and z (4) and the given shaped parameters, and return
 * the lifted right-hand side's `faq` body.
 */
function lift2d(
  wrap: (ma: Expression) => Expression,
  shapes: Record<string, string[]>,
): Expression {
  const makearray = {
    op: 'makearray',
    args: [],
    regions: [
      [
        [1, 2],
        [1, 3],
      ],
    ],
    values: [{ op: 'index', args: ['C', 'i', 'j'] }],
  } as unknown as ExpressionNode
  const parameters: Record<string, unknown> = {}
  for (const [name, shape] of Object.entries(shapes))
    parameters[name] = { type: 'parameter', shape }
  const flat = {
    equations: [
      {
        lhs: { op: 'D', args: ['C'], wrt: 't' },
        rhs: wrap(makearray),
        sourceSystem: 'M',
        contributions: [],
      },
    ],
    stateVariables: { C: { type: 'state' } },
    parameters,
    observedVariables: {},
    indexSets: {
      x: { kind: 'interval', size: 2 },
      y: { kind: 'interval', size: 3 },
      z: { kind: 'interval', size: 4 },
    },
    liftedShapes: {},
  } as unknown as FlattenedSystem
  const coupling = [
    { type: 'operator_compose', lifting: 'pointwise' },
  ] as unknown as CouplingEntry[]
  applyPointwiseLift(flat, coupling)
  expect(flat.liftedShapes).toEqual({ C: [2, 3] })
  expect(flat.stateVariables.C.shape).toEqual(['x', 'y'])
  const rhs = flat.equations[0].rhs as unknown as { op: string; expr: Expression }
  expect(rhs.op).toBe('faq')
  return rhs.expr
}

/** `makearray / <operand>`. */
const over =
  (operand: Expression) =>
  (ma: Expression): Expression => ({ op: '/', args: [ma, operand] })

/** The divisor of a lifted `makearray / <operand>` body. */
const divisor = (body: Expression): Expression => (body as ExpressionNode).args![1]

describe('pointwise lift gathers shaped operands by index-set name (esm-spec §4.3.4)', () => {
  // A variable already on the lift grid is read per cell inside the lifted body.
  it('indexes an operand shaped exactly as the grid', () => {
    expect(divisor(lift2d(over('m'), { m: ['x', 'y'] }))).toEqual({
      op: 'index',
      args: ['m', 'i', 'j'],
    })
  })

  // A lower-rank operand is read at the loops of its own index sets and
  // replicates along the rest, rather than taking every loop positionally.
  it('gathers a lower-rank operand by name', () => {
    expect(divisor(lift2d(over('p'), { p: ['y'] }))).toEqual({ op: 'index', args: ['p', 'j'] })
  })

  // A permuted shape transposes: `[y, x]` is read at `(j, i)`, not `(i, j)`.
  it('gathers a permuted operand by name', () => {
    expect(divisor(lift2d(over('m'), { m: ['y', 'x'] }))).toEqual({
      op: 'index',
      args: ['m', 'j', 'i'],
    })
  })

  // An axis the grid is not shaped over has no loop to read it at.
  it.each([[['x', 'z']], [['z']]])('refuses an operand on a foreign index set: %j', (shape) => {
    const run = (): unknown => lift2d(over('f'), { f: shape })
    expect(run).toThrow(DimensionPromotionError)
    expect(run).toThrow(/'f'/)
    expect(run).toThrow(/index set 'z'/)
  })

  // A shaped variable sharing no index set with the grid, passed to a closed
  // function, is its whole-array argument and stays bare; a grid operand beside
  // it is still read per cell.
  it('leaves a whole-array fn argument bare', () => {
    const call = { op: 'fn', name: 'interp.searchsorted', args: ['p', 'table'] } as ExpressionNode
    const lifted = divisor(lift2d(over(call), { p: ['x'], table: ['z'] })) as ExpressionNode
    expect(lifted.args![0]).toEqual({ op: 'index', args: ['p', 'i'] })
    expect(lifted.args![1]).toBe('table')
  })

  // A whole-array shape op has no per-cell reading of its operand.
  it('refuses an operand of a whole-array op', () => {
    const reshaped = { op: 'reshape', args: ['m'], shape: [6] } as unknown as ExpressionNode
    const run = (): unknown => lift2d(over(reshaped), { m: ['x', 'y'] })
    expect(run).toThrow(DimensionPromotionError)
    expect(run).toThrow(/'m'.*'reshape'/s)
  })
})
