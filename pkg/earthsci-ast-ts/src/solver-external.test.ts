/**
 * esm-spec §2.2.6 `solver.external` resolution, against the SHARED pin.
 *
 * Reads `tests/conformance/solver_external/manifest.json` and asserts this
 * binding against it: what the typed document holds, what the accessor
 * returns, and what `toJson` writes. Expectations are repo-relative or
 * working-directory-relative paths, never literal absolute URLs, because a
 * resolved location is machine-specific. Nothing a fixture names exists on
 * disk, and nothing here creates it.
 */

import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import {
  flatten,
  loadPath,
  loadString,
  rejectSolverExternalPreV13,
  resolveSubsystemRefs,
  solverExternalLocation,
  toJson,
} from './index.js'
import { ERROR_CODES } from './errors.js'
import { removeDotSegments } from './data-source-urls.js'
import { REPO_ROOT } from './test-helpers.js'
import type { EsmFile } from './types.js'

const SUITE = path.join(REPO_ROOT, 'tests', 'conformance', 'solver_external')

type Pin = { repo_path?: string; cwd_path?: string; verbatim?: string }
interface Fixture {
  id: string
  path: string
  load: 'path' | 'string'
  base: Pin | null
  expect: 'accepted' | 'refused'
  external?: string | null
  location?: Pin | null
  solver?: unknown
  error_code?: string
  message_contains?: string[]
}
const MANIFEST = JSON.parse(fs.readFileSync(path.join(SUITE, 'manifest.json'), 'utf8')) as {
  bindings_required: string[]
  fixtures: Fixture[]
  invariance: { with: string; without: string }
}

function expand(pin: Pin | null | undefined): string | null {
  if (pin === null || pin === undefined) return null
  if (pin.verbatim !== undefined) return pin.verbatim
  if (pin.repo_path !== undefined)
    return 'file://' + removeDotSegments(path.join(REPO_ROOT, pin.repo_path))
  if (pin.cwd_path !== undefined)
    return 'file://' + removeDotSegments(process.cwd() + '/' + pin.cwd_path)
  throw new Error('a location pin must carry repo_path, cwd_path or verbatim')
}

function load(f: Fixture): EsmFile {
  const p = path.join(SUITE, f.path)
  return f.load === 'path' ? loadPath(p) : loadString(fs.readFileSync(p, 'utf8'))
}

function emittedSolver(file: EsmFile): unknown {
  return (JSON.parse(toJson(file)) as { solver?: unknown }).solver ?? null
}

const accepted = MANIFEST.fixtures.filter((f) => f.expect === 'accepted')
const refused = MANIFEST.fixtures.filter((f) => f.expect === 'refused')

describe('esm-spec §2.2.6 solver.external resolution', () => {
  it('names typescript among the required bindings', () => {
    expect(MANIFEST.bindings_required).toContain('typescript')
    expect(accepted.length).toBeGreaterThan(0)
    expect(refused.length).toBeGreaterThan(0)
  })

  it.each(accepted.map((f) => [f.id, f] as const))('%s resolves as the shared pin says', (_, f) => {
    const file = load(f)
    expect(file.solver?.external ?? null).toBe(f.external ?? null)
    const base = f.base === null ? undefined : path.join(REPO_ROOT, f.base.repo_path as string)
    expect(solverExternalLocation(file, base)).toBe(expand(f.location))
    expect(emittedSolver(file)).toEqual(f.solver ?? null)
  })

  it.each(refused.map((f) => [f.id, f] as const))('%s is refused at load', (_, f) => {
    expect(f.error_code).toBe(ERROR_CODES.SOLVER_EXTERNAL_UNRESOLVED)
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

  it('a mounted leaf’s solver block does not reach the root after ref resolution', async () => {
    for (const id of [
      'mount_root_with_external',
      'mount_root_without_external',
      'mount_subsystem_root_without_external',
    ]) {
      const f = accepted.find((x) => x.id === id) as Fixture
      const file = load(f)
      await resolveSubsystemRefs(file, path.dirname(path.join(SUITE, f.path)))
      expect(file.solver?.external ?? null, id).toBe(f.external ?? null)
      expect(solverExternalLocation(file), id).toBe(expand(f.location))
      expect(emittedSolver(file), id).toEqual(f.solver ?? null)
    }
  })

  it('keeps the authored string when the document is emitted elsewhere', () => {
    const file = loadPath(path.join(SUITE, 'fixtures', 'dot_relative.esm'))
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'solver-external-'))
    try {
      const moved = path.join(dir, 'moved.esm')
      fs.writeFileSync(moved, toJson(file))
      const again = loadPath(moved)
      expect(again.solver?.external).toBe('./runs/probe.run.json')
      expect(solverExternalLocation(again)).toBe(
        'file://' + removeDotSegments(path.resolve(dir) + '/runs/probe.run.json'),
      )
    } finally {
      fs.rmSync(dir, { recursive: true, force: true })
    }
  })

  it('leaves the flattened system unchanged', () => {
    const flat = (rel: string) => flatten(loadPath(path.join(SUITE, rel)))
    expect(flat(MANIFEST.invariance.with)).toEqual(flat(MANIFEST.invariance.without))
  })
})

