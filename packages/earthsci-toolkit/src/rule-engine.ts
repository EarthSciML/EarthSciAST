/**
 * Rule engine per discretization RFC §5.2.
 *
 * Pattern-match rewriting over the ESM expression AST with typed pattern
 * variables, guards, non-linear matching (via canonical equality), and a
 * top-down fixed-point loop with per-pass sealing of rewritten subtrees.
 *
 * This module mirrors the Julia and Rust reference implementations
 * (`packages/EarthSciSerialization.jl/src/rule_engine.jl`,
 * `packages/earthsci-toolkit-rs/src/rule_engine.rs`) so that all three
 * bindings emit byte-identical canonical output on the Step 1
 * conformance fixtures.
 *
 * The MVP supports only the inline `replacement` form; `use:<scheme>`
 * (RFC §7.2.1) is deferred to Step 1b.
 *
 * See `docs/rfcs/discretization.md` §5.2 for the normative rules.
 */

import { canonicalJson } from './canonicalize.js'
import type { Expr } from './expression.js'
import { intLit, isIntLit, isNumericLiteral, numericValue, type NumericLiteral } from './numeric-literal.js'

// ---------------------------------------------------------------------------
// Error type
// ---------------------------------------------------------------------------

/**
 * Error raised by the rule engine. `code` carries one of the RFC stable
 * error codes (`E_RULES_NOT_CONVERGED`, `E_UNREWRITTEN_PDE_OP`,
 * `E_PATTERN_VAR_UNBOUND`, `E_PATTERN_VAR_TYPE`, `E_UNKNOWN_GUARD`,
 * `E_RULE_PARSE`, `E_RULE_REPLACEMENT_MISSING`, `E_SCHEME_MISMATCH`).
 */
export class RuleEngineError extends Error {
  readonly code: string
  constructor(code: string, message?: string) {
    super(message ?? code)
    this.code = code
    this.name = 'RuleEngineError'
  }
}

export const E_RULES_NOT_CONVERGED = 'E_RULES_NOT_CONVERGED'
export const E_UNREWRITTEN_PDE_OP = 'E_UNREWRITTEN_PDE_OP'
export const E_PATTERN_VAR_UNBOUND = 'E_PATTERN_VAR_UNBOUND'
export const E_PATTERN_VAR_TYPE = 'E_PATTERN_VAR_TYPE'
export const E_UNKNOWN_GUARD = 'E_UNKNOWN_GUARD'
export const E_RULE_PARSE = 'E_RULE_PARSE'
export const E_RULE_REPLACEMENT_MISSING = 'E_RULE_REPLACEMENT_MISSING'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type ExprNode = { op: string; args: Expr[]; wrt?: string; dim?: string } & Record<
  string,
  unknown
>

export interface Guard {
  name: string
  params: Record<string, unknown>
}

/**
 * Object-form `region` scope per RFC §5.2.7. Discriminated by `kind`.
 */
export type RuleRegionScope =
  | { kind: 'boundary'; side: string }
  | { kind: 'mask_field'; field: string }
  | { kind: 'index_range'; axis: string; lo: number; hi: number }

/**
 * Closed set of policy kinds accepted in the string-form `boundary_policy`
 * or as `BoundaryPolicySpec.kind` (RFC §5.2.8 / §7).
 *
 * `ghosted`/`neumann_zero`/`extrapolate` are v0.3.x backwards-compatible
 * aliases for `prescribed`/`reflecting`/`one_sided_extrapolation`.
 */
export type BoundaryPolicyKind =
  | 'periodic'
  | 'reflecting'
  | 'one_sided_extrapolation'
  | 'prescribed'
  | 'ghosted'
  | 'neumann_zero'
  | 'extrapolate'

/**
 * String-form `boundary_policy` values (uniform across all axes).
 */
export type BoundaryPolicyString = BoundaryPolicyKind

const BOUNDARY_POLICY_KIND_VALUES: readonly BoundaryPolicyKind[] = [
  'periodic',
  'reflecting',
  'one_sided_extrapolation',
  'prescribed',
  'ghosted',
  'neumann_zero',
  'extrapolate',
]

const BOUNDARY_POLICY_STRING_VALUES: readonly BoundaryPolicyString[] = [
  'periodic',
  'reflecting',
  'one_sided_extrapolation',
  'prescribed',
  'ghosted',
  'neumann_zero',
  'extrapolate',
]

/**
 * Per-axis boundary policy entry (RFC §5.2.8 / §7). `kind` selects the
 * policy; sibling fields carry kind-specific parameters.
 */
export interface BoundaryPolicySpec {
  kind: BoundaryPolicyKind
  /** one_sided_extrapolation / extrapolate: order 0..3 (default linear=1). */
  degree?: number
  /** Free-form authorial note. */
  description?: string
}

/**
 * Authorial form of a rule's `boundary_policy` (RFC §5.2.8 / §7). Either:
 * (1) a closed-set string applied uniformly to every axis the rule's
 * stencil reaches, or (2) an object with `by_axis` declaring per-axis
 * policies (required for axis-heterogeneous rules).
 */
export type BoundaryPolicy =
  | BoundaryPolicyString
  | { by_axis: Record<string, BoundaryPolicySpec>; description?: string }

/**
 * Authorial form of a rule's `ghost_width` (RFC §5.2.8 / §7). Either a
 * non-negative integer applied uniformly to every axis, or an object with
 * `by_axis` declaring per-axis non-negative integers.
 */
export type GhostWidth =
  | number
  | { by_axis: Record<string, number>; description?: string }

/**
 * Rule binding declaration (RFC §5.2.8). Declares the cadence at which
 * the host runtime updates a non-pattern-variable, non-canonical-index
 * symbol that the rule's replacement may reference.
 */
export interface RuleBinding {
  kind: 'static' | 'per_step' | 'per_cell'
  default?: Expr
  description?: string
}

const BINDING_KIND_VALUES: readonly RuleBinding['kind'][] = [
  'static',
  'per_step',
  'per_cell',
]

