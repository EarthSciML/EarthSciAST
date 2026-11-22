/**
 * Typst math: spelling and lexing of tokens.
 *
 * Port of `formal/Esm/Document/Math/Typst.lean` (after the Rust binding's
 * `document/math/typst.rs`). Typst has one parenthesis: the lexer reads `(`
 * right after a name, a digit, `)` or `"` as a call parenthesis and any other
 * `(` as a grouping one; the renderer writes no space between a function name
 * and its `(` and a space between an operand and a following grouping `(`.
 *
 * The Lean lexer (`lexAux`, `pieces`, `pSepBy`) carries fuel equal to the input
 * length, never exhausted (every step consumes a character); the port loops
 * without it.
 */

import type { JNum } from '../json.js'
import { parseIntTok, printNum, type Chars, type Read } from '../number.js'
import { parseQuoted, quote } from '../strings.js'
import { encode as encodeTypstValue, pVal as pTypstValue } from '../typst-dict.js'
import { digRun, isDig, isGreek, isLetter } from './expr.js'
import { atomStart } from './parse.js'
import { dropP, isBin, lexSigned, sciSplit } from './surface.js'
import {
  kw,
  tCode,
  tGreek,
  tIt,
  tLetter,
  tOpn,
  tTxt,
  tUnits,
  tUps,
  tWord,
  type Kw,
  type Tok,
} from './token.js'
import { THIN_SEP, joinWith, pSepBy, pTFactor, typstFactor, type Factor } from './units.js'

// ## Spelling

/** `Typst.timesTen`. */
export const TIMES_TEN = ' times 10^'

/** `Typst.numChars`. */
export function numChars(n: JNum): string {
  const s = sciSplit(n)
  if (s === undefined) return printNum(n)
  const [m, e] = s
  return e < 0 ? `${m}${TIMES_TEN}(${e})` : `${m}${TIMES_TEN}${e}`
}

const KW_CHARS: Record<Kw, string> = {
  Plus: '+',
  Minus: '-',
  Eq: '=',
  Ne: '!=',
  Lt: '<',
  Gt: '>',
  Le: '<=',
  Ge: '>=',
  Land: 'and',
  Lor: 'or',
  Lnot: 'not',
  Cdot: 'dot',
  Times: 'times',
  Slash: '/',
  Caret: '^',
  Us: '_',
  Lp: '(',
  Lpg: '(',
  Rp: ')',
  Lbk: '[',
  Rbk: ']',
  Comma: ',',
  Semi: ';',
  Colon: ':',
  Amp: '&',
  Sdot: '"."',
  Sqrt: 'sqrt',
  Exp: 'exp',
  Ln: 'ln',
  Log: 'log',
  Sin: 'sin',
  Cos: 'cos',
  Tan: 'tan',
  Asin: 'arcsin',
  Acos: 'arccos',
  Atan: 'arctan',
  Sinh: 'sinh',
  Cosh: 'cosh',
  Tanh: 'tanh',
  Min: 'min',
  Max: 'max',
  Abs: 'abs',
  Floor: 'floor',
  Ceil: 'ceil',
  Pdiff: 'partial',
  Nabla: 'nabla',
  Dif: 'dif',
  Cases: 'cases',
  Esmnode: 'esm.node',
  Vec: 'vec',
  Mat: 'mat',
  Sum: 'sum',
  Prod: 'product',
  Inn: 'in',
  Limits: 'limits',
  Lr: 'lr',
  Nl: '\\',
  Lset: '{',
  Rset: '}',
  Rpg: '',
  Lb: '',
  Rb: '',
  Frac: '',
  Labs: '',
  Rabs: '',
  Lfloor: '',
  Rfloor: '',
  Lceil: '',
  Rceil: '',
  Dotacc: '',
  Bcases: '',
  Ecases: '',
  Bmat: '',
  Emat: '',
  Substack: '',
  Lbkg: '',
  Rbkg: '',
  LimitsL: '',
  Barr: '',
  Earr: '',
}

/** `Typst.kwChars`. */
export function kwChars(k: Kw): string {
  return KW_CHARS[k]
}

/** `Typst.pieceChars`. */
export function pieceChars(p: readonly [string, string]): string {
  return `upright(${quote(true, p[0])})${p[1].length > 0 ? `_${p[1]}` : ''}`
}

