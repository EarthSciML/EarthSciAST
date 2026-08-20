/**
 * EarthSciML Serialization Format TypeScript type definitions — plus a small
 * set of RUNTIME re-exports.
 *
 * Provides the complete type definitions for the ESM format: the auto-generated
 * types from the JSON schema (`export * from './generated.js'`) and manual
 * augmentations for discriminated unions and ergonomics. For convenience this
 * module ALSO re-exports the runtime tagged numeric-literal API (`intLit`,
 * `floatLit`, `losslessJsonParse`, …) from `./numeric-literal.js`, so it is not
 * purely type-level; `index.ts` re-exports both surfaces from here (do not move
 * the runtime re-exports without updating `index.ts`).
 *
 * Canonical alias names (duplicates are kept for back-compat but marked
 * `@deprecated`):
 *   - root file structure → `EsmFile`   (aliases: `EsmFormat`, generated `ESMFormat`)
 *   - operator node       → `ExpressionNode` (alias: `ExprNode`)
 *   - `Expression` (wire / schema-shaped value) and `Expr` (widened in-memory
 *     value that MAY carry a tagged `NumericLiteral`) are DISTINCT types, not
 *     aliases — pick by whether you hold a wire value or an in-memory one.
 */

// Re-export all generated types
export * from './generated.js'

// Manual type augmentations for better TypeScript experience

/**
 * In-memory mathematical-expression type: the wire `Expression`
 * (`number | string | ExpressionNode`) WIDENED to also admit `NumericLiteral`,
 * the tagged int/float leaf required by discretization RFC §5.4.1.
 *
 * `Expr` is NOT an alias of `Expression` and neither is deprecated: the
 * schema/wire form stays `Expression`, while `NumericLiteral` only exists in
 * memory (produced by `losslessJsonParse`, emitted back to bare JSON numbers by
 * `losslessJsonStringify`). Use `Expression` for values you parsed/serialized on
 * the wire; use `Expr` for values that may carry a tagged literal.
 */
import type { Expression as GeneratedExpression } from './generated.js'
import type { NumericLiteral } from './numeric-literal.js'

/**
 * An expression node whose OPERANDS are in-memory {@link Expr} values.
 *
 * The wire `ExpressionNode` has `args: Expression[]`, which cannot hold a
 * tagged `NumericLiteral`. Every rewriting pass (differentiation, substitution,
 * simplification, CSE) builds nodes out of operands it was handed, so those
 * operands are `Expr` and the node it builds is this. `ExpressionNode` is
 * assignable to it — `Expression` is a subset of `Expr` and `args` is covariant
 * — so a wire node flows into a rewriting pass unchanged.
 *
 * Before esm 1.0.0 this widening was ACCIDENTAL: json2ts resolved the generated
 * `Expression` to `number | string | { [k: string]: unknown }`, whose open
 * object branch swallowed anything at all. The 1.0.0 schema restructure made it
 * resolve to the real `ExpressionNode` — strictly more faithful — which exposed
 * every site that had been relying on that looseness. This states the widening
 * deliberately instead of inheriting it from a generator artifact.
 */
export interface ExprNodeOf {
  op: string
  args: Expr[]
  [k: string]: unknown
}

export type Expr = GeneratedExpression | NumericLiteral | ExprNodeOf

// Re-export the tagged-literal API for consumers that need canonical
// int/float handling.
export type { NumericLiteral } from './numeric-literal.js'
export {
  intLit,
  floatLit,
  isNumericLiteral,
  isIntLit,
  isFloatLit,
  numericValue,
  losslessJsonParse,
  losslessJsonStringify,
  formatFloatToken,
  CanonicalNonfiniteError,
  LosslessJsonParseError,
} from './numeric-literal.js'

/**
 * Main ESM file structure — the CANONICAL name for the root document type.
 * Alias for the generated `ESMFormat`. Prefer `EsmFile` over the deprecated
 * `EsmFormat` and the generated `ESMFormat` (all three are the same type).
 */
import type {
  ESMFormat,
  ExpressionNode,
  Model as GeneratedModel,
  SubsystemRef as GeneratedSubsystemRef,
} from './generated.js'
export type EsmFile = ESMFormat & {
  /**
   * Narrowed so that a model reached from the document root is the 1.0.0
   * {@link Model} — closed variables, no data-source subsystem — rather than the
   * generated shape. Without this the strictness stops at the root and
   * `file.models[m].variables[v].expression` reads as `unknown` again.
   */
  models?: { [k: string]: Model | GeneratedSubsystemRef }
}

/** @deprecated Prefer {@link EsmFile}. Identical to the generated `ESMFormat`. */
export type EsmFormat = ESMFormat

/** @deprecated Prefer {@link ExpressionNode} (the generated name). */
export type ExprNode = ExpressionNode

// Discriminated unions (on the 'type' field) come straight from the
// generated schema types.
export type { CouplingEntry, DiscreteEventTrigger } from './generated.js'

