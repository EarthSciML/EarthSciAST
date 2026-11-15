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
  const templates = [
    ...templatesOf(doc.expression_templates),
    ...templatesOf(c.expression_templates),
  ]
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
