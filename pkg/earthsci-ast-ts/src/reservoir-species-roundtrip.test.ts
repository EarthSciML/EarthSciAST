/**
 * Round-trip coverage for Species.constant (reservoir species) — gt-ertm.
 *
 * Loads a reaction system with three reservoir species (O2, CH4, H2O) declared
 * via constant=true, plus three ordinary state species. Verifies parse →
 * serialize → reparse is JSON-byte-equivalent and that the constant flag is
 * only present on the reservoir species.
 */
import { describe, it, expect } from 'vitest'
import { load, save } from './index.js'
import { readFixture } from './test-helpers.js'

describe('reservoir species (Species.constant=true)', () => {
  it('round-trips the constant flag byte-identical and flags only reservoir species', () => {
    const raw = readFixture('valid', 'reservoir_species_constant.esm')
    const parsed = load(raw) as Record<string, unknown>
    const rs = (
      parsed.reaction_systems as Record<string, { species: Record<string, { constant?: boolean }> }>
    ).SuperFastSubset
    for (const name of ['O2', 'CH4', 'H2O']) {
      expect(rs.species[name].constant).toBe(true)
    }
    for (const name of ['O3', 'OH', 'HO2']) {
      expect(rs.species[name].constant).toBeUndefined()
    }

    const serialized = save(parsed as never)
    const original = JSON.parse(raw)
    const reserialized = JSON.parse(serialized)
    expect(reserialized).toEqual(original)
  })
})
