/**
 * An equation as math: `lhs = rhs` is the math of the expression `==(lhs, rhs)`.
 *
 * Port of `formal/Esm/Document/Source/Equation.lean` (after the Rust binding's
 * `document/source/equation.rs`).
 */

import { jarr, jobj, jstr, type Json } from '../json.js'
import type { Eqn } from './skeleton.js'

/** `Source.eqExpr`: the expression an equation is printed as. */
export function eqExpr(e: Eqn): Json {
  return jobj([
    ['args', jarr([e.lhs, e.rhs])],
    ['op', jstr('==')],
  ])
}

/** `Source.eqSides`: the equation sides of a parsed `==` node. */
export function eqSides(j: Json): [Json, Json] | undefined {
  if (j.t !== 'obj' || j.kvs.length !== 2) return undefined
  const [[a, xs], [o, op]] = j.kvs
  if (
    a !== 'args' ||
    o !== 'op' ||
    xs.t !== 'arr' ||
    op.t !== 'str' ||
    op.s !== '==' ||
    xs.xs.length !== 2
  ) {
    return undefined
  }
  return [xs.xs[0], xs.xs[1]]
}
