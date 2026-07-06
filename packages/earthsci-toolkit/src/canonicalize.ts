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

import type { Expression } from './generated.js'
import {
  type NumericLiteral,
  intLit,
  floatLit,
  isFloatLit,
  isIntLit,
  isNumericLiteral,
  formatIntToken,
} from './numeric-literal.js'

export class CanonicalizeError extends Error {
  /** Stable RFC §5.4.6 / §5.4.7 error code. */
  readonly code: string
  constructor(code: string, message?: string) {
    super(message ?? code)
    this.code = code
    this.name = 'CanonicalizeError'
  }
}

/** `E_CANONICAL_NONFINITE` — NaN or ±Inf (§5.4.6). */
export const E_CANONICAL_NONFINITE = 'E_CANONICAL_NONFINITE'
/** `E_CANONICAL_DIVBY_ZERO` — `/(0, 0)` (§5.4.7). */
export const E_CANONICAL_DIVBY_ZERO = 'E_CANONICAL_DIVBY_ZERO'

type Expr = Expression | NumericLiteral
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

/** Emit canonical on-wire JSON per §5.4.6 (sorted keys, no whitespace). */
export function canonicalJson(expr: Expr): string {
  return emitJson(canonicalize(expr))
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
  const entries: Array<[string, string]> = []
  entries.push(['op', JSON.stringify(n.op)])
  entries.push(['args', `[${n.args.map(emitJson).join(',')}]`])
  if ('wrt' in n && (n as Record<string, unknown>).wrt !== undefined) {
    entries.push(['wrt', JSON.stringify((n as Record<string, unknown>).wrt)])
  }
  if ('dim' in n && (n as Record<string, unknown>).dim !== undefined) {
    entries.push(['dim', JSON.stringify((n as Record<string, unknown>).dim)])
  }
  if ('fn' in n && (n as Record<string, unknown>).fn !== undefined) {
    // `fn` carries the boundary-condition kind on synthetic `bc` nodes
    // (esm-spec §9.2). Emit it symmetrically with `dim`/`wrt` so the kind is
    // preserved in the canonical form — otherwise bc(u,dirichlet,xmin) and
    // bc(u,neumann,xmin) collapse to the same canonical JSON, making the
    // kind/side matcher's canonical equality kind-blind (ess-tox / G8).
    entries.push(['fn', JSON.stringify((n as Record<string, unknown>).fn)])
  }
  if ('name' in n && (n as Record<string, unknown>).name !== undefined) {
    entries.push(['name', JSON.stringify((n as Record<string, unknown>).name)])
  }
  if ('value' in n && (n as Record<string, unknown>).value !== undefined) {
    entries.push(['value', emitJson((n as Record<string, unknown>).value)])
  }
  entries.sort((x, y) => (x[0] < y[0] ? -1 : x[0] > y[0] ? 1 : 0))
  const body = entries.map(([k, v]) => `${JSON.stringify(k)}:${v}`).join(',')
  return `{${body}}`
}

/**
 * Format a finite `number` per RFC §5.4.6. Only handles float-typed
 * values: integer-typed `NumericLiteral` nodes are emitted as bare JSON
 * integers by {@link canonicalJson} directly.
 *
 * Unlike the convenience helper re-exported from `./numeric-literal`, this
 * version strips the leading `+` on exponent notation (RFC §5.4.6:
 * "no leading + on the exponent") so `1e25` emits as `1e25`, not `1e+25`.
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
