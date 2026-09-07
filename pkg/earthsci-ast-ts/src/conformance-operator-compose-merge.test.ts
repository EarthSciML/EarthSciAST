/**
 * Conformance harness adapter — `operator_compose` merge intent (TypeScript).
 *
 * Driven by the shared manifest at
 * `tests/conformance/operator_compose_merge/manifest.json`
 * (esm-libraries-spec §4.7.1 steps 3 and 5; EarthSciML/EarthSciAST#195).
 *
 * Three things are pinned, and they are distinct:
 *
 * 1. The merge TALLY is reported — `operator_compose_no_merge` when nothing
 *    landed, `operator_compose_partial_merge` when only some did, both naming
 *    the unmatched dependent variables. Step 5 still preserves the equations;
 *    it is no longer SILENT about doing so, because silence made "merged
 *    everything" and "merged nothing" the same observable outcome.
 * 2. `require_match: true` promotes either to a hard refusal, and a PARTIAL
 *    match refuses exactly as a zero match does. `require_match_satisfied` is
 *    the non-vacuity anchor that keeps the flag from being simply always-fatal.
 * 3. The BARE-NAME fallback's surviving spelling follows the state's OWNER —
 *    the component the document declares first — not `systems[0]`, so an entry
 *    means the same thing in either argument order.
 *
 * Unlike the flatten corpus this category carries no golden: it compares
 * DIAGNOSTIC OUTCOMES, so each binding asserts its own idiomatic surface. Here
 * that is `console.warn` and {@link OperatorComposeRequireMatchError}.
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { readFileSync } from 'fs'
import { dirname, join } from 'path'
import { fileURLToPath } from 'url'
import { flatten, loadString, toJson } from './index'
import { OperatorComposeRequireMatchError } from './flatten'

const here = dirname(fileURLToPath(import.meta.url))
const categoryDir = join(here, '..', '..', '..', 'tests', 'conformance', 'operator_compose_merge')

interface MergeCase {
  id: string
  path: string
  outcome: 'warning' | 'refused' | 'clean'
  code: string | null
  merged?: number
  authored?: number
  unmatched?: string[]
  state_variables?: string[]
  models_declared?: string[]
  systems?: string[]
  surviving_state?: string
  surviving_default?: number
}

interface Manifest {
  category: string
  bindings_required: string[]
  codes: Record<string, string>
  cases: MergeCase[]
}

// A missing manifest is a hard failure, not a skip: the manifest IS the
// contract this file exists to enforce.
const manifest = JSON.parse(readFileSync(join(categoryDir, 'manifest.json'), 'utf-8')) as Manifest

/** Captured `console.warn` lines from one flatten, filtered to this category. */
let captured: string[] = []
let originalWarn: typeof console.warn

beforeEach(() => {
  captured = []
  originalWarn = console.warn
  console.warn = (...args: unknown[]) => {
    captured.push(args.map(String).join(' '))
  }
})

afterEach(() => {
  console.warn = originalWarn
})

function loadFixture(relPath: string) {
  return loadString(readFileSync(join(categoryDir, relPath), 'utf-8'))
}

function diagnostics(): string[] {
  return captured.filter((line) => line.startsWith('operator_compose_'))
}

