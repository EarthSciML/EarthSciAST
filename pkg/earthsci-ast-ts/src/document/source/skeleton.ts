/**
 * The document skeleton: front matter, description, path blocks, and one section
 * per model or reaction system, with the path-keyed fallback for every field
 * without a native surface.
 *
 * Port of `formal/Esm/Document/Source/Skeleton.lean` (after the Rust binding's
 * `document/source/skeleton.rs`). The mapping is total: every field a container
 * cannot spell natively falls back to a block keyed by its JSON path relative to
 * the enclosing section. {@link Caps} are the container's predicates saying which
 * values it spells natively.
 */

import {
  JNULL,
  jarr,
  jnum,
  jobj,
  jsonEq,
  jstr,
  lookKvs as look,
  type JNum,
  type Json,
} from '../json.js'
import { isE, jwf, keysSorted, type Sym } from '../math/index.js'
import { at_, joinField, pickOne, sortKvs, splitOpt, type Kv, type Kvs } from './keys.js'

// ## The canonical form of a document

/** `Source.sortedDeep`: every object, at every depth, has strictly increasing keys. */
export function sortedDeep(j: Json): boolean {
  if (j.t === 'obj') return keysSorted(j.kvs) && j.kvs.every(([, v]) => sortedDeep(v))
  if (j.t === 'arr') return j.xs.every(sortedDeep)
  return true
}

/** `Source.canonDoc`: a JSON object, well formed, with sorted keys at every depth. */
export function canonDoc(j: Json): boolean {
  return j.t === 'obj' && jwf(j) && sortedDeep(j)
}

/** `Source.Kind`: a model or a reaction system. */
export type Kind = 'model' | 'rs'

/** `Source.DKind`: the declaration directives (`sub`: a subsystem included by reference). */
export type DKind = 'var' | 'param' | 'species' | 'sub'

/** `Source.Decl`: the directive, the declared name, and the other fields as attributes. */
export interface Decl {
  readonly kind: DKind
  readonly name: string
  readonly attrs: Kvs
}

/** `Source.Eqn`: `lhs = rhs`, with its optional `_comment`. */
export interface Eqn {
  readonly comment: string | undefined
  readonly lhs: Json
  readonly rhs: Json
}

/** `Source.Role`: the field an equation belongs to. */
export type Role = 'eqn' | 'init' | 'cons'

/** `Role.field`. */
export function roleField(r: Role): string {
  return r === 'eqn'
    ? 'equations'
    : r === 'init'
      ? 'initialization_equations'
      : 'constraint_equations'
}

/** `Source.Term`: a species and its stoichiometric coefficient. */
export interface Term {
  readonly species: string
  readonly coef: JNum
}

/**
 * `Source.Rxn`: a reaction's `id`, sides (`undefined` for an empty side), rate
 * (`R`: the expression, or its math text) and other fields.
 */
export interface Rxn<R> {
  readonly id: string
  readonly subs: readonly Term[] | undefined
  readonly prods: readonly Term[] | undefined
  readonly rate: R
  readonly attrs: Kvs
}

/**
 * `Source.Tm`: an entry of `operators`: a template (`lhs` undefined)
 * or a rewrite rule (`lhs` its match).
 */
export interface Tm<R> {
  readonly name: string
  readonly params: readonly string[]
  readonly lhs: R | undefined
  readonly body: R
  readonly attrs: Kvs
}

/** `Source.Mx`: a list entry of a component. */
export type Mx<A, R> =
  | { readonly m: 'eq'; readonly role: Role; readonly a: A }
  | { readonly m: 'rxn'; readonly x: Rxn<R> }
  | { readonly m: 'plot'; readonly attrs: Kvs }
  | { readonly m: 'tm'; readonly t: Tm<R> }

/** `Source.MC`: a math entry as read. */
export type MC = Mx<Eqn, Json>
/** `Source.MR`: a math entry as the container's text. */
export type MR = Mx<string, string>

/** `Mx.field`. */
export function mxField<A, R>(m: Mx<A, R>): string {
  switch (m.m) {
    case 'eq':
      return roleField(m.role)
    case 'rxn':
      return 'reactions'
    case 'plot':
      return 'analyses'
    case 'tm':
      return 'operators'
  }
}