/** `Typst.unitChars`. */
export function unitChars(l: readonly Factor[]): string {
  return `thin ${joinWith(typstFactor, THIN_SEP, l)}`
}

/** `Typst.tokChars`. */
export function tokChars(t: Tok): string {
  switch (t.t) {
    case 'num':
      return numChars(t.n)
    case 'letter':
      return t.c
    case 'greek':
    case 'word':
      return t.s
    case 'it':
      return `italic(${quote(true, t.s)})`
    case 'ups':
      return t.ps.map(pieceChars).join('')
    case 'opn':
      return `op(${quote(true, t.s)})`
    case 'txt':
      return quote(true, t.s)
    case 'code':
      return `#${encodeTypstValue(t.j)}`
    case 'units':
      return unitChars(t.l)
    case 'kw':
      return kwChars(t.k)
    case 'rm':
    case 'jstr':
    case 'esc':
    case 'acols':
      return ''
  }
}

/** The last code point of a string. */
function lastChar(s: string): string | undefined {
  if (s.length === 0) return undefined
  const c = s.charCodeAt(s.length - 1)
  return c >= 0xdc00 && c <= 0xdfff && s.length >= 2 ? s.slice(-2) : s[s.length - 1]
}

/** The first code point of a string. */
function firstChar(s: string): string | undefined {
  return s.length === 0 ? undefined : String.fromCodePoint(s.codePointAt(0) ?? 0)
}

// ## Spacing

/** `Typst.isIdC`. */
export function isIdC(c: string | undefined): boolean {
  return isLetter(c) || isDig(c)
}

/** `Typst.merges`: a space is needed between `t` and a following token starting with `c`. */
export function merges(t: Tok, c: string): boolean {
  const d = lastChar(tokChars(t))
  return (
    (d !== undefined && isLetter(d) && isIdC(c)) ||
    (t.t === 'num' && (isIdC(c) || c === '.')) ||
    (t.t === 'kw' && t.k === 'Minus' && isDig(c)) ||
    (t.t === 'ups' && (isDig(c) || c === 'u' || c === '_')) ||
    (t.t === 'code' && isIdC(c)) ||
    (t.t === 'units' && (isDig(c) || c === '^')) ||
    (t.t === 'kw' && (t.k === 'Lt' || t.k === 'Gt') && c === '=') ||
    (t.t === 'kw' && t.k === 'Slash' && c === '/')
  )
}

/** `Typst.callEnd`: `t` ends with a character after which `(` is a call parenthesis. */
export function callEnd(t: Tok): boolean {
  const d = lastChar(tokChars(t))
  return d !== undefined && (isIdC(d) || d === ')' || d === '"')
}

/** `Typst.needSpace`. */
export function needSpace(t1: Tok, t2: Tok): boolean {
  if (t2.t === 'kw' && t2.k === 'Lpg') return callEnd(t1)
  if (t2.t === 'kw' && t2.k === 'Lp') return false
  const c = firstChar(tokChars(t2))
  return c !== undefined && merges(t1, c)
}

/** `Typst.atomEnd`. */
export function atomEnd(t: Tok): boolean {
  switch (t.t) {
    case 'rm':
    case 'opn':
    case 'jstr':
    case 'esc':
    case 'acols':
      return false
    case 'kw':
      return t.k === 'Rp' || t.k === 'Rbk'
    default:
      return true
  }
}

const HEAD_KW: ReadonlySet<Kw> = new Set<Kw>([
  'Sqrt',
  'Exp',
  'Ln',
  'Log',
  'Sin',
  'Cos',
  'Tan',
  'Asin',
  'Acos',
  'Atan',
  'Sinh',
  'Cosh',
  'Tanh',
  'Min',
  'Max',
  'Abs',
  'Floor',
  'Ceil',
  'Cases',
  'Esmnode',
  'Cdot',
  'Vec',
  'Mat',
])

/** `Typst.isHead`: function names: no space before their `(`. */
export function isHead(t: Tok): boolean {
  return t.t === 'opn' || (t.t === 'kw' && HEAD_KW.has(t.k))
}

const isKwIn = (t: Tok, ...ks: Kw[]): boolean => t.t === 'kw' && ks.includes(t.k)

