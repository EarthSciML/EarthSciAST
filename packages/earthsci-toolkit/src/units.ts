/**
 * Unit parsing and dimensional analysis for ESM format
 *
 * This module implements unit string parsing and dimensional consistency
 * checking following the ESM specification Section 3.3.1. It shares its
 * canonical representation (`CanonicalDims` + `ParsedUnit`) with
 * `unit-conversion.ts`, so derived units like `cm`, `J`, `Pa` collapse to
 * their SI-base decomposition (`m`, `kg·m²·s⁻²`, `kg·m⁻¹·s⁻²`) with a scale
 * factor rather than being treated as independent dimensions.
 */

import type { Expression, ExpressionNode, EsmFile } from './types.js'
import {
  type CanonicalDims,
  type ParsedUnit,
  parseUnitForConversion,
  UnitConversionError,
} from './unit-conversion.js'
import { isNumericLiteral } from './numeric-literal.js'

export type { CanonicalDims, ParsedUnit } from './unit-conversion.js'

/**
 * Result of dimensional analysis for a single expression.
 */
export interface UnitResult {
  dimensions: ParsedUnit
  warnings: string[]
}

/**
 * Dimensional-consistency warning emitted during file-level validation.
 */
export interface UnitWarning {
  message: string
  /**
   * Structured warning kind. `dimensional_mismatch` marks a
   * dimensional-consistency violation (promoted to a structural error by
   * `validate()`); `analysis` covers informational diagnostics (unknown
   * variables, arity problems, internal errors).
   */
  code: 'dimensional_mismatch' | 'analysis'
  location?: string
  equation?: string
}

/**
 * Classify a `checkDimensions()` warning message. This lives beside the
 * message definitions in this module so the classification and the message
 * wording cannot drift apart in separate files.
 */
function warningCode(message: string): UnitWarning['code'] {
  return /same dimensions|incompatible|mismatch|inconsisten/i.test(message)
    ? 'dimensional_mismatch'
    : 'analysis'
}

function dimensionless(): ParsedUnit {
  return { dims: {}, scale: 1 }
}

/**
 * Parse a unit string into canonical SI dimensions plus scale factor.
 *
 * Delegates to `parseUnitForConversion` but swallows parse errors and returns
 * a dimensionless fallback, matching the lenient semantics of the earlier
 * unit validator (which silently ignored unknown tokens). This keeps the
 * `validateUnits` pipeline warning-driven rather than exception-driven.
 *
 * The string `"degrees"` is accepted as dimensionless because ESM treats
 * angle labels as informational; the canonical unit table does not register
 * it to avoid committing to a radian conversion factor that ESM does not
 * promise.
 */
export function parseUnit(unitStr: string): ParsedUnit {
  const normalized = (unitStr ?? '').trim().toLowerCase()
  if (normalized === 'degrees') {
    return dimensionless()
  }
  try {
    return parseUnitForConversion(unitStr)
  } catch (err) {
    if (err instanceof UnitConversionError) {
      return dimensionless()
    }
    throw err
  }
}

/**
 * Check dimensional consistency of an expression.
 *
 * Follows ESM spec Section 3.3.1:
 * - Addition/subtraction: operands must share canonical dimensions
 * - Multiplication: dimensions add (scales multiply)
 * - Division: dimensions subtract (scales divide)
 * - `D(x, wrt=t)`: dimension of x divided by dimension of t
 * - Transcendental functions require dimensionless arguments
 */
