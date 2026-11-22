/**
 * JSON values of an ESM document, in canonical form.
 *
 * Port of `formal/Esm/Document/Json.lean` (and of the Rust binding's
 * `document/json.rs`). The document codecs and the math layer work on this
 * value type, not on plain JavaScript values: numbers are kept in the canonical
 * form of CONFORMANCE §5.5.3.1 (an integral value that fits in Int64 IS an
 * integer; every other finite number is its shortest round-trip decimal digits
 * and the decimal exponent of the first digit), and object entries keep their
 * order. {@link fromPlain} and {@link toPlain} convert at the public boundary.
 *
 * A `math` value is not JSON: it is the math text of an expression inside a
 * path block (`Json.math`), the form a container prints and reads there
 * (`Source.mathify`, `Source.cookBlocks`). It lives only between a container's
 * text and the skeleton; a document never holds one ({@link jsonWfb} is false
 * on it).
 */

import { floatLit, intLit, isNumericLiteral } from '../numeric-literal.js'
import type { Chars, Read } from './number.js'

/**
 * A JSON number in canonical form (`Esm.Document.JNum`).
 *
 * - `int`: an integer literal (well formed when it fits in Int64).
 * - `dec`: the value `±d₁.d₂d₃… × 10^e10`, `digits` its decimal digits.
 */
export type JNum =
  | { readonly k: 'int'; readonly v: bigint }
  | {
      readonly k: 'dec'
      readonly neg: boolean
      readonly digits: readonly number[]
      readonly e10: number
    }

/** A JSON value (`Esm.Document.Json`). Object entries keep their order. */
export type Json =
  | { readonly t: 'null' }
  | { readonly t: 'bool'; readonly v: boolean }
  | { readonly t: 'num'; readonly n: JNum }
  | { readonly t: 'str'; readonly s: string }
  | { readonly t: 'arr'; readonly xs: readonly Json[] }
  | { readonly t: 'obj'; readonly kvs: readonly (readonly [string, Json])[] }
  | { readonly t: 'math'; readonly s: string }

export type JObj = Extract<Json, { t: 'obj' }>
export type Kvs = JObj['kvs']

export const JNULL: Json = Object.freeze({ t: 'null' })
export const JTRUE: Json = Object.freeze({ t: 'bool', v: true })
export const JFALSE: Json = Object.freeze({ t: 'bool', v: false })

export const jbool = (v: boolean): Json => (v ? JTRUE : JFALSE)
export const jstr = (s: string): Json => ({ t: 'str', s })
export const jnum = (n: JNum): Json => ({ t: 'num', n })
export const jint = (v: bigint | number): Json => ({ t: 'num', n: mkInt(v) })
export const jarr = (xs: readonly Json[]): Json => ({ t: 'arr', xs })
export const jobj = (kvs: readonly (readonly [string, Json])[]): Json => ({ t: 'obj', kvs })
export const jmath = (s: string): Json => ({ t: 'math', s })

/**
 * `Json.mathOK`: math text a container can delimit with `$`: not empty, no `$`,
 * no line break, and not ending in a backslash (which would escape the closing
 * `$`).
 */
export function mathOk(s: string): boolean {
  return s !== '' && !s.includes('$') && !s.includes('\n') && !s.includes('\r') && !s.endsWith('\\')
}

/**
 * `Json.pMath`: a math leaf `$…$`, at its `$`: the text up to the next `$`,
 * which must be {@link mathOk}.
 */
export function pMath(cs: Chars, i: number): Read<Json> {
  let j = i + 1
  while (j < cs.length && cs[j] !== '$') j++
  if (j >= cs.length) return undefined
  const t = cs.slice(i + 1, j).join('')
  return mathOk(t) ? [jmath(t), j + 1] : undefined
}

export const mkInt = (v: bigint | number): JNum => ({ k: 'int', v: BigInt(v) })

const INT64_MIN = -(2n ** 63n)
const INT64_MAX = 2n ** 63n - 1n

/** `JNum.InInt64`. */
export function inInt64(z: bigint): boolean {
  return INT64_MIN <= z && z <= INT64_MAX
}

/** `JNum.digitsVal`: the value of a big-endian digit list. */
export function digitsVal(ds: readonly number[]): bigint {
  let a = 0n
  for (const d of ds) a = a * 10n + BigInt(d)
  return a
}

/**
 * `JNum.decInt?`: the integer a decimal denotes, when it is integral.
 *
 * `undefined` when the decimal is not integral; `null` when it is integral but
 * far outside Int64 (more than 40 digits, so the value is never built).
 */
