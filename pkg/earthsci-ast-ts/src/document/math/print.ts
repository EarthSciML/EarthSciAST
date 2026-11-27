/**
 * The printer: expressions to tokens.
 *
 * Port of `formal/Esm/Document/Math/Print.lean` (after the Rust binding's
 * `document/math/print.rs`). {@link pr} prints an expression with its
 * precedence level; {@link outAt} wraps it for a position that needs a level at
 * least `L`. The levels, loosest first (spec §4.1.1):
 *
 * | level | construct |
 * |---|---|
 * | 1 | `or` chain |
 * | 2 | `and` chain |
 * | 3 | a comparison |
 * | 4 | `+` chain, binary `-` |
 * | 5 | `*` chain, unary `-` |
 * | 6 | `not`; a derivative applied to a parenthesized operand |
 * | 7 | Typst fraction; a negative literal and a quantity |
 * | 8 | power |
 * | 9 | index |
 * | 10 | atoms |
 *
 * Which notation a node gets is decided from its exact JSON shape; anything
 * without a native or call notation prints in the generic escape form.
 */

import {
  cmpCodePoints,
  jarr,
  jnum,
  jobj,
  jsonEq,
  jstr,
  mkInt,
  type JNum,
  type Json,
  type Kvs,
} from '../json.js'
import { EXPRESSION_NODE_ANNOTATIONS } from '../../expression.js'
import { digitChar, type Chars, type Read } from '../number.js'
import {
  REMOVED_OPS,
  isE,
  isFormula,
  isIdChar,
  isIdStart,
  isSingle,
  keysSorted,
  look,
  nameOk,
  numOk,
  pieces,
  segOk,
  splitDots,
  subParts,
  type Sym,
} from './expr.js'
import {
  kw,
  tAcols,
  tCode,
  tEsc,
  tGreek,
  tIt,
  tJstr,
  tLetter,
  tNum,
  tOpn,
  tRm,
  tTxt,
  tUnits,
  tUps,
  tWord,
  type Kw,
  type Sf,
  type Tok,
} from './token.js'
import {
  denFactors,
  factorsEq,
  factorsOf,
  latex as unitsLatex,
  latexBody,
  numFactors,
  parseLatex as unitsParseLatex,
  symOk,
  unitsOkFactors,
  type Factor,
} from './units.js'

type Kv = readonly [string, Json]

// ## Text pieces

/**
 * `Math.escSet`: the characters escaped by a backslash inside `\mathit{}`,
 * `\operatorname{}`, `\esm{}` and a name subscript's `\mathrm{}`.
 */
export function escSet(c: string): boolean {
  return c === '_' || c === '^' || c === '\\' || c === '{' || c === '}'
}

/** `Math.escT`: escape the text of `\mathit{}` and the like. */
export function escT(s: string): string {
  let out = ''
  for (const c of s) out += escSet(c) ? `\\${c}` : c
  return out
}

/** `Math.unescT`: undo {@link escT} (drop the backslash of every `\c` pair). */
export function unescT(s: string | Chars): string {
  const cs = typeof s === 'string' ? Array.from(s) : s
  let out = ''
  for (let i = 0; i < cs.length; i++) {
    if (cs[i] === '\\' && i + 1 < cs.length) i++
    out += cs[i]
  }
  return out
}

/** `Math.keySpecial`. */
export function keySpecial(c: string): boolean {
  return c === '$' || c === '%' || c === '&' || c === '#' || c === '~' || c === '^' || c === '\\'
}

/** `Math.dig3`: three decimal digits. */
export function dig3(n: number): string {
  return (
    digitChar(Math.floor(n / 100) % 10) + digitChar(Math.floor(n / 10) % 10) + digitChar(n % 10)
  )
}

/** `Math.escK`: escape a field key for `\mathrm{}`. */
export function escK(s: string): string {
  let out = ''
  for (const c of s) {
    if (keySpecial(c)) out += `{\\char${dig3(c.codePointAt(0) ?? 0)}}`
    else if (c === '_' || c === '{' || c === '}') out += `\\${c}`
    else out += c
  }
  return out
}

/** `Number.charDigit`: `c.toNat - 48`, saturating (any character, not only a digit). */
export function charDigitNat(c: string): number {
  return Math.max(0, (c.codePointAt(0) ?? 0) - 48)
}

/** Lean's `Char.ofNat`: an invalid code point is `'\0'`. */
export function charOfNat(n: number): string {
  if (n > 0x10ffff || (n >= 0xd800 && n <= 0xdfff)) return '\0'
  return String.fromCodePoint(n)
}

