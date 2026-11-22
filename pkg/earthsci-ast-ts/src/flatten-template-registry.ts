/**
 * The MERGED expression-template registry of the flattened representation
 * (esm-spec §9.6.4 rule 7, §10.7; esm-libraries-spec §4.7.5 steps 2 and 4).
 *
 * Every component's carried block is CLOSED first ({@link explicitFreeBlock}):
 * a body's free names become explicit trailing parameters, which every
 * reference binds in its own site's scope, so a closed body reads no component
 * name and one definition can serve every component (and subsystem) that
 * carries it. The closed blocks are then merged by the shared registry merge
 * ({@link mergeFlatRegistry}): one entry per distinct definition, in document
 * order.
 *
 * This binding expands every reference at load (the typed image is the
 * expanded image), so its flattened system holds no reference site to bind; the
 * merged registry is still carried, with the closed bodies, as the goldens pin.
 *
 * Mirrors the Julia reference `_collect_components` (`_tpl_explicit_free`,
 * `_merge_flat_registry`).
 */

import type { EsmFile } from './types.js'
import { isNumericLiteral } from './numeric-literal.js'
import { collectApplyNames, mergeFlatRegistry } from './lower-expression-templates.js'
import { compareUtf8 } from './json-rewrite.js'

/** Plain (non-array, non-null) object test — the JSON "map" shape. */
function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

const APPLY_OP = 'apply_expression_template'

/** The prefix of the template-call sentinel names, which are never free reads. */
const SENTINEL_PREFIX = '\0'

/** The string entries of a JSON list field, else empty. */
function asStringList(v: unknown): string[] {
  return Array.isArray(v) ? v.filter((s): s is string => typeof s === 'string') : []
}

/** Is `decl` a `match` rule (not referenceable, esm-spec §9.6.2)? */
function hasMatch(decl: unknown): boolean {
  return isObj(decl) && decl.match !== undefined && decl.match !== null
}

/**
 * The loop symbols a raw expression node binds for all of its children: its
 * `output_idx` strings, its `ranges` keys and an integral's `var`. Mirrors the
 * Julia `_bound_symbols`.
 */
function boundSymbols(node: Record<string, unknown>): string[] {
  const out: string[] = []
  if (typeof node.var === 'string') out.push(node.var)
  if (isObj(node.ranges)) out.push(...Object.keys(node.ranges))
  out.push(...asStringList(node.output_idx))
  return out
}

/**
 * The expression children of a raw node: `args`, `values`, `lower`, `upper`,
 * `expr`, `filter`, `key`, the values of `bindings` and the bounds of a dense
 * `ranges` entry. Scalar fields such as `wrt` are not reads.
 */
function exprChildren(node: Record<string, unknown>): unknown[] {
  const out: unknown[] = []
  for (const k of ['args', 'values'] as const) {
    const v = node[k]
    if (Array.isArray(v)) out.push(...(v as unknown[]))
  }
  for (const k of ['lower', 'upper', 'expr', 'filter', 'key'] as const) {
    if (node[k] !== undefined) out.push(node[k])
  }
  if (isObj(node.bindings)) out.push(...Object.values(node.bindings))
  if (isObj(node.ranges)) {
    for (const r of Object.values(node.ranges)) if (Array.isArray(r)) out.push(...(r as unknown[]))
  }
  return out
}

/**
 * The plain-string names a raw node's `join` clauses carry: each `on` clause's
 * key columns and each `overlap` clause's `src_env` / `tgt_env` envelope
 * factors (a clause's `syms` are binders, not reads).
 */
function joinNames(node: Record<string, unknown>): string[] {
  const out: string[] = []
  if (!Array.isArray(node.join)) return out
  for (const clause of node.join as unknown[]) {
    if (!isObj(clause)) continue
    if (Array.isArray(clause.on)) {
      for (const pair of clause.on as unknown[]) out.push(...asStringList(pair))
    }
    if (isObj(clause.overlap)) {
      out.push(...asStringList(clause.overlap.src_env), ...asStringList(clause.overlap.tgt_env))
    }
  }
  return out
}

/**
 * The names a raw expression reads and does not bind itself (a node's binders
 * bind all of its children and its own `join`): its variable leaves, and the
 * `join` key columns and overlap envelope factors, which name variables
 * exactly as a leaf does. Binding values of nested references are reads.
 * Mirrors the Julia `_tpl_free_leaves` and `_tpl_free_join_names`.
 */
function freeLeaves(x: unknown, bound: ReadonlySet<string>, out: Set<string>): void {
  if (typeof x === 'string') {
    if (!bound.has(x) && !x.startsWith(SENTINEL_PREFIX)) out.add(x)
    return
  }
  if (!isObj(x) || isNumericLiteral(x) || typeof x.op !== 'string') return
  const b = boundSymbols(x)
  const inner = b.length === 0 ? bound : new Set([...bound, ...b])
  for (const n of joinNames(x)) {
    if (!inner.has(n) && !n.startsWith(SENTINEL_PREFIX)) out.add(n)
  }
  for (const c of exprChildren(x)) freeLeaves(c, inner, out)
}

/**
 * `x` with every reference to a template of `added` binding each added
 * parameter to the same name (`n: n`); a binding the reference already has is
 * kept. Returns `x` itself when nothing changes. Mirrors the Julia
 * `_tpl_bind_explicit`.
 */
