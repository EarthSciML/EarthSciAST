/**
 * Coupling-library files and `coupling_import` role binding (esm-spec §10.9–§10.11).
 *
 * A *coupling-library file* is a document whose payload is a top-level
 * `coupling_roles` map plus a role-scoped `coupling` array. An assembly reuses
 * it with a `{ type: "coupling_import", ref, bind }` coupling entry: at flatten
 * the import expands into concrete `variable_map` / `couple` / `operator_compose`
 * / `event` edges by substituting the bound actual component for every
 * role-named top-level segment (the §10.10.2 occurrence surface).
 *
 * Expansion runs *inside* flatten (esm-spec §10.10.3), after subsystem mounting
 * (which happens at load, §2.1b) and before the coupling-rule step, so every
 * `bind` target resolves against fully-mounted components. The `coupling_import`
 * source entry is preserved for round-trip; only the flattened system carries
 * the expanded edges.
 */

import type { EsmFile, CouplingEntry, CouplingImport, Expression } from './types.js'
import { numericValue } from './numeric-literal.js'
import { deepClone, isObject } from './object-utils.js'
import { isRemoteRef, joinPath } from './path-utils.js'
import { ERROR_CODES } from './errors.js'
import { ExpressionTemplateError } from './lower-expression-templates.js'

/**
 * The `coupling` entry `type` tag identifying a coupling-library import
 * (esm-spec §10.10). Used both to detect imports in an assembly and to reject a
 * nested import inside a library edge (§10.9 forbids layering).
 */
const COUPLING_IMPORT_TYPE = 'coupling_import'

/** Payload keys a coupling-library file MUST NOT declare (esm-spec §10.9). */
const LIBRARY_FORBIDDEN_KEYS = [
  'models',
  'reaction_systems',
  'data_loaders',
  'domain',
  'index_sets',
  'metaparameters',
  'expression_templates',
] as const

/** Coupling-entry types a library edge MAY carry (esm-spec §10.9). */
const ROLE_BEARING_TYPES = new Set(['variable_map', 'couple', 'operator_compose', 'event'])

/** Options controlling how `coupling_import` refs are resolved at flatten. */
export interface CouplingImportOptions {
  /** Directory the import `ref`s resolve against. Defaults to '.'. */
  basePath?: string
  /**
   * Resolve a `ref` string to a parsed coupling-library document. Defaults to a
   * synchronous Node `fs` reader. Tests may supply an in-memory resolver.
   */
  loadRef?: (ref: string, basePath: string) => unknown
}

/**
 * True when `raw` has the coupling-library-file FORM (top-level
 * `coupling_roles`, esm-spec §10.9). Presence of that key is the sole positive
 * identifier of the file kind; purity is checked separately at the import edge.
 */
export function isCouplingLibraryDoc(raw: unknown): boolean {
  return isObject(raw) && 'coupling_roles' in raw
}

// ---------------------------------------------------------------------------
// Reference rewriting — the §10.10.2 occurrence surface
// ---------------------------------------------------------------------------

type RefFn = (ref: string) => string

function headSegment(ref: string): string {
  const dot = ref.indexOf('.')
  return dot === -1 ? ref : ref.slice(0, dot)
}

/**
 * Replace the top-level segment of a scoped reference with its bound actual.
 * `"Fuel.w_0"` under `{ Fuel: "FuelModelLookup" }` → `"FuelModelLookup.w_0"`;
 * a dotted bind value (`{ Fuel: "Parent.Child" }`) → `"Parent.Child.w_0"`.
 * A segment not in `bind` is returned unchanged (e.g. bare `"t"`, literals).
 */
function rewriteScopedRef(ref: string, bind: Record<string, string>): string {
  const head = headSegment(ref)
  const actual = bind[head]
  return actual === undefined ? ref : actual + ref.slice(head.length)
}

/**
 * Map a string array's elements through `fn`, passing any non-string element
 * (never a valid role ref) through untouched — mirrors the per-element `typeof
 * === 'string'` guards on the scalar ref fields, so a malformed array cannot
 * feed a non-string into a ref function.
 */
