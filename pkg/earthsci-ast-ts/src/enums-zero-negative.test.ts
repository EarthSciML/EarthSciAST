/**
 * An `enums` member may be ANY integer — negative, zero or positive
 * (esm-spec §9.3, CONFORMANCE_SPEC §5.26).
 *
 * The schema used to carry `minimum: 1` on
 * `EnumDeclaration.additionalProperties`, so a zero-valued identifier could not
 * be named at all. MOVES has load-bearing ones: `operatingmode.opModeID = 0` is
 * Braking — an emitting mode with its own rate, not an absence — and
 * `opmodepolprocassoc.polProcessID = -1` marks the drive-cycle modes associated
 * with no pollutant/process.
 *
 * Both halves are pinned here: the document LOADS (schema + parse), and each
 * member resolves to EXACTLY its declared integer through the evaluator. A
 * binding that accepted the document but clamped or dropped the sign would
 * still be wrong, which is why the arithmetic case is here and not just the
 * two bare constants.
 */
import { describe, it, expect } from 'vitest'
import { loadString } from './parse.js'
import { validateText } from './validate.js'
import { evaluateExpression } from './codegen.js'
import { readFixture } from './test-helpers.js'

interface OpNode {
  op: string
  value?: number
  values?: OpNode[]
}

function fixtureFile() {
  return loadString(readFixture('valid', 'enums_zero_and_negative.esm')) as unknown as {
    enums: Record<string, Record<string, number>>
    models: Record<string, { equations: { lhs: unknown; rhs: OpNode }[] }>
  }
}

describe('enums: the member domain is the whole integer range (§9.3)', () => {
  it('a zero-valued and a negative-valued member are schema-valid', () => {
    const result = validateText(readFixture('valid', 'enums_zero_and_negative.esm'))
    expect(result.schema_errors).toEqual([])
    expect(result.is_valid).toBe(true)
  })

  it('the declared integers survive load unchanged', () => {
    const f = fixtureFile()
    expect(f.enums.operating_mode.Braking).toBe(0)
    expect(f.enums.pol_process.Unassociated).toBe(-1)
  })

  it('lowering resolves them to `const 0` and `const -1`, and arithmetic keeps the sign', () => {
    const f = fixtureFile()
    const rhs = f.models.EnumsZeroAndNegative.equations[0].rhs
    expect(rhs.op).toBe('makearray')
    const values = rhs.values as OpNode[]

    expect(values[0].op).toBe('const')
    expect(values[0].value).toBe(0)
    expect(values[1].op).toBe('const')
    expect(values[1].value).toBe(-1)

    // Evaluated, not merely inspected: 0, -1, and 0 + 10*1 + (-1) = 9.
    expect(evaluateExpression(values[0] as never, new Map())).toBe(0)
    expect(evaluateExpression(values[1] as never, new Map())).toBe(-1)
    expect(evaluateExpression(values[2] as never, new Map())).toBe(9)
  })
})
