/**
 * The documents of the geometry_templates conformance tier, which apply the
 * overlap-area templates of lib/geometry.esm. The TypeScript evaluator has no
 * `faq` rule, so it cannot evaluate an expanded template; this suite checks the
 * expansion instead: the import resolves, and the `expr` of every `faq` whose
 * body applied a template is that template's body with every parameter
 * occurrence (including the vertex-slot counts inside the body's `faq` `ranges`
 * bounds) replaced by the call's bindings (esm-spec §9.6.3 constraint 5), both
 * sides compared with the library's helper references expanded.
 */
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'fs'
import { join } from 'path'
import { loadPath } from './parse.js'
import type { Model } from './types.js'
import { REPO_ROOT } from './test-helpers.js'

// Test-local substitution oracle: every string other than an `op` name that
// equals a parameter is replaced by its binding. The geometry templates carry no
// nested `apply_expression_template`, whose `name` would be exempt.
function substitute(body: unknown, bindings: Record<string, unknown>): unknown {
  if (typeof body === 'string') return Object.hasOwn(bindings, body) ? bindings[body] : body
  if (Array.isArray(body)) return body.map((v) => substitute(v, bindings))
  if (body !== null && typeof body === 'object') {
    const out: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(body)) out[k] = k === 'op' ? v : substitute(v, bindings)
    return out
  }
  return body
}

// Replace every reference to a lib/geometry.esm helper (esm-spec §9.7.3, which a
// binding may keep unexpanded, §9.6.4) by the helper's body with its bindings
// substituted, recursively.
function expandRefs(node: unknown): unknown {
  if (Array.isArray(node)) return node.map(expandRefs)
  if (node !== null && typeof node === 'object') {
    const n = node as Record<string, unknown>
    if (n.op === 'apply_expression_template') {
      const bindings: Record<string, unknown> = {}
      for (const [k, v] of Object.entries((n.bindings ?? {}) as Record<string, unknown>))
        bindings[k] = expandRefs(v)
      return expandRefs(substitute(library.expression_templates[n.name as string].body, bindings))
    }
    const out: Record<string, unknown> = {}
    for (const [k, v] of Object.entries(n)) out[k] = expandRefs(v)
    return out
  }
  return node
}

const library = JSON.parse(readFileSync(join(REPO_ROOT, 'lib', 'geometry.esm'), 'utf-8'))

const planar = {
  ring_a: 'src_poly',
  cell_a: 'i',
  nv_a: 6,
  ring_b: 'tgt_poly',
  cell_b: 'j',
  nv_b: 6,
}
const spherical = {
  ring_a: 'src_xyz',
  cell_a: 'i',
  nv_a: 4,
  ring_b: 'tgt_xyz',
  cell_b: 'j',
  nv_b: 4,
}
const unit = (ring: string) => ({ ring, cell: 'c', vert: 'v', comp: 'd' })

const cases: Array<{
  fixture: string
  model: string
  calls: Record<string, [string, Record<string, unknown>]>
}> = [
  {
    fixture: 'planar_overlap.esm',
    model: 'GeometryPlanarOverlapTemplate',
    calls: {
      A_template: ['overlap_area_planar', planar],
      A_gated: ['overlap_area_planar', planar],
    },
  },
  {
    fixture: 'spherical_fan.esm',
    model: 'GeometrySphericalFanTemplate',
    calls: {
      A_template: ['overlap_area_spherical', spherical],
      src_xyz: ['lonlat_to_unit', unit('src_poly')],
      tgt_xyz: ['lonlat_to_unit', unit('tgt_poly')],
    },
  },
]

describe('lib/geometry.esm templates expand in the geometry_templates fixtures', () => {
  for (const tc of cases) {
    it(tc.fixture, () => {
      const path = join(
        REPO_ROOT,
        'tests',
        'conformance',
        'geometry_templates',
        'fixtures',
        tc.fixture,
      )
      const model = loadPath(path).models![tc.model] as Model
      let seen = 0
      for (const eq of model.equations) {
        if (typeof eq.lhs !== 'string' || !Object.hasOwn(tc.calls, eq.lhs)) continue
        seen++
        const [name, bindings] = tc.calls[eq.lhs]!
        const got = JSON.parse(JSON.stringify(eq.rhs)) as { expr: unknown }
        const want = JSON.parse(
          JSON.stringify(substitute(library.expression_templates[name].body, bindings)),
        )
        expect(expandRefs(got.expr), eq.lhs).toEqual(expandRefs(want))
      }
      expect(seen).toBe(Object.keys(tc.calls).length)
    })
  }
})
