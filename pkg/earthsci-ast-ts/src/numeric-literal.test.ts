import { describe, it, expect } from 'vitest'
import {
  intLit,
  floatLit,
  isNumericLiteral,
  isIntLit,
  isFloatLit,
  numericValue,
  losslessJsonParse,
  losslessJsonStringify,
  formatFloatToken,
  stripNumericLiterals,
  CanonicalizeError,
  CanonicalNonfiniteError,
  LosslessJsonParseError,
  type NumericLiteral,
} from './numeric-literal.js'

describe('NumericLiteral constructors', () => {
  it('intLit tags integer values', () => {
    const n = intLit(42)
    expect(isIntLit(n)).toBe(true)
    expect(isFloatLit(n)).toBe(false)
    expect(n.kind).toBe('int')
    expect(n.value).toBe(42)
  })

  it('intLit rejects non-integer values', () => {
    expect(() => intLit(1.5)).toThrow(TypeError)
    expect(() => intLit(NaN)).toThrow(TypeError)
    expect(() => intLit(Infinity)).toThrow(TypeError)
  })

  it('floatLit tags any finite or non-finite number', () => {
    expect(isFloatLit(floatLit(1))).toBe(true)
    expect(isFloatLit(floatLit(1.0))).toBe(true)
    expect(isFloatLit(floatLit(-0))).toBe(true)
    expect(floatLit(1).kind).toBe('float')
  })

  it('isNumericLiteral distinguishes tagged leaves from plain values', () => {
    expect(isNumericLiteral(intLit(1))).toBe(true)
    expect(isNumericLiteral(floatLit(1))).toBe(true)
    expect(isNumericLiteral(1)).toBe(false)
    expect(isNumericLiteral('x')).toBe(false)
    expect(isNumericLiteral(null)).toBe(false)
    expect(isNumericLiteral({ kind: 'int', value: 1 })).toBe(false) // untagged look-alike
  })

  it('numericValue unwraps plain numbers and NumericLiterals', () => {
    expect(numericValue(3)).toBe(3)
    expect(numericValue(intLit(3))).toBe(3)
    expect(numericValue(floatLit(2.5))).toBe(2.5)
    expect(numericValue('x')).toBeUndefined()
    expect(numericValue(null)).toBeUndefined()
  })
})

describe('losslessJsonParse — RFC §5.4.6 parse rule', () => {
  it('tags integer tokens as int', () => {
    const result = losslessJsonParse('1') as NumericLiteral
    expect(isIntLit(result)).toBe(true)
    expect(result.value).toBe(1)
  })

  it('tags tokens with "." as float', () => {
    const result = losslessJsonParse('1.0') as NumericLiteral
    expect(isFloatLit(result)).toBe(true)
    expect(result.value).toBe(1)
  })

  it('tags tokens with "e" or "E" as float', () => {
    expect(isFloatLit(losslessJsonParse('1e5') as NumericLiteral)).toBe(true)
    expect(isFloatLit(losslessJsonParse('1E5') as NumericLiteral)).toBe(true)
    expect(isFloatLit(losslessJsonParse('5e-324') as NumericLiteral)).toBe(true)
  })

  it('distinguishes 1 from 1.0', () => {
    const a = losslessJsonParse('1') as NumericLiteral
    const b = losslessJsonParse('1.0') as NumericLiteral
    expect(a.kind).toBe('int')
    expect(b.kind).toBe('float')
    expect(a.value).toBe(b.value) // both equal 1 numerically
  })

  it('parses negative integers and floats', () => {
    expect((losslessJsonParse('-42') as NumericLiteral).kind).toBe('int')
    expect((losslessJsonParse('-3.14') as NumericLiteral).kind).toBe('float')
  })

  it('falls back to float for integer tokens outside safe-integer range', () => {
    const huge = losslessJsonParse('9007199254740993') as NumericLiteral
    expect(huge.kind).toBe('float')
  })

  it('parses nested structures with tagged numbers', () => {
    const parsed = losslessJsonParse('{"op":"+","args":[1,2.5]}') as {
      op: string
      args: NumericLiteral[]
    }
    expect(parsed.op).toBe('+')
    expect(parsed.args[0]!.kind).toBe('int')
    expect(parsed.args[0]!.value).toBe(1)
    expect(parsed.args[1]!.kind).toBe('float')
    expect(parsed.args[1]!.value).toBe(2.5)
  })

  it('parses strings, booleans, null unchanged', () => {
    expect(losslessJsonParse('"hi"')).toBe('hi')
    expect(losslessJsonParse('true')).toBe(true)
    expect(losslessJsonParse('false')).toBe(false)
    expect(losslessJsonParse('null')).toBeNull()
  })

  it('parses escape sequences', () => {
    expect(losslessJsonParse('"a\\nb"')).toBe('a\nb')
    expect(losslessJsonParse('"\\u0041"')).toBe('A')
  })

  it('rejects malformed input', () => {
    expect(() => losslessJsonParse('')).toThrow(LosslessJsonParseError)
    expect(() => losslessJsonParse('{')).toThrow(LosslessJsonParseError)
    expect(() => losslessJsonParse('1 2')).toThrow(LosslessJsonParseError)
  })

  it('handles whitespace', () => {
    expect(losslessJsonParse('  [ 1 , 2.0 ] ')).toEqual([intLit(1), floatLit(2)])
  })
})

