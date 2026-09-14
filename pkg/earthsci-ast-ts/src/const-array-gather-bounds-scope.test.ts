/**
 * TypeScript's read of the SHARED `const_array_gather_bounds` conformance
 * manifest (CONFORMANCE_SPEC §5.39,
 * tests/conformance/const_array_gather_bounds/manifest.json).
 *
 * TypeScript cannot run that category: `index` has no scalar evaluator here and
 * there is no inline-test runner. The manifest says so in `scope_excluded`, and
 * this file keeps that claim honest the same way
 * `assertion-nonfinite-scope.test.ts` does: dropping TypeScript from
 * `scope_excluded`, or requiring it, without giving it a runner turns this red.
 */
import * as fs from 'node:fs'
import * as path from 'node:path'
import { describe, it, expect } from 'vitest'
import { loadString } from './parse.js'
import { fixturesDir } from './test-helpers.js'

interface GatherBoundsManifest {
  category: string
  bindings_required: string[]
  scope_excluded: Record<string, string>
  fixtures: Array<{ id: string; path: string; model: string; outcome: 'pass' | 'error' }>
}

const CATEGORY_DIR = fixturesDir('conformance', 'const_array_gather_bounds')

function manifest(): GatherBoundsManifest {
  return JSON.parse(
    fs.readFileSync(path.join(CATEGORY_DIR, 'manifest.json'), 'utf8'),
  ) as GatherBoundsManifest
}

describe('conformance: const_array_gather_bounds (scope)', () => {
  it('excludes TypeScript by name, with a reason', () => {
    const m = manifest()
    expect(m.category).toBe('const_array_gather_bounds')
    expect(m.bindings_required).not.toContain('typescript')
    expect(m.scope_excluded.typescript ?? '').not.toBe('')
  })

  it('carries fixtures this binding can still parse, both must-error and must-pass', () => {
    const m = manifest()
    for (const fx of m.fixtures) {
      const file = loadString(fs.readFileSync(path.join(CATEGORY_DIR, fx.path), 'utf8'))
      expect(Object.keys(file.models ?? {})).toContain(fx.model)
    }
    expect(m.fixtures.some((f) => f.outcome === 'error')).toBe(true)
    expect(m.fixtures.some((f) => f.outcome === 'pass')).toBe(true)
  })
})
