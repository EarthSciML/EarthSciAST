import { describe, it, expect, vi, afterEach } from 'vitest'
import { load, save, ParseError, SchemaValidationError, validateSchema } from './index.js'
import { isNumericLiteral, isIntLit, isFloatLit } from './numeric-literal.js'
import type { Model } from './types.js'

describe('Parse and Serialize', () => {
  const validMinimalEsm = {
    esm: '0.1.0',
    metadata: {
      name: 'test-model',
    },
    models: {
      test_model: {
        variables: {},
        equations: [],
      },
    },
  }

  const validMinimalEsmJson = JSON.stringify(validMinimalEsm, null, 2)

  describe('load()', () => {
    it('should parse valid JSON string', () => {
      const result = load(validMinimalEsmJson)
      expect(result.esm).toBe('0.1.0')
      expect(result.metadata.name).toBe('test-model')
    })

    it('should accept pre-parsed object', () => {
      const result = load(validMinimalEsm)
      expect(result.esm).toBe('0.1.0')
      expect(result.metadata.name).toBe('test-model')
    })

    it('should throw ParseError on invalid JSON', () => {
      expect(() => {
        load('{ invalid json')
      }).toThrow(ParseError)
    })

    it('should throw SchemaValidationError on missing required fields', () => {
      const invalid = { esm: '0.1.0' } // missing metadata and models/reaction_systems
      expect(() => {
        load(invalid)
      }).toThrow(SchemaValidationError)
    })

    it('should throw SchemaValidationError on invalid version string', () => {
      const invalid = {
        ...validMinimalEsm,
        esm: 'not-a-version',
      }
      expect(() => {
        load(invalid)
      }).toThrow(SchemaValidationError)
    })

    it('should load forward-compatible minor version (0.2.0) without error', () => {
      const forwardCompat = {
        ...validMinimalEsm,
        esm: '0.2.0',
      }
      const result = load(forwardCompat)
      expect(result.esm).toBe('0.2.0')
    })

    it('should handle Expression union types', () => {
      const esmWithExpression = {
        esm: '0.1.0',
        metadata: { name: 'expr-test' },
        models: {
          test: {
            variables: {
              x: {
                type: 'state',
                units: 'kg/m3',
                description: 'concentration',
              },
              temperature: {
                type: 'parameter',
                units: 'K',
                default: 298.15,
              },
              result: {
                type: 'observed',
                expression: {
                  op: '+',
                  args: [42, 'temperature', { op: '*', args: [2, 'x'] }],
                },
              },
            },
            equations: [
              {
                lhs: 'D(x, t)',
                rhs: {
                  op: '+',
                  args: [42, 'temperature', { op: '*', args: [2, 'x'] }],
                },
              },
            ],
          },
        },
      }

      const result = load(esmWithExpression)
      const testModel = result.models?.['test'] as Model | undefined
      expect(testModel).toBeDefined()
      const observedVar = testModel?.variables['result']
      expect(observedVar).toBeDefined()
      expect(observedVar?.type).toBe('observed')
      expect(typeof observedVar?.expression).toBe('object')
      if (
        observedVar &&
        typeof observedVar.expression === 'object' &&
        observedVar.expression &&
        'op' in observedVar.expression
      ) {
        expect(observedVar.expression.op).toBe('+')
        expect(Array.isArray(observedVar.expression.args)).toBe(true)
        expect(observedVar.expression.args[0]).toBe(42) // number
        expect(observedVar.expression.args[1]).toBe('temperature') // string
        expect(typeof observedVar.expression.args[2]).toBe('object') // ExpressionNode
      }
    })

    it('should handle CouplingEntry discriminated unions', () => {
      const esmWithCoupling = {
        esm: '0.1.0',
        metadata: { name: 'coupling-test' },
        models: {
          model1: { variables: {}, equations: [] },
          model2: { variables: {}, equations: [] },
        },
        coupling: [
          {
            type: 'operator_compose',
            systems: ['model1', 'model2'],
          },
        ],
      }

      const result = load(esmWithCoupling)
      expect(result.coupling).toBeDefined()
      expect(result.coupling?.[0]?.type).toBe('operator_compose')
    })

    describe('auto-fire dimensional validation', () => {
      afterEach(() => {
        vi.restoreAllMocks()
      })

      it('should emit console.warn for dimensional mismatches', () => {
        const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

        const badDimensions = {
          esm: '0.1.0',
          metadata: { name: 'bad-dims' },
          models: {
            mech: {
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

        load(badDimensions)

        expect(warnSpy).toHaveBeenCalled()
        const messages = warnSpy.mock.calls.map((args) => String(args[0]))
        expect(messages.some((m) => m.includes('ESM unit validation'))).toBe(true)
        expect(messages.some((m) => m.includes('Dimensional mismatch'))).toBe(true)
      })

      it('should not warn when dimensions are consistent', () => {
        const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

        const goodDimensions = {
          esm: '0.1.0',
          metadata: { name: 'good-dims' },
          models: {
            mech: {
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

        load(goodDimensions)

        const unitCalls = warnSpy.mock.calls
          .map((args) => String(args[0]))
          .filter((m) => m.includes('ESM unit validation'))
        expect(unitCalls).toEqual([])
      })

      it('should include the location field in emitted messages', () => {
        const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

        const badDimensions = {
          esm: '0.1.0',
          metadata: { name: 'located' },
          models: {
            mech: {
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

        load(badDimensions)

        // The location is now the JSON Pointer of the offending EQUATION, not
        // the dotted name of the enclosing model — `validate()` uses it verbatim
        // as the structural error's `path`, and the shared corpus pins unit
        // errors at `/models/<M>/equations/<i>`.
        const messages = warnSpy.mock.calls.map((args) => String(args[0]))
        expect(messages.some((m) => m.includes('[/models/mech/equations/0]'))).toBe(true)
      })
    })

    describe('canonical-mode loading (gt-4cx3)', () => {
      const canonicalEsmJson = JSON.stringify({
        esm: '0.1.0',
        metadata: { name: 'canonical' },
        models: {
          m: {
            variables: {
              x: { type: 'state' },
              y: { type: 'parameter', default: 2 },
            },
            equations: [{ lhs: 'x', rhs: { op: '*', args: [2, 1.5] } }],
          },
        },
      })

      it('returns plain JS numbers by default (backwards compatible)', () => {
        const plain = load(canonicalEsmJson) as any
        const rhs = plain.models.m.equations[0].rhs
        expect(rhs.args[0]).toBe(2)
        expect(rhs.args[1]).toBe(1.5)
        expect(isNumericLiteral(rhs.args[0])).toBe(false)
        expect(isNumericLiteral(rhs.args[1])).toBe(false)
      })

      it('preserves int/float distinction under { canonical: true }', () => {
        const canon = load(canonicalEsmJson, { canonical: true }) as any
        const rhs = canon.models.m.equations[0].rhs
        expect(isNumericLiteral(rhs.args[0])).toBe(true)
        expect(isNumericLiteral(rhs.args[1])).toBe(true)
        expect(isIntLit(rhs.args[0])).toBe(true)
        expect(isFloatLit(rhs.args[1])).toBe(true)
        // underlying values still correct
        expect((rhs.args[0] as any).value).toBe(2)
        expect((rhs.args[1] as any).value).toBe(1.5)
      })

      it('canonical mode still validates against the schema', () => {
        const invalid = '{"esm":"0.1.0","metadata":{"name":"x"}}' // missing models/reaction_systems
        expect(() => load(invalid, { canonical: true })).toThrow(SchemaValidationError)
      })

      it('canonical mode rejects malformed JSON', () => {
        expect(() => load('{ not json', { canonical: true })).toThrow(ParseError)
      })

      it('canonical mode with object input strips NumericLiterals for validation', () => {
        // Pre-parsed plain object — canonical mode is a no-op here (no tagged
        // leaves to preserve), but load() should not error on the plain view.
        const obj = JSON.parse(canonicalEsmJson)
        const result = load(obj, { canonical: true }) as any
        expect(result.models.m.equations[0].rhs.args[0]).toBe(2)
      })
    })

    it('should handle optional vs required fields correctly', () => {
      const esmWithOptionalFields = {
        esm: '0.1.0',
        metadata: {
          name: 'optional-test',
          description: 'A test model',
          // authors field is absent (optional)
        },
        models: {
          test: {
            variables: {},
            equations: [],
          },
        },
      }

      const result = load(esmWithOptionalFields)
      expect(result.metadata.description).toBe('A test model')
      expect(result.metadata.authors).toBeUndefined()
    })
  })

  describe('save()', () => {
    it('should serialize EsmFile to formatted JSON string', () => {
      const result = save(validMinimalEsm as any)
      expect(typeof result).toBe('string')

      // Should be valid JSON
      const parsed = JSON.parse(result)
      expect(parsed.esm).toBe('0.1.0')
      expect(parsed.metadata.name).toBe('test-model')
    })

    it('should produce formatted output with proper indentation', () => {
      const result = save(validMinimalEsm as any)
      expect(result).toContain('{\n  "esm"')
      expect(result).toContain('  "metadata": {')
    })
  })

  describe('round-trip property', () => {
    it('should satisfy load(save(load(json))) === load(json)', () => {
      const original = load(validMinimalEsmJson)
      const serialized = save(original)
      const reloaded = load(serialized)

      // Objects should be deeply equal
      expect(reloaded).toEqual(original)
    })

    it('should handle complex structures in round-trip', () => {
      const complexEsm = {
        esm: '0.1.0',
        metadata: {
          name: 'complex-model',
          description: 'A complex test model',
          authors: ['Test Author'],
          license: 'MIT',
        },
        models: {
          atmospheric: {
            variables: {
              O3: { type: 'state', units: 'ppb', description: 'Ozone concentration' },
              NO2: {
                type: 'parameter',
                units: 'ppb',
                description: 'Nitrogen dioxide',
                default: 10.0,
              },
              k1: { type: 'parameter', default: 0.5 },
            },
            equations: [
              {
                lhs: 'D(O3, t)',
                rhs: { op: '*', args: [{ op: '+', args: ['k1', 0.1] }, 'NO2'] },
              },
            ],
          },
          surface: {
            variables: {},
            equations: [],
          },
        },
        coupling: [
          {
            type: 'operator_compose',
            systems: ['atmospheric', 'surface'],
          },
        ],
      }

      const first = load(complexEsm)
      const serialized = save(first)
      const second = load(serialized)

      expect(second).toEqual(first)
    })
  })

  describe('validateSchema()', () => {
    it('should return empty array for valid data', () => {
      const errors = validateSchema(validMinimalEsm)
      expect(errors).toEqual([])
    })

    it('should return error details for invalid data', () => {
      const invalid = { esm: 'invalid', metadata: {} }
      const errors = validateSchema(invalid)

      expect(errors.length).toBeGreaterThan(0)
      expect(errors[0]).toHaveProperty('path')
      expect(errors[0]).toHaveProperty('message')
      expect(errors[0]).toHaveProperty('keyword')
    })
  })

  describe('v0.5.0 inline multi-series y (plots.y array form)', () => {
    it('should accept array-form plots.y without schema error', () => {
      const esmWithArrayY = {
        esm: '0.5.0',
        metadata: { name: 'multi_y_test' },
        models: {
          AB: {
            variables: {
              A: { type: 'state', default: 1.0 },
              B: { type: 'state', default: 0.0 },
            },
            equations: [
              { lhs: { op: 'D', args: ['A'], wrt: 't' }, rhs: { op: '*', args: [-0.1, 'A'] } },
              { lhs: { op: 'D', args: ['B'], wrt: 't' }, rhs: { op: '*', args: [0.1, 'A'] } },
            ],
            examples: [
              {
                id: 'ab_trace',
                time_span: { start: 0.0, end: 10.0 },
                plots: [
                  {
                    id: 'ab_multi',
                    type: 'line',
                    x: { variable: 't' },
                    y: [
                      { variable: 'A', label: 'Species A' },
                      { variable: 'B', label: 'Species B' },
                    ],
                  },
                ],
              },
            ],
          },
        },
      }
      const errors = validateSchema(esmWithArrayY)
      expect(errors).toHaveLength(0)
    })
  })

  describe('error handling', () => {
    it('should preserve original error in ParseError', () => {
      try {
        load('{ invalid json }')
      } catch (error) {
        if (error instanceof ParseError) {
          expect(error.originalError).toBeDefined()
          expect(error.message).toContain('Invalid JSON')
        }
      }
    })

    it('should include validation errors in SchemaValidationError', () => {
      try {
        load({ invalid: 'data' })
      } catch (error) {
        if (error instanceof SchemaValidationError) {
          expect(error.errors).toBeDefined()
          expect(Array.isArray(error.errors)).toBe(true)
          expect(error.errors.length).toBeGreaterThan(0)
        }
      }
    })
  })
})
