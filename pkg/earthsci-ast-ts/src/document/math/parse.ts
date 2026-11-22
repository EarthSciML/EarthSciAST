/**
 * The parser: tokens to expressions.
 *
 * Port of `formal/Esm/Document/Math/Parse.lean` (and `parseToks` from
 * Induct.lean), after the Rust binding's `document/math/parse.rs`. Recursive
 * descent with one function per precedence level (see `print.ts`), each taking
 * fuel exactly as in Lean: a function at fuel 0 fails, and every call passes on
 * the fuel its Lean definition passes. The chain loops (`orLoop`, `addLoop`, …)
 * are loops here, spending one unit of fuel per iteration as the Lean recursion
 * does. The helpers whose fuel only serves termination and is given as the
 * input length (`pNameLoop`, `pNames`, `pGrid`, `pCells`) loop without it.
 *
 * A token list is read from an index: a parser takes the list and the index of
 * its first token and returns the value and the index after it.
 */

import {
  jarr,
  jnum,
  jnumWfb,
  jobj,
  jstr,
  JFALSE,
  JNULL,
  JTRUE,
  mkInt,
  type JNum,
  type Json,
} from '../json.js'
import type { Chars } from '../number.js'
import {
  DEPRECATED_OPS,
  REMOVED_OPS,
  isFormula,
  isGreek,
  isLetter,
  opOk,
  pieces,
  type Sym,
} from './expr.js'
import {
  CALL_OPS,
  faqJson,
  formulaRaw,
  insKv,
  mkJson,
  mkNode,
  node,
  simpleTok,
  tnameOk,
  tparams,
  BMAT_MAX_COLS,
  callFormNode,
  unescK,
  unescT,
  type Ctx,
  type FaqForm,
  type RedK,
} from './print.js'
import { nested, removedOp, shallow } from '../limits.js'
import { negNum } from './surface.js'
import { isKwTok, tNum, tokEq, type Kw, type Sf, type Tok } from './token.js'
import {
  MATHRM_OPEN,
  parseLatex as unitsParseLatex,
  spellUnitFactors,
  type Factor,
} from './units.js'

type Kv = readonly [string, Json]

/** A parse result: the value and the index of the rest of the tokens. */
export type P<T> = [T, number] | undefined

/** Named ranges (`List (String × Json)`). */
export type Ranges = Kv[]

type Toks = readonly Tok[]

// ## Small pieces

/** The keyword of the token at `i`, if it is one. */
function kwAt(ts: Toks, i: number): Kw | undefined {
  const t = ts[i]
  return t !== undefined && t.t === 'kw' ? t.k : undefined
}

/** `Math.expect`. */
export function expect(k: Kw, ts: Toks, i: number): number | undefined {
  return kwAt(ts, i) === k ? i + 1 : undefined
}

/** `Math.close`: close an n-ary chain: one operand is itself, more make a node. */
export function close(o: string, xs: Json[]): Json {
  return xs.length === 1 ? xs[0] : node(o, xs)
}

/** `Math.cmpOf`: the comparison a token spells. */
export function cmpOf(k: Kw): string | undefined {
  switch (k) {
    case 'Lt':
      return '<'
    case 'Le':
      return '<='
    case 'Gt':
      return '>'
    case 'Ge':
      return '>='
    case 'Eq':
      return '=='
    case 'Ne':
      return '!='
    default:
      return undefined
  }
}

const FN_OF: Partial<Record<Kw, string>> = {
  Exp: 'exp',
  Ln: 'log',
  Sin: 'sin',
  Cos: 'cos',
  Tan: 'tan',
  Asin: 'asin',
  Acos: 'acos',
  Atan: 'atan',
  Sinh: 'sinh',
  Cosh: 'cosh',
  Tanh: 'tanh',
}

/** `Math.fnOf`: the unary function a keyword spells. */
export function fnOf(k: Kw): string | undefined {
  return FN_OF[k]
}

const ATOM_START_KW: ReadonlySet<Kw> = new Set<Kw>([
  'Lpg',
  'Lp',
  'Lbk',
  'Lnot',
  'Frac',
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
  'Labs',
  'Lfloor',
  'Lceil',
  'Abs',
  'Floor',
  'Ceil',
  'Dotacc',
  'Bcases',
  'Cases',
  'Esmnode',
  'Bmat',
  'Vec',
  'Mat',
  'Sum',
  'Prod',
  'Limits',
  'Lbkg',
  'Lr',
  'Nabla',
  'Pdiff',
])

/** `Math.atomStart`: tokens that can start an operand of a product. */
export function atomStart(t: Tok): boolean {
  switch (t.t) {
    case 'num':
    case 'letter':
    case 'greek':
    case 'word':
    case 'it':
    case 'rm':
    case 'ups':
    case 'opn':
    case 'txt':
    case 'esc':
      return true
    case 'kw':
      return ATOM_START_KW.has(t.k)
    default:
      return false
  }
}

/** `Math.isLp`: `(` or `\left(`. */
export function isLp(t: Tok | undefined): boolean {
  return t !== undefined && t.t === 'kw' && (t.k === 'Lp' || t.k === 'Lpg')
}

/** `Math.isRp`: `)` or `\right)`. */
export function isRp(t: Tok | undefined): boolean {
  return t !== undefined && t.t === 'kw' && (t.k === 'Rp' || t.k === 'Rpg')
}

/** `Math.isKw`: the token is the keyword `k`. */
export function isKw(k: Kw, t: Tok | undefined): boolean {
  return isKwTok(t, k)
}

// ## Names

/** `Math.decodeFormula`. */
export function decodeFormula(raw: string): string {
  let out = ''
  for (const c of raw) if (c !== '_' && c !== '{' && c !== '}') out += c
  return out
}

/** `Math.formulaOf`: the name a formula token spells, if it is formula-shaped. */
export function formulaOf(sf: Sf, t: Tok): string | undefined {
  if (t.t === 'rm' && sf === 'latex') {
    const g = decodeFormula(t.s)
    return isFormula(g) && formulaRaw(g) === t.s ? g : undefined
  }
  if (t.t === 'ups' && sf === 'typst') {
    const g = t.ps.map((p) => p[0] + p[1]).join('')
    const back = pieces(g)
    const same =
      back.length === t.ps.length &&
      back.every((p, i) => p[0] === t.ps[i][0] && p[1] === t.ps[i][1])
    return isFormula(g) && same ? g : undefined
  }
  return undefined
}

/** `Math.subOrPlain`: a single letter or Greek base, then an optional upright name subscript. */
export function subOrPlain(sf: Sf, b: string, ts: Toks, i: number): [string, number] {
  if (isKwTok(ts[i], 'Us')) {
    const t3 = ts[i + 2]
    if (sf === 'latex' && isKwTok(ts[i + 1], 'Lb') && t3?.t === 'rm' && isKwTok(ts[i + 3], 'Rb')) {
      return [`${b}_${unescT(t3.s)}`, i + 4]
    }
    if (
      sf === 'typst' &&
      isKwTok(ts[i + 1], 'Lpg') &&
      t3?.t === 'ups' &&
      isKwTok(ts[i + 3], 'Rp') &&
      t3.ps.length === 1 &&
      t3.ps[0][1] === ''
    ) {
      return [`${b}_${t3.ps[0][0]}`, i + 4]
    }
  }
  return [b, i]
}

/** `Math.pSeg`: one name segment. */
export function pSeg(sf: Sf, ts: Toks, i: number): P<string> {
  const t = ts[i]
  if (t === undefined) return undefined
  switch (t.t) {
    case 'letter':
      return isLetter(t.c) ? subOrPlain(sf, t.c, ts, i + 1) : undefined
    case 'greek':
      return isGreek(t.s) ? subOrPlain(sf, t.s, ts, i + 1) : undefined
    case 'it':
      return [t.s, i + 1]
    default: {
      const g = formulaOf(sf, t)
      return g === undefined ? undefined : [g, i + 1]
    }
  }
}

/**
 * `Math.pName`: a name: segments joined by the scope dot (`pNameLoop` as a
 * loop; its fuel, the input length, is never exhausted).
 */
export function pName(sf: Sf, ts: Toks, i: number): P<string> {
  const first = pSeg(sf, ts, i)
  if (first === undefined) return undefined
  let [acc, r] = first
  while (isKwTok(ts[r], 'Sdot')) {
    const g = pSeg(sf, ts, r + 1)
    if (g === undefined) return undefined
    acc += `.${g[0]}`
    r = g[1]
  }
  return [acc, r]
}

// ## JSON inside LaTeX escape nodes

/** `Math.pJson`. */
export function pJson(f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  return nested(() => pJsonIn(f - 1, ts, i))
}

function pJsonIn(f: number, ts: Toks, i: number): P<Json> {
  const t = ts[i]
  if (t === undefined) return undefined
  switch (t.t) {
    case 'word':
      if (t.s === 'null') return [JNULL, i + 1]
      if (t.s === 'true') return [JTRUE, i + 1]
      if (t.s === 'false') return [JFALSE, i + 1]
      return undefined
    case 'num':
      return [jnum(t.n), i + 1]
    case 'jstr':
      return [jstr(t.s), i + 1]
    case 'kw':
      if (t.k === 'Lbk') {
        if (isKwTok(ts[i + 1], 'Rbk')) return [jarr([]), i + 2]
        const r = pJsonItems(f, ts, i + 1)
        return r !== undefined && isKwTok(ts[r[1]], 'Rbk') ? [jarr(r[0]), r[1] + 1] : undefined
      }
      if (t.k === 'Lb') {
        if (isKwTok(ts[i + 1], 'Rb')) return [jobj([]), i + 2]
        const r = pJsonEntries(f, ts, i + 1)
        return r !== undefined && isKwTok(ts[r[1]], 'Rb') ? [jobj(r[0]), r[1] + 1] : undefined
      }
      return undefined
    default:
      return undefined
  }
}

