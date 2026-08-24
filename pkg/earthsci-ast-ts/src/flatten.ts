/**
 * Coupled System Flattening for the ESM format (esm-libraries-spec §4.7.5).
 *
 * Transforms a multi-system ESM file into a single unified flattened system:
 * every variable dot-namespaced by its owning component, every coupling rule
 * resolved INTO the equation set, and the registries a consumer needs
 * (`index_sets`, `function_tables`, the merged `template_registry`) carried
 * along so the flattened form is self-describing.
 *
 * ## The canonical field set (esm-libraries-spec §4.7.5 step 4, `esm: 1.0.0`)
 *
 * Step 4's field table is a CROSS-BINDING CONTRACT, not a suggestion: the
 * canonical `snake_case` names transliterate to `camelCase` here per
 * API_SPEC.md §2, and the shared corpus `tests/conformance/flatten/cases.json`
 * (generated from the Python oracle) pins every field of it, INCLUDING ORDER.
 *
 * Three rules from that section drive shapes this module would otherwise get
 * wrong, and each cost a real defect before it was written down:
 *
 *  - **The parameter subsets partition `parameters`; they are not siblings of
 *    it.** esm-spec §6.3.1 says `brownian_parameters` / `discrete_parameters` /
 *    `sampled_parameters` / `constant_parameters` *partition the parameters*, so
 *    a `wiener`-updated entry appears in BOTH {@link FlattenedSystem.parameters}
 *    and {@link FlattenedSystem.brownianParameters}. This binding used to
 *    EXCLUDE it (under the old name `brownianVariables`), which made the
 *    parameter vector's LENGTH depend on whether the model happened to be
 *    stochastic and left the four sets partitioning nothing.
 *  - **`algebraicVariables` is a SUBSET of `stateVariables`.** `stateVariables`
 *    is the SOLVED-FOR VECTOR (an implementation axis), not §6.3.1's
 *    classification of the unknowns; a DAE solves for its algebraic unknowns, so
 *    they ride in the vector.
 *  - **`fieldIcs` entries are REMOVED from `equations`.** An initial condition is
 *    a datum, not an equation of motion.
 *
 * ## Ordering is observable
 *
 * Every ordered map and list below is in DOCUMENT ORDER: components in the order
 * the file declares them (models first, then reaction systems), and within a
 * component the order it declares its variables; a coupling-merged entry keeps
 * the position of its first occurrence. A parameter vector is positional, so
 * lexicographic sorting or host-map iteration order is NON-CONFORMING. The
 * `name -> variable` maps are plain objects, whose string-key insertion order
 * JavaScript preserves.
 *
 * The Python binding (`pkg/earthsci-ast-py`) is the flatten oracle; this module
 * mirrors its semantics function for function.
 */

import type {
  AffectEquation,
  ContinuousEvent,
  CouplingEntry,
  DataSource,
  DiscreteEvent,
  Domain,
  EsmFile,
  Equation,
  Expression,
  ExpressionNode,
  Model,
  ModelVariable,
  ReactionSystem,
  SubsystemRef,
} from './types.js'
import type { Distribution, ParameterUpdateSpec } from './types.js'
import { numericValue } from './numeric-literal.js'
import { expandCouplingImports, type CouplingImportOptions } from './coupling-imports.js'
import { mapChildren } from './expression.js'
import { substitute } from './substitute.js'
import {
  algebraicUnknowns,
  brownianParameters as classifyBrownian,
  discreteParameters as classifyDiscrete,
  observedDefinitions,
  systemKind as classifySystemKind,
  updateRules,
  type SystemKind,
} from './classification.js'
import { EsmDiagnosticError } from './errors.js'
import { mergedTemplateRegistry } from './flatten-template-registry.js'

/** Options for {@link flatten}. Only needed when the file uses `coupling_import`. */
export type FlattenOptions = CouplingImportOptions

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/**
 * Base class for every error {@link flatten} raises. Mirrors Rust's
 * `FlattenError` and Python's `FlattenError` for cross-language error-name
 * parity.
 */
export class FlattenError extends EsmDiagnosticError {
  constructor(message: string, code = 'flatten_error') {
    super(code, message)
    this.name = 'FlattenError'
  }
}

/**
 * Two systems define non-additive equations for the same dependent variable —
 * the §4.7.5 over-determination check. Such a system is over-determined: one
 * contribution to `d[X]/dt` would silently shadow the other.
 */
export class ConflictingDerivativeError extends FlattenError {
  constructor(message: string) {
    super(message, 'conflicting_derivative')
    this.name = 'ConflictingDerivativeError'
  }
}

/**
 * An `identity`-transform `variable_map` bridges two variables whose declared,
 * non-empty units differ (esm-libraries-spec §4.7.6). `conversion_factor` and
 * `param_to_var` are exempt: the first declares the conversion explicitly, the
 * second does not imply unit equivalence at the mapping site.
 */
export class DomainUnitMismatchError extends FlattenError {
  constructor(message: string) {
    super(message, 'domain_unit_mismatch')
    this.name = 'DomainUnitMismatchError'
  }
}

/**
 * A variable or equation cannot be promoted onto the target grid — raised by the
 * §10.5 pointwise spatial lift when a species' operator makearrays yield no
 * full-rank interior-stencil gather.
 */
export class DimensionPromotionError extends FlattenError {
  constructor(message: string) {
    super(message, 'dimension_promotion')
    this.name = 'DimensionPromotionError'
  }
}

// ---------------------------------------------------------------------------
// Data shapes
// ---------------------------------------------------------------------------

/**
 * The DERIVED role of a flattened variable (esm-spec §6.3.1) — never a declared
 * type, which from 1.0.0 is only `unknown` or `parameter`.
 *
 * - `state` — solved for: an ODE state, an algebraic unknown, or an arrayed
 *   observed that materializes into a buffer.
 * - `observed` — an unknown a bare-variable-LHS equation defines, eliminable by
 *   inlining.
 * - `parameter` — a parameter of any cadence.
 * - `species` — a reaction-system state (a `state` that came from a species).
 */
export type FlattenedVariableRole = 'state' | 'parameter' | 'observed' | 'species'

/**
 * One variable of the flattened system, carrying the COMPLETE declared metadata
 * step 4 requires ("Full metadata, not names"): a consumer must be able to build
 * a solver problem from the flattened form alone, without re-reading the source
 * document.
 */
export interface FlattenedVariable {
  /** Dot-namespaced name, e.g. `"OU.theta"`. */
  name: string
  /** The DERIVED role — see {@link FlattenedVariableRole}. */
  type: FlattenedVariableRole
  units?: string
  /** For an unknown, its value at t=0; for a parameter, its constant value. */
  default?: number
  description?: string
  /** The namespaced prefix of the component that declared it. */
  sourceSystem?: string
  /** Ordered index-set names for an arrayed variable; absent means scalar. */
  shape?: string[]
  /** The declared cadence machinery, carried verbatim (parameters only). */
  update?: ParameterUpdateSpec
  /** The declared sampling law, carried verbatim (parameters only). */
  distribution?: Distribution
}

/**
 * An insertion-ORDERED map from namespaced name to variable. Order is part of
 * the cross-binding contract (see the module doc); JavaScript preserves the
 * insertion order of string keys that do not look like array indices, which a
 * dot-namespaced variable name never does.
 */
export type FlattenedVariableMap = Record<string, FlattenedVariable>

/**
 * A data-fed PARAMETER lowered to a flattened array input (esm-spec §8.5).
 *
 * From 1.0.0 a data source is not a component: a model consumes one by declaring
 * a parameter whose `update` is `{kind: "data", source, from: {file_variable}}`.
 * The parameter IS the loaded field and owns the units; this descriptor is what
 * lets a simulator execute the source at its cadence and bind the resulting
 * array into the RHS as a read-only input.
 */
export interface LoaderField {
  /** The namespaced parameter symbol, e.g. `"Plume.wind"`. */
  name: string
  /** The owning component's namespaced prefix, e.g. `"Plume"`. */
  owner: string
  /** The `data_sources` key the parameter's `update` names. */
  subkey: string
  /** The source-file variable the binding names. */
  var: string
  /** The resolved `data_sources` entry (carries kind / source / temporal). */
  dataSource: DataSource
  /**
   * Source-seeded cadence (CONFORMANCE_SPEC §5.7.2): a source WITH a `temporal`
   * block is time-varying (`discrete`); one without is read once (`const`).
   */
  cadence: 'const' | 'discrete'
  /** The binding's declared `unit_conversion` (§8.5), when the document has one. */
  unitConversion?: Expression
}

/**
 * A single equation of the flattened system, with dot-namespaced Expression
 * TREES.
 *
 * ### Breaking change in `esm 1.0.0`
 *
 * `lhs` / `rhs` used to be pretty-printed STRINGS produced by a flatten-local,
 * fully-parenthesizing printer. They are now the canonical Expression AST, which
 * is what every other binding carries and what the shared corpus pins (rendered
 * through the shared `toAscii`). A caller that wants text calls `toAscii` on
 * them — one renderer for the whole toolkit rather than a second, subtly
 * different one living here.
 */
export interface FlattenedEquation {
  /** Dot-namespaced LHS, e.g. `D(Atmos.O3, t)` or a bare `Atmos.total`. */
  lhs: Expression
  /** Dot-namespaced RHS, with coupling contributions merged in. */
  rhs: Expression
  /** Name of the source system this equation originated from. */
  sourceSystem: string
}

