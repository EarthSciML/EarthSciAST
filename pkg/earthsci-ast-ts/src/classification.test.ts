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
  declaredSystemKind,
  effectiveSystemKind,
  classifyDocument,
  unknowns,
  parameters,
} from './classification.js'
import { leafCadence } from './cadence.js'
import { flatten } from './flatten.js'
import type { EsmFile, Model } from './types.js'
import { fixturesDir } from './test-helpers.js'

const classificationDir = join(fixturesDir(), 'conformance', 'classification')

// The INDEXED LHS spelling of an arrayed definition (esm-spec §6.3.1), which the
// `classification` category cannot state: it carries no `index` or `aggregate`
// LHS at all, which is why four of the five bindings drifted onto the same wrong
// answer independently. Same golden shape, so the same driver reads it.
// See tests/conformance/classification_indexed_lhs/README.md.
const indexedLhsDir = join(fixturesDir(), 'conformance', 'classification_indexed_lhs')

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

/**
 * esm-libraries-spec §4.7.5 step 4's flattened buckets, where a golden pins
 * them. Optional: only the categories whose fixtures make the distinction
 * interesting carry it.
 */
interface GoldenFlattenBuckets {
  state_variables: string[]
  observed_variables: string[]
  algebraic_variables: string[]
}

interface Manifest {
  bindings_required: string[]
  fixtures: { id: string; fixture: string; golden: string; pins: string }[]
}

function runClassificationCategory(label: string, dir: string): void {
  const manifest: Manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf-8'))

  describe(label, () => {
    it('names typescript as a required binding', () => {
      expect(manifest.bindings_required).toContain('typescript')
    })

    for (const entry of manifest.fixtures) {
      describe(entry.id, () => {
        const doc = loadString(readFileSync(join(dir, entry.fixture), 'utf-8')) as {
          models: { [k: string]: unknown }
        }
        const golden: {
          models: { [k: string]: GoldenEntry }
          flatten_buckets?: GoldenFlattenBuckets
        } = JSON.parse(readFileSync(join(dir, entry.golden), 'utf-8'))
        const actual = classifyDocument(doc.models)

        const buckets = golden.flatten_buckets
        if (buckets !== undefined) {
          // Which flattened MAP an unknown lands in is a different question
          // from which §6.3.1 set classifies it, and §4.7.5 step 4 answers it
          // with two maps that are NOT a partition: an arrayed observed is in
          // `observedVariables` (an equation defines it) AND in
          // `stateVariables` (it materializes into a buffer the solver
          // allocates). Issue #270.
          it('files the unknowns in the §4.7.5 step-4 buckets, dual membership and all', () => {
            const flat = flatten(doc as unknown as EsmFile)
            expect(Object.keys(flat.stateVariables)).toEqual(buckets.state_variables)
            expect(Object.keys(flat.observedVariables)).toEqual(buckets.observed_variables)
            expect(Object.keys(flat.algebraicVariables)).toEqual(buckets.algebraic_variables)
          })
        }

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
              // §8 item 11: `declared ?? derived`, never null.
              expect(effectiveSystemKind(model)).toBe(
                declaredSystemKind(model) ?? expected.system_kind,
              )
            })
          })
        }
      })
    }
  })
}

runClassificationCategory('classification conformance (esm-spec §6.3.1)', classificationDir)
runClassificationCategory(
  'classification conformance: the INDEXED LHS spelling (esm-spec §6.3.1)',
  indexedLhsDir,
)

/** Resolve a dot-path like `Parent.Child` to its model node. */
function modelAt(models: { [k: string]: unknown }, path: string): Model {
  const [head, ...rest] = path.split('.')
  let node = models[head] as Model
  for (const part of rest) {
    node = (node.subsystems as { [k: string]: Model })[part]
  }
  return node
}

describe('effectiveSystemKind (API_SPEC.md §8 item 11)', () => {
  const derivedOde: Model = {
    variables: { x: { type: 'unknown', default: 0 } },
    equations: [{ lhs: { op: 'D', args: ['x', 't'] }, rhs: 1 }],
  } as unknown as Model

  it('falls back to the DERIVED kind when nothing is declared', () => {
    expect(declaredSystemKind(derivedOde)).toBeNull()
    expect(systemKind(derivedOde)).toBe('ode')
    expect(effectiveSystemKind(derivedOde)).toBe('ode')
  })

  it('prefers the DECLARED kind when the document states one', () => {
    const declared = { ...derivedOde, system_kind: 'nonlinear' } as unknown as Model
    expect(declaredSystemKind(declared)).toBe('nonlinear')
    expect(systemKind(declared)).toBe('ode')
    expect(effectiveSystemKind(declared)).toBe('nonlinear')
  })
})

