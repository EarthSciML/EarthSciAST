/**
 * The canonical number spelling (CONFORMANCE §5.5.3.1).
 *
 * Port of `formal/Esm/Document/Number.lean` (and `Esm.digitChar` from
 * `formal/Esm/Digits.lean`), after the Rust binding's `document/number.rs`.
 *
 * - An integer prints plainly, `-` for a negative one.
 * - A decimal prints its digits positionally when its decimal exponent is in
 *   `[-4, 5]`, and otherwise as `d.f…e<exp>` with at least one fraction digit.
 *
 * {@link parse} reads any decimal spelling and returns the canonical number;
 * {@link parseRaw} reads the token as written.
 *
 * Text is a code point array (`Chars`) read from an index; a reader returns the
 * value and the index after it, or `undefined`.
 */

import { decInt, digitsVal, inInt64, jnumWfb, mkInt, type JNum } from './json.js'

/** A text as its code points. */
export type Chars = readonly string[]

/** A reader's result: the value and the index after it. */
export type Read<T> = [T, number] | undefined

/** The code points of a string. */
export const chars = (s: string): string[] => Array.from(s)

export const isDigitChar = (c: string | undefined): boolean =>
  c !== undefined && c.length === 1 && c >= '0' && c <= '9'

/** `Esm.digitChar`. */
export const digitChar = (d: number): string => String.fromCharCode(48 + d)

/** `Number.printInt`. */
export function printInt(z: bigint): string {
  return z.toString()
}

/** `Number.readDigits`: the maximal run of digit characters at `i`. */
export function readDigits(cs: Chars, i: number): [number[], number] {
  const ds: number[] = []
  while (isDigitChar(cs[i])) ds.push(cs[i++].charCodeAt(0) - 48)
  return [ds, i]
}

/** `Number.parseNat`. */
export function parseNat(cs: Chars, i: number): Read<bigint> {
  const [ds, j] = readDigits(cs, i)
  if (ds.length === 0) return undefined
  return [digitsVal(ds), j]
}

/** `Number.parseInt`: an optional `-`, then digits. */
export function parseIntTok(cs: Chars, i: number): Read<bigint> {
  if (cs[i] === '-') {
    const r = parseNat(cs, i + 1)
    return r && [-r[0], r[1]]
  }
  return parseNat(cs, i)
}

/** `Number.fracDigits`. */
const fracDigits = (fp: readonly number[]): readonly number[] => (fp.length === 0 ? [0] : fp)

/** `Number.decBody`: the unsigned spelling of `d₁.d₂… × 10^e10`. */
export function decBody(ds: readonly number[], e10: number): string {
  if (e10 < -4 || e10 > 5) {
    if (ds.length === 0) return ''
    return `${digitChar(ds[0])}.${fracDigits(ds.slice(1)).join('')}e${e10}`
  }
  if (e10 < 0) return `0.${'0'.repeat(-e10 - 1)}${ds.join('')}`
  const k = e10 + 1
  const head = ds.slice(0, k).join('') + '0'.repeat(Math.max(0, k - ds.length))
  return `${head}.${fracDigits(ds.length > k ? ds.slice(k) : []).join('')}`
}

/** `Number.print`: the canonical spelling of a number. */
export function printNum(n: JNum): string {
  if (n.k === 'int') return printInt(n.v)
  return (n.neg ? '-' : '') + decBody(n.digits, n.e10)
}

/**
 * `Number.mkDec`: the decimal with digits `ds` (leading and trailing zeros
 * dropped) whose first listed digit sits at decimal exponent `e10`.
 */
export function mkDec(neg: boolean, ds: readonly number[], e10: number): JNum {
  let lead = 0
  while (lead < ds.length && ds[lead] === 0) lead++
  let end = ds.length
  while (end > lead && ds[end - 1] === 0) end--
  return { k: 'dec', neg, digits: ds.slice(lead, end), e10: e10 - lead }
}

/** `Number.finishDec`: an optional `e` exponent after the fraction digits. */
function finishDec(
  neg: boolean,
  ds: readonly number[],
  e10: number,
  cs: Chars,
  i: number,
): Read<JNum> {
  if (cs[i] === 'e') {
    const r = parseIntTok(cs, i + 1)
    if (r === undefined) return undefined
    const x = r[0]
    if (x > 2n ** 53n || x < -(2n ** 53n)) return undefined
    return [mkDec(neg, ds, e10 + Number(x)), r[1]]
  }
  return [mkDec(neg, ds, e10), i]
}

/** `Number.afterInt`. */
function afterInt(neg: boolean, ip: readonly number[], cs: Chars, i: number): Read<JNum> {
  if (cs[i] === '.') {
    const [q, j] = readDigits(cs, i + 1)
    if (q.length === 0) return undefined
    return finishDec(neg, [...ip, ...q], ip.length - 1, cs, j)
  }
  const v = digitsVal(ip)
  return [mkInt(neg ? -v : v), i]
}

/** `Number.parseRaw`: a number token as written, not yet canonical. */
export function parseRaw(cs: Chars, i: number): Read<JNum> {
  let neg = false
  if (cs[i] === '-') {
    neg = true
    i++
  }
  const [p, j] = readDigits(cs, i)
  if (p.length === 0 || (p.length > 1 && p[0] === 0)) return undefined
  return afterInt(neg, p, cs, j)
}

/** `Number.canonize`. */
export function canonize(n: JNum): JNum {
  if (n.k === 'int') return n
  if (n.digits.length === 0) return mkInt(0)
  const z = decInt(n.neg, n.digits, n.e10)
  if (typeof z === 'bigint' && inInt64(z)) return mkInt(z)
  return n
}

/** `Number.parse`: a number token, in canonical form. */
export function parseNum(cs: Chars, i: number): Read<JNum> {
  const r = parseRaw(cs, i)
  if (r === undefined) return undefined
  const c = canonize(r[0])
  return jnumWfb(c) ? [c, r[1]] : undefined
}