function mapStringRefs(arr: readonly unknown[], fn: RefFn): unknown[] {
  return arr.map((s) => (typeof s === 'string' ? fn(s) : s))
}

/** Rewrite every scoped reference inside an Expression tree, mutating in place. */
function rewriteExprInPlace(expr: unknown, fn: RefFn): unknown {
  if (numericValue(expr as Expression) !== undefined) return expr
  if (typeof expr === 'string') return fn(expr)
  if (!isObject(expr)) return expr
  const node = expr
  if (Array.isArray(node.args)) {
    node.args = (node.args as unknown[]).map((a) => rewriteExprInPlace(a, fn))
  }
  // `apply_expression_template` bindings VALUES are free-variable targets
  // (esm-spec §10.10.2) — Expressions in their own right.
  if (node.op === 'apply_expression_template' && isObject(node.bindings)) {
    const b = node.bindings
    for (const k of Object.keys(b)) b[k] = rewriteExprInPlace(b[k], fn)
  }
  return node
}

/**
 * Apply `structFn` to every structural system/scoped reference of a coupling
 * entry and `exprFn` to every scoped reference inside its Expression fields
 * (esm-spec §10.10.2). Mutates `entry` in place (callers pass a clone). Its
 * read-only twin {@link forEachEntryRef} MUST visit the same occurrence set.
 */
function rewriteEntryInPlace(
  entry: Record<string, unknown>,
  structFn: RefFn,
  exprFn: RefFn,
): void {
  switch (entry.type) {
    case 'variable_map':
      if (typeof entry.from === 'string') entry.from = structFn(entry.from)
      if (typeof entry.to === 'string') entry.to = structFn(entry.to)
      if (isObject(entry.transform)) entry.transform = rewriteExprInPlace(entry.transform, exprFn)
      break

    case 'couple':
      if (Array.isArray(entry.systems)) entry.systems = mapStringRefs(entry.systems, structFn)
      if (isObject(entry.connector) && Array.isArray(entry.connector.equations)) {
        for (const eq of entry.connector.equations as unknown[]) {
          if (!isObject(eq)) continue
          if (typeof eq.from === 'string') eq.from = structFn(eq.from)
          if (typeof eq.to === 'string') eq.to = structFn(eq.to)
          if (eq.expression !== undefined) eq.expression = rewriteExprInPlace(eq.expression, exprFn)
        }
      }
      break

    case 'operator_compose':
      if (Array.isArray(entry.systems)) entry.systems = mapStringRefs(entry.systems, structFn)
      if (isObject(entry.translate)) {
        const next: Record<string, unknown> = {}
        for (const [k, v] of Object.entries(entry.translate)) {
          const nk = structFn(k)
          if (typeof v === 'string') next[nk] = structFn(v)
          else if (isObject(v)) {
            const vv = { ...v }
            if (typeof vv.var === 'string') vv.var = structFn(vv.var)
            next[nk] = vv
          } else next[nk] = v
        }
        entry.translate = next
      }
      break

    case 'event': {
      if (Array.isArray(entry.conditions)) {
        entry.conditions = (entry.conditions as unknown[]).map((c) => rewriteExprInPlace(c, exprFn))
      }
      const rewriteAffect = (a: unknown): unknown => {
        if (!isObject(a)) return a
        if (typeof a.lhs === 'string') a.lhs = structFn(a.lhs)
        if (a.rhs !== undefined) a.rhs = rewriteExprInPlace(a.rhs, exprFn)
        return a
      }
      if (Array.isArray(entry.affects)) entry.affects = (entry.affects as unknown[]).map(rewriteAffect)
      if (Array.isArray(entry.affect_neg)) {
        entry.affect_neg = (entry.affect_neg as unknown[]).map(rewriteAffect)
      }
      if (isObject(entry.trigger) && entry.trigger.type === 'condition' && entry.trigger.expression !== undefined) {
        entry.trigger.expression = rewriteExprInPlace(entry.trigger.expression, exprFn)
      }
      if (isObject(entry.functional_affect)) {
        const fa = entry.functional_affect
        for (const key of ['read_vars', 'read_params', 'modified_params']) {
          if (Array.isArray(fa[key])) fa[key] = mapStringRefs(fa[key], structFn)
        }
      }
      if (Array.isArray(entry.discrete_parameters)) {
        entry.discrete_parameters = mapStringRefs(entry.discrete_parameters, structFn)
      }
      break
    }
  }
}

