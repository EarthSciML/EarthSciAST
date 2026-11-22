/**
 * Load-time rewrite pass for `operators` (esm-spec §9.6 /
 * docs/rfcs/ast-expression-templates.md, docs/rfcs/open-op-namespace-fixpoint-rewrite.md).
 *
 * An `operators` entry is a **rewrite rule** with `params`
 * (metavariables), a `body` (the replacement Expression), an optional
 * integer `priority`, and an optional `match` pattern. This single engine
 * covers both application modes:
 *
 *   - **No `match`** — the entry is applied only by an explicit
 *     `apply_operator` node that names it and supplies
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
 * (`rewritePass`) is a single **pre-order (outermost-first)** walk of the tree.
 * At each object node the structurally-matching `match` rule of highest
 * `priority` (integer, default 0; ties broken by DECLARATION order) whose
 * `where` holds fires, and the firing writes a REFERENCE to the rule in place
 * of the node (constraint 7; a leaf-bodied rule writes its leaf); the walk does
 * **not** descend into it during the current pass. At an
 * `apply_operator` node no rule is tried, but the walk descends into
 * the values of its `bindings`. If nothing fires, the walk descends into
 * children. Passes repeat until a pass performs **zero** rewrites; a rewrite
 * whose depth (the pass that made it) would exceed `MAX_REWRITE_PASSES = 64`
 * rejects the file with `rewrite_rule_nonterminating`.
 *
 * Then rule 3 (esm-spec §9.6.4): the rules rewrite the body of every template
 * the references reach, once per template instance (`applyRule3`), with depth
 * counted through bodies. One distinct rewritten body replaces the template's
 * in place (unless a registry entry rule 3 leaves as authored still references
 * the template, directly or through such entries: then it becomes
 * `<name>.variant1`); several become `<name>.variant<k>` entries; every reference is
 * re-pointed, and each referenced rule is materialized without `match`,
 * `where` and `priority`. Nothing here expands a reference: references survive
 * and denote their expansion (`Expand`, §9.6.4 rule 2). Any rewrite-target op
 * (e.g. a spatial `D`) left in an evaluation position or a reachable body is
 * caught later by the `unlowered_operator` gate (`evaluateExpression`).
 *
 * Operates on the pre-coercion JSON view (plain objects) — runs in
 * `load()` after schema validation but before typed coercion.
 *
 * Errors (raised directly by this file; the code STRINGS live in
 * `./errors.js` `ERROR_CODES`):
 *   - operator_unknown_definition
 *   - operator_bindings_mismatch
 *   - operator_recursive_body
 *   - operator_version_too_old
 *   - operator_invalid_definition
 *   - rewrite_rule_nonterminating
 *   - operator_constraint_unknown_index_set   (§9.6.1 `where` registration)
 *   - makearray_region_inverted               (§9.6.4 expanded-form validator)
 *
 * plus the esm-spec §9.7 template-library / metaparameter codes (§9.6.6,
 * raised from `template-imports.ts` and `ref-loading.ts`):
 *
 *   - operator_import_version_too_old
 *   - operator_import_unresolved
 *   - operator_import_not_library
 *   - subsystem_ref_is_operator_library
 *   - operator_import_cycle
 *   - operator_import_name_conflict
 *   - operator_import_unknown_name
 *   - operator_import_index_set_conflict
 *   - operator_body_expansion_too_deep
 *   - metaparameter_unbound
 *   - metaparameter_type_error
 *   - metaparameter_name_conflict
 */

import { isNumericLiteral, numericValue } from './numeric-literal.js'
import { deepClone, isObject } from './object-utils.js'
import { ERROR_CODES, EsmDiagnosticError } from './errors.js'
import { lowerEnumOpsForFile } from './lower-enums.js'
import { wireOldSpellings } from './old-spellings.js'
import { isCoreOp } from './op-registry.js'
import {
  type BodyView,
  deepEqual,
  definitionDefines,
  matchPattern,
  matchRootOp,
  onlyOpArgs,
  substituteBindings,
  withDefines,
} from './operator-definitions.js'
import {
  JSON_DESCEND,
  canonicalCompact,
  compareUtf8,
  rewriteJson,
  rewriteJsonChildren,
  visitJson,
} from './json-rewrite.js'

const APPLY_OP = 'apply_operator'

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
 * raise it as their common coded-diagnostic class — `validate` maps it (by
 * `instanceof`) to the `expression_template_error` load-error kind. A subclass
 * of {@link EsmDiagnosticError}: `code` is the specific diagnostic and the
 * message text is `[code] message`.
 */
export class EsmMachineryError extends EsmDiagnosticError {
  constructor(code: string, message: string) {
    super(code, `[${code}] ${message}`)
    this.name = 'EsmMachineryError'
  }
}

/**
 * @deprecated Alias of {@link EsmMachineryError} — the SAME class object, so
 * `instanceof ExpressionTemplateError` and `instanceof EsmMachineryError` are
 * identical. Prefer {@link EsmMachineryError}, which names the class's role as
 * the shared load-time template/coupling/import/ref machinery diagnostic.
 */
export { EsmMachineryError as ExpressionTemplateError }

// The definition layer (esm 2.4.0 defined operators), re-exported for the
// modules that import it from here.
export {
  deepEqual,
  definitionDefines,
  explainUnresolvedCall,
  substituteBindings,
  withDefines,
} from './operator-definitions.js'

type Json = unknown
type TemplateDecl = {
  params: string[]
  body: Json
  match?: Json
  priority?: unknown
  /** Static match-scoping constraints (esm-spec §9.6.1 `where`). */
  where?: unknown
  /** The defined operator this entry is a definition of (esm-spec §9.6.1, esm 2.4.0). */
  defines?: unknown
  /** The definition's unit expression (esm-spec §9.6.12 "Units"). */
  units?: unknown
}
/** Named templates invoked explicitly via `apply_operator` (no `match`). */
type Templates = Record<string, TemplateDecl>

/** An auto-applied rewrite rule (a template carrying a `match` pattern). */
interface MatchRule {
  name: string
  params: Set<string>
  /** `params` in declared order: the keys of the reference a firing writes (§9.6.3 constraint 7). */
  paramList: string[]
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
  /**
   * esm 2.4.0 (esm-spec §9.6.3 constraint 2, §9.6.12): a match-less definition
   * is eligible at a CALL of the defined operator it defines — `match` is
   * `{op: defines, args: params}` and the node may carry no field besides `op`
   * and `args` (`exact`).
   */
  exact: boolean
}

/**
 * The §9.6.3 selection order of two rules: highest `priority` first, then a
 * definition carrying a `where` before one without (esm 2.4.0), then
 * declaration order.
 */
function compareSelection(a: MatchRule, b: MatchRule): number {
  return (
    b.priority - a.priority ||
    (a.whereConstraint === null ? 1 : 0) - (b.whereConstraint === null ? 1 : 0) ||
    a.declIndex - b.declIndex
  )
}

/**
 * esm-spec §9.6.12 "Core names are reserved": a definition whose `defines`,
 * written or inferred, is a core operator's name is `operator_defines_core_op`.
 * A rule whose `match` is rooted at a core op defines no callable name, so its
 * `defines` is provenance only and is not checked.
 */
function checkDefinesNotCore(name: string, decl: unknown, scope: string): void {
  const r = matchRootOp(decl)
  if (r !== undefined && isCoreOp(r)) return
  const d = definitionDefines(name, decl)
  if (isCoreOp(d)) {
    throw new EsmMachineryError(
      ERROR_CODES.OPERATOR_DEFINES_CORE_OP,
      `${scope}.operators.${name}: defines the core operator '${d}'; a definition may not ` +
        `define a core operator's name (esm-spec §9.6.12, "Core names are reserved")`,
    )
  }
}

/** The static shape environment of one component (variable name → declared shape). */
type ShapeEnv = Record<string, string[]>

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
 * Deep equality of two `index_sets` declarations for the §4.7 mount merge and
 * the §9.7.5 template-import merge: {@link deepEqual}, with `"records": false`
 * read as an absent `records` (esm-spec §8.5.1), so the two spellings are one
 * declaration while `"records": true` against either is a conflict.
 */
export function indexSetDeclEqual(a: Json, b: Json): boolean {
  const plain = (d: Json): Json => {
    if (!isObject(d) || d.records !== false) return d
    const { records: _records, ...rest } = d
    return rest
  }
  return deepEqual(plain(a), plain(b))
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
  bv?: BodyView,
): boolean {
  if (whereC === null) return true
  for (const [p, req] of Object.entries(whereC)) {
    const b = Object.prototype.hasOwnProperty.call(bindings, p) ? bindings[p] : undefined
    if (typeof b !== 'string') return false
    // A template-body parameter satisfies it iff its instance binds a bare
    // variable of exactly that declared shape (esm-spec §9.6.4 rule 3).
    if (bv !== undefined && bv.params.has(b)) {
      if ((bv.entries.get(b) ?? '') !== shapeEntry(req)) return false
      continue
    }
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
 * unknown name is `operator_constraint_unknown_index_set` (esm-spec §9.6.6) —
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
          ERROR_CODES.OPERATOR_CONSTRAINT_UNKNOWN_INDEX_SET,
          `${scope}.operators.${tname}: where.${p}.shape names index set '${s}', which the consuming document's index_sets registry does not declare (esm-spec §9.6.1/§9.6.6)`,
        )
      }
    }
    out[p] = req
  }
  return out
}

