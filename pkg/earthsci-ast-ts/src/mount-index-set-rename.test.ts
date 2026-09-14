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
import { loadString, raiseFaqVersionFloor } from './parse.js'
import { expandDocument, lowerExpressionTemplates } from './lower-expression-templates.js'
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

  // esm-spec §4.7 "Two mount forms, one mechanism": the top-level form lands its
  // component as a TOP-LEVEL system, which is exactly what the form mounts — so
  // it has to compose with itself. A binding that resolves one level deep picks
  // the leaf's own UNRESOLVED `{ ref }` edge out of its `models` and splices it
  // in as though it were the component: a document that mounts an assembly loads
  // clean and carries a mount edge where a model belongs.
  it('resolves an assembly mounted at a top-level `models.<k>` {ref}', () => {
    const { file } = loadResolved('valid/mount_chain_outer.esm')
    const models = file.models as Record<string, { variables?: object; ref?: string }>
    expect(models.Deep?.ref).toBeUndefined()
    expect(Object.keys(models.Deep?.variables ?? {})).toEqual(['Tsoil'])
    // The axis name the INNER edge chose reaches the OUTER document's registry.
    const sets = (file as unknown as { index_sets: Record<string, { size?: number }> }).index_sets
    expect(sets.soil_lev?.size).toBe(4)
    expect(sets.lev).toBeUndefined()
  })

  // Which attachment point mounted a file cannot change what that file IS.
  it('resolves an assembly mounted at a `subsystems.<k>` {ref}', () => {
    const { file } = loadResolved('valid/mount_chain_via_subsystem.esm')
    const host = (file.models as Record<string, { subsystems?: Record<string, unknown> }>).Host
    const deep = host?.subsystems?.Deep as { variables?: object; ref?: string }
    expect(deep?.ref).toBeUndefined()
    expect(Object.keys(deep?.variables ?? {})).toEqual(['Tsoil'])
    const sets = (file as unknown as { index_sets: Record<string, { size?: number }> }).index_sets
    expect(sets.soil_lev?.size).toBe(4)
  })

  // Composition without cycle detection is unbounded recursion. `resolving` is
  // path-scoped, so the same component file may be mounted by several keys —
  // only a cycle ALONG THE CURRENT PATH is the error.
  it('reports a mount cycle that only exists across the chain', () => {
    const dir = mkdtempSync(path.join(tmpdir(), 'esm-mount-cycle-'))
    const doc = (name: string, ref: string) => ({
      esm: '1.0.0',
      metadata: { name },
      models: { M: { ref } },
    })
    writeFileSync(path.join(dir, 'a.esm'), JSON.stringify(doc('a', './b.esm')))
    writeFileSync(path.join(dir, 'b.esm'), JSON.stringify(doc('b', './a.esm')))
    const root = JSON.parse(JSON.stringify(doc('root', './a.esm'))) as unknown as EsmFile
    expect(() => resolveSubsystemRefsSync(root, dir)).toThrow(/[Cc]ircular/)
  })
})

