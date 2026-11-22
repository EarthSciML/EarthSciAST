/**
 * LaTeX math: spelling and lexing of tokens.
 *
 * Port of `formal/Esm/Document/Math/Latex.lean` (after the Rust binding's
 * `document/math/latex.rs`). {@link render} spells a token list as LaTeX math,
 * writing a space between two tokens where the reader needs one (`needSpace`)
 * and where it reads better (`pretty`); {@link lex} reads it back, skipping
 * spaces and the spacing commands.
 *
 * The Lean lexer (`lexAux`, `skipWs`) carries fuel equal to the input length
 * plus one, never exhausted (every step consumes a character); the port loops
 * without it.
 */

import type { JNum } from '../json.js'
import { digitChar, parseIntTok, printNum, type Chars, type Read } from '../number.js'
import { escChar, unquoteBody } from '../strings.js'
import { isDig, isGreek, isLetter, letRun } from './expr.js'
import { atomStart, unitsOfRaw } from './parse.js'
import { charDigitNat, charOfNat, dig3, escT, keySpecial, rawB, unescT } from './print.js'
import { dropP, isBin, lexSigned, sciSplit } from './surface.js'
import {
  kw,
  tAcols,
  tEsc,
  tGreek,
  tIt,
  tJstr,
  tLetter,
  tOpn,
  tRm,
  tTxt,
  tUnits,
  tWord,
  type Kw,
  type Tok,
} from './token.js'
import { MATHRM_OPEN, latexBody, type Factor } from './units.js'

// ## Spelling

/** `Latex.specials`: characters of a JSON string written as a hex escape. */
export const SPECIALS: readonly string[] = ['%', '$', '#', '{', '}']

const hex4 = (n: number): string => n.toString(16).padStart(4, '0')

/** `Latex.escCharB`: the JSON escape of one character, with the specials as hex escapes. */
export function escCharB(c: string): string {
  return SPECIALS.includes(c) ? `\\u${hex4(c.codePointAt(0) ?? 0)}` : escChar(false, c)
}

/** `Latex.escCharL`: `_` as `\_`, otherwise {@link escCharB}. */
export function escCharL(c: string): string {
  return c === '_' ? '\\_' : escCharB(c)
}

/**
 * `Latex.fixUs`: undo the `\_` of `escCharL` up to the closing quote. Returns
 * the text up to and including the first bare `"` (the rest is unchanged by
 * `fixUs`), and the index after that quote (the input's end if there is none).
 */
export function fixUs(cs: Chars, i: number): [string[], number] {
  const out: string[] = []
  while (i < cs.length) {
    const c = cs[i]
    if (c === '\\' && i + 1 < cs.length) {
      if (cs[i + 1] === '_') out.push('_')
      else out.push('\\', cs[i + 1])
      i += 2
    } else if (c === '"') {
      out.push('"')
      return [out, i + 1]
    } else {
      out.push(c)
      i += 1
    }
  }
  return [out, i]
}

/** `Latex.quoteL`. */
export function quoteL(s: string): string {
  let out = '"'
  for (const c of s) out += escCharL(c)
  return `${out}"`
}

/** `Latex.strPlain`: a character of a JSON string written as itself inside `\text{…}`. */
export function strPlain(c: string): boolean {
  const n = c.codePointAt(0) ?? 0
  return n >= 32 && n <= 126 && !keySpecial(c) && c !== '_' && c !== '{' && c !== '}'
}

/** `Latex.dig7`: seven decimal digits. */
export function dig7(n: number): string {
  let out = ''
  for (const p of [1_000_000, 100_000, 10_000, 1000, 100, 10, 1])
    out += digitChar(Math.floor(n / p) % 10)
  return out
}

/** `Latex.escS`: the spelling of a JSON string's characters inside `\text{"…"}`. */
export function escS(s: string): string {
  let out = ''
  for (const c of s) {
    const n = c.codePointAt(0) ?? 0
    if (strPlain(c)) out += c
    else if (c === '_' || c === '{' || c === '}') out += `\\${c}`
    else if (n < 1000) out += `{\\char${dig3(n)}}`
    else out += `{\\char${dig7(n)}}`
  }
  return out
}

const CHAR_OPEN = ['{', '\\', 'c', 'h', 'a', 'r']

