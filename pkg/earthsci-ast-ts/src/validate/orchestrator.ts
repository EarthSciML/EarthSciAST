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
import { CircularReferenceError, RefLoadError, resolveSubsystemRefsSync } from '../ref-loading.js'
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
  implicitNames,
  validateEquationBalance,
  validateReferenceIntegrity,
  validateEventConsistency,
  validatePhysicalConstantUnits,
  validateConversionFactorConsistency,
  validateDefaultUnits,
} from './model-checks.js'
import {
  validateReactionConsistency,
  validateReactionReferenceIntegrity,
  validateReactionRateUnits,
  validateReactionSystemICs,
} from './reaction-checks.js'
import {
  validateSubsystemRefs,
  validateCouplingIntegrity,
  validateCircularReferences,
  validateDataLoaderReferences,
  validateDataLoaderExpressions,
  validateCouplingExpressions,
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
    // is used verbatim. Root token is the shared `ROOT_PATH` (the empty-string
    // document-root JSON Pointer), used only
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

      // Equation balance exempts a coupled model: its unknowns may be driven by
      // equations another system contributes, so counting locally is meaningless.
      if (!isCoupled) {
        errors.push(...validateEquationBalance(model, modelPath))
      }
      // An OPERATOR-COMPOSED model is exempt from reference integrity, and the
      // exemption is semantically required rather than a convenience: such a
      // model is written against a GENERIC state it does not declare, under a
      // placeholder name the AUTHOR chooses. `tests/valid/minimal_chemistry.esm`
      // is the canonical case — its `Advection` operator declares only
      // `u_wind`/`v_wind` and writes `D(u)/dt = -u_wind*grad(u,x) + …`, where `u`
      // is the field composition will substitute. No local declaration-site union
      // can decide `u`, because the name is arbitrary. (§6.4 blesses `_var` for
      // this; the flagship fixture uses `u` — see the report.)
      //
      // A CALLBACK target is NOT exempt: its injected names are knowable, so it
      // is checked against them (see `declaredNamesFor` site 6). That is the (k)
      // fix — `callback_examples.esm` was falsely rejected because the names its
      // callback injects were not credited anywhere.
      if (!isCoupled) {
        errors.push(...validateReferenceIntegrity(model, modelPath, esmFile, modelName, isCoupled))
      }

      // `isCoupled` also admits the §6.4 `_var` placeholder as an event-affect
      // target.
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
          }
          if (!isCoupled) {
            errors.push(
              ...validateReferenceIntegrity(
                subsystem,
                subsystemPath,
                esmFile,
                subsystemName,
                isCoupled,
              ),
            )
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
      // (h) A reaction system's constraint_equations and events are expression
      // positions too, and were never reference-checked.
      errors.push(
        ...validateReactionReferenceIntegrity(
          reactionSystem,
          systemPath,
          esmFile,
          implicitNames(esmFile),
        ),
      )
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

  // (h) sites 9-11: the expression positions outside any component — a data
  // loader's `unit_conversion`, a coupling `transform`, a connector equation.
  errors.push(...validateDataLoaderExpressions(esmFile))
  errors.push(...validateCouplingExpressions(esmFile))

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
  // A ref that would not resolve carries the canonical code the resolver decided
  // on (`unresolved_subsystem_ref` when the target is missing or unreadable,
  // `ambiguous_subsystem_ref` when it holds more than one component) — the
  // resolver is the only layer that opened the file, so it is the only layer that
  // can tell those apart.
  if (error instanceof RefLoadError) return error.code
  if (error instanceof CircularReferenceError) return ERROR_CODES.CIRCULAR_DEPENDENCY
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
 * Options for {@link validate}.
 */
export interface ValidateOptions {
  /**
   * Base directory that relative `{ref}` targets and `expression_template_imports`
   * resolve against — normally the directory of the file being validated.
   *
   * WITHOUT it, `validate()` does no file I/O: it cannot open a ref target, so it
   * cannot know whether that target exists, and every `{ref}` subsystem is
   * reported as `unresolved_subsystem_ref`. That is a truthful answer (the
   * document has an unresolved mount) but a useless one for a caller who has the
   * file on disk and simply wants it validated — and it makes every subsystem-ref
   * and template-import pin in the shared corpus unsatisfiable, because a
   * MISSING target and a PRESENT one produce the identical verdict.
   *
   * WITH it, refs are resolved (recursively, including the §4.7 index-set merge
   * and §9.7 template machinery) before structural validation runs: a present
   * target validates through, and a missing one yields `unresolved_subsystem_ref`
   * — the two are now distinguishable, which is the whole point.
   *
   * Only LOCAL paths resolve here, because `validate()` is synchronous and
   * `fetch` cannot be awaited; a remote (`http(s)://`) ref is reported as
   * unresolved with a message pointing at the async `resolveSubsystemRefs()`.
   */
  basePath?: string
}

/**
 * Validate ESM data and return structured validation result.
 *
 * @param data - ESM data as JSON string or object
 * @param options - Optional {@link ValidateOptions}; pass `basePath` to let
 *   relative `{ref}` / template-import targets be opened and resolved.
 * @returns ValidationResult with validation status and errors
 */
export function validate(data: string | object, options: ValidateOptions = {}): ValidationResult {
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
          basePath: options.basePath,
          onUnitWarning: (warning) => unit_warnings.push(warning),
        })

        // With a `basePath`, open and inline the `{ref}` mounts before checking
        // anything: an unresolved stub declares no variables, so validating
        // around one reports phantom `unresolved_scoped_ref`s for names the
        // mounted component really does provide. A failure here (missing target,
        // ambiguous target, cycle) is a real diagnostic and is reported with the
        // resolver's own code by the catch below.
        if (options.basePath !== undefined) {
          resolveSubsystemRefsSync(esmFile, options.basePath)
        }

        // Perform structural validation
        structural_errors.push(...performStructuralValidation(esmFile))

        // Promote unit incompatibility warnings to structural errors
        structural_errors.push(...promoteUnitWarningsToErrors(unit_warnings))
      } catch (e: unknown) {
        const error = e as Error
        structural_errors.push({
          // A resolver failure knows WHICH MOUNT broke, so report it there
          // (`/models/ClimateModel/subsystems/Atm`) rather than at the document
          // root — that is the path the shared corpus pins.
          path: error instanceof RefLoadError ? error.path : ROOT_PATH,
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
