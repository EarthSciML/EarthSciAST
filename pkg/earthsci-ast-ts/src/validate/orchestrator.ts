/**
 * Public `validate()` orchestrator: parses/loads an ESM file, runs schema
 * validation, then drives every structural (post-schema) validator and
 * aggregates the results into a {@link ValidationResult}.
 *
 * This module imports the check modules (model-, reaction-, coupling-checks)
 * and shared helpers; the check modules never import back, so there is no cycle.
 */

import {
  validateSchema,
  load,
  ParseError,
  SchemaValidationError,
  ROOT_PATH,
  type SchemaError,
} from '../parse.js'
import { EsmMachineryError } from '../lower-expression-templates.js'
import { EnumLoweringError } from '../lower-enums.js'
import {
  LosslessJsonParseError,
  CanonicalNonfiniteError,
  losslessJsonParse,
  stripNumericLiterals,
} from '../numeric-literal.js'
import { ERROR_CODES } from '../errors.js'
import { type UnitWarning } from '../units.js'
import type { EsmFile } from '../types.js'
import type { ValidationError, ValidationResult, StructuralError } from './types.js'
import { isInlineModel } from './expr-utils.js'
import {
  validateEquationBalance,
  validateReferenceIntegrity,
  validateEventConsistency,
  validatePhysicalConstantUnits,
  validateConversionFactorConsistency,
  validateDefaultUnits,
} from './model-checks.js'
import {
  validateReactionConsistency,
  validateReactionRateUnits,
  validateReactionSystemICs,
} from './reaction-checks.js'
import {
  validateSubsystemRefs,
  validateCouplingIntegrity,
  validateCircularReferences,
  validateDataLoaderReferences,
  validateTemporalResolution,
} from './coupling-checks.js'

/**
 * Promote the DEFECT-BEARING unit findings to structural errors.
 *
 * The classification is carried on the warning itself (UnitWarning.code, assigned
 * in units.ts beside the message definitions, where the policy is stated in
 * full). Two codes describe a defect in the FILE and are promoted — to two
 * DIFFERENT structural codes, because they are different failures:
 *
 *   - `dimensional_mismatch` → `unit_inconsistency`. A PROVABLE inconsistency
 *     (metres plus kilograms, `log()` of a dimensional quantity, two sides that
 *     cannot agree). Something was proved wrong.
 *   - `unparseable_unit` → `unit_parse_error`. A declared unit string that names
 *     no real unit. NOTHING was proved inconsistent — the declaration is simply
 *     meaningless. Reported at the VARIABLE pointer with the offending
 *     declaration in `details`, exactly as the shared corpus pins
 *     (`tests/invalid/unparseable_unit.esm`).
 *
 * `analysis` warnings stay warnings: a symbolic exponent, an op with no
 * dimensional rule, an unknown variable, a bad arity. Each reports what the
 * CHECKER could not determine — a limit of the analysis, not a defect in the
 * file — and the dimension is left unknown and the check skipped rather than
 * assumed. (An unknown variable is separately a hard `undefined_variable` error,
 * so promoting it here would double-report it.)
 *
 * Promoting to a hard error is what the shared corpus requires:
 * `tests/invalid/expected_errors.json` pins every `units_*.esm` fixture as a
 * STRUCTURAL ERROR (`is_valid: false`), not a warning, at the JSON Pointer the
 * warning already carries.
 */
function promoteUnitWarningsToErrors(warnings: UnitWarning[]): StructuralError[] {
  const errors: StructuralError[] = []
  for (const warning of warnings) {
    // `location` is already a JSON Pointer (units.ts `componentPointer`), so it
    // is used verbatim. Root token is the shared `ROOT_PATH` ('$'), used only
    // when the warning carries no location (consistent with validate()'s catch
    // blocks and parse.ts's schema-error root fallback).
    const path = warning.location ?? ROOT_PATH
    if (warning.code === ERROR_CODES.UNPARSEABLE_UNIT) {
      errors.push({
        path,
        message: warning.message,
        code: ERROR_CODES.UNIT_PARSE_ERROR,
        details: { variable: warning.variable ?? '', units: warning.units ?? '' },
      })
    } else if (warning.code === ERROR_CODES.DIMENSIONAL_MISMATCH) {
      errors.push({
        path,
        message: warning.message,
        code: ERROR_CODES.UNIT_INCONSISTENCY,
        details: { equation: warning.equation || '' },
      })
    }
  }
  return errors
}

