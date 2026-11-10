// The `argmin` / `argmax` templates of lib/relational.esm through every
// scenario of tests/conformance/relational_templates/scenarios.json. The
// TypeScript evaluator is scalar-only (no rule for `faq`), so this checks the
// expansion: the template import resolves, and each right-hand side is the
// template body with `f` (the candidate value over the template's loop symbol)
// and `n` (also inside the `faq` `ranges` bounds) replaced by the scenario's
// binding (esm-spec §9.6.3 constraint 5).
import { describe, it, expect } from 'vitest'
import { readFileSync } from 'fs'
import { join } from 'path'
import { loadPath, loadString } from './parse.js'
import { REPO_ROOT } from './test-helpers.js'
import type { Model } from './types.js'

interface Scenario {
  name: string
  op: 'argmin' | 'argmax'
  values: (number | string)[]
}

const libraryPath = join(REPO_ROOT, 'lib', 'relational.esm')
const tierDir = join(REPO_ROOT, 'tests', 'conformance', 'relational_templates')

// Test-local substitution oracle: every string other than an `op` name that
// equals a parameter is replaced by its binding.
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

// A candidate as num / den, so a non-finite one fits in a `const`.
function numDen(v: number | string): [number, number] {
  if (v === 'NaN') return [0, 0]
  if (v === 'Inf') return [1, 0]
  if (v === '-Inf') return [-1, 0]
  return [v as number, 1]
}

describe('lib/relational.esm argmin/argmax templates', () => {
  const library = JSON.parse(readFileSync(libraryPath, 'utf-8'))
  const scenarios: Scenario[] = JSON.parse(
    readFileSync(join(tierDir, 'scenarios.json'), 'utf-8'),
  ).scenarios

  it('declares argmin(f, n) and argmax(f, n)', () => {
    expect(library.expression_templates.argmin.params).toEqual(['f', 'n'])
    expect(library.expression_templates.argmax.params).toEqual(['f', 'n'])
  })

  it('expands every scenario to the substituted body', () => {
    const constArray = (v: number[]): unknown => ({ op: 'const', args: [], value: v })
    const calls = scenarios.map((sc) => {
      const sym = `k_${sc.op}_1`
      const pairs = sc.values.map(numDen)
      return {
        f: {
          op: '/',
          args: [
            { op: 'index', args: [constArray(pairs.map((p) => p[0])), sym] },
            { op: 'index', args: [constArray(pairs.map((p) => p[1])), sym] },
          ],
        },
        n: sc.values.length,
      }
    })
    const variables: Record<string, unknown> = {}
    calls.forEach((_, i) => {
      variables[`out_${i}`] = { type: 'unknown', default: 0.0, units: '1' }
    })
    const doc = {
      esm: '2.0.0',
      metadata: { name: 'relational_templates' },
      models: {
        Probe: {
          expression_template_imports: [{ ref: libraryPath }],
          variables,
          equations: calls.map((bindings, i) => ({
            lhs: { op: 'D', args: [`out_${i}`], wrt: 't' },
            rhs: { op: 'apply_expression_template', args: [], name: scenarios[i]!.op, bindings },
          })),
        },
      },
    }
    const equations = (loadString(JSON.stringify(doc)).models!.Probe as Model).equations
    expect(equations).toHaveLength(calls.length)
    equations.forEach((eq, i) => {
      const body = library.expression_templates[scenarios[i]!.op].body
      const got = JSON.parse(JSON.stringify(eq.rhs))
      const want = JSON.parse(JSON.stringify(substitute(body, calls[i]!)))
      expect(got, scenarios[i]!.name).toEqual(want)
    })
  })

  for (const name of ['argmin_template.esm', 'nearest_generator_template_ode.esm']) {
    it(`loads the tier document ${name} with no template reference left`, () => {
      const file = loadPath(join(tierDir, 'fixtures', name))
      for (const m of Object.values(file.models ?? {})) {
        for (const eq of (m as Model).equations) {
          expect(JSON.stringify(eq.rhs)).not.toContain('apply_expression_template')
        }
      }
    })
  }

  it('expands the key, rank and gated arg-witness templates', () => {
    const constArray = (v: number[]): unknown => ({ op: 'const', args: [], value: v })
    const idx = (sym: string): unknown => ({ op: 'index', args: [constArray([3, 1, 2]), sym] })
    const calls: [string, Record<string, unknown>][] = [
      ['pair_key', { a: 2, b: 3, lo_a: 1, lo_b: 1, n_a: 4, n_b: 5 }],
      ['edge_key', { u: 4, v: 2, lo: 1, n: 5 }],
      ['rank_of', { x: 7, members: constArray([1, 3, 7]), n: 3 }],
      ['rank_of_set', { x: 7, members: 'm', S: 'cells' }],
      [
        'argmin_where',
        { f: idx('k_argmin_where_1'), p: { op: '>', args: [idx('k_argmin_where_1'), 1] }, n: 3 },
      ],
      [
        'argmax_where',
        { f: idx('k_argmax_where_1'), p: { op: '>', args: [idx('k_argmax_where_1'), 1] }, n: 3 },
      ],
    ]
    const variables: Record<string, unknown> = {
      m: { type: 'parameter', shape: ['cells'], default: 0.0, units: '1' },
    }
    calls.forEach((_, i) => {
      variables[`out_${i}`] = { type: 'unknown', default: 0.0, units: '1' }
    })
    const doc = {
      esm: '2.0.0',
      metadata: { name: 'relational_key_templates' },
      index_sets: { cells: { kind: 'interval', size: 3 } },
      models: {
        Probe: {
          expression_template_imports: [{ ref: libraryPath }],
          variables,
          equations: calls.map(([name, bindings], i) => ({
            lhs: { op: 'D', args: [`out_${i}`], wrt: 't' },
            rhs: { op: 'apply_expression_template', args: [], name, bindings },
          })),
        },
      },
    }
    const equations = (loadString(JSON.stringify(doc)).models!.Probe as Model).equations
    equations.forEach((eq, i) => {
      const [name, bindings] = calls[i]!
      const want = JSON.parse(
        JSON.stringify(substitute(library.expression_templates[name].body, bindings)),
      )
      expect(JSON.parse(JSON.stringify(eq.rhs)), name).toEqual(want)
    })
  })

  it('loads every template rewrite of the skolem / rank / gated-argmin fixtures', () => {
    const manifest = JSON.parse(readFileSync(join(tierDir, 'rewrites', 'manifest.json'), 'utf-8'))
    for (const e of manifest.rewrites as { id: string; out?: string }[]) {
      const path = e.out ? join(REPO_ROOT, e.out) : join(tierDir, 'rewrites', `${e.id}.esm`)
      const file = loadPath(path)
      for (const m of Object.values(file.models ?? {})) {
        for (const eq of (m as Model).equations) {
          expect(JSON.stringify(eq.rhs), e.id).not.toContain('apply_expression_template')
        }
      }
    }
  })
})