// ---------------------------------------------------------------------------
// esm 1.0.0 unified variable model — hand-written types.
//
// These OVERRIDE the same-named `export *` re-exports from `./generated.js`
// (an explicit export wins over a star export). They are hand-written because
// `json2ts` cannot express what the schema means here:
//
//   - `Distribution` and `ParameterUpdate` are `oneOf` unions discriminated by
//     `kind`, but the branches carry `allOf`/`oneOf` co-constraints, so json2ts
//     collapses most of them to `{ [k: string]: unknown }` — every field would
//     read as `unknown` and every `kind` narrowing would be a no-op.
//   - `ModelVariable` carries an `allOf` of `if`/`then` rules, which makes
//     json2ts emit `ModelVariable1 & {...}` with `ModelVariable1` an open index
//     signature. That index signature silently types a REMOVED field (notably
//     `variable.expression`) as `unknown` instead of rejecting it, which is
//     exactly the 0.x-shaped mistake 1.0.0 is meant to make impossible.
//
// Keep these in step with `esm-schema.json` `$defs`: ModelVariable,
// Distribution, ParameterUpdate, ParameterUpdateSpec, DataSourceBinding,
// FunctionalUpdate, CovarianceMatrix.
// ---------------------------------------------------------------------------

import type { DataSourceSelect, Reference as SchemaReference } from './generated.js'

/**
 * Symmetric positive-semidefinite covariance matrix, row-major: `[i][j]` is the
 * covariance of components i and j. Square, with order equal to the length of
 * the accompanying `mean` / `mu` vector and of the parameter's `shape`.
 */
export type CovarianceMatrix = number[][]

/**
 * Gaussian. Exactly one of `std` (independent components) or `cov` (a full
 * covariance matrix) — never both, which is why this is a union rather than two
 * optional fields.
 */
export type NormalDistribution = { kind: 'normal'; mean: number | number[] } & (
  | { std: number | number[]; cov?: never }
  | { cov: CovarianceMatrix; std?: never }
)

/**
 * Log-normal: `log(value)` is normal with mean `mu` and spread `sigma` / `cov`.
 * Both spread forms are on the LOG scale. Exactly one of `sigma` or `cov`.
 */
export type LognormalDistribution = { kind: 'lognormal'; mu: number | number[] } & (
  | { sigma: number | number[]; cov?: never }
  | { cov: CovarianceMatrix; sigma?: never }
)

/**
 * Uniform on `[low, high]`. Components are independent by construction, so
 * there is no covariance form.
 */
export interface UniformDistribution {
  kind: 'uniform'
  low: number | number[]
  high: number | number[]
}

/**
 * A parameter's value drawn from a probability distribution rather than fixed.
 * The closed set is `normal` | `lognormal` | `uniform`. Mutually exclusive with
 * `default`. WHEN it is drawn is decided by the parameter's `update`: with no
 * update it is sampled ONCE at setup; with `update.kind: "wiener"` it is
 * resampled every step with √dt scaling.
 *
 * Univariate when the location parameter is a number, multivariate when it is
 * an array (in which case the parameter's `shape` must agree).
 */
export type Distribution = NormalDistribution | LognormalDistribution | UniformDistribution

/**
 * A registered handler computing a parameter's new value when its update fires
 * — the 0.x event `functional_affect`, relocated onto the parameter it writes.
 */
export interface FunctionalUpdate {
  handler_id: string
  read_vars?: string[]
  read_params?: string[]
  config?: { [k: string]: unknown }
}

/** Decodes a TEXT source column into numbers a model can compute with. */
export interface DataSourceCodes {
  map: { [k: string]: number }
  case_insensitive?: boolean
  unmapped?: 'drop' | 'error' | number
}

/**
 * Binds a parameter to one variable of a `data_sources` entry. This is the 0.x
 * `DataLoaderVariable` minus `units`: the units are the parameter's own,
 * declared once on the parameter instead of twice.
 */
export interface DataSourceBinding {
  file_variable: string
  unit_conversion?: GeneratedExpression
  codes?: DataSourceCodes
  select?: DataSourceSelect
  description?: string
  reference?: SchemaReference
}

/**
 * The value form every non-`wiener` update kind takes EXACTLY ONE of: computed
 * symbolically (`expression`), read from a data source (`from`), or produced by
 * a registered handler (`handler`).
 */
export type UpdateValueForm =
  | { expression: GeneratedExpression; from?: never; handler?: never }
  | { from: DataSourceBinding; expression?: never; handler?: never }
  | { handler: FunctionalUpdate; expression?: never; from?: never }

/**
 * A driving Wiener (Brownian) process: the parameter's `distribution` is
 * resampled every step with √dt increment scaling. Takes NO value form — the
 * distribution IS the value — and requires `distribution` on the variable.
 * Its presence promotes the enclosing model from an ODE system to an SDE.
 */
