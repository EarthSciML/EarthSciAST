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
    expect(fixtures.length).toBeGreaterThanOrEqual(46)
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

  it('checks interp.* arity first, and leaves datetime.* to evaluation (ruling Q-112)', () => {
    expect(codeOf(() => checkClosedFunctionArguments('datetime.year', ['t', 't']))).toBeNull()
    expect(codeOf(() => checkClosedFunctionArguments('interp.linear', ['x']))).toBe(
      ERROR_CODES.CLOSED_FUNCTION_ARITY,
    )
    expect(codeOf(() => checkClosedFunctionArguments('interp.searchsorted', [c([1])]))).toBe(
      ERROR_CODES.CLOSED_FUNCTION_ARITY,
    )
  })

  it('runs each step over every axis before the next (ruling Q-110)', () => {
    // axis_x disagrees with the table's outer length; axis_y has one entry.
    expect(
      codeOf(() =>
        checkClosedFunctionArguments('interp.bilinear', [
          c([[1], [2], [3]]),
          c([0, 1]),
          c([0]),
          'x',
          'y',
        ]),
      ),
    ).toBe(ERROR_CODES.INTERP_AXIS_TOO_SHORT)
    // A length mismatch comes before a non-finite axis entry.
    expect(
      codeOf(() =>
        checkClosedFunctionArguments('interp.linear', [c([1, 2]), c([0, Number.NaN, 2]), 'x']),
      ),
    ).toBe(ERROR_CODES.INTERP_AXIS_LENGTH_MISMATCH)
  })

  it('treats an infinite axis entry as interp_nan_in_axis (ruling Q-113)', () => {
    for (const inf of [Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY]) {
      expect(
        codeOf(() => checkClosedFunctionArguments('interp.linear', [c([1, 2]), c([0, inf]), 'x'])),
      ).toBe(ERROR_CODES.INTERP_NAN_IN_AXIS)
    }
  })

  it('treats an empty bilinear table as rank 1 (ruling Q-111)', () => {
    expect(
      codeOf(() =>
        checkClosedFunctionArguments('interp.bilinear', [c([]), c([0, 1]), c([0, 1]), 'x', 'y']),
      ),
    ).toBe(ERROR_CODES.INTERP_TABLE_NOT_CONST)
  })
})

describe('table_lookup node checks run at load (ruling Q-112)', () => {
  const doc = (lookup: object, tables?: object) => ({
    esm: '1.0.0',
    metadata: { name: 'LookupAtLoad' },
    ...(tables ? { function_tables: tables } : {}),
    models: {
      M: {
        variables: {
          x: { type: 'parameter', units: '1', default: 0.5 },
          y: { type: 'unknown', units: '1', default: 1.0 },
        },
        equations: [
          {
            lhs: { op: 'D', args: ['y'], wrt: 't' },
            rhs: { op: 'table_lookup', table: 'T', args: [], ...lookup },
          },
        ],
      },
    },
  })
  const T = { T: { axes: [{ name: 'x', values: [0, 1] }], data: [1, 2] } }

  it('loads a well-formed lookup', () => {
    expect(codeOf(() => loadString(JSON.stringify(doc({ axes: { x: 'x' } }, T))))).toBeNull()
  })

  it.each<[string, object, object | undefined, string]>([
    ['an unknown table', { axes: { x: 'x' } }, undefined, ERROR_CODES.TABLE_LOOKUP_UNKNOWN_TABLE],
    ['a missing axis key', { axes: { z: 'x' } }, T, ERROR_CODES.TABLE_LOOKUP_AXIS_NAME_MISMATCH],
    [
      'an output out of range',
      { axes: { x: 'x' }, output: 2 },
      T,
      ERROR_CODES.TABLE_LOOKUP_OUTPUT_OUT_OF_RANGE,
    ],
  ])('refuses %s, though nothing evaluates it', (_label, lookup, tables, want) => {
    expect(codeOf(() => loadString(JSON.stringify(doc(lookup, tables))))).toBe(want)
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