/** `Mx.key`. */
export function mxKey<A, R>(m: Mx<A, R>): string {
  return m.m === 'tm' ? m.t.name : ''
}

/** A template's symbol-table entry: its name and parameters. */
export type THead = readonly [string, readonly string[]]

/** `Mx.head`: the symbol-table entry of a template or rule. */
export function mxHead<A, R>(m: Mx<A, R>): THead | undefined {
  return m.m === 'tm' ? [m.t.name, tmPs(m.t)] : undefined
}

/** `Source.mathFields`. */
export const MATH_FIELDS: readonly string[] = [
  'analyses',
  'constraint_equations',
  'equations',
  'initialization_equations',
  'operators',
  'reactions',
]

/** `k ∈ mathFields`. */
export const isMathField = (k: string): boolean => MATH_FIELDS.includes(k)

/** `Source.Comp`: one component section. */
export interface Comp<A> {
  readonly kind: Kind
  readonly name: string
  readonly desc: string | undefined
  readonly decls: readonly Decl[]
  readonly math: readonly A[]
  readonly mathBlocks: Kvs
  readonly blocks: Kvs
}

/** `Source.Doc`: a document skeleton. */
export interface Doc<A> {
  readonly front: Kvs
  readonly desc: string | undefined
  readonly blocks: Kvs
  readonly math: readonly A[]
  readonly comps: readonly Comp<A>[]
}

/** `Comp.mapMath`. */
export function mapMath<A, B>(c: Comp<A>, f: (c: Comp<A>, a: A) => B): Comp<B> {
  return { ...c, math: c.math.map((m) => f(c, m)) }
}

// ## The symbol table of a component

/** `Source.keysOf`. */
export function keysOf(v: Json | undefined): string[] {
  return v !== undefined && v.t === 'obj' ? v.kvs.map((kv) => kv[0]) : []
}

/** `Source.strsOf`. */
export function strsOf(v: Json | undefined): string[] {
  if (v === undefined || v.t !== 'arr') return []
  const out: string[] = []
  for (const x of v.xs) if (x.t === 'str') out.push(x.s)
  return out
}

/** `Source.templatesOf`. */
export function templatesOf(v: Json | undefined): THead[] {
  if (v === undefined || v.t !== 'obj') return []
  const out: THead[] = []
  for (const [k, x] of v.kvs) if (x.t === 'obj') out.push([k, strsOf(look('params', x.kvs))])
  return out
}

/** `Tm.ps`: a template's header parameters; a rule's `params` attribute. */
export function tmPs<R>(t: Tm<R>): readonly string[] {
  return t.lhs === undefined ? t.params : strsOf(look('params', t.attrs))
}

/** `Tm.scope`: the table around it, with the parameters declared. */
export function tmScope<R>(t: Tm<R>, s: Sym): Sym {
  return { names: [...s.names, ...tmPs(t)], templates: s.templates }
}

/**
 * `Tm.mscope`: the symbol table a rule's `match` pattern is read under: its
 * body's, with no templates. A pattern never applies a template (spec §9.7.3:
 * `match` patterns MUST NOT contain `apply_operator` nodes), so an
 * operator in it named like a template in scope (a rule is in scope under its
 * own name) reads as that operator, in the call form.
 */
export function tmMscope<R>(t: Tm<R>, s: Sym): Sym {
  return { names: tmScope(t, s).names, templates: [] }
}

/** `Source.rootTs`. */
export function rootTs<A, R>(root: Kvs, rm: readonly Mx<A, R>[]): THead[] {
  const out = templatesOf(look('operators', root))
  for (const m of rm) {
    const h = mxHead(m)
    if (h !== undefined) out.push(h)
  }
  return out
}

/** `Source.compTs`. */
export function compTs<A, R>(c: Comp<Mx<A, R>>): THead[] {
  const out = templatesOf(look('operators', c.mathBlocks))
  for (const m of c.math) {
    const h = mxHead(m)
    if (h !== undefined) out.push(h)
  }
  return out
}

