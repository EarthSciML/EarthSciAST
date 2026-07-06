/**
 * Load-time rewrite pass for `expression_templates` (esm-spec §9.6 /
 * docs/rfcs/ast-expression-templates.md, docs/rfcs/open-op-namespace-fixpoint-rewrite.md).
 *
 * An `expression_templates` entry is a **rewrite rule** with `params`
 * (metavariables), a `body` (the replacement Expression), an optional
 * integer `priority`, and an optional `match` pattern. This single engine
 * covers both application modes:
 *
 *   - **No `match`** — the entry is applied only by an explicit
 *     `apply_expression_template` node that names it and supplies
 *     per-parameter `bindings` (named-template expansion).
 *   - **With `match`** — the entry is an *auto-applied* rewrite rule.
 *     `match` is a pattern Expression in which the params are wildcards:
 *     a param in an operand/`args` position binds to the matched sub-AST;
 *     a param in a scalar field (e.g. `dim`, `side`, or a custom `attrs.<key>`)
 *     binds to the matched literal. The rule fires wherever the pattern
 *     structurally matches a node.
 *
 * Rewriting is an **outermost-first, priority-ordered, bounded-fixpoint**
 * process (esm-spec §9.6.3; mirrors the Julia reference `_rewrite_pass` /
 * `_rewrite_to_fixpoint`). Rule application proceeds in **passes**; one pass
 * (`onePass`) is a single **pre-order (outermost-first)** walk of the tree. At
 * each node visited the engine first tries to fire a rule AT that node before
 * descending: an `apply_expression_template` op is expanded (counts as a
 * rewrite), otherwise the structurally-matching `match` rule of highest
 * `priority` (integer, default 0; ties broken by DECLARATION order) fires. A
 * fired rule's `body` replaces the node and the walk does **not** descend into
 * that freshly-produced body during the current pass (it is revisited next
 * pass). If nothing fires, the walk descends into children. Passes repeat until
 * a pass performs **zero** rewrites (the fixpoint) or until
 * `MAX_REWRITE_PASSES = 64` productive passes have run without converging, in
 * which case the file is rejected with `rewrite_rule_nonterminating`. The pass
 * bound — NOT a static check — is the authoritative termination guard, so a
 * self-reintroducing rule simply fails to converge. Because selection and
 * traversal are fully deterministic, all bindings produce byte-identical
 * fixpoints.
 *
 * After convergence the component carries no `expression_templates` block and
 * no `apply_expression_template` ops — downstream consumers see only normal
 * Expression ASTs (Option A round-trip). Any rewrite-target op (e.g. a spatial
 * `D`) that survives the fixpoint into an evaluation position is caught later by
 * the `unlowered_operator` gate (`evaluateExpression`), not here.
 *
 * Operates on the pre-coercion JSON view (plain objects) — runs in
 * `load()` after schema validation but before typed coercion.
 *
 * Errors:
 *   - apply_expression_template_unknown_template
 *   - apply_expression_template_bindings_mismatch
 *   - apply_expression_template_recursive_body
 *   - apply_expression_template_version_too_old
 *   - apply_expression_template_invalid_declaration
 *   - rewrite_rule_nonterminating
 *
 * plus the esm-spec §9.7 template-library / metaparameter codes (§9.6.6,
 * raised from `template_imports.ts` and `ref-loading.ts`):
 *
 *   - template_import_version_too_old
 *   - template_import_unresolved
 *   - template_import_not_library
 *   - subsystem_ref_is_template_library
 *   - template_import_cycle
 *   - template_import_name_conflict
 *   - template_import_unknown_name
 *   - template_import_index_set_conflict
 *   - template_body_expansion_too_deep
 *   - metaparameter_unbound
 *   - metaparameter_type_error
 *   - metaparameter_name_conflict
 */

import { isNumericLiteral, numericValue } from './numeric-literal.js'

const APPLY_OP = 'apply_expression_template'

/**
 * Geometry-kernel ops whose `manifold` scalar field is restricted to the
 * closed manifold registry (CONFORMANCE_SPEC §5.8.4). The document schema
 * admits any string in the `manifold` position so a template `body` can carry
 * a parameter name there (esm-spec §9.6.1 scalar-field substitution site); the
 * closed set is enforced by `validateGeometryManifolds` on the EXPANDED form
 * per esm-spec §9.6.4.
 */
const GEOMETRY_MANIFOLD_OPS = new Set(['intersect_polygon', 'polygon_intersection_area'])
const GEOMETRY_MANIFOLD_VALUES = new Set(['planar', 'spherical', 'geodesic'])

/**
 * Maximum number of productive rewrite passes before a file is rejected as
 * non-converging (esm-spec §9.6.3, diagnostic `rewrite_rule_nonterminating`).
 * Pinned identically across all bindings so the accept/reject decision — and
 * the resulting fixpoint — is byte-identical everywhere.
 */
const MAX_REWRITE_PASSES = 64

export class ExpressionTemplateError extends Error {
  constructor(public code: string, message: string) {
    super(`[${code}] ${message}`)
    this.name = 'ExpressionTemplateError'
  }
}

type Json = unknown
type TemplateDecl = {
  params: string[]
  body: Json
  match?: Json
  priority?: unknown
  /** Static match-scoping constraints (esm-spec §9.6.1 `where`). */
  where?: unknown
}
/** Named templates invoked explicitly via `apply_expression_template` (no `match`). */
type Templates = Record<string, TemplateDecl>

/** An auto-applied rewrite rule (a template carrying a `match` pattern). */
interface MatchRule {
  name: string
  params: Set<string>
  match: Json
  body: Json
  /** Selection precedence (esm-spec §9.6.3): higher fires first, ties by declIndex. */
  priority: number
  /** Declaration order (0-based) — the tie-breaker under equal priority. */
  declIndex: number
  /**
   * Registered `where` constraints (param → required ordered shape) or `null`
   * when the rule carries no `where` block (esm-spec §9.6.1). Index-set names
   * are already checked against the consuming registry at registration.
   */
  whereConstraint: Record<string, string[]> | null
}

