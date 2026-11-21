/**
 * The YAML subset of front matter and container bodies.
 *
 * Port of `formal/Esm/Document/Yaml.lean` (after the Rust binding's
 * `document/yaml.rs`). The printed text is block-style YAML 1.2:
 *
 * - a non-empty object is one `key: value` line per entry, a non-empty array
 *   one `- item` line per element, at the current indentation;
 * - a scalar, `[]` or `{}` follows its `key: ` or `- ` on the same line;
 * - a non-empty container under a key starts on the next line, two spaces
 *   deeper; a non-empty object as an array element starts on the `- ` line,
 *   its other entries aligned with its first key; a non-empty array as an
 *   element starts on the next line, two spaces deeper.
 *
 * Strings are always double-quoted with JSON-style escapes, so a math leaf (path
 * blocks only) is the plain scalar `$…$`; the printer makes one only of text
 * that is {@link plainMathOk}, which every YAML 1.2 parser reads as that
 * string. A key is bare when
 * it is an identifier and not one of YAML's special plain scalars in any letter
 * case; a key longer than 1024 characters uses the explicit `? "key"` form. The
 * reader accepts only this layout and well-formed values.
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
  mathOk,
  pMath,
  type Json,
  type Kvs,
} from './json.js'
import { nested } from './limits.js'
import { parseNum, printNum, type Chars, type Read } from './number.js'
import {
  isIdentStart,
  needsHex,
  parseKey,
  parseQuoted,
  printKey,
  quote,
  spaces,
} from './strings.js'

/**
 * `Yaml.plainMathOK`: math text YAML holds as the plain scalar `$…$`, which a
 * YAML 1.2 parser reads as that string: {@link mathOk}, and no `: ` (a mapping
 * indicator), no ` #` (a comment) and no character of `needsHex`. The Markdown
 * printer leaves any other expression in its block as JSON.
 */
export function plainMathOk(s: string): boolean {
  if (!mathOk(s) || s.includes(': ') || s.includes(' #')) return false
  for (const c of s) if (needsHex(c)) return false
  return true
}

/** `Yaml.specialWords`. */
const SPECIAL_WORDS: ReadonlySet<string> = new Set([
  'true',
  'false',
  'null',
  'yes',
  'no',
  'on',
  'off',
  'y',
  'n',
])

/** `Yaml.reserved`: a key equal (in any ASCII letter case) to a special plain scalar. */
export function reserved(k: string): boolean {
  return k.length <= 5 && SPECIAL_WORDS.has(k.replace(/[A-Z]/g, (c) => c.toLowerCase()))
}

/** `Yaml.longKey`. */
function longKey(k: string): boolean {
  // A key of at most 170 characters prints in at most 6 * 170 + 2 = 1022.
  return k.length > 170 && Array.from(printKey(false, reserved, k)).length > 1024
}

/** `Yaml.keyPart`: the key of an entry at indentation `m`, up to its `:`. */
function keyPart(m: number, k: string, out: string[]): void {
  if (longKey(k)) out.push('? ', quote(false, k), '\n', spaces(m))
  else out.push(printKey(false, reserved, k))
}

/** `Yaml.inline`: the one-line spelling of a scalar or an empty container. */
export function inline(v: Json): string {
  switch (v.t) {
    case 'null':
      return 'null'
    case 'bool':
      return v.v ? 'true' : 'false'
    case 'num':
      return printNum(v.n)
    case 'str':
      return quote(false, v.s)
    case 'math':
      return `$${v.s}$`
    case 'arr':
      return '[]'
    case 'obj':
      return '{}'
  }
}

/** `Yaml.encItems`: the lines of a non-empty array at indentation `m`. */
function encItems(m: number, vs: readonly Json[], out: string[]): void {
  for (const v of vs) {
    out.push(spaces(m), '-')
    itemBody(m, v, out)
  }
}

