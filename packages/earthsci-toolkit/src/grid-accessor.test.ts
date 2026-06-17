/**
 * Unit tests for the GridAccessor interface and registration hook
 * (gt-j2b8 — 2026-04-22 grid-inversion decision).
 *
 * ESS defines the surface; ESD ships concrete implementations. These
 * tests use stub factories to exercise the registry contract.
 */

import { afterEach, describe, expect, it } from 'vitest'
import {
  E_GRID_FAMILY_ALREADY_REGISTERED,
  E_GRID_FAMILY_NAME_INVALID,
  E_GRID_FAMILY_UNKNOWN,
  GridAccessorError,
  clearGridFamilies,
  createGrid,
  getGridFamily,
  hasGridFamily,
  listGridFamilies,
  registerGridFamily,
  unregisterGridFamily,
  type CellCenter,
  type CellIndex,
  type GridAccessor,
  type GridAccessorFactory,
} from './grid-accessor.js'

function stubFactory(family: string): GridAccessorFactory {
  return (opts) => ({
    family,
    dtype: 'float64',
    n_cells: typeof opts.n_cells === 'number' ? (opts.n_cells as number) : 0,
    cell_centers(i: number, j: number): CellCenter {
      return { x: i, y: j }
    },
    neighbors(cell: CellIndex): readonly CellIndex[] {
      return Array.isArray(cell) ? [] : []
    },
    metric_eval(_name: string, _i: number, _j: number): number {
      return 0
    },
    toESM(): object {
      return { family, dtype: 'float64', opts }
    },
  })
}

afterEach(() => {
  clearGridFamilies()
})

describe('registerGridFamily / hasGridFamily / getGridFamily', () => {
  it('registers and retrieves a factory', () => {
    const factory = stubFactory('cartesian')
    registerGridFamily('cartesian', factory)
    expect(hasGridFamily('cartesian')).toBe(true)
    expect(getGridFamily('cartesian')).toBe(factory)
  })

  it('rejects re-registration of the same family', () => {
    registerGridFamily('cartesian', stubFactory('cartesian'))
    expect(() =>
      registerGridFamily('cartesian', stubFactory('cartesian')),
    ).toThrowError(GridAccessorError)
    try {
      registerGridFamily('cartesian', stubFactory('cartesian'))
    } catch (err) {
      expect((err as GridAccessorError).code).toBe(E_GRID_FAMILY_ALREADY_REGISTERED)
    }
  })

  it('rejects empty / non-string family names', () => {
    expect(() => registerGridFamily('', stubFactory('x'))).toThrowError(GridAccessorError)
    try {
      registerGridFamily('', stubFactory('x'))
    } catch (err) {
      expect((err as GridAccessorError).code).toBe(E_GRID_FAMILY_NAME_INVALID)
    }
  })

  it('rejects a non-function factory', () => {
    expect(() =>
      registerGridFamily('cartesian', undefined as unknown as GridAccessorFactory),
    ).toThrowError(GridAccessorError)
  })

  it('hasGridFamily is false for unknown families', () => {
    expect(hasGridFamily('nope')).toBe(false)
    expect(getGridFamily('nope')).toBeUndefined()
  })
})

describe('unregisterGridFamily', () => {
  it('removes an existing registration and returns true', () => {
    registerGridFamily('cartesian', stubFactory('cartesian'))
    expect(unregisterGridFamily('cartesian')).toBe(true)
    expect(hasGridFamily('cartesian')).toBe(false)
  })

  it('returns false when the family was not registered', () => {
    expect(unregisterGridFamily('nope')).toBe(false)
  })

  it('allows re-registration after unregister (hot-reload path)', () => {
    registerGridFamily('cartesian', stubFactory('cartesian'))
    unregisterGridFamily('cartesian')
    expect(() =>
      registerGridFamily('cartesian', stubFactory('cartesian')),
    ).not.toThrow()
  })
})

describe('listGridFamilies', () => {
  it('returns families in sorted order', () => {
    registerGridFamily('lat_lon', stubFactory('lat_lon'))
    registerGridFamily('cartesian', stubFactory('cartesian'))
    expect(listGridFamilies()).toEqual(['cartesian', 'lat_lon'])
  })

  it('returns an empty array when the registry is empty', () => {
    expect(listGridFamilies()).toEqual([])
  })
})

describe('createGrid', () => {
  it('invokes the registered factory and returns a conforming accessor', () => {
    registerGridFamily('cartesian', stubFactory('cartesian'))
    const grid = createGrid('cartesian', { n_cells: 42 })
    expect(grid.family).toBe('cartesian')
    expect(grid.dtype).toBe('float64')
    expect(grid.n_cells).toBe(42)
    expect(grid.cell_centers(1, 2)).toEqual({ x: 1, y: 2 })
    expect(grid.neighbors([0, 0])).toEqual([])
    expect(grid.metric_eval('area', 0, 0)).toBe(0)
    expect(grid.toESM()).toEqual({
      family: 'cartesian',
      dtype: 'float64',
      opts: { n_cells: 42 },
    })
  })

  it('throws E_GRID_FAMILY_UNKNOWN when the family is not registered', () => {
    expect(() => createGrid('nope')).toThrowError(GridAccessorError)
    try {
      createGrid('nope')
    } catch (err) {
      expect((err as GridAccessorError).code).toBe(E_GRID_FAMILY_UNKNOWN)
    }
  })

  it('defaults opts to {} when omitted', () => {
    registerGridFamily('cartesian', stubFactory('cartesian'))
    const grid = createGrid('cartesian')
    expect(grid.n_cells).toBe(0)
  })
})

describe('GridAccessor interface shape', () => {
  it('stub factory satisfies the GridAccessor contract at the type level', () => {
    // Compile-time check: the following assignment must type-check.
    const grid: GridAccessor = stubFactory('cartesian')({ n_cells: 4 })
    expect(typeof grid.family).toBe('string')
    expect(grid.dtype === 'float64' || grid.dtype === 'float32').toBe(true)
    expect(typeof grid.n_cells).toBe('number')
    expect(typeof grid.cell_centers).toBe('function')
    expect(typeof grid.neighbors).toBe('function')
    expect(typeof grid.metric_eval).toBe('function')
    expect(typeof grid.toESM).toBe('function')
  })
})
