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
  /**
   * The expression's canonical dimension, or `null` when it is INDETERMINATE.
   *
   * `null` is not "dimensionless" — it is "this analysis cannot say", and it is
   * the value returned for an unknown variable, an unparseable unit
   * declaration, and any operator whose dimensional semantics this module does
   * not model (`index`, `fn`, `aggregate`, `makearray`, `table_lookup`, ...).
   * Keeping the two apart is what stops a structural op from being *assumed*
   * dimensionless and thereby manufacturing a false mismatch against a
   * dimensional operand. `null` propagates through every combining rule, and a
   * comparison against `null` is never a mismatch — it is simply skipped, which
   * mirrors the Go reference (`PropagateDimension` returns `nil, nil`).
   */
  dimensions: ParsedUnit | null
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
 * Parse a unit string into canonical SI dimensions plus scale factor, or return
 * `null` when the string cannot be parsed.
 *
 * This is the fallible companion to {@link parseUnit}: instead of swallowing a
 * parse failure into a dimensionless fallback, it surfaces the failure as
 * `null`. Callers can then leave the variable's dimension UNKNOWN (unbound) and
 * emit a warning, rather than silently manufacturing a dimensionless binding
 * that HIDES real dimensional mismatches — or MANUFACTURES false ones
 * (esm-libraries-spec §3.3.3/§3.4, matching the Julia reference). A
 * `UnitConversionError` (unknown unit name, malformed token, misused offset
 * unit) maps to `null`; any other error is rethrown.
 *
 * The string `"degrees"` is still accepted as dimensionless because ESM treats
 * angle labels as informational; the canonical unit table does not register it
 * to avoid committing to a radian conversion factor that ESM does not promise.
 */
export function tryParseUnit(unitStr: string): ParsedUnit | null {
  const normalized = (unitStr ?? '').trim().toLowerCase()
  if (normalized === 'degrees') {
    return dimensionless()
  }
  try {
    return parseUnitForConversion(unitStr)
  } catch (err) {
    if (err instanceof UnitConversionError) {
      return null
    }
    throw err
  }
}

/**
 * Parse a unit string into canonical SI dimensions plus scale factor.
 *
 * STRICT: an unparseable unit string is an ERROR. It is never silently
 * collapsed to dimensionless — a dimensionless fallback is a *claim* about the
 * quantity, and a wrong one, which both hides real mismatches (everything
 * compares equal to everything) and manufactures false ones (against genuinely
 * dimensional operands). `J/(mol*K)` used to land in exactly that trap.
 *
 * Callers that must degrade gracefully rather than throw — the validators, which
 * want to leave a dimension UNKNOWN and carry on — use {@link tryParseUnit},
 * which returns `null` instead.
 *
 * @throws {UnitConversionError} on an unknown unit name, a malformed token,
 *   unbalanced parentheses, or a misused offset unit.
 */
export function parseUnit(unitStr: string): ParsedUnit {
  const normalized = (unitStr ?? '').trim().toLowerCase()
  if (normalized === 'degrees') {
    return dimensionless()
  }
  return parseUnitForConversion(unitStr)
}

/**
 * Extract the constant numeric value of an expression, or `null` when it is not
 * a literal. Handles both plain JS numbers and the tagged int/float
 * `NumericLiteral` leaves that the lossless parser produces — a `^` exponent is
 * naturally spelled `2` (int), and matching only the float form is exactly the
 * bug the Rust binding has (audit R6).
 */
function literalValue(expr: Expression): number | null {
  if (typeof expr === 'number') return expr
  if (isNumericLiteral(expr)) return expr.value
  return null
}

/**
 * Raise a dimension to a power (`m^2`, `s^-1`, and also `(m^2)^1.5 → m^3`). The
 * scale is raised alongside, so `km^2` stays 1e6 m².
 *
 * The exponent itself need NOT be an integer — only the RESULTING exponents
 * must be. `(d^2 + r^2)^1.5` with a length-squared base is the ordinary
 * spelling of a Mogi/Boussinesq kernel and yields a clean `m^3`; rejecting it
 * because `1.5` is fractional would reject correct physics. Returns `null` when
 * the result is not representable in an integer dimension vector (e.g.
 * `m^1.5`), which the caller reports as an inconsistency.
 */
