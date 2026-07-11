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

import type { Expression, ExpressionNode, EsmFile, Model } from './types.js'
import {
  type CanonicalDims,
  type ParsedUnit,
  parseUnitForConversion,
  UnitConversionError,
} from './unit-conversion.js'
import { isNumericLiteral } from './numeric-literal.js'
import { getOpInfo } from './op-registry.js'
import { forEachComponent, forEachEquation } from './traverse.js'

export type { CanonicalDims, ParsedUnit } from './unit-conversion.js'

/**
 * A single dimensional-analysis diagnostic: the message plus the classification
 * decided AT THE POINT it was raised (see {@link UnitWarning.code}). The code is
 * explicit rather than recovered from the prose, so rewording a message can
 * never silently flip a warning between `analysis` and `dimensional_mismatch`.
 */
export interface UnitDiagnostic {
  message: string
  code: UnitWarning['code']
}

/**
 * Result of dimensional analysis for a single expression.
 */
export interface UnitResult {
  dimensions: ParsedUnit
  /** Message-only view, retained for the public `checkDimensions` API and
   *  legacy callers that inspect warning prose. */
  warnings: string[]
  /** Structured view of {@link warnings}: each message with its explicit
   *  classification. `validateUnits` uses these codes (not a prose regex) to
   *  decide which warnings `validate()` promotes to errors. */
  diagnostics: UnitDiagnostic[]
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
   * variables, arity problems, internal errors). Assigned explicitly where the
   * message is raised — never inferred from the message text.
   */
  code: 'dimensional_mismatch' | 'analysis'
  location?: string
  equation?: string
}

/**
 * Non-throwing arity check driven by the op-registry bounds — the single
 * source of truth — instead of hardcoding the count per case. Returns the
 * units-style warning message when `count` violates `op`'s registered arity, or
 * `null` when it is within bounds. `label` supplies the operator's display form
 * (which varies: `Division`, `Derivative D()`, `atan2()`, a bare comparison
 * symbol, ...), keeping the exact
 * "<label> requires exactly|at least N argument(s), got M" wording. Returns
 * `null` for an unregistered op (those cases carry no arity check).
 */
