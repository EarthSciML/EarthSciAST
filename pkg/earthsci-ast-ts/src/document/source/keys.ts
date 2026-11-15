/**
 * Objects in canonical form: sorting entries, and splitting an object between
 * surfaces.
 *
 * Port of `formal/Esm/Document/Source/Keys.lean` (after the Rust binding's
 * `document/source/keys.rs`).
 */

import { cmpCodePoints, jobj, type Json } from '../json.js'

/** One object entry. */
export type Kv = readonly [string, Json]
/** An object's entries. */
export type Kvs = readonly Kv[]

/** `Source.sortKeys`: the entries ordered by key (a stable sort). */
export function sortKvs(l: Kvs): Kv[] {
  return [...l].sort((a, b) => cmpCodePoints(a[0], b[0]))
}

/** `Source.at_`: the entries of `l` with key `k`. */
export function at_(k: string, l: Kvs): Kv[] {
  return l.filter((kv) => kv[0] === k)
}

/**
 * `Source.splitField`: the entries of an object-valued field that `pick` takes,
 * and the residue (`undefined` when every entry was taken and there was at least
 * one).
 */
export function splitField<B>(
  pick: (k: string, v: Json) => B | undefined,
  v: Json,
): [B[], Json | undefined] {
  if (v.t !== 'obj') return [[], v]
  const ps: B[] = []
  const rs: Kv[] = []
  for (const kv of v.kvs) {
    const p = pick(kv[0], kv[1])
    if (p !== undefined) ps.push(p)
    else rs.push(kv)
  }
  return [ps, ps.length > 0 && rs.length === 0 ? undefined : jobj(rs)]
}

/** `Source.splitOpt`: `splitField` of a field that may be absent. */
export function splitOpt<B>(
  pick: (k: string, v: Json) => B | undefined,
  v: Json | undefined,
): [B[], Json | undefined] {
  return v === undefined ? [[], undefined] : splitField(pick, v)
}

/**
 * `Source.joinField`: the field rebuilt from its pieces and its residue:
 * `undefined` when they do not fit together, `null` when the field is absent.
 */
export function joinField<B>(
  back: (b: B) => Kv | undefined,
  ps: readonly B[],
  r: Json | undefined,
): Json | null | undefined {
  if (ps.length === 0) return r === undefined ? null : r
  const es: Kv[] = []
  for (const p of ps) {
    const e = back(p)
    if (e === undefined) return undefined
    es.push(e)
  }
  if (r === undefined) return jobj(sortKvs(es))
  if (r.t === 'obj') return jobj(sortKvs([...es, ...r.kvs]))
  return undefined
}

/**
 * `Source.pickOne`: the value of key `k`, when it occurs at most once (`null`
 * when it does not occur, `undefined` when it occurs twice or more).
 */
export function pickOne(k: string, l: Kvs): Json | null | undefined {
  let found: Json | null = null
  for (const [key, v] of l) {
    if (key !== k) continue
    if (found !== null) return undefined
    found = v
  }
  return found
}
