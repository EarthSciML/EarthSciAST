/**
 * esm-spec §4.7 `${VAR}` environment-variable expansion in refs — the OPTIONAL
 * loader capability the spec lists alongside URL refs, and the form §10.10
 * names for a `coupling_import` ref ("relative path, absolute path, URL,
 * `${VAR}`").
 *
 * These pin the three rules `expandRefEnv` implements, at every ref-resolution
 * surface this package owns (template-library imports, subsystem / top-level
 * model mounts on both the sync and async paths, and coupling imports):
 *
 *   1. Only the braced `${VAR}` form is a token — a bare `$VAR` is ordinary ref
 *      text.
 *   2. A SET variable is replaced; an UNSET one is left LITERAL, so the ref
 *      fails with the ordinary unresolved diagnostic naming the `${VAR}` text
 *      the author wrote rather than misresolving against an empty string.
 *   3. Expansion happens BEFORE the remote/absolute classification and before
 *      anchoring, so an expanded RELATIVE ref still anchors against the
 *      referencing document's own directory.
 *
 * The documents under test are written into a fresh `mkdtempSync` directory
 * rather than the shared `tests/valid` corpus, which every binding sweeps and
 * which no binding may be asked to resolve against this process's environment.
 * The variable names are unique to this file so a parallel vitest file cannot
 * race them.
 */
import * as fs from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { expandRefEnv } from './path-utils.js'
import { resolveTemplateMachinery } from './template-imports.js'
import { resolveSubsystemRefs, resolveSubsystemRefsSync } from './ref-loading.js'
import { expandCouplingImports } from './coupling-imports.js'
import { loadString, validateSchema } from './parse.js'
import type { EsmFile } from './types.js'

/** Unique to this file — see the header note on parallel vitest files. */
const LIB_DIR_VAR = 'ESM_TS_ENVREF_TEST_LIBDIR'
const SUB_DIR_VAR = 'ESM_TS_ENVREF_TEST_SUBDIR'

const VALID_DIR = path.resolve(__dirname, '../../../tests/valid')

let dir: string
let saved: Record<string, string | undefined>

beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'esm-envref-'))
  saved = { [LIB_DIR_VAR]: process.env[LIB_DIR_VAR], [SUB_DIR_VAR]: process.env[SUB_DIR_VAR] }
  delete process.env[LIB_DIR_VAR]
  delete process.env[SUB_DIR_VAR]
})

afterEach(() => {
  for (const [k, v] of Object.entries(saved)) {
    if (v === undefined) delete process.env[k]
    else process.env[k] = v
  }
})

/** Write `doc` into the scratch directory and hand back its path. */
function write(name: string, doc: unknown): string {
  const full = path.join(dir, name)
  fs.mkdirSync(path.dirname(full), { recursive: true })
  fs.writeFileSync(full, JSON.stringify(doc), 'utf8')
  return full
}

/** A consuming model whose §9.7.2 import edge points at `ref`. */
function importer(ref: string): unknown {
  return {
    esm: '1.0.0',
    metadata: { name: 'envref_importer' },
    models: {
      M: {
        expression_template_imports: [{ ref }],
        variables: {
          x: { type: 'unknown', units: '1', default: 1.0 },
          y: { type: 'unknown', units: '1' },
        },
        equations: [
          { lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: { op: '-', args: ['x'] } },
          { lhs: 'y', rhs: { op: 'scale_by_n', args: ['x'] } },
        ],
      },
    },
  }
}

/** A leaf component file, for the §4.7 mount cases. */
const leafDoc = {
  esm: '1.0.0',
  metadata: { name: 'envref_leaf' },
  models: {
    Leaf: {
      variables: { u: { type: 'unknown', units: '1', default: 1.0 } },
      equations: [{ lhs: { op: 'D', args: ['u'], wrt: 't' }, rhs: { op: '*', args: [-1.0, 'u'] } }],
    },
  },
}

/** A §10.9 coupling-library file, for the §10.10 import case. */
const couplingLibDoc = {
  esm: '1.0.0',
  metadata: { name: 'envref_coupling_lib' },
  coupling_roles: { Fuel: { description: 'source' }, Spread: { description: 'sink' } },
  coupling: [
    { type: 'variable_map', from: 'Fuel.sigma', to: 'Spread.sigma', transform: 'param_to_var' },
  ],
}

