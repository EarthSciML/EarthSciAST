/**
 * Document-scoped solver hints (esm-spec §2.2).
 *
 * The `solver` block records numerics the document knows about *itself* —
 * stiffness, integration tolerances, and a splitting hint — which each binding
 * maps to its own integrator.
 *
 * Every field is ADVISORY: a binding may ignore any or all of them and still
 * conform. Advisory governs the MECHANISM, never the OUTCOME — the
 * CONFORMANCE_SPEC §5.9 requirement to integrate successfully and agree within
 * the error band is untouched by this block and is not excused by it.
 *
 * This module carries the parts that are NOT advisory: the spec-version gates
 * (§2.2.4), the §2.2.2 tolerance resolution order, the §2.2.6 resolution of
 * `solver.external`, and the §2.2.7 conversion of `solver.time_span`. TypeScript ships no
 * integrator, so `resolveTolerances` exists for parity and for callers driving
 * another runtime.
 */

import { ERROR_CODES } from './errors.js'
import { EsmMachineryError } from './lower-expression-templates.js'
import type { Solver } from './generated.js'
import type { EsmFile } from './types.js'
import { removeDotSegments, SCHEME_RE } from './data-source-urls.js'
import { isNumericLiteral } from './numeric-literal.js'

/**
 * Binding default relative tolerance (API_SPEC §5.8) — the bottom of the
 * §2.2.2 chain, used when neither the caller nor `solver.reltol` sets one.
 */
export const DEFAULT_RELTOL = 1e-4
/**
 * Binding default absolute tolerance (API_SPEC §5.8) — the bottom of the
 * §2.2.2 chain, used when neither the caller nor `solver.abstol` sets one.
 */
export const DEFAULT_ABSTOL = 1e-6

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

/** `[major, minor]` of the document's `esm` string, or `null` when it has none. */
function declaredMinor(view: Record<string, unknown>): [number, number] | null {
  const esm = view.esm
  if (typeof esm !== 'string') return null
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(esm)
  if (!m) return null
  return [Number(m[1]), Number(m[2])]
}

/** Whether a declared `[major, minor]` is below `1.<minor>`. */
function below1(version: [number, number] | null, minor: number): boolean {
  return version !== null && (version[0] < 1 || (version[0] === 1 && version[1] < minor))
}

/**
 * Reject a top-level `solver` block in a file declaring esm < 1.1.0.
 *
 * The block arrives at `esm: 1.1.0`; a document declaring an earlier version
 * that carries one is rejected with `solver_version_too_old` (esm-spec
 * §2.2.4). Mirrors `rejectTemplateImportsPreV08`.
 */
export function rejectSolverPreV11(view: unknown): void {
  if (!isObject(view)) return
  if (!('solver' in view)) return
  if (!below1(declaredMinor(view), 1)) return
  throw new EsmMachineryError(
    ERROR_CODES.SOLVER_VERSION_TOO_OLD,
    `the top-level \`solver\` block requires esm >= 1.1.0; file declares ${String(view.esm)}. Offending path: /solver`,
  )
}

/**
 * Reject `solver.external` in a file declaring esm < 1.3.0.
 *
 * `external` arrives at `esm: 1.3.0`; a 1.1.0 or 1.2.0 document whose `solver`
 * block carries it is rejected with `solver_external_version_too_old` at
 * `/solver/external` (esm-spec §2.2.4 requirement 4). The same block without
 * `external` stays valid. Below 1.1.0 the whole block is refused first, by
 * {@link rejectSolverPreV11}.
 */
export function rejectSolverExternalPreV13(view: unknown): void {
  if (!isObject(view)) return
  const solver = view.solver
  if (!isObject(solver) || !('external' in solver)) return
  if (!below1(declaredMinor(view), 3)) return
  throw new EsmMachineryError(
    ERROR_CODES.SOLVER_EXTERNAL_VERSION_TOO_OLD,
    `\`solver.external\` requires esm >= 1.3.0; file declares ${String(view.esm)}. Offending path: /solver/external`,
  )
}

function checkSolverExternal(external: string): void {
  if (!external.includes('${')) return
  throw new EsmMachineryError(
    ERROR_CODES.SOLVER_EXTERNAL_UNRESOLVED,
    `/solver/external: "${external}" carries an unexpanded '\${...}' variable. ` +
      'esm-spec §2.2.6 does not expand environment variables into a run-configuration ' +
      'reference: a run configuration chosen by the environment is not reproducible. ' +
      'Write a path relative to this document, or pass the run configuration at the call site.',
  )
}

