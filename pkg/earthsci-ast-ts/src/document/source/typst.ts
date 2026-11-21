/**
 * The Typst container: markup plus the functions of the `esm` Typst package.
 *
 * Port of `formal/Esm/Document/Source/Typst.lean` (namespace `Source.Typ`),
 * after the Rust binding's `document/source/typst.rs`. The lexer reads a
 * construct where one starts at the beginning of a line (a declaration anywhere)
 * and otherwise drops one character of prose.
 */

import { jsonWfmb, jstr } from '../json.js'
import { jwf, nameOk, parseTypst, printTypst, type Sym } from '../math/index.js'
import { chars, type Chars, type Read } from '../number.js'
import { bareKey, isIdent, parseQuoted, quote, readIdent } from '../strings.js'
import * as typstDict from '../typst-dict.js'
import type { RItem } from './items.js'
import type { Kv } from './keys.js'
import { idChar, idOk, pPiece, pSide, sideOk, sideTxt, type RSurf } from './reaction.js'
import type { DKind, Decl, Kind, Role, Rxn, Term, Tm } from './skeleton.js'
import { afterS, blank, hasSub, preS, splitLine, str, takeWhile } from './text.js'

// ## Spellings

const O_DESC = '#description['
const O_BLOCK = '#esm-block('
const O_MODEL = '#model('
const O_RS = '#reaction-system('
const O_EQ = '$ '
const O_VAR = '#var('
const O_PARAM = '#param('
const O_SPECIES = '#species('
const O_CE = '#ce['
const O_RXN = '#reaction('
const O_INIT = '#initialization['
const O_CONS = '#constraints['
const O_PLOT = '#plot('
const O_SUB = '#subsystem('
const O_TMPL = '#template('
const O_RULE = '#rule('

/** `Typ.oRole`. */
const oRole = (r: Role): string => (r === 'init' ? O_INIT : r === 'cons' ? O_CONS : O_EQ)

/** `Typ.header`: the header's first line and the start of its second. */
export const HEADER = '#import "@preview/esm:0.1.0": *\n#show: esm-document.with('

/** The empty symbol table. */
const EMPTY_SYM: Sym = { names: [], templates: [] }

// ## Description text

const ALWAYS_ESC = new Set(['\\', '[', ']', '#', '$', '*', '_', '`', '<', '>', '@', '~'])

/** `Typ.mustEsc`: whether a character of a description is written escaped. */
function mustEsc(bol: boolean, c: string, next: string | undefined): boolean {
  return (
    ALWAYS_ESC.has(c) ||
    (bol && (c === '=' || c === '-' || c === '+')) ||
    (c === '/' && (next === '/' || next === '*'))
  )
}

/** `Typ.escT`: a description's text in a content block. */
function escDesc(bol: boolean, s: string): string {
  const cs = chars(s)
  let out = ''
  let b = bol
  for (let i = 0; i < cs.length; i++) {
    const c = cs[i]
    if (mustEsc(b, c, cs[i + 1])) out += '\\'
    out += c
    b = c === '\n'
  }
  return out
}

/** `Typ.readEsc`: the text of a content block up to its unescaped `]`. */
function readEsc(cs: Chars, i: number): Read<string> {
  let out = ''
  for (;;) {
    const c = cs[i]
    if (c === undefined) return undefined
    if (c === ']') return [out, i + 1]
    if (c === '\\' && i + 1 < cs.length) {
      out += cs[i + 1]
      i += 2
      continue
    }
    if (c === '[') return undefined
    out += c
    i++
  }
}

/** `Typ.argT`: `key: value`. */
const argT = (a: Kv): string => `${a[0]}: ${typstDict.encode(a[1])}`

/** `Typ.pArg`: one named argument at its key. */
function pArg(cs: Chars, i: number): Read<Kv> {
  const [k, j] = readIdent(cs, i)
  if (!isIdent(k) || typstDict.reserved(k) || cs[j] !== ':' || cs[j + 1] !== ' ') return undefined
  const v = typstDict.pVal(cs, j + 2)
  return v && [[k, v[0]], v[1]]
}