/** `Source.symWith`. */
export function symWith<A>(root: Kvs, rt: readonly THead[], c: Comp<A>, ct: readonly THead[]): Sym {
  const names = c.decls.filter((d) => d.kind !== 'sub').map((d) => d.name)
  names.push(...keysOf(look('variables', c.blocks)))
  names.push(...keysOf(look('species', c.blocks)))
  names.push(...keysOf(look('parameters', c.blocks)))
  names.push(...keysOf(look('index_sets', root)))
  return { names, templates: [...rt, ...ct] }
}

/** `Source.symFor`: the symbol table of a component. */
export function symFor<A, R>(d: Doc<Mx<A, R>>, c: Comp<Mx<A, R>>): Sym {
  return symWith(d.blocks, rootTs(d.blocks, d.math), c, compTs(c))
}

/** `Source.topSym`: the symbol table of the top-level templates. */
export function topSym<A, R>(d: Doc<Mx<A, R>>): Sym {
  return { names: keysOf(look('index_sets', d.blocks)), templates: rootTs(d.blocks, d.math) }
}

/** `Source.Caps`: what a container spells natively. */
export interface Caps {
  /** A front-matter key. */
  frontKey(k: string): boolean
  /** A description text. */
  desc(s: string): boolean
  /** A component name in its directive. */
  compName(n: string): boolean
  /** A declared name (printed as math). */
  declName(n: string): boolean
  /** A declaration attribute. */
  attr(a: Kv): boolean
  /** An equation under the component's symbol table. */
  eqn(s: Sym, e: Eqn): boolean
  /** A reaction under the component's symbol table. */
  rxn(s: Sym, x: Rxn<Json>): boolean
  /** The fields of a plot directive. */
  plot(a: Kvs): boolean
  /** A template or rule, under its body's symbol table. */
  tm(s: Sym, t: Tm<Json>): boolean
}

/** `Caps.item`: a list entry the container spells. */
export function capsItem(caps: Caps, s: Sym, m: MC): boolean {
  switch (m.m) {
    case 'eq':
      return caps.eqn(s, m.a)
    case 'rxn':
      return caps.rxn(s, m.x)
    case 'plot':
      return caps.plot(m.attrs)
    case 'tm':
      return caps.tm(tmScope(m.t, s), m.t)
  }
}

// ## Equations and the other math entries

/** `Source.eqnJson`. */
export function eqnJson(e: Eqn): Json {
  return e.comment !== undefined
    ? jobj([
        ['_comment', jstr(e.comment)],
        ['lhs', e.lhs],
        ['rhs', e.rhs],
      ])
    : jobj([
        ['lhs', e.lhs],
        ['rhs', e.rhs],
      ])
}

/** `Source.eqnOf`: exactly the keys `lhs`, `rhs` and optionally a string `_comment`. */
export function eqnOf(v: Json): Eqn | undefined {
  if (v.t !== 'obj') return undefined
  const kvs = v.kvs
  if (kvs.length === 3) {
    const [[c, cm], [l, lv], [r, rv]] = kvs
    if (c === '_comment' && cm.t === 'str' && l === 'lhs' && r === 'rhs') {
      return isE(lv) && isE(rv) ? { comment: cm.s, lhs: lv, rhs: rv } : undefined
    }
    return undefined
  }
  if (kvs.length === 2) {
    const [[l, lv], [r, rv]] = kvs
    if (l === 'lhs' && r === 'rhs')
      return isE(lv) && isE(rv) ? { comment: undefined, lhs: lv, rhs: rv } : undefined
  }
  return undefined
}

/** `Source.termJson`. */
export function termJson(t: Term): Json {
  return jobj([
    ['species', jstr(t.species)],
    ['stoichiometry', jnum(t.coef)],
  ])
}

/** `Source.termOf`. */
export function termOf(v: Json): Term | undefined {
  if (v.t !== 'obj' || v.kvs.length !== 2) return undefined
  const [[a, s], [b, n]] = v.kvs
  if (a === 'species' && s.t === 'str' && b === 'stoichiometry' && n.t === 'num')
    return { species: s.s, coef: n.n }
  return undefined
}

/** `Source.sideJson`. */
export function sideJson(s: readonly Term[] | undefined): Json {
  return s === undefined ? JNULL : jarr(s.map(termJson))
}