export interface Rule {
  name: string
  pattern: Expr
  where: Guard[]
  replacement: Expr
  /**
   * Legacy advisory tag (string) per v0.2. No runtime effect. Mutually
   * exclusive with `regionScope` at parse time — JSON shape picks which.
   */
  region?: string
  /**
   * Object-form spatial scope per RFC §5.2.7. When present the rule
   * applies only at query points inside the scope. The TypeScript
   * binding evaluates `regionScope.index_range` and `regionScope.boundary`
   * (and the where-expression predicate) per query point; the
   * `mask_field` variant parses and round-trips but does not evaluate
   * (conservative fall-through, equivalent to W_UNEVAL_SCOPE).
   */
  regionScope?: RuleRegionScope
  /**
   * Per-query-point boolean predicate AST per RFC §5.2.7. Mutually
   * exclusive with the guard-list `where` at author level; structurally
   * discriminated by JSON shape at parse time.
   */
  whereExpr?: Expr
  /**
   * Behavior at domain edges (RFC §5.2.8 / §7). Either a closed-set
   * string (uniform across axes) or a `{by_axis}` object (per-axis).
   * Omission == 'periodic'. Stored verbatim; the rule engine does not
   * branch on this field.
   */
  boundaryPolicy?: BoundaryPolicy
  /**
   * Per-axis ghost-cell padding the rule's stencil reaches (RFC §5.2.8
   * / §7). Either a non-negative integer (uniform) or a `{by_axis}`
   * object. Omission == 0. Stored verbatim.
   */
  ghostWidth?: GhostWidth
  /**
   * Map from bare identifier name to a {@link RuleBinding} declaration
   * (RFC §5.2.8). Documents the time-varying / static symbols the
   * replacement AST may reference. Loaders preserve this across roundtrips.
   */
  bindings?: Record<string, RuleBinding>
}

export interface GridMeta {
  spatial_dims?: string[]
  periodic_dims?: string[]
  nonuniform_dims?: string[]
  /**
   * Optional per-dim [lo, hi] integer bounds, used by RFC §5.2.7
   * region.boundary scope evaluation. Absence is equivalent to "scope
   * disabled" (conservative fall-through).
   */
  dim_bounds?: Record<string, [number, number]>
  /**
   * Optional per-dim cell counts, consumed by bind_side_spacing and
   * bind_side_dim_size guards.
   */
  dim_sizes?: Record<string, number>
}

export interface VariableMeta {
  grid?: string
  location?: string
  shape?: string[]
}

export interface RuleContext {
  grids: Record<string, GridMeta>
  variables: Record<string, VariableMeta>
  /**
   * Per-query-point index bindings (canonical names i, j, k, ...) used
   * to evaluate RFC §5.2.7 region / where-expression scopes. Empty for
   * ordinary tree rewriting; scope-bearing rules then fall through.
   */
  query_point?: Record<string, number>
  /**
   * Grid the `query_point` refers to (used to resolve
   * region.boundary.side against `dim_bounds`).
   */
  grid_name?: string
  /**
   * Named loader-backed mask tables. Each entry is a list of query-point
   * coordinates at which the mask is truthy. Used by region.mask_field
   * scope evaluation (RFC §5.2.7).
   */
  mask_fields?: Record<string, Array<Record<string, number>>>
}

export function emptyContext(): RuleContext {
  return { grids: {}, variables: {} }
}

export const DEFAULT_MAX_PASSES = 32

// ---------------------------------------------------------------------------
// Expression classification
// ---------------------------------------------------------------------------

function isOpNode(e: Expr): e is ExprNode {
  return (
    typeof e === 'object' &&
    e !== null &&
    !isNumericLiteral(e) &&
    typeof (e as { op?: unknown }).op === 'string' &&
    Array.isArray((e as { args?: unknown }).args)
  )
}

function isPvarString(s: unknown): s is string {
  return typeof s === 'string' && s.length >= 2 && s.startsWith('$')
}

function numericEqual(a: Expr, b: Expr): boolean {
  const an = isNumericLiteral(a) ? a : null
  const bn = isNumericLiteral(b) ? b : null
  if (an && bn) return an.kind === bn.kind && Object.is(an.value, bn.value)
  if (typeof a === 'number' && typeof b === 'number') return Object.is(a, b)
  if (an && typeof b === 'number') return an.kind === 'float' && Object.is(an.value, b)
  if (bn && typeof a === 'number') return bn.kind === 'float' && Object.is(bn.value, a)
  return false
}

// ---------------------------------------------------------------------------
// Pattern matching (§5.2.1 – §5.2.4)
// ---------------------------------------------------------------------------

type Bindings = Map<string, Expr>

/**
 * Attempt to match `pattern` against `expr`. On success, returns a
 * substitution map from each pattern-variable name (including the
 * leading `$`) to the bound expression. Sibling-field (name-class)
 * pvars bind to bare-name strings.
 */
export function matchPattern(pattern: Expr, expr: Expr): Bindings | null {
  return matchInner(pattern, expr, new Map())
}

function matchInner(pat: Expr, expr: Expr, b: Bindings): Bindings | null {
  if (typeof pat === 'string' && isPvarString(pat)) {
    return unify(pat, expr, b)
  }
  if (typeof pat === 'string' && typeof expr === 'string') {
    return pat === expr ? b : null
  }
  if (typeof pat === 'number' || isNumericLiteral(pat)) {
    return numericEqual(pat, expr) ? b : null
  }
  if (typeof expr === 'number' || isNumericLiteral(expr)) {
    return null
  }
  if (isOpNode(pat) && isOpNode(expr)) {
    return matchOp(pat, expr, b)
  }
  return null
}

function matchOp(pat: ExprNode, expr: ExprNode, b: Bindings): Bindings | null {
  if (pat.op !== expr.op) return null
  if (pat.args.length !== expr.args.length) return null
  let cur: Bindings | null = matchSiblingName(pat.wrt, expr.wrt, b)
  if (cur === null) return null
  cur = matchSiblingName(pat.dim, expr.dim, cur)
  if (cur === null) return null
  cur = matchSiblingName(
    (pat as Record<string, unknown>).fn as string | undefined,
    (expr as Record<string, unknown>).fn as string | undefined,
    cur,
  )
  if (cur === null) return null
  for (let i = 0; i < pat.args.length; i++) {
    cur = matchInner(pat.args[i]!, expr.args[i]!, cur)
    if (cur === null) return null
  }
  return cur
}