/** A read-only callback receiving one scoped reference. */
type RefVisit = (ref: string) => void

/**
 * Read-only twin of {@link rewriteExprInPlace}: visit every scoped-reference
 * string inside an Expression tree without mutating it.
 */
function forEachExprRef(expr: unknown, visit: RefVisit): void {
  if (numericValue(expr as Expression) !== undefined) return
  if (typeof expr === 'string') {
    visit(expr)
    return
  }
  if (!isObject(expr)) return
  if (Array.isArray(expr.args)) {
    for (const a of expr.args) forEachExprRef(a, visit)
  }
  if (expr.op === 'apply_expression_template' && isObject(expr.bindings)) {
    const b = expr.bindings
    for (const k of Object.keys(b)) forEachExprRef(b[k], visit)
  }
}

/**
 * Read-only twin of {@link rewriteEntryInPlace}: visit every structural ref
 * (`structVisit`) and every Expression-embedded ref (`exprVisit`) of a coupling
 * entry WITHOUT cloning or mutating it. Its traversal is kept in lockstep with
 * `rewriteEntryInPlace` so both agree on which occurrences are §10.10.2 role
 * sites; only this read path is needed to enumerate the roles an edge names.
 */
function forEachEntryRef(
  entry: Record<string, unknown>,
  structVisit: RefVisit,
  exprVisit: RefVisit,
): void {
  const visitSystems = (arr: readonly unknown[]) => {
    for (const s of arr) if (typeof s === 'string') structVisit(s)
  }
  switch (entry.type) {
    case 'variable_map':
      if (typeof entry.from === 'string') structVisit(entry.from)
      if (typeof entry.to === 'string') structVisit(entry.to)
      if (isObject(entry.transform)) forEachExprRef(entry.transform, exprVisit)
      break

    case 'couple':
      if (Array.isArray(entry.systems)) visitSystems(entry.systems)
      if (isObject(entry.connector) && Array.isArray(entry.connector.equations)) {
        for (const eq of entry.connector.equations as unknown[]) {
          if (!isObject(eq)) continue
          if (typeof eq.from === 'string') structVisit(eq.from)
          if (typeof eq.to === 'string') structVisit(eq.to)
          if (eq.expression !== undefined) forEachExprRef(eq.expression, exprVisit)
        }
      }
      break

    case 'operator_compose':
      if (Array.isArray(entry.systems)) visitSystems(entry.systems)
      if (isObject(entry.translate)) {
        for (const [k, v] of Object.entries(entry.translate)) {
          structVisit(k)
          if (typeof v === 'string') structVisit(v)
          else if (isObject(v) && typeof v.var === 'string') structVisit(v.var)
        }
      }
      break

    case 'event': {
      if (Array.isArray(entry.conditions)) {
        for (const c of entry.conditions) forEachExprRef(c, exprVisit)
      }
      const visitAffect = (a: unknown): void => {
        if (!isObject(a)) return
        if (typeof a.lhs === 'string') structVisit(a.lhs)
        if (a.rhs !== undefined) forEachExprRef(a.rhs, exprVisit)
      }
      if (Array.isArray(entry.affects)) entry.affects.forEach(visitAffect)
      if (Array.isArray(entry.affect_neg)) entry.affect_neg.forEach(visitAffect)
      if (isObject(entry.trigger) && entry.trigger.type === 'condition' && entry.trigger.expression !== undefined) {
        forEachExprRef(entry.trigger.expression, exprVisit)
      }
      if (isObject(entry.functional_affect)) {
        const fa = entry.functional_affect
        for (const key of ['read_vars', 'read_params', 'modified_params']) {
          if (Array.isArray(fa[key])) visitSystems(fa[key])
        }
      }
      if (Array.isArray(entry.discrete_parameters)) visitSystems(entry.discrete_parameters)
      break
    }
  }
}

