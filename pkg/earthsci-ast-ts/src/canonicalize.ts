/**
 * Canonical AST form per discretization RFC §5.4.
 *
 * Implements `canonicalize(expr)` and `canonicalJson(expr)` for the TypeScript
 * binding. Integer-vs-float AST-node distinction is carried by the
 * `NumericLiteral` tagged leaf (see `./numeric-literal.ts`); plain JS
 * `number` values are treated as untagged float-like literals for backward
 * compatibility with callers that have not migrated to `intLit` / `floatLit`.
 *
 * See `docs/rfcs/discretization.md` §5.4.1–§5.4.7 for the normative rules.
 */

import type { Expr } from './types.js'
import {
  CanonicalizeError,
  intLit,
  floatLit,
  isFloatLit,
  isIntLit,
  isNumericLiteral,
  formatIntToken,
  type NumericLiteral,
} from './numeric-literal.js'
import { canonicalUnitSpelling } from './unit-conversion.js'

// `CanonicalizeError` is DEFINED in numeric-literal.ts (the lowest module in
// the canonical-form stack) so its nonfinite specialization
// `CanonicalNonfiniteError` can extend it without an import cycle. Re-exported
// here so existing consumers keep importing it from `./canonicalize.js`.
export { CanonicalizeError }

/** `E_CANONICAL_NONFINITE` — NaN or ±Inf (§5.4.6). */
export const E_CANONICAL_NONFINITE = 'E_CANONICAL_NONFINITE'
/** `E_CANONICAL_DIVBY_ZERO` — `/(0, 0)` (§5.4.7). */
export const E_CANONICAL_DIVBY_ZERO = 'E_CANONICAL_DIVBY_ZERO'
/**
 * `E_CANONICAL_UNSUPPORTED_FIELD` — a node carries an expression field outside
 * the RFC-pinned emissible set (`op`/`args`/`wrt`/`dim`/`fn`/`name`/`value`), so
 * no faithful canonical JSON exists (emitting only the pinned fields would make
 * structurally-different aggregates byte-identical — the defect class behind the
 * `fn` bc-node bug). Fail-closed, matching the Julia reference `canonical_json`.
 */
export const E_CANONICAL_UNSUPPORTED_FIELD = 'E_CANONICAL_UNSUPPORTED_FIELD'

/**
 * Fields WITH a pinned slot in the cross-binding canonical JSON node encoding:
 * exactly the set every binding (TS/Python/Rust/Julia) serializes and the
 * cross-language canonical fixtures pin. CLOSED — extending it is a cross-binding
 * format change, never a TS-local edit.
 */
const EMISSIBLE_FIELDS = ['op', 'args', 'wrt', 'dim', 'fn', 'name', 'value', 'units'] as const

/**
 * Fields TOLERATED-AND-IGNORED by the canonical emitter: a node carrying them
 * still canonicalizes, emitting the pinned fields only (matches Julia's
 * `_CANONICAL_IGNORED_FIELDS`). Both are display/rendering conveniences with no
 * wire slot of their own (`arg` — an arg-witness index; `bindings` — the
 * apply_operator parameter map).
 */
const CANONICAL_IGNORED_FIELDS = ['arg', 'bindings'] as const

/**
 * Own keys allowed on a node without failing canonical emission: emissible ∪
 * tolerated. Any OTHER own key with a defined value is NON-EMISSIBLE and makes
 * {@link canonicalJson} throw `E_CANONICAL_UNSUPPORTED_FIELD` (fail-closed:
 * a future field cannot be silently dropped — it must be added to one of the two
 * closed tuples above deliberately).
 */
const CANONICAL_ALLOWED_KEYS: ReadonlySet<string> = new Set<string>([
  ...EMISSIBLE_FIELDS,
  ...CANONICAL_IGNORED_FIELDS,
])

type Node = { op: string; args: Expr[] } & Record<string, unknown>

function isNode(e: unknown): e is Node {
  return typeof e === 'object' && e !== null && !isNumericLiteral(e) && 'op' in e && 'args' in e
}

function isPlainNumber(e: unknown): e is number {
  return typeof e === 'number'
}

function isString(e: unknown): e is string {
  return typeof e === 'string'
}