/**
 * Reject `apply_operator` nodes inside a `match` pattern
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
        ERROR_CODES.OPERATOR_INVALID_DEFINITION,
        `operators.${templateName}: \`match\` contains an 'apply_operator' node at ${path}; match patterns MUST NOT reference templates (esm-spec §9.7.3)`,
      )
    }
    for (const k of Object.keys(body)) {
      assertNoNestedApply(body[k], templateName, `${path}/${k}`)
    }
  }
}

/**
 * Structurally validate a raw `operators` block (esm-spec §9.6.1).
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
        ERROR_CODES.OPERATOR_INVALID_DEFINITION,
        `${scope}.operators.${name}: entry must be an object with params + body`,
      )
    }
    // `params` MAY be empty (esm-spec §9.6.1, 0.8.0): a zero-parameter
    // template is a named constant fragment (common in library files).
    const params = (decl as { params?: unknown }).params
    if (!Array.isArray(params)) {
      throw new EsmMachineryError(
        ERROR_CODES.OPERATOR_INVALID_DEFINITION,
        `${scope}.operators.${name}: 'params' must be an array of strings`,
      )
    }
    const seen = new Set<string>()
    for (const p of params) {
      if (typeof p !== 'string' || p.length === 0) {
        throw new EsmMachineryError(
          ERROR_CODES.OPERATOR_INVALID_DEFINITION,
          `${scope}.operators.${name}: param names must be non-empty strings`,
        )
      }
      if (seen.has(p)) {
        throw new EsmMachineryError(
          ERROR_CODES.OPERATOR_INVALID_DEFINITION,
          `${scope}.operators.${name}: param '${p}' is declared twice`,
        )
      }
      seen.add(p)
    }
    if (!('body' in (decl as object))) {
      throw new EsmMachineryError(
        ERROR_CODES.OPERATOR_INVALID_DEFINITION,
        `${scope}.operators.${name}: 'body' is required`,
      )
    }
    // A body MAY reference other match-less in-scope templates via
    // apply_operator nodes (esm-spec §9.7.3); those are checked
    // (acyclic, depth <= MAX_TEMPLATE_EXPANSION_DEPTH) and inlined at
    // registration by `composeTemplateBodies` — the old any-nesting rejection
    // is now cycle-only (`operator_recursive_body`).
    //
    // esm-spec §9.6.3: nontermination is NOT checked statically any more — the
    // bounded fixpoint (`MAX_REWRITE_PASSES`) is the authoritative guard, so a
    // self-reintroducing rule is rejected (`rewrite_rule_nonterminating`) only
    // when it actually fails to converge. A `match` pattern still MUST NOT
    // contain nested apply_operator ops.
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
      // esm 2.4.0 (esm-spec §9.6.3 constraint 2, §9.6.8): a `where` scopes a
      // match-less definition too, at a call of the defined operator it defines.
      if (!isObject(whr) || Object.keys(whr).length === 0) {
        throw new EsmMachineryError(
          ERROR_CODES.OPERATOR_INVALID_DEFINITION,
          `${scope}.operators.${name}: 'where' must be a non-empty object mapping declared params to constraint objects`,
        )
      }
      for (const [p, cobj] of Object.entries(whr)) {
        if (!seen.has(p)) {
          throw new EsmMachineryError(
            ERROR_CODES.OPERATOR_INVALID_DEFINITION,
            `${scope}.operators.${name}: 'where' constrains '${p}', which is not a declared param (esm-spec §9.6.1)`,
          )
        }
        if (!isObject(cobj)) {
          throw new EsmMachineryError(
            ERROR_CODES.OPERATOR_INVALID_DEFINITION,
            `${scope}.operators.${name}: where.${p} must be a constraint object (v1 admits exactly the 'shape' kind)`,
          )
        }
        const ckeys = Object.keys(cobj)
        if (!(ckeys.length === 1 && ckeys[0] === 'shape')) {
          throw new EsmMachineryError(
            ERROR_CODES.OPERATOR_INVALID_DEFINITION,
            `${scope}.operators.${name}: where.${p} carries constraint kind(s) ${[...ckeys].sort().join(', ')}; the v1 constraint vocabulary is exactly {shape} (esm-spec §9.6.1)`,
          )
        }
        const shp = (cobj as { shape?: unknown }).shape
        if (!Array.isArray(shp) || shp.length === 0) {
          throw new EsmMachineryError(
            ERROR_CODES.OPERATOR_INVALID_DEFINITION,
            `${scope}.operators.${name}: where.${p}.shape must be a non-empty array of index-set names`,
          )
        }
        for (const s of shp) {
          if (typeof s !== 'string' || s.length === 0) {
            throw new EsmMachineryError(
              ERROR_CODES.OPERATOR_INVALID_DEFINITION,
              `${scope}.operators.${name}: where.${p}.shape entries must be non-empty strings`,
            )
          }
        }
      }
    }
  }
}

/**
 * Maximum template-body reference-chain depth (counted in TEMPLATES along the
 * longest chain, so a 65-template chain is rejected while a 64-template chain
 * is accepted) before a file is rejected with
 * `operator_body_expansion_too_deep` (esm-spec §9.7.3). Pinned identically
 * across all bindings. It equals `MAX_REWRITE_PASSES`: a rewrite of depth `d`
 * writes a body-reference chain `d` templates deep, so every document the
 * rewriter accepts also reloads once emitted with its references.
 */
export const MAX_TEMPLATE_EXPANSION_DEPTH = 64

/** Collect the `name`s of every `apply_operator` node in a tree. */
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
 * `apply_operator` nodes. Builds the body-reference graph, rejects
 * cycles (`operator_recursive_body`), references to undeclared
 * or `match`-bearing templates (`operator_unknown_definition`),
 * and chains deeper than `MAX_TEMPLATE_EXPANSION_DEPTH` templates
 * (`operator_body_expansion_too_deep`).
 *
 * From `esm: 0.9.0` (RFC out-of-line-expression-templates §7.1 step 4) bodies
 * are **NOT inlined** — the references are preserved uninlined and denote their
 * expansion (§9.6.4 rule 2). Runs BEFORE the §9.6.3 fixpoint
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
          ERROR_CODES.OPERATOR_UNKNOWN_DEFINITION,
          `${scope}.operators.${name}: body references undeclared template '${r}' (esm-spec §9.7.3)`,
        )
      }
      if ((tdecl as { match?: Json }).match !== undefined) {
        throw new EsmMachineryError(
          ERROR_CODES.OPERATOR_UNKNOWN_DEFINITION,
          `${scope}.operators.${name}: body references '${r}', a \`match\` rewrite rule — only match-less templates are invocable by name (esm-spec §9.7.3)`,
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
        ERROR_CODES.OPERATOR_RECURSIVE_BODY,
        `${scope}.operators: template-body reference cycle ${cyc.join(' -> ')} (esm-spec §9.7.3)`,
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
        ERROR_CODES.OPERATOR_BODY_EXPANSION_TOO_DEEP,
        `${scope}.operators.${name}: body-reference chain of ${d} templates exceeds MAX_TEMPLATE_EXPANSION_DEPTH=${MAX_TEMPLATE_EXPANSION_DEPTH} (esm-spec §9.7.3)`,
      )
    }
    return d
  }
  for (const name of [...names].sort()) visit(name)
}

/**
 * Expand a single `apply_operator` node against `templates`.
 * The template `body` is instantiated by pure structural substitution of the
 * supplied `bindings`; the bindings are spliced in AS-IS (not pre-scanned) —
 * any `apply_operator` or match-able node inside a binding is
 * rewritten in a SUBSEQUENT pass of the outermost-first fixpoint, never within
 * the current pass (esm-spec §9.6.3).
 */
function expandApply(node: Record<string, unknown>, templates: Templates, scope: string): Json {
  const name = node.name
  if (typeof name !== 'string' || name.length === 0) {
    throw new EsmMachineryError(
      ERROR_CODES.OPERATOR_INVALID_DEFINITION,
      `${scope}: apply_operator node missing or empty 'name'`,
    )
  }
  const decl = templates[name]
  if (!decl) {
    throw new EsmMachineryError(
      ERROR_CODES.OPERATOR_UNKNOWN_DEFINITION,
      `${scope}: apply_operator references undeclared template '${name}'`,
    )
  }
  const bindings = node.bindings
  if (!isObject(bindings)) {
    throw new EsmMachineryError(
      ERROR_CODES.OPERATOR_BINDINGS_MISMATCH,
      `${scope}: apply_operator '${name}' missing 'bindings' object`,
    )
  }
  const provided = new Set(Object.keys(bindings))
  const declared = new Set(decl.params)
  for (const p of decl.params) {
    if (!provided.has(p)) {
      throw new EsmMachineryError(
        ERROR_CODES.OPERATOR_BINDINGS_MISMATCH,
        `${scope}: apply_operator '${name}' missing binding for param '${p}'`,
      )
    }
  }
  for (const p of provided) {
    if (!declared.has(p)) {
      throw new EsmMachineryError(
        ERROR_CODES.OPERATOR_BINDINGS_MISMATCH,
        `${scope}: apply_operator '${name}' supplies unknown param '${p}'`,
      )
    }
  }
  // Bindings are spliced in AS-IS (esm-spec §9.6.3): `substitute` splices each
  // value BY REFERENCE (structural sharing — expanded forms are never mutated
  // in place downstream), so the narrowed `bindings` map is passed straight
  // through — no copy is needed or meaningful here.
  return substituteBindings(decl.body, bindings)
}

// ---------------------------------------------------------------------------
// Op flags over the template reference DAG (the library-edge `enum` lowering)
// ---------------------------------------------------------------------------

/**
 * True iff `node` contains, anywhere within it, an object whose `op` satisfies
 * `pred`.
 */
function directOp(
  node: Json,
  pred: (op: string) => boolean,
  seen: Set<object> = new Set(),
): boolean {
  if (Array.isArray(node)) {
    if (seen.has(node)) return false
    seen.add(node)
    for (const c of node) if (directOp(c, pred, seen)) return true
    return false
  }
  if (isObject(node)) {
    if (seen.has(node)) return false
    seen.add(node)
    if (typeof node.op === 'string' && pred(node.op)) return true
    for (const k of Object.keys(node)) if (directOp(node[k], pred, seen)) return true
    return false
  }
  return false
}

/**
 * Compute, for every template in `templates`, whether it can produce an object
 * whose `op` satisfies `pred`: its body contains one anywhere (including inside
 * nested references' `bindings`), or it references, transitively through the
 * acyclic body-reference DAG, a template that can.
 */
