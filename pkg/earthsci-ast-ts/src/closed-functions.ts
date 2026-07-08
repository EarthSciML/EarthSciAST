/**
 * Closed function registry — TypeScript binding for esm-spec §9.2.
 *
 * v0.3.0 set:
 *  - datetime.year / .month / .day / .hour / .minute / .second
 *  - datetime.day_of_year / .julian_day / .is_leap_year
 *  - interp.searchsorted
 *  - interp.linear, interp.bilinear (named tensor-interpolation primitives, esm-94w)
 *
 * The dispatch table is closed by construction. `fn`-op nodes whose name
 * is not in this set MUST be rejected with diagnostic
 * `unknown_closed_function`.
 *
 * Boundary semantics, tolerances, and error codes match the Julia
 * reference implementation (pkg/EarthSciAST.jl/src/registered_functions.jl).
 */

/** Stable diagnostic codes raised by the registry. */
export type ClosedFunctionErrorCode =
  | 'unknown_closed_function'
  | 'closed_function_arity'
  | 'closed_function_overflow'
  | 'searchsorted_non_monotonic'
  | 'searchsorted_nan_in_table'
  | 'interp_non_monotonic_axis'
  | 'interp_axis_length_mismatch'
  | 'interp_nan_in_axis'
  | 'interp_axis_too_short'
  | 'interp_table_not_const'
  | 'interp_axis_not_const'

/**
 * Error thrown by closed function dispatch and load-time table validation.
 * `code` identifies the spec-pinned diagnostic; cross-binding harnesses
 * compare against this exact string.
 */
export class ClosedFunctionError extends Error {
  constructor(
    public code: ClosedFunctionErrorCode,
    message: string,
  ) {
    super(`[${code}] ${message}`)
    this.name = 'ClosedFunctionError'
  }
}

/** Names that bindings MUST recognize. */
export const CLOSED_FUNCTION_NAMES: readonly string[] = Object.freeze([
  'datetime.year',
  'datetime.month',
  'datetime.day',
  'datetime.hour',
  'datetime.minute',
  'datetime.second',
  'datetime.day_of_year',
  'datetime.julian_day',
  'datetime.is_leap_year',
  'interp.searchsorted',
  'interp.linear',
  'interp.bilinear',
])

const SECONDS_PER_DAY = 86400
// Days from proleptic-Gregorian year 0000-01-01 to Unix epoch 1970-01-01.
// Matches the Julia ref (Date(1970,1,1) - Date(0,1,1)).value = 719528.
const UNIX_EPOCH_DAYS_FROM_YEAR_ZERO = 719528

const INT32_MIN = -2147483648
const INT32_MAX = 2147483647

function checkInt32(name: string, v: number): number {
  if (!Number.isFinite(v) || v < INT32_MIN || v > INT32_MAX) {
    throw new ClosedFunctionError(
      'closed_function_overflow',
      `${name} result ${v} overflows signed 32-bit integer range`,
    )
  }
  return v
}

/**
 * Floor-division of two integers (matches Math.floor semantics for
 * negative dividends, which Julia's `fld` and Python's `//` also use).
 */
function fdiv(a: number, b: number): number {
  return Math.floor(a / b)
}

/**
 * Decompose UTC seconds-since-epoch (IEEE-754 binary64, no leap seconds)
 * into proleptic-Gregorian Y/M/D/h/m/s plus day_of_year and julian_day.
 *
 * Pure integer arithmetic for Y/M/D/h/m/s — bit-exact across bindings
 * given the same input. The fractional-day component for `julian_day` is
 * the only floating-point step.
 */
interface DateParts {
  year: number
  month: number
  day: number
  hour: number
  minute: number
  second: number
  dayOfYear: number
  julianDay: number
  isLeapYear: number
}

