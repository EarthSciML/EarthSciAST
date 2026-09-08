/**
 * Conformance harness adapter — merged-away rename REACH (TypeScript).
 *
 * Driven by the shared manifest at
 * `tests/conformance/merged_rename_reach/manifest.json`
 * (esm-libraries-spec §4.7.1 step 4 and §4.7.5 step 3 ordering;
 * EarthSciML/EarthSciAST#230).
 *
 * An `operator_compose` renaming match folds `B.x` into `A.x`, deleting `B.x`
 * and rewriting every equation off it. That rewrite reaches equation ASTs and
 * nothing else, and `operator_compose` entries run BEFORE `couple` and
 * `variable_map` — so a later entry's `from` / `to`, plain scoped-reference
 * STRINGS on the entry object, could still name a spelling that no longer
 * exists. This pins that they RESOLVE to the survivor.
 *
 * Only the `flatten` surface binds here: the manifest excludes TypeScript from
 * the `override_keys` surface, because this binding has no simulator and so no
 * override-key surface at all.
 */

import { readFileSync } from 'fs'
import { dirname, join } from 'path'
import { fileURLToPath } from 'url'
import { describe, expect, it } from 'vitest'
import { flatten, loadString, toAscii } from './index'
import type { Expression } from './types'

const here = dirname(fileURLToPath(import.meta.url))
const categoryDir = join(here, '..', '..', '..', 'tests', 'conformance', 'merged_rename_reach')

interface ReachCase {
  id: string
  path: string
  surface: 'flatten' | 'override_keys'
  merged_variable_renames?: Record<string, string>
  state_variables?: string[]
  tendency_of?: string
  tendency_references?: string[]
  no_equation_references?: string[]
}

interface Manifest {
  cases: ReachCase[]
  surfaces: Record<string, { bindings: string[]; scope_excluded?: Record<string, string> }>
  merged_variable_renames_field: Record<string, string>
}

const manifest = JSON.parse(readFileSync(join(categoryDir, 'manifest.json'), 'utf-8')) as Manifest
const flattenCases = manifest.cases.filter((c) => c.surface === 'flatten')

function flattenCase(c: ReachCase) {
  return flatten(loadString(readFileSync(join(categoryDir, c.path), 'utf-8')))
}

/** The dependent variable an equation LHS defines, `undefined` for none. */
function dependentVar(lhs: Expression): string | undefined {
  if (typeof lhs === 'string') return lhs
  if (typeof lhs === 'object' && lhs !== null && 'op' in lhs) {
    const node = lhs as { op: string; args?: unknown[] }
    if (node.op === 'D' && node.args !== undefined && node.args.length > 0) {
      return dependentVar(node.args[0] as Expression)
    }
  }
  return undefined
}

describe('conformance: merged_rename_reach (esm-libraries-spec §4.7.1 step 4)', () => {
  it('the manifest is not empty and lists this binding', () => {
    // A manifest that silently listed zero cases would make every test below
    // vacuously green.
    expect(flattenCases.length).toBeGreaterThan(0)
    expect(manifest.surfaces.flatten.bindings).toContain('typescript')
    // …and both runtime halves are recorded as OUT of scope here, each with a
    // reason. This binding has no simulator, so it has neither an override-key
    // surface nor a result object to read by name; asserting the exclusion is
    // what keeps it from quietly becoming a gap.
    for (const surface of ['override_keys', 'output_selection'] as const) {
      expect(manifest.surfaces[surface].bindings).not.toContain('typescript')
      expect(manifest.surfaces[surface].scope_excluded?.typescript).toBeTruthy()
    }
    expect(manifest.merged_variable_renames_field.typescript).toBe(
      'FlattenMetadata.mergedVariableRenames',
    )
  })

  for (const c of flattenCases) {
    describe(c.id, () => {
      it('records which names the merge deleted', () => {
        // The rename map is what a consumer addressing a state by name resolves
        // through, so it is part of the flattened form's contract.
        const flat = flattenCase(c)
        expect(flat.metadata.mergedVariableRenames).toEqual(c.merged_variable_renames)
      })

      it('leaves the merged-away name surviving nowhere', () => {
        const flat = flattenCase(c)
        expect(Object.keys(flat.stateVariables)).toEqual(c.state_variables)
        for (const gone of c.no_equation_references ?? []) {
          expect(flat.stateVariables[gone]).toBeUndefined()
          expect(flat.parameters[gone]).toBeUndefined()
          expect(flat.observedVariables[gone]).toBeUndefined()
          for (const eq of flat.equations) {
            const rendered = `${toAscii(eq.lhs)} = ${toAscii(eq.rhs)}`
            expect(rendered, `equation still references ${gone}`).not.toContain(gone)
          }
        }
      })

      it('lands the later entry on the survivor', () => {
        // The non-vacuity anchor for the test above: deleting the entry's
        // reference outright would satisfy "the dead name survives nowhere" by
        // doing nothing at all.
        const flat = flattenCase(c)
        const target = c.tendency_of as string
        const eq = flat.equations.find((e) => dependentVar(e.lhs) === target)
        expect(eq, `no equation defines ${target}`).toBeDefined()
        const rendered = toAscii(eq!.rhs)
        for (const name of c.tendency_references ?? []) {
          expect(rendered, `D(${target}) must reference ${name}`).toContain(name)
        }
      })
    })
  }
})