describe('mount-edge index_set_rename is PER EDGE (esm-spec §4.7), at both ends', () => {
  // End one: an edge may NOT rename an axis that reached the registry ONLY
  // through a mount nested inside the referenced document — that axis is
  // renamed at ITS own edge.
  it.each([
    ['rename_scope_nested_only_axis.esm', 'subsystem ref'],
    ['rename_scope_nested_only_axis_toplevel.esm', 'top-level model ref'],
  ])('refuses to rename an axis only a nested mount contributed (%s)', (name, noun) => {
    expect(() => loadResolved(`fixtures/mount_edge_rename_nested_scope/${name}`)).toThrow(
      /subsystem_index_set_rename_unknown_name/,
    )
    try {
      loadResolved(`fixtures/mount_edge_rename_nested_scope/${name}`)
    } catch (e) {
      expect(String((e as Error).message)).toContain(noun)
      expect(String((e as Error).message)).toContain("index set 'lev'")
    }
  })

  // End two, which a future reader is most likely to collapse into end one: an
  // edge MUST rename an axis the referenced document declares ITSELF, even
  // where a component it mounts declares a deep-equal one of the same name.
  // §4.7's deep-equal merge has already made those ONE axis, so the rename
  // covers the whole resolved leaf: the registry is `{soil_lev}` alone with the
  // nested component's `shape` re-pointed, not `{lev, soil_lev}` with the
  // nested component still on `lev`.
  it.each([['rename_scope_shared_axis.esm'], ['rename_scope_shared_axis_toplevel.esm']])(
    'renames an axis the leaf shares with its own nested mount (%s)',
    (name) => {
      const { file } = loadResolved(`fixtures/mount_edge_rename_nested_scope/${name}`)
      const sets = (file as unknown as { index_sets: Record<string, { size?: number }> }).index_sets
      expect(Object.keys(sets)).toEqual(['soil_lev'])
      expect(sets.soil_lev?.size).toBe(4)
      expect(JSON.stringify(file)).not.toContain('"lev"')
    },
  )
})

describe('a §4.7 merge folds against the environment of the registry it lands in', () => {
  // esm-spec §4.7 "Which environment it folds against". The fixture makes the
  // two candidate environments disagree on purpose: the grandchild sizes an
  // axis `"n_lev"` and carries no §9.7 machinery, so the name survives its own
  // load unfolded; the leaf declares `n_lev: 4` and mounts it; the assembly
  // declares an unrelated `n_lev: 9` and mounts the leaf. The axis lands in the
  // LEAF's registry, so the leaf's close is the one that speaks.
  //
  // This binding answered 9 before the rule was settled, letting an assembler's
  // unrelated same-named metaparameter resize an axis the leaf owns.
  it("uses the LEAF's close for an axis its own nested mount contributed", () => {
    const { file } = loadResolved('fixtures/mount_merge_fold_env/fold_env_root.esm')
    const sets = (file as unknown as { index_sets: Record<string, { size?: number }> }).index_sets
    expect(sets.prof?.size).toBe(4)
  })

  // And "the leaf's closed environment" means CLOSED: an explicit edge binding
  // closes the referenced document and wins over its own default (§9.7.6 site
  // 3), so the same axis is 7 when the edge binds 7. An axis the leaf declares
  // ITSELF already folds to 7 through that close, so answering 4 here would
  // make one resolved document disagree with itself.
  it("takes an edge binding over the leaf's own default in that close", () => {
    const { file } = loadResolved('fixtures/mount_merge_fold_env/fold_env_bound_root.esm')
    const sets = (file as unknown as { index_sets: Record<string, { size?: number }> }).index_sets
    expect(sets.prof?.size).toBe(7)
  })
})

describe('the raised floor, at the seam the §4.7 inline/merge reorder needs it', () => {
  // esm-spec §4.7 resolves a `{ ref }` "before validation or any other
  // processing", which puts a mounted leaf's content in the document BEFORE the
  // esm-version gates run. A legal 1.0.0 assembly that mounts a `faq`-using
  // leaf then CONTAINS `faq` without ever having spelled it, and the gate
  // refuses a document nobody authored wrongly. The Julia reference answers
  // this by not gating an already-inlined document and raising the floor
  // instead, "exactly as `emit` does"
  // (docs/content/rfcs/faq-node-rename.md §5.5).
  //
  // This binding already has that stamp — `raiseFaqVersionFloor`, applied after
  // ref resolution — and the reorder needs it applied before `loadString` gates
  // the inlined document. Pinned here so the mechanism is in place and
  // known-good ahead of the reorder rather than debugged alongside it.
  it('admits a 1.0.0 document that contains `faq` only because a mount was inlined', () => {
    const leaf = JSON.parse(
      readFileSync(path.join(TESTS, 'valid/mount_rename_atm_column.esm'), 'utf8'),
    ) as Record<string, unknown>
    const inlined: Record<string, unknown> = {
      esm: '1.0.0',
      metadata: {
        name: 'inlined_assembly',
        description: 'a 1.0.0 assembly that CONTAINS faq only because a mount was inlined into it',
        license: 'MIT',
      },
      index_sets: leaf.index_sets,
      models: leaf.models,
    }

    // Ungated, it is refused.
    expect(() => loadString(JSON.stringify(inlined))).toThrow(/faq_version_too_old/)

    // With the floor raised, it loads — and the floor only ever raises.
    raiseFaqVersionFloor(inlined)
    expect(inlined.esm).toBe('1.1.0')
    const file = loadString(JSON.stringify(inlined))
    expect((file as unknown as { esm: string }).esm).toBe('1.1.0')
  })
})

