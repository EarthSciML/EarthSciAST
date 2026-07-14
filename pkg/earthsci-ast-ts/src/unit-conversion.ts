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
 * LONG-FORM ALIASES ARE PART OF THE CONTRACT. The entries below (`meter(s)`,
 * `sec`/`second(s)`, `minute`, `hour`, `Kelvin`, `Celsius`, `liter`, `ratio`,
 * `percent`, `kHz`, `MHz`) began as TS-only spellings Go's table did not carry.
 * Each denotes a REAL unit, so rejecting one is exactly the false rejection
 * described above (`tests/valid` uses `meters`), and they have since been
 * ADOPTED into the shared canonical table rather than deleted. They are kept
 * here, and they are canonical.
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
  // The canonical spelling of the day is `day`. The one-letter `d` is
  // DELIBERATELY EXCLUDED from the §4.8.1 registry: a bare `d` reads as a deci-
  // prefix or as a differential, so accepting it would be a permissive
  // divergence from the shared table — the very thing the hard-error policy is
  // meant to eliminate. (`lib/calendar.esm` has been migrated to `day`.)
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
  // `molecule` is the long-form spelling of `molec` — the corpus writes
  // `cm³/molecule/s` for a bimolecular rate constant. Same dimension (none),
  // same scale.
  molecule: { dims: {}, scale: 1 },
  individuals: { dims: {}, scale: 1 },
  vehicles: { dims: {}, scale: 1 },
  units: { dims: {}, scale: 1 },
  count: { dims: {}, scale: 1 },

  // ---- Earth science ----
  // 1 Dobson Unit = 2.6867e20 molec/m^2; `molec` is dimensionless, so a column
  // amount is an inverse area. The scale is PINNED at 2.6867e20 across the
  // bindings (Go's 2.69e20 was a rounded, and wrong, value).
  Dobson: { dims: { m: -2 }, scale: 2.6867e20 },
  DU: { dims: { m: -2 }, scale: 2.6867e20 },
  // Practical Salinity Unit — salinity on the PSS-78 scale is a pure ratio, so
  // `psu` is dimensionless (ocean-model salinity fields declare it).
  psu: { dims: {}, scale: 1 },
  // Microatmosphere — the standard unit for seawater/air pCO2.
  uatm: { dims: { kg: 1, m: -1, s: -2 }, scale: 101325e-6 },

  // ---- Dimensionless spellings ----
  dimensionless: { dims: {}, scale: 1 },
  // `%` is a dimensionless ratio of 1/100 — the same unit as the long-form
  // `percent` below. The scanner admits `%` as an identifier start, so `%/h`
  // scans as the symbol `%` divided by `h`.
  '%': { dims: {}, scale: 0.01 },

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
 * Superscript digits, indexed by the ASCII digit they denote. NOT a contiguous
 * Unicode range: `¹`, `²` and `³` are Latin-1 (U+00B9/B2/B3) while `⁰` and
 * `⁴`–`⁹` live in the Superscripts block (U+2070, U+2074–2079). A `[⁰-⁹]` regex
 * range is therefore WRONG — it silently omits `¹²³`, i.e. the three exponents
 * that actually occur (`m²`, `cm³`, `s⁻¹`). Enumerate them.
 */
const SUPERSCRIPT_DIGITS = '⁰¹²³⁴⁵⁶⁷⁸⁹'
/** Superscript minus (U+207B), the sign in `s⁻¹`. */
const SUPERSCRIPT_MINUS = '⁻'
/** Character class matching one superscript digit or the superscript minus. */
const SUPERSCRIPT_CLASS = `[${SUPERSCRIPT_DIGITS}${SUPERSCRIPT_MINUS}]`

/**
 * Fold the non-ASCII and alternate spellings the shared corpus uses into the
 * ASCII grammar the parser implements. A pure SPELLING normalization — every
 * target already exists in {@link UNIT_TABLE}, no unit is invented here:
 *
 *   - SUPERSCRIPT EXPONENTS `⁰¹²³⁴⁵⁶⁷⁸⁹` and superscript minus `⁻` become an
 *     explicit `^` exponent: `W/m²` → `W/m^2`, `cm³` → `cm^3`, `s⁻¹` → `s^-1`.
 *     A whole superscript RUN maps to one exponent, so `m⁻²` is `m^-2` and not
 *     `m^-^2`.
 *   - MIDDOT `·` (U+00B7) and DOT OPERATOR `⋅` (U+22C5) → `*`, the two spellings
 *     of multiplication the corpus uses (`J/(kg·K)`, `kg⋅m/s`).
 *   - U+00B5 MICRO SIGN and U+03BC GREEK SMALL LETTER MU → `u` (`μg` → `ug`)
 *   - `°C` / `°F` / `°K` → `degC` / `degF` / `K`, and a bare `°` → `deg`
 *   - `Ω` (U+03A9 / U+2126) → `Ohm`
 *
 * Runs before the scanner, which only recognizes ASCII identifier characters —
 * so without this pass every one of these spellings is an `unparseable_unit`
 * HARD ERROR (units.ts), i.e. a false rejection of a legitimate file.
 */