/**
 * Refuse a `solver.external` carrying `${` with `solver_external_unresolved`
 * (esm-spec §2.2.6). Runs at load on the raw JSON; a non-string `external` is
 * left to schema validation.
 */
export function rejectSolverExternalUnresolved(view: unknown): void {
  if (!isObject(view)) return
  const solver = view.solver
  if (!isObject(solver) || typeof solver.external !== 'string') return
  checkSolverExternal(solver.external)
}

/** A drive-letter path, `C:/` or `C:\`: absolute on every host (§2.2.6). */
const DRIVE_RE = /^[A-Za-z]:[/\\]/

/** The bytes a §2.2.6 location writes as themselves; every other byte is `%XX`. */
const LOCATION_SAFE = /^[A-Za-z0-9\-._~/:]$/

function isAbsolutePath(path: string): boolean {
  return path.startsWith('/') || DRIVE_RE.test(path)
}

/**
 * An absolute `path` with its dot segments removed (RFC 3986 §5.2.4). A
 * drive-letter path comes back as `C:/…`, its `\` read as `/` and its drive a
 * root that `..` does not climb above.
 */
function lexicalAbsolute(path: string): string {
  if (DRIVE_RE.test(path)) {
    return path.slice(0, 2) + removeDotSegments(path.slice(2).replace(/\\/g, '/'))
  }
  return removeDotSegments(path)
}

/**
 * `dir` as the absolute, dot-segment-free directory *D* of esm-spec §2.2.6. A
 * relative `dir` is taken against the working directory. Purely lexical.
 */
export function absoluteDirectory(dir: string): string {
  let d = (dir || '.').replace(/\\/g, '/')
  if (!isAbsolutePath(d)) {
    const cwd =
      typeof process !== 'undefined' && typeof process.cwd === 'function' ? process.cwd() : '/'
    d = cwd.replace(/\\/g, '/') + '/' + d
  }
  return lexicalAbsolute(d)
}

/** `file://` plus an absolute, dot-segment-free `path`, percent-encoded (§2.2.6). */
function fileUrl(path: string): string {
  let encoded = ''
  for (const byte of new TextEncoder().encode(path)) {
    const ch = String.fromCharCode(byte)
    encoded += LOCATION_SAFE.test(ch) ? ch : '%' + byte.toString(16).toUpperCase().padStart(2, '0')
  }
  return 'file://' + (path.startsWith('/') ? '' : '/') + encoded
}

/**
 * The location `solver.external` names, resolved by esm-spec §2.2.6, or `null`
 * when the root document's `solver` block carries none.
 *
 * A URL (`scheme://…`) is returned unchanged. An absolute path — `/…`, or a
 * drive-letter `C:/…` / `C:\…` — has its dot segments removed, is
 * percent-encoded and is prefixed `file://` (`file:///C:/…` for a drive).
 * Anything else is joined onto the base, dot segments removed,
 * percent-encoded, and prefixed `file://`. Percent-encoding writes each byte of
 * the path's UTF-8 encoding outside `A-Za-z0-9-._~/:` as `%XX`, `%` included:
 * the input is a path, not a URL.
 *
 * The base is `base` when given — a relative one is taken against the working
 * directory — and otherwise the directory recorded at load: the directory of
 * the file `loadPath` read, the `basePath` load option, or the working
 * directory of a `loadString` / `loadDocument`. A document built in memory
 * resolves against the working directory.
 *
 * Purely lexical: it never touches the filesystem, and a location that does not
 * exist resolves normally. The authored string stays in the document and is
 * what `toJson` writes; the resolved location is never written back. A mounted
 * leaf's `solver` block does not cross the mount, so only the root's
 * `external` is consulted.
 *
 * @throws {EsmMachineryError} `solver_external_unresolved` when `external`
 *   carries `${` (only reachable for a document built in memory; load refuses it).
 */
export function solverExternalLocation(file: EsmFile, base?: string): string | null {
  const external = file.solver?.external
  if (typeof external !== 'string') return null
  checkSolverExternal(external)
  if (SCHEME_RE.test(external)) return external
  if (isAbsolutePath(external)) return fileUrl(lexicalAbsolute(external))
  const dir =
    base !== undefined ? absoluteDirectory(base) : (file.documentBase ?? absoluteDirectory('.'))
  return fileUrl(lexicalAbsolute(dir + '/' + external))
}

