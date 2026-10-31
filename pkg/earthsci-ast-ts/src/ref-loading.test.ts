import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { resolveSubsystemRefs, CircularReferenceError, RefLoadError } from './ref-loading.js'
import type { EsmFile, Model, ReactionSystem } from './types.js'
import { loadPath } from './parse.js'
import { validate } from './validate.js'
import { fixturesDir } from './test-helpers.js'
import * as fs from 'node:fs/promises'
import * as os from 'node:os'
import * as path from 'node:path'

/**
 * Build an `EsmFile` fixture from a top-level component map, replacing the
 * repeated `{ esm, metadata, models/reaction_systems } as unknown as EsmFile`
 * literals. The single `as unknown as EsmFile` cast lives here so intentionally
 * partial test shapes don't scatter double-casts through every test.
 */
function esmFile(parts: {
  name?: string
  models?: Record<string, unknown>
  reaction_systems?: Record<string, unknown>
}): EsmFile {
  const file: Record<string, unknown> = {
    esm: '0.1.0',
    metadata: { name: parts.name ?? 'test' },
  }
  if (parts.models) file.models = parts.models
  if (parts.reaction_systems) file.reaction_systems = parts.reaction_systems
  return file as unknown as EsmFile
}

describe('resolveSubsystemRefs', () => {
  let tmpDir: string

  beforeEach(async () => {
    tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), 'esm-ref-test-'))
  })

  afterEach(async () => {
    await fs.rm(tmpDir, { recursive: true, force: true })
  })

  it('does nothing for files with no refs', async () => {
    const file = esmFile({
      models: {
        Atm: { variables: {}, equations: [] },
      },
    })

    await resolveSubsystemRefs(file, tmpDir)
    expect(file.models!.Atm).toBeDefined()
  })

  it('resolves a local file ref into a subsystem', async () => {
    const refContent = JSON.stringify({
      esm: '0.1.0',
      metadata: { name: 'sub' },
      models: {
        Inner: {
          variables: { x: { type: 'state' } },
          equations: [],
        },
      },
    })
    await fs.writeFile(path.join(tmpDir, 'inner.esm.json'), refContent)

    const file = esmFile({
      name: 'main',
      models: {
        Outer: {
          variables: {},
          equations: [],
          subsystems: {
            Inner: { ref: './inner.esm.json' },
          },
        },
      },
    })

    await resolveSubsystemRefs(file, tmpDir)
    const inner = (file.models!.Outer as Model).subsystems!.Inner as any
    expect(inner.ref).toBeUndefined()
    expect(inner.variables.x).toBeDefined()
  })

  it('leaves the ref stub in place for a source-only file', async () => {
    // Referenced file declares only `data_sources`. In 0.x its first loader was
    // inlined under the parent key, because the schema then allowed a
    // DataLoader inside Model.subsystems. From 1.0.0 a data source is ingest
    // configuration rather than a component and CANNOT be a subsystem, so the
    // file contributes no component and the `{ref}` stub stays put -- which the
    // unresolved-ref diagnostic then reports, rather than the reference
    // silently binding to ingest configuration.
    const refContent = JSON.stringify({
      esm: '1.0.0',
      metadata: { name: 'met' },
      data_sources: {
        Weather: {
          kind: 'grid',
          source: { url_template: '/data/weather_{date:%Y%m%d}.nc' },
        },
      },
    })
    await fs.writeFile(path.join(tmpDir, 'weather.esm.json'), refContent)

    const file = esmFile({
      name: 'main',
      models: {
        Outer: {
          variables: {},
          equations: [],
          subsystems: {
            Met: { ref: './weather.esm.json' },
          },
        },
      },
    })

    await resolveSubsystemRefs(file, tmpDir)
    const met = (file.models!.Outer as Model).subsystems!.Met as any
    expect(met.ref).toBe('./weather.esm.json')
    expect(met.kind).toBeUndefined()
  })

  it('throws RefLoadError when local file is missing', async () => {
    const file = esmFile({
      name: 'main',
      models: {
        Outer: {
          variables: {},
          equations: [],
          subsystems: {
            Missing: { ref: './does-not-exist.esm.json' },
          },
        },
      },
    })

    await expect(resolveSubsystemRefs(file, tmpDir)).rejects.toBeInstanceOf(RefLoadError)
  })

  it('detects circular references', async () => {
    const aContent = JSON.stringify({
      esm: '0.1.0',
      metadata: { name: 'a' },
      models: {
        A: {
          variables: {},
          equations: [],
          subsystems: { Cycle: { ref: './b.esm.json' } },
        },
      },
    })
    const bContent = JSON.stringify({
      esm: '0.1.0',
      metadata: { name: 'b' },
      models: {
        B: {
          variables: {},
          equations: [],
          subsystems: { Cycle: { ref: './a.esm.json' } },
        },
      },
    })
    await fs.writeFile(path.join(tmpDir, 'a.esm.json'), aContent)
    await fs.writeFile(path.join(tmpDir, 'b.esm.json'), bContent)

    const file = esmFile({
      name: 'main',
      models: {
        Root: {
          variables: {},
          equations: [],
          subsystems: { Start: { ref: './a.esm.json' } },
        },
      },
    })

    await expect(resolveSubsystemRefs(file, tmpDir)).rejects.toBeInstanceOf(CircularReferenceError)
  })

  it('resolves refs inside reaction systems', async () => {
    const refContent = JSON.stringify({
      esm: '0.1.0',
      metadata: { name: 'sub' },
      reaction_systems: {
        SubChem: {
          species: { O3: {} },
          parameters: {},
          reactions: [],
        },
      },
    })
    await fs.writeFile(path.join(tmpDir, 'subchem.esm.json'), refContent)

    const file = esmFile({
      name: 'main',
      reaction_systems: {
        Chem: {
          species: {},
          parameters: {},
          reactions: [],
          subsystems: {
            Sub: { ref: './subchem.esm.json' },
          },
        },
      },
    })

    await resolveSubsystemRefs(file, tmpDir)
    const sub = (file.reaction_systems!.Chem as ReactionSystem).subsystems!.Sub as any
    expect(sub.ref).toBeUndefined()
    expect(sub.species.O3).toBeDefined()
  })
})

