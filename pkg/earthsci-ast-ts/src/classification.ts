/**
 * The esm 1.0.0 classification API (esm-spec §6.3.1).
 *
 * The format declares TWO variable types, `unknown` and `parameter`. Everything
 * a solver additionally needs — which unknowns are ODE states, which are
 * observed, which are algebraic; which parameters are Brownian, discrete,
 * sampled, constant — is DERIVED from the equations and from each parameter's
 * `distribution` / `update`, never read off a declared type.
 *
 * Every binding exposes the same pure functions of a model, spelled in its own
 * idiom: snake_case in Julia, Python, Rust and Go; camelCase HERE and only
 * here. The semantics are identical; only the spelling differs.
 *
 * These functions are the ONLY sanctioned way to ask these questions. A site
 * that used to branch on `variable.type === 'state'` calls {@link isOdeState};
 * one that branched on `'observed'` calls {@link observedUnknowns}; `'brownian'`
 * and `'discrete'` call {@link brownianParameters} / {@link discreteParameters}.
 * Reading a declared type to answer a derived question is precisely what 1.0.0
 * removes.
 *
 * The cross-language oracle is `tests/conformance/classification/`.
 */

import type { Equation, Expression, ExpressionNode, Model, ModelVariable } from './types.js'
import type { ParameterUpdate, ParameterUpdateSpec } from './types.js'

/** The four derived parameter categories (esm-spec §6.3.1). */
export type ParameterClass = 'brownian' | 'discrete' | 'sampled' | 'constant'

/** The three derived unknown categories (esm-spec §6.3.1). */
export type UnknownClass = 'ode_state' | 'observed' | 'algebraic'

/** The MTK system type a model maps to. */
export type SystemKind = 'ode' | 'nonlinear' | 'sde' | 'pde'

/** Sugar spellings of a spatial differential operator (esm-spec §4.2). */
const SPATIAL_SUGAR_OPS = new Set(['grad', 'div', 'laplacian'])

function isExpressionNode(e: unknown): e is ExpressionNode {
  return typeof e === 'object' && e !== null && typeof (e as { op?: unknown }).op === 'string'
}

/** Lexicographic by UTF-8 code point, matching the conformance goldens. */
function sortedUnique(names: Iterable<string>): string[] {
  return [...new Set(names)].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))
}

function variableEntries(model: Model): [string, ModelVariable][] {
  return Object.entries(model.variables ?? {})
}

function equationsOf(model: Model): Equation[] {
  return Array.isArray(model.equations) ? model.equations : []
}

// ---------------------------------------------------------------------------
// Equation-LHS analysis
// ---------------------------------------------------------------------------

/**
 * The base variable name of an expression used as a DERIVATIVE TARGET, or
 * `undefined` when it is not one.
 *
 * A derivative LHS may be wrapped, and each wrapper credits the SAME base
 * variable as an ODE state:
 *   - `D(u)`                          → `u`
 *   - `D(u[i])`, i.e. `D(index(u,i))` → `u`
 *   - an `aggregate` whose `expr` is a `D(...)`
 */
function derivativeTarget(expr: Expression): string | undefined {
  if (!isExpressionNode(expr)) return undefined

  if (expr.op === 'D') {
    // Only a STRUCTURAL D (wrt `t`, or absent) marks a time derivative. A
    // spatial `wrt` is a rewrite-target operator, not an ODE state.
    if (expr.wrt !== undefined && expr.wrt !== 't') return undefined
    const arg = expr.args?.[0]
    return arg === undefined ? undefined : baseVariableName(arg)
  }

  // An `aggregate` over a derivative: the reduction wraps the D, so look inside.
  if (expr.op === 'aggregate') {
    const inner = (expr as { expr?: Expression }).expr
    return inner === undefined ? undefined : derivativeTarget(inner)
  }

  return undefined
}

/**
 * The base variable a (possibly indexed) expression names: `u` → `u`,
 * `index(u, i)` → `u`. Anything else is not a single named variable.
 */
function baseVariableName(expr: Expression): string | undefined {
  if (typeof expr === 'string') return expr
  if (isExpressionNode(expr) && expr.op === 'index') {
    const arg = expr.args?.[0]
    return arg === undefined ? undefined : baseVariableName(arg)
  }
  return undefined
}

/** True when any equation LHS in the model is a time derivative. */
function hasTimeDerivative(model: Model): boolean {
  return equationsOf(model).some((eq) => derivativeTarget(eq.lhs) !== undefined)
}

/**
 * True when an expression contains a SPATIAL differential operator: a `D` whose
 * `wrt` is present and is not `t`, or one of the `grad` / `div` / `laplacian`
 * sugar ops.
 */
