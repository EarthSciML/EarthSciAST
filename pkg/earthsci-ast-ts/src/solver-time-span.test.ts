/**
 * esm-spec §2.2.7 `solver.time_span`, against the SHARED pin.
 *
 * Reads `tests/conformance/solver_time_span/manifest.json` and asserts this
 * binding against it: what `resolveTimeSpan` returns (binary64-exact), what
 * `toJson` writes for the root's `solver` block, and which loads are refused.
 */

import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import {
  loadPath,
  loadString,
  rejectSolverTimeSpanPreV13,
  resolveSubsystemRefs,
  resolveTimeSpan,
  toJson,
} from './index.js'
import { ERROR_CODES } from './errors.js'
import { REPO_ROOT } from './test-helpers.js'
import type { EsmFile } from './types.js'

const SUITE = path.join(REPO_ROOT, 'tests', 'conformance', 'solver_time_span')

interface Fixture {
  id: string
  path: string
  expect: 'accepted' | 'refused'
  solver?: unknown
  seconds?: [number, number] | null
  error_code?: string
  message_contains?: string[]
}
const MANIFEST = JSON.parse(fs.readFileSync(path.join(SUITE, 'manifest.json'), 'utf8')) as {
  bindings_required: string[]
  fixtures: Fixture[]
  call_site: {
    cases: { fixture: string; call_site: [number, number]; resolved: [number, number] }[]
  }
}

const byId = new Map(MANIFEST.fixtures.map((f) => [f.id, f]))
const load = (f: Fixture): EsmFile => loadPath(path.join(SUITE, f.path))
const emittedSolver = (file: EsmFile): unknown =>
  (JSON.parse(toJson(file)) as { solver?: unknown }).solver ?? null

const accepted = MANIFEST.fixtures.filter((f) => f.expect === 'accepted')
const refused = MANIFEST.fixtures.filter((f) => f.expect === 'refused')

/** Binary64 equality, bound by bound (`toBe` is `Object.is`: -0 ≠ 0 would be too strict). */
function expectSeconds(got: [number, number] | null, want: [number, number] | null | undefined) {
  if (want === null || want === undefined) {
    expect(got).toBeNull()
    return
  }
  expect(got).not.toBeNull()
  expect((got as [number, number])[0] === want[0]).toBe(true)
  expect((got as [number, number])[1] === want[1]).toBe(true)
}

describe('esm-spec §2.2.7 solver.time_span', () => {
  it('names typescript among the required bindings', () => {
    expect(MANIFEST.bindings_required).toContain('typescript')
    expect(accepted.length).toBeGreaterThan(0)
    expect(refused.length).toBeGreaterThan(0)
  })

  it.each(accepted.map((f) => [f.id, f] as const))('%s resolves as the shared pin says', (_, f) => {
    const file = load(f)
    expectSeconds(resolveTimeSpan(file), f.seconds)
    expect(emittedSolver(file)).toEqual(f.solver ?? null)
  })

  it.each(refused.map((f) => [f.id, f] as const))('%s is refused at load', (_, f) => {
    let caught: unknown
    try {
      load(f)
    } catch (e) {
      caught = e
    }
    expect(caught, 'must be REFUSED at load').toBeInstanceOf(Error)
    expect((caught as { code?: string }).code).toBe(f.error_code)
    for (const needle of f.message_contains ?? []) {
      expect((caught as Error).message).toContain(needle)
    }
  })

  it.each(MANIFEST.call_site.cases.map((c) => [c.fixture, c] as const))(
    'a call-site interval wins over %s',
    (_, c) => {
      const file = load(byId.get(c.fixture) as Fixture)
      expectSeconds(resolveTimeSpan(file, c.call_site), c.resolved)
    },
  )

  it('a mounted leaf’s solver block does not reach the root after ref resolution', async () => {
    const mounts = accepted.filter((x) => x.id.startsWith('mount_'))
    expect(mounts.length).toBeGreaterThanOrEqual(8)
    for (const f of mounts) {
      const file = load(f)
      await resolveSubsystemRefs(file, path.dirname(path.join(SUITE, f.path)))
      expectSeconds(resolveTimeSpan(file), f.seconds)
      expect(emittedSolver(file), f.id).toEqual(f.solver ?? null)
    }
  })

  it('keeps the authored bounds through parse → emit → parse', () => {
    const file = load(byId.get('mixed') as Fixture)
    const again = loadString(toJson(file))
    expect(again.solver?.time_span).toEqual({ start: 0, end: '2019-07-01T01:00:00Z' })
    expectSeconds(resolveTimeSpan(again), [0, 3600])
  })
})