/** The static shape environment of one component (variable name → declared shape). */
type ShapeEnv = Record<string, string[]>
const EMPTY_SHAPE_ENV: ShapeEnv = {}

function isObject(v: unknown): v is Record<string, unknown> {
  return (
    typeof v === 'object' && v !== null && !Array.isArray(v) && !isNumericLiteral(v)
  )
}

/**
 * The `priority` of a `match` rule (esm-spec §9.6.3): higher fires first,
 * ties break by declaration order. Absent ⇒ 0. The schema constrains
 * `priority` to an integer; any numeric encoding is coerced defensively.
 */
function rulePriority(decl: TemplateDecl): number {
  const p: unknown = decl.priority
  if (p === undefined || p === null) return 0
  if (typeof p === 'boolean') return 0
  const n = numericValue(p)
  if (n !== undefined) return Math.round(n)
  if (typeof p === 'number' && Number.isFinite(p)) return Math.round(p)
  return 0
}

/**
 * Structural deep equality over the JSON AST, treating plain `number`
 * and tagged `NumericLiteral` leaves as equal when their numeric values
 * agree. Used for match-binding consistency, pattern literal checks, and
 * the §9.7.4 / §9.7.5 deep-equal dedup of diamond imports.
 */
export function deepEqual(a: Json, b: Json): boolean {
  if (a === b) return true
  const av = numericValue(a)
  const bv = numericValue(b)
  if (av !== undefined || bv !== undefined) return av !== undefined && av === bv
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false
    for (let i = 0; i < a.length; i++) if (!deepEqual(a[i], b[i])) return false
    return true
  }
  if (isObject(a) && isObject(b)) {
    const ak = Object.keys(a)
    const bk = Object.keys(b)
    if (ak.length !== bk.length) return false
    for (const k of ak) {
      if (!Object.prototype.hasOwnProperty.call(b, k)) return false
      if (!deepEqual(a[k], b[k])) return false
    }
    return true
  }
  return false
}

/**
 * Attempt to structurally match `pattern` against `node`, treating any
 * bare string in `params` as a wildcard metavariable. On success the
 * `bindings` map is populated (param → bound sub-AST for operand/`args`
 * positions, param → matched literal for scalar fields — including a custom
 * `attrs.<key>` slot) and `true` is returned. Repeated occurrences of a
 * metavariable must bind consistently.
 *
 * Pattern object fields are matched by key; node keys absent from the
 * pattern are ignored (so a partial operator pattern listing only
 * `op`/`args`/`dim` still matches a node that carries extra fields).
 */
function matchPattern(
  pattern: Json,
  node: Json,
  params: Set<string>,
  bindings: Record<string, Json>,
): boolean {
  // Metavariable: binds to whatever node occupies this position (sub-AST
  // in an operand/`args` slot, literal in a scalar field / `attrs.<key>`).
  if (typeof pattern === 'string' && params.has(pattern)) {
    if (Object.prototype.hasOwnProperty.call(bindings, pattern)) {
      return deepEqual(bindings[pattern], node)
    }
    bindings[pattern] = node
    return true
  }
  // Literal string (a concrete op name / variable reference): exact match.
  if (typeof pattern === 'string') return pattern === node
  // Numeric literal (plain or tagged): match by value.
  if (typeof pattern === 'number' || isNumericLiteral(pattern)) {
    const pv = numericValue(pattern)
    const nv = numericValue(node)
    return pv !== undefined && pv === nv
  }
  // Array (an `args`/operand list): element-wise, equal length.
  if (Array.isArray(pattern)) {
    if (!Array.isArray(node) || node.length !== pattern.length) return false
    for (let i = 0; i < pattern.length; i++) {
      if (!matchPattern(pattern[i], node[i], params, bindings)) return false
    }
    return true
  }
  // Object (an operator node, or a nested `attrs` object): node must be an
  // object that carries every key the pattern specifies (extra node keys are
  // allowed). Generic recursion is what makes `attrs.<key>` metavariables work.
  if (isObject(pattern)) {
    if (!isObject(node)) return false
    for (const k of Object.keys(pattern)) {
      if (!Object.prototype.hasOwnProperty.call(node, k)) return false
      if (!matchPattern(pattern[k], node[k], params, bindings)) return false
    }
    return true
  }
  // null / boolean.
  return deepEqual(pattern, node)
}

// ---------------------------------------------------------------------------
// Static match-scoping constraints (`where`, esm-spec §9.6.1;
// docs/rfcs/match-pattern-scoping-constraints.md)
// ---------------------------------------------------------------------------

/**
 * The static shape environment of one component: every declared variable name
 * mapped to its declared `shape` (ordered index-set names). This is the ONLY
 * information a `where` constraint may consult (esm-spec §9.6.1) — declared
 * shapes at lowering time, never runtime values — so constraint evaluation is
 * fully static and the §9.6.3 determinism contract is untouched. Variables with
 * no `shape` (scalars) are absent, as are reaction-system species / parameters
 * (which carry no `shape` field): a shape-constrained rule can only fire on a
 * declared, shaped model variable.
 */
function componentShapeEnv(comp: Record<string, unknown>): ShapeEnv {
  const env: ShapeEnv = {}
  const vars = comp.variables
  if (!isObject(vars)) return env
  for (const [vn, vd] of Object.entries(vars)) {
    if (!isObject(vd)) continue
    const shp = vd.shape
    if (!Array.isArray(shp)) continue
    if (!shp.every((s) => typeof s === 'string')) continue
    env[vn] = shp.map((s) => String(s))
  }
  return env
}

/**
 * Evaluate a registered `where` constraint map (param → required shape) against
 * the bindings produced by a successful structural match (esm-spec §9.6.1). A
 * constraint on param `p` holds iff `bindings[p]` is a BARE variable-reference
 * string naming an entry of `shapeEnv` whose declared shape equals the required
 * list exactly (same names, same order). Everything else — a compound sub-AST, a
 * numeric literal, a scalar-field-bound literal, a scoped reference, an
 * undeclared name, a scalar variable, or a param that never bound — fails. The
 * judgment is deliberately syntactic and conservative: no shape inference over
 * compound expressions, so eligibility is byte-identical across bindings.
 */
