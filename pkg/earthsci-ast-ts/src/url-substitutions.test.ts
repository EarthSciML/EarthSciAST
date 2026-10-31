/**
 * esm-spec §4.7 "Binding a data source's location at the mount"
 * (`url_substitutions`), against the SHARED pin
 * `tests/conformance/url_substitutions/manifest.json`.
 *
 * `cases` pin the edge rule as a document normalization: apply the edge with
 * the MOUNTING document's directory, then §8.2.1 resolution with the DECLARING
 * document's. `fixtures` pin it through a real load. This binding does not
 * hoist a mounted document's `data_sources` at either mount form, so
 * `hoisted_sources` is not checked and a `requires_hoisting` fixture is
 * skipped; the edge's verdict (accepted / refused + code) is.
 */

import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { loadPath, toJson } from './index.js'
import { resolveSubsystemRefs } from './ref-loading.js'
import {
  applyMountUrlSubstitutions,
  placeholders,
  resolveDataSourceUrls,
} from './data-source-urls.js'
import { REPO_ROOT } from './test-helpers.js'

const SUITE = path.join(REPO_ROOT, 'tests', 'conformance', 'url_substitutions')
type Pin = { verbatim?: string; repo_path?: string }
const MANIFEST = JSON.parse(fs.readFileSync(path.join(SUITE, 'manifest.json'), 'utf8')) as {
  declaring_dir: string
  binder_dir: string
  cases: Array<{
    id: string
    url_template: string
    mirrors?: string[]
    url_substitutions: unknown
    expect: {
      url_template?: Pin
      mirrors?: Pin[]
      error_code?: string
      message_contains?: string[]
    }
  }>
  fixtures: Array<{
    id: string
    path: string
    expect: 'accepted' | 'refused'
    requires_hoisting?: boolean
    error_code?: string
    message_contains?: string[]
  }>
}

function expected(pin: Pin): string {
  if (pin.verbatim !== undefined) return pin.verbatim
  return 'file://' + path.join(REPO_ROOT, pin.repo_path as string)
}

function caught(fn: () => unknown): { code?: string; message: string } | null {
  try {
    fn()
    return null
  } catch (e) {
    return e as { code?: string; message: string }
  }
}

async function caughtAsync(
  fn: () => Promise<unknown>,
): Promise<{ code?: string; message: string } | null> {
  try {
    await fn()
    return null
  } catch (e) {
    return e as { code?: string; message: string }
  }
}

describe('esm-spec §4.7 url_substitutions: the edge rule (shared cases)', () => {
  const declaring = path.join(REPO_ROOT, MANIFEST.declaring_dir)
  const binder = path.join(REPO_ROOT, MANIFEST.binder_dir)

  it('the manifest carries cases', () => {
    expect(MANIFEST.cases.length).toBeGreaterThan(0)
  })

  it.each(MANIFEST.cases.map((c) => [c.id, c] as const))('%s', (_id, c) => {
    const source: Record<string, unknown> = { url_template: c.url_template }
    if (c.mirrors !== undefined) source.mirrors = [...c.mirrors]
    let doc: object = { data_sources: { s: { kind: 'static', source } } }
    const err = caught(() => {
      applyMountUrlSubstitutions(doc, c.url_substitutions, binder, 'case')
      doc = resolveDataSourceUrls(doc, declaring) ?? doc
    })
    if (c.expect.error_code !== undefined) {
      expect(err, `${c.id} must be refused`).not.toBeNull()
      expect(err?.code, err?.message).toBe(c.expect.error_code)
      for (const n of c.expect.message_contains ?? []) expect(err?.message).toContain(n)
      return
    }
    expect(err, err?.message).toBeNull()
    const got = (doc as { data_sources: { s: { source: Record<string, unknown> } } }).data_sources.s
      .source
    expect(got.url_template).toBe(expected(c.expect.url_template as Pin))
    if (c.expect.mirrors !== undefined) expect(got.mirrors).toEqual(c.expect.mirrors.map(expected))
  })

  it('an edge without url_substitutions leaves the document alone', () => {
    const doc = { data_sources: { s: { source: { url_template: '{x}/t.nc' } } } }
    const before = JSON.stringify(doc)
    applyMountUrlSubstitutions(doc, undefined, '/a', 'e')
    applyMountUrlSubstitutions(doc, {}, '/a', 'e')
    expect(JSON.stringify(doc)).toBe(before)
  })

  it('placeholders are bare identifiers only', () => {
    expect(placeholders('{a}/{b_1}/{date:%Y}/{1x}/{}/{a').map(([, , n]) => n)).toEqual(['a', 'b_1'])
    expect(placeholders('x{snapshot}y').map(([, , n]) => n)).toEqual(['snapshot'])
  })

  it('a non-object map or a non-string value is data_source_url_unresolved', () => {
    const doc = () => ({ data_sources: { s: { source: { url_template: '{x}/t.nc' } } } })
    expect(caught(() => applyMountUrlSubstitutions(doc(), ['x'], '/a', 'e'))?.code).toBe(
      'data_source_url_unresolved',
    )
    expect(caught(() => applyMountUrlSubstitutions(doc(), { x: 1 }, '/a', 'e'))?.code).toBe(
      'data_source_url_unresolved',
    )
  })
})

describe('esm-spec §4.7 url_substitutions: through a real load (shared fixtures)', () => {
  it.each(MANIFEST.fixtures.map((f) => [f.id, f] as const))('%s', async (_id, f) => {
    if (f.requires_hoisting) return // TypeScript does not hoist a mounted document's data_sources
    const file = path.join(SUITE, f.path)
    let loaded: ReturnType<typeof loadPath> | undefined
    const err = await caughtAsync(async () => {
      loaded = loadPath(file)
      await resolveSubsystemRefs(loaded, path.dirname(file))
    })
    if (f.expect === 'refused') {
      expect(err, `${f.id} must be refused`).not.toBeNull()
      expect(err?.code, err?.message).toBe(f.error_code)
      for (const n of f.message_contains ?? []) expect(err?.message).toContain(n)
      return
    }
    expect(err, err?.message).toBeNull()
    // Consumed at the mount: the edge field does not survive parse → emit, and
    // the mounted catalogue's data_sources are not hoisted in this binding.
    const text = toJson(loaded!)
    expect(text).not.toContain('"url_substitutions":')
    expect(loaded!.data_sources).toBeUndefined()
  })
})