function arityWarning(op: string, label: string, count: number): string | null {
  const arity = getOpInfo(op)?.arity
  if (!arity) return null
  const { min, max } = arity
  if (count >= min && (max === null || count <= max)) return null
  const bound = max === null ? `at least ${min}` : `exactly ${min}`
  return `${label} requires ${bound} argument${min === 1 ? '' : 's'}, got ${count}`
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
  const diagnostics: UnitDiagnostic[] = []
  // Record a diagnostic with its classification made EXPLICIT here (not
  // recovered later from the prose). `dimensional_mismatch` is the promotable
  // dimensional-consistency violation; `analysis` is everything else (unknown
  // variables, arity problems, dimensionless-argument checks).
  const warn = (message: string, code: UnitWarning['code']): void => {
    diagnostics.push({ message, code })
  }
  const finish = (dimensions: ParsedUnit): UnitResult => ({
    dimensions,
    warnings: diagnostics.map((d) => d.message),
    diagnostics,
  })

  if (typeof expr === 'number' || isNumericLiteral(expr)) {
    return finish(dimensionless())
  }

  if (typeof expr === 'string') {
    const dims = unitBindings.get(expr)
    if (!dims) {
      warn(`Unknown variable: ${expr}`, 'analysis')
      return finish(dimensionless())
    }
    return finish(dims)
  }

  const node = expr as ExpressionNode
  const op = node.op
  const args = node.args

  const argResults = args.map((arg) => checkDimensions(arg, unitBindings, coordinateBindings))
  for (const r of argResults) diagnostics.push(...r.diagnostics)

  const argDims = argResults.map((r) => r.dimensions)
  const get = (i: number): ParsedUnit => argDims[i] ?? dimensionless()

  switch (op) {
    case '+':
    case '-': {
      const first = get(0)
      for (let i = 1; i < argDims.length; i++) {
        const other = get(i)
        if (!dimsEqual(first.dims, other.dims)) {
          warn(
            `Addition/subtraction requires same dimensions, got ${formatDims(first.dims)} and ${formatDims(other.dims)}`,
            'dimensional_mismatch',
          )
        }
      }
      return finish(first)
    }

    case '*':
      return finish(multiplyUnits(argDims))

    case '/': {
      const arity = arityWarning('/', 'Division', argDims.length)
      if (arity) {
        warn(arity, 'analysis')
        return finish(dimensionless())
      }
      return finish(divideUnits(get(0), get(1)))
    }

    case '^': {
      const arity = arityWarning('^', 'Exponentiation', argDims.length)
      if (arity) {
        warn(arity, 'analysis')
        return finish(dimensionless())
      }
      if (!isDimensionless(get(1))) {
        warn(`Exponent must be dimensionless, got ${formatDims(get(1).dims)}`, 'analysis')
      }
      // Preserve the base unit unchanged. Applying the exponent would require
      // extracting the constant value from the second argument, which the
      // original implementation did not attempt and current tests do not
      // exercise.
      return finish(get(0))
    }

    case 'D': {
      const arity = arityWarning('D', 'Derivative D()', args.length)
      if (arity) {
        warn(arity, 'analysis')
        return finish(dimensionless())
      }
      const timeVar = node.wrt || 't'
      const timeDims = unitBindings.get(timeVar) ?? { dims: { s: 1 }, scale: 1 }
      return finish(divideUnits(get(0), timeDims))
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
        return finish(divideUnits(get(0), lengthDims))
      }
      const coordDims = coordinateBindings.get(dimName)
      if (!coordDims) {
        return finish(divideUnits(get(0), lengthDims))
      }
      if (isDimensionless(coordDims)) {
        warn(
          `Gradient operator applied to variable with incompatible spatial units: coordinate '${dimName}' has no declared units (unit_inconsistency)`,
          'dimensional_mismatch',
        )
        return finish(get(0))
      }
      return finish(divideUnits(get(0), coordDims))
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
          warn(`${op}() requires dimensionless argument, got ${formatDims(arg.dims)}`, 'analysis')
        }
      }
      return finish(dimensionless())

    case 'atan2': {
      const arity = arityWarning('atan2', 'atan2()', argDims.length)
      if (arity) {
        warn(arity, 'analysis')
        return finish(dimensionless())
      }
      if (!dimsEqual(get(0).dims, get(1).dims)) {
        warn(
          `atan2() requires arguments with same dimensions, got ${formatDims(get(0).dims)} and ${formatDims(get(1).dims)}`,
          'dimensional_mismatch',
        )
      }
      return finish(dimensionless())
    }

    case 'sqrt':
    case 'abs':
    case 'sign':
    case 'floor':
    case 'ceil':
      return finish(get(0))

    case 'min':
    case 'max': {
      const arity = arityWarning(op, `${op}()`, argDims.length)
      if (arity) {
        warn(arity, 'analysis')
        return finish(dimensionless())
      }
      const ref = get(0)
      for (let i = 1; i < argDims.length; i++) {
        const other = get(i)
        if (!dimsEqual(ref.dims, other.dims)) {
          warn(
            `${op}() requires all arguments to have same dimensions, got ${formatDims(ref.dims)} and ${formatDims(other.dims)}`,
            'dimensional_mismatch',
          )
        }
      }
      return finish(ref)
    }

    case 'ifelse': {
      const arity = arityWarning('ifelse', 'ifelse()', argDims.length)
      if (arity) {
        warn(arity, 'analysis')
        return finish(dimensionless())
      }
      if (!isDimensionless(get(0))) {
        warn(`ifelse() condition must be dimensionless, got ${formatDims(get(0).dims)}`, 'analysis')
      }
      if (!dimsEqual(get(1).dims, get(2).dims)) {
        warn(
          `ifelse() branches must have same dimensions, got ${formatDims(get(1).dims)} and ${formatDims(get(2).dims)}`,
          'dimensional_mismatch',
        )
      }
      return finish(get(1))
    }

    case '>':
    case '<':
    case '>=':
    case '<=':
    case '==':
    case '!=': {
      const arity = arityWarning(op, op, argDims.length)
      if (arity) {
        warn(arity, 'analysis')
        return finish(dimensionless())
      }
      if (!dimsEqual(get(0).dims, get(1).dims)) {
        warn(
          `${op} requires arguments with same dimensions, got ${formatDims(get(0).dims)} and ${formatDims(get(1).dims)}`,
          'dimensional_mismatch',
        )
      }
      return finish(dimensionless())
    }

    case 'and':
    case 'or':
    case 'not':
      for (let i = 0; i < argDims.length; i++) {
        const arg = get(i)
        if (!isDimensionless(arg)) {
          warn(`${op} requires dimensionless arguments, got ${formatDims(arg.dims)}`, 'analysis')
        }
      }
      return finish(dimensionless())

    case 'Pre':
      return finish(get(0))

    default:
      warn(`Unknown operator: ${op}`, 'analysis')
      return finish(dimensionless())
  }
}