/** `Typ.pArgsMore`: `, key: value` repeated, up to `)`. */
function pArgsMore(cs: Chars, i: number): Read<Kv[]> {
  const out: Kv[] = []
  for (;;) {
    if (cs[i] === ')') return [out, i + 1]
    if (cs[i] !== ',' || cs[i + 1] !== ' ') return undefined
    const a = pArg(cs, i + 2)
    if (a === undefined) return undefined
    out.push(a[0])
    i = a[1]
  }
}

/** `Typ.pArgsFirst`: arguments directly after `(`. */
export function pArgsFirst(cs: Chars, i: number): Read<Kv[]> {
  if (cs[i] === ')') return [[], i + 1]
  const a = pArg(cs, i)
  if (a === undefined) return undefined
  const r = pArgsMore(cs, a[1])
  return r && [[a[0], ...r[0]], r[1]]
}

/** `Typ.argsMoreT`: each `, key: value`. */
const argsMoreT = (as: readonly Kv[]): string => as.map((a) => `, ${argT(a)}`).join('')

/** `Typ.argsFirstT`: arguments directly after `(`. */
export const argsFirstT = (as: readonly Kv[]): string => as.map(argT).join(', ')

/** `Typ.argOK`: an identifier key that is not a keyword, and a well-formed value. */
export const argOk = (a: Kv): boolean => bareKey(typstDict.reserved, a[0]) && jwf(a[1])

// ## Constructs

/** `Typ.nameTyp`: a name as Typst math under the empty symbol table. */
export const nameTyp = (n: string): string => printTypst(EMPTY_SYM, jstr(n))

/** `Typ.dkw`. */
const dkw = (k: DKind): string =>
  k === 'var' ? O_VAR : k === 'param' ? O_PARAM : k === 'species' ? O_SPECIES : O_SUB

/** `Typ.declT`: `#var($N$, default: 100)`. */
const declT = (d: Decl): string => `${dkw(d.kind)}$${nameTyp(d.name)}$${argsMoreT(d.attrs)})`

/** `Typ.lineEnd`: the rest of a construct's line must be blank. */
export function lineEnd(cs: Chars, i: number): number | undefined {
  const [e, r] = splitLine(cs, i)
  return blank(str(cs, i, e)) ? r : undefined
}

// ## Reactions

/** `Typ.typR`: Typst math under the empty symbol table. */
const TYP_R: RSurf = {
  pm: (s) => parseTypst(EMPTY_SYM, s),
  prm: (j) => printTypst(EMPTY_SYM, j),
  empty: 'emptyset',
}

const ARROW_L = ' ->[$'
const ARROW_R = '] '

/** `Typ.coreT`: the sides and the rate over the arrow. */
const coreT = (x: Rxn<string>): string =>
  `${sideTxt(TYP_R, x.subs)}${ARROW_L}${x.rate}$${ARROW_R}${sideTxt(TYP_R, x.prods)}`

/** `Typ.rxnT`: `#ce[…] <id>`, or `#reaction(…)[#ce[…]] <id>`. */
function rxnT(x: Rxn<string>): string {
  const head =
    x.attrs.length === 0
      ? `${O_CE}${coreT(x)}] <`
      : `${O_RXN}${argsFirstT(x.attrs)})[#ce[${coreT(x)}]] <`
  return `${head}${x.id}>\n`
}

/** The pieces `coreAt` reads: subs, rate, prods, and the index after. */
type Core = [readonly Term[] | undefined, string, readonly Term[] | undefined, number]

/** `Typ.coreAt`. */
function coreAt(cs: Chars, i: number): Core | undefined {
  const s = pSide(TYP_R, cs, i)
  if (s === undefined) return undefined
  const u2 = afterS(ARROW_L, cs, s[1])
  if (u2 === undefined) return undefined
  const rate = pPiece(cs, u2)
  if (rate === undefined) return undefined
  const u3 = afterS(ARROW_R, cs, rate[1])
  if (u3 === undefined) return undefined
  const p = pSide(TYP_R, cs, u3)
  if (p === undefined) return undefined
  return [s[0] ?? undefined, rate[0], p[0] ?? undefined, p[1]]
}

/** `Typ.labelAt`: the label `<id>` and the end of the line. */
function labelAt(cs: Chars, i: number): Read<string> {
  if (cs[i] !== '<') return undefined
  const e = takeWhile(cs, i + 1, idChar)
  if (cs[e] !== '>' || e === i + 1) return undefined
  const r = lineEnd(cs, e + 1)
  return r === undefined ? undefined : [str(cs, i + 1, e), r]
}

