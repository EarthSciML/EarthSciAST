/**
 * esm-spec §9.6.4 rules 1 and 7, §10.7: a mounted leaf keeps its template
 * references; its definitions join the mounting component's registry in the
 * leaf's OWN names, and a body's free names are read in the scope of the
 * subsystem that owns the reference. Flatten closes every body (its free names
 * become parameters each reference binds in its own scope), and the registry
 * merge keeps one entry per distinct definition.
 *
 * Drives `tests/conformance/expression_templates/mount_registry_merge/` and
 * `mount_shared_definition/` against their Julia-written goldens, byte for
 * byte. Mirrors `pkg/EarthSciAST.jl/test/mount_template_registry_test.jl`.
 */
import * as fs from 'node:fs'
import * as path from 'node:path'
import { describe, expect, it } from 'vitest'
import { emitEsmString } from './lower-expression-templates.js'
import { emitDocument } from './template-imports.js'
import { fixturesDir } from './test-helpers.js'
import { loadPath } from './parse.js'
import { resolveSubsystemRefsSync } from './ref-loading.js'
import { flatten } from './flatten.js'
import { toJson } from './serialize.js'
import type { EsmFile } from './types.js'

const conf = (...parts: string[]) => fixturesDir('conformance', 'expression_templates', ...parts)
const golden = (dir: string, f: string): string => fs.readFileSync(conf(dir, f), 'utf-8')

/** `fixture` loaded with its `{ ref }` mounts resolved. */
function load(dir: string, fixture: string): EsmFile {
  const file = loadPath(conf(dir, fixture))
  resolveSubsystemRefsSync(file, conf(dir))
  return file
}

/** A registry written as the goldens write it: one `operators` block. */
const block = (reg: unknown): string => emitEsmString({ operators: reg })

const flatRegistry = (dir: string, fixture: string): string =>
  block(flatten(load(dir, fixture)).templateRegistry)

const loadedRegistry = (dir: string, fixture: string): string =>
  block(load(dir, fixture).componentTemplates?.['models.Host'])

type Eq = { lhs: unknown; rhs: unknown }
type Comp = { equations: Eq[]; subsystems?: Record<string, Comp> }

/** The right-hand side of the equation for `D(name)` in `comp`. */
function rhsOf(comp: Comp, name: string): unknown {
  const eq = comp.equations.find((e) => JSON.stringify(e.lhs).includes(`["${name}"]`))
  if (eq === undefined) throw new Error(`no equation for ${name}`)
  return eq.rhs
}

