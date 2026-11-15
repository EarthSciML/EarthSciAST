import { describe, expect, it } from 'vitest'
import { canonicalizeDocument } from './canonicalize.js'
import { isIntLit, isNumericLiteral, losslessJsonParse } from './numeric-literal.js'
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