/**
 * Main structural validation function. Runs every structural (post-schema)
 * validator over a loaded ESM file and returns the aggregated errors.
 */
function performStructuralValidation(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []

  // Collect systems that participate in coupling — these may reference
  // variables from other systems, so equation balance and reference
  // integrity checks must be relaxed.
  const coupledSystems = new Set<string>()
  if (esmFile.coupling) {
    for (const entry of esmFile.coupling) {
      if ('systems' in entry && Array.isArray((entry as any).systems)) {
        for (const s of (entry as any).systems) {
          coupledSystems.add(s)
        }
      }
      if ('from' in entry && typeof (entry as any).from === 'string') {
        const fromSystem = (entry as any).from.split('.')[0]
        coupledSystems.add(fromSystem)
      }
      if ('to' in entry && typeof (entry as any).to === 'string') {
        const toSystem = (entry as any).to.split('.')[0]
        coupledSystems.add(toSystem)
      }
    }
  }

  // Validate models. Unresolved SubsystemRef entries are reported by
  // validateSubsystemRefs below; DataLoader subsystems carry no equations.
  if (esmFile.models) {
    for (const [modelName, model] of Object.entries(esmFile.models)) {
      if (!isInlineModel(model)) continue
      const modelPath = `/models/${modelName}`
      const isCoupled = coupledSystems.has(modelName)

      // Skip equation balance and reference integrity for coupled models,
      // as they may reference variables provided by other systems.
      if (!isCoupled) {
        errors.push(...validateEquationBalance(model, modelPath))
        errors.push(...validateReferenceIntegrity(model, modelPath, esmFile))
      }
      // `isCoupled` also admits the §6.4 `_var` placeholder as an event-affect
      // target — the same premise (this model's names may be supplied by the
      // composition) that skips the two checks above.
      errors.push(...validateEventConsistency(model, modelPath, isCoupled))
      errors.push(...validatePhysicalConstantUnits(model, modelPath))
      errors.push(...validateConversionFactorConsistency(model, modelPath))
      errors.push(...validateDefaultUnits(model, modelPath))

      // Recursively validate subsystems
      if (model.subsystems) {
        for (const [subsystemName, subsystem] of Object.entries(model.subsystems)) {
          if (!isInlineModel(subsystem)) continue
          const subsystemPath = `${modelPath}/subsystems/${subsystemName}`
          if (!isCoupled) {
            errors.push(...validateEquationBalance(subsystem, subsystemPath))
            errors.push(...validateReferenceIntegrity(subsystem, subsystemPath, esmFile))
          }
          errors.push(...validateEventConsistency(subsystem, subsystemPath, isCoupled))
          errors.push(...validatePhysicalConstantUnits(subsystem, subsystemPath))
          errors.push(...validateConversionFactorConsistency(subsystem, subsystemPath))
        }
      }
    }
  }

  // Validate reaction systems
  if (esmFile.reaction_systems) {
    for (const [systemName, reactionSystem] of Object.entries(esmFile.reaction_systems)) {
      const systemPath = `/reaction_systems/${systemName}`

      // `esmFile` lets a rate expression's SCOPED references (a cross-system
      // Arrhenius rate reading another model's temperature) resolve against the
      // whole document instead of being reported undefined.
      errors.push(...validateReactionConsistency(reactionSystem, systemPath, esmFile))
      errors.push(...validateReactionRateUnits(reactionSystem, systemPath))
      errors.push(...validateReactionSystemICs(reactionSystem, systemName, systemPath))

      // Recursively validate subsystems (unresolved SubsystemRef
      // entries carry no species/reactions — validating them is a
      // no-op, so skip them; validateSubsystemRefs flags them below)
      if (reactionSystem.subsystems) {
        for (const [subsystemName, subsystem] of Object.entries(reactionSystem.subsystems)) {
          if ('ref' in subsystem) continue
          const subsystemPath = `${systemPath}/subsystems/${subsystemName}`
          errors.push(...validateReactionConsistency(subsystem, subsystemPath, esmFile))
          errors.push(...validateReactionRateUnits(subsystem, subsystemPath))
        }
      }
    }
  }

  // Validate subsystem ref resolution
  errors.push(...validateSubsystemRefs(esmFile))

  // Validate coupling integrity
  errors.push(...validateCouplingIntegrity(esmFile))

  // Check for circular cross-model references
  errors.push(...validateCircularReferences(esmFile))

  // Validate data loader variable references in coupling
  errors.push(...validateDataLoaderReferences(esmFile))

  // Validate temporal resolution in data loaders
  errors.push(...validateTemporalResolution(esmFile))

  return errors
}