/** `Latex.unescS`: undo {@link escS}. */
export function unescS(cs: Chars): string {
  let out = ''
  let i = 0
  const open = (j: number): boolean => CHAR_OPEN.every((ch, k) => cs[j + k] === ch)
  while (i < cs.length) {
    if (open(i) && i + 9 < cs.length && cs[i + 9] === '}') {
      out += charOfNat(
        100 * charDigitNat(cs[i + 6]) + 10 * charDigitNat(cs[i + 7]) + charDigitNat(cs[i + 8]),
      )
      i += 10
    } else if (open(i) && i + 13 < cs.length && cs[i + 13] === '}') {
      let v = 0
      for (let k = 6; k < 13; k++) v = v * 10 + charDigitNat(cs[i + k])
      out += charOfNat(v)
      i += 14
    } else if (cs[i] === '\\' && i + 1 < cs.length) {
      out += cs[i + 1]
      i += 2
    } else {
      out += cs[i]
      i += 1
    }
  }
  return out
}

/** `Latex.strL`: a JSON string in LaTeX: `\text{"…"}`. */
export function strL(s: string): string {
  return `\\text{"${escS(s)}"}`
}

/** `Latex.textTok`: the token of `\text{raw}`: a JSON string when the text is double-quoted, else text. */
export function textTok(raw: Chars): Tok {
  if (raw.length >= 2 && raw[0] === '"' && raw[raw.length - 1] === '"')
    return tJstr(unescS(raw.slice(1, -1)))
  return tTxt(raw.join(''))
}

/** `Latex.timesTen`. */
export const TIMES_TEN = ' \\times 10^{'

/** `Latex.numChars`. */
export function numChars(n: JNum): string {
  const s = sciSplit(n)
  return s === undefined ? printNum(n) : `${s[0]}${TIMES_TEN}${s[1]}}`
}

const KW_CHARS: Record<Kw, string> = {
  Plus: '+',
  Minus: '-',
  Eq: '=',
  Ne: '\\ne',
  Lt: '<',
  Gt: '>',
  Le: '\\le',
  Ge: '\\ge',
  Land: '\\land',
  Lor: '\\lor',
  Lnot: '\\lnot',
  Cdot: '\\cdot',
  Times: '\\times',
  Slash: '/',
  Caret: '^',
  Us: '_',
  Lp: '(',
  Rp: ')',
  Lpg: '\\left(',
  Rpg: '\\right)',
  Lb: '{',
  Rb: '}',
  Lbk: '[',
  Rbk: ']',
  Comma: ',',
  Semi: ';',
  Colon: ':',
  Amp: '&',
  Nl: '\\\\',
  Sdot: '.',
  Frac: '\\frac',
  Sqrt: '\\sqrt',
  Exp: '\\exp',
  Ln: '\\ln',
  Log: '\\log',
  Sin: '\\sin',
  Cos: '\\cos',
  Tan: '\\tan',
  Asin: '\\arcsin',
  Acos: '\\arccos',
  Atan: '\\arctan',
  Sinh: '\\sinh',
  Cosh: '\\cosh',
  Tanh: '\\tanh',
  Min: '\\min',
  Max: '\\max',
  Labs: '\\left|',
  Rabs: '\\right|',
  Lfloor: '\\lfloor',
  Rfloor: '\\rfloor',
  Lceil: '\\lceil',
  Rceil: '\\rceil',
  Pdiff: '\\partial',
  Nabla: '\\nabla',
  Dotacc: '\\dot',
  Bcases: '\\begin{cases}',
  Ecases: '\\end{cases}',
  Bmat: '\\begin{bmatrix}',
  Emat: '\\end{bmatrix}',
  Sum: '\\sum',
  Prod: '\\prod',
  Inn: '\\in',
  Substack: '\\substack',
  LimitsL: '\\limits',
  Lbkg: '\\left[',
  Rbkg: '\\right]',
  Barr: '\\begin{array}{l|l}',
  Earr: '\\end{array}',
  Lset: '\\{',
  Rset: '\\}',
  Abs: '',
  Floor: '',
  Ceil: '',
  Dif: '',
  Cases: '',
  Esmnode: '',
  Vec: '',
  Mat: '',
  Lr: '',
  Limits: '',
}

/** `Latex.kwChars`. */
export function kwChars(k: Kw): string {
  return KW_CHARS[k]
}

/** `Latex.tokChars`. */
export function tokChars(t: Tok): string {
  switch (t.t) {
    case 'num':
      return numChars(t.n)
    case 'letter':
      return t.c
    case 'greek':
      return `\\${t.s}`
    case 'word':
      return t.s
    case 'it':
      return `\\mathit{${escT(t.s)}}`
    case 'rm':
      return `\\mathrm{${t.s}}`
    case 'opn':
      return `\\operatorname{${escT(t.s)}}`
    case 'txt':
      return `\\text{${t.s}}`
    case 'jstr':
      return strL(t.s)
    case 'esc':
      return `\\esm{${escT(t.s)}}`
    case 'units':
      return `\\,\\mathrm{${latexBody(t.l)}}`
    case 'kw':
      return kwChars(t.k)
    case 'acols':
      return `\\begin{array}{${'c'.repeat(t.n)}}`
    case 'ups':
    case 'code':
      return ''
  }
}

