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
 */

import { isNumericLiteral, numericValue } from './numeric-literal.js'

const APPLY_OP = 'apply_expression_template'

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
type TemplateDecl = { params: string[]; body: Json; match?: Json; priority?: unknown }
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
}

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
 * agree. Used for match-binding consistency and pattern literal checks.
 */
function deepEqual(a: Json, b: Json): boolean {
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

/** Validate a template body contains no apply_expression_template nodes. */
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
        'apply_expression_template_recursive_body',
        `expression_templates.${templateName}: body contains nested 'apply_expression_template' at ${path}; templates MUST NOT call other templates`,
      )
    }
    for (const k of Object.keys(body)) {
      assertNoNestedApply(body[k], templateName, `${path}/${k}`)
    }
  }
}

function validateTemplates(templates: Templates, scope: string): void {
  for (const [name, decl] of Object.entries(templates)) {
    if (!decl || typeof decl !== 'object') {
      throw new ExpressionTemplateError(
        'apply_expression_template_invalid_declaration',
        `${scope}.expression_templates.${name}: entry must be an object with params + body`,
      )
    }
    const params = (decl as { params?: unknown }).params
    if (!Array.isArray(params) || params.length === 0) {
      throw new ExpressionTemplateError(
        'apply_expression_template_invalid_declaration',
        `${scope}.expression_templates.${name}: 'params' must be a non-empty array of strings`,
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
    const body = (decl as { body: Json }).body
    assertNoNestedApply(body, name, '/body')
    // esm-spec §9.6.3: nontermination is NOT checked statically any more — the
    // bounded fixpoint (`MAX_REWRITE_PASSES`) is the authoritative guard, so a
    // self-reintroducing rule is rejected (`rewrite_rule_nonterminating`) only
    // when it actually fails to converge. A `match` pattern still MUST NOT
    // contain nested apply_expression_template ops.
    const match = (decl as { match?: Json }).match
    if (match !== undefined) {
      assertNoNestedApply(match, name, '/match')
    }
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
): PassResult {
  if (Array.isArray(node)) {
    let changed = false
    const out = node.map((c) => {
      const r = onePass(c, templates, sortedRules, scope, last)
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
    if (matchPattern(rule.match, node, rule.params, bindings)) {
      last.op = typeof node.op === 'string' ? node.op : ''
      return { node: substitute(rule.body, bindings), changed: true }
    }
  }
  // (2) No rule fired here — descend into children.
  let changed = false
  const out: Record<string, unknown> = {}
  for (const k of Object.keys(node)) {
    const r = onePass(node[k], templates, sortedRules, scope, last)
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
): Json {
  const last = { op: '' }
  let current = node
  for (let pass = 0; pass < MAX_REWRITE_PASSES; pass++) {
    const { node: next, changed } = onePass(current, templates, sortedRules, scope, last)
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
export function lowerExpressionTemplates<T extends object>(file: T): T {
  rejectExpressionTemplatesPreV04(file)

  if (!isObject(file)) return file
  const root = file as Record<string, unknown>

  // Scan globally for apply ops (orphan-op detection) and for any
  // expression_templates block (a component may carry `match` rules that
  // must run even when there are no apply ops).
  const globalOps = findStrayApplyOps(file)
  if (globalOps.length === 0 && !hasExpressionTemplatesBlock(root)) {
    // Nothing to expand and no rules to apply; strip empty
    // expression_templates blocks for canonical-form invariance and return.
    return stripExpressionTemplates(file)
  }

  // Walk both component families.
  const out = deepClone(root)
  for (const compKind of ['models', 'reaction_systems'] as const) {
    const comps = out[compKind]
    if (!isObject(comps)) continue
    for (const [compName, compRaw] of Object.entries(comps)) {
      if (!isObject(compRaw)) continue
      const comp = compRaw as Component
      const tplRaw = comp.expression_templates
      // `templates`  — every template keyed by name, consulted by
      //                `apply_expression_template` (order-independent).
      // `matchRules` — the auto-applied `match` rules, pre-sorted by
      //                (−priority, declarationIndex) so `onePass` takes the
      //                FIRST matching rule (esm-spec §9.6.3).
      const templates: Templates = {}
      const matchRules: MatchRule[] = []
      if (isObject(tplRaw)) {
        const all: Templates = {}
        for (const [tname, tdecl] of Object.entries(tplRaw)) {
          all[tname] = tdecl as TemplateDecl
        }
        validateTemplates(all, `${compKind}.${compName}`)
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
            })
          }
          declIndex++
        }
        // Deterministic selection order (esm-spec §9.6.3): highest `priority`
        // first, ties broken by declaration order (earliest wins).
        matchRules.sort((a, b) => b.priority - a.priority || a.declIndex - b.declIndex)
      }
      // Rewrite every property except expression_templates (we don't expand
      // inside template bodies — those are validated above) to a fixpoint.
      for (const k of Object.keys(comp)) {
        if (k === 'expression_templates') continue
        comp[k] = rewriteToFixpoint(comp[k], templates, matchRules, `${compKind}.${compName}.${k}`)
      }
      delete comp.expression_templates
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
