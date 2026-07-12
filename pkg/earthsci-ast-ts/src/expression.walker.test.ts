import { describe, it, expect } from 'vitest'
import {
  mapChildren,
  forEachChild,
  deepEqualExpr,
  isExprNode,
  EXPRESSION_CHILD_KEYS,
} from './expression.js'
import { intLit, floatLit } from './numeric-literal.js'
import type { Expr, ExprNode } from './types.js'

const identity = (child: Expr): Expr => child

describe('EXPRESSION_CHILD_KEYS', () => {
  it('lists every expression-bearing field in canonical order', () => {
    expect([...EXPRESSION_CHILD_KEYS]).toEqual([
      'args',
      'lower',
      'upper',
      'expr',
      'filter',
      'values',
      'axes',
      'key',
      'bindings',
    ])
  })
})

describe('mapChildren — field preservation', () => {
  it('a no-op map returns a new node deep-equal to the original', () => {
    const node: ExprNode = { op: 'D', args: ['x'], wrt: 't', dim: 'x' }
    const out = mapChildren(node, identity)
    expect(out).not.toBe(node)
    expect(out).toEqual(node)
  })

  it('preserves scalar metadata (units/wrt/dim and unknown fields)', () => {
    // `units` is not a schema field on ExpressionNode, but the walker must
    // copy any unrecognized field through verbatim.
    const node = {
      op: 'D',
      args: ['x'],
      wrt: 't',
      dim: 'x',
      units: 'K/s',
      x_custom: { nested: [1, 2] },
    } as unknown as ExprNode
    expect(mapChildren(node, identity)).toEqual(node)
  })

  it('preserves aggregate structural metadata while visiting expr/filter/key', () => {
    const node: ExprNode = {
      op: 'aggregate',
      args: ['A'],
      expr: { op: '*', args: ['A', 'w'] },
      filter: { op: '>', args: ['A', 0] },
      // `skolem` args are PURE key components — here the bound range symbols
      // `i`, `j` declared in `ranges`, ordinary references the walker never
      // treats as binders. The documentary relation tag lives in `label`.
      key: { op: 'skolem', label: 'edge', args: ['i', 'j'] },
      reduce: '+',
      semiring: 'sum_product',
      ranges: { i: [1, 10], j: { from: 'edges' } },
      join: [{ on: [['i', 'j']] }],
      output_idx: ['i'],
      distinct: false,
    } as unknown as ExprNode
    const out = mapChildren(node, identity)
    expect(out).toEqual(node)
    // Sidecar (non-expression) fields are byte-for-byte preserved.
    const rec = out as unknown as Record<string, unknown>
    expect(rec.reduce).toBe('+')
    expect(rec.semiring).toBe('sum_product')
    expect(rec.ranges).toEqual({ i: [1, 10], j: { from: 'edges' } })
    expect(rec.join).toEqual([{ on: [['i', 'j']] }])
    expect(rec.output_idx).toEqual(['i'])
    // The skolem key round-trips whole: its `label` documentary tag is a sidecar
    // field preserved verbatim, and its `args` (pure components) are unchanged.
    expect(rec.key).toEqual({ op: 'skolem', label: 'edge', args: ['i', 'j'] })
  })

  it('visits integral bounds (lower/upper) and preserves var', () => {
    const node: ExprNode = {
      op: 'integral',
      args: ['f'],
      var: 'x',
      lower: 0,
      upper: { op: '+', args: ['L', 1] },
    } as unknown as ExprNode
    const out = mapChildren(node, identity)
    expect(out).toEqual(node)
    expect((out as unknown as Record<string, unknown>).var).toBe('x')
  })

  it('visits table_lookup axes map and preserves table/output', () => {
    const node: ExprNode = {
      op: 'table_lookup',
      args: [],
      table: 'saturation',
      output: 1,
      axes: { T: { op: '+', args: ['T', 1] }, p: 'pressure' },
    } as unknown as ExprNode
    const out = mapChildren(node, identity)
    expect(out).toEqual(node)
    const rec = out as unknown as Record<string, unknown>
    expect(rec.table).toBe('saturation')
    expect(rec.output).toBe(1)
  })

  it('visits makearray values and preserves regions', () => {
    const node: ExprNode = {
      op: 'makearray',
      args: [],
      regions: [[[1, 5]]],
      values: [{ op: '*', args: ['a', 2] }],
    } as unknown as ExprNode
    const out = mapChildren(node, identity)
    expect(out).toEqual(node)
    expect((out as unknown as Record<string, unknown>).regions).toEqual([[[1, 5]]])
  })

  it('visits apply_expression_template bindings and preserves name', () => {
    const node: ExprNode = {
      op: 'apply_expression_template',
      args: [],
      name: 'arrhenius',
      bindings: { Ea: 100, T: { op: '+', args: ['T', 273] } },
    } as unknown as ExprNode
    const out = mapChildren(node, identity)
    expect(out).toEqual(node)
    expect((out as unknown as Record<string, unknown>).name).toBe('arrhenius')
  })
})