/** `Math.pJsonItems`. */
export function pJsonItems(f: number, ts: Toks, i: number): P<Json[]> {
  const out: Json[] = []
  for (;;) {
    if (f === 0) return undefined
    f -= 1
    const r = pJson(f, ts, i)
    if (r === undefined) return undefined
    out.push(r[0])
    if (!isKwTok(ts[r[1]], 'Comma')) return [out, r[1]]
    i = r[1] + 1
  }
}

/** `Math.pJsonEntries`. */
export function pJsonEntries(f: number, ts: Toks, i: number): P<Kv[]> {
  const out: Kv[] = []
  for (;;) {
    if (f === 0) return undefined
    f -= 1
    const k = ts[i]
    if (k?.t !== 'jstr' || !isKwTok(ts[i + 1], 'Colon')) return undefined
    const r = pJson(f, ts, i + 2)
    if (r === undefined) return undefined
    out.push([k.s, r[0]])
    if (!isKwTok(ts[r[1]], 'Comma')) return [out, r[1]]
    i = r[1] + 1
  }
}

// ## Negative literals after an operand

/** `Math.negTok`: a negative literal token. */
export function negTok(t: Tok): boolean {
  return t.t === 'num' && negNum(t.n)
}

/** `Math.negate`: the number with the opposite sign. */
export function negate(n: JNum): JNum {
  return n.k === 'int' ? mkInt(-n.v) : { k: 'dec', neg: !n.neg, digits: n.digits, e10: n.e10 }
}

/**
 * `Math.negTail`: a negative literal right after an operand is a binary minus
 * and a positive number. Returns the number without its sign; the tokens after
 * it are the input's own (Lean returns the list with the number replaced).
 */
export function negTail(ts: Toks, i: number): JNum | undefined {
  const t = ts[i]
  if (t?.t !== 'num') return undefined
  const m = negate(t.n)
  return negNum(t.n) && jnumWfb(m) ? m : undefined
}

// ## Expressions

/** `Math.mkNodeP`: rebuild a node with fields. */
export function mkNodeP(o: string, args: readonly Json[], fs: readonly Kv[]): Json {
  return mkNode(o, args, fs)
}

/** `Math.CallArg`: what `pCallArgs` read. */
export type CallArg =
  | { readonly k: 'pos'; readonly v: Json }
  | { readonly k: 'named'; readonly key: string; readonly v: Json }

/** `Math.allPos`. */
export function allPos(xs: readonly CallArg[]): Json[] | undefined {
  const out: Json[] = []
  for (const a of xs) {
    if (a.k !== 'pos') return undefined
    out.push(a.v)
  }
  return out
}

/** `Math.allNamed`. */
export function allNamed(xs: readonly CallArg[]): Kv[] | undefined {
  const out: Kv[] = []
  for (const a of xs) {
    if (a.k !== 'named') return undefined
    out.push([a.key, a.v])
  }
  return out
}

/** `Math.sortKV`: sort bindings by key (insertion from the right, so equal keys keep their order). */
export function sortKv(xs: readonly Kv[]): Kv[] {
  let out: Kv[] = []
  for (let i = xs.length - 1; i >= 0; i--) out = insKv(xs[i], out)
  return out
}

/** `Math.unitsOfRaw`: the unit a LaTeX `\mathrm{…}` after a number spells. */
export function unitsOfRaw(raw: string): Factor[] | undefined {
  return unitsParseLatex(Array.from(`${MATHRM_OPEN}${raw}}`))
}

/** `Math.qty`: a quantity node. */
export function qty(n: JNum, l: readonly Factor[]): Json {
  return jobj([
    ['args', jarr([])],
    ['op', jstr('const')],
    ['units', jstr(spellUnitFactors(l))],
    ['value', jnum(n)],
  ])
}

/** `Math.dNode`: a time-derivative node (`dNode x "t"`). */
export function dNode(x: Json, w: string): Json {
  return jobj([
    ['args', jarr([x])],
    ['op', jstr('D')],
    ['wrt', jstr(w)],
  ])
}

/** `Math.pNode`: a `partial` node, the spatial derivative (spec §4.2). */
export function pNode(x: Json, w: string): Json {
  return jobj([
    ['args', jarr([x])],
    ['op', jstr('partial')],
    ['wrt', jstr(w)],
  ])
}

/**
 * `Math.derivNode`: the derivative a fraction of differentials reads as: the
 * time derivative `D` along `t`, `partial` along any other axis.
 */
export function derivNode(x: Json, w: string): Json {
  return w === 't' ? dNode(x, 't') : pNode(x, w)
}

/** `Math.tNode`: a reference node (`apply_operator`, spec §9.6.2). */
export function tNode(n: string, bs: readonly Kv[]): Json {
  return jobj([
    ['args', jarr([])],
    ['bindings', jobj(bs)],
    ['name', jstr(n)],
    ['op', jstr('apply_operator')],
  ])
}

/** `Math.constNode`: the value, and the units when there are some. */
export function constNode(v: Json, u: string | undefined): Json {
  return u === undefined
    ? jobj([
        ['args', jarr([])],
        ['op', jstr('const')],
        ['value', v],
      ])
    : jobj([
        ['args', jarr([])],
        ['op', jstr('const')],
        ['units', jstr(u)],
        ['value', v],
      ])
}

/** `Math.pCells`: numbers separated by `sep`, up to the first other token. */
export function pCells(sep: Kw, ts: Toks, i: number): P<JNum[]> {
  const out: JNum[] = []
  for (;;) {
    const t = ts[i]
    if (t?.t !== 'num') return undefined
    out.push(t.n)
    const k = kwAt(ts, i + 1)
    if (k === undefined) return [out, i + 1]
    if (k !== sep) return [out, i + 1]
    i += 2
  }
}

/** `Math.pGrid`: rows of numbers: cells separated by `csep`, rows by `rsep`, closed by `close`. */
export function pGrid(csep: Kw, rsep: Kw, closeK: Kw, ts: Toks, i: number): P<JNum[][]> {
  const out: JNum[][] = []
  for (;;) {
    const r = pCells(csep, ts, i)
    if (r === undefined) return undefined
    const k = kwAt(ts, r[1])
    if (k === undefined) return undefined
    out.push(r[0])
    if (k === rsep) i = r[1] + 1
    else if (k === closeK) return [out, r[1] + 1]
    else return undefined
  }
}

/** `Math.gridJson`: a LaTeX `bmatrix`: one cell per row is a column (rank 1). */
export function gridJson(rows: readonly JNum[][]): Json {
  if (rows.every((r) => r.length === 1)) return jarr(rows.map((r) => jnum(r[0] ?? mkInt(0))))
  return jarr(rows.map((r) => jarr(r.map(jnum))))
}

/** `Math.constTail`: the unit after an array, if any. */
export function constTail(v: Json, ts: Toks, i: number): P<Json> {
  const t = ts[i]
  if (t?.t === 'units') return [constNode(v, spellUnitFactors(t.l)), i + 1]
  return [constNode(v, undefined), i]
}

const isInt = (t: Tok | undefined, v: bigint): boolean =>
  t?.t === 'num' && t.n.k === 'int' && t.n.v === v

/** `Math.icTailP`: the `ic` tail `(t_{0})` / `(t_0)`. */
export function icTailP(sf: Sf, ts: Toks, i: number): number | undefined {
  const t1 = ts[i + 1]
  if (!(isKwTok(ts[i], 'Lp') && t1?.t === 'letter' && t1.c === 't' && isKwTok(ts[i + 2], 'Us')))
    return undefined
  const j = i + 3
  if (sf === 'latex') {
    return isKwTok(ts[j], 'Lb') &&
      isInt(ts[j + 1], 0n) &&
      isKwTok(ts[j + 2], 'Rb') &&
      isKwTok(ts[j + 3], 'Rp')
      ? j + 4
      : undefined
  }
  return isInt(ts[j], 0n) && isKwTok(ts[j + 1], 'Rp') ? j + 2 : undefined
}

/** `Math.jsonStart`: a LaTeX field value that is JSON starts with `{`, `[`, a string or a word. */
export function jsonStart(ts: Toks, i: number): boolean {
  const t = ts[i]
  return (
    t !== undefined && (isKwTok(t, 'Lb') || isKwTok(t, 'Lbk') || t.t === 'jstr' || t.t === 'word')
  )
}

/** `Math.keyOf`: a field key: LaTeX `\mathrm{key} =`, Typst `upright("key") =`. */
export function keyOf(c: Ctx, ts: Toks, i: number): P<string> {
  const t = ts[i]
  if (t === undefined || !isKwTok(ts[i + 1], 'Eq')) return undefined
  if (c.sf === 'latex' && t.t === 'rm') return [unescK(t.s), i + 2]
  if (c.sf === 'typst' && t.t === 'ups' && t.ps.length === 1 && t.ps[0][1] === '')
    return [t.ps[0][0], i + 2]
  return undefined
}