/** `Source.sideOf`: `null`, or a non-empty array of terms (`null` result = an empty side). */
export function sideOf(v: Json): Term[] | null | undefined {
  if (v.t === 'null') return null
  if (v.t !== 'arr' || v.xs.length === 0) return undefined
  const out: Term[] = []
  for (const x of v.xs) {
    const t = termOf(x)
    if (t === undefined) return undefined
    out.push(t)
  }
  return out
}

/** `Source.rxnKeys`. */
export const RXN_KEYS: readonly string[] = ['id', 'products', 'rate', 'substrates']

/** `Source.rxnJson`. */
export function rxnJson(x: Rxn<Json>): Json {
  return jobj(
    sortKvs([
      ['id', jstr(x.id)],
      ['products', sideJson(x.prods)],
      ['rate', x.rate],
      ['substrates', sideJson(x.subs)],
      ...x.attrs,
    ]),
  )
}

/** `Source.rxnOf`: checked by printing it back. */
export function rxnOf(v: Json): Rxn<Json> | undefined {
  if (v.t !== 'obj') return undefined
  const kvs = v.kvs
  const id = look('id', kvs)
  const sv = look('substrates', kvs)
  const pv = look('products', kvs)
  const r = look('rate', kvs)
  if (id === undefined || id.t !== 'str' || sv === undefined || pv === undefined || r === undefined)
    return undefined
  const s = sideOf(sv)
  const p = sideOf(pv)
  if (s === undefined || p === undefined) return undefined
  const x: Rxn<Json> = {
    id: id.s,
    subs: s ?? undefined,
    prods: p ?? undefined,
    rate: r,
    attrs: kvs.filter((kv) => !RXN_KEYS.includes(kv[0])),
  }
  return jsonEq(rxnJson(x), v) && isE(r) ? x : undefined
}

/** `Source.plotJson`. */
export function plotJson(attrs: Kvs): Json {
  return jobj(
    sortKvs(
      attrs.map(([k, v]) => (k === 'plot' ? (['plots', jarr([v])] as const) : ([k, v] as const))),
    ),
  )
}

/** `Source.plotOf`: an analysis with exactly one plot and no `plot` field, checked by printing it back. */
export function plotOf(v: Json): Kv[] | undefined {
  if (v.t !== 'obj') return undefined
  const ps = look('plots', v.kvs)
  if (ps === undefined || ps.t !== 'arr' || ps.xs.length !== 1 || look('plot', v.kvs) !== undefined)
    return undefined
  const a: Kv[] = v.kvs.map(([k, x]) =>
    k === 'plots' ? (['plot', ps.xs[0]] as const) : ([k, x] as const),
  )
  return jsonEq(plotJson(a), v) ? a : undefined
}

/** `Source.tmJson`. */
export function tmJson(t: Tm<Json>): Json {
  const kvs: Kv[] =
    t.lhs === undefined
      ? [
          ['body', t.body],
          ['params', jarr(t.params.map(jstr))],
        ]
      : [
          ['body', t.body],
          ['match', t.lhs],
        ]
  return jobj(sortKvs([...kvs, ...t.attrs]))
}

/** `Source.strList`: the string entries of a list, when every entry is a string. */
export function strList(xs: readonly Json[]): string[] | undefined {
  const out: string[] = []
  for (const x of xs) {
    if (x.t !== 'str') return undefined
    out.push(x.s)
  }
  return out
}

/** `Source.tmOf`: the template or rule an entry of `operators` is, checked by printing it back. */
export function tmOf(n: string, v: Json): Tm<Json> | undefined {
  if (v.t !== 'obj') return undefined
  const kvs = v.kvs
  const b = look('body', kvs)
  const m = look('match', kvs)
  const ps = look('params', kvs)
  if (b !== undefined && m === undefined && ps !== undefined && ps.t === 'arr') {
    const ps2 = strList(ps.xs)
    if (ps2 === undefined) return undefined
    const t: Tm<Json> = {
      name: n,
      params: ps2,
      lhs: undefined,
      body: b,
      attrs: kvs.filter((kv) => kv[0] !== 'body' && kv[0] !== 'params'),
    }
    return jsonEq(tmJson(t), v) && isE(b) ? t : undefined
  }
  if (b !== undefined && m !== undefined) {
    const t: Tm<Json> = {
      name: n,
      params: [],
      lhs: m,
      body: b,
      attrs: kvs.filter((kv) => kv[0] !== 'body' && kv[0] !== 'match'),
    }
    return jsonEq(tmJson(t), v) && isE(b) && isE(m) ? t : undefined
  }
  return undefined
}