describe('mounted template registries (esm-spec §9.6.4 rule 1)', () => {
  it('mount_registry_merge: flattened registry of the mounted form', () => {
    expect(flatRegistry('mount_registry_merge', 'fixture.esm')).toBe(
      golden('mount_registry_merge', 'flattened_registry.esm'),
    )
  })

  it('mount_registry_merge: flattened registry of the inline form', () => {
    expect(flatRegistry('mount_registry_merge', 'inline_form.esm')).toBe(
      golden('mount_registry_merge', 'inline_flattened_registry.esm'),
    )
  })

  it('mount_registry_merge: the loaded registry of models.Host', () => {
    expect(loadedRegistry('mount_registry_merge', 'fixture.esm')).toBe(
      golden('mount_registry_merge', 'loaded_registry.esm'),
    )
  })

  it('mount_registry_merge: the emitted inline form', () => {
    const fp = conf('mount_registry_merge', 'inline_form.esm')
    const raw = JSON.parse(fs.readFileSync(fp, 'utf-8'))
    expect(emitEsmString(emitDocument(raw, path.dirname(fp)))).toBe(
      golden('mount_registry_merge', 'inline_emitted.esm'),
    )
  })

  it('mount_registry_merge: the mounted and inline forms expand alike', () => {
    const host = (f: string) =>
      JSON.stringify((load('mount_registry_merge', f).models as Record<string, unknown>).Host)
    const mounted = load('mount_registry_merge', 'fixture.esm')
    const sub = (mounted.models as Record<string, Comp>).Host!.subsystems!.Sub!
    // The leaf's `rate` reads the leaf's own `k`, in Sub's scope; `scale` is
    // the leaf's (3x), not Host's (2x).
    expect(rhsOf(sub, 'c')).toEqual({
      op: '-',
      args: [{ op: '*', args: ['k', { op: '*', args: [3, 'c'] }] }],
    })
    expect(JSON.stringify(mounted)).not.toContain('apply_operator')
    // The inline form carries Sub's `k` declaration in the same place, so the
    // two forms expand to the same Host.
    const inline = JSON.parse(host('inline_form.esm')) as Comp
    expect(rhsOf(inline.subsystems!.Sub!, 'c')).toEqual(rhsOf(sub, 'c'))
    expect(rhsOf(inline.subsystems!.Inner!, 'w')).toEqual(
      rhsOf((mounted.models as Record<string, Comp>).Host!.subsystems!.Inner!, 'w'),
    )
  })

  it('mount_shared_definition: flattened and loaded registries', () => {
    expect(flatRegistry('mount_shared_definition', 'fixture.esm')).toBe(
      golden('mount_shared_definition', 'flattened_registry.esm'),
    )
    expect(loadedRegistry('mount_shared_definition', 'fixture.esm')).toBe(
      golden('mount_shared_definition', 'loaded_registry.esm'),
    )
    const reg = load('mount_shared_definition', 'fixture.esm').componentTemplates?.[
      'models.Host'
    ] as Record<string, { body: unknown }>
    // One definition per leaf template, in the leaf's own names.
    expect(Object.keys(reg).sort()).toEqual(['Host.rate', 'Sub1.rate', 'loss', 'pull'])
    expect(reg['Sub1.rate']!.body).toEqual({ op: '*', args: ['k', 'x'] })
  })

  it("mount_shared_definition: each subsystem's expansion reads its own names", () => {
    const host = (load('mount_shared_definition', 'fixture.esm').models as Record<string, Comp>)
      .Host!
    const subs = host.subsystems!
    // Sub1 and Sub2 share one `rate` / `loss` definition; each reads its own `k`.
    for (const s of ['Sub1', 'Sub2']) {
      expect(rhsOf(subs[s]!, 'c')).toEqual({ op: '-', args: [{ op: '*', args: ['k', 'c'] }] })
      expect(rhsOf(subs[s]!, 'd')).toEqual({
        op: '-',
        args: [{ op: '*', args: ['k', 'd', 'd'] }],
      })
    }
    // Host's `pull` reads `g`: Host's own at Host's reference, Inner's at Inner's.
    expect(rhsOf(host, 'y')).toEqual({ op: '-', args: [{ op: '*', args: [2, 'y'] }] })
    expect(rhsOf(host, 'z')).toEqual({ op: '-', args: [{ op: '*', args: ['g', 'z'] }] })
    expect(rhsOf(subs.Inner!, 'w')).toEqual({ op: '-', args: [{ op: '*', args: ['g', 'w'] }] })
  })

  it("mount_host_rule: the mounting component's rule fires in its mounts", () => {
    // esm-spec §9.6.3: Host's `match` rule `cube` fires on the content of the
    // models Host mounts, at any depth (Sub, Sub's own mount Deep, and Bare,
    // which declares no templates), as on an authored subsystem's.
    expect(loadedRegistry('mount_host_rule', 'fixture.esm')).toBe(
      golden('mount_host_rule', 'loaded_registry.esm'),
    )
    expect(flatRegistry('mount_host_rule', 'fixture.esm')).toBe(
      golden('mount_host_rule', 'flattened_registry.esm'),
    )
    expect(JSON.parse(toJson(load('mount_host_rule', 'fixture.esm')))).toEqual(
      JSON.parse(golden('mount_host_rule', 'expanded.esm')),
    )
  })

  it('flatten_closes_join_names: join names are closed like variable leaves', () => {
    // esm-spec §10.7: a body's `join` clauses name component variables it reads
    // nowhere else (overlap envelope factors, `on` key columns); closing makes
    // them parameters, as it does the body's variable leaves.
    expect(flatRegistry('flatten_closes_join_names', 'fixture.esm')).toBe(
      golden('flatten_closes_join_names', 'flattened_registry.esm'),
    )
  })
})
