import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { canonicalJson } from './canonicalize.js'
import { losslessJsonParse } from './numeric-literal.js'

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)
// pkg/earthsci-ast-ts/src/ -> repo root is 3 levels up.
const REPO_ROOT = resolve(__dirname, '..', '..', '..')
const FIXTURES_DIR = resolve(REPO_ROOT, 'tests', 'conformance', 'canonical')

interface ManifestEntry {
  id: string
  path: string
  ts_skip?: string
}

interface Manifest {
  fixtures: ManifestEntry[]
}

const manifest: Manifest = JSON.parse(readFileSync(resolve(FIXTURES_DIR, 'manifest.json'), 'utf-8'))

describe('canonical-form cross-binding conformance', () => {
  for (const entry of manifest.fixtures) {
    // Parse the fixture lossly so JSON-integer tokens (e.g. `1`) become
    // tagged `intLit` leaves and JSON-float tokens (`1.0`, `5e-324`) become
    // `floatLit` leaves. Preserves the RFC §5.4.1 distinction that the
    // binding's canonical form depends on.
    const raw = losslessJsonParse(
      readFileSync(resolve(FIXTURES_DIR, entry.path), 'utf-8'),
    ) as Record<string, unknown>
    const expected = raw.expected as string
    const input = raw.input
    const test = entry.ts_skip ? it.skip : it
    test(`${entry.id}${entry.ts_skip ? ' (TS skip: ' + entry.ts_skip + ')' : ''}`, () => {
      const got = canonicalJson(input as never)
      expect(got).toBe(expected)
    })
  }
})
