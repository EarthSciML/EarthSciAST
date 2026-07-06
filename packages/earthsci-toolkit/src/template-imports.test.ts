/**
 * Tests for esm-spec §9.7 — template-library files,
 * `expression_template_imports`, and load-time `metaparameters`
 * (docs/content/rfcs/template-library-imports.md; esm-libraries-spec §2.1c).
 *
 * Drives the shared conformance fixtures under
 * tests/conformance/expression_templates/ and the resolver-level invalid
 * fixtures under tests/invalid/template_imports/, mirroring the Julia
 * reference suite (`EarthSciSerialization.jl/test/template_imports_test.jl`).
 */
import * as fs from 'node:fs'
import * as os from 'node:os'
import * as path from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { load, validateSchema } from './parse.js'
import { save } from './serialize.js'
import { resolveSubsystemRefs } from './ref-loading.js'
import {
  ExpressionTemplateError,
  MAX_TEMPLATE_EXPANSION_DEPTH,
  lowerExpressionTemplates,
} from './lower-expression-templates.js'
import {
  rejectTemplateImportsPreV08,
  resolveTemplateMachinery,
} from './template-imports.js'

const repoRoot = path.resolve(__dirname, '../../..')
const conf = (...parts: string[]) =>
  path.join(repoRoot, 'tests', 'conformance', 'expression_templates', ...parts)
const invalidDir = path.join(repoRoot, 'tests', 'invalid', 'template_imports')
const validDir = path.join(repoRoot, 'tests', 'valid')

/** Raw §9.7 pipeline (resolve → lower), mirroring the Julia golden generator. */
function expandRaw(fixturePath: string): unknown {
  const raw = JSON.parse(fs.readFileSync(fixturePath, 'utf8'))
  const resolved = resolveTemplateMachinery(raw, path.dirname(fixturePath), { validateSchema })
  return lowerExpressionTemplates(resolved ?? raw)
}

const golden = (goldenPath: string): unknown => JSON.parse(fs.readFileSync(goldenPath, 'utf8'))

function errCode(f: () => unknown): string | null {
  try {
    f()
    return null
  } catch (e) {
    if (e instanceof ExpressionTemplateError) return e.code
    throw e
  }
}

async function errCodeAsync(f: () => Promise<unknown>): Promise<string | null> {
  try {
    await f()
    return null
  } catch (e) {
    if (e instanceof ExpressionTemplateError) return e.code
    throw e
  }
}

/** load() from a fixture path with the fixture's directory as basePath. */
function loadPath(p: string, metaparameters?: Record<string, number>) {
  return load(fs.readFileSync(p, 'utf8'), { basePath: path.dirname(p), metaparameters })
}