/** `Source.itemJson`. */
export function itemJson(m: MC): Json {
  switch (m.m) {
    case 'eq':
      return eqnJson(m.a)
    case 'rxn':
      return rxnJson(m.x)
    case 'plot':
      return plotJson(m.attrs)
    case 'tm':
      return tmJson(m.t)
  }
}

/** `Source.fieldJson`: an object keyed by the entries' names for `operators`, a list otherwise. */
export function fieldJson(f: string, ms: readonly MC[]): Json {
  if (f === 'operators') return jobj(ms.map((m) => [mxKey(m), itemJson(m)] as const))
  return jarr(ms.map(itemJson))
}

/** `Source.roleOf`. */
export function roleOf(f: string): Role | undefined {
  return (['eqn', 'init', 'cons'] as const).find((r) => roleField(r) === f)
}

/** `Source.itemOf`. */
export function itemOf(f: string, v: Json): MC | undefined {
  if (f === 'reactions') {
    const x = rxnOf(v)
    return x && { m: 'rxn', x }
  }
  if (f === 'analyses') {
    const attrs = plotOf(v)
    return attrs && { m: 'plot', attrs }
  }
  const role = roleOf(f)
  if (role === undefined) return undefined
  const a = eqnOf(v)
  return a && { m: 'eq', role, a }
}

/** `Source.tmItem`. */
export function tmItem(kv: Kv): MC | undefined {
  const t = tmOf(kv[0], kv[1])
  return t && { m: 'tm', t }
}

/** `Source.mathOf`: the entries of a math field, when all of them print natively. */
export function mathOf(caps: Caps, s: Sym, f: string, v: Json): MC[] | undefined {
  const ms: MC[] = []
  if (v.t === 'arr' && v.xs.length > 0) {
    if (f === 'operators') return undefined
    for (const x of v.xs) {
      const m = itemOf(f, x)
      if (m === undefined) return undefined
      ms.push(m)
    }
  } else if (v.t === 'obj' && v.kvs.length > 0) {
    if (f !== 'operators') return undefined
    for (const kv of v.kvs) {
      const m = tmItem(kv)
      if (m === undefined) return undefined
      ms.push(m)
    }
  } else return undefined
  return ms.every((m) => capsItem(caps, s, m)) ? ms : undefined
}

/** `Source.descOf`. */
export function descOf(caps: Caps, v: Json | undefined): string | undefined {
  return v !== undefined && v.t === 'str' && caps.desc(v.s) ? v.s : undefined
}

/** `Source.metaOf`: `metadata` printed in the front matter: the front-matter entries and the description. */
export function metaOf(caps: Caps, v: Json | undefined): [Kv[], string | undefined] | undefined {
  if (v === undefined || v.t !== 'obj') return undefined
  const kvs = v.kvs
  if (
    kvs.length === 0 ||
    look('esm', kvs) !== undefined ||
    !kvs.every((kv) => caps.frontKey(kv[0]))
  )
    return undefined
  const d = descOf(caps, look('description', kvs))
  return [kvs.filter((kv) => !(kv[0] === 'description' && d !== undefined)), d]
}

/** `Source.pickVar`: a model variable as a declaration. */
export function pickVar(caps: Caps, n: string, v: Json): Decl | undefined {
  if (!caps.declName(n) || v.t !== 'obj') return undefined
  const kvs = v.kvs
  const withoutType = (): Kvs => kvs.filter((kv) => kv[0] !== 'type')
  const mk = (kind: DKind, attrs: Kvs): Decl | undefined =>
    attrs.every((a) => caps.attr(a)) ? { kind, name: n, attrs } : undefined
  const t = look('type', kvs)
  if (t === undefined) return undefined
  if (t.t === 'str' && t.s === 'parameter') return mk('param', withoutType())
  if (t.t === 'str' && t.s === 'unknown') return mk('var', withoutType())
  return mk('var', kvs)
}

