// Flatten a coupled document into one system.
import assert from 'node:assert/strict'
import { fileURLToPath } from 'node:url'
import { loadPath, flatten, toAscii } from '@earthsciml/ast'

const fixture = (name: string): string => fileURLToPath(new URL(`../fixtures/${name}`, import.meta.url))

// region: flatten ops=flatten,flattened_system,flattened_variable,flattened_equation
const doc = loadPath(fixture('coupled.esm'))
const flat = flatten(doc)

// Variables are namespaced by the system that declared them.
assert.deepEqual(Object.keys(flat.stateVariables), ['Heater.T', 'Box.T_air'])
assert.deepEqual(Object.keys(flat.parameters), ['Heater.rate', 'Box.T_wall', 'Box.k'])
assert.equal(flat.stateVariables['Box.T_air'].units, 'K')

// The variable_map coupling is resolved into the equations: the box now sees
// the heater's temperature where it had its wall temperature.
const equations = flat.equations.map((eq) => toAscii(eq))
assert.deepEqual(equations, [
  'D(Heater.T)/Dt = Heater.rate',
  'D(Box.T_air)/Dt = Box.k * (Heater.T - Box.T_air)',
])
assert.deepEqual(
  flat.equations.map((eq) => eq.sourceSystem),
  ['Heater', 'Box'],
)
// endregion