describe('solver.external load gates', () => {
  const doc = (esm: string, solver: string) =>
    `{"esm":"${esm}","metadata":{"name":"T"},"solver":${solver},` +
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
    ['1.2.0', '{"external":"a.json"}', ERROR_CODES.SOLVER_EXTERNAL_VERSION_TOO_OLD],
    ['1.1.0', '{"reltol":1e-6,"external":"a.json"}', ERROR_CODES.SOLVER_EXTERNAL_VERSION_TOO_OLD],
    ['1.0.0', '{"external":"a.json"}', ERROR_CODES.SOLVER_VERSION_TOO_OLD],
    ['1.2.0', '{"external":"${X}/a.json"}', ERROR_CODES.SOLVER_EXTERNAL_VERSION_TOO_OLD],
    ['1.2.0', '{"reltol":1e-6}', null],
    ['1.3.0', '{"external":"a.json"}', null],
  ])('esm %s, solver %s -> %s', (esm, solver, want) => {
    expect(codeOf(() => loadString(doc(esm, solver)))).toBe(want)
  })

  it('names /solver/external in the version-gate message', () => {
    expect(() =>
      rejectSolverExternalPreV13({ esm: '1.2.0', solver: { external: 'a.json' } }),
    ).toThrow(/\/solver\/external/)
  })

  it.each([
    ['solver_external_version_too_old.esm', ERROR_CODES.SOLVER_EXTERNAL_VERSION_TOO_OLD],
    ['solver_external_env_var.esm', ERROR_CODES.SOLVER_EXTERNAL_UNRESOLVED],
  ])('refuses the corpus document %s with its pinned code', (name, want) => {
    const pins = JSON.parse(
      fs.readFileSync(path.join(REPO_ROOT, 'tests', 'invalid', 'expected_errors.json'), 'utf8'),
    ) as Record<string, { resolver_only?: boolean; resolver_error_code?: string }>
    expect(pins[name]?.resolver_only).toBe(true)
    expect(pins[name]?.resolver_error_code).toBe(want)
    expect(codeOf(() => loadPath(path.join(REPO_ROOT, 'tests', 'invalid', name)))).toBe(want)
  })
})

describe('solverExternalLocation base handling', () => {
  const inMemory = (external?: string) =>
    ({
      esm: '1.3.0',
      metadata: { name: 'T' },
      ...(external ? { solver: { external } } : {}),
    }) as unknown as EsmFile

  it('takes a relative explicit base against the working directory', () => {
    const cwd = process.cwd()
    expect(solverExternalLocation(inMemory('x/../run.json'))).toBe(
      'file://' + removeDotSegments(cwd + '/run.json'),
    )
    expect(solverExternalLocation(inMemory('x/../run.json'), 'rel/./dir')).toBe(
      'file://' + removeDotSegments(cwd + '/rel/dir/run.json'),
    )
    expect(solverExternalLocation(inMemory('x/../run.json'), '/abs/a/../b')).toBe(
      'file:///abs/b/run.json',
    )
  })

  it('returns null without an external and refuses an in-memory ${', () => {
    expect(solverExternalLocation(inMemory())).toBeNull()
    expect(() => solverExternalLocation(inMemory('${HOME}/r.json'))).toThrow(/\/solver\/external/)
  })
})
