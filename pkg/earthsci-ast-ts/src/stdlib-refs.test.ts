/**
 * Standard-library refs (esm-spec §4.7): `esm:std/<file>.esm` resolves to the
 * bundled `lib/` (`stdlib-bundle.ts`). Runs the shared cases of
 * tests/conformance/stdlib_refs/ and checks the bundle-internal rules against a
 * substitute bundle.
 */
import * as fs from 'node:fs'
import * as path from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { loadPath, loadString } from './parse.js'
import { toJson } from './serialize.js'
import { flatten } from './flatten.js'
import { resolveSubsystemRefsSync } from './ref-loading.js'
import { classifyStdRef, setStdlibFilesForTesting, STDLIB_BASE } from './stdlib.js'
import { fixturesDir } from './test-helpers.js'
import type { EsmFile } from './types.js'

const dir = fixturesDir('conformance', 'stdlib_refs')

interface Case {
  id: string
  fixture: string
  twin?: string
  expect: 'same_as_twin' | 'error'
  code?: string
  driver: 'load' | 'flatten'
  env?: Record<string, string>
}

const manifest = JSON.parse(fs.readFileSync(path.join(dir, 'manifest.json'), 'utf8')) as {
  cases: Case[]
}

function code(fn: () => unknown): string {
  try {
    fn()
    return 'NO_ERROR'
  } catch (e) {
    return (e as { code?: string }).code ?? `<${String(e)}>`
  }
}

function withEnv<T>(env: Record<string, string> | undefined, fn: () => T): T {
  const saved: Record<string, string | undefined> = {}
  for (const [k, v] of Object.entries(env ?? {})) {
    saved[k] = process.env[k]
    process.env[k] = v
  }
  try {
    return fn()
  } finally {
    for (const [k, v] of Object.entries(saved)) {
      if (v === undefined) delete process.env[k]
      else process.env[k] = v
    }
  }
}

/** Replace every string value of a `ref` key by one placeholder. */
function blankRefs(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(blankRefs)
  if (v !== null && typeof v === 'object') {
    const out: Record<string, unknown> = {}
    for (const [k, c] of Object.entries(v)) {
      out[k] = k === 'ref' && typeof c === 'string' ? '<ref>' : blankRefs(c)
    }
    return out
  }
  return v
}

/** Load, resolve the mounts in place (load keeps them), serialize. */
function loadResolved(p: string): EsmFile {
  const f = loadPath(p)
  resolveSubsystemRefsSync(f, path.dirname(p))
  return f
}

describe('stdlib_refs conformance (tests/conformance/stdlib_refs)', () => {
  it('has cases', () => expect(manifest.cases.length).toBeGreaterThan(0))
  for (const c of manifest.cases) {
    it(c.id, () => {
      withEnv(c.env, () => {
        const p = path.join(dir, c.fixture)
        if (c.expect === 'same_as_twin') {
          const got = loadResolved(p)
          const want = loadResolved(path.join(dir, c.twin!))
          expect(blankRefs(JSON.parse(toJson(got)))).toEqual(blankRefs(JSON.parse(toJson(want))))
          expect(JSON.parse(JSON.stringify(flatten(got)))).toEqual(
            JSON.parse(JSON.stringify(flatten(want))),
          )
        } else {
          const got = code(() => {
            const f = loadResolved(p)
            if (c.driver === 'flatten') flatten(f)
          })
          expect(got).toBe(c.code)
        }
      })
    })
  }
})