export interface WienerUpdate {
  kind: 'wiener'
}

/** Time-driven refresh at preset `times` and/or on a periodic `interval`. */
export type ScheduleUpdate = {
  kind: 'schedule'
  times?: number[]
  interval?: number
  initial_offset?: number
} & UpdateValueForm

/** Refresh at the end of any timestep at which `when` is true. */
export type ConditionUpdate = { kind: 'condition'; when: GeneratedExpression } & UpdateValueForm

/** Refresh when `when` crosses zero, located by root-finding. */
export type CrossingUpdate = {
  kind: 'crossing'
  when: GeneratedExpression
  direction?: 'up' | 'down' | 'any'
} & UpdateValueForm

/**
 * Refresh when the named data source advances a record. `source` MUST resolve
 * to a `data_sources` key (`data_source_undefined`).
 */
export type DataUpdate = { kind: 'data'; source: string } & UpdateValueForm

/** Refresh on a mesh-topology change (AMR refinement, moving/reloaded mesh). */
export type RemeshUpdate = { kind: 'remesh'; hook?: string } & UpdateValueForm

/**
 * Every update kind except `wiener`. The schema forbids `wiener` inside an
 * update ARRAY (a driving noise process is the parameter's whole value), which
 * is what this type names.
 */
export type NonWienerParameterUpdate =
  | ScheduleUpdate
  | ConditionUpdate
  | CrossingUpdate
  | DataUpdate
  | RemeshUpdate

/** One update rule. Six kinds, discriminated by `kind`. */
export type ParameterUpdate = WienerUpdate | NonWienerParameterUpdate

/**
 * A parameter's update behavior: EITHER a single rule, OR an ordered array of
 * TWO OR MORE rules applied in declaration order. A single rule MUST be the
 * object form — a one-element array is invalid — so the representation of any
 * given update set is unique and the round-trip is stable.
 */
export type ParameterUpdateSpec =
  | ParameterUpdate
  | [NonWienerParameterUpdate, NonWienerParameterUpdate, ...NonWienerParameterUpdate[]]

/**
 * A variable in a model — either an `unknown` the solver solves for, or a
 * `parameter` supplied to it. There is no third kind, and no `expression`
 * field: an unknown's behavior is stated by the model's `equations` and nowhere
 * else.
 *
 * Everything a solver additionally needs is DERIVED, never declared — see the
 * classification API in `./classification.js` (`odeStates`, `observedUnknowns`,
 * `algebraicUnknowns`, `brownianParameters`, `discreteParameters`,
 * `sampledParameters`, `constantParameters`, `systemKind`).
 *
 * Deliberately CLOSED (no index signature): reading a field 1.0.0 removed —
 * `expression`, `noise_kind`, `correlation_group`, `refresh` — is a compile
 * error rather than a silent `unknown`.
 */
export interface ModelVariable {
  type: 'unknown' | 'parameter'
  units?: string
  /** For an unknown, its value at t=0. For a parameter, its constant value. */
  default?: number
  default_units?: string
  description?: string
  /**
   * Ordered index-set names. REQUIRED for a parameter whose `update` is
   * `schedule`, `data`, or `remesh`.
   */
  shape?: string[]
  location?: string
  /** Parameter-only. Mutually exclusive with `default`. */
  distribution?: Distribution
  /** Parameter-only. Absent means the parameter never changes after setup. */
  update?: ParameterUpdateSpec
}

/**
 * A model node. Narrows the generated type in the two places that matter: its
 * variables are the CLOSED {@link ModelVariable} above, and a subsystem is a
 * child model or a reference — never a data source, which from 1.0.0 is not a
 * component and cannot be a subsystem, a coupling endpoint, or a scoped-name
 * path root.
 */
export type Model = Omit<GeneratedModel, 'variables' | 'subsystems'> & {
  variables: { [k: string]: ModelVariable }
  subsystems?: { [k: string]: Model | GeneratedSubsystemRef }
}

// Re-export key types with explicit names for better documentation.
//
// `Model` and `ModelVariable` are NOT re-exported here: both are declared above
// as hand-written 1.0.0 types that deliberately override the generated shapes.
export type {
  // Core file structure
  Metadata,

  // Model components
  ReactionSystem,
  Species,
  Reaction,

  // Events
  ContinuousEvent,
  DiscreteEvent,

  // Expressions and equations
  Expression,
  Equation,
  AffectEquation,

  // Data handling — a data SOURCE is ingest configuration, not a component.
  // `DataLoader` / `DataLoaderVariable` / `FunctionalAffect` are gone in 1.0.0.
  DataSource,
  DataSourceDeterminism,
  DataSourceTemporal,
  DataSourceSelect,

  // Closed function registry (v0.3.0)
  EnumDeclaration,

  // System configuration
  Domain,
  Reference,
  SubsystemRef,
} from './generated.js'