function matchSiblingName(
  pat: string | undefined,
  val: string | undefined,
  b: Bindings,
): Bindings | null {
  if (pat === undefined && val === undefined) return b
  if (pat === undefined || val === undefined) return null
  if (isPvarString(pat)) return unify(pat, val, b)
  return pat === val ? b : null
}

function unify(pvar: string, candidate: Expr, b: Bindings): Bindings | null {
  const prev = b.get(pvar)
  if (prev === undefined) {
    const nb = new Map(b)
    nb.set(pvar, candidate)
    return nb
  }
  // Non-linear (§5.2.2): existing binding must match canonically.
  let prevJson: string
  let candJson: string
  try {
    prevJson = canonicalJson(prev as Expr)
    candJson = canonicalJson(candidate)
  } catch {
    return null
  }
  return prevJson === candJson ? b : null
}

// ---------------------------------------------------------------------------
// Apply bindings (build replacement AST)
// ---------------------------------------------------------------------------

/**
 * Substitute pattern variables in `template` with their bound values.
 * Throws `RuleEngineError(E_PATTERN_VAR_UNBOUND)` if the template
 * references a pattern variable not in `bindings`.
 */
export function applyBindings(template: Expr, b: Bindings): Expr {
  if (typeof template === 'string' && isPvarString(template)) {
    const v = b.get(template)
    if (v === undefined) {
      throw new RuleEngineError(
        E_PATTERN_VAR_UNBOUND,
        `pattern variable ${template} is not bound`,
      )
    }
    return v
  }
  if (isOpNode(template)) {
    const newArgs = template.args.map((a) => applyBindings(a, b))
    const newWrt = applyNameField(template.wrt, b)
    const newDim = applyNameField(template.dim, b)
    const out: ExprNode = { ...(template as ExprNode), args: newArgs }
    if (newWrt === undefined) delete (out as Record<string, unknown>).wrt
    else out.wrt = newWrt
    if (newDim === undefined) delete (out as Record<string, unknown>).dim
    else out.dim = newDim
    return out
  }
  return template
}

function applyNameField(field: string | undefined, b: Bindings): string | undefined {
  if (field === undefined) return undefined
  if (!isPvarString(field)) return field
  const v = b.get(field)
  if (v === undefined) {
    throw new RuleEngineError(
      E_PATTERN_VAR_UNBOUND,
      `pattern variable ${field} is not bound`,
    )
  }
  if (typeof v !== 'string') {
    throw new RuleEngineError(
      E_PATTERN_VAR_TYPE,
      `pattern variable ${field} used in name-class field must bind a bare name`,
    )
  }
  return v
}

// ---------------------------------------------------------------------------
// Guards (§5.2.4 closed set)
// ---------------------------------------------------------------------------

/**
 * Evaluate `guards` left-to-right, threading bindings. A guard whose
 * pvar-valued `grid` field is unbound at entry binds it to the
 * variable's actual grid (§9.2.1). Returns extended bindings on
 * success, `null` on miss. Throws on unknown guard names.
 */
export function checkGuards(
  guards: Guard[],
  bindings: Bindings,
  ctx: RuleContext,
): Bindings | null {
  let b: Bindings = bindings
  for (const g of guards) {
    const next = checkGuard(g, b, ctx)
    if (next === null) return null
    b = next
  }
  return b
}

export function checkGuard(g: Guard, b: Bindings, ctx: RuleContext): Bindings | null {
  switch (g.name) {
    case 'var_has_grid':
      return guardVarHasGrid(g, b, ctx)
    case 'dim_is_spatial_dim_of':
      return guardDim(g, b, ctx, 'spatial_dims')
    case 'dim_is_periodic':
      return guardDim(g, b, ctx, 'periodic_dims')
    case 'dim_is_nonuniform':
      return guardDim(g, b, ctx, 'nonuniform_dims')
    case 'var_location_is':
      return guardVarLocationIs(g, b, ctx)
    case 'var_shape_rank':
      return guardVarShapeRank(g, b, ctx)
    case 'bind_side_axis':
      return guardBindSideAxis(g, b)
    case 'bind_side_spacing':
      return guardBindSideSpacing(g, b, ctx)
    case 'bind_side_dim_size':
      return guardBindSideDimSize(g, b, ctx)
    default:
      throw new RuleEngineError(
        E_UNKNOWN_GUARD,
        `unknown guard: ${g.name} (§5.2.4 closed set)`,
      )
  }
}

function paramStr(g: Guard, field: string): string | undefined {
  const v = g.params[field]
  return typeof v === 'string' ? v : undefined
}

function resolveName(b: Bindings, key: string): string | undefined {
  const v = b.get(key)
  return typeof v === 'string' ? v : undefined
}

/**
 * Resolve a guard field that may be a literal string or a pvar
 * reference. Returns `{value, unboundPvar}`.
 */
function resolveOrMark(
  g: Guard,
  b: Bindings,
  field: string,
): { value?: string; unboundPvar?: string } {
  const raw = paramStr(g, field)
  if (raw === undefined) return {}
  if (isPvarString(raw)) {
    const v = b.get(raw)
    if (v === undefined) return { unboundPvar: raw }
    if (typeof v === 'string') return { value: v }
    return {}
  }
  return { value: raw }
}

function bindPvarName(b: Bindings, pvar: string, name: string): Bindings {
  const nb = new Map(b)
  nb.set(pvar, name)
  return nb
}

function guardVarHasGrid(g: Guard, b: Bindings, ctx: RuleContext): Bindings | null {
  const pvar = paramStr(g, 'pvar')
  if (pvar === undefined) return null
  const varName = resolveName(b, pvar)
  if (varName === undefined) return null
  const meta = ctx.variables[varName]
  if (!meta || meta.grid === undefined) return null
  const actual = meta.grid
  const { value, unboundPvar } = resolveOrMark(g, b, 'grid')
  if (unboundPvar !== undefined) return bindPvarName(b, unboundPvar, actual)
  if (value !== undefined && value === actual) return b
  return null
}

function dimFromPvarOrLiteral(g: Guard, b: Bindings): string | undefined {
  const pvar = paramStr(g, 'pvar')
  if (pvar === undefined) return undefined
  if (isPvarString(pvar)) return resolveName(b, pvar)
  return pvar
}

