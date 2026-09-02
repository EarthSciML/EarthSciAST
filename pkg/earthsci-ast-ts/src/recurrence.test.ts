/**
 * Causal self-reference (recurrence) along one index axis — esm-spec §4.3.1.1,
 * CONFORMANCE_SPEC §5.19.
 *
 * This binding evaluates no array numerics, so §5.19.5 *rejection parity* is
 * the whole of what it implements — and parity cuts both ways. Half of what
 * follows is therefore POSITIVE: the shared fixtures, which this binding must
 * not reject, and which it did reject before the `CadenceSeeder` self-edge fix
 * turned a legal recurrence into a `CadenceCycleError` and collapsed the whole
 * document into one load error. The other half pins each malformed shape to an
 * exact `(code, path)` pair rather than to "it failed", because the codes are
 * the cross-binding contract and a check that merely counts errors cannot tell
 * `recurrence_not_wellfounded` from `recurrence_unsupported_form`.
 */

import { describe, it, expect } from 'vitest'
import { validate, validateText } from './validate.js'
import { CadenceSeeder, CadenceCycleError } from './cadence.js'
import { isRecurrenceCandidate, isWellFoundedRecurrence } from './recurrence.js'
import { fixturesDir, readFixture } from './test-helpers.js'
import { readdirSync } from 'node:fs'
import { dirname } from 'node:path'
import type { EsmFile, Expression, Model } from './types.js'

// ---------------------------------------------------------------------------
// Positive controls: the shared corpus
// ---------------------------------------------------------------------------

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

describe('a well-founded recurrence is ADMITTED (§5.19.5, converse duty)', () => {
  it('validates tests/valid/recurrence_causal_self_reference.esm with ZERO errors', () => {
    // The regression test for the blocker. `r`'s defining aggregate reads
    // `index(r, y - a)`, so the observed-cadence seeder used to walk `r -> r`
    // and throw `CadenceCycleError`; `validate()` caught that and degraded the
    // entire document to a single `load_error`, i.e. this binding REJECTED a
    // legal document. Asserted at zero findings, not `is_valid`, so a future
    // regression names what it added.
    const result = validateFixture('valid', 'recurrence_causal_self_reference.esm')
    expect(findings(result)).toEqual([])
    expect(result.is_valid).toBe(true)
  })

  // The conformance fixtures. This binding executes none of them — it has no
  // numeric array path — but §5.19.5 gives a non-executing binding the same
  // rejection duty as an executing one, so it must not reject them either.
  // Between them they cover every admitted shape: a literal lag of 1, a lag > 1,
  // a lag carried by an index SYMBOL (whose bounds straddle zero), and a
  // recurrence on one axis of a two-axis frame.
  //
  // Enumerated from the DIRECTORY rather than from a list written here. The
  // executing bindings own this corpus and add to it (a 38-lag fixture arrived
  // while this file was being written); a hardcoded list would have kept
  // passing while quietly not covering the new one, which is the failure mode
  // this suite exists to prevent.
  const conformanceFixtures = readdirSync(fixturesDir('fixtures', 'recurrence'))
    .filter((name) => name.endsWith('.esm'))
    .sort()

  it('finds the recurrence fixture corpus (guards against a vacuous sweep)', () => {
    expect(conformanceFixtures.length).toBeGreaterThanOrEqual(6)
  })

  it.each(conformanceFixtures)('validates tests/fixtures/recurrence/%s clean', (name) => {
    const result = validateFixture('fixtures', 'recurrence', name)
    expect(findings(result)).toEqual([])
  })
})

// ---------------------------------------------------------------------------
// Negative controls: one malformed shape per row of the §4.3.1.1 Rejections
// table, built in memory so the shape under test is the ONLY thing that varies
// ---------------------------------------------------------------------------

/**
 * A one-variable model whose array unknown `s` over `steps` is defined by an
 * `aggregate` with frame `[k]` and body `selfRead * 2`. Only the self-read
 * varies between cases, so every finding below is attributable to it, and the
 * equation stays at index 0 because the findings are pinned by JSON Pointer.
 */
function recurrenceDoc(selfRead: Expression, body?: Expression): EsmFile {
  return {
    esm: '1.0.0',
    metadata: { name: 'RecurrenceShape', description: 'shape under test', authors: ['t'] },
    index_sets: { steps: { kind: 'interval', size: 4 } },
    models: {
      M: {
        variables: { s: { type: 'unknown', shape: ['steps'], units: '1' } },
        equations: [
          {
            lhs: 's',
            rhs: {
              op: 'aggregate',
              args: [],
              output_idx: ['k'],
              ranges: { k: { from: 'steps' } },
              expr: body ?? { op: '*', args: [selfRead, 2.0] },
            },
          },
        ],
      },
    },
  } as unknown as EsmFile
}