function powerUnit(base: ParsedUnit, exp: number): ParsedUnit | null {
  const dims: CanonicalDims = {}
  for (const [k, v] of Object.entries(base.dims)) {
    if (v == null || v === 0) continue
    const scaled = v * exp
    if (!Number.isInteger(scaled)) return null
    dims[k as keyof CanonicalDims] = scaled
  }
  pruneZeros(dims)
  return { dims, scale: Math.pow(base.scale, exp) }
}

/**
 * Check dimensional consistency of an expression.
 *
 * Follows ESM spec Section 3.3.1:
 * - Addition/subtraction: operands must share canonical dimensions
 * - Multiplication: dimensions add (scales multiply)
 * - Division: dimensions subtract (scales divide)
 * - `^` with a constant integer exponent: dimensions scale by the exponent
 * - `sqrt`: dimensions halve
 * - `D(x, wrt=t)`: dimension of x divided by dimension of t
 * - Transcendental functions require dimensionless arguments
 *
 * Returns `dimensions: null` for anything INDETERMINATE (see
 * {@link UnitResult.dimensions}) — an unknown variable, or an operator this
 * module does not model dimensionally. Indeterminate operands never produce a
 * mismatch; only a *provable* inconsistency does.
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
  const finish = (dimensions: ParsedUnit | null): UnitResult => ({
    dimensions,
    warnings: diagnostics.map((d) => d.message),
    diagnostics,
  })
  /** The indeterminate result: "this analysis cannot say". */
  const unknown = (): UnitResult => finish(null)

  // A BARE NUMERIC LITERAL has an INDETERMINATE dimension, not a dimensionless
  // one. This is the same principle as the structural-op case below, applied to
  // the one leaf that carries no annotation: you cannot tell from the AST
  // whether `273.15` is a pure number or a temperature offset, whether `0.0224`
  // is a molar volume, whether `-1000` is an activation temperature, or whether
  // `6.022e23` is Avogadro's number. The valid corpus is full of exactly these
  // — implicit-unit constants — and calling them dimensionless manufactured a
  // mismatch on every line that uses one.
  //
  // This matters *because* TS promotes dimensional findings to hard errors (the
  // shared corpus pins every `units_*.esm` fixture as a structural error). A
  // checker that fails the build must not fabricate a dimension it cannot know.
  // The other bindings can afford the dimensionless assumption only because
  // they downgrade the result to a warning.
  //
  // It costs nothing on the pinned invalid corpus: every fixture there states
  // its inconsistency between DECLARED quantities (`length + mass`, `ln(mass)`,
  // `m^kg`), never via a literal. Literals still behave correctly where their
  // meaning IS determined: additively they are neutral and adopt their
  // sibling's dimension (`T - 273.15` → K), an all-literal expression is
  // dimensionless (`1 + 2`, `-1`), and an exponent is read by VALUE (`x^2`).
  if (typeof expr === 'number' || isNumericLiteral(expr)) {
    return unknown()
  }

  if (typeof expr === 'string') {
    const dims = unitBindings.get(expr)
    if (!dims) {
      // Unknown variable ⇒ UNKNOWN dimension, not dimensionless. Assuming
      // dimensionless here would manufacture mismatches against every
      // dimensional operand it meets.
      warn(`Unknown variable: ${expr}`, 'analysis')
      return unknown()
    }
    return finish(dims)
  }

  const node = expr as ExpressionNode
  const op = node.op
  const args = node.args ?? []

  const argResults = args.map((arg) => checkDimensions(arg, unitBindings, coordinateBindings))
  for (const r of argResults) diagnostics.push(...r.diagnostics)

  // `get(i)` is the i-th operand's dimension, or `null` when indeterminate.
  const argDims = argResults.map((r) => r.dimensions)
  const get = (i: number): ParsedUnit | null => argDims[i] ?? null

  switch (op) {
    case '+':
    case '-': {
      // Compare only the operands we actually know; an unknown operand is
      // skipped rather than defaulted. The result is the first known dimension
      // (or unknown if none is).
      //
      // A BARE NUMERIC LITERAL in additive position is dimensionally NEUTRAL,
      // not dimensionless: it adopts the dimension of what it is added to. This
      // is how physical models are actually written — `T - 273.15`, `1 - phi`,
      // `biomass + 0.5` — where the literal silently carries the sibling's
      // unit. Treating it as dimensionless instead reported a mismatch on every
      // such line in the valid corpus. It costs no real coverage: a genuine
      // inconsistency (`length + mass`) is between two DECLARED quantities, and
      // is still caught.
      let first: ParsedUnit | null = null
      let sawNonLiteral = false
      for (let i = 0; i < argDims.length; i++) {
        if (literalValue(args[i]) !== null) continue
        sawNonLiteral = true
        const other = get(i)
        if (other === null) continue
        if (first === null) {
          first = other
          continue
        }
        if (!dimsEqual(first.dims, other.dims)) {
          warn(
            `Addition/subtraction requires same dimensions, got ${formatDims(first.dims)} and ${formatDims(other.dims)}`,
            'dimensional_mismatch',
          )
        }
      }
      // Every operand was a literal (`1 + 2`, or a unary `-1`) ⇒ dimensionless.
      if (!sawNonLiteral) return finish(dimensionless())
      return finish(first)
    }

    case '*': {
      // A single unknown factor makes the whole product unknown.
      if (argDims.some((d) => d === null)) return unknown()
      return finish(multiplyUnits(argDims as ParsedUnit[]))
    }

    case '/': {
      const arity = arityWarning('/', 'Division', argDims.length)
      if (arity) {
        warn(arity, 'analysis')
        return unknown()
      }
      const num = get(0)
      const den = get(1)
      if (num === null || den === null) return unknown()
      return finish(divideUnits(num, den))
    }

    case '^':
    case '**':
    case 'pow': {
      const arity = arityWarning('^', 'Exponentiation', argDims.length)
      if (arity) {
        warn(arity, 'analysis')
        return unknown()
      }
      const base = get(0)
      const expDims = get(1)

      // A dimensional exponent is always an error (`m^kg` is meaningless),
      // whether or not the base is known.
      if (expDims !== null && !isDimensionless(expDims)) {
        warn(
          `Exponent must be dimensionless, got ${formatDims(expDims.dims)}`,
          'dimensional_mismatch',
        )
        return unknown()
      }

      if (base === null) return unknown()
      // A dimensionless base stays dimensionless under any exponent, so a
      // non-constant exponent is only a problem for a DIMENSIONAL base.
      if (isDimensionless(base)) return finish(dimensionless())

      const expValue = literalValue(args[1])
      if (expValue === null) {
        // A SYMBOLIC exponent on a dimensional base is INDETERMINATE, not
        // wrong. `k * [X]^n` — a rate law with a fitted reaction order — is
        // ordinary earth-science chemistry (tests/valid/expr_graphs_variable_deps.esm
        // writes exactly `k2 * x^alpha * z^beta`), and no dimension can be
        // computed for it without knowing `n`. "Cannot compute" is not a defect
        // in the file, so this is an `analysis` remark and never promoted to an
        // error — the same principle as the structural-op default arm below.
        // (A DIMENSIONAL exponent, `m^kg`, is a different rule and stays a
        // provable mismatch — see just above.)
        warn(
          `Cannot determine the dimension of a non-literal exponent applied to a dimensional quantity (base has ${formatDims(base.dims)})`,
          'analysis',
        )
        return unknown()
      }
      const raised = powerUnit(base, expValue)
      if (raised === null) {
        warn(
          `Exponent ${expValue} applied to ${formatDims(base.dims)} yields a non-integer dimension`,
          'dimensional_mismatch',
        )
        return unknown()
      }
      return finish(raised)
    }

    case 'D': {
      const arity = arityWarning('D', 'Derivative D()', args.length)
      if (arity) {
        warn(arity, 'analysis')
        return unknown()
      }
      const operand = get(0)
      if (operand === null) return unknown()
      const timeVar = node.wrt || 't'
      const timeDims = unitBindings.get(timeVar)
      // An UNDECLARED independent variable has an unknown dimension, so the
      // derivative's dimension is unknown too. Defaulting to seconds here was a
      // false-positive factory: in a nondimensionalized model (state and RHS
      // both declared "1", `t` undeclared) it manufactured `1/s` on the left
      // against `1` on the right and reported a mismatch in a perfectly valid
      // file. The equation-level rule in `validateUnits`
      // (`derivativeTimeMismatch`) still catches a derivative equation that NO
      // choice of time unit could reconcile, so dropping the assumption costs
      // no real coverage.
      if (timeDims === undefined) return unknown()
      return finish(divideUnits(operand, timeDims))
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
      const operand = get(0)
      if (operand === null) return unknown()
      // `laplacian` is the SECOND derivative (∂²u/∂x²), so it divides by the
      // coordinate SQUARED; `grad` and `div` are first-order and divide once.
      // Dividing only once for laplacian reported `nu*laplacian(u)` as m²/s²
      // against an advection term of m/s² — a false mismatch in every
      // Navier-Stokes fixture in the corpus.
      const order = op === 'laplacian' ? 2 : 1
      const dimName = node.dim
      const lengthDims: ParsedUnit = { dims: { m: 1 }, scale: 1 }
      const denominator = (coord: ParsedUnit): ParsedUnit => powerUnit(coord, order) ?? coord
      if (!dimName || !coordinateBindings) {
        return finish(divideUnits(operand, denominator(lengthDims)))
      }
      const coordDims = coordinateBindings.get(dimName)
      if (!coordDims) {
        return finish(divideUnits(operand, denominator(lengthDims)))
      }
      if (isDimensionless(coordDims)) {
        warn(
          `Gradient operator applied to variable with incompatible spatial units: coordinate '${dimName}' has no declared units (unit_inconsistency)`,
          'dimensional_mismatch',
        )
        return unknown()
      }
      return finish(divideUnits(operand, denominator(coordDims)))
    }

    case 'exp':
    case 'log':
    case 'ln':
    case 'log10':
    case 'log2':
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
      // A transcendental function of a dimensional quantity is a provable
      // inconsistency (`log(kg)` has no meaning), not a soft remark — the
      // shared corpus pins units_invalid_logarithm.esm as invalid on exactly
      // this rule.
      for (let i = 0; i < argDims.length; i++) {
        const arg = get(i)
        if (arg !== null && !isDimensionless(arg)) {
          warn(
            `${op}() requires dimensionless argument, got ${formatDims(arg.dims)}`,
            'dimensional_mismatch',
          )
        }
      }
      return finish(dimensionless())

    case 'atan2': {
      const arity = arityWarning('atan2', 'atan2()', argDims.length)
      if (arity) {
        warn(arity, 'analysis')
        return finish(dimensionless())
      }
      const a = get(0)
      const b = get(1)
      if (a !== null && b !== null && !dimsEqual(a.dims, b.dims)) {
        warn(
          `atan2() requires arguments with same dimensions, got ${formatDims(a.dims)} and ${formatDims(b.dims)}`,
          'dimensional_mismatch',
        )
      }
      return finish(dimensionless())
    }

    case 'sqrt': {
      // sqrt is exactly `^0.5`: it HALVES the dimension. Returning the base
      // unchanged (as the old code did) reported sqrt(m^2) as m^2.
      const base = get(0)
      if (base === null) return unknown()
      const halved = powerUnit(base, 0.5)
      if (halved === null) {
        warn(
          `sqrt() requires a dimension with even exponents, got ${formatDims(base.dims)}`,
          'dimensional_mismatch',
        )
        return unknown()
      }
      return finish(halved)
    }

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
        return unknown()
      }
      // `max(x, 0)` / `min(rate, 1e-6)` clamp against a bare literal that
      // carries the operand's implicit unit — literals are neutral here for the
      // same reason they are in `+`/`-`.
      let ref: ParsedUnit | null = null
      let sawNonLiteral = false
      for (let i = 0; i < argDims.length; i++) {
        if (literalValue(args[i]) !== null) continue
        sawNonLiteral = true
        const other = get(i)
        if (other === null) continue
        if (ref === null) {
          ref = other
          continue
        }
        if (!dimsEqual(ref.dims, other.dims)) {
          warn(
            `${op}() requires all arguments to have same dimensions, got ${formatDims(ref.dims)} and ${formatDims(other.dims)}`,
            'dimensional_mismatch',
          )
        }
      }
      if (!sawNonLiteral) return finish(dimensionless())
      return finish(ref)
    }

    case 'ifelse': {
      const arity = arityWarning('ifelse', 'ifelse()', argDims.length)
      if (arity) {
        warn(arity, 'analysis')
        return unknown()
      }
      const cond = get(0)
      if (cond !== null && !isDimensionless(cond)) {
        warn(`ifelse() condition must be dimensionless, got ${formatDims(cond.dims)}`, 'analysis')
      }
      const a = get(1)
      const b = get(2)
      if (a !== null && b !== null && !dimsEqual(a.dims, b.dims)) {
        warn(
          `ifelse() branches must have same dimensions, got ${formatDims(a.dims)} and ${formatDims(b.dims)}`,
          'dimensional_mismatch',
        )
      }
      return finish(a ?? b)
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
      const a = get(0)
      const b = get(1)
      if (a !== null && b !== null && !dimsEqual(a.dims, b.dims)) {
        warn(
          `${op} requires arguments with same dimensions, got ${formatDims(a.dims)} and ${formatDims(b.dims)}`,
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
        if (arg !== null && !isDimensionless(arg)) {
          warn(`${op} requires dimensionless arguments, got ${formatDims(arg.dims)}`, 'analysis')
        }
      }
      return finish(dimensionless())

    case 'Pre':
      return finish(get(0))

    default:
      // Structural / not-dimensionally-modelled ops (`index`, `fn`,
      // `aggregate`, `const`, `makearray`, `table_lookup`, `arrayop`, ...).
      // Their dimension is UNKNOWN, and saying so is the whole point: the
      // previous `dimensionless()` fallback asserted a dimension these nodes do
      // not have, which manufactured false mismatches all over the valid
      // corpus. Go returns `nil, nil` here and skips the check; so do we. No
      // diagnostic is emitted — an unmodelled op is not a defect.
      return unknown()
  }
}

