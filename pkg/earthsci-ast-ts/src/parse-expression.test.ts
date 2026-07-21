/**
 * Tests for parse-expression: the inverse of toAscii for the scalar tier.
 *
 * Core property is REPRINT IDEMPOTENCE: `toAscii(parse(toAscii(ast))) ===
 * toAscii(ast)`, which is robust to the printer not being injective (flat vs.
 * nested `+`, `-(a*b)` vs `(-a)*b`, which reprint identically). It is asserted
 * on a hand corpus and on every scalar-tier entry of the shared display
 * fixtures; structural-tier fixtures are asserted to be REFUSED.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'fs'
import { join } from 'path'
import { toAscii } from './pretty-print.js'
import { parseExpression, parseEquation, ExpressionParseError } from './parse-expression.js'

const reprint = (ast: unknown) => toAscii(ast as never)

// Structural ops with no text surface yet — an expression containing one is
// still refused. (const/true/fn/index/integral/reshape/transpose/concat and the
// whole reduction & array-query tier — aggregate/argmin/argmax/
// apply_expression_template/polygon_intersection_area/makearray — DO have a
// surface now and are handled below.)
const STRUCTURAL = new Set(['enum', 'broadcast', 'table_lookup', 'intersect_polygon'])
function hasStructuralOp(n: unknown): boolean {
  if (!n || typeof n !== 'object') return false
  if (Array.isArray(n)) return n.some(hasStructuralOp)
  const o = n as Record<string, unknown>
  if (typeof o.op === 'string' && STRUCTURAL.has(o.op)) return true
  return Object.values(o).some(hasStructuralOp)
}

describe('parseExpression: reprint idempotence (hand corpus)', () => {
  const corpus: unknown[] = [
    {
      op: '-',
      args: [
        { op: '*', args: ['k1', 'NO2', 'O2'] },
        { op: '*', args: ['k2', 'O3'] },
      ],
    },
    // Arrhenius A * exp(-Ea / (R * T)) — unary minus over a whole quotient
    {
      op: '*',
      args: [
        'A',
        {
          op: 'exp',
          args: [{ op: '-', args: [{ op: '/', args: ['Ea', { op: '*', args: ['R', 'T'] }] }] }],
        },
      ],
    },
    { op: '*', args: ['r', 'N', { op: '-', args: [1, { op: '/', args: ['N', 'K'] }] }] },
    { op: '^', args: ['a', { op: '^', args: ['b', 'c'] }] }, // right-assoc
    { op: '^', args: [{ op: '/', args: [300, 'T'] }, -1.3] }, // negative-literal exponent
    { op: '-', args: ['a', { op: '-', args: ['b', 'c'] }] }, // non-assoc parens
    { op: 'D', wrt: 't', args: ['O3'] }, // derivative (the `/Dt` form)
    { op: 'atan2', args: ['y', 'x'] },
    { op: 'ifelse', args: [{ op: '>', args: ['x', 0] }, 'a', 'b'] },
    {
      op: 'or',
      args: [
        { op: 'and', args: ['p', 'q'] },
        { op: 'not', args: ['r'] },
      ],
    },
    { op: 'div', args: ['u'] }, // open-tier op → generic call
    0.0004,
    'Emissions.NO', // qualified variable reference
  ]
  for (const ast of corpus) {
    it(`round-trips ${reprint(ast)}`, () => {
      expect(reprint(parseExpression(reprint(ast)))).toBe(reprint(ast))
    })
  }
})

describe('parseExpression: expected ASTs', () => {
  it('flattens n-ary products and keeps binary minus', () => {
    expect(parseExpression('k1 * NO2 * O2 - k2 * O3')).toEqual({
      op: '-',
      args: [
        { op: '*', args: ['k1', 'NO2', 'O2'] },
        { op: '*', args: ['k2', 'O3'] },
      ],
    })
  })
  it('respects precedence and right-associativity', () => {
    expect(parseExpression('a^(b^c)')).toEqual({
      op: '^',
      args: ['a', { op: '^', args: ['b', 'c'] }],
    })
    expect(parseExpression('(a + b) * c')).toEqual({
      op: '*',
      args: [{ op: '+', args: ['a', 'b'] }, 'c'],
    })
  })
  it('lowers both derivative spellings to the same node', () => {
    const d = { op: 'D', wrt: 't', args: ['O3'] }
    expect(parseExpression('D(O3)/Dt')).toEqual(d)
    expect(parseExpression('D(O3, t)')).toEqual(d)
  })
})

describe('parseEquation', () => {
  it('splits on the top-level lone =', () => {
    expect(parseEquation('D(x)/Dt = k * A - x')).toEqual({
      lhs: { op: 'D', wrt: 't', args: ['x'] },
      rhs: { op: '-', args: [{ op: '*', args: ['k', 'A'] }, 'x'] },
    })
  })
  it('keeps == as a comparison on a side', () => {
    expect(parseEquation('y = ifelse(x == 0, a, b)')).toEqual({
      lhs: 'y',
      rhs: { op: 'ifelse', args: [{ op: '==', args: ['x', 0] }, 'a', 'b'] },
    })
  })
})

describe('array & call-shaped tier: reconstructs exact node shapes', () => {
  it('array literals → const', () => {
    expect(parseExpression('[1, 2, 3]')).toEqual({ op: 'const', value: [1, 2, 3], args: [] })
    expect(parseExpression('[[1, 2], [3, 4]]')).toEqual({
      op: 'const',
      value: [
        [1, 2],
        [3, 4],
      ],
      args: [],
    })
  })
  it('subscripts → index', () => {
    expect(parseExpression('u[i, j]')).toEqual({ op: 'index', args: ['u', 'i', 'j'] })
  })
  it('dotted calls → fn (closed function)', () => {
    expect(parseExpression('datetime.year(t)')).toEqual({
      op: 'fn',
      name: 'datetime.year',
      args: ['t'],
    })
  })
  it('true literal', () => {
    expect(parseExpression('true')).toEqual({ op: 'true', args: [] })
  })
  it('integral / reshape / transpose / concat', () => {
    expect(parseExpression('integral(f, x, 0, 1)')).toEqual({
      op: 'integral',
      args: ['f'],
      var: 'x',
      lower: 0,
      upper: 1,
    })
    expect(parseExpression('reshape(a, [3, 4])')).toEqual({
      op: 'reshape',
      args: ['a'],
      shape: [3, 4],
    })
    expect(parseExpression('transpose(a)')).toEqual({ op: 'transpose', args: ['a'] })
    expect(parseExpression('transpose(a, [1, 0])')).toEqual({
      op: 'transpose',
      args: ['a'],
      perm: [1, 0],
    })
    expect(parseExpression('concat(a, b, axis=0)')).toEqual({
      op: 'concat',
      args: ['a', 'b'],
      axis: 0,
    })
  })
})

describe('reduction & array-query tier: reconstructs exact node shapes', () => {
  it('plain sum with a numeric range and a from-set', () => {
    expect(parseExpression('sum[i] (i * j) where {i in 1:2, j in faces}')).toEqual({
      op: 'aggregate',
      output_idx: ['i'],
      ranges: { i: [1, 2], j: { from: 'faces' } },
      expr: { op: '*', args: ['i', 'j'] },
      args: [],
    })
  })
  it('from(of…) range and index-base arg derivation', () => {
    expect(parseExpression('sum[i] (u[i, k]) where {i in cells, k in edges_of_cell(i)}')).toEqual({
      op: 'aggregate',
      output_idx: ['i'],
      ranges: { i: { from: 'cells' }, k: { from: 'edges_of_cell', of: ['i'] } },
      expr: { op: 'index', args: ['u', 'i', 'k'] },
      args: ['u'],
    })
  })
  it('symbol selects reduce; empty output index', () => {
    expect(parseExpression('min[i] (a[i]) where {i in cells}')).toEqual({
      op: 'aggregate',
      output_idx: ['i'],
      reduce: 'min',
      ranges: { i: { from: 'cells' } },
      expr: { op: 'index', args: ['a', 'i'] },
      args: ['a'],
    })
    expect(parseExpression('sum[] (u[i]) where {i in cells}')).toEqual({
      op: 'aggregate',
      output_idx: [],
      ranges: { i: { from: 'cells' } },
      expr: { op: 'index', args: ['u', 'i'] },
      args: ['u'],
    })
  })
  it('explicit [semiring=…] supersedes the symbol', () => {
    expect(
      parseExpression('max[i] (i * j) where {i in 1:2, j in options} [semiring=max_product]'),
    ).toEqual({
      op: 'aggregate',
      output_idx: ['i'],
      semiring: 'max_product',
      ranges: { i: [1, 2], j: { from: 'options' } },
      expr: { op: '*', args: ['i', 'j'] },
      args: [],
    })
  })
  it('join implies sum_product; join names + index bases feed args', () => {
    expect(
      parseExpression(
        'sum[j] (A[i, j]) where {i in src, j in tgt} join(src_bin=tgt_bin) if A[i, j] > atol',
      ),
    ).toEqual({
      op: 'aggregate',
      output_idx: ['j'],
      semiring: 'sum_product',
      ranges: { i: { from: 'src' }, j: { from: 'tgt' } },
      join: [{ on: [['src_bin', 'tgt_bin']] }],
      filter: { op: '>', args: [{ op: 'index', args: ['A', 'i', 'j'] }, 'atol'] },
      expr: { op: 'index', args: ['A', 'i', 'j'] },
      args: ['A', 'src_bin', 'tgt_bin'],
    })
  })
  it('argmin arg-witness', () => {
    expect(parseExpression('argmin[g] (a[g]) where {g in gens}')).toEqual({
      op: 'argmin',
      args: ['a'],
      arg: 'g',
      ranges: { g: { from: 'gens' } },
      expr: { op: 'index', args: ['a', 'g'] },
    })
  })
  it('template application → apply_expression_template', () => {
    expect(parseExpression('arrhenius<A_pre=1.8e-12, Ea=1500>')).toEqual({
      op: 'apply_expression_template',
      args: [],
      name: 'arrhenius',
      bindings: { A_pre: 1.8e-12, Ea: 1500 },
    })
  })
  it('polygon_intersection_area with manifold=', () => {
    expect(parseExpression('polygon_intersection_area(a[i], b[j], manifold=planar)')).toEqual({
      op: 'polygon_intersection_area',
      args: [
        { op: 'index', args: ['a', 'i'] },
        { op: 'index', args: ['b', 'j'] },
      ],
      manifold: 'planar',
    })
  })
  it('distinct + key + [semiring=bool_and_or], and a nested aggregate body', () => {
    const src = 'any[e] (u[f]) where {f in faces} [semiring=bool_and_or]'
    expect(reprint(parseExpression(src))).toBe(src)
    const nested = 'sqrt(sum[] (v[e] * v[e]) where {e in space})'
    expect(reprint(parseExpression(nested))).toBe(nested)
  })
  it('makearray piecewise regions (expr bounds, empty args)', () => {
    expect(
      parseExpression('makearray([2:NLON - 1, 1:NLAT] = a[i, j] / dlon, [1:1, 1:NLAT] = b)'),
    ).toEqual({
      op: 'makearray',
      args: [],
      regions: [
        [
          [2, { op: '-', args: ['NLON', 1] }],
          [1, 'NLAT'],
        ],
        [
          [1, 1],
          [1, 'NLAT'],
        ],
      ],
      values: [{ op: '/', args: [{ op: 'index', args: ['a', 'i', 'j'] }, 'dlon'] }, 'b'],
    })
  })
  it('makearray whose region values are themselves aggregate / template bodies', () => {
    const src =
      'makearray([2:NLON, 1:NLAT] = central_D<f=f>, [1:1, 1:NLAT] = sum[j] (u[1, j]) where {j in lat})'
    expect(reprint(parseExpression(src))).toBe(src)
  })
})

describe('unicode names: ∂/∇ are name characters, big-operators are refused', () => {
  it('parses ∂-in-name variables (a discretized ∂u/∂z field) as plain names', () => {
    // `toAscii` prints such names verbatim (ascii derivatives are `D(x)/Dt`, not
    // `∂`), so `∂`/`∇` in ascii output are always name characters, never operators.
    expect(parseExpression('∂u_∂z^2 + ∂v_∂z^2')).toEqual({
      op: '+',
      args: [
        { op: '^', args: ['∂u_∂z', 2] },
        { op: '^', args: ['∂v_∂z', 2] },
      ],
    })
    const src = 'g / thetaᵥ * ∂thetaᵥ_∂z / S^2'
    expect(reprint(parseExpression(src))).toBe(src)
    expect(parseExpression('∇phi')).toBe('∇phi')
  })
  it('still refuses the unicode big-operator display forms', () => {
    for (const s of ['∑x', '∫f', 'a ∈ b']) {
      expect(() => parseExpression(s)).toThrow(ExpressionParseError)
    }
  })
})

describe('still-deferred structural ops are refused', () => {
  for (const s of ['table_lookup(a)', 'broadcast(y)', 'enum(a, b)']) {
    it(`refuses ${s}`, () => {
      expect(() => parseExpression(s)).toThrow(ExpressionParseError)
    })
  }
})

describe('malformed input reports a position', () => {
  // includes a makearray missing its `[region]` bracket (a body, not a region)
  for (const s of ['k * ', 'a b', '(a + b', 'makearray(x)']) {
    it(`rejects ${JSON.stringify(s)}`, () => {
      expect(() => parseExpression(s)).toThrow(ExpressionParseError)
    })
  }
})

describe('display fixtures: scalar tier round-trips, structural tier is refused', () => {
  const fixtures: Array<{ input: unknown }> = JSON.parse(
    readFileSync(join(process.cwd(), '../../tests/display/all_operators.json'), 'utf8'),
  )
  for (const { input } of fixtures) {
    let printed: string
    try {
      printed = reprint(input)
    } catch {
      continue
    }
    if (hasStructuralOp(input)) {
      it(`refuses structural: ${printed}`, () => {
        expect(() => parseExpression(printed)).toThrow(ExpressionParseError)
      })
    } else {
      it(`round-trips: ${printed}`, () => {
        expect(reprint(parseExpression(printed))).toBe(printed)
      })
    }
  }
})
