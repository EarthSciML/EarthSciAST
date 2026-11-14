import { describe, expect, it } from 'vitest'
import { canonicalizeDocument } from './canonicalize.js'
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