/**
 * Structured error code for an exception thrown by load(). Explicit mapping
 * (rather than deriving a code from the constructor name) so the codes are
 * stable strings that renames cannot silently change.
 */
function loadErrorCode(error: Error): string {
  if (error instanceof SchemaValidationError) return ERROR_CODES.SCHEMA_VALIDATION_ERROR
  if (error instanceof ParseError) return ERROR_CODES.PARSE_ERROR
  if (error instanceof EsmMachineryError) return ERROR_CODES.EXPRESSION_TEMPLATE_ERROR
  if (error instanceof EnumLoweringError) return ERROR_CODES.ENUM_LOWERING_ERROR
  if (error instanceof LosslessJsonParseError) return ERROR_CODES.JSON_PARSE_ERROR
  if (error instanceof CanonicalNonfiniteError) return ERROR_CODES.NONFINITE_NUMBER
  return ERROR_CODES.LOAD_ERROR
}

/**
 * Convert a SchemaError to our ValidationError format
 */
function convertSchemaError(error: SchemaError): ValidationError {
  return {
    path: error.path,
    message: error.message,
    code: error.keyword,
    details: {
      keyword: error.keyword,
    },
  }
}

/**
 * Validate ESM data and return structured validation result.
 *
 * @param data - ESM data as JSON string or object
 * @returns ValidationResult with validation status and errors
 */
export function validate(data: string | object): ValidationResult {
  const schema_errors: ValidationError[] = []
  const structural_errors: ValidationError[] = []
  const unit_warnings: UnitWarning[] = []

  try {
    let parsedData: object

    // Parse JSON if string, routing through the same `losslessJsonParse`
    // machinery `load()` uses rather than a divergent bare `JSON.parse`. The
    // tagged int/float leaves it produces are immediately stripped back to
    // plain JS numbers (`stripNumericLiterals`) so this non-canonical surface
    // (schema validation + `load(object)` below both expect plain numbers) is
    // unchanged from the previous `JSON.parse` result. A parse failure is
    // mapped to the historical `json_parse_error` envelope below — same `code`,
    // `path`, `details` shape, and `Invalid JSON: ` prefix — so the emitted
    // malformed-input diagnostic stays in the shape callers and
    // `validate.test.ts` expect.
    if (typeof data === 'string') {
      try {
        parsedData = stripNumericLiterals(losslessJsonParse(data)) as object
      } catch (e: unknown) {
        const error = e as Error
        return {
          is_valid: false,
          schema_errors: [
            {
              path: ROOT_PATH,
              message: `Invalid JSON: ${error.message}`,
              code: ERROR_CODES.JSON_PARSE_ERROR,
              details: { error: error.message },
            },
          ],
          structural_errors: [],
          unit_warnings: [],
        }
      }
    } else {
      parsedData = data
    }

    // Validate against schema
    const schemaErrors = validateSchema(parsedData)
    schema_errors.push(...schemaErrors.map(convertSchemaError))

    // Try structural validation by loading the data
    if (schema_errors.length === 0) {
      try {
        // Schema validation already ran above; collect unit warnings
        // from the load pipeline instead of re-running validateUnits.
        const esmFile = load(parsedData, {
          assumeValid: true,
          onUnitWarning: (warning) => unit_warnings.push(warning),
        })
        // Perform structural validation
        structural_errors.push(...performStructuralValidation(esmFile))

        // Promote unit incompatibility warnings to structural errors
        structural_errors.push(...promoteUnitWarningsToErrors(unit_warnings))
      } catch (e: unknown) {
        const error = e as Error
        structural_errors.push({
          path: ROOT_PATH,
          message: error.message || String(e),
          code: loadErrorCode(error),
          details: {
            exception_type: error.constructor.name,
            error: error.message || String(e),
          },
        })
      }
    }
  } catch (e: unknown) {
    // Unexpected error
    const error = e as Error
    return {
      is_valid: false,
      schema_errors: [
        {
          path: ROOT_PATH,
          message: `Validation failed with unexpected error: ${error.message || String(e)}`,
          code: ERROR_CODES.UNEXPECTED_ERROR,
          details: {
            exception_type: error.constructor.name,
            error: error.message || String(e),
          },
        },
      ],
      structural_errors: [],
      unit_warnings: [],
    }
  }

  return {
    is_valid: schema_errors.length === 0 && structural_errors.length === 0,
    schema_errors,
    structural_errors,
    unit_warnings,
  }
}
