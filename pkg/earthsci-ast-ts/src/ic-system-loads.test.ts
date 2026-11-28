/**
 * The loader half of tests/conformance/ic_system (esm 2.5.0, esm-spec §11.4.4,
 * §4.2): a deprecated `initialization_equations` block is rewritten into `ic`
 * equations (or into `guesses` for a model with no time derivative) with the
 * warning `deprecated_field`, a malformed `ic` argument or an `ic` of a
 * parameter is refused at load with `ic_invalid_argument`, and `validate`
 * reports exactly the codes each load names. Error codes are compared on the
 * error's `code` field, warnings by their code, both exactly. TypeScript does not simulate,
 * so the manifest's `cases` and the build-time balance are not run here.
 */
import * as fs from 'node:fs'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { canonicalizeDocument } from './canonicalize.js'
import { EsmDiagnosticError } from './errors.js'
import { initializationEquationsMigrated } from './initialization-migration.js'
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
  parameter_defaults?: Record<string, number>
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

  it('runs every load of the manifest', () => {
    expect(manifest.loads.length).toBeGreaterThanOrEqual(22)
  })

  it.each(manifest.loads.map((l) => [l.id, l] as const))('%s', (_id, l) => {
    const fp = dir(l.fixture)
    if (l.load_error !== undefined) {
      let err: unknown
      try {
        loadPath(fp)
      } catch (e) {
        err = e
      }
      expect(err).toBeInstanceOf(EsmDiagnosticError)
      expect((err as EsmDiagnosticError).code).toBe(l.load_error)
      return
    }
    const file = loadPath(fp) as unknown as Record<string, unknown>
    // The load's coded warnings (`<code>: ...`), by code. The unit analysis'
    // own notes (`ESM unit validation ...`) are not the manifest's subject.
    const warnings = warn.mock.calls.flatMap((c: unknown[]) => {
      const m = /^([a-z_]+): /.exec(String(c[0]))
      return m === null ? [] : [m[1]]
    })
    if (l.warnings !== undefined) expect(warnings).toEqual(l.warnings)
    if (l.validate_errors !== undefined) {
      const result = validate(file as never)
      expect(result.structural_errors.map((e) => e.code).sort()).toEqual(
        [...l.validate_errors].sort(),
      )
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
      const vars = (model.variables ?? {}) as Record<string, { default?: unknown }>
      for (const [k, v] of Object.entries(l.parameter_defaults ?? {})) {
        expect(vars[k]?.default).toBe(v)
      }
    }
  })

  it('a valid 2.5.0 document with ic anywhere validates', () => {
    const result = validate(loadPath(dir('fixtures', 'triangular.esm')))
    expect(result.structural_errors).toEqual([])
    expect(result.schema_errors).toEqual([])
  })
})

describe('initialization_equations migration (esm-spec §11.4.4)', () => {
  it('reaches operator-call bindings and leaves ic nodes and parameters alone', () => {
    const doc = {
      esm: '2.5.0',
      models: {
        M: {
          variables: {
            x: { type: 'unknown' },
            y: { type: 'unknown' },
            k: { type: 'parameter', default: 1 },
          },
          equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 0 }],
          initialization_equations: [
            {
              lhs: 'y',
              rhs: {
                op: 'apply_operator',
                name: 'f',
                args: [],
                bindings: { a: 'x', b: 'k', c: { op: 'ic', args: ['x'] } },
              },
            },
          ],
        },
      },
    }
    const copy = initializationEquationsMigrated(doc)
    expect(doc.models.M.initialization_equations).toBeDefined()
    const m = (copy as unknown as { models: { M: Record<string, unknown> } }).models.M
    expect(m.initialization_equations).toBeUndefined()
    expect((m.equations as unknown[])[1]).toEqual({
      lhs: { op: 'ic', args: ['y'] },
      rhs: {
        op: 'apply_operator',
        name: 'f',
        args: [],
        bindings: { a: { op: 'ic', args: ['x'] }, b: 'k', c: { op: 'ic', args: ['x'] } },
      },
    })
  })

  it('the canonical form carries no initialization_equations', () => {
    const doc = JSON.parse(
      fs.readFileSync(dir('fixtures', 'migration_steady_state.esm'), 'utf-8'),
    ) as Record<string, unknown>
    expect(JSON.stringify(canonicalizeDocument(doc))).not.toContain('initialization_equations')
  })
})
