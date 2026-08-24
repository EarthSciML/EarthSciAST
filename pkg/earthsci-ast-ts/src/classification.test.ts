/**
 * Cross-language conformance for the esm 1.0.0 classification API
 * (esm-spec §6.3.1), driven by the shared oracle in
 * `tests/conformance/classification/`.
 *
 * The manifest lists TypeScript under `bindings_required`, so every fixture
 * there must pass here. The goldens are authored, not produced by any binding,
 * so this is a comparison against the spec rather than against another
 * implementation.
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'fs'
import { join } from 'path'
import { loadString } from './parse.js'
import {
  odeStates,
  observedUnknowns,
  algebraicUnknowns,
  isOdeState,
  brownianParameters,
  discreteParameters,
  sampledParameters,
  constantParameters,
  systemKind,
  classifyDocument,
  unknowns,
  parameters,
} from './classification.js'
import type { Model } from './types.js'
import { fixturesDir } from './test-helpers.js'

const classificationDir = join(fixturesDir(), 'conformance', 'classification')

interface GoldenEntry {
  ode_states: string[]
  observed_unknowns: string[]
  algebraic_unknowns: string[]
  brownian_parameters: string[]
  discrete_parameters: string[]
  sampled_parameters: string[]
  constant_parameters: string[]
  system_kind: string
  declared_system_kind?: string | null
}

interface Manifest {
  bindings_required: string[]
  fixtures: { id: string; fixture: string; golden: string; pins: string }[]
}

const manifest: Manifest = JSON.parse(
  readFileSync(join(classificationDir, 'manifest.json'), 'utf-8'),
)

describe('classification conformance (esm-spec §6.3.1)', () => {
  it('names typescript as a required binding', () => {
    expect(manifest.bindings_required).toContain('typescript')
  })

  for (const entry of manifest.fixtures) {
    describe(entry.id, () => {
      const doc = loadString(readFileSync(join(classificationDir, entry.fixture), 'utf-8')) as {
        models: { [k: string]: unknown }
      }
      const golden: { models: { [k: string]: GoldenEntry } } = JSON.parse(
        readFileSync(join(classificationDir, entry.golden), 'utf-8'),
      )
      const actual = classifyDocument(doc.models)

      it(`classifies exactly the model nodes the golden names (${entry.pins.slice(0, 60)}…)`, () => {
        expect(Object.keys(actual).sort()).toEqual(Object.keys(golden.models).sort())
      })

      for (const [path, expected] of Object.entries(golden.models)) {
        describe(path, () => {
          it('partitions the unknowns as the golden says', () => {
            expect(actual[path].odeStates).toEqual(expected.ode_states)
            expect(actual[path].observedUnknowns).toEqual(expected.observed_unknowns)
            expect(actual[path].algebraicUnknowns).toEqual(expected.algebraic_unknowns)
          })

          it('partitions the parameters as the golden says', () => {
            expect(actual[path].brownianParameters).toEqual(expected.brownian_parameters)
            expect(actual[path].discreteParameters).toEqual(expected.discrete_parameters)
            expect(actual[path].sampledParameters).toEqual(expected.sampled_parameters)
            expect(actual[path].constantParameters).toEqual(expected.constant_parameters)
          })

          it('derives the system kind', () => {
            expect(actual[path].systemKind).toBe(expected.system_kind)
          })

          if (Object.prototype.hasOwnProperty.call(expected, 'declared_system_kind')) {
            it('reports the declared system kind verbatim', () => {
              expect(actual[path].declaredSystemKind).toBe(expected.declared_system_kind ?? null)
            })
          }

          it('THE UNKNOWN SETS PARTITION: disjoint, and together the unknowns', () => {
            const model = modelAt(doc.models, path)
            const parts = [
              actual[path].odeStates,
              actual[path].observedUnknowns,
              actual[path].algebraicUnknowns,
            ]
            const union = parts.flat()
            expect([...union].sort()).toEqual(unknowns(model))
            // Disjoint: no name appears in two of the three.
            expect(new Set(union).size).toBe(union.length)
          })

          it('THE PARAMETER SETS PARTITION: disjoint, and together the parameters', () => {
            const model = modelAt(doc.models, path)
            const parts = [
              actual[path].brownianParameters,
              actual[path].discreteParameters,
              actual[path].sampledParameters,
              actual[path].constantParameters,
            ]
            const union = parts.flat()
            expect([...union].sort()).toEqual(parameters(model))
            expect(new Set(union).size).toBe(union.length)
          })

          it('isOdeState agrees with odeStates, for every declared unknown', () => {
            const model = modelAt(doc.models, path)
            for (const name of unknowns(model)) {
              expect(isOdeState(model, name)).toBe(expected.ode_states.includes(name))
            }
          })

          it('the standalone accessors agree with classifyDocument', () => {
            const model = modelAt(doc.models, path)
            expect(odeStates(model)).toEqual(expected.ode_states)
            expect(observedUnknowns(model)).toEqual(expected.observed_unknowns)
            expect(algebraicUnknowns(model)).toEqual(expected.algebraic_unknowns)
            expect(brownianParameters(model)).toEqual(expected.brownian_parameters)
            expect(discreteParameters(model)).toEqual(expected.discrete_parameters)
            expect(sampledParameters(model)).toEqual(expected.sampled_parameters)
            expect(constantParameters(model)).toEqual(expected.constant_parameters)
            expect(systemKind(model)).toBe(expected.system_kind)
          })
        })
      }
    })
  }
})

/** Resolve a dot-path like `Parent.Child` to its model node. */
function modelAt(models: { [k: string]: unknown }, path: string): Model {
  const [head, ...rest] = path.split('.')
  let node = models[head] as Model
  for (const part of rest) {
    node = (node.subsystems as { [k: string]: Model })[part]
  }
  return node
}