/** Metadata describing the origin of the flattened system. */
export interface FlattenMetadata {
  /** Names of all top-level source systems, in document order. */
  sourceSystems: string[]
  /** Human-readable descriptions of every coupling rule, in array order. */
  couplingRules: string[]
  /** `operator_apply` entries, recorded as opaque runtime references. */
  operatorApplies: string[]
  /** `callback` entries, recorded as opaque runtime references. */
  callbacks: string[]
}

/** A deferred `ic` equation (esm-spec §11.4.1): an initial condition, not dynamics. */
export interface FieldInitialCondition {
  /** The namespaced state the condition pins. */
  state: string
  /** The value at t=0. */
  expr: Expression
}

/**
 * A fully flattened representation of a coupled ESM system — the canonical
 * field set of esm-libraries-spec §4.7.5 step 4.
 *
 * ### Removed in `esm 1.0.0`
 *
 * `variables: Record<string, string>` (observed name -> expression string) is
 * gone. It predates the canonical shape and duplicated, in a bespoke string
 * form, information the canonical fields already carry: WHICH unknowns are
 * observed is {@link observedVariables} (with full metadata rather than a bare
 * name), and each one's DEFINING EXPRESSION is its equation in
 * {@link equations}, as an AST. The coupling-derived entries it also collected
 * are no longer a side table: a `variable_map` now performs the substitution and
 * the promotion the spec calls for, so its effect is visible in `equations` and
 * `parameters` instead. Nothing it held is lost.
 *
 * Python exposes a `variables` property with a DIFFERENT meaning (namespaced
 * name -> role label); this binding deliberately does not reuse the name for a
 * third thing.
 */
export interface FlattenedSystem {
  /**
   * Always contains `"t"`. A spatial axis appears only while an UNDISCRETIZED
   * spatial differential still names it, so a discretized (array) system stays a
   * pure ODE.
   */
  independentVariables: string[]
  /**
   * The SOLVED-FOR VECTOR: every unknown the solver advances or solves for —
   * differential unknowns, PLUS {@link algebraicVariables}, PLUS any arrayed
   * observed that materializes into a buffer. NOT esm-spec §6.3.1's `odeStates`.
   */
  stateVariables: FlattenedVariableMap
  /** ALL parameters of every cadence, minus any promoted by `variable_map`. */
  parameters: FlattenedVariableMap
  /** Unknowns DEFINED by an equation naming them on its LHS (esm-spec §6.3.1). */
  observedVariables: FlattenedVariableMap
  /**
   * Unknowns CONSTRAINED only by an expression-LHS equation. A SUBSET of
   * {@link stateVariables} — a DAE solves for them.
   */
  algebraicVariables: FlattenedVariableMap
  /**
   * Parameters whose `update.kind` is `"wiener"` — the SDE noise sources. A
   * SUBSET of {@link parameters}, not a sibling bucket (esm-spec §6.3.1).
   */
  brownianParameters: FlattenedVariableMap
  /** Parameters carrying any OTHER `update`. A SUBSET of {@link parameters}. */
  discreteParameters: FlattenedVariableMap
  /**
   * The governing equations — dynamics and constraints — coupling applied,
   * dot-namespaced. Entries classified out into {@link fieldIcs} are REMOVED.
   */
  equations: FlattenedEquation[]
  /** Continuous events, dot-namespaced. */
  continuousEvents: ContinuousEvent[]
  /** Discrete events, dot-namespaced. */
  discreteEvents: DiscreteEvent[]
  /** The file's `domain` section, unchanged, or `null`. */
  domain: Domain | null
  /** Provenance metadata. */
  metadata: FlattenMetadata
  /** Document-scoped index-set registry; required to interpret arrayed equations. */
  indexSets: Record<string, unknown>
  /** Merged function-table registry; resolves `table_lookup`. */
  functionTables: Record<string, unknown>
  /**
   * The MERGED expression-template registry (esm-spec §9.6.4 rule 7, §10.7):
   * the union of the component registries with their bodies component-scoped
   * FIRST, deep-equal same-name entries deduplicated at first occurrence, and
   * non-deep-equal collisions renamed along the reference DAG.
   */
  templateRegistry: Record<string, unknown>
  /** Deferred scoped-reference / array `ic` equations (esm-spec §11.4.1). */
  fieldIcs: FieldInitialCondition[]
  /** Provider-served loaded fields the system consumes. */
  loaderFields: LoaderField[]
  /** Post-lift grid shapes for arrayed states, e.g. `{ "Chemistry.O3": [4, 2] }`. */
  liftedShapes: Record<string, number[]>
  /**
   * The system kind DERIVED from the FLATTENED system (esm-spec §6.3.1),
   * testing `brownianParameters` FIRST — which is exactly why that bucket must
   * survive flattening.
   */
  systemKind: SystemKind
}

// ---------------------------------------------------------------------------
// Expression helpers
// ---------------------------------------------------------------------------

/**
 * The canonical array-op set (Python `esm_types.ARRAY_OPS` — the `array` and
 * `geometry` op categories). Used only to recognize an equation that may
 * legitimately define different index subsets of one state variable.
 */
const ARRAY_OPS: ReadonlySet<string> = new Set([
  'aggregate',
  'broadcast',
  'concat',
  'index',
  'intersect_polygon',
  'makearray',
  'polygon_intersection_area',
  'reshape',
  'transpose',
])

function isNode(e: unknown): e is ExpressionNode {
  return typeof e === 'object' && e !== null && typeof (e as { op?: unknown }).op === 'string'
}

function isNumberExpr(e: unknown): boolean {
  return numericValue(e as Expression) !== undefined
}

/** Pre-order walk over every node of an expression tree. */
function walkNodes(expr: Expression | undefined, visit: (node: ExpressionNode) => void): void {
  if (!isNode(expr)) return
  visit(expr)
  mapChildren(expr, (child) => {
    walkNodes(child as Expression, visit)
    return child
  })
}

/** The loop symbols an `aggregate` node binds: its `output_idx` plus its `ranges` keys. */
function binderSymbols(node: ExpressionNode): string[] {
  const out: string[] = []
  const outputIdx = (node as { output_idx?: unknown }).output_idx
  if (Array.isArray(outputIdx)) {
    for (const sym of outputIdx) if (typeof sym === 'string') out.push(sym)
  }
  const ranges = (node as { ranges?: unknown }).ranges
  if (ranges !== null && typeof ranges === 'object') out.push(...Object.keys(ranges))
  return out
}

/**
 * Prefix the plain-string references a `join` clause carries
 * (CONFORMANCE_SPEC §5.5.6).
 *
 * A `join` names its references as STRINGS rather than child expressions — an
 * `on` key column, and an `overlap` clause's `src_env` / `tgt_env` envelope
 * factors — so the expression walker never sees them. They nonetheless resolve
 * against the same registry every other reference does, which after flattening
 * is the NAMESPACED registry.
 *
 * The gate is `locals` (the component's own declared names plus its subsystem
 * keys), which is what tells a model-local buffer from a document-scoped index
 * set or a loop symbol without needing an index-set registry. `binders` are THIS
 * node's own loop symbols and win over `locals`: an index symbol shadows any
 * coincident variable name, and prefixing a shadowed symbol makes it resolve to
 * nothing.
 */
function namespaceJoin(
  join: unknown[],
  binders: ReadonlySet<string>,
  prefix: string,
  locals: ReadonlySet<string>,
): unknown[] {
  const ns = (name: unknown): unknown => {
    if (typeof name !== 'string') return name
    if (binders.has(name)) return name
    if (name.includes('.')) {
      return locals.has(name.slice(0, name.indexOf('.'))) ? `${prefix}.${name}` : name
    }
    return locals.has(name) ? `${prefix}.${name}` : name
  }

  return join.map((clause) => {
    if (clause === null || typeof clause !== 'object' || Array.isArray(clause)) return clause
    const src = clause as Record<string, unknown>
    const next: Record<string, unknown> = { ...src }
    if (Array.isArray(src.on)) {
      next.on = src.on.map((pair) => (Array.isArray(pair) ? pair.map(ns) : pair))
    }
    const ov = src.overlap
    if (ov !== null && typeof ov === 'object' && !Array.isArray(ov)) {
      const nextOv: Record<string, unknown> = { ...(ov as Record<string, unknown>) }
      for (const side of ['src_env', 'tgt_env'] as const) {
        const factors = (ov as Record<string, unknown>)[side]
        if (Array.isArray(factors)) nextOv[side] = factors.map(ns)
      }
      next.overlap = nextOv
    }
    return next
  })
}

/**
 * Recursively prefix every variable reference in `expr` with `prefix.`.
 *
 * A bare reference (no dot) is prefixed. A dotted reference is normally left
 * alone (already fully namespaced), or skipped when it appears in `leaveAlone`
 * (independent vars like `t`, and the `_var` placeholder) — EXCEPT when its head
 * segment names a subsystem mounted on the component being namespaced. Such a
 * reference is subsystem-LOCAL and must be qualified with the owner, because the
 * bare "contains a dot ⇒ leave alone" rule cannot tell it from an absolute one.
 */
