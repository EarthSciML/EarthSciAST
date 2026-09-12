/**
 * Mount-edge index-set renaming (esm-spec §4.7 "Mount-edge index-set
 * renaming") — the fix for EarthSciML/EarthSciAST#198 item 4.
 *
 * `index_sets` is a DOCUMENT-scoped registry, so a document that mounts a
 * 59-layer atmospheric column and a 4-layer soil column — both of which spell
 * their axis `lev`, because both come from the same one-dimensional column
 * family at different lengths — hits the §4.7 deep-equal-or-error merge and
 * fails with
 * `subsystem_index_set_conflict`. That scoping is load-bearing (`shape`,
 * `{"from"}`, `from_faq`, §11.2 dimensionality, §9.6.1 `where` constraints and
 * §2.1 `coordinates` all resolve against the one registry), so the fix is not
 * to re-scope it but to let the ASSEMBLER say "this mount's `lev` is not that
 * mount's `lev`" at the edge.
 */
import { describe, expect, it } from 'vitest'
import { mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
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

  // esm-spec §4.7 "Where it applies": the field is normative at BOTH mount
  // forms, "with the same meaning and the same pipeline", because "a binding
  // MUST NOT make the two forms differ". This binding used to leave a top-level
  // `models.<k>` `{ref}` unresolved, so the edge — its rename included — was
  // silently ignored. The two fixtures driven below are the same assembly
  // written at the two attachment points, and must come out the same.
  it('applies the rename at a top-level `models.<k>` {ref} mount too', () => {
    const { file } = loadResolved('valid/mount_rename_two_columns_toplevel.esm')
    const sets = (file as unknown as { index_sets: Record<string, { size?: number }> }).index_sets
    expect(sets.lev?.size).toBe(59)
    expect(sets.soil_lev?.size).toBe(4)

    // The component LANDS as a top-level system under the mount key — an empty
    // `Soil` would satisfy the registry assertions above and still have thrown
    // the mounted model away.
    const models = file.models as Record<string, { variables?: object; ref?: string }>
    expect(models.Soil?.ref).toBeUndefined()
    expect(Object.keys(models.Soil?.variables ?? {})).toEqual(['Tsoil'])
    const soil = JSON.stringify(models.Soil)
    expect(soil).toContain('soil_lev')
    expect(soil).not.toContain('"lev"')
    expect(JSON.stringify(models.Atm)).toContain('"lev"')
  })

  it('checks the rename keys at a top-level `models.<k>` {ref} mount too', () => {
    expect(() =>
      loadResolved('invalid/template_imports/mount_rename_unknown_index_set_toplevel.esm'),
    ).toThrow(/subsystem_index_set_rename_unknown_name/)
    // The diagnostic says which mount form it is talking about.
    expect(() =>
      loadResolved('invalid/template_imports/mount_rename_unknown_index_set_toplevel.esm'),
    ).toThrow(/top-level model ref/)
  })

  // esm-spec §4.7 "Resolution timing": a component mounted at the TOP LEVEL by
  // `{ref}` is spliced in with its `tests` dropped, because an inline test
  // asserts something about the leaf under the leaf's OWN standalone conditions
  // and the mounting document may couple it. (A `subsystems.<k>` mount needs no
  // such handling — a test targets a top-level component, so a subsystem's tests
  // are never run by the mounting document either.)
  it('drops the inline tests of a top-level mounted component', () => {
    const dir = mkdtempSync(path.join(tmpdir(), 'esm-toplevel-mount-'))
    writeFileSync(
      path.join(dir, 'leaf.esm'),
      JSON.stringify({
        esm: '1.0.0',
        metadata: { name: 'leaf' },
        models: {
          Leaf: {
            variables: { u: { type: 'unknown', units: '1', default: 1.0 } },
            equations: [
              { lhs: { op: 'D', args: ['u'], wrt: 't' }, rhs: { op: '*', args: [-1.0, 'u'] } },
            ],
            tests: [
              {
                name: 'decays',
                duration: 1.0,
                assertions: [
                  { variable: 'u', at: 1.0, expected: 0.3679, tolerance: { abs: 0.01 } },
                ],
              },
            ],
          },
        },
      }),
    )
    const host = {
      esm: '1.0.0',
      metadata: { name: 'host' },
      models: { Mounted: { ref: './leaf.esm' } },
    } as unknown as EsmFile
    resolveSubsystemRefsSync(host, dir)
    const mounted = (host.models as Record<string, { variables?: object; tests?: unknown[] }>)
      .Mounted
    expect(Object.keys(mounted.variables ?? {})).toEqual(['u'])
    expect(mounted.tests).toBeUndefined()
  })
})
