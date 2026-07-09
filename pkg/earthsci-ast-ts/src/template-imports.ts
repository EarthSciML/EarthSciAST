/**
 * Load-time resolution for esm-spec §9.7: template-library files, cross-file
 * `expression_template_imports`, and load-time `metaparameters`
 * (docs/content/rfcs/template-library-imports.md; esm-libraries-spec §2.1c).
 *
 * Everything here resolves BEFORE the §9.6.3 rewrite fixpoint
 * (`lowerExpressionTemplates`) and before any validator sees the tree.
 * Per document the order is innermost-first (esm-spec §9.7.6):
 *
 *   1. resolve imports (recursively, depth-first post-order, instantiating the
 *      imported subtree with the edge's metaparameter `bindings` at each edge);
 *   2. merge imported `index_sets` into the document registry;
 *   3. close and fold this document's metaparameters (loader-API bindings,
 *      then defaults; `metaparameter_unbound` if still open);
 *   4. §9.7.3 registration-time body composition (`composeTemplateBodies`,
 *      invoked per component from `lowerExpressionTemplates`);
 *   5. the §9.6.3 fixpoint on fully-concrete trees.
 *
 * Round-trip is Option A: `expression_template_imports`, `metaparameters`, and
 * top-level `expression_templates` do not survive `parse → emit`; the emitted
 * form is the expanded, folded document.
 *
 * All diagnostics are raised as `ExpressionTemplateError` with the stable
 * §9.6.6 codes so they are machine-checkable across bindings. Mirrors the
 * Julia reference implementation (`EarthSciAST.jl/src/template_imports.jl`).
 *
 * File access is synchronous (imports resolve inside the synchronous
 * `load()`): under Node the built-in `fs` module is obtained via
 * `process.getBuiltinModule`; other environments must supply a `readFile`
 * hook. Remote (`http(s)://`) template-library refs are not fetchable from a
 * synchronous loader and are rejected as `template_import_unresolved`.
 */

import {
  ExpressionTemplateError,
  composeTemplateBodies,
  deepEqual,
  rejectExpressionTemplatesPreV04,
  validateTemplates,
} from './lower-expression-templates.js'
import { isNumericLiteral } from './numeric-literal.js'

type Json = unknown
type JsonObject = Record<string, unknown>

/** Schema-error shape accepted from the host's schema validator. */
export interface TemplateSchemaError {
  path: string
  message: string
}

/** Options threaded through §9.7 resolution. */
export interface TemplateResolveOptions {
  /**
   * Loader-API metaparameter bindings for the ROOT document
   * (esm-spec §9.7.6 binding site 4). Already-closed edge bindings win;
   * API bindings beat `default`s.
   */
  metaparameters?: Record<string, number> | undefined
  /**
   * Synchronous file reader for import refs. Defaults to Node's
   * `fs.readFileSync` (via `process.getBuiltinModule`); browser hosts must
   * supply their own.
   */
  readFile?: ((path: string) => string) | undefined
  /**
   * Schema validator applied to each import target (a target failing schema
   * validation is `template_import_unresolved`, mirroring the Julia
   * reference). Supplied by `load()`; optional for direct/raw use.
   */
  validateSchema?: ((raw: unknown) => TemplateSchemaError[]) | undefined
}

const COMPONENT_KINDS = ['models', 'reaction_systems'] as const

// A template-library file MUST NOT declare any of these (esm-spec §9.7.1).
const LIBRARY_FORBIDDEN_KEYS = [
  'models',
  'reaction_systems',
  'data_loaders',
  'coupling',
  'domain',
] as const

function isObject(v: unknown): v is JsonObject {
  return typeof v === 'object' && v !== null && !Array.isArray(v) && !isNumericLiteral(v)
}

/** Deep clone preserving tagged `NumericLiteral` leaves by reference. */
function deepClone<T>(v: T): T {
  if (v === null || v === undefined) return v
  if (isNumericLiteral(v)) return v
  if (Array.isArray(v)) return v.map(deepClone) as unknown as T
  if (typeof v === 'object') {
    const out: JsonObject = {}
    for (const k of Object.keys(v as object)) out[k] = deepClone((v as JsonObject)[k])
    return out as unknown as T
  }
  return v
}

/**
 * Read an INTEGER literal (plain JSON integer or an int-tagged
 * `NumericLiteral` leaf from canonical mode). Returns `undefined` for
 * anything else. Note the JS parser caveat: plain `JSON.parse` narrows
 * integral floats (`2.0` → `2`), so those are indistinguishable from
 * integers here — shared fixtures avoid integral-float literals.
 */
function asInt(v: unknown): number | undefined {
  if (typeof v === 'number' && Number.isInteger(v)) return v
  if (isNumericLiteral(v) && v.kind === 'int') return v.value
  return undefined
}

// ---------------------------------------------------------------------------
// Spec-version gate (esm-spec §9.6.5)
// ---------------------------------------------------------------------------

/**
 * `expression_template_imports`, top-level `expression_templates`
 * (template-library files), and `metaparameters` arrive at `esm: 0.8.0`;
 * files declaring an earlier version that carry any of them are rejected
 * with `template_import_version_too_old` (esm-spec §9.6.5). Mirrors
 * `rejectExpressionTemplatesPreV04` for the §9.7 constructs.
 */
export function rejectTemplateImportsPreV08(view: unknown): void {
  if (!isObject(view)) return
  const esm = view.esm
  if (typeof esm !== 'string') return
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(esm)
  if (!m) return
  const major = Number(m[1])
  const minor = Number(m[2])
  if (!(major === 0 && minor < 8)) return

  const offences: string[] = []
  if ('expression_templates' in view) offences.push('/expression_templates')
  if ('metaparameters' in view) offences.push('/metaparameters')
  if ('expression_template_imports' in view) offences.push('/expression_template_imports')
  for (const compKind of COMPONENT_KINDS) {
    const comps = view[compKind]
    if (!isObject(comps)) continue
    for (const [cname, comp] of Object.entries(comps)) {
      if (isObject(comp) && 'expression_template_imports' in comp) {
        offences.push(`/${compKind}/${cname}/expression_template_imports`)
      }
    }
  }
  if (offences.length === 0) return
  throw new ExpressionTemplateError(
    'template_import_version_too_old',
    `expression_template_imports / top-level expression_templates / metaparameters require esm >= 0.8.0; file declares ${esm}. Offending paths: ${offences.join(', ')}`,
  )
}

/**
 * True when `raw` has the template-library-file FORM (top-level
 * `expression_templates`, esm-spec §9.7.1). Purity (no models / reaction
 * systems / loaders / coupling / domain) is checked separately at import
 * edges.
 */
export function isTemplateLibraryDoc(raw: unknown): boolean {
  return isObject(raw) && 'expression_templates' in raw
}

// ---------------------------------------------------------------------------
// Metaparameters (esm-spec §9.7.6)
// ---------------------------------------------------------------------------

function requireInt(v: unknown, ctx: string): number {
  const i = asInt(v)
  if (i === undefined || typeof v === 'boolean') {
    throw new ExpressionTemplateError(
      'metaparameter_type_error',
      `${ctx}: value ${JSON.stringify(v)} is not an integer (esm-spec §9.7.6)`,
    )
  }
  return i
}

function collectMetaparamDecls(raw: unknown, origin: string): JsonObject {
  const out: JsonObject = {}
  if (!isObject(raw)) return out
  const mp = raw.metaparameters
  if (mp === undefined || mp === null) return out
  if (!isObject(mp)) {
    throw new ExpressionTemplateError(
      'metaparameter_type_error',
      `${origin}: \`metaparameters\` must be an object`,
    )
  }
  for (const [name, v] of Object.entries(mp)) {
    if (!isObject(v)) {
      throw new ExpressionTemplateError(
        'metaparameter_type_error',
        `${origin}: metaparameters.${name} must be an object with \`type: "integer"\``,
      )
    }
    if (String(v.type) !== 'integer') {
      throw new ExpressionTemplateError(
        'metaparameter_type_error',
        `${origin}: metaparameters.${name}: \`type\` must be "integer" (the only kind)`,
      )
    }
    if (v.default !== undefined && v.default !== null) {
      requireInt(v.default, `${origin}: metaparameters.${name} default`)
    }
    out[name] = deepClone(v)
  }
  return out
}

// Keys whose VALUES are never expression positions: metaparameter names are
// substituted as bare variable-reference strings, so structural string fields
// must not be rewritten. Template `params` shadowing is handled separately in
// `substituteMetaparamsDecl`.
const META_SUBST_SKIP_KEYS = new Set<string>([
  'metadata',
  'params',
  'type',
  'units',
  'kind',
  'description',
  'name',
  'wrt',
  'expression_template_imports',
  'metaparameters',
  'only',
  // `where` match-scoping constraints (esm-spec §9.6.1) carry index-set
  // NAMES, a structural namespace — never expression positions.
  'where',
])

