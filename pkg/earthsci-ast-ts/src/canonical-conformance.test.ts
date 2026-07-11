import { describe, expect, it } from 'vitest'
import { canonicalJson } from './canonicalize.js'
import { losslessJsonParse } from './numeric-literal.js'
import { readFixture } from './test-helpers.js'

const canon = (...segments: string[]): string =>
  readFixture('conformance', 'canonical', ...segments)

interface ManifestEntry {
  id: string
  path: string
  ts_skip?: string
}

interface Manifest {
  fixtures: ManifestEntry[]
}

const manifest: Manifest = JSON.parse(canon('manifest.json'))

describe('canonical-form cross-binding conformance', () => {
  for (const entry of manifest.fixtures) {
    // Parse the fixture lossly so JSON-integer tokens (e.g. `1`) become
    // tagged `intLit` leaves and JSON-float tokens (`1.0`, `5e-324`) become
    // `floatLit` leaves. Preserves the RFC §5.4.1 distinction that the
    // binding's canonical form depends on.
    const raw = losslessJsonParse(canon(entry.path)) as Record<string, unknown>
    const expected = raw.expected as string
    const input = raw.input
    const test = entry.ts_skip ? it.skip : it
    test(`${entry.id}${entry.ts_skip ? ' (TS skip: ' + entry.ts_skip + ')' : ''}`, () => {
      const got = canonicalJson(input as never)
      expect(got).toBe(expected)
    })
  }
})