export function decInt(
  neg: boolean,
  ds: readonly number[],
  e10: number,
): bigint | null | undefined {
  const len = ds.length
  if (len > e10 + 1) return undefined
  const zeros = e10 + 1 - len
  if (ds.every((d) => d === 0)) return 0n
  if (e10 + 1 > 40) return null
  const m = digitsVal(ds) * 10n ** BigInt(zeros)
  return neg ? -m : m
}

/** Structural equality of two numbers. */
export function jnumEq(a: JNum, b: JNum): boolean {
  if (a.k === 'int') return b.k === 'int' && a.v === b.v
  if (b.k !== 'dec') return false
  return (
    a.neg === b.neg &&
    a.e10 === b.e10 &&
    a.digits.length === b.digits.length &&
    a.digits.every((d, i) => d === b.digits[i])
  )
}

/** `n` is the integer `v`. */
export function isIntN(n: JNum, v: bigint | number): boolean {
  return n.k === 'int' && n.v === BigInt(v)
}

/** `JNum.wfb`: the number is in canonical form. */
export function jnumWfb(n: JNum): boolean {
  if (n.k === 'int') return inInt64(n.v)
  const { neg, digits, e10 } = n
  if (digits.length === 0) return false
  if (!digits.every((d) => d < 10)) return false
  if (digits[0] === 0 || digits[digits.length - 1] === 0) return false
  const z = decInt(neg, digits, e10)
  return z === undefined || z === null || !inInt64(z)
}

/** Structural equality of two JSON values (entry order matters). */
export function jsonEq(a: Json, b: Json): boolean {
  if (a === b) return true
  switch (a.t) {
    case 'null':
      return b.t === 'null'
    case 'bool':
      return b.t === 'bool' && a.v === b.v
    case 'num':
      return b.t === 'num' && jnumEq(a.n, b.n)
    case 'str':
      return b.t === 'str' && a.s === b.s
    case 'math':
      return b.t === 'math' && a.s === b.s
    case 'arr':
      return (
        b.t === 'arr' && a.xs.length === b.xs.length && a.xs.every((x, i) => jsonEq(x, b.xs[i]))
      )
    case 'obj':
      return (
        b.t === 'obj' &&
        a.kvs.length === b.kvs.length &&
        a.kvs.every(([k, v], i) => k === b.kvs[i][0] && jsonEq(v, b.kvs[i][1]))
      )
  }
}

/** `Json.wfb`: every number canonical, every object with distinct keys, and no math leaf. */
export function jsonWfb(j: Json): boolean {
  switch (j.t) {
    case 'num':
      return jnumWfb(j.n)
    case 'arr':
      return j.xs.every(jsonWfb)
    case 'obj':
      return keysDistinct(j.kvs) && j.kvs.every(([, v]) => jsonWfb(v))
    case 'math':
      return false
    default:
      return true
  }
}

/**
 * `Json.wfmb`: {@link jsonWfb}, except that a math leaf whose text is
 * {@link mathOk} is allowed (what the codecs print and read).
 */
export function jsonWfmb(j: Json): boolean {
  switch (j.t) {
    case 'num':
      return jnumWfb(j.n)
    case 'arr':
      return j.xs.every(jsonWfmb)
    case 'obj':
      return keysDistinct(j.kvs) && j.kvs.every(([, v]) => jsonWfmb(v))
    case 'math':
      return mathOk(j.s)
    default:
      return true
  }
}

/** The keys of an entry list are pairwise distinct. */
export function keysDistinct(kvs: Kvs): boolean {
  const seen = new Set<string>()
  for (const [k] of kvs) {
    if (seen.has(k)) return false
    seen.add(k)
  }
  return true
}

/** The value at key `k` of an entry list (the first one). */
export function lookKvs(k: string, kvs: Kvs): Json | undefined {
  for (const [key, v] of kvs) if (key === k) return v
  return undefined
}

const F_INT64_BOUND = 2 ** 63

/**
 * The canonical number of a finite binary64 (§5.5.3.1): an integral value in
 * Int64 is the integer, any other value its shortest round-trip digits.
 */
export function jnumOfFloat(f: number): JNum | undefined {
  if (!Number.isFinite(f)) return undefined
  if (f === 0) return mkInt(0)
  if (Number.isInteger(f) && f >= -F_INT64_BOUND && f < F_INT64_BOUND) return mkInt(BigInt(f))
  // toExponential() with no argument writes the shortest round-trip digits.
  const s = Math.abs(f).toExponential()
  const e = s.indexOf('e')
  const mant = s.slice(0, e).replace('.', '')
  const digits = Array.from(mant, (c) => c.charCodeAt(0) - 48)
  while (digits.length > 1 && digits[digits.length - 1] === 0) digits.pop()
  return { k: 'dec', neg: f < 0, digits, e10: Number(s.slice(e + 1)) }
}