/**
 * Substitute closed metaparameter names — appearing as bare strings, the
 * variable-reference surface syntax — with their integer values, everywhere
 * except the `META_SUBST_SKIP_KEYS` structural fields (esm-spec §9.7.6:
 * expression-position substitution; no folding here).
 */
function substituteMetaparams(x: Json, values: Record<string, Json>): Json {
  if (typeof x === 'string') {
    return Object.prototype.hasOwnProperty.call(values, x) ? values[x] : x
  }
  if (Array.isArray(x)) {
    return x.map((v) => substituteMetaparams(v, values))
  }
  if (isObject(x)) {
    const out: JsonObject = {}
    for (const k of Object.keys(x)) {
      out[k] = META_SUBST_SKIP_KEYS.has(k) ? deepClone(x[k]) : substituteMetaparams(x[k], values)
    }
    return out
  }
  return x
}

/**
 * Metaparameter substitution over one `expression_templates` entry: the
 * template's own `params` shadow like-named metaparameters inside its `body`
 * and `match` (a param is the inner binder; substitution must not capture it).
 */
function substituteMetaparamsDecl(decl: Json, values: Record<string, Json>): Json {
  let shadowed = values
  if (isObject(decl) && Array.isArray(decl.params)) {
    const params = decl.params
    if (params.some((p) => Object.prototype.hasOwnProperty.call(values, String(p)))) {
      shadowed = { ...values }
      for (const p of params) delete shadowed[String(p)]
    }
  }
  return substituteMetaparams(decl, shadowed)
}

const INT64_MIN = -(2n ** 63n)
const INT64_MAX = 2n ** 63n - 1n

function checkedInt64(v: bigint, ctx: string): bigint {
  if (v < INT64_MIN || v > INT64_MAX) {
    throw new ExpressionTemplateError(
      'metaparameter_type_error',
      `${ctx}: 64-bit integer overflow while folding a metaparameter expression`,
    )
  }
  return v
}

/**
 * Fold a metaparameter expression (integer literal, name, or `{op, args}`
 * over `+ - * /`) to a concrete integer with exact 64-bit arithmetic
 * (esm-spec §9.7.6; BigInt-backed, range-checked against Int64). Returns
 * `null` when the expression still contains a bare name (an open
 * metaparameter awaiting a later binding site, or a template-param slot
 * inside a rule body) — the site is left symbolic for a later pass. Throws
 * `metaparameter_type_error` for a non-integer literal, an op outside
 * `+ - * /` over concrete args, inexact division, or 64-bit overflow.
 */
function tryFold(x: Json, ctx: string): bigint | null {
  const i = asInt(x)
  if (i !== undefined && typeof x !== 'boolean') return BigInt(i)
  if (typeof x === 'string') return null
  if (typeof x === 'number' || isNumericLiteral(x)) {
    throw new ExpressionTemplateError(
      'metaparameter_type_error',
      `${ctx}: non-integer literal ${JSON.stringify(isNumericLiteral(x) ? x.value : x)} in a structural integer site (esm-spec §9.7.6)`,
    )
  }
  if (!isObject(x)) {
    throw new ExpressionTemplateError(
      'metaparameter_type_error',
      `${ctx}: invalid metaparameter expression (expected integer, name, or {op, args})`,
    )
  }
  const opRaw = x.op
  const args = x.args
  if (opRaw === undefined || !Array.isArray(args) || args.length === 0) {
    throw new ExpressionTemplateError(
      'metaparameter_type_error',
      `${ctx}: invalid metaparameter expression (expected {op: +|-|*|/, args: [...]})`,
    )
  }
  const vals = args.map((a) => tryFold(a, ctx))
  if (vals.some((v) => v === null)) return null
  const ivals = vals as bigint[]
  const op = String(opRaw)
  if (!['+', '-', '*', '/'].includes(op)) {
    throw new ExpressionTemplateError(
      'metaparameter_type_error',
      `${ctx}: op '${op}' is not allowed in a metaparameter expression (only + - * /)`,
    )
  }
  let acc = ivals[0]!
  if (op === '-' && ivals.length === 1) {
    return checkedInt64(-acc, ctx)
  }
  for (const v of ivals.slice(1)) {
    if (op === '+') {
      acc = checkedInt64(acc + v, ctx)
    } else if (op === '-') {
      acc = checkedInt64(acc - v, ctx)
    } else if (op === '*') {
      acc = checkedInt64(acc * v, ctx)
    } else {
      if (v === 0n) {
        throw new ExpressionTemplateError('metaparameter_type_error', `${ctx}: division by zero`)
      }
      if (acc % v !== 0n) {
        throw new ExpressionTemplateError(
          'metaparameter_type_error',
          `${ctx}: ${acc} / ${v} does not divide exactly (esm-spec §9.7.6)`,
        )
      }
      acc = acc / v
    }
  }
  return acc
}

function collectNames(x: Json, out: string[]): string[] {
  if (typeof x === 'string') {
    out.push(x)
  } else if (Array.isArray(x)) {
    for (const v of x) collectNames(v, out)
  } else if (isObject(x)) {
    for (const k of Object.keys(x)) {
      if (k === 'op') continue
      collectNames(x[k], out)
    }
  }
  return out
}

/**
 * Structural grammar check for a metaparameter expression (esm-spec §9.7.6),
 * independent of whether its names are yet concrete: integer literal, name
 * string, or `{op: +|-|*|/, args: [...non-empty...]}` recursively. Unlike
 * `tryFold` (which defers op-validation until every arg is concrete), this
 * catches an inadmissible op (`%`, missing `args`, float literal) at the
 * binding EDGE even when an arg is still a symbolic importer name.
 */
function validateMetaExpr(x: Json, ctx: string): void {
  const i = asInt(x)
  if (i !== undefined && typeof x !== 'boolean') return // integer literal
  if (typeof x === 'string') return // metaparameter name
  if (typeof x === 'boolean' || typeof x === 'number' || isNumericLiteral(x)) {
    throw new ExpressionTemplateError(
      'metaparameter_type_error',
      `${ctx}: non-integer literal ${JSON.stringify(isNumericLiteral(x) ? x.value : x)} in a metaparameter expression (esm-spec §9.7.6)`,
    )
  }
  if (!isObject(x)) {
    throw new ExpressionTemplateError(
      'metaparameter_type_error',
      `${ctx}: invalid metaparameter expression (expected integer, name, or {op, args})`,
    )
  }
  const op = x.op
  const args = x.args
  if (
    !(op === '+' || op === '-' || op === '*' || op === '/') ||
    !Array.isArray(args) ||
    args.length === 0
  ) {
    throw new ExpressionTemplateError(
      'metaparameter_type_error',
      `${ctx}: invalid metaparameter expression (expected {op: +|-|*|/, args: [...]})`,
    )
  }
  for (const a of args) validateMetaExpr(a, ctx)
}

/**
 * Validate that `v` is a *metaparameter expression* (esm-spec §9.7.6): an
 * integer literal, a metaparameter-name string, or a `{op: +|-|*|/, args}`
 * tree over the same. Returns `v` unchanged (UNFOLDED) — its free names close
 * at a later binding site. Throws `metaparameter_type_error` on an
 * inadmissible node.
 *
 * This is the relaxed replacement for `requireInt` at the metaparameter
 * *binding* sites (import edge / subsystem edge). Before this, binding values
 * were bare integers; a binding may now derive a child metaparameter from an
 * arithmetic combination of the importer's metaparameters (e.g. `NTGT = NX*NY`),
 * which import renaming (name→name) could not express.
 */
export function requireMetaExpr(v: Json, ctx: string): Json {
  validateMetaExpr(v, ctx)
  return v
}

/**
 * Fold a metaparameter expression to a concrete integer against a CLOSED
 * environment `env` (name → int) — the importing document's metaparameter
 * scope (esm-spec §9.7.6 binding value flow). Substitutes the env names, then
 * folds with the exact-integer `tryFold` arithmetic (`/` must divide exactly;
 * 64-bit overflow is an error). Throws `template_import_unknown_name` if the
 * expression references a name absent from `env` — the mount-edge typo
 * failure, keeping error locality at the edge that authored the expression.
 */
export function evalMetaExpr(expr: Json, env: Record<string, number>, ctx: string): number {
  const folded = tryFold(substituteMetaparams(expr, env), ctx)
  if (folded === null) {
    const free = [
      ...new Set(
        collectNames(expr, []).filter((n) => !Object.prototype.hasOwnProperty.call(env, n)),
      ),
    ].sort()
    throw new ExpressionTemplateError(
      'template_import_unknown_name',
      `${ctx}: metaparameter expression references ${
        free.join(', ') || 'a name'
      } not in the importing document's metaparameter scope (esm-spec §9.7.6)`,
    )
  }
  return Number(folded)
}

