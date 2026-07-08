import { describe, it, expect } from 'vitest'
import {
  convertUnits,
  parseUnitForConversion,
  unitsCompatible,
  UnitConversionError,
} from './unit-conversion.js'

describe('unit-conversion', () => {
  describe('convertUnits — same dimension scaling', () => {
    it('converts length (km → m)', () => {
      expect(convertUnits(1, 'km', 'm')).toBeCloseTo(1000, 10)
      expect(convertUnits(2.5, 'km', 'm')).toBeCloseTo(2500, 10)
      expect(convertUnits(500, 'm', 'km')).toBeCloseTo(0.5, 10)
    })

    it('converts length (m ↔ cm ↔ mm)', () => {
      expect(convertUnits(1, 'm', 'cm')).toBeCloseTo(100, 10)
      expect(convertUnits(1, 'm', 'mm')).toBeCloseTo(1000, 10)
      expect(convertUnits(1, 'cm', 'mm')).toBeCloseTo(10, 10)
    })

    it('converts volume through compound length (m^3 → cm^3)', () => {
      expect(convertUnits(1, 'm^3', 'cm^3')).toBeCloseTo(1e6, 0)
      expect(convertUnits(1, 'L', 'cm^3')).toBeCloseTo(1000, 6)
      expect(convertUnits(1, 'L', 'm^3')).toBeCloseTo(1e-3, 10)
    })

    it('converts mass (kg → g, g → mg)', () => {
      expect(convertUnits(1, 'kg', 'g')).toBeCloseTo(1000, 10)
      expect(convertUnits(1, 'g', 'mg')).toBeCloseTo(1000, 10)
      expect(convertUnits(2.5, 'kg', 'mg')).toBeCloseTo(2.5e6, 0)
    })

    it('converts time (hour → s, min → s, day → s)', () => {
      expect(convertUnits(1, 'hour', 's')).toBeCloseTo(3600, 10)
      expect(convertUnits(1, 'min', 's')).toBeCloseTo(60, 10)
      expect(convertUnits(1, 'day', 'hour')).toBeCloseTo(24, 10)
      expect(convertUnits(3600, 's', 'hour')).toBeCloseTo(1, 10)
    })

    it('converts derived units (pressure, energy, force)', () => {
      expect(convertUnits(1, 'atm', 'Pa')).toBeCloseTo(101325, 6)
      expect(convertUnits(1, 'bar', 'hPa')).toBeCloseTo(1000, 6)
      expect(convertUnits(1, 'kJ', 'J')).toBeCloseTo(1000, 10)
      expect(convertUnits(1, 'N', 'kg*m/s^2')).toBeCloseTo(1, 10)
    })

    it('round-trips without precision loss', () => {
      const kmVal = 42.195
      const mVal = convertUnits(kmVal, 'km', 'm')
      expect(convertUnits(mVal, 'm', 'km')).toBeCloseTo(kmVal, 10)
    })
  })

  describe('convertUnits — temperature (offset)', () => {
    it('converts Celsius → Kelvin', () => {
      expect(convertUnits(0, 'Celsius', 'K')).toBeCloseTo(273.15, 10)
      expect(convertUnits(100, 'Celsius', 'K')).toBeCloseTo(373.15, 10)
      expect(convertUnits(-273.15, 'Celsius', 'K')).toBeCloseTo(0, 10)
    })

    it('converts Kelvin → Celsius', () => {
      expect(convertUnits(273.15, 'K', 'Celsius')).toBeCloseTo(0, 10)
      expect(convertUnits(373.15, 'K', 'Celsius')).toBeCloseTo(100, 10)
    })

    it('handles Celsius → Celsius as identity', () => {
      expect(convertUnits(25, 'Celsius', 'Celsius')).toBeCloseTo(25, 10)
    })

    it('accepts the "C" and "degC" aliases', () => {
      expect(convertUnits(0, 'C', 'K')).toBeCloseTo(273.15, 10)
      expect(convertUnits(100, 'degC', 'K')).toBeCloseTo(373.15, 10)
    })

    it('rejects Celsius in compound expressions', () => {
      expect(() => parseUnitForConversion('Celsius*m')).toThrow(UnitConversionError)
      expect(() => parseUnitForConversion('1/Celsius')).toThrow(UnitConversionError)
      expect(() => parseUnitForConversion('Celsius^2')).toThrow(UnitConversionError)
    })
  })

  describe('convertUnits — cross-dimensional errors', () => {
    it('throws when converting length to time', () => {
      expect(() => convertUnits(1, 'm', 's')).toThrow(UnitConversionError)
      expect(() => convertUnits(1, 'm', 's')).toThrow(/incompatible dimensions/)
    })

    it('throws when converting mass to length', () => {
      expect(() => convertUnits(1, 'kg', 'm')).toThrow(UnitConversionError)
    })

    it('throws when converting temperature to dimensionless', () => {
      expect(() => convertUnits(1, 'K', 'ppm')).toThrow(UnitConversionError)
    })

    it('throws on unknown unit names', () => {
      expect(() => convertUnits(1, 'parsec', 'm')).toThrow(UnitConversionError)
      expect(() => convertUnits(1, 'm', 'furlong')).toThrow(UnitConversionError)
    })

    it('throws on malformed unit strings', () => {
      expect(() => convertUnits(1, 'm^', 'm')).toThrow(UnitConversionError)
      expect(() => convertUnits(1, '123abc', 'm')).toThrow(UnitConversionError)
    })
  })

  describe('convertUnits — dimensionless scaling', () => {
    it('converts percent ↔ ratio', () => {
      expect(convertUnits(50, 'percent', 'ratio')).toBeCloseTo(0.5, 10)
      expect(convertUnits(0.25, 'ratio', 'percent')).toBeCloseTo(25, 10)
    })

    it('converts percent → dimensionless', () => {
      expect(convertUnits(100, 'percent', 'dimensionless')).toBeCloseTo(1, 10)
    })

    it('converts ppm ↔ ppb', () => {
      expect(convertUnits(1, 'ppm', 'ppb')).toBeCloseTo(1000, 10)
      expect(convertUnits(500, 'ppb', 'ppm')).toBeCloseTo(0.5, 10)
    })
  })

  describe('convertUnits — ESM-specific units', () => {
    it('converts ppm to mol/mol', () => {
      expect(convertUnits(1, 'ppm', 'mol/mol')).toBeCloseTo(1e-6, 15)
      expect(convertUnits(400, 'ppm', 'mol/mol')).toBeCloseTo(4e-4, 10)
    })

    it('converts mol/mol to ppm and ppb', () => {
      expect(convertUnits(1e-6, 'mol/mol', 'ppm')).toBeCloseTo(1, 10)
      expect(convertUnits(1e-9, 'mol/mol', 'ppb')).toBeCloseTo(1, 10)
    })

    it('converts Dobson to molec/m^2', () => {
      expect(convertUnits(1, 'Dobson', 'molec/m^2')).toBeCloseTo(2.6867e20, 15)
      expect(convertUnits(300, 'DU', 'molec/m^2')).toBeCloseTo(8.0601e22, 17)
    })

    it('converts number densities (molec/cm^3 → molec/m^3)', () => {
      expect(convertUnits(1, 'molec/cm^3', 'molec/m^3')).toBeCloseTo(1e6, 0)
    })

    it('converts rate constants (cm^3/molec/s ↔ m^3/molec/s)', () => {
      expect(convertUnits(1, 'cm^3/molec/s', 'm^3/molec/s')).toBeCloseTo(1e-6, 15)
    })
  })

  describe('parseUnitForConversion', () => {
    it('parses dimensionless forms consistently', () => {
      expect(parseUnitForConversion('')).toEqual({ dims: {}, scale: 1 })
      expect(parseUnitForConversion('dimensionless')).toEqual({ dims: {}, scale: 1 })
      expect(parseUnitForConversion('1')).toEqual({ dims: {}, scale: 1 })
      expect(parseUnitForConversion('mol/mol').dims).toEqual({})
    })

    it('parses compound units', () => {
      const kgms2 = parseUnitForConversion('kg*m/s^2')
      expect(kgms2.dims).toEqual({ kg: 1, m: 1, s: -2 })
      expect(kgms2.scale).toBeCloseTo(1, 10)
    })

    it('attaches a scale factor distinct from dimensions', () => {
      const km = parseUnitForConversion('km')
      expect(km.dims).toEqual({ m: 1 })
      expect(km.scale).toBeCloseTo(1000, 10)

      const cm3 = parseUnitForConversion('cm^3')
      expect(cm3.dims).toEqual({ m: 3 })
      expect(cm3.scale).toBeCloseTo(1e-6, 15)
    })

    it('attaches offset only for temperature units', () => {
      expect(parseUnitForConversion('Celsius').offset).toBeCloseTo(273.15, 10)
      expect(parseUnitForConversion('K').offset).toBeUndefined()
      expect(parseUnitForConversion('m').offset).toBeUndefined()
    })
  })

  describe('unitsCompatible', () => {
    it('returns true for compatible units', () => {
      expect(unitsCompatible('km', 'm')).toBe(true)
      expect(unitsCompatible('Dobson', 'molec/m^2')).toBe(true)
      expect(unitsCompatible('atm', 'Pa')).toBe(true)
      expect(unitsCompatible('ppm', 'mol/mol')).toBe(true)
    })

    it('returns false for incompatible units', () => {
      expect(unitsCompatible('m', 's')).toBe(false)
      expect(unitsCompatible('kg', 'Pa')).toBe(false)
    })

    it('returns false for unparseable units', () => {
      expect(unitsCompatible('parsec', 'm')).toBe(false)
    })
  })
})
