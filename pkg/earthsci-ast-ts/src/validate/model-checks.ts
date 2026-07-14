/**
 * Structural validators that operate on a single Model: equation/unknown
 * balance, reference integrity, event consistency, and unit-related checks
 * (physical constants, conversion factors, default units).
 */

import { isExprNode } from '../expression.js'
import { ERROR_CODES } from '../errors.js'
import { parseUnit, tryParseUnit, dimsEqual, type ParsedUnit } from '../units.js'
import type { EsmFile, Model, Expression, AffectEquation } from '../types.js'
import type { StructuralError } from './types.js'
import {
  extractVariableReferences,
  collectIndexSymbols,
  lhsAssignmentTarget,
  countDerivatives,
  resolveScopedReference,
  expressionReferencesName,
} from './expr-utils.js'
import { isAffineTempUnit } from './unit-format.js'

/**
 * Check equation-unknown balance for a model
 */
export function validateEquationBalance(model: Model, modelPath: string): StructuralError[] {
  const errors: StructuralError[] = []

  // Count state variables
  const stateVariables = Object.entries(model.variables || {})
    .filter(([_, variable]) => variable.type === 'state')
    .map(([name, _]) => name)

  // Count equations driving each state variable. A normal ODE contributes a
  // D(var,t) derivative; an aggregate LHS contributes the derivative carried
  // in its contracted body. A relational / algebraic equation with no time
  // derivative (the aggregate-IR `index(v, i) = aggregate(...)` form emitted
  // by skolem / distinct / rank) instead credits the state variable its LHS
  // assigns to, so element-defined state still balances the unknown count.
  const derivativeCounts: { [variable: string]: number } = {}

  for (const equation of model.equations || []) {
    const lhsDerivatives = countDerivatives(equation.lhs)
    if (Object.keys(lhsDerivatives).length > 0) {
      for (const [variable, count] of Object.entries(lhsDerivatives)) {
        derivativeCounts[variable] = (derivativeCounts[variable] || 0) + count
      }
    } else {
      const target = lhsAssignmentTarget(equation.lhs)
      if (target !== undefined && stateVariables.includes(target)) {
        derivativeCounts[target] = (derivativeCounts[target] || 0) + 1
      }
    }
  }

  const odeEquationCount = Object.values(derivativeCounts).reduce((sum, count) => sum + count, 0)

  if (stateVariables.length !== odeEquationCount) {
    const missingEquations = stateVariables.filter((varName) => !(varName in derivativeCounts))

    errors.push({
      path: modelPath,
      code: ERROR_CODES.EQUATION_COUNT_MISMATCH,
      message: `Number of ODE equations (${odeEquationCount}) does not match number of state variables (${stateVariables.length})`,
      details: {
        state_variables: stateVariables,
        ode_equations: odeEquationCount,
        missing_equations_for: missingEquations,
      },
    })
  }

  return errors
}

/**
 * Check reference integrity for a model
 */