function guardDim(
  g: Guard,
  b: Bindings,
  ctx: RuleContext,
  field: 'spatial_dims' | 'periodic_dims' | 'nonuniform_dims',
): Bindings | null {
  const dimName = dimFromPvarOrLiteral(g, b)
  if (dimName === undefined) return null
  const { value: grid } = resolveOrMark(g, b, 'grid')
  if (grid === undefined) return null
  const meta = ctx.grids[grid]
  if (!meta) return null
  const list = meta[field]
  if (!list || !list.includes(dimName)) return null
  return b
}

function guardVarLocationIs(g: Guard, b: Bindings, ctx: RuleContext): Bindings | null {
  const pvar = paramStr(g, 'pvar')
  if (pvar === undefined) return null
  const varName = resolveName(b, pvar)
  if (varName === undefined) return null
  const target = paramStr(g, 'location')
  if (target === undefined) return null
  const meta = ctx.variables[varName]
  if (!meta) return null
  return meta.location === target ? b : null
}

function guardVarShapeRank(g: Guard, b: Bindings, ctx: RuleContext): Bindings | null {
  const pvar = paramStr(g, 'pvar')
  if (pvar === undefined) return null
  const varName = resolveName(b, pvar)
  if (varName === undefined) return null
  const rank = g.params.rank
  if (typeof rank !== 'number' || !Number.isInteger(rank)) return null
  const meta = ctx.variables[varName]
  if (!meta || !meta.shape) return null
  return meta.shape.length === rank ? b : null
}

const SIDE_TO_AXIS: Record<string, string> = {
  xmin: 'x', xmax: 'x', west: 'x', east: 'x',
  ymin: 'y', ymax: 'y', south: 'y', north: 'y',
  zmin: 'z', zmax: 'z', bottom: 'z', top: 'z',
}

const SIDE_TO_AXIS_IDX: Record<string, number> = {
  xmin: 1, xmax: 1, west: 1, east: 1,
  ymin: 2, ymax: 2, south: 2, north: 2,
  zmin: 3, zmax: 3, bottom: 3, top: 3,
}

function resolveSideOrLiteral(g: Guard, b: Bindings, param: string): string | undefined {
  const raw = paramStr(g, param)
  if (raw === undefined) return undefined
  if (isPvarString(raw)) return resolveName(b, raw)
  return raw
}

function guardBindSideAxis(g: Guard, b: Bindings): Bindings | null {
  const pvar = paramStr(g, 'pvar')
  if (pvar === undefined) return null
  const sideName = resolveSideOrLiteral(g, b, 'side')
  if (sideName === undefined) return null
  const axis = SIDE_TO_AXIS[sideName]
  if (axis === undefined) return null
  return bindPvarName(b, pvar, axis)
}

function guardBindSideSpacing(g: Guard, b: Bindings, ctx: RuleContext): Bindings | null {
  const pvar = paramStr(g, 'pvar')
  if (pvar === undefined) return null
  const sideName = resolveSideOrLiteral(g, b, 'side')
  if (sideName === undefined) return null
  const gridRaw = paramStr(g, 'grid')
  if (gridRaw === undefined) return null
  const gridName = isPvarString(gridRaw) ? resolveName(b, gridRaw) : gridRaw
  if (gridName === undefined) return null
  const gridMeta = ctx.grids[gridName]
  if (!gridMeta) return null
  const axisIdx = SIDE_TO_AXIS_IDX[sideName]
  if (axisIdx === undefined) return null
  const spatialDims = gridMeta.spatial_dims ?? []
  if (axisIdx > spatialDims.length) return null
  const dimName = spatialDims[axisIdx - 1]!
  const dimSizes = gridMeta.dim_sizes ?? {}
  const N = dimSizes[dimName]
  if (N === undefined) return null
  const nb = new Map(b)
  nb.set(pvar, 1.0 / N)
  return nb
}

function guardBindSideDimSize(g: Guard, b: Bindings, ctx: RuleContext): Bindings | null {
  const pvar = paramStr(g, 'pvar')
  if (pvar === undefined) return null
  const sideName = resolveSideOrLiteral(g, b, 'side')
  if (sideName === undefined) return null
  const gridRaw = paramStr(g, 'grid')
  if (gridRaw === undefined) return null
  const gridName = isPvarString(gridRaw) ? resolveName(b, gridRaw) : gridRaw
  if (gridName === undefined) return null
  const gridMeta = ctx.grids[gridName]
  if (!gridMeta) return null
  const axisIdx = SIDE_TO_AXIS_IDX[sideName]
  if (axisIdx === undefined) return null
  const spatialDims = gridMeta.spatial_dims ?? []
  if (axisIdx > spatialDims.length) return null
  const dimName = spatialDims[axisIdx - 1]!
  const dimSizes = gridMeta.dim_sizes ?? {}
  const N = dimSizes[dimName]
  if (N === undefined) return null
  const nb = new Map(b)
  nb.set(pvar, intLit(Math.round(N)))
  return nb
}

// ---------------------------------------------------------------------------
// Rewriter (§5.2.5)
// ---------------------------------------------------------------------------

/**
 * Run the rule engine on `expr` per RFC §5.2.5. Top-down walker, per-
 * pass sealing of rewritten subtrees, fixed-point loop bounded by
 * `maxPasses`. Throws `RuleEngineError(E_RULES_NOT_CONVERGED)` on
 * non-convergence.
 */
export function rewrite(
  expr: Expr,
  rules: Rule[],
  ctx: RuleContext = emptyContext(),
  maxPasses: number = DEFAULT_MAX_PASSES,
): Expr {
  let current = expr
  for (let pass = 0; pass < maxPasses; pass++) {
    const res = rewritePass(current, rules, ctx)
    if (!res.changed) return current
    current = res.expr
  }
  throw new RuleEngineError(
    E_RULES_NOT_CONVERGED,
    `rule engine did not converge within ${maxPasses} passes`,
  )
}

interface PassResult {
  expr: Expr
  changed: boolean
}

function rewritePass(expr: Expr, rules: Rule[], ctx: RuleContext): PassResult {
  const fired = tryFireAt(expr, rules, ctx)
  if (fired !== null) return { expr: fired, changed: true } // sealed
  if (isOpNode(expr)) {
    const newArgs: Expr[] = []
    let changed = false
    for (const a of expr.args) {
      const r = rewritePass(a, rules, ctx)
      newArgs.push(r.expr)
      if (r.changed) changed = true
    }
    if (changed) {
      return { expr: { ...(expr as ExprNode), args: newArgs }, changed: true }
    }
  }
  return { expr, changed: false }
}