/** `Typ.ceAt`: a reaction after `#ce[`. */
function ceAt(cs: Chars, i: number): Read<RItem> {
  const c = coreAt(cs, i)
  if (c === undefined) return undefined
  const u5 = afterS('] ', cs, c[3])
  if (u5 === undefined) return undefined
  const l = labelAt(cs, u5)
  return l && [{ i: 'rxn', x: { id: l[0], subs: c[0], prods: c[2], rate: c[1], attrs: [] } }, l[1]]
}

/** `Typ.rxnAtT`: a reaction after `#reaction(`. */
function rxnAtT(cs: Chars, i: number): Read<RItem> {
  const as = pArgsFirst(cs, i)
  if (as === undefined) return undefined
  const u2 = afterS('[#ce[', cs, as[1])
  if (u2 === undefined) return undefined
  const c = coreAt(cs, u2)
  if (c === undefined) return undefined
  const u5 = afterS(']] ', cs, c[3])
  if (u5 === undefined) return undefined
  const l = labelAt(cs, u5)
  return (
    l && [{ i: 'rxn', x: { id: l[0], subs: c[0], prods: c[2], rate: c[1], attrs: as[0] } }, l[1]]
  )
}

// ## Templates and rules

const TM_OP = 'op('
const TM_PAR = ')('
const TM_DEF_T = ') := '
const SEP_D = ', $'

/** `Typ.tmRawT`: the math text of a template display (one line). */
const tmRawT = (t: Tm<string>): string =>
  `${TM_OP}${quote(true, t.name)}${TM_PAR}${t.params.map(nameTyp).join(', ')}${TM_DEF_T}${t.body}`

/**
 * `Typ.nameLenT`: the length of a parameter name's Typst math: up to the first
 * `,` or `)` outside parentheses and string literals.
 */
function nameLenT(cs: Chars, start: number): number {
  let d = 0
  let q = false
  let n = 0
  let i = start
  while (i < cs.length) {
    const c = cs[i]
    if (q) {
      if (c === '\\') {
        if (i + 1 < cs.length) {
          n += 2
          i += 2
        } else return n + 1
      } else {
        n += 1
        q = c !== '"'
        i += 1
      }
    } else if (c === '"') {
      n += 1
      q = true
      i += 1
    } else if (c === '(') {
      n += 1
      d += 1
      i += 1
    } else if (c === ')') {
      if (d === 0) return n
      n += 1
      d -= 1
      i += 1
    } else if (c === ',' && d === 0) return n
    else {
      n += 1
      i += 1
    }
  }
  return n
}

/** `Typ.pNameT`: a parameter name in a template header. */
function pNameT(cs: Chars, i: number): Read<string> {
  const k = Math.min(nameLenT(cs, i), cs.length - i)
  const n = parseTypst(EMPTY_SYM, str(cs, i, i + k))
  return n !== undefined && n.t === 'str' ? [n.s, i + k] : undefined
}

/** `Typ.pParamsT`: the parameters up to `) := `. */
function pParamsT(cs: Chars, i: number): Read<string[]> {
  const out: string[] = []
  for (;;) {
    const a = afterS(TM_DEF_T, cs, i)
    if (a !== undefined) return [out, a]
    const n = pNameT(cs, i)
    if (n === undefined) return undefined
    out.push(n[0])
    const b = afterS(TM_DEF_T, cs, n[1])
    if (b !== undefined) return [out, b]
    if (cs[n[1]] !== ',' || cs[n[1] + 1] !== ' ') return undefined
    i = n[1] + 2
  }
}

/** `Typ.tmLexT`: read the math text of a display as a template: its name, parameters and body text. */
export function tmLexT(raw: string): [string, string[], string] | undefined {
  if (!raw.startsWith(TM_OP)) return undefined
  const cs = chars(raw)
  const n = parseQuoted(true, cs, TM_OP.length)
  if (n === undefined) return undefined
  const u2 = afterS(TM_PAR, cs, n[1])
  if (u2 === undefined) return undefined
  const ps = pParamsT(cs, u2)
  return ps && [n[0], ps[0], str(cs, ps[1])]
}

