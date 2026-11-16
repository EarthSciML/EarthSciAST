// Print equations and expressions as math for people: LaTeX or Typst.
import assert from 'node:assert/strict'
import { fileURLToPath } from 'node:url'
import { loadPath, printMath, expressionNames } from '@earthsciml/ast'

const fixture = (name: string): string => fileURLToPath(new URL(`../fixtures/${name}`, import.meta.url))

// region: display ops=print_math,expression_names
const model = loadPath(fixture('decay.esm')).models!.Decay
assert.ok(!('ref' in model)) // hide
const [decay, halfLife] = model.equations

// printMath takes an expression or equation and the names it may use: a run
// of letters is one name only when it is declared.
const names = expressionNames(decay)
assert.deepEqual(names, ['N', 'lambda'])
assert.equal(printMath(decay, names, 'markdown'), '\\frac{\\mathrm{d} N}{\\mathrm{d} t} = \\left(-\\lambda\\right) N')
assert.equal(printMath(decay, names, 'typst'), '(dif N)/(dif t) = (-lambda) N')

// A single expression prints the same way.
assert.equal(printMath(halfLife.rhs, expressionNames(halfLife.rhs), 'typst'), 'ln(2)/lambda')
// endregion