describe('losslessJsonStringify — RFC §5.4.6 emit rule', () => {
  it('emits int as JSON-integer token', () => {
    expect(losslessJsonStringify(intLit(42))).toBe('42')
    expect(losslessJsonStringify(intLit(-1))).toBe('-1')
    expect(losslessJsonStringify(intLit(0))).toBe('0')
  })

  it('emits integer-valued float with trailing .0', () => {
    expect(losslessJsonStringify(floatLit(1))).toBe('1.0')
    expect(losslessJsonStringify(floatLit(-3))).toBe('-3.0')
    expect(losslessJsonStringify(floatLit(0))).toBe('0.0')
  })

  it('emits -0.0 for negative-zero float', () => {
    expect(losslessJsonStringify(floatLit(-0))).toBe('-0.0')
  })

  it('emits non-integer floats via ToString(Number)', () => {
    expect(losslessJsonStringify(floatLit(2.5))).toBe('2.5')
    expect(losslessJsonStringify(floatLit(0.1 + 0.2))).toBe('0.30000000000000004')
  })

  it('emits exponent notation for very small or very large floats', () => {
    expect(losslessJsonStringify(floatLit(1e25))).toBe('1e+25')
    expect(losslessJsonStringify(floatLit(5e-324))).toBe('5e-324')
  })

  it('rejects non-finite floats with CanonicalNonfiniteError', () => {
    expect(() => losslessJsonStringify(floatLit(NaN))).toThrow(CanonicalNonfiniteError)
    expect(() => losslessJsonStringify(floatLit(Infinity))).toThrow(CanonicalNonfiniteError)
    expect(() => losslessJsonStringify(floatLit(-Infinity))).toThrow(CanonicalNonfiniteError)
  })

  it('emits plain numbers via JSON.stringify (no canonical override)', () => {
    expect(losslessJsonStringify(1)).toBe('1')
    expect(losslessJsonStringify(1.5)).toBe('1.5')
  })

  it('rejects non-finite plain numbers', () => {
    expect(() => losslessJsonStringify(NaN)).toThrow(CanonicalNonfiniteError)
    expect(() => losslessJsonStringify(Infinity)).toThrow(CanonicalNonfiniteError)
  })

  it('emits nested structures', () => {
    const ast = { op: '+', args: [intLit(1), floatLit(2.5)] }
    expect(losslessJsonStringify(ast)).toBe('{"op":"+","args":[1,2.5]}')
  })

  it('distinguishes int-node 1 from float-node 1.0 on the wire', () => {
    const intAst = { op: '+', args: [intLit(1), floatLit(2.5)] }
    const floatAst = { op: '+', args: [floatLit(1), floatLit(2.5)] }
    expect(losslessJsonStringify(intAst)).toBe('{"op":"+","args":[1,2.5]}')
    expect(losslessJsonStringify(floatAst)).toBe('{"op":"+","args":[1.0,2.5]}')
  })

  it('skips undefined object properties', () => {
    expect(losslessJsonStringify({ a: 1, b: undefined })).toBe('{"a":1}')
  })

  it('escapes string values', () => {
    expect(losslessJsonStringify('a"b')).toBe('"a\\"b"')
  })
})