export function templateOpBearing(
  templates: Record<string, unknown>,
  pred: (op: string) => boolean,
): Record<string, boolean> {
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
    let res = body !== undefined && directOp(body, pred)
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
 * Fully expand EVERY `apply_operator` node in `node` by pure
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
 * The ONE call-site resolution shared by the surviving-reference check
 * ({@link validateApplyRef}) and rule 3 ({@link refInstance}): `name` present,
 * declared in `templates`, `bindings` an object covering the declaration's
 * `params` exactly. `rejectMatchRule` additionally rejects a reference to a
 * `match` rewrite rule (only match-less templates are invocable by name,
 * esm-spec §9.6.2); that check runs directly after the declaration lookup, so it
 * takes precedence over a bindings mismatch. Mirrors the Julia reference
 * `_resolve_apply_site`.
 */
function resolveApplySite(
  node: Record<string, unknown>,
  templates: Templates,
  scope: string,
  rejectMatchRule: boolean,
): { name: string; decl: TemplateDecl; bindings: Record<string, unknown> } {
  const name = node.name
  if (typeof name !== 'string' || name.length === 0) {
    throw new EsmMachineryError(
      ERROR_CODES.OPERATOR_INVALID_DEFINITION,
      `${scope}: apply_operator node missing or empty 'name'`,
    )
  }
  const decl = Object.prototype.hasOwnProperty.call(templates, name) ? templates[name] : undefined
  if (!decl) {
    throw new EsmMachineryError(
      ERROR_CODES.OPERATOR_UNKNOWN_DEFINITION,
      `${scope}: apply_operator references undeclared template '${name}'`,
    )
  }
  if (rejectMatchRule && (decl as { match?: Json }).match !== undefined) {
    throw new EsmMachineryError(
      ERROR_CODES.OPERATOR_UNKNOWN_DEFINITION,
      `${scope}: apply_operator references '${name}', a \`match\` rewrite rule — only match-less templates are invocable by name (esm-spec §9.6.2)`,
    )
  }
  const bindings = node.bindings
  if (!isObject(bindings)) {
    throw new EsmMachineryError(
      ERROR_CODES.OPERATOR_BINDINGS_MISMATCH,
      `${scope}: apply_operator '${name}' missing 'bindings' object`,
    )
  }
  const provided = new Set(Object.keys(bindings))
  const declared = new Set(decl.params)
  for (const p of decl.params) {
    if (!provided.has(p)) {
      throw new EsmMachineryError(
        ERROR_CODES.OPERATOR_BINDINGS_MISMATCH,
        `${scope}: apply_operator '${name}' missing binding for param '${p}'`,
      )
    }
  }
  for (const p of provided) {
    if (!declared.has(p)) {
      throw new EsmMachineryError(
        ERROR_CODES.OPERATOR_BINDINGS_MISMATCH,
        `${scope}: apply_operator '${name}' supplies unknown param '${p}'`,
      )
    }
  }
  return { name, decl, bindings }
}

/**
 * Call-site check for a SURVIVING `apply_operator` reference
 * (esm-spec §9.6.9): the referenced `name` must resolve to an in-scope
 * MATCH-LESS template (a rule a firing referenced was materialized match-less
 * by rule 3) and `bindings` must cover its `params` exactly.
 */
function validateApplyRef(
  node: Record<string, unknown>,
  templates: Templates,
  scope: string,
): void {
  resolveApplySite(node, templates, scope, true)
}

/**
 * Walk `node` and run {@link validateApplyRef} on every surviving
 * `apply_operator` reference it carries (esm-spec §9.6.9 call-site
 * checks). Descends into references' `bindings` too — a binding value MAY itself
 * be a surviving reference. Mirrors the Julia reference `_check_surviving_refs`.
 */
function checkSurvivingRefs(node: Json, templates: Templates, scope: string): void {
  visitJson(node, (n) => {
    if (n.op === APPLY_OP) validateApplyRef(n, templates, scope)
  })
}

/** Whether `n` is an `apply_operator` node. */
function isApplyNode(n: unknown): n is Record<string, unknown> {
  return isObject(n) && n.op === APPLY_OP
}

/**
 * One component's rewrite state (esm-spec §9.6.3, §9.6.4 rule 3): `named` —
 * every template declaration keyed by name (the component's registry, to which
 * rule 3 adds its variants); `matchRules` — the auto-applied rules in §9.6.3
 * selection order; `shapeEnv` — the component's static shape environment;
 * `enums` — the document's `enums` block (the per-instance `enum` lowering of
 * rule 3); `depth` — the rewrite depth of each reference a firing wrote (the
 * pass that wrote it; an authored reference has depth 0 and no entry). Mirrors
 * the Julia reference `_Lowering`.
 */
interface Lowering {
  named: Templates
  matchRules: MatchRule[]
  /**
   * Match-less definitions by the defined operator they define, each list in
   * §9.6.3 selection order (esm 2.4.0 calls by operator name).
   */
  callRules: Map<string, MatchRule[]>
  /** Operand counts the definitions of each defined operator take (esm-spec §9.6.12 "Arity"). */
  arities: Map<string, Set<number>>
  /** The component-wide call scope {@link callScopeAt} narrows per subsystem. */
  calls: CallScope
  shapeEnv: ShapeEnv
  enums: unknown
  scope: string
  depth: Map<object, number>
}

/**
 * What a firing of `rule` writes in place of the matched node (esm-spec §9.6.3
 * constraint 7): a reference to the rule bound to what the match captured, a
 * parameter the match never bound being bound to its own name. A rule whose
 * body is a single leaf writes the leaf (for one of its parameters, what that
 * parameter bound): there is no body to share.
 */
function ruleReference(rule: MatchRule, captured: Record<string, Json>): Json {
  const body = rule.body
  const has = (p: string): boolean => Object.prototype.hasOwnProperty.call(captured, p)
  if (!isObject(body) && !Array.isArray(body)) {
    if (typeof body === 'string' && rule.params.has(body)) return has(body) ? captured[body] : body
    return body
  }
  const b: Record<string, Json> = {}
  for (const p of rule.paramList) b[p] = has(p) ? captured[p] : p
  return { op: APPLY_OP, args: [], name: rule.name, bindings: b }
}

/**
 * One pre-order (outermost-first) rewrite pass over `node` (esm-spec §9.6.3), a
 * sharing-preserving walk. At each object node the first rule in
 * `L.matchRules` (highest `priority` first, ties by declaration order) whose
 * `match` pattern matches AND whose `where` constraints hold fires; constraint
 * filtering is part of match eligibility (§9.6.3 constraint 2). A firing writes
 * a reference to the rule ({@link ruleReference}, constraint 7), recorded in
 * `L.depth` at depth `pass`, and the walk does not descend into it during this
 * pass. At a reference — authored or written — no pattern matches (§9.6.4
 * rule 4), but the walk descends into the values of its `bindings`. `bv` is the
 * template-body view when `node` is a body rewritten for one instance (§9.6.4
 * rule 3). Mirrors the Julia reference `_rewrite_pass`.
 */
function rewritePass(
  node: Json,
  L: Lowering,
  pass: number,
  last: { name: string },
  bv: BodyView | undefined,
): { node: Json; changed: boolean } {
  let changed = false
  const out = rewriteJson(node, (rw, n) => {
    if (n.op === APPLY_OP) {
      const b = n.bindings
      if (!isObject(b)) return n
      const nb = rewriteJsonChildren(rw, b)
      if (nb === b) return n
      const nn: Record<string, unknown> = {}
      for (const k of Object.keys(n)) nn[k] = k === 'bindings' ? nb : n[k]
      const d = L.depth.get(n)
      if (d !== undefined) L.depth.set(nn, d)
      return nn
    }
    const win = selectDefinition(L, n, bv)
    if (win !== null) {
      last.name = win.rule.name
      changed = true
      const r = ruleReference(win.rule, win.bindings)
      if (isApplyNode(r)) L.depth.set(r, pass)
      return r
    }
    return JSON_DESCEND
  })
  return { node: out, changed }
}

/**
 * The definition that resolves node `n` (esm-spec §9.6.3 constraint 2,
 * §9.6.12): among the `match` rules whose pattern matches and the match-less
 * definitions of the defined operator `n.op` that take `n`'s operands, those
 * whose `where` holds, the first in {@link compareSelection} order.
 */
function selectDefinition(
  L: Lowering,
  n: Record<string, unknown>,
  bv: BodyView | undefined,
): { rule: MatchRule; bindings: Record<string, Json> } | null {
  let best: { rule: MatchRule; bindings: Record<string, Json> } | null = null
  for (const rule of L.matchRules) {
    const b: Record<string, Json> = {}
    if (
      matchPattern(rule.match, n, rule.params, b, bv) &&
      whereSatisfied(rule.whereConstraint, b, L.shapeEnv, bv)
    ) {
      best = { rule, bindings: b }
      break
    }
  }
  const calls = typeof n.op === 'string' && n.op !== '' ? L.callRules.get(n.op) : undefined
  if (calls !== undefined && onlyOpArgs(n)) {
    for (const rule of calls) {
      if (best !== null && compareSelection(best.rule, rule) < 0) break
      const b: Record<string, Json> = {}
      if (
        matchPattern(rule.match, n, rule.params, b, bv) &&
        whereSatisfied(rule.whereConstraint, b, L.shapeEnv, bv)
      ) {
        best = { rule, bindings: b }
        break
      }
    }
  }
  return best
}

/**
 * esm-spec §9.6.12 "Arity": a call of a defined operator `N` that survives the
 * fixpoint, when definitions of `N` are in scope and none takes the call's
 * operand count, is `operator_arity_mismatch` at load. A name with no
 * definition in scope is a placeholder, whatever its arity.
 */
function checkCallArity(node: Json, L: Lowering, scope: string): void {
  if (L.arities.size === 0) return
  visitJson(node, (n) => {
    const op = n.op
    if (typeof op !== 'string') return
    const counts = L.arities.get(op)
    if (counts === undefined || isCoreOp(op)) return
    const k = Array.isArray(n.args) ? n.args.length : 0
    if (counts.has(k)) return
    throw new EsmMachineryError(
      ERROR_CODES.OPERATOR_ARITY_MISMATCH,
      `${scope}: a call of the defined operator '${op}' carries ${k} operand(s), but its ` +
        `definitions in scope take ${[...counts].sort((a, b) => a - b).join(', ')} ` +
        `(esm-spec §9.6.12)`,
    )
  })
}

/** The registry entries a node's references reach, transitively through bodies. */
function reachedDefinitions(out: Set<string>, node: Json, named: Templates): Set<string> {
  for (const r of collectApplyNames(node, [])) {
    if (out.has(r)) continue
    if (!Object.prototype.hasOwnProperty.call(named, r)) continue
    out.add(r)
    reachedDefinitions(out, named[r]!.body, named)
  }
  return out
}

/**
 * Drive {@link rewritePass} to a fixpoint (esm-spec §9.6.3): repeat pre-order
 * passes until one performs zero rewrites. A rewrite made in pass `p` has depth
 * `p`; one whose depth would exceed `MAX_REWRITE_PASSES` rejects the file with
 * `rewrite_rule_nonterminating` (so at most `MAX_REWRITE_PASSES + 1` passes run,
 * the last of which must rewrite nothing). Returns the rewritten node and the
 * number of productive passes. Mirrors the Julia reference
 * `_rewrite_to_fixpoint`.
 */
function rewriteToFixpoint(
  node: Json,
  L: Lowering,
  scope: string,
  bv?: BodyView,
): { node: Json; passes: number } {
  const last = { name: '' }
  let current = node
  for (let pass = 1; pass <= MAX_REWRITE_PASSES + 1; pass++) {
    const r = rewritePass(current, L, pass, last, bv)
    current = r.node
    if (!r.changed) return { node: current, passes: pass - 1 }
  }
  throw new EsmMachineryError(
    ERROR_CODES.REWRITE_RULE_NONTERMINATING,
    `${scope}: expression-template rewriting did not converge within ` +
      `MAX_REWRITE_PASSES=${MAX_REWRITE_PASSES} passes (last rule fired ` +
      `'${last.name}'). A \`match\` rule likely re-introduces its own pattern ` +
      `(esm-spec §9.6.3).`,
  )
}

// ===========================================================================
// Rule 3: rewriting inside template bodies, once per template instance
// (esm-spec §9.6.4 rule 3). Mirrors the Julia reference `templates/instances.jl`.
// ===========================================================================

/** The instance entry of a bare variable with declared shape `shape`. */
function shapeEntry(shape: readonly string[]): string {
  return 'V' + canonicalCompact(shape)
}

/** Fields whose value is an Expression (an operand position). */
const OPERAND_FIELDS = new Set(['expr', 'filter', 'key', 'lower', 'upper'])
const OPERAND_LIST_FIELDS = new Set(['args', 'values'])

/**
 * The parameters of a template that occur in a structural position of `body`
 * (esm-spec §9.6.4 rule 3): anywhere but an operand position — a scalar field
 * (`wrt`, `dim`, `fn`, …), a `ranges` bound or `from`, an `enum` argument. An
 * operand position is an element of `args` or `values` (but not an `enum` op's
 * `args`), the value of `expr`, `filter`, `key`, `lower` or `upper`, a value of
 * a nested reference's `bindings`, or the body itself.
 */
function structuralParams(body: Json, params: readonly string[]): Set<string> {
  const P = new Set(params)
  const out = new Set<string>()
  const walk = (x: Json, operand: boolean): void => {
    if (typeof x === 'string') {
      if (!operand && P.has(x)) out.add(x)
    } else if (Array.isArray(x)) {
      for (const v of x) walk(v, operand)
    } else if (isObject(x)) {
      const ops = typeof x.op === 'string' ? x.op : x.op === undefined ? '' : String(x.op)
      for (const k of Object.keys(x)) {
        const v = x[k]
        if (k === 'op' || (k === 'name' && ops === APPLY_OP)) continue
        if (k === 'bindings' && ops === APPLY_OP && isObject(v)) {
          for (const bvv of Object.values(v)) walk(bvv, true)
        } else if (OPERAND_LIST_FIELDS.has(k) && ops !== 'enum') {
          walk(v, true)
        } else if (OPERAND_FIELDS.has(k)) {
          walk(v, true)
        } else {
          walk(v, false)
        }
      }
    }
  }
  walk(body, true)
  return out
}

const NO_LIT: unique symbol = Symbol('no-literal')

/** A JSON number or boolean (plain or a tagged numeric literal). */
function isNumberLike(v: unknown): boolean {
  return typeof v === 'number' || typeof v === 'boolean' || isNumericLiteral(v)
}

/**
 * The instance entry (esm-spec §9.6.4 rule 3) for one parameter bound to `v`:
 * inside a body (`bv`), a binding that is one of the body's own parameters
 * forwards the enclosing instance's entry; a structural parameter takes the
 * literal bound (`"L" + canonical bytes`); otherwise the kind — `"V" + shape`
 * for a bare variable with a declared shape, `"V"` for one without, `"N"` for a
 * number or boolean literal, `"E"` for any other expression. The literal is
 * the value a structural position reads, or {@link NO_LIT}.
 */
function instanceEntry(
  v: Json,
  structural: boolean,
  L: Lowering,
  bv: BodyView | undefined,
): [string, Json | typeof NO_LIT] {
  if (typeof v === 'string' && bv !== undefined && bv.params.has(v)) {
    return [bv.entries.get(v)!, bv.lit.has(v) ? bv.lit.get(v) : NO_LIT]
  }
  if (structural) {
    if (typeof v === 'string' || isNumberLike(v)) return ['L' + canonicalCompact(v), v]
    return ['E', NO_LIT]
  }
  if (typeof v === 'string') {
    const shp = Object.prototype.hasOwnProperty.call(L.shapeEnv, v) ? L.shapeEnv[v] : undefined
    return [shp === undefined ? 'V' : shapeEntry(shp), NO_LIT]
  }
  if (isNumberLike(v)) return ['N', NO_LIT]
  return ['E', NO_LIT]
}

/**
 * One rewritten template instance: the template's `name`, the body as rule 3
 * rewrote it (references not yet re-pointed to variants), the instance key of
 * every reference in that body (by node identity), and its height — the
 * deepest rewrite depth below the reference that names it.
 */
interface InstanceResult {
  key: string
  name: string
  body: Json
  refs: Map<object, string>
  height: number
}

interface Rule3State {
  L: Lowering
  done: Map<string, InstanceResult>
  active: string[]
  structural: Map<string, Set<string>>
  order: string[]
}

function nonterminating(scope: string, msg: string): never {
  throw new EsmMachineryError(
    ERROR_CODES.REWRITE_RULE_NONTERMINATING,
    `${scope}: ${msg} (esm-spec §9.6.4 rule 3)`,
  )
}

/**
 * The structural parameters of template `name` ({@link structuralParams}), plus
 * each parameter forwarded whole into a structural parameter of a template its
 * body references (transitively). Memoized per template; a template reached
 * again while being computed contributes its direct set.
 */
function templateStructural(st: Rule3State, name: string, decl: TemplateDecl): Set<string> {
  const r = st.structural.get(name)
  if (r !== undefined) return r
  const S = structuralParams(decl.body, decl.params)
  st.structural.set(name, S) // a cycle reads the direct set
  const P = new Set(decl.params)
  visitJson(decl.body, (n) => {
    if (n.op !== APPLY_OP) return
    const inner = n.name
    const b = n.bindings
    if (typeof inner !== 'string' || !isObject(b)) return
    const idecl = Object.prototype.hasOwnProperty.call(st.L.named, inner)
      ? st.L.named[inner]
      : undefined
    if (!idecl) return
    const IS = templateStructural(st, inner, idecl)
    for (const [k, v] of Object.entries(b)) {
      if (typeof v === 'string' && P.has(v) && IS.has(k)) S.add(v)
    }
  })
  return S
}

/**
 * The rewritten instance a reference `n` names, computed once per instance. A
 * reference the author wrote must name a match-less template (§9.6.2); one a
 * firing wrote (it has a depth) names its rule. `bv` is the enclosing body's
 * view when `n` sits in a template body, `undefined` at a call site.
 */
function refInstance(
  st: Rule3State,
  n: Record<string, unknown>,
  bv: BodyView | undefined,
  scope: string,
): InstanceResult {
  const written = st.L.depth.has(n)
  const { name, decl, bindings } = resolveApplySite(n, st.L.named, scope, !written)
  const params = decl.params
  const S = templateStructural(st, name, decl)
  const entries: string[] = []
  const lits = new Map<string, Json>()
  for (const p of params) {
    const [e, l] = instanceEntry(bindings[p], S.has(p), st.L, bv)
    entries.push(e)
    if (l !== NO_LIT) lits.set(p, l)
  }
  return instance(st, name, decl, params, entries, lits)
}

function instance(
  st: Rule3State,
  name: string,
  decl: TemplateDecl,
  params: string[],
  entries: string[],
  lits: Map<string, Json>,
): InstanceResult {
  const key = [name, ...entries].join('\x1f')
  const r = st.done.get(key)
  if (r !== undefined) return r
  const tscope = `${st.L.scope}.operators.${name}`
  if (st.active.includes(key)) {
    nonterminating(
      tscope,
      `rewriting template '${name}' needs the same template instance again — a \`match\` ` +
        `rule re-introduces its own pattern through the template's body`,
    )
  }
  st.active.push(key)
  const bv: BodyView = {
    params: new Set(params),
    lit: lits,
    entries: new Map(params.map((p, i) => [p, entries[i]!])),
  }
  const body = instancePartial(lowerBodyEnums(decl.body, bv, st.L.enums), bv)
  const { node: rewritten, passes } = rewriteToFixpoint(body, st.L, tscope, bv)
  const refs = new Map<object, string>()
  let height = passes
  visitJson(rewritten, (n) => {
    if (n.op !== APPLY_OP) return
    const child = refInstance(st, n, bv, tscope)
    refs.set(n, child.key)
    height = Math.max(height, (st.L.depth.get(n) ?? 0) + child.height)
  })
  if (height > MAX_REWRITE_PASSES) {
    nonterminating(
      tscope,
      `a rewrite inside template '${name}' has depth ${height}, beyond MAX_REWRITE_PASSES=` +
        `${MAX_REWRITE_PASSES} (depth counts through template bodies)`,
    )
  }
  st.active.pop()
  const res: InstanceResult = { key, name, body: rewritten, refs, height }
  st.done.set(key, res)
  st.order.push(key)
  return res
}

/**
 * esm-spec §4.2 "Reading earlier documents": a `D` whose `wrt` is one of the
 * definition's `params` is decided per instance — where the instance binds that
 * parameter to an axis name other than `"t"`, the `D` reads as `partial` in
 * this instance (the wire boundary left it as written). Bound to `"t"`, it
 * stays the time derivative.
 */
function instancePartial(body: Json, bv: BodyView): Json {
  return rewriteJson(body, (rw, n) => {
    if (n.op !== 'D') return JSON_DESCEND
    const w = n.wrt
    if (typeof w !== 'string' || !bv.params.has(w)) return JSON_DESCEND
    const lit = bv.lit.has(w) ? bv.lit.get(w) : NO_LIT
    if (typeof lit !== 'string' || lit === 't') return JSON_DESCEND
    const nn = rewriteJsonChildren(rw, n) as Record<string, unknown>
    return { ...nn, op: 'partial' }
  })
}

/**
 * The `enum` lowering of esm-spec §9.3 applied inside a template body for one
 * instance (§9.6.4 rule 3): an `enum` op whose two arguments are strings, or
 * parameters the instance binds to strings, becomes its `const`; one still
 * spelled with an unbound parameter stays as written.
 */
function lowerBodyEnums(body: Json, bv: BodyView, enums: unknown): Json {
  return rewriteJson(body, (_rw, n) => {
    if (n.op !== 'enum') return JSON_DESCEND
    const args = n.args
    if (!Array.isArray(args) || args.length !== 2) return n
    const resolved = args.map((a) =>
      typeof a === 'string' && bv.params.has(a) ? (bv.lit.has(a) ? bv.lit.get(a) : NO_LIT) : a,
    )
    if (!resolved.every((a) => typeof a === 'string')) return n
    return lowerEnumOpsForFile({ enums }, { ...n, args: resolved })
  })
}

/**
 * `x` with every reference re-pointed to the entry its instance was given:
 * `refs` maps a reference node (by identity) to its instance key, `final` an
 * instance key to the registry name its body lives under.
 */
function repointRefs(x: Json, refs: Map<object, string>, final: Map<string, string>): Json {
  return rewriteJson(x, (rw, n) => {
    if (n.op !== APPLY_OP) return JSON_DESCEND
    const key = refs.get(n)
    const nn = rewriteJsonChildren(rw, n, 'name') as Record<string, unknown>
    const newname = key === undefined ? undefined : final.get(key)
    if (newname === undefined || newname === n.name) return nn
    return { ...nn, name: newname }
  })
}

/**
 * The template-level order in which instances are named: a template after
 * every template its instances' bodies reference. A cycle is a rule that
 * re-introduces itself through a template body.
 */
function rule3TemplateOrder(st: Rule3State, byTemplate: Map<string, string[]>): string[] {
  const deps = new Map<string, string[]>()
  for (const [t, keysT] of byTemplate) {
    const ds: string[] = []
    for (const k of keysT) {
      for (const ck of st.done.get(k)!.refs.values()) {
        const dn = st.done.get(ck)!.name
        if (!ds.includes(dn)) ds.push(dn)
      }
    }
    deps.set(t, ds)
  }
  const order: string[] = []
  const state = new Map<string, number>()
  const visit = (t: string): void => {
    const s = state.get(t) ?? 0
    if (s === 2) return
    if (s === 1) {
      nonterminating(
        st.L.scope,
        `template '${t}' reaches itself through the references rules wrote in template bodies`,
      )
    }
    state.set(t, 1)
    for (const d of deps.get(t)!) visit(d)
    state.set(t, 2)
    order.push(t)
  }
  for (const t of byTemplate.keys()) visit(t)
  return order
}

/**
 * The templates whose reached instances rewrite to more than one distinct body.
 * Naming each single-bodied template in place or as `<name>.variant1` renames
 * every reference to it alike, so which bodies are distinct does not depend on
 * that choice: this provisional pass names every single-bodied template in
 * place. Mirrors the Julia `_rule3_multi`.
 */
function rule3Multi(
  st: Rule3State,
  byTemplate: Map<string, string[]>,
  order: string[],
): Set<string> {
  const final = new Map<string, string>()
  const multi = new Set<string>()
  for (const t of order) {
    const keysT = byTemplate.get(t)!
    const canon = keysT.map((k) => {
      const r = st.done.get(k)!
      return canonicalCompact(repointRefs(r.body, r.refs, final))
    })
    const distinct = [...new Set(canon)].sort(compareUtf8)
    if (distinct.length === 1) {
      for (const k of keysT) final.set(k, t)
      continue
    }
    multi.add(t)
    keysT.forEach((k, i) => final.set(k, `${t}\x1f${distinct.indexOf(canon[i]!) + 1}`))
  }
  return multi
}

/**
 * The reached match-less templates whose authored body stays reachable from a
 * registry entry that rule 3 does not rewrite under its own name (esm-spec
 * §9.6.4 rule 3): a match-less entry no reference reaches, one whose instances
 * took variants, and, transitively, any reached template such an entry
 * references. Such a template keeps its authored body; a single rewritten body
 * is registered as `<name>.variant1` instead. Mirrors the Julia
 * `_rule3_exposed`.
 */
function rule3Exposed(
  st: Rule3State,
  byTemplate: Map<string, string[]>,
  order: string[],
): Set<string> {
  const named = st.L.named as Record<string, unknown>
  const matchless = (n: string): boolean => {
    const d = Object.prototype.hasOwnProperty.call(named, n) ? named[n] : undefined
    return isObject(d) && (d as { match?: unknown }).match == null
  }
  const memo = new Map<string, string[]>()
  const refsOf = (n: string): string[] => {
    let r = memo.get(n)
    if (r === undefined) {
      const d = named[n]
      const body = isObject(d) ? (d as { body?: Json }).body : undefined
      r = [...new Set(collectApplyNames(body as Json, []))].filter(
        (x) => byTemplate.has(x) && matchless(x),
      )
      memo.set(n, r)
    }
    return r
  }
  const stack = Object.keys(named).filter((n) => !byTemplate.has(n) && matchless(n))
  if ([...byTemplate.keys()].some((t) => matchless(t) && refsOf(t).length > 0)) {
    for (const t of rule3Multi(st, byTemplate, order)) if (matchless(t)) stack.push(t)
  }
  const visible = new Set<string>()
  while (stack.length > 0) {
    const n = stack.pop()!
    for (const r of refsOf(n)) {
      if (visible.has(r)) continue
      visible.add(r)
      stack.push(r)
    }
  }
  return visible
}

/** `decl` without `match`, `where` and `priority`. */
function matchStripped(decl: TemplateDecl): TemplateDecl {
  const out: Record<string, unknown> = {}
  for (const [k, v] of Object.entries(decl)) {
    if (k === 'match' || k === 'where' || k === 'priority') continue
    out[k] = v
  }
  return out as TemplateDecl
}

/**
 * Esm-spec §9.6.4 rule 3 for one component whose expression positions (and the
 * coupling `transforms` it receives, `variable_map` entries) have reached the
 * §9.6.3 fixpoint: rewrite the body of every template instance their
 * references reach, place each result (in place, or as `<name>.variant<k>`),
 * re-point the references, materialize each referenced `match` rule without its
 * `match`, `where` and `priority`, and check the rewrite depth of every call
 * site. Mirrors the Julia reference `_apply_rule3!`.
 */
function applyRule3(
  comp: Record<string, unknown>,
  L: Lowering,
  transforms: { entry: Record<string, unknown>; scope: string }[],
): void {
  const st: Rule3State = { L, done: new Map(), active: [], structural: new Map(), order: [] }
  const siteRefs = new Map<object, string>()
  const sites: [Record<string, unknown>, string, string][] = []
  for (const k of Object.keys(comp)) {
    if (k === 'operators') continue
    sites.push([comp, k, `${L.scope}.${k}`])
  }
  for (const { entry, scope } of transforms) sites.push([entry, 'transform', scope])
  for (const [holder, k, scope] of sites) {
    visitJson(holder[k], (n) => {
      if (n.op !== APPLY_OP) return
      const res = refInstance(st, n, undefined, scope)
      siteRefs.set(n, res.key)
      const d = (L.depth.get(n) ?? 0) + res.height
      if (d > MAX_REWRITE_PASSES) {
        nonterminating(
          scope,
          `a rewrite through template '${res.name}' has depth ${d}, beyond ` +
            `MAX_REWRITE_PASSES=${MAX_REWRITE_PASSES} (depth counts through template bodies)`,
        )
      }
    })
  }
  if (st.order.length === 0) return

  const byTemplate = new Map<string, string[]>()
  for (const k of st.order) {
    const t = st.done.get(k)!.name
    if (!byTemplate.has(t)) byTemplate.set(t, [])
    byTemplate.get(t)!.push(k)
  }
  const final = new Map<string, string>()
  if (!isObject(comp.operators)) comp.operators = L.named
  const block = comp.operators as Record<string, unknown>
  const taken = new Set(Object.keys(L.named))
  const order = rule3TemplateOrder(st, byTemplate)
  const exposed = rule3Exposed(st, byTemplate, order)
  for (const t of order) {
    const keysT = byTemplate.get(t)!
    const bodies = keysT.map((k) => {
      const r = st.done.get(k)!
      return repointRefs(r.body, r.refs, final)
    })
    const canon = bodies.map((b) => canonicalCompact(b))
    const distinct = [...new Set(canon)].sort(compareUtf8)
    const decl = L.named[t]!
    if (distinct.length === 1 && !(exposed.has(t) && distinct[0] !== canonicalCompact(decl.body))) {
      for (const k of keysT) final.set(k, t)
      const isRule = (decl as { match?: Json }).match !== undefined
      const nd = isRule ? matchStripped(decl) : ({ ...decl } as TemplateDecl)
      if (distinct[0] !== canonicalCompact(decl.body)) {
        nd.body = bodies[0]
      } else if (!isRule) {
        continue
      }
      L.named[t] = nd
      block[t] = nd
    } else {
      const names = new Map<string, string>()
      distinct.forEach((c, i) => {
        let vn = `${t}.variant${i + 1}`
        while (taken.has(vn)) vn += '_'
        taken.add(vn)
        names.set(c, vn)
        const nd = matchStripped(decl)
        nd.body = bodies[canon.indexOf(c)]
        L.named[vn] = nd
        block[vn] = nd
      })
      keysT.forEach((k, i) => final.set(k, names.get(canon[i]!)!))
    }
  }
  for (const [holder, k] of sites) holder[k] = repointRefs(holder[k], siteRefs, final)
}

/**
 * Walk the file looking for apply_operator ops anywhere.
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
      if (v.op === APPLY_OP || v.op === 'apply_expression_template') hits.push(path)
      for (const k of Object.keys(v)) {
        // An `apply_operator` inside an `operators` BLOCK is
        // not a stray call site — it is template COMPOSITION (§9.7.3): one template's
        // body naming another, expanded when the template is INVOKED, not where it is
        // DECLARED. The scanner never saw one before only because the declaration was
        // deleted on the way out; now that §9.6.4 rule 5 keeps the registry, skipping
        // the block is what tells a declaration apart from an unexpanded call.
        if (k === 'operators') continue
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
 * Reject `apply_operator` and `operators` in files
 * declaring `esm` < 0.4.0. Operates on the pre-coercion JSON view.
 */
export function rejectExpressionTemplatesPreV04(view: unknown): void {
  if (!isObject(view)) return
  const v = parseSemver((view as { esm?: unknown }).esm)
  if (!v) return
  const isPreV04 = v.major === 0 && v.minor < 4
  if (!isPreV04) return

  const offences: string[] = []
  // operators blocks anywhere
  // The esm-2.4.0 names and their old spellings alike (esm-spec §9.6.5).
  forEachRawComponent(view, (compKind, name, comp) => {
    for (const k of ['operators', 'expression_templates']) {
      if (k in comp) offences.push(`/${compKind}/${name}/${k}`)
    }
  })
  // apply_operator ops anywhere in the AST
  for (const path of findStrayApplyOps(view)) offences.push(path)

  if (offences.length > 0) {
    throw new EsmMachineryError(
      ERROR_CODES.OPERATOR_VERSION_TOO_OLD,
      `operators / apply_operator require esm >= 0.4.0; file declares ${(view as { esm?: string }).esm}. Offending paths: ${offences.join(', ')}`,
    )
  }
}

interface Component {
  operators?: unknown
  [k: string]: unknown
}

/**
 * The rewrite context of one component: its named templates (consulted by
 * `apply_operator`) plus its auto-applied `match` rules pre-sorted
 * by (−priority, declarationIndex) — exactly what `rewriteToFixpoint` needs.
 */
interface RewriteContext {
  templates: Templates
  matchRules: MatchRule[]
  /** Match-less definitions by the defined operator they define (esm 2.4.0). */
  callRules: Map<string, MatchRule[]>
  /** Operand counts the definitions of each defined operator take (§9.6.12). */
  arities: Map<string, Set<number>>
  /** Operand counts of the `match` rules alone, by the defined operator at their root. */
  matchArities: Map<string, Set<number>>
  /** Each match-less definition: its name, the operator it defines, its operand count. */
  matchlessArities: [string, string, number][]
  /** The enclosing component's static shape environment for `where` (esm-spec §9.6.1). */
  shapeEnv: ShapeEnv
}

/**
 * The definitions a component's calls may resolve to, by where the call
 * stands. Definitions are component-local (esm-spec §9.6.3 constraint 4): an
 * entry a subsystem's block contributed (a mounted leaf's, or an authored
 * subsystem's own) is a definition of its operator only at a call inside that
 * subsystem's subtree; the component's own entries are definitions everywhere
 * in it.
 */
interface CallScope {
  callRules: Map<string, MatchRule[]>
  matchArities: Map<string, Set<number>>
  matchlessArities: [string, string, number][]
  /** Registry entry => the subsystem paths (below the component) that own it; absent = the component's own. */
  owners: ReadonlyMap<string, ReadonlySet<string>>
}

/** Is the entry `name` a definition at a call standing in the subsystem `path` (`''` = the component itself)? */
function ownedOnPath(scope: CallScope, name: string, path: string): boolean {
  const owners = scope.owners.get(name)
  if (owners === undefined) return true
  for (const o of owners) if (path === o || path.startsWith(`${o}.`)) return true
  return false
}

/** The `callRules` and `arities` a call standing in the subsystem `path` sees. */
function callScopeAt(
  scope: CallScope,
  path: string,
): { callRules: Map<string, MatchRule[]>; arities: Map<string, Set<number>> } {
  const callRules = new Map<string, MatchRule[]>()
  for (const [op, list] of scope.callRules) {
    const kept = list.filter((r) => ownedOnPath(scope, r.name, path))
    if (kept.length > 0) callRules.set(op, kept)
  }
  const arities = new Map<string, Set<number>>()
  for (const [op, ks] of scope.matchArities) arities.set(op, new Set(ks))
  for (const [name, op, k] of scope.matchlessArities) {
    if (!ownedOnPath(scope, name, path)) continue
    let ks = arities.get(op)
    if (ks === undefined) arities.set(op, (ks = new Set()))
    ks.add(k)
  }
  return { callRules, arities }
}

/**
 * Apply `fn` to each non-registry field of `comp` with the {@link Lowering}
 * for where it stands: `comp`'s own fields with `L`, each subsystem's fields
 * (at any depth) with `L` narrowed to that subsystem's call scope. `fn`
 * returns the field's new value.
 */
function mapScopedFields(
  comp: Record<string, unknown>,
  L: Lowering,
  scope: string,
  fn: (node: Json, L: Lowering, scope: string) => Json,
): void {
  const walk = (node: Record<string, unknown>, path: string, nodeScope: string): void => {
    const here = path === '' ? L : { ...L, ...callScopeAt(L.calls, path) }
    for (const k of Object.keys(node)) {
      if (k === 'operators' && node === comp) continue
      const subs = node[k]
      if (k === 'subsystems' && isObject(subs)) {
        for (const [name, sub] of Object.entries(subs)) {
          const subPath = path === '' ? name : `${path}.${name}`
          const subScope = `${nodeScope}.subsystems.${name}`
          if (isObject(sub)) walk(sub, subPath, subScope)
          else subs[name] = fn(sub as Json, { ...L, ...callScopeAt(L.calls, subPath) }, subScope)
        }
        continue
      }
      node[k] = fn(node[k] as Json, here, `${nodeScope}.${k}`)
    }
  }
  walk(comp, '', scope)
}

/**
 * Build the rewrite context from a component's raw `operators`
 * block: validate declarations, compose body references (esm-spec §9.7.3),
 * and register `match` rules in deterministic selection order (§9.6.3). Each
 * rule's `where` constraints are normalized and checked against the consuming
 * document's merged `index_sets` registry (`isetNames`,
 * `operator_constraint_unknown_index_set`).
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
  const callRules = new Map<string, MatchRule[]>()
  const arities = new Map<string, Set<number>>()
  const matchArities = new Map<string, Set<number>>()
  const matchlessArities: [string, string, number][] = []
  const addArity = (into: Map<string, Set<number>>, op: string, k: number): void => {
    let s = into.get(op)
    if (s === undefined) into.set(op, (s = new Set()))
    s.add(k)
  }
  // Object key order in JS preserves declaration order, so the
  // enumeration index IS the authored declaration order.
  let declIndex = 0
  for (const [tname, decl0] of Object.entries(templates)) {
    // esm 2.4.0 (esm-spec §9.6.12): every definition records the defined
    // operator it defines; a core operator's name is reserved.
    checkDefinesNotCore(tname, decl0, scope)
    let decl = decl0
    if (decl0.defines === undefined) {
      decl = { ...decl0, defines: definitionDefines(tname, decl0) }
      templates[tname] = decl
    }
    const defines = definitionDefines(tname, decl)
    const rop = matchRootOp(decl)
    if (decl.match === undefined) {
      addArity(arities, defines, decl.params.length)
      matchlessArities.push([tname, defines, decl.params.length])
    } else if (rop !== undefined && !isCoreOp(rop)) {
      const margs = isObject(decl.match) ? decl.match.args : undefined
      addArity(arities, rop, Array.isArray(margs) ? margs.length : 0)
      addArity(matchArities, rop, Array.isArray(margs) ? margs.length : 0)
    }
    if (decl.match === undefined && !isCoreOp(defines) && defines !== APPLY_OP) {
      let list = callRules.get(defines)
      if (list === undefined) callRules.set(defines, (list = []))
      list.push({
        name: tname,
        params: new Set(decl.params),
        paramList: [...decl.params],
        match: { op: defines, args: [...decl.params] },
        body: decl.body,
        priority: rulePriority(decl),
        declIndex,
        whereConstraint: registeredWhere(decl, isetNames, scope, tname),
        exact: true,
      })
    }
    if (decl.match !== undefined) {
      matchRules.push({
        name: tname,
        params: new Set(decl.params),
        paramList: [...decl.params],
        match: decl.match,
        body: decl.body,
        priority: rulePriority(decl),
        declIndex,
        // `where` registration: normalize constraints and resolve every
        // referenced index-set name against the consuming registry (esm-spec
        // §9.6.1; `operator_constraint_unknown_index_set`).
        whereConstraint: registeredWhere(decl, isetNames, scope, tname),
        exact: false,
      })
    }
    declIndex++
  }
  // Deterministic selection order (esm-spec §9.6.3): highest `priority`
  // first, then a definition with a `where` before one without (esm 2.4.0),
  // then declaration order (earliest wins). `selectDefinition` takes the
  // FIRST eligible definition.
  matchRules.sort(compareSelection)
  for (const list of callRules.values()) list.sort(compareSelection)
  return { templates, matchRules, callRules, arities, matchArities, matchlessArities, shapeEnv }
}

/** True if any model / reaction_system declares an operators block. */
function hasExpressionTemplatesBlock(root: Record<string, unknown>): boolean {
  // A subsystem's own block counts: it joins its component's registry
  // (`hoistMountedTemplates`).
  const carries = (node: Record<string, unknown>): boolean => {
    if (isObject(node.operators)) return true
    const subs = node.subsystems
    if (!isObject(subs)) return false
    return Object.values(subs).some((sub) => isObject(sub) && carries(sub))
  }
  let found = false
  forEachRawComponent(root, (_kind, _name, comp) => {
    if (carries(comp)) found = true
  })
  return found
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
 * Visits each unique node once (`seen`, keyed on object identity — the
 * expanded form is a shared DAG; see `substitute`). The first, pre-order-earliest
 * offending node still throws with the same path as an unshared walk would,
 * because memoization never changes when a node is FIRST visited.
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
    if (k === 'operators') continue
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
        validateMakearrayRegions(body, `operators.${tname}/body`)
      }
    }
  }
}

