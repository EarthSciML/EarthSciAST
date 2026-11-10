/**
 * Brownian (SDE) support — see tests/fixtures/sde/*.
 *
 * From esm 1.0.0 there is no `brownian` variable TYPE. A noise source is a
 * PARAMETER carrying a `distribution` plus `update: {kind: "wiener"}`: the
 * distribution is what gets resampled, every step, with √dt increment scaling.
 * Whether a parameter is Brownian is therefore DERIVED (`brownianParameters`,
 * esm-spec §6.3.1), and correlated noise is one vector-valued parameter whose
 * distribution carries a `cov` matrix rather than the opaque `correlation_group`
 * tag the 0.x schema used and never supplied a matrix for.
 */
import { describe, it, expect } from 'vitest'
import { loadString } from './parse.js'
import { toJson } from './serialize.js'
import { flatten } from './flatten.js'
import { brownianParameters, parameterClass, systemKind } from './classification.js'
import { readFixture } from './test-helpers.js'
import type { Model } from './types.js'

describe('Brownian (SDE) support', () => {
  it('round-trips the Ornstein–Uhlenbeck fixture preserving the wiener parameter', () => {
    const fixture = readFixture('fixtures', 'sde', 'ornstein_uhlenbeck.esm')
    const parsed = loadString(fixture)
    const model = parsed.models!.OU as Model
    const bw = model.variables.Bw

    // Declared as a plain parameter; its Brownian-ness is derived.
    expect(bw.type).toBe('parameter')
    expect(bw.distribution).toEqual({ kind: 'normal', mean: 0.0, std: 1.0 })
    expect(bw.update).toEqual({ kind: 'wiener' })
    expect(parameterClass(bw)).toBe('brownian')
    expect(brownianParameters(model)).toEqual(['Bw'])

    // One wiener parameter is what makes the enclosing model an SDE.
    expect(systemKind(model)).toBe('sde')

    const out = toJson(parsed)
    const reparsed = loadString(out)
    expect((reparsed.models!.OU as Model).variables.Bw).toEqual(bw)
  })

  it('does not mistake the other parameters for noise sources', () => {
    const fixture = readFixture('fixtures', 'sde', 'ornstein_uhlenbeck.esm')
    const model = loadString(fixture).models!.OU as Model

    // `sigma` carries the noise AMPLITUDE and is an ordinary constant; only the
    // parameter with the `wiener` update is Brownian.
    expect(parameterClass(model.variables.sigma)).toBe('constant')
    expect(parameterClass(model.variables.theta)).toBe('constant')
  })

  it('flatten surfaces brownian parameters as a SUBSET of the parameters', () => {
    const fixture = readFixture('fixtures', 'sde', 'correlated_noise.esm')
    const parsed = loadString(fixture)
    const flat = flatten(parsed)
    // esm-spec §6.3.1: the four parameter sets PARTITION the parameters, so the
    // wiener entry is in BOTH maps. `brownianParameters` was `brownianVariables`
    // before 1.0.0, and it EXCLUDED the entry from `parameters` — which made the
    // parameter vector's length depend on whether the model was stochastic.
    expect(Object.keys(flat.brownianParameters)).toEqual(['TwoBody.B'])
    expect(Object.keys(flat.parameters)).toContain('TwoBody.B')
    // Carrying the bucket is exactly what lets the flattened form report "sde".
    expect(flat.systemKind).toBe('sde')
  })

  it('schema rejects a wiener update on an UNKNOWN', () => {
    // `distribution` and `update` are parameter-only: an unknown's behaviour is
    // stated by the equations and nowhere else.
    const bad = JSON.stringify({
      esm: '1.0.0',
      metadata: { name: 'Bad' },
      models: {
        M: {
          variables: {
            x: {
              type: 'unknown',
              units: '1',
              distribution: { kind: 'normal', mean: 0.0, std: 1.0 },
              update: { kind: 'wiener' },
            },
          },
          equations: [],
        },
      },
    })
    expect(() => loadString(bad)).toThrow()
  })

  it('schema rejects a wiener update with no distribution to resample', () => {
    const bad = JSON.stringify({
      esm: '1.0.0',
      metadata: { name: 'Bad' },
      models: {
        M: {
          variables: {
            x: { type: 'unknown', units: '1' },
            w: { type: 'parameter', units: '1/s^0.5', update: { kind: 'wiener' } },
          },
          equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 'w' }],
        },
      },
    })
    expect(() => loadString(bad)).toThrow()
  })
})
