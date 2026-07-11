/**
 * Integration tests for structural validation with real files
 */

import { describe, it, expect } from 'vitest'
import { validate } from './validate.js'
import { readFixture } from './test-helpers.js'

describe('Structural validation integration', () => {
  it('should detect equation count mismatch in actual test file', () => {
    const data = readFixture('invalid', 'equation_count_mismatch.esm')

    const result = validate(data)

    expect(result.is_valid).toBe(false)
    expect(result.structural_errors).toHaveLength(1)
    expect(result.structural_errors[0].code).toBe('equation_count_mismatch')
    expect(result.structural_errors[0].path).toBe('/models/TestModel')
    expect(result.structural_errors[0].details.state_variables).toEqual(['x', 'y'])
    expect(result.structural_errors[0].details.ode_equations).toBe(1)
    expect(result.structural_errors[0].details.missing_equations_for).toEqual(['y'])
  })

  it('should validate a correct model', () => {
    const validData = {
      esm: '0.1.0',
      metadata: {
        name: 'ValidTest',
      },
      models: {
        TestModel: {
          variables: {
            x: { type: 'state', default: 0.0 },
            k: { type: 'parameter', default: 1.0 },
          },
          equations: [
            {
              lhs: { op: 'D', args: ['x'], wrt: 't' },
              rhs: { op: '*', args: ['k', 'x'] },
            },
          ],
        },
      },
    }

    const result = validate(validData)

    expect(result.is_valid).toBe(true)
    expect(result.schema_errors).toHaveLength(0)
    expect(result.structural_errors).toHaveLength(0)
  })

  it('should detect undefined species in reaction system', async () => {
    // Read a reaction system file and modify it to have undefined species
    const validReactionData = {
      esm: '0.1.0',
      metadata: {
        name: 'InvalidReactionTest',
      },
      reaction_systems: {
        TestSystem: {
          species: {
            A: { default: 1.0 },
          },
          parameters: {
            k: { default: 0.1 },
          },
          reactions: [
            {
              id: 'R1',
              substrates: [{ species: 'UndefinedSpecies', stoichiometry: 1 }],
              products: [{ species: 'A', stoichiometry: 1 }],
              rate: 'k',
            },
          ],
        },
      },
    }

    const result = validate(validReactionData)

    expect(result.is_valid).toBe(false)
    expect(result.structural_errors.some((err) => err.code === 'undefined_species')).toBe(true)

    const speciesError = result.structural_errors.find((err) => err.code === 'undefined_species')
    expect(speciesError?.details.species).toBe('UndefinedSpecies')
    expect(speciesError?.details.reaction_id).toBe('R1')
  })
})