export function bindExplicit(x: unknown, added: ReadonlyMap<string, readonly string[]>): unknown {
  if (added.size === 0) return x
  if (Array.isArray(x)) {
    let changed = false
    const out = x.map((c: unknown) => {
      const r = bindExplicit(c, added)
      if (r !== c) changed = true
      return r
    })
    return changed ? out : x
  }
  if (!isObj(x) || isNumericLiteral(x)) return x
  let out: Record<string, unknown> | undefined
  for (const k of Object.keys(x)) {
    const r = bindExplicit(x[k], added)
    if (r !== x[k]) (out ??= { ...x })[k] = r
  }
  let node = out ?? x
  if (node.op === APPLY_OP && typeof node.name === 'string') {
    const names = added.get(node.name)
    if (names !== undefined) {
      const b: Record<string, unknown> = isObj(node.bindings) ? { ...node.bindings } : {}
      let changed = false
      for (const n of names) {
        if (!Object.prototype.hasOwnProperty.call(b, n)) {
          b[n] = n
          changed = true
        }
      }
      if (changed) node = { ...node, bindings: b }
    }
  }
  return node
}

/**
 * `block` (a component's raw template registry) with every match-less body's
 * free names made EXPLICIT parameters (esm-spec §10.7; esm-libraries-spec
 * §4.7.5 step 2). Entries are visited in block order, callees (templates of
 * this block the body references) first. A name a body reads from its caller
 * (a variable leaf, or a `join` key column or overlap envelope factor, that it
 * does not bind and that is not one of its parameters, read directly or
 * through a nested reference) is appended, sorted by UTF-8
 * bytes, to its `params`, and every nested reference in a body binds its
 * callee's added parameters to the same names ({@link bindExplicit}). A decl
 * with no body or with `match` is unchanged. `added` maps each changed template
 * to the parameters it gained, for the call sites.
 *
 * Mirrors the Julia reference `_tpl_explicit_free`.
 */
export function explicitFreeBlock(block: Record<string, unknown>): {
  block: Record<string, unknown>
  added: Map<string, string[]>
} {
  const added = new Map<string, string[]>()
  const newdecl = new Map<string, unknown>()
  const visiting = new Set<string>()
  const has = (n: string): boolean => Object.prototype.hasOwnProperty.call(block, n)
  const visit = (name: string): void => {
    if (newdecl.has(name) || visiting.has(name)) return
    visiting.add(name)
    const decl = block[name]
    const body = isObj(decl) ? decl.body : undefined
    if (!isObj(decl) || body === undefined || body === null || hasMatch(decl)) {
      newdecl.set(name, decl)
      return
    }
    for (const c of new Set(collectApplyNames(body, []))) if (has(c)) visit(c)
    const params = asStringList(decl.params)
    const bound = bindExplicit(body, added)
    const leaves = new Set<string>()
    freeLeaves(bound, new Set<string>(), leaves)
    const pset = new Set(params)
    const free = [...leaves].filter((n) => !pset.has(n)).sort(compareUtf8)
    if (bound === body && free.length === 0) {
      newdecl.set(name, decl)
      return
    }
    const nd: Record<string, unknown> = { ...decl }
    if (bound !== body) nd.body = bound
    if (free.length > 0) {
      nd.params = [...params, ...free]
      added.set(name, free)
    }
    newdecl.set(name, nd)
  }
  for (const k of Object.keys(block)) visit(k)
  const out: Record<string, unknown> = {}
  for (const k of Object.keys(block)) out[k] = newdecl.get(k)
  return { block: out, added }
}

/**
 * The MERGED expression-template registry of `file`'s flattened form
 * (esm-spec §9.6.4 rule 7, §10.7; esm-libraries-spec §4.7.5 steps 2 and 4).
 *
 * The per-component registries captured at load (`EsmFile.componentTemplates`),
 * models in file order then reaction systems:
 *
 *  1. **Close, then merge.** Every component's block (models and reaction
 *     systems alike) is closed ({@link explicitFreeBlock}): a body's free names
 *     become explicit parameters, bound at every reference in its own site's
 *     scope, so a body reads no component name.
 *  2. **Merge** ({@link mergeFlatRegistry}): deep-equal entries kept once
 *     under the bare name; a colliding name keeps one entry per distinct
 *     definition, `<first owner>.<name>`, the collision closed under the
 *     reference DAG.
 *
 * `match` rules are excluded: only match-less templates are referenceable
 * (§9.6.2), so only they can be merged. The returned object's KEY ORDER is part
 * of the contract.
 *
 * Returns `{}` for a file carrying no `componentTemplates`.
 */
export function mergedTemplateRegistry(file: EsmFile): Record<string, unknown> {
  const componentTemplates = file.componentTemplates
  if (!isObj(componentTemplates) || Object.keys(componentTemplates).length === 0) return {}

  // Document order: models as the file declares them, then reaction systems.
  const models: Record<string, unknown> = isObj(file.models) ? file.models : {}
  const reactionSystems: Record<string, unknown> = isObj(file.reaction_systems)
    ? file.reaction_systems
    : {}
  const orderedKeys = [
    ...Object.keys(models).map((n) => `models.${n}`),
    ...Object.keys(reactionSystems).map((n) => `reaction_systems.${n}`),
  ]
  for (const key of Object.keys(componentTemplates)) {
    // A component the typed file no longer holds.
    if (!orderedKeys.includes(key)) orderedKeys.push(key)
  }

  const blocks: { path: string; block: Record<string, unknown> }[] = []
  for (const compKey of orderedKeys) {
    const raw = componentTemplates[compKey]
    if (!isObj(raw)) continue
    const dot = compKey.indexOf('.')
    const cname = dot >= 0 ? compKey.slice(dot + 1) : ''
    const { block } = explicitFreeBlock(raw)
    const matchless: Record<string, unknown> = {}
    for (const [tname, decl] of Object.entries(block)) {
      // Match rules are not referenceable, so not merged.
      if (!hasMatch(decl)) matchless[tname] = decl
    }
    blocks.push({ path: cname, block: matchless })
  }
  return mergeFlatRegistry(blocks).merged
}
