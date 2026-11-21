/**
 * Typst documents: printing and parsing.
 *
 * Port of `formal/Esm/Document/Source/TypstDoc.lean` (after the Rust binding's
 * `document/source/typst_doc.rs`), composed exactly as the Markdown documents
 * (`markdown-doc.ts`).
 */

import type { Json } from '../json.js'
import { nameOk, parseTypst, printTypst, typstLex, type Sym } from '../math/index.js'
import { chars, type Chars } from '../number.js'
import { bareKey } from '../strings.js'
import * as typstDict from '../typst-dict.js'
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
import type { Kvs } from './keys.js'
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
import { decodeText, preS } from './text.js'
import {
  HEADER,
  argOk,
  argsFirstT,
  isBlock,
  itemOk,
  itemT,
  lex,
  lineEnd,
  nameTyp,
  pArgsFirst,
  rxnOk,
  tmLexT,
} from './typst.js'

/** `Typ.typOf`: an equation's Typst math under the symbol table `s`. */
const typOf = (s: Sym, e: Eqn): string => printTypst(s, eqExpr(e))

/** `Typ.prT`: its `_comment` as a `//` comment line, then the equation. */
const prT = (s: Sym, e: Eqn): string =>
  (e.comment !== undefined ? `// ${e.comment}\n` : '') + typOf(s, e)

/** `Typ.oneT`: one equation, or several rows separated by `\` with `&` alignment. */
function oneT(s: Sym, c: string | undefined, body: string): Eqn[] | undefined {
  const p = parseTypst(s, body)
  const sides = p === undefined ? undefined : eqSides(p)
  if (sides !== undefined) return [{ comment: c, lhs: sides[0], rhs: sides[1] }]
  const ts = typstLex(chars(body))
  const es = ts === undefined ? undefined : cookRows('typst', s, false, ts)
  // `Md.withComment`: the comment goes to the first equation of a display.
  return es && es.map((e, i) => (i === 0 ? { ...e, comment: c } : e))
}

/** `Typ.ckT`: read the math text of a display equation. */
function ckT(s: Sym, raw: string): Eqn[] | undefined {
  if (raw.startsWith('// ')) {
    const nl = raw.indexOf('\n', 3)
    return nl < 0 ? oneT(s, raw.slice(3), '') : oneT(s, raw.slice(3, nl), raw.slice(nl + 1))
  }
  return oneT(s, undefined, raw)
}

/** `Typ.prTx`. */
const prTx = (s: Sym, m: MC): MR => prMx(prT, printTypst, s, m)

/** `Typ.ckTx`. */
const ckTx = (s: Sym, m: MR): MC[] | undefined => ckMx(ckT, parseTypst, s, m)

/** `Md.commentOK`. */
const commentOk = (c: string | undefined): boolean =>
  c === undefined || (!c.includes('\n') && !c.includes('$'))

/** `Typ.capsT`: the Typst container's predicates. */
const CAPS_T: Caps = {
  frontKey: (k) => bareKey(typstDict.reserved, k),
  desc: () => true,
  compName: () => true,
  declName: (n) => nameOk(n) && !nameTyp(n).includes('$'),
  attr: (a) => bareKey(typstDict.reserved, a[0]),
  eqn: (s, e) => {
    const t = typOf(s, e)
    return (
      commentOk(e.comment) &&
      !t.includes('$') &&
      !t.startsWith('//') &&
      tmLexT(prT(s, e)) === undefined
    )
  },
  rxn: (s, x: Rxn<Json>) => rxnOk({ ...x, rate: printTypst(s, x.rate) }),
  plot: (a) => a.every(argOk),
  tm: (s, t: Tm<Json>) =>
    itemOk({
      i: 'tm',
      t: {
        ...t,
        lhs: t.lhs === undefined ? undefined : printTypst({ names: s.names, templates: [] }, t.lhs),
        body: printTypst(s, t.body),
      },
    }),
}

/** `Typ.printTyp`: print a document as Typst. */
export function printTyp(d: Json): string {
  const doc = toDoc(CAPS_T, d)
  // `Typ.headerT`, `Typ.canonSegs` and `Typ.render`: each construct after a blank line.
  const out: string[] = [`${HEADER}${argsFirstT(doc.front)})\n`]
  for (const it of items(mathifyDoc(printTypst, () => true, rawDoc(prTx, doc)))) {
    out.push('\n', itemT(it))
    if (!isBlock(it)) out.push('\n')
  }
  return out.join('')
}

/** `Typ.lexDoc`: read the header and the constructs. */
function lexDoc(cs: Chars): [Kvs, RItem[]] | undefined {
  if (!preS(HEADER, cs, 0)) return undefined
  const f = pArgsFirst(cs, HEADER.length)
  if (f === undefined) return undefined
  const r1 = lineEnd(cs, f[1])
  if (r1 === undefined) return undefined
  const its = lex(true, cs, r1)
  return its && [f[0], its]
}

/** `Typ.parseItemsT`. */
function parseItemsT(front: Kvs, its: readonly RItem[]): Json | undefined {
  const r = unitems(front, its)
  const rb = r === undefined ? undefined : cookDocBlocks(parseTypst, r)
  const d = rb === undefined ? undefined : cookDoc(ckTx, rb)
  return d === undefined ? undefined : ofDoc(d)
}

/** `Typ.parseTyp`: read a Typst document, after `decodeText`. */
export function parseTyp(s: string): Json | undefined {
  const r = lexDoc(chars(decodeText(s)))
  return r && parseItemsT(r[0], r[1])
}