function whereSatisfied(
  whereC: Record<string, string[]> | null,
  bindings: Record<string, Json>,
  shapeEnv: ShapeEnv,
): boolean {
  if (whereC === null) return true
  for (const [p, req] of Object.entries(whereC)) {
    const b = Object.prototype.hasOwnProperty.call(bindings, p) ? bindings[p] : undefined
    if (typeof b !== 'string') return false
    if (!Object.prototype.hasOwnProperty.call(shapeEnv, b)) return false
    const shp = shapeEnv[b]!
    if (shp.length !== req.length) return false
    for (let i = 0; i < req.length; i++) {
      if (shp[i] !== req[i]) return false
    }
  }
  return true
}

/**
 * Normalize a template's `where` block into the registered constraint map
 * (param → required shape), checking every referenced index-set name against
 * the CONSUMING document's merged `index_sets` registry (`isetNames`). An
 * unknown name is `template_constraint_unknown_index_set` (esm-spec §9.6.6) —
 * raised here, at rule registration in the consuming component, not when a
 * library file is loaded standalone. Assumes structural validity
 * (`validateTemplates` already ran). Returns `null` when there is no `where`.
 */
function registeredWhere(
  decl: TemplateDecl,
  isetNames: Set<string>,
  scope: string,
  tname: string,
): Record<string, string[]> | null {
  const whr = (decl as { where?: unknown }).where
  if (whr === undefined || whr === null) return null
  const out: Record<string, string[]> = {}
  for (const [p, cobj] of Object.entries(whr as Record<string, unknown>)) {
    const shp = (cobj as { shape?: unknown }).shape as unknown[]
    const req = shp.map((s) => String(s))
    for (const s of req) {
      if (!isetNames.has(s)) {
        throw new ExpressionTemplateError(
          'template_constraint_unknown_index_set',
          `${scope}.expression_templates.${tname}: where.${p}.shape names index set '${s}', which the consuming document's index_sets registry does not declare (esm-spec §9.6.1/§9.6.6)`,
        )
      }
    }
    out[p] = req
  }
  return out
}

function deepClone<T>(v: T): T {
  if (v === null || v === undefined) return v
  if (isNumericLiteral(v)) return v // preserve symbol-tagged literals as-is
  if (Array.isArray(v)) return v.map(deepClone) as unknown as T
  if (typeof v === 'object') {
    const out: Record<string, unknown> = {}
    for (const k of Object.keys(v as object)) out[k] = deepClone((v as Record<string, unknown>)[k])
    return out as unknown as T
  }
  return v
}

/** Substitute parameter occurrences in a template body. */
function substitute(body: Json, bindings: Record<string, Json>): Json {
  if (typeof body === 'string') {
    if (Object.prototype.hasOwnProperty.call(bindings, body)) {
      return deepClone(bindings[body])
    }
    return body
  }
  if (Array.isArray(body)) {
    return body.map((c) => substitute(c, bindings))
  }
  if (isObject(body)) {
    const out: Record<string, unknown> = {}
    for (const k of Object.keys(body)) {
      out[k] = substitute(body[k], bindings)
    }
    return out
  }
  return body
}

/**
 * Reject `apply_expression_template` nodes inside a `match` pattern
 * (esm-spec §9.7.3: match patterns MUST NOT reference templates).
 */
function assertNoNestedApply(body: Json, templateName: string, path: string): void {
  if (Array.isArray(body)) {
    for (let i = 0; i < body.length; i++) {
      assertNoNestedApply(body[i], templateName, `${path}/${i}`)
    }
    return
  }
  if (isObject(body)) {
    if (body.op === APPLY_OP) {
      throw new ExpressionTemplateError(
        'apply_expression_template_invalid_declaration',
        `expression_templates.${templateName}: \`match\` contains an 'apply_expression_template' node at ${path}; match patterns MUST NOT reference templates (esm-spec §9.7.3)`,
      )
    }
    for (const k of Object.keys(body)) {
      assertNoNestedApply(body[k], templateName, `${path}/${k}`)
    }
  }
}