describe('mapChildren — transformation and callback contract', () => {
  it('applies fn once per direct child (one level deep)', () => {
    const node: ExprNode = { op: '+', args: ['x', 'y'] }
    const out = mapChildren(node, (child) =>
      typeof child === 'string' ? child.toUpperCase() : child,
    )
    expect(out).toEqual({ op: '+', args: ['X', 'Y'] })
  })

  it('reports array children with field name and array index', () => {
    const node: ExprNode = { op: '+', args: ['x', 'y', 'z'] }
    const calls: Array<[Expr, string, number | undefined]> = []
    mapChildren(node, (child, key, index) => {
      calls.push([child, key, index])
      return child
    })
    expect(calls).toEqual([
      ['x', 'args', 0],
      ['y', 'args', 1],
      ['z', 'args', 2],
    ])
  })

  it('reports scalar children with field name and no index', () => {
    const node: ExprNode = {
      op: 'integral',
      args: ['f'],
      lower: 0,
      upper: 1,
    } as unknown as ExprNode
    const calls: Array<[Expr, string, number | undefined]> = []
    mapChildren(node, (child, key, index) => {
      calls.push([child, key, index])
      return child
    })
    expect(calls).toEqual([
      ['f', 'args', 0],
      [0, 'lower', undefined],
      [1, 'upper', undefined],
    ])
  })

  it('reports map children with the entry key in sorted order', () => {
    const node: ExprNode = {
      op: 'table_lookup',
      args: [],
      table: 't',
      axes: { z: 'zc', a: 'ac', m: 'mc' },
    } as unknown as ExprNode
    const calls: Array<[Expr, string, number | undefined]> = []
    mapChildren(node, (child, key, index) => {
      calls.push([child, key, index])
      return child
    })
    expect(calls).toEqual([
      ['ac', 'a', 0],
      ['mc', 'm', 1],
      ['zc', 'z', 2],
    ])
  })
})

describe('mapChildren / forEachChild — NumericLiteral leaves', () => {
  it('passes NumericLiteral leaves to fn but never descends into them', () => {
    const lit = intLit(3)
    const node: ExprNode = { op: '+', args: [lit, 'x'] } as unknown as ExprNode
    const seen: Expr[] = []
    forEachChild(node, (child) => {
      seen.push(child)
      // The walker must not treat a leaf as an operator node.
      expect(isExprNode(child)).toBe(false)
    })
    expect(seen).toEqual([lit, 'x'])
    // No-op map keeps the exact leaf reference through the copy.
    const out = mapChildren(node, identity)
    expect((out.args as Expr[])[0]).toBe(lit)
  })
})

describe('forEachChild', () => {
  it('visits every child across args + structural fields in canonical order', () => {
    const node: ExprNode = {
      op: 'aggregate',
      args: ['A', 'B'],
      expr: 'body',
      filter: 'pred',
      key: 'skol',
      values: undefined,
      axes: { b: 'bx', a: 'ax' },
    } as unknown as ExprNode
    const keys: string[] = []
    forEachChild(node, (_child, key) => keys.push(key))
    // args, (lower/upper absent), expr, filter, (values absent), axes sorted, key
    expect(keys).toEqual(['args', 'args', 'expr', 'filter', 'a', 'b', 'key'])
  })

  it('is read-only (does not mutate the node)', () => {
    const node: ExprNode = { op: '+', args: ['x', 'y'] }
    const snapshot = JSON.parse(JSON.stringify(node))
    forEachChild(node, () => {})
    expect(node).toEqual(snapshot)
  })
})

