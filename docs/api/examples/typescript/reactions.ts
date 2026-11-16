// Derive the ODEs of a reaction system.
import assert from 'node:assert/strict'
import { fileURLToPath } from 'node:url'
import { loadPath, deriveOdes, stoichiometricMatrix, odeStates, printMath, expressionNames } from '@earthsciml/ast'

const fixture = (name: string): string => fileURLToPath(new URL(`../fixtures/${name}`, import.meta.url))

// region: reactions ops=derive_odes,stoichiometric_matrix,print_math
const doc = loadPath(fixture('ozone.esm'))
const system = doc.reaction_systems!.Ozone
assert.ok(!('ref' in system)) // narrows away an unresolved `{ ref }` mount

// Mass-action kinetics: one ODE per species.
const odes = deriveOdes(system)
assert.deepEqual(odeStates(odes).sort(), ['NO', 'NO2', 'O3'])
// Printed as LaTeX, which spells chemical names more readably than Typst does.
assert.deepEqual(
  odes.equations.map((eq) => printMath(eq, expressionNames(eq), 'markdown')),
  [
    '\\frac{\\mathrm{d} \\mathrm{O_{3}}}{\\mathrm{d} t} = ' +
      '-1 \\left(\\mathit{k1} \\mathrm{NO} \\mathrm{O_{3}}\\right) + \\mathit{jNO2} \\mathrm{NO_{2}}',
    '\\frac{\\mathrm{d} \\mathrm{NO}}{\\mathrm{d} t} = ' +
      '-1 \\left(\\mathit{k1} \\mathrm{NO} \\mathrm{O_{3}}\\right) + \\mathit{jNO2} \\mathrm{NO_{2}}',
    '\\frac{\\mathrm{d} \\mathrm{NO_{2}}}{\\mathrm{d} t} = ' +
      '\\mathit{k1} \\mathrm{NO} \\mathrm{O_{3}} + -1 \\left(\\mathit{jNO2} \\mathrm{NO_{2}}\\right)',
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
