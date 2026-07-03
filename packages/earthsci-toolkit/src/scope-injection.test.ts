/**
 * Tests for esm-spec §9.7.10 — scope-directed template injection
 * (docs/content/rfcs/scoped-template-injection.md): the assembler- or
 * test-chosen discretization for a discretization-agnostic PDE leaf, via
 * `expression_template_imports` on a §4.7 subsystem-ref edge (form A), a §10
 * coupling entry (form B), or a §6.6/§6.7 test/example (form C). Drives the
 * shared conformance fixtures under tests/conformance/expression_templates/,
 * mirroring the Julia reference suite
 * (`EarthSciSerialization.jl/test/scope_injection_test.jl`).
 *
 * This binding does not numerically simulate PDEs; form C is exercised as the
 * round-trip contract (test imports survive parse → emit, component intact)
 * plus the structural half of the ephemeral per-run build (`ephemeralInjectedFile`
 * lowers the leaf's rewrite-target in a throwaway copy). No solver is implied.
 */
import * as fs from 'node:fs'
import * as path from 'node:path'
import { describe, expect, it } from 'vitest'
import { load } from './parse.js'
import { save } from './serialize.js'
import { ephemeralInjectedFile, resolveSubsystemRefs } from './ref-loading.js'
import { ExpressionTemplateError } from './lower_expression_templates.js'

const repoRoot = path.resolve(__dirname, '../../..')
const conf = (...parts: string[]) =>
  path.join(repoRoot, 'tests', 'conformance', 'expression_templates', ...parts)

const golden = (goldenPath: string): unknown => JSON.parse(fs.readFileSync(goldenPath, 'utf8'))

/** load() from a fixture path with the fixture's directory as basePath. */
function loadPath(p: string): any {
  return load(fs.readFileSync(p, 'utf8'), { basePath: path.dirname(p) })
}

/** load() then resolve subsystem refs (the assembled document). */
async function loadResolved(p: string): Promise<any> {
  const f = loadPath(p)
  await resolveSubsystemRefs(f, path.dirname(p))
  return f
}

function errCode(f: () => unknown): string | null {
  try {
    f()
    return null
  } catch (e) {
    if (e instanceof ExpressionTemplateError) return e.code
    throw e
  }
}

describe('scope-directed template injection (esm-spec §9.7.10)', () => {
  it('form A — subsystem-ref injection (§4.7 / §9.7.10)', async () => {
    const f = await loadResolved(conf('inject_subsystem_ref', 'fixture.esm'))
    // The mounted, agnostic leaf's D(c, wrt: lon) is lowered by the injected
    // rule at the mount; the subsystem resolves to a Model (not a ref).
    const runoff = f.models.Assembly.subsystems.Runoff
    expect(runoff.equations).toBeDefined()
    expect(runoff.ref).toBeUndefined()
    expect(runoff.equations[0].rhs.args[1].op).toBe('makearray')
    // Injected library brought its grid into the importing registry.
    expect(f.index_sets.lon.size).toBe(288)
    expect(f.index_sets.lat.size).toBe(181)
    // Round-trip golden: the resolved+lowered assembly; the injection field
    // is gone (form A does not survive parse → emit).
    expect(JSON.parse(save(f))).toEqual(golden(conf('inject_subsystem_ref', 'expanded.esm')))

    // The leaf loads standalone with its D intact (agnostic; unlowered).
    const leaf = loadPath(conf('inject_subsystem_ref', 'leaf.esm'))
    expect(leaf.models.Advection.equations[0].rhs.args[1].op).toBe('D')

    // Negative twin: mounting WITHOUT injection loads cleanly (the D survives
    // — the op namespace is open); the unlowered_operator gate is an
    // evaluation-time concern, not a load error.
    const ni = await loadResolved(conf('inject_subsystem_ref', 'no_inject.esm'))
    const niRunoff = ni.models.Assembly.subsystems.Runoff
    expect(niRunoff.equations).toBeDefined()
    expect(niRunoff.ref).toBeUndefined()
    expect(niRunoff.equations[0].rhs.args[1].op).toBe('D')
  })

  it('form B — coupling-entry injection (§10.8 / §9.7.10)', () => {
    const f = loadPath(conf('inject_coupling_entry', 'fixture.esm'))
    // Advection is discretized by name; its lon-derivative is lowered.
    expect(f.models.Advection.equations[0].rhs.args[1].op).toBe('makearray')
    expect(f.index_sets.lon.size).toBe(288)
    // Emit (the 0-D partner) named no key and stays untouched.
    expect(f.models.Emit.equations[0].lhs.op).toBe('D')
    // The injection map is consumed — form B does not survive parse → emit.
    const ser = JSON.parse(save(f)) as any
    expect('expression_template_imports' in ser.coupling[0]).toBe(false)
    expect(ser).toEqual(golden(conf('inject_coupling_entry', 'expanded.esm')))

    // Diagnostics.
    expect(errCode(() => loadPath(conf('inject_coupling_entry', 'neg_target_unknown.esm')))).toBe(
      'template_inject_target_unknown',
    )
    expect(errCode(() => loadPath(conf('inject_coupling_entry', 'neg_target_is_loader.esm')))).toBe(
      'template_inject_target_is_loader',
    )
  })

  it('form C — test/example injection (§6.6.6 / §9.7.10)', async () => {
    const f = loadPath(conf('inject_test_block', 'fixture.esm'))
    const adv = f.models.Advection
    // The enclosing component round-trips with its D INTACT (form C does not
    // lower it at load) and each test keeps its import field (survives emit).
    expect(adv.equations[0].rhs.args[1].op).toBe('D')
    expect(adv.tests.length).toBe(2)
    expect(adv.tests.every((t: any) => Array.isArray(t.expression_template_imports) && t.expression_template_imports.length > 0)).toBe(true)
    expect(JSON.parse(save(f))).toEqual(golden(conf('inject_test_block', 'roundtrip.esm')))

    // One suite, many schemes: each test builds an INDEPENDENT ephemeral
    // instance with its own grid, with the D lowered in that build only — the
    // persisted component is never mutated.
    const src = conf('inject_test_block', 'fixture.esm')
    const base = conf('inject_test_block')
    const e1 = await ephemeralInjectedFile(f, src, 'Advection', adv.tests[0].expression_template_imports, base)
    const e2 = await ephemeralInjectedFile(f, src, 'Advection', adv.tests[1].expression_template_imports, base)
    expect((e1 as any).models.Advection.equations[0].rhs.args[1].op).toBe('makearray')
    expect((e2 as any).models.Advection.equations[0].rhs.args[1].op).toBe('makearray')
    expect((e1 as any).index_sets.lon.size).toBe(288)
    expect((e2 as any).index_sets.lon.size).toBe(144)
    // The persisted file is untouched by the ephemeral builds.
    expect(f.models.Advection.equations[0].rhs.args[1].op).toBe('D')
  })
})