/** `Typ.itemT`: the text of a construct. */
export function itemT(it: RItem): string {
  switch (it.i) {
    case 'desc':
      return `${O_DESC}${escDesc(true, it.s)}]\n`
    case 'block':
      return `${O_BLOCK}${quote(true, it.k)}, ${typstDict.encode(it.v)})\n`
    case 'comp':
      return `${it.kind === 'model' ? O_MODEL : O_RS}${quote(true, it.name)})\n`
    case 'decl':
      return it.d.kind === 'sub'
        ? `${O_SUB}${quote(true, it.d.name)}${argsMoreT(it.d.attrs)})\n`
        : declT(it.d)
    case 'eqn':
      return `${O_EQ}${it.raw} $\n`
    case 'eqx':
      return `${oRole(it.role)}${O_EQ}${it.raw} $]\n`
    case 'rxn':
      return rxnT(it.x)
    case 'plot':
      return `${O_PLOT}${argsFirstT(it.attrs)})\n`
    case 'tm': {
      const t = it.t
      if (t.lhs !== undefined) {
        return `${O_RULE}${quote(true, t.name)}${SEP_D}${t.lhs}$${SEP_D}${t.body}$${argsMoreT(t.attrs)})\n`
      }
      if (t.attrs.length === 0) return `${O_EQ}${tmRawT(t)} $\n`
      return `${O_TMPL}${argsFirstT(t.attrs)})[${O_EQ}${tmRawT(t)} $]\n`
    }
  }
}

/** `Typ.labelOK`: nothing, or `<id>`, with spaces around. */
function labelOk(sl: string): boolean {
  const t = sl.replace(/^ */, '')
  if (t.length === 0) return true
  if (!t.startsWith('<') || !t.endsWith('>') || t.length < 2) return false
  const inner = t.slice(1, -1)
  return !inner.includes('>') && !inner.includes('<')
}

// ## The lexer

const BLOCK_OPENS = [
  O_DESC,
  O_BLOCK,
  O_MODEL,
  O_RS,
  O_EQ,
  O_CE,
  O_RXN,
  O_INIT,
  O_CONS,
  O_PLOT,
  O_SUB,
  O_TMPL,
  O_RULE,
]

/** `Typ.blockOpen`. */
function blockOpen(cs: Chars, i: number): boolean {
  const c = cs[i]
  if (c !== '#' && c !== '$') return false
  return BLOCK_OPENS.some((o) => preS(o, cs, i))
}

/** `Typ.declOpen`. */
const declOpen = (cs: Chars, i: number): boolean =>
  cs[i] === '#' && (preS(O_VAR, cs, i) || preS(O_PARAM, cs, i) || preS(O_SPECIES, cs, i))

/** `Typ.descAt`. */
function descAt(cs: Chars, i: number): Read<RItem> {
  const t = readEsc(cs, i)
  if (t === undefined) return undefined
  const r = lineEnd(cs, t[1])
  return r === undefined ? undefined : [{ i: 'desc', s: t[0] }, r]
}

/** `Typ.blockAtT`: a path block after `#esm-block(`. */
function blockAtT(cs: Chars, i: number): Read<RItem> {
  const k = parseQuoted(true, cs, i)
  if (k === undefined || cs[k[1]] !== ',' || cs[k[1] + 1] !== ' ') return undefined
  const v = typstDict.pVal(cs, k[1] + 2)
  if (v === undefined || cs[v[1]] !== ')') return undefined
  const r = lineEnd(cs, v[1] + 1)
  return r === undefined ? undefined : [{ i: 'block', k: k[0], v: v[0] }, r]
}

/** `Typ.compAt`. */
function compAt(k: Kind, cs: Chars, i: number): Read<RItem> {
  const n = parseQuoted(true, cs, i)
  if (n === undefined || cs[n[1]] !== ')') return undefined
  const r = lineEnd(cs, n[1] + 1)
  return r === undefined ? undefined : [{ i: 'comp', kind: k, name: n[0] }, r]
}

/** `Typ.dispItem`: a template when the display reads as one, else an equation. */
function dispItem(raw: string): RItem {
  const t = tmLexT(raw)
  return t === undefined
    ? { i: 'eqn', raw }
    : { i: 'tm', t: { name: t[0], params: t[1], lhs: undefined, body: t[2], attrs: [] } }
}

