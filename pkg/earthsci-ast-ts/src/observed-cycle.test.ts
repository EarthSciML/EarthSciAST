/**
 * Observed dependency cycles — esm-spec §4.9.6, CONFORMANCE_SPEC §5.19.5,
 * issue #181.
 *
 * A model's observed definitions induce a dependency graph over the observed
 * names, and a cycle in it means no evaluation order satisfies every
 * definition. The graph is a function of the equations alone, so the verdict
 * belongs to `validate()` — which is the whole point of the issue: before this
 * check the cycle survived validation, and the first binding to MATERIALIZE the
 * observeds reported the name its walk happened to reach after the cycle
 * stalled. That name is an innocent bystander, and the shared fixture is built
 * to expose exactly that misattribution.
 *
 * Two things are pinned across bindings and asserted here: the `(code, path)`
 * pair, and the requirement that the message NAME the observeds on the cycle.
 * The prose around those names is not pinned (§5.19.5) and is not asserted.
 */

import { describe, it, expect } from 'vitest'
import { validate, validateText } from './validate.js'
import { fixturesDir, readFixture } from './test-helpers.js'
import { dirname } from 'node:path'
import { validateObservedCycles } from './validate/observed-checks.js'
import type { EsmFile, Model } from './types.js'

/** Validate a `tests/`-relative fixture the way a consumer holding it would. */
function validateFixture(...segments: string[]) {
  return validateText(readFixture(...segments), { basePath: dirname(fixturesDir(...segments)) })
}

/** Every finding as a `code @ path` line, for a failure message worth reading. */
function findings(result: ReturnType<typeof validate>): string[] {
  return [...result.schema_errors, ...result.structural_errors].map(
    (e) => `${e.code} @ ${e.path} :: ${e.message}`,
  )
}

/** The single `observed_cycle` finding, asserted to be the only one of its code. */
function onlyCycleFinding(result: ReturnType<typeof validate>) {
  const cycles = result.structural_errors.filter((e) => e.code === 'observed_cycle')
  expect(cycles, `expected one observed_cycle, got: ${findings(result).join(' | ')}`).toHaveLength(
    1,
  )
  return cycles[0]
}

// ---------------------------------------------------------------------------
// The shared fixture: the array-elementwise cycle from issue #181
// ---------------------------------------------------------------------------

describe('tests/invalid/observed_cycle_array_elementwise.esm (§4.9.6)', () => {
  const result = () => validateFixture('invalid', 'observed_cycle_array_elementwise.esm')

  it('is rejected with observed_cycle at /models/YSU', () => {
    // The pinned pair. The pointer is the MODEL, not an equation: a cycle is
    // carried by no single equation, so it pins where `equation_count_mismatch`
    // pins (esm-spec §4.9.6, "Reporting").
    const finding = onlyCycleFinding(result())
    expect(finding.path).toBe('/models/YSU')
  })

  it('is a STRUCTURAL rejection, not a schema failure and not a load_error', () => {
    // The document is schema-valid — the defect is a relationship BETWEEN
    // well-formed equations — so the JSON-Schema layer must accept it, and the
    // verdict must come from the structural layer under its own name. A
    // `load_error` at the document root would mean the exception escaped
    // instead of the check firing, which is precisely the pre-#181 behaviour.
    const r = result()
    expect(r.is_valid).toBe(false)
    expect(r.schema_errors).toEqual([])
    expect(r.structural_errors.map((e) => e.code)).not.toContain('load_error')
  })

  it('names gamfac, hpbl and wscale — the observeds actually on the cycle', () => {
    // §4.9.6 does not pin the prose, but it does require the message to name
    // the observeds on the cycle, so an author reading it knows what to break.
    const finding = onlyCycleFinding(result())
    for (const name of ['gamfac', 'hpbl', 'wscale']) {
      expect(finding.message).toContain(name)
    }
    expect(finding.message).toContain(' -> ')
  })

  it('does NOT name in_pbl — the innocent bystander (the whole of issue #181)', () => {
    // `in_pbl` is declared, defined and referenced perfectly well; it merely
    // READS `hpbl`, which puts it downstream of the cycle and on no cycle at
    // all. It is the name the Rust build reported (`E_TREEWALK_UNBOUND_NAME:
    // 'in_pbl'`) because it is what its materialization walk tried first after
    // the cycle stalled. A diagnostic that names it has misattributed the
    // defect, so this is asserted on the message AND on `details.cycle`.
    const finding = onlyCycleFinding(result())
    expect(finding.message).not.toContain('in_pbl')
    expect(finding.details?.cycle).not.toContain('in_pbl')
  })

  it('carries details.cycle as the closed path in traversal order', () => {
    // A PATH, not one of the §7.1.0 name lists: ordered semantically, with the
    // entry node repeated to close it. Sorted DFS roots and sorted successors
    // make which member of the cycle is the entry deterministic, so this can be
    // pinned exactly rather than up to rotation.
    const finding = onlyCycleFinding(result())
    expect(finding.details?.cycle).toEqual(['gamfac', 'hpbl', 'wscale', 'gamfac'])
  })
})