/** The binary64 value of a number (the nearest one, for a decimal). */
export function jnumToFloat(n: JNum): number {
  if (n.k === 'int') return Number(n.v)
  const mant = n.digits.length === 0 ? '0' : n.digits.join('')
  return Number(`${n.neg ? '-' : ''}0.${mant}e${n.e10 + 1}`)
}

/**
 * A plain JSON value (plain numbers, `NumericLiteral` leaves or the `bigint` of
 * an integer past 2^53, as `JSON.parse`, `losslessJsonParse` or
 * `canonicalizeDocument` give) as a document value. A non-finite number becomes
 * `null`, as no JSON can hold one.
 */
export function fromPlain(v: unknown): Json {
  if (v === null || v === undefined) return JNULL
  if (typeof v === 'boolean') return jbool(v)
  if (typeof v === 'string') return jstr(v)
  if (typeof v === 'number') {
    const n = jnumOfFloat(v)
    return n === undefined ? JNULL : jnum(n)
  }
  if (typeof v === 'bigint') return jint(v)
  if (isNumericLiteral(v)) {
    const n = jnumOfFloat(v.value)
    return n === undefined ? JNULL : jnum(n)
  }
  if (Array.isArray(v)) return jarr(v.map(fromPlain))
  if (typeof v === 'object') {
    const kvs: (readonly [string, Json])[] = []
    for (const [k, x] of Object.entries(v as Record<string, unknown>)) {
      if (x !== undefined) kvs.push([k, fromPlain(x)])
    }
    return jobj(kvs)
  }
  return JNULL
}

/**
 * A document value as a plain JSON value. Numbers are plain `number`s, or, with
 * `tagged`, `NumericLiteral` leaves: an integer is an int literal and a decimal a
 * float literal, so `1.0e19` (integral, outside Int64) stays a float. An integer
 * past 2^53 is, as a plain number, the nearest binary64 (as `JSON.parse` gives
 * it); `tagged`, it is the exact `bigint`.
 */
export function toPlain(j: Json, tagged: boolean): unknown {
  switch (j.t) {
    case 'null':
      return null
    case 'bool':
      return j.v
    // `math`: never reached, a document read back holds no math leaf
    case 'str':
    case 'math':
      return j.s
    case 'num': {
      const f = jnumToFloat(j.n)
      // A nonzero decimal below the smallest subnormal (`1.0e-400`) rounds to
      // zero, as every binding's JSON reader rounds it, and is the canonical
      // zero, the integer 0. (One beyond the binary64 range has no value;
      // the document readers refuse it before converting.)
      if (f === 0) return tagged ? intLit(0) : 0
      if (!tagged) return f
      if (j.n.k === 'dec') return floatLit(f)
      return Number.isSafeInteger(f) ? intLit(f) : j.n.v
    }
    case 'arr':
      return j.xs.map((x) => toPlain(x, tagged))
    case 'obj':
      // Object.fromEntries defines own properties, so a `__proto__` key stays a key.
      return Object.fromEntries(j.kvs.map(([k, v]) => [k, toPlain(v, tagged)]))
  }
}

/** Code point order of two strings (the key order of the canonical serialization). */
export function cmpCodePoints(a: string, b: string): number {
  const n = Math.min(a.length, b.length)
  for (let i = 0; i < n; i++) {
    const x = a.charCodeAt(i)
    const y = b.charCodeAt(i)
    if (x === y) continue
    // A surrogate (U+D800..U+DFFF) stands for a code point above U+FFFF, so it
    // sorts after every other UTF-16 unit.
    const sx = x >= 0xd800 && x <= 0xdfff
    const sy = y >= 0xd800 && y <= 0xdfff
    if (sx !== sy) return sx ? 1 : -1
    return x - y
  }
  return a.length - b.length
}

/** The value with every object's entries sorted by key (code point order). */
export function sortKeys(j: Json): Json {
  switch (j.t) {
    case 'arr':
      return jarr(j.xs.map(sortKeys))
    case 'obj': {
      const kvs = j.kvs.map(([k, v]) => [k, sortKeys(v)] as const)
      kvs.sort((a, b) => cmpCodePoints(a[0], b[0]))
      return jobj(kvs)
    }
    default:
      return j
  }
}