/** `Typ.eqAt`: a display after its `$ `. */
function eqAt(cs: Chars, i: number): Read<RItem> {
  const e = takeWhile(cs, i, (c) => c !== '$')
  if (cs[e] !== '$') return undefined
  const [le, rest] = splitLine(cs, e + 1)
  if (e === i || cs[e - 1] !== ' ' || !labelOk(str(cs, e + 1, le))) return undefined
  return [dispItem(str(cs, i, e - 1)), rest]
}

/** `Typ.tmplAtT`: a template with other fields, after `#template(`. */
function tmplAtT(cs: Chars, i: number): Read<RItem> {
  const as = pArgsFirst(cs, i)
  if (as === undefined) return undefined
  const u2 = afterS('[$ ', cs, as[1])
  if (u2 === undefined) return undefined
  const p = pPiece(cs, u2)
  if (p === undefined || !p[0].endsWith(' ') || cs[p[1]] !== ']') return undefined
  const t = tmLexT(p[0].slice(0, -1))
  if (t === undefined) return undefined
  const r = lineEnd(cs, p[1] + 1)
  return r === undefined
    ? undefined
    : [{ i: 'tm', t: { name: t[0], params: t[1], lhs: undefined, body: t[2], attrs: as[0] } }, r]
}

/** `Typ.ruleAtT`: a rule, after `#rule(`. */
function ruleAtT(cs: Chars, i: number): Read<RItem> {
  const n = parseQuoted(true, cs, i)
  if (n === undefined) return undefined
  const r1 = afterS(SEP_D, cs, n[1])
  if (r1 === undefined) return undefined
  const l = pPiece(cs, r1)
  if (l === undefined) return undefined
  const r3 = afterS(SEP_D, cs, l[1])
  if (r3 === undefined) return undefined
  const b = pPiece(cs, r3)
  if (b === undefined) return undefined
  const as = pArgsMore(cs, b[1])
  if (as === undefined) return undefined
  const r = lineEnd(cs, as[1])
  return r === undefined
    ? undefined
    : [{ i: 'tm', t: { name: n[0], params: [], lhs: l[0], body: b[0], attrs: as[0] } }, r]
}

/** `Typ.eqxAt`: an equation in a container after its opener: `$ … $]`. */
function eqxAt(ro: Role, cs: Chars, i: number): Read<RItem> {
  const v = afterS(O_EQ, cs, i)
  if (v === undefined) return undefined
  const p = pPiece(cs, v)
  if (p === undefined || !p[0].endsWith(' ') || cs[p[1]] !== ']') return undefined
  const r = lineEnd(cs, p[1] + 1)
  return r === undefined ? undefined : [{ i: 'eqx', role: ro, raw: p[0].slice(0, -1) }, r]
}

/** `Typ.subAtT`: a subsystem directive after `#subsystem(`. */
function subAtT(cs: Chars, i: number): Read<RItem> {
  const n = parseQuoted(true, cs, i)
  if (n === undefined) return undefined
  const a = pArgsMore(cs, n[1])
  if (a === undefined) return undefined
  const r = lineEnd(cs, a[1])
  return r === undefined
    ? undefined
    : [{ i: 'decl', d: { kind: 'sub', name: n[0], attrs: a[0] } }, r]
}

/** `Typ.plotAtT`: a plot directive after `#plot(`. */
function plotAtT(cs: Chars, i: number): Read<RItem> {
  const a = pArgsFirst(cs, i)
  if (a === undefined) return undefined
  const r = lineEnd(cs, a[1])
  return r === undefined ? undefined : [{ i: 'plot', attrs: a[0] }, r]
}

/** `Typ.blockAt`: read the block construct that starts here. */
function blockAt(cs: Chars, i: number): Read<RItem> {
  const at = (o: string): boolean => preS(o, cs, i)
  if (at(O_DESC)) return descAt(cs, i + O_DESC.length)
  if (at(O_BLOCK)) return blockAtT(cs, i + O_BLOCK.length)
  if (at(O_MODEL)) return compAt('model', cs, i + O_MODEL.length)
  if (at(O_RS)) return compAt('rs', cs, i + O_RS.length)
  if (at(O_CE)) return ceAt(cs, i + O_CE.length)
  if (at(O_RXN)) return rxnAtT(cs, i + O_RXN.length)
  if (at(O_INIT)) return eqxAt('init', cs, i + O_INIT.length)
  if (at(O_CONS)) return eqxAt('cons', cs, i + O_CONS.length)
  if (at(O_PLOT)) return plotAtT(cs, i + O_PLOT.length)
  if (at(O_SUB)) return subAtT(cs, i + O_SUB.length)
  if (at(O_TMPL)) return tmplAtT(cs, i + O_TMPL.length)
  if (at(O_RULE)) return ruleAtT(cs, i + O_RULE.length)
  return eqAt(cs, Math.min(i + O_EQ.length, cs.length))
}

