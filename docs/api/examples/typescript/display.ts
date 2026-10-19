// Render equations and expressions for people.
import assert from 'node:assert/strict'
import { fileURLToPath } from 'node:url'
import { loadPath, toUnicode, toLatex, toAscii } from '@earthsciml/ast'

const fixture = (name: string): string => fileURLToPath(new URL(`../fixtures/${name}`, import.meta.url))

// region: display ops=to_unicode,to_latex,to_ascii
const model = loadPath(fixture('decay.esm')).models!.Decay
assert.ok(!('ref' in model)) // hide
const [decay, halfLife] = model.equations

assert.equal(toUnicode(decay), '∂N/∂t = (−λ)·N')
assert.equal(toLatex(decay), '\\frac{\\partial N}{\\partial t} = (-\\lambda) \\cdot N')
assert.equal(toAscii(decay), 'D(N)/Dt = (-lambda) * N')

// A single expression renders the same way.
assert.equal(toUnicode(halfLife.rhs), 'ln(2)/λ')

// So does a whole model: a summary line followed by its equations.
assert.equal(toUnicode(model).split('\n').length, 3)
// endregion