/** Options of {@link lowerExpressionTemplates}. */
export interface LowerOptions {
  /**
   * Per component (`"models.<name>"` / `"reaction_systems.<name>"`), the
   * owners of the registry entries its subsystems contributed before this call
   * (a caller that ran {@link hoistMountedTemplates} itself): entry => the
   * subsystem paths below the component that own it.
   */
  owners?: ReadonlyMap<string, ReadonlyMap<string, ReadonlySet<string>>>
}

/**
 * Load the file under Option B (reference preservation, esm-spec §9.6.4): fire
 * auto-applied `match` rules to a fixpoint per component (outermost-first,
 * priority-ordered, bounded — §9.6.3), each firing writing a reference to its
 * rule (constraint 7); then rewrite the bodies of the templates the references
 * reach, once per template instance (§9.6.4 rule 3). No reference is expanded:
 * every `apply_operator` reference survives and denotes its
 * expansion (§9.6.4 rule 2). The per-component `operators`
 * registries are RETAINED (with referenced rules materialized match-less and
 * any `<name>.variant<k>` entries) — they are what {@link expandDocument}
 * consumes (rule 2) and emit materializes (rule 5). Call-site checks (§9.6.9)
 * and the registration-time makearray-region check run on the
 * reference-preserving form.
 *
 * Returns a new file object; the input is not mutated.
 *
 * Pre-condition: the input has been schema-validated.
 */