/**
 * Register a unit binding under BOTH its scoped key (`Scope.name`) and its bare
 * short name (`name`). The scoped key always reflects this component; the bare
 * key is FIRST-WINS — an earlier component's short name is never overwritten by
 * a later collision, matching the legacy resolution order where the
 * first-declared short name shadows later ones. No-op when `units` is absent.
 */
function addBinding(
  bindings: Map<string, ParsedUnit>,
  scope: string,
  name: string,
  units: string | undefined,
): void {
  if (!units) return
  const parsed = parseUnit(units)
  bindings.set(`${scope}.${name}`, parsed)
  if (!bindings.has(name)) bindings.set(name, parsed)
}

/**
 * Run a single dimensional check `run`, funnel its structured sub-diagnostics
 * into `warnings` (tagged with `location` and their EXPLICIT codes), and emit
 * its dimensional-mismatch warning when one is present AND no operand was an
 * unknown variable — missing unit declarations would otherwise produce false
 * positives, since both sides default to dimensionless. Any thrown error
 * surfaces as one `analysis` warning prefixed with `errorContext`. The equation
 * and observed-variable passes share this; they differ only in what `run`
 * compares.
 */
function checkAndReport(
  warnings: UnitWarning[],
  location: string,
  errorContext: string,
  run: () => { diagnostics: UnitDiagnostic[]; mismatch: UnitWarning | null },
): void {
  try {
    const { diagnostics, mismatch } = run()
    const hasUnknownVariable = diagnostics.some((d) => d.message.includes('Unknown variable'))
    if (mismatch && !hasUnknownVariable) {
      warnings.push(mismatch)
    }
    for (const d of diagnostics) {
      warnings.push({ message: d.message, code: d.code, location })
    }
  } catch (error) {
    warnings.push({
      message: `${errorContext}: ${error instanceof Error ? error.message : String(error)}`,
      code: 'analysis',
      location,
    })
  }
}

/**
 * Build the coordinate → units table a model's `grad`/`div`/`laplacian` ops
 * resolve their `dim` against. Mirrors Julia's `_collect_coordinate_units`
 * (validate.jl): every declared model variable maps to its parsed units, and a
 * variable declared WITHOUT units maps to a dimensionless entry. `checkDimensions`
 * then flags a grad whose `dim` names a dimensionless (no-units) coordinate,
 * resolves one naming a coordinate WITH units, and — for a `dim` that is NOT a
 * declared variable (an index-set axis) — finds no entry and falls back to the
 * metre denominator. Parameters live in `variables` (type `parameter`) so they
 * are covered by the same loop, matching Julia's `model.variables`.
 */
function buildCoordinateBindings(model: Model): Map<string, ParsedUnit> {
  const coords = new Map<string, ParsedUnit>()
  for (const [name, variable] of Object.entries(model.variables ?? {})) {
    coords.set(name, variable.units ? parseUnit(variable.units) : dimensionless())
  }
  return coords
}

/**
 * Validate dimensional consistency of equations in an ESM file.
 *
 * SCOPE: every real inline component — each top-level model / reaction system
 * AND their inline `subsystems` (walked via `forEachComponent(..., {recurse:
 * true})`; reference-stub and data-loader subsystems are opaque leaves and are
 * skipped). For each, `forEachEquation` covers a model's dynamic `equations`
 * and a reaction system's `constraint_equations`; models additionally have
 * their `observed` variable expressions checked.
 *
 * BINDINGS: the shared top-level environment (top-level models' variables +
 * reaction systems' species/parameters, scoped key + bare first-wins) is used
 * for EVERY component, including subsystems. Subsystem-local declarations are
 * deliberately NOT added, so a name defined only inside a subsystem stays an
 * "Unknown variable" and keeps the mismatch-suppression in `checkAndReport`.
 * This is the conservative scope required to broaden coverage without
 * introducing cross-language divergence: binding a subsystem's own variables
 * would un-suppress equation-level mismatches for nondimensionalized subsystem
 * ODEs (e.g. `D(u,t) = k*u` with a dimensionless `u`), which the other bindings
 * — none of which run a full per-equation dimensional check — never flag. A
 * top-level reaction system's `constraint_equations` still resolve fully,
 * because that system's species/parameters ARE in the shared environment.
 *
 * SPATIAL COORDINATES: each model supplies `checkDimensions` a
 * `coordinateBindings` map built from its declared variables (see
 * {@link buildCoordinateBindings}), so `grad`/`div`/`laplacian` resolve their
 * `dim` against the model's own declarations (mirroring Julia's
 * `validate_model_gradient_units`). Reaction-system constraint equations get no
 * coordinate table (gradient-unit resolution is model-only in Julia), so any
 * grad there keeps the metre-denominator fallback.
 */
