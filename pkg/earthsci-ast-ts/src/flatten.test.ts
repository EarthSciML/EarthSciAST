/**
 * Unit tests for `flatten` on hand-built documents.
 *
 * The cross-binding contract lives in `flatten-conformance.test.ts`, which
 * drives `tests/conformance/flatten/cases.json`. This file covers the small
 * hand-authored cases that corpus does not: subsystem namespacing, the
 * coupling-rule provenance strings, and the `variable_map` transforms.
 *
 * Since `esm 1.0.0` the flattened maps are ORDERED `name -> variable` records
 * carrying full metadata (esm-libraries-spec §4.7.5 step 4), not bare name
 * lists, and `equations` carry Expression TREES rather than pretty-printed
 * strings — so these assertions read `Object.keys(...)` and compare ASTs.
 */
import { describe, it, expect } from 'vitest'
import { flatten, FlattenError } from './flatten.js'
import { toAscii } from './pretty-print.js'
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
    expect(Object.keys(flat.stateVariables)).toEqual(['Atmos.T'])
    expect(Object.keys(flat.parameters)).toEqual(['Atmos.k'])
    expect(flat.metadata.sourceSystems).toEqual(['Atmos'])
    // Full metadata, not a bare name (step 4): the variable carries its derived
    // role and its owning system, so a consumer can build a problem from the
    // flattened form alone.
    expect(flat.stateVariables['Atmos.T']).toMatchObject({
      name: 'Atmos.T',
      type: 'state',
      sourceSystem: 'Atmos',
    })
    expect(flat.equations).toHaveLength(1)
    expect(flat.equations[0]!.sourceSystem).toBe('Atmos')
    expect(toAscii(flat.equations[0]!.lhs)).toBe('D(Atmos.T)/Dt')
    expect(toAscii(flat.equations[0]!.rhs)).toBe('Atmos.k * Atmos.T')
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
    expect(Object.keys(flat.stateVariables)).toContain('Chem.O3')
    expect(Object.keys(flat.parameters)).toContain('Chem.k1')
    // A species keeps the `species` role — a state that came from a reaction
    // network — and its declared units survive flattening.
    expect(flat.stateVariables['Chem.O3']).toMatchObject({ type: 'species', units: 'mol/L' })
    expect(flat.metadata.sourceSystems).toEqual(['Chem'])
    // One species, one net-consuming reaction: exactly one derived ODE, with the
    // `-1 * rate` form every binding renders (not a unary minus).
    expect(flat.equations).toHaveLength(1)
    expect(toAscii(flat.equations[0]!.rhs)).toBe('-1 * Chem.k1 * Chem.O3 * Chem.O3')
  })

  it('records coupling rules in metadata', () => {
    const file = {
      esm: '1.0.0',
      metadata: { name: 'test' },
      models: {
        A: {
          variables: { x: { type: 'unknown' } },
          equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 1 }],
        },
        B: {
          variables: { y: { type: 'parameter' } },
          equations: [{ lhs: { op: 'D', args: ['z'], wrt: 't' }, rhs: 'y' }],
        },
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
    expect(flat.metadata.couplingRules).toEqual(['variable_map(A.x -> B.y, transform=identity)'])
    // `identity` does NOT promote, so `B.y` stays a parameter — but the
    // substitution still runs, so the equation set names the canonical source.
    expect(Object.keys(flat.parameters)).toContain('B.y')
    expect(toAscii(flat.equations[1]!.rhs)).toBe('A.x')
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
    expect(flat.metadata.couplingRules).toEqual([
      'variable_map(Src.F -> Sink.y, transform=expression)',
    ])
    // An expression transform promotes like `param_to_var`: the target leaves
    // `parameters` and becomes an OBSERVED variable whose defining equation is
    // the transform VERBATIM (its references are already fully scoped).
    expect(Object.keys(flat.parameters)).toEqual(['Sink.offset'])
    expect(Object.keys(flat.observedVariables)).toEqual(['Sink.y'])
    expect(flat.equations).toHaveLength(1)
    expect(toAscii(flat.equations[0]!.lhs)).toBe('Sink.y')
    expect(toAscii(flat.equations[0]!.rhs)).toBe('2 * Src.F + Sink.offset')
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
          B: {
            variables: { y: { type: 'parameter' } },
            equations: [{ lhs: { op: 'D', args: ['z'], wrt: 't' }, rhs: 'y' }],
          },
        },
        coupling: [{ type: 'variable_map', from: 'A.x', to: 'B.y', transform, factor }],
      }) satisfies EsmFile

    const substituted = (
      transform: 'additive' | 'multiplicative' | 'conversion_factor',
      factor?: number,
    ) => toAscii(flatten(makeFile(transform, factor)).equations[0]!.rhs)

    // Factor applies uniformly across every scaling transform (mirrors Rust /
    // Python / Go: `factor * from`, additive and multiplicative alike).
    expect(substituted('multiplicative', 2.5)).toBe('2.5 * A.x')
    expect(substituted('additive', 3)).toBe('3 * A.x')
    expect(substituted('conversion_factor', 1000)).toBe('1000 * A.x')

    // A factor of 1 (or absent) is a no-op identity map.
    expect(substituted('multiplicative', 1)).toBe('A.x')
    expect(substituted('additive')).toBe('A.x')
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
    // Document order: the parent's own variables precede its subsystems'.
    expect(Object.keys(flat.stateVariables)).toEqual(['Outer.y', 'Outer.Inner.x'])
  })

  it('derives the state / observed / brownian buckets from equations and updates', () => {
    // The three output buckets used to mirror three DECLARED variable types
    // (`state` / `observed` / `brownian`). 1.0.0 declares only `unknown` and
    // `parameter`, so each bucket is now derived:
    //   - `S` is an unknown under `D(·,t)`          -> stateVariables
    //   - `C` is an unknown with a BARE-string LHS   -> observedVariables, its
    //     definition carried as an ordinary equation
    //   - `W` is a parameter with a `wiener` update  -> parameters AND
    //     brownianParameters (§6.3.1's four sets PARTITION the parameters)
    //   - `k` is a plain parameter                   -> parameters only
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
    expect(Object.keys(flat.stateVariables)).toEqual(['Box.S'])
    expect(Object.keys(flat.observedVariables)).toEqual(['Box.C'])
    // Declaration order is W then k, and the wiener parameter is IN
    // `parameters`. Excluding it (as this binding used to) would make the
    // parameter vector's LENGTH depend on whether the model is stochastic.
    expect(Object.keys(flat.parameters)).toEqual(['Box.W', 'Box.k'])
    expect(Object.keys(flat.brownianParameters)).toEqual(['Box.W'])
    expect(flat.systemKind).toBe('sde')
    // The observed's DEFINING EXPRESSION is its equation, not a side table.
    expect(toAscii(flat.equations[1]!.lhs)).toBe('Box.C')
    expect(toAscii(flat.equations[1]!.rhs)).toBe('Box.k * Box.S')
  })

  it('refuses a document with no models and no reaction systems', () => {
    const file = { esm: '1.0.0', metadata: { name: 'empty' } } satisfies EsmFile
    expect(() => flatten(file)).toThrow(FlattenError)
    expect(() => flatten(file)).toThrow(/no models or reaction systems/)
  })
})