function tryFireAt(expr: Expr, rules: Rule[], ctx: RuleContext): Expr | null {
  for (const rule of rules) {
    const m = matchPattern(rule.pattern, expr)
    if (m === null) continue
    const m2 = checkGuards(rule.where, m, ctx)
    if (m2 === null) continue
    if (!checkScope(rule, m2, ctx)) continue
    return applyBindings(rule.replacement, m2)
  }
  return null
}

// ---------------------------------------------------------------------------
// Scope evaluation — region object + where expression (RFC §5.2.7)
// ---------------------------------------------------------------------------

/**
 * Evaluate a rule's per-query-point scope. Returns true when the rule
 * should fire at the current query point, false otherwise (conservative
 * fall-through). A legacy string `region` and a missing `whereExpr`
 * pass unconditionally, preserving v0.2 semantics.
 */
function checkScope(rule: Rule, bindings: Bindings, ctx: RuleContext): boolean {
  if (rule.regionScope !== undefined && !evalRegion(rule.regionScope, ctx)) {
    return false
  }
  if (rule.whereExpr !== undefined && !evalWhereExpr(rule.whereExpr, bindings, ctx)) {
    return false
  }
  return true
}

const CANONICAL_INDEX_NAMES = ['i', 'j', 'k', 'l', 'm']

function evalRegion(region: RuleRegionScope, ctx: RuleContext): boolean {
  switch (region.kind) {
    case 'index_range': {
      const v = ctx.query_point?.[region.axis]
      if (v === undefined) return false
      return region.lo <= v && v <= region.hi
    }
    case 'boundary':
      return evalBoundary(region.side, ctx)
    case 'mask_field':
      return evalMaskField(region, ctx)
  }
}

function evalMaskField(region: RuleRegionScope & { kind: 'mask_field' }, ctx: RuleContext): boolean {
  if (!ctx.query_point || !ctx.mask_fields) return false
  const mask = ctx.mask_fields[region.field]
  if (!mask) return false
  const qp = ctx.query_point
  return mask.some(entry => {
    const entryKeys = Object.keys(entry)
    return entryKeys.length === Object.keys(qp).length &&
      entryKeys.every(k => qp[k] === entry[k])
  })
}

function evalBoundary(side: string, ctx: RuleContext): boolean {
  if (ctx.grid_name === undefined) return false
  const meta = ctx.grids[ctx.grid_name]
  if (meta === undefined) return false
  const sides: Record<string, [string, boolean]> = {
    xmin: ['x', false], west: ['x', false],
    xmax: ['x', true],  east: ['x', true],
    ymin: ['y', false], south: ['y', false],
    ymax: ['y', true],  north: ['y', true],
    zmin: ['z', false], bottom: ['z', false],
    zmax: ['z', true],  top: ['z', true],
  }
  const entry = sides[side]
  if (entry === undefined) return false
  const [dim, whichHi] = entry
  const bounds = meta.dim_bounds?.[dim]
  if (bounds === undefined) return false
  const idxPos = (meta.spatial_dims ?? []).indexOf(dim)
  const idxName = CANONICAL_INDEX_NAMES[idxPos]
  if (idxName === undefined) return false
  const v = ctx.query_point?.[idxName]
  if (v === undefined) return false
  const target = whichHi ? bounds[1] : bounds[0]
  return v === target
}

function evalWhereExpr(expr: Expr, bindings: Bindings, ctx: RuleContext): boolean {
  if (ctx.query_point === undefined || Object.keys(ctx.query_point).length === 0) {
    return false
  }
  const v = evalScalar(expr, bindings, ctx)
  if (v === undefined) return false
  return scalarTruthy(v)
}

type ScalarValue =
  | { kind: 'bool'; value: boolean }
  | { kind: 'int'; value: number }
  | { kind: 'float'; value: number }

function scalarToFloat(s: ScalarValue): number {
  if (s.kind === 'bool') return s.value ? 1 : 0
  return s.value
}

function scalarTruthy(s: ScalarValue): boolean {
  if (s.kind === 'bool') return s.value
  return s.value !== 0
}

function evalScalar(e: Expr, b: Bindings, ctx: RuleContext): ScalarValue | undefined {
  if (typeof e === 'boolean') return { kind: 'bool', value: e }
  if (typeof e === 'number') {
    return Number.isInteger(e)
      ? { kind: 'int', value: e }
      : { kind: 'float', value: e }
  }
  if (isNumericLiteral(e)) {
    const v = numericValue(e)
    if (v === undefined) return undefined
    return e.kind === 'int'
      ? { kind: 'int', value: v }
      : { kind: 'float', value: v }
  }
  if (typeof e === 'string') {
    if (isPvarString(e)) {
      const bound = b.get(e)
      if (bound === undefined) return undefined
      return evalScalar(bound, b, ctx)
    }
    const v = ctx.query_point?.[e]
    if (v === undefined) return undefined
    return { kind: 'int', value: v }
  }
  if (isOpNode(e)) {
    return evalOp(e, b, ctx)
  }
  return undefined
}