/** True for plain JS numbers and tagged `NumericLiteral` leaves. */
function isNumericLeaf(e: Expr): boolean {
  return isPlainNumber(e) || isNumericLiteral(e)
}

/** Underlying numeric value for a plain number or `NumericLiteral`. */
function leafValue(e: Expr): number {
  if (isPlainNumber(e)) return e
  if (isNumericLiteral(e)) return e.value
  throw new TypeError('not a numeric leaf')
}

/**
 * A value counts as "float-like" for RFC §5.4.4 type-preserving rules when
 * it is either a plain JS number (TS has no native int tag) or an explicit
 * `floatLit`. Tagged `intLit` leaves and all non-numeric nodes are not
 * float-like.
 */
function isFloatLike(e: Expr): boolean {
  return isPlainNumber(e) || isFloatLit(e)
}

function isZeroValue(e: Expr): boolean {
  return isNumericLeaf(e) && leafValue(e) === 0
}

function isOneValue(e: Expr): boolean {
  return isNumericLeaf(e) && leafValue(e) === 1
}

/** Canonicalize an expression tree per RFC §5.4. Input is not mutated. */
export function canonicalize(expr: Expr): Expr {
  if (isNumericLiteral(expr)) {
    if (!Number.isFinite(expr.value)) {
      throw new CanonicalizeError(E_CANONICAL_NONFINITE)
    }
    return expr
  }
  if (isPlainNumber(expr)) {
    if (!Number.isFinite(expr)) {
      throw new CanonicalizeError(E_CANONICAL_NONFINITE)
    }
    return expr
  }
  if (isString(expr)) {
    return expr
  }
  if (isNode(expr)) {
    return canonOp(expr)
  }
  throw new TypeError(`unknown expression type: ${typeof expr}`)
}

/**
 * Emit canonical on-wire JSON per §5.4.6 (sorted keys, no whitespace).
 *
 * FAIL-CLOSED (matching the Julia reference): `canonicalize` PRESERVES every
 * node field, then this validates the canonicalized tree and throws
 * `E_CANONICAL_UNSUPPORTED_FIELD` if any node carries an own key (with a defined
 * value) outside the emissible ∪ tolerated set. A node carrying a non-emissible
 * aggregate/geometry field has NO faithful canonical JSON — emitting only the
 * pinned fields would collapse structurally-different nodes to identical bytes.
 */
export function canonicalJson(expr: Expr): string {
  const canon = canonicalize(expr)
  assertEmissible(canon)
  return emitJson(canon)
}

/**
 * Fail-closed field validation. Walks the canonicalized tree (recursing into
 * `args`, the only field emission recurses into — matching Julia's
 * `_emit_node_json`) and throws `E_CANONICAL_UNSUPPORTED_FIELD` at the first
 * node carrying a non-emissible own field.
 */
function assertEmissible(e: Expr | unknown): void {
  if (!isNode(e)) return
  const rec = e as Record<string, unknown>
  const offending: string[] = []
  for (const key of Object.keys(rec)) {
    if (rec[key] === undefined) continue
    if (!CANONICAL_ALLOWED_KEYS.has(key)) offending.push(key)
  }
  if (offending.length > 0) {
    throw new CanonicalizeError(
      E_CANONICAL_UNSUPPORTED_FIELD,
      `op '${e.op}' carries field(s) [${offending.join(', ')}] outside the canonical ` +
        `JSON node encoding (op/args/wrt/dim/fn/name/value/units); emitting them would be ` +
        `lossy and non-portable (RFC §5.4.6)`,
    )
  }
  for (const a of e.args) assertEmissible(a)
}

