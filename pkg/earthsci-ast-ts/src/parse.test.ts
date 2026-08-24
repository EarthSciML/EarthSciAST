import { describe, it, expect, vi, afterEach } from 'vitest'
import { loadString, loadDocument, toJson, ParseError, SchemaValidationError, validateSchema } from './index.js'
import { isNumericLiteral, isIntLit, isFloatLit } from './numeric-literal.js'
import { observedUnknowns, observedDefinitions } from './classification.js'
import type { Model } from './types.js'

describe('Parse and Serialize', () => {
  const validMinimalEsm = {
    esm: '1.0.0',
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

  describe('loadString()', () => {
    it('should parse valid JSON string', () => {
      const result = loadString(validMinimalEsmJson)
      expect(result.esm).toBe('1.0.0')
      expect(result.metadata.name).toBe('test-model')
    })

    it('should accept pre-parsed object', () => {
      const result = loadDocument(validMinimalEsm)
      expect(result.esm).toBe('1.0.0')
      expect(result.metadata.name).toBe('test-model')
    })

    it('should throw ParseError on invalid JSON', () => {
      expect(() => {
        loadString('{ invalid json')
      }).toThrow(ParseError)
    })

    it('should throw SchemaValidationError on missing required fields', () => {
      const invalid = { esm: '1.0.0' } // missing metadata and models/reaction_systems
      expect(() => {
        loadDocument(invalid)
      }).toThrow(SchemaValidationError)
    })

    it('should throw SchemaValidationError on invalid version string', () => {
      const invalid = {
        ...validMinimalEsm,
        esm: 'not-a-version',
      }
      expect(() => {
        loadDocument(invalid)
      }).toThrow(SchemaValidationError)
    })

    it('should loadString forward-compatible minor version (0.2.0) without error', () => {
      const forwardCompat = {
        ...validMinimalEsm,
        esm: '1.0.0',
      }
      const result = loadDocument(forwardCompat)
      expect(result.esm).toBe('1.0.0')
    })

    it('should handle Expression union types', () => {
      const esmWithExpression = {
        esm: '1.0.0',
        metadata: { name: 'expr-test' },
        models: {
          test: {
            variables: {
              x: {
                type: 'unknown',
                units: 'kg/m3',
                description: 'concentration',
              },
              temperature: {
                type: 'parameter',
                units: 'K',
                default: 298.15,
              },
              // An observed unknown. Its definition is the bare-LHS equation
              // below, not a field here.
              result: {
                type: 'unknown',
                units: 'kg/m3',
              },
            },
            equations: [
              {
                lhs: { op: 'D', args: ['x'], wrt: 't' },
                rhs: {
                  op: '+',
                  args: [42, 'temperature', { op: '*', args: [2, 'x'] }],
                },
              },
              {
                lhs: 'result',
                rhs: {
                  op: '+',
                  args: [42, 'temperature', { op: '*', args: [2, 'x'] }],
                },
              },
            ],
          },
        },
      }

      const result = loadDocument(esmWithExpression)
      const testModel = result.models?.['test'] as Model | undefined
      expect(testModel).toBeDefined()

      // `result` is an observed unknown: declared `unknown`, DERIVED as
      // observed from having a bare-variable equation LHS.
      const observedVar = testModel?.variables['result']
      expect(observedVar).toBeDefined()
      expect(observedVar?.type).toBe('unknown')
      expect(observedUnknowns(testModel!)).toEqual(['result'])

      // The Expression union — number | string | ExpressionNode — is exercised
      // by the operands of that defining equation.
      const definition = observedDefinitions(testModel!).get('result')
      expect(typeof definition).toBe('object')
      if (definition && typeof definition === 'object' && 'op' in definition) {
        expect(definition.op).toBe('+')
        expect(Array.isArray(definition.args)).toBe(true)
        expect(definition.args![0]).toBe(42) // number
        expect(definition.args![1]).toBe('temperature') // string
        expect(typeof definition.args![2]).toBe('object') // ExpressionNode
      }
    })

    it('should handle CouplingEntry discriminated unions', () => {
      const esmWithCoupling = {
        esm: '1.0.0',
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

      const result = loadDocument(esmWithCoupling)
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
          esm: '1.0.0',
          metadata: { name: 'bad-dims' },
          models: {
            mech: {
              variables: {
                x: { type: 'unknown', units: 'm', description: 'Position' },
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

        loadDocument(badDimensions)

        expect(warnSpy).toHaveBeenCalled()
        const messages = warnSpy.mock.calls.map((args) => String(args[0]))
        expect(messages.some((m) => m.includes('ESM unit validation'))).toBe(true)
        expect(messages.some((m) => m.includes('Dimensional mismatch'))).toBe(true)
      })

      it('should not warn when dimensions are consistent', () => {
        const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

        const goodDimensions = {
          esm: '1.0.0',
          metadata: { name: 'good-dims' },
          models: {
            mech: {
              variables: {
                x: { type: 'unknown', units: 'm', description: 'Position' },
                v: { type: 'unknown', units: 'm/s', description: 'Velocity' },
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

        loadDocument(goodDimensions)

        const unitCalls = warnSpy.mock.calls
          .map((args) => String(args[0]))
          .filter((m) => m.includes('ESM unit validation'))
        expect(unitCalls).toEqual([])
      })

      it('should include the location field in emitted messages', () => {
        const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

        const badDimensions = {
          esm: '1.0.0',
          metadata: { name: 'located' },
          models: {
            mech: {
              variables: {
                x: { type: 'unknown', units: 'm', description: 'Position' },
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

        loadDocument(badDimensions)

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
        esm: '1.0.0',
        metadata: { name: 'canonical' },
        models: {
          m: {
            variables: {
              x: { type: 'unknown' },
              y: { type: 'parameter', default: 2 },
            },
            equations: [{ lhs: 'x', rhs: { op: '*', args: [2, 1.5] } }],
          },
        },
      })

      it('returns plain JS numbers by default (backwards compatible)', () => {
        const plain = loadString(canonicalEsmJson) as any
        const rhs = plain.models.m.equations[0].rhs
        expect(rhs.args[0]).toBe(2)
        expect(rhs.args[1]).toBe(1.5)
        expect(isNumericLiteral(rhs.args[0])).toBe(false)
        expect(isNumericLiteral(rhs.args[1])).toBe(false)
      })

      it('preserves int/float distinction under { canonical: true }', () => {
        const canon = loadString(canonicalEsmJson, { canonical: true }) as any
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
        const invalid = '{"esm": "1.0.0","metadata":{"name":"x"}}' // missing models/reaction_systems
        expect(() => loadString(invalid, { canonical: true })).toThrow(SchemaValidationError)
      })

      it('canonical mode rejects malformed JSON', () => {
        expect(() => loadString('{ not json', { canonical: true })).toThrow(ParseError)
      })

      it('canonical mode with object input strips NumericLiterals for validation', () => {
        // Pre-parsed plain object — canonical mode is a no-op here (no tagged
        // leaves to preserve), but loadString() should not error on the plain view.
        const obj = JSON.parse(canonicalEsmJson)
        const result = loadString(obj, { canonical: true }) as any
        expect(result.models.m.equations[0].rhs.args[0]).toBe(2)
      })
    })

    it('should handle optional vs required fields correctly', () => {
      const esmWithOptionalFields = {
        esm: '1.0.0',
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

      const result = loadDocument(esmWithOptionalFields)
      expect(result.metadata.description).toBe('A test model')
      expect(result.metadata.authors).toBeUndefined()
    })
  })

  describe('toJson()', () => {
    it('should serialize EsmFile to formatted JSON string', () => {
      const result = toJson(validMinimalEsm as any)
      expect(typeof result).toBe('string')

      // Should be valid JSON
      const parsed = JSON.parse(result)
      expect(parsed.esm).toBe('1.0.0')
      expect(parsed.metadata.name).toBe('test-model')
    })

    it('should produce formatted output with proper indentation', () => {
      const result = toJson(validMinimalEsm as any)
      expect(result).toContain('{\n  "esm"')
      expect(result).toContain('  "metadata": {')
    })
  })

  describe('round-trip property', () => {
    it('should satisfy loadString(toJson(loadString(json))) === loadString(json)', () => {
      const original = loadString(validMinimalEsmJson)
      const serialized = toJson(original)
      const reloaded = loadString(serialized)

      // Objects should be deeply equal
      expect(reloaded).toEqual(original)
    })

    it('should handle complex structures in round-trip', () => {
      const complexEsm = {
        esm: '1.0.0',
        metadata: {
          name: 'complex-model',
          description: 'A complex test model',
          authors: ['Test Author'],
          license: 'MIT',
        },
        models: {
          atmospheric: {
            variables: {
              O3: { type: 'unknown', units: 'ppb', description: 'Ozone concentration' },
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

      const first = loadDocument(complexEsm)
      const serialized = toJson(first)
      const second = loadString(serialized)

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
        esm: '1.0.0',
        metadata: { name: 'multi_y_test' },
        models: {
          AB: {
            variables: {
              A: { type: 'unknown', default: 1.0 },
              B: { type: 'unknown', default: 0.0 },
            },
            equations: [
              { lhs: { op: 'D', args: ['A'], wrt: 't' }, rhs: { op: '*', args: [-0.1, 'A'] } },
              { lhs: { op: 'D', args: ['B'], wrt: 't' }, rhs: { op: '*', args: [0.1, 'A'] } },
            ],
            analyses: [
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
        loadString('{ invalid json }')
      } catch (error) {
        if (error instanceof ParseError) {
          expect(error.originalError).toBeDefined()
          expect(error.message).toContain('Invalid JSON')
        }
      }
    })

    it('should include validation errors in SchemaValidationError', () => {
      try {
        loadDocument({ invalid: 'data' })
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
