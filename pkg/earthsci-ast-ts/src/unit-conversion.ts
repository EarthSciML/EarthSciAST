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

  // Frequency (Go's registry has Hz; the two tables agree).
  Hz: { dims: { s: -1 }, scale: 1 },
  kHz: { dims: { s: -1 }, scale: 1e3 },
  MHz: { dims: { s: -1 }, scale: 1e6 },

  // NO ELECTROMAGNETIC UNITS (V, T, F, Ohm, coulomb). This is deliberate, and
  // it is not an oversight to be "fixed" by adding them.
  //
  // `C` in this table is CELSIUS, not coulomb — a choice ESM shares with the Go
  // reference registry, which spells it out (`r["C"] = r["K"] // coulomb
  // disabled`). Charge is therefore not expressible, so an EM quantity can
  // never be given a coherent dimension here: adding V/T/F/Ohm would make
  // `q * E` *determinate and wrong* (Celsius × volt) instead of leaving it
  // UNKNOWN, and a determinate-and-wrong dimension is exactly what manufactures
  // the false mismatches this module was rewritten to stop emitting. Leaving
  // them unknown makes the EM expressions indeterminate and skipped, matching
  // Go. (`T` was the sharpest trap: as tesla it silently shadowed every model
  // variable named `T` — temperature — in the shared binding table.)

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
 * Recursive-descent parser over the grammar (ported from the Go reference
 * implementation, `pkg/earthsci-ast-go/pkg/esm/units.go`, so the five bindings
 * agree on how a unit string associates):
 *
 * ```
 *   unit := term ( ('*' | '/') term )*
 *   term := atom ( '^' integer )?
 *   atom := number | symbol | '(' unit ')'
 * ```
 *
 * `*` and `/` share one precedence level and associate LEFT — so `kg/m*s` is
 * `(kg/m)*s` = kg·s·m⁻¹, NOT kg·m⁻¹·s⁻¹. (The previous implementation split on
 * `/` and treated *everything* after the first `/` as denominator, which
 * silently disagreed with every other binding.) Grouping with parentheses is
 * supported, so the ordinary earth-science spellings `J/(mol*K)` and
 * `cm^3/(molec*s)` parse correctly instead of being rejected token-by-token.
 *
 * Whitespace is ignored. Offset-based units (`C`, `Celsius`) may only appear as
 * the sole term at power +1; composing one with any other unit is an error.
 *
 * @throws {UnitConversionError} on unknown unit names, malformed tokens,
 *   unbalanced parentheses, trailing input, or misused offset units.
 */
export function parseUnitForConversion(unitStr: string): ParsedUnit {
  const trimmed = (unitStr ?? '').trim()
  if (trimmed === '' || trimmed === 'dimensionless' || trimmed === '1') {
    return { dims: {}, scale: 1 }
  }

  const parser = new UnitParser(trimmed)
  const result = parser.parseUnit()
  parser.expectEnd()

  pruneZeroDims(result.dims)
  return result
}

function pruneZeroDims(dims: CanonicalDims): void {
  for (const key of Object.keys(dims) as (keyof CanonicalDims)[]) {
    if (dims[key] === 0) delete dims[key]
  }
}

/**
 * An offset unit (degC) denotes an affine scale, so it has no meaning as a
 * factor inside a product, a quotient, or a power: `degC*m` and `1/degC` are
 * not units. Combining forms funnel through here so the rejection is stated
 * once rather than re-derived at each call site.
 */
function assertNoOffset(u: ParsedUnit, context: string): void {
  if (u.offset !== undefined && u.offset !== 0) {
    throw new UnitConversionError(`Offset-based unit cannot be ${context}`)
  }
}

function multiplyParsed(a: ParsedUnit, b: ParsedUnit): ParsedUnit {
  assertNoOffset(a, 'composed with other units')
  assertNoOffset(b, 'composed with other units')
  const dims: CanonicalDims = { ...a.dims }
  for (const [dim, power] of Object.entries(b.dims)) {
    const key = dim as keyof CanonicalDims
    dims[key] = (dims[key] ?? 0) + (power as number)
  }
  return { dims, scale: a.scale * b.scale }
}

function divideParsed(a: ParsedUnit, b: ParsedUnit): ParsedUnit {
  assertNoOffset(a, 'composed with other units')
  assertNoOffset(b, 'placed in a denominator')
  const dims: CanonicalDims = { ...a.dims }
  for (const [dim, power] of Object.entries(b.dims)) {
    const key = dim as keyof CanonicalDims
    dims[key] = (dims[key] ?? 0) - (power as number)
  }
  return { dims, scale: a.scale / b.scale }
}

