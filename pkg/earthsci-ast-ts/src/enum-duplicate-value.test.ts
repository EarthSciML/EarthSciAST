/**
 * Within ONE enum, values are unique — `0` included — and a duplicate is
 * rejected at load with `enum_duplicate_value`, whether or not any `enum` op
 * names either symbol (esm-spec §9.3; CONFORMANCE_SPEC §5.26.5). Values MAY
 * coincide across enums.
 */
import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { loadPath, loadString } from './parse.js'
import { ERROR_CODES } from './errors.js'
import { checkEnumsBlock, lowerEnumOpsForFile } from './lower-enums.js'
import { REPO_ROOT } from './test-helpers.js'

function codeOf(fn: () => unknown): string | null {
  try {
    fn()
    return null
  } catch (e) {
    return (e as { code?: string }).code ?? 'NO_CODE'
  }
}

describe('enum_duplicate_value (esm-spec §9.3)', () => {
  it.each(['enum_duplicate_value.esm', 'enum_duplicate_zero_value.esm'])(
    'refuses the corpus document %s with its pinned code',
    (name) => {
      const pins = JSON.parse(
        fs.readFileSync(path.join(REPO_ROOT, 'tests', 'invalid', 'expected_errors.json'), 'utf8'),
      ) as Record<string, { resolver_only?: boolean; resolver_error_code?: string }>
      expect(pins[name]?.resolver_only).toBe(true)
      expect(pins[name]?.resolver_error_code).toBe(ERROR_CODES.ENUM_DUPLICATE_VALUE)
      expect(codeOf(() => loadPath(path.join(REPO_ROOT, 'tests', 'invalid', name)))).toBe(
        ERROR_CODES.ENUM_DUPLICATE_VALUE,
      )
    },
  )

  it('allows the same value in two different enums', () => {
    expect(codeOf(() => checkEnumsBlock({ a: { x: 0, y: 1 }, b: { z: 0, w: 1 } }))).toBeNull()
  })

  it('rejects a duplicate 0 and a duplicate negative value', () => {
    expect(codeOf(() => checkEnumsBlock({ m: { Braking: 0, Stopped: 0 } }))).toBe(
      ERROR_CODES.ENUM_DUPLICATE_VALUE,
    )
    expect(codeOf(() => checkEnumsBlock({ m: { a: -1, b: 2, c: -1 } }))).toBe(
      ERROR_CODES.ENUM_DUPLICATE_VALUE,
    )
  })

  it('checks the block even when the document has no `enum` op', () => {
    const doc = {
      esm: '1.0.0',
      metadata: { name: 'D' },
      enums: { m: { a: 1, b: 1 } },
      models: {
        M: {
          variables: { x: { type: 'unknown', units: '1', default: 1.0 } },
          equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 0 }],
        },
      },
    }
    expect(codeOf(() => loadString(JSON.stringify(doc)))).toBe(ERROR_CODES.ENUM_DUPLICATE_VALUE)
  })

  it('checks a template library block at its import edge', () => {
    expect(
      codeOf(() => lowerEnumOpsForFile({ enums: { m: { a: 2, b: 2 } } }, { op: '+', args: [1] })),
    ).toBe(ERROR_CODES.ENUM_DUPLICATE_VALUE)
  })
})
