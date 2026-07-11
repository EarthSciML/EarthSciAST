/**
 * File-based conformance corpus for the coupling-library / coupling_import
 * feature (docs/content/rfcs/coupling-libraries-role-binding.md §11; esm-spec
 * §10.9–§10.11). The in-memory counterpart is coupling-imports.test.ts; this
 * suite drives the SAME real TS API (`load`, `save`, `flatten`,
 * `expandCouplingImports`, `resolveSubsystemRefs`, `validate`, `validateSchema`)
 * over the .esm fixtures under tests/coupling_libraries/, asserting the outcome
 * recorded in that directory's expected_errors.json.
 *
 * Fixture-path resolution mirrors scope-injection.test.ts / conformance.test.ts:
 * the repo-root tests/ dir is three levels up from this file's directory.
 */
import * as fs from 'node:fs'
import * as path from 'node:path'
import { describe, expect, it } from 'vitest'
import { load, validateSchema } from './parse.js'
import { save } from './serialize.js'
import { flatten } from './flatten.js'
import { expandCouplingImports } from './coupling-imports.js'
import { resolveSubsystemRefs } from './ref-loading.js'
import { validate } from './validate.js'
import {
  errCode as errCodeShared,
  errCodeAsync as errCodeAsyncShared,
  fixturesDir,
  loadFixtureFile,
} from './test-helpers.js'
import type { CouplingEntry, EsmFile } from './types.js'

const dir = fixturesDir('coupling_libraries')
const cl = (...parts: string[]): string => path.join(dir, ...parts)

const readText = (p: string): string => fs.readFileSync(p, 'utf8')
const readJson = (p: string): Record<string, unknown> => JSON.parse(readText(p))

/** load() a fixture with the fixtures directory as basePath. */
const loadPath = (p: string): EsmFile => loadFixtureFile(p)

// This file-corpus suite uses the legacy sentinel contract: 'NO_ERROR' on
// success and `err.code ?? 'NON_CODE_ERROR'` for any throw (never rethrows).
const errCode = (fn: () => unknown): string | null => errCodeShared(fn, { sentinel: true })
const errCodeAsync = (fn: () => Promise<unknown>): Promise<string | null> =>
  errCodeAsyncShared(fn, { sentinel: true })

/** Expand a fixture's coupling_import edges (typed convenience). */
function expandFixture(p: string): CouplingEntry[] {
  const out = expandCouplingImports(loadPath(p), { basePath: dir })
  if (!out) throw new Error(`fixture ${p} has no coupling block`)
  return out
}

/* eslint-disable @typescript-eslint/no-explicit-any */