export function lowerExpressionTemplates<T extends object>(
  input: T,
  options: LowerOptions = {},
): T {
  // Old spellings (esm-spec §9.6.12) when the caller skipped the wire boundary.
  const file = wireOldSpellings(input)
  rejectExpressionTemplatesPreV04(file)

  if (!isObject(file)) return file
  const root = file as Record<string, unknown>

  // Scan globally for apply ops and for any operators block.
  const strayApplyPaths = findStrayApplyOps(file)
  if (strayApplyPaths.length === 0 && !hasExpressionTemplatesBlock(root)) {
    // No template machinery at all; the §9.6.4 expanded-form validator still
    // runs — the raw tree IS the expanded form. Return a fresh tree (the
    // "returns a fresh clone" contract callers rely on).
    validateMakearrayRegions(root)
    return deepClone(root) as T
  }

  // The consuming document's merged index_sets registry (post-§9.7.5): the
  // namespace `where` shape constraints resolve against at registration
  // (esm-spec §9.6.1 — `operator_constraint_unknown_index_set` for a name not
  // declared here).
  const isetNames = new Set<string>()
  if (isObject(root.index_sets)) {
    for (const k of Object.keys(root.index_sets)) isetNames.add(k)
  }

  const out = deepClone(root)
  const enums = out.enums
  // Contexts of components that DECLARE an operators block, per
  // family, for the registry validator below.
  const contextsByKind = {
    models: new Map<string, RewriteContext>(),
    reaction_systems: new Map<string, RewriteContext>(),
  }
  // Every component's rewrite state, captured so coupling `variable_map`
  // transforms (esm-spec §10.4) are rewritten against the RECEIVING
  // component's rules, and rule 3 runs per component afterwards.
  const lowerings: {
    comp: Record<string, unknown>
    L: Lowering
    transforms: { entry: Record<string, unknown>; scope: string }[]
  }[] = []
  const byKind = {
    models: new Map<string, number>(),
    reaction_systems: new Map<string, number>(),
  }
  forEachRawComponent(out, (compKind, compName, compRaw) => {
    const comp = compRaw as Component
    // A model mounted as a subsystem keeps its references and brings its
    // template definitions (as does an authored subsystem with its own block);
    // they join this component's registry here (esm-spec §9.6.4 rule 1).
    const cscope = `${compKind}.${compName}`
    const owners = new Map<string, Set<string>>()
    for (const [n, ps] of options.owners?.get(cscope) ?? []) owners.set(n, new Set(ps))
    hoistMountedTemplates(comp, compName, owners)
    const tplRaw = comp.operators
    const shapeEnv = componentShapeEnv(comp)
    let templates: Templates = {}
    let matchRules: MatchRule[] = []
    const calls: CallScope = {
      callRules: new Map(),
      matchArities: new Map(),
      matchlessArities: [],
      owners,
    }
    if (isObject(tplRaw)) {
      const ctx = buildRewriteContext(tplRaw, isetNames, shapeEnv, cscope)
      templates = ctx.templates
      matchRules = ctx.matchRules
      calls.callRules = ctx.callRules
      calls.matchArities = ctx.matchArities
      calls.matchlessArities = ctx.matchlessArities
      contextsByKind[compKind].set(compName, ctx)
    }
    const L: Lowering = {
      named: templates,
      matchRules,
      ...callScopeAt(calls, ''),
      calls,
      shapeEnv,
      enums,
      scope: cscope,
      depth: new Map(),
    }
    // Outermost-first, priority-ordered, bounded-fixpoint rewrite per
    // non-template field (esm-spec §9.6.3): each firing writes a reference to
    // its rule (constraint 7); references are leaves for matching and the walk
    // descends into their bindings (§9.6.4 rule 4). The registry block is
    // RETAINED (Option B, §9.6.4 rule 1).
    // A call resolves to the definitions of the component and of the
    // subsystems on the path to it, never to another subsystem's.
    mapScopedFields(comp, L, cscope, (node, Lp, scope) => rewriteToFixpoint(node, Lp, scope).node)
    lowerings.push({ comp, L, transforms: [] })
    // Only a component that declares templates receives transforms: one
    // without leaves the transform unrewritten (Expand rejects a dangling ref).
    if (isObject(tplRaw)) byKind[compKind].set(compName, lowerings.length - 1)
  })

  // Top-level coupling: a `variable_map` entry may carry an object-valued
  // Expression `transform` (esm-spec §8.6). It is rewritten to fixpoint with
  // the rules of the RECEIVING component — the first dot-segment of the
  // entry's `to`, looked up under models then reaction_systems — exactly as a
  // field of that component would be. A receiving component that is absent or
  // declares no templates leaves the transform unrewritten.
  const coupling = out.coupling
  if (Array.isArray(coupling)) {
    for (let i = 0; i < coupling.length; i++) {
      const entry = coupling[i]
      if (!isObject(entry) || entry.type !== 'variable_map') continue
      if (!isObject(entry.transform)) continue
      const to = entry.to
      if (typeof to !== 'string') continue
      const receiver = to.split('.')[0] ?? ''
      const idx = byKind.models.get(receiver) ?? byKind.reaction_systems.get(receiver)
      if (idx === undefined) continue
      const lw = lowerings[idx]!
      entry.transform = rewriteToFixpoint(entry.transform, lw.L, `coupling[${i}].transform`).node
      lw.transforms.push({ entry, scope: `coupling[${i}].transform` })
    }
  }

  // esm-spec §9.6.4 rule 3: the rules apply inside the bodies of the templates
  // the references reach, once per template instance, without expanding any
  // reference. Then the call-site checks on surviving references (§9.6.9):
  // unknown name / bindings mismatch, against the registry as rule 3 left it.
  for (const { comp, L, transforms } of lowerings) {
    applyRule3(comp, L, transforms)
    for (const k of Object.keys(comp)) {
      if (k === 'operators') continue
      checkSurvivingRefs(comp[k], L.named, `${L.scope}.${k}`)
    }
    for (const { entry, scope } of transforms) checkSurvivingRefs(entry.transform, L.named, scope)
    // esm-spec §9.6.12 "Arity": surviving calls in the component, in the
    // transforms it receives, and in the bodies its references reach.
    if (L.calls.matchArities.size > 0 || L.calls.matchlessArities.length > 0) {
      const reached = new Set<string>()
      mapScopedFields(comp, L, L.scope, (node, Lp, scope) => {
        checkCallArity(node, Lp, scope)
        reachedDefinitions(reached, node, L.named)
        return node
      })
      for (const { entry } of transforms) {
        checkCallArity(entry.transform, L, `${L.scope} coupling transform`)
        reachedDefinitions(reached, entry.transform, L.named)
      }
      for (const r of [...reached].sort(compareUtf8)) {
        // A subsystem's definition's body was checked where it was lowered.
        if (L.calls.owners.has(r)) continue
        checkCallArity(L.named[r]!.body, L, `${L.scope}.operators.${r}`)
      }
    }
  }

  // Validation discharge (esm-spec §9.6.9): the makearray-region check on the
  // reference-preserving form. Region bounds cannot carry template params, so
  // it runs on the reference-preserving tree AND the retained folded template
  // bodies directly.
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
  const tpl = comp.operators
  if (isObject(tpl)) {
    for (const [n, d] of Object.entries(tpl)) named[n] = d as TemplateDecl
  }
  return named
}