/** `Math.dCallNode`: `partial` with trailing operands. */
export function dCallNode(w: string, xs: readonly Json[]): Json {
  return jobj([
    ['args', jarr(xs)],
    ['op', jstr('partial')],
    ['wrt', jstr(w)],
  ])
}

function declared(c: Ctx, n: string): boolean {
  return c.s.names.includes(n)
}

/** `Math.eulerHead`: the input starts with Euler's number raised to a power. */
export function eulerHead(c: Ctx, ts: Toks, i: number): boolean {
  const t = ts[i]
  if (t === undefined || !isKwTok(ts[i + 1], 'Caret')) return false
  switch (t.t) {
    case 'rm':
      return t.s === 'e'
    case 'ups':
      return t.ps.length === 1 && t.ps[0][0] === 'e' && t.ps[0][1] === ''
    case 'letter':
      return t.c === 'e' && !declared(c, 'e')
    default:
      return false
  }
}

/** `Math.pNamePrim`: a name, or an initial condition `N(t_{0})`. */
export function pNamePrim(c: Ctx, ts: Toks, i: number): P<Json> {
  const r = pName(c.sf, ts, i)
  if (r === undefined) return undefined
  const [n, j] = r
  const r2 = icTailP(c.sf, ts, j)
  return r2 !== undefined ? [node('ic', [jstr(n)]), r2] : [jstr(n), j]
}

/**
 * `Math.pWord`: a bare run of letters: the declared name when only it is
 * declared, the product of its letters when only they are.
 */
export function pWord(c: Ctx, w: string, i: number): P<Json> {
  const whole = declared(c, w)
  const cs = Array.from(w)
  const letters = cs.every((ch) => declared(c, ch))
  if (whole && !letters) return [jstr(w), i]
  if (letters && !whole) return [node('*', cs.map(jstr)), i]
  return undefined
}

/** `Math.dName`: `d` then a name, up to a closing token `k`. */
export function dName(c: Ctx, k: Kw, ts: Toks, i: number): P<string> {
  const t = ts[i]
  if (t?.t === 'word') {
    if (kwAt(ts, i + 1) === undefined) return undefined
    if (kwAt(ts, i + 1) === k && !declared(c, t.s)) {
      const cs = Array.from(t.s)
      return cs[0] === 'd' ? [cs.slice(1).join(''), i + 2] : undefined
    }
    return undefined
  }
  if (t?.t === 'letter' && t.c === 'd') {
    const r = pName(c.sf, ts, i + 1)
    if (r === undefined) return undefined
    return kwAt(ts, r[1]) === k ? [r[0], r[1] + 1] : undefined
  }
  return undefined
}

/** `Math.pItalicD`: the italic-d derivative variant. */
export function pItalicD(c: Ctx, ts: Toks, i: number): P<Json> {
  if (declared(c, 'd')) return undefined
  if (c.sf === 'latex') {
    const r = dName(c, 'Rb', ts, i)
    if (r === undefined || !isKwTok(ts[r[1]], 'Lb')) return undefined
    const r2 = dName(c, 'Rb', ts, r[1] + 1)
    return r2 && [derivNode(jstr(r[0]), r2[0]), r2[1]]
  }
  const r = dName(c, 'Rp', ts, i)
  if (r === undefined || !isKwTok(ts[r[1]], 'Slash') || !isKwTok(ts[r[1] + 1], 'Lpg'))
    return undefined
  const r2 = dName(c, 'Rp', ts, r[1] + 2)
  return r2 && [derivNode(jstr(r[0]), r2[0]), r2[1]]
}

/** `Math.Row`: a row of a reduction's subscript, or an output entry. */
export type Row =
  | { readonly k: 'rng'; readonly key: string; readonly v: Json }
  | { readonly k: 'filt'; readonly v: Json }

/** `Math.redOf`. */
export function redOf(k: Kw | undefined): RedK | undefined {
  return k === 'Sum' || k === 'Prod' || k === 'Max' || k === 'Min' ? k : undefined
}

/** `Math.pRedHead`: the operator of a reduction and whether it is marked. */
export function pRedHead(sf: Sf, ts: Toks, i: number): [RedK, boolean, number] | undefined {
  const k0 = kwAt(ts, i)
  if (k0 === undefined) return undefined
  if (
    k0 === 'Limits' &&
    isKwTok(ts[i + 1], 'Lp') &&
    kwAt(ts, i + 2) !== undefined &&
    isKwTok(ts[i + 3], 'Rp')
  ) {
    if (sf !== 'typst') return undefined
    const red = redOf(kwAt(ts, i + 2))
    return red && [red, true, i + 4]
  }
  const red = redOf(k0)
  if (isKwTok(ts[i + 1], 'LimitsL')) {
    if (red === undefined) return undefined
    return sf === 'latex' ? [red, true, i + 2] : [red, false, i + 1]
  }
  return red && [red, false, i + 1]
}

/** `Math.pNames`: names separated by commas (fuel, the input length, dropped). */
export function pNames(sf: Sf, ts: Toks, i: number): P<string[]> {
  const out: string[] = []
  for (;;) {
    const r = pName(sf, ts, i)
    if (r === undefined) return undefined
    out.push(r[0])
    if (!isKwTok(ts[r[1]], 'Comma')) return [out, r[1]]
    i = r[1] + 1
  }
}

/** `Math.rowParts`: ranges, then at most one filter, last. */
export function rowParts(rows: readonly Row[]): [Ranges, Json | undefined] | undefined {
  const rg: Kv[] = []
  let fl: Json | undefined
  for (let i = 0; i < rows.length; i++) {
    const row = rows[i]
    if (row.k === 'rng') rg.push([row.key, row.v])
    else if (i + 1 === rows.length) fl = row.v
    else return undefined
  }
  return [rg, fl]
}

/** `Math.entryParts`: the output entries of a list of entry rows, with their ranges. */
export function entryParts(rows: readonly Row[]): [Json[], Ranges] | undefined {
  const outs: Json[] = []
  const rs: Kv[] = []
  for (const row of rows) {
    if (row.k === 'rng') {
      outs.push(jstr(row.key))
      rs.push([row.key, row.v])
    } else if (row.v.t === 'str') outs.push(row.v)
    else if (row.v.t === 'num' && row.v.n.k === 'int' && row.v.n.v === 1n) outs.push(row.v)
    else return undefined
  }
  return [outs, rs]
}

/** `Math.withOut`: the reduction's parts with the output entries. */
export function withOut(f: FaqForm, outs: Json[], ors: readonly Kv[]): FaqForm {
  return { ...f, out: outs, ranges: sortKv([...ors, ...f.ranges]) }
}

/**
 * `Math.pSup`: the superscript set of a reduction or of an output form, if there
 * is one: LaTeX `^{\{f, g\}}`, Typst `^({f, g})`. No set reads as the empty one.
 */
export function pSup(sf: Sf, ts: Toks, i: number): P<string[]> {
  const open: Kw = sf === 'latex' ? 'Lb' : 'Lpg'
  const closeK: Kw = sf === 'latex' ? 'Rb' : 'Rp'
  if (!(isKwTok(ts[i], 'Caret') && isKwTok(ts[i + 1], open) && isKwTok(ts[i + 2], 'Lset')))
    return [[], i]
  const r = pNames(sf, ts, i + 3)
  return r !== undefined && isKwTok(ts[r[1]], 'Rset') && isKwTok(ts[r[1] + 1], closeK)
    ? [r[0], r[1] + 2]
    : undefined
}

/** A row of a `makearray` table: the value and the region it fills. */
type MkRow = readonly [Json, (readonly [Json, Json])[]]

/**
 * `Math.mkTail`: the `makearray` node of a table read back, with its subscript
 * of output indices if one follows.
 */
export function mkTail(sf: Sf, rows: readonly MkRow[], ts: Toks, i: number): P<Json> {
  const nodeOf = (out: readonly string[]): Json =>
    mkJson({ out, regions: rows.map((r) => r[1]), values: rows.map((r) => r[0]) })
  const open: Kw = sf === 'latex' ? 'Lb' : 'Lpg'
  const closeK: Kw = sf === 'latex' ? 'Rb' : 'Rp'
  if (!(isKwTok(ts[i], 'Us') && isKwTok(ts[i + 1], open))) return [nodeOf([]), i]
  const r = pNames(sf, ts, i + 2)
  return r !== undefined && isKwTok(ts[r[1]], closeK) ? [nodeOf(r[0]), r[1] + 1] : undefined
}

// ## The level parsers

/** `Math.pOr`: level 1, an `or` chain. */
export function pOr(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  const r = pAnd(c, f, ts, i)
  if (r === undefined) return undefined
  const acc = [r[0]]
  let j = r[1]
  for (;;) {
    if (f === 0) return undefined
    f -= 1
    if (!isKwTok(ts[j], 'Lor')) return [close('or', acc), j]
    const y = pAnd(c, f, ts, j + 1)
    if (y === undefined) return undefined
    acc.push(y[0])
    j = y[1]
  }
}

