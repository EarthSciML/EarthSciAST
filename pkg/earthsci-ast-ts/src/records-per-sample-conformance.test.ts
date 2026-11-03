/**
 * Conformance: `from.records_per_sample` (esm-spec §8.5.1).
 *
 * Consumes `tests/conformance/records_per_sample/manifest.json`. A valid case
 * must validate, round-trip the field, and flatten with each data-fed
 * parameter's `LoaderField` reporting the EFFECTIVE value (the binding's own,
 * else the source's `temporal.records_per_sample`, else 1) and the flattened
 * parameter's `update.from` carrying the field as written. An invalid case
 * must be refused with `records_per_sample_invalid` at the pinned pointer.
 */
import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { loadPath } from './parse.js'
import { flatten } from './flatten.js'
import { toJson } from './serialize.js'
import { validate } from './validate.js'
import { REPO_ROOT } from './test-helpers.js'

const TIER = path.join(REPO_ROOT, 'tests', 'conformance', 'records_per_sample')

interface Case {
  id: string
  path: string
  expect: 'valid' | 'invalid'
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

describe('conformance: records_per_sample (esm-spec §8.5.1)', () => {
  for (const c of MANIFEST.cases) {
    it(c.id, () => {
      const file = loadPath(path.join(TIER, c.path))
      const result = validate(file)
      const found = result.structural_errors.filter((e) => e.code === 'records_per_sample_invalid')
      if (c.expect === 'invalid') {
        expect(found.map((e) => e.path)).toEqual([c.pointer])
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
      expect(writtenRecords(JSON.parse(toJson(file)))).toEqual(writtenRecords(raw))
    })
  }
})