/**
 * Fully expand every surviving `apply_operator` reference in a
 * document `loaded` by {@link lowerExpressionTemplates} (Option B), producing
 * the Option-A image: every reference replaced by its expansion (pure
 * substitution to the acyclic fixpoint, §9.6.4 rule 2) and every per-component
 * `operators` block stripped. Deterministic — the §9.7.3 DAG is
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
      compNamed.set(`${compKind}\u0000${cname}`, namedRegistry(comp))
    }
  }

  for (const compKind of COMP_KINDS) {
    const comps = root[compKind]
    if (!isObject(comps)) continue
    for (const [cname, comp] of Object.entries(comps)) {
      if (!isObject(comp)) continue
      const named = compNamed.get(`${compKind}\u0000${cname}`)!
      const scope = `${compKind}.${cname}`
      for (const k of Object.keys(comp)) {
        if (k === 'operators' || k === 'operator_imports') continue
        comp[k] = expandAllNode(comp[k], named, `${scope}.${k}`)
      }
      delete comp.operators
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
        compNamed.get(`models\u0000${receiver}`) ??
        compNamed.get(`reaction_systems\u0000${receiver}`)
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
 * Per-component template names authored in-file in `rawSource`
 * (`compKind.cname` → ordered names). Emit keeps these in authored position
 * (esm-spec §9.6.4 rule 5): a match-less entry always, a `match` rule only when
 * a firing referenced it (it is then materialized without `match`, `where` and
 * `priority`); imported/derived templates are materialized instead. Mirrors the
 * Julia reference `_authored_template_names`.
 */