/**
 * Collect the top-level role segments a library edge references. Structural
 * ref fields (systems[], from/to, translate keys, event var lists) always name
 * a role; Expression strings name a role only when they are scoped references
 * (contain a dot) — bare Expression operands like `"t"` are incidental.
 * Purely READS the edge (no clone, no mutation) via {@link forEachEntryRef}.
 */
function collectRoleSegments(edge: unknown): Set<string> {
  const seen = new Set<string>()
  if (!isObject(edge)) return seen
  forEachEntryRef(
    edge,
    (ref) => {
      seen.add(headSegment(ref))
    },
    (ref) => {
      if (ref.includes('.')) seen.add(headSegment(ref))
    },
  )
  return seen
}

// ---------------------------------------------------------------------------
// Ref loading (synchronous)
//
// Path joining + remote-ref detection are the shared `./path-utils.js` helpers
// (`joinPath`, `isRemoteRef`). The synchronous file read stays LOCAL rather
// than delegating to path-utils' `readFileSyncNode`: its two failure paths
// below emit coupling-specific `coupling_import_unresolved` diagnostics (the
// "unavailable environment" and "file not found" wordings), which are distinct
// from the generic reader throw and are part of the coupling contract.
//
// Delta from the removed local `joinPath`: coupling's third variant stripped
// ALL trailing slashes and returned a bare `ref` on an empty base, whereas the
// shared form collapses a single trailing slash and returns `/ref` on an empty
// base. They agree for every basePath this resolver is handed ('.', a real
// directory) and diverge only on multi-slash / empty bases, which never occur
// here — so the shared form is adopted.
// ---------------------------------------------------------------------------

function defaultLoadRef(ref: string, basePath: string): unknown {
  if (isRemoteRef(ref)) {
    throw new ExpressionTemplateError(
      ERROR_CODES.COUPLING_IMPORT_UNRESOLVED,
      `remote coupling_import ref '${ref}' cannot be loaded synchronously; download the file and import it by local path`,
    )
  }
  const proc = (globalThis as { process?: { getBuiltinModule?: (id: string) => unknown } }).process
  const getBuiltin = proc?.getBuiltinModule
  if (typeof getBuiltin !== 'function') {
    throw new ExpressionTemplateError(
      ERROR_CODES.COUPLING_IMPORT_UNRESOLVED,
      `synchronous file access is unavailable in this environment; supply CouplingImportOptions.loadRef (ref '${ref}')`,
    )
  }
  const fs = getBuiltin.call(proc, 'node:fs') as { readFileSync: (p: string, enc: string) => string }
  const path = joinPath(basePath, ref)
  let content: string
  try {
    content = fs.readFileSync(path, 'utf8')
  } catch (e) {
    throw new ExpressionTemplateError(
      ERROR_CODES.COUPLING_IMPORT_UNRESOLVED,
      `coupling-library file not found or unreadable: ${path} (from ref '${ref}'): ${e instanceof Error ? e.message : String(e)}`,
    )
  }
  try {
    return JSON.parse(content)
  } catch (e) {
    throw new ExpressionTemplateError(
      ERROR_CODES.COUPLING_IMPORT_UNRESOLVED,
      `coupling-library ref '${path}' is not valid JSON: ${e instanceof Error ? e.message : String(e)}`,
    )
  }
}

// ---------------------------------------------------------------------------
// Library validation + expansion
// ---------------------------------------------------------------------------

/**
 * Validate a resolved coupling-library document and expand one `coupling_import`
 * entry into its concrete edges, bound to `bind`. Raises the esm-spec §10.11
 * diagnostics.
 */