/**
 * Fold metaparameter expressions in the structural integer sites —
 * `aggregate` dense `ranges` tuple entries and `makearray` `regions` bound
 * pairs — to concrete integers, in place, wherever they are already closed.
 * Entries still carrying a bare name (a template-param slot, or an open
 * metaparameter in a not-yet-fully-bound library) are left symbolic for a
 * later binding site. Index-set sizes are folded separately by
 * `foldIndexSetSizes`.
 */
function foldStructuralSites(x: Json, ctx: string): void {
  if (Array.isArray(x)) {
    for (const v of x) foldStructuralSites(v, ctx)
    return
  }
  if (!isObject(x)) return
  const op = typeof x.op === 'string' ? x.op : ''
  if (op === 'aggregate') {
    const ranges = x.ranges
    if (isObject(ranges)) {
      for (const [k, rv] of Object.entries(ranges)) {
        if (!Array.isArray(rv)) continue // {from: ...} index-set refs untouched
        for (let i = 0; i < rv.length; i++) {
          if (asInt(rv[i]) !== undefined) continue
          const f = tryFold(rv[i], `${ctx}: aggregate ranges.${k}`)
          if (f !== null) rv[i] = Number(f)
        }
      }
    }
  } else if (op === 'makearray') {
    const regions = x.regions
    if (Array.isArray(regions)) {
      for (const region of regions) {
        if (!Array.isArray(region)) continue
        for (const bounds of region) {
          if (!Array.isArray(bounds)) continue
          for (let i = 0; i < bounds.length; i++) {
            if (asInt(bounds[i]) !== undefined) continue
            const f = tryFold(bounds[i], `${ctx}: makearray regions bound`)
            if (f !== null) bounds[i] = Number(f)
          }
        }
      }
    }
  }
  for (const k of Object.keys(x)) foldStructuralSites(x[k], ctx)
}

/**
 * Fold interval `size` metaparameter expressions in an `index_sets`
 * registry. With `strict = true` (the root document, after its
 * metaparameters closed) any remaining bare name is `metaparameter_unbound`;
 * with `strict = false` (a library instantiated at an edge that left some
 * metaparameters open) open sizes stay symbolic and close at a later
 * binding site.
 */
function foldIndexSetSizes(indexSets: JsonObject, ctx: string, strict: boolean): void {
  for (const [name, decl] of Object.entries(indexSets)) {
    if (!isObject(decl)) continue
    const sz = decl.size
    if (sz === undefined || sz === null) continue
    if (asInt(sz) !== undefined) continue
    const f = tryFold(sz, `${ctx}: index_sets.${name}.size`)
    if (f === null) {
      if (strict) {
        const names = [...new Set(collectNames(sz, []))]
        throw new ExpressionTemplateError(
          'metaparameter_unbound',
          `${ctx}: index_sets.${name}.size references unbound name(s) ${names.join(', ')} (esm-spec §9.7.6)`,
        )
      }
    } else {
      decl.size = Number(f)
    }
  }
}

// ---------------------------------------------------------------------------
// Import-graph resolution (esm-spec §9.7.2 / §9.7.4 / §9.7.5)
// ---------------------------------------------------------------------------

/**
 * Everything one template-library file exports after resolution in its OWN
 * scope: its effective template sequence (imports depth-first post-order,
 * then own declarations; esm-spec §9.7.4), its instantiated `index_sets`,
 * and its still-open metaparameter declarations (re-exported to the
 * importer, esm-spec §9.7.6 binding site 2). Plain-object key order IS the
 * effective order.
 */
interface TemplateScope {
  templates: JsonObject
  indexSets: JsonObject
  metaparams: JsonObject
}

function newScope(): TemplateScope {
  return { templates: {}, indexSets: {}, metaparams: {} }
}

function mergeNamed(
  dst: JsonObject,
  name: string,
  decl: Json,
  code: string,
  what: string,
  origin: string,
): void {
  if (Object.prototype.hasOwnProperty.call(dst, name)) {
    // Deep-equal redeclaration (a diamond import) dedups at first occurrence;
    // a non-equal collision is a conflict (esm-spec §9.7.4/§9.7.5).
    if (deepEqual(dst[name], decl)) return
    throw new ExpressionTemplateError(
      code,
      `${origin}: ${what} '${name}' collides with a non-deep-equal existing definition (esm-spec §9.7.4/§9.7.5)`,
    )
  }
  dst[name] = decl
}

function mergeScope(dst: TemplateScope, src: TemplateScope, origin: string): void {
  for (const [n, d] of Object.entries(src.templates)) {
    mergeNamed(dst.templates, n, d, 'template_import_name_conflict', 'template', origin)
  }
  for (const [n, d] of Object.entries(src.indexSets)) {
    mergeNamed(dst.indexSets, n, d, 'template_import_index_set_conflict', 'index set', origin)
  }
  for (const [n, d] of Object.entries(src.metaparams)) {
    mergeNamed(dst.metaparams, n, d, 'template_import_name_conflict', 'metaparameter', origin)
  }
}

/**
 * Per-edge metaparameter instantiation (esm-spec §9.7.6 binding site 1):
 * substitute the bound names throughout the exported templates and index sets,
 * then fold the structural sites that are now closed. A bound VALUE is a
 * metaparameter expression (usually an integer literal, but possibly a symbolic
 * `NX*NY` over the importer's still-open metaparameters); the folds leave any
 * site still carrying a free name symbolic for the importer's close.
 */
function instantiateScope(scope: TemplateScope, values: Record<string, Json>, ctx: string): void {
  const newTemplates: JsonObject = {}
  for (const [n, d] of Object.entries(scope.templates)) {
    const nd = substituteMetaparamsDecl(d, values)
    foldStructuralSites(nd, ctx)
    newTemplates[n] = nd
  }
  scope.templates = newTemplates
  const newIndexSets: JsonObject = {}
  for (const [n, d] of Object.entries(scope.indexSets)) {
    newIndexSets[n] = substituteMetaparams(d, values)
  }
  foldIndexSetSizes(newIndexSets, ctx, false)
  scope.indexSets = newIndexSets
}

// ---- path + file access helpers (POSIX-style, mirroring ref-loading.ts) ----

function isRemoteRef(ref: string): boolean {
  return ref.startsWith('http://') || ref.startsWith('https://')
}

function joinPath(a: string, b: string): string {
  if (b.startsWith('/')) return b
  if (a.endsWith('/')) return `${a}${b}`
  return `${a}/${b}`
}

function canonicalizePath(p: string): string {
  const isAbs = p.startsWith('/')
  const parts = p.split('/').filter((seg) => seg.length > 0 && seg !== '.')
  const stack: string[] = []
  for (const seg of parts) {
    if (seg === '..') {
      if (stack.length > 0 && stack[stack.length - 1] !== '..') {
        stack.pop()
      } else if (!isAbs) {
        stack.push('..')
      }
    } else {
      stack.push(seg)
    }
  }
  const joined = stack.join('/')
  return isAbs ? `/${joined}` : joined || '.'
}

function dirName(p: string): string {
  const lastSlash = p.lastIndexOf('/')
  return lastSlash > 0 ? p.substring(0, lastSlash) : '/'
}

/** Canonical key for import-cycle detection (esm-spec §9.7.2, as §4.7). */
function canonicalRef(ref: string, baseDir: string): string {
  if (isRemoteRef(ref)) return ref
  return canonicalizePath(joinPath(baseDir.replace(/\\/g, '/'), ref))
}

function defaultReadFile(path: string): string {
  const proc = (globalThis as { process?: { getBuiltinModule?: (id: string) => unknown } }).process
  const getBuiltin = proc?.getBuiltinModule
  if (typeof getBuiltin === 'function') {
    const fs = getBuiltin.call(proc, 'node:fs') as {
      readFileSync: (p: string, enc: string) => string
    }
    return fs.readFileSync(path, 'utf8')
  }
  throw new Error(
    'synchronous file access is unavailable in this environment; supply LoadOptions.readFile',
  )
}

function loadImportRaw(
  ref: string,
  baseDir: string,
  origin: string,
  opts: TemplateResolveOptions,
): { raw: unknown; dir: string } {
  if (isRemoteRef(ref)) {
    // The synchronous §9.7 resolver cannot fetch over the network (mirrors
    // the Rust binding's remote-ref stance): download the library first and
    // import it by local path.
    throw new ExpressionTemplateError(
      'template_import_unresolved',
      `${origin}: failed to load template-library ref '${ref}': remote refs are not fetchable from the synchronous loader; download the file and import it by local path`,
    )
  }
  const path = canonicalRef(ref, baseDir)
  let content: string
  try {
    content = (opts.readFile ?? defaultReadFile)(path)
  } catch (e) {
    throw new ExpressionTemplateError(
      'template_import_unresolved',
      `${origin}: template-library file not found or unreadable: ${path} (from ref '${ref}'): ${e instanceof Error ? e.message : String(e)}`,
    )
  }
  let raw: unknown
  try {
    raw = JSON.parse(content)
  } catch (e) {
    throw new ExpressionTemplateError(
      'template_import_unresolved',
      `${origin}: template-library ref '${path}' is not valid JSON: ${e instanceof Error ? e.message : String(e)}`,
    )
  }
  return { raw, dir: dirName(path) }
}

