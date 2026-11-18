/**
 * The skeleton as a sequence of constructs.
 *
 * Port of `formal/Esm/Document/Source/Items.lean` (after the Rust binding's
 * `document/source/items.rs`). {@link items} lists the constructs of a skeleton
 * in the printer's order; {@link unitems} reads a construct sequence back. Math
 * entries are held as the container's math text at this layer; {@link rawDoc}
 * prints them under each component's symbol table and {@link cookDoc} reads
 * them back.
 */

import type { Json } from '../json.js'
import type { Sym } from '../math/index.js'
import type { Kv, Kvs } from './keys.js'
import {
  isMathField,
  mapMath,
  symFor,
  tmMscope,
  tmScope,
  topSym,
  type Comp,
  type Decl,
  type Doc,
  type Eqn,
  type Kind,
  type MC,
  type MR,
  type Role,
  type Rxn,
  type Tm,
} from './skeleton.js'

/**
 * `Source.RItem`: one construct of a document. An equation is its math text,
 * uninterpreted; so is a reaction's rate.
 */
export type RItem =
  | { readonly i: 'desc'; readonly s: string }
  | { readonly i: 'block'; readonly k: string; readonly v: Json }
  | { readonly i: 'comp'; readonly kind: Kind; readonly name: string }
  | { readonly i: 'decl'; readonly d: Decl }
  | { readonly i: 'eqn'; readonly raw: string }
  | { readonly i: 'eqx'; readonly role: Role; readonly raw: string }
  | { readonly i: 'rxn'; readonly x: Rxn<string> }
  | { readonly i: 'plot'; readonly attrs: Kvs }
  | { readonly i: 'tm'; readonly t: Tm<string> }

/** `Source.mItem`: the construct of a math entry. */
export function mItem(m: MR): RItem {
  switch (m.m) {
    case 'eq':
      return m.role === 'eqn' ? { i: 'eqn', raw: m.a } : { i: 'eqx', role: m.role, raw: m.a }
    case 'rxn':
      return { i: 'rxn', x: m.x }
    case 'plot':
      return { i: 'plot', attrs: m.attrs }
    case 'tm':
      return { i: 'tm', t: m.t }
  }
}

const block = ([k, v]: Kv): RItem => ({ i: 'block', k, v })

/** `Source.compItems`: the constructs of a component section. */
function compItems(c: Comp<MR>, out: RItem[]): void {
  out.push({ i: 'comp', kind: c.kind, name: c.name })
  if (c.desc !== undefined) out.push({ i: 'desc', s: c.desc })
  for (const d of c.decls) out.push({ i: 'decl', d })
  for (const m of c.math) out.push(mItem(m))
  for (const kv of c.mathBlocks) out.push(block(kv))
  for (const kv of c.blocks) out.push(block(kv))
}

/** `Source.items`: the constructs of a skeleton, in the printer's order. */
export function items(d: Doc<MR>): RItem[] {
  const out: RItem[] = []
  if (d.desc !== undefined) out.push({ i: 'desc', s: d.desc })
  for (const kv of d.blocks) out.push(block(kv))
  for (const m of d.math) out.push(mItem(m))
  for (const c of d.comps) compItems(c, out)
  return out
}

/** A component section being read. */
interface CompBuf {
  kind: Kind
  name: string
  desc: string | undefined
  decls: Decl[]
  math: MR[]
  mathBlocks: Kv[]
  blocks: Kv[]
}

/** `Comp.fresh`. */
const compFresh = (kind: Kind, name: string): CompBuf => ({
  kind,
  name,
  desc: undefined,
  decls: [],
  math: [],
  mathBlocks: [],
  blocks: [],
})

/** `Source.addTo`: add a construct to a component section; a second description is refused. */
function addTo(c: CompBuf, it: RItem): boolean {
  switch (it.i) {
    case 'desc':
      if (c.desc !== undefined) return false
      c.desc = it.s
      return true
    case 'block':
      if (isMathField(it.k)) c.mathBlocks.push([it.k, it.v])
      else c.blocks.push([it.k, it.v])
      return true
    case 'decl':
      c.decls.push(it.d)
      return true
    case 'eqn':
      c.math.push({ m: 'eq', role: 'eqn', a: it.raw })
      return true
    case 'eqx':
      c.math.push({ m: 'eq', role: it.role, a: it.raw })
      return true
    case 'rxn':
      c.math.push({ m: 'rxn', x: it.x })
      return true
    case 'plot':
      c.math.push({ m: 'plot', attrs: it.attrs })
      return true
    case 'tm':
      c.math.push({ m: 'tm', t: it.t })
      return true
    case 'comp':
      return false
  }
}