function containsSpatialDerivative(expr: Expression): boolean {
  if (!isExpressionNode(expr)) return false

  if (expr.op === 'D' && expr.wrt !== undefined && expr.wrt !== 't') return true
  if (SPATIAL_SUGAR_OPS.has(expr.op)) return true

  for (const arg of expr.args ?? []) {
    if (containsSpatialDerivative(arg)) return true
  }
  // Sub-expression-bearing fields that are not in `args`.
  for (const key of ['expr', 'filter', 'lower', 'upper'] as const) {
    const sub = (expr as Record<string, unknown>)[key]
    if (sub !== undefined && containsSpatialDerivative(sub as Expression)) return true
  }
  return false
}

// ---------------------------------------------------------------------------
// Unknowns — these three sets PARTITION the model's unknowns
// ---------------------------------------------------------------------------

/** Names of every variable declared `unknown`, sorted. */
export function unknowns(model: Model): string[] {
  return sortedUnique(
    variableEntries(model)
      .filter(([, v]) => v.type === 'unknown')
      .map(([name]) => name),
  )
}

/** Names of every variable declared `parameter`, sorted. */
export function parameters(model: Model): string[] {
  return sortedUnique(
    variableEntries(model)
      .filter(([, v]) => v.type === 'parameter')
      .map(([name]) => name),
  )
}

/**
 * Unknowns appearing under `D(·, t)` on some equation LHS — the integrated
 * states.
 */
export function odeStates(model: Model): string[] {
  const declared = new Set(unknowns(model))
  const found: string[] = []
  for (const eq of equationsOf(model)) {
    const target = derivativeTarget(eq.lhs)
    if (target !== undefined && declared.has(target)) found.push(target)
  }
  return sortedUnique(found)
}

/** Membership test for {@link odeStates}. */
export function isOdeState(model: Model, name: string): boolean {
  return odeStates(model).includes(name)
}

/**
 * Unknowns defined by a BARE-VARIABLE LHS (`y ~ f(…)`) — eliminable,
 * materializable. An unknown that is already an ODE state is not observed.
 */
export function observedUnknowns(model: Model): string[] {
  const declared = new Set(unknowns(model))
  const states = new Set(odeStates(model))
  const found: string[] = []
  for (const eq of equationsOf(model)) {
    // A bare-variable LHS is a plain string. An EXPRESSION LHS (`H*H*SO4 ~ Ksp`)
    // is an implicit constraint, not a definition — that is what separates an
    // observed unknown from an algebraic one.
    if (typeof eq.lhs !== 'string') continue
    if (declared.has(eq.lhs) && !states.has(eq.lhs)) found.push(eq.lhs)
  }
  return sortedUnique(found)
}

/**
 * Unknowns constrained only implicitly (`H*H*SO4 ~ Ksp`) — everything left once
 * the ODE states and the observed unknowns are removed. Defining this set by
 * elimination is what makes the three sets a partition by construction.
 */
export function algebraicUnknowns(model: Model): string[] {
  const states = new Set(odeStates(model))
  const observed = new Set(observedUnknowns(model))
  return unknowns(model).filter((n) => !states.has(n) && !observed.has(n))
}

// ---------------------------------------------------------------------------
// Parameters — these four sets PARTITION the model's parameters
// ---------------------------------------------------------------------------

/** The update rules of a parameter, normalized to an array (possibly empty). */
export function updateRules(spec: ParameterUpdateSpec | undefined): ParameterUpdate[] {
  if (spec === undefined) return []
  return Array.isArray(spec) ? [...spec] : [spec]
}

/**
 * The derived class of ONE parameter. Exported because the cadence pass seeds
 * its leaves from this rather than re-deriving the categories locally
 * (CONFORMANCE_SPEC §5.7.2).
 */
export function parameterClass(variable: ModelVariable): ParameterClass {
  const rules = updateRules(variable.update)
  // Brownian iff ANY rule is `wiener`. The schema forbids `wiener` inside an
  // update array, so in practice an array always means discrete — but testing
  // every rule keeps this correct without relying on that.
  if (rules.some((r) => r.kind === 'wiener')) return 'brownian'
  if (rules.length > 0) return 'discrete'
  if (variable.distribution !== undefined) return 'sampled'
  return 'constant'
}

function parametersOfClass(model: Model, cls: ParameterClass): string[] {
  return sortedUnique(
    variableEntries(model)
      .filter(([, v]) => v.type === 'parameter' && parameterClass(v) === cls)
      .map(([name]) => name),
  )
}

