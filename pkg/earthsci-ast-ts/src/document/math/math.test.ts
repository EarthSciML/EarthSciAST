/**
 * Tests of the math layer: the checks of `HandWritten.lean`, the unit typeset
 * round trip, and the math of every expression case of the document-format
 * golden set (port of the Rust binding's `document/math/tests.rs`).
 */

import { describe, expect, it } from 'vitest'
import { fromPlain, jarr, jint, jobj, jstr, type Json } from '../json.js'
import { losslessJsonParse } from '../../numeric-literal.js'
import { readFixture } from '../../test-helpers.js'
import { parseLatex, parseTypst, printLatex, printTypst, type Sym } from './index.js'
import { render as latexRender } from './latex.js'
import { dNode } from './parse.js'
import { keyToks, mkNode, node } from './print.js'
import {
  latex as unitsLatex,
  parseLatex as unitsParseLatex,
  parseTypst as unitsParseTypst,
  rat,
  typst as unitsTypst,
  type Factor,
} from './units.js'

const sym = (names: string[]): Sym => ({ names, templates: [] })
const int = (z: number): Json => jint(z)
const s = (x: string): Json => jstr(x)

// ## HandWritten.lean

const hw = (): Sym => sym(['x', 'k', 'a', 'T', 'n', 'N'])

function readsL(sy: Sym, text: string, e: Json): void {
  expect(parseLatex(sy, text), `LaTeX ${JSON.stringify(text)}`).toEqual(e)
}

function readsT(sy: Sym, text: string, e: Json): void {
  expect(parseTypst(sy, text), `Typst ${JSON.stringify(text)}`).toEqual(e)
}

