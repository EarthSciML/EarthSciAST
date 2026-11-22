/**
 * Conformance tests for the out-of-line-expression-templates RFC (Option B,
 * reference-preserving expression templates): esm-spec §9.6.4 (rules 1-8),
 * §9.6.7 (new fixtures), §9.6.9 (validation discharge), §10.7 (flatten registry
 * merge). Mirrors the Julia reference test
 * `pkg/EarthSciAST.jl/test/out_of_line_templates_test.jl`.
 *
 * Drives tests/conformance/expression_templates/{emit_*, rewrite_*, opacity_*,
 * rule_writes_reference, template_instance_variants, unlowered_in_template_body,
 * flatten_registry_merge}.
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
} from './lower-expression-templates.js'
import { resolveTemplateMachinery, emitDocument } from './template-imports.js'
import { fixturesDir } from './test-helpers.js'
import { loadString } from './parse.js'
import { evaluateExpression, UnloweredOperatorError } from './codegen.js'

const conf = (...parts: string[]) => fixturesDir('conformance', 'expression_templates', ...parts)

/** Normalize a value through a JSON round-trip for structural comparison. */
function normj(v: unknown): unknown {
  return JSON.parse(JSON.stringify(v))
}

/**
 * Load a fixture under Option B (references preserved), returning the raw
 * loaded document view — the TS counterpart of the Julia test `_load`
 * (resolveTemplateMachinery + lowerExpressionTemplates, NOT the Expand-at-build
 * `loadString()`).
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
    typeof x === 'object' && x !== null && (x as Record<string, unknown>).op === 'apply_operator'
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
  // BRIDGE GATE (esm-spec §9.6.7, RFC §12 gate 1): Expand(loadString(fixture)) is
  // structurally equal to the existing expanded*.esm oracle. The goldens are
  // NOT regenerated — they are the Option-A image `Expand` must reproduce.
  // -------------------------------------------------------------------------
  describe('bridge: Expand(loadString) == expanded oracle', () => {
    /**
     * A model's `equations` are a SYSTEM, not a sequence: esm assigns no meaning
     * to their order, and from esm 1.0.0 the fixture/golden pairs no longer even
     * agree on it. Each former `type: 'observed'` variable became a bare-LHS
     * equation appended in its own file's `variables` key order, and the goldens
     * were emitted with those keys sorted while the fixtures kept authored order
     * — so e.g. faq_int_ratio_golden's fixture yields `dx, c0` where its
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
      ['faq_int_ratio_golden', 'fixture.esm', 'expanded.esm'],
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
      ['import_rename_integral_axis', 'fixture.esm', 'expanded.esm'],
      ['import_rename_two_instances', 'fixture.esm', 'expanded.esm'],
      ['import_smoke', 'fixture.esm', 'expanded.esm'],
      ['import_where_rename_two_instances', 'fixture.esm', 'expanded.esm'],
      ['metaparam_axis_name_collision', 'fixture.esm', 'expanded.esm'],
      ['per_variable_scheme_literal_args', 'fixture.esm', 'expanded.esm'],
      ['scalar_field_param', 'fixture.esm', 'expanded.esm'],
      ['ranges_param', 'fixture.esm', 'expanded.esm'],
      ['ranges_from_param', 'fixture.esm', 'expanded.esm'],
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
    expect(isApply(normj(mk))).toBe(true) // the rule's firing wrote a reference
  })

  // -------------------------------------------------------------------------
  // Rules write references (CONFORMANCE_SPEC §5.60; esm-spec §9.6.3
  // constraint 7, §9.6.4 rule 3): both goldens — the emitted form byte for
  // byte, and Expand(load) against the expanded oracle.
  // -------------------------------------------------------------------------
  describe('rules write references: emitted and expanded goldens (§5.60)', () => {
    const core = (d: Record<string, unknown>): Record<string, unknown> => {
      const out: Record<string, unknown> = {}
      for (const k of ['models', 'reaction_systems', 'coupling', 'index_sets']) {
        if (k in d) out[k] = normj(d[k])
      }
      return out
    }
    const cases: [string, string, string, string][] = [
      ['rewrite_in_template_body', 'fixture.esm', 'emitted.esm', 'expanded.esm'],
      ['rule_writes_reference', 'fixture.esm', 'emitted.esm', 'expanded.esm'],
      ['template_instance_variants', 'fixture.esm', 'emitted.esm', 'expanded.esm'],
      ['rewrite_shared_by_unreached_entry', 'fixture.esm', 'emitted.esm', 'expanded.esm'],
      ['opacity_rule_replacement', 'fixture.esm', 'emitted.esm', 'expanded.esm'],
      [
        'rewrite_depth_through_bodies',
        'chain_depth_64.esm',
        'emitted_chain_depth_64.esm',
        'expanded_chain_depth_64.esm',
      ],
      // Coupling transforms keep their references (esm-spec §10.4); the
      // receiving component's block materializes what they name.
      ['coupling_transform_expression', 'fixture.esm', 'emitted.esm', 'expanded.esm'],
      ['coupling_transform_rule_and_import', 'fixture.esm', 'emitted.esm', 'expanded.esm'],
    ]
    it.each(cases)('%s / %s: emitted == %s, Expand(load) == %s', (dir, fix, emitted, expanded) => {
      expect(emit(dir, fix)).toBe(fs.readFileSync(conf(dir, emitted), 'utf-8'))
      // Emit then load is a fixed point: the emitted form reloads and re-emits
      // byte for byte. For the depth-64 chain this holds only because the
      // body-nesting bound equals MAX_REWRITE_PASSES (esm-spec §9.7.3): its
      // emitted form is a 64-template body-reference chain.
      expect(emit(dir, emitted)).toBe(fs.readFileSync(conf(dir, emitted), 'utf-8'))
      expect(core(expandDocument(loadRefPreserving(dir, fix)))).toEqual(
        core(JSON.parse(fs.readFileSync(conf(dir, expanded), 'utf-8'))),
      )
    })

    it('variants are numbered by canonical bytes and each call site re-pointed', () => {
      const m = (loadRefPreserving('template_instance_variants').models as Record<string, any>).m
      expect((definingRhs(m, 'du') as any).name).toBe('ddx.variant1')
      expect((definingRhs(m, 'dv') as any).name).toBe('ddx.variant2')
      expect((normj(m.operators['ddx.variant1'].body) as any).name).toBe('central_1d')
    })

    it('a leaf-bodied rule writes its leaf', () => {
      const m = (loadRefPreserving('rule_writes_reference').models as Record<string, any>).m
      expect(normj(definingRhs(m, 'e'))).toEqual({ op: '*', args: [0.25, 'b'] })
    })

    it.each([
      ['rewrite_depth_through_bodies', 'fixture.esm', 'error.json'],
      ['rewrite_depth_through_bodies', 'chain_depth_65.esm', 'error_chain_depth_65.json'],
    ])('%s / %s is rejected as in %s', (dir, fix, errf) => {
      const want = JSON.parse(fs.readFileSync(conf(dir, errf), 'utf-8')).code
      let got: unknown
      try {
        loadRefPreserving(dir, fix)
      } catch (e) {
        got = (e as { code?: unknown }).code
      }
      expect(got).toBe(want)
    })

    it('unlowered_in_template_body: loads, emits its golden, and the evaluation gate refuses it', () => {
      expect(emit('unlowered_in_template_body')).toBe(
        fs.readFileSync(conf('unlowered_in_template_body', 'emitted.esm'), 'utf-8'),
      )
      const want = JSON.parse(
        fs.readFileSync(conf('unlowered_in_template_body', 'error.json'), 'utf-8'),
      ).code
      expect(want).toBe('unlowered_operator')
      // The reference survives the load with the body unrewritten; what it
      // denotes still holds the spatial derivative `partial` (the spatial `D`
      // read at the wire boundary, esm 2.4.0) the gate refuses.
      const d = loadRefPreserving('unlowered_in_template_body')
      const m = (d.models as Record<string, any>).m
      expect(normj(m.operators.ddy.body)).toMatchObject({ op: 'partial', wrt: 'y' })
      const expanded = JSON.stringify(expandDocument(d))
      expect(expanded).toContain('"op":"partial"')
      // The evaluation gate (stage "evaluate"): the build reaches the op.
      const file = loadString(
        fs.readFileSync(conf('unlowered_in_template_body', 'fixture.esm'), 'utf-8'),
      ) as any
      let err: unknown
      try {
        evaluateExpression(definingRhs(file.models.m, 'dy') as any, new Map([['u', 1.0]]))
      } catch (e) {
        err = e
      }
      expect(err).toBeInstanceOf(UnloweredOperatorError)
      expect((err as UnloweredOperatorError).code).toBe(want)
    })
  })

  // -------------------------------------------------------------------------
  // emit_materialized_registry (§9.6.4 rule 5, §9.6.7)
  // -------------------------------------------------------------------------
  it('emit_materialized_registry: imports gone, stencils materialized', () => {
    const s = emit('emit_materialized_registry')
    expect(s).toBe(fs.readFileSync(conf('emit_materialized_registry', 'emitted.esm'), 'utf-8'))
    const doc = JSON.parse(s) as Record<string, any>
    const adv = doc.models.Advection
    // Rule 8 version stamp: an emitted document writes the names `operators`
    // and `apply_operator`, so the floor is 2.4.0 (esm-spec §9.6.5). It is a
    // FLOOR, not an assignment: a source above it keeps its own version.
    expect(doc.esm).toBe('2.4.0')
    expect('operator_imports' in adv).toBe(false) // imports consumed
    const reg = adv.operators
    // The firing wrote a reference to its rule, which materializes match-less
    // (esm-spec §9.6.3 constraint 7, §9.6.4 rule 5).
    expect(new Set(Object.keys(reg))).toEqual(
      new Set(['central_D_lon_interior', 'central_D_lon_zero_grad_bc', 'dlon_deg']),
    )
    expect('match' in reg.central_D_lon_zero_grad_bc).toBe(false)
    const site = adv.equations[0].rhs.args[1]
    expect(isApply(site)).toBe(true)
    expect(site.name).toBe('central_D_lon_zero_grad_bc')
    const interior = reg.central_D_lon_zero_grad_bc.body.values[0]
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
    const reg = doc.models.TwoGrids.operators
    expect(new Set(Object.keys(reg))).toEqual(
      new Set(['fine.dx', 'coarse.dx', 'fine.central_D_x', 'coarse.central_D_x']),
    )
    expect(new Set(Object.keys(doc.index_sets))).toEqual(new Set(['fine.x', 'coarse.x']))
  })

  // -------------------------------------------------------------------------
  // rewrite_in_template_body (§9.6.4 rule 3, §9.6.7; formerly
  // eager_target_bearing): both references survive; the `central` rule
  // rewrites `deriv_c`'s body in place to a reference to itself.
  // -------------------------------------------------------------------------
  it('rewrite_in_template_body: rules rewrite the body, both references survive', () => {
    const d = loadRefPreserving('rewrite_in_template_body')
    const m = (d.models as Record<string, any>).m
    const deager = normj(definingRhs(m, 'd_eager')) as any
    expect(isApply(deager.args[0])).toBe(true)
    expect(deager.args[0].name).toBe('deriv_c')
    const body = normj(m.operators.deriv_c.body) as any
    expect(isApply(body)).toBe(true)
    expect(body.name).toBe('central')
    expect(body.bindings).toEqual({ f: 'f' })
    expect('match' in m.operators.central).toBe(false)
    const dsurv = normj(definingRhs(m, 'd_survive')) as any
    expect(isApply(dsurv.args[0])).toBe(true)
    expect(dsurv.args[0].name).toBe('scale_c')
    expect(emit('rewrite_in_template_body')).toBe(
      fs.readFileSync(conf('rewrite_in_template_body', 'emitted.esm'), 'utf-8'),
    )
  })

  // -------------------------------------------------------------------------
  // opacity_negative (§9.6.4 rule 4): the compound pattern MUST NOT fire
  // across a surviving-reference boundary.
  // -------------------------------------------------------------------------
  it('opacity_negative: compound rule does not see through a reference', () => {
    const d = loadRefPreserving('opacity_negative')
    const flux = normj(definingRhs((d.models as Record<string, any>).m, 'flux')) as any
    expect(flux.op).toBe('partial') // compound did NOT fire (no marker 999)
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
    const m = (d.models as Record<string, any>).m
    const flux = normj(definingRhs(m, 'flux')) as any
    // The generic rule fired and wrote a reference to itself (esm-spec §9.6.3
    // constraint 7), binding the surviving reference WHOLE.
    expect(isApply(flux)).toBe(true)
    expect(flux.name).toBe('generic')
    expect(isApply(flux.bindings.f)).toBe(true)
    expect(flux.bindings.f.name).toBe('flux_prod')
    // generic marker (NOT compound 999)
    expect((normj(m.operators.generic.body) as any).args[0]).toBe(1)
    expect(emit('opacity_priority_shadowing')).toBe(
      fs.readFileSync(conf('opacity_priority_shadowing', 'emitted.esm'), 'utf-8'),
    )
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
    expect('operators' in models.A).toBe(false)
    expect('operators' in models.B).toBe(false)
  })

  // -------------------------------------------------------------------------
  // flatten_registry_merge_transitive (§9.6.4 rule 7, §10.7): TWO models in ONE
  // document import the same rule library. `interior_stencil` folds differently
  // per model (B rebinds its free `inv_dx`) and collides; the byte-identical
  // `outer_stencil` that REFERENCES it must collide too — a single deduped
  // `outer_stencil` would carry a reference the merged registry no longer holds,
  // and expansion would fail with `operator_unknown_definition`
  // naming a transitively imported stencil no model ever mentioned.
  // -------------------------------------------------------------------------
  it('flatten_registry_merge_transitive: collisions propagate along the reference DAG', () => {
    const loaded = loadRefPreserving('flatten_registry_merge_transitive')
    const { root, merged } = flattenTemplateRegistries(loaded)
    expect(new Set(Object.keys(merged))).toEqual(
      new Set([
        'A.interior_stencil',
        'A.outer_stencil',
        'A.d_x_rule',
        'B.interior_stencil',
        'B.outer_stencil',
        'B.d_x_rule',
      ]),
    )
    const names = (x: unknown): string[] => collectApplyNames(x, [])
    // The rule's firing wrote a reference to the rule (esm-spec §9.6.3
    // constraint 7), whose body references the wrapper: it renames with it.
    expect(names((merged['A.d_x_rule'] as any).body)).toEqual(['A.outer_stencil'])
    expect(names((merged['B.d_x_rule'] as any).body)).toEqual(['B.outer_stencil'])
    // Each owner's wrapper reaches its OWN leaf, never the other model's.
    expect(names((merged['A.outer_stencil'] as any).body)).toEqual(['A.interior_stencil'])
    expect(names((merged['B.outer_stencil'] as any).body)).toEqual(['B.interior_stencil'])
    // Component reference sites follow in lockstep.
    const models = root.models as Record<string, any>
    expect(names(models.A.equations)).toEqual(['A.d_x_rule'])
    expect(names(models.B.equations)).toEqual(['B.d_x_rule'])
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
  // reaches this surface only from conformance — its loadString path expands every
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
    expect(new Set(Object.keys(merged))).toEqual(
      new Set(['interior_stencil', 'outer_stencil', 'd_x_rule']),
    )
    expect(names((merged.outer_stencil as any).body)).toEqual(['interior_stencil'])
    const models = root.models as Record<string, any>
    expect(names(models.A.equations)).toEqual(['d_x_rule'])
    expect(names(models.B.equations)).toEqual(['d_x_rule'])
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
    'rewrite_in_template_body',
    'opacity_negative',
    'opacity_priority_shadowing',
    'rule_writes_reference',
    'template_instance_variants',
    'opacity_rule_replacement',
    'unlowered_in_template_body',
    'coupling_transform_expression',
    'coupling_transform_rule_and_import',
  ])('emit ∘ loadString byte-wise fixed point: %s', (dir) => {
    const s1 = emit(dir)
    const s2 = emitEsmString(emitDocument(JSON.parse(s1), conf(dir)))
    expect(s1).toBe(s2)
  })
})
