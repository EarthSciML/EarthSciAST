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
}

/**
 * Structural errors share the exact `ValidationError` shape. This alias is a
 * readability marker used on the return types of the structural validators
 * below (as opposed to schema errors); it introduces no new fields.
 */
export type StructuralError = ValidationError