/** Parameters whose `update.kind` is `wiener` — the SDE noise sources. */
export function brownianParameters(model: Model): string[] {
  return parametersOfClass(model, 'brownian')
}

/** Parameters carrying any OTHER update — piecewise-constant between refreshes. */
export function discreteParameters(model: Model): string[] {
  return parametersOfClass(model, 'discrete')
}

/** Parameters with a `distribution` and no `update` — drawn once at setup. */
export function sampledParameters(model: Model): string[] {
  return parametersOfClass(model, 'sampled')
}

/** Parameters with neither a `distribution` nor an `update` — plain constants. */
export function constantParameters(model: Model): string[] {
  return parametersOfClass(model, 'constant')
}

// ---------------------------------------------------------------------------
// System kind
// ---------------------------------------------------------------------------

/**
 * The system kind DERIVED from the equations and the parameter updates.
 *
 * FIRST match wins, and the order is normative
 * (`tests/conformance/classification/manifest.json`, `system_kind_order`):
 *
 *   1. `sde`       — any Brownian parameter.
 *   2. `pde`       — any equation contains a spatial derivative.
 *   3. `nonlinear` — no time-derivative equation at all.
 *   4. `ode`       — otherwise.
 *
 * Two orderings that look equivalent are not. `pde` is tested BEFORE
 * `nonlinear`, so a steady-state PDE (`laplacian(phi) ~ f`, no time derivative)
 * is `pde`. `sde` is tested BEFORE `pde`, so a model carrying both a wiener
 * parameter and a spatial derivative is `sde` — not because it is not spatial,
 * but because there is no SPDESystem constructor to select.
 *
 * Detection is a property of the EQUATIONS and never of the `domain` block:
 * v0.8.0 removed `Domain.spatial`, so `domain` carries nothing spatial.
 */
export function systemKind(model: Model): SystemKind {
  if (brownianParameters(model).length > 0) return 'sde'

  const spatial = equationsOf(model).some(
    (eq) => containsSpatialDerivative(eq.lhs) || containsSpatialDerivative(eq.rhs),
  )
  if (spatial) return 'pde'

  if (!hasTimeDerivative(model)) return 'nonlinear'
  return 'ode'
}

/** The model's explicit `system_kind` field, or `null` when absent. */
export function declaredSystemKind(model: Model): SystemKind | null {
  return (model.system_kind as SystemKind | undefined) ?? null
}

// ---------------------------------------------------------------------------
// Whole-model classification
// ---------------------------------------------------------------------------

/** Every derived set for one model node, as the conformance goldens spell it. */
export interface ModelClassification {
  odeStates: string[]
  observedUnknowns: string[]
  algebraicUnknowns: string[]
  brownianParameters: string[]
  discreteParameters: string[]
  sampledParameters: string[]
  constantParameters: string[]
  systemKind: SystemKind
  declaredSystemKind: SystemKind | null
}

/** Classify one model node. */
export function classifyModel(model: Model): ModelClassification {
  return {
    odeStates: odeStates(model),
    observedUnknowns: observedUnknowns(model),
    algebraicUnknowns: algebraicUnknowns(model),
    brownianParameters: brownianParameters(model),
    discreteParameters: discreteParameters(model),
    sampledParameters: sampledParameters(model),
    constantParameters: constantParameters(model),
    systemKind: systemKind(model),
    declaredSystemKind: declaredSystemKind(model),
  }
}

/**
 * Classify every model node in a document, keyed by DOT-PATH from the document
 * root, so a subsystem is `Parent.Child`. Classification is per model NODE, not
 * per document: the names inside each list are LOCAL to that model and are not
 * namespaced. A binding that flattens the document first and classifies once
 * returns one merged answer instead of a scoped answer per node.
 */
export function classifyDocument(models: { [k: string]: unknown }): {
  [path: string]: ModelClassification
} {
  const out: { [path: string]: ModelClassification } = {}

  const visit = (path: string, node: unknown): void => {
    if (typeof node !== 'object' || node === null) return
    const candidate = node as Partial<Model> & { subsystems?: { [k: string]: unknown } }
    // A subsystem may be a `$ref` stub or (pre-1.0.0 documents aside) some other
    // non-model entry; only a node with variables is a model node.
    if (candidate.variables !== undefined) {
      out[path] = classifyModel(candidate as Model)
    }
    for (const [childName, child] of Object.entries(candidate.subsystems ?? {})) {
      visit(`${path}.${childName}`, child)
    }
  }

  for (const [name, model] of Object.entries(models ?? {})) {
    visit(name, model)
  }
  return out
}