describe('template-library imports + metaparameters (esm-spec §9.7)', () => {
  it('import_smoke: the §9.7.7 four-file layering matches the golden', () => {
    expect(expandRaw(conf('import_smoke', 'fixture.esm'))).toEqual(
      golden(conf('import_smoke', 'expanded.esm')),
    )

    // Typed happy path: index sets merged and folded at the edge bindings.
    const f = loadPath(conf('import_smoke', 'fixture.esm')) as any
    expect(f.index_sets.lon.size).toBe(288)
    expect(f.index_sets.lat.size).toBe(181)
    // D(c, wrt: lon) lowered to the makearray rule body; D(c, wrt: t) not.
    const eq = f.models.Advection.equations[0]
    expect(eq.lhs.op).toBe('D')
    expect(eq.rhs.args[1].op).toBe('makearray')
  })

  it('import_diamond: deep-equal dedup at first occurrence', () => {
    expect(expandRaw(conf('import_diamond', 'fixture.esm'))).toEqual(
      golden(conf('import_diamond', 'expanded.esm')),
    )
    const f = loadPath(conf('import_diamond', 'fixture.esm')) as any
    expect(f.index_sets.cells.size).toBe(10) // NC default, deduped once
  })

  it('aggregate_int_ratio_golden: integer ratio inside a nested aggregate stays integer (§5.5.3.1)', () => {
    // A `coord` template body cos(pi·aggregate((i−1/2)·(1/8))) expands so an
    // integer ratio {op:/,args:[1,8]} lands inside a nested, float-heavy
    // aggregate expr. Julia's JSON3 reader widened it to `1.0/8.0`; every other
    // binding keeps `[1,8]`, so the committed golden is `[1,8]` and this binding
    // must reproduce it.
    expect(expandRaw(conf('aggregate_int_ratio_golden', 'fixture.esm'))).toEqual(
      golden(conf('aggregate_int_ratio_golden', 'expanded.esm')),
    )
    const d = expandRaw(conf('aggregate_int_ratio_golden', 'fixture.esm')) as any
    expect(d.models.M.variables.dx.expression).toEqual({ op: '/', args: [1, 8] })
    expect(
      d.models.M.variables.c0.expression.args[0].args[1].expr.args[1],
    ).toEqual({ op: '/', args: [1, 8] })
  })

  it('import_rename_two_instances: one grid family, two prefixed instances (§9.7.7)', () => {
    // prefix renames index set / templates / the rule's match `wrt` transitively;
    // per-edge bindings instantiate N; each rule instance fires only on its own
    // axis (fine.x vs coarse.x) with per-instance ranges and spacings.
    expect(expandRaw(conf('import_rename_two_instances', 'fixture.esm'))).toEqual(
      golden(conf('import_rename_two_instances', 'expanded.esm')),
    )
    const f = loadPath(conf('import_rename_two_instances', 'fixture.esm')) as any
    expect(f.index_sets['fine.x'].size).toBe(16)
    expect(f.index_sets['coarse.x'].size).toBe(8)
    // Fine equation's interior range folded to [2, 15], coarse to [2, 7].
    expect(f.models.TwoGrids.equations[0].rhs.ranges.i).toEqual([2, 15])
    expect(f.models.TwoGrids.equations[1].rhs.ranges.i).toEqual([2, 7])
  })

  it('import_where_rename_two_instances: rename carries where.shape (§9.7.7)', () => {
    // A where-constrained div rule imported twice under prefix has its
    // where.F.shape rewritten x -> meshA.x / meshB.x in lockstep with the index
    // set, so each instance registers and fires only on its own field. Without
    // the rewrite this raised template_constraint_unknown_index_set.
    const d = expandRaw(conf('import_where_rename_two_instances', 'fixture.esm')) as any
    expect(d).toEqual(golden(conf('import_where_rename_two_instances', 'expanded.esm')))
    const va = d.models.TwoGrids.variables.div_A.expression
    const vb = d.models.TwoGrids.variables.div_B.expression
    expect(va.op).toBe('*') // both div nodes lowered
    expect(vb.op).toBe('*')
    expect(va.args[0].op).toBe('/')
    expect(va.args[0].args[1]).toBe(16)
    expect(vb.args[0].args[1]).toBe(8)
    expect(va.args[1]).toBe('F_A')
    expect(vb.args[1]).toBe('F_B')
    const f = loadPath(conf('import_where_rename_two_instances', 'fixture.esm')) as any
    expect(f.index_sets['meshA.x'].size).toBe(16)
    expect(f.index_sets['meshB.x'].size).toBe(8)
  })

  it('import_where_rename_unknown_index_set: bad where set after rename rejected', () => {
    // A where shape naming a set the library never declares survives the rename
    // as spelled and is rejected at rule registration (esm-spec §9.6.6).
    expect(errCode(() => loadPath(conf('import_where_rename_unknown_index_set', 'fixture.esm')))).toBe(
      'template_constraint_unknown_index_set',
    )
  })

  it('import_rebind_keyed_factors: free-name rebind rewrites body + registry factors (§9.7.7)', () => {
    // rebind row_count/row_cols/row_w -> meshA_* transitively through the ragged
    // index set's offsets/values AND the rule body; the consumer's own
    // `row_count` parameter coexists (un-reserved).
    expect(expandRaw(conf('import_rebind_keyed_factors', 'fixture.esm'))).toEqual(
      golden(conf('import_rebind_keyed_factors', 'expanded.esm')),
    )
    const f = loadPath(conf('import_rebind_keyed_factors', 'fixture.esm')) as any
    expect(f.index_sets.nz_of_row.offsets).toBe('meshA_count')
    expect(f.index_sets.nz_of_row.values).toBe('meshA_cols')
    // rowsum(u) lowered by the rebound rule instance to the aggregate over
    // meshA_cols / meshA_w; the consumer's local `row_count` parameter survives.
    expect(f.models.Sparse.variables.total.expression.args).toEqual(['u', 'meshA_cols', 'meshA_w'])
    expect(f.models.Sparse.variables.row_count.type).toBe('parameter')
  })

  it('import_rename_diamond: rename-aware dedup + distinct instances (§9.7.4/§9.7.7)', () => {
    // Edges 1 & 2 (prefix a, NC 6) dedupe deep-equal; edge 3 (prefix b, NC 9)
    // registers distinctly. Both axis-less rule instances match; the §9.7.4
    // effective order breaks the equal-priority tie, so a wins (y = 6 * x).
    expect(expandRaw(conf('import_rename_diamond', 'fixture.esm'))).toEqual(
      golden(conf('import_rename_diamond', 'expanded.esm')),
    )
    const f = loadPath(conf('import_rename_diamond', 'fixture.esm')) as any
    expect(f.index_sets['a.cells'].size).toBe(6)
    expect(f.index_sets['b.cells'].size).toBe(9)
    expect(f.models.Diamond.variables.y.expression).toEqual({ op: '*', args: [6, 'x'] })
  })

  it('effective order: import order pins the tie-break, priority flips it', () => {
    expect(expandRaw(conf('import_order_determinism', 'fixture_import_order.esm'))).toEqual(
      golden(conf('import_order_determinism', 'expanded_import_order.esm')),
    )
    expect(expandRaw(conf('import_order_determinism', 'fixture_priority_override.esm'))).toEqual(
      golden(conf('import_order_determinism', 'expanded_priority_override.esm')),
    )
    // Winner sanity, independent of the goldens: earlier import wins the
    // equal-priority tie (2*x); explicit priority 10 out-ranks it (5*x).
    const d1 = expandRaw(conf('import_order_determinism', 'fixture_import_order.esm')) as any
    expect(d1.models.M.variables.y.expression.args[0]).toBe(2)
    const d2 = expandRaw(conf('import_order_determinism', 'fixture_priority_override.esm')) as any
    expect(d2.models.M.variables.y.expression.args[0]).toBe(5)
  })

  it('valid suite: library file + minimal consumer', () => {
    // A model-less template-library document loads (esm-spec §9.7.1);
    // round-trip strips every §9.7 construct, leaving the folded registry.
    const lib = loadPath(path.join(validDir, 'template_import_lib.esm')) as any
    expect(lib.models).toBeUndefined()
    expect(lib.index_sets.cells.size).toBe(8) // size "N" folded by default
    expect(lib.expression_templates).toBeUndefined()
    expect(lib.metaparameters).toBeUndefined()
    // Loader-API binding overrides the default on the library itself.
    const lib12 = loadPath(path.join(validDir, 'template_import_lib.esm'), { N: 12 }) as any
    expect(lib12.index_sets.cells.size).toBe(12)

    const m = loadPath(path.join(validDir, 'template_import_minimal.esm')) as any
    expect(m.index_sets.cells.size).toBe(8) // §9.7.5 merge into consumer
    // scale_by_n(x) lowered by the imported match rule to x * 8 (the
    // zero-parameter n_cells body composed and N folded at registration).
    expect(m.models.M.variables.y.expression).toEqual({ op: '*', args: ['x', 8] })
  })

  it('metaparameter_resolutions: subsystem-ref bindings (§9.7.6 site 3)', async () => {
    for (const [wrapper, goldenName, n] of [
      ['wrapper_n4.esm', 'expanded_n4.esm', 4],
      ['wrapper_n8.esm', 'expanded_n8.esm', 8],
    ] as const) {
      const wrapperPath = conf('metaparameter_resolutions', wrapper)
      const f = loadPath(wrapperPath) as any
      await resolveSubsystemRefs(f, path.dirname(wrapperPath))
      const sub = f.models.Sweep.subsystems.Problem
      // Expression position: bare "N" substituted as an integer literal.
      expect(sub.variables.npts.expression).toBe(n)
      // Expression-position division stays an AST division (no folding).
      expect(sub.variables.half.expression).toEqual({ op: '/', args: [n, 2] })
      // Structural site: the aggregate dense range folded exactly.
      expect(sub.variables.ramp.expression.op).toBe('aggregate')
      expect(sub.variables.ramp.expression.ranges.i).toEqual([1, n / 2])
      // Typed round-trip matches the golden, fully structurally.
      const emitted = JSON.parse(save(f))
      expect(emitted).toEqual(
        golden(conf('metaparameter_resolutions', goldenName)),
      )
    }
  })

  it('loader-API bindings (§9.7.6 site 4) and defaults (site 5)', () => {
    const problem = conf('metaparameter_resolutions', 'problem.esm')
    const fdef = loadPath(problem) as any
    expect(fdef.models.Problem.variables.npts.expression).toBe(2) // default
    const fapi = loadPath(problem, { N: 6 }) as any
    expect(fapi.models.Problem.variables.npts.expression).toBe(6) // API > default
    expect(fapi.models.Problem.variables.ramp.expression.ranges.i).toEqual([1, 3])
    // Binding a name the document does not declare is an error.
    expect(errCode(() => loadPath(problem, { Q: 1 }))).toBe('template_import_unknown_name')
  })

  it('round-trip emits the expanded, folded form (§9.7.6)', () => {
    const f = loadPath(conf('import_smoke', 'fixture.esm'))
    const text = save(f)
    expect(text).not.toContain('expression_template_imports')
    expect(text).not.toContain('metaparameters')
    expect(text).not.toContain('expression_templates')
    expect(text).not.toContain('apply_expression_template')
    const reloaded = load(text) as any
    expect(reloaded.index_sets.lon.size).toBe(288)
    expect(reloaded.models.Advection.equations[0].rhs.args[1].op).toBe('makearray')
  })

  it('invalid fixtures: every §9.7 diagnostic code, machine-checked', async () => {
    const expected = JSON.parse(
      fs.readFileSync(path.join(repoRoot, 'tests', 'invalid', 'expected_errors.json'), 'utf8'),
    ) as Record<string, { resolver_only?: boolean; resolver_error_code?: string }>
    const fixtures = fs
      .readdirSync(invalidDir)
      .filter((f) => f.endsWith('.esm'))
      .sort()
    expect(fixtures.length).toBeGreaterThan(0)
    const seenCodes = new Set<string>()
    for (const fname of fixtures) {
      const entry = expected[fname]
      expect(entry, `expected_errors.json entry for ${fname}`).toBeDefined()
      if (!entry) continue
      expect(entry.resolver_only).toBe(true)
      const want = entry.resolver_error_code!
      const got = await errCodeAsync(async () => {
        const file = loadPath(path.join(invalidDir, fname))
        // Subsystem-ref diagnostics (subsystem_ref_is_template_library,
        // §9.7.6 site-3 binding errors) surface during ref resolution.
        await resolveSubsystemRefs(file, invalidDir)
        return file
      })
      expect(got, fname).toBe(want)
      seenCodes.add(want)
    }
    // The fixture set exercises the full §9.6.6 §9.7 code table (the 12th,
    // template_import_unresolved, is exercised below — a missing file is
    // not representable as a fixture).
    for (const code of [
      'template_import_version_too_old',
      'template_import_not_library',
      'subsystem_ref_is_template_library',
      'template_import_cycle',
      'template_import_name_conflict',
      'template_import_unknown_name',
      'template_import_index_set_conflict',
      'apply_expression_template_recursive_body',
      'template_body_expansion_too_deep',
      'metaparameter_unbound',
      'metaparameter_type_error',
      'metaparameter_name_conflict',
    ]) {
      expect(seenCodes.has(code), code).toBe(true)
    }
  })
})

