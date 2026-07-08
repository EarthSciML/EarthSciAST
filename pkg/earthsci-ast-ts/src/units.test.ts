import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { join } from 'node:path'
import { parseUnit, checkDimensions, validateUnits, type ParsedUnit } from './units.js'
import { load } from './parse.js'
import type { Expression, EsmFile } from './types.js'

describe('Unit parsing and dimensional analysis', () => {
  describe('parseUnit', () => {
    it('should handle dimensionless units', () => {
      expect(parseUnit('degrees')).toEqual({ dims: {}, scale: 1 })
      expect(parseUnit('dimensionless')).toEqual({ dims: {}, scale: 1 })
      expect(parseUnit('')).toEqual({ dims: {}, scale: 1 })
      expect(parseUnit('mol/mol')).toEqual({ dims: {}, scale: 1 })
      expect(parseUnit('ppb')).toEqual({ dims: {}, scale: 1e-9 })
      expect(parseUnit('ppm')).toEqual({ dims: {}, scale: 1e-6 })
    })

    it('should parse basic units', () => {
      expect(parseUnit('K')).toEqual({ dims: { K: 1 }, scale: 1 })
      expect(parseUnit('m')).toEqual({ dims: { m: 1 }, scale: 1 })
      expect(parseUnit('s')).toEqual({ dims: { s: 1 }, scale: 1 })
      expect(parseUnit('mol')).toEqual({ dims: { mol: 1 }, scale: 1 })
      expect(parseUnit('molec')).toEqual({ dims: { molec: 1 }, scale: 1 })
    })

    it('should parse compound units', () => {
      expect(parseUnit('m/s')).toEqual({ dims: { m: 1, s: -1 }, scale: 1 })
      expect(parseUnit('mol/mol/s')).toEqual({ dims: { s: -1 }, scale: 1 })
      expect(parseUnit('1/s')).toEqual({ dims: { s: -1 }, scale: 1 })
      expect(parseUnit('s/m')).toEqual({ dims: { s: 1, m: -1 }, scale: 1 })
    })

    it('should decompose derived and prefixed units to SI base', () => {
      // cm collapses to m with a scale factor — this is the correctness
      // fix that motivates sharing the representation with unit-conversion.
      const cm3 = parseUnit('cm^3')
      expect(cm3.dims).toEqual({ m: 3 })
      expect(cm3.scale).toBeCloseTo(1e-6, 20)

      const reactionRate = parseUnit('cm^3/molec/s')
      expect(reactionRate.dims).toEqual({ m: 3, molec: -1, s: -1 })
      expect(reactionRate.scale).toBeCloseTo(1e-6, 20)
    })

    it('should recognize cm and m as the same dimension', () => {
      // The regression that motivated the unification: cm was a base
      // dimension in the old DimensionalRep, so `cm + m` looked like a
      // mismatch. Now both collapse to { m: 1 }.
      expect(parseUnit('cm').dims).toEqual(parseUnit('m').dims)
    })

    it('should handle multiplication', () => {
      const mcm3 = parseUnit('molec/cm^3')
      expect(mcm3.dims).toEqual({ molec: 1, m: -3 })
      expect(mcm3.scale).toBeCloseTo(1e6, -2)
    })

    it('should handle real-world ESM unit strings', () => {
      expect(parseUnit('mol/mol')).toEqual({ dims: {}, scale: 1 })
      expect(parseUnit('mol/mol/s')).toEqual({ dims: { s: -1 }, scale: 1 })
    })

    // ESM-specific units standard (docs/units-standard.md): every binding
    // must accept these with the listed dimension/scale so cross-binding
    // documents agree on dimension semantics.
    describe('ESM-specific units standard', () => {
      it('mole-fraction family is dimensionless with correct scale factors', () => {
        expect(parseUnit('mol/mol')).toEqual({ dims: {}, scale: 1 })
        expect(parseUnit('ppm')).toEqual({ dims: {}, scale: 1e-6 })
        expect(parseUnit('ppmv')).toEqual({ dims: {}, scale: 1e-6 })
        expect(parseUnit('ppb')).toEqual({ dims: {}, scale: 1e-9 })
        expect(parseUnit('ppbv')).toEqual({ dims: {}, scale: 1e-9 })
        expect(parseUnit('ppt')).toEqual({ dims: {}, scale: 1e-12 })
        expect(parseUnit('pptv')).toEqual({ dims: {}, scale: 1e-12 })
      })

      it('molec is a dimensionless count atom usable in composites', () => {
        expect(parseUnit('molec').dims).toEqual({ molec: 1 })
        const numberDensity = parseUnit('molec/cm^3')
        expect(numberDensity.dims).toEqual({ molec: 1, m: -3 })
      })

      it('Dobson is an areal number density with scale 2.6867e20 molec/m^2', () => {
        const du = parseUnit('Dobson')
        expect(du.dims).toEqual({ molec: 1, m: -2 })
        expect(du.scale).toBeCloseTo(2.6867e20, -15)
      })
    })
  })

  describe('checkDimensions', () => {
    const createUnitBindings = (bindings: Record<string, string>): Map<string, ParsedUnit> => {
      const map = new Map<string, ParsedUnit>()
      for (const [name, unitStr] of Object.entries(bindings)) {
        map.set(name, parseUnit(unitStr))
      }
      return map
    }

    it('should handle numbers and variables', () => {
      const bindings = createUnitBindings({ x: 'm', t: 's' })

      const numberResult = checkDimensions(42, bindings)
      expect(numberResult.dimensions.dims).toEqual({})
      expect(numberResult.warnings).toEqual([])

      const varResult = checkDimensions('x', bindings)
      expect(varResult.dimensions.dims).toEqual({ m: 1 })
      expect(varResult.warnings).toEqual([])

      const unknownVarResult = checkDimensions('unknown', bindings)
      expect(unknownVarResult.dimensions.dims).toEqual({})
      expect(unknownVarResult.warnings).toEqual(['Unknown variable: unknown'])
    })

    it('should handle addition and subtraction', () => {
      const bindings = createUnitBindings({ x: 'm', y: 'm', t: 's' })

      const addExpr: Expression = { op: '+', args: ['x', 'y'] }
      const addResult = checkDimensions(addExpr, bindings)
      expect(addResult.dimensions.dims).toEqual({ m: 1 })
      expect(addResult.warnings).toEqual([])

      const badAddExpr: Expression = { op: '+', args: ['x', 't'] }
      const badAddResult = checkDimensions(badAddExpr, bindings)
      expect(badAddResult.warnings[0]).toContain('Addition/subtraction requires same dimensions')
    })

    it('should treat cm and m as compatible in addition', () => {
      // Previously impossible: `cm + m` would warn because cm was a base
      // dimension distinct from m. With the shared representation, both
      // decompose to { m: 1 } and the operation is accepted.
      const bindings = createUnitBindings({ a: 'cm', b: 'm' })
      const expr: Expression = { op: '+', args: ['a', 'b'] }
      const result = checkDimensions(expr, bindings)
      expect(result.warnings).toEqual([])
      expect(result.dimensions.dims).toEqual({ m: 1 })
    })

    it('should handle multiplication', () => {
      const bindings = createUnitBindings({ F: 'kg*m/s^2', m: 'kg', a: 'm/s^2' })

      const multExpr: Expression = { op: '*', args: ['m', 'a'] }
      const result = checkDimensions(multExpr, bindings)
      expect(result.warnings).toEqual([])
      expect(result.dimensions.dims).toEqual({ kg: 1, m: 1, s: -2 })
    })

    it('should handle division', () => {
      const bindings = createUnitBindings({ v: 'm/s', t: 's', a: 'm/s^2' })

      const divExpr: Expression = { op: '/', args: ['v', 't'] }
      const result = checkDimensions(divExpr, bindings)
      expect(result.warnings).toEqual([])
      expect(result.dimensions.dims).toEqual({ m: 1, s: -2 })
    })

    it('should handle derivative operator', () => {
      const bindings = createUnitBindings({ x: 'm', t: 's' })

      const derivExpr: Expression = { op: 'D', args: ['x'], wrt: 't' }
      const result = checkDimensions(derivExpr, bindings)
      expect(result.dimensions.dims).toEqual({ m: 1, s: -1 })
      expect(result.warnings).toEqual([])
    })

    it('should handle mathematical functions', () => {
      const bindings = createUnitBindings({ x: 'dimensionless', y: 'm' })

      const expExpr: Expression = { op: 'exp', args: ['x'] }
      const expResult = checkDimensions(expExpr, bindings)
      expect(expResult.dimensions.dims).toEqual({})
      expect(expResult.warnings).toEqual([])

      const badExpExpr: Expression = { op: 'exp', args: ['y'] }
      const badExpResult = checkDimensions(badExpExpr, bindings)
      expect(badExpResult.warnings[0]).toContain('exp() requires dimensionless argument')
    })

    it('should handle comparison operators', () => {
      const bindings = createUnitBindings({ x: 'm', y: 'm', t: 's' })

      const compExpr: Expression = { op: '>', args: ['x', 'y'] }
      const compResult = checkDimensions(compExpr, bindings)
      expect(compResult.dimensions.dims).toEqual({})
      expect(compResult.warnings).toEqual([])

      const badCompExpr: Expression = { op: '>', args: ['x', 't'] }
      const badCompResult = checkDimensions(badCompExpr, bindings)
      expect(badCompResult.warnings[0]).toContain('> requires arguments with same dimensions')
    })

    it('should handle conditional expressions', () => {
      const bindings = createUnitBindings({ condition: 'dimensionless', x: 'm', y: 'm' })

      const ifExpr: Expression = { op: 'ifelse', args: ['condition', 'x', 'y'] }
      const result = checkDimensions(ifExpr, bindings)
      expect(result.dimensions.dims).toEqual({ m: 1 })
      expect(result.warnings).toEqual([])
    })
  })

  describe('validateUnits', () => {
    it('should validate simple ESM file with no errors', () => {
      const esmFile: EsmFile = {
        esm: '0.1.0',
        metadata: {
          name: 'test',
          description: 'test model',
          authors: ['test'],
        },
        models: {
          TestModel: {
            variables: {
              x: { type: 'state', units: 'm', description: 'Position' },
              v: { type: 'state', units: 'm/s', description: 'Velocity' },
              t: { type: 'parameter', units: 's', description: 'Time' },
            },
            equations: [
              {
                lhs: { op: 'D', args: ['x'], wrt: 't' },
                rhs: 'v',
              },
            ],
          },
        },
      }

      const warnings = validateUnits(esmFile)
      expect(warnings).toEqual([])
    })

    it('should detect dimensional inconsistencies', () => {
      const esmFile: EsmFile = {
        esm: '0.1.0',
        metadata: {
          name: 'test',
          description: 'test model',
          authors: ['test'],
        },
        models: {
          TestModel: {
            variables: {
              x: { type: 'state', units: 'm', description: 'Position' },
              f: { type: 'parameter', units: 's', description: 'Force (wrong units)' },
            },
            equations: [
              {
                lhs: { op: 'D', args: ['x'], wrt: 't' },
                rhs: 'f',
              },
            ],
          },
        },
      }

      const warnings = validateUnits(esmFile)
      expect(warnings.length).toBeGreaterThan(0)
      expect(warnings[0]?.message).toContain('Dimensional mismatch')
    })

    it('should validate observed variables', () => {
      const esmFile: EsmFile = {
        esm: '0.1.0',
        metadata: {
          name: 'test',
          description: 'test model',
          authors: ['test'],
        },
        models: {
          TestModel: {
            variables: {
              k: { type: 'parameter', units: '1/s', description: 'Rate constant' },
              x: { type: 'state', units: 'm', description: 'Position' },
              rate: {
                type: 'observed',
                units: 'm/s',
                expression: { op: '*', args: ['k', 'x'] },
                description: 'Rate of change',
              },
            },
            equations: [],
          },
        },
      }

      const warnings = validateUnits(esmFile)
      expect(warnings).toEqual([])
    })

    it('should handle reaction systems', () => {
      const esmFile: EsmFile = {
        esm: '0.1.0',
        metadata: {
          name: 'test',
          description: 'test reaction',
          authors: ['test'],
        },
        reaction_systems: {
          SimpleReaction: {
            species: {
              A: { units: 'mol/mol', description: 'Species A' },
              B: { units: 'mol/mol', description: 'Species B' },
            },
            parameters: {
              k: { units: '1/s', description: 'Rate constant' },
              M: { units: 'molec/cm^3', description: 'Number density' },
            },
            reactions: [
              {
                id: 'R1',
                substrates: [{ species: 'A', stoichiometry: 1 }],
                products: [{ species: 'B', stoichiometry: 1 }],
                rate: { op: '*', args: ['k', 'A'] },
              },
            ],
          },
        },
      }

      const warnings = validateUnits(esmFile)
      expect(warnings).toEqual([])
    })
  })

  describe('Edge cases and error handling', () => {
    it('should handle empty or null unit strings gracefully', () => {
      expect(parseUnit('')).toEqual({ dims: {}, scale: 1 })
      expect(parseUnit('   ')).toEqual({ dims: {}, scale: 1 })
    })

    it('should handle unknown unit tokens by falling back to dimensionless', () => {
      // Matches the lenient behavior of the legacy parser, which silently
      // ignored tokens it did not recognize.
      expect(parseUnit('completelyMadeUpUnit')).toEqual({ dims: {}, scale: 1 })
    })

    it('should handle unknown operators gracefully', () => {
      const bindings = new Map<string, ParsedUnit>()
      bindings.set('x', { dims: { m: 1 }, scale: 1 })

      const unknownOpExpr: Expression = { op: 'unknown_op' as any, args: ['x'] }
      const result = checkDimensions(unknownOpExpr, bindings)
      expect(result.warnings).toContain('Unknown operator: unknown_op')
    })

    it('should handle malformed expressions', () => {
      const bindings = new Map<string, ParsedUnit>()

      const badDivExpr: Expression = { op: '/', args: ['x', 'y', 'z'] }
      const result = checkDimensions(badDivExpr, bindings)
      const divisionWarning = result.warnings.find((w) =>
        w.includes('Division requires exactly 2 arguments'),
      )
      expect(divisionWarning).toBeDefined()
    })
  })

  describe('Cross-binding units fixtures (gt-gtf)', () => {
    // The three units_*.esm files in tests/valid/ are shared across
    // Julia/Python/Rust/TypeScript/Go and exist specifically to drive
    // cross-binding agreement on units handling. validateUnits is opt-in
    // for TypeScript, so call it explicitly per-fixture. Each binding's
    // unit registry covers a different subset, so this test asserts only
    // that load and validateUnits complete successfully and emit warnings
    // as a typed array.
    const fixturesDir = join(__dirname, '..', '..', '..', 'tests', 'valid')
    const fixtures = [
      'units_conversions.esm',
      'units_dimensional_analysis.esm',
      'units_propagation.esm',
    ]

    for (const fname of fixtures) {
      it(`loads ${fname} and runs validateUnits`, () => {
        const content = readFileSync(join(fixturesDir, fname), 'utf8')
        const file = load(content) as EsmFile
        expect(file.models).toBeDefined()
        expect(Object.keys(file.models ?? {}).length).toBeGreaterThan(0)
        const warnings = validateUnits(file)
        expect(Array.isArray(warnings)).toBe(true)
      })
    }
  })
})
