import { describe, it, expect, beforeEach, afterEach } from 'vitest'
import {
  resolveSubsystemRefs,
  resolveSubsystemRefsSync,
  CircularReferenceError,
  RefLoadError,
} from './ref-loading.js'
import type { EsmFile, Model, ReactionSystem } from './types.js'
import { SCHEMA_VERSION, loadPath } from './parse.js'
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

  // The async prefetch must classify a top-level entry as a mount edge exactly
  // when the sync pass does: an inline component that also carries a stray
  // `ref` (a reaction system with `species`, a model with `variables`) is a
  // component, so its nested subsystem refs must be prefetched.
  it('walks the subsystems of an inline top-level component that carries a stray ref', async () => {
    await fs.writeFile(
      path.join(tmpDir, 'subchem.esm.json'),
      JSON.stringify({
        esm: '0.1.0',
        metadata: { name: 'sub' },
        reaction_systems: { SubChem: { species: { O3: {} }, parameters: {}, reactions: [] } },
      }),
    )
    await fs.writeFile(
      path.join(tmpDir, 'inner.esm.json'),
      JSON.stringify({
        esm: '0.1.0',
        metadata: { name: 'inner' },
        models: { Inner: { variables: { x: { type: 'state' } }, equations: [] } },
      }),
    )

    const file = esmFile({
      name: 'main',
      models: {
        Outer: {
          ref: './stray.esm.json',
          variables: {},
          equations: [],
          subsystems: { Inner: { ref: './inner.esm.json' } },
        },
      },
      reaction_systems: {
        Chem: {
          ref: './stray.esm.json',
          species: {},
          parameters: {},
          reactions: [],
          subsystems: { Sub: { ref: './subchem.esm.json' } },
        },
      },
    })

    await resolveSubsystemRefs(file, tmpDir)
    const inner = (file.models!.Outer as Model).subsystems!.Inner as any
    expect(inner.ref).toBeUndefined()
    expect(inner.variables.x).toBeDefined()
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
  // A 1.x document loads at 2.0.0 on its own and as a mounted leaf (user
  // ruling); only a removed construct refuses it, by name.
  describe('a 1.x leaf under a current-version root', () => {
    const leaf = (rhs: unknown) => ({
      esm: '1.3.0',
      metadata: { name: 'leaf', authors: ['t'] },
      models: {
        Leaf: {
          variables: { y: { type: 'unknown', units: '1', default: 1.0 } },
          equations: [{ lhs: { op: 'D', args: ['y'], wrt: 't' }, rhs }],
        },
      },
    })
    const root = {
      esm: SCHEMA_VERSION,
      metadata: { name: 'root', authors: ['t'] },
      models: {
        Host: {
          subsystems: { Kid: { ref: 'leaf.esm' } },
          variables: { v: { type: 'unknown', units: '1', default: 0.0 } },
          equations: [{ lhs: { op: 'D', args: ['v'], wrt: 't' }, rhs: 0 }],
        },
      },
    }
    const mount = async (leafDoc: unknown): Promise<string> => {
      const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'esm-v1-leaf-'))
      await fs.writeFile(path.join(dir, 'leaf.esm'), JSON.stringify(leafDoc))
      await fs.writeFile(path.join(dir, 'root.esm'), JSON.stringify(root))
      return path.join(dir, 'root.esm')
    }

    it('loads, resolves and validates', async () => {
      const p = await mount(leaf({ op: '-', args: ['y'] }))
      try {
        expect(await codeOf(p)).toBe(null)
        const file = loadPath(p)
        await resolveSubsystemRefs(file, path.dirname(p))
        expect(validate(file).structural_errors).toEqual([])
      } finally {
        await fs.rm(path.dirname(p), { recursive: true, force: true })
      }
    })

    it('refuses the leaf by name when it uses a removed op', async () => {
      const p = await mount(leaf({ op: 'fn', name: 'datetime.year', args: ['t'] }))
      try {
        expect(await codeOf(p)).toBe('removed_op')
      } finally {
        await fs.rm(path.dirname(p), { recursive: true, force: true })
      }
    })
  })
})

