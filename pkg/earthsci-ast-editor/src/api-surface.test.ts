/**
 * The editor package's public surface must equal the API manifest.
 *
 * `@earthsciml/ast-editor` is the one binding whose surface is UI rather than
 * format: SolidJS components, primitives, and the AST store. It is still
 * pinned, for the same reason the others are — `api-surface.json` at the repo
 * root is the single record of what any package in this repo exports
 * (API_SPEC.md).
 *
 * Regenerate the manifest in the same commit as any surface change:
 *
 *     python3 scripts/gen-api-surface.py
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
  symbols: Array<{ name: string; kind: string; bindings: Record<string, string | string[]> }>
  binding_profiles: Record<string, { star_reexports?: string[] }>
}

function parseIndexExports(source: string): { exported: Set<string>; starReexports: string[] } {
  const stripped = source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '')
  const exported = new Set<string>()
  const starReexports: string[] = []

  const named = /export\s+(type\s+)?\{([^}]*)\}\s*from\s*'([^']+)'/g
  for (let m = named.exec(stripped); m !== null; m = named.exec(stripped)) {
    for (const raw of m[2].split(',')) {
      let item = raw.trim()
      if (item === '') continue
      if (item.startsWith('type ')) item = item.slice(5).trim()
      const alias = /^\S+\s+as\s+(\S+)$/.exec(item)
      exported.add(alias ? alias[1] : item)
    }
  }
  const star = /export\s+\*\s+from\s*'([^']+)'/g
  for (let m = star.exec(stripped); m !== null; m = star.exec(stripped)) {
    starReexports.push(m[1])
  }
  return { exported, starReexports: starReexports.sort() }
}

const manifest: Manifest = JSON.parse(readFileSync(MANIFEST, 'utf8'))
const { exported, starReexports } = parseIndexExports(readFileSync(INDEX_TS, 'utf8'))

const declared = new Set<string>()
for (const sym of manifest.symbols) {
  const entry = sym.bindings.editor
  if (entry === undefined) continue
  for (const s of typeof entry === 'string' ? [entry] : entry) declared.add(s)
}

describe('editor public API surface', () => {
  it('parsed a non-trivial surface out of index.ts', () => {
    expect(exported.size).toBeGreaterThan(20)
    expect(declared.size).toBeGreaterThan(20)
  })

  it('exports nothing the manifest does not declare', () => {
    const extra = [...exported].filter((n) => !declared.has(n)).sort()
    expect(
      extra,
      `re-exported from index.ts but absent from api-surface.json:\n  ${extra.join('\n  ')}\n` +
        'Re-run `python3 scripts/gen-api-surface.py`.',
    ).toEqual([])
  })

  it('exports everything the manifest declares', () => {
    const missing = [...declared].filter((n) => !exported.has(n)).sort()
    expect(
      missing,
      `declared for editor in api-surface.json but not re-exported:\n  ${missing.join('\n  ')}`,
    ).toEqual([])
  })

  it('re-exports the same wildcard barrels the manifest pins', () => {
    const pinned = manifest.binding_profiles.editor.star_reexports ?? []
    expect(starReexports).toEqual([...pinned].sort())
  })
})