function expandOne(
  lib: unknown,
  ref: string,
  bind: Record<string, string>,
  file: EsmFile,
): CouplingEntry[] {
  if (!isCouplingLibraryDoc(lib)) {
    throw new ExpressionTemplateError(
      ERROR_CODES.COUPLING_IMPORT_NOT_LIBRARY,
      `coupling_import ref '${ref}' lacks top-level \`coupling_roles\` — not a coupling-library file (esm-spec §10.9)`,
    )
  }
  const doc = lib as Record<string, unknown>

  // Purity (esm-spec §10.9).
  for (const k of LIBRARY_FORBIDDEN_KEYS) {
    if (k in doc) {
      throw new ExpressionTemplateError(
        ERROR_CODES.COUPLING_LIBRARY_ILLEGAL_PAYLOAD,
        `coupling-library '${ref}' declares \`${k}\` — a coupling library is nothing but roles + wiring (esm-spec §10.9)`,
      )
    }
  }

  const roles = isObject(doc.coupling_roles) ? Object.keys(doc.coupling_roles) : []
  if (roles.length === 0) {
    throw new ExpressionTemplateError(
      ERROR_CODES.COUPLING_LIBRARY_ILLEGAL_PAYLOAD,
      `coupling-library '${ref}' declares no roles (esm-spec §10.9: \`coupling_roles\` is required, non-empty)`,
    )
  }
  const edges = Array.isArray(doc.coupling) ? (doc.coupling as unknown[]) : []
  if (edges.length === 0) {
    throw new ExpressionTemplateError(
      ERROR_CODES.COUPLING_LIBRARY_ILLEGAL_PAYLOAD,
      `coupling-library '${ref}' has an empty \`coupling\` array (esm-spec §10.9: required, non-empty)`,
    )
  }

  // Edge-type + role-scope checks over the declared roles.
  const roleSet = new Set(roles)
  const usedRoles = new Set<string>()
  for (const edge of edges) {
    if (!isObject(edge)) continue
    const type = edge.type
    if (type === COUPLING_IMPORT_TYPE) {
      throw new ExpressionTemplateError(
        ERROR_CODES.COUPLING_LIBRARY_NESTED_IMPORT,
        `coupling-library '${ref}' contains a nested coupling_import (v1 forbids layering, esm-spec §10.9)`,
      )
    }
    if (type === 'callback' || 'expression_template_imports' in edge) {
      throw new ExpressionTemplateError(
        ERROR_CODES.COUPLING_LIBRARY_ILLEGAL_PAYLOAD,
        `coupling-library '${ref}' edge of type '${String(type)}' is not role-substitutable (no callback entries or edge-level expression_template_imports, esm-spec §10.9)`,
      )
    }
    if (typeof type !== 'string' || !ROLE_BEARING_TYPES.has(type)) {
      throw new ExpressionTemplateError(
        ERROR_CODES.COUPLING_LIBRARY_ILLEGAL_PAYLOAD,
        `coupling-library '${ref}' contains an unsupported edge type '${String(type)}' (esm-spec §10.9)`,
      )
    }
    for (const seg of collectRoleSegments(edge)) {
      if (!roleSet.has(seg)) {
        throw new ExpressionTemplateError(
          ERROR_CODES.COUPLING_EDGE_UNKNOWN_ROLE,
          `coupling-library '${ref}': edge references '${seg}', which is not a declared role (esm-spec §10.9)`,
        )
      }
      usedRoles.add(seg)
    }
  }
  for (const role of roles) {
    if (!usedRoles.has(role)) {
      throw new ExpressionTemplateError(
        ERROR_CODES.COUPLING_ROLE_UNUSED,
        `coupling-library '${ref}': role '${role}' is declared but referenced by no edge (esm-spec §10.9)`,
      )
    }
  }

  // Binding — total and checked (esm-spec §10.10.1).
  for (const key of Object.keys(bind)) {
    if (!roleSet.has(key)) {
      throw new ExpressionTemplateError(
        ERROR_CODES.COUPLING_IMPORT_UNKNOWN_ROLE,
        `coupling_import ref '${ref}': bind key '${key}' is not a declared role (esm-spec §10.10.1)`,
      )
    }
  }
  for (const role of roles) {
    if (!(role in bind)) {
      throw new ExpressionTemplateError(
        ERROR_CODES.COUPLING_IMPORT_ROLE_UNBOUND,
        `coupling_import ref '${ref}': role '${role}' has no bind entry (binding is total, esm-spec §10.10.1)`,
      )
    }
    if (!resolvesToComponent(file, bind[role])) {
      throw new ExpressionTemplateError(
        ERROR_CODES.COUPLING_IMPORT_BIND_NOT_A_COMPONENT,
        `coupling_import ref '${ref}': bind '${role}' -> '${bind[role]}' does not resolve to a component (esm-spec §10.10.1)`,
      )
    }
  }

  // Expand: substitute bound actuals for role names, one simultaneous rewrite.
  const rw: RefFn = (r) => rewriteScopedRef(r, bind)
  const expanded: CouplingEntry[] = []
  for (const edge of edges) {
    const clone = deepClone(edge) as Record<string, unknown>
    rewriteEntryInPlace(clone, rw, rw)
    expanded.push(clone as unknown as CouplingEntry)
  }
  return expanded
}