/** `Yaml.itemBody`: what follows the `-` of an array element. */
function itemBody(m: number, v: Json, out: string[]): void {
  if (v.t === 'arr' && v.xs.length > 0) {
    out.push('\n')
    encItems(m + 2, v.xs, out)
  } else if (v.t === 'obj' && v.kvs.length > 0) {
    const [k, x] = v.kvs[0]
    out.push(' ')
    keyPart(m + 2, k, out)
    out.push(':')
    valBody(m + 2, x, out)
    encEntries(m + 2, v.kvs.slice(1), out)
  } else out.push(' ', inline(v), '\n')
}

/** `Yaml.encEntries`: the lines of a non-empty object at indentation `m`. */
function encEntries(m: number, es: Kvs, out: string[]): void {
  for (const [k, v] of es) {
    out.push(spaces(m))
    keyPart(m, k, out)
    out.push(':')
    valBody(m, v, out)
  }
}

/** `Yaml.valBody`: what follows the `:` of an entry whose key is at indentation `m`. */
function valBody(m: number, v: Json, out: string[]): void {
  if (v.t === 'arr' && v.xs.length > 0) {
    out.push('\n')
    encItems(m + 2, v.xs, out)
  } else if (v.t === 'obj' && v.kvs.length > 0) {
    out.push('\n')
    encEntries(m + 2, v.kvs, out)
  } else out.push(' ', inline(v), '\n')
}

/** `Yaml.encode`: the canonical YAML spelling of a value. */
export function encode(v: Json): string {
  const out: string[] = []
  if (v.t === 'arr' && v.xs.length > 0) encItems(0, v.xs, out)
  else if (v.t === 'obj' && v.kvs.length > 0) encEntries(0, v.kvs, out)
  else out.push(inline(v), '\n')
  return out.join('')
}

// ## Reader

/** `Yaml.dropSp`: drop exactly `n` leading spaces. */
function dropSp(n: number, cs: Chars, i: number): number | undefined {
  for (let k = 0; k < n; k++) if (cs[i + k] !== ' ') return undefined
  return i + n
}

/**
 * `Yaml.parseKeyAt`: an explicit `? "key"` line followed by the indentation of
 * the `:` line, or a plain key.
 */
function parseKeyAt(m: number, cs: Chars, i: number): Read<string> {
  const c = cs[i]
  if (c === undefined) return undefined
  if (c === '?') {
    if (cs[i + 1] !== ' ') return undefined
    const q = parseQuoted(false, cs, i + 2)
    if (q === undefined || cs[q[1]] !== '\n') return undefined
    const j = dropSp(m, cs, q[1] + 1)
    return j === undefined ? undefined : [q[0], j]
  }
  return parseKey(false, reserved, cs, i)
}

const word = (cs: Chars, i: number, w: string): boolean => {
  for (let k = 0; k < w.length; k++) if (cs[i + k] !== w[k]) return false
  return true
}

/** `Yaml.pInline`: a scalar or an empty container. */
export function pInline(cs: Chars, i: number): Read<Json> {
  switch (cs[i]) {
    case undefined:
      return undefined
    case 'n':
      return word(cs, i, 'null') ? [JNULL, i + 4] : undefined
    case 't':
      return word(cs, i, 'true') ? [JTRUE, i + 4] : undefined
    case 'f':
      return word(cs, i, 'false') ? [JFALSE, i + 5] : undefined
    case '[':
      return cs[i + 1] === ']' ? [jarr([]), i + 2] : undefined
    case '{':
      return cs[i + 1] === '}' ? [jobj([]), i + 2] : undefined
    case '"': {
      const r = parseQuoted(false, cs, i)
      return r && [jstr(r[0]), r[1]]
    }
    case '$':
      return pMath(cs, i)
    default: {
      const r = parseNum(cs, i)
      return r && [jnum(r[0]), r[1]]
    }
  }
}

/** `Yaml.pScalarLine`: a scalar and the end of its line. */
function pScalarLine(cs: Chars, i: number): Read<Json> {
  const r = pInline(cs, i)
  return r && cs[r[1]] === '\n' ? [r[0], r[1] + 1] : undefined
}

/** `Yaml.isItemLine`. */
function isItemLine(m: number, cs: Chars, i: number): boolean {
  const j = dropSp(m, cs, i)
  return j !== undefined && cs[j] === '-'
}