/** `index(s, ...args)` — a self-read of the array being defined. */
const selfIndex = (...args: Expression[]): Expression => ({ op: 'index', args: ['s', ...args] })

/** The single finding a document is expected to produce. */
function onlyFinding(doc: EsmFile) {
  const result = validate(doc)
  expect(findings(result), 'expected exactly one structural finding').toHaveLength(1)
  return result.structural_errors[0]
}

const RHS_PATH = '/models/M/equations/0/rhs'

describe('recurrence_not_wellfounded (§4.3.1.1 Rejections)', () => {
  it('rejects a FORWARD read `index(s, k+1)`', () => {
    // hi(lag) = -1 <= 0: provably a later cell for every k, so no sweep order
    // can satisfy it. The axis is nameable here, hence `recurrence_axis: 'k'`.
    const finding = onlyFinding(recurrenceDoc(selfIndex({ op: '+', args: ['k', 1] })))
    expect(finding.code).toBe('recurrence_not_wellfounded')
    expect(finding.path).toBe(RHS_PATH)
    expect(finding.details).toEqual({ variable: 's', recurrence_axis: 'k' })
  })

  it('rejects a SAME-CELL read `index(s, k)`', () => {
    // lag is exactly [0,0] on the only axis, so no axis is left to fold along:
    // `s[k]` would be defined in terms of `s[k]`. Distinct from the forward
    // case, which fails on the axis it names; this one fails for want of one,
    // so no axis is reported.
    const finding = onlyFinding(recurrenceDoc(selfIndex('k')))
    expect(finding.code).toBe('recurrence_not_wellfounded')
    expect(finding.path).toBe(RHS_PATH)
    expect(finding.details).toEqual({ variable: 's', recurrence_axis: null })
    expect(finding.message).toContain('same cell on every axis')
  })

  it('rejects a BARE read of `s` alongside an `index` read', () => {
    // A bare `s` names the WHOLE array, and the whole array does not exist
    // while the recurrence sweeps it. Checked ahead of the per-axis rules
    // because it disqualifies the equation however well-founded the indexed
    // read beside it happens to be — the `k-1` read here is impeccable.
    const finding = onlyFinding(
      recurrenceDoc({ op: '+', args: ['s', selfIndex({ op: '-', args: ['k', 1] })] }),
    )
    expect(finding.code).toBe('recurrence_not_wellfounded')
    expect(finding.path).toBe(RHS_PATH)
    expect(finding.details).toEqual({ variable: 's', recurrence_axis: null })
    expect(finding.message).toContain('read bare')
  })

  it('rejects a NON-AFFINE index `index(s, 2*k)`', () => {
    // Affine, but with coefficient 2. A self-read must name a position
    // RELATIVE to the cell being written; `2k` names an unrelated cell, and
    // which direction it moves depends on k.
    const finding = onlyFinding(recurrenceDoc(selfIndex({ op: '*', args: [2, 'k'] })))
    expect(finding.code).toBe('recurrence_not_wellfounded')
    expect(finding.path).toBe(RHS_PATH)
    expect(finding.message).toContain('coefficient 2, not 1')
  })

  it('rejects a CONSTANT index `index(s, 1)`', () => {
    // Coefficient 0: the frame symbol is absent altogether, so the read is not
    // relative to anything. Reported through the same coefficient rule rather
    // than a bespoke "constant index" case, which is why the message says 0.
    const finding = onlyFinding(recurrenceDoc(selfIndex(1)))
    expect(finding.code).toBe('recurrence_not_wellfounded')
    expect(finding.path).toBe(RHS_PATH)
    expect(finding.message).toContain('coefficient 0, not 1')
  })
})

describe('recurrence_unsupported_form (§4.3.1.1 Rejections)', () => {
  it('rejects a self-read inside a `makearray` REGION VALUE', () => {
    // Not `not_wellfounded`: the read `s[k-1]` is perfectly causal, and it is
    // the CARRIER that cannot be sequenced. §4.3.2's overlap rule ("later
    // entries overwrite earlier ones") reads like a licence to define cell k
    // from cell k-1, but region order fixes which write WINS, not the order
    // cells are EVALUATED in, and a region's value is evaluated once for the
    // whole region.
    const doc = recurrenceDoc(0, {
      op: 'makearray',
      args: [],
      regions: [[[1, 4]]],
      values: [selfIndex({ op: '-', args: ['k', 1] })],
    } as unknown as Expression)
    const finding = onlyFinding(doc)
    expect(finding.code).toBe('recurrence_unsupported_form')
    expect(finding.path).toBe(RHS_PATH)
    expect(finding.details).toEqual({ variable: 's', recurrence_axis: null })
  })
})