describe('esm:std refs', () => {
  afterEach(() => setStdlibFilesForTesting())

  it('resolve from a document loaded from a string with no base', () => {
    const text = fs.readFileSync(path.join(dir, 'import_interp.esm'), 'utf8')
    expect(code(() => loadString(text))).toBe('NO_ERROR')
  })

  it('classify refs', () => {
    expect(classifyStdRef('esm:std/interp.esm', '/any')).toEqual({
      identity: 'esm:std/interp.esm',
      valid: true,
    })
    expect(classifyStdRef('esm:std/./interp.esm')).toEqual({
      identity: 'esm:std/interp.esm',
      valid: true,
    })
    expect(classifyStdRef('esm:std/../interp.esm')?.valid).toBe(false)
    expect(classifyStdRef('esm:std/a/b.esm')?.valid).toBe(false)
    expect(classifyStdRef('esm:other/x.esm')?.valid).toBe(false)
    expect(classifyStdRef('./calendar.esm', STDLIB_BASE)).toEqual({
      identity: 'esm:std/calendar.esm',
      valid: true,
    })
    expect(classifyStdRef('../x.esm', STDLIB_BASE)?.valid).toBe(false)
    expect(classifyStdRef('calendar.esm', '/any')).toBeUndefined()
    expect(classifyStdRef('https://example.com/x.esm', STDLIB_BASE)).toBeUndefined()
  })

  const lib = (name: string, importRef?: string): string =>
    JSON.stringify({
      esm: '1.1.0',
      metadata: { name },
      ...(importRef ? { expression_template_imports: [{ ref: importRef }] } : {}),
      expression_templates: {
        [`${name}_twice`]: { params: ['x'], body: { op: '*', args: [2, 'x'] } },
      },
    })

  const consumer = JSON.stringify({
    esm: '1.1.0',
    metadata: { name: 'consumer' },
    models: {
      M: {
        expression_template_imports: [{ ref: 'esm:std/a.esm' }],
        variables: {
          x: { type: 'unknown', units: '1', default: 1.0 },
          y: { type: 'unknown', units: '1' },
        },
        equations: [
          { lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: { op: '-', args: ['x'] } },
          {
            lhs: 'y',
            rhs: {
              op: 'apply_expression_template',
              args: [],
              name: 'b_twice',
              bindings: { x: 'x' },
            },
          },
        ],
      },
    },
  })

  for (const ref of ['b.esm', './b.esm', 'esm:std/b.esm']) {
    it(`a bundled file reaches its sibling through '${ref}'`, () => {
      setStdlibFilesForTesting({ 'a.esm': lib('a', ref), 'b.esm': lib('b') })
      expect(code(() => loadString(consumer))).toBe('NO_ERROR')
    })
  }

  it('a relative ref leaving the bundle is unresolved', () => {
    setStdlibFilesForTesting({ 'a.esm': lib('a', '../b.esm'), 'b.esm': lib('b') })
    expect(code(() => loadString(consumer))).toBe('template_import_unresolved')
  })

  it('detects a cycle by esm:std identity', () => {
    setStdlibFilesForTesting({ 'a.esm': lib('a', 'esm:std/b.esm'), 'b.esm': lib('b', './a.esm') })
    expect(code(() => loadString(consumer))).toBe('template_import_cycle')
  })

  it('a bundled subsystem file mounts its sibling', () => {
    setStdlibFilesForTesting({
      'outer.esm': JSON.stringify({
        esm: '1.1.0',
        metadata: { name: 'outer' },
        models: {
          Outer: {
            subsystems: { Inner: { ref: 'inner.esm' } },
            variables: { z: { type: 'unknown', units: '1' } },
            equations: [{ lhs: 'z', rhs: { op: '*', args: [2, 'Inner.w'] } }],
          },
        },
      }),
      'inner.esm': JSON.stringify({
        esm: '1.1.0',
        metadata: { name: 'inner' },
        models: {
          Inner: {
            variables: { w: { type: 'unknown', units: '1', default: 1.0 } },
            equations: [{ lhs: { op: 'D', args: ['w'], wrt: 't' }, rhs: { op: '-', args: ['w'] } }],
          },
        },
      }),
    })
    const f = loadString(
      JSON.stringify({
        esm: '1.1.0',
        metadata: { name: 'mounter' },
        models: {
          Top: {
            subsystems: { Outer: { ref: 'esm:std/outer.esm' } },
            variables: { q: { type: 'unknown', units: '1' } },
            equations: [{ lhs: 'q', rhs: 'Outer.z' }],
          },
        },
      }),
    )
    resolveSubsystemRefsSync(f, '.')
    expect(JSON.stringify(flatten(f))).toContain('Top.Outer.Inner.w')
  })
})