/** `Math.pAnd`: level 2, an `and` chain. */
export function pAnd(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  const r = pCmp(c, f, ts, i)
  if (r === undefined) return undefined
  const acc = [r[0]]
  let j = r[1]
  for (;;) {
    if (f === 0) return undefined
    f -= 1
    if (!isKwTok(ts[j], 'Land')) return [close('and', acc), j]
    const y = pCmp(c, f, ts, j + 1)
    if (y === undefined) return undefined
    acc.push(y[0])
    j = y[1]
  }
}

/** `Math.pCmp`: level 3, one comparison (`cmpLoop`). */
export function pCmp(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  const r = pAdd(c, f, ts, i)
  if (r === undefined) return undefined
  const [x, j] = r
  if (f === 0) return undefined
  f -= 1
  const k = kwAt(ts, j)
  const o = k === undefined ? undefined : cmpOf(k)
  if (o === undefined) return [x, j]
  const y = pAdd(c, f, ts, j + 1)
  return y && [node(o, [x, y[0]]), y[1]]
}

/**
 * `Math.pAdd`: level 4, `+` chains and binary `-` (`addLoop`). After `negTail`,
 * Lean parses the list with the number's sign removed; here a copy of the list
 * with that token replaced is read, and its rest index is the input's own.
 */
export function pAdd(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  const r = pMul(c, f, ts, i)
  if (r === undefined) return undefined
  let acc = [r[0]]
  let j = r[1]
  for (;;) {
    if (f === 0) return undefined
    f -= 1
    const k = kwAt(ts, j)
    if (k === 'Plus') {
      const y = pMul(c, f, ts, j + 1)
      if (y === undefined) return undefined
      acc.push(y[0])
      j = y[1]
    } else if (k === 'Minus') {
      const y = pMul(c, f, ts, j + 1)
      if (y === undefined) return undefined
      const z = shallow(node('-', [close('+', acc), y[0]]))
      if (z === undefined) return undefined
      acc = [z]
      j = y[1]
    } else {
      const m = negTail(ts, j)
      if (m === undefined) return [close('+', acc), j]
      const ts1 = ts.slice()
      ts1[j] = tNum(m)
      const y = pMul(c, f, ts1, j)
      if (y === undefined) return undefined
      const z = shallow(node('-', [close('+', acc), y[0]]))
      if (z === undefined) return undefined
      acc = [z]
      j = y[1]
    }
  }
}

/** `Math.pMul`: level 5, unary minus and `*` chains (`mulLoop`). */
export function pMul(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  return nested(() => pMulIn(c, f - 1, ts, i))
}

function pMulIn(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (isKwTok(ts[i], 'Minus')) {
    const r = pMul(c, f, ts, i + 1)
    return r && [node('-', [r[0]]), r[1]]
  }
  const r = pNot(c, f, ts, i)
  if (r === undefined) return undefined
  let acc = [r[0]]
  let j = r[1]
  for (;;) {
    if (f === 0) return undefined
    f -= 1
    const t = ts[j]
    if (t === undefined) return [close('*', acc), j]
    if (isKwTok(t, 'Cdot') || isKwTok(t, 'Times')) {
      const y = pNot(c, f, ts, j + 1)
      if (y === undefined) return undefined
      acc.push(y[0])
      j = y[1]
    } else if (isKwTok(t, 'Slash')) {
      if (c.sf !== 'latex') return [close('*', acc), j]
      const y = pNot(c, f, ts, j + 1)
      if (y === undefined) return undefined
      const z = shallow(node('/', [close('*', acc), y[0]]))
      if (z === undefined) return undefined
      acc = [z]
      j = y[1]
    } else if (atomStart(t) && !negTok(t)) {
      const y = pNot(c, f, ts, j)
      if (y === undefined) return undefined
      acc.push(y[0])
      j = y[1]
    } else return [close('*', acc), j]
  }
}

/** `Math.pNot`: level 6, `not`, and the `\nabla` forms, whose operand is read at level 9. */
export function pNot(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  return nested(() => {
    if (isKwTok(ts[i], 'Lnot')) {
      const r = pNot(c, f, ts, i + 1)
      return r && [node('not', [r[0]]), r[1]]
    }
    if (isKwTok(ts[i], 'Nabla')) {
      const [o, j] = nabTail(c.sf, ts, i + 1)
      const r = pNabArg(c, f, ts, j)
      return r && [node(o, [r[0]]), r[1]]
    }
    return pFrac(c, f, ts, i)
  })
}

/**
 * `Math.nabTail`: after `\nabla`: which form it is (`\cdot` div, `\times`
 * curl, `^{2}` laplacian, nothing grad), and where its operand starts.
 */
export function nabTail(sf: Sf, ts: Toks, i: number): [string, number] {
  if (isKwTok(ts[i], 'Cdot')) return ['div', i + 1]
  if (isKwTok(ts[i], 'Times')) return ['curl', i + 1]
  const two = (t: Tok | undefined): boolean => t?.t === 'num' && t.n.k === 'int' && t.n.v === 2n
  if (
    sf === 'latex' &&
    isKwTok(ts[i], 'Caret') &&
    isKwTok(ts[i + 1], 'Lb') &&
    two(ts[i + 2]) &&
    isKwTok(ts[i + 3], 'Rb')
  )
    return ['laplacian', i + 4]
  if (sf === 'typst' && isKwTok(ts[i], 'Caret') && two(ts[i + 1])) return ['laplacian', i + 2]
  return ['grad', i]
}

/** `Math.pNabArg`: the operand of a `\nabla` form: another `\nabla` form, or a postfix-level operand. */
export function pNabArg(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  if (isKwTok(ts[i], 'Nabla')) return pNot(c, f, ts, i)
  return pPost(c, f, ts, i)
}

/** `Math.pFrac`: level 7, the Typst fraction, grouping to the left (`fracLoop`). */
export function pFrac(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  const r = pPow(c, f, ts, i)
  if (r === undefined) return undefined
  let [x, j] = r
  for (;;) {
    if (f === 0) return undefined
    f -= 1
    if (!(isKwTok(ts[j], 'Slash') && c.sf === 'typst')) return [x, j]
    const y = pPow(c, f, ts, j + 1)
    if (y === undefined) return undefined
    const z = shallow(node('/', [x, y[0]]))
    if (z === undefined) return undefined
    x = z
    j = y[1]
  }
}

/** `Math.pPow`: level 8, a power. */
export function pPow(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  const r = pPost(c, f, ts, i)
  if (r === undefined) return undefined
  if (!isKwTok(ts[r[1]], 'Caret')) return r
  const y = pExpo(c, f, ts, r[1] + 1)
  return y && [node('^', [r[0], y[0]]), y[1]]
}

/** The token `t` alone parsed as a primary, consumed whole. */
function primOne(c: Ctx, f: number, t: Tok): Json | undefined {
  const r = pPrim(c, f, [t], 0)
  return r !== undefined && r[1] === 1 ? r[0] : undefined
}

/** `Math.pExpo`: an exponent: LaTeX `{…}`; Typst `(…)` or one simple token. */
export function pExpo(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  const t = ts[i]
  if (t === undefined) return undefined
  if (c.sf === 'latex') {
    if (!isKwTok(t, 'Lb')) return undefined
    const r = pOr(c, f, ts, i + 1)
    return r !== undefined && isKwTok(ts[r[1]], 'Rb') ? [r[0], r[1] + 1] : undefined
  }
  if (isKwTok(t, 'Lpg')) {
    const r = pOr(c, f, ts, i + 1)
    return r !== undefined && isRp(ts[r[1]]) ? [r[0], r[1] + 1] : undefined
  }
  if (!simpleTok(t)) return undefined
  const y = primOne(c, f, t)
  return y === undefined ? undefined : [y, i + 1]
}

/** `Math.pPost`: level 9, postfix index, `_{…}` or `[…]` (`postLoop`). */
export function pPost(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  const r = pPrim(c, f, ts, i)
  if (r === undefined) return undefined
  let [x, j] = r
  for (;;) {
    if (f === 0) return undefined
    f -= 1
    const k = kwAt(ts, j)
    if (k === 'Us') {
      const t1 = ts[j + 1]
      if (c.sf === 'latex' && isKwTok(t1, 'Lb')) {
        const l = pList(c, f, 1, ts, j + 2)
        if (l === undefined || !isKwTok(ts[l[1]], 'Rb') || l[0].length === 0) return undefined
        x = node('index', [x, ...l[0]])
        j = l[1] + 1
      } else if (c.sf === 'typst' && isKwTok(t1, 'Lpg')) {
        const l = pList(c, f, 1, ts, j + 2)
        if (l === undefined || !isRp(ts[l[1]]) || l[0].length === 0) return undefined
        x = node('index', [x, ...l[0]])
        j = l[1] + 1
      } else if (c.sf === 'typst' && t1 !== undefined && simpleTok(t1)) {
        const y = primOne(c, f, t1)
        if (y === undefined) return undefined
        x = node('index', [x, y])
        j = j + 2
      } else return undefined
    } else if (k === 'Lbk') {
      const l = pList(c, f, 1, ts, j + 1)
      if (l === undefined || !isKwTok(ts[l[1]], 'Rbk') || l[0].length === 0) return undefined
      x = node('index', [x, ...l[0]])
      j = l[1] + 1
    } else return [x, j]
  }
}

/**
 * `Math.pList`: a comma-separated list of expressions at level `L` (1 or 4),
 * possibly empty when the next token closes it.
 */