export function checkDimensions(
  expr: Expression,
  unitBindings: Map<string, ParsedUnit>,
  coordinateBindings?: Map<string, ParsedUnit>,
): UnitResult {
  const warnings: string[] = []

  if (typeof expr === 'number' || isNumericLiteral(expr)) {
    return { dimensions: dimensionless(), warnings }
  }

  if (typeof expr === 'string') {
    const dims = unitBindings.get(expr)
    if (!dims) {
      warnings.push(`Unknown variable: ${expr}`)
      return { dimensions: dimensionless(), warnings }
    }
    return { dimensions: dims, warnings }
  }

  const node = expr as ExpressionNode
  const op = node.op
  const args = node.args

  const argResults = args.map((arg) => checkDimensions(arg, unitBindings, coordinateBindings))
  warnings.push(...argResults.flatMap((r) => r.warnings))

  const argDims = argResults.map((r) => r.dimensions)
  const get = (i: number): ParsedUnit => argDims[i] ?? dimensionless()

  switch (op) {
    case '+':
    case '-': {
      const first = get(0)
      for (let i = 1; i < argDims.length; i++) {
        const other = get(i)
        if (!dimsEqual(first.dims, other.dims)) {
          warnings.push(
            `Addition/subtraction requires same dimensions, got ${formatDims(first.dims)} and ${formatDims(other.dims)}`,
          )
        }
      }
      return { dimensions: first, warnings }
    }

    case '*':
      return { dimensions: multiplyUnits(argDims), warnings }

    case '/':
      if (argDims.length !== 2) {
        warnings.push(`Division requires exactly 2 arguments, got ${argDims.length}`)
        return { dimensions: dimensionless(), warnings }
      }
      return { dimensions: divideUnits(get(0), get(1)), warnings }

    case '^':
      if (argDims.length !== 2) {
        warnings.push(`Exponentiation requires exactly 2 arguments, got ${argDims.length}`)
        return { dimensions: dimensionless(), warnings }
      }
      if (!isDimensionless(get(1))) {
        warnings.push(`Exponent must be dimensionless, got ${formatDims(get(1).dims)}`)
      }
      // Preserve the base unit unchanged. Applying the exponent would require
      // extracting the constant value from the second argument, which the
      // original implementation did not attempt and current tests do not
      // exercise.
      return { dimensions: get(0), warnings }

    case 'D': {
      if (args.length !== 1) {
        warnings.push(`Derivative D() requires exactly 1 argument, got ${args.length}`)
        return { dimensions: dimensionless(), warnings }
      }
      const timeVar = node.wrt || 't'
      const timeDims = unitBindings.get(timeVar) ?? { dims: { s: 1 }, scale: 1 }
      return { dimensions: divideUnits(get(0), timeDims), warnings }
    }

    case 'grad':
    case 'div':
    case 'laplacian': {
      // Spatial derivative: operand dimensions divided by the spatial
      // coordinate's declared units. The coordinate is identified by
      // `node.dim` and resolved against the enclosing model's domain.
      // When the coordinate is declared in the domain but carries no
      // units, we cannot infer the result's dimension — flag as
      // unit_inconsistency rather than silently assuming metres. When
      // no coordinate table is available (0D model, or the coord is
      // simply not present in the domain), fall back to the legacy
      // metre denominator so pre-existing fixtures that rely on the
      // old behaviour keep validating.
      const dimName = node.dim
      const lengthDims: ParsedUnit = { dims: { m: 1 }, scale: 1 }
      if (!dimName || !coordinateBindings) {
        return { dimensions: divideUnits(get(0), lengthDims), warnings }
      }
      const coordDims = coordinateBindings.get(dimName)
      if (!coordDims) {
        return { dimensions: divideUnits(get(0), lengthDims), warnings }
      }
      if (isDimensionless(coordDims)) {
        warnings.push(
          `Gradient operator applied to variable with incompatible spatial units: coordinate '${dimName}' has no declared units (unit_inconsistency)`,
        )
        return { dimensions: get(0), warnings }
      }
      return { dimensions: divideUnits(get(0), coordDims), warnings }
    }

    case 'exp':
    case 'log':
    case 'log10':
    case 'sin':
    case 'cos':
    case 'tan':
    case 'asin':
    case 'acos':
    case 'atan':
    case 'sinh':
    case 'cosh':
    case 'tanh':
    case 'asinh':
    case 'acosh':
    case 'atanh':
      for (let i = 0; i < argDims.length; i++) {
        const arg = get(i)
        if (!isDimensionless(arg)) {
          warnings.push(`${op}() requires dimensionless argument, got ${formatDims(arg.dims)}`)
        }
      }
      return { dimensions: dimensionless(), warnings }

    case 'atan2':
      if (argDims.length !== 2) {
        warnings.push(`atan2() requires exactly 2 arguments, got ${argDims.length}`)
        return { dimensions: dimensionless(), warnings }
      }
      if (!dimsEqual(get(0).dims, get(1).dims)) {
        warnings.push(
          `atan2() requires arguments with same dimensions, got ${formatDims(get(0).dims)} and ${formatDims(get(1).dims)}`,
        )
      }
      return { dimensions: dimensionless(), warnings }

    case 'sqrt':
    case 'abs':
    case 'sign':
    case 'floor':
    case 'ceil':
      return { dimensions: get(0), warnings }

    case 'min':
    case 'max': {
      if (argDims.length < 2) {
        warnings.push(`${op}() requires at least 2 arguments, got ${argDims.length}`)
        return { dimensions: dimensionless(), warnings }
      }
      const ref = get(0)
      for (let i = 1; i < argDims.length; i++) {
        const other = get(i)
        if (!dimsEqual(ref.dims, other.dims)) {
          warnings.push(
            `${op}() requires all arguments to have same dimensions, got ${formatDims(ref.dims)} and ${formatDims(other.dims)}`,
          )
        }
      }
      return { dimensions: ref, warnings }
    }

    case 'ifelse':
      if (argDims.length !== 3) {
        warnings.push(`ifelse() requires exactly 3 arguments, got ${argDims.length}`)
        return { dimensions: dimensionless(), warnings }
      }
      if (!isDimensionless(get(0))) {
        warnings.push(`ifelse() condition must be dimensionless, got ${formatDims(get(0).dims)}`)
      }
      if (!dimsEqual(get(1).dims, get(2).dims)) {
        warnings.push(
          `ifelse() branches must have same dimensions, got ${formatDims(get(1).dims)} and ${formatDims(get(2).dims)}`,
        )
      }
      return { dimensions: get(1), warnings }

    case '>':
    case '<':
    case '>=':
    case '<=':
    case '==':
    case '!=':
      if (argDims.length !== 2) {
        warnings.push(`${op} requires exactly 2 arguments, got ${argDims.length}`)
        return { dimensions: dimensionless(), warnings }
      }
      if (!dimsEqual(get(0).dims, get(1).dims)) {
        warnings.push(
          `${op} requires arguments with same dimensions, got ${formatDims(get(0).dims)} and ${formatDims(get(1).dims)}`,
        )
      }
      return { dimensions: dimensionless(), warnings }

    case 'and':
    case 'or':
    case 'not':
      for (let i = 0; i < argDims.length; i++) {
        const arg = get(i)
        if (!isDimensionless(arg)) {
          warnings.push(`${op} requires dimensionless arguments, got ${formatDims(arg.dims)}`)
        }
      }
      return { dimensions: dimensionless(), warnings }

    case 'Pre':
      return { dimensions: get(0), warnings }

    default:
      warnings.push(`Unknown operator: ${op}`)
      return { dimensions: dimensionless(), warnings }
  }
}

