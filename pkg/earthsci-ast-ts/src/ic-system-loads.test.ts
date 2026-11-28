/**
 * The loader half of tests/conformance/ic_system (esm 2.5.0, esm-spec §11.4.4,
 * §4.2): a deprecated `initialization_equations` block is rewritten into `ic`
 * equations (or into `guesses` for a model with no time derivative) with the
 * warning `deprecated_field`, a malformed `ic` argument is refused at load,
 * and an `ic` anywhere in an equation is valid. TypeScript does not simulate,
 * so the manifest's `cases` and the build-time balance are not run here.
 */
import * as fs from 'node:fs'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { loadPath } from './parse.js'
import { validate } from './validate.js'
import { fixturesDir } from './test-helpers.js'

const dir = (...p: string[]) => fixturesDir('conformance', 'ic_system', ...p)

interface Load {
  id: string
  fixture: string
  warnings?: string[]
  model?: string
  equations_tail?: unknown[]
  equations_count?: number
  guesses?: Record<string, unknown>
  no_field?: string
  load_error?: string
  validate_errors?: string[]
}

const manifest = JSON.parse(fs.readFileSync(dir('manifest.json'), 'utf-8')) as { loads: Load[] }

const normj = (v: unknown): unknown => JSON.parse(JSON.stringify(v))

describe('ic_system loads (esm-spec §11.4.4)', () => {
  let warn: ReturnType<typeof vi.spyOn>
  beforeEach(() => {
    warn = vi.spyOn(console, 'warn').mockImplementation(() => {})
  })
  afterEach(() => {
    warn.mockRestore()
  })

  it.each(manifest.loads.map((l) => [l.id, l] as const))('%s', (_id, l) => {
    const fp = dir(l.fixture)
    if (l.load_error !== undefined) {
      let err: { code?: string; message: string } | undefined
      try {
        loadPath(fp)
      } catch (e) {
        err = e as { code?: string; message: string }
      }
      expect(err).toBeDefined()
      expect(`${err!.code ?? ''} ${err!.message}`).toContain(l.load_error)
      return
    }
    const file = loadPath(fp) as unknown as Record<string, unknown>
    const messages: string[] = warn.mock.calls.map((c: unknown[]) => String(c[0]))
    for (const w of l.warnings ?? []) {
      expect(messages.some((m) => m.startsWith(w))).toBe(true)
    }
    if (l.warnings !== undefined && l.warnings.length === 0) {
      expect(messages.filter((m) => m.startsWith('deprecated_field'))).toEqual([])
    }
    if (l.model !== undefined) {
      const model = normj((file.models as Record<string, unknown>)[l.model]) as Record<
        string,
        unknown
      >
      if (l.no_field !== undefined) expect(model[l.no_field]).toBeUndefined()
      const eqs = (model.equations ?? []) as unknown[]
      if (l.equations_tail !== undefined) {
        expect(eqs.slice(eqs.length - l.equations_tail.length)).toEqual(l.equations_tail)
      }
      if (l.equations_count !== undefined) expect(eqs.length).toBe(l.equations_count)
      if (l.guesses !== undefined) expect(model.guesses).toEqual(l.guesses)
    }
  })

  it('a valid 2.5.0 document with ic anywhere validates', () => {
    const result = validate(loadPath(dir('fixtures', 'triangular.esm')))
    expect(result.structural_errors).toEqual([])
    expect(result.schema_errors).toEqual([])
  })
})