describe('solver.time_span load gates', () => {
  const doc = (esm: string, solver: string, domain = '') =>
    `{"esm":"${esm}","metadata":{"name":"T"},"solver":${solver},${domain}` +
    `"models":{"M":{"variables":{"x":{"type":"unknown","units":"m","default":1.0}},` +
    `"equations":[{"lhs":{"op":"D","args":["x"],"wrt":"t"},"rhs":{"op":"neg","args":["x"]}}]}}}`
  const codeOf = (fn: () => unknown): string | null => {
    try {
      fn()
    } catch (e) {
      return (e as { code?: string }).code ?? 'uncoded'
    }
    return null
  }

  it.each([
    ['1.2.0', '{"time_span":{"start":0,"end":1}}', ERROR_CODES.SOLVER_TIME_SPAN_VERSION_TOO_OLD],
    ['1.0.0', '{"time_span":{"start":0,"end":1}}', ERROR_CODES.SOLVER_VERSION_TOO_OLD],
    // The version gate precedes the interval check …
    ['1.2.0', '{"time_span":{"start":1,"end":0}}', ERROR_CODES.SOLVER_TIME_SPAN_VERSION_TOO_OLD],
    // … `external` is gated before `time_span` …
    [
      '1.2.0',
      '{"external":"a.json","time_span":{"start":0,"end":1}}',
      ERROR_CODES.SOLVER_EXTERNAL_VERSION_TOO_OLD,
    ],
    // … and the `${` refusal precedes the interval check.
    [
      '1.3.0',
      '{"external":"${X}","time_span":{"start":1,"end":0}}',
      ERROR_CODES.SOLVER_EXTERNAL_UNRESOLVED,
    ],
    ['1.3.0', '{"time_span":{"start":1,"end":0}}', ERROR_CODES.SOLVER_TIME_SPAN_INVALID],
    // Interval check runs before schema validation.
    ['1.3.0', '{"time_span":{"start":1,"end":0},"bogus":1}', ERROR_CODES.SOLVER_TIME_SPAN_INVALID],
    // A bound with no schema-valid form is the schema's to report.
    ['1.3.0', '{"time_span":{"start":"yesterday","end":0}}', 'schema_validation_failed'],
    ['1.3.0', '{"time_span":{"start":0}}', 'schema_validation_failed'],
    ['1.3.0', '{"time_span":{"start":0,"end":1}}', null],
    // A number past binary64 parses to Infinity and is refused, not skipped.
    ['1.3.0', '{"time_span":{"start":1e400,"end":1e400}}', ERROR_CODES.SOLVER_TIME_SPAN_INVALID],
    ['1.3.0', '{"time_span":{"start":0,"end":1e400}}', ERROR_CODES.SOLVER_TIME_SPAN_INVALID],
    ['1.2.0', '{"reltol":1e-6}', null],
  ])('esm %s, solver %s -> %s', (esm, solver, want) => {
    const got = codeOf(() => loadString(doc(esm, solver)))
    if (want === 'schema_validation_failed') {
      expect(got).not.toBeNull()
      expect(got).not.toBe(ERROR_CODES.SOLVER_TIME_SPAN_INVALID)
    } else {
      expect(got).toBe(want)
    }
  })

  it('names /solver/time_span in the version-gate message', () => {
    expect(() =>
      rejectSolverTimeSpanPreV13({ esm: '1.2.0', solver: { time_span: { start: 0, end: 1 } } }),
    ).toThrow(/\/solver\/time_span/)
  })

  it('names the start origin field when it is unreadable', () => {
    const domain = '"domain":{"temporal":{"start":"2019-07-01T25:00:00Z"}},'
    const ts = '{"time_span":{"start":"2019-07-01T00:00:00Z","end":"2019-07-02T00:00:00Z"}}'
    expect(() => loadString(doc('1.3.0', ts, domain))).toThrow(/\/domain\/temporal\/start/)
    // A number-only interval never reads the origin.
    expect(
      codeOf(() => loadString(doc('1.3.0', '{"time_span":{"start":0,"end":1}}', domain))),
    ).not.toBe(ERROR_CODES.SOLVER_TIME_SPAN_INVALID)
  })

  it.each([
    ['solver_time_span_version_too_old.esm', ERROR_CODES.SOLVER_TIME_SPAN_VERSION_TOO_OLD],
    ['solver_time_span_reversed.esm', ERROR_CODES.SOLVER_TIME_SPAN_INVALID],
  ])('refuses the corpus document %s with its pinned code', (name, want) => {
    const pins = JSON.parse(
      fs.readFileSync(path.join(REPO_ROOT, 'tests', 'invalid', 'expected_errors.json'), 'utf8'),
    ) as Record<string, { resolver_only?: boolean; resolver_error_code?: string }>
    expect(pins[name]?.resolver_only).toBe(true)
    expect(pins[name]?.resolver_error_code).toBe(want)
    expect(codeOf(() => loadPath(path.join(REPO_ROOT, 'tests', 'invalid', name)))).toBe(want)
  })
})