function canonOp(node: Node): Expr {
  const newArgs: Expr[] = node.args.map((a) => canonicalize(a))
  const work: Node = { ...node, args: newArgs }
  if (typeof work.units === 'string') {
    // A `const` node's declared units take the canonical unit spelling
    // (esm-spec §4.8.2), so two spellings of one unit canonicalize alike.
    work.units = canonicalUnitSpelling(work.units)
    if (work.op === 'const' && work.units === '1') {
      // A dimensionless const drops its units (user ruling 2026-11-14): a
      // scalar becomes the bare literal, an array a unitless const.
      if (typeof work.value === 'number' || isNumericLiteral(work.value)) {
        return canonicalize(work.value as Expr)
      }
      delete work.units
    }
  }
  switch (work.op) {
    case '+':
      return canonAdd(work)
    case '*':
      return canonMul(work)
    case '-':
      return canonSub(work)
    case '/':
      return canonDiv(work)
    case 'neg':
      // Deprecated word spelling of unary `-` (esm-spec §4.2): canonicalizes
      // to the unary `-` node, never back to `neg` (RFC §5.4.7).
      return canonNeg(work)
    case 'pow':
      // Deprecated word spelling of `^` (esm-spec §4.2).
      return work.args.length === 2 ? { ...work, op: '^' } : work
    default:
      return work
  }
}

function canonAdd(node: Node): Expr {
  const flat = flattenSameOp(node.args, '+')
  const others: Expr[] = []
  let floatZeroSample: Expr | null = null
  let hadFloatZero = false
  let hadIntZero = false
  for (const a of flat) {
    if (isZeroValue(a)) {
      // Tagged float-zero is conditional (RFC §5.4.4 type-preserving).
      if (isFloatLit(a)) {
        if (floatZeroSample === null) floatZeroSample = a
        hadFloatZero = true
        continue
      }
      // Tagged int-zero and plain-number zeros drop unconditionally.
      if (isIntLit(a)) hadIntZero = true
      continue
    }
    others.push(a)
  }
  if (hadFloatZero && !others.every(isFloatLike)) {
    others.push(floatZeroSample as Expr)
    hadFloatZero = false // consumed — don't re-emit below
  }
  if (others.length === 0) {
    if (hadFloatZero) return floatZeroSample as Expr
    if (hadIntZero) return intLit(0)
    return 0
  }
  if (others.length === 1) return others[0]!
  sortArgs(others)
  return { ...node, op: '+', args: others }
}

function canonMul(node: Node): Expr {
  const flat = flattenSameOp(node.args, '*')
  // Zero annihilation (§5.4.4) — preserve the numeric type of the zero.
  for (const a of flat) {
    if (!isZeroValue(a)) continue
    if (isIntLit(a)) return intLit(0)
    if (isFloatLit(a)) return a // preserves signed zero
    // Plain number zero — preserve signed zero for -0.
    if (isPlainNumber(a) && Object.is(a, -0)) return -0
    return 0
  }
  const others: Expr[] = []
  let floatOneSample: Expr | null = null
  let hadFloatOne = false
  let hadIntOne = false
  for (const a of flat) {
    if (isOneValue(a)) {
      if (isFloatLit(a)) {
        if (floatOneSample === null) floatOneSample = a
        hadFloatOne = true
        continue
      }
      if (isIntLit(a)) hadIntOne = true
      continue
    }
    others.push(a)
  }
  if (hadFloatOne && !others.every(isFloatLike)) {
    others.push(floatOneSample as Expr)
    hadFloatOne = false
  }
  if (others.length === 0) {
    if (hadFloatOne) return floatOneSample as Expr
    if (hadIntOne) return intLit(1)
    return 1
  }
  if (others.length === 1) return others[0]!
  sortArgs(others)
  return { ...node, op: '*', args: others }
}

function canonSub(node: Node): Expr {
  if (node.args.length === 1) return canonNegValue(node.args[0]!)
  if (node.args.length === 2) {
    const a = node.args[0]!
    const b = node.args[1]!
    // `0 - x` is NOT `-x` when x is +0.0 (`0 - 0.0` is +0.0, `-(0.0)` is
    // -0.0), so only a literal subtrahend folds, to the exact difference: an
    // integer when both are integers, else the IEEE float difference. Any
    // other `-(0, x)` stays binary (RFC §5.4.7).
    if (isZeroValue(a) && isNumericLeaf(b)) return subFromZero(a, b)
    if (isZeroValue(b)) {
      // Type-preserving: -(intLit(x), floatLit(0)) → floatLit(x) to keep float promotion.
      if (isFloatLit(b) && isIntLit(a)) return floatLit(a.value)
      return a
    }
  }
  return node
}

