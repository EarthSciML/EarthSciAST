/**
 * esm-spec §9.3: an `enum` op in a mounted file resolves against THAT file's
 * `enums` block, at either §4.7 mount form, and `enums` do not merge across the
 * mount.
 *
 * Issue #260: a mounted leaf's `enum` ops were not resolved in its own file, so
 * a leaf could compute with another file's constant. The fixtures are shared
 * with the other four bindings (`tests/conformance/mount_enums/`).
 */

import { readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { loadPath } from './parse.js'
import { resolveSubsystemRefs } from './ref-loading.js'

const here = path.dirname(fileURLToPath(import.meta.url))
const dir = path.resolve(here, '../../../tests/conformance/mount_enums')
const expected = JSON.parse(readFileSync(path.join(dir, 'expected.json'), 'utf8')) as {
  loads: Record<string, Record<string, number>>
  errors: Record<string, string>
}

async function load(fixture: string): Promise<Record<string, unknown>> {
  const file = loadPath(path.join(dir, fixture))
  await resolveSubsystemRefs(file, dir)
  return file as unknown as Record<string, unknown>
}

/** The right-hand side defining the variable at the end of `dotted`. */
function rhs(file: Record<string, unknown>, dotted: string): unknown {
  const parts = dotted.split('.')
  const variable = parts.pop() as string
  let node = (file.models as Record<string, any>)[parts[0] as string]
  for (const sub of parts.slice(1)) node = node.subsystems[sub]
  const eq = (node.equations as Array<{ lhs: unknown; rhs: unknown }>).find(
    (e) => e.lhs === variable,
  )
  return eq?.rhs
}

describe('mount_enums (esm-spec §9.3, issue #260)', () => {
  for (const [fixture, values] of Object.entries(expected.loads)) {
    it(`${fixture}: each mounted file's enum ops resolve against its own block`, async () => {
      const file = await load(fixture)
      for (const [dotted, want] of Object.entries(values)) {
        expect(rhs(file, dotted), dotted).toMatchObject({ op: 'const', value: want })
      }
    })
  }

  for (const [fixture, code] of Object.entries(expected.errors)) {
    it(`${fixture}: is refused with ${code}`, async () => {
      await expect(load(fixture)).rejects.toMatchObject({ code })
    })
  }
})