function powerParsed(u: ParsedUnit, exp: number): ParsedUnit {
  if (exp === 1) return u
  assertNoOffset(u, 'raised to a power')
  const dims: CanonicalDims = {}
  for (const [dim, power] of Object.entries(u.dims)) {
    dims[dim as keyof CanonicalDims] = (power as number) * exp
  }
  return { dims, scale: Math.pow(u.scale, exp) }
}

const isIdentStart = (c: string): boolean => /[A-Za-z_%]/.test(c)
const isIdentCont = (c: string): boolean => /[A-Za-z0-9_]/.test(c)
const isDigit = (c: string): boolean => c >= '0' && c <= '9'

class UnitParser {
  private pos = 0

  constructor(private readonly src: string) {}

  private skipSpace(): void {
    while (this.pos < this.src.length && /\s/.test(this.src[this.pos])) this.pos++
  }

  private peek(): string {
    this.skipSpace()
    return this.pos < this.src.length ? this.src[this.pos] : ''
  }

  expectEnd(): void {
    if (this.peek() !== '') {
      throw new UnitConversionError(
        `Cannot parse unit "${this.src}": unexpected "${this.src.slice(this.pos)}" at position ${this.pos}`,
      )
    }
  }

  /** unit := term ( ('*' | '/') term )* — left-associative. */
  parseUnit(): ParsedUnit {
    let result = this.parseTerm()
    for (;;) {
      const c = this.peek()
      if (c !== '*' && c !== '/') break
      this.pos++
      const next = this.parseTerm()
      result = c === '*' ? multiplyParsed(result, next) : divideParsed(result, next)
    }
    return result
  }

  /** term := atom ( '^' integer )? */
  private parseTerm(): ParsedUnit {
    const atom = this.parseAtom()
    if (this.peek() !== '^') return atom
    this.pos++
    return powerParsed(atom, this.parseInt())
  }

  /** atom := number | symbol | '(' unit ')' */
  private parseAtom(): ParsedUnit {
    this.skipSpace()
    if (this.pos >= this.src.length) {
      throw new UnitConversionError(`Cannot parse unit "${this.src}": unexpected end of input`)
    }

    const c = this.src[this.pos]

    if (c === '(') {
      this.pos++
      const inner = this.parseUnit()
      if (this.peek() !== ')') {
        throw new UnitConversionError(`Cannot parse unit "${this.src}": missing ")"`)
      }
      this.pos++
      return inner
    }

    // A bare number is a dimensionless scalar factor ("1" → identity, and e.g.
    // the leading "1" of "1/s").
    if (isDigit(c)) {
      const start = this.pos
      while (
        this.pos < this.src.length &&
        (isDigit(this.src[this.pos]) || this.src[this.pos] === '.')
      ) {
        this.pos++
      }
      const text = this.src.slice(start, this.pos)
      const value = Number(text)
      if (!Number.isFinite(value)) {
        throw new UnitConversionError(`Cannot parse unit "${this.src}": invalid number "${text}"`)
      }
      return { dims: {}, scale: value }
    }

    if (!isIdentStart(c)) {
      throw new UnitConversionError(
        `Cannot parse unit "${this.src}": unexpected "${c}" at position ${this.pos}`,
      )
    }

    const start = this.pos
    this.pos++
    while (this.pos < this.src.length && isIdentCont(this.src[this.pos])) this.pos++
    const name = this.src.slice(start, this.pos)

    const spec = UNIT_TABLE[name]
    if (!spec) {
      throw new UnitConversionError(`Unknown unit "${name}"`)
    }
    const parsed: ParsedUnit = { dims: { ...spec.dims }, scale: spec.scale }
    if (spec.offset !== undefined && spec.offset !== 0) parsed.offset = spec.offset
    return parsed
  }

  /** A signed integer exponent. Fractional exponents are not representable. */
  private parseInt(): number {
    this.skipSpace()
    const start = this.pos
    if (this.pos < this.src.length && (this.src[this.pos] === '-' || this.src[this.pos] === '+')) {
      this.pos++
    }
    const digitsStart = this.pos
    while (this.pos < this.src.length && isDigit(this.src[this.pos])) this.pos++
    if (this.pos === digitsStart) {
      throw new UnitConversionError(
        `Cannot parse unit "${this.src}": expected integer exponent at position ${start}`,
      )
    }
    return parseInt(this.src.slice(start, this.pos), 10)
  }
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