export function validateReferenceIntegrity(
  model: Model,
  modelPath: string,
  esmFile: EsmFile,
): StructuralError[] {
  const errors: StructuralError[] = []
  const declaredVariables = new Set(Object.keys(model.variables || {}))
  // Declared index sets are a legitimate, non-variable identifier namespace
  // (RFC semiring-faq-unified-ir §5.2). An `aggregate` may name an index set
  // as a positional operand — the value-invention form
  // `aggregate(args:["faces"], ...)` enumerates over the `faces` set itself
  // (the mesh-edge enumeration of ess-my4.3.10 / §7.3). Such a name is not a
  // declared variable, so credit the document-scoped `index_sets` keys here,
  // exactly as the binder symbols below credit aggregate range / `index`
  // positions (the aggregate-aware fix of ess-my4.1.7). A genuinely-undefined
  // reference still matches neither set and is flagged. As of v0.8.0 the
  // `index_sets` registry is a single, document-level field shared by every
  // model (a sibling of `models` / `domain`), not a per-model field.
  const declaredIndexSets = new Set(Object.keys(esmFile.index_sets || {}))

  // Check equations
  for (let i = 0; i < (model.equations || []).length; i++) {
    const equation = model.equations![i]
    const equationPath = `${modelPath}/equations/${i}`

    // Binder-introduced index / contraction symbols (aggregate ranges and
    // output indices, `index` element positions) are iteration positions,
    // not declared variables — collect them so they are not flagged as
    // undefined references below.
    const boundSymbols = new Set<string>([
      ...collectIndexSymbols(equation.lhs),
      ...collectIndexSymbols(equation.rhs),
    ])

    const checkSide = (expr: Expression, sidePath: string): void => {
      for (const varRef of extractVariableReferences(expr)) {
        if (varRef.includes('.')) {
          // Scoped reference
          if (!resolveScopedReference(varRef, esmFile)) {
            errors.push({
              path: sidePath,
              code: ERROR_CODES.UNRESOLVED_SCOPED_REF,
              message: `Scoped reference "${varRef}" cannot be resolved`,
              details: { reference: varRef },
            })
          }
        } else if (
          !declaredVariables.has(varRef) &&
          !declaredIndexSets.has(varRef) &&
          !boundSymbols.has(varRef)
        ) {
          // Local reference
          errors.push({
            path: sidePath,
            code: ERROR_CODES.UNDEFINED_VARIABLE,
            message: `Variable "${varRef}" referenced in equation is not declared`,
            details: { variable: varRef },
          })
        }
      }
    }

    checkSide(equation.lhs, `${equationPath}/lhs`)
    checkSide(equation.rhs, `${equationPath}/rhs`)
  }

  // Check observed variables have expressions
  for (const [varName, variable] of Object.entries(model.variables || {})) {
    if (variable.type === 'observed' && !variable.expression) {
      errors.push({
        path: `${modelPath}/variables/${varName}`,
        code: ERROR_CODES.MISSING_OBSERVED_EXPR,
        message: `Observed variable "${varName}" is missing its expression field`,
        details: { variable: varName },
      })
    }
  }

  return errors
}

/**
 * Flag affect-equation LHS targets that are not declared variables. Shared by
 * the discrete-event `affects`, continuous-event `affects`, and continuous-event
 * `affect_neg` loops, which are byte-identical apart from the array path segment
 * and the human-readable context phrase.
 *
 * `phrase` is interpolated verbatim into the message, preserving the historical
 * per-site wording — "event affects" vs "continuous event affects" vs
 * "continuous event affect_neg" — which the cross-language goldens pin, so it is
 * NOT unified. `basePath` is the array's JSON path (e.g. `.../affects`); the
 * per-element `/${j}/lhs` suffix is appended here.
 */
function checkAffectTargets(
  affects: AffectEquation[] | null | undefined,
  declaredVariables: Set<string>,
  basePath: string,
  phrase: string,
): StructuralError[] {
  const errors: StructuralError[] = []
  if (!affects) return errors
  for (let j = 0; j < affects.length; j++) {
    const affect = affects[j]
    if (!declaredVariables.has(affect.lhs)) {
      errors.push({
        path: `${basePath}/${j}/lhs`,
        code: ERROR_CODES.EVENT_VAR_UNDECLARED,
        message: `Variable "${affect.lhs}" in ${phrase} is not declared`,
        details: { variable: affect.lhs },
      })
    }
  }
  return errors
}

/**
 * Check discrete parameters in events
 */