function namespaceExpr(
  expr: Expression,
  prefix: string,
  leaveAlone: ReadonlySet<string>,
  subsystemKeys?: ReadonlySet<string>,
  locals?: ReadonlySet<string>,
): Expression {
  if (expr === null || expr === undefined || isNumberExpr(expr)) return expr

  if (typeof expr === 'string') {
    if (leaveAlone.has(expr)) return expr
    if (expr.includes('.')) {
      const head = expr.slice(0, expr.indexOf('.'))
      if (!leaveAlone.has(head) && subsystemKeys?.has(head) === true) return `${prefix}.${expr}`
      return expr
    }
    return `${prefix}.${expr}`
  }

  if (isNode(expr)) {
    // An `aggregate`'s index symbols are local to its body and must not be
    // namespaced. They are binder NAMES, not child expressions, so the only
    // handling needed is adding them to `leaveAlone` for the children.
    let localLeave = leaveAlone
    if (expr.op === 'aggregate') {
      const syms = binderSymbols(expr)
      if (syms.length > 0) localLeave = new Set([...leaveAlone, ...syms])
    }
    let out = mapChildren(expr, (child) =>
      namespaceExpr(child as Expression, prefix, localLeave, subsystemKeys, locals),
    )
    const join = (expr as { join?: unknown }).join
    if (locals !== undefined && Array.isArray(join) && join.length > 0) {
      // THIS node's own binders, not `localLeave` (which also holds enclosing
      // nodes'): a join column resolves against this node's own `ranges`.
      out = {
        ...out,
        join: namespaceJoin(join, new Set(binderSymbols(expr)), prefix, locals),
      } as ExpressionNode
    }
    return out
  }

  return expr
}

/**
 * The dependent variable an equation LHS names, or `undefined` when the LHS
 * cannot be identified (an algebraic constraint with a compound LHS).
 *
 * `D(v, t)` and `D(v[i], t)` both credit `v`; an `aggregate` wrapping a `D`
 * looks inside; a bare name is itself.
 */
function lhsDependentVar(lhs: Expression): string | undefined {
  if (typeof lhs === 'string') return lhs
  if (!isNode(lhs)) return undefined

  if (lhs.op === 'D' && lhs.args !== undefined && lhs.args.length > 0) {
    const inner = lhs.args[0]
    if (typeof inner === 'string') return inner
    if (isNode(inner)) {
      if (inner.op === 'D' && inner.args !== undefined && inner.args.length > 0) {
        return lhsDependentVar(inner)
      }
      if (inner.op === 'index' && inner.args !== undefined && inner.args.length > 0) {
        const head = inner.args[0]
        if (typeof head === 'string') return head
      }
    }
    return undefined
  }

  if (lhs.op === 'aggregate' && (lhs as { expr?: Expression }).expr !== undefined) {
    return lhsDependentVar((lhs as { expr: Expression }).expr)
  }
  return undefined
}

/** True when `expr` contains any array-op node. */
function hasArrayOp(expr: Expression): boolean {
  let found = false
  walkNodes(expr, (node) => {
    if (ARRAY_OPS.has(node.op)) found = true
  })
  return found
}

/**
 * Harvest the spatial dimension labels named by an UNDISCRETIZED spatial
 * differential into `into`.
 *
 * Read STRUCTURALLY from every node's `dim` axis field (esm-spec §4.9.1), NOT
 * from a list of op names: the open-tier sugar ops carry no spatial-detection
 * privilege, and only an undiscretized differential node carries `dim`. A
 * discretized system has folded its spatial axes into array dimensions and yields
 * the empty set, so it stays a pure ODE.
 */
function spatialDimsInExpr(expr: Expression, into: Set<string>): void {
  walkNodes(expr, (node) => {
    const dim = (node as { dim?: unknown }).dim
    if (typeof dim === 'string' && dim !== '') into.add(dim)
  })
}

/** Sum two expressions, normalizing the trivial `0 + x` / `x + 0` cases. */
function addExprs(left: Expression, right: Expression): Expression {
  if (numericValue(left) === 0) return right
  if (numericValue(right) === 0) return left
  return { op: '+', args: [left, right] }
}

/** Multiply two expressions, normalizing the trivial `1 *` / `0 *` cases. */
function multiplyExprs(left: Expression, right: Expression): Expression {
  if (numericValue(left) === 1) return right
  if (numericValue(right) === 1) return left
  if (numericValue(left) === 0 || numericValue(right) === 0) return 0
  return { op: '*', args: [left, right] }
}

/** True when `_var` (the operator-model placeholder, §6.4) occurs anywhere in `expr`. */
function hasVarPlaceholder(expr: Expression): boolean {
  if (typeof expr === 'string') return expr === '_var'
  if (!isNode(expr)) return false
  let found = false
  mapChildren(expr, (child) => {
    if (hasVarPlaceholder(child as Expression)) found = true
    return child
  })
  return found
}

/** True when `name` occurs as a string leaf in a variable-reference position. */
function exprReferencesVar(expr: Expression, name: string): boolean {
  if (typeof expr === 'string') return expr === name
  if (!isNode(expr)) return false
  let found = false
  mapChildren(expr, (child) => {
    if (exprReferencesVar(child as Expression, name)) found = true
    return child
  })
  return found
}

/** True when any node in `expr` carries a non-empty `join`. */
function containsJoin(expr: Expression): boolean {
  let found = false
  walkNodes(expr, (node) => {
    const join = (node as { join?: unknown }).join
    if (Array.isArray(join) && join.length > 0) found = true
  })
  return found
}

/**
 * Rename `toVar` -> `fromVar` in every plain-string `join` name — the join-side
 * companion of the `variable_map` substitution (CONFORMANCE_SPEC §5.5.6).
 *
 * {@link substitute} walks expression CHILDREN, so it cannot see an `on` key
 * column or an `overlap`'s envelope factors. A `param_to_var` /
 * `conversion_factor` map REMOVES `toVar` from the flattened parameters, so a
 * join still naming it points at a variable the system no longer declares.
 *
 * The {@link containsJoin} scan runs BEFORE the rebuild: almost no model carries
 * a join, and those must not pay a whole-tree copy on top of the substitution's.
 */
function renameJoinNames(expr: Expression, toVar: string, fromVar: string): Expression {
  if (!isNode(expr) || !containsJoin(expr)) return expr
  return renameJoinNamesIn(expr, toVar, fromVar)
}

function renameJoinNamesIn(expr: Expression, toVar: string, fromVar: string): Expression {
  if (!isNode(expr)) return expr
  const ren = (name: unknown): unknown => (name === toVar ? fromVar : name)
  const out = mapChildren(expr, (child) =>
    renameJoinNamesIn(child as Expression, toVar, fromVar),
  ) as ExpressionNode
  const join = (expr as { join?: unknown }).join
  if (!Array.isArray(join) || join.length === 0) return out
  const clauses = join.map((clause) => {
    if (clause === null || typeof clause !== 'object' || Array.isArray(clause)) return clause
    const src = clause as Record<string, unknown>
    const next: Record<string, unknown> = { ...src }
    if (Array.isArray(src.on)) {
      next.on = src.on.map((pair) => (Array.isArray(pair) ? pair.map(ren) : pair))
    }
    const ov = src.overlap
    if (ov !== null && typeof ov === 'object' && !Array.isArray(ov)) {
      const nextOv: Record<string, unknown> = { ...(ov as Record<string, unknown>) }
      for (const side of ['src_env', 'tgt_env'] as const) {
        const factors = (ov as Record<string, unknown>)[side]
        if (Array.isArray(factors)) nextOv[side] = factors.map(ren)
      }
      next.overlap = nextOv
    }
    return next
  })
  return { ...out, join: clauses } as ExpressionNode
}

// ---------------------------------------------------------------------------
// Coupling-rule descriptions
// ---------------------------------------------------------------------------

function describeTranslateTarget(target: unknown): string {
  if (typeof target === 'string') return target
  return JSON.stringify(target)
}

/**
 * The human-readable provenance string recorded in
 * {@link FlattenMetadata.couplingRules}. The spellings are the shared
 * cross-binding ones — the flatten corpus pins them.
 */
function describeCoupling(entry: CouplingEntry): string {
  const e = entry as unknown as Record<string, unknown>
  switch (entry.type) {
    case 'operator_compose': {
      const systems = (e.systems as string[]).join(' + ')
      let rule = `operator_compose(${systems})`
      const translate = e.translate as Record<string, unknown> | undefined
      if (translate !== undefined && Object.keys(translate).length > 0) {
        const pairs = Object.entries(translate).map(
          ([k, v]) => `${k}->${describeTranslateTarget(v)}`,
        )
        rule += ` [translate: ${pairs.join(', ')}]`
      }
      return rule
    }
    case 'couple':
      return `couple(${(e.systems as string[]).join(' <-> ')})`
    case 'variable_map': {
      // A non-string transform is an EXPRESSION (esm-spec §8.6/§10.4). It is
      // reported by KIND rather than by body: the oracle renders its own typed
      // node's repr there, which no other binding can reproduce, and the tree
      // itself is already visible in `equations` as the target's definition.
      const transform = e.transform
      const shown = typeof transform === 'string' ? transform : 'expression'
      let rule = `variable_map(${String(e.from)} -> ${String(e.to)}, transform=${shown})`
      if (e.factor !== undefined && e.factor !== null) rule += ` [factor=${String(e.factor)}]`
      return rule
    }
    case 'callback':
      return `callback(${String(e.callback_id)})`
    case 'event':
      return `event(${String(e.name ?? 'unnamed')}, ${String(e.event_type)})`
    default:
      // `operator_apply` is not in the 1.0.0 `CouplingEntry` union, but the
      // metadata slot for it is normative (step 4 records it as an opaque
      // runtime reference), so keep the spelling reachable.
      if ((entry as { type: string }).type === 'operator_apply') {
        return `operator_apply(${String(e.operator)})`
      }
      return `unknown(${String((entry as { type: string }).type)})`
  }
}

