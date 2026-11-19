/**
 * Expressions as JSON values, and the symbol table.
 *
 * Port of `formal/Esm/Document/Math/Expr.lean` (after the Rust binding's
 * `document/math/expr.rs`). An expression is the JSON value at an expression
 * position (spec §4.1): a number, a name (dot-separated identifier segments), or
 * a node (`op`, `args` and any other fields). {@link isE} is the
 * well-formedness check; {@link Sym} is what a document declares.
 *
 * Names are handled as code point arrays where their characters are inspected,
 * so a non-ASCII character is one character, as in Lean and Rust.
 */

import {
  cmpCodePoints,
  decInt,
  inInt64,
  keysDistinct,
  type JNum,
  type Json,
  type Kvs,
} from '../json.js'

// ## Characters (`Math.isLetter` …): ASCII only.

/** `Math.isLetter`. */
export function isLetter(c: string | undefined): boolean {
  return c !== undefined && c.length === 1 && ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))
}
/** `Math.isUpper`. */
export function isUpper(c: string | undefined): boolean {
  return c !== undefined && c.length === 1 && c >= 'A' && c <= 'Z'
}
/** `Math.isLower`. */
export function isLower(c: string | undefined): boolean {
  return c !== undefined && c.length === 1 && c >= 'a' && c <= 'z'
}
/** `Math.isDig`. */
export function isDig(c: string | undefined): boolean {
  return c !== undefined && c.length === 1 && c >= '0' && c <= '9'
}
/** `Math.isIdStart`. */
export function isIdStart(c: string | undefined): boolean {
  return isLetter(c) || c === '_'
}
/** `Math.isIdChar`. */
export function isIdChar(c: string | undefined): boolean {
  return isLetter(c) || isDig(c) || c === '_'
}

// ## Names

/** `Math.splitDots`: split at every `.` (an empty input is one empty segment). */
export function splitDots(s: string): string[] {
  return s.split('.')
}

/** `Math.joinDots`. */
export function joinDots(ss: readonly string[]): string {
  return ss.join('.')
}

/** `Math.segOK`: an identifier segment `[A-Za-z_][A-Za-z0-9_]*`. */
export function segOk(s: string): boolean {
  if (s.length === 0 || !isIdStart(s[0])) return false
  for (let i = 1; i < s.length; i++) if (!isIdChar(s[i])) return false
  return true
}

/** `Math.nameOK`: dot-separated identifier segments. */
export function nameOk(s: string): boolean {
  return splitDots(s).every(segOk)
}

/** `Math.greek`: the Greek letter names that are a LaTeX command and a Typst symbol. */
export const GREEK: readonly string[] = [
  'alpha',
  'beta',
  'gamma',
  'delta',
  'epsilon',
  'zeta',
  'eta',
  'theta',
  'iota',
  'kappa',
  'lambda',
  'mu',
  'nu',
  'xi',
  'pi',
  'rho',
  'sigma',
  'tau',
  'upsilon',
  'phi',
  'chi',
  'psi',
  'omega',
  'Gamma',
  'Delta',
  'Theta',
  'Lambda',
  'Xi',
  'Pi',
  'Sigma',
  'Upsilon',
  'Phi',
  'Psi',
  'Omega',
]
const GREEK_SET: ReadonlySet<string> = new Set(GREEK)

/** `Math.isGreek`. */
export function isGreek(s: string): boolean {
  return GREEK_SET.has(s)
}

/** `Math.isSingle`: one letter, or a Greek letter name. */
export function isSingle(s: string): boolean {
  return s.length === 1 ? isLetter(s) : isGreek(s)
}

/** `Math.elements`: the element symbols a chemical-formula name is built from. */
export const ELEMENTS: readonly string[] = [
  'H',
  'He',
  'Li',
  'Be',
  'B',
  'C',
  'N',
  'O',
  'F',
  'Ne',
  'Na',
  'Mg',
  'Al',
  'Si',
  'P',
  'S',
  'Cl',
  'Ar',
  'K',
  'Ca',
  'Ti',
  'Cr',
  'Mn',
  'Fe',
  'Co',
  'Ni',
  'Cu',
  'Zn',
  'Br',
  'Kr',
  'Ag',
  'Sn',
  'I',
  'Xe',
  'Hg',
  'Pb',
  'Rn',
]
const ELEMENT_SET: ReadonlySet<string> = new Set(ELEMENTS)

/** `Math.digRun`: the end of the maximal run of digits at `i`. */
export function digRun(cs: readonly string[] | string, i: number): number {
  while (i < cs.length && isDig(cs[i])) i++
  return i
}

/** `Math.letRun`: the end of the maximal run of letters at `i`. */
export function letRun(cs: readonly string[] | string, i: number): number {
  while (i < cs.length && isLetter(cs[i])) i++
  return i
}

/**
 * `Math.pieces`: a run of letters and the run of digits after it, repeatedly.
 * `CH2O` is `[("CH", "2"), ("O", "")]`.
 *
 * Only ASCII letters and digits are consumed, so UTF-16 indexing is code point
 * indexing here.
 */
export function pieces(s: string): [string, string][] {
  const out: [string, string][] = []
  let i = 0
  while (i < s.length) {
    const j = letRun(s, i)
    const k = digRun(s, j)
    if (j === i) break
    out.push([s.slice(i, j), s.slice(j, k)])
    i = k
  }
  return out
}

