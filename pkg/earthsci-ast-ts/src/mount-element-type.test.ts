/**
 * esm-spec §4.7 "Working precision crosses a mount" (CONFORMANCE_SPEC
 * §5.18.2b): a mounted document's `domain.element_type` does not merge, so the
 * mount edge writes it onto the variables of the component it splices in
 * whenever it differs from the mounting document's effective precision.
 *
 * The fixtures are shared with the other four bindings
 * (`tests/conformance/mount_element_type/`). This binding asserts the loader
 * contract (`loads`, `load_errors`); it has no numeric evaluator, so `values`
 * and `build_errors` belong to the bindings listed in `evaluated_by`.
 */

import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { loadPath, loadString } from './parse.js'
import { resolveSubsystemRefs } from './ref-loading.js'
import { toJson } from './serialize.js'

const here = path.dirname(fileURLToPath(import.meta.url))
const dir = path.resolve(here, '../../../tests/conformance/mount_element_type')
const expected = JSON.parse(readFileSync(path.join(dir, 'expected.json'), 'utf8')) as {
  loads: Record<
    string,
    { domain_element_type: string | null; element_types: Record<string, string | null> }
  >
  load_errors: Record<string, Record<string, string[]>>
}

type System = {
  variables?: Record<string, { element_type?: string }>
  subsystems?: Record<string, System>
}

/** Every variable (subsystems as `Model.Sub.var`) -> its `element_type`, or null. */
function carried(doc: { models?: Record<string, System> }): Record<string, string | null> {
  const out: Record<string, string | null> = {}
  const walk = (prefix: string, system: System): void => {
    for (const [name, decl] of Object.entries(system.variables ?? {})) {
      out[`${prefix}.${name}`] = decl.element_type ?? null
    }
    for (const [key, sub] of Object.entries(system.subsystems ?? {})) walk(`${prefix}.${key}`, sub)
  }
  for (const [name, model] of Object.entries(doc.models ?? {})) walk(name, model)
  return out
}

async function emitted(fixture: string): Promise<Record<string, unknown>> {
  const file = loadPath(path.join(dir, fixture))
  await resolveSubsystemRefs(file, dir)
  return JSON.parse(toJson(file)) as Record<string, unknown>
}

describe('mount_element_type (esm-spec §4.7 "Working precision crosses a mount")', () => {
  for (const [fixture, want] of Object.entries(expected.loads)) {
    it(`${fixture}: a mount writes exactly the leaf's differing precision`, async () => {
      const doc = await emitted(fixture)
      const domain = (doc.domain as { element_type?: string } | undefined)?.element_type ?? null
      expect(domain).toBe(want.domain_element_type)
      expect(carried(doc as { models?: Record<string, System> })).toEqual(want.element_types)
    })

    it(`${fixture}: the written fields round-trip`, async () => {
      const once = await emitted(fixture)
      const twice = JSON.parse(toJson(loadString(JSON.stringify(once)))) as Record<string, unknown>
      expect(carried(twice as { models?: Record<string, System> })).toEqual(
        carried(once as { models?: Record<string, System> }),
      )
    })
  }

  for (const [fixture, want] of Object.entries(expected.load_errors)) {
    // `load_errors` maps a fixture to `{code: [bindings]}`; a binding listed
    // under none must still refuse it.
    const code = Object.entries(want).find(([, bindings]) => bindings.includes('typescript'))?.[0]
    it(`${fixture}: a reaction system cannot carry a mounted precision`, async () => {
      let err: unknown
      try {
        const file = loadPath(path.join(dir, fixture))
        await resolveSubsystemRefs(file, dir)
      } catch (e) {
        err = e
      }
      expect(err).toBeDefined()
      if (code !== undefined) expect((err as { code?: string }).code).toBe(code)
    })
  }
})