export function pList(c: Ctx, f: number, l: number, ts: Toks, i: number): P<Json[]> {
  if (f === 0) return undefined
  f -= 1
  const t = ts[i]
  if (t === undefined || isRp(t) || isKwTok(t, 'Rb') || isKwTok(t, 'Rbk')) return [[], i]
  return pItems(c, f, l, ts, i)
}

/** `Math.pItems`. */
export function pItems(c: Ctx, f: number, l: number, ts: Toks, i: number): P<Json[]> {
  const out: Json[] = []
  for (;;) {
    if (f === 0) return undefined
    f -= 1
    const r = pLv(c, f, l, ts, i)
    if (r === undefined) return undefined
    out.push(r[0])
    if (!isKwTok(ts[r[1]], 'Comma')) return [out, r[1]]
    i = r[1] + 1
  }
}

/** `Math.pLv`: parse at level 1 or level 4. */
export function pLv(c: Ctx, f: number, l: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  return l === 4 ? pAdd(c, f, ts, i) : pOr(c, f, ts, i)
}

/** `Math.pCallArgs`: call arguments at level 4: each positional, or `name = value`. */
export function pCallArgs(c: Ctx, f: number, ts: Toks, i: number): P<CallArg[]> {
  if (f === 0) return undefined
  f -= 1
  const k = kwAt(ts, i)
  if (k === 'Rp' || k === 'Semi') return [[], i]
  return pCallItems(c, f, ts, i)
}

/** `Math.pCallItems`. */
export function pCallItems(c: Ctx, f: number, ts: Toks, i: number): P<CallArg[]> {
  const out: CallArg[] = []
  for (;;) {
    if (f === 0) return undefined
    f -= 1
    const r = pAdd(c, f, ts, i)
    if (r === undefined) return undefined
    const [x, j] = r
    if (x.t === 'str' && isKwTok(ts[j], 'Eq')) {
      const v = pAdd(c, f, ts, j + 1)
      if (v === undefined) return undefined
      out.push({ k: 'named', key: x.s, v: v[0] })
      if (!isKwTok(ts[v[1]], 'Comma')) return [out, v[1]]
      i = v[1] + 1
    } else {
      out.push({ k: 'pos', v: x })
      if (!isKwTok(ts[j], 'Comma')) return [out, j]
      i = j + 1
    }
  }
}

/** `Math.pFields`: open-operator fields after `;`. */
export function pFields(c: Ctx, f: number, ts: Toks, i: number): P<Kv[]> {
  const out: Kv[] = []
  for (;;) {
    if (f === 0) return undefined
    f -= 1
    const k = keyOf(c, ts, i)
    if (k === undefined) return undefined
    const v = pVal(c, f, ts, k[1])
    if (v === undefined) return undefined
    out.push([k[0], v[0]])
    if (!isKwTok(ts[v[1]], 'Comma')) return [out, v[1]]
    i = v[1] + 1
  }
}

/** `Math.pVal`: a field value: JSON (LaTeX JSON tokens, Typst `#value`) or an expression. */
export function pVal(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  if (c.sf === 'typst') {
    const t = ts[i]
    return t?.t === 'code' ? [t.j, i + 1] : pAdd(c, f, ts, i)
  }
  return jsonStart(ts, i) ? pJson(f, ts, i) : pAdd(c, f, ts, i)
}

function nodupKeys(xs: readonly Kv[]): boolean {
  return new Set(xs.map((x) => x[0])).size === xs.length
}

/** `Math.pOpn`: `\operatorname{n}(…)`. */
export function pOpn(c: Ctx, f: number, n: string, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  const t0 = ts[i]
  // A bare `\operatorname{n}` (not followed by `(` or `_`): a template with no
  // bindings, except one in scope with no parameters, which prints `n()`.
  const bare: P<Json> = tnameOk(n) && tparams(c.s, n)?.length !== 0 ? [tNode(n, []), i] : undefined
  if (t0 === undefined) return bare
  if (isLp(t0)) {
    const r = pCallArgs(c, f, ts, i + 1)
    if (r === undefined) return undefined
    const [args, j] = r
    const k = kwAt(ts, j)
    if (k === 'Rp') {
      const r2 = j + 1
      if (CALL_OPS.includes(n)) {
        const vs = allPos(args)
        return vs && [node(n, vs), r2]
      }
      if (n === 'neg') {
        const vs = allPos(args)
        return vs !== undefined && vs.length === 1 ? [node('-', [vs[0]]), r2] : undefined
      }
      if (n === 'pow') {
        const vs = allPos(args)
        return vs !== undefined && vs.length === 2 ? [node('^', [vs[0], vs[1]]), r2] : undefined
      }
      if (REMOVED_OPS.includes(n) || n === 'D') return undefined
      const ps = tparams(c.s, n)
      const vs = allPos(args)
      if (ps !== undefined && vs !== undefined) {
        return ps.length === vs.length
          ? [tNode(n, sortKv(ps.map((p, idx): Kv => [p, vs[idx]]))), r2]
          : undefined
      }
      const bs = allNamed(args)
      if (bs !== undefined && bs.length > 0)
        return nodupKeys(bs) ? [tNode(n, sortKv(bs)), r2] : undefined
      if (ps === undefined && vs !== undefined) return [mkNode(n, vs, []), r2]
      return undefined
    }
    if (k === 'Semi') {
      if (REMOVED_OPS.includes(n)) return undefined
      const vs = allPos(args)
      const fs = pFields(c, f, ts, j + 1)
      if (vs === undefined || fs === undefined || !isKwTok(ts[fs[1]], 'Rp')) return undefined
      // Each field once, and never the node's own `op` or `args`.
      if (!nodupKeys(fs[0]) || fs[0].some((kv) => kv[0] === 'op' || kv[0] === 'args'))
        return undefined
      const e = mkNode(n, vs, fs[0])
      return e.t === 'obj' && callFormNode(c, n, fs[0], e.kvs) ? [e, fs[1] + 1] : undefined
    }
    return undefined
  }
  if (isKwTok(t0, 'Us')) return n === 'D' ? pDCall(c, f, ts, i + 1) : undefined
  return bare
}

/**
 * `Math.pDCall`: `\partial_{x}(u, a, b)`, and the earlier `\operatorname{D}_{x}(u, a, b)`
 * (read, never printed), after the `_`: `partial` with trailing operands.
 */
export function pDCall(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  const open: Kw = c.sf === 'latex' ? 'Lb' : 'Lpg'
  const closeK: Kw = c.sf === 'latex' ? 'Rb' : 'Rp'
  if (!isKwTok(ts[i], open)) return undefined
  const w = pName(c.sf, ts, i + 1)
  if (w === undefined || !isKwTok(ts[w[1]], closeK)) return undefined
  const j = w[1] + 1
  if (!isLp(ts[j])) return undefined
  const r = pCallArgs(c, f, ts, j + 1)
  if (r === undefined || !isKwTok(ts[r[1]], 'Rp')) return undefined
  const xs = allPos(r[0])
  return xs && [dCallNode(w[0], xs), r[1] + 1]
}

/**
 * Record a removed operator written in the call or escape form at `i`, so a
 * refusal can name it (CONFORMANCE §7.1). Not in Lean, whose reader refuses
 * every bad input alike.
 */
function noteRemovedOp(ts: Toks, i: number): void {
  const t = ts[i]
  let name: string | undefined
  if (t?.t === 'opn' || t?.t === 'esc') name = t.s
  else if (isKwTok(t, 'Esmnode')) {
    const t2 = ts[i + 2]
    if (t2?.t === 'txt') name = t2.s
  }
  if (name !== undefined && REMOVED_OPS.includes(name)) removedOp(name)
}

function opAllowed(o: string): boolean {
  return opOk(o) && !REMOVED_OPS.includes(o) && !DEPRECATED_OPS.includes(o)
}