describe('math: HandWritten.lean', () => {
  it('minus and negative literals', () => {
    const sy = hw()
    const [x, k, a] = [s('x'), s('k'), s('a')]
    const xm1 = node('-', [x, int(1)])
    readsL(sy, 'x-1', xm1)
    readsL(sy, 'x - 1', xm1)
    readsL(sy, 'x -1', xm1)
    readsL(sy, '-1', int(-1))
    readsL(sy, '2-x', node('-', [int(2), x]))
    readsL(sy, 'k-1-x', node('-', [node('-', [k, int(1)]), x]))
    readsL(sy, 'a \\cdot -1', node('*', [a, int(-1)]))
    readsL(sy, 'a\\cdot-1', node('*', [a, int(-1)]))
    readsL(sy, 'x^{-1}', node('^', [x, int(-1)]))
    readsL(sy, 'x = -1', node('==', [x, int(-1)]))
    readsL(sy, 'k-2x', node('-', [k, node('*', [int(2), x])]))
    readsL(sy, 'k-0', node('-', [k, int(0)]))

    readsT(sy, 'x-1', xm1)
    readsT(sy, 'x - 1', xm1)
    readsT(sy, '-1', int(-1))
    readsT(sy, '2-x', node('-', [int(2), x]))
    readsT(sy, 'a dot -1', node('*', [a, int(-1)]))
    readsT(sy, 'x^(-1)', node('^', [x, int(-1)]))
  })

  it('scientific literals', () => {
    const sy = hw()
    const th = int(2000)
    const tiny: Json = { t: 'num', n: { k: 'dec', neg: false, digits: [1, 5], e10: -12 } }
    for (const t of [
      '2 \\times 10^{3}',
      '2\\times 10^{3}',
      '2\\times10^{3}',
      '2  \\times  10^{3}',
      '2 \\times 10 ^ { 3 }',
    ]) {
      readsL(sy, t, th)
    }
    readsL(sy, '1.5\\times 10^{-12}', tiny)
    readsL(sy, '1.5 \\times 10^{-12}', tiny)
    const p = node('*', [int(3), node('^', [int(10), s('n')])])
    readsL(sy, '3 \\times 10^{n}', p)
    for (const t of ['2 times 10^3', '2times 10^3', '2 times 10^( 3 )']) readsT(sy, t, th)
    readsT(sy, '1.5 times 10^(-12)', tiny)
    readsT(sy, '1.5times 10 ^ (-12)', tiny)
    readsT(sy, '3 times 10^n', p)
  })

  it('thin space', () => {
    const sy = hw()
    const meters = jobj([
      ['args', jarr([])],
      ['op', s('const')],
      ['units', s('m')],
      ['value', int(3)],
    ])
    readsL(sy, '3\\,\\mathrm{m}', meters)
    readsL(sy, '3 \\, \\mathrm{m}', meters)
    readsL(sy, 'k\\,T', node('*', [s('k'), s('T')]))
    readsL(sy, 'k \\, T', node('*', [s('k'), s('T')]))
    readsT(sy, '3 thin upright("m")', meters)
  })

  it('italic d', () => {
    const sd = sym(['x'])
    const sdx = sym(['x', 'dx', 'dt'])
    const sdx1 = sym(['x', 'dx'])
    const dx = dNode(s('x'), 't')
    readsL(sd, '\\frac{dx}{dt}', dx)
    readsL(sd, '\\frac{d x}{d t}', dx)
    readsT(sd, '(d x)/(d t)', dx)
    const q = node('/', [s('dx'), s('dt')])
    readsL(sdx, '\\frac{dx}{dt}', q)
    readsT(sdx, '(dx)/(dt)', q)
    expect(parseLatex(sdx1, '\\frac{dx}{dt}')).toBeUndefined()
  })

  it('field keys', () => {
    const sy = hw()
    expect(latexRender(keyToks('latex', 'a%b$'))).toBe('\\mathrm{a{\\char037}b{\\char036}}')
    readsL(
      sy,
      '\\operatorname{foo}(x; \\mathrm{a{\\char037}b} = 1)',
      mkNode('foo', [s('x')], [['a%b', int(1)]]),
    )
    const odd = jobj([
      ['a%b$', int(1)],
      ['args', jarr([s('x')])],
      ['op', s('foo')],
    ])
    const p = printLatex(sy, odd)
    expect(p.includes('%') || p.includes('$'), p).toBe(false)
    readsL(sy, p, odd)
  })

  it('JSON strings', () => {
    const sy = hw()
    const strOp = mkNode('myop', [s('k')], [['s', s('a{b}')]])
    expect(printLatex(sy, strOp)).toBe('\\operatorname{myop}(k; \\mathrm{s} = \\text{"a\\{b\\}"})')
    readsL(sy, printLatex(sy, strOp), strOp)
    const odd = mkNode('myop', [s('k')], [['s', s('x$%é\n"_~\\ 中')]])
    expect(printLatex(sy, odd)).toBe(
      '\\operatorname{myop}(k; \\mathrm{s} = \\text{"x{\\char036}{\\char037}{\\char233}{\\char010}"\\_{\\char126}{\\char092} {\\char0020013}"})',
    )
    readsL(sy, printLatex(sy, odd), odd)
    readsL(sy, '\\operatorname{myop}(k; \\mathrm{s} = "a\\u007Bb\\u007D")', strOp)
  })
})

describe('math: unit typesetting', () => {
  it('LaTeX and Typst round trip', () => {
    const f = (sy: string, p: number, q: number): Factor => [sy, rat(BigInt(p), BigInt(q))]
    const l = [f('cm', 3, 1), f('short_ton', 1, 3), f('K', -1, 1), f('mol', -1, 2)]
    expect(unitsLatex(l)).toBe('\\mathrm{cm^{3}\\,short\\_ton^{1/3}/(K\\,mol^{1/2})}')
    expect(unitsParseLatex(Array.from(unitsLatex(l)))).toEqual(l)
    expect(unitsTypst(l)).toBe(
      'upright("cm")^3 thin upright("short_ton")^(1\\/3) thin upright("K")^(-1) thin upright("mol")^(-1\\/2)',
    )
    expect(unitsParseTypst(Array.from(unitsTypst(l)))).toEqual(l)
    expect(unitsParseTypst(['1'])).toEqual([])
  })
})

// ## The golden set

type Plain = Record<string, unknown>

const isObj = (v: unknown): v is Plain => typeof v === 'object' && v !== null && !Array.isArray(v)

function keysOf(v: unknown): string[] {
  return isObj(v) ? Object.keys(v) : []
}

