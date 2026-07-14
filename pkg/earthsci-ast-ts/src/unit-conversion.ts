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

/**
 * Exponents over the SI base dimensions — the SAME eight axes, in the same
 * roles, as the Go reference's `Dimension` vector (`m kg s mol K A cd rad`),
 * which is the cross-binding contract for what a unit string MEANS.
 *
 * `molec` is deliberately NOT an axis. A count of discrete things carries no
 * physical dimension, so `molec` (and `individuals`, `vehicles`, `units`,
 * `count`) is a DIMENSIONLESS unit in the table below — which is what makes
 * `molec/cm^3` compare equal to `1/cm^3`, as every other binding has it. Giving
 * counts their own axis made TS the only binding that could report a mismatch
 * between the two spellings of a number density.
 */
export interface CanonicalDims {
  kg?: number
  m?: number
  s?: number
  K?: number
  mol?: number
  A?: number
  cd?: number
  rad?: number
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

/**
 * The unit registry. Every symbol the five bindings recognize, and nothing else.
 *
 * THE CONTRACT. This table is the TypeScript half of a CROSS-BINDING contract
 * whose reference statement is Go's `unitRegistry`
 * (`pkg/earthsci-ast-go/pkg/esm/units.go`). The two must agree symbol for symbol
 * and dimension for dimension, because an unresolvable unit string is a HARD
 * ERROR (`unparseable_unit`, see units.ts): a symbol one binding knows and
 * another does not is not a difference of opinion, it is one binding rejecting a
 * file the other accepts.
 *
 * That cuts BOTH ways, and the second edge is the one that drew blood. A unit
 * missing from the table is not "conservatively unknown" — under a hard-error
 * policy it FAILS THE FILE. `V`, `T`, `F` and `Ohm` were once deleted from here
 * in the name of "parity with Go", whose table lacked them; but
 * `tests/valid/units_dimensional_analysis.esm` declares `E: "V/m"`, `B: "T"` and
 * `epsilon0: "F/m"` — real SI units, in a fixture pinned VALID. The absence was
 * Go's GAP, not TS's excess, and copying it turned a legitimate file into a
 * rejected one. Go has since added them. Adding a real unit is safe; removing
 * one is a false rejection waiting to happen.
 *
 * `C` IS THE COULOMB. Not Celsius. Binding it to Celsius silently injected a
 * temperature dimension into every electromagnetic expression: a charge `q: "C"`
 * times a field `E: "V/m"` — a force, declared `"N"` — came out as
 * `kg*m*K/(s^3*A)`. Celsius has its own unambiguous spellings (`degC`, `°C`, and
 * TS's long-form `Celsius`), so the SI reading is the only one that can be
 * pinned as a contract.
 *
 * NO SI-PREFIX MECHANISM. This is a flat table: `km` is an entry, not `k` + `m`.
 * A prefix parser would accept `kkg`, `mmol` as milli-mol *and* metre-mol, and
 * generally invent symbols no binding agrees on.
 *
 * TS-ONLY ALIASES. A handful of entries below (`meter(s)`, `sec`/`second(s)`,
 * `minute`, `hour`, `Kelvin`, `Celsius`, `liter`, `ratio`, `percent`, `kHz`,
 * `MHz`) are long-form spellings Go's table does not carry. They are kept
 * deliberately: each denotes a REAL unit, so rejecting it would be exactly the
 * false rejection described above (`tests/valid` uses `meters`), and being more
 * permissive than the contract can never fail a file the contract accepts. They
 * are TS's standing recommendation for the shared table, not a divergence in
 * what any shared symbol MEANS.
 */
const UNIT_TABLE: Record<string, UnitSpec> = {
  // ---- SI base ----
  m: { dims: { m: 1 }, scale: 1 },
  kg: { dims: { kg: 1 }, scale: 1 },
  s: { dims: { s: 1 }, scale: 1 },
  mol: { dims: { mol: 1 }, scale: 1 },
  K: { dims: { K: 1 }, scale: 1 },
  A: { dims: { A: 1 }, scale: 1 },
  cd: { dims: { cd: 1 }, scale: 1 },
  rad: { dims: { rad: 1 }, scale: 1 },

  // ---- Mass ----
  g: { dims: { kg: 1 }, scale: 1e-3 },
  mg: { dims: { kg: 1 }, scale: 1e-6 },
  ug: { dims: { kg: 1 }, scale: 1e-9 },

  // ---- Length ----
  dm: { dims: { m: 1 }, scale: 1e-1 },
  cm: { dims: { m: 1 }, scale: 1e-2 },
  mm: { dims: { m: 1 }, scale: 1e-3 },
  um: { dims: { m: 1 }, scale: 1e-6 },
  nm: { dims: { m: 1 }, scale: 1e-9 },
  km: { dims: { m: 1 }, scale: 1e3 },

  // ---- Time ----
  ms: { dims: { s: 1 }, scale: 1e-3 },
  us: { dims: { s: 1 }, scale: 1e-6 },
  ns: { dims: { s: 1 }, scale: 1e-9 },
  min: { dims: { s: 1 }, scale: 60 },
  h: { dims: { s: 1 }, scale: 3600 },
  hr: { dims: { s: 1 }, scale: 3600 },
  day: { dims: { s: 1 }, scale: 86400 },
  yr: { dims: { s: 1 }, scale: 365.25 * 86400 },
  year: { dims: { s: 1 }, scale: 365.25 * 86400 },

  // ---- Volume ----
  L: { dims: { m: 3 }, scale: 1e-3 },
  l: { dims: { m: 3 }, scale: 1e-3 },
  mL: { dims: { m: 3 }, scale: 1e-6 },

  // ---- Amount of substance ----
  kmol: { dims: { mol: 1 }, scale: 1e3 },
  mmol: { dims: { mol: 1 }, scale: 1e-3 },
  umol: { dims: { mol: 1 }, scale: 1e-6 },
  nmol: { dims: { mol: 1 }, scale: 1e-9 },
  // Molarity: mol/L.
  M: { dims: { mol: 1, m: -3 }, scale: 1e3 },

  // ---- Derived ----
  Hz: { dims: { s: -1 }, scale: 1 },
  N: { dims: { kg: 1, m: 1, s: -2 }, scale: 1 },
  Pa: { dims: { kg: 1, m: -1, s: -2 }, scale: 1 },
  J: { dims: { kg: 1, m: 2, s: -2 }, scale: 1 },
  kJ: { dims: { kg: 1, m: 2, s: -2 }, scale: 1e3 },
  cal: { dims: { kg: 1, m: 2, s: -2 }, scale: 4.184 },
  kcal: { dims: { kg: 1, m: 2, s: -2 }, scale: 4184 },
  W: { dims: { kg: 1, m: 2, s: -3 }, scale: 1 },
  kW: { dims: { kg: 1, m: 2, s: -3 }, scale: 1e3 },
  MW: { dims: { kg: 1, m: 2, s: -3 }, scale: 1e6 },

  // ---- Pressure ----
  atm: { dims: { kg: 1, m: -1, s: -2 }, scale: 101325 },
  bar: { dims: { kg: 1, m: -1, s: -2 }, scale: 1e5 },
  hPa: { dims: { kg: 1, m: -1, s: -2 }, scale: 100 },
  kPa: { dims: { kg: 1, m: -1, s: -2 }, scale: 1e3 },
  mbar: { dims: { kg: 1, m: -1, s: -2 }, scale: 100 },
  Torr: { dims: { kg: 1, m: -1, s: -2 }, scale: 101325 / 760 },
  mmHg: { dims: { kg: 1, m: -1, s: -2 }, scale: 133.322387415 },
  psi: { dims: { kg: 1, m: -1, s: -2 }, scale: 6894.757293168 },

  // ---- Energy / power ----
  erg: { dims: { kg: 1, m: 2, s: -2 }, scale: 1e-7 },
  BTU: { dims: { kg: 1, m: 2, s: -2 }, scale: 1055.05585262 },
  Wh: { dims: { kg: 1, m: 2, s: -2 }, scale: 3600 },
  kWh: { dims: { kg: 1, m: 2, s: -2 }, scale: 3.6e6 },

  // ---- Electromagnetic ----
  // Derived from the SI base, exactly as Go composes them:
  //   C   = A*s                     (COULOMB — see the header note)
  //   V   = W/A   = kg*m^2/(s^3*A)
  //   Ohm = V/A   = kg*m^2/(s^3*A^2)
  //   F   = C/V   = A^2*s^4/(kg*m^2)
  //   T   = V*s/m^2 = kg/(s^2*A)
  C: { dims: { A: 1, s: 1 }, scale: 1 },
  V: { dims: { kg: 1, m: 2, s: -3, A: -1 }, scale: 1 },
  Ohm: { dims: { kg: 1, m: 2, s: -3, A: -2 }, scale: 1 },
  F: { dims: { kg: -1, m: -2, s: 4, A: 2 }, scale: 1 },
  T: { dims: { kg: 1, s: -2, A: -1 }, scale: 1 },

  // ---- Temperature ----
  // Celsius and Fahrenheit are AFFINE scales. The offset is modelled here (Go
  // does not model it) purely so `convertUnits` can do the arithmetic; it is
  // dropped the moment the unit is composed, where the interval reading is the
  // correct one — see `intervalOf`.
  degC: { dims: { K: 1 }, scale: 1, offset: 273.15 },
  degF: { dims: { K: 1 }, scale: 5 / 9, offset: 459.67 * (5 / 9) },

  // ---- Plane angle ----
  deg: { dims: { rad: 1 }, scale: Math.PI / 180 },

  // ---- Mixing ratios (dimensionless) ----
  // ppmv/ppbv/pptv are volume-mixing-ratio spellings of the same quantity under
  // the ideal-gas approximation — identical dims and scale.
  ppm: { dims: {}, scale: 1e-6 },
  ppmv: { dims: {}, scale: 1e-6 },
  ppb: { dims: {}, scale: 1e-9 },
  ppbv: { dims: {}, scale: 1e-9 },
  ppt: { dims: {}, scale: 1e-12 },
  pptv: { dims: {}, scale: 1e-12 },

  // ---- Count nouns (dimensionless) ----
  // A count of discrete things carries no physical dimension — which is what
  // makes `molec/cm^3` equal `1/cm^3`, the treatment `molec` has always had in
  // every other binding. They are REAL unit names in the shared corpus
  // (`individuals/km^2`, `vehicles/km^2`, `units/L`), and an unresolvable unit
  // string is now a hard error, so omitting them would falsely reject those
  // files.
  molec: { dims: {}, scale: 1 },
  individuals: { dims: {}, scale: 1 },
  vehicles: { dims: {}, scale: 1 },
  units: { dims: {}, scale: 1 },
  count: { dims: {}, scale: 1 },

  // ---- Earth science ----
  // 1 Dobson Unit = 2.6867e20 molec/m^2; `molec` is dimensionless, so a column
  // amount is an inverse area.
  Dobson: { dims: { m: -2 }, scale: 2.6867e20 },
  DU: { dims: { m: -2 }, scale: 2.6867e20 },

  // ---- Dimensionless spellings ----
  dimensionless: { dims: {}, scale: 1 },

  // ---- TS-only long-form aliases (see the header note) ----
  meter: { dims: { m: 1 }, scale: 1 },
  meters: { dims: { m: 1 }, scale: 1 },
  sec: { dims: { s: 1 }, scale: 1 },
  second: { dims: { s: 1 }, scale: 1 },
  seconds: { dims: { s: 1 }, scale: 1 },
  minute: { dims: { s: 1 }, scale: 60 },
  hour: { dims: { s: 1 }, scale: 3600 },
  Kelvin: { dims: { K: 1 }, scale: 1 },
  Celsius: { dims: { K: 1 }, scale: 1, offset: 273.15 },
  liter: { dims: { m: 3 }, scale: 1e-3 },
  ratio: { dims: {}, scale: 1 },
  percent: { dims: {}, scale: 0.01 },
  kHz: { dims: { s: -1 }, scale: 1e3 },
  MHz: { dims: { s: -1 }, scale: 1e6 },
}

/**
 * Fold the non-ASCII and alternate spellings the shared corpus uses into the
 * ASCII grammar the parser implements. A pure SPELLING normalization — every
 * target already exists in {@link UNIT_TABLE}, no unit is invented here:
 *
 *   - U+00B5 MICRO SIGN and U+03BC GREEK SMALL LETTER MU → `u` (`μg` → `ug`)
 *   - `°C` / `°F` / `°K` → `degC` / `degF` / `K`, and a bare `°` → `deg`
 *
 * Mirrors Go's `normalizeUnitString`, and runs before the scanner, which only
 * recognizes ASCII identifier characters.
 */
function normalizeUnitString(s: string): string {
  if (!/[µμ°]/.test(s)) return s
  return s
    .replace(/°C/g, 'degC')
    .replace(/°F/g, 'degF')
    .replace(/°K/g, 'K')
    .replace(/°/g, 'deg')
    .replace(/[µμ]/g, 'u')
}

/**
 * Parse a unit string into canonical SI dimensions plus scale (and optional offset).
 *
 * Recursive-descent parser over the grammar of the Go reference implementation
 * (`pkg/earthsci-ast-go/pkg/esm/units.go`), so the bindings agree on how a unit
 * string associates:
 *
 * ```
 *   unit := term ( ('*' | '/')? term )*
 *   term := atom ( ('^' | '**') integer )?
 *   atom := number | symbol | '(' unit ')'
 * ```
 *
 * `*` and `/` share one precedence level and associate LEFT — so `kg/m*s` is
 * `(kg/m)*s` = kg·s·m⁻¹, NOT kg·m⁻¹·s⁻¹, and `a/b/c` is `a/(b*c)`. Grouping with
 * parentheses is supported, so the ordinary earth-science spellings `J/(mol*K)`
 * and `cm^3/(molec*s)` parse.
 *
 * WHITESPACE BETWEEN TWO TERMS IS MULTIPLICATION — the SI style `kg m^2 s^-2`
 * and the corpus's `ppb^-1 s^-1`. The scanner is greedy over identifier
 * characters, so `ms` stays ONE symbol (millisecond); juxtaposition can only
 * arise across a real token boundary. `**` is accepted as a synonym for `^` (the
 * Python/pint spelling, e.g. the corpus's `Pa*m**3`).
 *
 * The empty string, `"1"` and `"dimensionless"` are the dimensionless unit.
 * Non-ASCII spellings (`μg`, `°C`) are normalized first — see
 * {@link normalizeUnitString}.
 *
 * @throws {UnitConversionError} on unknown unit names, malformed tokens,
 *   unbalanced parentheses, or trailing input.
 */
export function parseUnitForConversion(unitStr: string): ParsedUnit {
  const trimmed = (unitStr ?? '').trim()
  if (trimmed === '' || trimmed === 'dimensionless' || trimmed === '1') {
    return { dims: {}, scale: 1 }
  }

  const parser = new UnitParser(normalizeUnitString(trimmed))
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
 * The INTERVAL reading of a unit: the same dimension and scale, with any affine
 * offset dropped.
 *
 * An affine unit (`degC`, `degF`) denotes a POINT on a scale only when it stands
 * alone. The moment it is composed — `degC/min` is a warming RATE, `J/degC` a
 * heat capacity — what is meant is the INTERVAL, and ΔdegC is exactly ΔK. That
 * is why composing here degrades to the interval instead of throwing: `°C/min`
 * is an ordinary, legitimate declaration in the corpus, and an unparseable unit
 * string is now a HARD ERROR (units.ts `unparseable_unit`), so refusing to parse
 * it would fail a valid file. It also restores agreement with Go, whose registry
 * carries no offset at all (`degC` is plain `K`) and parses every composition.
 *
 * The offset survives only where it is meaningful and needed: a standalone unit,
 * which is the sole form `convertUnits` applies it to.
 */
function intervalOf(u: ParsedUnit): ParsedUnit {
  return { dims: u.dims, scale: u.scale }
}

function multiplyParsed(a: ParsedUnit, b: ParsedUnit): ParsedUnit {
  const dims: CanonicalDims = { ...a.dims }
  for (const [dim, power] of Object.entries(b.dims)) {
    const key = dim as keyof CanonicalDims
    dims[key] = (dims[key] ?? 0) + (power as number)
  }
  return { dims, scale: intervalOf(a).scale * intervalOf(b).scale }
}

function divideParsed(a: ParsedUnit, b: ParsedUnit): ParsedUnit {
  const dims: CanonicalDims = { ...a.dims }
  for (const [dim, power] of Object.entries(b.dims)) {
    const key = dim as keyof CanonicalDims
    dims[key] = (dims[key] ?? 0) - (power as number)
  }
  return { dims, scale: intervalOf(a).scale / intervalOf(b).scale }
}

function powerParsed(u: ParsedUnit, exp: number): ParsedUnit {
  if (exp === 1) return u
  const dims: CanonicalDims = {}
  for (const [dim, power] of Object.entries(u.dims)) {
    dims[dim as keyof CanonicalDims] = (power as number) * exp
  }
  return { dims, scale: Math.pow(intervalOf(u).scale, exp) }
}

const isIdentStart = (c: string): boolean => /[A-Za-z_%]/.test(c)
const isIdentCont = (c: string): boolean => /[A-Za-z0-9_]/.test(c)
const isDigit = (c: string): boolean => c >= '0' && c <= '9'
/** Can `c` begin an atom? The lookahead that drives implicit multiplication. */
const startsAtom = (c: string): boolean => isIdentStart(c) || isDigit(c) || c === '('

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

  /**
   * unit := term ( ('*' | '/')? term )* — left-associative.
   *
   * An OMITTED operator is multiplication: `kg m^2 s^-2`, `ppb^-1 s^-1`. `peek()`
   * has already skipped the separating whitespace by the time we look, and the
   * scanner is greedy over identifier characters, so `ms` is still one symbol
   * (millisecond) — juxtaposition can only arise across a real token boundary.
   */
  parseUnit(): ParsedUnit {
    let result = this.parseTerm()
    for (;;) {
      const c = this.peek()
      if (c === '*' || c === '/') {
        this.pos++
        const next = this.parseTerm()
        result = c === '*' ? multiplyParsed(result, next) : divideParsed(result, next)
        continue
      }
      if (startsAtom(c)) {
        result = multiplyParsed(result, this.parseTerm())
        continue
      }
      return result
    }
  }

  /**
   * term := atom ( ('^' | '**') integer )?
   *
   * `**` is the Python/pint spelling of `^` (`Pa*m**3`). `peek()` skips
   * whitespace, so the second `*` is tested against the already-skipped position.
   */
  private parseTerm(): ParsedUnit {
    const atom = this.parseAtom()
    const c = this.peek()
    if (c === '^') {
      this.pos++
    } else if (c === '*' && this.src[this.pos + 1] === '*') {
      this.pos += 2
    } else {
      return atom
    }
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