// ---------------------------------------------------------------------------
// Component / subsystem helpers
// ---------------------------------------------------------------------------

function isSubsystemRef(entry: unknown): entry is SubsystemRef {
  return entry !== null && typeof entry === 'object' && 'ref' in (entry as object)
}

/**
 * The child MODELS mounted on `model`. A `{ref}` stub carries no variables or
 * equations, and from 1.0.0 a data source is not a component — neither can be
 * flattened, so both are skipped.
 */
function modelSubsystems(model: Model): Record<string, Model> {
  const out: Record<string, Model> = {}
  for (const [name, sub] of Object.entries(model.subsystems ?? {})) {
    if (isSubsystemRef(sub)) continue
    if (sub === null || typeof sub !== 'object') continue
    if (!('variables' in sub)) continue
    out[name] = sub as Model
  }
  return out
}

function reactionSubsystems(rs: ReactionSystem): Record<string, ReactionSystem> {
  const out: Record<string, ReactionSystem> = {}
  for (const [name, sub] of Object.entries(rs.subsystems ?? {})) {
    if (isSubsystemRef(sub)) continue
    if (sub === null || typeof sub !== 'object') continue
    out[name] = sub as ReactionSystem
  }
  return out
}

// ---------------------------------------------------------------------------
// Coupling preflight (esm-libraries-spec §4.7.6)
// ---------------------------------------------------------------------------

function lookupModelUnits(model: Model, name: string): string | undefined {
  const v = (model.variables ?? {})[name]
  if (v !== undefined) return v.units
  const dot = name.indexOf('.')
  if (dot === -1) return undefined
  const sub = modelSubsystems(model)[name.slice(0, dot)]
  return sub === undefined ? undefined : lookupModelUnits(sub, name.slice(dot + 1))
}

function lookupReactionUnits(rs: ReactionSystem, name: string): string | undefined {
  const sp = (rs.species ?? {})[name]
  if (sp !== undefined) return sp.units
  const p = (rs.parameters ?? {})[name]
  if (p !== undefined) return p.units
  const dot = name.indexOf('.')
  if (dot === -1) return undefined
  const sub = reactionSubsystems(rs)[name.slice(0, dot)]
  return sub === undefined ? undefined : lookupReactionUnits(sub, name.slice(dot + 1))
}

function lookupVariableUnits(file: EsmFile, qualified: string): string | undefined {
  const parts = qualified.split('.')
  if (parts.length < 2) return undefined
  const root = parts[0]
  const tail = parts.slice(1).join('.')
  const model = (file.models ?? {})[root]
  if (model !== undefined && !isSubsystemRef(model)) return lookupModelUnits(model as Model, tail)
  const rs = (file.reaction_systems ?? {})[root]
  if (rs !== undefined && !isSubsystemRef(rs)) {
    return lookupReactionUnits(rs as ReactionSystem, tail)
  }
  return undefined
}

/**
 * Reject an `identity`-transform `variable_map` whose `from` / `to` carry
 * declared, non-empty, DIFFERENT units (esm-libraries-spec §4.7.6). Runs over the
 * EXPANDED coupling list, so imported edges are checked too.
 */
function checkVariableMapUnits(file: EsmFile, entries: CouplingEntry[]): void {
  for (const entry of entries) {
    if (entry.type !== 'variable_map') continue
    const e = entry as unknown as Record<string, unknown>
    if (e.transform !== 'identity') continue
    const src = lookupVariableUnits(file, String(e.from ?? ''))
    const tgt = lookupVariableUnits(file, String(e.to ?? ''))
    if (src === undefined || tgt === undefined || src === '' || tgt === '' || src === tgt) continue
    throw new DomainUnitMismatchError(
      `variable '${String(e.from)}' has units '${src}' on source and '${tgt}' on target`,
    )
  }
}

// ---------------------------------------------------------------------------
// Per-component collection
// ---------------------------------------------------------------------------

/** One component's tables, before coupling and before the components are merged. */
interface ComponentSystem {
  name: string
  stateVars: FlattenedVariableMap
  parameters: FlattenedVariableMap
  observed: FlattenedVariableMap
  equations: FlattenedEquation[]
  loaderFields: LoaderField[]
}

function newComponent(name: string): ComponentSystem {
  return { name, stateVars: {}, parameters: {}, observed: {}, equations: [], loaderFields: [] }
}

/**
 * Fold `other`'s tables into `target` — last-writer-wins for the variable maps
 * (a re-inserted key keeps its ORIGINAL position, which is what document order
 * requires), order-preserving append for equations and loader fields.
 */
function mergeComponent(target: ComponentSystem, other: ComponentSystem): void {
  Object.assign(target.stateVars, other.stateVars)
  Object.assign(target.parameters, other.parameters)
  Object.assign(target.observed, other.observed)
  target.equations.push(...other.equations)
  target.loaderFields.push(...other.loaderFields)
}

/** `_var` is a placeholder expanded by `operator_compose`; never namespace it. */
const LEAVE_ALONE: ReadonlySet<string> = new Set(['t', '_var'])

function namespaceEquations(
  equations: Equation[],
  component: ComponentSystem,
  prefix: string,
  subsystemKeys?: ReadonlySet<string>,
  locals?: ReadonlySet<string>,
): void {
  for (const eq of equations) {
    component.equations.push({
      lhs: namespaceExpr(eq.lhs, prefix, LEAVE_ALONE, subsystemKeys, locals),
      rhs: namespaceExpr(eq.rhs, prefix, LEAVE_ALONE, subsystemKeys, locals),
      sourceSystem: prefix,
    })
  }
}

/**
 * Every data-fed parameter of `model`, as a {@link LoaderField} (esm-spec §8.5).
 * Cadence follows the SOURCE, not the parameter's own declaration.
 */
function dataSourceFields(
  model: Model,
  fullPrefix: string,
  dataSources: Record<string, DataSource>,
): LoaderField[] {
  const fields: LoaderField[] = []
  for (const [varName, variable] of Object.entries(model.variables ?? {})) {
    if (variable.type !== 'parameter' || variable.update === undefined) continue
    for (const rule of updateRules(variable.update)) {
      if (rule.kind !== 'data') continue
      const binding = (rule as { from?: { file_variable: string; unit_conversion?: Expression } })
        .from
      if (binding === undefined) continue
      const sourceKey = (rule as { source: string }).source
      const source = dataSources[sourceKey]
      if (source === undefined) continue
      const field: LoaderField = {
        name: `${fullPrefix}.${varName}`,
        owner: fullPrefix,
        subkey: sourceKey,
        var: binding.file_variable,
        dataSource: source,
        cadence: (source as { temporal?: unknown }).temporal !== undefined ? 'discrete' : 'const',
      }
      if (binding.unit_conversion !== undefined) field.unitConversion = binding.unit_conversion
      fields.push(field)
    }
  }
  return fields
}

function flattenedVariableOf(
  namespaced: string,
  role: FlattenedVariableRole,
  variable: ModelVariable,
  sourceSystem: string,
): FlattenedVariable {
  const out: FlattenedVariable = { name: namespaced, type: role, sourceSystem }
  if (variable.units !== undefined) out.units = variable.units
  if (variable.default !== undefined) out.default = variable.default
  if (variable.description !== undefined) out.description = variable.description
  if (variable.shape !== undefined && variable.shape.length > 0) out.shape = [...variable.shape]
  if (variable.update !== undefined) out.update = variable.update
  if (variable.distribution !== undefined) out.distribution = variable.distribution
  return out
}

/** Collect a Model (recursively, including subsystems) into a {@link ComponentSystem}. */
function collectModel(
  model: Model,
  fullPrefix: string,
  dataSources: Record<string, DataSource>,
): ComponentSystem {
  const component = newComponent(fullPrefix)

  // The role comes from the §6.3.1 classification, NOT from a declared type.
  // `observed` is the INLINED form specifically — an unknown a BARE-variable LHS
  // defines, substituted into its consumers. Every other unknown is SOLVED FOR
  // and lands in `stateVars`: an ODE state, an algebraic unknown, and an ARRAYED
  // definition (`y[i] ~ f(i)`) alike. The arrayed one is observed by §6.3.1, but
  // it materializes into a buffer its consumers index rather than being inlined.
  const inlined = new Set(observedDefinitions(model, { bareOnly: true }).keys())

  for (const [varName, variable] of Object.entries(model.variables ?? {})) {
    const namespaced = `${fullPrefix}.${varName}`
    let role: FlattenedVariableRole
    if (variable.type === 'parameter') {
      role = 'parameter'
    } else if (variable.type !== 'unknown') {
      // Fail closed on a retired 0.x type rather than silently filing it with
      // the unknowns: `state` / `observed` / `brownian` / `discrete` are gone.
      throw new FlattenError(
        `variable '${namespaced}' declares type '${String(variable.type)}', which esm 1.0.0 ` +
          `removed; the declared types are 'unknown' and 'parameter' (esm-spec §6.3)`,
      )
    } else if (inlined.has(varName)) {
      role = 'observed'
    } else {
      role = 'state'
    }
    const flat = flattenedVariableOf(namespaced, role, variable, fullPrefix)
    if (role === 'state') component.stateVars[namespaced] = flat
    else if (role === 'parameter') component.parameters[namespaced] = flat
    else component.observed[namespaced] = flat
  }

  const subs = modelSubsystems(model)
  const subKeys = new Set(Object.keys(model.subsystems ?? {}))
  // The component's own declared names — the gate for namespacing the plain
  // string references a `join` clause carries (§5.5.6).
  const locals = new Set([...Object.keys(model.variables ?? {}), ...subKeys])

  // An observed unknown's defining relation is an ORDINARY equation with a
  // bare-variable LHS, so it travels through `equations` like any other.
  namespaceEquations(model.equations ?? [], component, fullPrefix, subKeys, locals)
  component.loaderFields.push(...dataSourceFields(model, fullPrefix, dataSources))

  for (const [subName, subModel] of Object.entries(subs)) {
    mergeComponent(component, collectModel(subModel, `${fullPrefix}.${subName}`, dataSources))
  }
  return component
}