// ---------------------------------------------------------------------------
// In-memory shapes: the two ends of the graph the fixture does not cover
// ---------------------------------------------------------------------------

/** Wrap a model in the minimum document `validate()` will accept. */
function doc(models: Record<string, unknown>): EsmFile {
  return {
    esm: '1.0.0',
    metadata: { name: 'ObservedCycleShape', description: 'shape under test', authors: ['t'] },
    domain: { independent_variable: 't' },
    models,
  } as unknown as EsmFile
}

describe('cycles through DISTINCT observeds', () => {
  it('reports observed_cycle for `a ~ b + 1`, `b ~ a + 1`', () => {
    // Two scalars, each defined from the other. This is the shape that used to
    // escape `validateRelationalNodesInContinuous` as a `CadenceCycleError` and
    // collapse the document to one `load_error` at the root — see
    // `recurrence.test.ts`, which pins the seeder's own behaviour and the
    // change to what `validate()` makes of it.
    const result = validate(
      doc({
        M: {
          variables: {
            a: { type: 'unknown', units: '1' },
            b: { type: 'unknown', units: '1' },
          },
          equations: [
            { lhs: 'a', rhs: { op: '+', args: ['b', 1.0] } },
            { lhs: 'b', rhs: { op: '+', args: ['a', 1.0] } },
          ],
        },
      }),
    )
    const finding = onlyCycleFinding(result)
    expect(finding.path).toBe('/models/M')
    expect(finding.details?.cycle).toEqual(['a', 'b', 'a'])
    expect(result.structural_errors.map((e) => e.code)).not.toContain('load_error')
  })
})

describe('self-references that are NOT recurrence candidates (§4.3.1.1 gating)', () => {
  it('reports observed_cycle for a SCALAR `x ~ x + 1`', () => {
    // The self-edge exemption is gated on recurrence CANDIDACY, and a scalar is
    // not a candidate: a recurrence folds along an output AXIS and a scalar has
    // none, so `x ~ x + 1` is an equation reading a name nothing binds. It is a
    // cycle of length one and §4.9.6 requires it to be named as such — gating
    // instead on "is this a self-edge at all" would swallow it.
    const result = validate(
      doc({
        M: {
          variables: { x: { type: 'unknown', units: '1' } },
          equations: [{ lhs: 'x', rhs: { op: '+', args: ['x', 1.0] } }],
        },
      }),
    )
    const finding = onlyCycleFinding(result)
    expect(finding.path).toBe('/models/M')
    expect(finding.details?.cycle).toEqual(['x', 'x'])
  })

  it('reports observed_cycle for a BARE `s ~ s + 1` over an array', () => {
    // Array-shaped, but the self-read is BARE — it names the whole array, with
    // no `index` — so there is no axis to fold along and no candidacy either.
    // Same verdict as the scalar, for the same reason.
    const result = validate({
      esm: '1.0.0',
      metadata: { name: 'BareSelfRead', description: 'shape under test', authors: ['t'] },
      domain: { independent_variable: 't' },
      index_sets: { steps: { kind: 'interval', size: 4 } },
      models: {
        M: {
          variables: { s: { type: 'unknown', shape: ['steps'], units: '1' } },
          equations: [{ lhs: 's', rhs: { op: '+', args: ['s', 1.0] } }],
        },
      },
    } as unknown as EsmFile)
    const finding = onlyCycleFinding(result)
    expect(finding.details?.cycle).toEqual(['s', 's'])
  })
})

// ---------------------------------------------------------------------------
// The converse duty: the new check must reject nothing that was legal
// ---------------------------------------------------------------------------

