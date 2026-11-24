/**
 * Shared validation result / error types for the structural-validation modules.
 *
 * Leaf module: no dependency on any other `validate/` file, so the check
 * modules and the orchestrator can all import these shapes without a cycle.
 */

import type { UnitWarning } from '../units.js'

/**
 * Validation error with structured details
 */
export interface ValidationError {
  path: string
  message: string
  code: string
  details: Record<string, unknown>
}

/**
 * Structured validation result
 */
export interface ValidationResult {
  is_valid: boolean
  schema_errors: ValidationError[]
  structural_errors: ValidationError[]
  unit_warnings: UnitWarning[]
  /** Non-unit diagnostics that do not invalidate the document. */
  warnings: ValidationWarning[]
}

/**
 * An advisory validation finding that is not about units. It never changes
 * `is_valid`.
 */
export interface ValidationWarning {
  /** Stable diagnostic code. */
  code: string
  /** JSON pointer to the finding. */
  path: string
  message: string
}

/**
 * Structural errors share the exact `ValidationError` shape. This alias is a
 * readability marker used on the return types of the structural validators
 * below (as opposed to schema errors); it introduces no new fields.
 */
export type StructuralError = ValidationError
