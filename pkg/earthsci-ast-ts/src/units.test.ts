import { describe, it, expect } from 'vitest'
import {
  parseUnit,
  tryParseUnit,
  checkDimensions,
  validateUnits,
  dimsEqual,
  type ParsedUnit,
  type CanonicalDims,
} from './units.js'
import { load } from './parse.js'
import { validate } from './validate.js'
import { readFixture } from './test-helpers.js'
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
      // A count of discrete things has no physical dimension.
      expect(parseUnit('molec')).toEqual({ dims: {}, scale: 1 })
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
      expect(reactionRate.dims).toEqual({ m: 3, s: -1 })
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
      expect(mcm3.dims).toEqual({ m: -3 })
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
        // A COUNT of discrete things carries no physical dimension, which is
        // what makes `molec/cm^3` the same quantity as `1/cm^3` — the reading
        // every other binding has. Giving counts their own dimension axis (as
        // this table once did) made TS the only binding that could report the
        // two spellings of a number density as a mismatch.
        expect(parseUnit('molec').dims).toEqual({})
        expect(parseUnit('molec/cm^3').dims).toEqual({ m: -3 })
        expect(dimsEqual(parseUnit('molec/cm^3').dims, parseUnit('1/cm^3').dims)).toBe(true)
      })

      it('the other count nouns are dimensionless too', () => {
        // Real unit names in the shared corpus (`individuals/km^2`,
        // `vehicles/km^2`, `units/L`). An unresolvable unit string is a hard
        // error, so omitting them would falsely reject those files.
        for (const count of ['individuals', 'vehicles', 'units', 'count']) {
          expect(parseUnit(count)).toEqual({ dims: {}, scale: 1 })
        }
        expect(parseUnit('individuals/km^2').dims).toEqual({ m: -2 })
      })

      it('Dobson is an areal number density with scale 2.6867e20 molec/m^2', () => {
        const du = parseUnit('Dobson')
        // `molec` is dimensionless, so a column amount is an inverse area.
        expect(du.dims).toEqual({ m: -2 })
        expect(du.scale).toBeCloseTo(2.6867e20, -15)
      })
    })

    // The EM units are REAL SI units, and `tests/valid/units_dimensional_analysis.esm`
    // — a fixture pinned VALID — declares `E: "V/m"`, `B: "T"`, `epsilon0: "F/m"`,
    // `q: "C"`. They were once deleted from the registry to "match Go", whose table
    // lacked them; that was Go's GAP, not TS's excess, and copying it turned a
    // legitimate file into a rejected one now that an unparseable unit is a hard
    // error. Go has since added them.
    describe('electromagnetic units', () => {
      it('parses V, T, F and Ohm as their SI-base decompositions', () => {
        expect(parseUnit('V')).toEqual({ dims: { kg: 1, m: 2, s: -3, A: -1 }, scale: 1 })
        expect(parseUnit('T')).toEqual({ dims: { kg: 1, s: -2, A: -1 }, scale: 1 })
        expect(parseUnit('F')).toEqual({ dims: { kg: -1, m: -2, s: 4, A: 2 }, scale: 1 })
        expect(parseUnit('Ohm')).toEqual({ dims: { kg: 1, m: 2, s: -3, A: -2 }, scale: 1 })
        expect(parseUnit('V/m').dims).toEqual({ kg: 1, m: 1, s: -3, A: -1 })
        expect(parseUnit('F/m').dims).toEqual({ kg: -1, m: -3, s: 4, A: 2 })
      })

      it('C is the COULOMB, so charge times field is a force', () => {
        expect(parseUnit('C')).toEqual({ dims: { A: 1, s: 1 }, scale: 1 })
        // q[C] * E[V/m] must be a newton. With `C` bound to Celsius it came out
        // as kg*m*K/(s^3*A) — a temperature dimension smuggled into every
        // electromagnetic expression.
        const force = checkDimensions(
          { op: '*', args: ['q', 'E'] },
          new Map([
            ['q', parseUnit('C')],
            ['E', parseUnit('V/m')],
          ]),
        )
        expect(dimsEqual(force.dimensions!.dims, parseUnit('N').dims)).toBe(true)
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

    /** Assert a determinate dimension and return it (narrows away `null`). */
    const dimsOf = (result: { dimensions: ParsedUnit | null }): CanonicalDims => {
      expect(result.dimensions).not.toBeNull()
      return result.dimensions!.dims
    }

    it('should handle numbers and variables', () => {
      const bindings = createUnitBindings({ x: 'm', t: 's' })

      // A bare literal carries no declared unit, so its dimension is
      // INDETERMINATE — it may be a pure number or an implicit-unit constant
      // (273.15 K, 0.0224 m^3/mol, ...). It raises no diagnostic: an
      // un-annotated constant is not a defect.
      const numberResult = checkDimensions(42, bindings)
      expect(numberResult.dimensions).toBeNull()
      expect(numberResult.warnings).toEqual([])

      const varResult = checkDimensions('x', bindings)
      expect(dimsOf(varResult)).toEqual({ m: 1 })
      expect(varResult.warnings).toEqual([])

      // An unknown variable is INDETERMINATE, not dimensionless.
      const unknownVarResult = checkDimensions('unknown', bindings)
      expect(unknownVarResult.dimensions).toBeNull()
      expect(unknownVarResult.warnings).toEqual(['Unknown variable: unknown'])
    })

    // The literal rules, stated as tests because they are the load-bearing part
    // of "a literal is indeterminate".
    describe('numeric literals', () => {
      it('is neutral in additive position — it adopts its sibling dimension', () => {
        const bindings = createUnitBindings({ T: 'K' })
        // `T - 273.15` is Kelvin, not a K-vs-dimensionless mismatch.
        const result = checkDimensions({ op: '-', args: ['T', 273.15] }, bindings)
        expect(dimsOf(result)).toEqual({ K: 1 })
        expect(result.diagnostics.filter((d) => d.code === 'dimensional_mismatch')).toEqual([])
      })

      it('makes an all-literal expression dimensionless', () => {
        const bindings = createUnitBindings({})
        expect(dimsOf(checkDimensions({ op: '+', args: [1, 2] }, bindings))).toEqual({})
        expect(dimsOf(checkDimensions({ op: '-', args: [1] }, bindings))).toEqual({})
      })

      it('makes a product involving an un-annotated constant indeterminate', () => {
        // `6.022e23 * conc` might be a mole→molecule conversion carrying
        // implicit 1/mol. We cannot know, so we do not claim to.
        const bindings = createUnitBindings({ conc: 'mol/m^3' })
        const result = checkDimensions({ op: '*', args: [6.022e23, 'conc'] }, bindings)
        expect(result.dimensions).toBeNull()
        expect(result.diagnostics.filter((d) => d.code === 'dimensional_mismatch')).toEqual([])
      })

      it('is still read BY VALUE in exponent position', () => {
        const bindings = createUnitBindings({ x: 'm' })
        expect(dimsOf(checkDimensions({ op: '^', args: ['x', 2] }, bindings))).toEqual({ m: 2 })
      })
    })

    it('should handle addition and subtraction', () => {
      const bindings = createUnitBindings({ x: 'm', y: 'm', t: 's' })

      const addExpr: Expression = { op: '+', args: ['x', 'y'] }
      const addResult = checkDimensions(addExpr, bindings)
      expect(dimsOf(addResult)).toEqual({ m: 1 })
      expect(addResult.warnings).toEqual([])

      const badAddExpr: Expression = { op: '+', args: ['x', 't'] }
      const badAddResult = checkDimensions(badAddExpr, bindings)
      expect(badAddResult.warnings[0]).toContain('Addition/subtraction requires same dimensions')
      expect(badAddResult.diagnostics[0].code).toBe('dimensional_mismatch')
    })

    it('should treat cm and m as compatible in addition', () => {
      // Previously impossible: `cm + m` would warn because cm was a base
      // dimension distinct from m. With the shared representation, both
      // decompose to { m: 1 } and the operation is accepted.
      const bindings = createUnitBindings({ a: 'cm', b: 'm' })
      const expr: Expression = { op: '+', args: ['a', 'b'] }
      const result = checkDimensions(expr, bindings)
      expect(result.warnings).toEqual([])
      expect(dimsOf(result)).toEqual({ m: 1 })
    })

    it('should handle multiplication', () => {
      const bindings = createUnitBindings({ F: 'kg*m/s^2', m: 'kg', a: 'm/s^2' })

      const multExpr: Expression = { op: '*', args: ['m', 'a'] }
      const result = checkDimensions(multExpr, bindings)
      expect(result.warnings).toEqual([])
      expect(dimsOf(result)).toEqual({ kg: 1, m: 1, s: -2 })
    })

    it('should handle division', () => {
      const bindings = createUnitBindings({ v: 'm/s', t: 's', a: 'm/s^2' })

      const divExpr: Expression = { op: '/', args: ['v', 't'] }
      const result = checkDimensions(divExpr, bindings)
      expect(result.warnings).toEqual([])
      expect(dimsOf(result)).toEqual({ m: 1, s: -2 })
    })

    // C3: the `^` arm used to return the base dimension UNCHANGED, so `x^2`
    // with x in metres reported `m` rather than `m^2`, and `sqrt(A)` with A in
    // m^2 reported `m^2` rather than `m`.
    describe('exponentiation and sqrt (C3)', () => {
      it('raises the base dimension to an integer literal exponent', () => {
        const bindings = createUnitBindings({ x: 'm' })
        expect(dimsOf(checkDimensions({ op: '^', args: ['x', 2] }, bindings))).toEqual({ m: 2 })
        expect(dimsOf(checkDimensions({ op: '^', args: ['x', 3] }, bindings))).toEqual({ m: 3 })
        expect(dimsOf(checkDimensions({ op: '^', args: ['x', -1] }, bindings))).toEqual({ m: -1 })
      })

      it('accepts a float-valued integer exponent as well as an int literal', () => {
        // JSON `2` and `2.0` must behave identically — matching only the float
        // form is exactly the Rust binding's R6 bug.
        const bindings = createUnitBindings({ x: 'm' })
        expect(dimsOf(checkDimensions({ op: '^', args: ['x', 2.0] }, bindings))).toEqual({ m: 2 })
      })

      it('scales a compound base dimension by the exponent', () => {
        const bindings = createUnitBindings({ v: 'm/s' })
        expect(dimsOf(checkDimensions({ op: '^', args: ['v', 2] }, bindings))).toEqual({
          m: 2,
          s: -2,
        })
      })

      it('halves the dimension under sqrt', () => {
        const bindings = createUnitBindings({ A: 'm^2', vsq: 'm^2/s^2' })
        expect(dimsOf(checkDimensions({ op: 'sqrt', args: ['A'] }, bindings))).toEqual({ m: 1 })
        expect(dimsOf(checkDimensions({ op: 'sqrt', args: ['vsq'] }, bindings))).toEqual({
          m: 1,
          s: -1,
        })
      })

      // Dimension exponents are RATIONAL, not integral, so sqrt of an odd
      // exponent is well-defined rather than a mismatch. `sqrt(k)` on a `1/s`
      // rate constant is `1/s^0.5` — the declared unit of an SDE noise
      // intensity in the corpus. The old contract (odd exponent ⇒ mismatch)
      // rejected correct physics.
      it('halves an odd exponent instead of reporting a mismatch (rational dimensions)', () => {
        const bindings = createUnitBindings({ x: 'm', k: '1/s' })

        const length = checkDimensions({ op: 'sqrt', args: ['x'] }, bindings)
        expect(length.dimensions?.dims).toEqual({ m: 0.5 })
        expect(length.diagnostics.some((d) => d.code === 'dimensional_mismatch')).toBe(false)

        // The SDE case: sqrt of a rate constant is a noise intensity, 1/s^0.5.
        const noise = checkDimensions({ op: 'sqrt', args: ['k'] }, bindings)
        expect(noise.dimensions?.dims).toEqual({ s: -0.5 })
        expect(noise.diagnostics.some((d) => d.code === 'dimensional_mismatch')).toBe(false)
      })

      // The transcendentals split THREE ways (spec §4.8.3). `rad` is an AXIS of
      // this dimension vector, so an angle is NOT dimensionless — which is why a
      // naive "transcendentals take a dimensionless argument" rule makes
      // `cos(theta)` illegal and rejects `lib/solar.esm` (a SHIPPED
      // standard-library file, pinned valid via lib_solar_subsystem_inclusion.esm).
      it('sin/cos/tan take an angle OR a dimensionless argument, and return dimensionless', () => {
        const bindings = createUnitBindings({ theta: 'rad', phase: '1', mass: 'kg' })

        for (const op of ['sin', 'cos', 'tan']) {
          for (const arg of ['theta', 'phase']) {
            const r = checkDimensions({ op, args: [arg] }, bindings)
            expect(
              r.diagnostics.some((d) => d.code === 'dimensional_mismatch'),
              `${op}(${arg})`,
            ).toBe(false)
            expect(dimsOf(r), `${op}(${arg})`).toEqual({})
          }
          // A genuinely dimensional argument is still a provable mismatch.
          const bad = checkDimensions({ op, args: ['mass'] }, bindings)
          expect(
            bad.diagnostics.some((d) => d.code === 'dimensional_mismatch'),
            op,
          ).toBe(true)
        }
      })

      it('asin/acos/atan take dimensionless and RETURN AN ANGLE (rad)', () => {
        const bindings = createUnitBindings({ ratio: '1', mass: 'kg' })
        for (const op of ['acos', 'asin', 'atan']) {
          const r = checkDimensions({ op, args: ['ratio'] }, bindings)
          expect(dimsOf(r), op).toEqual({ rad: 1 })
          expect(
            r.diagnostics.some((d) => d.code === 'dimensional_mismatch'),
            op,
          ).toBe(false)

          const bad = checkDimensions({ op, args: ['mass'] }, bindings)
          expect(
            bad.diagnostics.some((d) => d.code === 'dimensional_mismatch'),
            op,
          ).toBe(true)
        }
        // atan2 is the two-argument atan: it too returns an angle.
        const r2 = checkDimensions({ op: 'atan2', args: ['ratio', 'ratio'] }, bindings)
        expect(dimsOf(r2)).toEqual({ rad: 1 })
      })

      it('round-trips: acos(cos(theta)) is an angle again', () => {
        const bindings = createUnitBindings({ theta: 'rad' })
        const r = checkDimensions({ op: 'acos', args: [{ op: 'cos', args: ['theta'] }] }, bindings)
        expect(dimsOf(r)).toEqual({ rad: 1 })
        expect(r.diagnostics.some((d) => d.code === 'dimensional_mismatch')).toBe(false)
      })

      it('keeps the STRICTLY dimensionless set strict (log, exp, hyperbolics)', () => {
        const bindings = createUnitBindings({ theta: 'rad', mass: 'kg' })
        // There is no angle reading of exp/log, and a hyperbolic angle is a pure
        // number — so `rad` is NOT admitted here, and neither is any dimension.
        for (const op of [
          'ln',
          'log',
          'log10',
          'exp',
          'sinh',
          'cosh',
          'tanh',
          'asinh',
          'acosh',
          'atanh',
        ]) {
          for (const arg of ['theta', 'mass']) {
            const r = checkDimensions({ op, args: [arg] }, bindings)
            expect(
              r.diagnostics.some((d) => d.code === 'dimensional_mismatch'),
              `${op}(${arg})`,
            ).toBe(true)
          }
        }
      })

      it('does not report acos() against a rad-declared observed variable', () => {
        // The lib/solar.esm shape, reduced: declared `rad`, computed by `acos`.
        const file: EsmFile = {
          esm: '0.1.0',
          metadata: { name: 'solar' },
          models: {
            Solar: {
              variables: {
                cos_zenith: { type: 'parameter', units: '1', default: 0.5 },
                solar_zenith_angle: {
                  type: 'observed',
                  units: 'rad',
                  expression: { op: 'acos', args: ['cos_zenith'] },
                },
              },
              equations: [],
            },
          },
        }
        const mismatches = validateUnits(file).filter((w) => w.code === 'dimensional_mismatch')
        expect(mismatches).toEqual([])
      })

      it('rejects a dimensional exponent', () => {
        const bindings = createUnitBindings({ x: 'm', w: 'kg' })
        const result = checkDimensions({ op: '^', args: ['x', 'w'] }, bindings)
        expect(result.diagnostics.some((d) => d.code === 'dimensional_mismatch')).toBe(true)
      })

      it('leaves a non-literal exponent on a dimensional base INDETERMINATE, not wrong', () => {
        // `k * [X]^n` (a fitted reaction order) is ordinary chemistry. Its
        // dimension cannot be computed, but the file is not defective, so this
        // must NOT be a promotable mismatch.
        const bindings = createUnitBindings({ x: 'm', n: 'dimensionless' })
        const result = checkDimensions({ op: '^', args: ['x', 'n'] }, bindings)
        expect(result.dimensions).toBeNull()
        expect(result.diagnostics.filter((d) => d.code === 'dimensional_mismatch')).toEqual([])
        expect(result.diagnostics.some((d) => d.code === 'analysis')).toBe(true)
      })

      it('allows a non-literal exponent on a DIMENSIONLESS base', () => {
        // `ratio^n` is fine whatever n is — the result is dimensionless either way.
        const bindings = createUnitBindings({ r: 'dimensionless', n: 'dimensionless' })
        const result = checkDimensions({ op: '^', args: ['r', 'n'] }, bindings)
        expect(dimsOf(result)).toEqual({})
        expect(result.diagnostics.filter((d) => d.code === 'dimensional_mismatch')).toEqual([])
      })
    })

    it('should handle derivative operator', () => {
      const bindings = createUnitBindings({ x: 'm', t: 's' })

      const derivExpr: Expression = { op: 'D', args: ['x'], wrt: 't' }
      const result = checkDimensions(derivExpr, bindings)
      expect(dimsOf(result)).toEqual({ m: 1, s: -1 })
      expect(result.warnings).toEqual([])
    })

    it('should handle mathematical functions', () => {
      const bindings = createUnitBindings({ x: 'dimensionless', y: 'm' })

      const expExpr: Expression = { op: 'exp', args: ['x'] }
      const expResult = checkDimensions(expExpr, bindings)
      expect(dimsOf(expResult)).toEqual({})
      expect(expResult.warnings).toEqual([])

      const badExpExpr: Expression = { op: 'exp', args: ['y'] }
      const badExpResult = checkDimensions(badExpExpr, bindings)
      expect(badExpResult.warnings[0]).toContain('exp() requires dimensionless argument')
      // A transcendental of a dimensional quantity is a PROVABLE inconsistency,
      // so it is promotable — the corpus pins units_invalid_logarithm.esm on it.
      expect(badExpResult.diagnostics[0].code).toBe('dimensional_mismatch')
    })

    it('should handle comparison operators', () => {
      const bindings = createUnitBindings({ x: 'm', y: 'm', t: 's' })

      const compExpr: Expression = { op: '>', args: ['x', 'y'] }
      const compResult = checkDimensions(compExpr, bindings)
      expect(dimsOf(compResult)).toEqual({})
      expect(compResult.warnings).toEqual([])

      const badCompExpr: Expression = { op: '>', args: ['x', 't'] }
      const badCompResult = checkDimensions(badCompExpr, bindings)
      expect(badCompResult.warnings[0]).toContain('> requires arguments with same dimensions')
    })

    it('should handle conditional expressions', () => {
      const bindings = createUnitBindings({ condition: 'dimensionless', x: 'm', y: 'm' })

      const ifExpr: Expression = { op: 'ifelse', args: ['condition', 'x', 'y'] }
      const result = checkDimensions(ifExpr, bindings)
      expect(dimsOf(result)).toEqual({ m: 1 })
      expect(result.warnings).toEqual([])
    })

    // T3: structural ops have NO modelled dimension. Reporting them as
    // dimensionless manufactured false mismatches against dimensional operands
    // all over the valid corpus.
    describe('structural operators are indeterminate, not dimensionless (T3)', () => {
      const structural: Expression[] = [
        { op: 'index', args: ['u', 2] },
        { op: 'fn', args: ['t'], name: 'datetime.year' } as unknown as Expression,
        { op: 'aggregate', args: ['A'], expr: { op: '*', args: ['A', 'w'] } } as Expression,
        { op: 'table_lookup', args: [], table: 'kT', axes: { temp: 'T_air' } } as Expression,
        { op: 'makearray', args: [1, 2] } as unknown as Expression,
      ]

      it.each(structural)('reports %j as indeterminate', (expr) => {
        const bindings = createUnitBindings({ u: 'm', w: 'm', A: 'm', T_air: 'K', t: 's' })
        expect(checkDimensions(expr, bindings).dimensions).toBeNull()
      })

      it('does not manufacture a mismatch against a dimensional operand', () => {
        // `m + index(u, 2)`: the old code called index() dimensionless and
        // warned that metres and dimensionless differ. There is nothing to
        // prove here — index's dimension is simply unknown.
        const bindings = createUnitBindings({ x: 'm', u: 'm' })
        const result = checkDimensions(
          { op: '+', args: ['x', { op: 'index', args: ['u', 2] }] },
          bindings,
        )
        expect(result.diagnostics.filter((d) => d.code === 'dimensional_mismatch')).toEqual([])
      })
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

    it('surfaces an unparseable unit as a warning, not a dimensional mismatch', () => {
      // `x` carries an unparseable unit ('notaunit'). The pre-fix behaviour
      // bound it as DIMENSIONLESS, so `D(x, t)` (= 1/s) vs `v` (= m/s) looked
      // like a dimensional mismatch — a FALSE positive. Per esm-libraries-spec
      // §3.3.3/§3.4 (and the Julia reference) the unparseable unit must instead
      // surface as a WARNING with the variable's dimension left UNKNOWN
      // (unbound), which suppresses the mismatch and keeps validation valid.
      const esmFile: EsmFile = {
        esm: '0.1.0',
        metadata: {
          name: 'test',
          description: 'unparseable unit',
          authors: ['test'],
        },
        models: {
          TestModel: {
            variables: {
              x: { type: 'state', units: 'notaunit', description: 'Unparseable unit' },
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

      // 'notaunit' denotes no real unit, so the DECLARATION is meaningless and
      // the file is malformed: an `unparseable_unit` finding, which validate()
      // promotes to a hard `unit_inconsistency` error. (This is a deliberate
      // reversal of the old policy, which called it an `analysis` warning and
      // let the file pass.)
      const unparseable = warnings.filter((w) => w.code === 'unparseable_unit')
      expect(unparseable).toHaveLength(1)
      expect(unparseable[0].message).toContain('notaunit')
      // The pointer is the offending DECLARATION, which is what validate() uses
      // verbatim as the structural error's path.
      expect(unparseable[0].location).toBe('/models/TestModel/variables/x')
      // The one defect is reported ONCE, and nothing is INVENTED on top of it:
      // `x` is left unbound (dimension UNKNOWN, not dimensionless), so the
      // equation that uses it yields no dimensional mismatch.
      expect(warnings.some((w) => w.code === 'dimensional_mismatch')).toBe(false)
    })

    it('reports an unparseable observed-variable declared unit once, and invents no mismatch', () => {
      // `rate` declares an unparseable unit ('notaunit') while its expression
      // (k*x) evaluates to m/s. The declaration is the defect and is reported as
      // such (`unparseable_unit` → hard error). Forcing the declared side to
      // dimensionless would ALSO manufacture a false dimensional mismatch
      // against the expression — two errors for one defect, one of them
      // fictional — so the declared side is left UNKNOWN and the comparison is
      // skipped.
      const esmFile: EsmFile = {
        esm: '0.1.0',
        metadata: {
          name: 'test',
          description: 'unparseable observed unit',
          authors: ['test'],
        },
        models: {
          TestModel: {
            variables: {
              k: { type: 'parameter', units: '1/s', description: 'Rate constant' },
              x: { type: 'state', units: 'm', description: 'Position' },
              rate: {
                type: 'observed',
                units: 'notaunit',
                expression: { op: '*', args: ['k', 'x'] },
                description: 'Rate of change',
              },
            },
            equations: [],
          },
        },
      }

      const warnings = validateUnits(esmFile)

      const unparseable = warnings.filter((w) => w.code === 'unparseable_unit')
      expect(unparseable).toHaveLength(1)
      expect(unparseable[0].message).toContain('notaunit')
      expect(unparseable[0].location).toBe('/models/TestModel/variables/rate')
      expect(warnings.some((w) => w.code === 'dimensional_mismatch')).toBe(false)
    })
  })

  describe('Edge cases and error handling', () => {
    it('should handle empty or null unit strings gracefully', () => {
      expect(parseUnit('')).toEqual({ dims: {}, scale: 1 })
      expect(parseUnit('   ')).toEqual({ dims: {}, scale: 1 })
    })

    it('should REJECT an unknown unit token rather than silently pass it', () => {
      // C4: an unparseable unit must be an error. Collapsing it to
      // dimensionless is a false claim about the quantity — it both hides real
      // mismatches and manufactures fake ones.
      expect(() => parseUnit('completelyMadeUpUnit')).toThrow(/Unknown unit/)
      // `tryParseUnit` is the fallible form the validators use: null, not a
      // fabricated dimensionless.
      expect(tryParseUnit('completelyMadeUpUnit')).toBeNull()
    })

    it('should report an unknown operator as indeterminate, not dimensionless', () => {
      const bindings = new Map<string, ParsedUnit>()
      bindings.set('x', { dims: { m: 1 }, scale: 1 })

      const unknownOpExpr: Expression = { op: 'unknown_op' as any, args: ['x'] }
      const result = checkDimensions(unknownOpExpr, bindings)
      expect(result.dimensions).toBeNull()
      // An unmodelled op is not a defect, so it raises no mismatch.
      expect(result.diagnostics.filter((d) => d.code === 'dimensional_mismatch')).toEqual([])
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
    // cross-binding agreement on units handling.
    //
    // These are VALID fixtures, so the contract is sharp and worth stating as
    // an assertion rather than the `expect(Array.isArray(warnings)).toBe(true)`
    // that used to stand here (which no implementation could ever fail):
    // dimensional analysis must find NO provable inconsistency in any of them,
    // and `validate()` must accept them.
    const fixtures = ['units_conversions.esm', 'units_propagation.esm']

    // CORPUS CONTRADICTION — units_dimensional_analysis.esm is deliberately NOT
    // in the list above, and this is not a gap in the checker.
    //
    // That fixture lives in tests/valid/ and declares
    //     S (observed, J/K) = n * R * log(V),  with V: state, units "m^3"
    // i.e. a transcendental function applied to a bare variable whose declared
    // units are dimensional. `tests/invalid/units_invalid_logarithm.esm` is the
    // SAME construct —
    //     invalid_log (observed) = ln(mass),  with mass: parameter, units "kg"
    // — and `tests/invalid/expected_errors.json` pins it as a structural
    // `unit_inconsistency` error that this binding is required to emit.
    //
    // No dimensional checker can accept the first and reject the second: they
    // are dimensionally identical. One of the two fixtures is wrong, and it is
    // the VALID one — log of a dimensional quantity is meaningless physics (the
    // author omitted a reference volume, cf. units_propagation.esm, which
    // correctly writes `log(V / (n * 0.0224))`).
    //
    // Resolving this requires editing the shared corpus, which this binding does
    // not own. Until then we honour the pinned *invalid* contract (the sharper
    // one) and leave the valid fixture failing rather than silently downgrading
    // the log-argument rule, which would let units_invalid_logarithm.esm pass.
    // See `checkDimensions`' transcendental arm.

    for (const fname of fixtures) {
      it(`finds no dimensional inconsistency in ${fname}`, () => {
        const content = readFixture('valid', fname)
        const file = load(content) as EsmFile
        expect(file.models).toBeDefined()
        expect(Object.keys(file.models ?? {}).length).toBeGreaterThan(0)

        const warnings = validateUnits(file)
        const mismatches = warnings.filter((w) => w.code === 'dimensional_mismatch')
        expect(mismatches.map((w) => `${w.code} @ ${w.location ?? '?'}: ${w.message}`)).toEqual([])
      })

      it(`validate() accepts ${fname}`, () => {
        const result = validate(readFixture('valid', fname))
        expect(result.structural_errors.map((e) => `[${e.code}] ${e.path}: ${e.message}`)).toEqual(
          [],
        )
        expect(result.is_valid).toBe(true)
      })
    }
  })

  // T4: unit findings ARE hard errors in TS (the shared corpus pins every
  // units_*.esm fixture as `is_valid: false`), but they must carry the pinned
  // CODE and the pinned PATH — `unit_inconsistency` at the equation / variable,
  // not `unit_error` at the enclosing model.
  describe('unit errors use the corpus-pinned code and path (T4)', () => {
    it('reports an inconsistent equation at /models/<M>/equations/<i>', () => {
      const result = validate(readFixture('invalid', 'units_incompatible_assignment.esm'))
      expect(result.is_valid).toBe(false)
      expect(
        result.structural_errors.some(
          (e) => e.code === 'unit_inconsistency' && e.path === '/models/BadUnitsModel/equations/0',
        ),
      ).toBe(true)
    })

    it('reports an inconsistent observed variable at /models/<M>/variables/<v>', () => {
      const result = validate(readFixture('invalid', 'units_inconsistent_addition.esm'))
      expect(result.is_valid).toBe(false)
      expect(
        result.structural_errors.some(
          (e) =>
            e.code === 'unit_inconsistency' &&
            e.path === '/models/BadUnitsModel/variables/invalid_sum',
        ),
      ).toBe(true)
    })

    it('rejects a dimensional logarithm argument', () => {
      // Previously hard-quarantined in conformance.test.ts's
      // PENDING_BINDING_PHASE: TS returned is_valid:true for a fixture the
      // corpus pins invalid.
      const result = validate(readFixture('invalid', 'units_invalid_logarithm.esm'))
      expect(result.is_valid).toBe(false)
      expect(
        result.structural_errors.some(
          (e) =>
            e.code === 'unit_inconsistency' &&
            e.path === '/models/BadUnitsModel/variables/invalid_log',
        ),
      ).toBe(true)
    })
  })
})
