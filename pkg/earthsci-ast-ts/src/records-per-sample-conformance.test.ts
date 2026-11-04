/**
 * Conformance: `from.records_per_sample` (esm-spec §8.5.1).
 *
 * Consumes `tests/conformance/records_per_sample/manifest.json`. A valid case
 * must validate, round-trip the field, and flatten with each data-fed
 * parameter's `LoaderField` reporting the EFFECTIVE value (the binding's own,
 * else the source's `temporal.records_per_sample`, else 1) and the flattened
 * parameter's `update.from` carrying the field as written. An `invalid` case
 * must be refused by validation with exactly one `records_per_sample_invalid`
 * at the pinned pointer; a `flatten_invalid` case must validate clean of that
 * code and then be refused by `flatten` with it; a `refused` case must be
 * refused with it by whichever stage first sees the record shape.
 *
 * `loadPath` does not mount `{ref}` components, so every case is validated
 * first as loaded (where a target behind a ref is not decidable and must not
 * be refused) and then again after `resolveSubsystemRefsSync` mounts the refs.
 */
import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { loadPath } from './parse.js'
import { flatten } from './flatten.js'
import { toJson } from './serialize.js'
import { validate } from './validate.js'
import { resolveSubsystemRefsSync } from './ref-loading.js'
import { EsmDiagnosticError } from './errors.js'
import { REPO_ROOT } from './test-helpers.js'

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
}

const MANIFEST = JSON.parse(fs.readFileSync(path.join(TIER, 'manifest.json'), 'utf8')) as {
  cases: Case[]
}

/** `update.from.records_per_sample` of each parameter of a raw document. */
function writtenRecords(doc: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  const models = (doc.models ?? {}) as Record<string, { variables?: Record<string, any> }>
  for (const [m, model] of Object.entries(models)) {
    for (const [v, variable] of Object.entries(model.variables ?? {})) {
      const from = variable?.update?.from
      if (from !== undefined) out[`${m}.${v}`] = from.records_per_sample ?? null
    }
  }
  return out
}

const CODE = 'records_per_sample_invalid'

/** The pointers of every `records_per_sample_invalid` validation reports. */
function validationPointers(file: ReturnType<typeof loadPath>): string[] {
  return validate(file)
    .structural_errors.filter((e) => e.code === CODE)
    .map((e) => e.path)
}

/** The coded diagnostic `flatten(file)` throws, or `undefined` when it succeeds. */
function flattenRefusal(file: ReturnType<typeof loadPath>): EsmDiagnosticError | undefined {
  try {
    flatten(file)
  } catch (err) {
    if (err instanceof EsmDiagnosticError) return err
    throw err
  }
  return undefined
}

/** Assert that `err` is the rule's refusal at `pointer`. */
function expectRefusalAt(err: EsmDiagnosticError | undefined, pointer: string): void {
  expect(err, 'flatten must refuse').toBeDefined()
  expect(err!.code).toBe(CODE)
  const named = err!.message.includes(pointer) || err!.details?.path === pointer
  expect(named, `${err!.message} must name ${pointer}`).toBe(true)
}

describe('conformance: records_per_sample (esm-spec §8.5.1)', () => {
  for (const c of MANIFEST.cases) {
    it(c.id, () => {
      const casePath = path.join(TIER, c.path)
      const asLoaded = loadPath(casePath)
      const loadedPointers = validationPointers(asLoaded)
      if (c.expect === 'invalid') {
        expect(loadedPointers).toEqual([c.pointer])
        return
      }
      // Nothing behind an unmounted ref, or arriving by coupling_import, is
      // refused by validation of the document as loaded.
      expect(loadedPointers).toEqual([])
      if (c.expect === 'flatten_invalid') {
        expectRefusalAt(flattenRefusal(asLoaded), c.pointer!)
        return
      }

      const file = loadPath(casePath)
      resolveSubsystemRefsSync(file, path.dirname(casePath))
      const result = validate(file)
      const found = result.structural_errors.filter((e) => e.code === CODE)
      if (c.expect === 'refused') {
        if (found.length > 0) expect(found.map((e) => e.path)).toEqual([c.pointer])
        else expectRefusalAt(flattenRefusal(file), c.pointer!)
        return
      }
      expect(found).toEqual([])
      expect(result.schema_errors).toEqual([])
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
      const raw = JSON.parse(fs.readFileSync(path.join(TIER, c.path), 'utf8'))
      expect(writtenRecords(JSON.parse(toJson(asLoaded)))).toEqual(writtenRecords(raw))
    })
  }
})
