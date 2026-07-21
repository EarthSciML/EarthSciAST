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

// Structural ops carry data outside `args`; an expression containing one is a
// structural-tier expression and must be refused.
const STRUCTURAL = new Set([
  'const',
  'true',
  'fn',
  'enum',
  'index',
  'broadcast',
  'integral',
  'table_lookup',
  'apply_expression_template',
  'makearray',
  'reshape',
  'transpose',
  'concat',
  'intersect_polygon',
  'polygon_intersection_area',
  'aggregate',
  'argmin',
  'argmax',
])
function hasStructuralOp(n: unknown): boolean {
  if (!n || typeof n !== 'object') return false
  if (Array.isArray(n)) return n.some(hasStructuralOp)
  const o = n as Record<string, unknown>
  if (typeof o.op === 'string' && STRUCTURAL.has(o.op)) return true
  return Object.values(o).some(hasStructuralOp)
}

describe('parseExpression: reprint idempotence (hand corpus)', () => {
  const corpus: unknown[] = [
    { op: '-', args: [{ op: '*', args: ['k1', 'NO2', 'O2'] }, { op: '*', args: ['k2', 'O3'] }] },
    // Arrhenius A * exp(-Ea / (R * T)) — unary minus over a whole quotient
    {
      op: '*',
      args: [
        'A',
        { op: 'exp', args: [{ op: '-', args: [{ op: '/', args: ['Ea', { op: '*', args: ['R', 'T'] }] }] }] },
      ],
    },
    { op: '*', args: ['r', 'N', { op: '-', args: [1, { op: '/', args: ['N', 'K'] }] }] },
    { op: '^', args: ['a', { op: '^', args: ['b', 'c'] }] }, // right-assoc
    { op: '^', args: [{ op: '/', args: [300, 'T'] }, -1.3] }, // negative-literal exponent
    { op: '-', args: ['a', { op: '-', args: ['b', 'c'] }] }, // non-assoc parens
    { op: 'D', wrt: 't', args: ['O3'] }, // derivative (the `/Dt` form)
    { op: 'atan2', args: ['y', 'x'] },
    { op: 'ifelse', args: [{ op: '>', args: ['x', 0] }, 'a', 'b'] },
    { op: 'or', args: [{ op: 'and', args: ['p', 'q'] }, { op: 'not', args: ['r'] }] },
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
    expect(parseExpression('a^(b^c)')).toEqual({ op: '^', args: ['a', { op: '^', args: ['b', 'c'] }] })
    expect(parseExpression('(a + b) * c')).toEqual({ op: '*', args: [{ op: '+', args: ['a', 'b'] }, 'c'] })
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

describe('structural tier is refused', () => {
  for (const s of ['aggregate(x)', 'table_lookup(a)', 'integral(f, x, 0, 1)', 'const(3)', 'a[0]', 'datetime.year(t)']) {
    it(`refuses ${s}`, () => {
      expect(() => parseExpression(s)).toThrow(ExpressionParseError)
    })
  }
})

describe('malformed input reports a position', () => {
  for (const s of ['k * ', 'a b', '(a + b']) {
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
