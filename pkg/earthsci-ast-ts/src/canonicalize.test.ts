import { describe, expect, it } from 'vitest'
import {
  CanonicalizeError,
  E_CANONICAL_DIVBY_ZERO,
  E_CANONICAL_NONFINITE,
  E_CANONICAL_UNSUPPORTED_FIELD,
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

  it('fails closed on non-emissible node fields', () => {
    // `reduce` is NOT in the emissible set (op,args,wrt,dim,fn,name,value); a
    // node carrying it has no faithful canonical JSON, so — matching the Julia
    // reference — `canonicalJson` THROWS `E_CANONICAL_UNSUPPORTED_FIELD` rather
    // than silently dropping the field or emitting an ambiguous sidecar.
    const agg = { op: 'aggregate', args: ['x'], reduce: 'max' } as never
    expect(() => canonicalJson(agg)).toThrow(
      expect.objectContaining({ code: E_CANONICAL_UNSUPPORTED_FIELD }),
    )
    expect(() => canonicalJson(agg)).toThrow(CanonicalizeError)

    // A non-emissible field on a nested arg node is caught too (tree walk).
    const nested = { op: '+', args: [{ op: 'aggregate', args: ['x'], semiring: 'tropical' }, 'y'] }
    expect(() => canonicalJson(nested as never)).toThrow(
      expect.objectContaining({ code: E_CANONICAL_UNSUPPORTED_FIELD }),
    )

    // `undefined` non-emissible fields are treated as absent — no throw.
    const undef = { op: 'D', args: ['x'], wrt: 't', reduce: undefined } as never
    expect(canonicalJson(undef)).toBe('{"args":["x"],"op":"D","wrt":"t"}')
  })

  it('emits the 7 emissible fields (sorted), tolerating arg / bindings', () => {
    // Each pinned field keeps its byte-identical output.
    expect(canonicalJson({ op: 'D', args: ['x'], wrt: 't' } as never)).toBe(
      '{"args":["x"],"op":"D","wrt":"t"}',
    )
    const bc = { op: 'bc', args: ['u'], fn: 'dirichlet', dim: 'x', name: 'foo' } as never
    expect(canonicalJson(bc)).toBe('{"args":["u"],"dim":"x","fn":"dirichlet","name":"foo","op":"bc"}')
    const c = { op: 'const', args: [], value: 2.5 } as never
    expect(canonicalJson(c)).toBe('{"args":[],"op":"const","value":2.5}')

    // `arg` / `bindings` are TOLERATED: present, ignored, not emitted, no error.
    const tol = { op: '+', args: ['a', 'b'], arg: 0, bindings: { p: 1 } } as never
    expect(canonicalJson(tol)).toBe('{"args":["a","b"],"op":"+"}')
  })
})
