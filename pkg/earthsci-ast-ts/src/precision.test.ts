/**
 * esm-spec §11.3.3 P8: validation warns, on its non-unit `warnings` channel,
 * about an unspecified variable used directly as an equality or join key.
 * Fixtures shared with the other four bindings
 * (`tests/conformance/precision_source/`).
 */

import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { loadString } from './parse.js'
import { validate } from './validate.js'

const here = path.dirname(fileURLToPath(import.meta.url))
const dir = path.resolve(here, '../../../tests/conformance/precision_source')
const expected = JSON.parse(readFileSync(path.join(dir, 'expected.json'), 'utf8')) as {
  legacy_version: string
  warnings: Record<string, { code: string; path: string }[]>
}

const pairs = (ws: { code: string; path: string }[]): string[] =>
  ws.map((w) => `${w.code} ${w.path}`).sort()

describe('key_precision_unspecified (esm-spec §11.3.3 P8)', () => {
  for (const [fixture, want] of Object.entries(expected.warnings)) {
    const text = readFileSync(path.join(dir, fixture), 'utf8')
    it(`${fixture}: warns on the non-unit channel`, () => {
      const result = validate(loadString(text))
      expect(result.is_valid).toBe(true)
      expect(pairs(result.warnings)).toEqual(pairs(want))
      const codes = new Set(want.map((w) => w.code))
      expect(result.unit_warnings.filter((w) => codes.has(w.code))).toEqual([])
    })
    it(`${fixture}: a root below the gate declares binary64 and draws no warning`, () => {
      const doc = JSON.parse(text) as Record<string, unknown>
      doc.esm = expected.legacy_version
      expect(validate(loadString(JSON.stringify(doc))).warnings).toEqual([])
    })
  }
})