// ---------------------------------------------------------------------------
// Import-edge renaming / namespacing + free-name rebinding (esm-spec §9.7.7)
// docs/content/rfcs/template-import-renaming.md
// ---------------------------------------------------------------------------

const APPLY_EXPRESSION_TEMPLATE_OP = 'apply_expression_template'

const NAME_SEGMENT_RE = /^[A-Za-z_][A-Za-z0-9_]*$/

/**
 * Grammar for a `prefix` and for `rename`/`rebind` TARGETS (esm-spec §9.7.7):
 * one or more `[A-Za-z_][A-Za-z0-9_]*` segments joined by single dots — the
 * §4.6 scoped-reference shape. Keys are never grammar-checked: they must match
 * whatever the target actually exports (or whatever occurs free).
 */
function isValidDottedName(s: string): boolean {
  return s.length > 0 && s.split('.').every((seg) => NAME_SEGMENT_RE.test(seg))
}

/** Parse a `rename`/`rebind` map (name → name), validating targets against the grammar. */
function nameMap(raw: unknown, field: string, where: string): Record<string, string> {
  const out: Record<string, string> = {}
  if (raw === undefined || raw === null) return out
  if (!isObject(raw)) {
    throw new ExpressionTemplateError(
      'template_import_rename_invalid',
      `${where}: \`${field}\` must be an object mapping names to names (esm-spec §9.7.7)`,
    )
  }
  for (const [k, v] of Object.entries(raw)) {
    if (k.length === 0) {
      throw new ExpressionTemplateError(
        'template_import_rename_invalid',
        `${where}: \`${field}\` has an empty key (esm-spec §9.7.7)`,
      )
    }
    if (!(typeof v === 'string' && isValidDottedName(v))) {
      throw new ExpressionTemplateError(
        'template_import_rename_invalid',
        `${where}: \`${field}\`.${k} target ${JSON.stringify(v)} is not a valid dotted identifier (segments [A-Za-z_][A-Za-z0-9_]* joined by single dots; esm-spec §9.7.7)`,
      )
    }
    out[k] = v
  }
  return out
}

// Scalar Expression-node fields whose string value names an AXIS / index set
// (rewritten by the index-set rename map, param-shadowed like §9.6.1).
const RENAME_AXIS_KEYS = new Set<string>(['wrt', 'dim'])

// Object keys whose values are never variable-reference positions for the
// rename walk: the metaparameter skip set plus the remaining scalar structural
// ExpressionNode fields (`op`, closed-registry ids, literal enums). `from`,
// `wrt`/`dim`, apply-`name`, and `of` are handled positionally in the walk.
const RENAME_PROTECTED_KEYS = new Set<string>([
  ...META_SUBST_SKIP_KEYS,
  'op',
  'id',
  'expect_cadence',
  'reduce',
  'semiring',
  'manifold',
  'fn',
  'table',
  'side',
  'attrs',
  'members',
  'from_faq',
])

/**
 * One transitive-substitution pass over an imported declaration (esm-spec
 * §9.7.7): `varmap` (renamed open metaparameters + rebound free names) rewrites
 * bare strings in variable-reference positions; `isetmap` rewrites index-set
 * reference positions (`{"from": …}` values, the `wrt`/`dim` axis fields, and
 * the `where.*.shape` match-scoping index-set names, in `body` and `match`
 * alike); `tplmap` rewrites `apply_expression_template.name`. Structural scalar
 * fields (`RENAME_PROTECTED_KEYS`) and bound-index lists (range `of`) are never
 * rewritten. Pure syntactic substitution — no evaluation.
 *
 * `where` is handled positionally (never by the protected-key copy that
 * metaparameter substitution uses, esm-spec §9.7.7): a `where` block is a map
 * `{paramName: {shape: [indexSetName, …]}}`. Rename renames templates, index
 * sets, and metaparameters — NOT template-internal param names — so the
 * constraint KEYS (param names) are copied verbatim while each constraint's
 * `shape` entries are mapped through `isetmap` (an unmapped name stays as
 * spelled). Without this the rule body/registry would use the renamed set while
 * `where` still named the original, and registration would fail with
 * `template_constraint_unknown_index_set`.
 */
function renameWalk(
  x: Json,
  varmap: Record<string, string>,
  isetmap: Record<string, string>,
  tplmap: Record<string, string>,
): Json {
  if (typeof x === 'string') {
    return Object.prototype.hasOwnProperty.call(varmap, x) ? varmap[x]! : x
  }
  if (Array.isArray(x)) {
    return x.map((v) => renameWalk(v, varmap, isetmap, tplmap))
  }
  if (isObject(x)) {
    const isApply = x.op === APPLY_EXPRESSION_TEMPLATE_OP
    const out: JsonObject = {}
    for (const k of Object.keys(x)) {
      const v = x[k]
      if (k === 'from' && typeof v === 'string') {
        out[k] = Object.prototype.hasOwnProperty.call(isetmap, v) ? isetmap[v]! : v
      } else if (RENAME_AXIS_KEYS.has(k) && typeof v === 'string') {
        out[k] = Object.prototype.hasOwnProperty.call(isetmap, v) ? isetmap[v]! : v
      } else if (k === 'name' && isApply && typeof v === 'string') {
        out[k] = Object.prototype.hasOwnProperty.call(tplmap, v) ? tplmap[v]! : v
      } else if (k === 'where' && isObject(v)) {
        out[k] = renameWhere(v, isetmap)
      } else if (k === 'of' || RENAME_PROTECTED_KEYS.has(k)) {
        out[k] = deepClone(v)
      } else {
        out[k] = renameWalk(v, varmap, isetmap, tplmap)
      }
    }
    return out
  }
  return x
}

/**
 * Rewrite a `where` match-scoping block (esm-spec §9.6.1) under an import-edge
 * index-set rename (esm-spec §9.7.7). Constraint KEYS (param names) are copied
 * verbatim — rename never touches template-internal param names — and each
 * constraint's `shape` entries (index-set names) are mapped through `isetmap`,
 * with any unmapped name left as spelled (the body-reference rule).
 */
function renameWhere(whr: JsonObject, isetmap: Record<string, string>): JsonObject {
  const out: JsonObject = {}
  for (const p of Object.keys(whr)) {
    const cobj = whr[p]
    if (isObject(cobj)) {
      const cout: JsonObject = {}
      for (const ck of Object.keys(cobj)) {
        const cv = cobj[ck]
        if (ck === 'shape' && Array.isArray(cv)) {
          cout[ck] = cv.map((e) =>
            typeof e === 'string'
              ? Object.prototype.hasOwnProperty.call(isetmap, e)
                ? isetmap[e]!
                : e
              : deepClone(e),
          )
        } else {
          cout[ck] = deepClone(cv)
        }
      }
      out[p] = cout
    } else {
      out[p] = deepClone(cobj)
    }
  }
  return out
}

/**
 * `renameWalk` over one template declaration with the §9.6.1 shadowing rule:
 * the template's own `params` shadow like-named entries of `varmap` and
 * `isetmap` inside its `body`/`match` (a param is the inner binder; renaming
 * must not capture it). `tplmap` is never shadowed — params do not bind
 * template names.
 */
function renameDecl(
  decl: Json,
  varmap: Record<string, string>,
  isetmap: Record<string, string>,
  tplmap: Record<string, string>,
): Json {
  let v2 = varmap
  let i2 = isetmap
  const params = isObject(decl) ? decl.params : undefined
  if (Array.isArray(params) && params.length > 0) {
    const pset = new Set<string>()
    for (const p of params) if (typeof p === 'string') pset.add(p)
    if ([...pset].some((p) => Object.prototype.hasOwnProperty.call(varmap, p))) {
      v2 = {}
      for (const [k, v] of Object.entries(varmap)) if (!pset.has(k)) v2[k] = v
    }
    if ([...pset].some((p) => Object.prototype.hasOwnProperty.call(isetmap, p))) {
      i2 = {}
      for (const [k, v] of Object.entries(isetmap)) if (!pset.has(k)) i2[k] = v
    }
  }
  return renameWalk(decl, v2, i2, tplmap)
}

/**
 * Bound index symbols of a declaration: aggregate `output_idx` entries and
 * `ranges` keys (at any nesting depth). Rebinding one would desynchronize the
 * ranges KEYS (object keys, unreachable by value substitution) from their
 * `expr` occurrences, so it is rejected outright.
 */
