/**
 * The Markdown container: CommonMark with `$…$` / `$$…$$` LaTeX math, fenced
 * blocks, YAML front matter and remark directives.
 *
 * Port of `formal/Esm/Document/Source/Markdown.lean` (namespace `Source.Md`),
 * after the Rust binding's `document/source/markdown.rs`. The lexer reads a
 * construct where one starts and otherwise drops one character of prose; a code
 * span is skipped whole.
 */

import { jarr, jobj, jsonWfmb, jstr, type Json } from '../json.js'
import { nested } from '../limits.js'
import { escT, jwf, nameOk, parseLatex, printLatex, rawB, unescT, type Sym } from '../math/index.js'
import { chars, type Chars, type Read } from '../number.js'
import { escChar, isIdent, parseKey, parseQuoted, printKey, readIdent } from '../strings.js'
import * as yaml from '../yaml.js'
import type { RItem } from './items.js'
import type { Kv } from './keys.js'
import { idChar, idOk, pPiece, pSide, sideOk, sideTxt, type RSurf } from './reaction.js'
import type { DKind, Decl, Kind, Role, Rxn, Tm } from './skeleton.js'
import {
  afterS,
  blank,
  findChar,
  hasSub,
  noStop,
  preS,
  splitLine,
  str,
  takeWhile,
  untilStop,
} from './text.js'

// ## Spellings

const FENCE_ESM = '```esm:'
const FENCE = '```'
const DD = '$$'
const D_MODEL = '::model['
const D_RS = '::reaction-system['
const DESC_INFO = 'description'
const D_PLOT = '::plot{'
const D_RXN = '$$\\ce{'
const D_INIT = ':::initialization'
const D_CONS = ':::constraints'
const D_END = ':::'
const D_SUB = '::subsystem['

/** `Md.dRole`. */
const dRole = (r: Role): string => (r === 'init' ? D_INIT : r === 'cons' ? D_CONS : D_END)

/** `Md.dkw`: the directive keyword of a declaration. */
const dkw = (k: DKind): string =>
  k === 'var' ? 'var' : k === 'param' ? 'param' : k === 'species' ? 'species' : 'subsystem'

/** The empty symbol table. */
const EMPTY_SYM: Sym = { names: [], templates: [] }

// ## Path-block keys

/** `Md.escKey`: the JSON escape, and the backtick as ```. */
const escKey = (c: string): string => (c === '`' ? '\\u0060' : escChar(false, c))

/** `Md.keyMd`: a path block's key in the fence's info string. */
export function keyMd(k: string): string {
  if (isIdent(k) && k !== DESC_INFO) return k
  let out = '"'
  for (const c of k) out += escKey(c)
  return out + '"'
}

/** `Md.parseKeyMd`: a path block's key from the whole info string. */
function parseKeyMd(info: string): string | undefined {
  if (info.startsWith('"')) {
    const cs = chars(info)
    const r = parseQuoted(false, cs, 0)
    return r !== undefined && r[1] === cs.length ? r[0] : undefined
  }
  return isIdent(info) && info !== DESC_INFO ? info : undefined
}

// ## Declarations

/** `Md.nameLatex`: a declared name as LaTeX math under the empty symbol table. */
export const nameLatex = (n: string): string => printLatex(EMPTY_SYM, jstr(n))

// ## Attribute values: YAML scalars and flow collections

/** `Md.flow`: a value as a YAML scalar or flow collection. */
function flow(v: Json): string {
  if (v.t === 'arr' && v.xs.length > 0) return `[${v.xs.map(flow).join(', ')}]`
  if (v.t === 'obj' && v.kvs.length > 0) {
    return `{${v.kvs.map(([k, x]) => `${printKey(false, yaml.reserved, k)}: ${flow(x)}`).join(', ')}}`
  }
  return yaml.inline(v)
}

/** `Md.pFlow`: a flow collection at `[` or `{`, else a scalar. */
function pFlow(cs: Chars, i: number): Read<Json> {
  return nested(() => pFlowIn(cs, i))
}

