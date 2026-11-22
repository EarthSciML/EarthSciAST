/**
 * Source documents loaded from files (esm-spec §1.2.1, CONFORMANCE_SPEC §5.61):
 * a document read from a path or a ref is Markdown (`.md`), Typst (`.typ`) or
 * JSON (anything else) by its extension alone, at the root and at every ref
 * site. Runs the shared cases of tests/conformance/source_documents/.
 */
import * as fs from 'node:fs'
import * as path from 'node:path'
import { describe, expect, it } from 'vitest'
import { loadPath } from './parse.js'
import { toJson } from './serialize.js'
import { flatten } from './flatten.js'
import { resolveSubsystemRefsSync } from './ref-loading.js'
import { documentFormatOf } from './path-utils.js'
import { fixturesDir } from './test-helpers.js'
import type { EsmFile } from './types.js'

const dir = fixturesDir('conformance', 'source_documents')

interface Case {
  id: string
  fixture: string
  twin?: string
  expect: 'same_as_twin' | 'ok' | 'error'
  code?: string
  driver: 'load' | 'flatten'
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

/** Load, resolve the mounts in place (load keeps them). */
function loadResolved(p: string): EsmFile {
  const f = loadPath(p)
  resolveSubsystemRefsSync(f, path.dirname(p))
  return f
}

/** Run a case through its driver. */
function drive(c: Case, p: string): EsmFile {
  const f = loadResolved(p)
  if (c.driver === 'flatten') flatten(f)
  return f
}

describe('source_documents conformance (tests/conformance/source_documents)', () => {
  it('has cases', () => expect(manifest.cases.length).toBeGreaterThan(0))
  for (const c of manifest.cases) {
    it(c.id, () => {
      const p = path.join(dir, c.fixture)
      if (c.expect === 'same_as_twin') {
        const got = loadResolved(p)
        const want = loadResolved(path.join(dir, c.twin!))
        expect(blankRefs(JSON.parse(toJson(got)))).toEqual(blankRefs(JSON.parse(toJson(want))))
      } else if (c.expect === 'ok') {
        expect(code(() => drive(c, p))).toBe('NO_ERROR')
      } else {
        expect(code(() => drive(c, p))).toBe(c.code)
      }
    })
  }
})

describe('documentFormatOf (esm-spec §1.2.1)', () => {
  it('picks the format by the exact, case-sensitive extension', () => {
    expect(documentFormatOf('a/b.md')).toBe('markdown')
    expect(documentFormatOf('a/b.typ')).toBe('typst')
    expect(documentFormatOf('a/b.esm')).toBeUndefined()
    expect(documentFormatOf('a/b.json')).toBeUndefined()
    expect(documentFormatOf('a/b.MD')).toBeUndefined()
    expect(documentFormatOf('a/b.Typ')).toBeUndefined()
    expect(documentFormatOf('a/b.md.esm')).toBeUndefined()
  })

  it("reads a URL's path, ignoring its query and fragment", () => {
    expect(documentFormatOf('https://example.com/lib.typ?raw=1')).toBe('typst')
    expect(documentFormatOf('https://example.com/lib.md#top')).toBe('markdown')
    expect(documentFormatOf('https://example.com/lib.esm?f=x.md')).toBeUndefined()
  })

  it("never reads a URL's host as its path", () => {
    expect(documentFormatOf('https://docs.example.md')).toBeUndefined()
    expect(documentFormatOf('https://host.typ?x=1')).toBeUndefined()
    expect(documentFormatOf('https://host.typ#a.md')).toBeUndefined()
  })
})