function collectBoundSyms(out: Set<string>, x: Json): Set<string> {
  if (Array.isArray(x)) {
    for (const v of x) collectBoundSyms(out, v)
    return out
  }
  if (!isObject(x)) return out
  if (x.op === 'aggregate') {
    const oi = x.output_idx
    if (Array.isArray(oi)) {
      for (const e of oi) if (typeof e === 'string') out.add(e)
    }
    const rg = x.ranges
    if (isObject(rg)) {
      for (const k of Object.keys(rg)) out.add(k)
    }
  }
  for (const k of Object.keys(x)) collectBoundSyms(out, x[k])
  return out
}

/**
 * Every bare string in a variable-reference position of a declaration (the
 * positions `varmap` would rewrite), minus the per-template `params` shadow
 * set. Used for the rebind occurs-check and the freshness (collision) guard.
 */
function collectRefNames(out: Set<string>, x: Json, shadowed: Set<string>): Set<string> {
  if (typeof x === 'string') {
    if (!shadowed.has(x)) out.add(x)
    return out
  }
  if (Array.isArray(x)) {
    for (const v of x) collectRefNames(out, v, shadowed)
    return out
  }
  if (isObject(x)) {
    for (const k of Object.keys(x)) {
      if (k === 'from' || RENAME_AXIS_KEYS.has(k) || k === 'of' || RENAME_PROTECTED_KEYS.has(k)) {
        continue
      }
      collectRefNames(out, x[k], shadowed)
    }
    return out
  }
  return out
}

/**
 * Apply one import edge's `prefix` / `rename` / `rebind` (esm-spec §9.7.7) to
 * the target's SURVIVING export scope — templates after `only`, all index sets,
 * and metaparameters still open after this edge's `bindings` — transitively
 * through every occurrence inside the surviving declarations (index-set
 * references in `from`/`wrt`/`dim` and registry `of` lists, open-metaparameter
 * names in expression positions, keyed-factor and other free names in
 * variable-reference positions and registry `offsets`/`values`,
 * `apply_expression_template.name` references). Runs after `bindings`
 * instantiation and `only` filtering, before the §9.7.4/§9.7.5 merge, so dedup
 * and conflict detection operate on post-rename names. Pure load-time
 * substitution: determinism, §9.6.3 ordering, and the expansion-depth bound are
 * untouched. Mutates `scope` in place and returns it.
 */
function applyEdgeRenames(
  scope: TemplateScope,
  entry: JsonObject,
  origin: string,
  ref: string,
): TemplateScope {
  const where = `${origin}: import of '${ref}'`
  const prefixRaw = entry.prefix
  const rename = nameMap(entry.rename, 'rename', where)
  const rebind = nameMap(entry.rebind, 'rebind', where)
  if (
    prefixRaw !== undefined &&
    prefixRaw !== null &&
    !(typeof prefixRaw === 'string' && isValidDottedName(prefixRaw))
  ) {
    throw new ExpressionTemplateError(
      'template_import_rename_invalid',
      `${where}: \`prefix\` ${JSON.stringify(prefixRaw)} is not a valid dotted identifier (segments [A-Za-z_][A-Za-z0-9_]* joined by single dots; esm-spec §9.7.7)`,
    )
  }
  const prefix = prefixRaw === undefined || prefixRaw === null ? null : String(prefixRaw)
  if (prefix === null && Object.keys(rename).length === 0 && Object.keys(rebind).length === 0) {
    return scope
  }

  // --- `rename` keys must name a surviving exported name (typo protection) ---
  const exported = new Set<string>([
    ...Object.keys(scope.templates),
    ...Object.keys(scope.indexSets),
    ...Object.keys(scope.metaparams),
  ])
  for (const k of Object.keys(rename)) {
    if (!exported.has(k)) {
      throw new ExpressionTemplateError(
        'template_import_rename_unknown_name',
        `${where}: \`rename\` names '${k}', which the target does not export at this edge (the surviving exports are templates after \`only\`, index sets, and metaparameters left open by this edge's \`bindings\`; esm-spec §9.7.7)`,
      )
    }
  }

  const finalName = (n: string): string =>
    Object.prototype.hasOwnProperty.call(rename, n)
      ? rename[n]!
      : prefix === null
        ? n
        : `${prefix}.${n}`
  const buildMap = (names: string[]): Record<string, string> => {
    const m: Record<string, string> = {}
    for (const n of names) m[n] = finalName(n)
    return m
  }
  const tplmap = buildMap(Object.keys(scope.templates))
  const isetmap = buildMap(Object.keys(scope.indexSets))
  const metamap = buildMap(Object.keys(scope.metaparams))

  // --- per-namespace final-name uniqueness ---
  for (const [what, m] of [
    ['template', tplmap],
    ['index set', isetmap],
    ['metaparameter', metamap],
  ] as const) {
    const seen: Record<string, string> = {}
    for (const [o, n] of Object.entries(m)) {
      if (Object.prototype.hasOwnProperty.call(seen, n)) {
        throw new ExpressionTemplateError(
          'template_import_rename_collision',
          `${where}: ${what} names '${seen[n]}' and '${o}' both map to '${n}' after renaming (esm-spec §9.7.7)`,
        )
      }
      seen[n] = o
    }
  }

  // --- free / bound name inventory over the surviving declarations ---
  const free = new Set<string>()
  const bound = new Set<string>()
  const paramsAll = new Set<string>()
  for (const d of Object.values(scope.templates)) {
    collectBoundSyms(bound, d)
    const shadowed = new Set<string>()
    const params = isObject(d) ? d.params : undefined
    if (Array.isArray(params)) {
      for (const p of params) if (typeof p === 'string') shadowed.add(p)
    }
    for (const p of shadowed) paramsAll.add(p)
    collectRefNames(free, d, shadowed)
  }
  for (const d of Object.values(scope.indexSets)) {
    for (const f of ['offsets', 'values']) {
      const v = isObject(d) ? d[f] : undefined
      if (typeof v === 'string') free.add(v)
    }
  }
  for (const n of Object.keys(scope.metaparams)) free.delete(n) // declared names are not free

  // --- `rebind` keys must denote free names (typo protection) ---
  for (const k of Object.keys(rebind)) {
    if (exported.has(k)) {
      throw new ExpressionTemplateError(
        'template_import_rebind_unknown_name',
        `${where}: \`rebind\` names '${k}', a declared name of the target (template / index set / metaparameter) — \`rebind\` addresses only free names; use \`rename\` for declared names (esm-spec §9.7.7)`,
      )
    }
    if (bound.has(k)) {
      throw new ExpressionTemplateError(
        'template_import_rename_invalid',
        `${where}: \`rebind\` key '${k}' is a bound index symbol (\`output_idx\` / \`ranges\`) of an imported template, not a free name (esm-spec §9.7.7)`,
      )
    }
    if (!free.has(k)) {
      throw new ExpressionTemplateError(
        'template_import_rebind_unknown_name',
        `${where}: \`rebind\` names '${k}', which does not occur free in the imported declarations (esm-spec §9.7.7)`,
      )
    }
  }

  // --- freshness guard: new bare names must not capture / merge ---
  const taken = new Set<string>()
  for (const f of free) if (!Object.prototype.hasOwnProperty.call(rebind, f)) taken.add(f)
  for (const b of bound) taken.add(b)
  for (const p of paramsAll) taken.add(p)
  const newnames: string[] = []
  for (const [o, n] of Object.entries(metamap)) if (o !== n) newnames.push(n)
  for (const [o, n] of Object.entries(rebind)) if (o !== n) newnames.push(n)
  for (const t of newnames) {
    if (taken.has(t)) {
      throw new ExpressionTemplateError(
        'template_import_rename_collision',
        `${where}: renamed/rebound name '${t}' collides with a name still in use inside the imported declarations (a remaining free name, a bound index symbol, a template param, or another rename/rebind target; esm-spec §9.7.7)`,
      )
    }
    taken.add(t)
  }

  // --- apply (identity entries dropped; one simultaneous substitution) ---
  const varmap: Record<string, string> = {}
  for (const [o, n] of Object.entries(metamap)) if (o !== n) varmap[o] = n
  for (const [o, n] of Object.entries(rebind)) if (o !== n) varmap[o] = n
  const isetChanged: Record<string, string> = {}
  for (const [o, n] of Object.entries(isetmap)) if (o !== n) isetChanged[o] = n
  const tplChanged: Record<string, string> = {}
  for (const [o, n] of Object.entries(tplmap)) if (o !== n) tplChanged[o] = n

  const newt: JsonObject = {}
  for (const [n, d] of Object.entries(scope.templates)) {
    newt[tplmap[n]!] = renameDecl(d, varmap, isetChanged, tplChanged)
  }
  scope.templates = newt

  const newi: JsonObject = {}
  for (const [n, d] of Object.entries(scope.indexSets)) {
    const nd = renameWalk(d, varmap, isetChanged, tplChanged) as JsonObject
    const of = isObject(nd) ? nd.of : undefined
    if (Array.isArray(of)) {
      nd.of = of.map((e) =>
        typeof e === 'string'
          ? Object.prototype.hasOwnProperty.call(isetChanged, e)
            ? isetChanged[e]!
            : e
          : e,
      )
    }
    newi[isetmap[n]!] = nd
  }
  scope.indexSets = newi

  const newm: JsonObject = {}
  for (const [n, d] of Object.entries(scope.metaparams)) {
    newm[metamap[n]!] = d
  }
  scope.metaparams = newm
  return scope
}