/** An assembly whose §10.10 import edge points at `ref`. */
function couplingImporter(ref: string): EsmFile {
  return {
    esm: '1.0.0',
    metadata: { name: 'envref_assembly' },
    models: {
      Src: { variables: { sigma: { type: 'parameter', units: '1', default: 1 } }, equations: [] },
      Dst: { variables: { sigma: { type: 'parameter', units: '1', default: 0 } }, equations: [] },
    },
    coupling: [{ type: 'coupling_import', ref, bind: { Fuel: 'Src', Spread: 'Dst' } }],
  } as unknown as EsmFile
}

describe('expandRefEnv (esm-spec §4.7)', () => {
  it('replaces a set `${VAR}` and leaves an unset one literal', () => {
    process.env[LIB_DIR_VAR] = '/opt/libs'
    expect(expandRefEnv(`\${${LIB_DIR_VAR}}/a.esm`)).toBe('/opt/libs/a.esm')
    expect(expandRefEnv(`\${${SUB_DIR_VAR}}/a.esm`)).toBe(`\${${SUB_DIR_VAR}}/a.esm`)
  })

  it('expands only the braced C-identifier form', () => {
    process.env[LIB_DIR_VAR] = '/opt/libs'
    // Bare `$VAR`, an unclosed `${`, and a non-identifier name are ref text.
    expect(expandRefEnv(`$${LIB_DIR_VAR}/a.esm`)).toBe(`$${LIB_DIR_VAR}/a.esm`)
    expect(expandRefEnv(`\${${LIB_DIR_VAR}/a.esm`)).toBe(`\${${LIB_DIR_VAR}/a.esm`)
    expect(expandRefEnv('${2BAD}/a.esm')).toBe('${2BAD}/a.esm')
    expect(expandRefEnv('${A-B}/a.esm')).toBe('${A-B}/a.esm')
  })

  it('expands every token in a ref, independently', () => {
    process.env[LIB_DIR_VAR] = 'one'
    expect(expandRefEnv(`\${${LIB_DIR_VAR}}/\${${SUB_DIR_VAR}}/\${${LIB_DIR_VAR}}.esm`)).toBe(
      `one/\${${SUB_DIR_VAR}}/one.esm`,
    )
  })
})

describe('§4.7 `${VAR}` in a template-library import (§9.7.2)', () => {
  it('resolves the import through a set variable', () => {
    process.env[LIB_DIR_VAR] = VALID_DIR
    const doc = importer(`\${${LIB_DIR_VAR}}/template_import_lib.esm`)
    const resolved = resolveTemplateMachinery(doc, dir, { validateSchema })
    // The library's templates and its metaparameter-sized axis both arrived.
    const model = (resolved?.models as Record<string, Record<string, unknown>>).M
    expect(Object.keys(model.expression_templates ?? {})).toContain('scale_by_n')
    expect((resolved?.index_sets as Record<string, { size?: unknown }>).cells?.size).toBe(8)
  })

  it('leaves an unset variable literal and fails naming the `${VAR}` text', () => {
    const ref = `\${${LIB_DIR_VAR}}/template_import_lib.esm`
    expect(() => resolveTemplateMachinery(importer(ref), dir, { validateSchema })).toThrow(
      new RegExp(`\\$\\{${LIB_DIR_VAR}\\}`),
    )
    try {
      resolveTemplateMachinery(importer(ref), dir, { validateSchema })
      expect.unreachable('an unset ${VAR} must not resolve')
    } catch (e) {
      expect((e as { code?: string }).code).toBe('template_import_unresolved')
    }
  })

  it('does not expand a bare `$VAR`', () => {
    process.env[LIB_DIR_VAR] = VALID_DIR
    const ref = `$${LIB_DIR_VAR}/template_import_lib.esm`
    try {
      resolveTemplateMachinery(importer(ref), dir, { validateSchema })
      expect.unreachable('a bare $VAR must not expand')
    } catch (e) {
      const msg = String((e as Error).message)
      expect(msg).toContain(`$${LIB_DIR_VAR}`)
      expect(msg).not.toContain(VALID_DIR)
    }
  })

  it('anchors an expanded RELATIVE ref against the referencing document', () => {
    // The variable supplies a path FRAGMENT, not a whole path: expansion comes
    // first, and the still-relative result is then joined to the importer's own
    // directory — not to the process cwd, which is the package root here.
    process.env[SUB_DIR_VAR] = 'libs'
    fs.mkdirSync(path.join(dir, 'libs'), { recursive: true })
    fs.copyFileSync(
      path.join(VALID_DIR, 'template_import_lib.esm'),
      path.join(dir, 'libs', 'lib.esm'),
    )
    const doc = importer(`./\${${SUB_DIR_VAR}}/lib.esm`)
    const resolved = resolveTemplateMachinery(doc, dir, { validateSchema })
    const model = (resolved?.models as Record<string, Record<string, unknown>>).M
    expect(Object.keys(model.expression_templates ?? {})).toContain('scale_by_n')
  })
})