// esm-spec §4.7 "Two mount forms, one mechanism": the `model` selector picks one
// of several models at a top-level `models.<k>` mount exactly as
// `reaction_system` does at `reaction_systems.<k>`, and the single-component
// rule reads only the block the form mounts from.
describe('the selector at a top-level mount', () => {
  let dir: string
  const model = (v: string) => ({ variables: { [v]: { type: 'state' } }, equations: [] })
  const reactionSystem = { species: { A: {} }, reactions: [] }
  const leaf = (parts: Record<string, unknown>) =>
    JSON.stringify({ esm: '0.1.0', metadata: { name: 'leaf' }, ...parts })

  beforeEach(async () => {
    dir = await fs.mkdtemp(path.join(os.tmpdir(), 'esm-selector-'))
    await fs.writeFile(
      path.join(dir, 'two_models.esm'),
      leaf({ models: { A: model('a'), B: model('b') } }),
    )
    await fs.writeFile(
      path.join(dir, 'model_and_rs.esm'),
      leaf({ models: { M: model('m') }, reaction_systems: { R: reactionSystem } }),
    )
    await fs.writeFile(
      path.join(dir, 'two_rs.esm'),
      leaf({ reaction_systems: { R: reactionSystem, S: reactionSystem } }),
    )
  })

  afterEach(async () => {
    await fs.rm(dir, { recursive: true, force: true })
  })

  // Run the sync core and the async (prefetching) entry point on copies of one
  // document; both must give the same answer.
  const resolveBoth = async (
    parts: Parameters<typeof esmFile>[0],
  ): Promise<Array<EsmFile | { code?: string; path?: string }>> => {
    const results: Array<EsmFile | { code?: string; path?: string }> = []
    const runs: Array<(f: EsmFile) => Promise<void> | void> = [
      (f) => resolveSubsystemRefsSync(f, dir),
      (f) => resolveSubsystemRefs(f, dir),
    ]
    for (const run of runs) {
      const file = esmFile(structuredClone(parts))
      try {
        await run(file)
        results.push(file)
      } catch (e) {
        results.push(e as { code?: string; path?: string })
      }
    }
    return results
  }

  const expectRefused = async (parts: Parameters<typeof esmFile>[0], pointer: string) => {
    for (const err of await resolveBoth(parts)) {
      expect(err).toBeInstanceOf(RefLoadError)
      expect((err as RefLoadError).code).toBe('unresolved_subsystem_ref')
      expect((err as RefLoadError).path).toBe(pointer)
    }
  }

  it('mounts the model the `model` selector names', async () => {
    for (const file of await resolveBoth({
      models: { Atm: { ref: './two_models.esm', model: 'B' } },
    })) {
      const atm = (file as EsmFile).models!.Atm as Model
      expect(Object.keys(atm.variables)).toEqual(['b'])
    }
  })

  it('refuses several models and no selector', async () => {
    await expectRefused({ models: { Atm: { ref: './two_models.esm' } } }, '/models/Atm')
  })

  it('refuses a selector naming a model the leaf does not declare', async () => {
    await expectRefused({ models: { Atm: { ref: './two_models.esm', model: 'C' } } }, '/models/Atm')
  })

  it('refuses a selector naming an Object.prototype key', async () => {
    await expectRefused(
      { models: { Atm: { ref: './two_models.esm', model: 'constructor' } } },
      '/models/Atm',
    )
    await expectRefused(
      { reaction_systems: { Chem: { ref: './two_rs.esm', reaction_system: 'constructor' } } },
      '/reaction_systems/Chem',
    )
  })

  it('refuses a leaf with no model', async () => {
    await expectRefused({ models: { Atm: { ref: './two_rs.esm' } } }, '/models/Atm')
  })

  it('mounts the one model of a leaf that also declares a reaction system', async () => {
    for (const file of await resolveBoth({ models: { Atm: { ref: './model_and_rs.esm' } } })) {
      expect(Object.keys(((file as EsmFile).models!.Atm as Model).variables)).toEqual(['m'])
    }
  })
})