function templatesOf(v: unknown): [string, string[]][] {
  if (!isObj(v)) return []
  const out: [string, string[]][] = []
  for (const [k, t] of Object.entries(v)) {
    if (!isObj(t)) continue
    const ps = Array.isArray(t.params)
      ? t.params.filter((x): x is string => typeof x === 'string')
      : []
    out.push([k, ps])
  }
  return out
}

/**
 * The symbol table of the one component of a fixture document and its one
 * equation, as `Source.symFor` and `Source.eqExpr` build them.
 */
function component(doc: Plain): [Sym, Json] {
  const comps: Plain[] = []
  for (const key of ['models', 'reaction_systems']) {
    const m = doc[key]
    if (isObj(m)) for (const c of Object.values(m)) comps.push(c as Plain)
  }
  expect(comps.length).toBe(1)
  const c = comps[0]
  const names = [
    ...keysOf(c.variables),
    ...keysOf(c.species),
    ...keysOf(c.parameters),
    ...keysOf(doc.index_sets),
  ]
  const templates = [...templatesOf(doc.operators), ...templatesOf(c.operators)]
  const eq = (c.equations as Plain[])[0]
  const e = jobj([
    ['args', jarr([fromPlain(eq.lhs), fromPlain(eq.rhs)])],
    ['op', jstr('==')],
  ])
  return [{ names, templates }, e]
}

describe('math: the golden set', () => {
  it('prints and reads the math of every expression case', () => {
    const failures: string[] = []
    let n = 0
    for (const file of ['operators', 'names', 'units']) {
      const v = losslessJsonParse(
        readFixture('conformance', 'document_format', `${file}.json`),
      ) as Plain
      for (const cs of v.cases as Plain[]) {
        const math = cs.math as Plain | undefined
        if (math === undefined) continue
        n++
        const id = cs.id as string
        const [sy, e] = component(cs.esm as Plain)
        const lx = math.latex as string
        const ty = math.typst as string
        const pl = printLatex(sy, e)
        if (pl !== lx) failures.push(`${id}: printLatex\n  got  ${pl}\n  want ${lx}`)
        const bl = parseLatex(sy, lx)
        if (bl === undefined || JSON.stringify(bl, big) !== JSON.stringify(e, big)) {
          failures.push(`${id}: parseLatex ${lx}\n  got ${JSON.stringify(bl, big)}`)
        }
        const pt = printTypst(sy, e)
        if (pt !== ty) failures.push(`${id}: printTypst\n  got  ${pt}\n  want ${ty}`)
        const bt = parseTypst(sy, ty)
        if (bt === undefined || JSON.stringify(bt, big) !== JSON.stringify(e, big)) {
          failures.push(`${id}: parseTypst ${ty}\n  got ${JSON.stringify(bt, big)}`)
        }
      }
    }
    expect(n).toBeGreaterThanOrEqual(79)
    expect(failures, `${failures.length} of ${n} cases fail:\n${failures.join('\n')}`).toEqual([])
  })
})

function big(_k: string, v: unknown): unknown {
  return typeof v === 'bigint' ? `${v}n` : v
}

// ## Array notation: canonical-only reading