/** `Typst.pretty`. */
export function pretty(p: Tok | undefined, t1: Tok, t2: Tok): boolean {
  return (
    isBin(t1) ||
    isBin(t2) ||
    isKwIn(t1, 'Comma', 'Colon', 'Semi') ||
    (isKwIn(t2, 'Minus') && atomEnd(t1)) ||
    (isKwIn(t1, 'Minus') && p !== undefined && atomEnd(p)) ||
    (atomEnd(t1) && atomStart(t2)) ||
    t2.t === 'units'
  )
}

/** `Typst.sp`: no space before a call parenthesis, nor before the `[` of an index. */
export function sp(p: Tok | undefined, t1: Tok, t2: Tok): boolean {
  return (
    needSpace(t1, t2) ||
    (pretty(p, t1, t2) && !isKwIn(t2, 'Lp') && !(isKwIn(t2, 'Lbk') && atomEnd(t1)))
  )
}

/** `Typst.render` (`renderAux`). */
export function render(ts: readonly Tok[]): string {
  let out = ''
  for (let i = 0; i < ts.length; i++) {
    out += tokChars(ts[i])
    if (i + 1 < ts.length && sp(i === 0 ? undefined : ts[i - 1], ts[i], ts[i + 1])) out += ' '
  }
  return out
}

// ## Lexing

/** `Typst.idRun`: the end of the maximal run of identifier characters at `i`. */
export function idRun(cs: Chars, i: number): number {
  while (isIdC(cs[i])) i++
  return i
}

/** `Typst.identKw`. */
export const IDENT_KW: readonly (readonly [string, Kw])[] = [
  ['and', 'Land'],
  ['or', 'Lor'],
  ['not', 'Lnot'],
  ['dot', 'Cdot'],
  ['times', 'Times'],
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
  ['abs', 'Abs'],
  ['floor', 'Floor'],
  ['ceil', 'Ceil'],
  ['partial', 'Pdiff'],
  ['nabla', 'Nabla'],
  ['dif', 'Dif'],
  ['cases', 'Cases'],
  ['vec', 'Vec'],
  ['mat', 'Mat'],
  ['sum', 'Sum'],
  ['product', 'Prod'],
  ['in', 'Inn'],
  ['limits', 'Limits'],
  ['lr', 'Lr'],
]
const IDENT_KW_MAP: ReadonlyMap<string, Kw> = new Map(IDENT_KW)

/** `Typst.quotedArg`: `("…")` after a function name. */
export function quotedArg(cs: Chars, i: number): Read<string> {
  if (cs[i] !== '(') return undefined
  const r = parseQuoted(true, cs, i + 1)
  return r !== undefined && cs[r[1]] === ')' ? [r[0], r[1] + 1] : undefined
}

/** `Typst.pieces`: adjacent `upright("…")` pieces, each with an optional digit subscript. */
export function uprightPieces(cs: Chars, i: number): [[string, string][], number] {
  const out: [string, string][] = []
  for (;;) {
    const r = dropP('upright', cs, i)
    if (r === undefined) return [out, i]
    const q = quotedArg(cs, r)
    if (q === undefined) return [out, i]
    const [s, r1] = q
    let d = ''
    let rest = r1
    if (cs[r1] === '_') {
      const e = digRun(cs, r1 + 1)
      if (e > r1 + 1) {
        d = cs.slice(r1 + 1, e).join('')
        rest = e
      }
    }
    out.push([s, d])
    i = rest
  }
}

/** `Typst.isWsT`. */
export function isWsT(c: string | undefined): boolean {
  return c === ' ' || c === '\n' || c === '\t' || c === '\r'
}

function skip(cs: Chars, i: number): number {
  while (isWsT(cs[i])) i++
  return i
}

/**
 * `Typst.sciExp`: the scientific tail `times 10^exponent` after a mantissa (the
 * exponent bare or in parentheses), with any white space between its parts.
 */