export function validateTemplates(templates: Templates, scope: string): void {
  for (const [name, decl] of Object.entries(templates)) {
    if (!decl || typeof decl !== 'object') {
      throw new ExpressionTemplateError(
        'apply_expression_template_invalid_declaration',
        `${scope}.expression_templates.${name}: entry must be an object with params + body`,
      )
    }
    // `params` MAY be empty (esm-spec §9.6.1, 0.8.0): a zero-parameter
    // template is a named constant fragment (common in library files).
    const params = (decl as { params?: unknown }).params
    if (!Array.isArray(params)) {
      throw new ExpressionTemplateError(
        'apply_expression_template_invalid_declaration',
        `${scope}.expression_templates.${name}: 'params' must be an array of strings`,
      )
    }
    const seen = new Set<string>()
    for (const p of params) {
      if (typeof p !== 'string' || p.length === 0) {
        throw new ExpressionTemplateError(
          'apply_expression_template_invalid_declaration',
          `${scope}.expression_templates.${name}: param names must be non-empty strings`,
        )
      }
      if (seen.has(p)) {
        throw new ExpressionTemplateError(
          'apply_expression_template_invalid_declaration',
          `${scope}.expression_templates.${name}: param '${p}' is declared twice`,
        )
      }
      seen.add(p)
    }
    if (!('body' in (decl as object))) {
      throw new ExpressionTemplateError(
        'apply_expression_template_invalid_declaration',
        `${scope}.expression_templates.${name}: 'body' is required`,
      )
    }
    // A body MAY reference other match-less in-scope templates via
    // apply_expression_template nodes (esm-spec §9.7.3); those are checked
    // (acyclic, depth <= MAX_TEMPLATE_EXPANSION_DEPTH) and inlined at
    // registration by `composeTemplateBodies` — the old any-nesting rejection
    // is now cycle-only (`apply_expression_template_recursive_body`).
    //
    // esm-spec §9.6.3: nontermination is NOT checked statically any more — the
    // bounded fixpoint (`MAX_REWRITE_PASSES`) is the authoritative guard, so a
    // self-reintroducing rule is rejected (`rewrite_rule_nonterminating`) only
    // when it actually fails to converge. A `match` pattern still MUST NOT
    // contain nested apply_expression_template ops.
    const match = (decl as { match?: Json }).match
    if (match !== undefined) {
      assertNoNestedApply(match, name, '/match')
    }

    // esm-spec §9.6.1 (0.8.0): an optional `where` block adds static
    // match-scoping constraints on the captured params. Structural validation
    // only, here; the unknown-index-set check runs at rule REGISTRATION in the
    // consuming component (where the merged `index_sets` registry is in scope)
    // — see `registeredWhere`.
    const whr = (decl as { where?: unknown }).where
    if (whr !== undefined && whr !== null) {
      if (match === undefined) {
        throw new ExpressionTemplateError(
          'apply_expression_template_invalid_declaration',
          `${scope}.expression_templates.${name}: 'where' is only admissible alongside 'match' — constraints scope an auto-applied rewrite rule, not a named fragment (esm-spec §9.6.1)`,
        )
      }
      if (!isObject(whr) || Object.keys(whr).length === 0) {
        throw new ExpressionTemplateError(
          'apply_expression_template_invalid_declaration',
          `${scope}.expression_templates.${name}: 'where' must be a non-empty object mapping declared params to constraint objects`,
        )
      }
      for (const [p, cobj] of Object.entries(whr)) {
        if (!seen.has(p)) {
          throw new ExpressionTemplateError(
            'apply_expression_template_invalid_declaration',
            `${scope}.expression_templates.${name}: 'where' constrains '${p}', which is not a declared param (esm-spec §9.6.1)`,
          )
        }
        if (!isObject(cobj)) {
          throw new ExpressionTemplateError(
            'apply_expression_template_invalid_declaration',
            `${scope}.expression_templates.${name}: where.${p} must be a constraint object (v1 admits exactly the 'shape' kind)`,
          )
        }
        const ckeys = Object.keys(cobj)
        if (!(ckeys.length === 1 && ckeys[0] === 'shape')) {
          throw new ExpressionTemplateError(
            'apply_expression_template_invalid_declaration',
            `${scope}.expression_templates.${name}: where.${p} carries constraint kind(s) ${[...ckeys].sort().join(', ')}; the v1 constraint vocabulary is exactly {shape} (esm-spec §9.6.1)`,
          )
        }
        const shp = (cobj as { shape?: unknown }).shape
        if (!Array.isArray(shp) || shp.length === 0) {
          throw new ExpressionTemplateError(
            'apply_expression_template_invalid_declaration',
            `${scope}.expression_templates.${name}: where.${p}.shape must be a non-empty array of index-set names`,
          )
        }
        for (const s of shp) {
          if (typeof s !== 'string' || s.length === 0) {
            throw new ExpressionTemplateError(
              'apply_expression_template_invalid_declaration',
              `${scope}.expression_templates.${name}: where.${p}.shape entries must be non-empty strings`,
            )
          }
        }
      }
    }
  }
}

/**
 * Maximum template-body reference-chain depth (counted in TEMPLATES along the
 * longest chain, so a 33-template chain is rejected while a 32-template chain
 * is accepted) before a file is rejected with
 * `template_body_expansion_too_deep` (esm-spec §9.7.3). Pinned identically
 * across all bindings.
 */
export const MAX_TEMPLATE_EXPANSION_DEPTH = 32

/** Collect the `name`s of every `apply_expression_template` node in a tree. */
function collectApplyNames(x: Json, out: string[]): string[] {
  if (Array.isArray(x)) {
    for (const c of x) collectApplyNames(c, out)
    return out
  }
  if (isObject(x)) {
    if (x.op === APPLY_OP && typeof x.name === 'string') out.push(x.name)
    for (const k of Object.keys(x)) collectApplyNames(x[k], out)
  }
  return out
}

/**
 * Inline every `apply_expression_template` node in `node` against
 * `templates`, post-order (so the bindings' own sub-ASTs are inlined first).
 * Referenced bodies are already closed when this runs in topological order,
 * so a single `expandApply` produces an apply-free subtree.
 */
function inlineApplies(node: Json, templates: Templates, scope: string): Json {
  if (Array.isArray(node)) {
    return node.map((c) => inlineApplies(c, templates, scope))
  }
  if (!isObject(node)) return node
  const out: Record<string, unknown> = {}
  for (const k of Object.keys(node)) {
    out[k] = inlineApplies(node[k], templates, scope)
  }
  if (out.op === APPLY_OP) {
    return expandApply(out, templates, scope)
  }
  return out
}

/**
 * Registration-time body composition (esm-spec §9.7.3): template bodies MAY
 * reference other in-scope MATCH-LESS templates via `apply_expression_template`
 * nodes. Builds the body-reference graph, rejects cycles
 * (`apply_expression_template_recursive_body`) and chains deeper than
 * `MAX_TEMPLATE_EXPANSION_DEPTH` templates (`template_body_expansion_too_deep`),
 * then inlines dependencies-first by pure substitution — confluent, so
 * topological order cannot affect the result. Afterwards every `body` is a
 * closed Expression AST with zero `apply_expression_template` nodes; runs
 * BEFORE the §9.6.3 fixpoint ever consults a `match` rule. Mutates the decl
 * objects in `templates` in place.
 */