/**
 * Lower a reaction list to `D(species, t) = Σ net_stoich · rate` equations by
 * mass action (esm-spec §7.4).
 *
 * Kept LOCAL to flatten rather than routed through `deriveODEs` because the two
 * differ in two observable ways, and the cross-binding corpus pins THIS one: a
 * species with a zero net rate gets NO equation (rather than `D(s,t) = 0`), and a
 * net stoichiometry of -1 emits `-1 * rate` (rather than a unary minus), which is
 * the form every other binding renders.
 *
 * A reservoir species (`constant: true`, §7.4) is held fixed and gets no ODE; its
 * concentration is still a mass-action factor in every other species' rate law.
 */
function lowerReactionsToEquations(rs: ReactionSystem): Equation[] {
  const speciesNames = Object.keys(rs.species ?? {})
  const constantNames = new Set(
    speciesNames.filter((n) => (rs.species ?? {})[n]?.constant === true),
  )
  const rates: Record<string, Expression> = {}
  for (const name of speciesNames) rates[name] = 0

  for (const reaction of rs.reactions ?? []) {
    // Per esm-spec §7.4 the `rate` field is the rate COEFFICIENT; the full
    // mass-action rate law is always `k · ∏ Sᵢ^nᵢ`.
    let rateExpr: Expression = reaction.rate
    for (const substrate of reaction.substrates ?? []) {
      const factor: Expression =
        substrate.stoichiometry === 1
          ? substrate.species
          : { op: '^', args: [substrate.species, substrate.stoichiometry] }
      rateExpr = multiplyExprs(rateExpr, factor)
    }

    for (const name of speciesNames) {
      let net = 0
      for (const s of reaction.substrates ?? []) if (s.species === name) net -= s.stoichiometry
      for (const p of reaction.products ?? []) if (p.species === name) net += p.stoichiometry
      if (net === 0) continue
      rates[name] = addExprs(rates[name], multiplyExprs(net, rateExpr))
    }
  }

  const equations: Equation[] = []
  for (const name of speciesNames) {
    if (constantNames.has(name)) continue
    if (numericValue(rates[name]) === 0) continue
    equations.push({ lhs: { op: 'D', args: [name], wrt: 't' }, rhs: rates[name] })
  }
  return equations
}

/** Collect a ReactionSystem (lowered to ODEs) into a {@link ComponentSystem}. */
function collectReactionSystem(rs: ReactionSystem, fullPrefix: string): ComponentSystem {
  const component = newComponent(fullPrefix)

  for (const [name, species] of Object.entries(rs.species ?? {})) {
    const namespaced = `${fullPrefix}.${name}`
    const flat: FlattenedVariable = {
      name: namespaced,
      type: species.constant === true ? 'parameter' : 'species',
      sourceSystem: fullPrefix,
    }
    if (species.units !== undefined) flat.units = species.units
    if (species.default !== undefined) flat.default = species.default
    if (species.description !== undefined) flat.description = species.description
    // A reservoir species is held fixed and emits no ODE, so it lowers to a
    // PARAMETER whose value is its declared default. It still resolves as a
    // concentration factor wherever a rate law references it.
    if (species.constant === true) component.parameters[namespaced] = flat
    else component.stateVars[namespaced] = flat
  }

  for (const [name, param] of Object.entries(rs.parameters ?? {})) {
    const namespaced = `${fullPrefix}.${name}`
    const flat: FlattenedVariable = {
      name: namespaced,
      type: 'parameter',
      sourceSystem: fullPrefix,
    }
    if (param.units !== undefined) flat.units = param.units
    if (typeof param.default === 'number') flat.default = param.default
    if (param.description !== undefined) flat.description = param.description
    component.parameters[namespaced] = flat
  }

  const locals = new Set([...Object.keys(rs.species ?? {}), ...Object.keys(rs.parameters ?? {})])

  if ((rs.reactions ?? []).length > 0) {
    namespaceEquations(lowerReactionsToEquations(rs), component, fullPrefix, undefined, locals)
  }
  namespaceEquations(rs.constraint_equations ?? [], component, fullPrefix, undefined, locals)

  for (const [subName, subRs] of Object.entries(reactionSubsystems(rs))) {
    mergeComponent(component, collectReactionSystem(subRs, `${fullPrefix}.${subName}`))
  }
  return component
}

// ---------------------------------------------------------------------------
// Coupling resolution
// ---------------------------------------------------------------------------

/** Normalize an `operator_compose` `translate` entry to `(target, factor)`. */
function buildTranslateMap(entry: CouplingEntry): Record<string, [string, number]> {
  const out: Record<string, [string, number]> = {}
  const translate = (entry as unknown as Record<string, unknown>).translate
  if (translate === null || typeof translate !== 'object') return out
  for (const [k, v] of Object.entries(translate as Record<string, unknown>)) {
    if (typeof v === 'string') {
      out[k] = [v, 1]
    } else if (v !== null && typeof v === 'object') {
      const rec = v as Record<string, unknown>
      const target = rec.to ?? rec.target ?? rec.var
      if (typeof target === 'string') {
        out[k] = [target, typeof rec.factor === 'number' ? rec.factor : 1]
      }
    }
  }
  return out
}

/**
 * Expand `_var` placeholders in B's equations against A's state variables
 * (esm-spec §4.7.1): an equation like `D(_var, t) = -u·grad(_var)` is cloned once
 * per state variable of A, with `_var` substituted for the namespaced name.
 */
function expandOperatorComposePlaceholders(
  components: Record<string, ComponentSystem>,
  entry: CouplingEntry,
): void {
  const systems = (entry as unknown as { systems?: string[] }).systems
  if (systems === undefined || systems.length < 2) return
  const a = components[systems[0]]
  const b = components[systems[1]]
  if (a === undefined || b === undefined) return

  const aStates = Object.keys(a.stateVars)
  if (aStates.length === 0) return

  const next: FlattenedEquation[] = []
  for (const eq of b.equations) {
    if (hasVarPlaceholder(eq.lhs) || hasVarPlaceholder(eq.rhs)) {
      for (const varName of aStates) {
        next.push({
          lhs: substitute(eq.lhs, { _var: varName }) as Expression,
          rhs: substitute(eq.rhs, { _var: varName }) as Expression,
          sourceSystem: eq.sourceSystem,
        })
      }
    } else {
      next.push(eq)
    }
  }
  b.equations = next
}

/**
 * Merge B's equations into A by matching dependent variables (esm-spec §4.7.1):
 * for each B equation with LHS `D(x, t)`, find A's equation with the same LHS
 * (translation-aware) and SUM their RHS. Unmatched B equations survive unchanged.
 */
function applyOperatorCompose(
  components: Record<string, ComponentSystem>,
  entry: CouplingEntry,
): void {
  const systems = (entry as unknown as { systems?: string[] }).systems
  if (systems === undefined || systems.length < 2) return
  const a = components[systems[0]]
  const b = components[systems[1]]
  if (a === undefined || b === undefined) return

  const translate = buildTranslateMap(entry)

  const aIndex: Record<string, number> = {}
  a.equations.forEach((eq, i) => {
    const dep = lhsDependentVar(eq.lhs)
    if (dep !== undefined) aIndex[dep] = i
  })

  const survivingB: FlattenedEquation[] = []
  for (const bEq of b.equations) {
    const bDep = lhsDependentVar(bEq.lhs)
    if (bDep === undefined) {
      survivingB.push(bEq)
      continue
    }

    let targetDep = bDep
    let factor = 1
    if (Object.prototype.hasOwnProperty.call(translate, bDep)) {
      const mapped = translate[bDep]
      targetDep = mapped[0]
      factor = mapped[1]
    } else {
      // Map a bare name from B back to A's equivalent.
      const short = bDep.includes('.') ? bDep.slice(bDep.indexOf('.') + 1) : bDep
      for (const ad of Object.keys(aIndex)) {
        if (ad.endsWith(`.${short}`)) {
          targetDep = ad
          break
        }
      }
    }

    if (Object.prototype.hasOwnProperty.call(aIndex, targetDep)) {
      const i = aIndex[targetDep]
      const aEq = a.equations[i]
      let rhs = substitute(bEq.rhs, { [bDep]: targetDep }) as Expression
      if (factor !== 1) rhs = { op: '*', args: [factor, rhs] }
      a.equations[i] = {
        lhs: aEq.lhs,
        rhs: addExprs(aEq.rhs, rhs),
        sourceSystem: aEq.sourceSystem,
      }
    } else {
      survivingB.push(bEq)
    }
  }
  b.equations = survivingB
}

/**
 * Resolve a `couple` connector by injecting source / sink terms: each connector
 * equation maps `from` (already a scoped reference) to `to` with one of three
 * transforms, appended to / multiplied with / replacing the target's RHS.
 */