describe('RFC §5.4.6 worked example — round-trip', () => {
  it('Input A (float + float) round-trips', () => {
    // AST: +(1.0, 2.5), both floats → wire `{"op":"+","args":[1.0,2.5]}`
    const ast = { op: '+', args: [floatLit(1), floatLit(2.5)] }
    const wire = losslessJsonStringify(ast)
    expect(wire).toBe('{"op":"+","args":[1.0,2.5]}')

    const reparsed = losslessJsonParse(wire) as {
      op: string
      args: NumericLiteral[]
    }
    expect(reparsed.args[0].kind).toBe('float')
    expect(reparsed.args[0].value).toBe(1)
    expect(reparsed.args[1].kind).toBe('float')
  })

  it('Input B (int + float) round-trips distinctly', () => {
    // AST: +(1, 2.5), int+float → wire `{"op":"+","args":[1,2.5]}`
    const ast = { op: '+', args: [intLit(1), floatLit(2.5)] }
    const wire = losslessJsonStringify(ast)
    expect(wire).toBe('{"op":"+","args":[1,2.5]}')

    const reparsed = losslessJsonParse(wire) as {
      op: string
      args: NumericLiteral[]
    }
    expect(reparsed.args[0].kind).toBe('int')
    expect(reparsed.args[0].value).toBe(1)
    expect(reparsed.args[1].kind).toBe('float')
  })

  it('canonical-numbers inline fixture (RFC §5.4.6)', () => {
    // Table from RFC §5.4.6 — every binding must reproduce these.
    const cases: Array<[NumericLiteral, string]> = [
      [intLit(1), '1'],
      [intLit(-42), '-42'],
      [intLit(0), '0'],
      [floatLit(1), '1.0'],
      [floatLit(-3), '-3.0'],
      [floatLit(0), '0.0'],
      [floatLit(-0), '-0.0'],
      [floatLit(2.5), '2.5'],
      [floatLit(0.1 + 0.2), '0.30000000000000004'],
      [floatLit(5e-324), '5e-324'],
    ]
    for (const [lit, expected] of cases) {
      expect(losslessJsonStringify(lit)).toBe(expected)
      const reparsed = losslessJsonParse(expected) as NumericLiteral
      expect(reparsed.kind).toBe(lit.kind)
      expect(reparsed.value).toBe(lit.value)
    }
  })
})

describe('formatFloatToken', () => {
  it('adds trailing .0 only for integer-valued plain-decimal floats', () => {
    expect(formatFloatToken(1)).toBe('1.0')
    expect(formatFloatToken(-3)).toBe('-3.0')
    expect(formatFloatToken(0)).toBe('0.0')
    expect(formatFloatToken(-0)).toBe('-0.0')
    expect(formatFloatToken(2.5)).toBe('2.5')
    expect(formatFloatToken(1e25)).toBe('1e+25')
  })

  it('throws on non-finite values', () => {
    expect(() => formatFloatToken(NaN)).toThrow(CanonicalNonfiniteError)
    expect(() => formatFloatToken(Infinity)).toThrow(CanonicalNonfiniteError)
  })
})

describe('CanonicalNonfiniteError', () => {
  it('is a CanonicalizeError carrying the shared E_CANONICAL_NONFINITE code', () => {
    const err = new CanonicalNonfiniteError(NaN, '$.x')
    // One shared error hierarchy: the nonfinite error IS a CanonicalizeError.
    expect(err).toBeInstanceOf(CanonicalizeError)
    expect(err.code).toBe('E_CANONICAL_NONFINITE')
    expect(err.value).toBeNaN()
    expect(err.path).toBe('$.x')
    expect(err.message).toBe('Canonical form forbids non-finite number NaN at $.x')
  })
})

describe('stripNumericLiterals', () => {
  it('replaces tagged leaves with plain numbers without mutating the input', () => {
    const lit = intLit(5)
    const input = { a: lit, b: [floatLit(1.5), 'x'], c: { d: 2 } }
    const out = stripNumericLiterals(input) as typeof input
    expect(out.a).toBe(5)
    expect(out.b[0]).toBe(1.5)
    expect(out.b[1]).toBe('x')
    // Input tree still holds the original tagged literal.
    expect(input.a).toBe(lit)
  })

  it('returns the SAME reference when no literal is present (structural sharing)', () => {
    const input = { a: 1, b: ['x', { c: 'y' }] }
    expect(stripNumericLiterals(input)).toBe(input)
  })
})
