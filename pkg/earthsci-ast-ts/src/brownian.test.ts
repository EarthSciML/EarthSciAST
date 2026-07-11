/**
 * Brownian (SDE) round-trip tests — see tests/fixtures/sde/*.
 */
import { describe, it, expect } from 'vitest'
import { load } from './parse.js'
import { save } from './serialize.js'
import { flatten } from './flatten.js'
import { readFixture } from './test-helpers.js'
import type { Model } from './types.js'

describe('Brownian (SDE) support', () => {
  it('round-trips the Ornstein–Uhlenbeck fixture preserving brownian fields', () => {
    const fixture = readFixture('fixtures', 'sde', 'ornstein_uhlenbeck.esm')
    const parsed = load(fixture)
    const bw = (parsed.models!.OU as Model).variables.Bw
    expect(bw.type).toBe('brownian')
    expect((bw as any).noise_kind).toBe('wiener')

    const out = save(parsed)
    const reparsed = load(out)
    expect((reparsed.models!.OU as Model).variables.Bw).toEqual(bw)
  })

  it('flatten surfaces brownian variables in a dedicated collection', () => {
    const fixture = readFixture('fixtures', 'sde', 'correlated_noise.esm')
    const parsed = load(fixture)
    const flat = flatten(parsed)
    expect(flat.brownianVariables.sort()).toEqual(['TwoBody.Bx', 'TwoBody.By'])
  })

  it('schema rejects noise_kind on a non-brownian variable', () => {
    const bad = JSON.stringify({
      esm: '0.1.0',
      metadata: { name: 'Bad' },
      models: {
        M: {
          variables: { x: { type: 'state', noise_kind: 'wiener' } },
          equations: [],
        },
      },
    })
    expect(() => load(bad)).toThrow()
  })
})
