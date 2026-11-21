/**
 * The Typst value codec: a JSON value as a Typst code-mode value.
 *
 * Port of `formal/Esm/Document/TypstDict.lean` (after the Rust binding's
 * `document/typst_dict.rs`).
 *
 * - `none`, `true`, `false`; numbers in the canonical spelling, except `-2^63`,
 *   printed `(-9223372036854775807 - 1)` because Typst reads the literal
 *   `-9223372036854775808` as a float;
 * - strings with Typst escapes (`\u{XXXX}`);
 * - arrays `(a, b)`, `()` empty; dictionaries `(key: v, "quoted key": v)`,
 *   `(:)` empty. A key is bare when it is an identifier and not a Typst keyword;
 * - a math leaf `$…$`, Typst math content (path blocks only).
 *
 * The canonical layout is one element per line, each indented two spaces deeper
 * than the opening line and followed by `,`. The reader skips whitespace between
 * tokens, accepts a trailing comma or none, and rejects a one-element array
 * without its comma (Typst reads `(x)` as `x`).
 */

import {
  JFALSE,
  JNULL,
  JTRUE,
  jarr,
  jnum,
  jobj,
  jsonWfmb,
  jstr,
  mkInt,
  pMath,
  type JNum,
  type Json,
} from './json.js'
import { nested } from './limits.js'
import { parseNum, printNum as printCanonical, type Chars, type Read } from './number.js'
import { parseKey, parseQuoted, printKey, quote, spaces } from './strings.js'

/** `TypstDict.keywords`: Typst keywords, which cannot be bare dictionary keys. */
const KEYWORDS: ReadonlySet<string> = new Set([
  'none',
  'auto',
  'true',
  'false',
  'not',
  'and',
  'or',
  'let',
  'set',
  'show',
  'if',
  'else',
  'for',
  'in',
  'while',
  'break',
  'continue',
  'return',
  'import',
  'include',
  'context',
  'as',
  '_',
])

/** `TypstDict.reserved`. */
export const reserved = (k: string): boolean => KEYWORDS.has(k)

/** `TypstDict.int64Min`. */
const INT64_MIN = -(2n ** 63n)

/** `TypstDict.minLit`: the first operand of the `-2^63` expression. */
const MIN_LIT = '-9223372036854775807'

/** `TypstDict.printNum`. */
export function printNum(n: JNum): string {
  return n.k === 'int' && n.v === INT64_MIN ? '(-9223372036854775807 - 1)' : printCanonical(n)
}

/**
 * `TypstDict.enc`: the canonical print of a value whose first line is indented
 * by `m` spaces (the indentation itself is not printed).
 */
function enc(m: number, v: Json, out: string[]): void {
  switch (v.t) {
    case 'null':
      out.push('none')
      return
    case 'bool':
      out.push(v.v ? 'true' : 'false')
      return
    case 'num':
      out.push(printNum(v.n))
      return
    case 'str':
      out.push(quote(true, v.s))
      return
    case 'math':
      out.push('$', v.s, '$')
      return
    case 'arr':
      if (v.xs.length === 0) {
        out.push('()')
        return
      }
      out.push('(\n')
      for (const x of v.xs) {
        out.push(spaces(m + 2))
        enc(m + 2, x, out)
        out.push(',\n')
      }
      out.push(spaces(m), ')')
      return
    case 'obj':
      if (v.kvs.length === 0) {
        out.push('(:)')
        return
      }
      out.push('(\n')
      for (const [k, x] of v.kvs) {
        out.push(spaces(m + 2), printKey(true, reserved, k), ': ')
        enc(m + 2, x, out)
        out.push(',\n')
      }
      out.push(spaces(m), ')')
  }
}

/** `TypstDict.encode`: the canonical Typst spelling of a value. */
export function encode(v: Json): string {
  const out: string[] = []
  enc(0, v, out)
  return out.join('')
}

/** `TypstDict.isWs`. */
export const isWs = (c: string | undefined): boolean =>
  c === ' ' || c === '\n' || c === '\t' || c === '\r'

/** `TypstDict.skipWs`. */
export function skipWs(cs: Chars, i: number): number {
  while (isWs(cs[i])) i++
  return i
}

/** `TypstDict.isEntry`: the input starts with a key and a colon. */
function isEntry(cs: Chars, i: number): boolean {
  const r = parseKey(true, reserved, cs, i)
  return r !== undefined && cs[skipWs(cs, r[1])] === ':'
}

/** `TypstDict.Next`: `more` (`,` and another element), or `)` after a `,` or directly. */
type Next = 'more' | 'close-comma' | 'close'