function evalOp(node: ExprNode, b: Bindings, ctx: RuleContext): ScalarValue | undefined {
  const args: ScalarValue[] = []
  for (const a of node.args) {
    const sv = evalScalar(a, b, ctx)
    if (sv === undefined) return undefined
    args.push(sv)
  }
  switch (node.op) {
    case '==':
    case '!=':
    case '<':
    case '<=':
    case '>':
    case '>=': {
      const a0 = args[0]
      const a1 = args[1]
      if (args.length !== 2 || a0 === undefined || a1 === undefined) return undefined
      const l = scalarToFloat(a0)
      const r = scalarToFloat(a1)
      const cmp =
        node.op === '==' ? l === r :
        node.op === '!=' ? l !== r :
        node.op === '<'  ? l <   r :
        node.op === '<=' ? l <=  r :
        node.op === '>'  ? l >   r :
                           l >=  r
      return { kind: 'bool', value: cmp }
    }
    case '+': {
      if (allInt(args)) {
        return { kind: 'int', value: args.reduce((s, a) => s + a.value, 0) }
      }
      return { kind: 'float', value: args.reduce((s, a) => s + scalarToFloat(a), 0) }
    }
    case '-': {
      if (args.length === 1) {
        const a = args[0]
        if (a === undefined || a.kind === 'bool') return undefined
        return { kind: a.kind, value: -a.value }
      }
      const a0 = args[0]
      const a1 = args[1]
      if (args.length !== 2 || a0 === undefined || a1 === undefined) return undefined
      if (a0.kind === 'int' && a1.kind === 'int') {
        return { kind: 'int', value: a0.value - a1.value }
      }
      return { kind: 'float', value: scalarToFloat(a0) - scalarToFloat(a1) }
    }
    case '*': {
      if (allInt(args)) {
        return { kind: 'int', value: args.reduce((p, a) => p * a.value, 1) }
      }
      return { kind: 'float', value: args.reduce((p, a) => p * scalarToFloat(a), 1) }
    }
    case 'and':
      return { kind: 'bool', value: args.every(scalarTruthy) }
    case 'or':
      return { kind: 'bool', value: args.some(scalarTruthy) }
    case 'not': {
      const a = args[0]
      if (args.length !== 1 || a === undefined) return undefined
      return { kind: 'bool', value: !scalarTruthy(a) }
    }
    default:
      return undefined
  }
}

function allInt(args: ScalarValue[]): args is Array<{ kind: 'int'; value: number }> {
  return args.every((a) => a.kind === 'int')
}

// ---------------------------------------------------------------------------
// JSON parsing (rules and expressions)
// ---------------------------------------------------------------------------

/**
 * Parse a `rules` section (already-parsed JSON value — produced by
 * `losslessJsonParse` or `JSON.parse`) into an ordered list. Accepts
 * either the JSON-object-keyed-by-name form or the array form
 * (RFC §5.2.5).
 */
export function parseRules(value: unknown): Rule[] {
  if (Array.isArray(value)) {
    return value.map((v) => parseRuleArrayEntry(v))
  }
  if (typeof value === 'object' && value !== null && !isNumericLiteral(value)) {
    const out: Rule[] = []
    for (const [name, v] of Object.entries(value as Record<string, unknown>)) {
      out.push(parseRuleNamed(name, v))
    }
    return out
  }
  throw new RuleEngineError(E_RULE_PARSE, '`rules` must be an object or array')
}

function parseRuleArrayEntry(v: unknown): Rule {
  if (typeof v !== 'object' || v === null || isNumericLiteral(v)) {
    throw new RuleEngineError(E_RULE_PARSE, 'array-form rule must be an object')
  }
  const obj = v as Record<string, unknown>
  const name = obj.name
  if (typeof name !== 'string') {
    throw new RuleEngineError(E_RULE_PARSE, 'array-form rule missing `name`')
  }
  return parseRuleNamed(name, v)
}

function parseRuleNamed(name: string, v: unknown): Rule {
  if (typeof v !== 'object' || v === null || isNumericLiteral(v)) {
    throw new RuleEngineError(E_RULE_PARSE, `rule \`${name}\` must be an object`)
  }
  const obj = v as Record<string, unknown>
  if (!('pattern' in obj)) {
    throw new RuleEngineError(E_RULE_PARSE, `rule \`${name}\` missing \`pattern\``)
  }
  if (!('replacement' in obj)) {
    throw new RuleEngineError(
      E_RULE_REPLACEMENT_MISSING,
      `rule \`${name}\`: MVP supports only the \`replacement\` form; \`use:\` rules are deferred`,
    )
  }
  const pattern = parseExpr(obj.pattern)
  const replacement = parseExpr(obj.replacement)
  let where: Guard[] = []
  let whereExpr: Expr | undefined
  if ('where' in obj && obj.where !== undefined) {
    const w = obj.where
    if (Array.isArray(w)) {
      where = w.map(parseGuard)
    } else if (typeof w === 'object' && w !== null) {
      const wObj = w as Record<string, unknown>
      if (typeof wObj.op !== 'string') {
        throw new RuleEngineError(
          E_RULE_PARSE,
          `rule \`${name}\`: \`where\` object must be an expression node with an \`op\` field`,
        )
      }
      whereExpr = parseExpr(w)
    } else {
      throw new RuleEngineError(
        E_RULE_PARSE,
        `rule \`${name}\`: \`where\` must be an array of guards or an expression object`,
      )
    }
  }
  let region: string | undefined
  let regionScope: RuleRegionScope | undefined
  if ('region' in obj && obj.region !== undefined) {
    const r = obj.region
    if (typeof r === 'string') {
      region = r
    } else if (typeof r === 'object' && r !== null) {
      regionScope = parseRegionScope(name, r as Record<string, unknown>)
    } else {
      throw new RuleEngineError(
        E_RULE_PARSE,
        `rule \`${name}\`: \`region\` must be a string (legacy) or object (scope)`,
      )
    }
  }
  let boundaryPolicy: BoundaryPolicy | undefined
  if ('boundary_policy' in obj && obj.boundary_policy !== undefined) {
    boundaryPolicy = parseBoundaryPolicy(name, obj.boundary_policy)
  }
  let ghostWidth: GhostWidth | undefined
  if ('ghost_width' in obj && obj.ghost_width !== undefined) {
    ghostWidth = parseGhostWidth(name, obj.ghost_width)
  }
  let bindings: Record<string, RuleBinding> | undefined
  if ('bindings' in obj && obj.bindings !== undefined) {
    const bRaw = obj.bindings
    if (typeof bRaw !== 'object' || bRaw === null || Array.isArray(bRaw)) {
      throw new RuleEngineError(
        E_RULE_PARSE,
        `rule \`${name}\`: \`bindings\` must be an object`,
      )
    }
    bindings = {}
    for (const [bname, bval] of Object.entries(bRaw as Record<string, unknown>)) {
      bindings[bname] = parseRuleBinding(name, bname, bval)
    }
  }
  return {
    name,
    pattern,
    where,
    replacement,
    region,
    regionScope,
    whereExpr,
    boundaryPolicy,
    ghostWidth,
    bindings,
  }
}