// ---------------------------------------------------------------------------
// The converse duty: admitting a recurrence must weaken no cycle rejection
// ---------------------------------------------------------------------------

describe('cycles through DISTINCT variables are still rejected (§5.19.5)', () => {
  const twoVariableCycle = {
    variables: { a: { type: 'unknown' }, b: { type: 'unknown' } },
    equations: [
      { lhs: 'a', rhs: 'b' },
      { lhs: 'b', rhs: 'a' },
    ],
  } as unknown as Model

  it('still throws CadenceCycleError for `a ~ b`, `b ~ a`', () => {
    // The self-edge drop tests the TOP of the in-progress stack, not
    // membership, precisely so this two-hop cycle is untouched. Pinned to the
    // cycle PATH as well as the class: a drop that swallowed one hop too many
    // would still throw here, just with the wrong cycle.
    expect(() => new CadenceSeeder(twoVariableCycle).leaf('a')).toThrow(CadenceCycleError)
    try {
      new CadenceSeeder(twoVariableCycle).leaf('a')
      expect.unreachable('expected a CadenceCycleError')
    } catch (error) {
      expect((error as CadenceCycleError).cycle).toEqual(['a', 'b', 'a'])
    }
  })

  it('reports that cycle through validate() as a load_error, as it did before', () => {
    const result = validate({
      esm: '1.0.0',
      metadata: { name: 'Cycle', description: 'd', authors: ['t'] },
      models: { M: twoVariableCycle },
    } as unknown as EsmFile)
    expect(result.is_valid).toBe(false)
    expect(result.structural_errors.map((e) => e.code)).toContain('load_error')
    expect(result.structural_errors[0].details).toMatchObject({
      exception_type: 'CadenceCycleError',
    })
  })

  it('seeds a legal recurrence instead of throwing on its self-edge', () => {
    // The unit-level statement of the fix: `s`'s own definition reads `s`, and
    // the seeder resolves it to a class rather than raising. `const` is
    // `joinCadence`'s identity, so the dropped edge contributes nothing and the
    // seed comes from the recurrence's other inputs — here only literals.
    const model = {
      variables: { s: { type: 'unknown', shape: ['steps'] } },
      equations: [
        {
          lhs: 's',
          rhs: {
            op: 'aggregate',
            args: [],
            output_idx: ['k'],
            ranges: { k: { from: 'steps' } },
            expr: {
              op: '*',
              args: [{ op: 'index', args: ['s', { op: '-', args: ['k', 1] }] }, 2.0],
            },
          },
        },
      ],
    } as unknown as Model
    expect(new CadenceSeeder(model).leaf('s')).toBe('const')
  })
})

// ---------------------------------------------------------------------------
// Boundaries the Rejections table states but no fixture spells out
// ---------------------------------------------------------------------------

describe('what is NOT a recurrence', () => {
  it('leaves a `D(...)` derivative LHS alone', () => {
    // A derivative LHS defines no array algebraically, so a stencil read of `u`
    // at `i-1` is a GATHER on the solver's state — the ordinary §4.3.3
    // out-of-range convention applies to it — and not a self-reference. Running
    // it through the well-foundedness table would reject every upwind scheme in
    // the corpus.
    const result = validate({
      esm: '1.0.0',
      metadata: { name: 'Upwind', description: 'd', authors: ['t'] },
      index_sets: { cells: { kind: 'interval', size: 4 } },
      models: {
        M: {
          variables: { u: { type: 'unknown', shape: ['cells'], units: '1' } },
          equations: [
            {
              lhs: { op: 'D', args: ['u'], wrt: 't' },
              rhs: {
                op: 'aggregate',
                args: [],
                output_idx: ['i'],
                ranges: { i: { from: 'cells' } },
                expr: { op: 'index', args: ['u', { op: '-', args: ['i', 1] }] },
              },
            },
          ],
        },
      },
    } as unknown as EsmFile)
    expect(findings(result)).toEqual([])
  })

  it('admits a STRADDLING lag `index(s, k - a)` with `a` in [0, 3]', () => {
    // Earlier for a >= 1, same-cell at a = 0. Admitted deliberately: requiring
    // `lo(lag) >= 1` would reject the natural spelling of every banded fold, and
    // guarding the a = 0 cell is the author's job, done with an `ifelse` in the
    // body. The runtime is fail-closed (§4.3.1.1 point 5), so an unguarded cell
    // costs a fault rather than a wrong number.
    const doc = recurrenceDoc(selfIndex({ op: '-', args: ['k', 'a'] })) as unknown as {
      models: { M: { equations: { rhs: { ranges: Record<string, unknown> } }[] } }
    }
    doc.models.M.equations[0].rhs.ranges.a = [0, 3]
    expect(findings(validate(doc as unknown as EsmFile))).toEqual([])
  })
})

