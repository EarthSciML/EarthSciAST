/**
 * esm-spec §8.2.1 data-source location resolution, against the SHARED pin.
 *
 * Reads `tests/conformance/data_source_url/manifest.json` — the one place the
 * expected resolution is written down — and asserts this binding against it.
 * Every binding's own suite reads the same file, so a path rule that differed
 * between bindings (which would silently make documents non-portable, the
 * defect §8.2.1 closes) fails here rather than downstream.
 *
 * Expectations are repo-relative paths, not literal URLs: the resolved form is
 * a machine-specific absolute `file://` URL and a golden holding one would only
 * pass on the machine that wrote it.
 */

import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { loadDocument, loadPath, toJson } from './index.js'
import { ERROR_CODES } from './errors.js'
import { resolveSourceUrl } from './data-source-urls.js'
import { REPO_ROOT } from './test-helpers.js'

const SUITE = path.join(REPO_ROOT, 'tests', 'conformance', 'data_source_url')
const MANIFEST = JSON.parse(fs.readFileSync(path.join(SUITE, 'manifest.json'), 'utf8')) as {
  fixtures: Array<{
    id: string
    path: string
    sources?: Record<string, { url_template: Pin; mirrors?: Pin[] }>
    error_code?: string
    message_contains?: string[]
  }>
}
type Pin = { verbatim?: string; repo_path?: string }

function expected(pin: Pin): string {
  if (pin.verbatim !== undefined) return pin.verbatim
  return 'file://' + path.join(REPO_ROOT, pin.repo_path as string)
}

function fixture(id: string) {
  const f = MANIFEST.fixtures.find((x) => x.id === id)
  if (f === undefined) throw new Error(`no fixture '${id}' in the shared manifest`)
  return f
}

describe('esm-spec §8.2.1 data-source location resolution', () => {
  it('resolves every pinned form as the shared manifest says', () => {
    const f = fixture('relative_catalog')
    const loaded = loadPath(path.join(SUITE, f.path))
    for (const [name, pin] of Object.entries(f.sources ?? {})) {
      const source = loaded.data_sources?.[name]?.source
      expect(source, `data_sources.${name} must survive load`).toBeDefined()
      expect(source?.url_template, `data_sources.${name}.source.url_template`).toBe(
        expected(pin.url_template),
      )
      if (pin.mirrors !== undefined) {
        expect(source?.mirrors, `data_sources.${name}.source.mirrors`).toEqual(
          pin.mirrors.map(expected),
        )
      }
    }
  })

  it('is idempotent, so parse → emit → parse is stable', () => {
    // Re-loaded with a DIFFERENT base, so a template that had somehow stayed
    // relative would resolve somewhere else and be caught, rather than
    // resolving to the same place by accident.
    const f = fixture('relative_catalog')
    const first = loadPath(path.join(SUITE, f.path))
    const again = JSON.parse(toJson(first)) as object
    for (const [, entry] of Object.entries(first.data_sources ?? {})) {
      const source = (entry as { source?: { url_template?: string } }).source
      expect(resolveSourceUrl(source?.url_template as string, '/somewhere/else')).toBe(
        source?.url_template,
      )
    }
    expect(again).toBeDefined()
  })

  for (const id of ['env_var_catalog', 'env_var_mirror_catalog']) {
    it(`refuses ${id} with a diagnostic that names the template`, () => {
      // Not merely "it does not resolve": the diagnostic has to NAME the entry
      // and the template. Treating `${MOVES_SNAPSHOTS}` as a directory name
      // yields an I/O error about a path nobody wrote, one step away from a
      // source that delivers a consuming parameter's default.
      const f = fixture(id)
      let caught: unknown
      try {
        loadPath(path.join(SUITE, f.path))
      } catch (e) {
        caught = e
      }
      expect(caught, `${id} must be refused at load`).toBeDefined()
      expect((caught as { code?: string }).code).toBe(f.error_code)
      expect(f.error_code).toBe(ERROR_CODES.DATA_SOURCE_URL_UNRESOLVED)
      for (const needle of f.message_contains ?? []) {
        expect(String((caught as Error).message)).toContain(needle)
      }
    })
  }

  it('does not resolve urls inside the callers own object', () => {
    // §8.2.1 resolution must not be a side effect on an argument.
    // `loadDocument(obj)` hands the caller's object straight through with no
    // copy at any level. An in-place rewrite would (a) mutate that argument,
    // and (b) make a SECOND load of the same object resolve an
    // already-resolved URL -- which, against a different base, silently reads a
    // different file. That is the silent-wrong-value shape, so it is pinned.
    const doc = {
      esm: '1.0.0',
      metadata: { name: 'M', description: 'd', authors: ['a'], license: 'MIT' },
      data_sources: {
        t: { kind: 'static', source: { url_template: './tables/probe.parquet' } },
      },
    }
    const source = doc.data_sources.t.source

    const first = loadDocument(doc, { basePath: '/base/one' })
    expect(first.data_sources?.['t']?.source.url_template).toBe(
      'file:///base/one/tables/probe.parquet',
    )
    expect(source.url_template, "the caller's object must keep the AUTHORED template").toBe(
      './tables/probe.parquet',
    )

    // The same object, a different base: it must resolve afresh, not compound.
    const second = loadDocument(doc, { basePath: '/base/two' })
    expect(second.data_sources?.['t']?.source.url_template).toBe(
      'file:///base/two/tables/probe.parquet',
    )
  })

  it('leaves a substitution-led template alone, per §8.2 pass-through', () => {
    expect(resolveSourceUrl('{archive_root}/x.nc', '/a/b')).toBe('{archive_root}/x.nc')
  })

  it('removes dot segments lexically rather than by realpath', () => {
    // §8.2.1: a template carrying a `{date:...}` substitution names a file per
    // timestep, none of which exists at load time, so resolution cannot touch
    // the filesystem.
    expect(resolveSourceUrl('./a/../b/./c.nc', '/x/y')).toBe('file:///x/y/b/c.nc')
    expect(resolveSourceUrl('/../c.nc', '/x/y')).toBe('file:///c.nc')
  })
})