/** `Math.pPrim`: a primary. */
export function pPrim(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  noteRemovedOp(ts, i)
  const parenClose = (j: number): P<Json> => {
    const r = pOr(c, f, ts, j)
    return r !== undefined && isRp(ts[r[1]]) ? [r[0], r[1] + 1] : undefined
  }
  const closed = (j: number, k: Kw, o: string): P<Json> => {
    const r = pOr(c, f, ts, j)
    return r !== undefined && isKwTok(ts[r[1]], k) ? [node(o, [r[0]]), r[1] + 1] : undefined
  }
  const t = ts[i]
  if (t === undefined) return undefined
  const t1 = ts[i + 1]
  if (t.t === 'num') {
    if (t1?.t === 'units') return [qty(t.n, t1.l), i + 2]
    return [jnum(t.n), i + 1]
  }
  if (t.t === 'txt') {
    if (t.s === 'true') return [node('true', []), i + 1]
    if (t.s === 'false') return [node('false', []), i + 1]
  }
  if (t.t === 'kw') {
    const k = t.k
    switch (k) {
      case 'Bmat': {
        const g = pGrid('Amp', 'Nl', 'Emat', ts, i + 1)
        if (g === undefined || g[0].some((r) => r.length > BMAT_MAX_COLS)) return undefined
        return constTail(gridJson(g[0]), ts, g[1])
      }
      case 'Vec':
        if (t1 !== undefined) {
          if (!isLp(t1)) return undefined
          const r = pCells('Comma', ts, i + 2)
          if (r === undefined || !isKwTok(ts[r[1]], 'Rp')) return undefined
          return constTail(jarr(r[0].map(jnum)), ts, r[1] + 1)
        }
        break
      case 'Mat':
        if (matHeadAt(ts, i)) {
          const r = pMkRows(c, f, 'Comma', 'Semi', 'Rp', ts, i + MAT_HEAD_LEN)
          return r && mkTail(c.sf, r[0], ts, r[1])
        }
        if (t1 !== undefined) {
          if (!isLp(t1)) return undefined
          const g = pGrid('Comma', 'Semi', 'Rp', ts, i + 2)
          return g && constTail(jarr(g[0].map((q) => jarr(q.map(jnum)))), ts, g[1])
        }
        break
      case 'Lpg':
      case 'Lp': {
        const j = i + 1
        if (c.sf === 'typst') {
          if (isKwTok(t1, 'Dif')) return pDT(c, f, 'Dif', ts, j + 1)
          if (isKwTok(t1, 'Pdiff') && isKwTok(ts[j + 1], 'Us')) return parenClose(j)
          if (isKwTok(t1, 'Pdiff')) return pDT(c, f, 'Pdiff', ts, j + 1)
          if (t1?.t === 'letter' && t1.c === 'd') return pItalicD(c, ts, j) ?? parenClose(j)
        }
        return parenClose(j)
      }
      case 'Lbk': {
        const r = pOr(c, f, ts, i + 1)
        return r !== undefined && isKwTok(ts[r[1]], 'Rbk') ? [r[0], r[1] + 1] : undefined
      }
      case 'Frac':
        if (isKwTok(t1, 'Lb')) return pFracL(c, f, ts, i + 2)
        break
      case 'Pdiff':
        // `\partial_{x}(u, a, b)` / `partial_(x)(u, a, b)`: `partial` with trailing operands.
        if (isKwTok(t1, 'Us')) return pDCall(c, f, ts, i + 2)
        break
      case 'Sqrt':
        if (c.sf === 'latex') return isKwTok(t1, 'Lb') ? closed(i + 2, 'Rb', 'sqrt') : undefined
        if (t1 === undefined || !isLp(t1)) return undefined
        return pFn1(c, f, 'sqrt', ts, i + 2)
      case 'Log':
        if (isKwTok(t1, 'Us')) {
          const j = i + 2
          if (c.sf === 'latex') {
            if (
              isKwTok(ts[j], 'Lb') &&
              isInt(ts[j + 1], 10n) &&
              isKwTok(ts[j + 2], 'Rb') &&
              ts[j + 3] !== undefined
            ) {
              return isLp(ts[j + 3]) ? pFn1(c, f, 'log10', ts, j + 4) : undefined
            }
            return undefined
          }
          if (isInt(ts[j], 10n) && ts[j + 1] !== undefined) {
            return isLp(ts[j + 1]) ? pFn1(c, f, 'log10', ts, j + 2) : undefined
          }
          return undefined
        }
        break
      case 'Labs':
        return closed(i + 1, 'Rabs', 'abs')
      case 'Lfloor':
        return closed(i + 1, 'Rfloor', 'floor')
      case 'Lceil':
        return closed(i + 1, 'Rceil', 'ceil')
      case 'Min':
      case 'Max':
        if (t1 !== undefined) {
          if (!isKwTok(t1, 'Lp')) return pRed(c, f, ts, i)
          const l = pList(c, f, 1, ts, i + 2)
          if (l === undefined || !isKwTok(ts[l[1]], 'Rp')) return undefined
          return 2 <= l[0].length ? [node(k === 'Min' ? 'min' : 'max', l[0]), l[1] + 1] : undefined
        }
        break
      case 'Lbkg':
        if (t1?.t === 'acols') {
          const g = pGrid('Amp', 'Nl', 'Earr', ts, i + 2)
          if (
            g === undefined ||
            t1.n <= BMAT_MAX_COLS ||
            !g[0].every((r) => r.length === t1.n) ||
            !isKwTok(ts[g[1]], 'Rbkg')
          )
            return undefined
          return constTail(jarr(g[0].map((r) => jarr(r.map(jnum)))), ts, g[1] + 1)
        }
        if (isKwTok(t1, 'Barr')) {
          const r = pMkRows(c, f, 'Amp', 'Nl', 'Earr', ts, i + 2)
          return r !== undefined && isKwTok(ts[r[1]], 'Rbkg')
            ? mkTail(c.sf, r[0], ts, r[1] + 1)
            : undefined
        }
        return pRed(c, f, ts, i)
      case 'Sum':
      case 'Prod':
      case 'Limits':
        return pRed(c, f, ts, i)
      case 'Lr':
        if (isKwTok(t1, 'Lp') && isKwTok(ts[i + 2], 'Lbk')) return pRed(c, f, ts, i)
        break
      case 'Bcases':
        return pCases(c, f, ts, i + 1)
      case 'Cases':
        if (t1 !== undefined) return isLp(t1) ? pCases(c, f, ts, i + 2) : undefined
        break
      case 'Esmnode': {
        const o = ts[i + 2]
        const fs = ts[i + 4]
        if (
          t1 !== undefined &&
          o?.t === 'txt' &&
          isKwTok(ts[i + 3], 'Comma') &&
          fs?.t === 'code' &&
          fs.j.t === 'obj'
        ) {
          if (!isLp(t1)) return undefined
          const r = pEscArgs(c, f, ts, i + 5)
          if (r === undefined) return undefined
          return opAllowed(o.s) ? [mkNode(o.s, r[0], fs.j.kvs), r[1]] : undefined
        }
        break
      }
      case 'Dotacc':
        if (isKwTok(t1, 'Lb')) {
          const r = pOr(c, f, ts, i + 2)
          return r !== undefined && isKwTok(ts[r[1]], 'Rb')
            ? [dNode(r[0], 't'), r[1] + 1]
            : undefined
        }
        break
      case 'Cdot':
        if (isKwTok(t1, 'Lp')) {
          const r = pOr(c, f, ts, i + 2)
          return r !== undefined && isKwTok(ts[r[1]], 'Rp')
            ? [dNode(r[0], 't'), r[1] + 1]
            : undefined
        }
        break
    }
    // `[Tok::Kw(k), t, r @ ..]`: a function keyword and its parenthesis.
    if (t1 !== undefined) {
      if (!isLp(t1)) return undefined
      const j = i + 2
      if (k === 'Log') return pFn1(c, f, 'log', ts, j)
      if (k === 'Abs') return pFn1(c, f, 'abs', ts, j)
      if (k === 'Floor') return pFn1(c, f, 'floor', ts, j)
      if (k === 'Ceil') return pFn1(c, f, 'ceil', ts, j)
      const o = fnOf(k)
      return o === undefined ? undefined : pFn1(c, f, o, ts, j)
    }
    return pNamePrim(c, ts, i)
  }
  if (t.t === 'opn') return pOpn(c, f, t.s, ts, i + 1)
  if (t.t === 'esc' && isKwTok(t1, 'Lb')) {
    const r = pJson(f, ts, i + 2)
    if (
      r === undefined ||
      r[0].t !== 'obj' ||
      !isKwTok(ts[r[1]], 'Rb') ||
      !isKwTok(ts[r[1] + 1], 'Lb')
    ) {
      return undefined
    }
    const fs = r[0].kvs
    const l = pList(c, f, 1, ts, r[1] + 2)
    if (l === undefined || !isKwTok(ts[l[1]], 'Rb')) return undefined
    return opAllowed(t.s) ? [mkNode(t.s, l[0], fs), l[1] + 1] : undefined
  }
  if (t.t === 'word') return pWord(c, t.s, i + 1)
  if (eulerHead(c, ts, i)) return pEulerExp(c, f, ts, i + 2)
  return pNamePrim(c, ts, i)
}

/** `Math.pEulerExp`: `\exp` written as a power of e. */
export function pEulerExp(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  const r = pExpo(c, f, ts, i)
  return r && [node('exp', [r[0]]), r[1]]
}

/** `Math.pRange`: a range row: `k \in S`, `k \in S(i, j)`, `a \le k \le b`. */
export function pRange(c: Ctx, f: number, ts: Toks, i: number): P<Row> {
  if (f === 0) return undefined
  f -= 1
  const r = pAdd(c, f, ts, i)
  if (r === undefined) return undefined
  const [x, j] = r
  if (x.t === 'str' && isKwTok(ts[j], 'Inn')) {
    const s = pName(c.sf, ts, j + 1)
    if (s === undefined) return undefined
    if (isKwTok(ts[s[1]], 'Lp')) {
      const ps = pNames(c.sf, ts, s[1] + 1)
      if (ps === undefined || !isKwTok(ts[ps[1]], 'Rp')) return undefined
      return [
        {
          k: 'rng',
          key: x.s,
          v: jobj([
            ['from', jstr(s[0])],
            ['of', jarr(ps[0].map(jstr))],
          ]),
        },
        ps[1] + 1,
      ]
    }
    return [{ k: 'rng', key: x.s, v: jobj([['from', jstr(s[0])]]) }, s[1]]
  }
  if (isKwTok(ts[j], 'Le')) {
    const r2 = pAdd(c, f, ts, j + 1)
    if (r2 === undefined || r2[0].t !== 'str' || !isKwTok(ts[r2[1]], 'Le')) return undefined
    const b = pAdd(c, f, ts, r2[1] + 1)
    return b && [{ k: 'rng', key: r2[0].s, v: jarr([x, b[0]]) }, b[1]]
  }
  return undefined
}