export function authoredTemplateNames(rawSource: unknown): Record<string, string[]> {
  const authored: Record<string, string[]> = {}
  if (!isObject(rawSource)) return authored
  for (const compKind of COMP_KINDS) {
    const comps = rawSource[compKind]
    if (!isObject(comps)) continue
    for (const [cname, comp] of Object.entries(comps)) {
      if (!isObject(comp)) continue
      const tpl = comp.operators
      if (!isObject(tpl)) continue
      const names: string[] = []
      for (const [n, d] of Object.entries(tpl)) {
        if (!isObject(d)) continue
        names.push(n)
      }
      authored[`${compKind}.${cname}`] = names
    }
  }
  return authored
}

/**
 * The template names referenced by the `variable_map` transforms each
 * component RECEIVES, keyed by component name (the first segment of `to`; the
 * first component of that name, models before reaction systems, as the
 * lowering pairs them). The transforms keep their references (esm-spec
 * §10.4); the receiving component owns them, so its emitted block
 * materializes their closure (§9.6.4 rule 5). Mirrors the Julia reference
 * `_received_transform_refs`.
 */
export function receivedTransformRefs(root: Record<string, unknown>): Map<string, string[]> {
  const out = new Map<string, string[]>()
  const coupling = root.coupling
  if (!Array.isArray(coupling)) return out
  for (const entry of coupling) {
    if (!isObject(entry) || entry.type !== 'variable_map') continue
    if (!isObject(entry.transform)) continue
    const to = entry.to
    if (typeof to !== 'string') continue
    const receiver = to.split('.')[0] ?? ''
    let names = out.get(receiver)
    if (names === undefined) {
      names = []
      out.set(receiver, names)
    }
    collectApplyNames(entry.transform as Json, names)
  }
  return out
}

/**
 * The emitted `operators` block of one Option-B loaded component
 * (esm-spec §9.6.4 rule 5): authored entries first in authored order (a
 * `match` rule only once rule 3 materialized it match-less), then the closure
 * of its references not authored here, sorted by UTF-8 bytes. `referenced` is
 * whether the component carries a surviving reference, `materialized` whether
 * a non-authored entry was added. `received` names the references of the
 * coupling transforms the component receives ({@link receivedTransformRefs}),
 * which count as its own. Shared by emit ({@link buildEmittedDocument})
 * and the typed load path's per-component registry capture. Does not mutate
 * `comp`. Mirrors the Python/Rust `materialize_component_block`.
 */
export function materializeComponentBlock(
  comp: Record<string, unknown>,
  authoredHere: readonly string[],
  received: readonly string[] = [],
): { block: Record<string, unknown>; referenced: boolean; materialized: boolean } {
  const named = namedRegistry(comp)
  const refnames = new Set<string>(received)
  for (const [k, v] of Object.entries(comp)) {
    if (k === 'operators' || k === 'operator_imports') continue
    for (const r of collectApplyNames(v, [])) refnames.add(r)
  }
  const closure = refClosure(refnames, named)
  const authoredSet = new Set(authoredHere)
  const block: Record<string, unknown> = {}
  for (const n of authoredHere) {
    // A `match` rule nothing references still carries its `match` (a
    // referenced one was materialized without it, §9.6.4 rule 3).
    if (
      Object.prototype.hasOwnProperty.call(named, n) &&
      (named[n] as { match?: Json }).match === undefined
    ) {
      block[n] = named[n]
    }
  }
  let materialized = false
  for (const n of [...closure].filter((n) => !authoredSet.has(n)).sort(compareUtf8)) {
    block[n] = named[n]
    materialized = true
  }
  return { block, referenced: refnames.size > 0, materialized }
}

/**
 * Whether a loaded (Option-B) document is stamped at least the emit floor
 * ({@link atLeastEmitVersion}) on load, as emit stamps it: some component
 * carries a surviving reference, materializes a non-authored entry, or keeps
 * an `operators` block (esm-spec §9.6.4 rule 8, §9.6.5). Mirrors the Julia
 * reference's typed load path (`_materialize_components!` `bump`).
 */
export function needsEmitVersionFloor(
  loaded: Record<string, unknown>,
  authored: Record<string, string[]>,
): boolean {
  const received = receivedTransformRefs(loaded)
  for (const compKind of COMP_KINDS) {
    const comps = loaded[compKind]
    if (!isObject(comps)) continue
    for (const [cname, comp] of Object.entries(comps)) {
      if (!isObject(comp)) continue
      const here = received.get(cname) ?? []
      received.delete(cname)
      const { block, referenced, materialized } = materializeComponentBlock(
        comp,
        authored[`${compKind}.${cname}`] ?? [],
        here,
      )
      if (referenced || materialized || Object.keys(block).length > 0) return true
    }
  }
  return false
}

/**
 * Build the reference-preserving, self-contained emitted document (esm-spec
 * §9.6.4 rule 5, §7.5) from an already Option-B-loaded document `loaded` and
 * the authored-name map from the pristine source. For every component builds
 * its emitted `operators` block — authored entries first in authored
 * order (a `match` rule only once rule 3 materialized it match-less), then the materialized transitive closure of its surviving
 * references (match-less), lexicographically sorted — drops consumed
 * `operator_imports`, and version-stamps `esm: 2.4.0` when any
 * surviving reference or materialized entry remains (§9.6.4 rule 8). Mutates
 * and returns `loaded`. Mirrors the Julia reference `emit_document` tail.
 */
export function buildEmittedDocument(
  loaded: Record<string, unknown>,
  authored: Record<string, string[]>,
): Record<string, unknown> {
  const root = loaded
  let bump = false
  const received = receivedTransformRefs(root)

  for (const compKind of COMP_KINDS) {
    const comps = root[compKind]
    if (!isObject(comps)) continue
    for (const [cname, comp] of Object.entries(comps)) {
      if (!isObject(comp)) continue
      const key = `${compKind}.${cname}`
      const here = received.get(cname) ?? []
      received.delete(cname)
      const {
        block: emitBlock,
        referenced,
        materialized,
      } = materializeComponentBlock(comp, authored[key] ?? [], here)
      if (referenced || materialized) bump = true

      if (Object.keys(emitBlock).length === 0) {
        delete comp.operators
      } else {
        comp.operators = emitBlock
        bump = true
      }
      delete comp.operator_imports
    }
  }

  delete root.operator_imports
  if (bump) root.esm = atLeastEmitVersion(root.esm)
  return root
}

/**
 * The `esm` marker for an emitted document carrying surviving references or
 * an `operators` block.
 *
 * esm-spec §9.6.4 states a FLOOR, so this raises the marker to 2.4.0 and
 * never lowers it. Assigning
 * `'0.9.0'` outright, as this did, stamped a 1.0.0 document back down to a
 * version the 1.0.0 loader rejects outright as an unsupported major, making
 * `emitDocument` produce a document that could not be loaded again.
 */
export function atLeastEmitVersion(current: unknown): string {
  // esm 2.4.0: an emitted document writes the names `operators` and
  // `apply_operator` (esm-spec §9.6.5, §9.6.12), so it declares 2.4.0 or
  // later; this floor subsumes the 0.9.0 floor of the Option-B machinery
  // (§9.6.4 rule 8).
  const EMIT_FLOOR = '2.4.0'
  if (typeof current !== 'string') return EMIT_FLOOR
  const parse = (v: string): [number, number, number] | null => {
    const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(v)
    return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null
  }
  const a = parse(current)
  const b = parse(EMIT_FLOOR)!
  if (!a) return EMIT_FLOOR
  for (let i = 0; i < 3; i++) {
    if (a[i] > b[i]) return current
    if (a[i] < b[i]) return EMIT_FLOOR
  }
  return current
}

// --- Canonical byte writer (2-space indent, keys sorted except the ordered
//     `operators` block) — the cross-binding byte-identity surface. ---

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
      emitWrite(out, (x as Record<string, unknown>)[k], indent + 1, k === 'operators')
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
 * EXCEPT the entries of an `operators` object, which preserve their
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
 * Rewrite the `name` of every `apply_operator` reference in `node`
 * according to `rename` (old name → new name), in lockstep with a registry
 * rename. Mirrors the Julia reference `_rename_apply_refs`.
 */
export function renameApplyRefs(node: Json, rename: Record<string, string>): Json {
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

/**
 * The set of template names the flatten-time registry merge MUST owner-path
 * rename (esm-spec §9.6.4 rule 7 / §10.7). `byname` maps a template name to its
 * per-component occurrences.
 *
 * A name collides directly when its occurrences are not all deep-equal. The set
 * is then closed under the reference DAG: **if a declaration references a
 * colliding name, that declaration collides too**, in every component that
 * carries it. That propagation is what makes the rename total.
 *
 * Without it the common multi-model shape silently breaks. Two components
 * import one rule library; the leaf stencil folds differently per component (a
 * rebind, a metaparameter, or the §10.7 component-scoping of its free
 * variables) and renames to `A.leaf` / `B.leaf`, while the intermediate wrapper
 * that REFERENCES the leaf is byte-identical and would dedup under its bare
 * name. That single deduped body then carries a reference the registry no
 * longer holds, and expansion fails with
 * `operator_unknown_definition` naming a template no component
 * ever mentioned. Renaming the wrapper per owner lets each copy's nested
 * reference be rewritten to its own owner's leaf.
 *
 * A consequence worth relying on: a name left OUT of the returned set never
 * references a name inside it, so deduped entries need no reference rewriting.
 *
 * Mirrors the Julia reference `_registry_collision_names`.
 */
export function registryCollisionNames(
  byname: Map<string, { path: string; decl: unknown }[]>,
): Set<string> {
  const collide = new Set<string>()
  const refs = new Map<string, Set<string>>()
  for (const [name, occ] of byname) {
    if (!occ.every((o) => deepEqual(occ[0]!.decl, o.decl))) collide.add(name)
    const seen = new Set<string>()
    for (const { decl } of occ) for (const r of collectApplyNames(decl, [])) seen.add(r)
    refs.set(name, seen)
  }
  // Close under the reference edges (monotone; ≤ byname.size rounds).
  let changed = true
  while (changed) {
    changed = false
    for (const name of byname.keys()) {
      if (collide.has(name)) continue
      for (const r of refs.get(name)!) {
        if (collide.has(r)) {
          collide.add(name)
          changed = true
          break
        }
      }
    }
  }
  return collide
}

/** Is `decl` a match-less (referenceable, esm-spec §9.6.2) template entry? */
function isMatchless(decl: unknown): boolean {
  return !(isObject(decl) && decl.match !== undefined && decl.match !== null)
}

/** The match-less entries of a raw `operators` block, in block order. */
function matchlessEntries(block: unknown): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  if (!isObject(block)) return out
  for (const [n, d] of Object.entries(block)) if (isMatchless(d)) out[n] = d
  return out
}