/** `Source.pickPlain`: a reaction-system species or parameter as a declaration of kind `k`. */
export function pickPlain(caps: Caps, k: DKind, n: string, v: Json): Decl | undefined {
  if (!caps.declName(n)) return undefined
  if (v.t === 'obj' && v.kvs.every((a) => caps.attr(a))) return { kind: k, name: n, attrs: v.kvs }
  return undefined
}

/** `Source.pickSub`: a subsystem included by reference. */
export function pickSub(caps: Caps, n: string, v: Json): Decl | undefined {
  return v.t === 'obj' && look('ref', v.kvs) !== undefined
    ? pickPlain(caps, 'sub', n, v)
    : undefined
}

/** The pickers of `Source.declFields`. */
type Picker = (caps: Caps, n: string, v: Json) => Decl | undefined

const PICK_SPECIES: Picker = (caps, n, v) => pickPlain(caps, 'species', n, v)
const PICK_PARAM: Picker = (caps, n, v) => pickPlain(caps, 'param', n, v)

/** `Source.declFields`: the declaration fields of a component kind, with their pickers. */
export function declFields(k: Kind): readonly (readonly [string, Picker])[] {
  return k === 'model'
    ? [
        ['variables', pickVar],
        ['subsystems', pickSub],
      ]
    : [
        ['species', PICK_SPECIES],
        ['parameters', PICK_PARAM],
        ['subsystems', pickSub],
      ]
}

/** `Source.declField`. */
export function declField(k: Kind, d: DKind): string | undefined {
  if (d === 'sub') return 'subsystems'
  if (k === 'model') return d === 'var' || d === 'param' ? 'variables' : undefined
  return d === 'species' ? 'species' : d === 'param' ? 'parameters' : undefined
}

/** `Source.backDecl`: the entry a declaration stands for. */
export function backDecl(k: Kind, d: Decl): Kv | undefined {
  const hasType = d.attrs.some((kv) => kv[0] === 'type')
  const withType = (t: string): Json => jobj(sortKvs([['type', jstr(t)], ...d.attrs]))
  if (k === 'model' && d.kind === 'param')
    return hasType ? undefined : [d.name, withType('parameter')]
  if (k === 'model' && d.kind === 'var')
    return hasType ? [d.name, jobj(sortKvs(d.attrs))] : [d.name, withType('unknown')]
  if ((k === 'rs' && (d.kind === 'species' || d.kind === 'param')) || d.kind === 'sub') {
    return [d.name, jobj(sortKvs(d.attrs))]
  }
  return undefined
}

/** `Source.compBlock`: where an entry of a component goes when it is not a native surface. */
export function compBlock(caps: Caps, k: Kind, desc: string | undefined, kv: Kv): Kv | undefined {
  if (kv[0] === 'description') return desc !== undefined ? undefined : kv
  if (isMathField(kv[0])) return undefined
  const f = declFields(k).find((p) => p[0] === kv[0])
  if (f === undefined) return kv
  const r = splitOpt((n, v) => f[1](caps, n, v), kv[1])[1]
  return r === undefined ? undefined : [kv[0], r]
}

/** `Source.compBase`: a component before its equations are decided. */
export function compBase(caps: Caps, k: Kind, name: string, kvs: Kvs): Comp<MC> {
  const desc = descOf(caps, look('description', kvs))
  const decls = declFields(k).flatMap(
    ([f, p]) => splitOpt((n, v) => p(caps, n, v), look(f, kvs))[0],
  )
  const blocks: Kv[] = []
  for (const kv of kvs) {
    const b = compBlock(caps, k, desc, kv)
    if (b !== undefined) blocks.push(b)
  }
  return { kind: k, name, desc, decls, math: [], mathBlocks: [], blocks }
}

