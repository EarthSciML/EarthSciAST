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
} from './numeric-literal.js'

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
const EMISSIBLE_FIELDS = ['op', 'args', 'wrt', 'dim', 'fn', 'name', 'value'] as const

/**
 * Fields TOLERATED-AND-IGNORED by the canonical emitter: a node carrying them
 * still canonicalizes, emitting the pinned fields only (matches Julia's
 * `_CANONICAL_IGNORED_FIELDS`). Both are display/rendering conveniences with no
 * wire slot of their own (`arg` — the argmin/argmax witness index for the
 * pretty-printer; `bindings` — the apply_expression_template parameter map).
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
        `JSON node encoding (op/args/wrt/dim/fn/name/value); emitting them would be ` +
        `lossy and non-portable (RFC §5.4.6)`,
    )
  }
  for (const a of e.args) assertEmissible(a)
}

function canonOp(node: Node): Expr {
  const newArgs: Expr[] = node.args.map((a) => canonicalize(a))
  const work: Node = { ...node, args: newArgs }
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
      return canonNeg(work)
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
    if (isZeroValue(a)) return canonNegValue(b)
    if (isZeroValue(b)) {
      // Type-preserving: -(intLit(x), floatLit(0)) → floatLit(x) to keep float promotion.
      if (isFloatLit(b) && isIntLit(a)) return floatLit(a.value)
      return a
    }
  }
  return node
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
  if (isNode(arg) && arg.op === 'neg' && arg.args.length === 1) return arg.args[0]!
  return { op: 'neg', args: [arg] }
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
 * document-serialization emitter used by `save()` / `losslessJsonStringify`).
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
  const m = /^(-?[0-9]*\.?[0-9]*)[eE]([+-]?[0-9]+)$/.exec(s)
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
  return s.replace(/(\.[0-9]*?)0+$/, '$1').replace(/\.$/, '')
}