/**
 * Resolve ONE `expression_template_imports` entry (esm-spec §9.7.2): load
 * the target (path-scoped cycle detection over canonical refs, as §4.7),
 * verify library purity, resolve the target recursively in its own scope,
 * instantiate at this edge's `bindings`, apply `only` visibility filtering,
 * then apply the edge's `prefix`/`rename`/`rebind` (esm-spec §9.7.7).
 */
function resolveImportEntry(
  entry: Json,
  baseDir: string,
  stack: string[],
  origin: string,
  opts: TemplateResolveOptions,
): TemplateScope {
  if (!isObject(entry)) {
    throw new ExpressionTemplateError(
      'template_import_unresolved',
      `${origin}: expression_template_imports entries must be objects with a \`ref\` field`,
    )
  }
  const refRaw = entry.ref
  if (typeof refRaw !== 'string' || refRaw.length === 0) {
    throw new ExpressionTemplateError(
      'template_import_unresolved',
      `${origin}: expression_template_imports entry requires a non-empty string \`ref\``,
    )
  }
  const ref = refRaw
  const canonical = canonicalRef(ref, baseDir)
  if (stack.includes(canonical)) {
    const cyc = [...stack.slice(stack.indexOf(canonical)), canonical]
    throw new ExpressionTemplateError(
      'template_import_cycle',
      `${origin}: import-graph cycle detected: ${cyc.join(' -> ')} (esm-spec §9.7.2)`,
    )
  }

  const { raw, dir: targetDir } = loadImportRaw(ref, baseDir, origin, opts)
  // Version gates on the target (esm-spec §9.6.5).
  rejectExpressionTemplatesPreV04(raw)
  rejectTemplateImportsPreV08(raw)

  // Library purity (esm-spec §9.7.1): the reference mechanisms are disjoint —
  // a component/subsystem file, and a coupling-library file, are not importable
  // as a template library.
  if (isObject(raw) && 'coupling_roles' in raw) {
    throw new ExpressionTemplateError(
      'template_import_is_coupling_library',
      `${origin}: import target '${ref}' is a coupling-library file (has \`coupling_roles\`), not a template library (esm-spec §10.9)`,
    )
  }
  if (!isTemplateLibraryDoc(raw)) {
    throw new ExpressionTemplateError(
      'template_import_not_library',
      `${origin}: import target '${ref}' lacks top-level \`expression_templates\` — not a template-library file (esm-spec §9.7.1)`,
    )
  }
  for (const k of LIBRARY_FORBIDDEN_KEYS) {
    if (isObject(raw) && k in raw) {
      throw new ExpressionTemplateError(
        'template_import_not_library',
        `${origin}: import target '${ref}' declares \`${k}\` — not a pure template-library file (esm-spec §9.7.1)`,
      )
    }
  }
  if (opts.validateSchema) {
    const schemaErrors = opts.validateSchema(raw)
    if (schemaErrors.length > 0) {
      throw new ExpressionTemplateError(
        'template_import_unresolved',
        `${origin}: import target '${ref}' failed schema validation: ${schemaErrors[0]!.path}: ${schemaErrors[0]!.message}`,
      )
    }
  }

  stack.push(canonical)
  let scope: TemplateScope
  try {
    scope = processLibrary(raw, targetDir, stack, `${origin} -> ${ref}`, opts)
  } finally {
    stack.pop()
  }

  // Edge metaparameter bindings (esm-spec §9.7.6 binding site 1). A binding
  // VALUE may be a metaparameter expression over the importer's metaparameters
  // (e.g. `NX*NY`); at an import edge the importer's names are not yet closed
  // (innermost-first), so the value is carried SYMBOLICALLY into the child and
  // folds when the importing document closes (§9.7.6 "Binding value flow").
  const values: Record<string, Json> = {}
  const bindingsRaw = entry.bindings
  if (isObject(bindingsRaw)) {
    for (const [name, v] of Object.entries(bindingsRaw)) {
      if (!Object.prototype.hasOwnProperty.call(scope.metaparams, name)) {
        throw new ExpressionTemplateError(
          'template_import_unknown_name',
          `${origin}: import of '${ref}' binds metaparameter '${name}', which the target neither declares nor re-exports (esm-spec §9.7.6)`,
        )
      }
      values[name] = requireMetaExpr(v, `${origin}: import of '${ref}', binding '${name}'`)
    }
  }
  if (Object.keys(values).length > 0) {
    instantiateScope(scope, values, `${origin} -> ${ref}`)
    for (const name of Object.keys(values)) {
      delete scope.metaparams[name]
    }
  }

  // `only` visibility filtering (esm-spec §9.7.2) — after the target's own
  // internal wiring resolved in its own scope.
  const onlyRaw = entry.only
  if (Array.isArray(onlyRaw)) {
    const keep = onlyRaw.map(String)
    for (const n of keep) {
      if (!Object.prototype.hasOwnProperty.call(scope.templates, n)) {
        throw new ExpressionTemplateError(
          'template_import_unknown_name',
          `${origin}: \`only\` names template '${n}', which '${ref}' does not declare (esm-spec §9.7.2)`,
        )
      }
    }
    const keepSet = new Set(keep)
    const filtered: JsonObject = {}
    for (const [n, d] of Object.entries(scope.templates)) {
      if (keepSet.has(n)) filtered[n] = d
    }
    scope.templates = filtered
  }

  // Import-edge renaming / namespacing + free-name rebinding (esm-spec §9.7.7)
  // — after `bindings` instantiation and `only` filtering, before the
  // §9.7.4/§9.7.5 merge, so dedup/conflict checks see post-rename names.
  return applyEdgeRenames(scope, entry, origin, ref)
}

/**
 * Resolve a template-library document in its OWN scope: its imports
 * (depth-first post-order), then its own templates / index sets /
 * metaparameters appended in declaration order (esm-spec §9.7.4), then
 * §9.7.3 body composition — so a BC-layer body reference to an imported
 * interior stencil closes here, before any `only` filtering by a downstream
 * importer.
 */
function processLibrary(
  raw: unknown,
  dir: string,
  stack: string[],
  origin: string,
  opts: TemplateResolveOptions,
): TemplateScope {
  const scope = newScope()
  if (isObject(raw) && Array.isArray(raw.expression_template_imports)) {
    for (const entry of raw.expression_template_imports) {
      const sub = resolveImportEntry(entry, dir, stack, origin, opts)
      mergeScope(scope, sub, origin)
    }
  }

  const own: JsonObject = {}
  if (isObject(raw) && isObject(raw.expression_templates)) {
    for (const [n, d] of Object.entries(raw.expression_templates)) {
      own[n] = deepClone(d)
    }
  }
  validateTemplates(own as never, origin)
  for (const [n, d] of Object.entries(own)) {
    mergeNamed(scope.templates, n, d, 'template_import_name_conflict', 'template', origin)
  }

  if (isObject(raw) && isObject(raw.index_sets)) {
    for (const [n, d] of Object.entries(raw.index_sets)) {
      mergeNamed(
        scope.indexSets,
        n,
        deepClone(d),
        'template_import_index_set_conflict',
        'index set',
        origin,
      )
    }
  }

  for (const [n, d] of Object.entries(collectMetaparamDecls(raw, origin))) {
    mergeNamed(scope.metaparams, n, d, 'template_import_name_conflict', 'metaparameter', origin)
  }

  // §9.7.3 body composition in the library's own scope (decl objects are
  // mutated in place, so scope.templates sees the closed bodies).
  composeTemplateBodies(scope.templates as never, origin)
  return scope
}

// ---------------------------------------------------------------------------
// Root-document resolution (the load-time entry point)
// ---------------------------------------------------------------------------

function hasImportMachinery(raw: unknown): boolean {
  if (!isObject(raw)) return false
  if (
    'expression_templates' in raw ||
    'metaparameters' in raw ||
    'expression_template_imports' in raw
  ) {
    return true
  }
  for (const compKind of COMPONENT_KINDS) {
    const comps = raw[compKind]
    if (!isObject(comps)) continue
    for (const comp of Object.values(comps)) {
      if (isObject(comp) && 'expression_template_imports' in comp) return true
    }
  }
  return false
}