// ---------------------------------------------------------------------------
// The split proof obligation (esm-spec §4.3.1.1 *Admitted lag*, normative)
//
// The COEFFICIENT must be provable; the lag's SIGN need not be. A validator
// sees `ranges` before they resolve against the registry, so it proves strictly
// less than an evaluator — and a validator that treated "unproven" as "illegal"
// would reject documents its own evaluator accepts.
// ---------------------------------------------------------------------------

describe('an UNPROVABLE lag is admitted, not rejected', () => {
  it('admits a PARAMETER-valued lag `index(s, k - n)`', () => {
    // `n` is a parameter, so nothing static can bound the lag in either
    // direction. The coefficient of `k` is still provably 1, which is the half
    // that must be provable, so this is the recurrence axis — unproven. The
    // shared fixture for this is 08_recurrence_parameter_valued_lag.esm.
    const doc = recurrenceDoc(selfIndex({ op: '-', args: ['k', 'n'] })) as unknown as {
      models: { M: { variables: Record<string, unknown> } }
    }
    doc.models.M.variables.n = { type: 'parameter', units: '1', default: 2 }
    expect(findings(validate(doc as unknown as EsmFile))).toEqual([])
  })

  it('admits a lag over a symbol whose range it cannot resolve', () => {
    // A `derived` index set has no static extent, so `a`'s range is unknown and
    // the lag `a` is unbounded. Admitted for the same reason: the evaluator
    // resolves this set and this validator cannot.
    const doc = recurrenceDoc(selfIndex({ op: '-', args: ['k', 'a'] })) as unknown as {
      models: { M: { equations: { rhs: { ranges: Record<string, unknown> } }[] } }
      index_sets: Record<string, unknown>
    }
    doc.index_sets.picked = { kind: 'derived', from_faq: 'nodeid' }
    doc.models.M.equations[0].rhs.ranges.a = { from: 'picked' }
    expect(findings(validate(doc as unknown as EsmFile))).toEqual([])
  })

  it('still rejects an unprovable COEFFICIENT — the half that must be proved', () => {
    // `index(s, n * k)` with `n` a parameter. Here it is the COEFFICIENT of the
    // frame symbol that cannot be determined, so the read names no position
    // relative to the cell being written and which direction it moves is
    // undecidable. This is the asymmetry: unknown constant part is admitted,
    // unknown coefficient is not.
    const doc = recurrenceDoc(selfIndex({ op: '*', args: ['n', 'k'] })) as unknown as {
      models: { M: { variables: Record<string, unknown> } }
    }
    doc.models.M.variables.n = { type: 'parameter', units: '1', default: 2 }
    const finding = onlyFinding(doc as unknown as EsmFile)
    expect(finding.code).toBe('recurrence_not_wellfounded')
    expect(finding.path).toBe(RHS_PATH)
    expect(finding.message).toContain('not affine in its frame symbol')
  })

  it('bounds a symbol over a CATEGORICAL index set by its member count', () => {
    // The evaluator resolves a categorical set to the dense 1..len(members)
    // range before it builds a rule, so a validator that did not would prove
    // less than the evaluator. Pinned through the FORWARD-read rejection, which
    // is only reachable when the bound is actually known: with `a` in 1..3 the
    // lag `-a` is provably in [-3, -1], i.e. hi(lag) < 0.
    const doc = recurrenceDoc(selfIndex({ op: '+', args: ['k', 'a'] })) as unknown as {
      models: { M: { equations: { rhs: { ranges: Record<string, unknown> } }[] } }
      index_sets: Record<string, unknown>
    }
    doc.index_sets.fuels = { kind: 'categorical', members: ['gas', 'diesel', 'e85'] }
    doc.models.M.equations[0].rhs.ranges.a = { from: 'fuels' }
    const finding = onlyFinding(doc as unknown as EsmFile)
    expect(finding.code).toBe('recurrence_not_wellfounded')
    expect(finding.details).toEqual({ variable: 's', recurrence_axis: 'k' })
    expect(finding.message).toContain('names the cell being written, or a later one')
  })
})

