/**
 * Pieces the LaTeX and Typst spellings share: literal prefixes, binary operator
 * tokens, and the reading of numbers (a JSON spelling, or a scientific literal
 * `mantissa × 10^exponent` whose tail each surface reads with its own
 * `sciExp`).
 *
 * Port of `formal/Esm/Document/Math/Surface.lean` (after the Rust binding's
 * `document/math/surface.rs`).
 */

import { jnumWfb, type JNum } from '../json.js'
import { canonize, digitChar, mkDec, parseNum, parseRaw, type Chars, type Read } from '../number.js'
import { kw, tNum, type Tok } from './token.js'

/** `Math.dropP`: the index after the literal prefix `p` at `i`, if it is there. */
export function dropP(p: string, cs: Chars, i: number): number | undefined {
  for (let k = 0; k < p.length; k++) if (cs[i + k] !== p[k]) return undefined
  return i + p.length
}

const BIN: ReadonlySet<string> = new Set([
  'Plus',
  'Eq',
  'Ne',
  'Lt',
  'Gt',
  'Le',
  'Ge',
  'Land',
  'Lor',
  'Cdot',
  'Times',
  'Amp',
  'Nl',
  'Inn',
])

/** `Math.isBin`: the binary operator tokens. */
export function isBin(t: Tok): boolean {
  return t.t === 'kw' && BIN.has(t.k)
}

/** `Number.fracDigits`. */
export const fracDigits = (fp: readonly number[]): readonly number[] => (fp.length === 0 ? [0] : fp)

/**
 * `Math.sciSplit`: the mantissa (with its sign) and exponent of a number printed
 * in scientific notation.
 */
export function sciSplit(n: JNum): [string, number] | undefined {
  if (n.k !== 'dec' || n.digits.length === 0 || !(n.e10 < -4 || 5 < n.e10)) return undefined
  const m =
    (n.neg ? '-' : '') + digitChar(n.digits[0]) + '.' + fracDigits(n.digits.slice(1)).join('')
  return [m, n.e10]
}

/** `Math.negNum`: a number below zero. */
export function negNum(n: JNum): boolean {
  return n.k === 'int' ? n.v < 0n : n.neg
}

/** `Number.natDigits`. */
function natDigits(n: bigint): number[] {
  return Array.from(n.toString(), (c) => c.charCodeAt(0) - 48)
}

const EXP_BOUND = 2n ** 53n

/**
 * `Math.sciNum`: the value of a mantissa times `10^z`, in canonical form.
 *
 * Lean's exponents are unbounded; Rust gives `None` for a decimal exponent
 * outside `i64`, and this port (whose exponents are JavaScript numbers, as in
 * `number.ts`) for one outside `±2^53`. No document writes either.
 */
export function sciNum(n0: JNum, z: bigint): JNum | undefined {
  let m: JNum
  if (n0.k === 'dec') {
    const e = BigInt(n0.e10) + z
    if (e > EXP_BOUND || e < -EXP_BOUND) return undefined
    m = canonize({ k: 'dec', neg: n0.neg, digits: n0.digits, e10: Number(e) })
  } else {
    const ds = natDigits(n0.v < 0n ? -n0.v : n0.v)
    const e = BigInt(ds.length - 1) + z
    if (e > EXP_BOUND || e < -EXP_BOUND) return undefined
    m = canonize(mkDec(n0.v < 0n, ds, Number(e)))
  }
  return jnumWfb(m) ? m : undefined
}

/** A scientific tail reader: the exponent and the index after the tail. */
export type SciExp = (cs: Chars, i: number) => Read<bigint>

/**
 * `Math.lexNum`: a number: its JSON spelling, or a decimal mantissa followed by
 * a scientific tail that `sciExp` reads.
 */
export function lexNum(sciExp: SciExp, cs: Chars, i: number): Read<Tok> {
  const raw = parseRaw(cs, i)
  if (raw === undefined) return undefined
  const plain = (): Read<Tok> => {
    const p = parseNum(cs, i)
    return p && [tNum(p[0]), p[1]]
  }
  const s = sciExp(cs, raw[1])
  if (s === undefined) return plain()
  const m = sciNum(raw[0], s[0])
  return m === undefined ? plain() : [tNum(m), s[1]]
}

/**
 * `Math.lexSigned`: a number where `-` starts it only when the value is below
 * zero (otherwise the `-` is a minus sign of its own).
 */
export function lexSigned(sciExp: SciExp, cs: Chars, i: number): Read<Tok> {
  if (cs[i] !== '-') return lexNum(sciExp, cs, i)
  const r = lexNum(sciExp, cs, i)
  if (r === undefined || r[0].t !== 'num') return undefined
  return negNum(r[0].n) ? r : [kw('Minus'), i + 1]
}