/** The first code point of a token's spelling. */
function firstChar(t: Tok): string | undefined {
  const s = tokChars(t)
  return s.length === 0 ? undefined : String.fromCodePoint(s.codePointAt(0) ?? 0)
}

// ## Spacing

/** `Latex.endsAlpha`: `t` ends with letters a following letter would extend. */
export function endsAlpha(t: Tok): boolean {
  switch (t.t) {
    case 'letter':
    case 'word':
    case 'greek':
      return true
    case 'kw': {
      const s = kwChars(t.k)
      return s.length > 0 && isLetter(s[s.length - 1])
    }
    default:
      return false
  }
}

/** `Latex.merges`: a space is needed between `t` and a following token starting with `c`. */
export function merges(t: Tok, c: string): boolean {
  return (
    (endsAlpha(t) && isLetter(c)) ||
    (t.t === 'num' && (isDig(c) || c === '.' || c === 'e')) ||
    (t.t === 'kw' && t.k === 'Minus' && isDig(c))
  )
}

/** `Latex.needSpace`. */
export function needSpace(t1: Tok, t2: Tok): boolean {
  const c = firstChar(t2)
  return c !== undefined && merges(t1, c)
}

const ATOM_END_KW: ReadonlySet<Kw> = new Set<Kw>([
  'Rp',
  'Rpg',
  'Rb',
  'Rbk',
  'Rabs',
  'Rfloor',
  'Rceil',
  'Ecases',
])

/** `Latex.atomEnd`: tokens that end an operand. */
export function atomEnd(t: Tok): boolean {
  switch (t.t) {
    case 'opn':
    case 'esc':
    case 'acols':
      return false
    case 'kw':
      return ATOM_END_KW.has(t.k)
    default:
      return true
  }
}

const isKwIn = (t: Tok, ...ks: Kw[]): boolean => t.t === 'kw' && ks.includes(t.k)

/** `Latex.pretty`: spacing for reading. */
export function pretty(p: Tok | undefined, t1: Tok, t2: Tok): boolean {
  return (
    isBin(t1) ||
    isBin(t2) ||
    isKwIn(t1, 'Comma', 'Colon', 'Semi') ||
    (isKwIn(t2, 'Minus') && atomEnd(t1)) ||
    (isKwIn(t1, 'Minus') && p !== undefined && atomEnd(p)) ||
    (atomEnd(t1) && atomStart(t2) && !isKwIn(t2, 'Lp', 'Lbk')) ||
    isKwIn(t1, 'Barr') ||
    isKwIn(t2, 'Earr')
  )
}

/** `Latex.sp`. */
export function sp(p: Tok | undefined, t1: Tok, t2: Tok): boolean {
  return needSpace(t1, t2) || pretty(p, t1, t2)
}

/** `Latex.render`: the LaTeX spelling of a token list (`renderAux`). */
export function render(ts: readonly Tok[]): string {
  let out = ''
  for (let i = 0; i < ts.length; i++) {
    out += tokChars(ts[i])
    if (i + 1 < ts.length && sp(i === 0 ? undefined : ts[i - 1], ts[i], ts[i + 1])) out += ' '
  }
  return out
}

// ## Lexing

/** `Latex.ctrlKw`: control words that are keywords, with the variants read on input. */
export const CTRL_KW: readonly (readonly [string, Kw])[] = [
  ['ne', 'Ne'],
  ['neq', 'Ne'],
  ['le', 'Le'],
  ['leq', 'Le'],
  ['ge', 'Ge'],
  ['geq', 'Ge'],
  ['land', 'Land'],
  ['lor', 'Lor'],
  ['lnot', 'Lnot'],
  ['cdot', 'Cdot'],
  ['times', 'Times'],
  ['frac', 'Frac'],
  ['sqrt', 'Sqrt'],
  ['exp', 'Exp'],
  ['ln', 'Ln'],
  ['log', 'Log'],
  ['sin', 'Sin'],
  ['cos', 'Cos'],
  ['tan', 'Tan'],
  ['arcsin', 'Asin'],
  ['arccos', 'Acos'],
  ['arctan', 'Atan'],
  ['sinh', 'Sinh'],
  ['cosh', 'Cosh'],
  ['tanh', 'Tanh'],
  ['min', 'Min'],
  ['max', 'Max'],
  ['lfloor', 'Lfloor'],
  ['rfloor', 'Rfloor'],
  ['lceil', 'Lceil'],
  ['rceil', 'Rceil'],
  ['partial', 'Pdiff'],
  ['nabla', 'Nabla'],
  ['dot', 'Dotacc'],
  ['sum', 'Sum'],
  ['prod', 'Prod'],
  ['in', 'Inn'],
  ['substack', 'Substack'],
  ['limits', 'LimitsL'],
]
const CTRL_KW_MAP: ReadonlyMap<string, Kw> = new Map(CTRL_KW)

