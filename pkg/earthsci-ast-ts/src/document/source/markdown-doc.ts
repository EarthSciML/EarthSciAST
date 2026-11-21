/**
 * Markdown documents: printing and parsing.
 *
 * Port of `formal/Esm/Document/Source/MarkdownDoc.lean` (after the Rust
 * binding's `document/source/markdown_doc.rs`). The layers compose: the skeleton
 * (`toDoc` / `ofDoc`), the math entries as LaTeX (`rawDoc` / `cookDoc`), the
 * construct sequence (`items` / `unitems`), and the text (front matter, then the
 * constructs separated by blank lines).
 */

import { jobj, type Json } from '../json.js'
import { latexLex, nameOk, parseLatex, printLatex, type Sym } from '../math/index.js'
import { chars, type Chars } from '../number.js'
import { escChar, isIdent } from '../strings.js'
import * as yaml from '../yaml.js'
import { eqExpr, eqSides } from './equation.js'
import {
  ckMx,
  cookDoc,
  cookDocBlocks,
  items,
  mathifyDoc,
  prMx,
  rawDoc,
  unitems,
  type RItem,
} from './items.js'
import type { Kv, Kvs } from './keys.js'
import { attrOk, isBlock, itemMd, itemOk, lex, nameLatex, rxnOk, tmLex } from './markdown.js'
import { cookRows } from './multi-line.js'
import {
  ofDoc,
  toDoc,
  type Caps,
  type Eqn,
  type MC,
  type MR,
  type Rxn,
  type Tm,
} from './skeleton.js'
import { blank, decodeText, noStop, preS, untilStop } from './text.js'

const DASHES = '---'
const FENCE = '```'

// ## Equations in LaTeX

/** `Md.latexOf`: an equation's LaTeX under the symbol table `s`. */
const latexOf = (s: Sym, e: Eqn): string => printLatex(s, eqExpr(e))

/** `Md.prMd`: an equation's math text: its `_comment` as a LaTeX comment line, then the equation. */
function prMd(s: Sym, e: Eqn): string {
  return (e.comment !== undefined ? `% ${e.comment}\n` : '') + latexOf(s, e)
}

/** `Md.envs`: the multi-line environments: `true` when all rows are one equation. */
const ENVS: readonly (readonly [string, boolean])[] = [
  ['aligned', false],
  ['align', false],
  ['align*', false],
  ['gathered', false],
  ['split', true],
  ['multline', true],
  ['multline*', true],
]

/** `Md.envOf`: a display that is one multi-line environment: whether its rows are one equation, and its body. */
function envOf(body: string): [boolean, string] | undefined {
  const b = body.replace(/^[ \n\t]+/, '').replace(/[ \n\t]+$/, '')
  if (!b.startsWith('\\begin{')) return undefined
  for (const [e, one] of ENVS) {
    const o = `\\begin{${e}}`
    const c = `\\end{${e}}`
    if (b.startsWith(o) && b.endsWith(c)) {
      return [one, b.slice(o.length, o.length + Math.max(0, b.length - o.length - c.length))]
    }
  }
  return undefined
}

/** `Md.oneMd`: one display in LaTeX: a multi-line environment, or one equation. */
function oneMd(s: Sym, c: string | undefined, body: string): Eqn[] | undefined {
  const env = envOf(body)
  if (env !== undefined) {
    const ts = latexLex(chars(env[1]))
    const es = ts === undefined ? undefined : cookRows('latex', s, env[0], ts)
    // `Md.withComment`: the comment goes to the first equation of a display.
    return es && es.map((e, i) => (i === 0 ? { ...e, comment: c } : e))
  }
  const p = parseLatex(s, body)
  const sides = p === undefined ? undefined : eqSides(p)
  return sides && [{ comment: c, lhs: sides[0], rhs: sides[1] }]
}

/** `Md.ckMd`: read the math text of a display equation: an optional leading comment line `% …`, then the equation. */
function ckMd(s: Sym, raw: string): Eqn[] | undefined {
  if (raw.startsWith('% ')) {
    const nl = raw.indexOf('\n', 2)
    return nl < 0 ? oneMd(s, raw.slice(2), '') : oneMd(s, raw.slice(2, nl), raw.slice(nl + 1))
  }
  return oneMd(s, undefined, raw)
}