/**
 * Resolve every esm-spec §9.7 construct of the ROOT document `rawData`
 * (relative import refs resolve against `basePath`): imports recursively
 * with per-edge instantiation, `index_sets` merge, metaparameter close
 * (`options.metaparameters` is the loader-API binding site 4;
 * already-closed edge bindings win, then API bindings, then defaults) and
 * fold, expression-position substitution, and — for a root library file —
 * §9.7.3 body composition.
 *
 * Returns an order-preserving plain-object tree ready for
 * `lowerExpressionTemplates` with `expression_template_imports`,
 * `metaparameters`, and top-level `expression_templates` consumed (Option A
 * round-trip: none survives `parse → emit`), or `null` when the document
 * carries no §9.7 machinery (the legacy fast path).
 */
export function resolveTemplateMachinery(
  rawData: unknown,
  basePath: string,
  options: TemplateResolveOptions = {},
): JsonObject | null {
  const api: Record<string, number> = {}
  for (const [k, v] of Object.entries(options.metaparameters ?? {})) {
    api[k] = requireInt(v, `loader API metaparameter '${k}'`)
  }

  if (!hasImportMachinery(rawData)) {
    if (Object.keys(api).length > 0) {
      throw new ExpressionTemplateError(
        'template_import_unknown_name',
        `loader API binds metaparameter(s) ${Object.keys(api).sort().join(', ')} but the document declares none (esm-spec §9.7.6)`,
      )
    }
    return null
  }
  const baseDir = basePath.replace(/\\/g, '/')
  const root = deepClone(rawData) as JsonObject
  const stack: string[] = []

  const docMeta = collectMetaparamDecls(root, 'document')
  let docIsets: JsonObject = {}
  if (isObject(root.index_sets)) {
    for (const [n, d] of Object.entries(root.index_sets)) {
      docIsets[n] = d
    }
  }

  // --- top-level templates + imports (root template-library file) ---
  const isLibrary = 'expression_templates' in root
  let topTemplates: JsonObject = {}
  if (isLibrary) {
    const topScope = newScope()
    if (Array.isArray(root.expression_template_imports)) {
      for (const entry of root.expression_template_imports) {
        const sub = resolveImportEntry(entry, baseDir, stack, 'document', options)
        mergeScope(topScope, sub, 'document')
      }
    }
    const own: JsonObject = {}
    if (isObject(root.expression_templates)) {
      for (const [n, d] of Object.entries(root.expression_templates)) {
        own[n] = d
      }
    }
    validateTemplates(own as never, 'document')
    for (const [n, d] of Object.entries(own)) {
      mergeNamed(topScope.templates, n, d, 'template_import_name_conflict', 'template', 'document')
    }
    for (const [n, d] of Object.entries(topScope.indexSets)) {
      mergeNamed(docIsets, n, d, 'template_import_index_set_conflict', 'index set', 'document')
    }
    for (const [n, d] of Object.entries(topScope.metaparams)) {
      mergeNamed(docMeta, n, d, 'template_import_name_conflict', 'metaparameter', 'document')
    }
    topTemplates = topScope.templates
  }

  // --- per-component imports (models / reaction systems, esm-spec §9.7.2) ---
  for (const compKind of COMPONENT_KINDS) {
    const comps = root[compKind]
    if (!isObject(comps)) continue
    for (const [cname, comp] of Object.entries(comps)) {
      if (!isObject(comp)) continue
      const imports = comp.expression_template_imports
      if (imports === undefined) continue
      const cscope = newScope()
      const corigin = `${compKind}.${cname}`
      if (Array.isArray(imports)) {
        for (const entry of imports) {
          const sub = resolveImportEntry(entry, baseDir, stack, corigin, options)
          mergeScope(cscope, sub, corigin)
        }
      }
      if (isObject(comp.expression_templates)) {
        const own: JsonObject = {}
        for (const [n, d] of Object.entries(comp.expression_templates)) {
          own[n] = d
        }
        validateTemplates(own as never, corigin)
        for (const [n, d] of Object.entries(own)) {
          mergeNamed(cscope.templates, n, d, 'template_import_name_conflict', 'template', corigin)
        }
      }
      for (const [n, d] of Object.entries(cscope.indexSets)) {
        mergeNamed(docIsets, n, d, 'template_import_index_set_conflict', 'index set', corigin)
      }
      for (const [n, d] of Object.entries(cscope.metaparams)) {
        mergeNamed(docMeta, n, d, 'template_import_name_conflict', 'metaparameter', corigin)
      }
      // The effective sequence (imports depth-first post-order, then local
      // declarations) becomes the component's template block; plain-object
      // key order IS the §9.6.3 declaration order.
      comp.expression_templates = cscope.templates
      delete comp.expression_template_imports
    }
  }

  // --- close this document's metaparameters (§9.7.6 sites 4-5) ---
  for (const k of Object.keys(api).sort()) {
    if (!Object.prototype.hasOwnProperty.call(docMeta, k)) {
      throw new ExpressionTemplateError(
        'template_import_unknown_name',
        `loader API binds metaparameter '${k}', which the document does not declare (esm-spec §9.7.6)`,
      )
    }
  }
  const values: Record<string, number> = {}
  const openNames: string[] = []
  for (const [name, decl] of Object.entries(docMeta)) {
    if (Object.prototype.hasOwnProperty.call(api, name)) {
      values[name] = api[name]!
    } else {
      const d = isObject(decl) ? decl.default : undefined
      if (d === undefined || d === null) {
        openNames.push(name)
      } else {
        values[name] = asInt(d) as number
      }
    }
  }
  if (openNames.length > 0) {
    throw new ExpressionTemplateError(
      'metaparameter_unbound',
      `metaparameter(s) ${openNames.join(', ')} still open after edge bindings, loader-API bindings, and defaults (esm-spec §9.7.6)`,
    )
  }

  // --- §9.7.6 name-collision check: no shadowing of visible names ---
  if (Object.keys(docMeta).length > 0) {
    const visible = new Set<string>(Object.keys(docIsets))
    for (const compKind of COMPONENT_KINDS) {
      const comps = root[compKind]
      if (!isObject(comps)) continue
      for (const comp of Object.values(comps)) {
        if (!isObject(comp)) continue
        for (const blk of ['variables', 'species', 'parameters']) {
          const b = comp[blk]
          if (!isObject(b)) continue
          for (const vn of Object.keys(b)) visible.add(vn)
        }
      }
    }
    for (const name of Object.keys(docMeta)) {
      if (visible.has(name)) {
        throw new ExpressionTemplateError(
          'metaparameter_name_conflict',
          `metaparameter '${name}' collides with a visible variable/parameter/species/index-set name (esm-spec §9.7.6)`,
        )
      }
    }
  }

  // --- expression-position substitution of the closed values ---
  if (Object.keys(values).length > 0) {
    for (const compKind of COMPONENT_KINDS) {
      const comps = root[compKind]
      if (!isObject(comps)) continue
      for (const comp of Object.values(comps)) {
        if (!isObject(comp)) continue
        for (const k of Object.keys(comp)) {
          if (k === 'expression_templates' && isObject(comp[k])) {
            const tpl = comp[k] as JsonObject
            for (const [tn, td] of Object.entries(tpl)) {
              tpl[tn] = substituteMetaparamsDecl(td, values)
            }
          } else {
            comp[k] = substituteMetaparams(comp[k], values)
          }
        }
      }
    }
    for (const [tn, td] of Object.entries(topTemplates)) {
      topTemplates[tn] = substituteMetaparamsDecl(td, values)
    }
    const newIsets: JsonObject = {}
    for (const [n, d] of Object.entries(docIsets)) {
      newIsets[n] = substituteMetaparams(d, values)
    }
    docIsets = newIsets
  }

  // --- fold structural sites on the closed document ---
  for (const compKind of COMPONENT_KINDS) {
    const comps = root[compKind]
    if (!isObject(comps)) continue
    for (const [cname, comp] of Object.entries(comps)) {
      if (!isObject(comp)) continue
      foldStructuralSites(comp, `${compKind}.${cname}`)
    }
  }
  for (const [tn, td] of Object.entries(topTemplates)) {
    foldStructuralSites(td, `document.expression_templates.${tn}`)
  }
  foldIndexSetSizes(docIsets, 'document', true)

  // --- root library file: compose bodies (validation), then strip; no §9.7
  //     construct survives parse → emit (esm-spec §9.7.6 round-trip) ---
  if (isLibrary) {
    composeTemplateBodies(topTemplates as never, 'document')
    delete root.expression_templates
  }
  delete root.expression_template_imports
  delete root.metaparameters
  if (Object.keys(docIsets).length > 0) root.index_sets = docIsets
  return root
}