/**
 * Register a unit binding under BOTH its scoped key (`Scope.name`) and its bare
 * short name (`name`). The scoped key always reflects this component; the bare
 * key is FIRST-WINS — an earlier component's short name is never overwritten by
 * a later collision, matching the legacy resolution order where the
 * first-declared short name shadows later ones. No-op when `units` is absent.
 *
 * When `units` is present but UNPARSEABLE, the variable is deliberately left
 * UNBOUND (its dimension is UNKNOWN, not dimensionless) and an `analysis`
 * `unit_warning` is recorded on `warnings`. `checkDimensions` then treats the
 * name as an "Unknown variable", which `checkAndReport` uses to suppress
 * equation mismatches — so an unparseable unit surfaces as a warning without
 * hiding or manufacturing a dimensional mismatch.
 */
function addBinding(
  bindings: Map<string, ParsedUnit>,
  scope: string,
  name: string,
  units: string | undefined,
  warnings: UnitWarning[],
): void {
  if (!units) return
  const parsed = tryParseUnit(units)
  if (parsed === null) {
    warnings.push({
      message: `Unable to parse units '${units}' for ${scope}.${name}; dimension left unknown`,
      code: 'analysis',
      location: `${scope}.${name}`,
    })
    return
  }
  bindings.set(`${scope}.${name}`, parsed)
  if (!bindings.has(name)) bindings.set(name, parsed)
}

