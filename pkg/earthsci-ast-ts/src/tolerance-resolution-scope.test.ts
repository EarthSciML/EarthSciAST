/**
 * TypeScript's read of the SHARED `tolerance_resolution` conformance manifest
 * (CONFORMANCE_SPEC §5.21, tests/conformance/tolerance_resolution/manifest.json).
 *
 * TypeScript cannot run that category: the contract is esm-spec §6.6.4's
 * resolution of the assertion / test / model `{abs?, rel?}` blocks into the one
 * `(rel, abs)` pair the §6.6.3 predicate is evaluated with, and this binding has
 * no inline-test runner — it parses a `tolerance` block as data and never
 * resolves one. (`resolveTolerances` in `solver.ts` is the OTHER axis: §2.2.2's
 * `abstol`/`reltol` for the integrator, which resolves on its own chain.) The
 * manifest says so in `scope_excluded`, and this file is what keeps that claim
 * honest, exactly as `assertion-nonfinite-scope.test.ts` does for §5.20.
 *
 * The hazard is specific, not hypothetical: the moment a binding grows a §6.6.4
 * resolver it can implement the pre-#228 wholesale rule and diverge from the
 * other three without anything going red, because a category nobody in that
 * binding reads cannot object. So the excluded bindings assert their own
 * exclusion: drop TypeScript from `scope_excluded` (or add it to
 * `bindings_required`) without giving it a resolver and this goes red, instead
 * of the category quietly covering one binding fewer than it claims.
 */
import * as fs from 'node:fs'
import * as path from 'node:path'
import { describe, it, expect } from 'vitest'
import { fixturesDir } from './test-helpers.js'

type Block = Record<string, number | null> | null

interface ToleranceCase {
  id: string
  levels: { model: Block; test: Block; assertion: Block }
  resolved: { rel: number; abs: number }
  changed_by_228: boolean
}

interface ToleranceManifest {
  category: string
  bindings_required: string[]
  scope_excluded: Record<string, string>
  integrators: unknown
  cases: ToleranceCase[]
}

const MANIFEST = path.join(fixturesDir('conformance', 'tolerance_resolution'), 'manifest.json')

function manifest(): ToleranceManifest {
  return JSON.parse(fs.readFileSync(MANIFEST, 'utf8')) as ToleranceManifest
}

const declares = (block: Block, field: string): boolean =>
  block !== null && block[field] !== undefined && block[field] !== null

describe('conformance: tolerance_resolution (scope)', () => {
  it('excludes TypeScript by name, with a reason', () => {
    const m = manifest()
    expect(m.category).toBe('tolerance_resolution')
    // Requiring TypeScript would be a claim this binding cannot honour: there
    // is nothing here that resolves a §6.6.4 tolerance.
    expect(m.bindings_required).not.toContain('typescript')
    expect(m.scope_excluded.typescript ?? '').not.toBe('')
  })

  it('is data-only: no integrator is pinned', () => {
    // CONFORMANCE_SPEC §5.21.2 — resolution is a pure function of the declared
    // blocks, so pinning an integrator here would be a category error.
    expect(manifest().integrators).toBeNull()
  })

  it('carries a non-vacuous case list', () => {
    const m = manifest()
    expect(m.cases.length).toBeGreaterThanOrEqual(15)
    expect(new Set(m.cases.map((c) => c.id)).size).toBe(m.cases.length)
    // The tier must actually exercise the regression it exists for.
    expect(m.cases.filter((c) => c.changed_by_228).length).toBeGreaterThanOrEqual(5)

    // And it must contain the shape that distinguishes a per-field merge from a
    // wholesale one: two levels each declaring a DIFFERENT bound. Without such
    // a case every binding resolves identically under either rule, which is
    // precisely why no other category could see #228.
    let partialPairs = 0
    for (const c of m.cases) {
      const blocks: Block[] = [c.levels.assertion, c.levels.test, c.levels.model]
      for (let i = 0; i < blocks.length; i++) {
        for (const outer of blocks.slice(i + 1)) {
          const inner = blocks[i]
          if (declares(inner, 'abs') && !declares(inner, 'rel') && declares(outer, 'rel')) {
            partialPairs++
          }
          if (declares(inner, 'rel') && !declares(inner, 'abs') && declares(outer, 'abs')) {
            partialPairs++
          }
        }
      }
    }
    expect(partialPairs).toBeGreaterThan(0)
  })
})