describe('§4.7 `${VAR}` in a mount ref', () => {
  it('resolves a top-level `models.<k>` {ref} through a set variable', () => {
    write('leaf.esm', leafDoc)
    process.env[LIB_DIR_VAR] = dir
    const host = {
      esm: '1.0.0',
      metadata: { name: 'host' },
      models: { Mounted: { ref: `\${${LIB_DIR_VAR}}/leaf.esm` } },
    } as unknown as EsmFile
    resolveSubsystemRefsSync(host, dir)
    const models = host.models as Record<string, { ref?: string; variables?: object }>
    expect(models.Mounted.ref).toBeUndefined()
    expect(Object.keys(models.Mounted.variables ?? {})).toEqual(['u'])
  })

  it('resolves a `subsystems.<k>` {ref} through a set variable, anchored relatively', () => {
    write('nested/leaf.esm', leafDoc)
    process.env[SUB_DIR_VAR] = 'nested'
    const host = {
      esm: '1.0.0',
      metadata: { name: 'host' },
      models: {
        Host: {
          variables: { q: { type: 'unknown', units: '1', default: 0 } },
          equations: [{ lhs: { op: 'D', args: ['q'], wrt: 't' }, rhs: 0.0 }],
          subsystems: { S: { ref: `./\${${SUB_DIR_VAR}}/leaf.esm` } },
        },
      },
    } as unknown as EsmFile
    resolveSubsystemRefsSync(host, dir)
    const sub = (host.models as Record<string, { subsystems: Record<string, { ref?: string }> }>)
      .Host.subsystems.S
    expect(sub.ref).toBeUndefined()
  })

  it('agrees between the async prefetch cache key and the sync read', async () => {
    // The prefetch stores each document under `normalizeRef(ref, base)` and the
    // sync core looks it up with the same key. If only one of the two expanded,
    // the lookup would miss and fail closed with a RefLoadError.
    write('leaf.esm', leafDoc)
    process.env[LIB_DIR_VAR] = dir
    const host = {
      esm: '1.0.0',
      metadata: { name: 'host' },
      models: { Mounted: { ref: `\${${LIB_DIR_VAR}}/leaf.esm` } },
    } as unknown as EsmFile
    await resolveSubsystemRefs(host, dir)
    const models = host.models as Record<string, { ref?: string; variables?: object }>
    expect(models.Mounted.ref).toBeUndefined()
    expect(Object.keys(models.Mounted.variables ?? {})).toEqual(['u'])
  })

  it('leaves an unset variable literal and fails naming the `${VAR}` text', () => {
    const host = {
      esm: '1.0.0',
      metadata: { name: 'host' },
      models: { Mounted: { ref: `\${${LIB_DIR_VAR}}/leaf.esm` } },
    } as unknown as EsmFile
    expect(() => resolveSubsystemRefsSync(host, dir)).toThrow(new RegExp(`\\$\\{${LIB_DIR_VAR}\\}`))
  })

  it('does not expand a bare `$VAR`', () => {
    write('leaf.esm', leafDoc)
    process.env[LIB_DIR_VAR] = dir
    const host = {
      esm: '1.0.0',
      metadata: { name: 'host' },
      models: { Mounted: { ref: `$${LIB_DIR_VAR}/leaf.esm` } },
    } as unknown as EsmFile
    expect(() => resolveSubsystemRefsSync(host, dir)).toThrow(new RegExp(`\\$${LIB_DIR_VAR}`))
  })
})

