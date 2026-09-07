/**
 * Conformance harness adapter — `operator_compose` merge intent (TypeScript).
 *
 * Driven by the shared manifest at
 * `tests/conformance/operator_compose_merge/manifest.json`
 * (esm-libraries-spec §4.7.1 steps 3 and 5; EarthSciML/EarthSciAST#195).
 *
 * Three things are pinned, and they are distinct:
 *
 * 1. An entry that merges NOTHING is `operator_compose_no_merge`, a hard
 *    refusal: such an entry is indistinguishable from one that is not there. A
 *    PARTIAL merge stays a warning, because an operator may legitimately
 *    contribute states of its own alongside the ones it does merge.
 * 2. `require_match` is TRI-STATE and absent is not `false` — absent means "the
 *    author has not said" (zero-merge refuses), `true` makes ANY shortfall
 *    fatal, `false` DECLARES a standalone-contributing operator and silences
 *    both. Each state has a non-vacuity anchor, so a binding cannot pass by
 *    being uniformly strict or uniformly lax.
 * 3. A bare-name match that would unify two STATES is
 *    `operator_compose_ambiguous_bare_name`, a refusal: each carries its own
 *    initial condition and the merge keeps one, which is exactly the silent
 *    choice that made the `systems` order matter. Where only one side is a state
 *    the match is unambiguous and the state owns the quantity.
 *
 * Unlike the flatten corpus this category carries no golden: it compares
 * DIAGNOSTIC OUTCOMES, so each binding asserts its own idiomatic surface. Here
 * that is `console.warn` and the three error classes.
 */

import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { readFileSync } from 'fs'
import { dirname, join } from 'path'
import { fileURLToPath } from 'url'
import { flatten, loadString, toJson } from './index'
import {
  OperatorComposeAmbiguousBareNameError,
  OperatorComposeNoMergeError,
  OperatorComposeRequireMatchError,
} from './flatten'
import type { FlattenError } from './flatten'

const here = dirname(fileURLToPath(import.meta.url))
const categoryDir = join(here, '..', '..', '..', 'tests', 'conformance', 'operator_compose_merge')

interface MergeCase {
  id: string
  path: string
  outcome: 'warning' | 'refused' | 'clean'
  code: string | null
  require_match?: boolean | string
  merged?: number
  authored?: number
  unmatched?: string[]
  unified?: string[]
  state_variables?: string[]
  systems?: string[]
  surviving_state?: string
  surviving_default?: number
}

interface Manifest {
  bindings_required: string[]
  codes: Record<string, string>
  diagnostic_surface: { errors: Record<string, Record<string, string>> }
  cases: MergeCase[]
}

// A missing manifest is a hard failure, not a skip: the manifest IS the
// contract this file exists to enforce.
const manifest = JSON.parse(readFileSync(join(categoryDir, 'manifest.json'), 'utf-8')) as Manifest

/** The refusal each code maps to in THIS binding — asserted, not assumed. */
const ERROR_FOR_CODE: Record<string, new (m: string) => FlattenError> = {
  operator_compose_no_merge: OperatorComposeNoMergeError,
  operator_compose_require_match_unmatched: OperatorComposeRequireMatchError,
  operator_compose_ambiguous_bare_name: OperatorComposeAmbiguousBareNameError,
}

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

/**
 * The observable outcome of a fixture: either the refusal's class name, or the
 * surviving states paired with their defaults. Compared BETWEEN two runs that
 * must agree, rather than each against a recorded value.
 */
function outcomeOf(testCase: MergeCase): unknown {
  try {
    const system = flatten(loadFixture(testCase.path))
    return Object.entries(system.stateVariables).map(([n, v]) => [n, v.default])
  } catch (error) {
    return (error as Error).name
  }
}

