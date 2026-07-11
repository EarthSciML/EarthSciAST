/**
 * ESM Format validation wrapper for cross-language conformance testing.
 *
 * Provides a standardized validation interface that matches the format expected
 * by the conformance test runner across all language implementations.
 *
 * This module is a thin barrel: the implementation lives under `./validate/`,
 * split into cohesive modules (expression-tree utilities, Go-mirroring unit
 * formatters, model / reaction-system / coupling checks, and the public
 * orchestrator). The public import path `./validate.js` and its export surface
 * are preserved verbatim — `validate`, `ValidationError`, `ValidationResult`,
 * and `StructuralError`.
 */

export { validate } from './validate/orchestrator.js'
export type { ValidationError, ValidationResult, StructuralError } from './validate/types.js'