function isLeapProleptic(y: number): boolean {
  return (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0
}

const DAYS_BEFORE_MONTH_NORMAL = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
const DAYS_BEFORE_MONTH_LEAP = [0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335]

/** Convert "days since 0000-01-01" (proleptic Gregorian) to Y/M/D. */
function daysToYMD(dayOfEra: number): { year: number; month: number; day: number } {
  // Algorithm follows Howard Hinnant's date / civil_from_days, adjusted
  // so day 0 = 0000-01-01. Equivalent to the Julia Date arithmetic used
  // in the reference implementation.
  // Shift so day 0 is the start of year 0 in Hinnant's epoch (0000-03-01).
  // Hinnant's days[z] is days since 0000-03-01.
  // We have dayOfEra = days since 0000-01-01.
  // 0000-01-01 → 0000-03-01 is +60 days (year 0 is leap by Gregorian rule? 0%400==0 → yes).
  // But Hinnant's algorithm operates on integer-floor arithmetic; do this carefully.
  // To keep cross-binding parity with Julia (which uses Dates.Date arithmetic),
  // we replicate via month-table lookup walking centuries.

  // Compute year by Hinnant's formula directly:
  const z = dayOfEra - 60 // days since 0000-03-01
  const era = fdiv(z >= 0 ? z : z - 146096, 146097)
  const doe = z - era * 146097 // [0, 146096]
  const yoe = fdiv(doe - fdiv(doe, 1460) + fdiv(doe, 36524) - fdiv(doe, 146096), 365)
  const y = yoe + era * 400
  const doy = doe - (365 * yoe + fdiv(yoe, 4) - fdiv(yoe, 100))
  const mp = fdiv(5 * doy + 2, 153)
  const d = doy - fdiv(153 * mp + 2, 5) + 1
  const m = mp < 10 ? mp + 3 : mp - 9
  const year = m <= 2 ? y + 1 : y
  return { year, month: m, day: d }
}

function dayOfYear(year: number, month: number, day: number): number {
  const tbl = isLeapProleptic(year) ? DAYS_BEFORE_MONTH_LEAP : DAYS_BEFORE_MONTH_NORMAL
  return tbl[month - 1] + day
}

/**
 * Julian Day Number (continuous including fractional day-of-day).
 * 1970-01-01T00:00:00 UTC → 2440587.5.
 */
function julianDayValue(tUtc: number): number {
  // Constant offset by Unix-epoch JDN. The only float op is the divide.
  return 2440587.5 + tUtc / SECONDS_PER_DAY
}

function decomposeUtcSeconds(tUtc: number): DateParts {
  if (!Number.isFinite(tUtc)) {
    throw new ClosedFunctionError(
      'closed_function_overflow',
      `datetime input ${tUtc} is not a finite value`,
    )
  }
  const totalDays = fdiv(tUtc, SECONDS_PER_DAY) // floor seconds → days
  const remSeconds = tUtc - totalDays * SECONDS_PER_DAY // [0, 86400)
  const dayOfEra = totalDays + UNIX_EPOCH_DAYS_FROM_YEAR_ZERO

  const { year, month, day } = daysToYMD(dayOfEra)
  // remSeconds may be fractional; Y/M/D/h/m/s integer outputs are taken
  // from the floored second count.
  const wholeRem = Math.floor(remSeconds)
  const hour = fdiv(wholeRem, 3600)
  const minute = fdiv(wholeRem - hour * 3600, 60)
  const second = wholeRem - hour * 3600 - minute * 60

  const doy = dayOfYear(year, month, day)
  const jdn = julianDayValue(tUtc)
  const isLeap = isLeapProleptic(year) ? 1 : 0

  return {
    year,
    month,
    day,
    hour,
    minute,
    second,
    dayOfYear: doy,
    julianDay: jdn,
    isLeapYear: isLeap,
  }
}

function requireArity(name: string, args: unknown[], expected: number): void {
  if (args.length !== expected) {
    throw new ClosedFunctionError(
      'closed_function_arity',
      `${name} expects ${expected} argument(s); got ${args.length}`,
    )
  }
}

function asNumber(name: string, v: unknown, idx = 0): number {
  if (typeof v === 'number') return v
  throw new ClosedFunctionError(
    'closed_function_arity',
    `${name} argument #${idx + 1} must be a scalar number; got ${typeof v}`,
  )
}

/**
 * Validate a `searchsorted` xs table. Throws on NaN entries or
 * non-monotonic order. Empty arrays are rejected with the spec arity
 * code (the registry requires N ≥ 1).
 */
export function validateSearchsortedTable(
  xs: readonly number[],
  where = 'interp.searchsorted',
): void {
  if (xs.length === 0) {
    throw new ClosedFunctionError(
      'closed_function_arity',
      `${where}: xs table is empty (must have at least one entry)`,
    )
  }
  for (let i = 0; i < xs.length; i++) {
    if (Number.isNaN(xs[i])) {
      throw new ClosedFunctionError('searchsorted_nan_in_table', `${where}: xs[${i + 1}] is NaN`)
    }
  }
  for (let i = 1; i < xs.length; i++) {
    if (xs[i] < xs[i - 1]) {
      throw new ClosedFunctionError(
        'searchsorted_non_monotonic',
        `${where}: xs is not non-decreasing at index ${i + 1} (xs[${i + 1}]=${xs[i]} < xs[${i}]=${xs[i - 1]})`,
      )
    }
  }
}

/**
 * Smallest 1-based `i` with `xs[i] ≥ x` (Julia `searchsortedfirst`
 * semantics). NaN x → N+1. xs MUST be pre-validated; the table is
 * inspected at every call so the caller can pass a fresh array each
 * scenario without bookkeeping (validation is cheap relative to the
 * dispatch overhead).
 */
export function searchsortedFirst(x: number, xs: readonly number[]): number {
  validateSearchsortedTable(xs)
  if (Number.isNaN(x)) return xs.length + 1
  // Binary search for the first index with xs[i] >= x (1-based output).
  let lo = 0
  let hi = xs.length // exclusive
  while (lo < hi) {
    const mid = (lo + hi) >>> 1
    if (xs[mid] >= x) {
      hi = mid
    } else {
      lo = mid + 1
    }
  }
  return lo + 1
}

/**
 * Validate a 1-D interpolation axis (`interp.linear` / `interp.bilinear`).
 * Strictly increasing, no NaN, length ≥ 2. Diagnostic codes match
 * esm-spec §9.2 "Errors (load time)" table.
 */
export function validateInterpAxis(axis: readonly number[], where: string): void {
  if (axis.length < 2) {
    throw new ClosedFunctionError(
      'interp_axis_too_short',
      `${where}: axis has ${axis.length} entries (must have at least 2)`,
    )
  }
  for (let i = 0; i < axis.length; i++) {
    if (Number.isNaN(axis[i]!)) {
      throw new ClosedFunctionError('interp_nan_in_axis', `${where}: axis[${i + 1}] is NaN`)
    }
  }
  for (let i = 1; i < axis.length; i++) {
    if (axis[i]! <= axis[i - 1]!) {
      throw new ClosedFunctionError(
        'interp_non_monotonic_axis',
        `${where}: axis is not strictly increasing at index ${i + 1} (axis[${i + 1}]=${axis[i]} ≤ axis[${i}]=${axis[i - 1]})`,
      )
    }
  }
}

function asNumberArray(name: string, v: unknown, argLabel: string): number[] {
  if (!Array.isArray(v) || !v.every((e) => typeof e === 'number')) {
    throw new ClosedFunctionError(
      'interp_axis_not_const',
      `${name}: ${argLabel} must be a const-array of numbers`,
    )
  }
  return v as number[]
}

function asNumberMatrix(name: string, v: unknown): number[][] {
  if (
    !Array.isArray(v) ||
    !v.every((row) => Array.isArray(row) && row.every((e) => typeof e === 'number'))
  ) {
    throw new ClosedFunctionError(
      'interp_table_not_const',
      `${name}: table must be a const-array of const-arrays of numbers`,
    )
  }
  return v as number[][]
}

/**
 * 1-D linear interpolation with extrapolate-flat clamps. Pinned form
 * `result = t[i] + w * (t[i+1] - t[i])` so that w=0/1 reproduce the
 * endpoint exactly under IEEE-754 round-to-nearest.
 *
 * Validates `axis` on every call (cheap relative to dispatch overhead;
 * matches the `searchsortedFirst` convention in this module).
 */
export function interpLinear(table: readonly number[], axis: readonly number[], x: number): number {
  if (table.length !== axis.length) {
    throw new ClosedFunctionError(
      'interp_axis_length_mismatch',
      `interp.linear: len(table)=${table.length} != len(axis)=${axis.length}`,
    )
  }
  validateInterpAxis(axis, 'interp.linear')
  const n = axis.length
  if (x <= axis[0]!) return table[0]!
  if (x >= axis[n - 1]!) return table[n - 1]!
  // Find unique i in [0, n-2] with axis[i] <= x < axis[i+1].
  // Binary search; axis is strictly increasing so xs[i] >= x ⇒ first such i+1.
  let lo = 0
  let hi = n // exclusive
  while (lo < hi) {
    const mid = (lo + hi) >>> 1
    if (axis[mid]! > x) hi = mid
    else lo = mid + 1
  }
  // lo is first index with axis[lo] > x; cell is [lo-1, lo].
  const i = lo - 1
  const w = (x - axis[i]!) / (axis[i + 1]! - axis[i]!)
  return table[i]! + w * (table[i + 1]! - table[i]!)
}

/**
 * 2-D bilinear interpolation with per-axis extrapolate-flat clamps.
 * Pinned evaluation order: two x-blends followed by one y-blend, each
 * in the form `a + w*(b - a)` (esm-spec §9.2). `table` is row-major:
 * `table[i][j]` is the value at `(axis_x[i], axis_y[j])`.
 */
export function interpBilinear(
  table: readonly (readonly number[])[],
  axisX: readonly number[],
  axisY: readonly number[],
  x: number,
  y: number,
): number {
  const nx = axisX.length
  const ny = axisY.length
  if (table.length !== nx) {
    throw new ClosedFunctionError(
      'interp_axis_length_mismatch',
      `interp.bilinear: outer len(table)=${table.length} != len(axis_x)=${nx}`,
    )
  }
  for (let r = 0; r < table.length; r++) {
    if (table[r]!.length !== ny) {
      throw new ClosedFunctionError(
        'interp_axis_length_mismatch',
        `interp.bilinear: table row ${r + 1} has length ${table[r]!.length}, expected len(axis_y)=${ny}`,
      )
    }
  }
  validateInterpAxis(axisX, 'interp.bilinear axis_x')
  validateInterpAxis(axisY, 'interp.bilinear axis_y')

  // Per-axis clamp (extrapolate-flat). NaN passes through unchanged
  // because both comparisons return false for NaN, propagating to wx/wy.
  const xq = x <= axisX[0]! ? axisX[0]! : x >= axisX[nx - 1]! ? axisX[nx - 1]! : x
  const yq = y <= axisY[0]! ? axisY[0]! : y >= axisY[ny - 1]! ? axisY[ny - 1]! : y

  // Cell location: largest i in [0, nx-2] with axis_x[i] <= xq.
  // Equivalent to clamp(searchsortedfirst(xq, axis), 2, nx) - 1, then
  // converted to 0-based. For xq exactly on an interior knot k (1-based),
  // the spec convention selects i = k (0-based: k-1) so that wx = 0.
  function locateCell(axis: readonly number[], q: number): number {
    const m = axis.length
    let lo = 0
    let hi = m
    while (lo < hi) {
      const mid = (lo + hi) >>> 1
      if (axis[mid]! > q) hi = mid
      else lo = mid + 1
    }
    // lo is first index with axis[lo] > q (or m if none). Cell index is
    // lo - 1, clamped to [0, m-2].
    let i = lo - 1
    if (i < 0) i = 0
    if (i > m - 2) i = m - 2
    return i
  }
  const i = locateCell(axisX, xq)
  const j = locateCell(axisY, yq)
  const wx = (xq - axisX[i]!) / (axisX[i + 1]! - axisX[i]!)
  const wy = (yq - axisY[j]!) / (axisY[j + 1]! - axisY[j]!)

  const t_ij = table[i]![j]!
  const t_ip1_j = table[i + 1]![j]!
  const t_i_jp1 = table[i]![j + 1]!
  const t_ip1_jp1 = table[i + 1]![j + 1]!
  const rowJ = t_ij + wx * (t_ip1_j - t_ij)
  const rowJp1 = t_i_jp1 + wx * (t_ip1_jp1 - t_i_jp1)
  return rowJ + wy * (rowJp1 - rowJ)
}

/**
 * Resolve a closed-function name + already-evaluated positional args
 * into a scalar result. `args` semantics:
 *
 *  - datetime.* take a single scalar `t_utc` (number).
 *  - interp.searchsorted takes [scalar x, number[] xs]. The xs array
 *    MUST be a plain array of numbers (the AST evaluator extracts it
 *    from a `const`-op child without numeric-collapsing it).
 *  - interp.linear takes [number[] table, number[] axis, scalar x].
 *  - interp.bilinear takes
 *    [number[][] table, number[] axis_x, number[] axis_y, scalar x, scalar y].
 *
 * Unknown names raise `unknown_closed_function`.
 */
export function dispatchClosedFunction(name: string, args: unknown[]): number {
  switch (name) {
    case 'datetime.year': {
      requireArity(name, args, 1)
      return checkInt32(name, decomposeUtcSeconds(asNumber(name, args[0])).year)
    }
    case 'datetime.month': {
      requireArity(name, args, 1)
      return decomposeUtcSeconds(asNumber(name, args[0])).month
    }
    case 'datetime.day': {
      requireArity(name, args, 1)
      return decomposeUtcSeconds(asNumber(name, args[0])).day
    }
    case 'datetime.hour': {
      requireArity(name, args, 1)
      return decomposeUtcSeconds(asNumber(name, args[0])).hour
    }
    case 'datetime.minute': {
      requireArity(name, args, 1)
      return decomposeUtcSeconds(asNumber(name, args[0])).minute
    }
    case 'datetime.second': {
      requireArity(name, args, 1)
      return decomposeUtcSeconds(asNumber(name, args[0])).second
    }
    case 'datetime.day_of_year': {
      requireArity(name, args, 1)
      return decomposeUtcSeconds(asNumber(name, args[0])).dayOfYear
    }
    case 'datetime.julian_day': {
      requireArity(name, args, 1)
      return decomposeUtcSeconds(asNumber(name, args[0])).julianDay
    }
    case 'datetime.is_leap_year': {
      requireArity(name, args, 1)
      return decomposeUtcSeconds(asNumber(name, args[0])).isLeapYear
    }
    case 'interp.searchsorted': {
      requireArity(name, args, 2)
      const x = asNumber(name, args[0], 0)
      const xs = args[1]
      if (!Array.isArray(xs) || !xs.every((v) => typeof v === 'number')) {
        throw new ClosedFunctionError(
          'closed_function_arity',
          `${name}: xs (arg 2) must be a const-array of numbers`,
        )
      }
      return searchsortedFirst(x, xs as number[])
    }
    case 'interp.linear': {
      requireArity(name, args, 3)
      const table = asNumberArray(name, args[0], 'table')
      const axis = asNumberArray(name, args[1], 'axis')
      const x = asNumber(name, args[2], 2)
      return interpLinear(table, axis, x)
    }
    case 'interp.bilinear': {
      requireArity(name, args, 5)
      const table = asNumberMatrix(name, args[0])
      const axisX = asNumberArray(name, args[1], 'axis_x')
      const axisY = asNumberArray(name, args[2], 'axis_y')
      const x = asNumber(name, args[3], 3)
      const y = asNumber(name, args[4], 4)
      return interpBilinear(table, axisX, axisY, x, y)
    }
    default:
      throw new ClosedFunctionError(
        'unknown_closed_function',
        `'${name}' is not in the v0.3.0 closed function registry`,
      )
  }
}