/**
 * Reject `solver.time_span` in a file declaring esm < 1.3.0.
 *
 * `time_span` arrives at `esm: 1.3.0`; a 1.1.0 or 1.2.0 document whose `solver`
 * block carries it is rejected with `solver_time_span_version_too_old` at
 * `/solver/time_span` (esm-spec §2.2.4 requirement 4), before schema
 * validation. Below 1.1.0 the whole block is refused first, by
 * {@link rejectSolverPreV11}.
 */
export function rejectSolverTimeSpanPreV13(view: unknown): void {
  if (!isObject(view)) return
  const solver = view.solver
  if (!isObject(solver) || !('time_span' in solver)) return
  if (!below1(declaredMinor(view), 3)) return
  throw new EsmMachineryError(
    ERROR_CODES.SOLVER_TIME_SPAN_VERSION_TOO_OLD,
    `\`solver.time_span\` requires esm >= 1.3.0; file declares ${String(view.esm)}. Offending path: /solver/time_span`,
  )
}

/**
 * A `time_span` bound timestamp: the schema's pattern (esm-spec §2.2.7), UTC
 * with `Z`, each field in its calendar range except the day-of-month check.
 */
const BOUND_RE =
  /^([0-9]{4})-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])T([01][0-9]|2[0-3]):([0-5][0-9]):([0-5][0-9])(?:\.([0-9]+))?Z$/

/** A time-origin RFC 3339 date-time: `T`/`t`, and `Z`/`z` or a `±hh:mm` offset. */
const ORIGIN_RE =
  /^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?(?:([Zz])|([+-])([0-9]{2}):([0-9]{2}))$/

/**
 * Days from 1970-01-01 to the proleptic Gregorian date `y-m-d` (H. Hinnant's
 * days_from_civil). Exact in binary64 for every four-digit year.
 */