export function composeTemplateBodies(templates: Templates, scope: string): void {
  const names = Object.keys(templates)
  if (names.length === 0) return
  const refs: Record<string, string[]> = {}
  let anyRefs = false
  for (const name of names) {
    refs[name] = collectApplyNames((templates[name] as { body?: Json }).body, [])
    if (refs[name]!.length > 0) anyRefs = true
  }
  if (!anyRefs) return

  for (const name of [...names].sort()) {
    for (const r of refs[name]!) {
      const tdecl = templates[r]
      if (!tdecl) {
        throw new ExpressionTemplateError(
          'apply_expression_template_unknown_template',
          `${scope}.expression_templates.${name}: body references undeclared template '${r}' (esm-spec §9.7.3)`,
        )
      }
      if ((tdecl as { match?: Json }).match !== undefined) {
        throw new ExpressionTemplateError(
          'apply_expression_template_unknown_template',
          `${scope}.expression_templates.${name}: body references '${r}', a \`match\` rewrite rule — only match-less templates are invocable by name (esm-spec §9.7.3)`,
        )
      }
    }
  }

  // DFS over the reference graph: cycle detection, chain-depth bound, and a
  // dependencies-first (post-) order for inlining.
  const state: Record<string, number> = {} // 1 = on stack, 2 = done
  const depth: Record<string, number> = {} // templates on the longest chain
  const order: string[] = []
  const chain: string[] = []
  const visit = (name: string): number => {
    const st = state[name] ?? 0
    if (st === 1) {
      const cyc = [...chain.slice(chain.indexOf(name)), name]
      throw new ExpressionTemplateError(
        'apply_expression_template_recursive_body',
        `${scope}.expression_templates: template-body reference cycle ${cyc.join(' -> ')} (esm-spec §9.7.3)`,
      )
    }
    if (st === 2) return depth[name]!
    state[name] = 1
    chain.push(name)
    let d = 1
    for (const r of refs[name]!) {
      d = Math.max(d, 1 + visit(r))
    }
    chain.pop()
    state[name] = 2
    depth[name] = d
    if (d > MAX_TEMPLATE_EXPANSION_DEPTH) {
      throw new ExpressionTemplateError(
        'template_body_expansion_too_deep',
        `${scope}.expression_templates.${name}: body-reference chain of ${d} templates exceeds MAX_TEMPLATE_EXPANSION_DEPTH=${MAX_TEMPLATE_EXPANSION_DEPTH} (esm-spec §9.7.3)`,
      )
    }
    order.push(name)
    return d
  }
  for (const name of [...names].sort()) visit(name)

  for (const name of order) {
    if (refs[name]!.length === 0) continue
    const decl = templates[name] as { body: Json }
    decl.body = inlineApplies(decl.body, templates, `${scope}.expression_templates.${name}`)
  }
}

/**
 * Expand a single `apply_expression_template` node against `templates`.
 * The template `body` is instantiated by pure structural substitution of the
 * supplied `bindings`; the bindings are spliced in AS-IS (not pre-scanned) —
 * any `apply_expression_template` or match-able node inside a binding is
 * rewritten in a SUBSEQUENT pass of the outermost-first fixpoint, never within
 * the current pass (esm-spec §9.6.3).
 */
function expandApply(
  node: Record<string, unknown>,
  templates: Templates,
  scope: string,
): Json {
  const name = node.name
  if (typeof name !== 'string' || name.length === 0) {
    throw new ExpressionTemplateError(
      'apply_expression_template_invalid_declaration',
      `${scope}: apply_expression_template node missing or empty 'name'`,
    )
  }
  const decl = templates[name]
  if (!decl) {
    throw new ExpressionTemplateError(
      'apply_expression_template_unknown_template',
      `${scope}: apply_expression_template references undeclared template '${name}'`,
    )
  }
  const bindings = node.bindings
  if (!isObject(bindings)) {
    throw new ExpressionTemplateError(
      'apply_expression_template_bindings_mismatch',
      `${scope}: apply_expression_template '${name}' missing 'bindings' object`,
    )
  }
  const provided = new Set(Object.keys(bindings))
  const declared = new Set(decl.params)
  for (const p of decl.params) {
    if (!provided.has(p)) {
      throw new ExpressionTemplateError(
        'apply_expression_template_bindings_mismatch',
        `${scope}: apply_expression_template '${name}' missing binding for param '${p}'`,
      )
    }
  }
  for (const p of provided) {
    if (!declared.has(p)) {
      throw new ExpressionTemplateError(
        'apply_expression_template_bindings_mismatch',
        `${scope}: apply_expression_template '${name}' supplies unknown param '${p}'`,
      )
    }
  }
  const resolvedBindings: Record<string, Json> = {}
  for (const [k, v] of Object.entries(bindings)) {
    resolvedBindings[k] = v
  }
  return substitute(decl.body, resolvedBindings)
}

interface PassResult {
  node: Json
  changed: boolean
}

/**
 * One pre-order (outermost-first) rewrite pass over `node` (esm-spec §9.6.3).
 * At each object node the engine first tries to fire a rule AT the node before
 * descending:
 *
 *   1. an `apply_expression_template` op is expanded (`expandApply`), OR
 *   2. the first rule in `sortedRules` (pre-sorted highest-`priority`-first,
 *      ties by declaration order) whose `match` pattern structurally matches
 *      the node fires.
 *
 * A fired rule's body replaces the node and the walk does NOT descend into that
 * freshly-produced body during this pass (it is revisited next pass). If nothing
 * fires, the walk descends into the node's children. `changed` is `true` iff any
 * rewrite occurred in this subtree; `last.op` records the op of the most recent
 * rewrite, for the non-convergence diagnostic.
 */
function onePass(
  node: Json,
  templates: Templates,
  sortedRules: MatchRule[],
  scope: string,
  last: { op: string },
  shapeEnv: ShapeEnv,
): PassResult {
  if (Array.isArray(node)) {
    let changed = false
    const out = node.map((c) => {
      const r = onePass(c, templates, sortedRules, scope, last, shapeEnv)
      changed = changed || r.changed
      return r.node
    })
    return { node: out, changed }
  }
  if (!isObject(node)) {
    return { node, changed: false }
  }
  // (1) Outermost-first: fire a rule AT this node before descending.
  if (node.op === APPLY_OP) {
    last.op = APPLY_OP
    return { node: expandApply(node, templates, scope), changed: true }
  }
  for (const rule of sortedRules) {
    const bindings: Record<string, Json> = {}
    // Constraint filtering is part of match ELIGIBILITY (esm-spec §9.6.3
    // constraint 2): a `where`-excluded rule is treated exactly like a
    // non-matching rule at this node, so a high-priority excluded rule never
    // shadows a lower-priority rule that does fire.
    if (
      matchPattern(rule.match, node, rule.params, bindings) &&
      whereSatisfied(rule.whereConstraint, bindings, shapeEnv)
    ) {
      last.op = typeof node.op === 'string' ? node.op : ''
      return { node: substitute(rule.body, bindings), changed: true }
    }
  }
  // (2) No rule fired here — descend into children.
  let changed = false
  const out: Record<string, unknown> = {}
  for (const k of Object.keys(node)) {
    const r = onePass(node[k], templates, sortedRules, scope, last, shapeEnv)
    out[k] = r.node
    changed = changed || r.changed
  }
  return { node: out, changed }
}

