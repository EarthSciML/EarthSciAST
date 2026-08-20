/**
 * Tests for the shared component/variable/equation traversal (`traverse.ts`).
 *
 * The fixture exercises every branch of the documented subsystem/skip policy:
 * top-level real components, an inline nested subsystem (recursion +
 * scopedName composition), a `{ref}` include stub, and a `{kind}` data-loader
 * stub. The stubs deliberately carry a bogus `subsystems` map to prove they
 * are treated as opaque leaves and never descended into.
 */
import { describe, it, expect } from 'vitest'
import {
  forEachComponent,
  forEachModelVariable,
  forEachEquation,
  isReferenceStub,
  type ComponentVisit,
} from './traverse.js'
import type { EsmFile, Model, ReactionSystem } from './types.js'

/**
 * Hand-built file:
 *   models:
 *     M1 (inline)  variables x/k/y, one equation, subsystems:
 *       Sub  (inline model, one variable + one equation)  -> descended
 *       Ext  ({ref}, + bogus subsystems.Ghost)            -> leaf, not descended
 *       Load ({kind:'grid'}, + bogus subsystems.Ghost)    -> leaf, not descended
 *     MRef ({ref})                                        -> top-level leaf
 *   reaction_systems:
 *     R1 (inline)  species A/B, param k1, one reaction,
 *                  one constraint_equation, subsystems:
 *       RSub (inline reaction system)                     -> descended
 *       RRef ({ref})                                      -> leaf, not descended
 *
 * There is no data-loader subsystem: from esm 1.0.0 a data source is ingest
 * configuration rather than a component, so it cannot appear in `subsystems` at
 * all, and `kind` is no longer a reference-stub discriminator.
 */
const file: EsmFile = {
  esm: '1.0.0',
  metadata: { name: 'traverse-fixture' },
  models: {
    M1: {
      variables: {
        x: { type: 'unknown' },
        k: { type: 'parameter' },
        // An observed unknown: defined by the bare-LHS equation below.
        y: { type: 'unknown' },
      },
      equations: [
        { lhs: { op: 'D', args: ['x'] }, rhs: 'k' },
        { lhs: 'y', rhs: { op: '*', args: ['k', 'x'] } },
      ],
      subsystems: {
        Sub: {
          variables: { z: { type: 'unknown' } },
          equations: [{ lhs: { op: 'D', args: ['z'] }, rhs: 'z' }],
        } as Model,
        // Reference stub with a bogus nested subsystem to prove non-descent.
        Ext: {
          ref: './external.esm',
          subsystems: { Ghost: { variables: {}, equations: [] } },
        } as any,
      },
    },
    MRef: { ref: './other.esm' },
  },
  reaction_systems: {
    R1: {
      species: { A: {}, B: {} },
      parameters: { k1: { default: 1 } },
      reactions: [
        {
          id: 'r1',
          substrates: [{ species: 'A', stoichiometry: 1 }],
          products: [{ species: 'B', stoichiometry: 1 }],
          rate: 'k1',
        },
      ],
      constraint_equations: [{ lhs: 'A', rhs: 'B' }],
      subsystems: {
        RSub: {
          species: { C: {} },
          parameters: {},
          reactions: [
            {
              id: 'r2',
              substrates: null,
              products: [{ species: 'C', stoichiometry: 1 }],
              rate: '1',
            },
          ],
        } as ReactionSystem,
        RRef: { ref: './sub.esm' },
      },
    },
  },
}

const M1 = file.models!.M1 as Model
const R1 = file.reaction_systems!.R1 as ReactionSystem

function collect(opts?: { recurse?: boolean }): ComponentVisit[] {
  const seen: ComponentVisit[] = []
  forEachComponent(file, (v) => seen.push(v), opts)
  return seen
}

describe('isReferenceStub', () => {
  it('flags `ref` includes, not real components', () => {
    expect(isReferenceStub({ ref: './x.esm' })).toBe(true)
    expect(isReferenceStub(M1)).toBe(false)
    expect(isReferenceStub(R1)).toBe(false)
  })
})

describe('forEachComponent (no recursion)', () => {
  it('visits only top-level entries, including stubs as leaves', () => {
    const seen = collect()
    expect(seen.map((v) => v.scopedName)).toEqual(['M1', 'MRef', 'R1'])
  })

  it('sets kind and isReference correctly', () => {
    const byName = new Map(collect().map((v) => [v.scopedName, v]))
    expect(byName.get('M1')).toMatchObject({ kind: 'models', isReference: false })
    expect(byName.get('MRef')).toMatchObject({ kind: 'models', isReference: true })
    expect(byName.get('R1')).toMatchObject({ kind: 'reaction_systems', isReference: false })
  })
})

describe('forEachComponent (recurse: true)', () => {
  it('descends inline subsystems and composes scopedName with dots', () => {
    const names = collect({ recurse: true }).map((v) => v.scopedName)
    // Inline subsystems appear with dot-composed names, pre-order.
    expect(names).toContain('M1.Sub')
    expect(names).toContain('R1.RSub')
    // Reference stubs are still visited as leaves...
    expect(names).toContain('M1.Ext')
    expect(names).toContain('R1.RRef')
  })

  it('does NOT descend into ref stubs (opaque leaves)', () => {
    const names = collect({ recurse: true }).map((v) => v.scopedName)
    // The bogus `Ghost` subsystem hung off the stub must never be visited.
    expect(names).not.toContain('M1.Ext.Ghost')
  })

  it('emits the full expected visit set in pre-order', () => {
    expect(collect({ recurse: true }).map((v) => v.scopedName)).toEqual([
      'M1',
      'M1.Sub',
      'M1.Ext',
      'MRef',
      'R1',
      'R1.RSub',
      'R1.RRef',
    ])
  })

  it('marks descended inline subsystems as non-reference', () => {
    const byName = new Map(collect({ recurse: true }).map((v) => [v.scopedName, v]))
    expect(byName.get('M1.Sub')).toMatchObject({ kind: 'models', isReference: false })
    expect(byName.get('R1.RSub')).toMatchObject({ kind: 'reaction_systems', isReference: false })
    expect(byName.get('M1.Ext')).toMatchObject({ isReference: true })
  })
})

describe('forEachModelVariable', () => {
  it('visits every variable with (value, name)', () => {
    const names: string[] = []
    const types: string[] = []
    forEachModelVariable(M1, (variable, name) => {
      names.push(name)
      types.push(variable.type)
    })
    expect(names).toEqual(['x', 'k', 'y'])
    // Two declared types only; `y` being OBSERVED is derived from its equation,
    // not from anything on the variable.
    expect(types).toEqual(['unknown', 'parameter', 'unknown'])
  })
})

describe('forEachEquation', () => {
  it('covers Model.equations', () => {
    const seen: number[] = []
    forEachEquation(M1, (_eq, i) => seen.push(i))
    // Two now: the state's derivative equation and the observed's defining one.
    expect(seen).toEqual([0, 1])
  })

  it('covers ReactionSystem.constraint_equations', () => {
    const eqs: Array<{ lhs: unknown; rhs: unknown; index: number }> = []
    forEachEquation(R1, (eq, index) => eqs.push({ lhs: eq.lhs, rhs: eq.rhs, index }))
    expect(eqs).toEqual([{ lhs: 'A', rhs: 'B', index: 0 }])
  })

  it('yields nothing for a reaction system without constraint equations', () => {
    const RSub = R1.subsystems!.RSub as ReactionSystem
    const seen: number[] = []
    forEachEquation(RSub, (_eq, i) => seen.push(i))
    expect(seen).toEqual([])
  })
})