describe('resolveTimeSpan on a document built in memory', () => {
  const inMemory = (time_span?: unknown, temporal?: unknown) =>
    ({
      esm: '1.3.0',
      metadata: { name: 'T' },
      ...(time_span !== undefined ? { solver: { time_span } } : {}),
      ...(temporal !== undefined ? { domain: { temporal } } : {}),
    }) as unknown as EsmFile

  it('returns null without an interval, and the call site when given', () => {
    expect(resolveTimeSpan(inMemory())).toBeNull()
    expect(resolveTimeSpan(inMemory(), [1, 2])).toEqual([1, 2])
  })

  it.each([
    ['9999-12-31T23:59:59Z', 253402300799],
    ['0000-03-01T00:00:00Z', -62162035200],
    ['1900-03-01T00:00:00Z', -2203891200],
    ['2400-02-29T00:00:00Z', 13574563200],
  ])('converts %s against the POSIX epoch', (stamp, want) => {
    expect(resolveTimeSpan(inMemory({ start: -1e12, end: stamp }))).toEqual([-1e12, want])
  })

  it('adds the fraction difference after the whole difference', () => {
    const got = resolveTimeSpan(
      inMemory(
        { start: '2019-07-01T00:00:00.1Z', end: '2019-07-01T00:00:00.3Z' },
        { reference_time: '2019-07-01T00:00:00.2Z' },
      ),
    )
    expect(got).toEqual([0.1 - 0.2, 0.3 - 0.2])
  })

  it.each([['1900-02-29T00:00:00Z'], ['2019-02-30T00:00:00Z']])(
    'refuses %s, which names no calendar day',
    (stamp) => {
      expect(() => resolveTimeSpan(inMemory({ start: 0, end: stamp }))).toThrow(
        /\/solver\/time_span/,
      )
    },
  )

  it('refuses a bound with no schema-valid form', () => {
    expect(() => resolveTimeSpan(inMemory({ start: 0, end: '2019-07-01' }))).toThrow(
      /\/solver\/time_span/,
    )
  })
})
