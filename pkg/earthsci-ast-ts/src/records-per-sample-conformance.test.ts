/**
 * Conformance: record axes and the deprecated `records_per_sample`
 * (esm-spec §8.5.1).
 *
 * Consumes `tests/conformance/records_per_sample/manifest.json`. A valid case
 * must validate with none of `record_codes`, flatten with each listed
 * `LoaderField` reporting the number of records its record shape gives, keep
 * the deprecated field as written on the flattened parameter, keep both that
 * field and each index set's `records` flag through emit then load, and have
 * `deprecatedRecordsPerSampleSites` return exactly `deprecated_fields` (with
 * the load warning emitted exactly when that list is non-empty). An `invalid`
 * case must be refused by validation with exactly one diagnostic from
 * `record_codes`; a `flatten_invalid` case must validate clean of them and then
 * be refused by `flatten`; a `refused` case must be refused by whichever stage
 * first sees the record shape.
 *
 * `loadPath` does not mount `{ref}` components, so every case is validated
 * first as loaded (where a target behind a ref is not decidable and must not
 * be refused) and then again after `resolveSubsystemRefsSync` mounts the refs.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { loadPath, loadString } from './parse.js'
import { flatten } from './flatten.js'
import { toJson } from './serialize.js'
import { validate } from './validate.js'
import { resolveSubsystemRefsSync } from './ref-loading.js'
import { EsmDiagnosticError } from './errors.js'
import { deprecatedRecordsPerSampleSites } from './records-per-sample.js'
import { REPO_ROOT } from './test-helpers.js'
import type { EsmFile } from './types.js'

const TIER = path.join(REPO_ROOT, 'tests', 'conformance', 'records_per_sample')

interface Case {
  id: string
  path: string
  expect: 'valid' | 'invalid' | 'flatten_invalid' | 'refused'
  code?: string
  pointer?: string
  loader_fields?: Array<{
    name: string
    source: string
    file_variable: string
    cadence: string
    records_per_sample: number
  }>
  flattened_from_records_per_sample?: Record<string, number | null>
  deprecated_fields?: string[]
}

const MANIFEST = JSON.parse(fs.readFileSync(path.join(TIER, 'manifest.json'), 'utf8')) as {
  record_codes: string[]
  deprecation_warning: string
  cases: Case[]
}
const RECORD_CODES = new Set(MANIFEST.record_codes)

/** Every written `records_per_sample` of a raw document (`null` = absent). */
function writtenRecords(doc: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  const models = (doc.models ?? {}) as Record<string, { variables?: Record<string, any> }>
  for (const [m, model] of Object.entries(models)) {
    for (const [v, variable] of Object.entries(model.variables ?? {})) {
      const rules = Array.isArray(variable?.update) ? variable.update : [variable?.update]
      rules.forEach((rule: any, i: number) => {
        if (rule?.from !== undefined) {
          out[`${m}.${v}#${i}`] = rule.from.records_per_sample ?? null
        }
      })
    }
  }
  const sources = (doc.data_sources ?? {}) as Record<string, any>
  for (const [s, source] of Object.entries(sources)) {
    out[`source:${s}`] = source?.temporal?.records_per_sample ?? null
  }
  return out
}

/** Each index set's `records` flag (`null` when absent). */
function recordFlags(doc: Record<string, unknown>): Record<string, unknown> {
  const sets = (doc.index_sets ?? {}) as Record<string, { records?: boolean }>
  return Object.fromEntries(Object.entries(sets).map(([n, s]) => [n, s.records ?? null]))
}

/** The `record_codes` diagnostics validation reports, as `{code, pointer}`. */
function recordFindings(file: EsmFile): Array<{ code: string; pointer: string }> {
  return validate(file)
    .structural_errors.filter((e) => RECORD_CODES.has(e.code))
    .map((e) => ({ code: e.code, pointer: e.path }))
}

/** The coded diagnostic `flatten(file)` throws, or `undefined` when it succeeds. */
function flattenRefusal(file: EsmFile): EsmDiagnosticError | undefined {
  try {
    flatten(file)
  } catch (err) {
    if (err instanceof EsmDiagnosticError) return err
    throw err
  }
  return undefined
}