export function validateEventConsistency(model: Model, modelPath: string): StructuralError[] {
  const errors: StructuralError[] = []
  const declaredVariables = new Set(Object.keys(model.variables || {}))
  const declaredParameters = new Set(
    Object.entries(model.variables || {})
      .filter(([_, variable]) => variable.type === 'parameter')
      .map(([name, _]) => name),
  )

  // Check discrete events
  for (let i = 0; i < (model.discrete_events || []).length; i++) {
    const event = model.discrete_events![i]
    const eventPath = `${modelPath}/discrete_events/${i}`

    // Check discrete_parameters entries
    if (event.discrete_parameters) {
      for (const paramName of event.discrete_parameters) {
        if (!declaredParameters.has(paramName)) {
          errors.push({
            path: `${eventPath}/discrete_parameters`,
            code: ERROR_CODES.INVALID_DISCRETE_PARAM,
            message: `discrete_parameters entry "${paramName}" does not match a declared parameter`,
            details: { parameter: paramName },
          })
        }
      }
    }

    // Check affects variables
    errors.push(
      ...checkAffectTargets(
        event.affects,
        declaredVariables,
        `${eventPath}/affects`,
        'event affects',
      ),
    )

    // Check functional affect variables
    if (event.functional_affect) {
      for (const varName of event.functional_affect.read_vars || []) {
        if (!declaredVariables.has(varName)) {
          errors.push({
            path: `${eventPath}/functional_affect/read_vars`,
            code: ERROR_CODES.EVENT_VAR_UNDECLARED,
            message: `Variable "${varName}" in functional_affect read_vars is not declared`,
            details: { variable: varName },
          })
        }
      }

      for (const paramName of event.functional_affect.read_params || []) {
        if (!declaredParameters.has(paramName)) {
          errors.push({
            path: `${eventPath}/functional_affect/read_params`,
            code: ERROR_CODES.EVENT_VAR_UNDECLARED,
            message: `Parameter "${paramName}" in functional_affect read_params is not declared`,
            details: { variable: paramName },
          })
        }
      }
    }
  }

  // Check continuous events
  for (let i = 0; i < (model.continuous_events || []).length; i++) {
    const event = model.continuous_events![i]
    const eventPath = `${modelPath}/continuous_events/${i}`

    // Check affects variables
    errors.push(
      ...checkAffectTargets(
        event.affects,
        declaredVariables,
        `${eventPath}/affects`,
        'continuous event affects',
      ),
    )

    // Check affect_neg variables
    errors.push(
      ...checkAffectTargets(
        event.affect_neg,
        declaredVariables,
        `${eventPath}/affect_neg`,
        'continuous event affect_neg',
      ),
    )
  }

  return errors
}

/**
 * Well-known physical constants whose declared units can be dimensionally
 * verified against a canonical form. Conservative on purpose — names chosen
 * to minimize collision with common non-constant uses (e.g., no `c` for
 * speed of light, which conflicts with concentration). Mirrors Python's
 * `_KNOWN_PHYSICAL_CONSTANTS` (gt-j91l / gt-3tgv).
 */
const KNOWN_PHYSICAL_CONSTANTS: Array<{
  name: string
  canonical: string
  description: string
}> = [
  { name: 'R', canonical: 'J/(mol*K)', description: 'ideal gas constant' },
  { name: 'k_B', canonical: 'J/K', description: 'Boltzmann constant' },
  { name: 'N_A', canonical: '1/mol', description: 'Avogadro constant' },
]

/**
 * Flag parameters whose name matches a well-known physical constant but whose
 * declared units are dimensionally incompatible with the canonical form (e.g.,
 * `R` declared as `kcal/mol` — missing temperature — instead of `J/(mol*K)`).
 * Reports at the first observed-variable usage site in the same model;
 * otherwise at the declaration. Mirrors Python's
 * `parse._check_physical_constant_units`.
 */
export function validatePhysicalConstantUnits(model: Model, modelPath: string): StructuralError[] {
  const errors: StructuralError[] = []
  const variables = model.variables || {}

  for (const { name, canonical, description } of KNOWN_PHYSICAL_CONSTANTS) {
    const declaration = variables[name]
    if (!declaration) continue
    if (declaration.type !== 'parameter') continue
    const declared = declaration.units
    if (!declared) continue

    // An unparseable declaration is INDETERMINATE, not "different from
    // canonical" — we cannot prove a mismatch against a dimension we could not
    // read, so skip rather than report. (`parseUnit` is strict and would throw;
    // `tryParseUnit` is the fallible form.)
    const declaredUnit = tryParseUnit(declared)
    const canonicalUnit = tryParseUnit(canonical)
    if (declaredUnit === null || canonicalUnit === null) continue
    if (dimsEqual(declaredUnit.dims, canonicalUnit.dims)) continue

    let usageName: string | undefined
    for (const [otherName, otherVar] of Object.entries(variables)) {
      if (otherVar.type !== 'observed') continue
      if (expressionReferencesName(otherVar.expression, name)) {
        usageName = otherName
        break
      }
    }
    const targetName = usageName ?? name
    errors.push({
      path: `${modelPath}/variables/${targetName}`,
      code: ERROR_CODES.UNIT_INCONSISTENCY,
      message: 'Physical constant used with incorrect dimensional analysis',
      details: {
        constant_name: name,
        constant_description: description,
        declared_units: declared,
        canonical_units: canonical,
      },
    })
  }
  return errors
}

