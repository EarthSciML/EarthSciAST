/**
 * The TypeScript adapter for tests/conformance/unit_registry (esm-spec
 * §4.8.1-4.8.2): one unit STRING at a time, the same golden the Julia, Python,
 * Rust and Go adapters read. The exact-scale half of `accept` is pinned in
 * unit-exact-scale.test.ts; this file adds the dimension and float-factor half,
 * and the two rejection lists.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { parseUnitForConversion } from './unit-conversion.js'

interface Entry {
  units: string
  canonical?: string
  scale_to_canonical?: number | null
  why?: string
}

const golden = JSON.parse(
  readFileSync(
    join(process.cwd(), '../../tests/conformance/unit_registry/golden/unit_verdicts.json'),
    'utf8',
  ),
) as { accept: Entry[]; reject: Entry[]; reject_scaling_factor: Entry[] }

const dimsKey = (d: Record<string, number>): string =>
  JSON.stringify(
    Object.entries(d)
      .filter(([, v]) => v !== 0)
      .sort(([a], [b]) => (a < b ? -1 : 1)),
  )

describe('unit registry golden', () => {
  it.each(golden.accept.map((e) => [e.units, e] as const))('accepts %j', (_, e) => {
    const got = parseUnitForConversion(e.units)
    const want = parseUnitForConversion(e.canonical!)
    expect(dimsKey(got.dims as Record<string, number>)).toBe(
      dimsKey(want.dims as Record<string, number>),
    )
    if (e.scale_to_canonical != null) {
      const factor = got.scale / want.scale
      expect(Math.abs(factor - e.scale_to_canonical)).toBeLessThanOrEqual(
        1e-12 * Math.abs(e.scale_to_canonical),
      )
    }
  })

  it.each(golden.reject.map((e) => [e.units, e] as const))('rejects %j', (_, e) => {
    expect(() => parseUnitForConversion(e.units), e.why).toThrow()
  })

  it.each(golden.reject_scaling_factor.map((e) => [e.units] as const))(
    'rejects %j as a scaling factor',
    (units) => {
      expect(() => parseUnitForConversion(units)).toThrow(/scaling factor/)
    },
  )
})