/** `Typ.declBody`: a declaration after its opener. */
function declBody(k: DKind, cs: Chars, i: number): Read<RItem> {
  if (cs[i] !== '$') return undefined
  const e = takeWhile(cs, i + 1, (c) => c !== '$')
  if (cs[e] !== '$') return undefined
  const n = parseTypst(EMPTY_SYM, str(cs, i + 1, e))
  if (n === undefined || n.t !== 'str') return undefined
  const a = pArgsMore(cs, e + 1)
  return a && [{ i: 'decl', d: { kind: k, name: n.s, attrs: a[0] } }, a[1]]
}

/** `Typ.declAt`. */
function declAt(cs: Chars, i: number): Read<RItem> {
  if (preS(O_VAR, cs, i)) return declBody('var', cs, i + O_VAR.length)
  if (preS(O_PARAM, cs, i)) return declBody('param', cs, i + O_PARAM.length)
  return declBody('species', cs, Math.min(i + O_SPECIES.length, cs.length))
}

/** `Typ.lex`: the constructs of a text, skipping prose one character at a time. */
export function lex(bol: boolean, cs: Chars, i: number): RItem[] | undefined {
  const out: RItem[] = []
  while (i < cs.length) {
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
    } else {
      bol = cs[i] === '\n'
      i++
    }
  }
  return out
}

// ## What each construct needs to read back

/** `Typ.typsiumOK`: no `//` or `/*` in the chemistry. */
function typsiumOk(x: Rxn<string>): boolean {
  const t = sideTxt(TYP_R, x.subs) + x.rate + sideTxt(TYP_R, x.prods)
  return !hasSub('//', t) && !hasSub('/*', t)
}

/** `Typ.rxnOK`: a reaction the Typst syntax can hold. */
export const rxnOk = (x: Rxn<string>): boolean =>
  sideOk(TYP_R, x.subs) &&
  sideOk(TYP_R, x.prods) &&
  !x.rate.includes('$') &&
  !x.rate.includes('\n') &&
  idOk(x.id) &&
  x.attrs.every(argOk) &&
  typsiumOk(x)

/** `Typ.declOK`. */
const declOk = (d: Decl): boolean =>
  nameOk(d.name) && !nameTyp(d.name).includes('$') && d.attrs.every(argOk)

/** `Typ.isBlock`. */
export const isBlock = (it: RItem): boolean => it.i !== 'decl' || it.d.kind === 'sub'

/** `Typ.itemOK`: what each construct's content must satisfy for its text to read back. */
export function itemOk(it: RItem): boolean {
  switch (it.i) {
    case 'desc':
    case 'comp':
      return true
    case 'block':
      return jsonWfmb(it.v)
    case 'decl':
      return it.d.kind === 'sub' ? it.d.attrs.every(argOk) : declOk(it.d)
    case 'eqn':
      return !it.raw.includes('$') && tmLexT(it.raw) === undefined
    case 'eqx':
      return it.role !== 'eqn' && !it.raw.includes('$')
    case 'rxn':
      return rxnOk(it.x)
    case 'plot':
      return it.attrs.every(argOk)
    case 'tm': {
      const t = it.t
      if (!t.attrs.every(argOk)) return false
      if (t.lhs !== undefined)
        return !t.lhs.includes('$') && !t.body.includes('$') && t.params.length === 0
      const raw = tmRawT(t)
      const l = tmLexT(raw)
      return (
        !raw.includes('$') &&
        l !== undefined &&
        l[0] === t.name &&
        l[1].length === t.params.length &&
        l[1].every((p, k) => p === t.params[k]) &&
        l[2] === t.body
      )
    }
  }
}
