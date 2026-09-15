/**
 * Exact unit scales and scale agreement (esm-spec §4.8.1, §4.8.3).
 *
 * A scale agreement — `m + km`, `m/s = mi/h` — is decided on an EXACT scale,
 * never on the floating-point one, and the operands of `+`, the two sides of an
 * equation and an observed variable against its declared units must agree in
 * scale as well as dimension.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { parseUnitForConversion, unitTableScales } from './unit-conversion.js'
import { checkDimensions } from './units.js'
import type { ParsedUnit } from './unit-conversion.js'
import type { Expression } from './types.js'

const TESTS = join(process.cwd(), '../../tests')

describe('exact unit scales', () => {
  it('gives every table entry an exact scale equal to its float scale', () => {
    for (const [name, scale, exact] of unitTableScales()) {
      expect(
        Math.abs(exact.toNumber() - scale) <= 1e-12 * Math.abs(scale),
        `${name}: exact ${exact.toNumber()} vs float ${scale}`,
      ).toBe(true)
    }
  })

  it('pins the reconciled entries exactly', () => {
    const exact = (s: string): string | null => parseUnitForConversion(s).exact.ratioString()
    expect(exact('Torr')).toBe('20265/152')
    expect(exact('psi')).toBe('8896443230521/1290320000')
    expect(exact('degF')).toBe('5/9')
    expect(exact('deg')).toBe('1/180*pi')
    expect(exact('mi')).toBe('201168/125')
    expect(exact('hp')).toBe('37284993579113511/50000000000000')
    expect(exact('DU')).toBe('268670000000000000000')
  })

  it('matches every scale_exact pin in tests/conformance/unit_registry', () => {
    const golden = JSON.parse(
      readFileSync(join(TESTS, 'conformance/unit_registry/golden/unit_verdicts.json'), 'utf8'),
    ) as { accept: Array<{ units: string; canonical: string; scale_exact: string }> }
    expect(golden.accept.length).toBeGreaterThan(0)
    for (const e of golden.accept) {
      const got = parseUnitForConversion(e.units)
      const want = parseUnitForConversion(e.canonical)
      expect(got.exact.divide(want.exact).ratioString(), `${e.units} -> ${e.canonical}`).toBe(
        e.scale_exact,
      )
    }
  })
})

describe('scale agreement', () => {
  const bindings = (units: Record<string, string>): Map<string, ParsedUnit> =>
    new Map(Object.entries(units).map(([name, u]) => [name, parseUnitForConversion(u)]))

  it('rejects metres plus kilometres', () => {
    const env = bindings({ x: 'm', y: 'km', z: 'm' })
    const bad = checkDimensions({ op: '+', args: ['x', 'y'] } as Expression, env)
    expect(bad.diagnostics.some((d) => d.code === 'dimensional_mismatch')).toBe(true)
    const good = checkDimensions({ op: '+', args: ['x', 'z'] } as Expression, env)
    expect(good.diagnostics.some((d) => d.code === 'dimensional_mismatch')).toBe(false)
  })

  it('carries a conversion through a quantity whose units hold it', () => {
    const env = bindings({ speed_mph: 'mi/h', ms_per_mph: 'm*h/(mi*s)' })
    const converted = checkDimensions(
      { op: '*', args: ['speed_mph', 'ms_per_mph'] } as Expression,
      env,
    )
    expect(converted.dimensions?.exact.equals(parseUnitForConversion('m/s').exact)).toBe(true)
    const bare = checkDimensions('speed_mph' as Expression, env)
    expect(bare.dimensions?.exact.equals(parseUnitForConversion('m/s').exact)).toBe(false)
  })
})
