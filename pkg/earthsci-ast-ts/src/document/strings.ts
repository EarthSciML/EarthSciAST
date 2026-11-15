/**
 * Lexical pieces shared by the YAML and Typst codecs.
 *
 * Port of `formal/Esm/Document/Strings.lean` (after the Rust binding's
 * `document/strings.rs`): double-quoted strings with JSON-style escapes (YAML
 * writes the hex escape `\uXXXX`, Typst `\u{XXXX}`; `braces` selects the Typst
 * spelling), bare identifier keys, and the characters a number or a key never
 * starts with.
 */

import type { Chars, Read } from './number.js'

/** `Strings.hexChar`: a lowercase hex digit. */
const hexChar = (d: number): string => String.fromCharCode(d < 10 ? 48 + d : 87 + d)

/** `Strings.hexVal`: the value of a hex digit (either case). */
export function hexVal(c: string | undefined): number | undefined {
  if (c === undefined || c.length !== 1) return undefined
  if (c >= '0' && c <= '9') return c.charCodeAt(0) - 48
  if (c >= 'a' && c <= 'f') return c.charCodeAt(0) - 87
  if (c >= 'A' && c <= 'F') return c.charCodeAt(0) - 55
  return undefined
}

/** `Strings.hex4`. */
const hex4 = (n: number): string =>
  hexChar(Math.floor(n / 4096) % 16) +
  hexChar(Math.floor(n / 256) % 16) +
  hexChar(Math.floor(n / 16) % 16) +
  hexChar(n % 16)

/** `Strings.hex4Val`. */
function hex4Val(cs: Chars, i: number): number | undefined {
  const a = hexVal(cs[i])
  const b = hexVal(cs[i + 1])
  const c = hexVal(cs[i + 2])
  const d = hexVal(cs[i + 3])
  if (a === undefined || b === undefined || c === undefined || d === undefined) return undefined
  return a * 4096 + b * 256 + c * 16 + d
}

/** `Strings.needsHex`: characters written as a hex escape. */
export function needsHex(c: string): boolean {
  const n = c.codePointAt(0) ?? 0
  return (
    n < 0x20 ||
    n === 0x7f ||
    (n >= 0x80 && n <= 0x9f) ||
    n === 0x2028 ||
    n === 0x2029 ||
    n === 0xfeff ||
    n === 0xfffe ||
    n === 0xffff
  )
}

/** `Strings.escChar`. */
export function escChar(braces: boolean, c: string): string {
  switch (c) {
    case '"':
      return '\\"'
    case '\\':
      return '\\\\'
    case '\n':
      return '\\n'
    case '\t':
      return '\\t'
    case '\r':
      return '\\r'
  }
  if (needsHex(c)) {
    const h = hex4(c.codePointAt(0) ?? 0)
    return braces ? `\\u{${h}}` : `\\u${h}`
  }
  return c
}

/** `Strings.escape`: the escaped characters of a string, without the quotes. */
export function escape(braces: boolean, s: string): string {
  let out = ''
  for (const c of s) out += escChar(braces, c)
  return out
}

/** `Strings.quote`: a double-quoted string literal. */
export function quote(braces: boolean, s: string): string {
  return `"${escape(braces, s)}"`
}

/**
 * Lean's `Char.ofNat`: a surrogate code point becomes `'\0'`.
 */
const charOf = (n: number): string => (n >= 0xd800 && n <= 0xdfff ? '\0' : String.fromCodePoint(n))

/** `Strings.unquoteBody`: the characters up to the closing quote, and the index after it. */
export function unquoteBody(braces: boolean, cs: Chars, i: number): Read<string> {
  let out = ''
  for (;;) {
    const c = cs[i]
    if (c === undefined) return undefined
    if (c === '"') return [out, i + 1]
    if (c !== '\\') {
      out += c
      i++
      continue
    }
    const e = cs[i + 1]
    if (e === '"') out += '"'
    else if (e === '\\') out += '\\'
    else if (e === 'n') out += '\n'
    else if (e === 't') out += '\t'
    else if (e === 'r') out += '\r'
    else if (e === 'u') {
      if (cs[i + 2] === '{' && cs[i + 7] === '}' && i + 7 < cs.length) {
        if (!braces) return undefined
        const v = hex4Val(cs, i + 3)
        if (v === undefined) return undefined
        out += charOf(v)
        i += 8
        continue
      }
      if (braces || i + 5 >= cs.length) return undefined
      const v = hex4Val(cs, i + 2)
      if (v === undefined) return undefined
      out += charOf(v)
      i += 6
      continue
    } else return undefined
    i += 2
  }
}

/** `Strings.parseQuoted`. */
export function parseQuoted(braces: boolean, cs: Chars, i: number): Read<string> {
  return cs[i] === '"' ? unquoteBody(braces, cs, i + 1) : undefined
}

/** `Strings.isIdentStart` (ASCII letters, as Lean's `Char.isAlpha`). */
export function isIdentStart(c: string | undefined): boolean {
  return (
    c !== undefined &&
    c.length === 1 &&
    ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c === '_')
  )
}

/** `Strings.isIdentChar`. */
export function isIdentChar(c: string | undefined): boolean {
  return isIdentStart(c) || (c !== undefined && c.length === 1 && c >= '0' && c <= '9')
}

const IDENT_RE = /^[A-Za-z_][A-Za-z0-9_]*$/

/** `Strings.isIdent`: `[A-Za-z_][A-Za-z0-9_]*`. */
export function isIdent(s: string): boolean {
  return IDENT_RE.test(s)
}

/** `Strings.readIdent`: the maximal run of identifier characters at `i`. */
export function readIdent(cs: Chars, i: number): [string, number] {
  let j = i
  while (isIdentChar(cs[j])) j++
  return [cs.slice(i, j).join(''), j]
}

/** `Strings.spaces`. */
export const spaces = (n: number): string => ' '.repeat(n)

/**
 * `Strings.bareKey`: a key prints bare when it is an identifier and not one of
 * the codec's reserved words.
 */
export function bareKey(reserved: (k: string) => boolean, k: string): boolean {
  return isIdent(k) && !reserved(k)
}

/** `Strings.printKey`. */
export function printKey(braces: boolean, reserved: (k: string) => boolean, k: string): string {
  return bareKey(reserved, k) ? k : quote(braces, k)
}

/** `Strings.parseKey`: quoted, or an identifier that is not a reserved word. */
export function parseKey(
  braces: boolean,
  reserved: (k: string) => boolean,
  cs: Chars,
  i: number,
): Read<string> {
  const c = cs[i]
  if (c === undefined) return undefined
  if (c === '"') return parseQuoted(braces, cs, i)
  if (isIdentStart(c)) {
    const [id, j] = readIdent(cs, i)
    return reserved(id) ? undefined : [id, j]
  }
  return undefined
}
