/**
 * Tests for metaparameter-EXPRESSION binding values at import / subsystem
 * edges (esm-spec §9.7.6). Mirrors the Python reference
 * `pkg/earthsci-ast-py/tests/test_metaparam_expr_bindings.py`.
 *
 * Before this feature both `TemplateImport.bindings` and `SubsystemRef.bindings`
 * accepted only integer literals, so a child metaparameter could be unified with
 * a parent one by *rename* (name→name) but never *derived* as an arithmetic
 * combination (`NTGT = NX*NY`). This relaxes the binding VALUE to a metaparameter
 * expression (integer literal, name, or `{op: +|-|*|/, args}`) whose free names
 * resolve in the importing document's metaparameter scope:
 *
 *  - import edge — the value is carried symbolically into the child and folds
 *    when the importing document closes (the importer's names are not yet closed
 *    at edge time, innermost-first);
 *  - subsystem / model edge — the referenced document is resolved to concrete
 *    integers at the mount, so the value folds against the mounting document's
 *    already-closed metaparameter environment (in this binding, `load`'s
 *    metaparameter substitution closes the parent names into the ref bindings
 *    before `resolveSubsystemRefs` folds them).
 */
import * as fs from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { load } from './parse.js'
import { resolveSubsystemRefs } from './ref-loading.js'
import { EsmMachineryError } from './lower-expression-templates.js'
import { evalMetaExpr, requireMetaExpr, resolveTemplateMachinery } from './template-imports.js'

let dir: string

beforeAll(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'esm-metaexpr-'))
})

afterAll(() => {
  fs.rmSync(dir, { recursive: true, force: true })
})

function write(name: string, doc: unknown): string {
  const p = path.join(dir, name)
  fs.writeFileSync(p, JSON.stringify(doc))
  return p
}

/** Return the thrown EsmMachineryError code, or null on success. */
function errCode(fn: () => unknown): string | null {
  try {
    fn()
    return null
  } catch (e) {
    if (e instanceof EsmMachineryError) return e.code
    throw e
  }
}

async function errCodeAsync(fn: () => Promise<unknown>): Promise<string | null> {
  try {
    await fn()
    return null
  } catch (e) {
    if (e instanceof EsmMachineryError) return e.code
    throw e
  }
}

// --------------------------------------------------------------------------
// 1. The folding / validation helpers
// --------------------------------------------------------------------------

describe('metaparameter-expression helpers (§9.7.6)', () => {
  it('evalMetaExpr folds a product', () => {
    expect(evalMetaExpr({ op: '*', args: ['NX', 'NY'] }, { NX: 18, NY: 20 }, 't')).toBe(360)
  })

  it('evalMetaExpr resolves a bare name and an integer literal', () => {
    expect(evalMetaExpr('NX', { NX: 7 }, 't')).toBe(7)
    expect(evalMetaExpr(5, {}, 't')).toBe(5)
  })

  it('evalMetaExpr folds nested arithmetic', () => {
    // (NX + 2) * NY  with NX=4, NY=3  ->  18
    const expr = { op: '*', args: [{ op: '+', args: ['NX', 2] }, 'NY'] }
    expect(evalMetaExpr(expr, { NX: 4, NY: 3 }, 't')).toBe(18)
  })

  it('requireMetaExpr returns the value unfolded', () => {
    const expr = { op: '*', args: ['NX', 'NY'] }
    expect(requireMetaExpr(expr, 't')).toEqual(expr) // unchanged, unfolded
  })

  it.each([
    // Bad op is caught structurally at the edge, even with a symbolic arg.
    [{ op: '%', args: ['NX', 2] }, {}, 'metaparameter_type_error'],
    [{ op: '*', args: [] }, {}, 'metaparameter_type_error'],
    [1.5, {}, 'metaparameter_type_error'],
    // Unknown free name is caught at fold time.
    [{ op: '*', args: ['NZ', 'NY'] }, { NX: 18, NY: 20 }, 'template_import_unknown_name'],
    // Inexact division is rejected.
    [{ op: '/', args: ['NX', 7] }, { NX: 18 }, 'metaparameter_type_error'],
  ] as [unknown, Record<string, number>, string][])(
    'helper diagnostics: %o -> %s',
    (expr, env, code) => {
      expect(
        errCode(() => {
          requireMetaExpr(expr, 't')
          evalMetaExpr(expr, env, 't')
        }),
      ).toBe(code)
    },
  )
})

// --------------------------------------------------------------------------
// 2. Import edge: GX = NX*NY carried symbolically, folds at the doc close
// --------------------------------------------------------------------------

function libGrid() {
  return {
    esm: '0.8.0',
    metadata: { name: 'lib_grid' },
    metaparameters: { GX: { type: 'integer', default: 2 } },
    index_sets: { cells: { kind: 'interval', size: 'GX' } },
    expression_templates: {
      one: { params: [], body: { op: 'const', value: 1, args: [] } },
    },
  }
}

