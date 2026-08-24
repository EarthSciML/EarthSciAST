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
import { flatten, CoupleMultiplicativeNoTendencyError, FlattenError } from './flatten.js'
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

/**
 * The `operator_compose` `translate` map, in the direction esm-spec §10.2 and
 * esm-libraries-spec §4.7.1 step 2 fix: for `"systems": [A, B]` every KEY names
 * a variable of A and every VALUE names a variable of B.
 *
 * These are the two failure modes the corpus's new `operator_compose` tier
 * exists to catch, reduced to the smallest documents that show them.
 */
describe('operator_compose translate direction (§10.2 / §4.7.1 step 2)', () => {
  /** A: one ODE state `x`. B: one ODE on a DIFFERENTLY named `y`. */
  function differentlyNamed(translate: Record<string, unknown>): EsmFile {
    return {
      esm: '1.0.0',
      metadata: { name: 'translate-direction' },
      models: {
        A: {
          variables: { x: { type: 'unknown' }, k: { type: 'parameter' } },
          equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: { op: '*', args: ['k', 'x'] } }],
        },
        B: {
          variables: { y: { type: 'unknown' }, u: { type: 'parameter' } },
          equations: [{ lhs: { op: 'D', args: ['y'], wrt: 't' }, rhs: { op: '*', args: ['u', 'y'] } }],
        },
      },
      coupling: [{ type: 'operator_compose', systems: ['A', 'B'], translate }],
    } as unknown as EsmFile
  }

  it('composes with the AUTHORED direction: keys in A, values in B', () => {
    const flat = flatten(differentlyNamed({ 'A.x': 'B.y' }))
    // One merged equation, not two: B's `D(y)` was consumed into A's `D(x)`.
    expect(flat.equations).toHaveLength(1)
    expect(toAscii(flat.equations[0]!.lhs)).toBe('D(A.x)/Dt')
    // §4.7.1 step 4: B's dependent variable is rewritten to A's target
    // throughout `rhs_B`. Leaving `B.y` here would strand it as an unknown
    // nothing defines — its defining equation was just consumed.
    expect(toAscii(flat.equations[0]!.rhs)).toBe('A.k * A.x + B.u * A.x')
    // `B.y` does NOT survive as a declaration. §4.7.1 step 4's last bullet and
    // esm-spec §10.2 now settle what an earlier revision left open: a
    // translation match consumes the merged-away name, because an unknown whose
    // defining equation was just consumed classifies as ALGEBRAIC (§6.3.1) and
    // would hand the solver an unconstrained state. The rewrite above keeps
    // `B.y` out of the merged RHS; the prune is its other half.
    expect(Object.keys(flat.stateVariables)).toEqual(['A.x'])
  })

  it('applies the translate conversion factor to B`s RHS only', () => {
    const flat = flatten(differentlyNamed({ 'A.x': { var: 'B.y', factor: 2 } }))
    expect(flat.equations).toHaveLength(1)
    // `*` is left-associative and flat in the printer, so the factor node reads
    // without parentheses; the TREE is `2 * (B.u * A.x)`.
    expect(toAscii(flat.equations[0]!.rhs)).toBe('A.k * A.x + 2 * B.u * A.x')
  })

  it('keeps a redundant `B._var` translate value harmless (§10.2)', () => {
    // Placeholder expansion is automatic, so naming `_var` in `translate` asks
    // for something that already happens: the flattened system MUST equal the
    // one produced with no `translate` at all. Consulting an A-keyed map with
    // B's POST-expansion dependent variable made this a spurious
    // ConflictingDerivativeError — bug (b) of the operator_compose defect.
    const withPlaceholder = (translate?: Record<string, unknown>): EsmFile =>
      ({
        esm: '1.0.0',
        metadata: { name: 'redundant-translate' },
        models: {
          A: {
            variables: { x: { type: 'unknown' }, k: { type: 'parameter' } },
            equations: [
              { lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: { op: '*', args: ['k', 'x'] } },
            ],
          },
          B: {
            variables: { u: { type: 'parameter' } },
            equations: [
              { lhs: { op: 'D', args: ['_var'], wrt: 't' }, rhs: { op: '*', args: ['u', '_var'] } },
            ],
          },
        },
        coupling: [
          translate === undefined
            ? { type: 'operator_compose', systems: ['A', 'B'] }
            : { type: 'operator_compose', systems: ['A', 'B'], translate },
        ],
      }) as unknown as EsmFile

    const bare = flatten(withPlaceholder())
    const redundant = flatten(withPlaceholder({ 'A.x': 'B._var' }))
    expect(toAscii(redundant.equations[0]!.lhs)).toBe(toAscii(bare.equations[0]!.lhs))
    expect(toAscii(redundant.equations[0]!.rhs)).toBe(toAscii(bare.equations[0]!.rhs))
    expect(toAscii(bare.equations[0]!.rhs)).toBe('A.k * A.x + B.u * A.x')
    expect(bare.equations).toHaveLength(1)
    expect(redundant.equations).toHaveLength(1)
  })
})

/**
 * `couple` + `transform: "multiplicative"` against a target with no tendency
 * (esm-spec §10.3, esm-libraries-spec §4.7.2), and the deliberate asymmetry
 * with `additive`.
 */
describe('couple multiplicative requires an existing tendency (§10.3)', () => {
  function coupled(to: string, transform: string): EsmFile {
    return {
      esm: '1.0.0',
      metadata: { name: 'multiplicative-tendency' },
      models: {
        A: {
          variables: { x: { type: 'unknown' }, s: { type: 'parameter', default: 3 } },
          equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 'x' }],
        },
        B: {
          variables: { y: { type: 'unknown' } },
          equations: [{ lhs: { op: 'D', args: ['y'], wrt: 't' }, rhs: 'y' }],
        },
      },
      coupling: [
        {
          type: 'couple',
          systems: ['A', 'B'],
          connector: { equations: [{ from: 'B.y', to, transform, expression: 'B.y' }] },
        },
      ],
    } as unknown as EsmFile
  }

  it('raises when `to` names a PARAMETER — it is never silently dropped', () => {
    expect(() => flatten(coupled('A.s', 'multiplicative'))).toThrow(
      CoupleMultiplicativeNoTendencyError,
    )
    try {
      flatten(coupled('A.s', 'multiplicative'))
      expect.unreachable('flatten should have raised')
    } catch (err) {
      expect(err).toBeInstanceOf(FlattenError)
      expect((err as CoupleMultiplicativeNoTendencyError).code).toBe(
        'couple_multiplicative_no_tendency',
      )
      // The diagnostic must NAME the target (§4.7.2).
      expect((err as Error).message).toContain('A.s')
    }
  })

  it('raises when `to` names nothing at all', () => {
    expect(() => flatten(coupled('A.nope', 'multiplicative'))).toThrow(
      CoupleMultiplicativeNoTendencyError,
    )
  })

  it('multiplies normally when `to` DOES carry a tendency', () => {
    const flat = flatten(coupled('A.x', 'multiplicative'))
    const eq = flat.equations.find((e) => toAscii(e.lhs) === 'D(A.x)/Dt')
    expect(eq).toBeDefined()
    expect(toAscii(eq!.rhs)).toBe('A.x * B.y')
  })

  it('does NOT raise for `additive` against an absent tendency', () => {
    // The asymmetry is deliberate: zero is the additive identity, so an
    // additive term against an absent tendency has an obvious reading. There is
    // no multiplicative counterpart, which is why only one of the two errors.
    expect(() => flatten(coupled('A.s', 'additive'))).not.toThrow()
  })
})