/** `Math.unescK`: undo {@link escK}. */
export function unescK(s: string): string {
  const cs = Array.from(s)
  let out = ''
  let i = 0
  while (i < cs.length) {
    if (
      cs[i] === '{' &&
      cs[i + 1] === '\\' &&
      cs[i + 2] === 'c' &&
      cs[i + 3] === 'h' &&
      cs[i + 4] === 'a' &&
      cs[i + 5] === 'r' &&
      i + 9 < cs.length &&
      cs[i + 9] === '}'
    ) {
      out += charOfNat(
        100 * charDigitNat(cs[i + 6]) + 10 * charDigitNat(cs[i + 7]) + charDigitNat(cs[i + 8]),
      )
      i += 10
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

// ## The printing context

/** `Math.Ctx`: the surface and the symbol table. */
export interface Ctx {
  readonly sf: Sf
  readonly s: Sym
}

/** `Math.rpG`: the closing token of a grouping parenthesis. */
export function rpG(sf: Sf): Tok {
  return kw(sf === 'latex' ? 'Rpg' : 'Rp')
}

/** `Math.grp`: grouping parentheses. */
export function grp(sf: Sf, ts: readonly Tok[]): Tok[] {
  return [kw('Lpg'), ...ts, rpG(sf)]
}

/** `Math.sepBy`: items joined by a separator. */
export function sepBy(sep: readonly Tok[], xs: readonly (readonly Tok[])[]): Tok[] {
  const out: Tok[] = []
  xs.forEach((x, i) => {
    if (i > 0) out.push(...sep)
    out.push(...x)
  })
  return out
}

function cat(...parts: (readonly Tok[])[]): Tok[] {
  const out: Tok[] = []
  for (const p of parts) for (const t of p) out.push(t)
  return out
}

const COMMA: readonly Tok[] = [kw('Comma')]

// ## Names

/** `Math.baseTok`: a single letter or a Greek name as a token. */
export function baseTok(g: string): Tok {
  return g.length === 1 ? tLetter(g) : tGreek(g)
}

/** `Math.subTxt`: the subscript text of a name, upright. */
export function subTxt(sf: Sf, r: string): Tok[] {
  return sf === 'latex'
    ? [kw('Us'), kw('Lb'), tRm(escT(r)), kw('Rb')]
    : [kw('Us'), kw('Lpg'), tUps([[r, '']]), kw('Rp')]
}

/** `Math.formulaRaw`: the raw `\mathrm{}` content of a formula (counts as `_{n}`). */
export function formulaRaw(g: string): string {
  let out = ''
  for (const [a, b] of pieces(g)) out += b.length > 0 ? `${a}_{${b}}` : a
  return out
}

/** `Math.formTok`: a formula name. */
export function formTok(sf: Sf, g: string): Tok {
  return sf === 'latex' ? tRm(formulaRaw(g)) : tUps(pieces(g))
}

/** `Math.segToks`: one segment of a name, by its shape. */
export function segToks(sf: Sf, g: string): Tok[] {
  if (isSingle(g)) return [baseTok(g)]
  const sp = subParts(g)
  if (sp !== undefined) return [baseTok(sp[0]), ...subTxt(sf, sp[1])]
  return isFormula(g) ? [formTok(sf, g)] : [tIt(g)]
}

/** `Math.explicitName`: an undeclared `e` or `d` prints in the explicit form. */
export function explicitName(s: Sym, n: string): boolean {
  return (n === 'e' || n === 'd') && !s.names.includes(n)
}

/** `Math.nameToks`: the tokens of a name. */
export function nameToks(c: Ctx, s: string): Tok[] {
  if (explicitName(c.s, s)) return [tIt(s)]
  return sepBy(
    [kw('Sdot')],
    splitDots(s).map((g) => segToks(c.sf, g)),
  )
}

/** `Math.plainLast`: the last segment of a name prints with no subscript. */
export function plainLast(s: string): boolean {
  const gs = splitDots(s)
  const g = gs[gs.length - 1]
  return isSingle(g) || (subParts(g) === undefined && !isFormula(g))
}

// ## JSON inside escape nodes (LaTeX)

/** `Math.jsonToks`. */
export function jsonToks(j: Json): Tok[] {
  const out: Tok[] = []
  jsonToksInto(j, out)
  return out
}

function jsonToksInto(j: Json, out: Tok[]): void {
  switch (j.t) {
    case 'null':
      out.push(tWord('null'))
      return
    case 'bool':
      out.push(tWord(j.v ? 'true' : 'false'))
      return
    case 'num':
      out.push(tNum(j.n))
      return
    // `math`: never reached, an expression holds no math leaf
    case 'str':
    case 'math':
      out.push(tJstr(j.s))
      return
    case 'arr':
      out.push(kw('Lbk'))
      j.xs.forEach((x, i) => {
        if (i > 0) out.push(kw('Comma'))
        jsonToksInto(x, out)
      })
      out.push(kw('Rbk'))
      return
    case 'obj':
      out.push(kw('Lb'))
      j.kvs.forEach(([k, v], i) => {
        if (i > 0) out.push(kw('Comma'))
        out.push(tJstr(k), kw('Colon'))
        jsonToksInto(v, out)
      })
      out.push(kw('Rb'))
      return
  }
}

// ## Operator tables

/** `Math.fnKw`: unary functions with a native spelling, and their keyword. */
export const FN_KW: readonly (readonly [string, Kw])[] = [
  ['exp', 'Exp'],
  ['log', 'Ln'],
  ['sin', 'Sin'],
  ['cos', 'Cos'],
  ['tan', 'Tan'],
  ['asin', 'Asin'],
  ['acos', 'Acos'],
  ['atan', 'Atan'],
  ['sinh', 'Sinh'],
  ['cosh', 'Cosh'],
  ['tanh', 'Tanh'],
]

/** `Math.cmpKw`: comparisons and their token. */
export const CMP_KW: readonly (readonly [string, Kw])[] = [
  ['<', 'Lt'],
  ['<=', 'Le'],
  ['>', 'Gt'],
  ['>=', 'Ge'],
  ['==', 'Eq'],
  ['!=', 'Ne'],
]

/** `Math.callOps`: core operators in the call form. */
export const CALL_OPS: readonly string[] = [
  'sign',
  'atan2',
  'asinh',
  'acosh',
  'atanh',
  'Pre',
  'enum',
]

/**
 * `Math.fieldCallOps`: core operators with no notation of their own that print
 * in the call form, their fields as named arguments after `;` (when no field
 * annotates the node).
 */
export const FIELD_CALL_OPS: readonly string[] = [
  'broadcast',
  'reshape',
  'transpose',
  'concat',
  'faq',
  'makearray',
  'const',
]

/** `Math.reservedOpn`: names `\operatorname{…}` never means a template or an open operator by. */
export function reservedOpn(n: string): boolean {
  return CALL_OPS.includes(n) || n === 'D' || n === 'neg' || n === 'pow' || REMOVED_OPS.includes(n)
}

/** `Math.coreOps` (`coreOpNames` of `Notation`). */
export const CORE_OPS: readonly string[] = [
  '+',
  '-',
  '*',
  '/',
  '^',
  'pow',
  'neg',
  '<',
  '<=',
  '>',
  '>=',
  '==',
  '!=',
  'and',
  'or',
  'not',
  'true',
  'false',
  'ifelse',
  'exp',
  'log',
  'log10',
  'sqrt',
  'abs',
  'sign',
  'floor',
  'ceil',
  'sin',
  'cos',
  'tan',
  'asin',
  'acos',
  'atan',
  'sinh',
  'cosh',
  'tanh',
  'asinh',
  'acosh',
  'atanh',
  'atan2',
  'min',
  'max',
  'D',
  'ic',
  'Pre',
  'enum',
  'const',
  'faq',
  'makearray',
  'index',
  'broadcast',
  'reshape',
  'transpose',
  'concat',
  'apply_operator',
]
const CORE_OP_SET: ReadonlySet<string> = new Set(CORE_OPS)

/** The operator is one of the core operators. */
export const isCoreOp = (o: string): boolean => CORE_OP_SET.has(o)

/** `Math.opnOK`: a name `\operatorname{…}` can carry: identifier characters and dots. */
export function opnOk(s: string): boolean {
  if (s.length === 0 || !isIdStart(s[0])) return false
  for (let i = 1; i < s.length; i++) if (!isIdChar(s[i]) && s[i] !== '.') return false
  return true
}

/**
 * `Math.callFormOK`: an operator prints in the call form: an open operator, or
 * a core operator of {@link FIELD_CALL_OPS} none of whose fields annotates it.
 */
export function callFormOk(o: string, fs: readonly Kv[]): boolean {
  return (
    !isCoreOp(o) ||
    (FIELD_CALL_OPS.includes(o) &&
      fs.every((kv) => !(EXPRESSION_NODE_ANNOTATIONS as readonly string[]).includes(kv[0])))
  )
}

/**
 * `Math.mathKeys`: the fields of a core operator in the call form that hold an
 * expression; the others print as JSON, even a string that is a name.
 */
export const MATH_KEYS: readonly string[] = ['expr', 'filter', 'key']

/**
 * `Math.mathField`: a field of a call-form node prints as math: its value is an
 * expression and, for a core operator, the field holds one. An open operator's
 * fields are all read as math when they can be.
 */
export function mathField(o: string, kv: Kv): boolean {
  return isE(kv[1]) && (!isCoreOp(o) || MATH_KEYS.includes(kv[0]))
}

/** `Math.keyOK`: a field key printed upright in a call: an identifier. */
export function keyOk(s: string): boolean {
  return segOk(s)
}

/** `Math.insKV`: sorted insertion by key. */
export function insKv(kv: Kv, l: readonly Kv[]): Kv[] {
  let i = l.findIndex((e) => cmpCodePoints(kv[0], e[0]) < 0)
  if (i < 0) i = l.length
  return [...l.slice(0, i), kv, ...l.slice(i)]
}

/** `Math.fieldsOf`: the fields of a node other than `op` and `args`. */
export function fieldsOf(kvs: Kvs): Kv[] {
  return kvs.filter((kv) => kv[0] !== 'op' && kv[0] !== 'args')
}

/** `Math.mkNode`: a node from its operator, operands and other fields. */
export function mkNode(o: string, args: readonly Json[], fs: readonly Kv[]): Json {
  return jobj(insKv(['args', jarr(args)], insKv(['op', jstr(o)], fs)))
}

/** `Math.node`: the plain two-field node. */
export function node(o: string, args: readonly Json[]): Json {
  return jobj([
    ['args', jarr(args)],
    ['op', jstr(o)],
  ])
}

/** `Math.isNegNum`. */
export function isNegNum(j: Json): boolean {
  return j.t === 'num' && (j.n.k === 'int' ? j.n.v < 0n : j.n.neg)
}

/** `Math.simpleTok`: Typst exponent and subscript tokens that need no parentheses. */
export function simpleTok(t: Tok): boolean {
  switch (t.t) {
    case 'num':
      return t.n.k === 'int' ? 0n <= t.n.v : !t.n.neg && -4 <= t.n.e10 && t.n.e10 <= 5
    case 'letter':
    case 'greek':
      return true
    default:
      return false
  }
}

/** `Math.startsNum`. */
export function startsNum(ts: readonly Tok[]): boolean {
  return ts.length > 0 && ts[0].t === 'num'
}

/** `Math.tparams`: the template parameter list, when the symbol table knows it. */
export function tparams(s: Sym, n: string): readonly string[] | undefined {
  for (const t of s.templates) if (t[0] === n) return t[1]
  return undefined
}

function nodup(xs: readonly string[]): boolean {
  return new Set(xs).size === xs.length
}

/** `Math.positional`: positional template arguments. */
export function positional(s: Sym, n: string, bs: Kvs): readonly string[] | undefined {
  const ps = tparams(s, n)
  if (ps === undefined) return undefined
  return nodup(ps) && ps.length === bs.length && ps.every((p) => look(p, bs) !== undefined)
    ? ps
    : undefined
}

/**
 * `Math.rawB`: balanced text up to the `}` that closes depth 0; `\x` is one
 * unit. Returns the raw text and the index after the closing `}`.
 */
export function rawB(d: number, cs: Chars, i: number): Read<string> {
  const start = i
  for (;;) {
    const c = cs[i]
    if (c === undefined) return undefined
    if (c === '\\' && i + 1 < cs.length) {
      i += 2
    } else if (c === '}') {
      if (d === 0) return [cs.slice(start, i).join(''), i + 1]
      d -= 1
      i += 1
    } else {
      if (c === '{') d += 1
      i += 1
    }
  }
}

/** `Math.balOK`: raw text that {@link rawB} reads back whole. */
export function balOk(raw: string): boolean {
  const cs = [...Array.from(raw), '}']
  const r = rawB(0, cs, 0)
  return r !== undefined && r[0] === raw && r[1] === cs.length
}

/** `Math.unitsOK`: the units of a quantity print typeset. */
export function unitsOk(sf: Sf, u: string): boolean {
  const l = factorsOf(u)
  if (!unitsOkFactors(u, l)) return false
  if (!l.every((f) => symOk(f[0]) && f[1].n !== 0n)) return false
  if (sf === 'latex') {
    const back = unitsParseLatex(Array.from(unitsLatex(l)))
    return back !== undefined && factorsEq(back, l) && balOk(latexBody(l))
  }
  return factorsEq([...numFactors(l), ...denFactors(l)], l)
}

// ## The printer

/** `Math.wrap`: wrap a printed form for a position needing level `L`. */
export function wrap(sf: Sf, l: number, lvl: number, ts: readonly Tok[]): Tok[] {
  return l <= lvl ? (ts as Tok[]) : grp(sf, ts)
}

/** `Math.mulToks`: a `*` chain: juxtaposition, `\cdot` before a factor that starts with a number. */
export function mulToks(xs: readonly (readonly Tok[])[]): Tok[] {
  const out: Tok[] = []
  xs.forEach((y, i) => {
    if (i > 0 && startsNum(y)) out.push(kw('Cdot'))
    out.push(...y)
  })
  return out
}

/** `Math.OpK`: the printer kind of a plain node's operator. */
export type OpK =
  | { readonly k: 'Minus' | 'Div' | 'Pow' | 'Lnot' | 'Tru' | 'Fls' | 'Ite' | 'Ic' | 'Index' }
  | { readonly k: 'Plus' | 'Times' | 'Land' | 'Lor' | 'Call' | 'Other' }
  | { readonly k: 'Cmp' | 'Un' | 'Mm'; readonly kw: Kw }
  | { readonly k: 'Nab'; readonly n: NabK }

/**
 * `Math.NabK`: the four defined operators with a `\nabla` form (spec §1.2):
 * `grad`, `div`, `laplacian`, `curl`.
 */
export type NabK = 'grad' | 'div' | 'lap' | 'curl'

const UN_KW: readonly (readonly [string, Kw])[] = [
  ...FN_KW,
  ['log10', 'Log'],
  ['sqrt', 'Sqrt'],
  ['abs', 'Abs'],
  ['floor', 'Floor'],
  ['ceil', 'Ceil'],
]

/** `Math.unKw`: unary functions with a native spelling (`log10` is `\log_{10}`). */
export function unKw(o: string): Kw | undefined {
  for (const [n, k] of UN_KW) if (n === o) return k
  return undefined
}

/** `Math.kindTable`: the plain-node operators with their own notation. */
export const KIND_TABLE: readonly (readonly [string, OpK])[] = [
  ['-', { k: 'Minus' }],
  ['/', { k: 'Div' }],
  ['^', { k: 'Pow' }],
  ['not', { k: 'Lnot' }],
  ['true', { k: 'Tru' }],
  ['false', { k: 'Fls' }],
  ['ifelse', { k: 'Ite' }],
  ['ic', { k: 'Ic' }],
  ['index', { k: 'Index' }],
  ['+', { k: 'Plus' }],
  ['*', { k: 'Times' }],
  ['and', { k: 'Land' }],
  ['or', { k: 'Lor' }],
  ['min', { k: 'Mm', kw: 'Min' }],
  ['max', { k: 'Mm', kw: 'Max' }],
  ['grad', { k: 'Nab', n: 'grad' }],
  ['div', { k: 'Nab', n: 'div' }],
  ['laplacian', { k: 'Nab', n: 'lap' }],
  ['curl', { k: 'Nab', n: 'curl' }],
]

/** `Math.kindOf`. */
export function kindOf(o: string): OpK {
  for (const [n, k] of CMP_KW) if (n === o) return { k: 'Cmp', kw: k }
  const u = unKw(o)
  if (u !== undefined) return { k: 'Un', kw: u }
  for (const [n, k] of KIND_TABLE) if (n === o) return k
  return CALL_OPS.includes(o) ? { k: 'Call' } : { k: 'Other' }
}

/**
 * `Math.Out`: the printed form of an expression and its level. `crow` is the
 * form as the last rows of a `cases` block; it is built on demand (see
 * {@link outCrow}) unless the form is itself a `cases` block.
 */
export interface Out {
  readonly lvl: number
  readonly toks: Tok[]
  readonly crow?: Tok[]
}

/** `Math.mkOut`. */
export function mkOut(l: number, t: Tok[]): Out {
  return { lvl: l, toks: t }
}

/** The `crow` of `Math.Out`: by `mkOut`, the form then `& \text{otherwise}`. */
export function outCrow(o: Out): Tok[] {
  return o.crow ?? [...o.toks, kw('Amp'), tTxt('otherwise')]
}

/** `Math.Out.at`. */
export function outAt(o: Out, sf: Sf, l: number): Tok[] {
  return wrap(sf, l, o.lvl, o.toks)
}

/**
 * `Math.escToks`: the escape form: LaTeX `\esm{op}{fields}{args}`, Typst
 * `esm.node("op", #(fields), args)`.
 */
export function escToks(
  sf: Sf,
  o: string,
  fs: readonly Kv[],
  args: readonly (readonly Tok[])[],
): Tok[] {
  if (sf === 'latex') {
    return cat([tEsc(o), kw('Lb')], jsonToks(jobj(fs)), [kw('Rb'), kw('Lb')], sepBy(COMMA, args), [
      kw('Rb'),
    ])
  }
  const out: Tok[] = [kw('Esmnode'), kw('Lp'), tTxt(o), kw('Comma'), tCode(jobj(fs))]
  for (const a of args) out.push(kw('Comma'), ...a)
  out.push(kw('Rp'))
  return out
}

/** `Math.lpC`: the call parenthesis. */
export function lpC(_sf: Sf): Tok {
  return kw('Lp')
}

/** `Math.callToks`: `name(args)` with call parentheses. */
export function callToks(sf: Sf, head: readonly Tok[], args: readonly (readonly Tok[])[]): Tok[] {
  return cat(head, [lpC(sf)], sepBy(COMMA, args), [kw('Rp')])
}

/** `Math.unToks`: a unary function applied to the printed operand `t`. */
export function unToks(sf: Sf, k: Kw, t: Tok[]): Tok[] {
  if (sf === 'latex') {
    switch (k) {
      case 'Sqrt':
        return cat([kw('Sqrt'), kw('Lb')], t, [kw('Rb')])
      case 'Abs':
        return cat([kw('Labs')], t, [kw('Rabs')])
      case 'Floor':
        return cat([kw('Lfloor')], t, [kw('Rfloor')])
      case 'Ceil':
        return cat([kw('Lceil')], t, [kw('Rceil')])
      case 'Log':
        return cat(
          [kw('Log'), kw('Us'), kw('Lb'), tNum(mkInt(10)), kw('Rb')],
          callToks(sf, [], [t]),
        )
    }
  } else if (k === 'Log') {
    return cat([kw('Log'), kw('Us'), tNum(mkInt(10))], callToks(sf, [], [t]))
  }
  return callToks(sf, [kw(k)], [t])
}

/** `Math.caseRow`: one cases row, `value & \text{if } condition`, then the row break. */
export function caseRow(sf: Sf, v: Tok[], cnd: Tok[]): Tok[] {
  return cat(v, [kw('Amp'), tTxt('if ')], cnd, [kw(sf === 'latex' ? 'Nl' : 'Comma')])
}

/** `Math.casesToks`. */
export function casesToks(sf: Sf, rows: readonly Tok[]): Tok[] {
  return sf === 'latex'
    ? cat([kw('Bcases')], rows, [kw('Ecases')])
    : cat([kw('Cases'), kw('Lp')], rows, [kw('Rp')])
}

/** `Math.icTail`: `t_{0}` in an initial condition `N(t_{0})`. */
export function icTail(sf: Sf): Tok[] {
  return sf === 'latex'
    ? [kw('Lp'), tLetter('t'), kw('Us'), kw('Lb'), tNum(mkInt(0)), kw('Rb'), kw('Rp')]
    : [kw('Lp'), tLetter('t'), kw('Us'), tNum(mkInt(0)), kw('Rp')]
}

/** `Math.subList`: a subscript list: LaTeX `_{a, b}`; Typst `_a` for one simple token, else `_(a, b)`. */
export function subList(sf: Sf, simp: Tok | undefined, args: readonly (readonly Tok[])[]): Tok[] {
  if (sf === 'latex') return cat([kw('Us'), kw('Lb')], sepBy(COMMA, args), [kw('Rb')])
  if (simp !== undefined) return [kw('Us'), simp]
  return cat([kw('Us'), kw('Lpg')], sepBy(COMMA, args), [kw('Rp')])
}

/** `Math.simpleE`: the one token a Typst exponent or subscript may be written as without parentheses. */
export function simpleE(c: Ctx, j: Json): Tok | undefined {
  if (j.t === 'num') {
    const t = tNum(j.n)
    return simpleTok(t) ? t : undefined
  }
  if (j.t === 'str') {
    const ts = nameToks(c, j.s)
    return ts.length === 1 && simpleTok(ts[0]) ? ts[0] : undefined
  }
  return undefined
}

/** `Math.simpleArg`. */
export function simpleArg(c: Ctx, xs: readonly Json[]): Tok | undefined {
  return xs.length === 1 ? simpleE(c, xs[0]) : undefined
}

/** `Math.subOK`: the index prints with a subscript. */
export function subOk(s: Sym, base: Json, is: readonly Json[]): boolean {
  if (base.t !== 'str') return false
  const b = base.s
  if (!(nameOk(b) && plainLast(b) && !explicitName(s, b))) return false
  if (is.length === 1) {
    const x = is[0]
    if (x.t === 'str') return !(splitDots(x.s).length === 1 && isFormula(x.s))
    if (x.t === 'num' && x.n.k === 'int') {
      const n = x.n.v
      return !(0n <= n && s.names.includes(`${b}_${n}`))
    }
  }
  return true
}

/** `Math.subPat4`: four tokens of an upright name subscript. */
export function subPat4(sf: Sf, t1: Tok, t2: Tok, t3: Tok, t4: Tok): boolean {
  if (t1.t !== 'kw' || t1.k !== 'Us' || t2.t !== 'kw' || t4.t !== 'kw') return false
  if (t2.k === 'Lb' && t3.t === 'rm' && t4.k === 'Rb') return sf === 'latex'
  if (
    t2.k === 'Lpg' &&
    t3.t === 'ups' &&
    t4.k === 'Rp' &&
    t3.ps.length === 1 &&
    t3.ps[0][1] === ''
  ) {
    return sf === 'typst'
  }
  return false
}

/** `Math.subPat`: an upright name subscript at the front. */
export function subPat(sf: Sf, ts: readonly Tok[]): boolean {
  return ts.length >= 4 && subPat4(sf, ts[0], ts[1], ts[2], ts[3])
}

/** `Math.inlineD`: derivative operand printed inline. */
export function inlineD(o: Out): boolean {
  return 9 <= o.lvl
}

/** `Math.keyToks`: a field key, upright. */
export function keyToks(sf: Sf, k: string): Tok[] {
  return sf === 'latex' ? [tRm(escK(k))] : [tUps([[k, '']])]
}

/** `Math.jsonVal`: a field value that is not an expression, as JSON. */
export function jsonVal(sf: Sf, v: Json): Tok[] {
  return sf === 'latex' ? jsonToks(v) : [tCode(v)]
}

/** `Math.openToks`: the open-operator call. */
export function openToks(
  sf: Sf,
  o: string,
  args: readonly (readonly Tok[])[],
  fields: readonly (readonly Tok[])[],
): Tok[] {
  const out = cat([tOpn(o), lpC(sf)], sepBy(COMMA, args))
  if (fields.length > 0) out.push(kw('Semi'), ...sepBy(COMMA, fields))
  out.push(kw('Rp'))
  return out
}

const RM_D = (): Tok => tRm('d')

/** `Math.dTime`: the time derivative. */
export function dTime(sf: Sf, a: Out): Out {
  const a1 = outAt(a, sf, 1)
  if (sf === 'latex') {
    return inlineD(a)
      ? mkOut(
          10,
          cat([kw('Frac'), kw('Lb'), RM_D()], a1, [
            kw('Rb'),
            kw('Lb'),
            RM_D(),
            tLetter('t'),
            kw('Rb'),
          ]),
        )
      : mkOut(
          6,
          cat(
            [kw('Frac'), kw('Lb'), RM_D(), kw('Rb'), kw('Lb'), RM_D(), tLetter('t'), kw('Rb')],
            grp(sf, a1),
          ),
        )
  }
  return inlineD(a)
    ? mkOut(
        7,
        cat([kw('Lpg'), kw('Dif')], a1, [
          kw('Rp'),
          kw('Slash'),
          kw('Lpg'),
          kw('Dif'),
          tLetter('t'),
          kw('Rp'),
        ]),
      )
    : mkOut(
        6,
        cat(
          [
            kw('Lpg'),
            kw('Dif'),
            kw('Rp'),
            kw('Slash'),
            kw('Lpg'),
            kw('Dif'),
            tLetter('t'),
            kw('Rp'),
          ],
          grp(sf, a1),
        ),
      )
}

/** `Math.dSpace`: the spatial derivative along the axis printed `w`. */
export function dSpace(sf: Sf, w: readonly Tok[], a: Out): Out {
  const a1 = outAt(a, sf, 1)
  if (sf === 'latex') {
    return inlineD(a)
      ? mkOut(
          10,
          cat([kw('Frac'), kw('Lb'), kw('Pdiff')], a1, [kw('Rb'), kw('Lb'), kw('Pdiff')], w, [
            kw('Rb'),
          ]),
        )
      : mkOut(
          6,
          cat(
            [kw('Frac'), kw('Lb'), kw('Pdiff'), kw('Rb'), kw('Lb'), kw('Pdiff')],
            w,
            [kw('Rb')],
            grp(sf, a1),
          ),
        )
  }
  return inlineD(a)
    ? mkOut(
        7,
        cat([kw('Lpg'), kw('Pdiff')], a1, [kw('Rp'), kw('Slash'), kw('Lpg'), kw('Pdiff')], w, [
          kw('Rp'),
        ]),
      )
    : mkOut(
        6,
        cat(
          [kw('Lpg'), kw('Pdiff'), kw('Rp'), kw('Slash'), kw('Lpg'), kw('Pdiff')],
          w,
          [kw('Rp')],
          grp(sf, a1),
        ),
      )
}

/** `Math.dCall`: `partial` with trailing operands: `\partial_{x}(u, a, b)` / `partial_(x)(u, a, b)`. */
export function dCall(sf: Sf, w: readonly Tok[], args: readonly (readonly Tok[])[]): Tok[] {
  const open = kw(sf === 'latex' ? 'Lb' : 'Lpg')
  const close = kw(sf === 'latex' ? 'Rb' : 'Rp')
  return cat([kw('Pdiff'), kw('Us'), open], w, [close], callToks(sf, [], args))
}

/**
 * `Math.nabHead`: what a `\nabla` form writes before its operand: `\nabla`,
 * `\nabla \cdot`, `\nabla^{2}`, `\nabla \times` (Typst `nabla`, `nabla dot`,
 * `nabla^2`, `nabla times`).
 */
export function nabHead(sf: Sf, n: NabK): Tok[] {
  switch (n) {
    case 'grad':
      return [kw('Nabla')]
    case 'div':
      return [kw('Nabla'), kw('Cdot')]
    case 'lap':
      return sf === 'latex'
        ? [kw('Nabla'), kw('Caret'), kw('Lb'), tNum({ k: 'int', v: 2n }), kw('Rb')]
        : [kw('Nabla'), kw('Caret'), tNum({ k: 'int', v: 2n })]
    case 'curl':
      return [kw('Nabla'), kw('Times')]
  }
}

/**
 * `Math.nabArg`: the operand of a `\nabla` form: another `\nabla` form as it is
 * (`\nabla \cdot \nabla u` is `div(grad(u))`), anything else at the level of a
 * power base; after the `\times` of a curl, an operand that starts with a
 * number is parenthesized (the lexers read a number's scientific tail there).
 */
export function nabArg(sf: Sf, n: NabK, o: Out): Tok[] {
  if (o.toks[0]?.t === 'kw' && o.toks[0].k === 'Nabla' && 6 <= o.lvl) return o.toks
  const t = outAt(o, sf, 9)
  return n === 'curl' && startsNum(t) ? grp(sf, t) : t
}

/** `Math.qtyToks`: the quantity: the number, then the unit as one token. */
export function qtyToks(n: JNum, l: readonly Factor[]): Tok[] {
  return [tNum(n), tUnits(l)]
}

// ## Constant arrays

/** `Math.numsOf`: the entries of a list that are all well-formed numbers. */
export function numsOf(xs: readonly Json[]): JNum[] | undefined {
  const out: JNum[] = []
  for (const x of xs) {
    if (x.t !== 'num' || !numOk(x.n)) return undefined
    out.push(x.n)
  }
  return out
}

/** `Math.rowsOf`: the rows of a list of number lists. */
export function rowsOf(xs: readonly Json[]): JNum[][] | undefined {
  const out: JNum[][] = []
  for (const x of xs) {
    if (x.t !== 'arr') return undefined
    const ns = numsOf(x.xs)
    if (ns === undefined) return undefined
    out.push(ns)
  }
  return out
}

/** `Math.AForm`: the two array shapes with a native spelling. */
export type AForm =
  { readonly k: 'col'; readonly ns: JNum[] } | { readonly k: 'mat'; readonly rs: JNum[][] }

/**
 * `Math.arrForm`: a constant array printed natively: a column for rank 1, or a
 * matrix of at least two columns (a single-column matrix would print like a
 * column), of any size, every entry a well-formed number.
 */
export function arrForm(j: Json): AForm | undefined {
  if (j.t !== 'arr') return undefined
  const ns = numsOf(j.xs)
  if (ns !== undefined) return ns.length > 0 ? { k: 'col', ns } : undefined
  const rs = rowsOf(j.xs)
  if (rs === undefined || rs.length === 0) return undefined
  const r = rs[0]
  return 2 <= r.length && rs.slice(1).every((q) => q.length === r.length)
    ? { k: 'mat', rs }
    : undefined
}

/** `Math.AForm.json`. */
export function aformJson(a: AForm): Json {
  return a.k === 'col' ? jarr(a.ns.map(jnum)) : jarr(a.rs.map((r) => jarr(r.map(jnum))))
}

/** `Math.numToks`. */
export function numToks(ns: readonly JNum[]): Tok[][] {
  return ns.map((n) => [tNum(n)])
}

/** `Math.bmatMaxCols`: the most columns a LaTeX `bmatrix` holds (amsmath `MaxMatrixCols`). */
export const BMAT_MAX_COLS = 10

/**
 * `Math.arrToks`: LaTeX `bmatrix`, or `\left[\begin{array}{c…c} … \end{array}\right]`
 * for a matrix wider than {@link BMAT_MAX_COLS}; Typst `vec(…)` / `mat(…)`.
 */
export function arrToks(sf: Sf, a: AForm): Tok[] {
  if (a.k === 'col') {
    return sf === 'latex'
      ? cat([kw('Bmat')], sepBy([kw('Nl')], numToks(a.ns)), [kw('Emat')])
      : cat([kw('Vec'), kw('Lp')], sepBy(COMMA, numToks(a.ns)), [kw('Rp')])
  }
  const width = a.rs[0].length
  const wide = width > BMAT_MAX_COLS
  return sf === 'latex'
    ? cat(
        wide ? [kw('Lbkg'), tAcols(width)] : [kw('Bmat')],
        sepBy(
          [kw('Nl')],
          a.rs.map((r) => sepBy([kw('Amp')], numToks(r))),
        ),
        wide ? [kw('Earr'), kw('Rbkg')] : [kw('Emat')],
      )
    : cat(
        [kw('Mat'), kw('Lp')],
        sepBy(
          [kw('Semi')],
          a.rs.map((r) => sepBy(COMMA, numToks(r))),
        ),
        [kw('Rp')],
      )
}

/** `Math.unitToks`: the unit after a number or an array. */
export function unitToks(l: readonly Factor[]): Tok[] {
  return [tUnits(l)]
}

// ## Reductions (`faq`)

/** `Math.jbeq`: structural equality of JSON values. */
export function jbeq(a: Json, b: Json): boolean {
  return jsonEq(a, b)
}

/** `Math.idxBase`: the array an `index` node reads, when it names one. */
export function idxBase(kvs: Kvs): string | undefined {
  const o = look('op', kvs)
  const a = look('args', kvs)
  if (
    o?.t === 'str' &&
    o.s === 'index' &&
    a?.t === 'arr' &&
    a.xs.length > 0 &&
    a.xs[0].t === 'str'
  ) {
    return a.xs[0].s
  }
  return undefined
}

/** `Math.basesJ`: the arrays an expression indexes, in first-use order (appended to `acc`). */
export function basesJ(j: Json, acc: string[]): void {
  if (j.t === 'obj') {
    const s = idxBase(j.kvs)
    if (s !== undefined && !acc.includes(s)) acc.push(s)
    for (const [, v] of j.kvs) basesJ(v, acc)
  } else if (j.t === 'arr') {
    for (const x of j.xs) basesJ(x, acc)
  }
}

/** `Math.bases`. */
export function bases(e: Json): string[] {
  const acc: string[] = []
  basesJ(e, acc)
  return acc
}

/** `Math.RedK`: the reductions with a native spelling. */
export type RedK = 'Sum' | 'Prod' | 'Max' | 'Min'

/** `Math.RedK.kw`. */
export function redKw(r: RedK): Kw {
  return r
}

/** `Math.RedK.field`. */
export function redField(r: RedK): Kv[] {
  switch (r) {
    case 'Sum':
      return []
    case 'Prod':
      return [['reduce', jstr('*')]]
    case 'Max':
      return [['reduce', jstr('max')]]
    case 'Min':
      return [['reduce', jstr('min')]]
  }
}

/**
 * `Math.FaqForm`: a `faq` node with a native spelling, by its parts. `marked`:
 * `args` lists the arrays the body indexes; otherwise `args` is `set` (empty,
 * or names printed as a superscript set).
 */
export interface FaqForm {
  readonly red: RedK
  readonly marked: boolean
  readonly out: readonly Json[]
  readonly ranges: readonly Kv[]
  readonly expr: Json
  readonly filter: Json | undefined
  readonly set: readonly string[]
}

/** `Math.FaqForm.args`: the `args` of a native `faq`. */
export function faqArgs(f: FaqForm): Json[] {
  return (f.marked ? bases(f.expr) : f.set).map(jstr)
}

/** `Math.FaqForm.sup`: the names a superscript set shows: `set` when `args` is not the body's arrays. */
export function faqSup(f: FaqForm): readonly string[] {
  return f.marked ? [] : f.set
}

/** `Math.faqJson`. */
export function faqJson(f: FaqForm): Json {
  const kvs: Kv[] = [
    ['args', jarr(faqArgs(f))],
    ['expr', f.expr],
  ]
  if (f.filter !== undefined) kvs.push(['filter', f.filter])
  kvs.push(['op', jstr('faq')])
  kvs.push(['output_idx', jarr(f.out)])
  if (f.ranges.length > 0) kvs.push(['ranges', jobj(f.ranges)])
  kvs.push(...redField(f.red))
  return jobj(kvs)
}

/** `Math.strsOf`: the strings of a list of JSON values, when they are all strings. */
export function strsOf(xs: readonly Json[]): string[] | undefined {
  const out: string[] = []
  for (const x of xs) {
    if (x.t !== 'str') return undefined
    out.push(x.s)
  }
  return out
}

/** `Math.faqCand`: the parts a `faq` node would have. */
export function faqCand(kvs: Kvs): FaqForm | undefined {
  const e = look('expr', kvs)
  const out = look('output_idx', kvs)
  const args = look('args', kvs)
  if (e === undefined || out?.t !== 'arr' || args?.t !== 'arr') return undefined
  const rd = look('reduce', kvs)
  let red: RedK
  if (rd === undefined) red = 'Sum'
  else if (rd.t === 'str' && rd.s === '*') red = 'Prod'
  else if (rd.t === 'str' && rd.s === 'max') red = 'Max'
  else if (rd.t === 'str' && rd.s === 'min') red = 'Min'
  else return undefined
  const rg = look('ranges', kvs)
  let ranges: readonly Kv[]
  if (rg === undefined) ranges = []
  else if (rg.t === 'obj') ranges = rg.kvs
  else return undefined
  let marked: boolean
  let set: readonly string[]
  if (args.xs.length === 0) {
    marked = false
    set = []
  } else if (jbeq(jarr(args.xs), jarr(bases(e).map(jstr)))) {
    marked = true
    set = []
  } else {
    const st = strsOf(args.xs)
    if (st === undefined) return undefined
    marked = false
    set = st
  }
  return {
    red,
    marked,
    out: out.xs,
    ranges,
    expr: e,
    filter: look('filter', kvs),
    set,
  }
}

/** `Math.faqForm`: the parts of a `faq` node, when it is exactly the node they rebuild. */
export function faqForm(kvs: Kvs): FaqForm | undefined {
  const f = faqCand(kvs)
  return f !== undefined && jbeq(faqJson(f), jobj(kvs)) ? f : undefined
}

/** `Math.rangeOK`: a range a row can spell. */
export function rangeOk(j: Json): boolean {
  if (j.t === 'arr') return j.xs.length === 2 && isE(j.xs[0]) && isE(j.xs[1])
  if (j.t !== 'obj') return false
  const kvs = j.kvs
  if (kvs.length === 1) return kvs[0][0] === 'from' && kvs[0][1].t === 'str' && nameOk(kvs[0][1].s)
  if (kvs.length === 2) {
    const [[k, s], [k2, ps]] = kvs
    return (
      k === 'from' &&
      k2 === 'of' &&
      s.t === 'str' &&
      ps.t === 'arr' &&
      nameOk(s.s) &&
      ps.xs.length > 0 &&
      ps.xs.every((p) => p.t === 'str' && nameOk(p.s))
    )
  }
  return false
}

/** `Math.outNames`. */
export function outNames(out: readonly Json[]): string[] {
  const ns: string[] = []
  for (const j of out) if (j.t === 'str') ns.push(j.s)
  return ns
}

/** `Math.outOK`: an output entry: a name, or the singleton dimension `1`. */
export function outOk(j: Json): boolean {
  return (j.t === 'str' && nameOk(j.s)) || (j.t === 'num' && j.n.k === 'int' && j.n.v === 1n)
}

/** `Math.occursJ`: a bare name occurs in an expression. */
export function occursJ(k: string, j: Json): boolean {
  switch (j.t) {
    case 'str':
      return j.s === k
    case 'arr':
      return j.xs.some((x) => occursJ(k, x))
    case 'obj':
      return j.kvs.some(([, v]) => occursJ(k, v))
    default:
      return false
  }
}

/** `Math.faqOK`: the conditions under which the native spelling reads back. */
export function faqOk(f: FaqForm): boolean {
  const names = outNames(f.out)
  const filter = f.filter
  return (
    isE(f.expr) &&
    (filter === undefined || isE(filter)) &&
    f.out.every(outOk) &&
    nodup(names) &&
    f.set.every(nameOk) &&
    keysSorted(f.ranges) &&
    f.ranges.every(
      ([k, v]) =>
        nameOk(k) &&
        rangeOk(v) &&
        (names.includes(k) || occursJ(k, f.expr) || (filter !== undefined && occursJ(k, filter))),
    )
  )
}

/** `Math.upSet`: a segment of an index set's name prints upright in a Typst range row
 * when it would otherwise print `italic("…")`. */
export function upSet(sf: Sf, g: string): boolean {
  return sf === 'typst' && segOk(g) && !isSingle(g) && subParts(g) === undefined && !isFormula(g)
}

/** `Math.setSegToks`: one segment of an index set's name. */
export function setSegToks(sf: Sf, g: string): Tok[] {
  return upSet(sf, g) ? [tUps([[g, '']])] : segToks(sf, g)
}

/** `Math.setToks`: the tokens of an index set's name in a range row. */
export function setToks(c: Ctx, s: string): Tok[] {
  if (explicitName(c.s, s)) return [tIt(s)]
  return sepBy(
    [kw('Sdot')],
    splitDots(s).map((g) => setSegToks(c.sf, g)),
  )
}

/** `Math.rowToks`: a range row: `a \le k \le b`, `k \in S`, `k \in S(i, j)`. */
export function rowToks(c: Ctx, k: string, v: Json): Tok[] {
  if (v.t === 'arr') {
    if (v.xs.length !== 2) return []
    return cat(pa(c, 4, v.xs[0]), [kw('Le')], nameToks(c, k), [kw('Le')], pa(c, 4, v.xs[1]))
  }
  if (v.t !== 'obj') return []
  const kvs = v.kvs
  if (kvs.length === 1 && kvs[0][0] === 'from' && kvs[0][1].t === 'str') {
    return cat(nameToks(c, k), [kw('Inn')], setToks(c, kvs[0][1].s))
  }
  if (kvs.length === 2) {
    const [[f, s], [o, ps]] = kvs
    if (f === 'from' && o === 'of' && s.t === 'str' && ps.t === 'arr') {
      return cat(
        nameToks(c, k),
        [kw('Inn')],
        setToks(c, s.s),
        [kw('Lp')],
        sepBy(
          COMMA,
          ps.xs.map((p) => (p.t === 'str' ? nameToks(c, p.s) : [])),
        ),
        [kw('Rp')],
      )
    }
  }
  return []
}

/** `Math.redRanges`: the ranges of indices that are not output indices. */
export function redRanges(f: FaqForm): Kv[] {
  const names = outNames(f.out)
  return f.ranges.filter((kv) => !names.includes(kv[0]))
}

/** `Math.subRows`: the rows of the subscript: the reduced ranges, then the filter. */
export function subRows(c: Ctx, f: FaqForm): Tok[][] {
  const rows = redRanges(f).map(([k, v]) => rowToks(c, k, v))
  if (f.filter !== undefined) rows.push(pa(c, 1, f.filter))
  return rows
}

/** `Math.headToks`: the operator, marked when `args` is listed. */
export function headToks(sf: Sf, f: FaqForm): Tok[] {
  if (sf === 'latex') return f.marked ? [kw(redKw(f.red)), kw('LimitsL')] : [kw(redKw(f.red))]
  return f.marked ? [kw('Limits'), kw('Lp'), kw(redKw(f.red)), kw('Rp')] : [kw(redKw(f.red))]
}

/**
 * `Math.subToksL`: the LaTeX subscript: none, one row, a lone dense range
 * `_{k=a}^{b}` (not when `args` is a superscript set), or `\substack`.
 */
export function subToksL(c: Ctx, f: FaqForm): Tok[] {
  const rr = redRanges(f)
  if (rr.length === 1 && f.filter === undefined && faqSup(f).length === 0) {
    const [k, ab] = rr[0]
    if (ab.t === 'arr' && ab.xs.length === 2) {
      return cat(
        [kw('Us'), kw('Lb')],
        nameToks(c, k),
        [kw('Eq')],
        pa(c, 4, ab.xs[0]),
        [kw('Rb'), kw('Caret'), kw('Lb')],
        pa(c, 1, ab.xs[1]),
        [kw('Rb')],
      )
    }
  }
  const rows = subRows(c, f)
  if (rows.length === 0) return []
  if (rows.length === 1) return cat([kw('Us'), kw('Lb')], rows[0], [kw('Rb')])
  return cat([kw('Us'), kw('Lb'), kw('Substack'), kw('Lb')], sepBy([kw('Nl')], rows), [
    kw('Rb'),
    kw('Rb'),
  ])
}

/** `Math.subToksT`: the Typst subscript: rows in `_( … )`, stacked with `\`. */
export function subToksT(c: Ctx, f: FaqForm): Tok[] {
  const rows = subRows(c, f)
  return rows.length === 0 ? [] : cat([kw('Us'), kw('Lpg')], sepBy([kw('Nl')], rows), [kw('Rp')])
}

/** `Math.subToks`. */
export function subToks(c: Ctx, f: FaqForm): Tok[] {
  return c.sf === 'latex' ? subToksL(c, f) : subToksT(c, f)
}

/** `Math.supToks`: the superscript set of names: LaTeX `^{\{f, g\}}`, Typst `^({f, g})`. */
export function supToks(c: Ctx, ns: readonly string[]): Tok[] {
  const names = sepBy(
    COMMA,
    ns.map((n) => nameToks(c, n)),
  )
  return c.sf === 'latex'
    ? cat([kw('Caret'), kw('Lb'), kw('Lset')], names, [kw('Rset'), kw('Rb')])
    : cat([kw('Caret'), kw('Lpg'), kw('Lset')], names, [kw('Rset'), kw('Rp')])
}

/** `Math.supT`: the `args` set of a `faq`, as a superscript, when it is one. */
export function supT(c: Ctx, f: FaqForm): Tok[] {
  const sup = faqSup(f)
  return sup.length === 0 ? [] : supToks(c, sup)
}

/**
 * `Math.redToks`: operator, subscript, the superscript set (on the operator
 * only when there are no output indices), body at level 5.
 */
export function redToks(c: Ctx, f: FaqForm): Tok[] {
  return cat(
    headToks(c.sf, f),
    subToks(c, f),
    f.out.length === 0 ? supT(c, f) : [],
    pa(c, 5, f.expr),
  )
}

/** `Math.entryToks`: an output entry: its range row when it has one. */
export function entryToks(c: Ctx, f: FaqForm, j: Json): Tok[] {
  if (j.t === 'str') {
    const v = look(j.s, f.ranges)
    return v !== undefined ? rowToks(c, j.s, v) : nameToks(c, j.s)
  }
  return [tNum(mkInt(1))]
}

/**
 * `Math.faqOut`: the native `faq`, wrapped with its output indices when it has
 * some. A superscript set goes on the bracket, before its subscript; the form
 * is then a power's level (a power of it, or an index into it, is
 * parenthesized: no double superscript).
 *
 * Lean passes the printer of the sub-expressions as a table (`tableP` over
 * `faqSubs`); every lookup is of a member of `faqSubs`, so the port calls
 * {@link pr} directly.
 */
export function faqOut(c: Ctx, f: FaqForm): Out {
  if (f.out.length === 0) return mkOut(5, redToks(c, f))
  const es = sepBy(
    COMMA,
    f.out.map((j) => entryToks(c, f, j)),
  )
  const sup = supT(c, f)
  const l = sup.length === 0 ? 10 : 8
  if (c.sf === 'latex') {
    return mkOut(
      l,
      cat([kw('Lbkg')], redToks(c, f), [kw('Rbkg')], sup, [kw('Us'), kw('Lb')], es, [kw('Rb')]),
    )
  }
  return mkOut(
    l,
    cat(
      [kw('Lr'), kw('Lp'), kw('Lbk')],
      redToks(c, f),
      [kw('Rbk'), kw('Rp')],
      sup,
      [kw('Us'), kw('Lpg')],
      es,
      [kw('Rp')],
    ),
  )
}

// ## Block assembly (`makearray`)

/**
 * `Math.MkForm`: a `makearray` node with a native spelling, by its parts: the
 * output indices (empty when the node has no `output_idx`), and the regions
 * with their values.
 */
export interface MkForm {
  readonly out: readonly string[]
  readonly regions: readonly (readonly (readonly [Json, Json])[])[]
  readonly values: readonly Json[]
}

/** `Math.mkJson`. */
export function mkJson(m: MkForm): Json {
  const kvs: Kv[] = [
    ['args', jarr([])],
    ['op', jstr('makearray')],
  ]
  if (m.out.length > 0) kvs.push(['output_idx', jarr(m.out.map(jstr))])
  kvs.push(['regions', jarr(m.regions.map((r) => jarr(r.map((p) => jarr([p[0], p[1]])))))])
  kvs.push(['values', jarr(m.values)])
  return jobj(kvs)
}

/** `Math.pairsOf`: the bound pairs of a region. */
export function pairsOf(xs: readonly Json[]): [Json, Json][] | undefined {
  const out: [Json, Json][] = []
  for (const x of xs) {
    if (x.t !== 'arr' || x.xs.length !== 2) return undefined
    out.push([x.xs[0], x.xs[1]])
  }
  return out
}

/** `Math.regionsOf`: the regions of a `regions` list. */
export function regionsOf(xs: readonly Json[]): [Json, Json][][] | undefined {
  const out: [Json, Json][][] = []
  for (const x of xs) {
    if (x.t !== 'arr') return undefined
    const q = pairsOf(x.xs)
    if (q === undefined) return undefined
    out.push(q)
  }
  return out
}

/** `Math.mkCand`: the parts a `makearray` node would have. */
export function mkCand(kvs: Kvs): MkForm | undefined {
  const rs = look('regions', kvs)
  const vs = look('values', kvs)
  if (rs?.t !== 'arr' || vs?.t !== 'arr') return undefined
  const o = look('output_idx', kvs)
  let out: string[] | undefined
  if (o === undefined) out = []
  else if (o.t === 'arr') out = strsOf(o.xs)
  else return undefined
  const regs = regionsOf(rs.xs)
  if (out === undefined || regs === undefined) return undefined
  return { out, regions: regs, values: vs.xs }
}

/**
 * `Math.mkForm`: the parts of a `makearray` node, when it is exactly the node
 * they rebuild: `args` empty, `regions` and `values`, and an `output_idx` of
 * names or none.
 */
export function mkForm(kvs: Kvs): MkForm | undefined {
  const m = mkCand(kvs)
  return m !== undefined && jbeq(mkJson(m), jobj(kvs)) ? m : undefined
}

/**
 * `Math.mkOK`: the conditions under which the native spelling reads back: one
 * value per region, at least one region, each region a nonempty list of bound
 * pairs, values and bounds expressions, output indices names.
 */
export function mkOk(m: MkForm): boolean {
  return (
    m.values.length > 0 &&
    m.regions.length === m.values.length &&
    m.values.every(isE) &&
    m.regions.every((r) => r.length > 0 && r.every((p) => isE(p[0]) && isE(p[1]))) &&
    m.out.every(nameOk)
  )
}

/** `Math.cellSep`: the cell separator of the table. */
export function cellSep(sf: Sf): Kw {
  return sf === 'latex' ? 'Amp' : 'Comma'
}

/** `Math.rowSep`: the row separator of the table. */
export function rowSep(sf: Sf): Kw {
  return sf === 'latex' ? 'Nl' : 'Semi'
}

/** `Math.pairToks`: a bound pair: `a, b` (its brackets are written around it). */
export function pairToks(c: Ctx, p: readonly [Json, Json]): Tok[] {
  return cat(pa(c, 1, p[0]), COMMA, pa(c, 1, p[1]))
}

/** `Math.regToks`: a region: `[a, b] \times [c, d]`, one bound pair per dimension. */
export function regToks(c: Ctx, ps: readonly (readonly [Json, Json])[]): Tok[] {
  if (ps.length === 0) return []
  const out = cat([kw('Lbk')], pairToks(c, ps[0]), [kw('Rbk')])
  for (const q of ps.slice(1)) out.push(kw('Times'), kw('Lbk'), ...pairToks(c, q), kw('Rbk'))
  return out
}

/** `Math.mkRow`: a row of the table: the value, then the region it fills. */
export function mkRow(c: Ctx, v: Json, r: readonly (readonly [Json, Json])[]): Tok[] {
  return cat(pa(c, 1, v), [kw(cellSep(c.sf))], regToks(c, r))
}

/**
 * `Math.matHead`: the Typst table head: `mat(delim: "[", augment: #1,`; `delim`
 * and `augment` are plain words, not keywords.
 */
export function matHead(): Tok[] {
  return [
    kw('Mat'),
    kw('Lp'),
    tWord('delim'),
    kw('Colon'),
    tTxt('['),
    kw('Comma'),
    tWord('augment'),
    kw('Colon'),
    tCode(jnum(mkInt(1))),
    kw('Comma'),
  ]
}

/** `Math.mkSub`: the output indices as the bracket's subscript. */
export function mkSub(c: Ctx, out: readonly string[]): Tok[] {
  if (out.length === 0) return []
  const names = sepBy(
    COMMA,
    out.map((n) => nameToks(c, n)),
  )
  return c.sf === 'latex'
    ? cat([kw('Us'), kw('Lb')], names, [kw('Rb')])
    : cat([kw('Us'), kw('Lpg')], names, [kw('Rp')])
}

/**
 * `Math.mkOutT`: the native `makearray`: a bracketed two-column table, value
 * then region, one row per region in order; LaTeX
 * `\left[\begin{array}{l|l} v & [a, b] \\ … \end{array}\right]`, Typst
 * `mat(delim: "[", augment: #1, v, [a, b]; …)`; the output indices as its
 * subscript. As for {@link faqOut}, the port calls {@link pr} directly.
 */
export function mkOutT(c: Ctx, m: MkForm): Out {
  const rows = sepBy(
    [kw(rowSep(c.sf))],
    m.values.map((v, i) => mkRow(c, v, m.regions[i])),
  )
  return c.sf === 'latex'
    ? mkOut(10, cat([kw('Lbkg'), kw('Barr')], rows, [kw('Earr'), kw('Rbkg')], mkSub(c, m.out)))
    : mkOut(10, cat(matHead(), rows, [kw('Rp')], mkSub(c, m.out)))
}

/** `Math.tnameOK`. */
export function tnameOk(n: string): boolean {
  return opnOk(n) && !reservedOpn(n)
}

/** `Math.pr`: the printer. */
export function pr(c: Ctx, e: Json): Out {
  const sf = c.sf
  if (e.t === 'num') return mkOut(isNegNum(e) ? 7 : 10, [tNum(e.n)])
  if (e.t === 'str') return mkOut(10, nameToks(c, e.s))
  if (e.t !== 'obj') return mkOut(10, [])
  const kvs = e.kvs
  const esc = (): Out => {
    const o = look('op', kvs)
    const args = look('args', kvs)
    if (o?.t === 'str' && args?.t === 'arr') {
      return mkOut(
        10,
        escToks(
          sf,
          o.s,
          fieldsOf(kvs),
          args.xs.map((a) => pa(c, 1, a)),
        ),
      )
    }
    return mkOut(10, [])
  }
  const fq = (): Out | undefined => {
    const f = faqForm(kvs)
    return f !== undefined && faqOk(f) ? faqOut(c, f) : undefined
  }
  const mk = (): Out | undefined => {
    const m = mkForm(kvs)
    return m !== undefined && mkOk(m) ? mkOutT(c, m) : undefined
  }
  const opn = (): Out => {
    const o = look('op', kvs)
    const args = look('args', kvs)
    if (o?.t !== 'str' || args?.t !== 'arr') return esc()
    const fs = fieldsOf(kvs)
    if (
      !callFormOk(o.s, fs) ||
      !opnOk(o.s) ||
      tparams(c.s, o.s) !== undefined ||
      !fs.every((kv) => keyOk(kv[0]))
    ) {
      return esc()
    }
    return mkOut(
      10,
      openToks(
        sf,
        o.s,
        args.xs.map((a) => pa(c, 4, a)),
        fs.map((kv) =>
          cat(
            keyToks(sf, kv[0]),
            [kw('Eq')],
            mathField(o.s, kv) ? pa(c, 4, kv[1]) : jsonVal(sf, kv[1]),
          ),
        ),
      ),
    )
  }
  const field = (i: number, k: string): Json | undefined =>
    i < kvs.length && kvs[i][0] === k ? kvs[i][1] : undefined
  const strAt = (i: number, k: string, v: string): boolean => {
    const f = field(i, k)
    return f?.t === 'str' && f.s === v
  }
  const emptyArgs = (): boolean => {
    const a = field(0, 'args')
    return a?.t === 'arr' && a.xs.length === 0
  }
  switch (kvs.length) {
    case 2: {
      const args = field(0, 'args')
      const o = field(1, 'op')
      if (args?.t === 'arr' && o?.t === 'str') return prPlain(c, o.s, args.xs, opn, esc)
      break
    }
    case 3: {
      const args = field(0, 'args')
      const w = field(2, 'wrt')
      if (args?.t === 'arr' && strAt(1, 'op', 'D') && w?.t === 'str') {
        // `D` is the time derivative only; any other `wrt` is the escape form.
        const xs = args.xs
        return xs.length === 1 && w.s === 't' ? dTime(sf, pr(c, xs[0])) : esc()
      }
      if (args?.t === 'arr' && strAt(1, 'op', 'partial') && w?.t === 'str') {
        // `partial` (spec §4.2): one operand, or trailing operands, along an axis
        // other than `t`; any other `partial` is the call form.
        const xs = args.xs
        if (!(w.s !== 't' && nameOk(w.s)) || xs.length === 0) return opn()
        if (xs.length === 1) return dSpace(sf, nameToks(c, w.s), pr(c, xs[0]))
        return mkOut(
          10,
          dCall(
            sf,
            nameToks(c, w.s),
            xs.map((x) => pa(c, 4, x)),
          ),
        )
      }
      const cn = constNative(sf, kvs)
      if (cn !== undefined) return cn
      break
    }
    case 4: {
      const cn = constNative(sf, kvs)
      if (cn !== undefined) return cn
      if (emptyArgs()) {
        const bs = field(1, 'bindings')
        const n = field(2, 'name')
        if (bs?.t === 'obj' && n?.t === 'str' && strAt(3, 'op', 'apply_operator')) {
          return prTemplate(c, n.s, bs.kvs, esc)
        }
      }
      break
    }
  }
  return fq() ?? mk() ?? opn()
}

/** The `[("args", .arr as), ("op", .str o)]` case of `Math.pr`. */
function prPlain(c: Ctx, o: string, args: readonly Json[], opn: () => Out, esc: () => Out): Out {
  const sf = c.sf
  const chain = (l: number, sep: Kw | undefined, lvl: number): Out => {
    const parts = args.map((x) => pa(c, l, x))
    return sep !== undefined ? mkOut(lvl, sepBy([kw(sep)], parts)) : mkOut(lvl, mulToks(parts))
  }
  const k = kindOf(o)
  const n = args.length
  switch (k.k) {
    case 'Minus':
      if (n === 1) {
        const t = pa(c, 5, args[0])
        return mkOut(5, cat([kw('Minus')], startsNum(t) ? grp(sf, t) : t))
      }
      if (n === 2) return mkOut(4, cat(pa(c, 4, args[0]), [kw('Minus')], pa(c, 5, args[1])))
      return opn()
    case 'Div':
      if (n !== 2) return opn()
      return sf === 'latex'
        ? mkOut(
            10,
            cat(
              [kw('Frac'), kw('Lb')],
              pa(c, 1, args[0]),
              [kw('Rb'), kw('Lb')],
              pa(c, 1, args[1]),
              [kw('Rb')],
            ),
          )
        : mkOut(7, cat(pa(c, 8, args[0]), [kw('Slash')], pa(c, 8, args[1])))
    case 'Pow': {
      if (n !== 2) return opn()
      const b = args[1]
      let ex: Tok[]
      if (sf === 'latex') ex = cat([kw('Lb')], pa(c, 1, b), [kw('Rb')])
      else {
        const t = simpleE(c, b)
        ex = t !== undefined ? [t] : grp(sf, pr(c, b).toks)
      }
      return mkOut(8, cat(pa(c, 9, args[0]), [kw('Caret')], ex))
    }
    case 'Lnot':
      return n === 1 ? mkOut(6, cat([kw('Lnot')], pa(c, 6, args[0]))) : opn()
    case 'Tru':
      return n === 0 ? mkOut(10, [tTxt('true')]) : opn()
    case 'Fls':
      return n === 0 ? mkOut(10, [tTxt('false')]) : opn()
    case 'Ite': {
      if (n !== 3) return opn()
      const rows = caseRow(sf, pa(c, 1, args[1]), pa(c, 1, args[0]))
      rows.push(...outCrow(pr(c, args[2])))
      return { lvl: 10, toks: casesToks(sf, rows), crow: rows }
    }
    case 'Un':
      return n === 1 ? mkOut(10, unToks(sf, k.kw, pa(c, 1, args[0]))) : opn()
    case 'Ic':
      if (n === 1 && args[0].t === 'str') {
        const nm = args[0].s
        return nameOk(nm) ? mkOut(10, cat(nameToks(c, nm), icTail(sf))) : esc()
      }
      return opn()
    case 'Index': {
      if (n < 2) return opn()
      const base = args[0]
      const is = args.slice(1)
      const subs = (): Tok[][] => is.map((x) => pa(c, 1, x))
      const sl = subList(sf, simpleArg(c, is), subs())
      if (subOk(c.s, base, is) && !subPat(sf, sl)) {
        const b = base.t === 'str' ? base.s : ''
        return mkOut(9, cat(nameToks(c, b), sl))
      }
      return mkOut(9, cat(pa(c, 10, base), [kw('Lbk')], sepBy(COMMA, subs()), [kw('Rbk')]))
    }
    case 'Cmp':
      return n === 2 ? mkOut(3, cat(pa(c, 4, args[0]), [kw(k.kw)], pa(c, 4, args[1]))) : opn()
    case 'Plus':
      return 2 <= n ? chain(5, 'Plus', 4) : opn()
    case 'Times':
      return 2 <= n ? chain(6, undefined, 5) : opn()
    case 'Land':
      return 2 <= n ? chain(3, 'Land', 2) : opn()
    case 'Lor':
      return 2 <= n ? chain(2, 'Lor', 1) : opn()
    case 'Mm':
      return 2 <= n
        ? mkOut(
            10,
            callToks(
              sf,
              [kw(k.kw)],
              args.map((x) => pa(c, 1, x)),
            ),
          )
        : opn()
    case 'Nab':
      return n === 1 ? mkOut(6, cat(nabHead(sf, k.n), nabArg(sf, k.n, pr(c, args[0])))) : opn()
    case 'Call':
      return mkOut(
        10,
        callToks(
          sf,
          [tOpn(o)],
          args.map((x) => pa(c, 4, x)),
        ),
      )
    default:
      return opn()
  }
}

/** The `apply_operator` case of `Math.pr`. */
function prTemplate(c: Ctx, n: string, bs: Kvs, esc: () => Out): Out {
  const sf = c.sf
  if (!(tnameOk(n) && keysSorted(bs) && bs.every((kv) => isE(kv[1])))) return esc()
  const vals: [string, Tok[]][] = bs.map(([k, v]) => [k, pa(c, 4, v)])
  const ps = positional(c.s, n, bs)
  if (ps !== undefined) {
    return mkOut(
      10,
      callToks(
        sf,
        [tOpn(n)],
        ps.map((p) => vals.find((kv) => kv[0] === p)?.[1] ?? []),
      ),
    )
  }
  if (bs.length > 0 && bs.every((kv) => nameOk(kv[0]))) {
    return mkOut(
      10,
      callToks(
        sf,
        [tOpn(n)],
        vals.map(([k, v]) => cat(nameToks(c, k), [kw('Eq')], v)),
      ),
    )
  }
  if (bs.length === 0) return mkOut(5, [tOpn(n)])
  return esc()
}

/**
 * `Math.constNative`: the native spelling of a constant, `{args: [], op:
 * "const", value}` with an array value or `{args: [], op: "const", units, value}`
 * with a number or array value and a unit the surface spells; undefined when
 * the node has none. Only numbers and units are printed, no subexpression.
 */
export function constNative(sf: Sf, kvs: Kvs): Out | undefined {
  const at = (i: number, k: string): Json | undefined =>
    i < kvs.length && kvs[i][0] === k ? kvs[i][1] : undefined
  const args = at(0, 'args')
  const o = at(1, 'op')
  if (!(args?.t === 'arr' && args.xs.length === 0 && o?.t === 'str' && o.s === 'const'))
    return undefined
  if (kvs.length === 3) {
    const v = at(2, 'value')
    const af = v?.t === 'arr' ? arrForm(v) : undefined
    return af && mkOut(10, arrToks(sf, af))
  }
  const u = at(2, 'units')
  const v = at(3, 'value')
  if (kvs.length !== 4 || u?.t !== 'str' || !unitsOk(sf, u.s)) return undefined
  if (v?.t === 'num') return mkOut(7, qtyToks(v.n, factorsOf(u.s)))
  const af = v?.t === 'arr' ? arrForm(v) : undefined
  return af && mkOut(7, cat(arrToks(sf, af), unitToks(factorsOf(u.s))))
}

/**
 * The printer writes node `kvs`, of operator `o` with fields `fs`, in the call
 * form `\operatorname{o}(…; …)`: {@link callFormOk}, a name {@link opnOk}, no
 * template of that name in scope, and no native spelling (a constant, a `faq`
 * or a `makearray`). The `D` and template nodes with their own spellings are
 * core operators {@link callFormOk} already excludes. The field keys are not
 * checked ({@link keyOk}): the reader takes any key spelling. Nothing is
 * printed; only a `faq` or `makearray` node is walked, by the same shape tests
 * the printer applies to it.
 */
export function callFormNode(c: Ctx, o: string, fs: readonly Kv[], kvs: Kvs): boolean {
  if (!(callFormOk(o, fs) && opnOk(o) && tparams(c.s, o) === undefined)) return false
  if (o === 'const') return constNative(c.sf, kvs) === undefined
  if (o === 'faq') {
    const f = faqForm(kvs)
    return !(f !== undefined && faqOk(f))
  }
  if (o === 'makearray') {
    const m = mkForm(kvs)
    return !(m !== undefined && mkOk(m))
  }
  return true
}

/** `Math.pa`: the tokens of an expression for a position needing level `L`. */
export function pa(c: Ctx, l: number, e: Json): Tok[] {
  return outAt(pr(c, e), c.sf, l)
}

/** `Math.print`: the tokens of a whole expression. */
export function print(sf: Sf, s: Sym, e: Json): Tok[] {
  return pa({ sf, s }, 1, e)
}
