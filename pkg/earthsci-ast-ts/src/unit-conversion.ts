/**
 * Runtime unit conversion for ESM format.
 *
 * Complements `units.ts` (which performs dimensional analysis) by adding
 * numeric value conversion between compatible units: `convertUnits(1, "km", "m")` → 1000.
 *
 * Representation: each unit parses to a canonical SI-base dimension vector plus a
 * multiplicative scale factor and (for temperature) an additive offset. Conversion
 * goes through SI base: `value_SI = value * scale + offset`, then `target = (value_SI - offset_t) / scale_t`.
 *
 * This module is intentionally independent of the `DimensionalRep` used by `units.ts`
 * — that representation lacks scale tracking and treats `cm`, `J`, `Pa` as base
 * dimensions, which would make extension invasive.
 */

export interface CanonicalDims {
  kg?: number
  m?: number
  s?: number
  K?: number
  mol?: number
  molec?: number
  A?: number
  cd?: number
}

export interface ParsedUnit {
  dims: CanonicalDims
  scale: number
  offset?: number
}

export class UnitConversionError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'UnitConversionError'
  }
}

interface UnitSpec {
  dims: CanonicalDims
  scale: number
  offset?: number
}

const UNIT_TABLE: Record<string, UnitSpec> = {
  // Length (base: m)
  m: { dims: { m: 1 }, scale: 1 },
  meter: { dims: { m: 1 }, scale: 1 },
  meters: { dims: { m: 1 }, scale: 1 },
  km: { dims: { m: 1 }, scale: 1000 },
  cm: { dims: { m: 1 }, scale: 0.01 },
  mm: { dims: { m: 1 }, scale: 1e-3 },
  um: { dims: { m: 1 }, scale: 1e-6 },
  nm: { dims: { m: 1 }, scale: 1e-9 },

  // Mass (base: kg)
  kg: { dims: { kg: 1 }, scale: 1 },
  g: { dims: { kg: 1 }, scale: 1e-3 },
  mg: { dims: { kg: 1 }, scale: 1e-6 },
  ug: { dims: { kg: 1 }, scale: 1e-9 },

  // Time (base: s)
  s: { dims: { s: 1 }, scale: 1 },
  sec: { dims: { s: 1 }, scale: 1 },
  second: { dims: { s: 1 }, scale: 1 },
  seconds: { dims: { s: 1 }, scale: 1 },
  ms: { dims: { s: 1 }, scale: 1e-3 },
  min: { dims: { s: 1 }, scale: 60 },
  minute: { dims: { s: 1 }, scale: 60 },
  hr: { dims: { s: 1 }, scale: 3600 },
  hour: { dims: { s: 1 }, scale: 3600 },
  day: { dims: { s: 1 }, scale: 86400 },
  year: { dims: { s: 1 }, scale: 31536000 },

  // Temperature (base: K — Celsius carries an offset)
  K: { dims: { K: 1 }, scale: 1 },
  Kelvin: { dims: { K: 1 }, scale: 1 },
  C: { dims: { K: 1 }, scale: 1, offset: 273.15 },
  degC: { dims: { K: 1 }, scale: 1, offset: 273.15 },
  Celsius: { dims: { K: 1 }, scale: 1, offset: 273.15 },

  // Amount of substance
  mol: { dims: { mol: 1 }, scale: 1 },
  mmol: { dims: { mol: 1 }, scale: 1e-3 },
  umol: { dims: { mol: 1 }, scale: 1e-6 },

  // Molecular count (ESM convention — kept distinct from mol, as in units.ts)
  molec: { dims: { molec: 1 }, scale: 1 },

  // Current, luminous
  A: { dims: { A: 1 }, scale: 1 },
  cd: { dims: { cd: 1 }, scale: 1 },

  // Derived mechanical units
  N: { dims: { kg: 1, m: 1, s: -2 }, scale: 1 },
  J: { dims: { kg: 1, m: 2, s: -2 }, scale: 1 },
  kJ: { dims: { kg: 1, m: 2, s: -2 }, scale: 1000 },
  cal: { dims: { kg: 1, m: 2, s: -2 }, scale: 4.184 },
  kcal: { dims: { kg: 1, m: 2, s: -2 }, scale: 4184 },
  W: { dims: { kg: 1, m: 2, s: -3 }, scale: 1 },
  Pa: { dims: { kg: 1, m: -1, s: -2 }, scale: 1 },
  hPa: { dims: { kg: 1, m: -1, s: -2 }, scale: 100 },
  kPa: { dims: { kg: 1, m: -1, s: -2 }, scale: 1000 },
  bar: { dims: { kg: 1, m: -1, s: -2 }, scale: 1e5 },
  atm: { dims: { kg: 1, m: -1, s: -2 }, scale: 101325 },

  // Volume
  L: { dims: { m: 3 }, scale: 1e-3 },
  liter: { dims: { m: 3 }, scale: 1e-3 },
  mL: { dims: { m: 3 }, scale: 1e-6 },

  // Dimensionless scalings
  dimensionless: { dims: {}, scale: 1 },
  ratio: { dims: {}, scale: 1 },
  percent: { dims: {}, scale: 0.01 },
  // ESM mole-fraction family (see docs/units-standard.md).
  // ppmv/ppbv/pptv are volume-mixing-ratio aliases of ppm/ppb/ppt under the
  // ideal-gas approximation — they must parse to identical dims and scale.
  ppm: { dims: {}, scale: 1e-6 },
  ppmv: { dims: {}, scale: 1e-6 },
  ppb: { dims: {}, scale: 1e-9 },
  ppbv: { dims: {}, scale: 1e-9 },
  ppt: { dims: {}, scale: 1e-12 },
  pptv: { dims: {}, scale: 1e-12 },

  // Earth science: 1 Dobson Unit = 2.6867e20 molec/m^2
  Dobson: { dims: { molec: 1, m: -2 }, scale: 2.6867e20 },
  DU: { dims: { molec: 1, m: -2 }, scale: 2.6867e20 },
}