/** `zero - b` for a literal zero minuend and a literal `b` (see {@link canonSub}). */
function subFromZero(zero: Expr, b: Expr): Expr {
  // `0 - v` (not `-v`): IEEE subtraction gives +0.0 for both signed zeros.
  const v = 0 - leafValue(b)
  if (isIntLit(zero) && isIntLit(b)) return intLit(v)
  if (isPlainNumber(zero) && isPlainNumber(b)) return v
  return floatLit(v)
}

function canonDiv(node: Node): Expr {
  if (node.args.length !== 2) return node
  const a = node.args[0]!
  const b = node.args[1]!
  if (isZeroValue(a) && isZeroValue(b)) {
    throw new CanonicalizeError(E_CANONICAL_DIVBY_ZERO)
  }
  if (isOneValue(b)) {
    if (isFloatLit(b) && isIntLit(a)) return floatLit(a.value)
    return a
  }
  if (isZeroValue(a)) {
    // /(0, x) — preserve zero type.
    if (isFloatLit(a)) return a
    if (isIntLit(a)) return intLit(0)
    return 0
  }
  return node
}

function canonNeg(node: Node): Expr {
  if (node.args.length !== 1) return node
  return canonNegValue(node.args[0]!)
}

function canonNegValue(arg: Expr): Expr {
  if (isIntLit(arg)) {
    // intLit cannot hold -0, so -0 value is impossible here.
    return arg.value === 0 ? arg : intLit(-arg.value)
  }
  if (isFloatLit(arg)) return floatLit(-arg.value)
  if (isPlainNumber(arg)) return -arg
  // A double negation collapses whichever spelling either negation uses; the
  // inner one is already canonical, so it can only be unary `-` here unless the
  // caller handed in an uncanonicalized `neg`.
  if (isNode(arg) && (arg.op === '-' || arg.op === 'neg') && arg.args.length === 1)
    return arg.args[0]!
  return { op: '-', args: [arg] }
}

function flattenSameOp(args: Expr[], op: string): Expr[] {
  const out: Expr[] = []
  for (const a of args) {
    if (isNode(a) && a.op === op) {
      out.push(...a.args)
    } else {
      out.push(a)
    }
  }
  return out
}

function argTier(e: Expr): number {
  if (isNumericLeaf(e)) return 0
  if (isString(e)) return 1
  if (isNode(e)) return 2
  return 3
}

function sortArgs(args: Expr[]): void {
  const cache = new Map<number, string>()
  const indices = args.map((_, i) => i)
  const getJson = (i: number, e: Expr): string => {
    let s = cache.get(i)
    if (s === undefined) {
      s = emitJson(e)
      cache.set(i, s)
    }
    return s
  }
  indices.sort((ia, ib) => compareExprs(args[ia]!, args[ib]!, ia, ib, getJson))
  const snap = indices.map((i) => args[i]!)
  for (let i = 0; i < args.length; i++) args[i] = snap[i]!
}

function compareExprs(
  a: Expr,
  b: Expr,
  ia: number,
  ib: number,
  getJson: (i: number, e: Expr) => string,
): number {
  const ta = argTier(a)
  const tb = argTier(b)
  if (ta !== tb) return ta - tb
  if (ta === 0) {
    const va = leafValue(a)
    const vb = leafValue(b)
    if (va !== vb) return va - vb
    // Equal magnitude: int before float (RFC §5.4.2 stable tiebreak).
    const af = isFloatLit(a) || isPlainNumber(a)
    const bf = isFloatLit(b) || isPlainNumber(b)
    if (af === bf) return 0
    return af ? 1 : -1
  }
  if (ta === 1) {
    return (a as string) < (b as string) ? -1 : (a as string) > (b as string) ? 1 : 0
  }
  const aj = getJson(ia, a)
  const bj = getJson(ib, b)
  return aj < bj ? -1 : aj > bj ? 1 : 0
}