function parseBoundaryPolicy(name: string, raw: unknown): BoundaryPolicy {
  if (typeof raw === 'string') {
    if (!(BOUNDARY_POLICY_STRING_VALUES as readonly string[]).includes(raw)) {
      throw new RuleEngineError(
        E_RULE_PARSE,
        `rule \`${name}\`: unknown boundary_policy \`${raw}\` (closed set: ${BOUNDARY_POLICY_STRING_VALUES.join(', ')})`,
      )
    }
    return raw as BoundaryPolicyString
  }
  if (typeof raw === 'object' && raw !== null && !Array.isArray(raw)) {
    const o = raw as Record<string, unknown>
    const byAxisRaw = o.by_axis
    if (byAxisRaw === undefined) {
      throw new RuleEngineError(
        E_RULE_PARSE,
        `rule \`${name}\`: \`boundary_policy\` object must have a \`by_axis\` field`,
      )
    }
    if (typeof byAxisRaw !== 'object' || byAxisRaw === null || Array.isArray(byAxisRaw)) {
      throw new RuleEngineError(
        E_RULE_PARSE,
        `rule \`${name}\`: \`boundary_policy.by_axis\` must be an object`,
      )
    }
    const byAxis: Record<string, BoundaryPolicySpec> = {}
    for (const [axis, spec] of Object.entries(byAxisRaw as Record<string, unknown>)) {
      byAxis[axis] = parseBoundaryPolicySpec(name, axis, spec)
    }
    const out: { by_axis: Record<string, BoundaryPolicySpec>; description?: string } = {
      by_axis: byAxis,
    }
    if (typeof o.description === 'string') {
      out.description = o.description
    }
    return out
  }
  throw new RuleEngineError(
    E_RULE_PARSE,
    `rule \`${name}\`: \`boundary_policy\` must be a string or an object with a \`by_axis\` field`,
  )
}

function parseBoundaryPolicySpec(
  ruleName: string,
  axis: string,
  raw: unknown,
): BoundaryPolicySpec {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
    throw new RuleEngineError(
      E_RULE_PARSE,
      `rule \`${ruleName}\`: boundary_policy.by_axis.${axis} must be an object`,
    )
  }
  const o = raw as Record<string, unknown>
  const kind = o.kind
  if (typeof kind !== 'string') {
    throw new RuleEngineError(
      E_RULE_PARSE,
      `rule \`${ruleName}\`: boundary_policy.by_axis.${axis} missing required string \`kind\``,
    )
  }
  if (!(BOUNDARY_POLICY_KIND_VALUES as readonly string[]).includes(kind)) {
    throw new RuleEngineError(
      E_RULE_PARSE,
      `rule \`${ruleName}\`: boundary_policy.by_axis.${axis}: unknown kind \`${kind}\` (closed set: ${BOUNDARY_POLICY_KIND_VALUES.join(', ')})`,
    )
  }
  const spec: BoundaryPolicySpec = { kind: kind as BoundaryPolicyKind }
  if (o.degree !== undefined) {
    const d = asIntStrict(o.degree)
    if (d === undefined) {
      throw new RuleEngineError(
        E_RULE_PARSE,
        `rule \`${ruleName}\`: boundary_policy.by_axis.${axis}.degree must be an integer`,
      )
    }
    if (d < 0 || d > 3) {
      throw new RuleEngineError(
        E_RULE_PARSE,
        `rule \`${ruleName}\`: boundary_policy.by_axis.${axis}.degree must be between 0 and 3, got ${d}`,
      )
    }
    spec.degree = d
  }
  if (o.description !== undefined) {
    if (typeof o.description !== 'string') {
      throw new RuleEngineError(
        E_RULE_PARSE,
        `rule \`${ruleName}\`: boundary_policy.by_axis.${axis}.description must be a string`,
      )
    }
    spec.description = o.description
  }
  return spec
}

// Coerce a JSON-decoded numeric value to an integer. Accepts plain
// numbers and lossless NumericLiteral wrappers (the rule-engine
// conformance test loader emits the latter to preserve int-vs-float
// fidelity).
function asIntStrict(raw: unknown): number | undefined {
  if (typeof raw === 'number' && Number.isInteger(raw)) return raw
  if (isIntLit(raw)) return raw.value
  return undefined
}

function parseGhostWidth(name: string, raw: unknown): GhostWidth {
  const asInt = asIntStrict(raw)
  if (asInt !== undefined) {
    if (asInt < 0) {
      throw new RuleEngineError(
        E_RULE_PARSE,
        `rule \`${name}\`: \`ghost_width\` must be non-negative, got ${asInt}`,
      )
    }
    return asInt
  }
  if (typeof raw === 'object' && raw !== null && !Array.isArray(raw) && !isNumericLiteral(raw)) {
    const o = raw as Record<string, unknown>
    const byAxisRaw = o.by_axis
    if (byAxisRaw === undefined) {
      throw new RuleEngineError(
        E_RULE_PARSE,
        `rule \`${name}\`: \`ghost_width\` object must have a \`by_axis\` field`,
      )
    }
    if (
      typeof byAxisRaw !== 'object' ||
      byAxisRaw === null ||
      Array.isArray(byAxisRaw) ||
      isNumericLiteral(byAxisRaw)
    ) {
      throw new RuleEngineError(
        E_RULE_PARSE,
        `rule \`${name}\`: \`ghost_width.by_axis\` must be an object`,
      )
    }
    const byAxis: Record<string, number> = {}
    for (const [axis, w] of Object.entries(byAxisRaw as Record<string, unknown>)) {
      const wInt = asIntStrict(w)
      if (wInt === undefined) {
        throw new RuleEngineError(
          E_RULE_PARSE,
          `rule \`${name}\`: ghost_width.by_axis.${axis} must be an integer`,
        )
      }
      if (wInt < 0) {
        throw new RuleEngineError(
          E_RULE_PARSE,
          `rule \`${name}\`: ghost_width.by_axis.${axis} must be non-negative, got ${wInt}`,
        )
      }
      byAxis[axis] = wInt
    }
    const out: { by_axis: Record<string, number>; description?: string } = {
      by_axis: byAxis,
    }
    if (typeof o.description === 'string') {
      out.description = o.description
    }
    return out
  }
  throw new RuleEngineError(
    E_RULE_PARSE,
    `rule \`${name}\`: \`ghost_width\` must be a non-negative integer or an object with a \`by_axis\` field`,
  )
}