/**
 * esm-spec §6.3.1 admits TWO LHS spellings for the equation that DEFINES an
 * unknown — bare (`y ~ f(…)`) and indexed (`y[i] ~ f(…)`, which defines the
 * whole array `y`) — and neither is restricted by rank: "the defining form is
 * read through the LHS's BASE NAME … so an arrayed definition is observed
 * exactly as its scalar counterpart is".
 *
 * Both spellings of the indexed one must credit `w` an OBSERVED: the bare
 * `index(w, i)` LHS that §6.3.1's worked example names verbatim, and the
 * `aggregate{k}(index(w, k))` shell that documents in this repo actually use
 * (both are written out in `tests/conformance/classification_indexed_lhs/`).
 * `baseVariableName` stopped at the aggregate shell, so
 * the second spelling was credited to nobody and {@link algebraicUnknowns}
 * claimed `w` by elimination.
 *
 * That is not bookkeeping. §6.3.1: `algebraic_unknowns` seeds the CONTINUOUS
 * cadence partition, whereas an observed's cadence resolves through its
 * defining RHS — "so misclassifying an arrayed definition as algebraic pushes
 * build-time work … onto the per-timestep hot path". The partition assertion is
 * what pins that consequence.
 *
 * The classification conformance corpus above cannot catch this: none of its
 * fixtures carries an `index` or `aggregate` LHS at all.
 *
 * See issue #232 (Julia), issue #231 / PR #237 (Python), PR #250.
 */
describe('an ARRAYED definition is observed, in every LHS spelling (§6.3.1)', () => {
  const aggregateIndexed = {
    op: 'aggregate',
    args: [],
    output_idx: ['k'],
    ranges: { k: { from: 'lev' } },
    expr: { op: 'index', args: ['w', 'k'] },
  }
  const spellings: { [label: string]: unknown } = {
    bare: 'w',
    indexed: { op: 'index', args: ['w', 'k'] },
    'aggregate of indexed': aggregateIndexed,
  }

  for (const [label, lhs] of Object.entries(spellings)) {
    describe(label, () => {
      const model = {
        variables: {
          u: { type: 'unknown', units: '1' },
          w: { type: 'unknown', units: '1', shape: ['lev'] },
        },
        equations: [
          { lhs: { op: 'D', args: ['u'], wrt: 't' }, rhs: 'w' },
          { lhs, rhs: 2 },
        ],
      } as unknown as Model

      it('puts `w` in observedUnknowns', () => {
        expect(observedUnknowns(model)).toEqual(['w'])
      })

      // The three sets PARTITION, so crediting the definition must also take
      // `w` out of the algebraic bucket, not merely add it to the observed one.
      it('leaves algebraicUnknowns empty', () => {
        expect(algebraicUnknowns(model)).toEqual([])
      })

      it('leaves the ODE partition untouched', () => {
        expect(odeStates(model)).toEqual(['u'])
      })

      // THE CONSEQUENCE, not just the bookkeeping. `w`'s definition is
      // state-free, so an observed seeds from its RHS's class and folds at bind.
      // While the aggregate spelling was mis-credited to `algebraicUnknowns` it
      // seeded CONTINUOUS instead, putting build-time work on the per-timestep
      // hot path — exactly what §6.3.1 warns this misclassification costs.
      it('folds a state-free arrayed observed at bind', () => {
        expect(leafCadence(model, 'w')).toBe('const')
      })
    })
  }

  // The aggregate unwrap recognises an `index` body ONLY. An `aggregate` whose
  // body is a `D` is the whole-array spelling of a TENDENCY — it makes an ODE
  // state, and crediting it as a definition would hand a state's derivative RHS
  // to the units and cadence passes as if it defined the state.
  it('does NOT credit an aggregate over a derivative as a definition', () => {
    const model = {
      variables: { u: { type: 'unknown', units: '1', shape: ['lev'] } },
      equations: [
        {
          lhs: {
            op: 'aggregate',
            args: [],
            output_idx: ['k'],
            ranges: { k: { from: 'lev' } },
            expr: { op: 'D', args: [{ op: 'index', args: ['u', 'k'] }], wrt: 't' },
          },
          rhs: 1,
        },
      ],
    } as unknown as Model
    expect(odeStates(model)).toEqual(['u'])
    expect(observedUnknowns(model)).toEqual([])
    expect(algebraicUnknowns(model)).toEqual([])
  })
})