function applyCouple(components: Record<string, ComponentSystem>, entry: CouplingEntry): void {
  const connector = (entry as unknown as { connector?: { equations?: unknown[] } }).connector
  const connectorEquations = connector?.equations
  if (connectorEquations === undefined || connectorEquations.length === 0) return

  const eqIndex: Record<string, [string, number]> = {}
  for (const [sysName, comp] of Object.entries(components)) {
    comp.equations.forEach((eq, i) => {
      const dep = lhsDependentVar(eq.lhs)
      if (dep !== undefined) eqIndex[dep] = [sysName, i]
    })
  }

  for (const raw of connectorEquations) {
    const ceq = raw as { to?: string; from?: string; transform?: string; expression?: Expression }
    const target = ceq.to
    if (target === undefined || !Object.prototype.hasOwnProperty.call(eqIndex, target)) continue
    const [sysName, i] = eqIndex[target]
    const comp = components[sysName]
    const existing = comp.equations[i]
    const expression: Expression =
      ceq.expression !== undefined ? ceq.expression : (ceq.from as Expression)

    let rhs: Expression
    if (ceq.transform === 'multiplicative') rhs = multiplyExprs(existing.rhs, expression)
    else if (ceq.transform === 'replacement') rhs = expression
    else rhs = addExprs(existing.rhs, expression)

    comp.equations[i] = { lhs: existing.lhs, rhs, sourceSystem: existing.sourceSystem }
  }
}

/**
 * Resolve a `variable_map` whose `transform` is an Expression (esm-spec
 * §10.4/§10.5).
 *
 * It promotes like `param_to_var` — the target parameter is removed — but
 * consumer references to the target are NOT substituted. Instead the target
 * becomes an OBSERVED variable named exactly `to`, whose defining equation is the
 * transform expression VERBATIM: by contract every reference inside an expression
 * transform is already fully scoped, so no namespacing applies.
 */
function applyVariableMapExpression(
  components: Record<string, ComponentSystem>,
  entry: CouplingEntry,
): void {
  const e = entry as unknown as { from: string; to: string; transform: Expression }
  if (!exprReferencesVar(e.transform, e.from)) {
    throw new FlattenError(
      `variable_map expression transform mapping '${e.from}' -> '${e.to}' does not reference ` +
        `its source variable '${e.from}'`,
    )
  }

  let targetComp: ComponentSystem | undefined
  let removed: FlattenedVariable | undefined
  for (const comp of Object.values(components)) {
    const popped = comp.parameters[e.to]
    if (popped === undefined) continue
    delete comp.parameters[e.to]
    if (removed === undefined) {
      removed = popped
      targetComp = comp
    }
  }
  if (targetComp === undefined) targetComp = components[e.to.slice(0, e.to.indexOf('.'))]
  if (targetComp === undefined) return

  const observed: FlattenedVariable = {
    name: e.to,
    type: 'observed',
    sourceSystem: removed?.sourceSystem ?? targetComp.name,
  }
  if (removed?.units !== undefined) observed.units = removed.units
  if (removed?.description !== undefined) observed.description = removed.description
  if (removed?.shape !== undefined) observed.shape = [...removed.shape]
  targetComp.observed[e.to] = observed
  targetComp.equations.push({ lhs: e.to, rhs: e.transform, sourceSystem: targetComp.name })
}

/**
 * Substitute the target parameter with the source variable.
 *
 * For `param_to_var`, `conversion_factor`, and the empty/absent transform, the
 * target is PROMOTED — removed from the parameter list, since it becomes a shared
 * variable. For `identity` / `additive` / `multiplicative` the target stays a
 * parameter; the substitution still runs so the equation set references the
 * canonical name.
 *
 * `loaderNames` is the set of top-level `data_sources` keys. When a
 * `param_to_var` binds a LOADED field onto a GRID-SHAPED consumer parameter, the
 * shape transfers to the loader-qualified producer name so the downstream
 * pointwise lift (esm-spec §10.5) recognizes it as an array operand to index per
 * grid cell.
 */
function applyVariableMap(
  components: Record<string, ComponentSystem>,
  entry: CouplingEntry,
  loaderNames: ReadonlySet<string>,
): void {
  const e = entry as unknown as {
    from?: string
    to?: string
    transform?: string | ExpressionNode
    factor?: number
  }
  const fromVar = e.from
  const toVar = e.to
  if (fromVar === undefined || toVar === undefined || fromVar === '' || toVar === '') return
  if (e.transform !== undefined && typeof e.transform !== 'string') {
    applyVariableMapExpression(components, entry)
    return
  }

  const factor = e.factor ?? 1
  const src: Expression = factor !== 1 ? { op: '*', args: [factor, fromVar] } : fromVar
  const bindings = { [toVar]: src }

  for (const comp of Object.values(components)) {
    comp.equations = comp.equations.map((eq) => ({
      lhs: substitute(eq.lhs, bindings) as Expression,
      rhs: renameJoinNames(substitute(eq.rhs, bindings) as Expression, toVar, fromVar),
      sourceSystem: eq.sourceSystem,
    }))
  }

  const transform = typeof e.transform === 'string' ? e.transform.toLowerCase() : ''
  if (!['param_to_var', 'conversion_factor', ''].includes(transform)) return

  for (const comp of Object.values(components)) {
    const target = comp.parameters[toVar]
    if (target === undefined) continue
    delete comp.parameters[toVar]
    // Carry a grid shape from the (deleted) consumer parameter onto the
    // loader-qualified producer name so the pointwise lift indexes the loaded
    // field per cell. Only when `from` is a data-source-fed field (which guards
    // against binding a model STATE) and the producer is not already known.
    const fromOwner = fromVar.includes('.') ? fromVar.slice(0, fromVar.indexOf('.')) : fromVar
    if (
      target.shape !== undefined &&
      target.shape.length > 0 &&
      loaderNames.has(fromOwner) &&
      comp.parameters[fromVar] === undefined
    ) {
      const promoted: FlattenedVariable = {
        name: fromVar,
        type: 'parameter',
        sourceSystem: fromOwner,
        shape: [...target.shape],
      }
      if (target.units !== undefined) promoted.units = target.units
      if (target.description !== undefined) promoted.description = target.description
      comp.parameters[fromVar] = promoted
    }
  }
}

// ---------------------------------------------------------------------------
// Assembly
// ---------------------------------------------------------------------------

function collectComponents(file: EsmFile): {
  components: Record<string, ComponentSystem>
  sourceSystems: string[]
} {
  const components: Record<string, ComponentSystem> = {}
  const sourceSystems: string[] = []
  const dataSources = (file.data_sources ?? {}) as Record<string, DataSource>

  for (const [name, model] of Object.entries(file.models ?? {})) {
    if (isSubsystemRef(model)) continue
    components[name] = collectModel(model as Model, name, dataSources)
    sourceSystems.push(name)
  }
  for (const [name, rs] of Object.entries(file.reaction_systems ?? {})) {
    if (isSubsystemRef(rs)) continue
    components[name] = collectReactionSystem(rs as ReactionSystem, name)
    sourceSystems.push(name)
  }
  return { components, sourceSystems }
}

/**
 * Apply the file's coupling entries to `components` in place.
 *
 * `operator_compose` runs FIRST so its placeholder expansion and merge happen
 * before any `variable_map` substitution rewrites the dependent variable names
 * out from under it.
 */
function applyCouplings(
  file: EsmFile,
  components: Record<string, ComponentSystem>,
  metadata: FlattenMetadata,
  entries: CouplingEntry[],
): void {
  const composes: CouplingEntry[] = []
  const couples: CouplingEntry[] = []
  const varMaps: CouplingEntry[] = []

  for (const entry of entries) {
    const e = entry as unknown as Record<string, unknown>
    switch (entry.type) {
      case 'operator_compose':
        composes.push(entry)
        break
      case 'couple':
        couples.push(entry)
        break
      case 'variable_map':
        varMaps.push(entry)
        break
      case 'callback':
        metadata.callbacks.push(String(e.callback_id ?? '?'))
        break
      default:
        if ((entry as { type: string }).type === 'operator_apply') {
          metadata.operatorApplies.push(String(e.operator ?? '?'))
        }
        break
    }
    metadata.couplingRules.push(describeCoupling(entry))
  }

  for (const oc of composes) {
    expandOperatorComposePlaceholders(components, oc)
    applyOperatorCompose(components, oc)
  }
  for (const cp of couples) applyCouple(components, cp)

  const loaderNames = new Set(Object.keys(file.data_sources ?? {}))
  for (const vm of varMaps) applyVariableMap(components, vm, loaderNames)
}

