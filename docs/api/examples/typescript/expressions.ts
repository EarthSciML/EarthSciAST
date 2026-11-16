// Build expressions and read them from math, list their free variables, substitute.
import assert from 'node:assert/strict'
import {
  parseMath,
  printMath,
  freeVariables,
  substitute,
  simplify,
  contains,
  EsmDiagnosticError,
} from '@earthsciml/ast'
import type { Expr } from '@earthsciml/ast'

// region: expressions ops=parse_math,print_math,free_variables,contains,substitute,simplify
// Expressions are plain JSON trees; build one directly ...
const built: Expr = { op: '*', args: ['k', { op: '-', args: ['T_wall', 'T_air'] }] }

// ... or read one from LaTeX ('markdown') or Typst math, under the names it
// uses: the inverse of `printMath`.
const names = ['k', 'T_wall', 'T_air']
const latex = 'k \\left(T_{\\mathrm{wall}} - T_{\\mathrm{air}}\\right)'
const parsed = parseMath(latex, names, 'markdown') as Expr
assert.deepEqual(parsed, built)
assert.equal(printMath(parsed, names, 'markdown'), latex)
assert.deepEqual([...freeVariables(parsed)].sort(), ['T_air', 'T_wall', 'k'])
assert.equal(contains(parsed, 'T_wall'), true)

// Substitution is single-pass and returns a new tree.
const bound = substitute(parsed, { T_wall: 300, k: 0.05 })
assert.deepEqual(bound, { op: '*', args: [0.05, { op: '-', args: [300, 'T_air'] }] })
assert.deepEqual([...freeVariables(bound)], ['T_air'])
assert.equal(simplify(substitute(parsed, { T_wall: 300, T_air: 300 })), 0)

// Text whose top is `=` reads as an equation.
const eq = parseMath('(dif T_(upright("air")))/(dif t) = k (T_(upright("wall")) - T_(upright("air")))', names, 'typst') as {
  lhs: Expr
  rhs: Expr
}
assert.deepEqual(eq.rhs, built)

// Text that is not math raises a diagnostic error.
assert.throws(() => parseMath('k \\left(T_{\\mathrm{wall}}', names, 'markdown'), EsmDiagnosticError)
// endregion
