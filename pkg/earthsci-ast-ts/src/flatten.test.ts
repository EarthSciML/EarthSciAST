import { describe, it, expect } from 'vitest'
import { flatten } from './flatten.js'
import type { EsmFile } from './types.js'

describe('flatten', () => {
  it('namespaces variables from a single model', () => {
    const file = {
      esm: '0.1.0',
      metadata: { name: 'test' },
      models: {
        Atmos: {
          variables: {
            T: { type: 'state' },
            k: { type: 'parameter' },
          },
          equations: [
            {
              lhs: { op: 'D', args: ['T'], wrt: 't' },
              rhs: { op: '*', args: ['k', 'T'] },
            },
          ],
        },
      },
    } satisfies EsmFile

    const flat = flatten(file)
    expect(flat.stateVariables).toEqual(['Atmos.T'])
    expect(flat.parameters).toEqual(['Atmos.k'])
    expect(flat.metadata.sourceSystems).toEqual(['Atmos'])
    expect(flat.equations).toHaveLength(1)
    expect(flat.equations[0]!.sourceSystem).toBe('Atmos')
    expect(flat.equations[0]!.lhs).toContain('Atmos.T')
    expect(flat.equations[0]!.rhs).toContain('Atmos.k')
    expect(flat.equations[0]!.rhs).toContain('Atmos.T')
  })

  it('namespaces species and parameters from a reaction system', () => {
    const file = {
      esm: '0.1.0',
      metadata: { name: 'test' },
      reaction_systems: {
        Chem: {
          species: { O3: { units: 'mol/L' } },
          parameters: { k1: { units: '1/s' } },
          reactions: [
            {
              id: 'R1',
              substrates: [{ species: 'O3', stoichiometry: 1 }],
              products: null,
              rate: { op: '*', args: ['k1', 'O3'] },
            },
          ],
        },
      },
    } satisfies EsmFile

    const flat = flatten(file)
    expect(flat.stateVariables).toContain('Chem.O3')
    expect(flat.parameters).toContain('Chem.k1')
    expect(flat.metadata.sourceSystems).toEqual(['Chem'])
    expect(flat.equations.length).toBeGreaterThan(0)
  })

  it('records coupling rules in metadata', () => {
    const file = {
      esm: '0.1.0',
      metadata: { name: 'test' },
      models: {
        A: { variables: { x: { type: 'state' } }, equations: [] },
        B: { variables: { y: { type: 'parameter' } }, equations: [] },
      },
      coupling: [
        {
          type: 'variable_map',
          from: 'A.x',
          to: 'B.y',
          transform: 'identity',
        },
      ],
    } satisfies EsmFile

    const flat = flatten(file)
    expect(flat.metadata.couplingRules).toHaveLength(1)
    expect(flat.metadata.couplingRules[0]).toContain('variable_map')
    expect(flat.variables['B.y']).toBe('A.x')
  })

  it('handles an expression (object) transform in variable_map', () => {
    const file = {
      esm: '0.1.0',
      metadata: { name: 'test' },
      models: {
        Src: { variables: { F: { type: 'state' } }, equations: [] },
        Sink: {
          variables: {
            offset: { type: 'parameter' },
            y: { type: 'parameter' },
          },
          equations: [],
        },
      },
      coupling: [
        {
          type: 'variable_map',
          from: 'Src.F',
          to: 'Sink.y',
          transform: {
            op: '+',
            args: [{ op: '*', args: [2.0, 'Src.F'] }, 'Sink.offset'],
          },
        },
      ],
    } satisfies EsmFile

    const flat = flatten(file)
    expect(flat.metadata.couplingRules).toEqual(['variable_map(Src.F -> Sink.y, expression)'])
    expect(flat.variables['Sink.y']).toBe('((2 * Src.F) + Sink.offset)')
  })

  it('produces nested dot-namespacing for subsystems', () => {
    const file = {
      esm: '0.1.0',
      metadata: { name: 'test' },
      models: {
        Outer: {
          variables: { y: { type: 'state' } },
          equations: [],
          subsystems: {
            Inner: {
              variables: { x: { type: 'state' } },
              equations: [],
            },
          },
        },
      },
    } satisfies EsmFile

    const flat = flatten(file)
    expect(flat.stateVariables).toContain('Outer.y')
    expect(flat.stateVariables).toContain('Outer.Inner.x')
  })
})
