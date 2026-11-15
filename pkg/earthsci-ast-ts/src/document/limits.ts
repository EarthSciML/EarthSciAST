/**
 * What the readers bound that the Lean model leaves unbounded.
 *
 * Port of the Rust binding's `document/limits.rs`. The Lean model's numbers,
 * exponents and recursion are unbounded. The readers refuse, with
 * `parse_error`, a document past one of these bounds, rather than read it as
 * something else or run out of stack:
 *
 * - **Nesting.** At most {@link MAX_NESTING} constructs open at once across the
 *   recursive-descent readers: math sub-expressions (a bracket, a fraction, a
 *   prefix `-` or `\lnot`, a `cases` row, a JSON value in an escape node),
 *   Typst values, YAML blocks and flow collections. Each is read inside
 *   {@link nested}, at exactly the points the Rust readers hold a `Nest`.
 * - **Depth.** A document read from Markdown or Typst nests at most
 *   {@link MAX_JSON_DEPTH} arrays and objects (the depth `serde_json` reads).
 *   A left-nested chain (`a - b - c - …`, LaTeX `a / b / c`, Typst
 *   `a / b / c`) is checked as it grows ({@link shallow}), since it deepens
 *   the value without nesting the reader.
 * - **Numbers.** A decimal beyond the binary64 range (`1.0e400`) has no value a
 *   JSON document can hold; `index.ts` refuses it after the read.
 *
 * The readers stay ports of the Lean functions, which return `undefined` for
 * every refusal; {@link reading} collects what a read ran into, so the refusal
 * can say which bound it hit, and which removed operator its math names.
 */

import type { Json } from './json.js'

/** The most constructs a reader holds open at once. */
export const MAX_NESTING = 128

/** The deepest nesting of arrays and objects in a document. */
export const MAX_JSON_DEPTH = 127

/** What one read ran into, besides its result. */
export interface Findings {
  /** A construct nested past {@link MAX_NESTING}, or a value deeper than {@link MAX_JSON_DEPTH}. */
  tooDeep: boolean
  /** The first removed operator (esm-spec §4.2) the math parser met in a call or escape form. */
  removedOp: string | undefined
}

interface State extends Findings {
  depth: number
}

const fresh = (): State => ({ depth: 0, tooDeep: false, removedOp: undefined })

let state: State = fresh()

/** Run one read and collect its {@link Findings}. */
export function reading<T>(f: () => T): [T, Findings] {
  const saved = state
  state = fresh()
  try {
    const out = f()
    return [out, { tooDeep: state.tooDeep, removedOp: state.removedOp }]
  } finally {
    state = saved
  }
}

/** Record that the read went past a bound. */
export function tooDeep(): void {
  state.tooDeep = true
}

/** Record a removed operator the math names (the first one is kept). */
export function removedOp(op: string): void {
  if (state.removedOp === undefined) state.removedOp = op
}

/**
 * Read one construct (`f`) with it counted as open (the Rust `Nest::enter` and
 * its drop): `undefined`, recorded as {@link tooDeep}, when
 * {@link MAX_NESTING} are open already.
 */
export function nested<T>(f: () => T | undefined): T | undefined {
  if (state.depth >= MAX_NESTING) {
    state.tooDeep = true
    return undefined
  }
  state.depth += 1
  const st = state
  try {
    return f()
  } finally {
    st.depth -= 1
  }
}

/** The nesting depth of arrays and objects in a value (`0` for a scalar), found without recursion. */
export function jsonDepth(j: Json): number {
  let max = 0
  const stack: [Json, number][] = [[j, 0]]
  for (let top = stack.pop(); top !== undefined; top = stack.pop()) {
    const [v, d] = top
    if (v.t === 'arr') {
      max = Math.max(max, d + 1)
      for (const x of v.xs) stack.push([x, d + 1])
    } else if (v.t === 'obj') {
      max = Math.max(max, d + 1)
      for (const [, x] of v.kvs) stack.push([x, d + 1])
    }
  }
  return max
}

/** `j` when it is no deeper than {@link MAX_JSON_DEPTH}; otherwise `undefined`, recorded as {@link tooDeep}. */
export function shallow(j: Json): Json | undefined {
  if (jsonDepth(j) <= MAX_JSON_DEPTH) return j
  tooDeep()
  return undefined
}