describe('conformance: operator_compose merge intent', () => {
  it('the manifest is not empty and covers this binding', () => {
    // A manifest that silently listed zero cases would make every assertion
    // below vacuously green.
    expect(manifest.cases.length).toBeGreaterThan(0)
    expect(manifest.bindings_required).toContain('typescript')
    expect(manifest.codes.operator_compose_partial_merge).toBe('warning')
    for (const code of Object.keys(ERROR_FOR_CODE)) {
      expect(manifest.codes[code]).toBe('error')
      // The manifest names an error type per binding per code; reading
      // TypeScript's column back keeps the record from drifting silently.
      expect(manifest.diagnostic_surface.errors[code].typescript).toBe(
        ERROR_FOR_CODE[code].name,
      )
    }
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
        expect(thrown).toBeInstanceOf(ERROR_FOR_CODE[testCase.code as string])
        const message = (thrown as Error).message
        expect(message.startsWith(testCase.code as string)).toBe(true)
        for (const name of [...(testCase.unmatched ?? []), ...(testCase.unified ?? [])]) {
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
        expect(found[0]).toContain(`merged ${testCase.merged} of ${testCase.authored} equations`)
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

  it('the `require_match` truth table is covered', () => {
    // The table is the whole of `require_match`'s meaning, and its three states
    // are three different things an author can mean. A column with no case is a
    // column a binding could get wrong without failing anything.
    const covered = new Set(
      manifest.cases.map((c) => `${String(c.require_match)}|${c.outcome}`),
    )
    expect(covered).toContain('absent|refused')
    expect(covered).toContain('absent|warning')
    expect(covered).toContain('absent|clean')
    expect(covered).toContain('true|refused')
    expect(covered).toContain('true|clean')
    expect(covered).toContain('false|clean')
    expect(covered).not.toContain('false|refused')
  })

  it('flipping the `systems` order changes nothing observable', () => {
    // Issue #195 Symptom 1, in the form that fails under the old rule. Two pairs
    // of fixtures, each differing ONLY in the `systems` array's order. The
    // AMBIGUOUS pair used to produce different state names carrying different
    // initial conditions — an argument order choosing an IC.
    const byId = new Map(manifest.cases.map((c) => [c.id, c]))
    for (const [left, right] of [
      ['ambiguous_bare_name', 'ambiguous_bare_name_flipped'],
      ['owner_rename_state_wins_observed_first', 'owner_rename_state_wins_state_first'],
    ]) {
      const a = byId.get(left)!
      const b = byId.get(right)!
      expect(a.systems).toEqual([...b.systems!].reverse())
      expect(outcomeOf(a)).toEqual(outcomeOf(b))
    }
  })

  it('the ambiguity refusal is not a blanket ban on bare names', () => {
    // The two ways out both still work: `translate` names the surviving spelling
    // outright, and a match where only ONE side is a STATE is not ambiguous at
    // all. Without this a binding could pass every refusal by refusing the whole
    // bare-name fallback.
    const byId = new Map(manifest.cases.map((c) => [c.id, c]))
    const resolved = flatten(loadFixture(byId.get('ambiguous_resolved_by_translate')!.path))
    expect(Object.keys(resolved.stateVariables)).toEqual(['Chem.O3'])
    expect(resolved.stateVariables['Chem.O3'].default).toBe(30.0)

    const owned = flatten(
      loadFixture(byId.get('owner_rename_state_wins_observed_first')!.path),
    )
    expect(Object.keys(owned.stateVariables)).toEqual(['Sink.O3'])
    expect(owned.stateVariables['Sink.O3'].default).toBe(40.0)
  })

  it('`require_match` round-trips, an explicit `false` included', () => {
    // The flag is TRI-STATE, so an explicit `false` must survive the round trip
    // — dropping it as "the default" would silently re-arm the zero-merge
    // refusal on every document that opted out. An ABSENT flag must stay absent
    // for the same reason, in the other direction.
    const emitted = (name: string) =>
      JSON.parse(toJson(loadFixture(join('fixtures', name))))
    expect(emitted('require_match_unmatched.esm').coupling[0].require_match).toBe(true)
    expect(emitted('no_merge_declared.esm').coupling[0].require_match).toBe(false)
    expect('require_match' in emitted('partial_merge.esm').coupling[0]).toBe(false)
  })
})