/** `Source.mathPart`: one math field of a component: its entries when every one prints natively under `s`, else its block. */
export function mathPart(caps: Caps, s: Sym, kvs: Kvs, f: string): [MC[], Kv | undefined] {
  const v = look(f, kvs)
  if (v === undefined) return [[], undefined]
  const ms = mathOf(caps, s, f, v)
  return ms !== undefined ? [ms, undefined] : [[], [f, v]]
}

/** `Source.compSym`. */
export function compSym(
  root: Kvs,
  rt: readonly THead[],
  k: Kind,
  caps: Caps,
  name: string,
  kvs: Kvs,
): Sym {
  return symWith(root, rt, compBase(caps, k, name, kvs), templatesOf(look('operators', kvs)))
}

/** `Source.compOf`: a component, with its math fields decided. */
export function compOf(
  caps: Caps,
  root: Kvs,
  rt: readonly THead[],
  k: Kind,
  name: string,
  kvs: Kvs,
): Comp<MC> {
  const c = compBase(caps, k, name, kvs)
  const s = symWith(root, rt, c, templatesOf(look('operators', kvs)))
  const math: MC[] = []
  const mathBlocks: Kv[] = []
  for (const f of MATH_FIELDS) {
    const [ms, b] = mathPart(caps, s, kvs, f)
    math.push(...ms)
    if (b !== undefined) mathBlocks.push(b)
  }
  return { ...c, math, mathBlocks }
}

/** `Source.pickComp`. */
export function pickComp(caps: Caps, n: string, v: Json): [string, Kvs] | undefined {
  return v.t === 'obj' && caps.compName(n) ? [n, v.kvs] : undefined
}

/** `Source.topSymOf`. */
export function topSymOf(kvs: Kvs): Sym {
  return {
    names: keysOf(look('index_sets', kvs)),
    templates: templatesOf(look('operators', kvs)),
  }
}

/** `Source.topMath`: the top-level templates, when every one prints natively. */
export function topMath(caps: Caps, kvs: Kvs): MC[] | undefined {
  const v = look('operators', kvs)
  return v === undefined ? undefined : mathOf(caps, topSymOf(kvs), 'operators', v)
}

/** `Source.rootBlock`. */
export function rootBlock(caps: Caps, tn: boolean, kv: Kv): Kv | undefined {
  const k = kv[0]
  if (k === 'esm') return undefined
  if (k === 'metadata') return metaOf(caps, kv[1]) !== undefined ? undefined : kv
  if (k === 'models' || k === 'reaction_systems') {
    const r = splitOpt((n, v) => pickComp(caps, n, v), kv[1])[1]
    return r === undefined ? undefined : [k, r]
  }
  if (k === 'operators' && tn) return undefined
  return kv
}

/** `Source.rootBlocks`. */
export function rootBlocks(caps: Caps, tn: boolean, kvs: Kvs): Kv[] {
  const out: Kv[] = []
  for (const kv of kvs) {
    const b = rootBlock(caps, tn, kv)
    if (b !== undefined) out.push(b)
  }
  return out
}

/** `Source.toDoc`: the skeleton of a document. */
export function toDoc(caps: Caps, d: Json): Doc<MC> {
  if (d.t !== 'obj') return { front: [], desc: undefined, blocks: [], math: [], comps: [] }
  const kvs = d.kvs
  const m = metaOf(caps, look('metadata', kvs))
  const tm = topMath(caps, kvs)
  const blocks = rootBlocks(caps, tm !== undefined, kvs)
  const rt = templatesOf(look('operators', kvs))
  const comps = (k: Kind, f: string): Comp<MC>[] =>
    splitOpt((n, v) => pickComp(caps, n, v), look(f, kvs))[0].map(([n, ckvs]) =>
      compOf(caps, blocks, rt, k, n, ckvs),
    )
  const front = at_('esm', kvs)
  if (m !== undefined) front.push(...m[0])
  return {
    front,
    desc: m?.[1],
    blocks,
    math: tm ?? [],
    comps: [...comps('model', 'models'), ...comps('rs', 'reaction_systems')],
  }
}

// ## From a skeleton back to the document

/** `Source.optKv`. */
export function optKv(k: string, v: Json | null | undefined): Kv[] {
  return v === undefined || v === null ? [] : [[k, v]]
}