function emitJson(e: Expr | unknown): string {
  if (isIntLit(e)) {
    // Value is guaranteed integer-valued and finite by intLit(); the shared
    // token emitter re-checks defensively.
    return formatIntToken(e.value, '$')
  }
  // An integer past 2^53, as `canonicalizeDocument` gives it.
  if (typeof e === 'bigint') return e.toString()
  if (isFloatLit(e)) {
    if (!Number.isFinite(e.value)) throw new CanonicalizeError(E_CANONICAL_NONFINITE)
    return formatCanonicalFloat(e.value)
  }
  if (isPlainNumber(e)) {
    if (!Number.isFinite(e)) throw new CanonicalizeError(E_CANONICAL_NONFINITE)
    return formatCanonicalFloat(e)
  }
  if (isString(e)) return JSON.stringify(e)
  if (Array.isArray(e)) {
    // const-op `value` may be a (nested) numeric array. Emit each
    // element via emitJson so floats/ints round-trip canonically.
    return `[${(e as unknown[]).map((v) => emitJson(v)).join(',')}]`
  }
  if (isNode(e)) return emitNodeJson(e)
  if (e === null) return 'null'
  return JSON.stringify(e)
}

function emitNodeJson(n: Node): string {
  // FIXED emitter: only the pinned emissible fields (op,args,wrt,dim,fn,name,
  // value) reach the wire, sorted. Non-emissible fields are NOT dropped
  // silently here — `canonicalJson` validates the canonicalized tree first and
  // throws `E_CANONICAL_UNSUPPORTED_FIELD` for any node carrying one, matching
  // the Julia reference `_emit_node_json`. (This emitter also runs during
  // intermediate arg sorting, where a node may still carry a non-emissible
  // field; emitting the pinned subset gives a stable sort key, and the
  // fail-closed check in `canonicalJson` refuses to return the ambiguous bytes.)
  //
  // Each value routes through `emitJson`: strings emit via `JSON.stringify`,
  // `args`/`value` recurse through `emitJson`.
  const rec = n as Record<string, unknown>
  const entries: Array<[string, string]> = []
  for (const key of EMISSIBLE_FIELDS) {
    const v = rec[key]
    if (v === undefined) continue
    entries.push([key, emitJson(v)])
  }
  entries.sort((x, y) => (x[0] < y[0] ? -1 : x[0] > y[0] ? 1 : 0))
  const body = entries.map(([k, v]) => `${JSON.stringify(k)}:${v}`).join(',')
  return `{${body}}`
}

/**
 * Format a finite `number` as a byte-CANONICAL float token per RFC §5.4.6.
 * Only handles float-typed values: integer-typed `NumericLiteral` nodes are
 * emitted as bare JSON integers by {@link canonicalJson} directly.
 *
 * NAMING: distinct from `formatFloatToken` in `./numeric-literal` (the
 * document-serialization emitter used by `toJson()` / `losslessJsonStringify`).
 * This canonical version additionally NORMALIZES exponent notation — it strips
 * the leading `+` (RFC §5.4.6: "no leading + on the exponent") so `1e25` emits
 * as `1e25`, not `1e+25`, and forces the §5.4.6 exponent thresholds. Use this
 * one for canonical output, `formatFloatToken` for wire round-trip.
 */
export function formatCanonicalFloat(f: number): string {
  if (!Number.isFinite(f)) {
    throw new CanonicalizeError(E_CANONICAL_NONFINITE)
  }
  if (f === 0) {
    return Object.is(f, -0) ? '-0.0' : '0.0'
  }
  const abs = Math.abs(f)
  const useExp = abs < 1e-6 || abs >= 1e21
  if (useExp) {
    return normalizeExponent(f.toString())
  }
  let s = f.toString()
  if (s.includes('e') || s.includes('E')) {
    s = expandToPlain(f)
  }
  if (!s.includes('.')) s += '.0'
  return s
}

function normalizeExponent(s: string): string {
  // `[0-9]*(?:\.[0-9]*)?` accepts the same mantissas as `[0-9]*\.?[0-9]*`
  // without the two adjacent digit runs, which backtrack quadratically on a
  // long run of digits that never reaches an exponent.
  const m = /^(-?[0-9]*(?:\.[0-9]*)?)[eE]([+-]?[0-9]+)$/.exec(s)
  if (!m) return s
  const mant = m[1]!
  let exp = m[2]!
  if (exp.startsWith('+')) exp = exp.slice(1)
  let sign = ''
  if (exp.startsWith('-')) {
    sign = '-'
    exp = exp.slice(1)
  }
  exp = exp.replace(/^0+/, '') || '0'
  return `${mant}e${sign}${exp}`
}

