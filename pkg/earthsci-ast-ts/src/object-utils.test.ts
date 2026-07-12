/**
 * Unit tests for the shared object helpers (object-utils.ts): the
 * NumericLiteral-aware `isObject` guard and the NumericLiteral-preserving
 * `deepClone`.
 */

import { describe, it, expect } from 'vitest'
import { isObject, deepClone } from './object-utils.js'
import { intLit, floatLit, isNumericLiteral } from './numeric-literal.js'

describe('isObject', () => {
  it('accepts plain JSON objects', () => {
    expect(isObject({})).toBe(true)
    expect(isObject({ a: 1 })).toBe(true)
  })

  it('rejects null, arrays, and primitives', () => {
    expect(isObject(null)).toBe(false)
    expect(isObject(undefined)).toBe(false)
    expect(isObject([1, 2, 3])).toBe(false)
    expect(isObject(42)).toBe(false)
    expect(isObject('str')).toBe(false)
    expect(isObject(true)).toBe(false)
  })

  it('EXCLUDES tagged NumericLiteral leaves (they are opaque)', () => {
    expect(isObject(intLit(3))).toBe(false)
    expect(isObject(floatLit(1.5))).toBe(false)
  })
})

describe('deepClone', () => {
  it('deep-copies nested objects and arrays (no shared references)', () => {
    const src = { a: { b: [1, 2, { c: 'x' }] }, d: 'e' }
    const out = deepClone(src)
    expect(out).toEqual(src)
    expect(out).not.toBe(src)
    expect(out.a).not.toBe(src.a)
    expect(out.a.b).not.toBe(src.a.b)
    expect(out.a.b[2]).not.toBe(src.a.b[2])
    // Mutating the clone must not affect the source.
    ;(out.a.b as unknown[]).push(99)
    expect(src.a.b).toHaveLength(3)
  })

  it('preserves tagged NumericLiteral leaves by reference (frozen/immutable)', () => {
    const lit = intLit(7)
    const src = { x: lit, nested: { y: floatLit(2.5) } }
    const out = deepClone(src)
    expect(out.x).toBe(lit) // same reference, not a copied {kind,value}
    expect(isNumericLiteral(out.x)).toBe(true)
    expect(isNumericLiteral(out.nested.y)).toBe(true)
    expect((out.x as { value: number }).value).toBe(7)
    expect(out.nested).not.toBe(src.nested)
  })

  it('passes primitives, null, and undefined through unchanged', () => {
    expect(deepClone(5)).toBe(5)
    expect(deepClone('s')).toBe('s')
    expect(deepClone(null)).toBe(null)
    expect(deepClone(undefined)).toBe(undefined)
  })

  it('clones arrays at the top level', () => {
    const src = [1, { a: 2 }, [3]]
    const out = deepClone(src)
    expect(out).toEqual(src)
    expect(out).not.toBe(src)
    expect(out[1]).not.toBe(src[1])
  })
})