/** `Math.pRow`: a row ending at a token `isEnd` accepts: an expression read whole first, else a range. */
export function pRow(c: Ctx, f: number, isEnd: (t: Tok) => boolean, ts: Toks, i: number): P<Row> {
  if (f === 0) return undefined
  f -= 1
  const r = pOr(c, f, ts, i)
  if (r !== undefined && ts[r[1]] !== undefined && isEnd(ts[r[1]]))
    return [{ k: 'filt', v: r[0] }, r[1]]
  return pRange(c, f, ts, i)
}

/** `Math.pRows`: rows separated by `sep`, up to `close` (consumed). */
export function pRows(c: Ctx, f: number, sep: Kw, closeK: Kw, ts: Toks, i: number): P<Row[]> {
  const out: Row[] = []
  const isEnd = (t: Tok): boolean => isKwTok(t, sep) || isKwTok(t, closeK)
  for (;;) {
    if (f === 0) return undefined
    f -= 1
    const r = pRow(c, f, isEnd, ts, i)
    if (r === undefined) return undefined
    const k = kwAt(ts, r[1])
    if (k === undefined) return undefined
    out.push(r[0])
    if (k === sep) i = r[1] + 1
    else if (k === closeK) return [out, r[1] + 1]
    else return undefined
  }
}

/** The `.obj [("args", .arr [.str k, a]), ("op", .str "==")]` pattern of `pRedBody`. */
function loneEq(x: Json): [string, Json] | undefined {
  if (x.t !== 'obj' || x.kvs.length !== 2) return undefined
  const [[ka, a], [ko, o]] = x.kvs
  if (ka !== 'args' || ko !== 'op' || a.t !== 'arr' || o.t !== 'str' || o.s !== '==')
    return undefined
  if (a.xs.length !== 2 || a.xs[0].t !== 'str') return undefined
  return [a.xs[0].s, a.xs[1]]
}

/** `Math.pRedBody`: a reduction after its operator: the subscript rows, then the body. */
export function pRedBody(
  c: Ctx,
  f: number,
  red: RedK,
  marked: boolean,
  ts: Toks,
  i: number,
): P<FaqForm> {
  if (f === 0) return undefined
  f -= 1
  let rows: P<Row[]>
  if (c.sf === 'latex') {
    if (
      isKwTok(ts[i], 'Us') &&
      isKwTok(ts[i + 1], 'Lb') &&
      isKwTok(ts[i + 2], 'Substack') &&
      isKwTok(ts[i + 3], 'Lb')
    ) {
      const r = pRows(c, f, 'Nl', 'Rb', ts, i + 4)
      rows = r !== undefined && isKwTok(ts[r[1]], 'Rb') ? [r[0], r[1] + 1] : undefined
    } else if (isKwTok(ts[i], 'Us') && isKwTok(ts[i + 1], 'Lb')) {
      const r = pRow(c, f, (t) => isKwTok(t, 'Rb'), ts, i + 2)
      const le = r !== undefined && r[0].k === 'filt' ? loneEq(r[0].v) : undefined
      if (
        r !== undefined &&
        le !== undefined &&
        isKwTok(ts[r[1]], 'Rb') &&
        isKwTok(ts[r[1] + 1], 'Caret') &&
        isKwTok(ts[r[1] + 2], 'Lb')
      ) {
        // `_{k = a}^{\{…\}}`: a filter followed by a superscript set.
        if (isKwTok(ts[r[1] + 3], 'Lset')) rows = [[r[0]], r[1] + 1]
        else {
          const b = pOr(c, f, ts, r[1] + 3)
          rows =
            b !== undefined && isKwTok(ts[b[1]], 'Rb')
              ? [[{ k: 'rng', key: le[0], v: jarr([le[1], b[0]]) }], b[1] + 1]
              : undefined
        }
      } else if (r !== undefined && isKwTok(ts[r[1]], 'Rb')) {
        rows = [[r[0]], r[1] + 1]
      } else rows = undefined
    } else rows = [[], i]
  } else if (isKwTok(ts[i], 'Us') && isKwTok(ts[i + 1], 'Lpg')) {
    rows = pRows(c, f, 'Nl', 'Rp', ts, i + 2)
  } else rows = [[], i]
  if (rows === undefined) return undefined
  const parts = rowParts(rows[0])
  const sup = pSup(c.sf, ts, rows[1])
  if (parts === undefined || sup === undefined) return undefined
  // A marked head lists `args` itself; the printer writes no set after it.
  if (marked && sup[0].length > 0) return undefined
  const body = pMul(c, f, ts, sup[1])
  if (body === undefined) return undefined
  return [
    { red, marked, out: [], ranges: parts[0], expr: body[0], filter: parts[1], set: sup[0] },
    body[1],
  ]
}

/** The tokens `tail` occur in `ts` at `i`. */
function stripPrefix(tail: readonly Tok[], ts: Toks, i: number): number | undefined {
  for (let k = 0; k < tail.length; k++) {
    const t = ts[i + k]
    if (t === undefined || !tokEq(t, tail[k])) return undefined
  }
  return i + tail.length
}

const KW = (k: Kw): Tok => ({ t: 'kw', k })
const TAIL_L: readonly Tok[] = [KW('Rbkg')]
const TAIL_T: readonly Tok[] = [KW('Rbk'), KW('Rp')]

/** `Math.pRed`: a rank-0 reduction, or a reduction wrapped with its output entries. */
export function pRed(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  const wrapped = (j: number, tail: readonly Tok[], closeK: Kw): P<Json> => {
    const h = pRedHead(c.sf, ts, j)
    if (h === undefined) return undefined
    const b = pRedBody(c, f, h[0], h[1], ts, h[2])
    if (b === undefined) return undefined
    const r1 = stripPrefix(tail, ts, b[1])
    if (r1 === undefined) return undefined
    // The set of a wrapped reduction is written on the bracket only.
    if (b[0].set.length > 0) return undefined
    const sup = pSup(c.sf, ts, r1)
    const open: Kw = c.sf === 'latex' ? 'Lb' : 'Lpg'
    if (sup === undefined || !isKwTok(ts[sup[1]], 'Us') || !isKwTok(ts[sup[1] + 1], open))
      return undefined
    if (b[0].marked && sup[0].length > 0) return undefined
    const es = pRows(c, f, 'Comma', closeK, ts, sup[1] + 2)
    if (es === undefined) return undefined
    const ep = entryParts(es[0])
    return ep && [faqJson({ ...withOut(b[0], ep[0], ep[1]), set: sup[0] }), es[1]]
  }
  if (isKwTok(ts[i], 'Lbkg')) return wrapped(i + 1, TAIL_L, 'Rb')
  if (isKwTok(ts[i], 'Lr') && isKwTok(ts[i + 1], 'Lp') && isKwTok(ts[i + 2], 'Lbk'))
    return wrapped(i + 3, TAIL_T, 'Rp')
  const h = pRedHead(c.sf, ts, i)
  if (h === undefined) return undefined
  const b = pRedBody(c, f, h[0], h[1], ts, h[2])
  return b && [faqJson(b[0]), b[1]]
}

/** `Math.pFn1`: `f(x)` after the opening parenthesis. */
export function pFn1(c: Ctx, f: number, o: string, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  const r = pOr(c, f, ts, i)
  return r !== undefined && isKwTok(ts[r[1]], 'Rp') ? [node(o, [r[0]]), r[1] + 1] : undefined
}

function isRm(t: Tok | undefined, s: string): boolean {
  return t?.t === 'rm' && t.s === s
}

function isLetterT(t: Tok | undefined): boolean {
  return t?.t === 'letter' && t.c === 't'
}

/**
 * `Math.pFracL`: after `\frac{`: a time or spatial derivative, the italic-d
 * variant, or a quotient.
 */