/** `Source.mathKv`: one rebuilt math field. */
export function mathKv(c: Comp<MC>, f: string): Kv[] | undefined {
  const ms = c.math.filter((m) => mxField(m) === f)
  const bs = at_(f, c.mathBlocks)
  if (ms.length === 0 && bs.length === 0) return []
  if (ms.length === 0 && bs.length === 1) return [[f, bs[0][1]]]
  if (ms.length > 0 && bs.length === 0) return [[f, fieldJson(f, ms)]]
  return undefined
}

/** `Source.mathKvs`. */
export function mathKvs(c: Comp<MC>): Kv[] | undefined {
  const out: Kv[] = []
  for (const f of MATH_FIELDS) {
    const kv = mathKv(c, f)
    if (kv === undefined) return undefined
    out.push(...kv)
  }
  return out
}

/** `Source.declFieldNames`. */
export function declFieldNames(k: Kind): readonly string[] {
  return k === 'model' ? ['variables', 'subsystems'] : ['species', 'parameters', 'subsystems']
}

/** `Source.declKv`. */
export function declKv(k: Kind, c: Comp<MC>, f: string): Kv[] | undefined {
  const r = pickOne(f, c.blocks)
  if (r === undefined) return undefined
  const ds = c.decls.filter((d) => declField(k, d.kind) === f)
  const v = joinField((d: Decl) => backDecl(k, d), ds, r ?? undefined)
  if (v === undefined) return undefined
  return optKv(f, v)
}

/** `Source.declKvs`: a declaration of a kind the component does not have is refused. */
export function declKvs(k: Kind, c: Comp<MC>): Kv[] | undefined {
  if (!c.decls.every((d) => declField(k, d.kind) !== undefined)) return undefined
  const out: Kv[] = []
  for (const f of declFieldNames(k)) {
    const kv = declKv(k, c, f)
    if (kv === undefined) return undefined
    out.push(...kv)
  }
  return out
}

/** `Source.ofComp`: a component rebuilt from its section. */
export function ofComp(c: Comp<MC>): Json | undefined {
  const ds = declKvs(c.kind, c)
  if (ds === undefined) return undefined
  const es = mathKvs(c)
  if (es === undefined) return undefined
  const names = declFieldNames(c.kind)
  return jobj(
    sortKvs([
      ...optKv('description', c.desc === undefined ? undefined : jstr(c.desc)),
      ...ds,
      ...es,
      ...c.blocks.filter((kv) => !names.includes(kv[0])),
    ]),
  )
}

/** `Source.backComp`. */
export function backComp(c: Comp<MC>): Kv | undefined {
  const v = ofComp(c)
  return v === undefined ? undefined : [c.name, v]
}

/** `Source.ofDoc`: a document rebuilt from its skeleton, checked to be canonical. */
export function ofDoc(d: Doc<MC>): Json | undefined {
  const esmKv = at_('esm', d.front)
  const metaEs: Kv[] = d.front.filter((kv) => kv[0] !== 'esm')
  metaEs.push(...optKv('description', d.desc === undefined ? undefined : jstr(d.desc)))
  const metaKv: Kv[] = metaEs.length === 0 ? [] : [['metadata', jobj(sortKvs(metaEs))]]
  const mr = pickOne('models', d.blocks)
  if (mr === undefined) return undefined
  const models = joinField(
    backComp,
    d.comps.filter((c) => c.kind === 'model'),
    mr ?? undefined,
  )
  if (models === undefined) return undefined
  const rr = pickOne('reaction_systems', d.blocks)
  if (rr === undefined) return undefined
  const rss = joinField(
    backComp,
    d.comps.filter((c) => c.kind === 'rs'),
    rr ?? undefined,
  )
  if (rss === undefined) return undefined
  const tkv: Kv[] = d.math.length === 0 ? [] : [['operators', fieldJson('operators', d.math)]]
  const doc = jobj(
    sortKvs([
      ...esmKv,
      ...metaKv,
      ...optKv('models', models),
      ...optKv('reaction_systems', rss),
      ...tkv,
      ...d.blocks.filter((kv) => kv[0] !== 'models' && kv[0] !== 'reaction_systems'),
    ]),
  )
  return canonDoc(doc) ? doc : undefined
}
