/**
 * Mount-edge index-set renaming (esm-spec §4.7 "Mount-edge index-set
 * renaming") — the fix for EarthSciML/EarthSciAST#198 item 4.
 *
 * `index_sets` is a DOCUMENT-scoped registry, so a document that mounts a
 * 59-layer atmospheric column and a 4-layer soil column — both of which spell
 * their axis `lev`, because both import the same column-grid library at
 * different `NLEV` — hits the §4.7 deep-equal-or-error merge and fails with
 * `subsystem_index_set_conflict`. That scoping is load-bearing (`shape`,
 * `{"from"}`, `from_faq`, §11.2 dimensionality, §9.6.1 `where` constraints and
 * §2.1 `coordinates` all resolve against the one registry), so the fix is not
 * to re-scope it but to let the ASSEMBLER say "this mount's `lev` is not that
 * mount's `lev`" at the edge.
 */
import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import * as path from 'node:path'
import { resolveSubsystemRefsSync } from './ref-loading.js'
import type { EsmFile } from './types.js'

const TESTS = path.resolve(__dirname, '../../../tests')

function loadResolved(rel: string): { file: EsmFile; base: string } {
  const full = path.join(TESTS, rel)
  const file = JSON.parse(readFileSync(full, 'utf8')) as EsmFile
  const base = path.dirname(full)
  resolveSubsystemRefsSync(file, base)
  return { file, base }
}

describe('mount-edge index_set_rename (esm-spec §4.7)', () => {
  it('lets two columns that both name their axis `lev` coexist', () => {
    const { file } = loadResolved('valid/mount_rename_two_columns.esm')
    const sets = (file as unknown as { index_sets: Record<string, { size?: number }> }).index_sets
    expect(sets.lev?.size).toBe(59)
    expect(sets.soil_lev?.size).toBe(4)
  })

  it('rewrites the mounted component transitively, and leaves the other mount alone', () => {
    // A `shape` list that still said `lev` would resolve against the 59-layer
    // axis and allocate 59 soil layers.
    const { file } = loadResolved('valid/mount_rename_two_columns.esm')
    const host = (file.models as Record<string, { subsystems: Record<string, unknown> }>).Host
    const soil = JSON.stringify(host.subsystems.Soil)
    expect(soil).toContain('soil_lev')
    expect(soil).not.toContain('"lev"')
    expect(JSON.stringify(host.subsystems.Atm)).toContain('"lev"')
  })

  it('rejects a rename key the resolved mounted document does not declare', () => {
    // Renames never invent names — the §9.7.7 rule at a mount edge.
    expect(() =>
      loadResolved('invalid/template_imports/mount_rename_unknown_index_set.esm'),
    ).toThrow(/subsystem_index_set_rename_unknown_name|celsl/)
  })
})
