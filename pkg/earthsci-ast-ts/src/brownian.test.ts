/**
 * Brownian (SDE) round-trip tests — see tests/fixtures/sde/*.
 */
import { describe, it, expect } from 'vitest'
import * as fs from 'fs'
import * as path from 'path'
import { load } from './parse.js'
import { save } from './serialize.js'
import { flatten } from './flatten.js'
import type { Model } from './types.js'

const REPO_ROOT = path.join(__dirname, '..', '..', '..')

describe('Brownian (SDE) support', () => {
  it('round-trips the Ornstein–Uhlenbeck fixture preserving brownian fields', () => {
    const fixture = fs.readFileSync(
      path.join(REPO_ROOT, 'tests', 'fixtures', 'sde', 'ornstein_uhlenbeck.esm'),
      'utf-8',
    )
    const parsed = load(fixture)
    const bw = (parsed.models!.OU as Model).variables.Bw
    expect(bw.type).toBe('brownian')
    expect((bw as any).noise_kind).toBe('wiener')

    const out = save(parsed)
    const reparsed = load(out)
    expect((reparsed.models!.OU as Model).variables.Bw).toEqual(bw)
  })

  it('flatten surfaces brownian variables in a dedicated collection', () => {
    const fixture = fs.readFileSync(
      path.join(REPO_ROOT, 'tests', 'fixtures', 'sde', 'correlated_noise.esm'),
      'utf-8',
    )
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