function normalizeUnitString(s: string): string {
  // Ω GREEK CAPITAL OMEGA and Ω OHM SIGN are visually identical and
  // both occur in the wild; fold each to the ASCII `Ohm` the table registers.
  if (!new RegExp(`[µμ°·⋅ΩΩ]|${SUPERSCRIPT_CLASS}`, 'u').test(s)) return s
  return s
    .replace(/°C/g, 'degC')
    .replace(/°F/g, 'degF')
    .replace(/°K/g, 'K')
    .replace(/°/g, 'deg')
    .replace(/[µμ]/g, 'u')
    .replace(/[ΩΩ]/g, 'Ohm')
    .replace(/[·⋅]/g, '*')
    .replace(new RegExp(`${SUPERSCRIPT_CLASS}+`, 'gu'), (run) => {
      const sign = run.includes(SUPERSCRIPT_MINUS) ? '-' : ''
      const digits = [...run]
        .filter((c) => c !== SUPERSCRIPT_MINUS)
        .map((c) => String(SUPERSCRIPT_DIGITS.indexOf(c)))
        .join('')
      return `^${sign}${digits}`
    })
}

/**
 * Parse a unit string into canonical SI dimensions plus scale (and optional offset).
 *
 * Recursive-descent parser over the grammar of the Go reference implementation
 * (`pkg/earthsci-ast-go/pkg/esm/units.go`), so the bindings agree on how a unit
 * string associates:
 *
 * ```
 *   unit     := term ( ('*' | '/')? term )*
 *   term     := atom ( ('^' | '**') exponent )?
 *   exponent := integer | decimal | '(' integer '/' integer ')'
 *   atom     := number | symbol | '(' unit ')'
 * ```
 *
 * EXPONENTS ARE RATIONAL, not integral: `1/s^0.5` (an SDE noise intensity) and
 * `m^(1/2)` are legitimate corpus units, and a dimension vector may therefore
 * carry fractional entries.
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
   * term := atom ( ('^' | '**') exponent )?
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
    return powerParsed(atom, this.parseExponent())
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

  /**
   * exponent := integer | decimal | '(' integer '/' integer ')'
   *
   * A dimension exponent is RATIONAL, not integral. `1/s^0.5` is the ordinary
   * spelling of an SDE noise intensity (`tests/fixtures/sde/*.esm`), and
   * `m^(1/2)` is the same quantity written as a ratio. An integer-only grammar
   * makes both an `unparseable_unit` — a HARD ERROR under the severity policy in
   * units.ts — and therefore FALSELY REJECTS files that are correct physics.
   *
   * The parenthesised form is disambiguated from a parenthesised sub-unit by
   * position: this production is only ever entered after `^` / `**`.
   */
  private parseExponent(): number {
    this.skipSpace()
    const start = this.pos

    // '(' integer '/' integer ')' — the exact-ratio spelling, e.g. `m^(1/2)`.
    if (this.peek() === '(') {
      this.pos++
      const numerator = this.parseSignedNumber()
      if (this.peek() !== '/') {
        throw new UnitConversionError(
          `Cannot parse unit "${this.src}": expected "/" in rational exponent at position ${this.pos}`,
        )
      }
      this.pos++
      const denominator = this.parseSignedNumber()
      if (this.peek() !== ')') {
        throw new UnitConversionError(
          `Cannot parse unit "${this.src}": missing ")" closing rational exponent`,
        )
      }
      this.pos++
      if (denominator === 0) {
        throw new UnitConversionError(
          `Cannot parse unit "${this.src}": zero denominator in rational exponent`,
        )
      }
      return numerator / denominator
    }

    const value = this.parseSignedNumber()
    if (!Number.isFinite(value)) {
      throw new UnitConversionError(
        `Cannot parse unit "${this.src}": expected a rational exponent at position ${start}`,
      )
    }
    return value
  }

  /** A signed integer or decimal (`2`, `-1`, `0.5`, `+3`). */
  private parseSignedNumber(): number {
    this.skipSpace()
    const start = this.pos
    if (this.pos < this.src.length && (this.src[this.pos] === '-' || this.src[this.pos] === '+')) {
      this.pos++
    }
    const digitsStart = this.pos
    while (
      this.pos < this.src.length &&
      (isDigit(this.src[this.pos]) || this.src[this.pos] === '.')
    ) {
      this.pos++
    }
    if (this.pos === digitsStart) {
      throw new UnitConversionError(
        `Cannot parse unit "${this.src}": expected a numeric exponent at position ${start}`,
      )
    }
    const value = Number(this.src.slice(start, this.pos))
    if (!Number.isFinite(value)) {
      throw new UnitConversionError(
        `Cannot parse unit "${this.src}": invalid exponent "${this.src.slice(start, this.pos)}"`,
      )
    }
    return value
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