/**
 * Resolve a `bind` value as a component path (esm-spec §10.10.1) — a system or
 * loader node, walking `models`/`reaction_systems`/`data_loaders` then nested
 * `subsystems`, never terminating on a variable.
 */
function resolvesToComponent(file: EsmFile, value: string): boolean {
  const segs = value.split('.')
  const top = segs[0]
  const f = file as unknown as Record<string, Record<string, unknown> | undefined>
  let node: unknown =
    f.models?.[top] ?? f.reaction_systems?.[top] ?? f.data_loaders?.[top]
  if (!isObject(node)) return false
  for (let i = 1; i < segs.length; i++) {
    const subs = node.subsystems
    if (!isObject(subs)) return false
    node = subs[segs[i]]
    if (!isObject(node)) return false
  }
  return true
}

/**
 * Expand every `coupling_import` entry in `file.coupling` into concrete edges,
 * splicing them in the position of the import entry (esm-spec §10.10.3).
 * Returns the effective coupling array, or `undefined` if the file has no
 * `coupling` block. Non-import entries pass through untouched; a file with no
 * `coupling_import` entries needs no `options` and returns `file.coupling`
 * verbatim.
 */
export function expandCouplingImports(
  file: EsmFile,
  options: CouplingImportOptions = {},
): CouplingEntry[] | undefined {
  const coupling = file.coupling
  if (!coupling) return undefined
  if (!coupling.some((e) => isObject(e) && (e as { type?: unknown }).type === COUPLING_IMPORT_TYPE)) {
    return coupling
  }
  const loadRef = options.loadRef ?? defaultLoadRef
  const basePath = options.basePath ?? '.'
  const out: CouplingEntry[] = []
  for (const entry of coupling) {
    if ((entry as { type?: unknown }).type !== COUPLING_IMPORT_TYPE) {
      out.push(entry)
      continue
    }
    const imp = entry as CouplingImport
    // `ref`/`bind` are schema-constrained (`ref` a string, `bind` a string→
    // string map) and this runs post-schema-validation, so the fallbacks below
    // are DEFENSIVE only — a well-formed document never exercises them. They
    // are intentionally left as silent coercions rather than a new up-front
    // diagnostic so no pinned load-error code/message is disturbed; a malformed
    // `ref` ('') or dropped non-string bind surfaces as the existing
    // downstream `coupling_import_unresolved` / role-binding diagnostics.
    const ref = typeof imp.ref === 'string' ? imp.ref : ''
    const bind: Record<string, string> = {}
    if (isObject(imp.bind)) {
      for (const [k, v] of Object.entries(imp.bind)) if (typeof v === 'string') bind[k] = v
    }
    let lib: unknown
    try {
      lib = loadRef(ref, basePath)
    } catch (e) {
      if (e instanceof ExpressionTemplateError) throw e
      throw new ExpressionTemplateError(
        ERROR_CODES.COUPLING_IMPORT_UNRESOLVED,
        `coupling_import ref '${ref}' failed to load: ${e instanceof Error ? e.message : String(e)}`,
      )
    }
    for (const expandedEdge of expandOne(lib, ref, bind, file)) out.push(expandedEdge)
  }
  return out
}