export function validateUnits(file: EsmFile): UnitWarning[] {
  const warnings: UnitWarning[] = []

  // Shared binding environment: top-level models' variables + reaction systems'
  // species/parameters (scoped key + bare first-wins). This is the ONLY
  // environment — subsystem-local declarations are never added (see the
  // docstring's BINDINGS note), so a subsystem-only name stays unbound and its
  // equation-level mismatch is suppressed.
  const unitBindings = new Map<string, ParsedUnit>()
  if (file.models) {
    for (const [modelName, model] of Object.entries(file.models)) {
      if ('variables' in model && model.variables) {
        for (const [varName, variable] of Object.entries(model.variables)) {
          addBinding(unitBindings, modelName, varName, variable.units)
        }
      }
    }
  }
  if (file.reaction_systems) {
    for (const [systemName, system] of Object.entries(file.reaction_systems)) {
      if ('species' in system && system.species) {
        for (const [speciesName, species] of Object.entries(system.species)) {
          addBinding(unitBindings, systemName, speciesName, species.units)
        }
      }
      if ('parameters' in system && system.parameters) {
        for (const [paramName, param] of Object.entries(system.parameters)) {
          addBinding(unitBindings, systemName, paramName, param.units)
        }
      }
    }
  }

  // Reaction-rate / stoichiometry dimensional check lives in validate.ts
  // (`validateReactionRateUnits`) so it can emit a structured
  // `unit_inconsistency` error with typed details instead of a prose warning.

  forEachComponent(
    file,
    (visit) => {
      if (visit.isReference) return
      const { scopedName, component } = visit
      const location = `${visit.kind}.${scopedName}`

      // Every component (top-level and subsystem) shares `unitBindings`;
      // subsystem-local names stay unbound (see the docstring's BINDINGS note),
      // preserving the legacy mismatch-suppression.

      // Coordinate table for grad/div/laplacian — models only (a reaction
      // system has no `variables`, so `undefined` here keeps the metre fallback
      // for any grad in a constraint equation).
      const coordinateBindings =
        'variables' in component ? buildCoordinateBindings(component) : undefined

      forEachEquation(component, (equation) => {
        checkAndReport(warnings, location, 'Error checking equation dimensions', () => {
          const lhsResult = checkDimensions(equation.lhs, unitBindings, coordinateBindings)
          const rhsResult = checkDimensions(equation.rhs, unitBindings, coordinateBindings)
          const diagnostics = [...lhsResult.diagnostics, ...rhsResult.diagnostics]
          const mismatch: UnitWarning | null = dimsEqual(
            lhsResult.dimensions.dims,
            rhsResult.dimensions.dims,
          )
            ? null
            : {
                message: `Dimensional mismatch in equation: LHS has ${formatDims(lhsResult.dimensions.dims)}, RHS has ${formatDims(rhsResult.dimensions.dims)}`,
                code: 'dimensional_mismatch',
                location,
                equation: `${JSON.stringify(equation.lhs)} = ${JSON.stringify(equation.rhs)}`,
              }
          return { diagnostics, mismatch }
        })
      })

      if ('variables' in component && component.variables) {
        for (const [varName, variable] of Object.entries(component.variables)) {
          if (variable.type === 'observed' && variable.expression) {
            const expression = variable.expression
            const varLocation = `${location}.variables.${varName}`
            checkAndReport(
              warnings,
              varLocation,
              'Error checking observed variable dimensions',
              () => {
                const exprResult = checkDimensions(expression, unitBindings, coordinateBindings)
                const varDims: ParsedUnit = variable.units
                  ? parseUnit(variable.units)
                  : dimensionless()
                const mismatch: UnitWarning | null = dimsEqual(
                  exprResult.dimensions.dims,
                  varDims.dims,
                )
                  ? null
                  : {
                      message: `Dimensional mismatch in observed variable ${varName}: declared as ${formatDims(varDims.dims)}, expression evaluates to ${formatDims(exprResult.dimensions.dims)}`,
                      code: 'dimensional_mismatch',
                      location: varLocation,
                    }
                return { diagnostics: exprResult.diagnostics, mismatch }
              },
            )
          }
        }
      }
    },
    { recurse: true },
  )

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