/**
 * Drive `onePass` to a fixpoint (esm-spec §9.6.3): repeat pre-order passes
 * until a pass performs zero rewrites, or reject the file with
 * `rewrite_rule_nonterminating` once `MAX_REWRITE_PASSES` productive passes have
 * run without converging. This bound — not a static check — is the authoritative
 * termination guard, so a self-reintroducing rule fails to converge rather than
 * being flagged up front.
 */
function rewriteToFixpoint(
  node: Json,
  templates: Templates,
  sortedRules: MatchRule[],
  scope: string,
  shapeEnv: ShapeEnv = EMPTY_SHAPE_ENV,
): Json {
  const last = { op: '' }
  let current = node
  for (let pass = 0; pass < MAX_REWRITE_PASSES; pass++) {
    const { node: next, changed } = onePass(current, templates, sortedRules, scope, last, shapeEnv)
    current = next
    if (!changed) return current // fixpoint reached
  }
  throw new ExpressionTemplateError(
    'rewrite_rule_nonterminating',
    `${scope}: expression-template rewriting did not converge within ` +
      `MAX_REWRITE_PASSES=${MAX_REWRITE_PASSES} passes (last rewritten op ` +
      `'${last.op}'). A \`match\` rule likely re-introduces its own pattern ` +
      `(esm-spec §9.6.3).`,
  )
}

/** Walk the file looking for apply_expression_template ops anywhere. */
function findStrayApplyOps(view: unknown): string[] {
  const hits: string[] = []
  const visit = (v: unknown, path: string): void => {
    if (Array.isArray(v)) {
      for (let i = 0; i < v.length; i++) visit(v[i], `${path}/${i}`)
      return
    }
    if (isObject(v)) {
      if (v.op === APPLY_OP) hits.push(path)
      for (const k of Object.keys(v)) visit(v[k], `${path}/${k}`)
    }
  }
  visit(view, '')
  return hits
}

function parseSemver(v: unknown): { major: number; minor: number; patch: number } | null {
  if (typeof v !== 'string') return null
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(v)
  if (!m) return null
  return { major: Number(m[1]), minor: Number(m[2]), patch: Number(m[3]) }
}

/**
 * Reject `apply_expression_template` and `expression_templates` in files
 * declaring `esm` < 0.4.0. Operates on the pre-coercion JSON view.
 */
export function rejectExpressionTemplatesPreV04(view: unknown): void {
  if (!isObject(view)) return
  const v = parseSemver((view as { esm?: unknown }).esm)
  if (!v) return
  const isPreV04 = v.major === 0 && v.minor < 4
  if (!isPreV04) return

  const offences: string[] = []
  // expression_templates blocks anywhere
  const root = view as Record<string, unknown>
  for (const compKind of ['models', 'reaction_systems'] as const) {
    const comps = root[compKind]
    if (!isObject(comps)) continue
    for (const [name, comp] of Object.entries(comps)) {
      if (isObject(comp) && 'expression_templates' in comp) {
        offences.push(`/${compKind}/${name}/expression_templates`)
      }
    }
  }
  // apply_expression_template ops anywhere in the AST
  for (const path of findStrayApplyOps(view)) offences.push(path)

  if (offences.length > 0) {
    throw new ExpressionTemplateError(
      'apply_expression_template_version_too_old',
      `expression_templates / apply_expression_template require esm >= 0.4.0; file declares ${(view as { esm?: string }).esm}. Offending paths: ${offences.join(', ')}`,
    )
  }
}

interface Component {
  expression_templates?: unknown
  [k: string]: unknown
}

/**
 * The rewrite context of one component: its named templates (consulted by
 * `apply_expression_template`) plus its auto-applied `match` rules pre-sorted
 * by (−priority, declarationIndex) — exactly what `rewriteToFixpoint` needs.
 */
interface RewriteContext {
  templates: Templates
  matchRules: MatchRule[]
  /** The enclosing component's static shape environment for `where` (esm-spec §9.6.1). */
  shapeEnv: ShapeEnv
}

/**
 * Build the rewrite context from a component's raw `expression_templates`
 * block: validate declarations, compose body references (esm-spec §9.7.3),
 * and register `match` rules in deterministic selection order (§9.6.3). Each
 * rule's `where` constraints are normalized and checked against the consuming
 * document's merged `index_sets` registry (`isetNames`,
 * `template_constraint_unknown_index_set`).
 */
function buildRewriteContext(
  tplRaw: Record<string, unknown>,
  isetNames: Set<string>,
  shapeEnv: ShapeEnv,
  scope: string,
): RewriteContext {
  const templates: Templates = {}
  const matchRules: MatchRule[] = []
  const all: Templates = {}
  for (const [tname, tdecl] of Object.entries(tplRaw)) {
    all[tname] = tdecl as TemplateDecl
  }
  validateTemplates(all, scope)
  // Registration-time body composition (esm-spec §9.7.3): inline body
  // references to match-less in-scope templates as a statically-checked
  // acyclic DAG, so every rule body the fixpoint sees is a closed AST.
  composeTemplateBodies(all, scope)
  // Object key order in JS preserves declaration order, so the
  // enumeration index IS the authored declaration order.
  let declIndex = 0
  for (const [tname, decl] of Object.entries(all)) {
    templates[tname] = decl
    if (decl.match !== undefined) {
      matchRules.push({
        name: tname,
        params: new Set(decl.params),
        match: decl.match,
        body: decl.body,
        priority: rulePriority(decl),
        declIndex,
        // `where` registration: normalize constraints and resolve every
        // referenced index-set name against the consuming registry (esm-spec
        // §9.6.1; `template_constraint_unknown_index_set`).
        whereConstraint: registeredWhere(decl, isetNames, scope, tname),
      })
    }
    declIndex++
  }
  // Deterministic selection order (esm-spec §9.6.3): highest `priority`
  // first, ties broken by declaration order (earliest wins).
  matchRules.sort((a, b) => b.priority - a.priority || a.declIndex - b.declIndex)
  return { templates, matchRules, shapeEnv }
}