/** Assert that `err` is the case's refusal at its pointer. */
function expectRefusal(err: EsmDiagnosticError | undefined, c: Case): void {
  expect(err, 'flatten must refuse').toBeDefined()
  expect(err!.code).toBe(c.code)
  const named = err!.message.includes(c.pointer!) || err!.details?.path === c.pointer
  expect(named, `${err!.message} must name ${c.pointer}`).toBe(true)
}

/** Load, returning the file and the deprecation warnings the load gave. */
function loadCounting(casePath: string): { file: EsmFile; warnings: string[] } {
  const spy = vi.spyOn(console, 'warn').mockImplementation(() => {})
  try {
    const file = loadPath(casePath)
    const warnings = spy.mock.calls
      .map((call) => String(call[0]))
      .filter((m) => m.startsWith(`${MANIFEST.deprecation_warning}:`))
    return { file, warnings }
  } finally {
    spy.mockRestore()
  }
}

describe('conformance: record axes (esm-spec §8.5.1)', () => {
  afterEach(() => vi.restoreAllMocks())

  for (const c of MANIFEST.cases) {
    it(c.id, () => {
      const casePath = path.join(TIER, c.path)
      const { file: asLoaded, warnings } = loadCounting(casePath)
      const loadedFindings = recordFindings(asLoaded)
      if (c.expect === 'invalid') {
        expect(loadedFindings).toEqual([{ code: c.code, pointer: c.pointer }])
        return
      }
      // Nothing behind an unmounted ref, or arriving by coupling_import, is
      // refused by validation of the document as loaded.
      expect(loadedFindings).toEqual([])
      if (c.expect === 'flatten_invalid') {
        expectRefusal(flattenRefusal(asLoaded), c)
        return
      }

      const file = loadCounting(casePath).file
      resolveSubsystemRefsSync(file, path.dirname(casePath))
      const result = validate(file)
      const found = result.structural_errors
        .filter((e) => RECORD_CODES.has(e.code))
        .map((e) => ({ code: e.code, pointer: e.path }))
      if (c.expect === 'refused') {
        if (found.length > 0) expect(found).toEqual([{ code: c.code, pointer: c.pointer }])
        else expectRefusal(flattenRefusal(file), c)
        return
      }
      expect(found).toEqual([])
      expect(result.schema_errors).toEqual([])

      // Deprecated sites, and one load warning exactly when there are any.
      const deprecated = c.deprecated_fields ?? []
      expect(deprecatedRecordsPerSampleSites(asLoaded)).toEqual(deprecated)
      expect(warnings).toHaveLength(deprecated.length > 0 ? 1 : 0)
      if (deprecated.length > 0) expect(warnings[0]).toContain(deprecated.join(', '))

      const flat = flatten(file)
      for (const want of c.loader_fields ?? []) {
        const lf = flat.loaderFields.find((f) => f.name === want.name)
        expect(lf, want.name).toBeDefined()
        expect({
          name: lf!.name,
          source: lf!.subkey,
          file_variable: lf!.var,
          cadence: lf!.cadence,
          records_per_sample: lf!.recordsPerSample,
        }).toEqual(want)
      }
      for (const [name, written] of Object.entries(c.flattened_from_records_per_sample ?? {})) {
        const update = (flat.parameters as Record<string, any>)[name]?.update
        expect(update?.from?.records_per_sample ?? null, name).toEqual(written)
      }

      // emit then load keeps the deprecated field and every `records` flag.
      const raw = JSON.parse(fs.readFileSync(casePath, 'utf8'))
      const emitted = JSON.parse(toJson(asLoaded))
      expect(writtenRecords(emitted)).toEqual(writtenRecords(raw))
      expect(recordFlags(emitted)).toEqual(recordFlags(raw))
      const reloaded = loadString(toJson(asLoaded), {
        basePath: path.dirname(casePath),
        warn: false,
      })
      expect(deprecatedRecordsPerSampleSites(reloaded)).toEqual(deprecated)
      expect(recordFlags(JSON.parse(toJson(reloaded)))).toEqual(recordFlags(raw))
    })
  }
})
