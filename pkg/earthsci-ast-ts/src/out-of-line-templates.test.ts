/**
 * Conformance tests for the out-of-line-expression-templates RFC (Option B,
 * reference-preserving expression templates): esm-spec §9.6.4 (rules 1-8),
 * §9.6.7 (new fixtures), §9.6.9 (validation discharge), §10.7 (flatten registry
 * merge). Mirrors the Julia reference test
 * `pkg/EarthSciAST.jl/test/out_of_line_templates_test.jl`.
 *
 * Drives tests/conformance/expression_templates/{emit_*, eager_*, opacity_*,
 * per_instantiation_validation, flatten_registry_merge}.
 */
import * as fs from 'node:fs'
import * as path from 'node:path'
import { describe, it, expect } from 'vitest'
import {
  lowerExpressionTemplates,
  expandDocument,
  emitEsmString,
  flattenTemplateRegistries,
  EsmMachineryError,
} from './lower-expression-templates.js'
import { resolveTemplateMachinery, emitDocument } from './template-imports.js'
import { fixturesDir } from './test-helpers.js'

const conf = (...parts: string[]) => fixturesDir('conformance', 'expression_templates', ...parts)

/** Normalize a value through a JSON round-trip for structural comparison. */
function normj(v: unknown): unknown {
  return JSON.parse(JSON.stringify(v))
}

/**
 * Load a fixture under Option B (references preserved), returning the raw
 * loaded document view — the TS counterpart of the Julia test `_load`
 * (resolveTemplateMachinery + lowerExpressionTemplates, NOT the Expand-at-build
 * `load()`).
 */
function loadRefPreserving(dir: string, fixture = 'fixture.esm'): Record<string, unknown> {
  const fp = conf(dir, fixture)
  const raw = JSON.parse(fs.readFileSync(fp, 'utf-8'))
  const resolved = resolveTemplateMachinery(raw, path.dirname(fp))
  return lowerExpressionTemplates((resolved ?? raw) as object) as Record<string, unknown>
}

function emit(dir: string, fixture = 'fixture.esm'): string {
  const fp = conf(dir, fixture)
  const raw = JSON.parse(fs.readFileSync(fp, 'utf-8'))
  return emitEsmString(emitDocument(raw, path.dirname(fp)))
}

function isApply(x: unknown): boolean {
  return (
    typeof x === 'object' &&
    x !== null &&
    (x as Record<string, unknown>).op === 'apply_expression_template'
  )
}