function parseRuleBinding(
  ruleName: string,
  bindingName: string,
  v: unknown,
): RuleBinding {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) {
    throw new RuleEngineError(
      E_RULE_PARSE,
      `rule \`${ruleName}\`: bindings.${bindingName} must be an object`,
    )
  }
  const obj = v as Record<string, unknown>
  const kind = obj.kind
  if (typeof kind !== 'string') {
    throw new RuleEngineError(
      E_RULE_PARSE,
      `rule \`${ruleName}\`: bindings.${bindingName} missing required string \`kind\``,
    )
  }
  if (!(BINDING_KIND_VALUES as readonly string[]).includes(kind)) {
    throw new RuleEngineError(
      E_RULE_PARSE,
      `rule \`${ruleName}\`: bindings.${bindingName}: unknown kind \`${kind}\` (closed set: ${BINDING_KIND_VALUES.join(', ')})`,
    )
  }
  const out: RuleBinding = { kind: kind as RuleBinding['kind'] }
  if ('default' in obj && obj.default !== undefined) {
    out.default = parseExpr(obj.default)
  }
  if ('description' in obj && obj.description !== undefined) {
    if (typeof obj.description !== 'string') {
      throw new RuleEngineError(
        E_RULE_PARSE,
        `rule \`${ruleName}\`: bindings.${bindingName}.description must be a string`,
      )
    }
    out.description = obj.description
  }
  return out
}

function parseRegionScope(
  ruleName: string,
  obj: Record<string, unknown>,
): RuleRegionScope {
  const kind = obj.kind
  if (typeof kind !== 'string') {
    throw new RuleEngineError(
      E_RULE_PARSE,
      `rule \`${ruleName}\`: region object must carry a string \`kind\` field`,
    )
  }
  const missing = (f: string) =>
    new RuleEngineError(
      E_RULE_PARSE,
      `rule \`${ruleName}\`: region.${kind} requires \`${f}\``,
    )
  const str = (f: string): string => {
    const v = obj[f]
    if (typeof v !== 'string') throw missing(f)
    return v
  }
  const int = (f: string): number => {
    const v = obj[f]
    if (typeof v === 'number' && Number.isInteger(v)) return v
    if (isIntLit(v)) {
      const n = numericValue(v)
      if (n !== undefined && Number.isInteger(n)) return n
    }
    throw missing(f)
  }
  switch (kind) {
    case 'boundary':
      return { kind, side: str('side') }
    case 'mask_field':
      return { kind, field: str('field') }
    case 'index_range':
      return { kind, axis: str('axis'), lo: int('lo'), hi: int('hi') }
    default:
      throw new RuleEngineError(
        E_RULE_PARSE,
        `rule \`${ruleName}\`: unknown region.kind \`${kind}\` (closed set: boundary, mask_field, index_range)`,
      )
  }
}

function parseGuard(v: unknown): Guard {
  if (typeof v !== 'object' || v === null || isNumericLiteral(v)) {
    throw new RuleEngineError(E_RULE_PARSE, 'guard must be an object')
  }
  const obj = v as Record<string, unknown>
  const gname = obj.guard
  if (typeof gname !== 'string') {
    throw new RuleEngineError(E_RULE_PARSE, 'guard object missing `guard` field')
  }
  const params: Record<string, unknown> = {}
  for (const [k, val] of Object.entries(obj)) {
    if (k === 'guard') continue
    params[k] = unwrapNumeric(val)
  }
  return { name: gname, params }
}

/**
 * Unwrap NumericLiteral leaves produced by `losslessJsonParse` to their
 * plain number for use in guard params (rank, etc.).
 */
function unwrapNumeric(v: unknown): unknown {
  if (isNumericLiteral(v)) return (v as NumericLiteral).value
  return v
}

/**
 * Parse a JSON value (already parsed — produced by `losslessJsonParse`
 * or `JSON.parse`) into an [`Expr`], preserving int-vs-float per
 * RFC §5.4 when the caller used `losslessJsonParse`.
 */
export function parseExpr(v: unknown): Expr {
  if (typeof v === 'number') return v
  if (isNumericLiteral(v)) return v
  if (typeof v === 'string') return v
  if (typeof v === 'object' && v !== null) {
    const obj = v as Record<string, unknown>
    const op = obj.op
    if (typeof op !== 'string') {
      throw new RuleEngineError(E_RULE_PARSE, 'operator node missing `op`')
    }
    const rawArgs = obj.args
    const args: Expr[] = Array.isArray(rawArgs) ? rawArgs.map(parseExpr) : []
    const node: ExprNode = { op, args }
    if (typeof obj.wrt === 'string') node.wrt = obj.wrt
    if (typeof obj.dim === 'string') node.dim = obj.dim
    // Preserve other pass-through fields (kind, side, name, value, etc.)
    // so pattern matching and replacement can observe them.
    for (const [k, val] of Object.entries(obj)) {
      if (k === 'op' || k === 'args' || k === 'wrt' || k === 'dim') continue
      node[k] = val
    }
    return node
  }
  throw new RuleEngineError(E_RULE_PARSE, `cannot parse expression of type ${typeof v}`)
}

// ---------------------------------------------------------------------------
// Unrewritten PDE op check (§11 Step 7)
// ---------------------------------------------------------------------------

const PDE_OPS = new Set(['grad', 'div', 'laplacian', 'D', 'bc'])

/**
 * Scan `expr` for leftover PDE ops after rewriting. Throws
 * `RuleEngineError(E_UNREWRITTEN_PDE_OP)` if any are found.
 */
export function checkUnrewrittenPdeOps(expr: Expr): void {
  const op = findPdeOp(expr)
  if (op !== null) {
    throw new RuleEngineError(
      E_UNREWRITTEN_PDE_OP,
      `equation still contains PDE op '${op}' after rewrite; annotate the equation with 'passthrough: true' to opt out`,
    )
  }
}

function findPdeOp(e: Expr): string | null {
  if (!isOpNode(e)) return null
  if (PDE_OPS.has(e.op)) return e.op
  for (const a of e.args) {
    const x = findPdeOp(a)
    if (x !== null) return x
  }
  return null
}