/** `Source.unitems`: read a construct sequence (with the front matter) into a skeleton. */
export function unitems(front: Kvs, its: readonly RItem[]): Doc<MR> | undefined {
  let desc: string | undefined
  const blocks: Kv[] = []
  const math: MR[] = []
  const comps: CompBuf[] = []
  let cur: CompBuf | undefined
  // `Source.step`: before the first directive only a description, blocks and
  // templates are allowed.
  for (const it of its) {
    if (it.i === 'comp') {
      if (cur !== undefined) comps.push(cur)
      cur = compFresh(it.kind, it.name)
      continue
    }
    if (cur !== undefined) {
      if (!addTo(cur, it)) return undefined
      continue
    }
    if (it.i === 'desc') {
      if (desc !== undefined) return undefined
      desc = it.s
    } else if (it.i === 'block') blocks.push([it.k, it.v])
    else if (it.i === 'tm') math.push({ m: 'tm', t: it.t })
    else return undefined
  }
  if (cur !== undefined) comps.push(cur)
  return { front, desc, blocks, math, comps }
}

/** `Source.rawDoc`: every math entry printed under its symbol table. */
export function rawDoc(pr: (s: Sym, m: MC) => MR, d: Doc<MC>): Doc<MR> {
  const ts = topSym(d)
  return {
    front: d.front,
    desc: d.desc,
    blocks: d.blocks,
    math: d.math.map((m) => pr(ts, m)),
    comps: d.comps.map((c) => {
      const s = symFor(d, c)
      return mapMath(c, (_, m) => pr(s, m))
    }),
  }
}

/** `Source.cookComp`: read a component's math entries under its symbol table; one math text may hold several equations. */
function cookComp(
  ck: (s: Sym, m: MR) => MC[] | undefined,
  d: Doc<MR>,
  c: Comp<MR>,
): Comp<MC> | undefined {
  const s = symFor(d, c)
  const math: MC[] = []
  for (const m of c.math) {
    const r = ck(s, m)
    if (r === undefined) return undefined
    math.push(...r)
  }
  return { ...c, math }
}

/** `Source.cookDoc`: read every math entry of a skeleton. */
export function cookDoc(ck: (s: Sym, m: MR) => MC[] | undefined, d: Doc<MR>): Doc<MC> | undefined {
  const ts = topSym(d)
  const rm: MC[] = []
  for (const m of d.math) {
    const r = ck(ts, m)
    if (r === undefined) return undefined
    rm.push(...r)
  }
  const cs: Comp<MC>[] = []
  for (const c of d.comps) {
    const r = cookComp(ck, d, c)
    if (r === undefined) return undefined
    cs.push(r)
  }
  return { front: d.front, desc: d.desc, blocks: d.blocks, math: rm, comps: cs }
}

/** `Source.prMx`: a math entry's text, from the equation and expression printers. */
export function prMx(
  prE: (s: Sym, e: Eqn) => string,
  prR: (s: Sym, e: Json) => string,
  s: Sym,
  m: MC,
): MR {
  switch (m.m) {
    case 'eq':
      return { m: 'eq', role: m.role, a: prE(s, m.a) }
    case 'rxn':
      return { m: 'rxn', x: { ...m.x, rate: prR(s, m.x.rate) } }
    case 'plot':
      return m
    case 'tm': {
      const sc = tmScope(m.t, s)
      return {
        m: 'tm',
        t: {
          ...m.t,
          lhs: m.t.lhs === undefined ? undefined : prR(tmMscope(m.t, s), m.t.lhs),
          body: prR(sc, m.t.body),
        },
      }
    }
  }
}

/** `Source.ckMx`: read a math entry's text back. */
export function ckMx(
  ckE: (s: Sym, raw: string) => Eqn[] | undefined,
  ckR: (s: Sym, raw: string) => Json | undefined,
  s: Sym,
  m: MR,
): MC[] | undefined {
  switch (m.m) {
    case 'eq': {
      const es = ckE(s, m.a)
      return es && es.map((a) => ({ m: 'eq', role: m.role, a }))
    }
    case 'rxn': {
      const rate = ckR(s, m.x.rate)
      return rate === undefined ? undefined : [{ m: 'rxn', x: { ...m.x, rate } }]
    }
    case 'plot':
      return [m]
    case 'tm': {
      const sc = tmScope(m.t, s)
      let lhs: Json | undefined
      if (m.t.lhs !== undefined) {
        lhs = ckR(tmMscope(m.t, s), m.t.lhs)
        if (lhs === undefined) return undefined
      }
      const body = ckR(sc, m.t.body)
      if (body === undefined) return undefined
      return [{ m: 'tm', t: { ...m.t, lhs, body } }]
    }
  }
}