// ---------------------------------------------------------------------------
// The two predicates `cadence.ts` and `validate()` share
// ---------------------------------------------------------------------------

describe('recurrence predicates', () => {
  /** The `M` model of a document built by {@link recurrenceDoc}. */
  const modelOf = (doc: EsmFile): Model => (doc as unknown as { models: { M: Model } }).models.M

  it('agree on a well-founded recurrence', () => {
    const model = modelOf(recurrenceDoc(selfIndex({ op: '-', args: ['k', 1] })))
    const esmFile = { index_sets: { steps: { kind: 'interval', size: 4 } } } as unknown as EsmFile
    expect(isRecurrenceCandidate(model, 's', esmFile)).toBe(true)
    expect(isWellFoundedRecurrence(model, 's', esmFile)).toBe(true)
  })

  it('separate CANDIDACY from well-foundedness on a forward read', () => {
    // The distinction the cadence seeder turns on. A malformed array self-read
    // is still the recurrence checker's business — so its self-edge is dropped
    // and `validate()` reaches `recurrence_not_wellfounded` — but it is not a
    // well-founded recurrence.
    const model = modelOf(recurrenceDoc(selfIndex({ op: '+', args: ['k', 1] })))
    const esmFile = { index_sets: { steps: { kind: 'interval', size: 4 } } } as unknown as EsmFile
    expect(isRecurrenceCandidate(model, 's', esmFile)).toBe(true)
    expect(isWellFoundedRecurrence(model, 's', esmFile)).toBe(false)
  })

  it('call a scalar self-reference neither', () => {
    const model = {
      variables: { x: { type: 'unknown' } },
      equations: [{ lhs: 'x', rhs: { op: '+', args: ['x', 1.0] } }],
    } as unknown as Model
    expect(isRecurrenceCandidate(model, 'x')).toBe(false)
    expect(isWellFoundedRecurrence(model, 'x')).toBe(false)
  })

  it('call a BARE array self-reference neither (no `index` read)', () => {
    const model = {
      variables: { s: { type: 'unknown', shape: ['steps'] } },
      equations: [{ lhs: 's', rhs: { op: '+', args: ['s', 1.0] } }],
    } as unknown as Model
    expect(isRecurrenceCandidate(model, 's')).toBe(false)
    expect(isWellFoundedRecurrence(model, 's')).toBe(false)
  })
})

// ---------------------------------------------------------------------------
// The relaxation the gating closes back up
// ---------------------------------------------------------------------------

describe('a self-reference that is NOT a recurrence keeps its cycle rejection', () => {
  it('still throws CadenceCycleError for a scalar `x ~ x + 1`', () => {
    // The exemption belongs to the construct that earns it. A scalar has no axis
    // to fold along, so it can never be a causal recurrence; it is an equation
    // reading a name nothing binds. An earlier draft of this feature dropped
    // every self-edge unconditionally and let this document validate, which is
    // the regression this test pins closed.
    const model = {
      variables: { x: { type: 'unknown' } },
      equations: [{ lhs: 'x', rhs: { op: '+', args: ['x', 1.0] } }],
    } as unknown as Model
    expect(() => new CadenceSeeder(model).leaf('x')).toThrow(CadenceCycleError)
    try {
      new CadenceSeeder(model).leaf('x')
      expect.unreachable('expected a CadenceCycleError')
    } catch (error) {
      expect((error as CadenceCycleError).cycle).toEqual(['x', 'x'])
    }
  })

  it('reports the scalar self-cycle through validate() rather than admitting it', () => {
    const result = validate({
      esm: '1.0.0',
      metadata: { name: 'ScalarSelf', description: 'd', authors: ['t'] },
      models: {
        M: {
          variables: { x: { type: 'unknown', units: '1' } },
          equations: [{ lhs: 'x', rhs: { op: '+', args: ['x', 1.0] } }],
        },
      },
    } as unknown as EsmFile)
    expect(result.is_valid).toBe(false)
    expect(result.structural_errors.map((e) => e.code)).toContain('load_error')
  })

  it('still throws for a BARE array self-reference `s ~ s + 1`', () => {
    // Array-shaped, but with no `index` read there is no position to fold from
    // and nothing else reports it: `checkRecurrenceEquation` returns early when
    // it finds no self-read, so the cycle rejection is the only diagnosis left.
    const model = {
      variables: { s: { type: 'unknown', shape: ['steps'] } },
      equations: [{ lhs: 's', rhs: { op: '+', args: ['s', 1.0] } }],
    } as unknown as Model
    expect(() => new CadenceSeeder(model).leaf('s')).toThrow(CadenceCycleError)
  })
})