describe('issue #311 in this binding: the rewrite pass re-runs after resolveSubsystemRefs', () => {
  // `loadPath` / `loadString` do not resolve `{ ref }` mounts in this binding, so
  // a rule a component declares in its own `expression_template_imports` only
  // reaches a rewrite-target inside a component it mounts once
  // `resolveSubsystemRefs` has spliced the mount in and re-run the §9.6.3 pass
  // over that component. Rust, Go and Julia inline before their fixpoint instead.
  const fixture = (name: string) => path.join(TESTS, 'fixtures/mount_edge_injection_nested', name)
  const equation = (file: EsmFile, lhs: string) =>
    (
      file as unknown as { models: Record<string, { equations: { lhs: unknown; rhs: unknown }[] }> }
    ).models.Leaf.equations.find((e) => e.lhs === lhs)?.rhs

  it.each([
    ['nested_self_import.esm'],
    ['nested_subsystem_mount.esm'],
    ['nested_model_mount.esm'],
    ['nested_depth2_mount.esm'],
  ])('lowers the rewrite-target inside the mounted component (%s)', (name) => {
    const base = path.dirname(fixture(name))
    const file = loadString(readFileSync(fixture(name), 'utf8'), { basePath: base })
    resolveSubsystemRefsSync(file, base)
    // `componentTemplates` is non-enumerable, so a rule's own `match` pattern
    // never shows up here — only a surviving call site would.
    expect(JSON.stringify(file)).not.toContain('"op":"input_x"')
  })

  // The re-run must be IDEMPOTENT: content the ordinary load already lowered is
  // not rewritten a second time. The fixture's component has a rewrite-target
  // in its OWN equation, which lowers during the load before any ref resolves,
  // and mounts the grandchild whose target lowers only after resolution.
  it('leaves a target the load already lowered exactly as the load left it', () => {
    const name = 'nested_self_import_own_target.esm'
    const base = path.dirname(fixture(name))
    const file = loadString(readFileSync(fixture(name), 'utf8'), { basePath: base })
    const ownBeforeResolve = structuredClone(equation(file, 'own'))
    expect(JSON.stringify(ownBeforeResolve)).not.toContain('input_x')

    resolveSubsystemRefsSync(file, base)
    expect(JSON.stringify(file)).not.toContain('"op":"input_x"')
    expect(equation(file, 'own')).toEqual(ownBeforeResolve)

    // And running the lowering pass once more over the resolved component, with
    // the same rules, changes nothing at all.
    const templates = (file as unknown as { componentTemplates: Record<string, unknown> })
      .componentTemplates['models.Leaf']
    const leaf = (file as unknown as { models: Record<string, Record<string, unknown>> }).models
      .Leaf
    const single = {
      esm: (file as unknown as { esm: string }).esm,
      index_sets: (file as unknown as { index_sets?: unknown }).index_sets,
      models: { Leaf: { ...leaf, expression_templates: templates } },
    }
    const again = (
      expandDocument(lowerExpressionTemplates(single)) as {
        models: Record<string, Record<string, unknown>>
      }
    ).models.Leaf
    delete again.expression_templates
    expect(again).toEqual(leaf)
  })
})