// ===================================================================
// Scope-directed template injection (esm-spec §9.7.10)
// ===================================================================
//
// A consuming surface — a §4.7 subsystem-ref edge (form A), a §10 coupling
// entry (form B), or a §6.6/§6.7 test/example (form C) — may register imports
// into a TARGET component's own scope without editing the leaf. Forms A/B are
// applied here, at the raw-data level, BEFORE `resolveTemplateMachinery`: each
// widens the target component's `expression_template_imports` in the §9.7.10
// merge order (the target's own imports first, then the subsystem-ref edge,
// then coupling entries in `coupling`-array order), so the ordinary import
// resolver + §9.6.3 fixpoint lower the target's rewrite-targets with no engine
// change. Form C is applied by the PDE test runner in a per-test ephemeral
// build (`ephemeralInjectedFile` in `ref-loading.ts`). Mirrors the Julia
// reference (`EarthSciAST.jl/src/template_imports.jl`).

/**
 * True iff a scope-directed injection (esm-spec §9.7.10) must be applied to
 * `raw` before template resolution: a non-empty subsystem-ref edge list
 * `injected` (form A), or any `coupling` entry carrying an
 * `expression_template_imports` map (form B).
 */
function hasScopeInjection(raw: unknown, injected: readonly unknown[]): boolean {
  if (injected.length > 0) return true
  if (!isObject(raw)) return false
  const coupling = raw.coupling
  if (!Array.isArray(coupling)) return false
  for (const entry of coupling) {
    if (isObject(entry) && 'expression_template_imports' in entry) return true
  }
  return false
}

/**
 * Append raw §9.7.2 import entries to a component's own
 * `expression_template_imports` (esm-spec §9.7.10 merge order: the target's
 * own imports first, then the injected list). `comp` is mutated in place.
 */
function appendComponentImports(comp: JsonObject, imports: readonly unknown[]): void {
  const existing = comp.expression_template_imports
  const base: unknown[] = Array.isArray(existing) ? [...existing] : []
  for (const e of imports) base.push(deepClone(e))
  comp.expression_template_imports = base
}

/**
 * esm-spec §9.7.10 form A: append the subsystem-ref edge's injected §9.7.2
 * import entries to the single top-level component's own
 * `expression_template_imports`, so the referenced document is lowered under
 * the assembler-chosen discretization. A referenced subsystem file holds
 * exactly one top-level model or reaction system (§4.7), the implicit target;
 * a loader-only referenced file has no expression positions, so the injection
 * finds no home and the mount fails cleanly downstream.
 */
function applySubsystemRefInjection(root: JsonObject, injected: readonly unknown[]): void {
  if (injected.length === 0) return
  for (const compKind of COMPONENT_KINDS) {
    const comps = root[compKind]
    if (!isObject(comps)) continue
    const names = Object.keys(comps)
    if (names.length === 0) continue
    const comp = comps[names[0]!]
    if (!isObject(comp)) continue
    appendComponentImports(comp, injected)
    return
  }
}

/**
 * Add the owning-system segment of every scoped reference (a string of the
 * form "System.var") in `x` to `out`. Used for `event` entries whose system
 * references are spread across conditions / affects.
 */
function collectScopedOwners(out: Set<string>, x: unknown): void {
  if (typeof x === 'string') {
    if (x.includes('.')) out.add(x.split('.')[0]!)
  } else if (Array.isArray(x)) {
    for (const v of x) collectScopedOwners(out, v)
  } else if (isObject(x)) {
    for (const v of Object.values(x)) collectScopedOwners(out, v)
  }
}

/**
 * Collect, for one coupling entry, the set of system names it references
 * (esm-spec §10.8): `operator_compose`/`couple` → `systems`; `variable_map` →
 * the owning systems of `from`/`to`; `event` → owning systems of any scoped
 * reference in the entry. A `callback` references none.
 */
function couplingReferencedSystems(entry: JsonObject): Set<string> {
  const out = new Set<string>()
  const ctype = typeof entry.type === 'string' ? entry.type : ''
  if (ctype === 'operator_compose' || ctype === 'couple') {
    const sys = entry.systems
    if (Array.isArray(sys)) {
      for (const s of sys) {
        const str = String(s)
        out.add(str)
        out.add(str.split('.')[0]!)
      }
    }
  } else if (ctype === 'variable_map') {
    for (const k of ['from', 'to'] as const) {
      const v = entry[k]
      if (v === undefined || v === null) continue
      out.add(String(v).split('.')[0]!)
    }
  } else if (ctype === 'event') {
    collectScopedOwners(out, entry)
  }
  return out
}

/**
 * esm-spec §9.7.10 form B / §10.8: for each `coupling` entry carrying an
 * `expression_template_imports` map `{ <target>: [imports...] }`, resolve
 * each target key to a top-level system and append its imports to that
 * system's own `expression_template_imports` (merge order §9.7.10). The map
 * is consumed here (deleted from the entry) so form B does not survive
 * `parse → emit`.
 *
 * Diagnostics (esm-spec §9.6.6): a key naming no system the entry references
 * is `template_inject_target_unknown`; a key resolving to a data loader is
 * `template_inject_target_is_loader`; a key resolving to neither model,
 * reaction system, nor loader is `template_inject_target_not_component`. Only
 * top-level system targets are resolved by this binding — a nested
 * `Parent.Child` key is out of scope (RFC §8.3) → `..._not_component`.
 */
function applyCouplingInjections(root: JsonObject): void {
  const coupling = root.coupling
  if (!Array.isArray(coupling)) return
  const models = root.models
  const rsystems = root.reaction_systems
  const loaders = root.data_loaders
  const hasKey = (d: unknown, k: string): boolean =>
    isObject(d) && Object.prototype.hasOwnProperty.call(d, k)
  for (const entry of coupling) {
    if (!isObject(entry)) continue
    const inj = entry.expression_template_imports
    if (inj === undefined || inj === null) continue
    if (!isObject(inj)) {
      throw new ExpressionTemplateError(
        'template_inject_target_not_component',
        'coupling entry `expression_template_imports` must be a map from a target system name to a list of imports (esm-spec §9.7.10 / §10.8)',
      )
    }
    const referenced = couplingReferencedSystems(entry)
    for (const [tname, imports] of Object.entries(inj)) {
      if (!referenced.has(tname)) {
        throw new ExpressionTemplateError(
          'template_inject_target_unknown',
          `coupling entry \`expression_template_imports\` key '${tname}' names no system referenced by that entry (esm-spec §9.7.10 / §10.8). The entry references: ${
            referenced.size === 0 ? '(none)' : [...referenced].sort().join(', ')
          }.`,
        )
      }
      let comp: unknown
      if (hasKey(models, tname)) {
        comp = (models as JsonObject)[tname]
      } else if (hasKey(rsystems, tname)) {
        comp = (rsystems as JsonObject)[tname]
      } else if (hasKey(loaders, tname)) {
        throw new ExpressionTemplateError(
          'template_inject_target_is_loader',
          `coupling entry \`expression_template_imports\` key '${tname}' resolves to a data loader, which is pure I/O with no expression positions to rewrite (esm-spec §9.7.10 / §14).`,
        )
      } else {
        throw new ExpressionTemplateError(
          'template_inject_target_not_component',
          `coupling entry \`expression_template_imports\` key '${tname}' resolves to neither a top-level model, reaction system, nor data loader (esm-spec §9.7.10). Nested \`Parent.Child\` targets are out of scope.`,
        )
      }
      if (!isObject(comp)) {
        throw new ExpressionTemplateError(
          'template_inject_target_not_component',
          `coupling entry \`expression_template_imports\` key '${tname}' does not name a component object (esm-spec §9.7.10).`,
        )
      }
      if (!Array.isArray(imports)) {
        throw new ExpressionTemplateError(
          'template_import_not_library',
          `coupling entry \`expression_template_imports\` value for '${tname}' must be a list of §9.7.2 import entries (esm-spec §9.7.10 / §10.8).`,
        )
      }
      appendComponentImports(comp, imports)
    }
    delete entry.expression_template_imports
  }
}

/**
 * esm-spec §9.7.10 forms A + B: if `raw` needs a scope-directed injection (a
 * non-empty subsystem-ref edge list `injected`, or a coupling entry carrying
 * an injection map), return a fresh plain-object tree with the injected
 * imports folded into the target components' own `expression_template_imports`,
 * ready for `resolveTemplateMachinery`. Returns `null` when no injection
 * applies, so the caller keeps its original fast path.
 */
export function applyScopeInjections(
  raw: unknown,
  injected: readonly unknown[] = [],
): JsonObject | null {
  if (!hasScopeInjection(raw, injected)) return null
  const root = deepClone(raw) as JsonObject
  applySubsystemRefInjection(root, injected)
  applyCouplingInjections(root)
  return root
}