/** `Math.elemToks`: an uppercase letter, then an optional lowercase one, greedily. */
export function elemToks(s: string): string[] | undefined {
  const out: string[] = []
  let i = 0
  for (;;) {
    if (i >= s.length) return out
    const c = s[i]
    if (!isUpper(c)) return undefined
    if (i + 1 < s.length && isLower(s[i + 1])) {
      out.push(c + s[i + 1])
      i += 2
    } else {
      out.push(c)
      i += 1
    }
  }
}

/**
 * `Math.isFormula`: letters and digits only, read as element symbols and
 * counts, starting with an element, with at least two tokens.
 */
export function isFormula(s: string): boolean {
  for (let i = 0; i < s.length; i++) if (!isLetter(s[i]) && !isDig(s[i])) return false
  if (!isUpper(s[0])) return false
  const ps = pieces(s)
  if (ps.map(([a, b]) => a + b).join('') !== s) return false
  let count = 0
  for (const [a, b] of ps) {
    const ts = elemToks(a)
    if (ts === undefined || !ts.every((t) => ELEMENT_SET.has(t))) return false
    count += ts.length + (b.length > 0 ? 1 : 0)
  }
  return 2 <= count
}

/**
 * `Math.subParts`: the subscripted shape `b_r` (a single letter or Greek name,
 * `_`, a nonempty rest). Returns the base and the rest.
 */
export function subParts(s: string): [string, string] | undefined {
  const i = s.indexOf('_')
  if (i < 0) return undefined
  const b = s.slice(0, i)
  const rest = s.slice(i + 1)
  return isSingle(b) && rest.length > 0 ? [b, rest] : undefined
}

// ## Numbers and JSON well-formedness, as checks

/** `Math.int64OK`. */
export function int64Ok(z: bigint): boolean {
  return inInt64(z)
}

/** `Math.numOK`: `JNum.WF` as a check. */
export function numOk(n: JNum): boolean {
  if (n.k === 'int') return int64Ok(n.v)
  const { neg, digits, e10 } = n
  if (digits.length === 0) return false
  if (!digits.every((d) => d < 10)) return false
  if (digits[0] === 0 || digits[digits.length - 1] === 0) return false
  const z = decInt(neg, digits, e10)
  return typeof z === 'bigint' ? !int64Ok(z) : true
}

/** `Math.keysSorted`: object keys strictly increasing (code point order). */
export function keysSorted(kvs: Kvs): boolean {
  for (let i = 1; i < kvs.length; i++)
    if (cmpCodePoints(kvs[i - 1][0], kvs[i][0]) >= 0) return false
  return true
}

/** `Math.jwf`: `Json.WF` as a check. */
export function jwf(j: Json): boolean {
  switch (j.t) {
    case 'num':
      return numOk(j.n)
    case 'arr':
      return j.xs.every(jwf)
    case 'obj':
      return keysDistinct(j.kvs) && j.kvs.every(([, v]) => jwf(v))
    default:
      return true
  }
}

// ## Operators

/** `Math.removedOps`: spec §4.2 "Removed ops", refused by name. */
export const REMOVED_OPS: readonly string[] = [
  'arrayop',
  'aggregate',
  'fn',
  'table_lookup',
  'skolem',
  'rank',
  'argmin',
  'argmax',
  'polygon_intersection_area',
  'intersect_polygon',
]

/** `Math.deprecatedOps`: read in the call form and rewritten, never printed. */
export const DEPRECATED_OPS: readonly string[] = ['neg', 'pow']

const OP_SYMBOLS = '-+*/^<>=!'

/** `Math.opOK`: `[A-Za-z_][A-Za-z0-9_.]*`, or a nonempty run of the characters of `OP_SYMBOLS`. */
export function opOk(s: string): boolean {
  if (s.length === 0) return false
  let ident = isIdStart(s[0])
  for (let i = 1; ident && i < s.length; i++) ident = isIdChar(s[i]) || s[i] === '.'
  if (ident) return true
  for (const d of s) if (!OP_SYMBOLS.includes(d)) return false
  return true
}

/** `Math.look`: the value of key `k`. */
export function look(k: string, kvs: Kvs): Json | undefined {
  for (const [k2, v] of kvs) if (k2 === k) return v
  return undefined
}

/** `Math.opFieldOK`: an `op` that is neither removed nor deprecated. */
export function opFieldOk(kvs: Kvs): boolean {
  const o = look('op', kvs)
  return (
    o !== undefined &&
    o.t === 'str' &&
    opOk(o.s) &&
    !REMOVED_OPS.includes(o.s) &&
    !DEPRECATED_OPS.includes(o.s)
  )
}

/** `Math.hasArgs`. */
export function hasArgs(kvs: Kvs): boolean {
  return look('args', kvs) !== undefined
}

/** `Math.isE`: a well-formed expression (canonical form). */
export function isE(e: Json): boolean {
  switch (e.t) {
    case 'num':
      return numOk(e.n)
    case 'str':
      return nameOk(e.s)
    case 'obj':
      return (
        keysSorted(e.kvs) &&
        opFieldOk(e.kvs) &&
        hasArgs(e.kvs) &&
        e.kvs.every(([k, v]) => {
          if (k === 'args') return v.t === 'arr' && v.xs.every(isE)
          return k === 'op' || jwf(v)
        })
      )
    default:
      return false
  }
}

/**
 * `Math.Sym`: the names a document declares and the parameter list of every
 * template in scope.
 */
export interface Sym {
  readonly names: readonly string[]
  readonly templates: readonly (readonly [string, readonly string[]])[]
}
