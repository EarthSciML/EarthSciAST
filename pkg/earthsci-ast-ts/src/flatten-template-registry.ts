/**
 * The MERGED expression-template registry of the flattened representation
 * (esm-spec §9.6.4 rule 7, §10.7; esm-libraries-spec §4.7.5 step 4).
 *
 * This is the SCOPED, DOCUMENT-ORDERED merge that `flatten()` carries as a
 * first-class field of the flattened system. It is deliberately NOT
 * `flattenTemplateRegistries` (`lower-expression-templates.ts`): that function
 * is the separately-conformed `flatten_template_registries` surface, which
 * implements step 4's UNION HALF ONLY over the un-namespaced component view
 * (it sorts names and never component-scopes a body). Step 4's "Ordering
 * (normative)" paragraph says a caller that goes on to namespace MUST compose
 * that union with step 2 — which is what this module does, in the right order.
 *
 * Mirrors the Python reference `flatten._merged_template_registry` /
 * `flatten._scope_template_body` / `flatten._namespace_join`.
 */

import type { EsmFile } from './types.js'
import { isNumericLiteral } from './numeric-literal.js'
import { registryCollisionNames, renameApplyRefs } from './lower-expression-templates.js'

/** Plain (non-array, non-null) object test — the JSON "map" shape. */
function isObj(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

/**
 * An expression node in the RAW JSON (serialized) form: any object carrying an
 * `op`. `componentTemplates` bodies are raw JSON, never the typed
 * `ExpressionNode`, so this is the node test the walk below uses. A
 * `NumericLiteral` carrier (`{kind, value}`) has no `op` and is therefore a
 * leaf, exactly as in the Python reference.
 */
function isJsonExprNode(v: unknown): v is Record<string, unknown> {
  return isObj(v) && 'op' in v
}

// ---------------------------------------------------------------------------
// Child-position tables for the raw-JSON walk.
//
// These mirror `expression.ts`'s canonical `EXPRESSION_CHILD_KEYS` (and the
// Python `expr_walk` field set) split by codec kind, because the walk here
// operates on raw JSON rather than on typed `ExpressionNode`s and so cannot
// use `mapChildren` (which also re-sorts map-valued child keys, perturbing the
// key order the deep-equal dedup below compares).
// ---------------------------------------------------------------------------

/** Single-child slots: integral bounds, aggregate body/predicate/Skolem key. */
const SCALAR_CHILDREN = ['lower', 'upper', 'expr', 'filter', 'key'] as const
/** Positional child arrays: operands and `makearray` values. */
const ARRAY_CHILDREN = ['args', 'values'] as const
/** String-keyed child maps: `table_lookup` axes and template-apply bindings. */
const MAP_CHILDREN = ['axes', 'bindings'] as const

/**
 * Component-scope one carried template body: prefix exactly the references
 * that name one of the OWNING component's locals.
 *
 * This is the "post-step-2 scoping" esm-libraries-spec §4.7.5 step 4 calls an
 * ordering requirement rather than a parenthetical. A body's FREE variables are
 * resolved in its owner's scope, so two components importing one library carry
 * byte-identical bodies whose free `inv_dx` denotes a DIFFERENT variable in
 * each; deduplicating them pre-scoping keeps one body that is correct for
 * neither. Scoping also makes them non-deep-equal, which is what routes them
 * into the collision rename and keeps an entry per component.
 *
 * Unlike a general namespacing pass (which prefixes every bare reference except
 * an explicit leave-alone set) this is a WHITELIST: a body legitimately
 * references its own formal `params`, loop symbols, and document-scoped index
 * sets, none of which are component locals and none of which may be prefixed.
 * The caller removes the template's `params` from `localNames` before calling.
 *
 * `bound` carries the loop symbols an enclosing `aggregate` binds; they shadow
 * locals (esm-spec §4.3.1) and are never prefixed. Shadowing is scoped to the
 * subtree.
 */
function scopeTemplateBody(
  expr: unknown,
  prefix: string,
  localNames: ReadonlySet<string>,
  bound: ReadonlySet<string>,
): unknown {
  if (expr === null || expr === undefined) return expr
  if (typeof expr === 'number' || typeof expr === 'boolean') return expr
  if (isNumericLiteral(expr)) return expr
  if (typeof expr === 'string') return scopeName(expr, prefix, localNames, bound)
  if (!isJsonExprNode(expr)) return expr

  // Binder symbols this node introduces shadow the owner's locals for the
  // whole subtree (`output_idx` entries and `ranges` keys).
  let frozen = bound
  if (expr.op === 'aggregate') {
    const localBound = new Set(bound)
    for (const sym of asStringList(expr.output_idx)) localBound.add(sym)
    for (const sym of mapKeys(expr.ranges)) localBound.add(sym)
    frozen = localBound
  }

  const out: Record<string, unknown> = { ...expr }
  for (const k of ARRAY_CHILDREN) {
    const child = expr[k]
    if (Array.isArray(child)) {
      out[k] = child.map((c) => scopeTemplateBody(c, prefix, localNames, frozen))
    }
  }
  for (const k of SCALAR_CHILDREN) {
    if (expr[k] === undefined) continue
    out[k] = scopeTemplateBody(expr[k], prefix, localNames, frozen)
  }
  for (const k of MAP_CHILDREN) {
    const child = expr[k]
    if (!isObj(child)) continue
    // Rebuilt in the SOURCE key order (never sorted): the dedup below compares
    // these objects structurally, and reordering keys is a gratuitous diff.
    const mapped: Record<string, unknown> = {}
    for (const mk of Object.keys(child)) {
      mapped[mk] = scopeTemplateBody(child[mk], prefix, localNames, frozen)
    }
    out[k] = mapped
  }

  // A `join` clause names its references as plain STRINGS rather than as child
  // expressions, so the child walk above never sees them (CONFORMANCE_SPEC
  // §5.5.6). Same whitelist gate, with THIS node's own binders excluded.
  if (Array.isArray(expr.join) && expr.join.length > 0) {
    const binders = new Set<string>([...asStringList(expr.output_idx), ...mapKeys(expr.ranges)])
    out.join = scopeJoin(expr.join, binders, prefix, localNames)
  }

  return out
}

/** The whitelist gate for a single reference string. */
function scopeName(
  name: string,
  prefix: string,
  localNames: ReadonlySet<string>,
  bound: ReadonlySet<string>,
): string {
  if (bound.has(name)) return name
  const dot = name.indexOf('.')
  if (dot >= 0) {
    // A dotted reference is prefixed iff its HEAD segment is an owner local.
    return localNames.has(name.slice(0, dot)) ? `${prefix}.${name}` : name
  }
  return localNames.has(name) ? `${prefix}.${name}` : name
}

/**
 * Prefix the plain-string references a `join` clause carries: an `on` key
 * column pair, and an `overlap` clause's `src_env` / `tgt_env` envelope
 * factors. `binders` are the loop symbols the owning node binds; they win over
 * `localNames`, because an index symbol is resolved against the node's own
 * ranges and prefixing it makes it resolve to nothing.
 *
 * Mirrors Python `flatten._namespace_join`.
 */
function scopeJoin(
  join: readonly unknown[],
  binders: ReadonlySet<string>,
  prefix: string,
  localNames: ReadonlySet<string>,
): unknown[] {
  const ns = (n: unknown): unknown =>
    typeof n === 'string' ? scopeName(n, prefix, localNames, binders) : n

  return join.map((clause) => {
    if (!isObj(clause)) return clause
    const next: Record<string, unknown> = { ...clause }
    if (Array.isArray(clause.on)) {
      next.on = clause.on.map((pair) => (Array.isArray(pair) ? pair.map(ns) : pair))
    }
    const overlap = clause.overlap
    if (isObj(overlap)) {
      const nextOverlap: Record<string, unknown> = { ...overlap }
      for (const side of ['src_env', 'tgt_env'] as const) {
        const factors = overlap[side]
        if (Array.isArray(factors)) nextOverlap[side] = factors.map(ns)
      }
      next.overlap = nextOverlap
    }
    return next
  })
}

/** The string entries of a JSON list field (`output_idx`), else empty. */
function asStringList(v: unknown): string[] {
  return Array.isArray(v) ? v.filter((s): s is string => typeof s === 'string') : []
}

/** The keys of a JSON map field (`ranges`), else empty. */
function mapKeys(v: unknown): string[] {
  return isObj(v) ? Object.keys(v) : []
}

/** The owning component's local names: declared variables ∪ subsystem keys. */
function componentLocals(component: unknown): Set<string> {
  const out = new Set<string>()
  if (!isObj(component)) return out
  for (const field of ['variables', 'subsystems'] as const) {
    const block = component[field]
    if (isObj(block)) for (const k of Object.keys(block)) out.add(k)
  }
  return out
}

/**
 * The MERGED expression-template registry of `file`'s flattened form
 * (esm-spec §9.6.4 rule 7, §10.7; esm-libraries-spec §4.7.5 step 4).
 *
 * Union of the per-component registries captured at load
 * (`EsmFile.componentTemplates`), in this order:
 *
 *  1. **Scope, then union.** Each MODEL block's bodies are component-scoped
 *     first ({@link scopeTemplateBody}), because the dedup below compares
 *     POST-scoping bodies. Reaction-system blocks pass through unscoped BY
 *     POLICY, mirroring the Julia and Python references: a rate-law reference
 *     is expanded eagerly at collect, so a reaction-system entry is never
 *     resolved against the post-flatten scope — it rides along so the
 *     reconstituted document round-trips.
 *  2. **Deep-equal dedup at first occurrence** — two components importing one
 *     stencil keep one entry under the bare name.
 *  3. **Collision rename** — a same-name entry whose occurrences are not all
 *     deep-equal renames to `<ComponentPath>.<name>` in EVERY owning
 *     component, and the rename propagates along the reference DAG (see
 *     `registryCollisionNames`) so no surviving body holds a reference the
 *     merged registry cannot resolve.
 *
 * `match` rules are excluded: only match-less templates are referenceable
 * (§9.6.2), so only they can be merged.
 *
 * Components are walked in DOCUMENT order (models in file order, then reaction
 * systems), which is what step 4's ordering rule requires and what makes
 * "first occurrence" mean the first occurrence in the file. The returned
 * object's KEY ORDER is part of the contract.
 *
 * Returns `{}` for a file carrying no `componentTemplates` — the common case,
 * and also the case of a binding that expanded every reference at load, for
 * which step 4's "Applicability" paragraph makes the requirement vacuous.
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

  // name -> [{path, decl}, ...] in document order.
  const byname = new Map<string, { path: string; decl: unknown }[]>()
  for (const compKey of orderedKeys) {
    const block = componentTemplates[compKey]
    if (!isObj(block)) continue
    const dot = compKey.indexOf('.')
    const section = dot >= 0 ? compKey.slice(0, dot) : compKey
    const cname = dot >= 0 ? compKey.slice(dot + 1) : ''
    const model = section === 'models' ? models[cname] : undefined
    const localNames = model === undefined ? new Set<string>() : componentLocals(model)

    for (const [tname, decl] of Object.entries(block)) {
      // Match rules are not referenceable, so not merged.
      if (isObj(decl) && decl.match !== undefined && decl.match !== null) continue

      let scoped = decl
      const body = isObj(decl) ? decl.body : undefined
      if (model !== undefined && body !== undefined && body !== null) {
        const params = new Set(asStringList((decl as Record<string, unknown>).params))
        const gate = new Set([...localNames].filter((n) => !params.has(n)))
        scoped = {
          ...(decl as Record<string, unknown>),
          body: scopeTemplateBody(body, cname, gate, new Set<string>()),
        }
      }
      const occurrences = byname.get(tname)
      if (occurrences === undefined) byname.set(tname, [{ path: cname, decl: scoped }])
      else occurrences.push({ path: cname, decl: scoped })
    }
  }

  const collide = registryCollisionNames(byname)
  const merged: Record<string, unknown> = {}
  const rename = new Map<string, Record<string, string>>() // path => (old => new)
  // Insertion order of `byname` IS document order, and a plain object preserves
  // string-key insertion order — so this loop fixes the contractual key order.
  for (const [name, occurrences] of byname) {
    if (collide.has(name)) {
      for (const { path, decl } of occurrences) {
        const newName = `${path}.${name}`
        merged[newName] = decl
        let perOwner = rename.get(path)
        if (perOwner === undefined) rename.set(path, (perOwner = {}))
        perOwner[name] = newName
      }
    } else {
      // Deep-equal dedup at first occurrence.
      merged[name] = occurrences[0]!.decl
    }
  }

  // A renamed body's own nested references follow ITS OWNER's map, so a
  // per-owner wrapper reaches its owner's leaf and never the other owner's.
  for (const perOwner of rename.values()) {
    for (const newName of Object.values(perOwner)) {
      if (Object.prototype.hasOwnProperty.call(merged, newName)) {
        merged[newName] = renameApplyRefs(merged[newName], perOwner)
      }
    }
  }
  return merged
}