/** Assemble the final system from the per-component pieces. */
function assembleSystem(
  file: EsmFile,
  components: Record<string, ComponentSystem>,
  metadata: FlattenMetadata,
): FlattenedSystem {
  const combined = newComponent('')
  for (const comp of Object.values(components)) mergeComponent(combined, comp)

  const flat: FlattenedSystem = {
    independentVariables: ['t'],
    stateVariables: { ...combined.stateVars },
    parameters: { ...combined.parameters },
    observedVariables: { ...combined.observed },
    algebraicVariables: {},
    brownianParameters: {},
    discreteParameters: {},
    equations: [],
    continuousEvents: [],
    discreteEvents: [],
    domain: null,
    metadata,
    indexSets: { ...((file.index_sets ?? {}) as Record<string, unknown>) },
    functionTables: { ...((file.function_tables ?? {}) as Record<string, unknown>) },
    templateRegistry: {},
    fieldIcs: [],
    loaderFields: [...combined.loaderFields],
    liftedShapes: {},
    systemKind: 'ode',
  }

  const seenLhs: Record<string, FlattenedEquation> = {}
  for (const eq of combined.equations) {
    const dep = lhsDependentVar(eq.lhs)
    // Array-op equations may legitimately define different index subsets of one
    // state variable (stencil interior + BCs, block-assembled makearray), so the
    // scalar-only dedup check is skipped for them.
    const isArrayEq = hasArrayOp(eq.lhs) || hasArrayOp(eq.rhs)
    if (dep !== undefined && !isArrayEq) {
      const existing = seenLhs[dep]
      if (existing !== undefined) {
        if (JSON.stringify(existing.rhs) !== JSON.stringify(eq.rhs)) {
          // A SINGLE source system authoring two equations with the same scalar
          // LHS expressed an algebraic constraint on purpose (K = f(T) AND
          // K = [H+][OH-]); structural simplification resolves which equation
          // defines which variable. A CROSS-system conflict is an error.
          if (
            existing.sourceSystem !== eq.sourceSystem &&
            !(hasArrayOp(existing.lhs) || hasArrayOp(existing.rhs))
          ) {
            throw new ConflictingDerivativeError(
              `Two systems define non-additive equations for variable '${dep}': ` +
                `${existing.sourceSystem} vs ${eq.sourceSystem}`,
            )
          }
        } else {
          continue
        }
      }
      seenLhs[dep] = eq
    }
    flat.equations.push(eq)
  }
  return flat
}

// ---------------------------------------------------------------------------
// Events, domain, independent variables
// ---------------------------------------------------------------------------

function namespaceEventAffects(
  affects: AffectEquation[] | undefined,
  varToNamespaced: Record<string, string>,
): AffectEquation[] {
  return (affects ?? []).map((affect) => {
    const lhs = varToNamespaced[affect.lhs] ?? affect.lhs
    let rhs: Expression = affect.rhs
    if (typeof rhs === 'string') rhs = varToNamespaced[rhs] ?? rhs
    else if (isNode(rhs)) rhs = substitute(rhs, varToNamespaced) as Expression
    return { lhs, rhs }
  })
}

/**
 * Collect the file's events, dot-namespacing references that unambiguously match
 * a known state variable or parameter. A component's events are not tagged with
 * their source system in the file's flat event view, so the rewrite is by bare
 * name — first match wins.
 */
function namespaceEvents(file: EsmFile, flat: FlattenedSystem): void {
  const varToNamespaced: Record<string, string> = {}
  for (const name of [...Object.keys(flat.stateVariables), ...Object.keys(flat.parameters)]) {
    const bare = name.slice(name.lastIndexOf('.') + 1)
    if (!Object.prototype.hasOwnProperty.call(varToNamespaced, bare)) {
      varToNamespaced[bare] = name
    }
  }

  const components: Array<Model | ReactionSystem> = []
  for (const c of Object.values(file.models ?? {})) {
    if (!isSubsystemRef(c)) components.push(c as Model)
  }
  for (const c of Object.values(file.reaction_systems ?? {})) {
    if (!isSubsystemRef(c)) components.push(c as ReactionSystem)
  }

  for (const component of components) {
    for (const event of component.discrete_events ?? []) {
      flat.discreteEvents.push({
        ...event,
        affects: namespaceEventAffects(event.affects, varToNamespaced),
      })
    }
    for (const event of component.continuous_events ?? []) {
      const next: ContinuousEvent = {
        ...event,
        conditions: event.conditions.map((c) => substitute(c, varToNamespaced) as Expression) as [
          Expression,
          ...Expression[],
        ],
        affects: namespaceEventAffects(event.affects, varToNamespaced),
      }
      if (event.affect_neg !== undefined && event.affect_neg !== null) {
        next.affect_neg = namespaceEventAffects(event.affect_neg, varToNamespaced)
      }
      flat.continuousEvents.push(next)
    }
  }
}

/**
 * Derive independent variables from the equation set: time is always present,
 * and a spatial axis is added when an UNDISCRETIZED spatial differential still
 * names it.
 */
function deriveIndependentVars(flat: FlattenedSystem): void {
  const dims = new Set<string>()
  for (const eq of flat.equations) {
    spatialDimsInExpr(eq.lhs, dims)
    spatialDimsInExpr(eq.rhs, dims)
  }
  flat.independentVariables = ['t', ...[...dims].sort()]
}

// ---------------------------------------------------------------------------
// The §6.3.1 subsets, the `ic` classification, and the derived system kind
// ---------------------------------------------------------------------------

/**
 * A model-shaped view of the FLATTENED system that `classification` accepts.
 *
 * Classification is re-run over the flattened system rather than per component
 * because flattening moves the ground under it: `operator_compose` merges two
 * RHSs into one equation, `variable_map` deletes a parameter and promotes a
 * variable in its place, and the pointwise lift rewrites a scalar state ODE into
 * an `aggregate`. A per-component answer namespaced after the fact would describe
 * the document, not the system produced from it.
 *
 * The view hands the classifier the two DECLARED types plus the raw `update` /
 * `distribution` metadata and lets it derive everything else — the same code
 * path, and therefore the same answers, as the per-model accessors. Reading
 * {@link FlattenedVariable.type} (already a derived role) to answer a derived
 * question is precisely what 1.0.0 removes.
 */
function classificationView(flat: FlattenedSystem): Model {
  const variables: Record<string, ModelVariable> = {}
  const put = (name: string, v: FlattenedVariable, declared: 'unknown' | 'parameter'): void => {
    if (Object.prototype.hasOwnProperty.call(variables, name)) return
    const out: ModelVariable = { type: declared }
    if (v.units !== undefined) out.units = v.units
    if (v.default !== undefined) out.default = v.default
    if (v.shape !== undefined) out.shape = v.shape
    if (v.update !== undefined) out.update = v.update
    if (v.distribution !== undefined) out.distribution = v.distribution
    variables[name] = out
  }
  for (const [name, v] of Object.entries(flat.stateVariables)) put(name, v, 'unknown')
  for (const [name, v] of Object.entries(flat.observedVariables)) put(name, v, 'unknown')
  for (const [name, v] of Object.entries(flat.parameters)) put(name, v, 'parameter')
  return {
    variables,
    equations: flat.equations.map((eq) => ({ lhs: eq.lhs, rhs: eq.rhs })),
  } as Model
}

/**
 * Select `names` out of `maps`, keeping each map's insertion order.
 *
 * The classification accessors return SORTED name lists — a set-valued answer
 * spelled as a list. Step 4 requires DOCUMENT order of every map, so membership
 * comes from the accessor and POSITION comes from the already-document-ordered
 * map being filtered. Sorting here instead would be observable: a parameter
 * vector is positional.
 */
function inDocumentOrder(
  names: ReadonlySet<string>,
  ...maps: FlattenedVariableMap[]
): FlattenedVariableMap {
  const out: FlattenedVariableMap = {}
  for (const map of maps) {
    for (const [name, v] of Object.entries(map)) {
      if (names.has(name) && !Object.prototype.hasOwnProperty.call(out, name)) out[name] = v
    }
  }
  return out
}

/**
 * Fill the §6.3.1 SUBSET maps and the derived {@link FlattenedSystem.systemKind}.
 * Every membership decision is delegated to `classification`, the binding's only
 * sanctioned answer to these questions; nothing here re-implements an
 * `update.kind === 'wiener'` test.
 */
function classifyFlattened(flat: FlattenedSystem): void {
  const view = classificationView(flat)
  flat.algebraicVariables = inDocumentOrder(
    new Set(algebraicUnknowns(view)),
    flat.stateVariables,
    flat.observedVariables,
  )
  flat.brownianParameters = inDocumentOrder(new Set(classifyBrownian(view)), flat.parameters)
  flat.discreteParameters = inDocumentOrder(new Set(classifyDiscrete(view)), flat.parameters)
  flat.systemKind = classifySystemKind(view)
}

/**
 * Record the deferred `ic` equations (esm-spec §11.4.1) as ordered
 * `(state, expr)` pairs and REMOVE them from `equations`.
 *
 * An `ic` equation pins a state's value at t=0 rather than defining its dynamics,
 * so a consumer folds it into `u0` instead of the RHS. Leaving it in `equations`
 * would make that list unusable for building a right-hand side without filtering,
 * and equation counts incomparable across bindings.
 *
 * Runs LAST — after the pointwise lift and the independent-variable derivation —
 * so every intermediate pass still sees the equation list it always did and only
 * the FINAL, observable `equations` differs.
 */
function collectFieldIcs(flat: FlattenedSystem): void {
  const ics: FieldInitialCondition[] = []
  const remaining: FlattenedEquation[] = []
  for (const eq of flat.equations) {
    const lhs = eq.lhs
    const target =
      isNode(lhs) && lhs.op === 'ic' && lhs.args !== undefined && lhs.args.length === 1
        ? lhs.args[0]
        : undefined
    if (typeof target === 'string') ics.push({ state: target, expr: eq.rhs })
    else remaining.push(eq)
  }
  flat.fieldIcs = ics
  flat.equations = remaining
}

// ---------------------------------------------------------------------------
// Pointwise spatial lift (esm-spec §10.5)
// ---------------------------------------------------------------------------
//
// Reaction ODE-gen and coupling both run at the AST level and IN THAT ORDER
// (reactions -> generic `D(sp) = Σ terms`; then `operator_compose` merges each
// species' reaction ODE with the spatial operator's advection makearray). What
// operator_compose does NOT do is array-ify the result: the merged
// `D(sp) = <reaction> + <-u·makearray(grad(sp))>` still has a SCALAR `sp` while
// its advection makearray indexes `sp` per grid cell. This pass performs the
// `lifting: "pointwise"` promotion — wrapping each merged state ODE in an
// `aggregate` over the grid, indexing the bare reaction species per cell and each
// operator makearray per cell, and recording the species' concrete grid shape.