/** `Md.prMdx`: a math entry's text. */
const prMdx = (s: Sym, m: MC): MR => prMx(prMd, printLatex, s, m)

/** `Md.ckMdx`: read a math entry's text. */
const ckMdx = (s: Sym, m: MR): MC[] | undefined => ckMx(ckMd, parseLatex, s, m)

/** `Md.commentOK`. */
const commentOk = (c: string | undefined): boolean =>
  c === undefined || (!c.includes('\n') && !c.includes('$'))

// ## What Markdown spells natively

/** `Md.dqOK`: a string whose characters the YAML printer writes as themselves and without `&`; any other value. */
function dqOk(v: Json): boolean {
  if (v.t !== 'str') return true
  for (const c of v.s) if (c === '&' || escChar(false, c) !== c) return false
  return true
}

/** `Md.capsMd`: the Markdown container's predicates. */
const CAPS_MD: Caps = {
  frontKey: () => true,
  desc: (s) => {
    const t = `${s}\n`
    return ['', ' ', '  ', '   '].every((ind) => noStop(ind + FENCE, t)) && !s.includes('\r')
  },
  compName: (n) => !n.includes(']') && !n.includes('\n'),
  declName: (n) =>
    nameOk(n) && !nameLatex(n).includes('$') && !n.includes(']') && !n.includes('\n'),
  attr: (a: Kv) => isIdent(a[0]) && dqOk(a[1]),
  eqn: (s, e) => {
    const l = latexOf(s, e)
    return (
      commentOk(e.comment) &&
      !l.includes('$') &&
      !l.includes('\n') &&
      !l.startsWith('%') &&
      envOf(l) === undefined &&
      tmLex(prMd(s, e)) === undefined
    )
  },
  rxn: (s, x: Rxn<Json>) => rxnOk({ ...x, rate: printLatex(s, x.rate) }),
  plot: (a) => a.every(attrOk) && a.every((kv) => dqOk(kv[1])),
  tm: (s, t: Tm<Json>) =>
    itemOk({
      i: 'tm',
      t: {
        ...t,
        lhs: t.lhs === undefined ? undefined : printLatex({ names: s.names, templates: [] }, t.lhs),
        body: printLatex(s, t.body),
      },
    }) && t.attrs.every((kv) => dqOk(kv[1])),
}

/** `Md.frontMd`: the front matter. */
const frontMd = (front: Kvs): string => `${DASHES}\n${yaml.encode(jobj(front))}${DASHES}\n`

/** `Md.printMd`: print a document as Markdown. */
export function printMd(d: Json): string {
  const doc = toDoc(CAPS_MD, d)
  // `Md.canonSegs` and `Md.render`: each construct after a blank line, a
  // declaration on a line of its own.
  const out: string[] = [frontMd(doc.front)]
  for (const it of items(mathifyDoc(printLatex, rawDoc(prMdx, doc)))) {
    out.push('\n', itemMd(it))
    if (!isBlock(it)) out.push('\n')
  }
  return out.join('')
}

/** `Md.lexDoc`: read the front matter and the constructs. */
function lexDoc(cs: Chars): [Kvs, RItem[]] | undefined {
  if (!preS('---\n', cs, 0)) return undefined
  const u = untilStop(DASHES, cs, 4)
  if (u === undefined || !blank(u[1])) return undefined
  const fm = yaml.decode(chars(u[0]))
  if (fm === undefined || fm.t !== 'obj') return undefined
  const its = lex(true, cs, u[2])
  return its && [fm.kvs, its]
}

/** `Md.parseItemsMd`. */
function parseItemsMd(front: Kvs, its: readonly RItem[]): Json | undefined {
  const r = unitems(front, its)
  const rb = r === undefined ? undefined : cookDocBlocks(parseLatex, r)
  const d = rb === undefined ? undefined : cookDoc(ckMdx, rb)
  return d === undefined ? undefined : ofDoc(d)
}

/** `Md.parseMd`: read a Markdown document, after `decodeText`. */
export function parseMd(s: string): Json | undefined {
  const r = lexDoc(chars(decodeText(s)))
  return r && parseItemsMd(r[0], r[1])
}