describe('conformance: operator_compose merge intent', () => {
  it('the manifest is not empty and covers this binding', () => {
    // A manifest that silently listed zero cases would make every assertion
    // below vacuously green.
    expect(manifest.cases.length).toBeGreaterThan(0)
    expect(manifest.bindings_required).toContain('typescript')
    expect(Object.keys(manifest.codes).sort()).toEqual([
      'operator_compose_no_merge',
      'operator_compose_partial_merge',
      'operator_compose_require_match_unmatched',
    ])
  })

  for (const testCase of manifest.cases) {
    it(`${testCase.id}: ${testCase.outcome}`, () => {
      if (testCase.outcome === 'refused') {
        let thrown: unknown
        try {
          flatten(loadFixture(testCase.path))
        } catch (error) {
          thrown = error
        }
        expect(thrown).toBeInstanceOf(OperatorComposeRequireMatchError)
        const message = (thrown as Error).message
        expect(message.startsWith(testCase.code as string)).toBe(true)
        for (const name of testCase.unmatched ?? []) {
          expect(message).toContain(name)
        }
        return
      }

      const system = flatten(loadFixture(testCase.path))
      const found = diagnostics()

      if (testCase.outcome === 'clean') {
        expect(found).toEqual([])
      } else {
        expect(found).toHaveLength(1)
        expect(found[0].startsWith(testCase.code as string)).toBe(true)
        // The tally and the unmatched names are the content that makes the
        // diagnostic actionable; a code with no names is a shrug.
        expect(found[0]).toContain(
          `merged ${testCase.merged} of ${testCase.authored} equations`,
        )
        for (const name of testCase.unmatched ?? []) {
          expect(found[0]).toContain(name)
        }
      }

      if (testCase.state_variables !== undefined) {
        expect(Object.keys(system.stateVariables)).toEqual(testCase.state_variables)
      }
      if (testCase.surviving_state !== undefined) {
        expect(system.stateVariables[testCase.surviving_state].default).toBe(
          testCase.surviving_default,
        )
      }
    })
  }

  it('flipping the `systems` order changes nothing observable', () => {
    // Issue #195 Symptom 1, in the form that fails under the old rule. Two
    // fixtures with identical models in identical declaration order, differing
    // ONLY in the `systems` array's order. The tendency is arithmetically
    // identical either way, so the surviving NAME and its DEFAULT are the entire
    // observable difference — compared between the two RUNS rather than only
    // against the manifest, so this fails on disagreement even if both were
    // re-recorded.
    const byId = new Map(manifest.cases.map((c) => [c.id, c]))
    const a = byId.get('owner_rename_operator_first')!
    const b = byId.get('owner_rename_mechanism_listed_first')!
    expect(a.models_declared).toEqual(b.models_declared)
    expect(a.systems).toEqual([...b.systems!].reverse())

    const surviving = (c: MergeCase) => {
      const system = flatten(loadFixture(c.path))
      const names = Object.keys(system.stateVariables)
      expect(names).toHaveLength(1)
      return [names[0], system.stateVariables[names[0]].default] as const
    }
    expect(surviving(a)).toEqual(surviving(b))
  })

  it('declaration order decides, not argument order', () => {
    // The companion to the test above, and what keeps it from being trivial:
    // the same `systems` order with the models declared the other way round
    // must produce the OTHER name. A binding that hard-coded either answer, or
    // that kept renaming onto `systems[0]`, fails one of the two.
    const byId = new Map(manifest.cases.map((c) => [c.id, c]))
    const a = byId.get('owner_rename_operator_first')!
    const b = byId.get('owner_rename_mechanism_declared_first')!
    expect(a.systems).toEqual(b.systems)
    expect(a.models_declared).toEqual([...b.models_declared!].reverse())

    expect(Object.keys(flatten(loadFixture(a.path)).stateVariables)).toEqual(['Sink.O3'])
    expect(Object.keys(flatten(loadFixture(b.path)).stateVariables)).toEqual(['Chem.O3'])
  })

  it('`require_match` survives a round trip, and its default is not emitted', () => {
    // A flag that silently vanished on save would make the refusal
    // unreproducible from the file the author kept; emitting the `false` default
    // would put a key on every existing fixture and break load preservation.
    const set = JSON.parse(toJson(loadFixture('fixtures/require_match_unmatched.esm')))
    expect(set.coupling[0].require_match).toBe(true)
    const unset = JSON.parse(toJson(loadFixture('fixtures/no_merge.esm')))
    expect('require_match' in unset.coupling[0]).toBe(false)
  })
})