/** `Yaml.isEntryLine`. */
function isEntryLine(m: number, cs: Chars, i: number): boolean {
  const j = dropSp(m, cs, i)
  if (j === undefined) return false
  const c = cs[j]
  return c === '"' || c === '?' || isIdentStart(c)
}

/** `Yaml.pItems`: array elements at indentation `m`. */
function pItems(m: number, cs: Chars, i: number): Read<Json[]> {
  const out: Json[] = []
  while (isItemLine(m, cs, i)) {
    const r = pItemBody(m, cs, i + m + 1)
    if (r === undefined) return undefined
    out.push(r[0])
    i = r[1]
  }
  return [out, i]
}

/** `Yaml.pItemBody`: after the `-` of an element at indentation `m`. */
function pItemBody(m: number, cs: Chars, i: number): Read<Json> {
  return nested(() => pItemBodyIn(m, cs, i))
}

function pItemBodyIn(m: number, cs: Chars, i: number): Read<Json> {
  if (cs[i] === '\n') {
    const r = pItems(m + 2, cs, i + 1)
    return r && [jarr(r[0]), r[1]]
  }
  if (cs[i] === ' ') {
    const e = pEntry(m + 2, cs, i + 1)
    if (e === undefined) return pScalarLine(cs, i + 1)
    const r = pEntries(m + 2, cs, e[1])
    return r && [jobj([e[0], ...r[0]]), r[1]]
  }
  return undefined
}

/** `Yaml.pEntries`: object entries at indentation `m`. */
function pEntries(m: number, cs: Chars, i: number): Read<[string, Json][]> {
  const out: [string, Json][] = []
  while (isEntryLine(m, cs, i)) {
    const r = pEntry(m, cs, i + m)
    if (r === undefined) return undefined
    out.push(r[0])
    i = r[1]
  }
  return [out, i]
}

/** `Yaml.pEntry`: one entry, at its key. */
function pEntry(m: number, cs: Chars, i: number): Read<[string, Json]> {
  const k = parseKeyAt(m, cs, i)
  if (k === undefined || cs[k[1]] !== ':') return undefined
  const v = pValBody(m, cs, k[1] + 1)
  return v && [[k[0], v[0]], v[1]]
}

/** `Yaml.pValBody`: after the `:` of an entry whose key is at indentation `m`. */
function pValBody(m: number, cs: Chars, i: number): Read<Json> {
  return nested(() => pValBodyIn(m, cs, i))
}

function pValBodyIn(m: number, cs: Chars, i: number): Read<Json> {
  if (cs[i] === ' ') return pScalarLine(cs, i + 1)
  if (cs[i] === '\n') {
    if (isItemLine(m + 2, cs, i + 1)) {
      const r = pItems(m + 2, cs, i + 1)
      return r && [jarr(r[0]), r[1]]
    }
    const r = pEntries(m + 2, cs, i + 1)
    return r && [jobj(r[0]), r[1]]
  }
  return undefined
}

/** `Yaml.topIsArray`. */
function topIsArray(cs: Chars, i: number): boolean {
  return isItemLine(0, cs, i) && (cs[i + 1] === ' ' || cs[i + 1] === '\n')
}

/** `Yaml.pTop`: an array, an object, or one scalar line. */
function pTop(cs: Chars, i: number): Read<Json> {
  if (topIsArray(cs, i)) {
    const r = pItems(0, cs, i)
    return r && [jarr(r[0]), r[1]]
  }
  const e = pEntry(0, cs, i)
  if (e === undefined) return pScalarLine(cs, i)
  const r = pEntries(0, cs, e[1])
  return r && [jobj([e[0], ...r[0]]), r[1]]
}

/** `Yaml.decode`: all of the input consumed, and the value well formed (math leaves allowed). */
export function decode(cs: Chars, start = 0, end = cs.length): Json | undefined {
  const r = pTop(end === cs.length ? cs : cs.slice(0, end), start)
  if (r === undefined || r[1] !== end || !jsonWfmb(r[0])) return undefined
  return r[0]
}
