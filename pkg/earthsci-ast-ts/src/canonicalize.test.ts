import { describe, expect, it } from 'vitest'
import {
  CanonicalizeError,
  E_CANONICAL_DIVBY_ZERO,
  E_CANONICAL_NONFINITE,
  canonicalJson,
  canonicalize,
  formatCanonicalFloat,
} from './canonicalize.js'

const op = (name: string, args: unknown[]) => ({ op: name, args: args as never }) as never

describe('canonicalize per RFC §5.4 (TS best-effort)', () => {
  it('formats floats per §5.4.6 (with TS-only-floats limitation)', () => {
    // TS treats every literal as float; integer values get the trailing .0.
    const cases: Array<[number, string]> = [
      [1.0, '1.0'],
      [-3.0, '-3.0'],
      [0.0, '0.0'],
      [-0.0, '-0.0'],
      [2.5, '2.5'],
      [1e25, '1e25'],
      [5e-324, '5e-324'],
      [1e-7, '1e-7'],
    ]
    for (const [v, want] of cases) {
      expect(formatCanonicalFloat(v)).toBe(want)
    }
    // 0.1 + 0.2 -> 17-digit shortest round-trip.
    expect(formatCanonicalFloat(0.1 + 0.2)).toBe('0.30000000000000004')
  })

  it('errors on NaN / Inf', () => {
    for (const f of [NaN, Infinity, -Infinity]) {
      expect(() => canonicalize(f)).toThrow(CanonicalizeError)
      try {
        canonicalize(f)
      } catch (e) {
        expect((e as CanonicalizeError).code).toBe(E_CANONICAL_NONFINITE)
      }
    }
  })

  it('handles the §5.4.8 worked example (TS form)', () => {
    // Without int/float distinction every literal is float; the worked
    // example's `0` and `1` become `0.0` and `1.0` on the wire.
    const e = op('+', [op('*', ['a', 0]), 'b', op('+', ['a', 1])])
    expect(canonicalJson(e)).toBe('{"args":[1.0,"a","b"],"op":"+"}')
  })

  it('flattens nested same-op children', () => {
    const e = op('+', [op('+', ['a', 'b']), 'c'])
    expect(canonicalJson(e)).toBe('{"args":["a","b","c"],"op":"+"}')
  })

  it('drops identity operands', () => {
    expect(canonicalJson(op('*', [1, 'x']))).toBe('"x"')
    expect(canonicalJson(op('+', [0, 'x']))).toBe('"x"')
  })

  it('zero-annihilates (preserves -0)', () => {
    expect(canonicalJson(op('*', [0, 'x']))).toBe('0.0')
    expect(canonicalJson(op('*', [-0, 'x']))).toBe('-0.0')
  })

  it('canonicalizes neg / sub / div', () => {
    expect(canonicalJson(op('neg', [op('neg', ['x'])]))).toBe('"x"')
    expect(canonicalJson(op('neg', [5]))).toBe('-5.0')
    expect(canonicalJson(op('-', [0, 'x']))).toBe('{"args":["x"],"op":"neg"}')
    expect(() => canonicalize(op('/', [0, 0]))).toThrow(
      expect.objectContaining({ code: E_CANONICAL_DIVBY_ZERO }),
    )
  })
})
