/**
 * Tests for parse-reaction: the inverse of `toAscii` for a single reaction.
 *
 * Core property is REPRINT IDEMPOTENCE: `toAscii(parseReaction(s)) === s` for a
 * canonically-printed reaction, so an untouched reaction stays byte-identical
 * through a text-edit round-trip.
 */
import { describe, it, expect } from 'vitest'
import { toAscii, toMathML } from './pretty-print.js'
import { parseReaction, ExpressionParseError } from './index.js'
import type { Reaction } from './types.js'

const reprint = (r: Reaction) => toAscii(r)

describe('parseReaction', () => {
  it('parses a simple reaction with a parameter rate', () => {
    const r = parseReaction('NO + O3 -> [k1] NO2 + O2')
    expect(r.substrates).toEqual([
      { species: 'NO', stoichiometry: 1 },
      { species: 'O3', stoichiometry: 1 },
    ])
    expect(r.products).toEqual([
      { species: 'NO2', stoichiometry: 1 },
      { species: 'O2', stoichiometry: 1 },
    ])
    expect(r.rate).toBe('k1')
  })

  it('parses integer and fractional stoichiometric coefficients', () => {
    const r = parseReaction('2 NO + O3 -> [k] 0.87 CH2O + 1.86 CH3O2')
    expect(r.substrates).toEqual([
      { species: 'NO', stoichiometry: 2 },
      { species: 'O3', stoichiometry: 1 },
    ])
    expect(r.products).toEqual([
      { species: 'CH2O', stoichiometry: 0.87 },
      { species: 'CH3O2', stoichiometry: 1.86 },
    ])
  })

  it('accepts a coefficient with no space before the species', () => {
    const r = parseReaction('2NO -> [k] N2O2')
    expect(r.substrates).toEqual([{ species: 'NO', stoichiometry: 2 }])
    expect(r.products).toEqual([{ species: 'N2O2', stoichiometry: 1 }])
  })

  it('accepts a unicode arrow', () => {
    const r = parseReaction('NO + O3 → [k1] NO2 + O2')
    expect(r.rate).toBe('k1')
    expect(r.substrates).toHaveLength(2)
  })

  it('parses a source reaction (empty reactant side → null)', () => {
    const r = parseReaction('-> [k_emit] O3')
    expect(r.substrates).toBeNull()
    expect(r.products).toEqual([{ species: 'O3', stoichiometry: 1 }])
  })

  it('parses a sink reaction (empty product side → null)', () => {
    const r = parseReaction('O3 -> [k_dep]')
    expect(r.substrates).toEqual([{ species: 'O3', stoichiometry: 1 }])
    expect(r.products).toBeNull()
  })

  it('accepts ∅ as an explicit empty side', () => {
    const r = parseReaction('∅ -> [k] O3')
    expect(r.substrates).toBeNull()
  })

  it('parses a rate that is itself an expression with brackets/parens', () => {
    const r = parseReaction('CH4 + OH -> [arr(2.45e-12, 1775)] CH3O2 + H2O')
    // The rate round-trips as an expression node — assert it reprints intact.
    expect(toAscii(r.rate as never)).toContain('arr')
  })

  describe('errors', () => {
    it('rejects a missing arrow', () => {
      expect(() => parseReaction('NO + O3')).toThrow(ExpressionParseError)
    })
    it('rejects a missing rate', () => {
      expect(() => parseReaction('NO + O3 -> NO2')).toThrow(ExpressionParseError)
    })
    it('rejects a non-positive coefficient', () => {
      expect(() => parseReaction('0 NO -> [k] NO2')).toThrow(ExpressionParseError)
    })
    it('rejects a stray "+"', () => {
      expect(() => parseReaction('NO + -> [k] NO2')).toThrow(ExpressionParseError)
    })
    it('rejects an empty reaction', () => {
      expect(() => parseReaction('-> [k]')).toThrow(ExpressionParseError)
    })
  })
})

describe('toAscii(reaction) ⇄ parseReaction round-trip', () => {
  const forms = [
    'NO + O3 -> [k1] NO2 + O2',
    '2 NO + O3 -> [k] 0.87 CH2O + 1.86 CH3O2',
    'CH4 + OH -> [k_ch4] CH3O2 + H2O',
    '-> [k_emit] O3',
    'O3 -> [k_dep]',
  ]
  for (const form of forms) {
    it(`round-trips: ${form}`, () => {
      expect(reprint(parseReaction(form))).toBe(form)
    })
  }
})

describe('toMathML(reaction)', () => {
  it('emits a <math> root with the rate over the arrow', () => {
    const ml = toMathML(parseReaction('NO + O3 -> [k1] NO2 + O2'))
    expect(ml.startsWith('<math>')).toBe(true)
    expect(ml).toContain('<mover>')
    expect(ml).toContain('&#x27F6;') // ⟶
  })
  it('renders an empty side as ∅', () => {
    const ml = toMathML(parseReaction('-> [k] O3'))
    expect(ml).toContain('&#x2205;') // ∅
  })
})