// esm-spec §4.7: each file is held to its OWN declared `esm`, by every
// file-level version gate the root gets, read as raised by the `aggregate` →
// `faq` normalization.
describe('a mounted leaf runs every version gate on its own esm', () => {
  const codeOf = async (p: string): Promise<string | null> => {
    try {
      await resolveSubsystemRefs(loadPath(p), path.dirname(p))
      return null
    } catch (e) {
      return (e as { code?: string }).code ?? String(e)
    }
  }

  it.each([
    ['version_gate_newer_mounts_older_const_units.esm', 'const_units_version_too_old'],
    ['version_gate_newer_mounts_older_solver.esm', 'solver_version_too_old'],
  ])('rejects %s with %s', async (name, code) => {
    expect(await codeOf(fixturesDir('invalid', name))).toBe(code)
  })

  it('accepts an older root mounting a newer leaf', async () => {
    expect(await codeOf(fixturesDir('valid', 'version_gate_older_mounts_newer.esm'))).toBe(null)
  })

  it('validates the resolved form of an older root mounting a newer leaf', async () => {
    // validate() re-enters the loader with the RESOLVED document, which now
    // carries the leaf's 1.2.0 unit-bearing const under the root's version, so
    // resolution raises the declared floor to 1.2.0.
    const p = fixturesDir('valid', 'version_gate_older_mounts_newer.esm')
    const file = loadPath(p)
    await resolveSubsystemRefs(file, path.dirname(p))
    expect((file as unknown as { esm: string }).esm).toBe('1.2.0')
    const result = validate(file)
    expect(result.structural_errors).toEqual([])
  })

  it('reads the leaf version as raised by the aggregate normalization', async () => {
    const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'esm-leaf-gate-'))
    try {
      const alias = fixturesDir('conformance', 'deprecated_op_alias')
      const child = JSON.parse(
        await fs.readFile(path.join(alias, 'ref_child_aliased.esm'), 'utf-8'),
      )
      // A 1.0.0 leaf spelling `aggregate` is raised to 1.1.0, so its `solver`
      // block is in range.
      child.esm = '1.0.0'
      child.solver = { stiffness: 'high' }
      await fs.writeFile(path.join(dir, 'ref_child_aliased.esm'), JSON.stringify(child))
      await fs.copyFile(
        path.join(alias, 'ref_parent_aliased.esm'),
        path.join(dir, 'ref_parent_aliased.esm'),
      )
      const quiet = vi.spyOn(console, 'warn').mockImplementation(() => {})
      try {
        expect(await codeOf(path.join(dir, 'ref_parent_aliased.esm'))).toBe(null)
      } finally {
        quiet.mockRestore()
      }
    } finally {
      await fs.rm(dir, { recursive: true, force: true })
    }
  })
})