/** Result of {@link mergeFlatRegistry}. */
export interface FlatRegistryMerge {
  /** The merged registry, in document order. */
  merged: Record<string, unknown>
  /** Per owner path, the names it renamed (old name => merged name). */
  rename: Map<string, Record<string, string>>
}

/**
 * Merge per-owner template registries into one (esm-spec §9.6.4 rule 7,
 * §10.7; esm-libraries-spec §4.7.5 step 4). `blocks` is the ordered list of
 * (owner path, block) pairs; the owner path names the entries a collision
 * renames (`<path>.<name>`).
 *
 *  - A name whose occurrences are all deep-equal is kept once, under its bare
 *    name ({@link registryCollisionNames} decides which names collide, closed
 *    under the reference DAG).
 *  - A colliding name keeps ONE entry per distinct definition: its occurrences
 *    are settled callees first, each with its nested references renamed to its
 *    own owner's entries; an occurrence deep-equal to an earlier group's entry
 *    joins that group, otherwise it opens a new group named
 *    `<its owner path>.<name>`. So a definition two owners carry identically
 *    (a leaf mounted twice) stays one definition, named after its first owner.
 *
 * Output order: names in first-occurrence (document) order; a colliding name
 * emits its groups in order. The caller applies each owner's `rename` to that
 * owner's reference sites. Mirrors the Julia reference `_merge_flat_registry`.
 */
export function mergeFlatRegistry(
  blocks: readonly { path: string; block: Record<string, unknown> }[],
): FlatRegistryMerge {
  const byname = new Map<string, { path: string; decl: unknown }[]>()
  for (const { path, block } of blocks) {
    for (const [name, decl] of Object.entries(block)) {
      let occ = byname.get(name)
      if (occ === undefined) byname.set(name, (occ = []))
      occ.push({ path, decl })
    }
  }
  const collide = registryCollisionNames(byname)
  const rename = new Map<string, Record<string, string>>()
  const groups = new Map<string, { name: string; decl: unknown }[]>()
  const settle = (name: string): void => {
    if (groups.has(name)) return
    const gs: { name: string; decl: unknown }[] = []
    for (const { path, decl } of byname.get(name)!) {
      const rn: Record<string, string> = {}
      let renamed = false
      for (const c of collectApplyNames(decl, [])) {
        if (!collide.has(c) || c === name) continue
        settle(c)
        const target = rename.get(path)?.[c]
        if (target !== undefined) {
          rn[c] = target
          renamed = true
        }
      }
      const d = renamed ? renameApplyRefs(decl, rn) : decl
      let g = gs.find((x) => deepEqual(x.decl, d))
      if (g === undefined) {
        g = { name: `${path}.${name}`, decl: d }
        gs.push(g)
      }
      let perOwner = rename.get(path)
      if (perOwner === undefined) rename.set(path, (perOwner = {}))
      perOwner[name] = g.name
    }
    groups.set(name, gs)
  }
  for (const name of byname.keys()) if (collide.has(name)) settle(name)
  const merged: Record<string, unknown> = {}
  for (const [name, occ] of byname) {
    if (collide.has(name)) {
      for (const g of groups.get(name)!) merged[g.name] = g.decl
    } else {
      merged[name] = occ[0]!.decl
    }
  }
  return { merged, rename }
}

/**
 * Merge into the component `comp`'s `operators` block the template
 * definitions its subsystems carry (esm-spec §9.6.4 rule 1): a model mounted as
 * a subsystem (esm-spec §4.7) keeps its references and brings its match-less
 * definitions on its own block, and an authored inline subsystem may declare
 * one too. Every subsystem below `comp` carrying a block joins `comp`'s by
 * {@link mergeFlatRegistry}; the walk stops at such a subsystem (its own
 * subtree was merged into its block when it was lowered). Owner paths: `cname`
 * for `comp`'s own match-less entries, the subsystem path below `comp` (`Sub`,
 * `Sub.Inner`) for each block.
 *
 * Bodies are taken unchanged, in the subsystem's own names: a body's free names
 * are read in the scope of the subsystem that owns the reference, so a leaf
 * mounted twice brings one definition. Each mounted subtree's references follow
 * its own owner's renames; `comp`'s other sites (its own fields and its
 * subsystems without a block) follow `comp`'s. `comp`'s `match` rules stay
 * first in the new block; the subsystem blocks are deleted. Mutates `comp`.
 * Returns `comp`'s own rename map (old name => merged name), `null` when it
 * renamed nothing, or `undefined` when no subsystem carries a block.
 *
 * `owners`, when given, receives each merged entry `comp`'s own block did not
 * contribute, with the subsystem paths whose blocks did. Definitions are
 * component-local (esm-spec §9.6.3 constraint 4): such an entry resolves a
 * call, and counts for arity, only inside its owners' subtrees.
 *
 * Mirrors the Julia reference `_hoist_mounted_templates!`.
 */
export function hoistMountedTemplates(
  comp: Record<string, unknown>,
  cname: string,
  owners?: Map<string, Set<string>>,
): Record<string, string> | null | undefined {
  const mounts: [string, Record<string, unknown>][] = []
  collectMountedBlocks(mounts, comp, '')
  if (mounts.length === 0) return undefined
  const own = comp.operators
  // Each entry records the defined operator it defines under the key it was
  // declared with, before a collision rename (esm-spec §9.6.12 "Provenance").
  const withDefinesAll = (b: Record<string, unknown>): Record<string, unknown> => {
    const out: Record<string, unknown> = {}
    for (const [n, d] of Object.entries(b)) out[n] = withDefines(n, d)
    return out
  }
  const blocks = [{ path: cname, block: withDefinesAll(matchlessEntries(own)) }]
  for (const [path, sub] of mounts) {
    blocks.push({ path, block: withDefinesAll(matchlessEntries(sub.operators)) })
  }
  const { merged, rename } = mergeFlatRegistry(blocks)
  for (const [path, sub] of mounts) {
    const rm = rename.get(path)
    if (rm === undefined) continue
    for (const k of Object.keys(sub)) {
      if (k === 'operators') continue
      sub[k] = renameApplyRefs(sub[k], rm)
    }
  }
  const rn = rename.get(cname)
  const block: Record<string, unknown> = {}
  if (isObject(own)) {
    for (const [n, d] of Object.entries(own)) {
      if (isMatchless(d)) continue
      block[n] = rn === undefined ? d : renameApplyRefs(d, rn)
    }
  }
  Object.assign(block, merged)
  if (rn !== undefined) {
    for (const k of Object.keys(comp)) {
      if (k === 'operators' || k === 'subsystems') continue
      comp[k] = renameApplyRefs(comp[k], rn)
    }
    renameOutsideMounts(comp, rn)
  }
  for (const [, sub] of mounts) delete sub.operators
  comp.operators = block
  if (owners !== undefined) {
    const own = new Set(Object.keys(blocks[0]!.block).map((n) => rn?.[n] ?? n))
    for (const { path, block: b } of blocks.slice(1)) {
      for (const n of Object.keys(b)) {
        const m = rename.get(path)?.[n] ?? n
        if (own.has(m)) continue
        let ps = owners.get(m)
        if (ps === undefined) owners.set(m, (ps = new Set()))
        ps.add(path)
      }
    }
  }
  return rn ?? null
}

/**
 * The subsystems below `node` that carry an `operators` block, with
 * their paths. The walk stops at such a subsystem: its subtree is its block's.
 */
function collectMountedBlocks(
  out: [string, Record<string, unknown>][],
  node: Record<string, unknown>,
  prefix: string,
): void {
  const subs = node.subsystems
  if (!isObject(subs)) return
  for (const [k, sub] of Object.entries(subs)) {
    if (!isObject(sub)) continue
    const path = prefix === '' ? k : `${prefix}.${k}`
    if (isObject(sub.operators)) out.push([path, sub])
    else collectMountedBlocks(out, sub, path)
  }
}

/** `node`'s subsystems with the references outside every block-carrying subtree renamed by `rn`. */
function renameOutsideMounts(node: Record<string, unknown>, rn: Record<string, string>): void {
  const subs = node.subsystems
  if (!isObject(subs)) return
  for (const sub of Object.values(subs)) {
    if (!isObject(sub) || isObject(sub.operators)) continue
    for (const k of Object.keys(sub)) {
      if (k === 'subsystems') continue
      sub[k] = renameApplyRefs(sub[k], rn)
    }
    renameOutsideMounts(sub, rn)
  }
}

/** Result of {@link flattenTemplateRegistries}: the rewritten document + merged registry. */
export interface FlattenedTemplateRegistries {
  root: Record<string, unknown>
  merged: Record<string, unknown>
}

/**
 * The flatten-time template-registry merge (esm-spec §9.6.4 rule 7, §10.7;
 * esm-libraries-spec §4.7.5 step 4). Given an Option-B loaded multi-component
 * document `loaded`, merge every component's match-less `operators`
 * registry into a single document-scoped merged registry by
 * {@link mergeFlatRegistry}:
 *
 *  - **Deep-equal dedup at first occurrence** — two components importing one
 *    stencil produce identical folded bodies, kept once under the bare name.
 *  - **Non-deep-equal same-name collision** — the entries are renamed
 *    `<ComponentPath>.<name>`, one entry per distinct definition (named after
 *    its first owner), and every owner's `apply_operator`
 *    references are rewritten in lockstep.
 *  - **Collisions propagate along the reference DAG** — a declaration that
 *    references a colliding name collides too (see
 *    {@link registryCollisionNames}), so a byte-identical wrapper over a
 *    per-component leaf is renamed per owner rather than deduped into one body
 *    whose nested reference no longer resolves.
 *
 * The merged registry is in document order: components as the file declares
 * them, entries as their block declares them. Returns the rewritten document
 * `root` (component reference sites updated, per-component blocks removed) and
 * the merged registry (the FlattenedSystem's first-class registry field).
 * `match` rules are not merged (only match-less templates are referenceable).
 * Mirrors the Julia reference `flatten_template_registries`.
 */
export function flattenTemplateRegistries(loaded: object): FlattenedTemplateRegistries {
  const root = deepClone(loaded) as Record<string, unknown>
  const comps: { path: string; comp: Record<string, unknown> }[] = []
  const blocks: { path: string; block: Record<string, unknown> }[] = []
  for (const compKind of COMP_KINDS) {
    const cs = root[compKind]
    if (!isObject(cs)) continue
    for (const [cname, comp] of Object.entries(cs)) {
      if (!isObject(comp)) continue
      comps.push({ path: cname, comp })
      const tpl = comp.operators
      if (!isObject(tpl)) continue
      blocks.push({ path: cname, block: matchlessEntries(tpl) })
    }
  }
  const { merged, rename } = mergeFlatRegistry(blocks)

  // Rewrite each component's reference sites in lockstep with its renames, and
  // drop its now-merged block from the flattened form.
  for (const { path, comp } of comps) {
    const rn = rename.get(path)
    if (rn) {
      for (const k of Object.keys(comp)) {
        if (k === 'operators') continue
        comp[k] = renameApplyRefs(comp[k], rn)
      }
    }
    if ('operators' in comp) delete comp.operators
  }

  return { root, merged }
}