describe('math: array notation reads only what it prints', () => {
  const sy = sym(['S', 'w', 'v', 'C', 'f', 'g', 'N', 'x', 'k', 'delim', 'augment'])
  const roundL = (text: string): void => {
    const e = parseLatex(sy, text)
    expect(e, text).toBeDefined()
    expect(printLatex(sy, e as Json)).toBe(text)
  }
  const roundT = (text: string): void => {
    const e = parseTypst(sy, text)
    expect(e, text).toBeDefined()
    expect(printTypst(sy, e as Json)).toBe(text)
  }

  it('a \\limits head carries no superscript set', () => {
    roundL('\\sum\\limits_{i \\in S} w_{i}')
    expect(parseLatex(sy, '\\sum\\limits_{i \\in S}^{\\{w\\}} w_{i}')).toBeUndefined()
    expect(parseTypst(sy, 'limits(sum)_(i in S)^({w}) w_i')).toBeUndefined()
    expect(
      parseLatex(sy, '\\left[\\sum\\limits_{i \\in S} w_{i} v_{j}\\right]^{\\{w\\}}_{j \\in C}'),
    ).toBeUndefined()
  })

  it('a wrapped reduction has its set on the bracket only', () => {
    const canon =
      '\\left[\\sum\\left(f_{i + 1} - f_{i}\\right)\\right]^{\\{f, g\\}}_{2 \\le i \\le N - 1}'
    roundL(canon)
    // inner set only
    expect(
      parseLatex(
        sy,
        '\\left[\\sum^{\\{f, g\\}}\\left(f_{i + 1} - f_{i}\\right)\\right]_{2 \\le i \\le N - 1}',
      ),
    ).toBeUndefined()
    // inner and outer set
    expect(
      parseLatex(
        sy,
        '\\left[\\sum^{\\{f\\}}\\left(f_{i + 1} - f_{i}\\right)\\right]^{\\{f, g\\}}_{2 \\le i \\le N - 1}',
      ),
    ).toBeUndefined()
  })

  it('delim and augment are ordinary words in Typst', () => {
    readsT(sy, 'delim + 1', node('+', [s('delim'), int(1)]))
    expect(parseTypst(sy, '(d augment)/(d t)')).toBeDefined()
    roundT('(dif italic("augment"))/(dif t)')
    roundT('italic("augment") + italic("delim")')
    roundT('mat(delim: "[", augment: #1, 0, [1, 2] times [1, 3])_(i)')
  })

  it('the call form reads only a node the printer writes in it', () => {
    roundL('\\operatorname{foo}(x; \\mathrm{a} = 1)')
    roundL('\\operatorname{const}(; \\mathrm{value} = 2)')
    // An annotated core operator prints in the escape form.
    expect(
      parseLatex(sy, '\\operatorname{const}(; \\mathrm{id} = \\text{"n1"}, \\mathrm{value} = 2)'),
    ).toBeUndefined()
    expect(
      parseLatex(
        sy,
        '\\operatorname{const}(; \\mathrm{expect\\_cadence} = \\text{"const"}, \\mathrm{value} = 2)',
      ),
    ).toBeUndefined()
    expect(
      parseTypst(sy, 'op("const")(; upright("id") = #"n1", upright("value") = #2)'),
    ).toBeUndefined()
    // An open operator keeps its annotation fields in the call form.
    roundL('\\operatorname{foo}(x; \\mathrm{id} = \\mathit{n1})')
    readsL(
      sy,
      '\\operatorname{foo}(x; \\mathrm{id} = \\text{"n1"})',
      mkNode('foo', [s('x')], [['id', s('n1')]]),
    )
    // A field key repeats, or names the node's own `op` / `args`.
    expect(
      parseLatex(sy, '\\operatorname{foo}(x; \\mathrm{a} = 1, \\mathrm{a} = 2)'),
    ).toBeUndefined()
    expect(parseLatex(sy, '\\operatorname{foo}(x; \\mathrm{op} = 1)')).toBeUndefined()
    expect(parseLatex(sy, '\\operatorname{foo}(x; \\mathrm{args} = 1)')).toBeUndefined()
    expect(parseTypst(sy, 'op("foo")(x; upright("a") = 1, upright("a") = 2)')).toBeUndefined()
    // A constant array has a native spelling, so its call form is refused.
    expect(parseLatex(sy, '\\operatorname{const}(; \\mathrm{value} = [1, 2])')).toBeUndefined()
    // So does a makearray table.
    const mk = parseLatex(
      sy,
      '\\left[\\begin{array}{l|l} 0 & [1, 2] \\end{array}\\right]_{i}',
    ) as Json
    expect(mk).toBeDefined()
    expect(printLatex(sy, mk).startsWith('\\left[')).toBe(true)
    expect(
      parseLatex(
        sy,
        '\\operatorname{makearray}(; \\mathrm{output\\_idx} = [\\text{"i"}], \\mathrm{regions} = [[[1, 2]]], \\mathrm{values} = [0])',
      ),
    ).toBeUndefined()
    // With no region the table has no native spelling: the call form reads.
    roundL('\\operatorname{makearray}(; \\mathrm{regions} = [], \\mathrm{values} = [])')
    // Field keys are read in any spelling; the printer escapes this node.
    const pct = mkNode('foo', [s('x')], [['a%b', int(1)]])
    readsL(sy, '\\operatorname{foo}(x; \\mathrm{a{\\char037}b} = 1)', pct)
    expect(printLatex(sy, pct)).toBe('\\esm{foo}{{\\text{"a{\\char037}b"}: 1}}{x}')
    readsL(sy, printLatex(sy, pct), pct)
  })

  it('a bare template name is refused when it is in scope with no parameters', () => {
    const t0 = jobj([
      ['args', jarr([])],
      ['bindings', jobj([])],
      ['name', s('g0')],
      ['op', s('apply_operator')],
    ])
    const out: Sym = { names: ['x'], templates: [] }
    const zero: Sym = { names: ['x'], templates: [['g0', []]] }
    const one: Sym = { names: ['x'], templates: [['g0', ['p']]] }
    expect(printLatex(out, t0)).toBe('\\operatorname{g0}')
    readsL(out, '\\operatorname{g0}', t0)
    readsL(one, '\\operatorname{g0}', t0)
    expect(printLatex(zero, t0)).toBe('\\operatorname{g0}()')
    readsL(zero, '\\operatorname{g0}()', t0)
    expect(parseLatex(zero, '\\operatorname{g0}')).toBeUndefined()
    expect(parseLatex(zero, '\\operatorname{g0} + x')).toBeUndefined()
    expect(parseTypst(zero, 'op("g0")')).toBeUndefined()
  })

  it('the region product is two tokens', () => {
    roundL('\\left[\\begin{array}{l|l} 0 & [1, 2] \\times [1, 3] \\end{array}\\right]_{i}')
    roundT('mat(delim: "[", augment: #1, 0, [1, 2] times [1, 3])_(i)')
    // Outside a region `\times [` is a product.
    readsL(sy, 'x \\times [k]', node('*', [s('x'), s('k')]))
    readsT(sy, 'x times [k]', node('*', [s('x'), s('k')]))
    readsL(sy, 'x \\times[k]', node('*', [s('x'), s('k')]))
  })

  it('a constant matrix wider than ten columns prints as an array', () => {
    const row = (a: number): Json => jarr(Array.from({ length: 11 }, (_, i) => int(a + i)))
    const m = jobj([
      ['args', jarr([])],
      ['op', s('const')],
      ['value', jarr([row(1), row(12)])],
    ])
    const cells = (a: number): string => Array.from({ length: 11 }, (_, i) => a + i).join(' & ')
    const text = `\\left[\\begin{array}{ccccccccccc}${cells(1)} \\\\ ${cells(12)} \\end{array}\\right]`
    expect(printLatex(sy, m)).toBe(text)
    readsL(sy, text, m)
    expect(printTypst(sy, m)).toBe(
      `mat(${Array.from({ length: 11 }, (_, i) => 1 + i).join(', ')}; ${Array.from({ length: 11 }, (_, i) => 12 + i).join(', ')})`,
    )
    // the column count must match every row and exceed ten
    expect(parseLatex(sy, text.replace('{ccccccccccc}', '{cccccccccccc}'))).toBeUndefined()
    expect(
      parseLatex(sy, '\\left[\\begin{array}{cc}1 & 2 \\\\ 3 & 4 \\end{array}\\right]'),
    ).toBeUndefined()
    // a bmatrix holds at most ten columns
    expect(
      parseLatex(sy, `\\begin{bmatrix}${cells(1)} \\\\ ${cells(12)}\\end{bmatrix}`),
    ).toBeUndefined()
    const ten = jobj([
      ['args', jarr([])],
      ['op', s('const')],
      ['value', jarr([jarr(Array.from({ length: 10 }, (_, i) => int(i)))])],
    ])
    expect(printLatex(sy, ten).startsWith('\\begin{bmatrix}')).toBe(true)
    // with units
    const mu = jobj([
      ['args', jarr([])],
      ['op', s('const')],
      ['units', s('m')],
      ['value', jarr([row(1)])],
    ])
    roundL(printLatex(sy, mu))
  })
})