function pFlowIn(cs: Chars, i: number): Read<Json> {
  const c = cs[i]
  if (c === undefined) return undefined
  if (c === '[') {
    if (cs[i + 1] === ']') return [jarr([]), i + 2]
    const x = pFlow(cs, i + 1)
    if (x === undefined) return undefined
    const out: Json[] = [x[0]]
    // `Md.pItemsF`: the elements after the first, each after `, `, up to `]`.
    let j = x[1]
    for (;;) {
      if (cs[j] === ']') return [jarr(out), j + 1]
      if (cs[j] !== ',' || cs[j + 1] !== ' ') return undefined
      const y = pFlow(cs, j + 2)
      if (y === undefined) return undefined
      out.push(y[0])
      j = y[1]
    }
  }
  if (c === '{') {
    if (cs[i + 1] === '}') return [jobj([]), i + 2]
    const e = pEntryF(cs, i + 1)
    if (e === undefined) return undefined
    const out: Kv[] = [e[0]]
    // `Md.pEntriesF`: the entries after the first, each after `, `, up to `}`.
    let j = e[1]
    for (;;) {
      if (cs[j] === '}') return [jobj(out), j + 1]
      if (cs[j] !== ',' || cs[j + 1] !== ' ') return undefined
      const f = pEntryF(cs, j + 2)
      if (f === undefined) return undefined
      out.push(f[0])
      j = f[1]
    }
  }
  return yaml.pInline(cs, i)
}

/** `Md.pEntryF`: one entry, `key: value`. */
function pEntryF(cs: Chars, i: number): Read<Kv> {
  const k = parseKey(false, yaml.reserved, cs, i)
  if (k === undefined || cs[k[1]] !== ':' || cs[k[1] + 1] !== ' ') return undefined
  const v = pFlow(cs, k[1] + 2)
  return v && [[k[0], v[0]], v[1]]
}

/** `Md.isColl`. */
const isColl = (v: Json): boolean => v.t === 'arr' || v.t === 'obj'