function modelImporting(binding: unknown) {
  return {
    esm: '0.8.0',
    metadata: { name: 'model_import' },
    metaparameters: {
      NX: { type: 'integer', default: 3 },
      NY: { type: 'integer', default: 4 },
    },
    models: {
      M: {
        expression_template_imports: [{ ref: './lib_grid.esm', bindings: { GX: binding } }],
        variables: { a: { type: 'parameter', shape: ['cells'], default: 0.0 } },
        equations: [],
      },
    },
  }
}

describe('import-edge metaparameter-expression bindings (§9.7.6 site 1)', () => {
  it('a product binding GX = NX*NY folds at the importing document close', () => {
    write('lib_grid.esm', libGrid())
    // explicit API bindings
    const out = resolveTemplateMachinery(modelImporting({ op: '*', args: ['NX', 'NY'] }), dir, {
      metaparameters: { NX: 3, NY: 4 },
    }) as any
    expect(out.index_sets.cells.size).toBe(12)
    // via metaparameter defaults (3 * 4)
    const out2 = resolveTemplateMachinery(
      modelImporting({ op: '*', args: ['NX', 'NY'] }),
      dir,
    ) as any
    expect(out2.index_sets.cells.size).toBe(12)
  })
})

// --------------------------------------------------------------------------
// 3. Subsystem / model edge: NTGT = NX*NY folds at the mount
// --------------------------------------------------------------------------

function childRegrid() {
  return {
    esm: '0.8.0',
    metadata: { name: 'child_regrid' },
    metaparameters: {
      NX: { type: 'integer', default: 2 },
      NY: { type: 'integer', default: 2 },
      NTGT: { type: 'integer', default: 4 },
    },
    index_sets: {
      tgt_cells: { kind: 'interval', size: 'NTGT' },
      gx: { kind: 'interval', size: 'NX' },
      gy: { kind: 'interval', size: 'NY' },
    },
    models: {
      Regrid: {
        variables: {
          field: { type: 'parameter', shape: ['tgt_cells'], default: 0.0 },
          grid: { type: 'parameter', shape: ['gx', 'gy'], default: 0.0 },
        },
        equations: [],
      },
    },
  }
}

// The TS binding resolves refs nested under `subsystems` (not top-level model
// refs), so the mounting document wraps the ref in a `Mount` model; this mirrors
// the existing site-3 conformance fixture (wrapper_n4.esm -> problem.esm).
function parentMount(bindings: unknown) {
  return {
    esm: '0.8.0',
    metadata: { name: 'parent_mount' },
    metaparameters: {
      NX: { type: 'integer', default: 18 },
      NY: { type: 'integer', default: 20 },
    },
    models: {
      Mount: {
        variables: {},
        equations: [],
        subsystems: {
          Regrid: { ref: './child_regrid.esm', bindings },
        },
      },
    },
  }
}

function loadParent(doc: unknown, metaparameters?: Record<string, number>) {
  return load(JSON.stringify(doc), { basePath: dir, metaparameters }) as any
}

describe('subsystem-edge metaparameter-expression bindings (§9.7.6 site 3)', () => {
  it('a product binding NTGT = NX*NY folds to a concrete size at the mount', async () => {
    write('child_regrid.esm', childRegrid())
    const f = loadParent(
      parentMount({ NX: 'NX', NY: 'NY', NTGT: { op: '*', args: ['NX', 'NY'] } }),
      { NX: 18, NY: 20 },
    )
    await resolveSubsystemRefs(f, dir)
    expect(f.index_sets.tgt_cells.size).toBe(360) // NX*NY, derived — not a literal
    expect(f.index_sets.gx.size).toBe(18)
    expect(f.index_sets.gy.size).toBe(20)
  })

  it('the product binding folds against the parent defaults when no API bindings given', async () => {
    write('child_regrid.esm', childRegrid())
    const f = loadParent(parentMount({ NX: 'NX', NY: 'NY', NTGT: { op: '*', args: ['NX', 'NY'] } }))
    await resolveSubsystemRefs(f, dir) // parent defaults NX=18, NY=20
    expect(f.index_sets.tgt_cells.size).toBe(360)
  })

  it('plain-integer bindings keep working (regression)', async () => {
    write('child_regrid.esm', childRegrid())
    const f = loadParent(parentMount({ NX: 5, NY: 6, NTGT: 30 }))
    await resolveSubsystemRefs(f, dir)
    expect(f.index_sets.tgt_cells.size).toBe(30)
    expect(f.index_sets.gx.size).toBe(5)
    expect(f.index_sets.gy.size).toBe(6)
  })

  it('an unknown parent free name in a binding expression fails loud at the edge', async () => {
    write('child_regrid.esm', childRegrid())
    const doc = parentMount({ NX: 'NX', NY: 'NX', NTGT: { op: '*', args: ['NX', 'NZZ'] } })
    const code = await errCodeAsync(async () => {
      const f = loadParent(doc, { NX: 18 })
      await resolveSubsystemRefs(f, dir)
    })
    expect(code).toBe('template_import_unknown_name')
  })
})
