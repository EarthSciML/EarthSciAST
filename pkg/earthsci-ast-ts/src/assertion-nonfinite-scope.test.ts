/**
 * TypeScript's read of the SHARED `assertion_nonfinite` conformance manifest
 * (CONFORMANCE_SPEC §5.19, tests/conformance/assertion_nonfinite/manifest.json).
 *
 * TypeScript cannot run that category: the contract is the esm-spec §6.6.3 pass
 * predicate for a non-finite ACTUAL, and this binding has no simulator and no
 * assertion comparison at all — it parses a `tests` block as data and never
 * evaluates one. The manifest says so in `scope_excluded`, and this file is what
 * keeps that claim honest.
 *
 * Why a test rather than a line in a document. A shared corpus that only some
 * bindings read is a failure this suite has already had once: a rejection corpus
 * was being consumed by two of five bindings, and the three that ignored it
 * could have diverged silently for as long as nobody looked. An exclusion is the
 * same hazard one level down — invisible by construction. So all five bindings
 * read this manifest, and the two that cannot execute it assert their own
 * exclusion: if someone drops TypeScript from `scope_excluded` (or adds it to
 * `bindings_required`) without giving it a runner, this goes red instead of the
 * category quietly covering one binding fewer than it claims.
 */
import * as fs from 'node:fs'
import * as path from 'node:path'
import { describe, it, expect } from 'vitest'
import { loadString } from './parse.js'
import { fixturesDir } from './test-helpers.js'

interface NonfiniteCase {
  assertion_idx: number
  variable: string
  actual_class: '+inf' | '-inf' | 'nan' | 'finite'
  passed: boolean
}

interface NonfiniteManifest {
  category: string
  reference_binding: string
  bindings_required: string[]
  scope_excluded: Record<string, string>
  fixtures: Array<{ id: string; path: string; model: string; cases: NonfiniteCase[] }>
}

const CATEGORY_DIR = fixturesDir('conformance', 'assertion_nonfinite')

function manifest(): NonfiniteManifest {
  return JSON.parse(
    fs.readFileSync(path.join(CATEGORY_DIR, 'manifest.json'), 'utf8'),
  ) as NonfiniteManifest
}

describe('conformance: assertion_nonfinite (scope)', () => {
  it('excludes TypeScript by name, with a reason', () => {
    const m = manifest()
    expect(m.category).toBe('assertion_nonfinite')
    expect(m.reference_binding).toBe('julia')
    // Requiring TypeScript would be a claim this binding cannot honour: there
    // is nothing here that compares an assertion actual to an expectation.
    expect(m.bindings_required).not.toContain('typescript')
    expect(m.scope_excluded.typescript ?? '').not.toBe('')
  })

  it('carries a fixture this binding can still parse, and a non-vacuous case list', () => {
    const m = manifest()
    expect(m.fixtures.length).toBeGreaterThan(0)
    for (const fx of m.fixtures) {
      // A category whose fixture TypeScript cannot even load would be a format
      // divergence hiding behind a scope exclusion.
      const file = loadString(fs.readFileSync(path.join(CATEGORY_DIR, fx.path), 'utf8'))
      expect(Object.keys(file.models ?? {})).toContain(fx.model)

      // Non-vacuity, checkable without a simulator: at least one non-finite
      // case that MUST FAIL and at least one finite case that MUST PASS. A
      // manifest of nothing but failures would be satisfied by a binding that
      // failed every assertion.
      const mustFailNonFinite = fx.cases.filter((c) => c.actual_class !== 'finite' && !c.passed)
      const mustPassFinite = fx.cases.filter((c) => c.actual_class === 'finite' && c.passed)
      expect(mustFailNonFinite.length).toBeGreaterThan(0)
      expect(mustPassFinite.length).toBeGreaterThan(0)
    }
  })
})
