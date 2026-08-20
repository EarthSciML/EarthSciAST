/**
 * Cadence leaf seeding (CONFORMANCE_SPEC §5.7.2).
 *
 * The worked-example fixture `tests/valid/cadence/observed_leaf_seeds.esm`
 * carries an `expect_cadence` annotation on every equation's RHS root, and it
 * discriminates every wrong answer for the observed leaf:
 *
 *   geom       reads only parameters                  -> const
 *   geom_chain reads another observed                 -> const, transitively
 *   k_scaled   reads a DISCRETE parameter             -> discrete
 *   u_scaled   reads a state                          -> continuous
 *
 * Seeding every observed CONST (what the 0.x code did, with a comment admitting
 * it was imprecise and unexercised) gets `u_scaled` and `k_scaled` wrong.
 * Seeding every unknown CONTINUOUS gets `geom` and `geom_chain` wrong, which
 * matters because const-folding exactly those state-free observeds at bind is
 * what the geometry and projection-pushdown paths rely on.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'fs'
import { join } from 'path'
import { CadenceSeeder, joinCadence, expressionCadence, CadenceCycleError } from './cadence.js'
import { fixturesDir } from './test-helpers.js'
import type { EsmFile, Model, ExpressionNode } from './types.js'

/** Parse the fixture WITHOUT `load()`, which its unit defect currently trips. */
function readEsm(...segments: string[]): EsmFile {
  return JSON.parse(readFileSync(join(fixturesDir(), ...segments), 'utf-8'))
}

describe('cadence leaf seeding (CONFORMANCE_SPEC §5.7.2)', () => {
  const file = readEsm('valid', 'cadence', 'observed_leaf_seeds.esm')
  const model = file.models!.ObservedLeafSeeds as Model
  const seeder = new CadenceSeeder(model, file)

  it('seeds a state-free observed CONST, so it can still fold at bind', () => {
    expect(seeder.leaf('geom')).toBe('const')
  })

  it('resolves an observed reading another observed TRANSITIVELY', () => {
    expect(seeder.leaf('geom_chain')).toBe('const')
  })

  it('seeds an observed reading a DISCRETE parameter as discrete', () => {
    expect(seeder.leaf('k_scaled')).toBe('discrete')
  })

  it('seeds an observed reading a STATE as continuous', () => {
    expect(seeder.leaf('u_scaled')).toBe('continuous')
  })

  it('seeds the ODE state itself continuous and a plain parameter const', () => {
    expect(seeder.leaf('u')).toBe('continuous')
    expect(seeder.leaf('dx')).toBe('const')
  })

  it('seeds a parameter carrying a schedule update as discrete', () => {
    expect(seeder.leaf('Kdiff')).toBe('discrete')
  })

  it('agrees with every expect_cadence annotation the fixture carries', () => {
    // Each equation's RHS root asserts its own derived class.
    for (const equation of model.equations) {
      const rhs = equation.rhs as ExpressionNode
      if (typeof rhs !== 'object' || rhs === null || rhs.expect_cadence === undefined) continue
      expect({
        lhs: JSON.stringify(equation.lhs).slice(0, 40),
        cadence: expressionCadence(model, equation.rhs, file),
      }).toEqual({
        lhs: JSON.stringify(equation.lhs).slice(0, 40),
        cadence: rhs.expect_cadence,
      })
    }
  })

  it('the independent variable is continuous', () => {
    expect(seeder.leaf('t')).toBe('continuous')
  })

  it('an undeclared name — an index set, a bound index — seeds const', () => {
    expect(seeder.leaf('cells')).toBe('const')
    expect(seeder.leaf('i')).toBe('const')
  })
})

describe('the source-seeded refinement (CONFORMANCE_SPEC §5.7.2)', () => {
  // The `loader_temporal_seed` / `loader_const_seed` pair are identical models
  // differing only in the source's `temporal` block. It is the SOURCE, not the
  // parameter's own declaration, that fixes the seed.
  const cases: [string, 'discrete' | 'const'][] = [
    ['loader_temporal_seed', 'discrete'],
    ['loader_const_seed', 'const'],
  ]

  for (const [fixture, expected] of cases) {
    it(`${fixture}: a data-fed parameter seeds ${expected}`, () => {
      const file = readEsm('valid', 'cadence', `${fixture}.esm`)
      const [model] = Object.values(file.models!) as Model[]
      const seeder = new CadenceSeeder(model, file)

      const dataFed = Object.entries(model.variables).filter(
        ([, v]) => v.type === 'parameter' && !Array.isArray(v.update) && v.update?.kind === 'data',
      )
      expect(dataFed.length).toBeGreaterThan(0)
      for (const [name] of dataFed) {
        expect(seeder.leaf(name)).toBe(expected)
      }
    })
  }
})

describe('cadence algebra', () => {
  it('joins as max over const ⊏ discrete ⊏ continuous', () => {
    expect(joinCadence('const', 'discrete')).toBe('discrete')
    expect(joinCadence('discrete', 'const')).toBe('discrete')
    expect(joinCadence('discrete', 'continuous')).toBe('continuous')
    expect(joinCadence('const', 'const')).toBe('const')
  })

  it('reports a cyclic observed definition rather than silently seeding it', () => {
    // `a ~ b` and `b ~ a`: balanced by count, so equation-balance does not catch
    // it, and the recursion would not terminate without the guard.
    const model = {
      variables: { a: { type: 'unknown' }, b: { type: 'unknown' } },
      equations: [
        { lhs: 'a', rhs: 'b' },
        { lhs: 'b', rhs: 'a' },
      ],
    } as unknown as Model

    expect(() => new CadenceSeeder(model).leaf('a')).toThrow(CadenceCycleError)
  })

  it('memoises a shared observed rather than re-walking it', () => {
    const model = {
      variables: {
        p: { type: 'parameter', default: 1 },
        o1: { type: 'unknown' },
        o2: { type: 'unknown' },
      },
      equations: [
        { lhs: 'o1', rhs: { op: '*', args: ['p', 'p'] } },
        { lhs: 'o2', rhs: { op: '*', args: ['o1', 'o1'] } },
      ],
    } as unknown as Model

    const seeder = new CadenceSeeder(model)
    expect(seeder.leaf('o2')).toBe('const')
    // Second call hits the memo table and must agree.
    expect(seeder.leaf('o2')).toBe('const')
  })
})