describe('out-of-line expression templates (Option B, esm-spec §9.6.4)', () => {
  // -------------------------------------------------------------------------
  // BRIDGE GATE (esm-spec §9.6.7, RFC §12 gate 1): Expand(load(fixture)) is
  // structurally equal to the existing expanded*.esm oracle. The goldens are
  // NOT regenerated — they are the Option-A image `Expand` must reproduce.
  // -------------------------------------------------------------------------
  describe('bridge: Expand(load) == expanded oracle', () => {
    const core = (d: Record<string, unknown>): Record<string, unknown> => {
      const out: Record<string, unknown> = {}
      for (const k of ['models', 'reaction_systems', 'coupling', 'index_sets']) {
        if (k in d) out[k] = normj(d[k])
      }
      return out
    }
    const cases: [string, string, string][] = [
      ['aggregate_int_ratio_golden', 'fixture.esm', 'expanded.esm'],
      ['arrhenius_smoke', 'fixture.esm', 'expanded.esm'],
      ['constrained_match_scope', 'fixture.esm', 'expanded.esm'],
      ['coupling_transform_expression', 'fixture.esm', 'expanded.esm'],
      ['fixpoint_nested_deriv', 'fixture.esm', 'expanded.esm'],
      ['godunov_beats_inner_deriv', 'fixture.esm', 'expanded.esm'],
      ['import_diamond', 'fixture.esm', 'expanded.esm'],
      ['import_order_determinism', 'fixture_import_order.esm', 'expanded_import_order.esm'],
      [
        'import_order_determinism',
        'fixture_priority_override.esm',
        'expanded_priority_override.esm',
      ],
      ['import_rebind_keyed_factors', 'fixture.esm', 'expanded.esm'],
      ['import_rename_diamond', 'fixture.esm', 'expanded.esm'],
      ['import_rename_two_instances', 'fixture.esm', 'expanded.esm'],
      ['import_smoke', 'fixture.esm', 'expanded.esm'],
      ['import_where_rename_two_instances', 'fixture.esm', 'expanded.esm'],
      ['per_variable_scheme_literal_args', 'fixture.esm', 'expanded.esm'],
      ['scalar_field_param', 'fixture.esm', 'expanded.esm'],
      ['two_div_two_meshes', 'fixture.esm', 'expanded.esm'],
    ]
    it.each(cases)('%s / %s == %s', (dir, fix, gold) => {
      const got = core(expandDocument(loadRefPreserving(dir, fix)))
      const want = core(JSON.parse(fs.readFileSync(conf(dir, gold), 'utf-8')))
      expect(got).toEqual(want)
    })
  })

  // -------------------------------------------------------------------------
  // Expand determinism (§9.6.4 rule 2): two expansions produce structurally
  // identical ASTs; the loaded view still carries surviving references.
  // -------------------------------------------------------------------------
  it('Expand is deterministic and non-destructive (rule 2)', () => {
    const loaded = loadRefPreserving('import_smoke')
    expect(normj(expandDocument(loaded))).toEqual(normj(expandDocument(loaded)))
    // non-destructive: the loaded view still carries surviving references
    const adv = (loaded.models as Record<string, any>).Advection
    const mk = adv.equations[0].rhs.args[1]
    expect((normj(mk) as any).op).toBe('makearray')
  })

  // -------------------------------------------------------------------------
  // emit_materialized_registry (§9.6.4 rule 5, §9.6.7)
  // -------------------------------------------------------------------------
  it('emit_materialized_registry: imports gone, stencils materialized', () => {
    const s = emit('emit_materialized_registry')
    expect(s).toBe(fs.readFileSync(conf('emit_materialized_registry', 'emitted.esm'), 'utf-8'))
    const doc = JSON.parse(s) as Record<string, any>
    const adv = doc.models.Advection
    expect(doc.esm).toBe('0.9.0') // rule 8 version stamp
    expect('expression_template_imports' in adv).toBe(false) // imports consumed
    const reg = adv.expression_templates
    expect(new Set(Object.keys(reg))).toEqual(new Set(['central_D_lon_interior', 'dlon_deg']))
    expect('central_D_lon_zero_grad_bc' in reg).toBe(false) // match rule not materialized
    // Call site intact: the makearray interior region is a surviving ref.
    const interior = adv.equations[0].rhs.args[1].values[0]
    expect(isApply(interior)).toBe(true)
    expect(interior.name).toBe('central_D_lon_interior')
    // idempotency (§9.6.4 rule 5 / RFC gate 2)
    const s2 = emitEsmString(emitDocument(JSON.parse(s), conf('emit_materialized_registry')))
    expect(s2).toBe(s)
  })

  // -------------------------------------------------------------------------
  // emit_rename_dotted_keys (§9.6.4 rule 5, §7.5.6 dotted keys)
  // -------------------------------------------------------------------------
  it('emit_rename_dotted_keys: dotted registry keys on disk', () => {
    const s = emit('emit_rename_dotted_keys')
    expect(s).toBe(fs.readFileSync(conf('emit_rename_dotted_keys', 'emitted.esm'), 'utf-8'))
    const doc = JSON.parse(s) as Record<string, any>
    const reg = doc.models.TwoGrids.expression_templates
    expect(new Set(Object.keys(reg))).toEqual(new Set(['fine.dx', 'coarse.dx']))
    expect(new Set(Object.keys(doc.index_sets))).toEqual(new Set(['fine.x', 'coarse.x']))
  })

  // -------------------------------------------------------------------------
  // eager_target_bearing (§9.6.4 rule 3, §9.6.7): positive + negative.
  // -------------------------------------------------------------------------
  it('eager_target_bearing: eager expands+lowers, target-free survives', () => {
    const d = loadRefPreserving('eager_target_bearing')
    const vars = (d.models as Record<string, any>).m.variables
    // POSITIVE: deriv_c (D-bearing) eagerly expanded, then the D lowered by the
    // `central` rule → an aggregate. No surviving ref.
    const deager = normj(vars.d_eager.expression) as any
    expect(deager.op).toBe('index')
    expect(deager.args[0].op).toBe('aggregate')
    // NEGATIVE: scale_c (target-free) reference SURVIVES.
    const dsurv = normj(vars.d_survive.expression) as any
    expect(isApply(dsurv.args[0])).toBe(true)
    expect(dsurv.args[0].name).toBe('scale_c')
    // Emit golden.
    expect(emit('eager_target_bearing')).toBe(
      fs.readFileSync(conf('eager_target_bearing', 'emitted.esm'), 'utf-8'),
    )
  })

  // -------------------------------------------------------------------------
  // opacity_negative (§9.6.4 rule 4): the compound pattern MUST NOT fire
  // across a surviving-reference boundary.
  // -------------------------------------------------------------------------
  it('opacity_negative: compound rule does not see through a reference', () => {
    const d = loadRefPreserving('opacity_negative')
    const flux = normj((d.models as Record<string, any>).m.variables.flux.expression) as any
    expect(flux.op).toBe('D') // compound did NOT fire (no marker 999)
    expect(isApply(flux.args[0])).toBe(true) // its arg is the surviving reference
    expect(flux.args[0].name).toBe('flux_prod')
    expect(emit('opacity_negative')).toBe(
      fs.readFileSync(conf('opacity_negative', 'emitted.esm'), 'utf-8'),
    )
  })

  // -------------------------------------------------------------------------
  // opacity_priority_shadowing (§9.6.4 rule 4): the silent divergence — the
  // high-priority compound rule does NOT fire; a lower-priority generic rule
  // DOES, binding the surviving reference whole.
  // -------------------------------------------------------------------------
  it('opacity_priority_shadowing: generic fires, compound silently does not', () => {
    const d = loadRefPreserving('opacity_priority_shadowing')
    const flux = normj((d.models as Record<string, any>).m.variables.flux.expression) as any
    expect(flux.op).toBe('*')
    expect(flux.args[0]).toBe(1) // generic marker (NOT compound 999)
    expect(isApply(flux.args[1])).toBe(true) // reference bound WHOLE by metavariable f
    expect(flux.args[1].name).toBe('flux_prod')
    expect(emit('opacity_priority_shadowing')).toBe(
      fs.readFileSync(conf('opacity_priority_shadowing', 'emitted.esm'), 'utf-8'),
    )
  })

  // -------------------------------------------------------------------------
  // per_instantiation_validation (§9.6.9): manifold param, two call sites,
  // one inadmissible → geometry_manifold_invalid naming the call site.
  // -------------------------------------------------------------------------
  it('per_instantiation_validation: memoized manifold check names call site', () => {
    let err: unknown
    try {
      loadRefPreserving('per_instantiation_validation')
    } catch (e) {
      err = e
    }
    expect(err).toBeInstanceOf(EsmMachineryError)
    expect((err as EsmMachineryError).code).toBe('geometry_manifold_invalid')
    expect((err as EsmMachineryError).message).toContain('area_bad') // offending call site
    expect((err as EsmMachineryError).message).toContain('overlap') // template name
  })

  // -------------------------------------------------------------------------
  // flatten_registry_merge (§9.6.4 rule 7, §10.7): dedup + owner-path rename.
  // -------------------------------------------------------------------------
  it('flatten_registry_merge: dedup + deterministic collision rename', () => {
    const loaded = loadRefPreserving('flatten_registry_merge')
    const { root, merged } = flattenTemplateRegistries(loaded)
    expect(new Set(Object.keys(merged))).toEqual(new Set(['sten', 'A.s', 'B.s']))
    expect(normj((merged.sten as any).body)).toEqual({ op: '*', args: [2, 'f'] })
    // references rewritten in lockstep
    const models = root.models as Record<string, any>
    expect(models.A.variables.za.expression.name).toBe('A.s')
    expect(models.B.variables.zb.expression.name).toBe('B.s')
    expect(models.A.variables.ya.expression.name).toBe('sten')
    expect(models.B.variables.yb.expression.name).toBe('sten')
    // per-component blocks surrendered to the merged registry
    expect('expression_templates' in models.A).toBe(false)
    expect('expression_templates' in models.B).toBe(false)
  })

  // -------------------------------------------------------------------------
  // Idempotency property over every new emit fixture (RFC §12 gate 2).
  // -------------------------------------------------------------------------
  it.each([
    'emit_materialized_registry',
    'emit_rename_dotted_keys',
    'eager_target_bearing',
    'opacity_negative',
    'opacity_priority_shadowing',
  ])('emit ∘ load byte-wise fixed point: %s', (dir) => {
    const s1 = emit(dir)
    const s2 = emitEsmString(emitDocument(JSON.parse(s1), conf(dir)))
    expect(s1).toBe(s2)
  })
})