describe('deepEqualExpr', () => {
  it('equates plain numbers with tagged NumericLiteral of the same value', () => {
    expect(deepEqualExpr(1, intLit(1))).toBe(true)
    expect(deepEqualExpr(1, floatLit(1))).toBe(true)
    expect(deepEqualExpr(intLit(1), floatLit(1))).toBe(true)
    expect(deepEqualExpr(intLit(2), floatLit(2))).toBe(true)
  })

  it('distinguishes different numeric values', () => {
    expect(deepEqualExpr(1, 2)).toBe(false)
    expect(deepEqualExpr(intLit(1), floatLit(2))).toBe(false)
  })

  it('handles NaN and signed zero via Object.is', () => {
    expect(deepEqualExpr(NaN, NaN)).toBe(true)
    expect(deepEqualExpr(0, -0)).toBe(false)
  })

  it('compares variable-reference strings by value', () => {
    expect(deepEqualExpr('x', 'x')).toBe(true)
    expect(deepEqualExpr('x', 'y')).toBe(false)
    expect(deepEqualExpr('x', 1)).toBe(false)
  })

  it('distinguishes const nodes by their value field', () => {
    expect(
      deepEqualExpr(
        { op: 'const', args: [], value: 1 } as unknown as ExprNode,
        {
          op: 'const',
          args: [],
          value: 1,
        } as unknown as ExprNode,
      ),
    ).toBe(true)
    expect(
      deepEqualExpr(
        { op: 'const', args: [], value: 1 } as unknown as ExprNode,
        {
          op: 'const',
          args: [],
          value: 2,
        } as unknown as ExprNode,
      ),
    ).toBe(false)
  })

  it('distinguishes derivative nodes by wrt', () => {
    const t: ExprNode = { op: 'D', args: ['x'], wrt: 't' }
    const s: ExprNode = { op: 'D', args: ['x'], wrt: 's' }
    expect(deepEqualExpr(t, { op: 'D', args: ['x'], wrt: 't' })).toBe(true)
    expect(deepEqualExpr(t, s)).toBe(false)
  })

  it('distinguishes nodes by op', () => {
    expect(deepEqualExpr({ op: '+', args: ['x', 'y'] }, { op: '-', args: ['x', 'y'] })).toBe(false)
  })

  it('equates number vs NumericLiteral nested inside args', () => {
    expect(
      deepEqualExpr({ op: '+', args: ['x', 1] }, {
        op: '+',
        args: ['x', intLit(1)],
      } as unknown as ExprNode),
    ).toBe(true)
  })

  it('compares aggregate expression children and structural metadata', () => {
    const base: ExprNode = {
      op: 'aggregate',
      args: ['A'],
      expr: { op: '*', args: ['A', 'w'] },
      filter: { op: '>', args: ['A', 0] },
      reduce: '+',
    } as unknown as ExprNode
    const same: ExprNode = {
      op: 'aggregate',
      args: ['A'],
      expr: { op: '*', args: ['A', 'w'] },
      filter: { op: '>', args: ['A', 0] },
      reduce: '+',
    } as unknown as ExprNode
    expect(deepEqualExpr(base, same)).toBe(true)

    const diffFilter = {
      ...(same as object),
      filter: { op: '>', args: ['A', 1] },
    } as unknown as ExprNode
    expect(deepEqualExpr(base, diffFilter)).toBe(false)

    const diffReduce = { ...(same as object), reduce: '*' } as unknown as ExprNode
    expect(deepEqualExpr(base, diffReduce)).toBe(false)
  })

  it('compares map-valued children (table_lookup axes)', () => {
    const a: ExprNode = {
      op: 'table_lookup',
      args: [],
      table: 't',
      axes: { T: { op: '+', args: ['T', 1] }, p: 'pressure' },
    } as unknown as ExprNode
    const same: ExprNode = {
      op: 'table_lookup',
      args: [],
      table: 't',
      axes: { p: 'pressure', T: { op: '+', args: ['T', 1] } },
    } as unknown as ExprNode
    expect(deepEqualExpr(a, same)).toBe(true)

    const diff: ExprNode = {
      op: 'table_lookup',
      args: [],
      table: 't',
      axes: { T: { op: '+', args: ['T', 2] }, p: 'pressure' },
    } as unknown as ExprNode
    expect(deepEqualExpr(a, diff)).toBe(false)
  })

  it('treats a present-but-extra field as inequality', () => {
    expect(
      deepEqualExpr({ op: '+', args: ['x', 'y'] }, {
        op: '+',
        args: ['x', 'y'],
        id: 'n1',
      } as unknown as ExprNode),
    ).toBe(false)
  })

  it('ignores undefined-valued fields (treated as absent)', () => {
    expect(
      deepEqualExpr({ op: '+', args: ['x', 'y'] }, {
        op: '+',
        args: ['x', 'y'],
        filter: undefined,
      } as unknown as ExprNode),
    ).toBe(true)
  })
})
