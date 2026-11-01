/**
 * esm-spec §4.7 "Binding a data source's location at the mount"
 * (`url_substitutions`), against the SHARED pin
 * `tests/conformance/url_substitutions/manifest.json`.
 *
 * `cases` pin the edge rule as a document normalization: apply the edge with
 * the MOUNTING document's directory, then §8.2.1 resolution with the DECLARING
 * document's (a case with `binder_url` mounts from a URL-valued directory).
 * `fixtures` pin it through a real load, at both mount forms: the verdict, the
 * locations the ROOT document's `data_sources` carry once every mounted
 * document's sources have merged up (esm-spec §4.7 "A mounted document's data
 * sources"), and `index_set_sizes` — how an edge's `bindings` reach, through a
 * catalogue, the model the catalogue mounts ("Bindings reach through an
 * assembly").
 */

import { afterEach, describe, expect, it, vi } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { loadPath, loadString, toJson } from './index.js'
import { resolveSubsystemRefs } from './ref-loading.js'
import {
  applyMountUrlSubstitutions,
  joinUrlDirectory,
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
    binder_url?: string
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
    hoisted_sources?: Record<string, { url_template: Pin; mirrors?: Pin[] }>
    index_set_sizes?: Record<string, number>
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
      applyMountUrlSubstitutions(doc, c.url_substitutions, c.binder_url ?? binder, 'case')
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
      // esm-spec §9.6.6: a merge conflict names BOTH contributing edges.
      if (f.error_code === 'data_source_merge_conflict') {
        expect(err?.message).toContain('subsystems.A')
        expect(err?.message).toContain('subsystems.B')
      }
      return
    }
    expect(err, err?.message).toBeNull()
    // Consumed at the mount: the edge field does not survive parse → emit.
    const text = toJson(loaded!)
    expect(text).not.toContain('"url_substitutions":')
    const sources = (loaded!.data_sources ?? {}) as Record<
      string,
      { source?: { url_template?: string; mirrors?: string[] } }
    >
    for (const [name, pin] of Object.entries(f.hoisted_sources ?? {})) {
      const src = sources[name]?.source
      expect(src, `data_sources.${name} must reach the root`).toBeDefined()
      expect(src?.url_template, `data_sources.${name}.source.url_template`).toBe(
        expected(pin.url_template),
      )
      if (pin.mirrors !== undefined) {
        expect(src?.mirrors, `data_sources.${name}.source.mirrors`).toEqual(
          pin.mirrors.map(expected),
        )
      }
    }
    const isets = (loaded!.index_sets ?? {}) as Record<string, { size?: unknown }>
    for (const [name, size] of Object.entries(f.index_set_sizes ?? {})) {
      expect(isets[name]?.size, `index_sets.${name}.size`).toBe(size)
    }
    // The emitted root re-loads: what crossed the mount is an ordinary document.
    expect(() => loadString(text)).not.toThrow()
  })
})

describe('RFC 3986 join onto a URL-valued directory', () => {
  it('reads the base as a directory and removes dot segments', () => {
    expect(joinUrlDirectory('https://h/a/b', '../c/./d')).toBe('https://h/a/c/d')
    expect(joinUrlDirectory('https://h/a/b/', 'c')).toBe('https://h/a/b/c')
    expect(joinUrlDirectory('https://h', 'c/{date:%Y}.nc')).toBe('https://h/c/{date:%Y}.nc')
    expect(joinUrlDirectory('https://h/a?q=1#f', 'c/')).toBe('https://h/a/c/')
  })
})

describe('esm-spec §4.7 "Bindings reach through an assembly": a catalogue on the network', () => {
  // A catalogue that declares no metaparameters and mounts a model that does,
  // both served by a mocked `fetch`: the forwarding walk must reach the model
  // through the loader's own reader, not skip the remote mount.
  const sized = fs.readFileSync(path.join(SUITE, 'catalogue', 'sized.esm'), 'utf8')
  const catalogue = (ref: string): string =>
    JSON.stringify({
      esm: '1.0.0',
      metadata: { name: 'remote_catalogue' },
      models: { Inner: { ref } },
    })
  const run = (ref: string): string =>
    JSON.stringify({
      esm: '1.0.0',
      metadata: { name: 'remote_run' },
      models: {
        Run: {
          variables: {},
          equations: [],
          subsystems: { Snap: { ref, bindings: { n_rows: 4 } } },
        },
      },
    })
  const serve = (files: Record<string, string>): void => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async (url: string) =>
        url in files
          ? new Response(files[url], { status: 200 })
          : new Response('missing', { status: 404, statusText: 'Not Found' }),
      ),
    )
  }
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it.each([
    ['an absolute URL', 'https://example.test/lib/sized.esm'],
    ['a relative ref joined onto its URL directory', 'sized.esm'],
  ])('the catalogue mounts the model by %s', async (_label, innerRef) => {
    serve({
      'https://example.test/lib/catalogue.esm': catalogue(innerRef),
      'https://example.test/lib/sized.esm': sized,
    })
    const doc = loadString(run('https://example.test/lib/catalogue.esm'))
    await resolveSubsystemRefs(doc, SUITE)
    const isets = (doc.index_sets ?? {}) as Record<string, { size?: unknown }>
    expect(isets.rows?.size).toBe(4)
  })

  it('an unreadable nested mount reports the read, not an unknown name', async () => {
    serve({ 'https://example.test/lib/catalogue.esm': catalogue('missing.esm') })
    const doc = loadString(run('https://example.test/lib/catalogue.esm'))
    const err = await caughtAsync(() => resolveSubsystemRefs(doc, SUITE))
    expect(err).not.toBeNull()
    expect(err?.code, err?.message).toBe('unresolved_subsystem_ref')
  })
})