function expandToPlain(f: number): string {
  const s = f.toFixed(20)
  // Drop the fraction's trailing zeros, then a dot left with nothing after it.
  // A scan rather than `/(\.[0-9]*?)0+$/`, which backtracks quadratically.
  // toFixed falls back to exponent notation at |f| >= 1e21; that has no
  // all-digit fraction to trim.
  const dot = s.indexOf('.')
  if (dot < 0 || !/^[0-9]*$/.test(s.slice(dot + 1))) return s
  let end = s.length
  while (end > dot + 1 && s[end - 1] === '0') end--
  if (end === dot + 1) end = dot
  return s.slice(0, end)
}

// ---------------------------------------------------------------------------
// The document-level canonical step (esm-spec §4.8.2 "Canonical spelling").
// ---------------------------------------------------------------------------

/** Object properties whose value is a NAME-KEYED map (esm-schema.json): a map's
 * keys are names, never fields, so a variable NAMED `units` is not a units
 * string. The same list in every binding. */
const DOCUMENT_MAP_KEYS: ReadonlySet<string> = new Set([
  'bind',
  'bindings',
  'coordinates',
  'coords',
  'coupling_roles',
  'data_sources',
  'enums',
  'operator_imports',
  'operators',
  'guesses',
  'index_set_rename',
  'index_sets',
  'initial_conditions',
  'map',
  'metaparameters',
  'models',
  'parameter_overrides',
  'parameters',
  'pinned_coords',
  'ranges',
  'reaction_systems',
  'rebind',
  'rename',
  'species',
  'subsystems',
  'translate',
  'url_substitutions',
  'variables',
  'where',
])

/** Free-form objects (schema `additionalProperties: true`), never descended. */
const DOCUMENT_FREE_KEYS: ReadonlySet<string> = new Set([
  'attrs',
  'config',
  'metadata',
  'reader_options',
  'x_esd',
])

const DOCUMENT_UNIT_KEYS: ReadonlySet<string> = new Set(['units', 'default_units'])

function isPlainObject(x: unknown): x is Record<string, unknown> {
  if (typeof x !== 'object' || x === null || isNumericLiteral(x)) return false
  const proto = Object.getPrototypeOf(x) as unknown
  return proto === Object.prototype || proto === null
}

/**
 * The document-level canonical step: every units string of a document takes
 * the canonical unit spelling (esm-spec §4.8.2, Lean `Esm.Units.canon`).
 *
 * That is every `units` and `default_units` string of a variable, species,
 * parameter, coordinate or `const` node, wherever it sits: nested subsystems,
 * template bodies, tests, coupling entries. Free-form objects (`metadata`,
 * `x_esd`, `attrs`, `config`, `reader_options`) are not respelled, and neither
 * are the keys of name-keyed maps. A `const` node whose units spell `1` loses
 * them: a scalar one becomes the bare literal, an array one a `const` without
 * `units`. The deprecated ops are rewritten (esm-spec §4.2): a `neg` node with
 * one argument becomes unary `-`, a `pow` node with two becomes `^`, and a
 * `broadcast` of `neg` with one argument maps `-`. Every number, free-form
 * objects included, takes its canonical form (CONFORMANCE §5.5.3.1): a
 * `NumericLiteral` or `bigint` whose value is integral and in Int64 is an
 * integer (`2.0` is `2`): an int literal, or past 2^53 a `bigint` of the exact
 * integer; any other is a float literal, and `-0` is `0`; a plain number
 * already holds the nearest binary64 of its token. Takes the decoded JSON
 * document (an `EsmFile` is one; plain numbers, or the tagged literals and
 * bigints of `losslessJsonParse`); the input is not mutated and nothing else
 * changes.
 * These are the rules of Lean `Adapter.Doc.spellRules` and `Adapter.Doc.conv`.
 */
