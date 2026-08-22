/**
 * The TypeScript binding's public surface must equal the API manifest.
 *
 * `api-surface.json` at the repo root is the cross-language record of what
 * every binding exports (see API_SPEC.md). This test pins the TypeScript half:
 * a named re-export in `index.ts` that the manifest does not list fails, and a
 * TypeScript name in the manifest that `index.ts` does not re-export fails too.
 *
 * `index.ts` is parsed rather than imported because half the surface is
 * type-only (`export type { ... }`) and erased at runtime — a runtime
 * `import * as api` would silently miss all of it.
 *
 * If this test fails you have changed the public API. That is allowed — but
 * regenerate the manifest in the same commit:
 *
 *     python3 scripts/gen-api-surface.py
 *
 * and then say in API_SPEC.md which tier the new symbol lands in.
 */

import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const HERE = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(HERE, '../../..')
const INDEX_TS = resolve(HERE, 'index.ts')
const MANIFEST = resolve(REPO_ROOT, 'api-surface.json')

interface Manifest {
  symbols: Array<{
    name: string
    kind: string
    tier: string
    bindings: Record<string, string | string[]>
  }>
  binding_profiles: Record<string, { star_reexports?: string[] }>
}

/** Named re-exports of `index.ts`, split into value and type-only exports. */
export function parseIndexExports(source: string): {
  values: Set<string>
  types: Set<string>
  starReexports: string[]
} {
  const stripped = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '')
  const values = new Set<string>()
  const types = new Set<string>()
  const starReexports: string[] = []

  const named = /export\s+(type\s+)?\{([^}]*)\}\s*from\s*'([^']+)'/g
  for (let m = named.exec(stripped); m !== null; m = named.exec(stripped)) {
    const defaultBucket = m[1] ? types : values
    for (const raw of m[2].split(',')) {
      let item = raw.trim()
      if (item === '') continue
      let bucket = defaultBucket
      if (item.startsWith('type ')) {
        item = item.slice(5).trim()
        bucket = types
      }
      const alias = /^\S+\s+as\s+(\S+)$/.exec(item)
      bucket.add(alias ? alias[1] : item)
    }
  }

  const star = /export\s+\*\s+from\s*'([^']+)'/g
  for (let m = star.exec(stripped); m !== null; m = star.exec(stripped)) {
    starReexports.push(m[1])
  }
  return { values, types, starReexports: starReexports.sort() }
}

const manifest: Manifest = JSON.parse(readFileSync(MANIFEST, 'utf8'))
const surface = parseIndexExports(readFileSync(INDEX_TS, 'utf8'))
const exported = new Set([...surface.values, ...surface.types])

function spellings(entry: string | string[]): string[] {
  return typeof entry === 'string' ? [entry] : entry
}

const declared = new Set<string>()
for (const sym of manifest.symbols) {
  const entry = sym.bindings.typescript
  if (entry !== undefined) for (const s of spellings(entry)) declared.add(s)
}

describe('public API surface', () => {
  it('parsed a non-trivial surface out of index.ts', () => {
    // Guard against the regex silently matching nothing and the whole suite
    // passing vacuously.
    expect(exported.size).toBeGreaterThan(100)
    expect(declared.size).toBeGreaterThan(100)
  })

  it('exports nothing the manifest does not declare', () => {
    const extra = [...exported].filter((n) => !declared.has(n)).sort()
    expect(
      extra,
      `re-exported from index.ts but absent from api-surface.json:\n  ${extra.join('\n  ')}\n` +
        'Add them by re-running `python3 scripts/gen-api-surface.py`, then assign ' +
        'each a tier in API_SPEC.md.',
    ).toEqual([])
  })

  it('exports everything the manifest declares', () => {
    const missing = [...declared].filter((n) => !exported.has(n)).sort()
    expect(
      missing,
      `declared for typescript in api-surface.json but not re-exported from index.ts:\n  ` +
        `${missing.join('\n  ')}\n` +
        'Either restore the export or drop it from the manifest — dropping a ' +
        '`stable` symbol is a major-version break (API_SPEC.md §3).',
    ).toEqual([])
  })

  it('re-exports the same wildcard barrels the manifest pins', () => {
    // `export * from './types.js'` cannot be enumerated without resolving the
    // barrel, and its members are schema-derived and churn with
    // esm-schema.json. The manifest pins the barrel LIST instead, so adding or
    // removing a wildcard is still a surface change that must be declared.
    const pinned = manifest.binding_profiles.typescript.star_reexports ?? []
    expect(surface.starReexports).toEqual([...pinned].sort())
  })

  it('classifies type-only exports as manifest types, not values', () => {
    // A TypeScript error is a class and therefore a VALUE export; anything
    // reachable only via `export type` cannot be thrown or `instanceof`-ed.
    const wrong: string[] = []
    for (const sym of manifest.symbols) {
      const entry = sym.bindings.typescript
      if (entry === undefined) continue
      for (const name of spellings(entry)) {
        if (sym.kind === 'error' && surface.types.has(name) && !surface.values.has(name)) {
          wrong.push(`${name}: manifest says error, but index.ts exports it type-only`)
        }
      }
    }
    expect(wrong, wrong.join('\n')).toEqual([])
  })
})