/** `Md.sqEsc`: `'` as `&#39;` and `&` as `&amp;`. */
const sqEsc = (s: string): string => s.replace(/[&']/g, (c) => (c === '&' ? '&amp;' : '&#39;'))

/** `Md.sqUnesc`: undo `sqEsc`. */
const sqUnesc = (s: string): string => s.replace(/&#39;|&amp;/g, (m) => (m === '&amp;' ? '&' : "'"))

/** `Md.attrVal`: a scalar as its YAML, a list or object single-quoted. */
const attrVal = (v: Json): string => (isColl(v) ? `'${sqEsc(flow(v))}'` : flow(v))

/** `Md.attrMd`: `key=value`. */
const attrMd = (a: Kv): string => `${a[0]}=${attrVal(a[1])}`

/** `Md.attrsMd`: the attributes, separated by spaces. */
const attrsMd = (attrs: readonly Kv[]): string => attrs.map(attrMd).join(' ')

/** `Md.declMd`: `:var[$N$]{default=100 units="mol"}`. */
const declMd = (d: Decl): string => `:${dkw(d.kind)}[$${nameLatex(d.name)}$]{${attrsMd(d.attrs)}}`

/** `Md.pQuoted`: a single-quoted value after its opening quote. */
function pQuotedSq(cs: Chars, i: number): Read<Json> {
  const e = takeWhile(cs, i, (c) => c !== "'")
  if (cs[e] !== "'") return undefined
  const y = chars(sqUnesc(str(cs, i, e)))
  const v = pFlow(y, 0)
  return v !== undefined && v[1] === y.length ? [v[0], e + 1] : undefined
}

/** `Md.pAttr`: one attribute. */
function pAttr(cs: Chars, i: number): Read<Kv> {
  const [id, j] = readIdent(cs, i)
  if (!isIdent(id) || cs[j] !== '=') return undefined
  if (cs[j + 1] === "'") {
    const v = pQuotedSq(cs, j + 2)
    return v && [[id, v[0]], v[1]]
  }
  const v = pFlow(cs, j + 1)
  return v && [[id, v[0]], v[1]]
}

/** `Md.pAttrsMore`: the attributes after the first, each after a space, up to the closing brace. */
function pAttrsMore(cs: Chars, i: number): Read<Kv[]> {
  const out: Kv[] = []
  for (;;) {
    if (cs[i] === '}') return [out, i + 1]
    if (cs[i] !== ' ') return undefined
    const a = pAttr(cs, i + 1)
    if (a === undefined) return undefined
    out.push(a[0])
    i = a[1]
  }
}

/** `Md.pAttrs`: the attributes after the opening brace, up to the closing one. */
function pAttrs(cs: Chars, i: number): Read<Kv[]> {
  if (cs[i] === '}') return [[], i + 1]
  const a = pAttr(cs, i)
  if (a === undefined) return undefined
  const r = pAttrsMore(cs, a[1])
  return r && [[a[0], ...r[0]], r[1]]
}

/** `Md.declBody`: a declaration after its `[`. */
function declBody(k: DKind, cs: Chars, i: number): Read<RItem> {
  if (cs[i] !== '$') return undefined
  const e = takeWhile(cs, i + 1, (c) => c !== '$')
  if (!preS('$]{', cs, e)) return undefined
  const n = parseLatex(EMPTY_SYM, str(cs, i + 1, e))
  if (n === undefined || n.t !== 'str') return undefined
  const a = pAttrs(cs, e + 3)
  return a && [{ i: 'decl', d: { kind: k, name: n.s, attrs: a[0] } }, a[1]]
}

// ## Block constructs

/** `Md.fenceItem`: a fenced block's construct, from its info string and body. */
function fenceItem(info: string, body: string): RItem | undefined {
  if (info === DESC_INFO)
    return body.endsWith('\n') ? { i: 'desc', s: body.slice(0, -1) } : undefined
  const k = parseKeyMd(info)
  if (k === undefined) return undefined
  const v = yaml.decode(chars(body))
  return v && { i: 'block', k, v }
}

/** `Md.labelOK`: nothing, or `{#id}`, with spaces around. */
function labelOk(sl: string): boolean {
  const t = sl.replace(/^ */, '')
  if (t.length === 0) return true
  if (!t.startsWith('{#')) return false
  const inner = t.slice(2)
  return inner.endsWith('}') && !inner.slice(0, -1).includes('}')
}

/** `Md.fenceAt`: a fenced block after ```` ```esm: ````. */
function fenceAt(cs: Chars, i: number): Read<RItem> {
  const [e, after] = splitLine(cs, i)
  const u = untilStop(FENCE, cs, after)
  if (u === undefined || !blank(u[1])) return undefined
  const it = fenceItem(str(cs, i, e), u[0])
  return it && [it, u[2]]
}

// ## Templates and rules

const D_TMPL = ':::template{'
const D_RULE_C = ':::rule{'
const TM_HEAD_L = '\\operatorname{'
const TM_DEF = ') \\coloneqq '
const RULE_HEAD_L = '\\text{rule } \\operatorname{'
const RULE_SEP = ': \\; '
const RULE_ARROW = ' \\Rightarrow '

/** `Md.tmRaw`: the math text of a template or rule display (one line). */
function tmRaw(t: Tm<string>): string {
  if (t.lhs === undefined) {
    // `Md.paramsTxt`: the parameters of a template header, separated by `, `.
    return `${TM_HEAD_L}${escT(t.name)}}(${t.params.map(nameLatex).join(', ')}${TM_DEF}${t.body}`
  }
  return `${RULE_HEAD_L}${escT(t.name)}}${RULE_SEP}${t.lhs}${RULE_ARROW}${t.body}`
}

/** `Md.pName`: one parameter, up to the next `,` or `)`. */
function pName(cs: Chars, i: number): Read<string> {
  const e = takeWhile(cs, i, (c) => c !== ',' && c !== ')')
  const n = parseLatex(EMPTY_SYM, str(cs, i, e))
  return n !== undefined && n.t === 'str' ? [n.s, e] : undefined
}

/** `Md.pParams`: the parameters after `(`, up to `) \coloneqq `. */
function pParams(cs: Chars, i: number): Read<string[]> {
  const out: string[] = []
  for (;;) {
    const a = afterS(TM_DEF, cs, i)
    if (a !== undefined) return [out, a]
    const n = pName(cs, i)
    if (n === undefined) return undefined
    out.push(n[0])
    const b = afterS(TM_DEF, cs, n[1])
    if (b !== undefined) return [out, b]
    if (cs[n[1]] !== ',' || cs[n[1] + 1] !== ' ') return undefined
    i = n[1] + 2
  }
}

/** The pieces `tmLex` reads: name, parameters, a rule's left-hand side, body. */
type TmLex = [string, string[], string | undefined, string]

/** `Md.tmLex`: read the math text of a display as a template or rule. */
export function tmLex(raw: string): TmLex | undefined {
  // Every template or rule display starts with `\`; most equations do not.
  if (!raw.startsWith('\\')) return undefined
  const cs = chars(raw)
  const u = afterS(RULE_HEAD_L, cs, 0)
  if (u !== undefined) {
    const nm = rawB(0, cs, u)
    if (nm === undefined) return undefined
    const u2 = afterS(RULE_SEP, cs, nm[1])
    if (u2 === undefined) return undefined
    // `Md.splitAt`: split at the first occurrence of the arrow.
    const rest = str(cs, u2)
    const k = rest.indexOf(RULE_ARROW)
    if (k < 0) return undefined
    return [unescT(nm[0]), [], rest.slice(0, k), rest.slice(k + RULE_ARROW.length)]
  }
  const v = afterS(TM_HEAD_L, cs, 0)
  if (v === undefined) return undefined
  const nm = rawB(0, cs, v)
  if (nm === undefined || cs[nm[1]] !== '(') return undefined
  const ps = pParams(cs, nm[1] + 1)
  return ps && [unescT(nm[0]), ps[0], undefined, str(cs, ps[1])]
}

const tmLexEq = (a: TmLex | undefined, b: TmLex): boolean =>
  a !== undefined &&
  a[0] === b[0] &&
  a[1].length === b[1].length &&
  a[1].every((p, i) => p === b[1][i]) &&
  a[2] === b[2] &&
  a[3] === b[3]

/**
 * `Md.mathAt`: a display after its opening `$$`: a template or rule when its
 * math reads as one, otherwise an equation (optionally labelled).
 */
function mathAt(cs: Chars, i: number): Read<RItem> {
  const [e, after] = splitLine(cs, i)
  if (!blank(str(cs, i, e))) return undefined
  const u = untilStop(DD, cs, after)
  if (u === undefined) return undefined
  const [body, sl, rest] = u
  if (!body.endsWith('\n')) return undefined
  const b = body.slice(0, -1)
  const t = tmLex(b)
  if (t !== undefined) {
    return blank(sl)
      ? [{ i: 'tm', t: { name: t[0], params: t[1], lhs: t[2], body: t[3], attrs: [] } }, rest]
      : undefined
  }
  return labelOk(sl) ? [{ i: 'eqn', raw: b }, rest] : undefined
}

/** `Md.tmContAt`: a template or rule with other fields, after `:::template{` or `:::rule{`. */
function tmContAt(cs: Chars, i: number): Read<RItem> {
  const a = pAttrs(cs, i)
  if (a === undefined || cs[a[1]] !== '\n') return undefined
  const r1 = a[1] + 1
  if (!preS(DD, cs, r1)) return undefined
  const m = mathAt(cs, r1 + 2)
  if (m === undefined || m[0].i !== 'tm') return undefined
  const r2 = m[1]
  const [e, r3] = splitLine(cs, Math.min(r2 + 3, cs.length))
  if (!preS(D_END, cs, r2) || !blank(str(cs, r2 + 3, e))) return undefined
  return [{ i: 'tm', t: { ...m[0].t, attrs: a[0] } }, r3]
}

/** `Md.dirAt`: a component directive after its `[`. */
function dirAt(k: Kind, cs: Chars, i: number): Read<RItem> {
  const e = takeWhile(cs, i, (c) => c !== ']' && c !== '\n')
  if (cs[e] !== ']') return undefined
  const [le, r] = splitLine(cs, e + 1)
  return blank(str(cs, e + 1, le)) ? [{ i: 'comp', kind: k, name: str(cs, i, e) }, r] : undefined
}

// ## Reactions

/** `Md.latexR`: LaTeX under the empty symbol table. */
const LATEX_R: RSurf = {
  pm: (s) => parseLatex(EMPTY_SYM, s),
  prm: (j) => printLatex(EMPTY_SYM, j),
  empty: '\\varnothing',
}

const ARROW_L = ' ->[{$'
const ARROW_R = '}] '
const RXN_END = '}$$ {#'

/** `Md.rxnBody`: the text of a reaction line after `$$\ce{`. */
function rxnBody(x: Rxn<string>): string {
  let out = `${sideTxt(LATEX_R, x.subs)}${ARROW_L}${x.rate}$${ARROW_R}${sideTxt(LATEX_R, x.prods)}${RXN_END}${x.id}`
  for (const b of x.attrs) out += ` ${attrMd(b)}`
  return out + '}\n'
}

/** `Md.rxnAt`: a reaction line after its `$$\ce{`. */
function rxnAt(cs: Chars, i: number): Read<RItem> {
  const s = pSide(LATEX_R, cs, i)
  if (s === undefined) return undefined
  const u2 = afterS(ARROW_L, cs, s[1])
  if (u2 === undefined) return undefined
  const rate = pPiece(cs, u2)
  if (rate === undefined) return undefined
  const u3 = afterS(ARROW_R, cs, rate[1])
  if (u3 === undefined) return undefined
  const p = pSide(LATEX_R, cs, u3)
  if (p === undefined) return undefined
  const u5 = afterS(RXN_END, cs, p[1])
  if (u5 === undefined) return undefined
  const ide = takeWhile(cs, u5, idChar)
  const attrs = pAttrsMore(cs, ide)
  if (attrs === undefined) return undefined
  const [le, r] = splitLine(cs, attrs[1])
  if (ide === u5 || !blank(str(cs, attrs[1], le))) return undefined
  return [
    {
      i: 'rxn',
      x: {
        id: str(cs, u5, ide),
        subs: s[0] ?? undefined,
        prods: p[0] ?? undefined,
        rate: rate[0],
        attrs: attrs[0],
      },
    },
    r,
  ]
}

/** `Md.subAt`: a subsystem directive after its `::subsystem[`. */
function subAt(cs: Chars, i: number): Read<RItem> {
  const e = takeWhile(cs, i, (c) => c !== ']' && c !== '\n')
  if (cs[e] !== ']' || cs[e + 1] !== '{') return undefined
  const a = pAttrs(cs, e + 2)
  if (a === undefined) return undefined
  const [le, r1] = splitLine(cs, a[1])
  if (!blank(str(cs, a[1], le))) return undefined
  return [{ i: 'decl', d: { kind: 'sub', name: str(cs, i, e), attrs: a[0] } }, r1]
}

/** `Md.plotAt`: a plot directive after its `::plot{`. */
function plotAt(cs: Chars, i: number): Read<RItem> {
  const a = pAttrs(cs, i)
  if (a === undefined) return undefined
  const [le, r1] = splitLine(cs, a[1])
  return blank(str(cs, a[1], le)) ? [{ i: 'plot', attrs: a[0] }, r1] : undefined
}

// ## Containers of initialization equations and constraints

/** `Md.contBody`: the displays of a container, up to its closing `:::` line; blank lines between them are skipped. */
function contBody(ro: Role, cs: Chars, i: number): Read<RItem[]> {
  const out: RItem[] = []
  for (;;) {
    if (preS(D_END, cs, i)) {
      const [le, r] = splitLine(cs, i + 3)
      return blank(str(cs, i + 3, le)) ? [out, r] : undefined
    }
    if (preS(DD, cs, i)) {
      const m = mathAt(cs, i + 2)
      if (m === undefined || m[0].i !== 'eqn') return undefined
      out.push({ i: 'eqx', role: ro, raw: m[0].raw })
      i = m[1]
    } else if (cs[i] === '\n') i++
    else return undefined
  }
}

/** `Md.contOpen`: a container starts here. */
const contOpen = (cs: Chars, i: number): boolean => preS(D_INIT, cs, i) || preS(D_CONS, cs, i)

/** `Md.contAt`: a container, at its opening line. */
function contAt(cs: Chars, i: number): Read<RItem[]> {
  const [ro, n] = preS(D_INIT, cs, i)
    ? (['init', D_INIT.length] as const)
    : (['cons', D_CONS.length] as const)
  const s = Math.min(i + n, cs.length)
  const [le, r] = splitLine(cs, s)
  return blank(str(cs, s, le)) ? contBody(ro, cs, r) : undefined
}

// ## The lexer

/** `Md.blockOpen`: a block construct starts here. */
function blockOpen(cs: Chars, i: number): boolean {
  const c = cs[i]
  if (c === '`') return preS(FENCE_ESM, cs, i)
  if (c === '$') return preS(DD, cs, i)
  if (c !== ':') return false
  return (
    preS(D_MODEL, cs, i) ||
    preS(D_RS, cs, i) ||
    preS(D_PLOT, cs, i) ||
    preS(D_SUB, cs, i) ||
    preS(D_TMPL, cs, i) ||
    preS(D_RULE_C, cs, i)
  )
}

/** `Md.declOpen`: a declaration starts here. */
const declOpen = (cs: Chars, i: number): boolean =>
  cs[i] === ':' && (preS(':var[', cs, i) || preS(':param[', cs, i) || preS(':species[', cs, i))

/** `Md.blockAt`: read the block construct that starts here. */
function blockAt(cs: Chars, i: number): Read<RItem> {
  const d = (n: number): number => Math.min(i + n, cs.length)
  if (preS(FENCE_ESM, cs, i)) return fenceAt(cs, d(7))
  if (preS(D_RXN, cs, i)) return rxnAt(cs, d(6))
  if (preS(DD, cs, i)) return mathAt(cs, d(2))
  if (preS(D_MODEL, cs, i)) return dirAt('model', cs, d(8))
  if (preS(D_PLOT, cs, i)) return plotAt(cs, d(7))
  if (preS(D_SUB, cs, i)) return subAt(cs, d(12))
  if (preS(D_TMPL, cs, i)) return tmContAt(cs, d(12))
  if (preS(D_RULE_C, cs, i)) return tmContAt(cs, d(8))
  return dirAt('rs', cs, d(18))
}

/** `Md.declAt`: read the declaration that starts here. */
function declAt(cs: Chars, i: number): Read<RItem> {
  const d = (n: number): number => Math.min(i + n, cs.length)
  if (preS(':var[', cs, i)) return declBody('var', cs, d(5))
  if (preS(':param[', cs, i)) return declBody('param', cs, d(7))
  return declBody('species', cs, d(9))
}

// ## The declarations table (an accepted input variant)

const TABLE_OPEN = '| decl | name |'

/** `Md.headerCells`: the line split at `|`, each cell trimmed. */
function headerCells(cs: Chars, i: number): string[] {
  return str(cs, i, findChar('\n', cs, i))
    .split('|')
    .map((c) => c.replace(/^ +| +$/g, ''))
}

/** `Md.rateTable`: a line starting with `|` that has a cell `rate`. */
const rateTable = (cs: Chars, i: number): boolean =>
  cs[i] === '|' && headerCells(cs, i).includes('rate')

/** `Md.pCols`: the attribute columns of the header, up to its newline. */
function pCols(cs: Chars, i: number): Read<string[]> {
  const out: string[] = []
  for (;;) {
    if (cs[i] === '\n') return [out, i + 1]
    if (cs[i] !== ' ') return undefined
    const [id, j] = readIdent(cs, i + 1)
    if (!isIdent(id) || cs[j] !== ' ' || cs[j + 1] !== '|') return undefined
    out.push(id)
    i = j + 2
  }
}

/** `Md.pCell`: ` value |`, or ` |` when the attribute is absent (`null`). */
function pCell(cs: Chars, i: number): Read<Json | null> {
  if (cs[i] !== ' ') return undefined
  if (cs[i + 1] === '|') return [null, i + 2]
  const v = pFlow(cs, i + 1)
  if (v === undefined || cs[v[1]] !== ' ' || cs[v[1] + 1] !== '|') return undefined
  return [v[0], v[1] + 2]
}

/** `Md.pCells`: the cells of a row, one per attribute column. */
function pCells(cols: readonly string[], cs: Chars, i: number): Read<Kv[]> {
  const out: Kv[] = []
  for (const k of cols) {
    const c = pCell(cs, i)
    if (c === undefined) return undefined
    if (c[0] !== null) out.push([k, c[0]])
    i = c[1]
  }
  return [out, i]
}

/** `Md.kindOf`: the directive keyword of a row. */
function kindOf(w: string): DKind | undefined {
  switch (w) {
    case 'var':
      return 'var'
    case 'param':
      return 'param'
    case 'species':
      return 'species'
    case 'subsystem':
      return 'sub'
  }
  return undefined
}

/** `Md.pRow`: `| var | $N$ |` and the cells, then a newline. */
function pRow(cols: readonly string[], cs: Chars, i: number): Read<Decl> {
  if (cs[i] !== '|' || cs[i + 1] !== ' ') return undefined
  const [w, j] = readIdent(cs, i + 2)
  const k = kindOf(w)
  if (k === undefined || !preS(' | $', cs, j)) return undefined
  const e = takeWhile(cs, j + 4, (c) => c !== '$')
  if (!preS('$ |', cs, e)) return undefined
  const n = parseLatex(EMPTY_SYM, str(cs, j + 4, e))
  if (n === undefined || n.t !== 'str') return undefined
  const c = pCells(cols, cs, e + 3)
  if (c === undefined || cs[c[1]] !== '\n') return undefined
  return [{ kind: k, name: n.s, attrs: c[0] }, c[1] + 1]
}

/** `Md.sepOK`: the separator row. */
const sepOk = (l: string): boolean => /^[|\- :]*$/.test(l)

/** `Md.tableAt`: a declarations table, at its `| decl | name |`. */
function tableAt(cs: Chars, i: number): Read<RItem[]> {
  const cols = pCols(cs, Math.min(i + TABLE_OPEN.length, cs.length))
  if (cols === undefined) return undefined
  const [le, r1] = splitLine(cs, cols[1])
  if (!sepOk(str(cs, cols[1], le))) return undefined
  // `Md.pRows`: the rows, as long as lines start with `| `.
  const out: RItem[] = []
  let j = r1
  while (cs[j] === '|' && cs[j + 1] === ' ') {
    const d = pRow(cols[0], cs, j)
    if (d === undefined) return undefined
    out.push({ i: 'decl', d: d[0] })
    j = d[1]
  }
  return [out, j]
}

// ## Code spans

/** `Md.skipCode`: the index after the code span that starts here. */
function skipCode(cs: Chars, i: number): number {
  const e = takeWhile(cs, i, (c) => c === '`')
  const n = e - i
  // `Md.afterRun`: the text after the first occurrence of `n` backticks.
  for (let k = e; k + n <= cs.length; k++) {
    let run = true
    for (let m = 0; m < n; m++) {
      if (cs[k + m] !== '`') {
        run = false
        break
      }
    }
    if (run) return k + n
  }
  return e
}

/**
 * `Md.lex`: the constructs of a text, skipping prose one character at a time and
 * code spans whole. A malformed construct is an error.
 */
export function lex(bol: boolean, cs: Chars, i: number): RItem[] | undefined {
  const out: RItem[] = []
  while (i < cs.length) {
    const c = cs[i]
    if (bol && blockOpen(cs, i)) {
      const r = blockAt(cs, i)
      if (r === undefined) return undefined
      out.push(r[0])
      i = r[1]
      bol = true
    } else if (declOpen(cs, i)) {
      const r = declAt(cs, i)
      if (r === undefined) return undefined
      out.push(r[0])
      i = r[1]
      bol = false
    } else if (bol && preS(TABLE_OPEN, cs, i)) {
      const r = tableAt(cs, i)
      if (r === undefined) return undefined
      out.push(...r[0])
      i = r[1]
      bol = true
    } else if (bol && contOpen(cs, i)) {
      const r = contAt(cs, i)
      if (r === undefined) return undefined
      out.push(...r[0])
      i = r[1]
      bol = true
    } else if (bol && rateTable(cs, i)) {
      return undefined
    } else if (c === '`') {
      i = skipCode(cs, i)
      bol = false
    } else {
      bol = c === '\n'
      i++
    }
  }
  return out
}

// ## What each construct needs to read back

/** `Md.attrOK`. */
export const attrOk = (a: Kv): boolean => isIdent(a[0]) && jwf(a[1])

/** `Md.declOK`. */
const declOk = (d: Decl): boolean =>
  nameOk(d.name) && !nameLatex(d.name).includes('$') && d.attrs.every(attrOk)

/** `Md.mhchemOK`: no escaped brace anywhere inside `\ce{…}`. */
function mhchemOk(x: Rxn<string>): boolean {
  const t = sideTxt(LATEX_R, x.subs) + x.rate + sideTxt(LATEX_R, x.prods)
  return !hasSub('\\{', t) && !hasSub('\\}', t)
}

/** `Md.rxnOK`: a reaction the Markdown syntax can hold. */
export const rxnOk = (x: Rxn<string>): boolean =>
  sideOk(LATEX_R, x.subs) &&
  sideOk(LATEX_R, x.prods) &&
  !x.rate.includes('$') &&
  !x.rate.includes('\n') &&
  idOk(x.id) &&
  x.attrs.every(attrOk) &&
  mhchemOk(x)

/** `Md.subMd`. */
const subMd = (d: Decl): string => `${D_SUB}${d.name}]{${attrsMd(d.attrs)}}\n`

/** `Md.subOK`. */
const subOk = (d: Decl): boolean =>
  !d.name.includes(']') && !d.name.includes('\n') && d.attrs.every(attrOk)

/** A display: `$$`, the math, `$$`. */
const disp = (raw: string): string => `${DD}\n${raw}\n${DD}\n`

/** `Md.itemMd`: the text of a construct. */
export function itemMd(it: RItem): string {
  switch (it.i) {
    case 'desc':
      return `${FENCE_ESM}${DESC_INFO}\n${it.s}\n${FENCE}\n`
    case 'block':
      return `${FENCE_ESM}${keyMd(it.k)}\n${yaml.encode(it.v)}${FENCE}\n`
    case 'comp':
      return `${it.kind === 'model' ? D_MODEL : D_RS}${it.name}]\n`
    case 'decl':
      return it.d.kind === 'sub' ? subMd(it.d) : declMd(it.d)
    case 'eqn':
      return disp(it.raw)
    case 'eqx':
      return `${dRole(it.role)}\n${disp(it.raw)}${D_END}\n`
    case 'rxn':
      return D_RXN + rxnBody(it.x)
    case 'plot':
      return `${D_PLOT}${attrsMd(it.attrs)}}\n`
    case 'tm':
      if (it.t.attrs.length === 0) return disp(tmRaw(it.t))
      return `${it.t.lhs === undefined ? D_TMPL : D_RULE_C}${attrsMd(it.t.attrs)}}\n${disp(tmRaw(it.t))}${D_END}\n`
  }
}

/** `Md.isBlock`: a construct that must start a line (all but declarations). */
export const isBlock = (it: RItem): boolean => it.i !== 'decl' || it.d.kind === 'sub'

/** `Md.itemOK`: what each construct's content must satisfy for its text to read back. */
export function itemOk(it: RItem): boolean {
  switch (it.i) {
    case 'desc':
      return noStop(FENCE, `${it.s}\n`)
    case 'block':
      return jsonWfmb(it.v)
    case 'comp':
      return !it.name.includes(']') && !it.name.includes('\n')
    case 'decl':
      return it.d.kind === 'sub' ? subOk(it.d) : declOk(it.d)
    case 'eqn':
      return noStop(DD, `${it.raw}\n`) && tmLex(it.raw) === undefined
    case 'eqx':
      return it.role !== 'eqn' && noStop(DD, `${it.raw}\n`) && tmLex(it.raw) === undefined
    case 'rxn':
      return rxnOk(it.x)
    case 'plot':
      return it.attrs.every(attrOk)
    case 'tm': {
      const raw = tmRaw(it.t)
      return (
        noStop(DD, `${raw}\n`) &&
        !raw.includes('\n') &&
        tmLexEq(tmLex(raw), [it.t.name, [...it.t.params], it.t.lhs, it.t.body]) &&
        it.t.attrs.every(attrOk)
      )
    }
  }
}