export function canonicalizeDocument<T>(doc: T): T {
  const walk = (value: unknown, isMap: boolean): unknown => {
    if (Array.isArray(value)) return value.map((v) => walk(v, false))
    if (!isPlainObject(value)) return value
    let dropUnits = false
    if (
      !isMap &&
      value.op === 'const' &&
      typeof value.units === 'string' &&
      canonicalUnitSpelling(value.units) === '1'
    ) {
      // A dimensionless const drops its units: a scalar becomes the bare
      // literal, an array a unitless const.
      if (typeof value.value === 'number' || isNumericLiteral(value.value)) return value.value
      dropUnits = true
    }
    // Object.fromEntries defines each key as an own property, so a key named
    // `__proto__` (a legal name in a name-keyed map) is kept, not turned into
    // a prototype assignment.
    const entries: Array<[string, unknown]> = []
    for (const [k, v] of Object.entries(value)) {
      if (dropUnits && k === 'units') continue
      if (isMap) entries.push([k, walk(v, false)])
      else if (DOCUMENT_UNIT_KEYS.has(k) && typeof v === 'string')
        entries.push([k, canonicalUnitSpelling(v)])
      else if (DOCUMENT_FREE_KEYS.has(k)) entries.push([k, v])
      else entries.push([k, walk(v, DOCUMENT_MAP_KEYS.has(k))])
    }
    const out = Object.fromEntries(entries) as Record<string, unknown>
    if (!isMap) rewriteDeprecatedDocumentOp(out)
    return out
  }
  return canonicalDocumentNumbers(walk(doc, false)) as T
}

/** The deprecated ops (esm-spec §4.2): spelling -> [replacement, operand count]. */
const DEPRECATED_DOCUMENT_OPS: ReadonlyMap<string, readonly [string, number]> = new Map([
  ['neg', ['-', 1]],
  ['pow', ['^', 2]],
])

/**
 * `neg` with one argument is unary `-`, `pow` with two is `^`, a `broadcast`
 * of `neg` with one argument maps `-` (Lean `Adapter.Doc.deprecatedTo`).
 * `out` is a fresh object, rewritten in place.
 */
function rewriteDeprecatedDocumentOp(out: Record<string, unknown>): void {
  const op = out.op
  const args = out.args
  if (typeof op !== 'string' || !Array.isArray(args)) return
  const rule = DEPRECATED_DOCUMENT_OPS.get(op)
  if (rule !== undefined) {
    if (args.length === rule[1]) out.op = rule[0]
  } else if (op === 'broadcast' && out.fn === 'neg' && args.length === 1) {
    out.fn = '-'
  }
}

const INT64_MIN = -(2n ** 63n)
const INT64_MAX = 2n ** 63n - 1n

/**
 * An integer in Int64 in canonical form: an int literal, or, past 2^53, where
 * no `number` holds every integer, the `bigint` itself.
 */
function canonicalDocumentInt(z: bigint): NumericLiteral | bigint {
  const v = Number(z)
  return Number.isSafeInteger(v) ? intLit(v) : z
}

/**
 * Every number of a JSON value in canonical form, at every depth
 * (CONFORMANCE §5.5.3.1). A plain number stays plain (`-0` is `0`). A
 * `NumericLiteral` or a `bigint` takes the kind of its value: an integral value
 * in Int64 is an integer (a `bigint` past 2^53), every other value a float
 * literal. A `bigint` is decided by the integer written, not by its rounded
 * value: `9223372036854775807` (Int64 max) is an integer, although its binary64,
 * 2^63, is outside Int64.
 */
function canonicalDocumentNumbers(value: unknown): unknown {
  if (typeof value === 'number') return Object.is(value, -0) ? 0 : value
  if (typeof value === 'bigint') {
    return value >= INT64_MIN && value <= INT64_MAX
      ? canonicalDocumentInt(value)
      : floatLit(Number(value))
  }
  if (isNumericLiteral(value)) {
    const v = value.value
    if (Number.isSafeInteger(v)) {
      const z = Object.is(v, -0) ? 0 : v
      return isIntLit(value) && Object.is(z, v) ? value : intLit(z)
    }
    // A binary64 integer of 2^53 or more is exact; the ones below 2^63 are in Int64.
    if (Number.isInteger(v) && v >= -(2 ** 63) && v < 2 ** 63)
      return canonicalDocumentInt(BigInt(v))
    return isFloatLit(value) ? value : floatLit(v)
  }
  if (Array.isArray(value)) return value.map(canonicalDocumentNumbers)
  if (isPlainObject(value)) {
    return Object.fromEntries(
      Object.entries(value).map(([k, v]) => [k, canonicalDocumentNumbers(v)]),
    )
  }
  return value
}