function collectMakearrays(expr: Expression): ExpressionNode[] {
  const acc: ExpressionNode[] = []
  walkNodes(expr, (node) => {
    if (node.op === 'makearray') acc.push(node)
  })
  return acc
}

/** First bare-name leaf of an index-position expression (its loop variable). */
function indexArgLoop(expr: Expression): string | undefined {
  if (typeof expr === 'string') return expr
  if (!isNode(expr)) return undefined
  for (const arg of expr.args ?? []) {
    const v = indexArgLoop(arg)
    if (v !== undefined) return v
  }
  return undefined
}

/**
 * Ordered spatial loop variables of a lowered operator makearray, read from an
 * `index(<lifted species>, a1, …, aRank)` gather whose every position carries a
 * loop variable (the interior stencil).
 */
function detectLiftLoops(
  ma: ExpressionNode,
  lifted: ReadonlySet<string>,
  rank: number,
): string[] | undefined {
  let found: string[] | undefined
  walkNodes(ma, (node) => {
    if (found !== undefined) return
    if (node.op !== 'index' || node.args === undefined || node.args.length - 1 !== rank) return
    const head = node.args[0]
    if (typeof head !== 'string' || !lifted.has(head)) return
    const loops: string[] = []
    for (let k = 1; k < node.args.length; k++) {
      const lv = indexArgLoop(node.args[k])
      if (lv === undefined) return
      loops.push(lv)
    }
    found = loops
  })
  return found
}

/** Per-dimension grid extent: the largest cell index addressed in each `regions` dimension. */
function makearrayExtents(ma: ExpressionNode): number[] {
  const regions = ((ma as { regions?: unknown }).regions ?? []) as number[][][]
  if (regions.length === 0) return []
  const rank = regions[0].length
  const ext = new Array<number>(rank).fill(0)
  for (const region of regions) {
    if (region.length !== rank) continue
    for (let d = 0; d < rank; d++) ext[d] = Math.max(ext[d], Math.trunc(region[d][1]))
  }
  return ext
}

/**
 * Rewrite a scalar (merged reaction + operator) RHS into its per-cell form over
 * the spatial `loops`: a bare reference to an array variable becomes
 * `index(var, loops…)`, and each spatial-operator `makearray` becomes
 * `index(makearray, loops…)`. Self-contained nodes are left untouched.
 */
function liftRhsToCell(
  expr: Expression,
  arrayVars: ReadonlySet<string>,
  loops: string[],
): Expression {
  if (typeof expr === 'string') {
    return arrayVars.has(expr) ? { op: 'index', args: [expr, ...loops] } : expr
  }
  if (!isNode(expr)) return expr
  if (expr.op === 'makearray') {
    // Tag the makearray with its loop symbols so the evaluator binds each
    // region's own arange when materializing the field; otherwise a per-cell
    // gather would read the stencil out of bounds.
    const ma = { ...expr, output_idx: [...loops] } as ExpressionNode
    return { op: 'index', args: [ma, ...loops] }
  }
  if (expr.op === 'index' || expr.op === 'aggregate' || expr.op === 'arrayop') return expr
  return {
    ...expr,
    args: (expr.args ?? []).map((a) => liftRhsToCell(a, arrayVars, loops)),
  } as ExpressionNode
}

function applyPointwiseLift(flat: FlattenedSystem, coupling: CouplingEntry[]): void {
  const wanted = coupling.some(
    (c) =>
      c.type === 'operator_compose' &&
      (c as unknown as { lifting?: string }).lifting === 'pointwise',
  )
  if (!wanted) return

  const dTarget = (lhs: Expression): string | undefined => {
    if (
      isNode(lhs) &&
      lhs.op === 'D' &&
      lhs.args !== undefined &&
      typeof lhs.args[0] === 'string'
    ) {
      return lhs.args[0]
    }
    return undefined
  }

  // A species is lifted iff its state ODE's merged RHS carries a spatial-operator
  // makearray (the advection contribution operator_compose added).
  const lifted = new Set<string>()
  for (const eq of flat.equations) {
    const target = dTarget(eq.lhs)
    if (target !== undefined && collectMakearrays(eq.rhs).length > 0) lifted.add(target)
  }
  if (lifted.size === 0) return

  // Operands to index per cell: the lifted species plus any already array-shaped
  // parameter / observed / state (e.g. a grid-shaped wind field from a loader).
  const arrayVars = new Set<string>(lifted)
  for (const table of [flat.parameters, flat.observedVariables, flat.stateVariables]) {
    for (const [name, v] of Object.entries(table)) {
      if (v.shape !== undefined && v.shape.length > 0) arrayVars.add(name)
    }
  }

  const next: FlattenedEquation[] = []
  for (const eq of flat.equations) {
    const target = dTarget(eq.lhs)
    if (target === undefined || !lifted.has(target)) {
      next.push(eq)
      continue
    }
    const mas = collectMakearrays(eq.rhs)
    const regions =
      mas.length > 0 ? (((mas[0] as { regions?: number[][][] }).regions ?? []) as number[][][]) : []
    if (mas.length === 0 || regions.length === 0) {
      next.push(eq)
      continue
    }
    const rank = regions[0].length
    let loops: string[] | undefined
    for (const ma of mas) {
      loops = detectLiftLoops(ma, lifted, rank)
      if (loops !== undefined) break
    }
    if (loops === undefined) {
      throw new DimensionPromotionError(
        `pointwise lift: could not determine the spatial loop variables for species ` +
          `'${target}' from its operator makearray`,
      )
    }

    const extents = makearrayExtents(mas[0])
    const ranges: Record<string, [number, number]> = {}
    for (let d = 0; d < rank; d++) ranges[loops[d]] = [1, extents[d]]
    flat.liftedShapes[target] = extents

    // `args: []` is not decoration: an `aggregate` carries its body in `expr`,
    // but the canonical node shape (and `isExprNode`) still requires the `args`
    // slot, and the Python oracle emits it the same way.
    next.push({
      lhs: {
        op: 'aggregate',
        args: [],
        output_idx: [...loops],
        ranges,
        expr: { op: 'D', args: [{ op: 'index', args: [target, ...loops] }], wrt: 't' },
      } as unknown as ExpressionNode,
      rhs: {
        op: 'aggregate',
        args: [],
        output_idx: [...loops],
        ranges,
        expr: liftRhsToCell(eq.rhs, arrayVars, loops),
      } as unknown as ExpressionNode,
      sourceSystem: eq.sourceSystem,
    })
  }
  flat.equations = next
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Flatten a coupled multi-system ESM file into a single unified system
 * (esm-libraries-spec §4.7.5).
 *
 * The result is the canonical intermediate representation: dot-namespaced
 * variables carrying their full declared metadata, equations as Expression trees,
 * coupling rules resolved INTO the equation set, and the registries needed to
 * consume it without re-reading the source document.
 *
 * @throws {FlattenError} when the file has no models and no reaction systems, or
 *   when a variable carries a type esm 1.0.0 removed.
 * @throws {ConflictingDerivativeError} when two source systems define
 *   non-additive equations for the same dependent variable.
 * @throws {DomainUnitMismatchError} when an `identity` `variable_map` bridges two
 *   variables whose declared, non-empty units differ.
 */
export function flatten(file: EsmFile, options: FlattenOptions = {}): FlattenedSystem {
  const hasModels = Object.keys(file.models ?? {}).length > 0
  const hasReactions = Object.keys(file.reaction_systems ?? {}).length > 0
  if (!hasModels && !hasReactions) {
    throw new FlattenError('Cannot flatten an EsmFile with no models or reaction systems')
  }

  // Expand `coupling_import` entries (esm-spec §10.10.3) into concrete edges
  // BEFORE any coupling processing. A file with no such entries yields its
  // `coupling` array verbatim and needs no options.
  const couplingEntries = expandCouplingImports(file, options) ?? []

  // Preflight: reject an `identity` variable_map bridging different declared
  // units (§4.7.6). Runs over the expanded list so imported edges are checked.
  checkVariableMapUnits(file, couplingEntries)

  // 1. Collect every component into a per-system bag of variables + equations.
  const { components, sourceSystems } = collectComponents(file)
  const metadata: FlattenMetadata = {
    sourceSystems: [...sourceSystems],
    couplingRules: [],
    operatorApplies: [],
    callbacks: [],
  }

  // 2. Resolve coupling entries into the per-component equation sets.
  applyCouplings(file, components, metadata, couplingEntries)

  // 3. Assemble one system from the per-component pieces.
  const flat = assembleSystem(file, components, metadata)

  // 4. Collect and namespace events.
  namespaceEvents(file, flat)

  // 4b. Pointwise spatial lift (esm-spec §10.5) over the expanded couplings.
  applyPointwiseLift(flat, couplingEntries)

  // 5. Domain pass-through.
  if (file.domain !== undefined) flat.domain = file.domain as Domain

  // 6. Derive independent variables from the equation set.
  deriveIndependentVars(flat)

  // 7. The remaining canonical step-4 fields, all over the FINISHED system so
  //    they see the equations coupling and the lift actually produced.
  classifyFlattened(flat)
  collectFieldIcs(flat)
  flat.templateRegistry = mergedTemplateRegistry(file)

  return flat
}