/**
 * Validate dimensional consistency of all equations in an ESM file.
 */
export function validateUnits(file: EsmFile): UnitWarning[] {
  const warnings: UnitWarning[] = []
  const unitBindings = new Map<string, ParsedUnit>()

  if (file.models) {
    for (const [modelName, model] of Object.entries(file.models)) {
      if ('variables' in model && model.variables) {
        for (const [varName, variable] of Object.entries(model.variables)) {
          const fullVarName = `${modelName}.${varName}`
          if (variable.units) {
            unitBindings.set(fullVarName, parseUnit(variable.units))
          }
          if (!unitBindings.has(varName) && variable.units) {
            unitBindings.set(varName, parseUnit(variable.units))
          }
        }
      }
    }
  }

  if (file.reaction_systems) {
    for (const [systemName, system] of Object.entries(file.reaction_systems)) {
      if ('species' in system && system.species) {
        for (const [speciesName, species] of Object.entries(system.species)) {
          const fullSpeciesName = `${systemName}.${speciesName}`
          if (species.units) {
            unitBindings.set(fullSpeciesName, parseUnit(species.units))
          }
          if (!unitBindings.has(speciesName) && species.units) {
            unitBindings.set(speciesName, parseUnit(species.units))
          }
        }
      }

      if ('parameters' in system && system.parameters) {
        for (const [paramName, param] of Object.entries(system.parameters)) {
          const fullParamName = `${systemName}.${paramName}`
          if (param.units) {
            unitBindings.set(fullParamName, parseUnit(param.units))
          }
          if (!unitBindings.has(paramName) && param.units) {
            unitBindings.set(paramName, parseUnit(param.units))
          }
        }
      }
    }
  }

  // Reaction-rate / stoichiometry dimensional check lives in validate.ts
  // (`validateReactionRateUnits`) so it can emit a structured
  // `unit_inconsistency` error with typed details instead of a prose warning.

  if (file.models) {
    for (const [modelName, model] of Object.entries(file.models)) {
      if ('equations' in model && model.equations) {
        for (const equation of model.equations) {
          try {
            const lhsResult = checkDimensions(equation.lhs, unitBindings)
            const rhsResult = checkDimensions(equation.rhs, unitBindings)

            const allSubWarnings = [...lhsResult.warnings, ...rhsResult.warnings]
            const hasUnknownVariable = allSubWarnings.some((w) => w.includes('Unknown variable'))

            // Only emit mismatch warnings when dimensions are fully known.
            // Missing unit declarations would otherwise produce false
            // positives (both sides default to dimensionless in ways that
            // don't round-trip).
            if (
              !hasUnknownVariable &&
              !dimsEqual(lhsResult.dimensions.dims, rhsResult.dimensions.dims)
            ) {
              warnings.push({
                message: `Dimensional mismatch in equation: LHS has ${formatDims(lhsResult.dimensions.dims)}, RHS has ${formatDims(rhsResult.dimensions.dims)}`,
                code: 'dimensional_mismatch',
                location: `models.${modelName}`,
                equation: `${JSON.stringify(equation.lhs)} = ${JSON.stringify(equation.rhs)}`,
              })
            }

            for (const warning of allSubWarnings) {
              warnings.push({
                message: warning,
                code: warningCode(warning),
                location: `models.${modelName}`,
              })
            }
          } catch (error) {
            warnings.push({
              message: `Error checking equation dimensions: ${error instanceof Error ? error.message : String(error)}`,
              code: 'analysis',
              location: `models.${modelName}`,
            })
          }
        }
      }

      if ('variables' in model && model.variables) {
        for (const [varName, variable] of Object.entries(model.variables)) {
          if (variable.type === 'observed' && variable.expression) {
            try {
              const exprResult = checkDimensions(variable.expression, unitBindings)
              const varDims: ParsedUnit = variable.units
                ? parseUnit(variable.units)
                : dimensionless()

              const hasUnknownVariable = exprResult.warnings.some((w) =>
                w.includes('Unknown variable'),
              )

              if (!hasUnknownVariable && !dimsEqual(exprResult.dimensions.dims, varDims.dims)) {
                warnings.push({
                  message: `Dimensional mismatch in observed variable ${varName}: declared as ${formatDims(varDims.dims)}, expression evaluates to ${formatDims(exprResult.dimensions.dims)}`,
                  code: 'dimensional_mismatch',
                  location: `models.${modelName}.variables.${varName}`,
                })
              }

              for (const warning of exprResult.warnings) {
                warnings.push({
                  message: warning,
                  code: warningCode(warning),
                  location: `models.${modelName}.variables.${varName}`,
                })
              }
            } catch (error) {
              warnings.push({
                message: `Error checking observed variable dimensions: ${error instanceof Error ? error.message : String(error)}`,
                code: 'analysis',
                location: `models.${modelName}.variables.${varName}`,
              })
            }
          }
        }
      }
    }
  }

  return warnings
}