/**
 * Flag observed variables whose expression has the shape `<numeric> * <var>`
 * (or `<var> * <numeric>`) when the declared output units and the source
 * variable's units are dimensionally compatible but the numeric literal
 * disagrees with the correct linear scale factor. Mirrors Python's
 * parse._check_conversion_factor_consistency (gt-nvdv) and Go's
 * checkConversionFactorConsistency (gt-abh1). Affine conversions
 * (e.g., degC→K) are excluded.
 */
export function validateConversionFactorConsistency(
  model: Model,
  modelPath: string,
): StructuralError[] {
  const errors: StructuralError[] = []
  const variables = model.variables || {}

  for (const [vname, vdef] of Object.entries(variables)) {
    if (vdef.type !== 'observed') continue
    if (vdef.expression === undefined || vdef.expression === null) continue
    const lhsUnits = vdef.units
    if (!lhsUnits) continue

    const expr = vdef.expression
    if (!isExprNode(expr)) continue
    const node = expr
    if (node.op !== '*' || !node.args || node.args.length !== 2) continue

    let numeric: number | undefined
    let varRef: string | undefined
    for (const a of node.args) {
      if (typeof a === 'number') {
        numeric = a
      } else if (typeof a === 'string') {
        varRef = a
      }
    }
    if (numeric === undefined || varRef === undefined) continue

    const src = variables[varRef]
    if (!src || !src.units) continue
    const srcUnits = src.units
    if (srcUnits === lhsUnits) continue

    let srcU: ParsedUnit
    let lhsU: ParsedUnit
    try {
      srcU = parseUnit(srcUnits)
      lhsU = parseUnit(lhsUnits)
    } catch {
      continue
    }
    if (!dimsEqual(srcU.dims, lhsU.dims)) continue
    if (isAffineTempUnit(srcUnits) || isAffineTempUnit(lhsUnits)) continue
    if (lhsU.scale === 0) continue

    const factor = srcU.scale / lhsU.scale
    if (factor === 0) continue

    const tol = 1e-9 * Math.max(Math.abs(factor), 1)
    if (Math.abs(numeric - factor) <= tol) continue

    errors.push({
      path: `${modelPath}/variables/${vname}`,
      code: ERROR_CODES.UNIT_INCONSISTENCY,
      message: 'Unit conversion factor is incorrect for specified unit transformation',
      details: {
        variable: vname,
        declared_units: lhsUnits,
        source_units: srcUnits,
        declared_factor: numeric,
        expected_factor: factor,
      },
    })
  }
  return errors
}

/**
 * Flag model variables where default_units is set and the conversion from
 * default_units to units is affine (e.g., degC → K) rather than a pure
 * scale factor. Affine unit conversions are not expressible as a simple
 * default value and must use an explicit expression instead.
 */
export function validateDefaultUnits(model: Model, modelPath: string): StructuralError[] {
  const errors: StructuralError[] = []
  if (!model.variables) return errors
  for (const [vname, vdef] of Object.entries(model.variables)) {
    const { units, default_units } = vdef
    if (!default_units || !units || default_units === units) continue
    if (isAffineTempUnit(default_units) || isAffineTempUnit(units)) {
      errors.push({
        path: `${modelPath}/variables/${vname}`,
        code: ERROR_CODES.UNIT_INCONSISTENCY,
        message: `default_units '${default_units}' requires an affine conversion to/from '${units}'; use an expression instead of a scalar default`,
        details: { variable: vname, units, default_units },
      })
    }
  }
  return errors
}