/** True if any model / reaction_system declares an expression_templates block. */
function hasExpressionTemplatesBlock(root: Record<string, unknown>): boolean {
  for (const compKind of ['models', 'reaction_systems'] as const) {
    const comps = root[compKind]
    if (!isObject(comps)) continue
    for (const comp of Object.values(comps)) {
      if (isObject(comp) && isObject(comp.expression_templates)) return true
    }
  }
  return false
}

/**
 * Rewrite all `expression_templates` in the given file: expand explicit
 * `apply_expression_template` nodes AND auto-apply `match` rules to a fixpoint
 * per component (outermost-first, priority-ordered, bounded — esm-spec §9.6.3).
 * Returns a new file object with templates applied and `expression_templates`
 * blocks removed.
 *
 * Pre-condition: the input has been schema-validated.
 */
/**
 * Post-expansion validator (esm-spec §9.6.4): every `intersect_polygon` /
 * `polygon_intersection_area` node OUTSIDE an `expression_templates` block
 * must carry a `manifold` drawn from the closed set {planar, spherical,
 * geodesic}. Template bodies are skipped — a parameter name in the `manifold`
 * position of a `body` is a legal scalar-field substitution site (esm-spec
 * §9.6.1); by the time this validator runs on a loaded document every such
 * site has been substituted, so an out-of-set value here is a real defect
 * (e.g. a template invocation binding the manifold parameter to a non-member
 * literal). Throws `ExpressionTemplateError` with code
 * `geometry_manifold_invalid`.
 */
export function validateGeometryManifolds(tree: unknown, path = ''): void {
  if (Array.isArray(tree)) {
    for (let i = 0; i < tree.length; i++) validateGeometryManifolds(tree[i], `${path}/${i}`)
    return
  }
  if (!isObject(tree)) return
  const node = tree as Record<string, unknown>
  if (typeof node.op === 'string' && GEOMETRY_MANIFOLD_OPS.has(node.op) && 'manifold' in node) {
    const m = node.manifold
    if (!(typeof m === 'string' && GEOMETRY_MANIFOLD_VALUES.has(m))) {
      throw new ExpressionTemplateError(
        'geometry_manifold_invalid',
        `${path}: \`${node.op}\` carries manifold ${JSON.stringify(m)}, not a member of the closed set {planar, spherical, geodesic}. The manifold enum is enforced on the expanded form (esm-spec §9.6.4; CONFORMANCE_SPEC §5.8.4) — a template parameter substituted into this scalar field must be bound to one of the closed-set literals.`,
      )
    }
  }
  for (const k of Object.keys(node)) {
    // Pre-substitution template trees; params may legally occupy the manifold
    // position there (esm-spec §9.6.1).
    if (k === 'expression_templates') continue
    validateGeometryManifolds(node[k], `${path}/${k}`)
  }
}

/**
 * Post-expansion validator (esm-spec §4.3.2 / §9.6.4): every `makearray`
 * region bound pair `[start, stop]` on the expanded, metaparameter-folded tree
 * must satisfy `stop >= start - 1`. `stop == start - 1` is the canonical EMPTY
 * bound — the region covers no elements (the spelling an interior region like
 * `[2, N-1]` folds to at the minimum admissible extent `N = 2`).
 * `stop < start - 1` is INVERTED and rejected with `makearray_region_inverted`:
 * it is almost always an authoring bug (an interior stencil instantiated below
 * its minimum extent, e.g. `[2, N-1]` at `N = 1` folding to `[2, 0]`), and
 * silently treating it as empty would hide the defect. Template bodies are
 * skipped — pre-substitution bounds may legally carry metaparameter names
 * there; only concrete integer pairs are checked (a fully-folded document tree
 * carries nothing else in bound position). Throws `ExpressionTemplateError`
 * with code `makearray_region_inverted`.
 */
export function validateMakearrayRegions(tree: unknown, path = ''): void {
  if (Array.isArray(tree)) {
    for (let i = 0; i < tree.length; i++) validateMakearrayRegions(tree[i], `${path}/${i}`)
    return
  }
  if (!isObject(tree)) return
  const node = tree as Record<string, unknown>
  if (node.op === 'makearray') {
    const regions = node.regions
    if (Array.isArray(regions)) {
      for (let ri = 0; ri < regions.length; ri++) {
        const region = regions[ri]
        if (!Array.isArray(region)) continue
        for (let di = 0; di < region.length; di++) {
          const bounds = region[di]
          if (!Array.isArray(bounds) || bounds.length !== 2) continue
          const lo = intBound(bounds[0])
          const hi = intBound(bounds[1])
          if (lo === undefined || hi === undefined) continue
          if (hi < lo - 1) {
            throw new ExpressionTemplateError(
              'makearray_region_inverted',
              `${path}: makearray regions[${ri}] dimension ${di} bound pair [${lo}, ${hi}] is inverted (stop < start - 1). An empty bound is spelled [start, start-1] and contributes no elements (esm-spec §4.3.2); a further-inverted pair is an authoring error — e.g. an interior stencil region [2, N-1] instantiated at N below the scheme's minimum extent (§9.6.8).`,
            )
          }
        }
      }
    }
  }
  for (const k of Object.keys(node)) {
    // Template bodies/matches are pre-substitution trees; bounds may legally
    // carry metaparameter names or fold later (esm-spec §9.7.6).
    if (k === 'expression_templates') continue
    validateMakearrayRegions(node[k], `${path}/${k}`)
  }
}

