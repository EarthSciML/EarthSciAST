/**
 * Round-trip and canonical-form tests for `save()` (esm-cs3).
 *
 * Verifies that the serializer:
 *   - Strips `NumericLiteral` tagged leaves to bare JSON numbers
 *   - Round-trips files that traverse `lower_*` passes (enums, expression
 *     templates) via `save(load(file))` → structurally-equal re-parse
 *   - In `canonical: true` mode, preserves the integer-vs-float
 *     discriminator per RFC §5.4.6 (e.g. `floatLit(1)` emits as `1.0`)
 */
import { describe, it, expect } from 'vitest'
import * as fs from 'fs'
import * as path from 'path'
import { load } from './parse.js'
import { save } from './serialize.js'
import { intLit, floatLit, losslessJsonParse } from './numeric-literal.js'

const REPO_ROOT = path.join(__dirname, '..', '..', '..')

function fixture(name: string): string {
  return fs.readFileSync(path.join(REPO_ROOT, 'tests', 'valid', name), 'utf-8')
}

describe('save() — NumericLiteral handling', () => {
  it('emits bare JSON numbers for tagged literals (default mode)', () => {
    const ef = {
      esm: '0.4.0',
      metadata: { name: 'tagged_literals' },
      models: {
        M: {
          variables: { x: { type: 'state', default: intLit(42) } },
          equations: [{ lhs: 'x', rhs: { op: '*', args: [floatLit(2), 'x'] } }],
        },
      },
    } as unknown as Parameters<typeof save>[0]
    const out = save(ef)
    const reparsed = JSON.parse(out)
    expect(reparsed.models.M.variables.x.default).toBe(42)
    expect(reparsed.models.M.equations[0].rhs.args[0]).toBe(2)
  })

  it('canonical mode preserves the float discriminator', () => {
    const ef = {
      esm: '0.4.0',
      metadata: { name: 'canonical_floats' },
      models: {
        M: {
          variables: { x: { type: 'state', default: floatLit(1) } },
          equations: [{ lhs: 'x', rhs: { op: '*', args: [floatLit(1), 'x'] } }],
        },
      },
    } as unknown as Parameters<typeof save>[0]
    const out = save(ef, { canonical: true })
    expect(out).toContain('"default": 1.0')
    expect(out).toContain('1.0')
    // Sanity: parses back as valid JSON.
    expect(() => JSON.parse(out)).not.toThrow()
  })

  it('canonical mode emits intLit as bare integer', () => {
    const ef = {
      esm: '0.4.0',
      metadata: { name: 'canonical_ints' },
      models: {
        M: {
          variables: { x: { type: 'state', default: intLit(7) } },
          equations: [{ lhs: 'x', rhs: 'x' }],
        },
      },
    } as unknown as Parameters<typeof save>[0]
    const out = save(ef, { canonical: true })
    expect(out).toContain('"default": 7')
    expect(out).not.toContain('"default": 7.0')
  })

  it('canonical mode rejects NaN / Infinity in tagged leaves', () => {
    const bad = {
      esm: '0.4.0',
      metadata: { name: 'nonfinite' },
      models: {
        M: {
          variables: { x: { type: 'state', default: floatLit(NaN) } },
          equations: [{ lhs: 'x', rhs: 'x' }],
        },
      },
    } as unknown as Parameters<typeof save>[0]
    expect(() => save(bad, { canonical: true })).toThrow()
  })

  it('does not mutate the input tree', () => {
    const lit = intLit(5)
    const ef = {
      esm: '0.4.0',
      metadata: { name: 'no_mutation' },
      models: {
        M: {
          variables: { x: { type: 'state', default: lit } },
          equations: [{ lhs: 'x', rhs: 'x' }],
        },
      },
    } as unknown as Parameters<typeof save>[0]
    save(ef)
    // The input still holds the original tagged literal.
    expect(
      // @ts-expect-error -- traversing through unknown for the test.
      ef.models.M.variables.x.default,
    ).toBe(lit)
  })
})

describe('save() — round-trip through lower_* passes', () => {
  it('round-trips the enums fixture (lowerEnums applied at load time)', () => {
    const text = fixture('enums_categorical_lookup.esm')
    const parsed = load(text)
    const first = save(parsed)
    const second = save(load(first))
    expect(JSON.parse(first)).toEqual(JSON.parse(second))
  })

  it('round-trips the expression-templates fixture (lowered to inline AST)', () => {
    const text = fixture('expression_templates_arrhenius.esm')
    const parsed = load(text)
    const first = save(parsed)
    const second = save(load(first))
    expect(JSON.parse(first)).toEqual(JSON.parse(second))
  })

  it('round-trips canonical-mode parsed input (NumericLiteral leaves present)', () => {
    const text = fixture('enums_categorical_lookup.esm')
    const parsed = load(text, { canonical: true })
    const first = save(parsed)
    // After save + JSON.parse, NumericLiteral leaves have collapsed to bare
    // numbers, so a structural compare to a fresh non-canonical reparse holds.
    const second = save(load(first))
    expect(JSON.parse(first)).toEqual(JSON.parse(second))
  })
})

describe('save() — JSON formatting', () => {
  it('uses indent=2 by default to match the Python and Julia serializers', () => {
    const ef = {
      esm: '0.4.0',
      metadata: { name: 'indent_check' },
      models: {
        M: {
          variables: { x: { type: 'state', default: 0 } },
          equations: [{ lhs: 'x', rhs: 'x' }],
        },
      },
    } as unknown as Parameters<typeof save>[0]
    const out = save(ef)
    expect(out).toContain('\n  "metadata"')
  })

  it('honors a custom indent', () => {
    const ef = {
      esm: '0.4.0',
      metadata: { name: 'compact' },
    } as unknown as Parameters<typeof save>[0]
    const out = save(ef, { indent: 0 })
    expect(out).not.toContain('\n')
  })

  it('drops undefined fields (default mode)', () => {
    const ef = {
      esm: '0.4.0',
      metadata: { name: 'drop_undef', description: undefined },
    } as unknown as Parameters<typeof save>[0]
    const out = save(ef)
    expect(JSON.parse(out)).not.toHaveProperty('metadata.description')
  })

  it('drops undefined fields (canonical mode)', () => {
    const ef = {
      esm: '0.4.0',
      metadata: { name: 'drop_undef_canonical', description: undefined },
    } as unknown as Parameters<typeof save>[0]
    const out = save(ef, { canonical: true })
    expect(JSON.parse(out)).not.toHaveProperty('metadata.description')
  })
})

describe('save() — losslessJsonParse compatibility', () => {
  it('strips NumericLiterals produced by losslessJsonParse', () => {
    const wire =
      '{"esm":"0.4.0","metadata":{"name":"t"},"models":{"M":{"variables":{"x":{"type":"state","default":3.14}},"equations":[{"lhs":"x","rhs":"x"}]}}}'
    const tagged = losslessJsonParse(wire) as Parameters<typeof save>[0]
    const out = save(tagged)
    expect(JSON.parse(out)).toEqual(JSON.parse(wire))
  })
})
