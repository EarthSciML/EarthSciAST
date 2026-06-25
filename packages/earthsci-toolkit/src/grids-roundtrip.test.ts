/**
 * Round-trip tests for the §6 grids top-level schema (gt-5kq3).
 *
 * Loads each of the canonical grid fixtures (cartesian, unstructured),
 * serializes via save(), reloads, and asserts the `grids`
 * subtree survives the round-trip byte-equivalently at the JSON level. Also
 * exercises the negative case: a `kind='loader'` generator whose loader name
 * is absent from the top-level `data_loaders` map must throw
 * E_UNKNOWN_LOADER.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'fs'
import { join } from 'path'
import { load, save, GridValidationError } from './index.js'

const gridsDir = join(__dirname, '../../../tests/grids')

function roundTrip(fixtureFile: string): { before: unknown; after: unknown } {
  const raw = readFileSync(join(gridsDir, fixtureFile), 'utf-8')
  const loaded = load(raw)
  const serialized = save(loaded)
  const reloaded = load(serialized)
  const original = JSON.parse(raw)
  return {
    before: (original as { grids?: unknown }).grids,
    after: (reloaded as unknown as { grids?: unknown }).grids,
  }
}

describe('§6 grids top-level schema — round-trip', () => {
  it('preserves the cartesian family (uniform + nonuniform z, rank-1 loader)', () => {
    const { before, after } = roundTrip('cartesian_uniform.esm')
    expect(after).toBeDefined()
    expect(after).toEqual(before)
  })

  it('preserves the unstructured family (MPAS-style loader-backed connectivity)', () => {
    const { before, after } = roundTrip('unstructured_mpas.esm')
    expect(after).toBeDefined()
    expect(after).toEqual(before)
  })

  it('preserves a projected native grid (lambert_conformal crs, WRF params)', () => {
    const { before, after } = roundTrip('lambert_conformal.esm')
    expect(after).toBeDefined()
    expect(after).toEqual(before)
  })
})

describe('§6 grids generator validation', () => {
  it('throws E_UNKNOWN_LOADER when a metric_arrays generator references a missing loader', () => {
    // Build a minimal v0.2.0 ESM file whose grid references a loader that
    // isn't declared in top-level data_loaders.
    const bad = {
      esm: '0.2.0',
      metadata: { name: 'BadLoaderRef' },
      models: {
        M: {
          reference: { notes: 'placeholder' },
          variables: { T: { type: 'state', units: 'K', default: 273.15 } },
          equations: [{ lhs: 'D(T)', rhs: '0' }],
        },
      },
      grids: {
        g: {
          family: 'cartesian',
          dimensions: ['x'],
          extents: { x: { n: 'Nx', spacing: 'nonuniform' } },
          metric_arrays: {
            dx: {
              rank: 1,
              dim: 'x',
              generator: { kind: 'loader', loader: 'does_not_exist', field: 'dx' },
            },
          },
        },
      },
    }

    expect(() => load(JSON.stringify(bad))).toThrow(GridValidationError)
    try {
      load(JSON.stringify(bad))
    } catch (e) {
      expect(e).toBeInstanceOf(GridValidationError)
      expect((e as GridValidationError).code).toBe('E_UNKNOWN_LOADER')
    }
  })
})