export function sciExp(cs: Chars, i: number): Read<bigint> {
  const r1 = dropP('times', cs, skip(cs, i))
  if (r1 === undefined || isIdC(cs[r1])) return undefined
  const r2 = dropP('10', cs, skip(cs, r1))
  if (r2 === undefined) return undefined
  const r3 = skip(cs, r2)
  if (cs[r3] !== '^') return undefined
  const r4 = skip(cs, r3 + 1)
  if (cs[r4] === '(') {
    const z = parseIntTok(cs, skip(cs, r4 + 1))
    if (z === undefined) return undefined
    const r6 = skip(cs, z[1])
    return cs[r6] === ')' ? [z[0], r6 + 1] : undefined
  }
  return parseIntTok(cs, r4)
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
  ')': 'Rp',
  '[': 'Lbk',
  ']': 'Rbk',
  ',': 'Comma',
  ';': 'Semi',
  ':': 'Colon',
  '&': 'Amp',
  '.': 'Sdot',
  '\\': 'Nl',
  '{': 'Lset',
  '}': 'Rset',
}

/** `Typst.punct`. */
export function punct(c: string): Kw | undefined {
  return Object.hasOwn(PUNCT, c) ? PUNCT[c] : undefined
}

/** `Typst.uprightE`: `upright(e)`, Euler's number written without quotes. */
export function uprightE(cs: Chars, i: number): Read<Tok> {
  return cs[i] === '(' && cs[i + 1] === 'e' && cs[i + 2] === ')'
    ? [tUps([['e', '']]), i + 3]
    : undefined
}

/** `Typst.lexIdent`: one identifier-started token. */
export function lexIdent(cs: Chars, i: number): Read<Tok> {
  const e = idRun(cs, i)
  const w = cs.slice(i, e).join('')
  switch (w) {
    case 'upright': {
      const q = uprightE(cs, e)
      if (q !== undefined) return q
      const [ps, r] = uprightPieces(cs, i)
      return ps.length === 0 ? undefined : [tUps(ps), r]
    }
    case 'italic': {
      const q = quotedArg(cs, e)
      return q && [tIt(q[0]), q[1]]
    }
    case 'op': {
      const q = quotedArg(cs, e)
      return q && [tOpn(q[0]), q[1]]
    }
    case 'thin': {
      if (cs[e] !== ' ') return undefined
      const r = pSepBy(pTFactor, THIN_SEP, cs, e + 1)
      return r && [tUnits(r[0]), r[1]]
    }
    case 'esm': {
      const r = dropP('.node', cs, e)
      return r === undefined ? undefined : [kw('Esmnode'), r]
    }
  }
  const k = IDENT_KW_MAP.get(w)
  if (k !== undefined) return [kw(k), e]
  if (isGreek(w)) return [tGreek(w), e]
  return e - i === 1 ? [tLetter(w), e] : [tWord(w), e]
}

/**
 * `Typst.lexOne`: one token at `i`; `prev` is the character just before it, if
 * no space came between.
 */
export function lexOne(prev: string | undefined, cs: Chars, i: number): Read<Tok> {
  const c = cs[i]
  if (c === undefined) return undefined
  if (c === '(') {
    return prev !== undefined && (isIdC(prev) || prev === ')' || prev === '"')
      ? [kw('Lp'), i + 1]
      : [kw('Lpg'), i + 1]
  }
  if (c === '"') {
    const r = parseQuoted(true, cs, i)
    return r && (r[0] === '.' ? [kw('Sdot'), r[1]] : [tTxt(r[0]), r[1]])
  }
  if (c === '#') {
    const r = pTypstValue(cs, i + 1)
    return r && [tCode(r[0]), r[1]]
  }
  const d = cs[i + 1]
  if (d === '=') {
    if (c === '<') return [kw('Le'), i + 2]
    if (c === '>') return [kw('Ge'), i + 2]
    if (c === '!') return [kw('Ne'), i + 2]
  }
  if (isDig(c) || (c === '-' && isDig(d))) return lexSigned(sciExp, cs, i)
  if (isLetter(c)) return lexIdent(cs, i)
  const k = punct(c)
  return k === undefined ? undefined : [kw(k), i + 1]
}

/**
 * `Typst.lex`: read Typst math into tokens (`lexAux`). `prev` is the last
 * character of the previous token's canonical spelling when no space came
 * between.
 */
export function lex(cs: Chars): Tok[] | undefined {
  const out: Tok[] = []
  let prev: string | undefined
  let i = 0
  for (;;) {
    const prev2 = isWsT(cs[i]) ? undefined : prev
    i = skip(cs, i)
    if (i >= cs.length) return out
    const r = lexOne(prev2, cs, i)
    if (r === undefined) return undefined
    prev = lastChar(tokChars(r[0]))
    out.push(r[0])
    i = r[1]
  }
}