/** `TypstDict.pNext`. */
function pNext(cs: Chars, i: number): Read<Next> {
  const j = skipWs(cs, i)
  if (cs[j] === ',') {
    const k = skipWs(cs, j + 1)
    return cs[k] === ')' ? ['close-comma', k + 1] : ['more', k]
  }
  if (cs[j] === ')') return ['close', j + 1]
  return undefined
}

/** `TypstDict.pMin`: after `(` and any whitespace, the rest of `(-9223372036854775807 - 1)`. */
function pMin(cs: Chars, i: number): number | undefined {
  for (let k = 0; k < MIN_LIT.length; k++) if (cs[i + k] !== MIN_LIT[k]) return undefined
  let j = skipWs(cs, i + MIN_LIT.length)
  if (cs[j] !== '-') return undefined
  j = skipWs(cs, j + 1)
  if (cs[j] !== '1') return undefined
  j = skipWs(cs, j + 1)
  if (cs[j] !== ')') return undefined
  return j + 1
}

const word = (cs: Chars, i: number, w: string): boolean => {
  for (let k = 0; k < w.length; k++) if (cs[i + k] !== w[k]) return false
  return true
}

/** `TypstDict.pVal`: a value, at its first character. */
export function pVal(cs: Chars, i: number): Read<Json> {
  return nested(() => pValIn(cs, i))
}

function pValIn(cs: Chars, i: number): Read<Json> {
  switch (cs[i]) {
    case undefined:
      return undefined
    case '(': {
      const j = skipWs(cs, i + 1)
      const r = pMin(cs, j)
      if (r !== undefined) return [jnum(mkInt(INT64_MIN)), r]
      return pParen(cs, j)
    }
    case '"': {
      const r = parseQuoted(true, cs, i)
      return r && [jstr(r[0]), r[1]]
    }
    case '$':
      return pMath(cs, i)
    case 'n':
      return word(cs, i, 'none') ? [JNULL, i + 4] : undefined
    case 't':
      return word(cs, i, 'true') ? [JTRUE, i + 4] : undefined
    case 'f':
      return word(cs, i, 'false') ? [JFALSE, i + 5] : undefined
    default: {
      const r = parseNum(cs, i)
      return r && [jnum(r[0]), r[1]]
    }
  }
}

/** `TypstDict.pParen`: after `(` and any whitespace. */
function pParen(cs: Chars, i: number): Read<Json> {
  const c = cs[i]
  if (c === undefined) return undefined
  if (c === ')') return [jarr([]), i + 1]
  if (c === ':') {
    const j = skipWs(cs, i + 1)
    return cs[j] === ')' ? [jobj([]), j + 1] : undefined
  }
  if (isEntry(cs, i)) {
    const r = pEntries(cs, i)
    return r && [jobj(r[0]), r[1]]
  }
  const r = pItems(cs, i)
  return r && [jarr(r[0]), r[1]]
}

/** `TypstDict.pItems`: array elements; the first needs a `,` after it even when it is the last. */
function pItems(cs: Chars, i: number): Read<Json[]> {
  const out: Json[] = []
  let first = true
  for (;;) {
    const v = pVal(cs, i)
    if (v === undefined) return undefined
    out.push(v[0])
    const n = pNext(cs, v[1])
    if (n === undefined) return undefined
    if (n[0] === 'more') {
      i = n[1]
      first = false
      continue
    }
    return first && n[0] === 'close' ? undefined : [out, n[1]]
  }
}

/** `TypstDict.pEntries`: dictionary entries, at the first key. */
function pEntries(cs: Chars, i: number): Read<[string, Json][]> {
  const out: [string, Json][] = []
  for (;;) {
    const k = parseKey(true, reserved, cs, i)
    if (k === undefined) return undefined
    const j = skipWs(cs, k[1])
    if (cs[j] !== ':') return undefined
    const v = pVal(cs, skipWs(cs, j + 1))
    if (v === undefined) return undefined
    out.push([k[0], v[0]])
    const n = pNext(cs, v[1])
    if (n === undefined) return undefined
    if (n[0] !== 'more') return [out, n[1]]
    i = n[1]
  }
}

/**
 * `TypstDict.decode`: whitespace, the value, whitespace, end of input. The value
 * must be well formed (math leaves allowed).
 */
export function decode(cs: Chars): Json | undefined {
  const r = pVal(cs, skipWs(cs, 0))
  if (r === undefined || skipWs(cs, r[1]) !== cs.length || !jsonWfmb(r[0])) return undefined
  return r[0]
}
