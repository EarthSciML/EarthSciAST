import { describe, it, expect } from 'vitest'
import { flatten } from './flatten.js'
import type { EsmFile } from './types.js'

describe('flatten', () => {
  it('namespaces variables from a single model', () => {
    const file = {
      esm: '1.0.0',
      metadata: { name: 'test' },
      models: {
        Atmos: {
          variables: {
            T: { type: 'unknown' },
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
    // `stateVariables` is DERIVED in 1.0.0, not read off a declared type: it
    // holds the unknowns the solver carries (ODE states plus algebraic
    // unknowns). `T` is an unknown under `D(·,t)`, so it is an ODE state.
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
      esm: '1.0.0',
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
      esm: '1.0.0',
      metadata: { name: 'test' },
      models: {
        A: { variables: { x: { type: 'unknown' } }, equations: [] },
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
      esm: '1.0.0',
      metadata: { name: 'test' },
      models: {
        Src: { variables: { F: { type: 'unknown' } }, equations: [] },
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

  it('applies the factor scaling for additive/multiplicative/conversion_factor transforms', () => {
    const makeFile = (
      transform: 'additive' | 'multiplicative' | 'conversion_factor',
      factor?: number,
    ) =>
      ({
        esm: '1.0.0',
        metadata: { name: 'test' },
        models: {
          A: { variables: { x: { type: 'unknown' } }, equations: [] },
          B: { variables: { y: { type: 'parameter' } }, equations: [] },
        },
        coupling: [{ type: 'variable_map', from: 'A.x', to: 'B.y', transform, factor }],
      }) satisfies EsmFile

    // Factor applies uniformly across every scaling transform (mirrors Rust /
    // Python / Go: `factor * from`, additive and multiplicative alike).
    expect(flatten(makeFile('multiplicative', 2.5)).variables['B.y']).toBe('2.5 * A.x')
    expect(flatten(makeFile('additive', 3)).variables['B.y']).toBe('3 * A.x')
    expect(flatten(makeFile('conversion_factor', 1000)).variables['B.y']).toBe('1000 * A.x')

    // A factor of 1 (or absent) is a no-op identity map.
    expect(flatten(makeFile('multiplicative', 1)).variables['B.y']).toBe('A.x')
    expect(flatten(makeFile('additive')).variables['B.y']).toBe('A.x')
  })

  it('produces nested dot-namespacing for subsystems', () => {
    const file = {
      esm: '1.0.0',
      metadata: { name: 'test' },
      models: {
        Outer: {
          variables: { y: { type: 'unknown' } },
          equations: [],
          subsystems: {
            Inner: {
              variables: { x: { type: 'unknown' } },
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

  it('derives the state / observed / brownian buckets from equations and updates', () => {
    // The three output buckets used to mirror three DECLARED variable types
    // (`state` / `observed` / `brownian`). 1.0.0 declares only `unknown` and
    // `parameter`, so each bucket is now derived:
    //   - `S` is an unknown under `D(·,t)`             -> stateVariables
    //   - `C` is an unknown with a BARE-string LHS      -> variables (observed),
    //     mapped to its defining expression, namespaced
    //   - `W` is a parameter with a `wiener` update     -> brownianVariables
    //   - `k` is a plain parameter                      -> parameters
    const file = {
      esm: '1.0.0',
      metadata: { name: 'test' },
      models: {
        Box: {
          variables: {
            S: { type: 'unknown' },
            C: { type: 'unknown' },
            W: {
              type: 'parameter',
              distribution: { kind: 'normal', mean: 0, std: 1 },
              update: { kind: 'wiener' },
            },
            k: { type: 'parameter' },
          },
          equations: [
            { lhs: { op: 'D', args: ['S'], wrt: 't' }, rhs: { op: '*', args: ['k', 'S'] } },
            { lhs: 'C', rhs: { op: '*', args: ['k', 'S'] } },
          ],
        },
      },
    } satisfies EsmFile

    const flat = flatten(file)
    expect(flat.stateVariables).toEqual(['Box.S'])
    expect(flat.parameters).toEqual(['Box.k'])
    expect(flat.brownianVariables).toEqual(['Box.W'])
    expect(flat.variables).toEqual({ 'Box.C': '(Box.k * Box.S)' })
  })
})