describe('a legal recurrence keeps its self-edge exemption (§5.19.5)', () => {
  it('validates tests/valid/recurrence_causal_self_reference.esm with ZERO errors', () => {
    // The self-edge of a recurrence CANDIDATE is dropped from the dependency
    // graph, so the one legal document that has such an edge must survive this
    // check untouched. Asserted at zero findings, not `is_valid`, so a
    // regression names what it added.
    const result = validateFixture('valid', 'recurrence_causal_self_reference.esm')
    expect(findings(result)).toEqual([])
    expect(result.is_valid).toBe(true)
  })

  it('exempts an ILL-founded self-read too, leaving the recurrence_* diagnosis reachable', () => {
    // Candidacy, not the well-foundedness verdict (CONFORMANCE_SPEC §5.19.5).
    // `index(s, k + 1)` reads LATER on its axis and is rejected — but by
    // `recurrence_not_wellfounded`, at the offending expression, because that
    // is the cross-binding contract for the shape. If this check gated its
    // exemption on well-foundedness it would fire first, at the model, and the
    // named diagnosis would never be reached: the same masking defect issue
    // #181 is about, merely moved from the legal case to the illegal one.
    const result = validate({
      esm: '1.1.0',
      metadata: { name: 'IllFounded', description: 'shape under test', authors: ['t'] },
      domain: { independent_variable: 't' },
      index_sets: { steps: { kind: 'interval', size: 4 } },
      models: {
        M: {
          variables: { s: { type: 'unknown', shape: ['steps'], units: '1' } },
          equations: [
            {
              lhs: 's',
              rhs: {
                op: 'faq',
                args: [],
                output_idx: ['k'],
                ranges: { k: { from: 'steps' } },
                expr: {
                  op: '*',
                  args: [{ op: 'index', args: ['s', { op: '+', args: ['k', 1] }] }, 2.0],
                },
              },
            },
          ],
        },
      },
    } as unknown as EsmFile)
    const codes = result.structural_errors.map((e) => e.code)
    expect(codes).toContain('recurrence_not_wellfounded')
    expect(codes).not.toContain('observed_cycle')
  })
})

// ---------------------------------------------------------------------------
// Walk depth is a property of the DOCUMENT, not of expression nesting
// ---------------------------------------------------------------------------

describe('a chain longer than the JS call stack', () => {
  /**
   * `validateObservedCycles` is exercised DIRECTLY here rather than through
   * `validate()`, because the cadence seeder — which `validate()` also runs, and
   * which this PR does not touch — recurses over the same chain and overflows
   * first at a couple of thousand observeds. Calling the rule under test on its
   * own is what isolates its own ceiling.
   *
   * The depth of this walk is the length of the longest observed CHAIN. That is
   * unbounded in a document (a lowered mechanism is a long chain of algebraic
   * definitions) and is not the expression nesting the schema caps, so the DFS
   * must not be recursive: a recursive one turned a document that has to
   * validate CLEAN into `RangeError: Maximum call stack size exceeded`.
   */
  function chain(n: number, cyclic: boolean) {
    const variables: Record<string, unknown> = {
      p: { type: 'parameter', units: '1', default: 1.0 },
    }
    const equations: unknown[] = []
    for (let i = 0; i < n; i++) variables[`x${i}`] = { type: 'unknown', units: '1' }
    // x_i reads x_{i+1}, so the DFS entered at the sorted-first root descends
    // the whole chain in one go.
    for (let i = 0; i < n - 1; i++) {
      equations.push({ lhs: `x${i}`, rhs: { op: '+', args: [`x${i + 1}`, 'p'] } })
    }
    equations.push({
      lhs: `x${n - 1}`,
      rhs: cyclic ? { op: '+', args: ['x0', 'p'] } : 'p',
    })
    return { variables, equations } as unknown as Model
  }

  const DEPTH = 20000

  it('reports nothing for an ACYCLIC chain of 20000 observeds', () => {
    expect(validateObservedCycles(chain(DEPTH, false), '/models/M')).toEqual([])
  })

  it('still names the cycle when that chain is closed into a ring', () => {
    const errors = validateObservedCycles(chain(DEPTH, true), '/models/M')
    expect(errors.map((e) => e.code)).toEqual(['observed_cycle'])
    expect((errors[0].details as { cycle: string[] }).cycle).toHaveLength(DEPTH + 1)
  })
})
