/**
 * EarthSciML Serialization Format TypeScript Type Definitions
 *
 * This module provides the complete type definitions for the ESM format,
 * including auto-generated types from the JSON schema and manual augmentations
 * for discriminated unions and improved type safety.
 */

// Re-export all generated types
export * from './generated.js'

// Manual type augmentations for better TypeScript experience

/**
 * Expression type alias - more concise name for mathematical expressions.
 *
 * Widened beyond the generated schema type to include `NumericLiteral`,
 * the tagged int/float leaf required by discretization RFC §5.4.1.
 * The schema/wire form stays `number | string | ExpressionNode`;
 * `NumericLiteral` only exists in memory, produced by
 * `losslessJsonParse` and emitted back to bare JSON numbers by
 * `losslessJsonStringify`.
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
 * Main ESM file structure
 * Alias for the generated ESMFormat type
 */
import type { ESMFormat } from './generated.js'
export type EsmFile = ESMFormat

// Discriminated unions (on the 'type' field) come straight from the
// generated schema types.
export type { CouplingEntry, DiscreteEventTrigger } from './generated.js'

// Re-export key types with explicit names for better documentation
export type {
  // Core file structure
  ESMFormat as EsmFormat,
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
  ExpressionNode as ExprNode,
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