/**
 * A makearray region bound entry read as a concrete integer (plain JSON
 * integer or an int-tagged `NumericLiteral`), or `undefined` for anything else
 * (a still-symbolic bound, a float, a boolean). Only integer pairs are checked.
 */
function intBound(v: unknown): number | undefined {
  if (typeof v === 'boolean') return undefined
  if (typeof v === 'number') return Number.isInteger(v) ? v : undefined
  if (isNumericLiteral(v)) return v.kind === 'int' ? v.value : undefined
  return undefined
}

export function lowerExpressionTemplates<T extends object>(file: T): T {
  rejectExpressionTemplatesPreV04(file)

  if (!isObject(file)) return file
  const root = file as Record<string, unknown>

  // Scan globally for apply ops (orphan-op detection) and for any
  // expression_templates block (a component may carry `match` rules that
  // must run even when there are no apply ops).
  const globalOps = findStrayApplyOps(file)
  if (globalOps.length === 0 && !hasExpressionTemplatesBlock(root)) {
    // Nothing to expand and no rules to apply; the §9.6.4 expanded-form
    // validators still run — the raw tree IS the expanded form. Then strip
    // empty expression_templates blocks for canonical-form invariance.
    validateGeometryManifolds(root)
    validateMakearrayRegions(root)
    return stripExpressionTemplates(file)
  }

  // The consuming document's merged index_sets registry (post-§9.7.5): the
  // namespace `where` shape constraints resolve against at registration
  // (esm-spec §9.6.1 — `template_constraint_unknown_index_set` for a name not
  // declared here).
  const isetNames = new Set<string>()
  if (isObject(root.index_sets)) {
    for (const k of Object.keys(root.index_sets)) isetNames.add(k)
  }

  // Walk both component families. Contexts of components that DECLARE an
  // expression_templates block are retained per family so the top-level
  // coupling walk below can rewrite variable_map expression transforms in
  // the receiving component's scope (esm-spec §9.6.4).
  const out = deepClone(root)
  const contextsByKind = {
    models: new Map<string, RewriteContext>(),
    reaction_systems: new Map<string, RewriteContext>(),
  }
  for (const compKind of ['models', 'reaction_systems'] as const) {
    const comps = out[compKind]
    if (!isObject(comps)) continue
    for (const [compName, compRaw] of Object.entries(comps)) {
      if (!isObject(compRaw)) continue
      const comp = compRaw as Component
      const tplRaw = comp.expression_templates
      // Static shape environment for `where` constraint evaluation
      // (esm-spec §9.6.1): declared variable shapes only.
      const shapeEnv = componentShapeEnv(comp)
      // `templates`  — every template keyed by name, consulted by
      //                `apply_expression_template` (order-independent).
      // `matchRules` — the auto-applied `match` rules, pre-sorted by
      //                (−priority, declarationIndex) so `onePass` takes the
      //                FIRST matching rule (esm-spec §9.6.3).
      let templates: Templates = {}
      let matchRules: MatchRule[] = []
      if (isObject(tplRaw)) {
        const ctx = buildRewriteContext(tplRaw, isetNames, shapeEnv, `${compKind}.${compName}`)
        templates = ctx.templates
        matchRules = ctx.matchRules
        contextsByKind[compKind].set(compName, ctx)
      }
      // Rewrite every property except expression_templates (we don't expand
      // inside template bodies — those are validated above) to a fixpoint.
      for (const k of Object.keys(comp)) {
        if (k === 'expression_templates') continue
        comp[k] = rewriteToFixpoint(
          comp[k],
          templates,
          matchRules,
          `${compKind}.${compName}.${k}`,
          shapeEnv,
        )
      }
      delete comp.expression_templates
    }
  }

  // Top-level coupling: a `variable_map` entry may carry an object-valued
  // Expression `transform` (esm-spec §8.6). It is rewritten to fixpoint in
  // the SAME rewrite context (named templates + match rules) as a field of
  // the RECEIVING component — the first dot-segment of the entry's `to`,
  // looked up under models then reaction_systems. A receiving component
  // that is absent or declares no templates leaves the transform
  // unrewritten (a stray apply op is then caught by the leftover check).
  const coupling = out.coupling
  if (Array.isArray(coupling)) {
    for (let i = 0; i < coupling.length; i++) {
      const entry = coupling[i]
      if (!isObject(entry) || entry.type !== 'variable_map') continue
      if (!isObject(entry.transform)) continue
      const to = entry.to
      if (typeof to !== 'string') continue
      const receiver = to.split('.')[0] ?? ''
      const ctx =
        contextsByKind.models.get(receiver) ?? contextsByKind.reaction_systems.get(receiver)
      if (!ctx) continue
      entry.transform = rewriteToFixpoint(
        entry.transform,
        ctx.templates,
        ctx.matchRules,
        `coupling[${i}].transform`,
        ctx.shapeEnv,
      )
    }
  }

  // After expansion, there must be no apply_expression_template ops left
  // anywhere in the file.
  const leftover = findStrayApplyOps(out)
  if (leftover.length > 0) {
    throw new ExpressionTemplateError(
      'apply_expression_template_unknown_template',
      `apply_expression_template ops remain after expansion at: ${leftover.join(', ')} — likely referenced from a component lacking an expression_templates block`,
    )
  }

  // Validators run on the expanded form (esm-spec §9.6.4): reject any
  // geometry-kernel node whose (possibly just-substituted) `manifold` is
  // outside the closed set, and any makearray region whose folded bound pair
  // is inverted (stop < start - 1; esm-spec §4.3.2).
  validateGeometryManifolds(out)
  validateMakearrayRegions(out)

  return out as T
}

function stripExpressionTemplates<T extends object>(file: T): T {
  if (!isObject(file)) return file
  const out = deepClone(file as Record<string, unknown>)
  for (const compKind of ['models', 'reaction_systems'] as const) {
    const comps = out[compKind]
    if (!isObject(comps)) continue
    for (const compRaw of Object.values(comps)) {
      if (isObject(compRaw) && 'expression_templates' in compRaw) {
        delete (compRaw as Record<string, unknown>).expression_templates
      }
    }
  }
  return out as T
}
