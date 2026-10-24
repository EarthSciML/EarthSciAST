// Derive the ODEs of a reaction system.
import assert from 'node:assert/strict'
import { fileURLToPath } from 'node:url'
import { loadPath, deriveOdes, stoichiometricMatrix, odeStates, toAscii } from '@earthsciml/ast'

const fixture = (name: string): string => fileURLToPath(new URL(`../fixtures/${name}`, import.meta.url))

// region: reactions ops=derive_odes,stoichiometric_matrix
const doc = loadPath(fixture('ozone.esm'))
const system = doc.reaction_systems!.Ozone
assert.ok(!('ref' in system)) // narrows away an unresolved `{ ref }` mount

// Mass-action kinetics: one ODE per species.
const odes = deriveOdes(system)
assert.deepEqual(odeStates(odes).sort(), ['NO', 'NO2', 'O3'])
assert.deepEqual(
  odes.equations.map((eq) => toAscii(eq)),
  [
    'D(O3)/Dt = -k1 * NO * O3 + jNO2 * NO2',
    'D(NO)/Dt = -k1 * NO * O3 + jNO2 * NO2',
    'D(NO2)/Dt = k1 * NO * O3 - jNO2 * NO2',
  ],
)

// Net stoichiometry: rows are species, columns are reactions.
const { matrix, species, reactions } = stoichiometricMatrix(system)
assert.deepEqual(species, ['O3', 'NO', 'NO2'])
assert.deepEqual(reactions, ['R1', 'R2'])
assert.deepEqual(matrix, [
  [-1, 1],
  [-1, 1],
  [1, -1],
])
// endregion
