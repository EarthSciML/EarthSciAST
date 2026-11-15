import { describe, expect, it } from 'vitest'
import { canonicalizeDocument } from './canonicalize.js'
import { printMarkdown } from './document/index.js'
import {
  exactInteger,
  isFloatLit,
  isIntLit,
  isNumericLiteral,
  losslessJsonParse,
  losslessJsonStringify,
  type NumericLiteral,
} from './numeric-literal.js'
import { readFixture } from './test-helpers.js'

const read = (name: string): Record<string, unknown> =>
  JSON.parse(readFixture('conformance', 'canonical_document', name)) as Record<string, unknown>

const manifest = read('manifest.json') as { fixtures: Array<{ id: string; path: string }> }

// tests/conformance/canonical_document: canonicalizeDocument(input) equals the
// expected document as a JSON value, in every binding (esm-spec §4.8.2).
describe('document-level canonical form', () => {
  for (const entry of manifest.fixtures) {
    it(entry.id, () => {
      const fixture = read(entry.path)
      const before = structuredClone(fixture.input)
      expect(canonicalizeDocument(fixture.input)).toEqual(fixture.expected)
      expect(fixture.input).toEqual(before)
    })
  }
})

/**
 * A number leaf as its kind and value, so `2` and `2.0` differ. An integer
 * token past 2^53 reads as a float literal (`losslessJsonParse` keeps no
 * precision it cannot hold), so an `expected` float whose value is integral and
 * in Int64 is an int: the expected documents are in canonical form.
 */
const INT64_BOUND = 2 ** 63
function typed(value: unknown, expected: boolean): unknown {
  if (isNumericLiteral(value)) {
    const v = value.value
    const int =
      isIntLit(value) || (expected && Number.isInteger(v) && v >= -INT64_BOUND && v < INT64_BOUND)
    return { [int ? 'int' : 'float']: v }
  }
  if (typeof value === 'number') return { plain: value }
  if (Array.isArray(value)) return value.map((v) => typed(v, expected))
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, typed(v, expected)]))
  }
  return value
}

// The same fixtures read with every number tagged int or float by its token:
// the numbers compare by kind too.
describe('document-level canonical form, numbers by kind', () => {
  for (const entry of manifest.fixtures) {
    it(entry.id, () => {
      const fixture = losslessJsonParse(
        readFixture('conformance', 'canonical_document', entry.path),
      ) as Record<string, unknown>
      const got = canonicalizeDocument(fixture.input)
      expect(typed(got, false)).toEqual(typed(fixture.expected, true))
    })
  }
})

describe('canonicalizeDocument integers past 2^53', () => {
  // As a binary64, 9223372036854775807 (Int64 max) and 9223372036854775808 are
  // both 2^63; the integer written decides which is in Int64, as in the other
  // bindings.
  const text =
    '{"max": 9223372036854775807, "past": 9223372036854775808, "min": -9223372036854775808}'
  const out = canonicalizeDocument(losslessJsonParse(text)) as Record<string, NumericLiteral>

  it('keeps Int64 max an integer and makes 2^63 a float', () => {
    expect(isIntLit(out.max)).toBe(true)
    expect(exactInteger(out.max)).toBe(9223372036854775807n)
    expect(isFloatLit(out.past)).toBe(true)
    expect(isIntLit(out.min)).toBe(true)
    expect(out.min.value).toBe(-(2 ** 63))
  })

  it('writes the integer as it was written', () => {
    expect(losslessJsonStringify(out)).toBe(
      '{"max":9223372036854775807,"past":9223372036854776000.0,"min":-9223372036854775808}',
    )
    const md = printMarkdown({
      esm: '2.3.0',
      metadata: { name: 'm' },
      models: {
        M: {
          variables: {
            k: { type: 'parameter', default: losslessJsonParse('9223372036854775807') },
          },
          equations: [],
        },
      },
    })
    expect(md).toContain('default=9223372036854775807')
  })
})

describe('canonicalizeDocument keys', () => {
  it('keeps a key named __proto__ as an own property', () => {
    const doc = JSON.parse(
      '{"variables": {"__proto__": {"units": "s*m"}, "x": {"units": "1/s"}}}',
    ) as Record<string, unknown>
    const out = canonicalizeDocument(doc) as { variables: Record<string, unknown> }
    expect(Object.getPrototypeOf(out.variables)).toBe(Object.prototype)
    expect(Object.keys(out.variables)).toEqual(['__proto__', 'x'])
    expect(Object.getOwnPropertyDescriptor(out.variables, '__proto__')?.value).toEqual({
      units: 'm*s',
    })
  })
})