/**
 * `Latex.arrCols`: after `\begin`: `{array}{` then one or more `c` then `}`, the
 * opener of a wide constant matrix, with its column count.
 */
export function arrCols(cs: Chars, i: number): Read<Tok> {
  const r = dropP('{array}{', cs, i)
  if (r === undefined) return undefined
  let j = r
  while (cs[j] === 'c') j++
  return j > r && cs[j] === '}' ? [tAcols(j - r), j + 1] : undefined
}

/** `Latex.ctrlTok`: after a control word `w` (the input continues at `i`): its token. */
export function ctrlTok(w: string, cs: Chars, i: number): Read<Tok> {
  if (w === 'mathit' || w === 'mathrm' || w === 'operatorname' || w === 'text' || w === 'esm') {
    if (cs[i] !== '{') return undefined
    const r = rawB(0, cs, i + 1)
    if (r === undefined) return undefined
    const [raw, rest] = r
    switch (w) {
      case 'mathit':
        return [tIt(unescT(raw)), rest]
      case 'mathrm':
        return [tRm(raw), rest]
      case 'operatorname':
        return [tOpn(unescT(raw)), rest]
      case 'text':
        return [textTok(Array.from(raw)), rest]
      default:
        return [tEsc(unescT(raw)), rest]
    }
  }
  if (w === 'left' || w === 'bigl' || w === 'Bigl') {
    const c = cs[i]
    if (c === '(') return [kw('Lpg'), i + 1]
    if (c === '[') return [kw(w === 'left' ? 'Lbkg' : 'Lbk'), i + 1]
    if (c === '|') return w === 'left' ? [kw('Labs'), i + 1] : undefined
    return undefined
  }
  if (w === 'right' || w === 'bigr' || w === 'Bigr') {
    const c = cs[i]
    if (c === ')') return [kw('Rpg'), i + 1]
    if (c === ']') return [kw(w === 'right' ? 'Rbkg' : 'Rbk'), i + 1]
    if (c === '|') return w === 'right' ? [kw('Rabs'), i + 1] : undefined
    return undefined
  }
  if (w === 'begin' || w === 'end') {
    const r = dropP('{cases}', cs, i)
    if (r !== undefined) return [kw(w === 'begin' ? 'Bcases' : 'Ecases'), r]
    const r2 = dropP('{bmatrix}', cs, i)
    if (r2 !== undefined) return [kw(w === 'begin' ? 'Bmat' : 'Emat'), r2]
    const r3 = dropP(w === 'begin' ? '{array}{l|l}' : '{array}', cs, i)
    if (r3 !== undefined) return [kw(w === 'begin' ? 'Barr' : 'Earr'), r3]
    return w === 'begin' ? arrCols(cs, i) : undefined
  }
  if (isGreek(w)) return [tGreek(w), i]
  const k = CTRL_KW_MAP.get(w)
  return k === undefined ? undefined : [kw(k), i]
}

/** `Latex.isWsL`: white space. */
export function isWsL(c: string | undefined): boolean {
  return c === ' ' || c === '\n' || c === '\t' || c === '\r'
}

/** `Latex.skipSp`: skip white space and the two-character spacing commands, inside a scientific tail. */
export function skipSp(cs: Chars, i: number): number {
  for (;;) {
    const c = cs[i]
    if (isWsL(c)) i++
    else if (c === '\\' && [';', ':', '!', ' ', ','].includes(cs[i + 1])) i += 2
    else return i
  }
}

