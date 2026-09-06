import { describe, expect, it } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { loadString, toJson } from './index.js'
import { ERROR_CODES } from './errors.js'
import { resolveTolerances, DEFAULT_ABSTOL, DEFAULT_RELTOL } from './solver.js'

const FIXTURE = join(__dirname, '..', '..', '..', 'tests', 'valid', 'solver_block.esm')
const base = JSON.parse(readFileSync(FIXTURE, 'utf-8')) as Record<string, unknown>

describe('the document-scoped `solver` block (esm-spec §2.2)', () => {
  it('round-trips a declared block verbatim', () => {
    const out = JSON.parse(toJson(loadString(JSON.stringify(base)))) as Record<string, unknown>
    expect(out.solver).toEqual(base.solver)
  })

  it('normalizes an EMPTY block to absence at load', () => {
    // `{}` is legal — every other optional top-level container admits one — but
    // it means what omitting the block means, so it is dropped at load and does
    // not reach emit. Without the load-time step this binding would round-trip
    // `{}` verbatim (toJson serializes the whole document object) while Python
    // and Julia dropped it: five bindings disagreeing about one document.
    const out = JSON.parse(
      toJson(loadString(JSON.stringify({ ...base, solver: {} }))),
    ) as Record<string, unknown>
    expect('solver' in out).toBe(false)
  })

  it('rejects the block in a document declaring esm < 1.1.0', () => {
    // Regression: `rejectSolverPreV11` was defined and exported but never
    // CALLED from the load path, so this binding accepted a 1.0.0 document
    // carrying the block. Nothing caught it — the invalid fixture is pinned
    // `resolver_only`, which asks the schema layer to ACCEPT it.
    expect(() =>
      loadString(JSON.stringify({ ...base, esm: '1.0.0', solver: { stiffness: 'high' } })),
    ).toThrowError(expect.objectContaining({ code: ERROR_CODES.SOLVER_VERSION_TOO_OLD }))
  })

  it('resolves tolerances most-specific first (§2.2.2)', () => {
    const doc = { abstol: 1e-8, reltol: 1e-6 }
    expect(resolveTolerances(doc, { abstol: 1e-12, reltol: 1e-11 })).toEqual({
      abstol: 1e-12,
      reltol: 1e-11,
    })
    expect(resolveTolerances(doc)).toEqual({ abstol: 1e-8, reltol: 1e-6 })
    expect(resolveTolerances(undefined)).toEqual({
      abstol: DEFAULT_ABSTOL,
      reltol: DEFAULT_RELTOL,
    })
    // Per-field fall-through: a document declaring only `reltol` leaves
    // `abstol` on the default.
    expect(resolveTolerances({ reltol: 1e-9 })).toEqual({
      abstol: DEFAULT_ABSTOL,
      reltol: 1e-9,
    })
  })
})
