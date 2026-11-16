// Flatten a coupled document into one system.
import assert from 'node:assert/strict'
import { fileURLToPath } from 'node:url'
import { loadPath, flatten, printMath, expressionNames } from '@earthsciml/ast'

const fixture = (name: string): string => fileURLToPath(new URL(`../fixtures/${name}`, import.meta.url))

// region: flatten ops=flatten,flattened_system,flattened_variable,flattened_equation,print_math
const doc = loadPath(fixture('coupled.esm'))
const flat = flatten(doc)

// Variables are namespaced by the system that declared them.
assert.deepEqual(Object.keys(flat.stateVariables), ['Heater.T', 'Box.T_air'])
assert.deepEqual(Object.keys(flat.parameters), ['Heater.rate', 'Box.k'])
assert.equal(flat.stateVariables['Box.T_air'].units, 'K')

// The `param_to_var` variable_map replaces the box's wall-temperature
// parameter with the heater's temperature: `Box.T_wall` is gone from the
// parameters above, and the box equation reads `Heater.T` in its place.
// LaTeX prints the dotted names more readably than Typst does.
const equations = flat.equations.map((eq) => {
  const sides = { lhs: eq.lhs, rhs: eq.rhs }
  return printMath(sides, expressionNames(sides), 'markdown')
})
assert.deepEqual(equations, [
  '\\frac{\\mathrm{d} \\mathit{Heater}.T}{\\mathrm{d} t} = \\mathit{Heater}.\\mathit{rate}',
  '\\frac{\\mathrm{d} \\mathit{Box}.T_{\\mathrm{air}}}{\\mathrm{d} t} = ' +
    '\\mathit{Box}.k \\left(\\mathit{Heater}.T - \\mathit{Box}.T_{\\mathrm{air}}\\right)',
])
assert.deepEqual(
  flat.equations.map((eq) => eq.sourceSystem),
  ['Heater', 'Box'],
)
// endregion