/** `Latex.sciExp`: the scientific tail `\times 10^{exponent}` after a mantissa, with any spacing between its parts. */
export function sciExp(cs: Chars, i: number): Read<bigint> {
  const r1 = dropP('\\times', cs, skipSp(cs, i))
  if (r1 === undefined || isLetter(cs[r1])) return undefined
  const r2 = dropP('10', cs, skipSp(cs, r1))
  if (r2 === undefined) return undefined
  const r3 = skipSp(cs, r2)
  if (cs[r3] !== '^') return undefined
  const r4 = skipSp(cs, r3 + 1)
  if (cs[r4] !== '{') return undefined
  const z = parseIntTok(cs, skipSp(cs, r4 + 1))
  if (z === undefined) return undefined
  const r6 = skipSp(cs, z[1])
  return cs[r6] === '}' ? [z[0], r6 + 1] : undefined
}

/** `Latex.unitTok`: after `\,`: a unit `\mathrm{…}`, with white space between. */
export function unitTok(cs: Chars, i: number): Read<Factor[]> {
  while (isWsL(cs[i])) i++
  const r1 = dropP(MATHRM_OPEN, cs, i)
  if (r1 === undefined) return undefined
  const r = rawB(0, cs, r1)
  if (r === undefined) return undefined
  const l = unitsOfRaw(r[0])
  return l === undefined ? undefined : [l, r[1]]
}

const PUNCT: Readonly<Record<string, Kw>> = {
  '+': 'Plus',
  '-': 'Minus',
  '=': 'Eq',
  '<': 'Lt',
  '>': 'Gt',
  '/': 'Slash',
  '^': 'Caret',
  _: 'Us',
  '(': 'Lp',
  ')': 'Rp',
  '{': 'Lb',
  '}': 'Rb',
  '[': 'Lbk',
  ']': 'Rbk',
  ',': 'Comma',
  ';': 'Semi',
  ':': 'Colon',
  '&': 'Amp',
  '.': 'Sdot',
}

/** `Latex.punct`. */
export function punct(c: string): Kw | undefined {
  return Object.hasOwn(PUNCT, c) ? PUNCT[c] : undefined
}

/** `Latex.lexOne`: one token at `i`. */
export function lexOne(cs: Chars, i: number): Read<Tok> {
  const c = cs[i]
  if (c === undefined) return undefined
  if (c === '\\' && i + 1 < cs.length) {
    const d = cs[i + 1]
    if (isLetter(d)) {
      const e = letRun(cs, i + 1)
      return ctrlTok(cs.slice(i + 1, e).join(''), cs, e)
    }
    if (d === ',') {
      const u = unitTok(cs, i + 2)
      return u && [tUnits(u[0]), u[1]]
    }
    if (d === '\\') return [kw('Nl'), i + 2]
    if (d === '{') return [kw('Lset'), i + 2]
    if (d === '}') return [kw('Rset'), i + 2]
    return undefined
  }
  if (c === '"') {
    // `fixUs` changes nothing after the closing quote, so the rest is the
    // input's own suffix after that quote.
    const [fixed, after] = fixUs(cs, i + 1)
    const r = unquoteBody(false, fixed, 0)
    if (r === undefined) return undefined
    return [tJstr(r[0]), after - (fixed.length - r[1])]
  }
  if (isDig(c) || (c === '-' && isDig(cs[i + 1]))) return lexSigned(sciExp, cs, i)
  if (isLetter(c)) {
    const e = letRun(cs, i)
    return e - i === 1 ? [tLetter(c), e] : [tWord(cs.slice(i, e).join('')), e]
  }
  const k = punct(c)
  return k === undefined ? undefined : [kw(k), i + 1]
}

/** `Latex.skipWs`: skip spaces and the spacing commands (`\,` too, unless a unit follows it). */
export function skipWs(cs: Chars, i: number): number {
  for (;;) {
    const c = cs[i]
    if (isWsL(c)) {
      i++
      continue
    }
    if (c !== '\\' || i + 1 >= cs.length) return i
    const d = cs[i + 1]
    if (d === ';' || d === ':' || d === '!' || d === ' ') i += 2
    else if (d === ',') {
      if (unitTok(cs, i + 2) !== undefined) return i
      i += 2
    } else {
      const e = letRun(cs, i + 1)
      const w = cs.slice(i + 1, e).join('')
      if (w === 'quad' || w === 'qquad') i = e
      else return i
    }
  }
}

/** `Latex.lex`: read LaTeX math into tokens (`lexAux`). */
export function lex(cs: Chars): Tok[] | undefined {
  const out: Tok[] = []
  let i = 0
  for (;;) {
    i = skipWs(cs, i)
    if (i >= cs.length) return out
    const r = lexOne(cs, i)
    if (r === undefined) return undefined
    out.push(r[0])
    i = r[1]
  }
}
