/**
 * esm-spec §9.5.5 load-time table checks and their pinned order, driven from
 * the cross-binding ledger `tests/conformance/function_tables/load_errors/cases.json`.
 *
 * Each case is one table (id `T`) and one `table_lookup` node. The table is
 * built IN MEMORY — the string `"NaN"` anywhere in it becomes a binary64 NaN,
 * which JSON cannot carry, and several cases also hold an axis the schema would
 * reject — and the lookup goes through this binding's real §9.5.3 lowering
 * (`lowerTableLookups`), whose first step is `validateFunctionTable`. No case
 * is skipped: a JavaScript `number` holds a NaN.
 */
import { describe, it, expect } from 'vitest'
import { ERROR_CODES } from './errors.js'
import {
  lowerTableLookups,
  TableLookupLoweringError,
  type FunctionTables,
} from './lower-table-lookups.js'
import { readFixture } from './test-helpers.js'
import type { Expr } from './types.js'

interface LoadErrorCase {
  name: string
  breaks: string[]
  table: unknown
  lookup: unknown
  expected_error_code: string | null
}

interface Ledger {
  table_id: string
  order: string[]
  cases: LoadErrorCase[]
}

const ledger: Ledger = JSON.parse(
  readFixture('conformance', 'function_tables', 'load_errors', 'cases.json'),
)

/** A deep copy of `value` with every string `"NaN"` replaced by a binary64 NaN. */
function withNaN(value: unknown): unknown {
  if (value === 'NaN') return Number.NaN
  if (Array.isArray(value)) return value.map(withNaN)
  if (typeof value === 'object' && value !== null) {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, withNaN(v)]))
  }
  return value
}

/** The §9.5.5 code the lowering raises, or `null` when it lowers. */
function loweringCode(c: LoadErrorCase): string | null {
  const tables = { [ledger.table_id]: withNaN(c.table) } as FunctionTables
  try {
    lowerTableLookups(withNaN(c.lookup) as Expr, tables)
    return null
  } catch (e) {
    if (e instanceof TableLookupLoweringError) return e.code
    throw e
  }
}

const registered = new Set<string>(Object.values(ERROR_CODES))

describe('function_tables load_errors ledger (esm-spec §9.5.5 order of the table checks)', () => {
  it('carries cases, and a valid control', () => {
    expect(ledger.cases.length).toBeGreaterThan(0)
    expect(ledger.cases.some((c) => c.expected_error_code === null)).toBe(true)
  })

  it('names only codes this binding registers, and covers every step of the order', () => {
    const expected = new Set(ledger.cases.map((c) => c.expected_error_code))
    for (const step of ledger.order) {
      const code = step.split(' ')[0]
      expect(registered.has(code), `${code} is not in ERROR_CODES`).toBe(true)
      expect(expected.has(code), `no case expects ${code}`).toBe(true)
    }
  })

  for (const c of ledger.cases) {
    it(`${c.name} → ${c.expected_error_code ?? 'lowers'}`, () => {
      expect(loweringCode(c)).toBe(c.expected_error_code)
    })
  }
})
