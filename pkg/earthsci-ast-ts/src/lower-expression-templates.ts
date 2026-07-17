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
 * Errors (raised directly by this file; the code STRINGS live in
 * `./errors.js` `ERROR_CODES`):
 *   - apply_expression_template_unknown_template
 *   - apply_expression_template_bindings_mismatch
 *   - apply_expression_template_recursive_body
 *   - apply_expression_template_version_too_old
 *   - apply_expression_template_invalid_declaration
 *   - rewrite_rule_nonterminating
 *   - template_constraint_unknown_index_set   (§9.6.1 `where` registration)
 *   - geometry_manifold_invalid               (§9.6.4 expanded-form validator)
 *   - makearray_region_inverted               (§9.6.4 expanded-form validator)
 *
 * plus the esm-spec §9.7 template-library / metaparameter codes (§9.6.6,
 * raised from `template-imports.ts` and `ref-loading.ts`):
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
import { deepClone, isObject } from './object-utils.js'
import { ERROR_CODES, EsmDiagnosticError } from './errors.js'

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
/** The closed manifold set rendered for diagnostics, e.g. `{planar, spherical, geodesic}`. */
const GEOMETRY_MANIFOLD_SET_DISPLAY = `{${[...GEOMETRY_MANIFOLD_VALUES].join(', ')}}`

/**
 * Maximum number of productive rewrite passes before a file is rejected as
 * non-converging (esm-spec §9.6.3, diagnostic `rewrite_rule_nonterminating`).
 * Pinned identically across all bindings so the accept/reject decision — and
 * the resulting fixpoint — is byte-identical everywhere.
 */
const MAX_REWRITE_PASSES = 64

/**
 * Shared load-time diagnostic for the §9.x machinery: expression-template
 * lowering (§9.6), template-library imports (§9.7), coupling-library imports
 * (§10.10), subsystem-ref loading, and the §9.6.4 expanded-form validators all
 * raise it as their common coded-diagnostic class — validate.ts maps it (by
 * `instanceof`) to the `expression_template_error` load-error kind. Extends the
 * neutral {@link EsmDiagnosticError} additively: the `(code, message)`
 * constructor signature, the `[code] message` text, and the public `code`
 * string property are all preserved byte-for-byte, so the emitted diagnostic is
 * unchanged and every `instanceof` check is unaffected.
 */
export class EsmMachineryError extends EsmDiagnosticError {
  constructor(code: string, message: string) {
    super(code, `[${code}] ${message}`)
    this.name = 'EsmMachineryError'
  }
}

/**
 * @deprecated Historical name for {@link EsmMachineryError}, kept as a same-class
 * alias for backward compatibility. It is the SAME class object, so
 * `instanceof ExpressionTemplateError` and `instanceof EsmMachineryError` are
 * identical. Prefer {@link EsmMachineryError}, which reflects the class's true
 * role as the shared load-time template/coupling/import/ref machinery diagnostic.
 */
export { EsmMachineryError as ExpressionTemplateError }

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

/**
 * The `priority` of a `match` rule (esm-spec §9.6.3): higher fires first,
 * ties break by declaration order. Absent ⇒ 0. The schema constrains
 * `priority` to an integer; any numeric encoding is coerced defensively.
 * A non-finite priority (`NaN`/±`Infinity`) is treated as 0 rather than being
 * allowed to poison the rule sort.
 */
function rulePriority(decl: TemplateDecl): number {
  const p: unknown = decl.priority
  if (p === undefined || p === null) return 0
  if (typeof p === 'boolean') return 0
  const n = numericValue(p)
  if (n !== undefined) return Number.isFinite(n) ? Math.round(n) : 0
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
        throw new EsmMachineryError(
          ERROR_CODES.TEMPLATE_CONSTRAINT_UNKNOWN_INDEX_SET,
          `${scope}.expression_templates.${tname}: where.${p}.shape names index set '${s}', which the consuming document's index_sets registry does not declare (esm-spec §9.6.1/§9.6.6)`,
        )
      }
    }
    out[p] = req
  }
  return out
}

/**
 * Substitute parameter occurrences in a template body.
 *
 * STRUCTURAL SHARING (mirrors the Julia reference fix "store expanded
 * expression templates as shared DAGs, not exponential trees"): binding values
 * and untouched body subtrees are spliced in BY REFERENCE, never copied, and
 * the walk is identity-preserving (a subtree containing no parameter
 * occurrence is returned as the SAME object) and identity-memoized (a subtree
 * shared under many parents is processed once). A template chain in which each
 * body references its predecessor twice therefore expands to a DAG with O(n)
 * unique nodes instead of a 2^n-node tree. This changes representation only:
 * expansion is otherwise pure, every subsequent pass over the expanded form is
 * non-mutating, and the canonical serialized bytes are unchanged (JSON
 * serialization of the DAG re-expands it textually).
 */
function substitute(body: Json, bindings: Record<string, Json>): Json {
  const memo = new Map<object, Json>()
  const go = (node: Json): Json => {
    if (typeof node === 'string') {
      if (Object.prototype.hasOwnProperty.call(bindings, node)) {
        // Splice the binding by reference: expanded forms are never mutated in
        // place downstream, so sharing is safe and keeps expansion linear.
        return bindings[node]
      }
      return node
    }
    if (Array.isArray(node)) {
      const hit = memo.get(node)
      if (hit !== undefined) return hit
      let changed = false
      const out = node.map((c) => {
        const r = go(c)
        if (r !== c) changed = true
        return r
      })
      const res = changed ? out : node
      memo.set(node, res)
      return res
    }
    if (isObject(node)) {
      const hit = memo.get(node)
      if (hit !== undefined) return hit
      let changed = false
      const out: Record<string, unknown> = {}
      for (const k of Object.keys(node)) {
        const r = go(node[k])
        if (r !== node[k]) changed = true
        out[k] = r
      }
      const res = changed ? out : node
      memo.set(node, res)
      return res
    }
    return node
  }
  return go(body)
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
      throw new EsmMachineryError(
        ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
        `expression_templates.${templateName}: \`match\` contains an 'apply_expression_template' node at ${path}; match patterns MUST NOT reference templates (esm-spec §9.7.3)`,
      )
    }
    for (const k of Object.keys(body)) {
      assertNoNestedApply(body[k], templateName, `${path}/${k}`)
    }
  }
}

/**
 * Structurally validate a raw `expression_templates` block (esm-spec §9.6.1).
 * Accepts the pre-coercion `Record<string, unknown>` view directly — no
 * `as TemplateDecl` lie at the call site — and NARROWS it to {@link Templates}
 * on return via the `asserts` clause, so callers get the typed view only after
 * the structure has actually been checked.
 */
