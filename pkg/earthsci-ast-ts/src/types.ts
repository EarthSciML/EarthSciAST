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
export type Expr = GeneratedExpression | NumericLiteral

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
import type { ESMFormat, ExpressionNode } from './generated.js'
export type EsmFile = ESMFormat

/** @deprecated Prefer {@link EsmFile}. Identical to the generated `ESMFormat`. */
export type EsmFormat = ESMFormat

/** @deprecated Prefer {@link ExpressionNode} (the generated name). */
export type ExprNode = ExpressionNode

// Discriminated unions (on the 'type' field) come straight from the
// generated schema types.
export type { CouplingEntry, DiscreteEventTrigger } from './generated.js'

// Re-export key types with explicit names for better documentation
export type {
  // Core file structure
  Metadata,

  // Model components
  Model,
  ReactionSystem,
  ModelVariable,
  Species,
  Reaction,

  // Events
  ContinuousEvent,
  DiscreteEvent,

  // Expressions and equations
  Expression,
  Equation,
  AffectEquation,
  FunctionalAffect,

  // Data handling
  DataLoader,
  DataLoaderDeterminism,

  // Closed function registry (v0.3.0)
  EnumDeclaration,

  // System configuration
  Domain,
  Reference,
} from './generated.js'