describe('coupling-library conformance (esm-spec §10.9–§10.11)', () => {
  // --- Library validity ---------------------------------------------------

  it('valid library: schema-valid, loads, and round-trips (§10.9)', () => {
    const p = cl('rothermel_fuel.esm')
    // Regression guard for the §9 root-`anyOf` coupling_roles branch: a bare
    // roles + coupling document passes root-schema validation.
    expect(validateSchema(readJson(p))).toEqual([])
    const loaded = loadPath(p)
    expect((loaded as any).coupling_roles).toBeDefined()
    // save() -> load() is a fixed point.
    const reloaded = load(save(loaded), { basePath: dir })
    expect(reloaded).toEqual(loaded)
  })

  // --- Equivalence: import vs. inline flatten identically (§10.10.3) -------

  it('equivalence: an import and the inlined edges flatten to the same system', () => {
    const imported = flatten(loadPath(cl('assembly_import.esm')), { basePath: dir })
    const inline = flatten(loadPath(cl('assembly_inline.esm')))
    expect(imported).toEqual(inline)
    // Sanity anchor: the five expanded variable maps landed.
    expect(imported.variables['RothermelFireSpread.w0']).toBe('FuelModelLookup.w_0')
    expect(imported.metadata.couplingRules).toHaveLength(5)
  })

  // --- Multiple instantiation: two binds -> two independent edge sets -----

  it('multiple instantiation: distinct binds expand to two non-interfering edge sets', () => {
    const expanded = expandFixture(cl('assembly_multi.esm'))
    expect(expanded).toHaveLength(10)
    const first = expanded.slice(0, 5) as any[]
    const second = expanded.slice(5) as any[]
    expect(first.every((e) => e.from.startsWith('FuelModelLookup.') && e.to.startsWith('RothermelFireSpread.'))).toBe(
      true,
    )
    expect(second.every((e) => e.from.startsWith('LandfireFuel.') && e.to.startsWith('RothermelStatic.'))).toBe(true)
  })

  // --- Full surface: every §10.10.2 occurrence site is rewritten ----------

  it('full surface: expansion rewrites every role occurrence, leaving no residual role names', () => {
    const expanded = expandFixture(cl('assembly_full_surface.esm')) as any[]
    // The bind targets (SourceModel/SinkModel) contain neither role name as a
    // substring, so a clean substring check proves no role name survived.
    const json = JSON.stringify(expanded)
    expect(json.includes('Fuel')).toBe(false)
    expect(json.includes('Spread')).toBe(false)
    expect(json.includes('SourceModel')).toBe(true)
    expect(json.includes('SinkModel')).toBe(true)

    // variable_map: from/to and the apply_expression_template bindings VALUES.
    const vm = expanded.find((e) => e.type === 'variable_map')
    expect(vm.from).toBe('SourceModel.sigma')
    expect(vm.to).toBe('SinkModel.sigma')
    expect(vm.transform.op).toBe('apply_expression_template')
    expect(vm.transform.bindings.src).toBe('SourceModel.sigma')
    expect(vm.transform.bindings.weights).toBe('SinkModel.w_regrid')

    // couple: systems array + connector equations (from/to/expression).
    const couple = expanded.find((e) => e.type === 'couple')
    expect(couple.systems).toEqual(['SourceModel', 'SinkModel'])
    expect(couple.connector.equations[0].from).toBe('SourceModel.h')
    expect(couple.connector.equations[0].to).toBe('SinkModel.h')
    expect(couple.connector.equations[0].expression.args[0]).toBe('SourceModel.h')

    // operator_compose: translate keys AND values (object form's `.var`).
    const oc = expanded.find((e) => e.type === 'operator_compose')
    expect(Object.keys(oc.translate)).toEqual(['SourceModel.flux'])
    expect(oc.translate['SourceModel.flux'].var).toBe('SinkModel.flux')

    // event: conditions, affects (lhs + rhs), discrete_parameters.
    const ev = expanded.find((e) => e.type === 'event')
    expect(ev.conditions[0].args[0]).toBe('SourceModel.sigma')
    expect(ev.affects[0].lhs).toBe('SinkModel.r')
    expect(ev.affects[0].rhs.args[0].args[0]).toBe('SinkModel.r')
    expect(ev.discrete_parameters).toEqual(['SinkModel.r'])
  })

  // --- Invalid libraries (defect in the library; driven via flatten) ------

  function libHarness(libRef: string, bind: Record<string, string>): EsmFile {
    return {
      esm: '0.8.0',
      metadata: { name: 'harness' },
      models: {
        Fuel: { variables: { x: { type: 'parameter', units: '1', default: 0 } }, equations: [] },
        Spread: { variables: { y: { type: 'parameter', units: '1', default: 0 } }, equations: [] },
      },
      coupling: [{ type: 'coupling_import', ref: libRef, bind }],
    } as unknown as EsmFile
  }

  const libraryCases: Array<[string, string]> = [
    ['lib_declares_models.esm', 'coupling_library_illegal_payload'],
    ['lib_has_callback.esm', 'coupling_library_illegal_payload'],
    ['lib_edge_template_imports.esm', 'coupling_library_illegal_payload'],
    ['lib_unknown_role_edge.esm', 'coupling_edge_unknown_role'],
    ['lib_unused_role.esm', 'coupling_role_unused'],
    ['lib_nested_import.esm', 'coupling_library_nested_import'],
  ]
  it.each(libraryCases)('invalid library %s -> %s', (file, code) => {
    const harness = libHarness(`./${file}`, { Fuel: 'Fuel', Spread: 'Spread' })
    expect(errCode(() => flatten(harness, { basePath: dir }))).toBe(code)
  })

  // --- Invalid imports (defect in the assembly bind; driven via flatten) --

  const importCases: Array<[string, string]> = [
    ['import_role_unbound.esm', 'coupling_import_role_unbound'],
    ['import_unknown_role.esm', 'coupling_import_unknown_role'],
    ['import_bind_not_a_component.esm', 'coupling_import_bind_not_a_component'],
    ['import_not_library.esm', 'coupling_import_not_library'],
  ]
  it.each(importCases)('invalid import %s -> %s', (file, code) => {
    expect(errCode(() => flatten(loadPath(cl(file)), { basePath: dir }))).toBe(code)
  })

  // --- Mis-bind caught downstream (RFC §11 / §4.1 / §7) -------------------

  it('mis-bind: expansion succeeds; the expanded edge fails as unresolved_scoped_ref', () => {
    const p = cl('import_misbind_downstream.esm')
    // Binding is structurally complete, so expansion itself does NOT throw.
    const expanded = expandFixture(p)
    expect(expanded).toHaveLength(5)

    // The mis-bind (Spread -> RothermelNoW0, which lacks `w0`) surfaces on the
    // expanded edge as the existing unresolved_scoped_ref — the same diagnostic
    // a hand-authored bad edge yields. KNOWN TS GAP: the reference flatten()
    // does not itself re-run scoped-ref resolution on expanded edges (the check
    // lives in validate.ts, which iterates the UN-expanded coupling), so we
    // drive it by validating the expanded coupling. flatten() alone succeeds:
    expect(() => flatten(loadPath(p), { basePath: dir })).not.toThrow()

    const expandedFile = { ...readJson(p), coupling: expanded }
    const result = validate(expandedFile)
    const misbind = result.structural_errors.find((e) => e.code === 'unresolved_scoped_ref')
    expect(misbind).toBeDefined()
    expect(JSON.stringify(misbind?.details)).toContain('w0')
  })

  // --- Cross-kind rejection ----------------------------------------------

  it('subsystem ref targeting a coupling library -> subsystem_ref_is_coupling_library', async () => {
    const p = cl('subsystem_ref_to_library.esm')
    const f = loadPath(p)
    expect(await errCodeAsync(() => resolveSubsystemRefs(f, path.dirname(p)))).toBe('subsystem_ref_is_coupling_library')
  })

  it('template import targeting a coupling library -> template_import_is_coupling_library', () => {
    const p = cl('template_import_to_library.esm')
    expect(errCode(() => load(readText(p), { basePath: path.dirname(p) }))).toBe('template_import_is_coupling_library')
  })

  // --- coupletype removal (schema failure) --------------------------------

  const coupletypeCases = ['coupletype_model.esm', 'coupletype_reaction_system.esm']
  it.each(coupletypeCases)('%s carrying coupletype fails schema validation', (file) => {
    const errors = validateSchema(readJson(cl(file)))
    expect(errors.length).toBeGreaterThan(0)
    expect(errors.some((e) => e.keyword === 'additionalProperties')).toBe(true)
  })
})