describe('§4.7 `${VAR}` in the mount-declared-metaparameter walk (§9.7.6 site 4)', () => {
  // `collectMountDeclaredMetaparameters` reads each mounted file's top-level
  // `metaparameters` so a loader-API binding may name one the LEAF declares.
  // Without expansion the `${VAR}` ref is unreadable, the walk silently widens
  // nothing, and the binding is refused as a typo.
  const sizedLeaf = {
    esm: '1.0.0',
    metadata: { name: 'envref_sized_leaf' },
    metaparameters: { ENVREF_N: { type: 'integer', default: 8 } },
    index_sets: { cells: { kind: 'interval', size: 'ENVREF_N' } },
    models: {
      Leaf: {
        variables: { u: { type: 'unknown', units: '1', default: 1.0 } },
        equations: [
          { lhs: { op: 'D', args: ['u'], wrt: 't' }, rhs: { op: '*', args: [-1.0, 'u'] } },
        ],
      },
    },
  }
  const host = (ref: string) => ({
    esm: '1.0.0',
    metadata: { name: 'envref_meta_host' },
    models: { Mounted: { ref } },
  })

  it('accepts a loader-API binding for a name only the `${VAR}` leaf declares', () => {
    write('sized.esm', sizedLeaf)
    process.env[LIB_DIR_VAR] = dir
    const doc = host(`\${${LIB_DIR_VAR}}/sized.esm`)
    expect(() =>
      loadString(JSON.stringify(doc), { basePath: dir, metaparameters: { ENVREF_N: 4 } }),
    ).not.toThrow()
  })

  it('still refuses a binding no document in the assembly declares', () => {
    write('sized.esm', sizedLeaf)
    process.env[LIB_DIR_VAR] = dir
    const doc = host(`\${${LIB_DIR_VAR}}/sized.esm`)
    expect(() =>
      loadString(JSON.stringify(doc), { basePath: dir, metaparameters: { ENVREF_TYPO: 4 } }),
    ).toThrow(/template_import_unknown_name|ENVREF_TYPO/)
  })
})

describe('§10.10 `${VAR}` in a coupling_import ref', () => {
  it('resolves the library through a set variable', () => {
    write('coupling_lib.esm', couplingLibDoc)
    process.env[LIB_DIR_VAR] = dir
    const expanded = expandCouplingImports(
      couplingImporter(`\${${LIB_DIR_VAR}}/coupling_lib.esm`),
      { basePath: dir },
    )
    expect(expanded).toEqual([
      { type: 'variable_map', from: 'Src.sigma', to: 'Dst.sigma', transform: 'param_to_var' },
    ])
  })

  it('anchors an expanded RELATIVE ref against the importing document', () => {
    write('libs/coupling_lib.esm', couplingLibDoc)
    process.env[SUB_DIR_VAR] = 'libs'
    const expanded = expandCouplingImports(
      couplingImporter(`\${${SUB_DIR_VAR}}/coupling_lib.esm`),
      { basePath: dir },
    )
    expect(expanded).toHaveLength(1)
  })

  it('leaves an unset variable literal and fails naming the `${VAR}` text', () => {
    try {
      expandCouplingImports(couplingImporter(`\${${LIB_DIR_VAR}}/coupling_lib.esm`), {
        basePath: dir,
      })
      expect.unreachable('an unset ${VAR} must not resolve')
    } catch (e) {
      expect((e as { code?: string }).code).toBe('coupling_import_unresolved')
      expect(String((e as Error).message)).toContain(`\${${LIB_DIR_VAR}}`)
    }
  })

  it('does not expand a bare `$VAR`', () => {
    write('coupling_lib.esm', couplingLibDoc)
    process.env[LIB_DIR_VAR] = dir
    try {
      expandCouplingImports(couplingImporter(`$${LIB_DIR_VAR}/coupling_lib.esm`), {
        basePath: dir,
      })
      expect.unreachable('a bare $VAR must not expand')
    } catch (e) {
      expect(String((e as Error).message)).toContain(`$${LIB_DIR_VAR}`)
    }
  })
})
