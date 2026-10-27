/**
 * esm-spec §9.5.5 load-time table checks and their pinned order, driven from
 * the cross-binding ledger `tests/conformance/function_tables/load_errors/cases.json`.
 *
 * Each case is one table (id `T`) and one `table_lookup` node. The table is
 * built IN MEMORY — the strings `"NaN"`, `"Inf"` and `"-Inf"` anywhere in it
 * become the binary64 values JSON cannot carry, and several cases also hold an
 * axis the schema would reject. Each case runs through BOTH places this binding
 * checks a table: the load-time check `load` and `validate()` run on every
 * `function_tables` entry (`checkFunctionTablesAndClosedFunctionCalls`, ruling
 * Q-106), and the §9.5.3 lowering of the lookup (`lowerTableLookups`, which
 * re-checks the table it names, then the lookup's own fields). The cases a
 * document can carry live in `tests/invalid/function_table_*.esm` instead
 * (`load-function-checks.test.ts`). No case is skipped: a
 * JavaScript `number` holds NaN and ±Infinity.
 */
import { describe, it, expect } from 'vitest'
import { ERROR_CODES } from './errors.js'
import {
  lowerTableLookups,
  TableLookupLoweringError,
  type FunctionTables,
} from './lower-table-lookups.js'
import { checkFunctionTablesAndClosedFunctionCalls } from './load-function-checks.js'
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

/** The non-finite numbers the ledger spells as strings. */
const NON_FINITE: { [spelling: string]: number | undefined } = {
  NaN: Number.NaN,
  Inf: Number.POSITIVE_INFINITY,
  '-Inf': Number.NEGATIVE_INFINITY,
}

/** A deep copy of `value` with every `"NaN"` / `"Inf"` / `"-Inf"` string decoded. */
function decodeNonFinite(value: unknown): unknown {
  if (typeof value === 'string' && NON_FINITE[value] !== undefined) return NON_FINITE[value]
  if (Array.isArray(value)) return value.map(decodeNonFinite)
  if (typeof value === 'object' && value !== null) {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, decodeNonFinite(v)]))
  }
  return value
}

function tablesOf(c: LoadErrorCase): FunctionTables {
  return { [ledger.table_id]: decodeNonFinite(c.table) } as FunctionTables
}

/** The §9.5.5 code the load-time table check raises, or `null` when it passes. */
function loadCheckCode(c: LoadErrorCase): string | null {
  try {
    checkFunctionTablesAndClosedFunctionCalls({ function_tables: tablesOf(c) })
    return null
  } catch (e) {
    if (e instanceof TableLookupLoweringError) return e.code
    throw e
  }
}

/** The code the lowering of the case's lookup raises, or `null` when it lowers. */
function loweringCode(c: LoadErrorCase): string | null {
  try {
    lowerTableLookups(decodeNonFinite(c.lookup) as Expr, tablesOf(c))
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
    // The ledger and the `tests/invalid/function_table_*.esm` documents its
    // schema-valid cases moved to cover the order between them.
    const pins = JSON.parse(readFixture('invalid', 'expected_errors.json')) as Record<
      string,
      { resolver_error_code?: string }
    >
    const expected = new Set<string | null>(ledger.cases.map((c) => c.expected_error_code))
    for (const [name, pin] of Object.entries(pins)) {
      if (name.startsWith('function_table_') && pin.resolver_error_code !== undefined) {
        expected.add(pin.resolver_error_code)
      }
    }
    for (const step of ledger.order) {
      const code = step.split(' ')[0]
      expect(registered.has(code), `${code} is not in ERROR_CODES`).toBe(true)
      expect(expected.has(code), `no case expects ${code}`).toBe(true)
    }
  })

  for (const c of ledger.cases) {
    it(`${c.name} → ${c.expected_error_code ?? 'loads and lowers'}`, () => {
      expect(loadCheckCode(c), 'load-time table check').toBe(c.expected_error_code)
      expect(loweringCode(c), 'lowering').toBe(c.expected_error_code)
    })
  }
})