export function validateTemplates(
  templates: Record<string, unknown>,
  scope: string,
): asserts templates is Templates {
  for (const [name, decl] of Object.entries(templates)) {
    if (!decl || typeof decl !== 'object') {
      throw new EsmMachineryError(
        ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
        `${scope}.expression_templates.${name}: entry must be an object with params + body`,
      )
    }
    // `params` MAY be empty (esm-spec §9.6.1, 0.8.0): a zero-parameter
    // template is a named constant fragment (common in library files).
    const params = (decl as { params?: unknown }).params
    if (!Array.isArray(params)) {
      throw new EsmMachineryError(
        ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
        `${scope}.expression_templates.${name}: 'params' must be an array of strings`,
      )
    }
    const seen = new Set<string>()
    for (const p of params) {
      if (typeof p !== 'string' || p.length === 0) {
        throw new EsmMachineryError(
          ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
          `${scope}.expression_templates.${name}: param names must be non-empty strings`,
        )
      }
      if (seen.has(p)) {
        throw new EsmMachineryError(
          ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
          `${scope}.expression_templates.${name}: param '${p}' is declared twice`,
        )
      }
      seen.add(p)
    }
    if (!('body' in (decl as object))) {
      throw new EsmMachineryError(
        ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
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
        throw new EsmMachineryError(
          ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
          `${scope}.expression_templates.${name}: 'where' is only admissible alongside 'match' — constraints scope an auto-applied rewrite rule, not a named fragment (esm-spec §9.6.1)`,
        )
      }
      if (!isObject(whr) || Object.keys(whr).length === 0) {
        throw new EsmMachineryError(
          ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
          `${scope}.expression_templates.${name}: 'where' must be a non-empty object mapping declared params to constraint objects`,
        )
      }
      for (const [p, cobj] of Object.entries(whr)) {
        if (!seen.has(p)) {
          throw new EsmMachineryError(
            ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
            `${scope}.expression_templates.${name}: 'where' constrains '${p}', which is not a declared param (esm-spec §9.6.1)`,
          )
        }
        if (!isObject(cobj)) {
          throw new EsmMachineryError(
            ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
            `${scope}.expression_templates.${name}: where.${p} must be a constraint object (v1 admits exactly the 'shape' kind)`,
          )
        }
        const ckeys = Object.keys(cobj)
        if (!(ckeys.length === 1 && ckeys[0] === 'shape')) {
          throw new EsmMachineryError(
            ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
            `${scope}.expression_templates.${name}: where.${p} carries constraint kind(s) ${[...ckeys].sort().join(', ')}; the v1 constraint vocabulary is exactly {shape} (esm-spec §9.6.1)`,
          )
        }
        const shp = (cobj as { shape?: unknown }).shape
        if (!Array.isArray(shp) || shp.length === 0) {
          throw new EsmMachineryError(
            ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
            `${scope}.expression_templates.${name}: where.${p}.shape must be a non-empty array of index-set names`,
          )
        }
        for (const s of shp) {
          if (typeof s !== 'string' || s.length === 0) {
            throw new EsmMachineryError(
              ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
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
export function collectApplyNames(x: Json, out: string[]): string[] {
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
 * Registration-time body **checking** (esm-spec §9.7.3, Option B / esm 0.9.0):
 * template bodies MAY reference other in-scope MATCH-LESS templates via
 * `apply_expression_template` nodes. Builds the body-reference graph, rejects
 * cycles (`apply_expression_template_recursive_body`), references to undeclared
 * or `match`-bearing templates (`apply_expression_template_unknown_template`),
 * and chains deeper than `MAX_TEMPLATE_EXPANSION_DEPTH` templates
 * (`template_body_expansion_too_deep`).
 *
 * From `esm: 0.9.0` (RFC out-of-line-expression-templates §7.1 step 4) bodies
 * are **NOT inlined** — the references are preserved uninlined and denote their
 * expansion (§9.6.4 rule 2). Target-bearing flags (§9.6.4 rule 3) are computed
 * separately by {@link templateTargetBearing}. Runs BEFORE the §9.6.3 fixpoint
 * ever consults a `match` rule; it now only validates the DAG. Mirrors the
 * Julia reference `_compose_template_bodies!`.
 *
 * Accepts the pre-coercion `Record<string, unknown>` view (the §9.7 resolver
 * calls this on a raw `JsonObject`); the decls are assumed structurally valid
 * (`validateTemplates` already ran).
 */
export function composeTemplateBodies(templates: Record<string, unknown>, scope: string): void {
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
        throw new EsmMachineryError(
          ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
          `${scope}.expression_templates.${name}: body references undeclared template '${r}' (esm-spec §9.7.3)`,
        )
      }
      if ((tdecl as { match?: Json }).match !== undefined) {
        throw new EsmMachineryError(
          ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
          `${scope}.expression_templates.${name}: body references '${r}', a \`match\` rewrite rule — only match-less templates are invocable by name (esm-spec §9.7.3)`,
        )
      }
    }
  }

  // DFS over the reference graph: cycle detection + chain-depth bound. Bodies
  // are NOT inlined (Option B); the checked DAG is left intact.
  const state: Record<string, number> = {} // 1 = on stack, 2 = done
  const depth: Record<string, number> = {} // templates on the longest chain
  const chain: string[] = []
  const visit = (name: string): number => {
    const st = state[name] ?? 0
    if (st === 1) {
      const cyc = [...chain.slice(chain.indexOf(name)), name]
      throw new EsmMachineryError(
        ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_RECURSIVE_BODY,
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
      throw new EsmMachineryError(
        ERROR_CODES.TEMPLATE_BODY_EXPANSION_TOO_DEEP,
        `${scope}.expression_templates.${name}: body-reference chain of ${d} templates exceeds MAX_TEMPLATE_EXPANSION_DEPTH=${MAX_TEMPLATE_EXPANSION_DEPTH} (esm-spec §9.7.3)`,
      )
    }
    return d
  }
  for (const name of [...names].sort()) visit(name)
}

/**
 * Expand a single `apply_expression_template` node against `templates`.
 * The template `body` is instantiated by pure structural substitution of the
 * supplied `bindings`; the bindings are spliced in AS-IS (not pre-scanned) —
 * any `apply_expression_template` or match-able node inside a binding is
 * rewritten in a SUBSEQUENT pass of the outermost-first fixpoint, never within
 * the current pass (esm-spec §9.6.3).
 */
function expandApply(node: Record<string, unknown>, templates: Templates, scope: string): Json {
  const name = node.name
  if (typeof name !== 'string' || name.length === 0) {
    throw new EsmMachineryError(
      ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
      `${scope}: apply_expression_template node missing or empty 'name'`,
    )
  }
  const decl = templates[name]
  if (!decl) {
    throw new EsmMachineryError(
      ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
      `${scope}: apply_expression_template references undeclared template '${name}'`,
    )
  }
  const bindings = node.bindings
  if (!isObject(bindings)) {
    throw new EsmMachineryError(
      ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
      `${scope}: apply_expression_template '${name}' missing 'bindings' object`,
    )
  }
  const provided = new Set(Object.keys(bindings))
  const declared = new Set(decl.params)
  for (const p of decl.params) {
    if (!provided.has(p)) {
      throw new EsmMachineryError(
        ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
        `${scope}: apply_expression_template '${name}' missing binding for param '${p}'`,
      )
    }
  }
  for (const p of provided) {
    if (!declared.has(p)) {
      throw new EsmMachineryError(
        ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
        `${scope}: apply_expression_template '${name}' supplies unknown param '${p}'`,
      )
    }
  }
  // Bindings are spliced in AS-IS (esm-spec §9.6.3): `substitute` splices each
  // value BY REFERENCE (structural sharing — expanded forms are never mutated
  // in place downstream), so the narrowed `bindings` map is passed straight
  // through — no copy is needed or meaningful here.
  return substitute(decl.body, bindings)
}

// ---------------------------------------------------------------------------
// Eager-expansion carve-out: the rewrite-target op tier T (esm-spec §9.6.4
// rule 3 / RFC out-of-line-expression-templates §7.2)
// ---------------------------------------------------------------------------

/**
 * The rewrite-target ops explicitly named by §4.2 as the open rewrite-target
 * tier plus the two load-eliminated forms — the members of **T** that carry a
 * recognized op name. Any op NOT in the evaluable-core registry
 * ({@link EVALUABLE_CORE_OPS}) is ALSO in T (an open-namespace custom op no
 * evaluator implements); `apply_expression_template` itself is excluded.
 */
const REWRITE_TARGET_OPS = new Set<string>([
  'D',
  'grad',
  'div',
  'laplacian',
  'integral',
  'table_lookup',
  'enum',
])

/**
 * The evaluable-core op registry — every op name the format defines an
 * evaluator/structural meaning for (mirrors the Julia reference
 * `op_registry.jl` `_OP_INDEX`). An op absent from this set (and not
 * `apply_expression_template`) is an open-namespace custom op no evaluator
 * implements, hence a member of **T**. Pinned identically across bindings so
 * target-bearing classification — and therefore which references survive — is
 * byte-identical everywhere.
 */
const EVALUABLE_CORE_OPS = new Set<string>([
  '+',
  '-',
  '*',
  '/',
  '^',
  'pow',
  'neg',
  '<',
  '<=',
  '>',
  '>=',
  '==',
  '!=',
  'and',
  'or',
  'not',
  'ifelse',
  'Pre',
  'sin',
  'cos',
  'tan',
  'asin',
  'acos',
  'atan',
  'atan2',
  'sinh',
  'cosh',
  'tanh',
  'asinh',
  'acosh',
  'atanh',
  'exp',
  'log',
  'log10',
  'sqrt',
  'abs',
  'sign',
  'floor',
  'ceil',
  'min',
  'max',
  'pi',
  'π',
  'e',
  'true',
  'false',
  'fn',
  'call',
  'const',
  'enum',
  'D',
  'ic',
  'grad',
  'div',
  'laplacian',
  'index',
  'makearray',
  'broadcast',
  'reshape',
  'transpose',
  'concat',
  'arrayop',
  'aggregate',
  'intersect_polygon',
  'polygon_intersection_area',
  'skolem',
])

/**
 * True iff op string `op` is a member of the rewrite-target tier **T**
 * (esm-spec §9.6.4 rule 3): one of the named rewrite-target ops, or an op with
 * no evaluable-core registry entry (an open-namespace custom op). The template
 * reference op itself is never in T.
 */
function opInT(op: string): boolean {
  if (op === APPLY_OP) return false
  if (REWRITE_TARGET_OPS.has(op)) return true
  return !EVALUABLE_CORE_OPS.has(op)
}

/**
 * True iff `node` contains, ANYWHERE within it (descending through every field,
 * including the `bindings` of nested `apply_expression_template` nodes), an
 * object whose `op` is in **T** ({@link opInT}). Does NOT follow references to
 * other templates — that transitive step is {@link templateTargetBearing}.
 */
function directTOp(node: Json, seen: Set<object> = new Set()): boolean {
  if (Array.isArray(node)) {
    if (seen.has(node)) return false
    seen.add(node)
    for (const c of node) if (directTOp(c, seen)) return true
    return false
  }
  if (isObject(node)) {
    if (seen.has(node)) return false
    seen.add(node)
    if (typeof node.op === 'string' && opInT(node.op)) return true
    for (const k of Object.keys(node)) if (directTOp(node[k], seen)) return true
    return false
  }
  return false
}

/**
 * Compute, for every template in `templates`, its **target-bearing** flag
 * (esm-spec §9.6.4 rule 3): a template is target-bearing iff its body contains
 * an op in **T** anywhere (including inside nested references' `bindings`), OR
 * it references — transitively through the §9.7.3-checked acyclic DAG — a
 * target-bearing template. The DAG is acyclic (checked by
 * {@link composeTemplateBodies}), so a memoized DFS terminates. Cached per
 * component registry.
 */
export function templateTargetBearing(templates: Record<string, unknown>): Record<string, boolean> {
  const tb: Record<string, boolean> = {}
  const inProgress = new Set<string>()
  const visit = (name: string): boolean => {
    if (Object.prototype.hasOwnProperty.call(tb, name)) return tb[name]!
    // Defensive against a cycle the checker somehow missed.
    if (inProgress.has(name)) return false
    const decl = templates[name]
    if (!isObject(decl)) {
      tb[name] = false
      return false
    }
    inProgress.add(name)
    const body = decl.body
    let res = body !== undefined && directTOp(body)
    if (!res) {
      for (const r of collectApplyNames(body, [])) {
        if (!Object.prototype.hasOwnProperty.call(templates, r)) continue
        if (visit(r)) {
          res = true
          break
        }
      }
    }
    inProgress.delete(name)
    tb[name] = res
    return res
  }
  for (const name of Object.keys(templates)) visit(name)
  return tb
}

/**
 * Whether an `apply_expression_template` `node` is **eager** (esm-spec §9.6.4
 * rule 3): its referenced template is target-bearing, OR any of its `bindings`
 * values contains an op in **T**. (After innermost-first eager expansion of the
 * bindings, a "nested eager reference" always manifests as a T-op in the
 * bindings, so this predicate subsumes that clause — see {@link expandEager}.)
 */
function refIsEager(
  node: Record<string, unknown>,
  targetBearing: Record<string, boolean>,
): boolean {
  const name = node.name
  if (typeof name !== 'string') return false
  if (targetBearing[name]) return true
  const b = node.bindings
  if (b === undefined) return false
  return directTOp(b)
}

/**
 * The eager-expansion pre-pass (esm-spec §9.6.4 rule 3): expand — by pure
 * substitution, innermost-first — every EAGER `apply_expression_template` node,
 * and only eager nodes. Non-eager (surviving) references are returned intact.
 * Consumes no `MAX_REWRITE_PASSES` budget (it is a separate pre-pass). Sharing
 * is preserved via an identity memo. Mirrors the Julia reference `_expand_eager`.
 */
function expandEager(
  node: Json,
  templates: Templates,
  targetBearing: Record<string, boolean>,
  scope: string,
  memo: Map<object, Json> = new Map(),
): Json {
  if (isObject(node)) {
    const hit = memo.get(node)
    if (hit !== undefined) return hit
    let res: Json
    if (node.op === APPLY_OP) {
      // Innermost-first: expand eager references inside the bindings first.
      const b = node.bindings
      let newnode: Record<string, unknown> = node
      if (isObject(b)) {
        const nb: Record<string, unknown> = {}
        let changed = false
        for (const k of Object.keys(b)) {
          const rv = expandEager(b[k], templates, targetBearing, scope, memo)
          if (rv !== b[k]) changed = true
          nb[k] = rv
        }
        if (changed) {
          newnode = {}
          for (const k of Object.keys(node)) newnode[k] = k === 'bindings' ? nb : node[k]
        }
      }
      if (refIsEager(newnode, targetBearing)) {
        const body = expandApply(newnode, templates, scope)
        res = expandEager(body, templates, targetBearing, scope, memo)
      } else {
        res = newnode
      }
    } else {
      let changed = false
      const out: Record<string, unknown> = {}
      for (const k of Object.keys(node)) {
        const rv = expandEager(node[k], templates, targetBearing, scope, memo)
        if (rv !== node[k]) changed = true
        out[k] = rv
      }
      res = changed ? out : node
    }
    memo.set(node, res)
    return res
  }
  if (Array.isArray(node)) {
    const hit = memo.get(node)
    if (hit !== undefined) return hit
    let changed = false
    const out = node.map((v) => {
      const rv = expandEager(v, templates, targetBearing, scope, memo)
      if (rv !== v) changed = true
      return rv
    })
    const res = changed ? out : node
    memo.set(node, res)
    return res
  }
  return node
}

/**
 * Fully expand EVERY `apply_expression_template` node in `node` by pure
 * substitution to a fixpoint (innermost-first: bindings are expanded before the
 * body is instantiated, and the instantiated body is re-expanded). The
 * per-registry kernel of the public {@link expandDocument} function (esm-spec
 * §9.6.4 rule 2). Deterministic and sharing-preserving. Mirrors the Julia
 * reference `_expand_all`.
 */
function expandAllNode(
  node: Json,
  templates: Templates,
  scope: string,
  memo: Map<object, Json> = new Map(),
): Json {
  if (isObject(node)) {
    const hit = memo.get(node)
    if (hit !== undefined) return hit
    let res: Json
    if (node.op === APPLY_OP) {
      const b = node.bindings
      let newnode: Record<string, unknown> = node
      if (isObject(b)) {
        const nb: Record<string, unknown> = {}
        let changed = false
        for (const k of Object.keys(b)) {
          const rv = expandAllNode(b[k], templates, scope, memo)
          if (rv !== b[k]) changed = true
          nb[k] = rv
        }
        if (changed) {
          newnode = {}
          for (const k of Object.keys(node)) newnode[k] = k === 'bindings' ? nb : node[k]
        }
      }
      const body = expandApply(newnode, templates, scope)
      res = expandAllNode(body, templates, scope, memo)
    } else {
      let changed = false
      const out: Record<string, unknown> = {}
      for (const k of Object.keys(node)) {
        const rv = expandAllNode(node[k], templates, scope, memo)
        if (rv !== node[k]) changed = true
        out[k] = rv
      }
      res = changed ? out : node
    }
    memo.set(node, res)
    return res
  }
  if (Array.isArray(node)) {
    const hit = memo.get(node)
    if (hit !== undefined) return hit
    let changed = false
    const out = node.map((v) => {
      const rv = expandAllNode(v, templates, scope, memo)
      if (rv !== v) changed = true
      return rv
    })
    const res = changed ? out : node
    memo.set(node, res)
    return res
  }
  return node
}

/**
 * Call-site check for a SURVIVING (non-expanded) `apply_expression_template`
 * reference (esm-spec §9.6.9): the referenced `name` must resolve to an
 * in-scope MATCH-LESS template and `bindings` must cover its `params` exactly.
 * Same diagnostics as {@link expandApply}, but WITHOUT expanding — the
 * reference is preserved (§9.6.4 rule 1).
 */
function validateApplyRef(
  node: Record<string, unknown>,
  templates: Templates,
  scope: string,
): void {
  const name = node.name
  if (typeof name !== 'string' || name.length === 0) {
    throw new EsmMachineryError(
      ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_INVALID_DECLARATION,
      `${scope}: apply_expression_template node missing or empty 'name'`,
    )
  }
  const decl = templates[name]
  if (!decl) {
    throw new EsmMachineryError(
      ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
      `${scope}: apply_expression_template references undeclared template '${name}'`,
    )
  }
  if ((decl as { match?: Json }).match !== undefined) {
    throw new EsmMachineryError(
      ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_UNKNOWN_TEMPLATE,
      `${scope}: apply_expression_template references '${name}', a \`match\` rewrite rule — only match-less templates are invocable by name (esm-spec §9.6.2)`,
    )
  }
  const bindings = node.bindings
  if (!isObject(bindings)) {
    throw new EsmMachineryError(
      ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
      `${scope}: apply_expression_template '${name}' missing 'bindings' object`,
    )
  }
  const provided = new Set(Object.keys(bindings))
  const declared = new Set(decl.params)
  for (const p of decl.params) {
    if (!provided.has(p)) {
      throw new EsmMachineryError(
        ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
        `${scope}: apply_expression_template '${name}' missing binding for param '${p}'`,
      )
    }
  }
  for (const p of provided) {
    if (!declared.has(p)) {
      throw new EsmMachineryError(
        ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_BINDINGS_MISMATCH,
        `${scope}: apply_expression_template '${name}' supplies unknown param '${p}'`,
      )
    }
  }
}

/**
 * Walk `node` and run {@link validateApplyRef} on every surviving
 * `apply_expression_template` reference it carries (esm-spec §9.6.9 call-site
 * checks). Descends into references' `bindings` too — a binding value MAY itself
 * be a surviving reference. Mirrors the Julia reference `_check_surviving_refs`.
 */
function checkSurvivingRefs(
  node: Json,
  templates: Templates,
  scope: string,
  seen: Set<object> = new Set(),
): void {
  if (Array.isArray(node)) {
    if (seen.has(node)) return
    seen.add(node)
    for (const c of node) checkSurvivingRefs(c, templates, scope, seen)
    return
  }
  if (isObject(node)) {
    if (seen.has(node)) return
    seen.add(node)
    if (node.op === APPLY_OP) validateApplyRef(node, templates, scope)
    for (const k of Object.keys(node)) checkSurvivingRefs(node[k], templates, scope, seen)
  }
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
 *
 * The pass is IDENTITY-PRESERVING (a subtree with no rewrite is returned as
 * the SAME object, not a copy) and IDENTITY-MEMOIZED per pass (`memo`, keyed
 * on object identity): expanded template bodies are shared DAGs (see
 * `substitute`), so a subtree reachable through many parents is rewritten
 * once and the single result is spliced everywhere — the pass stays linear in
 * UNIQUE nodes and preserves the sharing. This is safe because the pass is a
 * pure function of the node (rules, templates, and shape env are fixed for
 * the pass) and nothing mutates expanded nodes in place afterwards; the
 * fixpoint result is byte-identical to the unshared expansion when
 * serialized.
 */
function onePass(
  node: Json,
  templates: Templates,
  sortedRules: MatchRule[],
  scope: string,
  last: { op: string },
  shapeEnv: ShapeEnv,
  targetBearing: Record<string, boolean>,
  memo: Map<object, PassResult>,
): PassResult {
  if (Array.isArray(node)) {
    const hit = memo.get(node)
    if (hit !== undefined) return hit
    let changed = false
    const out = node.map((c) => {
      const r = onePass(c, templates, sortedRules, scope, last, shapeEnv, targetBearing, memo)
      changed = changed || r.changed
      return r.node
    })
    const res: PassResult = { node: changed ? out : node, changed }
    memo.set(node, res)
    return res
  }
  if (!isObject(node)) {
    return { node, changed: false }
  }
  const hit = memo.get(node)
  if (hit !== undefined) return hit
  const res = onePassObject(
    node,
    templates,
    sortedRules,
    scope,
    last,
    shapeEnv,
    targetBearing,
    memo,
  )
  memo.set(node, res)
  return res
}

/** The object-node arm of {@link onePass} (split out so memoization stays in one place). */
function onePassObject(
  node: Record<string, unknown>,
  templates: Templates,
  sortedRules: MatchRule[],
  scope: string,
  last: { op: string },
  shapeEnv: ShapeEnv,
  targetBearing: Record<string, boolean>,
  memo: Map<object, PassResult>,
): PassResult {
  // (1) Outermost-first: fire a rule AT this node before descending.
  if (node.op === APPLY_OP) {
    // esm-spec §9.6.4 rule 4 (Option B): the engine treats a surviving
    // (non-eager) reference as a LEAF — it does not descend into its
    // `bindings`, no rule fires inside it, and it survives the fixpoint.
    // Eager references were already removed by the pre-pass (`expandEager`);
    // a defensive check keeps any eager node passed in unexpanded correct.
    if (refIsEager(node, targetBearing)) {
      last.op = APPLY_OP
      return { node: expandEager(node, templates, targetBearing, scope), changed: true }
    }
    return { node, changed: false }
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
      // Instantiate by pure substitution (through nested references' `bindings`;
      // `name` is never a site). An eager reference introduced by the
      // instantiation expands as part of the same rewrite (§9.6.4 rule 4).
      const body = substitute(rule.body, bindings)
      return {
        node: expandEager(body, templates, targetBearing, scope),
        changed: true,
      }
    }
  }
  // (2) No rule fired here — descend into children.
  let changed = false
  const out: Record<string, unknown> = {}
  for (const k of Object.keys(node)) {
    const r = onePass(node[k], templates, sortedRules, scope, last, shapeEnv, targetBearing, memo)
    out[k] = r.node
    changed = changed || r.changed
  }
  return { node: changed ? out : node, changed }
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
  targetBearing: Record<string, boolean> = {},
): Json {
  const last = { op: '' }
  // esm-spec §9.6.4 rule 3 / §7.1 step 5: the eager-expansion pre-pass runs
  // BEFORE the fixpoint and consumes no `MAX_REWRITE_PASSES` budget. It removes
  // every eager reference (target-bearing, or T-op in bindings) so the fixpoint
  // and the later `unlowered_operator` gate walk a tree in which no
  // rewrite-target op hides inside a surviving reference.
  let current = expandEager(node, templates, targetBearing, scope)
  for (let pass = 0; pass < MAX_REWRITE_PASSES; pass++) {
    // Fresh identity-memo per pass: rule context is fixed within a pass, so a
    // shared subtree is rewritten once per pass and stays shared.
    const memo = new Map<object, PassResult>()
    const { node: next, changed } = onePass(
      current,
      templates,
      sortedRules,
      scope,
      last,
      shapeEnv,
      targetBearing,
      memo,
    )
    current = next
    if (!changed) return current // fixpoint reached
  }
  throw new EsmMachineryError(
    ERROR_CODES.REWRITE_RULE_NONTERMINATING,
    `${scope}: expression-template rewriting did not converge within ` +
      `MAX_REWRITE_PASSES=${MAX_REWRITE_PASSES} passes (last rewritten op ` +
      `'${last.op}'). A \`match\` rule likely re-introduces its own pattern ` +
      `(esm-spec §9.6.3).`,
  )
}

/**
 * Walk the file looking for apply_expression_template ops anywhere.
 *
 * Expanded template bodies are shared DAGs (see `substitute`), so the walk
 * skips any object/array it has already visited (`seen`, keyed on object
 * identity): each unique node is scanned once. This cannot change the result
 * on freshly-parsed JSON (a tree — no aliasing), and shared expanded subtrees
 * are apply-free by construction, so the reported hit paths are unchanged.
 */
function findStrayApplyOps(view: unknown): string[] {
  const hits: string[] = []
  const seen = new Set<object>()
  const visit = (v: unknown, path: string): void => {
    if (Array.isArray(v)) {
      if (seen.has(v)) return
      seen.add(v)
      for (let i = 0; i < v.length; i++) visit(v[i], `${path}/${i}`)
      return
    }
    if (isObject(v)) {
      if (seen.has(v)) return
      seen.add(v)
      if (v.op === APPLY_OP) hits.push(path)
      for (const k of Object.keys(v)) {
        // An `apply_expression_template` inside an `expression_templates` BLOCK is
        // not a stray call site — it is template COMPOSITION (§9.7.3): one template's
        // body naming another, expanded when the template is INVOKED, not where it is
        // DECLARED. The scanner never saw one before only because the declaration was
        // deleted on the way out; now that §9.6.4 rule 5 keeps the registry, skipping
        // the block is what tells a declaration apart from an unexpanded call.
        if (k === 'expression_templates') continue
        visit(v[k], `${path}/${k}`)
      }
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
 * Visit every top-level model / reaction_system in the raw pre-coercion JSON
 * view, guarding that the container map and each entry are plain objects. This
 * is the file-local counterpart to `./traverse.js`'s typed `forEachComponent`:
 * it operates on the `Record<string, unknown>` view (not a typed `EsmFile`),
 * visits top-level entries ONLY (no subsystem descent), and applies NO
 * reference-stub skip — matching the four component walks in this module that
 * were previously copy-pasted, byte-for-byte.
 */
function forEachRawComponent(
  root: Record<string, unknown>,
  cb: (kind: 'models' | 'reaction_systems', name: string, comp: Record<string, unknown>) => void,
): void {
  for (const kind of ['models', 'reaction_systems'] as const) {
    const comps = root[kind]
    if (!isObject(comps)) continue
    for (const [name, comp] of Object.entries(comps)) {
      if (!isObject(comp)) continue
      cb(kind, name, comp)
    }
  }
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
  forEachRawComponent(view, (compKind, name, comp) => {
    if ('expression_templates' in comp) {
      offences.push(`/${compKind}/${name}/expression_templates`)
    }
  })
  // apply_expression_template ops anywhere in the AST
  for (const path of findStrayApplyOps(view)) offences.push(path)

  if (offences.length > 0) {
    throw new EsmMachineryError(
      ERROR_CODES.APPLY_EXPRESSION_TEMPLATE_VERSION_TOO_OLD,
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
  /** Per-template target-bearing flags (esm-spec §9.6.4 rule 3). */
  targetBearing: Record<string, boolean>
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
  // `tplRaw` IS the template map — validate it in place (which narrows it to
  // `Templates`) rather than copying into a second identically-keyed object.
  validateTemplates(tplRaw, scope)
  // Registration-time body composition (esm-spec §9.7.3): inline body
  // references to match-less in-scope templates as a statically-checked
  // acyclic DAG, so every rule body the fixpoint sees is a closed AST.
  composeTemplateBodies(tplRaw, scope)
  const templates: Templates = tplRaw
  const matchRules: MatchRule[] = []
  // Object key order in JS preserves declaration order, so the
  // enumeration index IS the authored declaration order.
  let declIndex = 0
  for (const [tname, decl] of Object.entries(templates)) {
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
  // Target-bearing flags (esm-spec §9.6.4 rule 3) drive the eager pre-pass and
  // the surviving-reference leaf semantics.
  const targetBearing = templateTargetBearing(templates)
  return { templates, matchRules, shapeEnv, targetBearing }
}

/** True if any model / reaction_system declares an expression_templates block. */
function hasExpressionTemplatesBlock(root: Record<string, unknown>): boolean {
  let found = false
  forEachRawComponent(root, (_kind, _name, comp) => {
    if (isObject(comp.expression_templates)) found = true
  })
  return found
}

/**
 * Post-expansion validator (esm-spec §9.6.4): every `intersect_polygon` /
 * `polygon_intersection_area` node OUTSIDE an `expression_templates` block
 * must carry a `manifold` drawn from the closed set {planar, spherical,
 * geodesic}. Template bodies are skipped — a parameter name in the `manifold`
 * position of a `body` is a legal scalar-field substitution site (esm-spec
 * §9.6.1); by the time this validator runs on a loaded document every such
 * site has been substituted, so an out-of-set value here is a real defect
 * (e.g. a template invocation binding the manifold parameter to a non-member
 * literal). Throws `EsmMachineryError` with code
 * `geometry_manifold_invalid`.
 *
 * The expanded form is a shared DAG (see `substitute`), so the walk visits
 * each unique node once (`seen`, keyed on object identity). The first —
 * pre-order-earliest — offending node still throws with the same path as an
 * unshared walk would, because memoization never changes when a node is FIRST
 * visited.
 */
export function validateGeometryManifolds(tree: unknown, path = ''): void {
  const seen = new Set<object>()
  const visit = (tree: unknown, path: string): void => {
    if (Array.isArray(tree)) {
      if (seen.has(tree)) return
      seen.add(tree)
      for (let i = 0; i < tree.length; i++) visit(tree[i], `${path}/${i}`)
      return
    }
    if (!isObject(tree)) return
    if (seen.has(tree)) return
    seen.add(tree)
    const node = tree as Record<string, unknown>
    if (typeof node.op === 'string' && GEOMETRY_MANIFOLD_OPS.has(node.op) && 'manifold' in node) {
      const m = node.manifold
      if (!(typeof m === 'string' && GEOMETRY_MANIFOLD_VALUES.has(m))) {
        throw new EsmMachineryError(
          ERROR_CODES.GEOMETRY_MANIFOLD_INVALID,
          `${path}: \`${node.op}\` carries manifold ${JSON.stringify(m)}, not a member of the closed set ${GEOMETRY_MANIFOLD_SET_DISPLAY}. The manifold enum is enforced on the expanded form (esm-spec §9.6.4; CONFORMANCE_SPEC §5.8.4) — a template parameter substituted into this scalar field must be bound to one of the closed-set literals.`,
        )
      }
    }
    for (const k of Object.keys(node)) {
      // Pre-substitution template trees; params may legally occupy the manifold
      // position there (esm-spec §9.6.1).
      if (k === 'expression_templates') continue
      visit(node[k], `${path}/${k}`)
    }
  }
  visit(tree, path)
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
 * carries nothing else in bound position). Throws `EsmMachineryError`
 * with code `makearray_region_inverted`.
 *
 * Visits each unique node once (`seen` — the expanded form is a shared DAG;
 * see `validateGeometryManifolds` for why the first-thrown diagnostic is
 * unchanged).
 */
export function validateMakearrayRegions(tree: unknown, path = ''): void {
  const seen = new Set<object>()
  visitMakearrayRegions(tree, path, seen)
}

function visitMakearrayRegions(tree: unknown, path: string, seen: Set<object>): void {
  if (Array.isArray(tree)) {
    if (seen.has(tree)) return
    seen.add(tree)
    for (let i = 0; i < tree.length; i++) visitMakearrayRegions(tree[i], `${path}/${i}`, seen)
    return
  }
  if (!isObject(tree)) return
  if (seen.has(tree)) return
  seen.add(tree)
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
            throw new EsmMachineryError(
              ERROR_CODES.MAKEARRAY_REGION_INVERTED,
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
    visitMakearrayRegions(node[k], `${path}/${k}`, seen)
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

// ---------------------------------------------------------------------------
// Reference-aware validation discharge (esm-spec §9.6.9, Option B)
// ---------------------------------------------------------------------------

/**
 * esm-spec §9.6.9: `makearray_region_inverted` is discharged at registration on
 * the composed, metaparameter-folded template bodies — region bounds cannot
 * carry template params (they are metaparameter expressions, §9.7.6), so the
 * check is instantiation-independent. Every retained template body (match and
 * match-less) is validated directly. Mirrors the Julia reference
 * `_validate_makearray_regions_in_registries`.
 */
function validateMakearrayRegionsInRegistries(
  contextsByKind: Record<'models' | 'reaction_systems', Map<string, RewriteContext>>,
): void {
  for (const kind of ['models', 'reaction_systems'] as const) {
    for (const ctx of contextsByKind[kind].values()) {
      for (const [tname, decl] of Object.entries(ctx.templates)) {
        const body = (decl as { body?: unknown }).body
        if (body === undefined) continue
        validateMakearrayRegions(body, `expression_templates.${tname}/body`)
      }
    }
  }
}

/**
 * Which templates can produce a geometry-kernel node (`GEOMETRY_MANIFOLD_OPS`)
 * — directly in the body or transitively through a referenced template. Only
 * references to these templates need per-instantiation manifold validation
 * (§9.6.9). Mirrors the Julia reference `_template_manifold_bearing`.
 */
function templateManifoldBearing(templates: Templates): Record<string, boolean> {
  const direct = (node: Json, seen: Set<object> = new Set()): boolean => {
    if (Array.isArray(node)) {
      if (seen.has(node)) return false
      seen.add(node)
      for (const c of node) if (direct(c, seen)) return true
      return false
    }
    if (isObject(node)) {
      if (seen.has(node)) return false
      seen.add(node)
      if (typeof node.op === 'string' && GEOMETRY_MANIFOLD_OPS.has(node.op)) return true
      for (const k of Object.keys(node)) if (direct(node[k], seen)) return true
      return false
    }
    return false
  }
  const mb: Record<string, boolean> = {}
  const inProgress = new Set<string>()
  const visit = (name: string): boolean => {
    if (Object.prototype.hasOwnProperty.call(mb, name)) return mb[name]!
    if (inProgress.has(name)) return false
    const decl = templates[name]
    if (!isObject(decl)) {
      mb[name] = false
      return false
    }
    inProgress.add(name)
    const body = decl.body
    let res = body !== undefined && direct(body)
    if (!res) {
      for (const r of collectApplyNames(body, [])) {
        if (Object.prototype.hasOwnProperty.call(templates, r) && visit(r)) {
          res = true
          break
        }
      }
    }
    inProgress.delete(name)
    mb[name] = res
    return res
  }
  for (const name of Object.keys(templates)) visit(name)
  return mb
}

/**
 * esm-spec §9.6.9: `geometry_manifold_invalid` is discharged per-instantiation
 * (a `manifold` may be a template param), memoized. Direct geometry nodes in
 * the reference-preserving tree are checked as before; every surviving
 * `apply_expression_template` reference whose template can produce a geometry
 * kernel is additionally expanded ONCE (memoized) and its expansion validated.
 * The diagnostic reports (call-site path, template name, intra-body path).
 * Mirrors the Julia reference `_validate_geometry_manifolds_refaware`.
 */
function validateGeometryManifoldsRefAware(
  root: Record<string, unknown>,
  contextsByKind: Record<'models' | 'reaction_systems', Map<string, RewriteContext>>,
): void {
  // Direct nodes on the reference-preserving tree (skips template blocks; does
  // not see manifold params hidden behind references).
  validateGeometryManifolds(root)
  for (const kind of ['models', 'reaction_systems'] as const) {
    const comps = root[kind]
    if (!isObject(comps)) continue
    for (const [cname, ctx] of contextsByKind[kind]) {
      const comp = comps[cname]
      if (!isObject(comp)) continue
      const manifoldBearing = templateManifoldBearing(ctx.templates)
      if (!Object.values(manifoldBearing).some(Boolean)) continue // no geometry
      const memo = new Set<object>()
      for (const [k, v] of Object.entries(comp)) {
        if (k === 'expression_templates') continue
        validateManifoldsInRefs(v, ctx.templates, manifoldBearing, `${kind}.${cname}.${k}`, memo)
      }
    }
  }
}

function validateManifoldsInRefs(
  node: Json,
  templates: Templates,
  manifoldBearing: Record<string, boolean>,
  path: string,
  memo: Set<object>,
): void {
  if (Array.isArray(node)) {
    if (memo.has(node)) return
    memo.add(node)
    for (let i = 0; i < node.length; i++)
      validateManifoldsInRefs(node[i], templates, manifoldBearing, `${path}/${i}`, memo)
    return
  }
  if (!isObject(node)) return
  if (memo.has(node)) return
  memo.add(node)
  const name = node.op === APPLY_OP ? String(node.name ?? '') : ''
  // Per-instantiation manifold check (§9.6.9): expand ONLY references whose
  // template can produce a geometry-kernel node; everything else is cheap.
  if (name !== '' && manifoldBearing[name]) {
    let expansion: Json
    try {
      expansion = expandAllNode(node, templates, path)
    } catch {
      expansion = undefined
    }
    if (expansion !== undefined) {
      try {
        validateGeometryManifolds(expansion)
      } catch (e) {
        if (e instanceof EsmMachineryError && e.code === ERROR_CODES.GEOMETRY_MANIFOLD_INVALID) {
          throw new EsmMachineryError(
            ERROR_CODES.GEOMETRY_MANIFOLD_INVALID,
            `${path}: instantiation of template '${name}' — ${e.message} (esm-spec §9.6.9; per-instantiation manifold check)`,
          )
        }
        throw e
      }
    }
  }
  for (const k of Object.keys(node)) {
    validateManifoldsInRefs(node[k], templates, manifoldBearing, `${path}/${k}`, memo)
  }
}

/**
 * Load the file under Option B (reference preservation, esm-spec §9.6.4): fire
 * auto-applied `match` rules and eagerly expand target-bearing references to a
 * fixpoint per component (outermost-first, priority-ordered, bounded — §9.6.3),
 * but leave NON-eager `apply_expression_template` references intact (they
 * denote their expansion, §9.6.4 rule 2). The per-component
 * `expression_templates` registries are RETAINED — they are what {@link
 * expandDocument} consumes (rule 2) and emit materializes (rule 5). Call-site
 * checks (§9.6.9), the reference-aware geometry-manifold check, and the
 * registration-time makearray-region check run on the reference-preserving form.
 *
 * Returns a new file object; the input is not mutated.
 *
 * Pre-condition: the input has been schema-validated.
 */
export function lowerExpressionTemplates<T extends object>(file: T): T {
  rejectExpressionTemplatesPreV04(file)

  if (!isObject(file)) return file
  const root = file as Record<string, unknown>

  // Scan globally for apply ops and for any expression_templates block (a
  // component may carry `match` rules or surviving references even when there
  // are no eager apply ops).
  const strayApplyPaths = findStrayApplyOps(file)
  if (strayApplyPaths.length === 0 && !hasExpressionTemplatesBlock(root)) {
    // No template machinery at all; the §9.6.4 expanded-form validators still
    // run — the raw tree IS the expanded form. Return a fresh tree (the "returns
    // a fresh clone" contract callers rely on).
    validateGeometryManifolds(root)
    validateMakearrayRegions(root)
    return deepClone(root) as T
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
  // expression_templates block are retained per family for the coupling walk
  // and the reference-aware validators below (esm-spec §9.6.4 / §9.6.9).
  const out = deepClone(root)
  const contextsByKind = {
    models: new Map<string, RewriteContext>(),
    reaction_systems: new Map<string, RewriteContext>(),
  }
  forEachRawComponent(out, (compKind, compName, compRaw) => {
    const comp = compRaw as Component
    const tplRaw = comp.expression_templates
    const shapeEnv = componentShapeEnv(comp)
    let templates: Templates = {}
    let matchRules: MatchRule[] = []
    let targetBearing: Record<string, boolean> = {}
    if (isObject(tplRaw)) {
      const ctx = buildRewriteContext(tplRaw, isetNames, shapeEnv, `${compKind}.${compName}`)
      templates = ctx.templates
      matchRules = ctx.matchRules
      targetBearing = ctx.targetBearing
      contextsByKind[compKind].set(compName, ctx)
    }
    // Rewrite every property except expression_templates to a fixpoint, then
    // run call-site checks on surviving (non-eager) references (§9.6.9). The
    // registry block is RETAINED (Option B, §9.6.4 rule 1).
    for (const k of Object.keys(comp)) {
      if (k === 'expression_templates') continue
      comp[k] = rewriteToFixpoint(
        comp[k],
        templates,
        matchRules,
        `${compKind}.${compName}.${k}`,
        shapeEnv,
        targetBearing,
      )
      checkSurvivingRefs(comp[k], templates, `${compKind}.${compName}.${k}`)
    }
  })

  // Top-level coupling: a `variable_map` entry may carry an object-valued
  // Expression `transform` (esm-spec §8.6). It is rewritten to fixpoint in the
  // SAME rewrite context as a field of the RECEIVING component — the first
  // dot-segment of the entry's `to`, looked up under models then
  // reaction_systems. A receiving component that is absent or declares no
  // templates leaves the transform unrewritten.
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
        ctx.targetBearing,
      )
      checkSurvivingRefs(entry.transform, ctx.templates, `coupling[${i}].transform`)
    }
  }

  // esm-spec §9.6.4 rule 1 (Option B): surviving `apply_expression_template`
  // references are the NEW NORMAL. Only unknown-name / bindings-mismatch
  // references are errors — already checked per component / per transform by
  // `checkSurvivingRefs`. No global "no apply ops remain" gate.

  // Validation discharge (esm-spec §9.6.9): geometry-manifold and
  // makearray-region checks on the reference-preserving form. The manifold
  // check is per-instantiation (a `manifold` may be a template param), so it
  // descends through surviving references' single-instantiation expansions,
  // memoized. Region bounds cannot carry template params, so the makearray
  // check runs on the reference-preserving tree AND the retained folded
  // template bodies directly.
  validateGeometryManifoldsRefAware(out, contextsByKind)
  validateMakearrayRegions(out)
  validateMakearrayRegionsInRegistries(contextsByKind)

  return out as T
}

// ===========================================================================
// `Expand` — the public full-expansion function (esm-spec §9.6.4 rule 2)
// ===========================================================================

const COMP_KINDS = ['models', 'reaction_systems'] as const

/** Collect the named registry of one component (match + match-less templates). */
function namedRegistry(comp: Record<string, unknown>): Templates {
  const named: Templates = {}
  const tpl = comp.expression_templates
  if (isObject(tpl)) {
    for (const [n, d] of Object.entries(tpl)) named[n] = d as TemplateDecl
  }
  return named
}

/**
 * Fully expand every surviving `apply_expression_template` reference in a
 * document `loaded` by {@link lowerExpressionTemplates} (Option B), producing
 * the Option-A image: every reference replaced by its expansion (pure
 * substitution to the acyclic fixpoint, §9.6.4 rule 2) and every per-component
 * `expression_templates` block stripped. Deterministic — the §9.7.3 DAG is
 * acyclic and substitution confluent, so `expandDocument(load(f))` is
 * structurally equal to the pre-0.9.0 expanded form (the `expanded*.esm`
 * conformance oracle). Non-destructive: `loaded` is deep-cloned first. Mirrors
 * the Julia reference `expand_document` / `Expand`.
 */
export function expandDocument<T extends object>(loaded: T): T {
  if (!isObject(loaded)) return loaded
  const root = deepClone(loaded) as Record<string, unknown>

  // Capture each component's named registry BEFORE stripping the blocks.
  const compNamed = new Map<string, Templates>()
  for (const compKind of COMP_KINDS) {
    const comps = root[compKind]
    if (!isObject(comps)) continue
    for (const [cname, comp] of Object.entries(comps)) {
      if (!isObject(comp)) continue
      compNamed.set(`${compKind} ${cname}`, namedRegistry(comp))
    }
  }

  for (const compKind of COMP_KINDS) {
    const comps = root[compKind]
    if (!isObject(comps)) continue
    for (const [cname, comp] of Object.entries(comps)) {
      if (!isObject(comp)) continue
      const named = compNamed.get(`${compKind} ${cname}`)!
      const scope = `${compKind}.${cname}`
      for (const k of Object.keys(comp)) {
        if (k === 'expression_templates' || k === 'expression_template_imports') continue
        comp[k] = expandAllNode(comp[k], named, `${scope}.${k}`)
      }
      delete comp.expression_templates
    }
  }

  const coupling = root.coupling
  if (Array.isArray(coupling)) {
    for (let i = 0; i < coupling.length; i++) {
      const entry = coupling[i]
      if (!isObject(entry) || entry.type !== 'variable_map') continue
      if (!isObject(entry.transform)) continue
      const to = entry.to
      if (typeof to !== 'string') continue
      const receiver = to.split('.')[0] ?? ''
      const named =
        compNamed.get(`models ${receiver}`) ?? compNamed.get(`reaction_systems ${receiver}`)
      if (!named) continue
      entry.transform = expandAllNode(entry.transform, named, `coupling[${i}].transform`)
    }
  }

  return root as T
}

/** Public alias for {@link expandDocument} using the spec's spelling (§9.6.4 rule 2). */
export { expandDocument as Expand }

// ===========================================================================
// Reference-preserving emit (esm-spec §9.6.4 rule 5, §9.6.7)
// ===========================================================================

/**
 * The transitive closure of the templates named by `refnames` (surviving-
 * reference names), following references inside materialized bodies, keeping
 * only MATCH-LESS entries (match rules are never materialized, §9.6.4 rule 5).
 * Mirrors the Julia reference `_ref_closure`.
 */
function refClosure(refnames: Iterable<string>, named: Record<string, unknown>): Set<string> {
  const out = new Set<string>()
  const stack = [...refnames]
  while (stack.length > 0) {
    const n = stack.pop()!
    if (out.has(n) || !Object.prototype.hasOwnProperty.call(named, n)) continue
    const decl = named[n]
    if (isObject(decl) && decl.match !== undefined) continue // match rules not materialized
    out.add(n)
    for (const r of collectApplyNames(isObject(decl) ? decl.body : undefined, [])) stack.push(r)
  }
  return out
}

/**
 * Per-component MATCH-LESS template names authored in-file in `rawSource`
 * (`compKind.cname` → ordered names). Emit keeps these verbatim as authored
 * entries (esm-spec §9.6.4 rule 5); imported/derived templates are materialized
 * instead. Mirrors the Julia reference `_authored_template_names`.
 */
export function authoredTemplateNames(rawSource: unknown): Record<string, string[]> {
  const authored: Record<string, string[]> = {}
  if (!isObject(rawSource)) return authored
  for (const compKind of COMP_KINDS) {
    const comps = rawSource[compKind]
    if (!isObject(comps)) continue
    for (const [cname, comp] of Object.entries(comps)) {
      if (!isObject(comp)) continue
      const tpl = comp.expression_templates
      if (!isObject(tpl)) continue
      const names: string[] = []
      for (const [n, d] of Object.entries(tpl)) {
        if (!isObject(d)) continue
        if (d.match !== undefined) continue // only match-less are referenceable
        names.push(n)
      }
      authored[`${compKind}.${cname}`] = names
    }
  }
  return authored
}

/**
 * Build the reference-preserving, self-contained emitted document (esm-spec
 * §9.6.4 rule 5, §7.5) from an already Option-B-loaded document `loaded` and
 * the authored-name map from the pristine source. For every component builds
 * its emitted `expression_templates` block — authored match-less entries first
 * in authored order, then the materialized transitive closure of its surviving
 * references (match-less), lexicographically sorted — drops consumed
 * `expression_template_imports`, and version-stamps `esm: 0.9.0` when any
 * surviving reference or materialized entry remains (§9.6.4 rule 8). Mutates
 * and returns `loaded`. Mirrors the Julia reference `emit_document` tail.
 */
export function buildEmittedDocument(
  loaded: Record<string, unknown>,
  authored: Record<string, string[]>,
): Record<string, unknown> {
  const root = loaded
  let bump = false

  for (const compKind of COMP_KINDS) {
    const comps = root[compKind]
    if (!isObject(comps)) continue
    for (const [cname, comp] of Object.entries(comps)) {
      if (!isObject(comp)) continue
      const key = `${compKind}.${cname}`
      const named = namedRegistry(comp)
      const refnames = new Set<string>()
      for (const [k, v] of Object.entries(comp)) {
        if (k === 'expression_templates' || k === 'expression_template_imports') continue
        for (const r of collectApplyNames(v, [])) refnames.add(r)
      }
      if (refnames.size > 0) bump = true
      const materialized = refClosure(refnames, named)
      const authoredHere = authored[key] ?? []
      const authoredSet = new Set(authoredHere)

      const emitBlock: Record<string, unknown> = {}
      for (const n of authoredHere) {
        if (Object.prototype.hasOwnProperty.call(named, n)) emitBlock[n] = named[n]
      }
      for (const n of [...materialized].filter((n) => !authoredSet.has(n)).sort()) {
        emitBlock[n] = named[n]
        bump = true
      }

      if (Object.keys(emitBlock).length === 0) {
        delete comp.expression_templates
      } else {
        comp.expression_templates = emitBlock
      }
      delete comp.expression_template_imports
    }
  }

  delete root.expression_template_imports
  if (bump) root.esm = '0.9.0'
  return root
}

// --- Canonical byte writer (2-space indent, keys sorted except the ordered
//     `expression_templates` block) — the cross-binding byte-identity surface. ---

/** Format a scalar leaf for the canonical emit writer. */
function emitScalar(x: unknown): string {
  if (x === undefined || x === null) return 'null'
  if (isNumericLiteral(x)) {
    const v = numericValue(x)
    return v === undefined ? 'null' : JSON.stringify(v)
  }
  return JSON.stringify(x)
}

function emitWrite(out: string[], x: unknown, indent: number, preserve: boolean): void {
  const pad = '  '.repeat(indent)
  const pad1 = '  '.repeat(indent + 1)
  if (isObject(x)) {
    const rawKeys = Object.keys(x)
    if (rawKeys.length === 0) {
      out.push('{}')
      return
    }
    const ks = preserve ? rawKeys : [...rawKeys].sort()
    out.push('{\n')
    ks.forEach((k, i) => {
      out.push(pad1, JSON.stringify(k), ': ')
      emitWrite(out, (x as Record<string, unknown>)[k], indent + 1, k === 'expression_templates')
      if (i < ks.length - 1) out.push(',')
      out.push('\n')
    })
    out.push(pad, '}')
  } else if (Array.isArray(x)) {
    if (x.length === 0) {
      out.push('[]')
      return
    }
    out.push('[\n')
    x.forEach((v, i) => {
      out.push(pad1)
      emitWrite(out, v, indent + 1, false)
      if (i < x.length - 1) out.push(',')
      out.push('\n')
    })
    out.push(pad, ']')
  } else {
    out.push(emitScalar(x))
  }
}

/**
 * Canonical byte serialization of an emitted document (esm-spec §9.6.4 rule 5):
 * 2-space indent, object keys sorted lexicographically (UTF-8 byte order)
 * EXCEPT the entries of an `expression_templates` object, which preserve their
 * authored-first / materialized-sorted order. The cross-binding byte-identity
 * surface for the Option-B emitted form and the target of the `emitted.esm`
 * goldens. Mirrors the Julia reference `emit_esm_string`.
 */
export function emitEsmString(doc: unknown): string {
  const out: string[] = []
  emitWrite(out, doc, 0, false)
  out.push('\n')
  return out.join('')
}

// ===========================================================================
// Flatten: template-registry merge (esm-spec §9.6.4 rule 7, §10.7;
// esm-libraries-spec §4.7.5)
// ===========================================================================

/**
 * Rewrite the `name` of every `apply_expression_template` reference in `node`
 * according to `rename` (old name → new name), in lockstep with a registry
 * rename. Mirrors the Julia reference `_rename_apply_refs`.
 */
function renameApplyRefs(node: Json, rename: Record<string, string>): Json {
  if (Array.isArray(node)) {
    return node.map((v) => renameApplyRefs(v, rename))
  }
  if (isObject(node)) {
    const isApply = node.op === APPLY_OP
    const out: Record<string, unknown> = {}
    for (const k of Object.keys(node)) {
      if (
        isApply &&
        k === 'name' &&
        typeof node[k] === 'string' &&
        Object.prototype.hasOwnProperty.call(rename, node[k] as string)
      ) {
        out[k] = rename[node[k] as string]
      } else {
        out[k] = renameApplyRefs(node[k], rename)
      }
    }
    return out
  }
  return node
}

/** Result of {@link flattenTemplateRegistries}: the rewritten document + merged registry. */
export interface FlattenedTemplateRegistries {
  root: Record<string, unknown>
  merged: Record<string, unknown>
}

/**
 * The flatten-time template-registry merge (esm-spec §9.6.4 rule 7, §10.7;
 * esm-libraries-spec §4.7.5 step 4). Given an Option-B loaded multi-component
 * document `loaded`, merge every component's match-less `expression_templates`
 * registry into a single document-scoped merged registry:
 *
 *  - **Deep-equal dedup at first occurrence** — two components importing one
 *    stencil produce identical folded bodies, kept once under the bare name.
 *  - **Non-deep-equal same-name collision** — both entries are renamed
 *    deterministically to `<ComponentPath>.<name>` and their
 *    `apply_expression_template` references are rewritten in lockstep.
 *
 * Returns the rewritten document `root` (component reference sites updated) and
 * the merged registry (the FlattenedSystem's first-class registry field).
 * `match` rules are not merged (only match-less templates are referenceable).
 * Mirrors the Julia reference `flatten_template_registries`.
 */
export function flattenTemplateRegistries(loaded: object): FlattenedTemplateRegistries {
  const root = deepClone(loaded) as Record<string, unknown>
  // (path, comp, named)
  const comps: { path: string; comp: Record<string, unknown>; named: Record<string, unknown> }[] =
    []
  for (const compKind of COMP_KINDS) {
    const cs = root[compKind]
    if (!isObject(cs)) continue
    for (const [cname, comp] of Object.entries(cs)) {
      if (!isObject(comp)) continue
      const named: Record<string, unknown> = {}
      const tpl = comp.expression_templates
      if (isObject(tpl)) {
        for (const [n, d] of Object.entries(tpl)) {
          if (isObject(d) && d.match !== undefined) continue // match rules not merged
          named[n] = d
        }
      }
      comps.push({ path: cname, comp, named })
    }
  }

  // Group each template name across components (preserving first-seen path).
  const byname = new Map<string, { path: string; decl: unknown }[]>()
  for (const { path, named } of comps) {
    for (const n of Object.keys(named).sort()) {
      if (!byname.has(n)) byname.set(n, [])
      byname.get(n)!.push({ path, decl: named[n] })
    }
  }

  const merged: Record<string, unknown> = {}
  const rename: Record<string, Record<string, string>> = {} // path => (old => new)
  for (const name of [...byname.keys()].sort()) {
    const occ = byname.get(name)!
    const allEq = occ.every((o) => deepEqual(occ[0]!.decl, o.decl))
    if (allEq) {
      merged[name] = occ[0]!.decl // deep-equal dedup
    } else {
      for (const { path, decl } of occ) {
        // collision: owner-path rename
        const newname = `${path}.${name}`
        merged[newname] = decl
        ;(rename[path] ??= {})[name] = newname
      }
    }
  }

  // Rewrite reference sites in lockstep (component expression positions and the
  // carried bodies of the renamed entries).
  for (const { path, comp } of comps) {
    const rn = rename[path]
    if (rn) {
      for (const k of Object.keys(comp)) {
        if (k === 'expression_templates') continue
        comp[k] = renameApplyRefs(comp[k], rn)
      }
      for (const newname of Object.values(rn)) {
        if (Object.prototype.hasOwnProperty.call(merged, newname)) {
          merged[newname] = renameApplyRefs(merged[newname], rn)
        }
      }
    }
    // Drop the now-merged per-component block from the flattened form.
    if ('expression_templates' in comp) delete comp.expression_templates
  }

  return { root, merged }
}
