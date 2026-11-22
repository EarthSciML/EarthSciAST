/**
 * Sharing-aware traversals of a raw JSON tree (which may be a DAG: template
 * substitution splices bindings by reference) and the canonical compact byte
 * form of a raw JSON value. Mirrors the Julia reference `json_walk.jl`
 * (`_rewrite_json`, `_rewrite_json_children`, `_visit_json`) and
 * `templates/instances.jl` (`_canonical_compact`).
 */

import { isNumericLiteral, numericValue } from './numeric-literal.js'
import { isObject } from './object-utils.js'

/** Returned by a {@link rewriteJson} callback to keep a node and rewrite its children. */
export const JSON_DESCEND: unique symbol = Symbol('json-descend')

/** The state of one {@link rewriteJson} walk, passed to its callback. */
export interface JsonRewrite {
  f: (rw: JsonRewrite, n: Record<string, unknown>) => unknown
  memo: Map<object, unknown>
}

/**
 * Sharing-preserving rewrite of a raw JSON tree. `f(rw, n)` is called once per
 * object (never on a leaf), parent first, and returns {@link JSON_DESCEND} to
 * keep `n` and rewrite its children, or anything else to replace `n` (the
 * replacement is not descended into). Arrays are always descended. Each
 * container's result is memoized by identity, so a subtree shared under many
 * parents is rewritten once; a container is rebuilt only when a child changed.
 */
export function rewriteJson(
  node: unknown,
  f: (rw: JsonRewrite, n: Record<string, unknown>) => unknown,
  memo: Map<object, unknown> = new Map(),
): unknown {
  return rewriteJsonNode({ f, memo }, node)
}

/** Rewrite the subtree `n` with the walk `rw` (sharing its memo). */
export function rewriteJsonNode(rw: JsonRewrite, n: unknown): unknown {
  if (isObject(n)) {
    if (rw.memo.has(n)) return rw.memo.get(n)
    const r = rw.f(rw, n)
    const res = r === JSON_DESCEND ? rewriteJsonChildren(rw, n) : r
    rw.memo.set(n, res)
    return res
  }
  if (Array.isArray(n)) {
    if (rw.memo.has(n)) return rw.memo.get(n)
    const res = rewriteJsonChildren(rw, n)
    rw.memo.set(n, res)
    return res
  }
  return n
}

/**
 * `n` with each child rewritten by the walk `rw`: a new container when some
 * child changed, else `n` itself. On an object, the value under the key `keep`
 * is copied as it is.
 */
export function rewriteJsonChildren(rw: JsonRewrite, n: unknown, keep?: string): unknown {
  if (Array.isArray(n)) {
    let changed = false
    const out = n.map((v) => {
      const rv = rewriteJsonNode(rw, v)
      if (rv !== v) changed = true
      return rv
    })
    return changed ? out : n
  }
  if (isObject(n)) {
    let changed = false
    const out: Record<string, unknown> = {}
    for (const k of Object.keys(n)) {
      const v = n[k]
      if (k === keep) {
        out[k] = v
        continue
      }
      const rv = rewriteJsonNode(rw, v)
      if (rv !== v) changed = true
      out[k] = rv
    }
    return changed ? out : n
  }
  return n
}

/**
 * Visit each object of a raw JSON tree once (by identity), parent first, in
 * document order. `f(n)` returns `false` to skip `n`'s children (`n` is then
 * not counted as visited); anything else descends. Arrays are descended.
 */
export function visitJson(
  node: unknown,
  f: (n: Record<string, unknown>) => boolean | void,
  seen: Set<object> = new Set(),
): void {
  if (Array.isArray(node)) {
    if (seen.has(node)) return
    seen.add(node)
    for (const v of node) visitJson(v, f, seen)
    return
  }
  if (!isObject(node)) return
  if (seen.has(node)) return
  if (f(node) === false) return
  seen.add(node)
  for (const k of Object.keys(node)) visitJson(node[k], f, seen)
}

/** Byte-wise (UTF-8) comparison of two strings, for sorting. */
export function compareUtf8(a: string, b: string): number {
  // UTF-8 byte order is code point order (UTF-16 code-unit order differs only
  // for astral characters against U+E000..U+FFFF).
  const ia = a[Symbol.iterator]()
  const ib = b[Symbol.iterator]()
  for (;;) {
    const x = ia.next()
    const y = ib.next()
    if (x.done) return y.done ? 0 : -1
    if (y.done) return 1
    const cx = x.value.codePointAt(0)!
    const cy = y.value.codePointAt(0)!
    if (cx !== cy) return cx < cy ? -1 : 1
  }
}

/**
 * A non-integral float written as Julia writes it (the shortest round-trip
 * digits; plain decimal when the decimal point falls in `(-4, 16]`, else
 * `d.ddde±x`). Integral values never reach this (they are written as integers).
 */
export function juliaFloatToken(x: number): string {
  if (!Number.isFinite(x)) return JSON.stringify(x)
  const exp = x.toExponential() // shortest round-trip digits
  const m = /^(-?)(\d)(?:\.(\d+))?e([+-]\d+)$/.exec(exp)
  if (!m) return String(x)
  const e10 = Number(m[4])
  const pt = e10 + 1
  if (pt > -4 && pt <= 16) return String(x)
  const frac = m[3] ?? '0'
  return `${m[1]}${m[2]}.${frac}e${e10}`
}

function canonicalNumber(v: number): string {
  if (Number.isInteger(v) && v >= -(2 ** 63) && v < 2 ** 63) {
    // Integral, Int64-representable: an integer token.
    return Math.abs(v) < 1e21 ? BigInt(v).toString() : String(v)
  }
  return juliaFloatToken(v)
}

/**
 * The canonical byte form of a raw JSON value (CONFORMANCE_SPEC §5.5.3):
 * compact (`,` and `:` separators), object keys sorted by UTF-8 bytes at every
 * level, integral Int64-representable numbers written as integers (§5.5.3.1
 * rule 1), other numbers in their shortest round-trip form. Orders the
 * variants of esm-spec §9.6.4 rule 3.
 */
export function canonicalCompact(x: unknown): string {
  const out: string[] = []
  canonicalWrite(out, x)
  return out.join('')
}

function canonicalWrite(out: string[], x: unknown): void {
  if (x === undefined || x === null) {
    out.push('null')
  } else if (isNumericLiteral(x)) {
    const v = numericValue(x)
    out.push(v === undefined ? 'null' : canonicalNumber(v))
  } else if (typeof x === 'number') {
    out.push(canonicalNumber(x))
  } else if (typeof x === 'bigint') {
    out.push(x.toString())
  } else if (Array.isArray(x)) {
    out.push('[')
    x.forEach((v, i) => {
      if (i > 0) out.push(',')
      canonicalWrite(out, v)
    })
    out.push(']')
  } else if (isObject(x)) {
    const ks = Object.keys(x).sort(compareUtf8)
    out.push('{')
    ks.forEach((k, i) => {
      if (i > 0) out.push(',')
      out.push(JSON.stringify(k), ':')
      canonicalWrite(out, x[k])
    })
    out.push('}')
  } else {
    out.push(JSON.stringify(x))
  }
}