export function pFracL(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  const t0 = ts[i]
  if (
    isRm(t0, 'd') &&
    isKwTok(ts[i + 1], 'Rb') &&
    isKwTok(ts[i + 2], 'Lb') &&
    isRm(ts[i + 3], 'd') &&
    isLetterT(ts[i + 4]) &&
    isKwTok(ts[i + 5], 'Rb')
  ) {
    return pDApply(c, f, 't', ts, i + 6)
  }
  if (isRm(t0, 'd')) {
    const r = pOr(c, f, ts, i + 1)
    if (r === undefined) return undefined
    const j = r[1]
    return isKwTok(ts[j], 'Rb') &&
      isKwTok(ts[j + 1], 'Lb') &&
      isRm(ts[j + 2], 'd') &&
      isLetterT(ts[j + 3]) &&
      isKwTok(ts[j + 4], 'Rb')
      ? [dNode(r[0], 't'), j + 5]
      : undefined
  }
  if (
    isKwTok(t0, 'Pdiff') &&
    isKwTok(ts[i + 1], 'Rb') &&
    isKwTok(ts[i + 2], 'Lb') &&
    isKwTok(ts[i + 3], 'Pdiff')
  ) {
    const w = pName(c.sf, ts, i + 4)
    return w !== undefined && isKwTok(ts[w[1]], 'Rb')
      ? pDApply(c, f, w[0], ts, w[1] + 1)
      : undefined
  }
  if (isKwTok(t0, 'Pdiff') && isKwTok(ts[i + 1], 'Us')) {
    // A quotient whose numerator starts with `\partial_{x}(…)`.
    const x = pOr(c, f, ts, i)
    if (x === undefined || !isKwTok(ts[x[1]], 'Rb') || !isKwTok(ts[x[1] + 1], 'Lb'))
      return undefined
    const y = pOr(c, f, ts, x[1] + 2)
    return y !== undefined && isKwTok(ts[y[1]], 'Rb')
      ? [node('/', [x[0], y[0]]), y[1] + 1]
      : undefined
  }
  if (isKwTok(t0, 'Pdiff')) {
    const r = pOr(c, f, ts, i + 1)
    if (r === undefined) return undefined
    const j = r[1]
    if (!(isKwTok(ts[j], 'Rb') && isKwTok(ts[j + 1], 'Lb') && isKwTok(ts[j + 2], 'Pdiff')))
      return undefined
    const w = pName(c.sf, ts, j + 3)
    return w !== undefined && isKwTok(ts[w[1]], 'Rb')
      ? [derivNode(r[0], w[0]), w[1] + 1]
      : undefined
  }
  const d = pItalicD(c, ts, i)
  if (d !== undefined) return d
  const x = pOr(c, f, ts, i)
  if (x === undefined || !isKwTok(ts[x[1]], 'Rb') || !isKwTok(ts[x[1] + 1], 'Lb')) return undefined
  const y = pOr(c, f, ts, x[1] + 2)
  return y !== undefined && isKwTok(ts[y[1]], 'Rb')
    ? [node('/', [x[0], y[0]]), y[1] + 1]
    : undefined
}

/**
 * `Math.pDT`: `(dif N)/(dif t)` and `(partial u)/(partial x)` after the first
 * `(dif` / `(partial`.
 */
export function pDT(c: Ctx, f: number, k: Kw, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  const tail = (j: number): P<string> => {
    if (!(isKwTok(ts[j], 'Rp') && isKwTok(ts[j + 1], 'Slash') && isKwTok(ts[j + 2], 'Lpg')))
      return undefined
    if (kwAt(ts, j + 3) === undefined) return undefined
    if (kwAt(ts, j + 3) !== k) return undefined
    const w = pName(c.sf, ts, j + 4)
    if (w === undefined || !isKwTok(ts[w[1]], 'Rp')) return undefined
    if (k === 'Dif' && w[0] !== 't') return undefined
    return [w[0], w[1] + 1]
  }
  if (
    isKwTok(ts[i], 'Rp') &&
    isKwTok(ts[i + 1], 'Slash') &&
    isKwTok(ts[i + 2], 'Lpg') &&
    kwAt(ts, i + 3) !== undefined
  ) {
    const w = tail(i)
    return w && pDApply(c, f, w[0], ts, w[1])
  }
  const r = pOr(c, f, ts, i)
  if (r === undefined) return undefined
  const w = tail(r[1])
  return w && [derivNode(r[0], w[0]), w[1]]
}

/** `Math.pDApply`: a derivative operator applied to a parenthesized operand. */
export function pDApply(c: Ctx, f: number, w: string, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  f -= 1
  if (!isKwTok(ts[i], 'Lpg')) return undefined
  const r = pOr(c, f, ts, i + 1)
  return r !== undefined && isRp(ts[r[1]]) ? [derivNode(r[0], w), r[1] + 1] : undefined
}

/** `Math.pCases`: `cases` rows; a chain re-nests to the right. */
export function pCases(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  if (f === 0) return undefined
  return nested(() => pCasesIn(c, f - 1, ts, i))
}

function pCasesIn(c: Ctx, f: number, ts: Toks, i: number): P<Json> {
  const r = pOr(c, f, ts, i)
  if (r === undefined) return undefined
  const [v, j] = r
  const tt = ts[j + 1]
  if (!isKwTok(ts[j], 'Amp') || tt?.t !== 'txt') return undefined
  if (tt.s === 'otherwise') {
    const endK: Kw = c.sf === 'latex' ? 'Ecases' : 'Rp'
    return isKwTok(ts[j + 2], endK) ? [v, j + 3] : undefined
  }
  if (tt.s === 'if ') {
    const cnd = pOr(c, f, ts, j + 2)
    if (cnd === undefined) return undefined
    const k = kwAt(ts, cnd[1])
    if (k === undefined) return undefined
    const brk: Kw = c.sf === 'latex' ? 'Nl' : 'Comma'
    if (k !== brk) return undefined
    const e = pCases(c, f, ts, cnd[1] + 1)
    return e && [node('ifelse', [cnd[0], v, e[0]]), e[1]]
  }
  return undefined
}

/** `Math.pPair`: a bound pair after its `[`: `a, b]`. */
export function pPair(c: Ctx, f: number, ts: Toks, i: number): P<[Json, Json]> {
  if (f === 0) return undefined
  f -= 1
  const a = pOr(c, f, ts, i)
  if (a === undefined || !isKwTok(ts[a[1]], 'Comma')) return undefined
  const b = pOr(c, f, ts, a[1] + 1)
  return b !== undefined && isKwTok(ts[b[1]], 'Rbk') ? [[a[0], b[0]], b[1] + 1] : undefined
}

/** `Math.pRegTail`: the further bound pairs of a region, each after `\times` then `[`. */
export function pRegTail(c: Ctx, f: number, ts: Toks, i: number): P<[Json, Json][]> {
  const out: [Json, Json][] = []
  for (;;) {
    if (f === 0) return undefined
    f -= 1
    if (!(isKwTok(ts[i], 'Times') && isKwTok(ts[i + 1], 'Lbk'))) return [out, i]
    const p = pPair(c, f, ts, i + 2)
    if (p === undefined) return undefined
    out.push(p[0])
    i = p[1]
  }
}

/**
 * `Math.pMkRows`: the rows of a `makearray` table: a value, the cell separator
 * `csep`, a region; rows separated by `rsep`, up to `closeK` (consumed).
 */
export function pMkRows(
  c: Ctx,
  f: number,
  csep: Kw,
  rsep: Kw,
  closeK: Kw,
  ts: Toks,
  i: number,
): P<MkRow[]> {
  const out: MkRow[] = []
  for (;;) {
    if (f === 0) return undefined
    f -= 1
    const v = pOr(c, f, ts, i)
    if (v === undefined || !isKwTok(ts[v[1]], csep) || !isKwTok(ts[v[1] + 1], 'Lbk'))
      return undefined
    const p = pPair(c, f, ts, v[1] + 2)
    if (p === undefined) return undefined
    const ps = pRegTail(c, f, ts, p[1])
    if (ps === undefined) return undefined
    out.push([v[0], [p[0], ...ps[0]]])
    const k = kwAt(ts, ps[1])
    if (k === rsep) i = ps[1] + 1
    else if (k === closeK) return [out, ps[1] + 1]
    else return undefined
  }
}

/** The tokens of the Typst table head `mat(delim: "[", augment: #1,` (`Math.matHead`). */
const MAT_HEAD_LEN = 10

/**
 * The Typst table head `mat(delim: "[", augment: #1,` is at `i`. `delim` and
 * `augment` are ordinary words, named arguments only at this position.
 */
function matHeadAt(ts: Toks, i: number): boolean {
  const t2 = ts[i + 2]
  const t4 = ts[i + 4]
  const t6 = ts[i + 6]
  const t8 = ts[i + 8]
  return (
    isKwTok(ts[i], 'Mat') &&
    isKwTok(ts[i + 1], 'Lp') &&
    t2?.t === 'word' &&
    t2.s === 'delim' &&
    isKwTok(ts[i + 3], 'Colon') &&
    t4?.t === 'txt' &&
    t4.s === '[' &&
    isKwTok(ts[i + 5], 'Comma') &&
    t6?.t === 'word' &&
    t6.s === 'augment' &&
    isKwTok(ts[i + 7], 'Colon') &&
    t8?.t === 'code' &&
    t8.j.t === 'num' &&
    t8.j.n.k === 'int' &&
    t8.j.n.v === 1n &&
    isKwTok(ts[i + 9], 'Comma')
  )
}

/** `Math.pEscArgs`: Typst escape arguments: `, a` repeated, then `)`. */
export function pEscArgs(c: Ctx, f: number, ts: Toks, i: number): P<Json[]> {
  const out: Json[] = []
  for (;;) {
    if (f === 0) return undefined
    f -= 1
    if (isKwTok(ts[i], 'Rp')) return [out, i + 1]
    if (!isKwTok(ts[i], 'Comma')) return undefined
    const r = pOr(c, f, ts, i + 1)
    if (r === undefined) return undefined
    out.push(r[0])
    i = r[1]
  }
}

/** `Math.need` (RoundTrip.lean): the fuel a token list of length `len` is read with at level `L`. */
export function need(l: number, len: number): number {
  return 30 * len + Math.max(0, 12 - l)
}

/** `Math.parseToks` (Induct.lean): read a whole token list. */
export function parseToks(sf: Sf, s: Sym, ts: readonly Tok[]): Json | undefined {
  const r = pOr({ sf, s }, need(1, ts.length), ts, 0)
  return r !== undefined && r[1] === ts.length ? r[0] : undefined
}

export type { Chars }