// ---------------------------------------------------------------------------
// Unit-level behavior over generated files
// ---------------------------------------------------------------------------

describe('template imports: unit-level behavior (esm-spec §9.7)', () => {
  let tmpDir: string

  beforeAll(() => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'esm-tpl-import-'))
  })

  afterAll(() => {
    fs.rmSync(tmpDir, { recursive: true, force: true })
  })

  const modelJson = (extraModelFields: string, topFields = '') => `
  {
    "esm": "0.8.0",
    "metadata": {"name": "t"},${topFields}
    "models": {
      "M": {${extraModelFields}
        "variables": {"x": {"type": "state", "units": "1", "default": 0.5}},
        "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                       "rhs": {"op": "-", "args": ["x"]}}]
      }
    }
  }
  `

  const loadStr = (text: string, metaparameters?: Record<string, number>) =>
    load(text, { basePath: tmpDir, metaparameters })

  const errCode = (f: () => unknown): string | null => {
    try {
      f()
      return null
    } catch (e) {
      if (e instanceof ExpressionTemplateError) return e.code
      throw e
    }
  }

  it('template_import_unresolved: missing / unparsable ref', () => {
    expect(
      errCode(() =>
        loadStr(modelJson(`
          "expression_template_imports": [{"ref": "./nope.esm"}],`)),
      ),
    ).toBe('template_import_unresolved')
    fs.writeFileSync(path.join(tmpDir, 'junk.esm'), '{not json')
    expect(
      errCode(() =>
        loadStr(modelJson(`
          "expression_template_imports": [{"ref": "./junk.esm"}],`)),
      ),
    ).toBe('template_import_unresolved')
  })

  it('`only` filters visibility, not the target internal wiring', () => {
    fs.writeFileSync(
      path.join(tmpDir, 'lib_only.esm'),
      JSON.stringify({
        esm: '0.8.0',
        metadata: { name: 'lib' },
        expression_templates: {
          t_inner: { params: [], body: 7 },
          t_keep: {
            params: [],
            body: {
              op: '*',
              args: [
                2,
                { op: 'apply_expression_template', args: [], name: 't_inner', bindings: {} },
              ],
            },
          },
          t_drop: { params: [], body: 9 },
        },
      }),
    )
    // t_keep's body reference to t_inner resolved in the LIBRARY's own
    // scope, so importing only t_keep still yields 2 * 7.
    const raw = JSON.parse(
      modelJson(`
        "expression_template_imports": [{"ref": "./lib_only.esm", "only": ["t_keep"]}],`),
    )
    const resolved = resolveTemplateMachinery(raw, tmpDir, { validateSchema }) as any
    const tpl = resolved.models.M.expression_templates
    expect(Object.keys(tpl)).toEqual(['t_keep'])
    expect(tpl.t_keep.body).toEqual({ op: '*', args: [2, 7] })
    // Referencing a filtered-out name from an expression position fails.
    expect(
      errCode(() =>
        loadStr(modelJson(`
          "expression_template_imports": [{"ref": "./lib_only.esm", "only": ["t_keep"]}],
          "expression_templates": {"local_uses_drop": {"params": [],
            "body": {"op": "apply_expression_template", "args": [], "name": "t_drop", "bindings": {}}}},`)),
      ),
    ).toBe('apply_expression_template_unknown_template')
  })

  it('diamond with conflicting edge bindings is rejected (§9.7.6)', () => {
    fs.writeFileSync(
      path.join(tmpDir, 'grid.esm'),
      JSON.stringify({
        esm: '0.8.0',
        metadata: { name: 'grid' },
        metaparameters: { NC: { type: 'integer' } },
        index_sets: { cells: { kind: 'interval', size: 'NC' } },
        expression_templates: { nc: { params: [], body: 'NC' } },
      }),
    )
    expect(
      errCode(() =>
        loadStr(modelJson(`
          "expression_template_imports": [
            {"ref": "./grid.esm", "bindings": {"NC": 4}},
            {"ref": "./grid.esm", "bindings": {"NC": 8}}],`)),
      ),
    ).toMatch(/^template_import_(name|index_set)_conflict$/)
    // Equal instantiation on both edges dedups cleanly.
    const f = loadStr(
      modelJson(`
        "expression_template_imports": [
          {"ref": "./grid.esm", "bindings": {"NC": 4}},
          {"ref": "./grid.esm", "bindings": {"NC": 4}}],`),
    ) as any
    expect(f.index_sets.cells.size).toBe(4)
  })

  it('edge bindings: unknown names are rejected', () => {
    fs.writeFileSync(
      path.join(tmpDir, 'lib_n.esm'),
      JSON.stringify({
        esm: '0.8.0',
        metadata: { name: 'lib' },
        metaparameters: { N: { type: 'integer', default: 8 } },
        expression_templates: { n: { params: [], body: 'N' } },
      }),
    )
    expect(
      errCode(() =>
        loadStr(modelJson(`
          "expression_template_imports": [{"ref": "./lib_n.esm", "bindings": {"Q": 1}}],`)),
      ),
    ).toBe('template_import_unknown_name')
    // A non-integer binding is rejected at the resolver level
    // (metaparameter_type_error); note the schema also rejects it earlier
    // in the full load() pipeline (TemplateImport.bindings is
    // integer-typed).
    const raw = JSON.parse(
      modelJson(`
        "expression_template_imports": [{"ref": "./lib_n.esm", "bindings": {"N": 2.5}}],`),
    )
    expect(errCode(() => resolveTemplateMachinery(raw, tmpDir, {}))).toBe(
      'metaparameter_type_error',
    )
  })

  it('metaparameter fold: ranges / regions / size, exact arithmetic', () => {
    const f = loadStr(`
    {
      "esm": "0.8.0",
      "metadata": {"name": "fold"},
      "metaparameters": {"N": {"type": "integer", "default": 6}},
      "index_sets": {"cells": {"kind": "interval", "size": {"op": "*", "args": ["N", 2]}}},
      "models": {
        "M": {
          "variables": {
            "x": {"type": "state", "units": "1", "default": 0.5},
            "agg": {"type": "observed", "units": "1",
              "expression": {"op": "aggregate", "output_idx": ["i"], "args": ["x"],
                "ranges": {"i": [1, {"op": "-", "args": ["N", 1]}]},
                "expr": {"op": "*", "args": ["x", "i"]}}},
            "ma": {"type": "observed", "units": "1",
              "expression": {"op": "makearray", "args": [],
                "regions": [[[{"op": "/", "args": ["N", 2]}, "N"]]],
                "values": [1.5]}}
          },
          "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                         "rhs": {"op": "-", "args": ["x"]}}]
        }
      }
    }
    `) as any
    expect(f.index_sets.cells.size).toBe(12)
    expect(f.models.M.variables.agg.expression.ranges.i).toEqual([1, 5])
    expect(f.models.M.variables.ma.expression.regions).toEqual([[[3, 6]]])
  })

  it('inexact division and unbound names are rejected in structural sites', () => {
    expect(
      errCode(() =>
        loadStr(
          modelJson(
            '',
            `
            "metaparameters": {"NX": {"type": "integer", "default": 5}},
            "index_sets": {"half": {"kind": "interval", "size": {"op": "/", "args": ["NX", 2]}}},`,
          ),
        ),
      ),
    ).toBe('metaparameter_type_error')
    expect(
      errCode(() =>
        loadStr(
          modelJson(
            '',
            `
            "metaparameters": {"NX": {"type": "integer"}},`,
          ),
        ),
      ),
    ).toBe('metaparameter_unbound')
  })

  it('expression-position substitution never folds', () => {
    const f = loadStr(`
    {
      "esm": "0.8.0",
      "metadata": {"name": "subst"},
      "metaparameters": {"N": {"type": "integer", "default": 144}},
      "models": {
        "M": {
          "variables": {
            "x": {"type": "state", "units": "1", "default": 0.5},
            "dlon": {"type": "observed", "units": "1",
                     "expression": {"op": "/", "args": [360, "N"]}}
          },
          "equations": [{"lhs": {"op": "D", "args": ["x"], "wrt": "t"},
                         "rhs": {"op": "-", "args": ["x"]}}]
        }
      }
    }
    `) as any
    expect(f.models.M.variables.dlon.expression).toEqual({ op: '/', args: [360, 144] })
  })

  const chainDoc = (n: number) => {
    const tpl: Record<string, unknown> = {}
    for (let i = 1; i <= n; i++) {
      const name = `c_${String(i).padStart(2, '0')}`
      tpl[name] =
        i === n
          ? { params: [], body: 1 }
          : {
              params: [],
              body: {
                op: 'apply_expression_template',
                args: [],
                name: `c_${String(i + 1).padStart(2, '0')}`,
                bindings: {},
              },
            }
    }
    return {
      esm: '0.8.0',
      metadata: { name: 'chain' },
      models: {
        M: {
          expression_templates: tpl,
          variables: { x: { type: 'state', default: 0.5 } },
          equations: [
            { lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: { op: '-', args: ['x'] } },
          ],
        },
      },
    }
  }

  it('body composition: acyclic DAG inlines; depth bound is exact', () => {
    // A 3-deep local chain inlines through the §9.6.3 fixpoint untouched.
    const doc = {
      esm: '0.8.0',
      metadata: { name: 'chain3' },
      models: {
        M: {
          expression_templates: {
            c1: {
              params: [],
              body: {
                op: '+',
                args: [1, { op: 'apply_expression_template', args: [], name: 'c2', bindings: {} }],
              },
            },
            c2: {
              params: [],
              body: {
                op: '+',
                args: [2, { op: 'apply_expression_template', args: [], name: 'c3', bindings: {} }],
              },
            },
            c3: { params: [], body: 3 },
          },
          variables: {
            x: { type: 'state', units: '1', default: 0.5 },
            y: {
              type: 'observed',
              units: '1',
              expression: { op: 'apply_expression_template', args: [], name: 'c1', bindings: {} },
            },
          },
          equations: [
            { lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: { op: '-', args: ['x'] } },
          ],
        },
      },
    }
    const out = lowerExpressionTemplates(doc) as any
    expect(out.models.M.variables.y.expression).toEqual({
      op: '+',
      args: [1, { op: '+', args: [2, 3] }],
    })

    // Exactly MAX_TEMPLATE_EXPANSION_DEPTH templates chain: accepted;
    // one more: template_body_expansion_too_deep (the shared generated
    // fixture pins the reject side; this pins the boundary).
    expect(() => lowerExpressionTemplates(chainDoc(MAX_TEMPLATE_EXPANSION_DEPTH))).not.toThrow()
    expect(errCode(() => lowerExpressionTemplates(chainDoc(MAX_TEMPLATE_EXPANSION_DEPTH + 1)))).toBe(
      'template_body_expansion_too_deep',
    )

    // A body may not reference a `match` rule by name.
    const matchRef = JSON.parse(
      modelJson(`
        "expression_templates": {
          "rule": {"params": ["f"], "match": {"op": "lowerme", "args": ["f"]},
                   "body": {"op": "*", "args": [2, "f"]}},
          "uses_rule": {"params": [], "body": {"op": "apply_expression_template",
                        "args": [], "name": "rule", "bindings": {"f": 1}}}
        },`),
    )
    expect(errCode(() => lowerExpressionTemplates(matchRef))).toBe(
      'apply_expression_template_unknown_template',
    )

    // A `match` pattern may not contain apply nodes.
    const matchWithApply = JSON.parse(
      modelJson(`
        "expression_templates": {
          "frag": {"params": [], "body": 1},
          "rule": {"params": ["f"],
                   "match": {"op": "lowerme", "args": [{"op": "apply_expression_template",
                             "args": [], "name": "frag", "bindings": {}}]},
                   "body": {"op": "*", "args": [2, "f"]}}
        },`),
    )
    expect(errCode(() => lowerExpressionTemplates(matchWithApply))).toBe(
      'apply_expression_template_invalid_declaration',
    )
  })

  it('version gate helper flags every §9.7 construct', () => {
    for (const snippet of [
      '"metaparameters": {"N": {"type": "integer"}},',
      '"expression_templates": {"t": {"params": [], "body": 1}},',
    ]) {
      const doc = JSON.parse(`
      {"esm": "0.7.0", "metadata": {"name": "old"},${snippet}
       "models": {"M": {"variables": {"x": {"type": "state", "default": 0.5}},
                        "equations": []}}}`)
      expect(errCode(() => rejectTemplateImportsPreV08(doc))).toBe(
        'template_import_version_too_old',
      )
    }
    // 0.8.0 files pass the gate.
    const ok = JSON.parse(`
    {"esm": "0.8.0", "metadata": {"name": "new"},
     "metaparameters": {"N": {"type": "integer", "default": 1}},
     "expression_templates": {"t": {"params": [], "body": 1}}}`)
    expect(() => rejectTemplateImportsPreV08(ok)).not.toThrow()
  })
})