/**
 * Parse a unit string into canonical SI dimensions plus scale (and optional offset).
 *
 * Accepts compound expressions like `"kg*m/s^2"`, `"molec/cm^3"`, `"cm^3/molec/s"`.
 * Offset-based units (`C`, `Celsius`) may only appear as the sole term at power +1.
 *
 * @throws {UnitConversionError} on unknown unit names, malformed tokens, or misused offset units.
 */
export function parseUnitForConversion(unitStr: string): ParsedUnit {
  const trimmed = (unitStr ?? '').trim()
  if (trimmed === '' || trimmed === 'dimensionless' || trimmed === '1') {
    return { dims: {}, scale: 1 }
  }

  const result: ParsedUnit = { dims: {}, scale: 1 }
  let termCount = 0

  const parts = trimmed.split('/')
  const numeratorStr = parts[0] || '1'

  for (const factor of numeratorStr.split('*')) {
    if (parseTerm(factor.trim(), result, +1)) termCount++
  }
  for (const denominatorStr of parts.slice(1)) {
    for (const factor of denominatorStr.split('*')) {
      if (parseTerm(factor.trim(), result, -1)) termCount++
    }
  }

  if (result.offset !== undefined && termCount !== 1) {
    throw new UnitConversionError(
      `Offset-based unit in "${unitStr}" cannot be composed with other units`,
    )
  }

  for (const key of Object.keys(result.dims) as (keyof CanonicalDims)[]) {
    if (result.dims[key] === 0) delete result.dims[key]
  }

  return result
}

function parseTerm(token: string, result: ParsedUnit, sign: number): boolean {
  if (!token || token === '1') return false

  const match = /^([A-Za-z%][A-Za-z0-9_]*)(?:\^(-?\d+))?$/.exec(token)
  if (!match) {
    throw new UnitConversionError(`Cannot parse unit token "${token}"`)
  }

  const name = match[1]
  const exp = match[2] ? parseInt(match[2], 10) : 1
  const signedExp = sign * exp

  const spec = UNIT_TABLE[name]
  if (!spec) {
    throw new UnitConversionError(`Unknown unit "${name}"`)
  }

  if (spec.offset !== undefined && spec.offset !== 0) {
    if (signedExp !== 1) {
      throw new UnitConversionError(
        `Offset-based unit "${name}" cannot be raised to a power or placed in denominator`,
      )
    }
    result.offset = spec.offset
  }

  for (const [dim, power] of Object.entries(spec.dims)) {
    const key = dim as keyof CanonicalDims
    result.dims[key] = (result.dims[key] || 0) + (power as number) * signedExp
  }

  result.scale *= Math.pow(spec.scale, signedExp)
  return true
}

/**
 * Convert a numeric value from one unit string to another.
 *
 * @example
 *   convertUnits(1, 'km', 'm')            // 1000
 *   convertUnits(0, 'Celsius', 'K')       // 273.15
 *   convertUnits(1, 'atm', 'Pa')          // 101325
 *   convertUnits(1, 'Dobson', 'molec/m^2') // 2.6867e20
 *
 * @throws {UnitConversionError} when the unit strings have incompatible dimensions
 *   or cannot be parsed.
 */
export function convertUnits(value: number, from: string, to: string): number {
  const fromSpec = parseUnitForConversion(from)
  const toSpec = parseUnitForConversion(to)

  if (!dimsEqual(fromSpec.dims, toSpec.dims)) {
    throw new UnitConversionError(
      `Cannot convert "${from}" to "${to}": incompatible dimensions ` +
        `(${formatDims(fromSpec.dims)} vs ${formatDims(toSpec.dims)})`,
    )
  }

  const valueInSI = value * fromSpec.scale + (fromSpec.offset ?? 0)
  return (valueInSI - (toSpec.offset ?? 0)) / toSpec.scale
}

/**
 * Report whether two unit strings represent compatible (same-dimension) quantities.
 * A non-throwing companion to `convertUnits`.
 */
export function unitsCompatible(a: string, b: string): boolean {
  try {
    const ap = parseUnitForConversion(a)
    const bp = parseUnitForConversion(b)
    return dimsEqual(ap.dims, bp.dims)
  } catch {
    return false
  }
}

function dimsEqual(a: CanonicalDims, b: CanonicalDims): boolean {
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
    else parts.push(`${key}^${value}`)
  }
  return parts.length > 0 ? parts.join('·') : 'dimensionless'
}
