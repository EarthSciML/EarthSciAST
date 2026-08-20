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
  collectApplyNames,
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

/**
 * The RHS of the equation that DEFINES the unknown `name` — the equation whose
 * `lhs` is the bare string `name` (esm-spec §4.4 observed form).
 *
 * From esm 1.0.0 a variable has no `expression` field: an unknown's behaviour is
 * stated by the model's `equations` and nowhere else, so what used to be read as
 * `model.variables[name].expression` is now this equation's `rhs`. Looking the
 * equation up BY LHS rather than by index keeps these tests indifferent to the
 * order in which a fixture happens to list its equations.
 */
function definingRhs(model: Record<string, any>, name: string): unknown {
  const eqs = (model.equations ?? []) as Array<{ lhs: unknown; rhs: unknown }>
  const eq = eqs.find((e) => e.lhs === name)
  if (eq === undefined) throw new Error(`no defining equation with lhs '${name}'`)
  return eq.rhs
}

describe('out-of-line expression templates (Option B, esm-spec §9.6.4)', () => {
  // -------------------------------------------------------------------------
  // BRIDGE GATE (esm-spec §9.6.7, RFC §12 gate 1): Expand(load(fixture)) is
  // structurally equal to the existing expanded*.esm oracle. The goldens are
  // NOT regenerated — they are the Option-A image `Expand` must reproduce.
  // -------------------------------------------------------------------------
  describe('bridge: Expand(load) == expanded oracle', () => {
    /**
     * A model's `equations` are a SYSTEM, not a sequence: esm assigns no meaning
     * to their order, and from esm 1.0.0 the fixture/golden pairs no longer even
     * agree on it. Each former `type: 'observed'` variable became a bare-LHS
     * equation appended in its own file's `variables` key order, and the goldens
     * were emitted with those keys sorted while the fixtures kept authored order
     * — so e.g. aggregate_int_ratio_golden's fixture yields `dx, c0` where its
     * expanded oracle lists `c0, dx`. Canonicalize each component's equation
     * list before comparing so the gate pins CONTENT, which is what rule 1 is
     * about; every other position stays an exact structural match.
     */
    const sortEqs = (d: unknown): unknown => {
      for (const kind of ['models', 'reaction_systems']) {
        const comps = (d as Record<string, any>)[kind]
        if (comps === undefined || comps === null || typeof comps !== 'object') continue
        for (const comp of Object.values(comps as Record<string, any>)) {
          if (Array.isArray(comp?.equations)) {
            comp.equations = [...comp.equations].sort((a: unknown, b: unknown) =>
              JSON.stringify(a) < JSON.stringify(b) ? -1 : 1,
            )
          }
        }
      }
      return d
    }
    const core = (d: Record<string, unknown>): Record<string, unknown> => {
      const out: Record<string, unknown> = {}
      for (const k of ['models', 'reaction_systems', 'coupling', 'index_sets']) {
        if (k in d) out[k] = normj(d[k])
      }
      return sortEqs(out) as Record<string, unknown>
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
    // Rule 8 version stamp: emitting a surviving reference requires Option B,
    // i.e. `esm >= 0.9.0`. It is a FLOOR, not an assignment — a 1.0.0 source
    // document must not be stamped back down to an unloadable 0.9.0.
    expect(doc.esm).toBe('1.0.0')
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
    const m = (d.models as Record<string, any>).m
    // POSITIVE: deriv_c (D-bearing) eagerly expanded, then the D lowered by the
    // `central` rule → an aggregate. No surviving ref. (esm 1.0.0: d_eager is a
    // plain unknown; the rewritten call site is its defining equation's RHS.)
    const deager = normj(definingRhs(m, 'd_eager')) as any
    expect(deager.op).toBe('index')
    expect(deager.args[0].op).toBe('aggregate')
    // NEGATIVE: scale_c (target-free) reference SURVIVES.
    const dsurv = normj(definingRhs(m, 'd_survive')) as any
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
    const flux = normj(definingRhs((d.models as Record<string, any>).m, 'flux')) as any
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
    const flux = normj(definingRhs((d.models as Record<string, any>).m, 'flux')) as any
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
    // The offending call site is named by PATH. In esm 1.0.0 `area_bad` is an
    // unknown defined by the document's second equation, so the path that
    // localizes the bad instantiation is `models.m.equations/1/rhs` (index 1 —
    // NOT index 0, which is the admissible `area_ok` call site) rather than the
    // old `variables.area_bad.expression`.
    expect((err as EsmMachineryError).message).toContain('models.m.equations/1/rhs')
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
    // (esm 1.0.0: za/zb/ya/yb are unknowns whose reference sites are the RHS of
    // their defining equations, not a variable-level `expression` field.)
    expect((definingRhs(models.A, 'za') as any).name).toBe('A.s')
    expect((definingRhs(models.B, 'zb') as any).name).toBe('B.s')
    expect((definingRhs(models.A, 'ya') as any).name).toBe('sten')
    expect((definingRhs(models.B, 'yb') as any).name).toBe('sten')
    // per-component blocks surrendered to the merged registry
    expect('expression_templates' in models.A).toBe(false)
    expect('expression_templates' in models.B).toBe(false)
  })

  // -------------------------------------------------------------------------
  // flatten_registry_merge_transitive (§9.6.4 rule 7, §10.7): TWO models in ONE
  // document import the same rule library. `interior_stencil` folds differently
  // per model (B rebinds its free `inv_dx`) and collides; the byte-identical
  // `outer_stencil` that REFERENCES it must collide too — a single deduped
  // `outer_stencil` would carry a reference the merged registry no longer holds,
  // and expansion would fail with `apply_expression_template_unknown_template`
  // naming a transitively imported stencil no model ever mentioned.
  // -------------------------------------------------------------------------
  it('flatten_registry_merge_transitive: collisions propagate along the reference DAG', () => {
    const loaded = loadRefPreserving('flatten_registry_merge_transitive')
    const { root, merged } = flattenTemplateRegistries(loaded)
    expect(new Set(Object.keys(merged))).toEqual(
      new Set(['A.interior_stencil', 'A.outer_stencil', 'B.interior_stencil', 'B.outer_stencil']),
    )
    // Each owner's wrapper reaches its OWN leaf, never the other model's.
    const names = (x: unknown): string[] => collectApplyNames(x, [])
    expect(names((merged['A.outer_stencil'] as any).body)).toEqual(['A.interior_stencil'])
    expect(names((merged['B.outer_stencil'] as any).body)).toEqual(['B.interior_stencil'])
    // Component reference sites follow in lockstep.
    const models = root.models as Record<string, any>
    expect(names(models.A.equations)).toEqual(['A.outer_stencil'])
    expect(names(models.B.equations)).toEqual(['B.outer_stencil'])
    // Nothing dangles: every surviving reference resolves in the merged registry.
    for (const decl of Object.values(merged)) {
      for (const r of names(decl)) expect(Object.keys(merged)).toContain(r)
    }
    for (const m of ['A', 'B']) {
      for (const r of names(models[m].equations)) expect(Object.keys(merged)).toContain(r)
    }
  })

  // -------------------------------------------------------------------------
  // flatten_registry_merge_transitive/fixture_twins.esm (§9.6.4 rule 7, §10.7):
  // the SCOPING PRECONDITION, pinned. Two byte-identical models import the same
  // rule library; `interior_stencil`'s body references the free name `inv_dx`,
  // which is a model-local parameter and so denotes a DIFFERENT variable in each.
  //
  // `flattenTemplateRegistries` is the UNION half only, over the un-namespaced
  // component view: identical bodies dedupe under their bare names, and the pair
  // it returns is self-consistent with the un-namespaced document. TypeScript
  // reaches this surface only from conformance — its load path expands every
  // surviving reference (§9.6.4 rule 2) so `flatten` carries no registry, which
  // is why no scoping step exists here and none is required (§10.7,
  // "Applicability across bindings"). The Julia twin of this test also pins the
  // scoping∘merge composition, which its reference-preserving `flatten` does
  // carry; if TypeScript ever grows that path it inherits the obligation, and
  // this test is what will fail if the merge is fed unscoped bodies from it.
  // -------------------------------------------------------------------------
  it('flatten_registry_merge: the shared surface is the union half only', () => {
    const loaded = loadRefPreserving('flatten_registry_merge_transitive', 'fixture_twins.esm')
    const { root, merged } = flattenTemplateRegistries(loaded)
    const names = (x: unknown): string[] => collectApplyNames(x, [])
    // Step-4 answer on identical (unscoped) bodies: dedup under the bare names.
    expect(new Set(Object.keys(merged))).toEqual(new Set(['interior_stencil', 'outer_stencil']))
    expect(names((merged.outer_stencil as any).body)).toEqual(['interior_stencil'])
    const models = root.models as Record<string, any>
    expect(names(models.A.equations)).toEqual(['outer_stencil'])
    expect(names(models.B.equations)).toEqual(['outer_stencil'])
    // Nothing dangles at this layer.
    for (const decl of Object.values(merged)) {
      for (const r of names(decl)) expect(Object.keys(merged)).toContain(r)
    }
    // The carried body's free variable is NOT component-scoped by this surface:
    // `inv_dx`, not `A.inv_dx`. Scoping belongs to the caller that namespaces.
    const body = JSON.stringify((merged.interior_stencil as any).body)
    expect(body).toContain('"inv_dx"')
    expect(body).not.toContain('A.inv_dx')
    expect(body).not.toContain('B.inv_dx')
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