/**
 * Run a single dimensional check `run`, funnel its structured sub-diagnostics
 * into `warnings` (tagged with `location` and their EXPLICIT codes), and emit
 * its dimensional-mismatch warning when `run` found one. Any thrown error
 * surfaces as one `analysis` warning prefixed with `errorContext`. The equation
 * and observed-variable passes share this; they differ only in what `run`
 * compares.
 *
 * `run` is responsible for producing a `mismatch` ONLY when both sides are
 * determinate — indeterminacy is modelled in the dimension itself
 * (`UnitResult.dimensions === null`), so this no longer sniffs the diagnostic
 * PROSE for "Unknown variable" to decide whether to suppress a mismatch.
 */
function checkAndReport(
  warnings: UnitWarning[],
  location: string,
  errorContext: string,
  run: () => { diagnostics: UnitDiagnostic[]; mismatch: UnitWarning | null },
): void {
  try {
    const { diagnostics, mismatch } = run()
    if (mismatch) {
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
function buildCoordinateBindings(
  model: Model,
  warnings: UnitWarning[],
  location: string,
): Map<string, ParsedUnit> {
  const coords = new Map<string, ParsedUnit>()
  for (const [name, variable] of Object.entries(model.variables ?? {})) {
    if (!variable.units) {
      coords.set(name, dimensionless())
      continue
    }
    const parsed = tryParseUnit(variable.units)
    if (parsed === null) {
      // Unparseable coordinate unit: leave it OUT of the table so its
      // dimension stays UNKNOWN. A grad/div/laplacian naming it then falls
      // back to the metre denominator (the not-a-declared-coordinate path)
      // instead of the dimensionless entry that would raise a false
      // unit_inconsistency. Record it as an `analysis` warning.
      warnings.push({
        message: `Unable to parse units '${variable.units}' for coordinate '${name}'; dimension left unknown`,
        code: 'analysis',
        location,
      })
      continue
    }
    coords.set(name, parsed)
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
          addBinding(unitBindings, modelName, varName, variable.units, warnings)
        }
      }
    }
  }
  if (file.reaction_systems) {
    for (const [systemName, system] of Object.entries(file.reaction_systems)) {
      if ('species' in system && system.species) {
        for (const [speciesName, species] of Object.entries(system.species)) {
          addBinding(unitBindings, systemName, speciesName, species.units, warnings)
        }
      }
      if ('parameters' in system && system.parameters) {
        for (const [paramName, param] of Object.entries(system.parameters)) {
          addBinding(unitBindings, systemName, paramName, param.units, warnings)
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
      const location = componentPointer(visit.kind, scopedName)
      // A model's equations live under `equations`; a reaction system's under
      // `constraint_equations` (the two component types are disjoint, and
      // `forEachEquation` walks whichever is present).
      const equationsKey = visit.kind === 'models' ? 'equations' : 'constraint_equations'

      // Components share `unitBindings`, but a BARE name inside this component's
      // equations means THIS component's declaration (see
      // {@link bindingsForComponent}); subsystem-local names stay unbound (see
      // the docstring's BINDINGS note), preserving the legacy
      // mismatch-suppression.
      const bindings = bindingsForComponent(unitBindings, scopedName, component)

      // Coordinate table for grad/div/laplacian — models only (a reaction
      // system has no `variables`, so `undefined` here keeps the metre fallback
      // for any grad in a constraint equation).
      const coordinateBindings =
        'variables' in component
          ? buildCoordinateBindings(component, warnings, location)
          : undefined

      forEachEquation(component, (equation, index) => {
        // Report AT THE EQUATION, not at the enclosing component: the shared
        // corpus pins `unit_inconsistency` at
        // `/models/<M>/equations/<i>` (tests/invalid/expected_errors.json).
        const eqLocation = `${location}/${equationsKey}/${index}`
        checkAndReport(warnings, eqLocation, 'Error checking equation dimensions', () => {
          const lhsResult = checkDimensions(equation.lhs, bindings, coordinateBindings)
          const rhsResult = checkDimensions(equation.rhs, bindings, coordinateBindings)
          const diagnostics = [...lhsResult.diagnostics, ...rhsResult.diagnostics]
          const lhs = lhsResult.dimensions
          const rhs = rhsResult.dimensions
          const equationText = `${JSON.stringify(equation.lhs)} = ${JSON.stringify(equation.rhs)}`

          // `D(x)` with an UNDECLARED independent variable is indeterminate, so
          // the plain LHS-vs-RHS comparison below cannot see it. Apply the
          // weaker — but still provable — time-ratio rule instead.
          const derivMessage = derivativeOfUndeclaredTime(equation.lhs, bindings)
            ? derivativeTimeMismatch(
                checkDimensions(
                  (equation.lhs as ExpressionNode).args[0],
                  bindings,
                  coordinateBindings,
                ).dimensions,
                rhs,
              )
            : null
          if (derivMessage) {
            return {
              diagnostics,
              mismatch: {
                message: derivMessage,
                code: 'dimensional_mismatch',
                location: eqLocation,
                equation: equationText,
              },
            }
          }

          // Only a comparison between two DETERMINATE sides can prove a
          // mismatch. An indeterminate side (unknown variable, unmodelled op)
          // is skipped, never defaulted to dimensionless.
          const mismatch: UnitWarning | null =
            lhs !== null && rhs !== null && !dimsEqual(lhs.dims, rhs.dims)
              ? {
                  message: `Dimensional mismatch in equation: LHS has ${formatDims(lhs.dims)}, RHS has ${formatDims(rhs.dims)}`,
                  code: 'dimensional_mismatch',
                  location: eqLocation,
                  equation: equationText,
                }
              : null
          return { diagnostics, mismatch }
        })
      })

      if ('variables' in component && component.variables) {
        for (const [varName, variable] of Object.entries(component.variables)) {
          if (variable.type === 'observed' && variable.expression) {
            const expression = variable.expression
            const varLocation = `${location}/variables/${varName}`
            checkAndReport(
              warnings,
              varLocation,
              'Error checking observed variable dimensions',
              () => {
                const exprResult = checkDimensions(expression, bindings, coordinateBindings)
                const diagnostics = [...exprResult.diagnostics]
                // Declared units are parsed leniently-but-fallibly. An
                // unparseable declaration leaves the target dimension UNKNOWN,
                // so we record an `analysis` warning and skip the mismatch
                // comparison instead of forcing the declared side to
                // dimensionless (which would manufacture a false mismatch
                // against the expression).
                let varDims: ParsedUnit | null = dimensionless()
                if (variable.units) {
                  varDims = tryParseUnit(variable.units)
                  if (varDims === null) {
                    diagnostics.push({
                      message: `Unable to parse declared units '${variable.units}' for observed variable ${varName}; dimension left unknown`,
                      code: 'analysis',
                    })
                  }
                }
                const exprDims = exprResult.dimensions
                const mismatch: UnitWarning | null =
                  varDims !== null && exprDims !== null && !dimsEqual(exprDims.dims, varDims.dims)
                    ? {
                        message: `Dimensional mismatch in observed variable ${varName}: declared as ${formatDims(varDims.dims)}, expression evaluates to ${formatDims(exprDims.dims)}`,
                        code: 'dimensional_mismatch',
                        location: varLocation,
                      }
                    : null
                return { diagnostics, mismatch }
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

/**
 * The binding view used to check ONE top-level component: the shared
 * environment, with every BARE name this component declares rebound to THIS
 * component's own units.
 *
 * The shared table publishes each declaration twice — under its scoped key
 * (`ChemicalKinetics.B`) and, first-writer-wins, under its bare name (`B`). The
 * bare half is a single flat namespace across the whole file, so when two models
 * both declare `B`, one model's units silently answered for the other's. That is
 * not a hypothetical: in `tests/valid/units_dimensional_analysis.esm`,
 * `ElectromagneticFields.B` reached the table first, so `ChemicalKinetics`' rate
 * equation `D(C) = k_bimolecular * A * B` resolved `B` to the OTHER model's `B`
 * and was reported as a dimensional mismatch — a false positive with no defect
 * anywhere in the file.
 *
 * A bare name inside a component's equations means that component's own
 * declaration. Rebinding is done per component rather than by removing the bare
 * keys, because a bare name that this component does NOT declare must still
 * resolve against the shared table (that is how a subsystem sees its parent's
 * variables, and how cross-model references keep working).
 *
 * SUBSYSTEMS are deliberately left on the shared table untouched — see the
 * BINDINGS note on {@link validateUnits}. Binding a subsystem's own declarations
 * would un-suppress mismatches the other bindings never flag, which is a
 * separate (and cross-language) decision from fixing the collision above.
 */
function bindingsForComponent(
  shared: Map<string, ParsedUnit>,
  scopedName: string,
  component: unknown,
): Map<string, ParsedUnit> {
  // A dotted scopedName is an inline subsystem.
  if (scopedName.includes('.')) return shared

  const own = new Map<string, string>()
  const collect = (table: Record<string, { units?: string }> | undefined): void => {
    for (const [name, decl] of Object.entries(table ?? {})) {
      if (decl?.units) own.set(name, decl.units)
    }
  }
  const c = component as {
    variables?: Record<string, { units?: string }>
    species?: Record<string, { units?: string }>
    parameters?: Record<string, { units?: string }>
  }
  collect(c.variables)
  collect(c.species)
  collect(c.parameters)
  if (own.size === 0) return shared

  const view = new Map(shared)
  for (const [name, units] of own) {
    const parsed = tryParseUnit(units)
    // An unparseable declaration leaves the name UNBOUND for this component —
    // and must also SHADOW any same-named binding another component published,
    // or the collision returns by the back door.
    if (parsed === null) view.delete(name)
    else view.set(name, parsed)
  }
  return view
}

/**
 * JSON Pointer for a component, from the dotted `scopedName` that
 * `forEachComponent` composes. `('models', 'A')` → `/models/A`;
 * `('models', 'A.B')` (an inline subsystem) → `/models/A/subsystems/B`. Unit
 * warnings carry this as their `location`, and `validate()` uses it verbatim as
 * the structural error's `path`, so the emitted path is the same JSON Pointer
 * the shared corpus pins.
 */
function componentPointer(kind: string, scopedName: string): string {
  return `/${kind}/${scopedName.split('.').join('/subsystems/')}`
}

/**
 * True when `lhs` is a derivative whose independent variable carries no declared
 * units — the case where {@link derivativeTimeMismatch} applies instead of the
 * plain LHS-vs-RHS comparison.
 */
function derivativeOfUndeclaredTime(
  lhs: Expression,
  unitBindings: Map<string, ParsedUnit>,
): boolean {
  if (typeof lhs !== 'object' || lhs === null || isNumericLiteral(lhs)) return false
  const node = lhs as ExpressionNode
  if (node.op !== 'D' || !node.args || node.args.length !== 1) return false
  return !unitBindings.has(node.wrt || 't')
}

/**
 * The derivative rule for an equation `D(x, wrt=t) = rhs` whose independent
 * variable `t` is NOT declared, and whose dimension is therefore unknown.
 *
 * `checkDimensions` leaves such a derivative indeterminate rather than assuming
 * seconds (see the `D` arm), which is what stops a nondimensionalized model
 * from being falsely rejected. But indeterminate is not the same as
 * unconstrained: `t` is the independent TIME variable, so whatever unit the
 * author has in mind, its dimension is a pure power of time. Consistency
 * therefore requires
 *
 *     [x] / [t] = [rhs]   ⟹   [t] = [x] / [rhs]
 *
 * to be satisfiable with `[t] = s^k` for some k — i.e. `[x]/[rhs]` must have NO
 * non-time component. When it does, no choice of time unit can reconcile the
 * two sides and the equation is provably inconsistent.
 *
 * This is what keeps `tests/invalid/units_incompatible_assignment.esm` (a
 * `m/s` state assigned a `kg` expression, with `t` undeclared) rejected, while
 * accepting `D(u) = F_in` with `u` and `F_in` both dimensionless (ratio `s^0`).
 *
 * Returns the offending message, or `null` when there is nothing to prove.
 */
function derivativeTimeMismatch(
  lhsStateDims: ParsedUnit | null,
  rhsDims: ParsedUnit | null,
): string | null {
  if (lhsStateDims === null || rhsDims === null) return null
  const ratio = divideUnits(lhsStateDims, rhsDims)
  for (const [key, value] of Object.entries(ratio.dims)) {
    if (key === 's') continue
    if (value) {
      return (
        `Dimensional mismatch in derivative equation: no time unit can reconcile ` +
        `d(${formatDims(lhsStateDims.dims)})/dt with ${formatDims(rhsDims.dims)} ` +
        `(their ratio ${formatDims(ratio.dims)} is not a power of time)`
      )
    }
  }
  return null
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