function daysFromCivil(y: number, m: number, d: number): number {
  const yy = m <= 2 ? y - 1 : y
  const era = Math.floor(yy / 400)
  const yoe = yy - era * 400
  const doy = Math.floor((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
  const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
}

function daysInMonth(y: number, m: number): number {
  if (m === 2) return (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0 ? 29 : 28
  return m === 4 || m === 6 || m === 9 || m === 11 ? 30 : 31
}

/**
 * A date-time's whole part `W` (integer seconds from the POSIX epoch, its
 * offset subtracted) and fraction `f` in `[0, 1)` (esm-spec §2.2.7), or `null`
 * when the fields name no calendar instant.
 */
function wholeAndFraction(
  ymd: [number, number, number],
  hms: [number, number, number],
  frac: string | undefined,
  offsetSeconds: number,
): [number, number] | null {
  const [y, mo, d] = ymd
  const [h, mi, s] = hms
  if (mo < 1 || mo > 12 || d < 1 || d > daysInMonth(y, mo)) return null
  if (h > 23 || mi > 59 || s > 59) return null
  const whole = daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s - offsetSeconds
  return [whole, frac === undefined ? 0 : Number('0.' + frac)]
}

/** A bound timestamp's `(W, f)`, or `null` when it names no calendar day. */
function boundInstant(m: RegExpExecArray): [number, number] | null {
  return wholeAndFraction(
    [Number(m[1]), Number(m[2]), Number(m[3])],
    [Number(m[4]), Number(m[5]), Number(m[6])],
    m[7],
    0,
  )
}

/** The origin date-time's `(W, f)`, or `null` when it is not a readable RFC 3339 date-time. */
function originInstant(value: unknown): [number, number] | null {
  if (typeof value !== 'string') return null
  const m = ORIGIN_RE.exec(value)
  if (!m) return null
  let offset = 0
  if (m[8] === undefined) {
    const oh = Number(m[10])
    const om = Number(m[11])
    if (oh > 23 || om > 59) return null
    offset = (m[9] === '-' ? -1 : 1) * (oh * 3600 + om * 60)
  }
  return wholeAndFraction(
    [Number(m[1]), Number(m[2]), Number(m[3])],
    [Number(m[4]), Number(m[5]), Number(m[6])],
    m[7],
    offset,
  )
}

function timeSpanInvalid(detail: string): EsmMachineryError {
  return new EsmMachineryError(ERROR_CODES.SOLVER_TIME_SPAN_INVALID, `/solver/time_span: ${detail}`)
}

/** A bound as a plain number, unwrapping a canonical-mode tagged literal. */
function plainBound(v: unknown): unknown {
  return isNumericLiteral(v) ? v.value : v
}

/**
 * The §2.2.7 conversion of a `time_span` whose bounds both have a
 * schema-valid form, to binary64 seconds since the time origin, checked.
 * Returns `null` when a bound's form is not schema-valid (the schema reports
 * it). Throws `solver_time_span_invalid` for a well-formed pair that is no
 * interval, or whose time origin cannot be read.
 */
function convertTimeSpan(timeSpan: unknown, doc: unknown): [number, number] | null {
  if (!isObject(timeSpan)) return null
  const raw = [plainBound(timeSpan.start), plainBound(timeSpan.end)]
  const stamps: (RegExpExecArray | null)[] = []
  for (const b of raw) {
    if (typeof b === 'number') {
      if (!Number.isFinite(b)) return null
      stamps.push(null)
    } else if (typeof b === 'string') {
      const m = BOUND_RE.exec(b)
      if (!m) return null
      stamps.push(m)
    } else {
      return null
    }
  }

  let origin: [number, number] | null = null
  if (stamps.some((m) => m !== null)) {
    const temporal = isObject(doc) && isObject(doc.domain) ? doc.domain.temporal : undefined
    let field: 'reference_time' | 'start' | null = null
    if (isObject(temporal)) {
      if (temporal.reference_time !== undefined) field = 'reference_time'
      else if (temporal.start !== undefined) field = 'start'
    }
    if (field === null) {
      origin = [0, 0]
    } else {
      origin = originInstant((temporal as Record<string, unknown>)[field])
      if (origin === null) {
        throw timeSpanInvalid(
          `a timestamp bound needs the time origin, and /domain/temporal/${field} ` +
            `(${JSON.stringify((temporal as Record<string, unknown>)[field])}) is not an ` +
            'RFC 3339 date-time naming a calendar day (esm-spec §2.2.7).',
        )
      }
    }
  }

  const seconds: number[] = []
  for (let i = 0; i < 2; i++) {
    const m = stamps[i]
    if (m === null || m === undefined) {
      seconds.push(raw[i] as number)
      continue
    }
    const instant = boundInstant(m)
    if (instant === null) {
      throw timeSpanInvalid(
        `${i === 0 ? 'start' : 'end'} "${m[0]}" names no calendar day (esm-spec §2.2.7).`,
      )
    }
    const [w0, f0] = origin as [number, number]
    seconds.push(instant[0] - w0 + (instant[1] - f0))
  }

  const [start, end] = seconds as [number, number]
  if (!(end > start)) {
    throw timeSpanInvalid(
      `end (${JSON.stringify(raw[1])} = ${end} s) is not after start ` +
        `(${JSON.stringify(raw[0])} = ${start} s); a time_span is a non-empty interval (esm-spec §2.2.7).`,
    )
  }
  return [start, end]
}

/**
 * Refuse a root `solver.time_span` that is no interval with
 * `solver_time_span_invalid` (esm-spec §2.2.7): `end` not after `start`, a
 * timestamp naming no calendar day, or a timestamp bound whose time origin
 * (`domain.temporal.reference_time`, else `domain.temporal.start`) is not a
 * readable RFC 3339 date-time. Runs at load on the raw JSON, before schema
 * validation, and only when both bounds have a schema-valid form.
 */
export function rejectSolverTimeSpanInvalid(view: unknown): void {
  if (!isObject(view)) return
  const solver = view.solver
  if (!isObject(solver) || !('time_span' in solver)) return
  convertTimeSpan(solver.time_span, view)
}

/**
 * The run interval by the esm-spec §2.2.7 chain: the call-site interval
 * `tspan` when given (both bounds, always), otherwise the root document's
 * `solver.time_span` converted to binary64 seconds since the document's time
 * origin, otherwise `null` (no interval).
 *
 * A timestamp bound counts seconds from `domain.temporal.reference_time`, else
 * `domain.temporal.start`, else the POSIX epoch, without leap seconds, by exact
 * arithmetic on its fields (no host date library). A number bound is its
 * value. The document keeps what was authored; `toJson` writes the authored
 * bounds back and never the converted value.
 *
 * @throws {EsmMachineryError} `solver_time_span_invalid` when the document's
 *   interval is not one (only reachable for a document built in memory; load
 *   refuses it), including a bound whose form is not schema-valid.
 */
export function resolveTimeSpan(
  file: EsmFile,
  tspan?: readonly [number, number] | null,
): [number, number] | null {
  if (tspan !== undefined && tspan !== null) return [tspan[0], tspan[1]]
  const timeSpan = file.solver?.time_span
  if (timeSpan === undefined || timeSpan === null) return null
  const seconds = convertTimeSpan(timeSpan, file)
  if (seconds === null) {
    throw timeSpanInvalid(
      'each bound must be a number or an RFC 3339 UTC timestamp (YYYY-MM-DDThh:mm:ss[.f]Z) (esm-spec §2.2.7).',
    )
  }
  return seconds
}

/**
 * Reject declared `units` on any expression node in a document declaring
 * `esm` < 1.2.0 (esm-spec §4.8.5 item 6), naming the first offending node.
 * Runs on the raw JSON before schema validation, like {@link rejectSolverPreV11}.
 */
export function rejectConstUnitsPreV12(view: unknown): void {
  if (!isObject(view)) return
  if (!below1(declaredMinor(view), 2)) return
  const find = (node: unknown, at: string): string | null => {
    if (Array.isArray(node)) {
      for (let i = 0; i < node.length; i++) {
        const hit = find(node[i], `${at}/${i}`)
        if (hit !== null) return hit
      }
    } else if (isObject(node)) {
      if ('op' in node && 'units' in node) return at
      for (const key of Object.keys(node)) {
        const hit = find(node[key], `${at}/${key}`)
        if (hit !== null) return hit
      }
    }
    return null
  }
  const path = find(view, '')
  if (path === null) return
  throw new EsmMachineryError(
    ERROR_CODES.CONST_UNITS_VERSION_TOO_OLD,
    `declared \`units\` on an expression node require esm >= 1.2.0; file declares ${String(view.esm)}. Offending path: ${path}`,
  )
}

/**
 * Resolve integration tolerances most-specific first (esm-spec §2.2.2):
 *
 * 1. An explicit argument at the call site — wins outright.
 * 2. Otherwise the document's `solver.abstol` / `solver.reltol`.
 * 3. Otherwise the binding default (`reltol` 1e-4, `abstol` 1e-6).
 *
 * The two resolve INDEPENDENTLY, so a document declaring only `reltol` leaves
 * `abstol` on the default — the same per-field fall-through §6.6.4 uses.
 *
 * These are INTEGRATION tolerances, a different quantity from the `tolerance`
 * object an assertion is COMPARED at (§6.6.4).
 */
export function resolveTolerances(
  solver: Solver | undefined | null,
  opts: { abstol?: number; reltol?: number } = {},
): { abstol: number; reltol: number } {
  return {
    abstol: opts.abstol ?? solver?.abstol ?? DEFAULT_ABSTOL,
    reltol: opts.reltol ?? solver?.reltol ?? DEFAULT_RELTOL,
  }
}

/**
 * Map a `solver` block with nothing set to absence (esm-spec §2.2).
 *
 * `"solver": {}` is legal — every other optional top-level container admits an
 * empty object, and making this one the exception would be a rule with no
 * payoff — but it means exactly what omitting the block means, so it is
 * normalized away AT LOAD. `toJson` serializes the whole document object, so
 * without this an empty block would survive `parse → emit` here while Python
 * and Julia dropped it: the five bindings disagreeing on one document.
 *
 * Returns a SHALLOW COPY without the key, or `null` when there is nothing to
 * drop — the same shape as `resolveDataSourceUrls`, and for the same two
 * reasons. Deleting in place would (a) mutate the caller's own object, since a
 * non-canonical object input is passed through by reference, and (b) land on
 * the wrong tree in canonical mode, where the validation view is a separate
 * stripped copy from the document the `EsmFile` is built out of — so `{}` would
 * survive to emit on exactly the path this normalization exists to make
 * uniform.
 */
export function normalizeEmptySolver(view: unknown): Record<string, unknown> | null {
  if (!isObject(view)) return null
  const solver = view.solver
  if (!isObject(solver)) return null
  if (Object.keys(solver).length > 0) return null
  const { solver: _dropped, ...rest } = view
  return rest
}
