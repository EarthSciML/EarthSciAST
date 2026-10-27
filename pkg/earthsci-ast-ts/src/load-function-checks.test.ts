/**
 * The closed-function argument checks (esm-spec §9.2) and the function-table
 * checks (§9.5.5) run at LOAD and in `validate()` — on every `function_tables`
 * entry whether or not a lookup references it, and on every `interp.*` `fn`
 * call wherever it sits (ruling Q-106). The shared corpus pins each case as a
 * schema-valid `tests/invalid/closed_fn_*.esm` / `function_table_*.esm`
 * document, `resolver_only` with a `resolver_error_code`, the
 * `enum_duplicate_value.esm` convention.
 */
import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { loadPath, loadString } from './parse.js'
import { validate, validateText } from './validate.js'
import { REPO_ROOT } from './test-helpers.js'
import { ERROR_CODES } from './errors.js'
import { checkClosedFunctionArguments } from './closed-functions.js'

function codeOf(fn: () => unknown): string | null {
  try {
    fn()
    return null
  } catch (e) {
    return (e as { code?: string }).code ?? 'NO_CODE'
  }
}

const INVALID_DIR = path.join(REPO_ROOT, 'tests', 'invalid')

const pins = JSON.parse(
  fs.readFileSync(path.join(INVALID_DIR, 'expected_errors.json'), 'utf8'),
) as Record<string, { resolver_only?: boolean; is_valid?: boolean; resolver_error_code?: string }>

const fixtures = fs
  .readdirSync(INVALID_DIR)
  .filter(
    (f) => f.endsWith('.esm') && (f.startsWith('closed_fn_') || f.startsWith('function_table_')),
  )
  .sort()

describe('closed-function and function-table checks at load (esm-spec §9.2, §9.5.5)', () => {
  it('finds the corpus documents', () => {
    expect(fixtures.length).toBeGreaterThanOrEqual(30)
  })

  it.each(fixtures)('refuses %s at load and in validate() with its pinned code', (name) => {
    const pin = pins[name]
    expect(pin?.resolver_only).toBe(true)
    expect(pin?.is_valid).toBe(false)
    const want = pin!.resolver_error_code!
    expect(Object.values(ERROR_CODES)).toContain(want)

    const file = path.join(INVALID_DIR, name)
    expect(codeOf(() => loadPath(file))).toBe(want)
    const text = fs.readFileSync(file, 'utf8')
    expect(codeOf(() => loadString(text, { canonical: true }))).toBe(want)

    for (const result of [
      validateText(text, { basePath: INVALID_DIR }),
      validate(JSON.parse(text) as object),
    ]) {
      expect(result.is_valid).toBe(false)
      expect(result.schema_errors).toHaveLength(0)
      expect(result.structural_errors.map((e) => e.code)).toContain(want)
    }
  })
})

describe('the load-time argument check on in-memory calls', () => {
  const c = (value: unknown) => ({ op: 'const', args: [], value })

  it('accepts an empty searchsorted xs (ruling Q-108)', () => {
    expect(
      codeOf(() => checkClosedFunctionArguments('interp.searchsorted', ['x', c([])])),
    ).toBeNull()
  })

  it('rejects a NaN axis, which no document can carry', () => {
    expect(
      codeOf(() =>
        checkClosedFunctionArguments('interp.linear', [c([1, 2, 3]), c([0, Number.NaN, 2]), 'x']),
      ),
    ).toBe(ERROR_CODES.INTERP_NAN_IN_AXIS)
    expect(
      codeOf(() => checkClosedFunctionArguments('interp.searchsorted', ['x', c([1, Number.NaN])])),
    ).toBe(ERROR_CODES.SEARCHSORTED_NAN)
  })

  it('names where the call sits', () => {
    expect(() =>
      checkClosedFunctionArguments(
        'interp.linear',
        ['tbl', c([0, 1]), 'x'],
        '/models/M/equations/0/rhs',
      ),
    ).toThrow(/\/models\/M\/equations\/0\/rhs/)
  })

  it('leaves other functions and a wrong arity to evaluation', () => {
    expect(codeOf(() => checkClosedFunctionArguments('datetime.year', ['t']))).toBeNull()
    expect(codeOf(() => checkClosedFunctionArguments('interp.linear', ['x']))).toBeNull()
  })
})

describe('a call inside an expression-template body is checked where it is applied', () => {
  const doc = (axis: number[]) => ({
    esm: '1.0.0',
    metadata: { name: 'TemplateInterp' },
    models: {
      M: {
        variables: {
          T: { type: 'parameter', units: 'K', default: 250 },
          y: { type: 'unknown', units: '1', default: 0 },
        },
        expression_templates: {
          lin: {
            params: ['ax'],
            // `ax` is a bare name in the body: checked there, it would be
            // `interp_axis_not_const`.
            body: { op: 'fn', name: 'interp.linear', args: [c([1, 2]), 'ax', 'T'] },
          },
        },
        equations: [
          {
            lhs: { op: 'D', args: ['y'], wrt: 't' },
            rhs: {
              op: 'apply_expression_template',
              args: [],
              name: 'lin',
              bindings: { ax: c(axis) },
            },
          },
        ],
      },
    },
  })
  const c = (value: unknown) => ({ op: 'const', args: [], value })

  it('loads when the applied axis is valid', () => {
    expect(codeOf(() => loadString(JSON.stringify(doc([200, 300]))))).toBeNull()
  })

  it('refuses when the applied axis is decreasing', () => {
    expect(codeOf(() => loadString(JSON.stringify(doc([300, 200]))))).toBe(
      ERROR_CODES.INTERP_NON_MONOTONIC_AXIS,
    )
  })
})
