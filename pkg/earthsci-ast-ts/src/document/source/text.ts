/**
 * Text scanning shared by the containers: prefixes, lines, and fenced bodies
 * ended by a closing line; and the input decoding.
 *
 * Port of `formal/Esm/Document/Source/Text.lean` and `Lines.lean` (after the
 * Rust binding's `document/source/text.rs` and `lines.rs`). Text is a code point
 * array read from an index, as in the other readers.
 */

import type { Chars } from '../number.js'

/** The text of `cs[a..b)`. */
export const str = (cs: Chars, a: number, b: number = cs.length): string => cs.slice(a, b).join('')

/**
 * `Source.pre` with a literal prefix: `p` occurs in `cs` at `i`. `p` holds no
 * character outside the Basic Multilingual Plane (each UTF-16 unit is one
 * character).
 */
export function preS(p: string, cs: Chars, i: number): boolean {
  if (i + p.length > cs.length) return false
  for (let k = 0; k < p.length; k++) if (cs[i + k] !== p[k]) return false
  return true
}

/** `Source.after` with a literal prefix: the index after `p` at `i`, when it is there. */
export function afterS(p: string, cs: Chars, i: number): number | undefined {
  return preS(p, cs, i) ? i + p.length : undefined
}

/** `Source.hasSub`: `p` occurs in `s`. */
export function hasSub(p: string, s: string): boolean {
  return s.includes(p)
}

/** The index of the first `c` at or after `i`, or the end. */
export function findChar(c: string, cs: Chars, i: number, end: number = cs.length): number {
  while (i < end && cs[i] !== c) i++
  return i
}

/**
 * `Source.splitLine`: the first line at `i` (its end index, without the newline)
 * and the index after it.
 */
export function splitLine(cs: Chars, i: number): [number, number] {
  const e = findChar('\n', cs, i)
  return [e, e < cs.length ? e + 1 : e]
}

/** `Source.noStop`: no line of `s` starts with `stop`. */
export function noStop(stop: string, s: string): boolean {
  if (s.startsWith(stop)) return false
  let i = s.indexOf('\n')
  while (i >= 0 && i + 1 < s.length) {
    if (s.startsWith(stop, i + 1)) return false
    i = s.indexOf('\n', i + 1)
  }
  return true
}

/**
 * `Source.untilStop`: lines up to the first one that starts with `stop`: the
 * lines before it (each with its newline), the rest of the closing line, and the
 * index after the closing line.
 */
export function untilStop(
  stop: string,
  cs: Chars,
  i: number,
): [string, string, number] | undefined {
  const start = i
  for (;;) {
    if (i >= cs.length) return undefined
    if (preS(stop, cs, i)) {
      const [e, next] = splitLine(cs, i + stop.length)
      return [str(cs, start, i), str(cs, i + stop.length, e), next]
    }
    i = splitLine(cs, i)[1]
  }
}

/** `l.all (· == ' ')`. */
export function blank(l: string): boolean {
  for (let k = 0; k < l.length; k++) if (l[k] !== ' ') return false
  return true
}

/** `t.takeWhile p`: the index after the run of characters at `i` that satisfy `p`. */
export function takeWhile(cs: Chars, i: number, p: (c: string) => boolean): number {
  while (i < cs.length && p(cs[i])) i++
  return i
}

/**
 * `Source.decodeText`: no byte-order mark, and LF line endings when the first
 * line ends in CRLF.
 */
export function decodeText(s: string): string {
  const d = s.startsWith('﻿') ? s.slice(1) : s
  // `Source.firstCRLF`: whether the first line ends in CRLF.
  const nl = d.indexOf('\n')
  const firstCrlf = nl > 0 && d[nl - 1] === '\r'
  return firstCrlf ? d.replace(/\r\n/g, '\n') : d
}
