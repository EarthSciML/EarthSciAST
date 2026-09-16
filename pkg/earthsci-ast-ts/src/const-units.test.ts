/**
 * Declared units on a `const` node (esm-spec §4.8.5): a `const` that declares its
 * units has that unit, a `const` without units stays undeterminable, and the
 * field is gated at esm 1.2.0.
 */
import { describe, it, expect } from 'vitest'
import { parseUnitForConversion } from './unit-conversion.js'
import type { ParsedUnit } from './unit-conversion.js'
import { checkDimensions } from './units.js'
import { rejectConstUnitsPreV12 } from './solver.js'
import type { Expression } from './types.js'

const bindings = (units: Record<string, string>): Map<string, ParsedUnit> =>
  new Map(Object.entries(units).map(([name, u]) => [name, parseUnitForConversion(u)]))

const konst = (units?: string): Expression =>
  ({
    op: 'const',
    args: [],
    value: 0.44704,
    ...(units === undefined ? {} : { units }),
  }) as unknown as Expression

describe('declared units on a const node', () => {
  it('gives a const with declared units that unit', () => {
    const env = bindings({ speed_mph: 'mi/h' })
    const got = checkDimensions(
      { op: '*', args: ['speed_mph', konst('m*h/(mi*s)')] } as Expression,
      env,
    )
    const ms = parseUnitForConversion('m/s')
    expect(got.dimensions).not.toBeNull()
    expect(got.dimensions?.exact.equals(ms.exact)).toBe(true)
  })

  it('leaves a const without units undeterminable', () => {
    const env = bindings({ speed_mph: 'mi/h' })
    const got = checkDimensions({ op: '*', args: ['speed_mph', konst()] } as Expression, env)
    expect(got.dimensions).toBeNull()
  })

  it('rejects declared units in a document below esm 1.2.0, naming the node', () => {
    const doc = (esm: string) => ({
      esm,
      models: {
        M: { equations: [{ lhs: 'x', rhs: { op: 'const', args: [], value: 1, units: 'm' } }] },
      },
    })
    expect(() => rejectConstUnitsPreV12(doc('1.1.0'))).toThrow(/models\/M\/equations\/0\/rhs/)
    expect(() => rejectConstUnitsPreV12(doc('1.2.0'))).not.toThrow()
  })
})
