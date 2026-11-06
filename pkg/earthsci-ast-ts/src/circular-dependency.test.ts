/**
 * `circular_dependency` is a cycle among OBSERVED unknowns that crosses a scope
 * boundary (esm-spec §4.9.7). The graph is over variables, not whole models:
 * a state's or a parameter's value is known at every right-hand-side
 * evaluation, so reading it orders nothing.
 */
import { describe, it, expect } from 'vitest'
import { validate } from './validate.js'
import { loadFixture } from './test-helpers.js'
import type { EsmFile, Model } from './types.js'

const cycleErrors = (file: EsmFile) =>
  validate(file).structural_errors.filter((e) => e.code === 'circular_dependency')

describe('circular_dependency (esm-spec §4.9.7)', () => {
  it.each([
    ['circular_coupling.esm', ['ModelA.a', 'ModelB.b', 'ModelA.a']],
    ['circular_coupling_subsystem.esm', ['ModelN.Sub.c', 'ModelN.a', 'ModelN.Sub.c']],
  ])('reports the pinned cycle for %s', (name, cycle) => {
    const errs = cycleErrors(loadFixture('invalid', name))
    expect(errs).toHaveLength(1)
    expect(errs[0].path).toBe('/models')
    expect(errs[0].details).toEqual({ cycle })
  })

  it.each([
    'cross_model_state_reads.esm',
    'cross_model_mixing_observed_state_cycle.esm',
    'cross_model_observed_reads_no_loop.esm',
  ])('does not report %s', (name) => {
    expect(cycleErrors(loadFixture('valid', name))).toHaveLength(0)
  })

  it('a derivative of an expression makes none of its operands a state', () => {
    // `D(a + x) ~ 3` credits no variable as a state (§6.3.1), so `a` stays an
    // observed and the ModelA.a <-> ModelB.b loop is still reported.
    const file = loadFixture('invalid', 'circular_coupling.esm')
    const modelA = file.models!.ModelA as Model
    modelA.equations = [
      ...(modelA.equations ?? []),
      { lhs: { op: 'D', args: [{ op: '+', args: ['a', 'x'] }], wrt: 't' }, rhs: 3 },
    ]
    const errs = cycleErrors(file)
    expect(errs).toHaveLength(1)
    expect(errs[0].details).toEqual({ cycle: ['ModelA.a', 'ModelB.b', 'ModelA.a'] })
  })

  it('skips a back edge whose cycle lies in one model and keeps searching', () => {
    // ModelA.a -> ModelA.p -> ModelA.a stays in ModelA (that is observed_cycle);
    // ModelA.p also reads ModelB.b, which reads ModelA.a, and that loop crosses
    // models, so it is the one reported.
    const file = loadFixture('invalid', 'circular_coupling.esm')
    const modelA = file.models!.ModelA as Model
    modelA.variables = { ...modelA.variables, p: { type: 'unknown', units: 'mol/mol' } }
    modelA.equations = [
      ...(modelA.equations ?? []).map((eq) =>
        eq.lhs === 'a' ? { lhs: 'a', rhs: { op: '*', args: [0.1, 'p'] } } : eq,
      ),
      { lhs: 'p', rhs: { op: '+', args: ['a', 'ModelB.b'] } },
    ]
    const errs = cycleErrors(file)
    expect(errs).toHaveLength(1)
    expect(errs[0].details).toEqual({
      cycle: ['ModelA.a', 'ModelA.p', 'ModelB.b', 'ModelA.a'],
    })
  })

  describe('a dotted name resolves relative to the reader before the top level', () => {
    // N.Sub.s ~ Inner.v (relative to N.Sub), N.Sub.Inner.v ~ M.w, M.w ~ N.Sub.s.
    const doc = (subStateEq: boolean): EsmFile =>
      ({
        esm: '1.0.0',
        metadata: { name: 'RelativeScopedRefs' },
        models: {
          M: {
            variables: { w: { type: 'unknown', units: '1' } },
            equations: [{ lhs: 'w', rhs: { op: '*', args: [0.1, 'N.Sub.s'] } }],
          },
          N: {
            variables: {},
            equations: [],
            subsystems: {
              Sub: {
                variables: { s: { type: 'unknown', units: '1' } },
                equations: [
                  { lhs: 's', rhs: { op: '*', args: [0.1, 'Inner.v'] } },
                  ...(subStateEq
                    ? [{ lhs: { op: 'D', args: ['Inner.v'], wrt: 't' }, rhs: 0 }]
                    : []),
                ],
                subsystems: {
                  Inner: {
                    variables: { v: { type: 'unknown', units: '1' } },
                    equations: [{ lhs: 'v', rhs: { op: '*', args: [0.1, 'M.w'] } }],
                  },
                },
              },
            },
          },
        },
      }) as unknown as EsmFile

    it('reads Inner.v inside N.Sub as N.Sub.Inner.v', () => {
      const errs = cycleErrors(doc(false))
      expect(errs).toHaveLength(1)
      expect(errs[0].details).toEqual({
        cycle: ['M.w', 'N.Sub.s', 'N.Sub.Inner.v', 'M.w'],
      })
    })

    it('D(Inner.v) inside N.Sub makes N.Sub.Inner.v a state, so reading it is not an edge', () => {
      expect(cycleErrors(doc(true))).toHaveLength(0)
    })
  })
})
