/**
 * Multi-line equations (accepted input variants): rows split at top-level line
 * breaks, cells at the first top-level `&`.
 *
 * Port of `formal/Esm/Document/Source/MultiLine.lean` (after the Rust binding's
 * `document/source/multi_line.rs`). The reader works on the math tokens, so rows
 * and cells are found by token and depth.
 */

import { parseToks, type Kw, type Sf, type Sym, type Tok } from '../math/index.js'
import { eqSides } from './equation.js'
import type { Eqn } from './skeleton.js'

const OPENS: ReadonlySet<Kw> = new Set<Kw>([
  'Lp',
  'Lpg',
  'Lb',
  'Lbk',
  'Bcases',
  'Bmat',
  'Lbkg',
  'Barr',
  'TimesLbk',
])
const CLOSES: ReadonlySet<Kw> = new Set<Kw>([
  'Rp',
  'Rpg',
  'Rb',
  'Rbk',
  'Ecases',
  'Emat',
  'Rbkg',
  'Earr',
])

/** `Source.delta`: how a token changes the delimiter depth. */
function delta(t: Tok): number {
  if (t.t !== 'kw') return 0
  return OPENS.has(t.k) ? 1 : CLOSES.has(t.k) ? -1 : 0
}

/** `Source.cut`: the index of the first `k` at depth 0 (from `a` to `b`), or -1. */
function cut(k: Kw, ts: readonly Tok[], a: number, b: number): number {
  let d = 0
  for (let i = a; i < b; i++) {
    const t = ts[i]
    if (d === 0 && t.t === 'kw' && t.k === k) return i
    d += delta(t)
  }
  return -1
}

/** `Source.splitAll`: split at every top-level `k`. */
function splitAll(k: Kw, ts: readonly Tok[]): Tok[][] {
  const out: Tok[][] = []
  let a = 0
  for (;;) {
    const c = cut(k, ts, a, ts.length)
    if (c < 0) {
      out.push(ts.slice(a))
      return out
    }
    out.push(ts.slice(a, c))
    a = c + 1
  }
}

/** `Source.group`: rows into equations (`one`: all rows are one equation). */
function group(one: boolean, rows: readonly Tok[][]): Tok[][] | undefined {
  const acc: Tok[][] = []
  for (const row of rows) {
    const c = cut('Amp', row, 0, row.length)
    if (c < 0) {
      if (row.length === 0) continue
      if (one && acc.length > 0) acc[acc.length - 1].push(...row)
      else acc.push([...row])
      continue
    }
    const l = row.slice(0, c)
    const r = row.slice(c + 1)
    if (cut('Amp', r, 0, r.length) >= 0) return undefined
    if (l.length === 0 && !one) {
      if (acc.length === 0) return undefined
      if (r.length > 0 && r[0].t === 'kw' && r[0].k === 'Eq') return undefined
      acc[acc.length - 1].push(...r)
    } else if (one && acc.length > 0) acc[acc.length - 1].push(...l, ...r)
    else acc.push([...l, ...r])
  }
  return acc
}

/** `Source.cookRows`: read the rows of a multi-line display into equations. */
export function cookRows(sf: Sf, s: Sym, one: boolean, ts: readonly Tok[]): Eqn[] | undefined {
  const eqs = group(one, splitAll('Nl', ts))
  if (eqs === undefined) return undefined
  const out: Eqn[] = []
  for (const t of eqs) {
    const p = parseToks(sf, s, t)
    const sides = p === undefined ? undefined : eqSides(p)
    if (sides === undefined) return undefined
    out.push({ comment: undefined, lhs: sides[0], rhs: sides[1] })
  }
  return out
}