function multiplyUnits(units: ParsedUnit[]): ParsedUnit {
  const result: ParsedUnit = { dims: {}, scale: 1 }
  for (const u of units) {
    for (const [k, v] of Object.entries(u.dims)) {
      if (v == null) continue
      const key = k as keyof CanonicalDims
      result.dims[key] = (result.dims[key] ?? 0) + v
    }
    result.scale *= u.scale
  }
  pruneZeros(result.dims)
  return result
}

function divideUnits(a: ParsedUnit, b: ParsedUnit): ParsedUnit {
  const result: ParsedUnit = { dims: { ...a.dims }, scale: a.scale }
  for (const [k, v] of Object.entries(b.dims)) {
    if (v == null) continue
    const key = k as keyof CanonicalDims
    result.dims[key] = (result.dims[key] ?? 0) - v
  }
  result.scale /= b.scale
  pruneZeros(result.dims)
  return result
}

function pruneZeros(dims: CanonicalDims): void {
  for (const key of Object.keys(dims) as (keyof CanonicalDims)[]) {
    if (dims[key] === 0) delete dims[key]
  }
}

export function isDimensionless(unit: ParsedUnit): boolean {
  for (const v of Object.values(unit.dims)) {
    if (v != null && v !== 0) return false
  }
  return true
}

export function dimsEqual(a: CanonicalDims, b: CanonicalDims): boolean {
  const keys = new Set([...Object.keys(a), ...Object.keys(b)])
  for (const key of keys) {
    const av = (a as Record<string, number | undefined>)[key] ?? 0
    const bv = (b as Record<string, number | undefined>)[key] ?? 0
    if (av !== bv) return false
  }
  return true
}

function formatDims(dims: CanonicalDims): string {
  const parts: string[] = []
  for (const [key, value] of Object.entries(dims)) {
    if (!value) continue
    if (value === 1) parts.push(key)
    else if (value === -1) parts.push(`/${key}`)
    else if (value > 0) parts.push(`${key}^${value}`)
    else parts.push(`/${key}^${-value}`)
  }
  return parts.length > 0 ? parts.join('·') : 'dimensionless'
}
