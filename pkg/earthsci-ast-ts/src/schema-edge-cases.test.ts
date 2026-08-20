import { describe, it, expect } from 'vitest'
import { validateSchema, load, SchemaValidationError, ParseError } from './index.js'
import type { Model, ReactionSystem } from './types.js'

describe('Schema Edge Cases', () => {
  describe('anyOf constraint: models OR reaction_systems required', () => {
    it('should fail when neither models nor reaction_systems are present', () => {
      const invalid = {
        esm: '1.0.0',
        metadata: { name: 'test' },
        // Missing both models AND reaction_systems
      }

      const errors = validateSchema(invalid)
      expect(errors.length).toBeGreaterThan(0)

      // Should also throw when using load()
      expect(() => load(invalid)).toThrow(SchemaValidationError)
    })

    it('should pass with only models', () => {
      const withModels = {
        esm: '1.0.0',
        metadata: { name: 'test' },
        models: {
          test_model: {
            variables: {},
            equations: [],
          },
        },
      }

      const errors = validateSchema(withModels)
      expect(errors).toEqual([])

      // Should not throw when using load()
      const result = load(withModels)
      expect(result.esm).toBe('1.0.0')
    })

    it('should pass with only reaction_systems', () => {
      const withReactionSystems = {
        esm: '1.0.0',
        metadata: { name: 'test' },
        reaction_systems: {
          test_rs: {
            species: {},
            parameters: {},
            reactions: [{ id: 'R1', substrates: null, products: null, rate: 1.0 }],
          },
        },
      }

      const errors = validateSchema(withReactionSystems)
      expect(errors).toEqual([])

      // Should not throw when using load()
      const result = load(withReactionSystems)
      expect(result.esm).toBe('1.0.0')
    })

    it('should pass with only data_sources (source-only file)', () => {
      // RFC pure-io-data-loaders §4.3: a document whose sole content is the
      // data registry (no models, no reaction_systems) is valid and must load.
      // From 1.0.0 the registry is `data_sources` and an entry declares NO
      // `variables` of its own — a source is ingest configuration, not a
      // component, so it exposes nothing and is not a coupling endpoint. A
      // consuming parameter names it through `update.source`.
      const sourceOnly = {
        esm: '1.0.0',
        metadata: { name: 'test' },
        data_sources: {
          weather: {
            kind: 'grid',
            source: { url_template: '/data/weather_{date:%Y%m%d}.nc' },
          },
        },
      }

      const errors = validateSchema(sourceOnly)
      expect(errors).toEqual([])

      // Should not throw when using load()
      const result = load(sourceOnly)
      expect(result.esm).toBe('1.0.0')
      expect(result.data_sources?.['weather']?.kind).toBe('grid')
    })

    it('should reject a data source that declares variables (1.0.0 clean break)', () => {
      // The 0.x loader carried a `variables` map (file_variable + units per
      // exposed name). 1.0.0 moved both onto the consuming parameter, and
      // DataSource is additionalProperties:false — so a document still carrying
      // the old shape must fail loudly rather than have the map ignored.
      const withLoaderVariables = {
        esm: '1.0.0',
        metadata: { name: 'test' },
        data_sources: {
          weather: {
            kind: 'grid',
            source: { url_template: '/data/weather_{date:%Y%m%d}.nc' },
            variables: {
              temp: { file_variable: 'T2', units: 'K', description: 'Temperature' },
            },
          },
        },
      }

      const errors = validateSchema(withLoaderVariables)
      expect(errors.some((error) => error.keyword === 'additionalProperties')).toBe(true)
      expect(() => load(withLoaderVariables)).toThrow(SchemaValidationError)
    })

    it('should pass with both models and reaction_systems', () => {
      const withBoth = {
        esm: '1.0.0',
        metadata: { name: 'test' },
        models: {
          test_model: {
            variables: {},
            equations: [],
          },
        },
        reaction_systems: {
          test_rs: {
            species: {},
            parameters: {},
            reactions: [{ id: 'R1', substrates: null, products: null, rate: 1.0 }],
          },
        },
      }

      const errors = validateSchema(withBoth)
      expect(errors).toEqual([])

      // Should not throw when using load()
      const result = load(withBoth)
      expect(result.esm).toBe('1.0.0')
    })
  })

  describe('deeply nested expression trees', () => {
    it('should handle deeply nested expressions', () => {
      // Create a deeply nested binary expression tree: ((((a+b)+c)+d)+e)
      let deepExpression: any = 'a'
      for (let i = 0; i < 50; i++) {
        deepExpression = {
          op: '+',
          args: [deepExpression, `var_${i}`],
        }
      }

      // From 1.0.0 an expression of any depth is carried by an EQUATION: there
      // is no `variables.*.expression` sidecar to hang one on, and the observed
      // quantity is an ordinary unknown whose bare-LHS equation defines it.
      const validDeepNested = {
        esm: '1.0.0',
        metadata: { name: 'deep_test' },
        models: {
          deep_model: {
            variables: {
              deep_observed: { type: 'unknown' },
            },
            equations: [{ lhs: 'deep_observed', rhs: deepExpression }],
          },
        },
      }

      const errors = validateSchema(validDeepNested)
      expect(errors).toEqual([])

      // Should also work with load()
      const result = load(validDeepNested)
      expect(result.esm).toBe('1.0.0')
    })

    it('should handle nested expression with multiple operators', () => {
      const complexExpression = {
        op: '*',
        args: [
          {
            op: '+',
            args: [
              {
                op: 'sin',
                args: ['x'],
              },
              {
                op: 'exp',
                args: [
                  {
                    op: '/',
                    args: ['y', 2.0],
                  },
                ],
              },
            ],
          },
          {
            op: 'sqrt',
            args: [
              {
                op: 'abs',
                args: ['z'],
              },
            ],
          },
        ],
      }

      const validComplexNested = {
        esm: '1.0.0',
        metadata: { name: 'complex_test' },
        models: {
          complex_model: {
            variables: {
              complex_observed: { type: 'unknown' },
            },
            equations: [{ lhs: 'complex_observed', rhs: complexExpression }],
          },
        },
      }

      const errors = validateSchema(validComplexNested)
      expect(errors).toEqual([])
    })

    it('accepts an unknown-but-well-formed operator (open op namespace, esm-spec §4.2)', () => {
      // 0.8.0 opened the `op` namespace (open-op-namespace-fixpoint-rewrite RFC):
      // the enum is gone; the schema keeps only a permissive minLength+pattern.
      // An unknown identifier op is a legal rewrite-target string at schema time
      // — the typo-catch moved to the `unlowered_operator` evaluation gate.
      const openOp = {
        esm: '1.0.0',
        metadata: { name: 'open_op_test' },
        models: {
          m: {
            variables: {
              obs: { type: 'unknown', units: '1' },
            },
            equations: [{ lhs: 'obs', rhs: { op: 'godunov_hamiltonian', args: ['x', 'y'] } }],
          },
        },
      }

      const errors = validateSchema(openOp)
      // No enum keyword any more, and the well-formed op passes validation.
      expect(errors.find((error) => error.keyword === 'enum')).toBeUndefined()
      expect(errors).toEqual([])
      // Loading is permissive — the open-tier op survives to (deferred) evaluation.
      expect(() => load(openOp)).not.toThrow()

      // A MALFORMED op string (violates the op `pattern`) is still rejected.
      const malformed = JSON.parse(JSON.stringify(openOp))
      malformed.models.m.equations[0].rhs.op = '9 bad op!'
      expect(validateSchema(malformed).length).toBeGreaterThan(0)
    })
  })

  describe('scientific notation and extreme numbers', () => {
    it('should handle very large numbers in scientific notation', () => {
      const validLargeNumbers = {
        esm: '1.0.0',
        metadata: { name: 'large_numbers_test' },
        models: {
          large_model: {
            variables: {
              large_param: {
                type: 'parameter',
                default: 1.23e50,
              },
              very_small_param: {
                type: 'parameter',
                default: 1.23e-50,
              },
              avogadro: {
                type: 'parameter',
                default: 6.022140857e23,
              },
            },
            equations: [],
          },
        },
      }

      const errors = validateSchema(validLargeNumbers)
      expect(errors).toEqual([])

      const result = load(validLargeNumbers)
      expect((result.models?.['large_model'] as Model).variables?.['avogadro']?.default).toBe(
        6.022140857e23,
      )
    })

    it('should handle edge case numeric values', () => {
      const edgeCaseNumbers = {
        esm: '1.0.0',
        metadata: { name: 'edge_numbers_test' },
        models: {
          edge_model: {
            variables: {
              zero: { type: 'parameter', default: 0 },
              negative_zero: { type: 'parameter', default: -0 },
              positive_infinity: { type: 'parameter', default: Number.POSITIVE_INFINITY },
              negative_infinity: { type: 'parameter', default: Number.NEGATIVE_INFINITY },
              max_safe_integer: { type: 'parameter', default: Number.MAX_SAFE_INTEGER },
              min_safe_integer: { type: 'parameter', default: Number.MIN_SAFE_INTEGER },
              epsilon: { type: 'parameter', default: Number.EPSILON },
            },
            equations: [],
          },
        },
      }

      const errors = validateSchema(edgeCaseNumbers)
      expect(errors).toEqual([])

      const result = load(edgeCaseNumbers)
      expect(
        (result.models?.['edge_model'] as Model).variables?.['max_safe_integer']?.default,
      ).toBe(Number.MAX_SAFE_INTEGER)
    })

    it('should handle numeric expressions with extreme values', () => {
      const extremeExpression = {
        op: '*',
        args: [1e100, 1e-100],
      }

      const validExtremeExpr = {
        esm: '1.0.0',
        metadata: { name: 'extreme_expr_test' },
        models: {
          extreme_model: {
            variables: {
              extreme_observed: { type: 'unknown' },
            },
            equations: [{ lhs: 'extreme_observed', rhs: extremeExpression }],
          },
        },
      }

      const errors = validateSchema(validExtremeExpr)
      expect(errors).toEqual([])
    })
  })

  describe('unicode characters in variable names', () => {
    it('should allow unicode characters in variable names', () => {
      const unicodeVariables = {
        esm: '1.0.0',
        metadata: { name: 'unicode_test' },
        models: {
          unicode_model: {
            variables: {
              température: { type: 'parameter', default: 298.15, units: 'K' },
              концентрация: { type: 'unknown', units: 'mol/L' },
              压力: { type: 'parameter', default: 101325, units: 'Pa' },
              ρ_air: { type: 'parameter', default: 1.225, units: 'kg/m³' },
              Δt: { type: 'parameter', default: 0.01, units: 's' },
              α_mixing: { type: 'parameter', default: 1.0 },
              'β₁': { type: 'parameter', default: 0.5 },
              'γ²': { type: 'parameter', default: 2.0 },
            },
            // The one unknown gets its equation, so the document is balanced as
            // well as schema-valid — and the unicode name is exercised in an
            // equation position too, not only as a `variables` key.
            equations: [{ lhs: { op: 'D', args: ['концентрация'], wrt: 't' }, rhs: 0 }],
          },
        },
      }

      const errors = validateSchema(unicodeVariables)
      expect(errors).toEqual([])

      const result = load(unicodeVariables)
      expect((result.models?.['unicode_model'] as Model).variables?.['température']?.default).toBe(
        298.15,
      )
      expect((result.models?.['unicode_model'] as Model).variables?.['β₁']?.default).toBe(0.5)
    })

    it('should allow unicode characters in reaction species names', () => {
      const unicodeReaction = {
        esm: '1.0.0',
        metadata: { name: 'unicode_reaction_test' },
        reaction_systems: {
          unicode_rs: {
            species: {
              'CO₂': { units: 'mol/L', default: 0.0 },
              'H₂O': { units: 'mol/L', default: 55.6 },
              '•OH': { units: 'mol/L', default: 1e-12 },
              'NO₃⁻': { units: 'mol/L', default: 0.0 },
            },
            parameters: {
              'k₁': { default: 1e-9, units: 'L/(mol·s)' },
            },
            reactions: [
              {
                id: 'R1',
                substrates: [{ species: 'CO₂', stoichiometry: 1 }],
                products: [{ species: 'H₂O', stoichiometry: 1 }],
                rate: 'k₁',
              },
            ],
          },
        },
      }

      const errors = validateSchema(unicodeReaction)
      expect(errors).toEqual([])

      const result = load(unicodeReaction)
      expect(
        (result.reaction_systems?.['unicode_rs'] as ReactionSystem).species?.['CO₂']?.default,
      ).toBe(0.0)
    })

    it('should allow unicode in metadata and descriptions', () => {
      const unicodeMetadata = {
        esm: '1.0.0',
        metadata: {
          name: 'test_模型',
          description: '这是一个测试模型 with émissions atmosphériques',
          authors: ['José María González', '李小明', 'Владимир Петров'],
          tags: ['大气化学', 'émissions', 'климат'],
        },
        models: {
          test: {
            variables: {},
            equations: [],
          },
        },
      }

      const errors = validateSchema(unicodeMetadata)
      expect(errors).toEqual([])

      const result = load(unicodeMetadata)
      expect(result.metadata.description).toContain('émissions')
      expect(result.metadata.authors?.[1]).toBe('李小明')
    })
  })

  describe('empty and null field handling', () => {
    it('should handle empty objects and arrays', () => {
      const emptyFields = {
        esm: '1.0.0',
        metadata: {
          name: 'empty_test',
          authors: [], // Empty array should be valid
          tags: [],
        },
        models: {
          empty_model: {
            variables: {}, // Empty object should be valid
            equations: [], // Empty array should be valid
          },
        },
      }

      const errors = validateSchema(emptyFields)
      expect(errors).toEqual([])

      const result = load(emptyFields)
      expect(result.metadata.authors).toEqual([])
      expect((result.models?.['empty_model'] as Model).equations).toEqual([])
    })

    it('should handle null values where allowed', () => {
      const nullFields = {
        esm: '1.0.0',
        metadata: { name: 'null_test' },
        reaction_systems: {
          null_rs: {
            species: { X: {} },
            parameters: { k: { default: 1.0 } },
            reactions: [
              {
                id: 'R1',
                substrates: null, // Source reaction: ∅ → X
                products: [{ species: 'X', stoichiometry: 1 }],
                rate: 'k',
              },
              {
                id: 'R2',
                substrates: [{ species: 'X', stoichiometry: 1 }],
                products: null, // Sink reaction: X → ∅
                rate: 'k',
              },
            ],
          },
        },
      }

      const errors = validateSchema(nullFields)
      expect(errors).toEqual([])

      const result = load(nullFields)
      expect(
        (result.reaction_systems?.['null_rs'] as ReactionSystem).reactions[0].substrates,
      ).toBeNull()
      expect(
        (result.reaction_systems?.['null_rs'] as ReactionSystem).reactions[1].products,
      ).toBeNull()
    })

    it('should reject the removed coupletype field (0.8.0 clean break)', () => {
      // coupletype was removed in 0.8.0; Model is additionalProperties:false, so
      // a document still carrying it must fail schema validation loudly. The
      // document declares the CURRENT version so the rejection is provably the
      // stray field and not the version gate.
      const withCoupletype = {
        esm: '1.0.0',
        metadata: { name: 'coupletype_removed_test' },
        models: {
          test_model: {
            coupletype: null,
            variables: {},
            equations: [],
          },
        },
      }

      const errors = validateSchema(withCoupletype)
      expect(errors.length).toBeGreaterThan(0)
      expect(errors.some((error) => error.keyword === 'additionalProperties')).toBe(true)
    })

    it('should fail when required fields are null', () => {
      const invalidNull = {
        esm: '1.0.0',
        metadata: { name: null }, // name is required, cannot be null
        models: {
          test: {
            variables: {},
            equations: [],
          },
        },
      }

      const errors = validateSchema(invalidNull)
      expect(errors.length).toBeGreaterThan(0)

      // Should find a type error for name field
      const typeError = errors.find(
        (error) => error.path.includes('name') && error.keyword === 'type',
      )
      expect(typeError).toBeDefined()

      expect(() => load(invalidNull)).toThrow(SchemaValidationError)
    })
  })

  describe('additional properties validation', () => {
    it('should fail with additional properties at root level', () => {
      const extraProps = {
        esm: '1.0.0',
        metadata: { name: 'test' },
        models: {
          test: {
            variables: {},
            equations: [],
          },
        },
        unexpected_field: 'should not be allowed', // This violates additionalProperties: false
      }

      const errors = validateSchema(extraProps)
      expect(errors.length).toBeGreaterThan(0)

      // Should find additionalProperties error
      const additionalPropsError = errors.find((error) => error.keyword === 'additionalProperties')
      expect(additionalPropsError).toBeDefined()

      expect(() => load(extraProps)).toThrow(SchemaValidationError)
    })

    it('should fail with additional properties in metadata', () => {
      const extraMetadata = {
        esm: '1.0.0',
        metadata: {
          name: 'test',
          unknown_metadata: 'not allowed', // additionalProperties: false in Metadata
        },
        models: {
          test: {
            variables: {},
            equations: [],
          },
        },
      }

      const errors = validateSchema(extraMetadata)
      expect(errors.length).toBeGreaterThan(0)

      const additionalPropsError = errors.find(
        (error) => error.keyword === 'additionalProperties' && error.path.includes('metadata'),
      )
      expect(additionalPropsError).toBeDefined()

      expect(() => load(extraMetadata)).toThrow(SchemaValidationError)
    })

    it('should fail with additional properties in ExpressionNode', () => {
      const extraExprProps = {
        esm: '1.0.0',
        metadata: { name: 'test' },
        models: {
          test: {
            variables: {
              bad_expr: { type: 'unknown' },
            },
            equations: [
              {
                lhs: 'bad_expr',
                rhs: {
                  op: '+',
                  args: ['x', 'y'],
                  extra_field: 'not allowed', // ExpressionNode has additionalProperties: false
                },
              },
            ],
          },
        },
      }

      const errors = validateSchema(extraExprProps)
      expect(errors.length).toBeGreaterThan(0)

      const additionalPropsError = errors.find((error) => error.keyword === 'additionalProperties')
      expect(additionalPropsError).toBeDefined()

      expect(() => load(extraExprProps)).toThrow(SchemaValidationError)
    })

    it('should allow additional properties in data source metadata', () => {
      const configProps = {
        esm: '1.0.0',
        metadata: { name: 'test' },
        models: {
          test: {
            variables: {},
            equations: [],
          },
        },
        data_sources: {
          test_source: {
            kind: 'grid',
            source: { url_template: '/data/weather_{date:%Y%m%d}.nc' },
            metadata: {
              // data source metadata has additionalProperties: true
              tags: ['reanalysis'],
              custom_setting: 'allowed',
              another_setting: 42,
              nested_config: {
                deeply: {
                  nested: 'also allowed',
                },
              },
            },
          },
        },
      }

      const errors = validateSchema(configProps)
      expect(errors).toEqual([])

      const result = load(configProps)
      const source = result.data_sources?.['test_source']
      const metadata = source?.metadata as Record<string, unknown> | undefined
      expect(metadata?.['custom_setting']).toBe('allowed')
    })
  })

  describe('schema evolution compatibility', () => {
    // These three are deliberately VERSION-GATING tests, so the version each
    // one declares is the thing under test rather than boilerplate. The library
    // now implements major version 1: a differing MINOR still loads (with a
    // forward-compatibility warning), a differing MAJOR is refused — which, with
    // 1.0.0 being a clean break, puts the whole 0.x line on the refused side.
    const captureWarnings = <T>(fn: () => T): { result: T; warnings: string[] } => {
      const warnings: string[] = []
      const originalWarn = console.warn
      console.warn = (...args: unknown[]) => {
        warnings.push(args.join(' '))
      }
      try {
        return { result: fn(), warnings }
      } finally {
        console.warn = originalWarn
      }
    }

    it('should handle version compatibility for minor version differences', () => {
      const minorVersionUpgrade = {
        esm: '1.1.0', // Minor version upgrade within the supported major.
        metadata: { name: 'test' },
        models: {
          test: {
            variables: {},
            equations: [],
          },
        },
      }

      // The `esm` field is now constrained by a semver PATTERN alone, so a
      // newer minor is schema-clean; only the major gate can reject a version.
      const errors = validateSchema(minorVersionUpgrade)
      expect(errors.length).toBe(0)

      // Load succeeds, with a forward-compatibility warning.
      const { result, warnings } = captureWarnings(() => load(minorVersionUpgrade))
      expect(result.esm).toBe('1.1.0')
      expect(result.metadata.name).toBe('test')
      expect(warnings.some((w) => w.includes('newer than'))).toBe(true)
    })

    it('should reject major version mismatches', () => {
      const majorVersionUpgrade = {
        esm: '2.0.0', // Major version mismatch - should be rejected
        metadata: { name: 'test' },
        models: {
          test: {
            variables: {},
            equations: [],
          },
        },
      }

      // Schema validation reports the major-version mismatch ahead of AJV.
      const errors = validateSchema(majorVersionUpgrade)
      expect(errors.length).toBeGreaterThan(0)
      expect(errors[0].keyword).toBe('major_version_mismatch')

      // Load function should also reject due to major version mismatch
      expect(() => load(majorVersionUpgrade)).toThrow(ParseError)
      expect(() => load(majorVersionUpgrade)).toThrow('Unsupported major version 2')

      // A 0.x document is refused the same way: 1.0.0 has no deprecation path.
      const legacy = { ...majorVersionUpgrade, esm: '0.8.0' }
      expect(validateSchema(legacy)[0]?.keyword).toBe('major_version_mismatch')
      expect(() => load(legacy)).toThrow('Unsupported major version 0')
    })

    it('should fail with invalid version format', () => {
      const invalidVersionFormat = {
        esm: '1.0', // Invalid semver format (missing patch version)
        metadata: { name: 'test' },
        models: {
          test: {
            variables: {},
            equations: [],
          },
        },
      }

      const errors = validateSchema(invalidVersionFormat)
      expect(errors.length).toBeGreaterThan(0)

      // The `esm` field carries a semver `pattern`; a malformed string cannot
      // even be parsed into a version, so it never reaches the major gate.
      const patternError = errors.find(
        (error) =>
          error.keyword === 'pattern' || error.keyword === 'const' || error.keyword === 'enum',
      )
      expect(patternError).toBeDefined()

      expect(() => load(invalidVersionFormat)).toThrow(SchemaValidationError)
    })

    it('should validate ISO 8601 datetime formats', () => {
      const validDates = {
        esm: '1.0.0',
        metadata: {
          name: 'datetime_test',
          created: '2024-01-15T10:30:00Z',
          modified: '2024-01-15T10:30:00.123Z',
        },
        models: {
          test: {
            variables: {},
            equations: [],
          },
        },
      }

      const errors = validateSchema(validDates)
      expect(errors).toEqual([])

      const result = load(validDates)
      expect(result.metadata.created).toBe('2024-01-15T10:30:00Z')
    })

    it('should fail with invalid datetime formats', () => {
      const invalidDate = {
        esm: '1.0.0',
        metadata: {
          name: 'bad_datetime_test',
          created: '2024-13-15T25:30:00Z', // Invalid month and hour
        },
        models: {
          test: {
            variables: {},
            equations: [],
          },
        },
      }

      const errors = validateSchema(invalidDate)
      expect(errors.length).toBeGreaterThan(0)

      // Should find format or anyOf validation error for the invalid date
      const dateError = errors.find(
        (error) => error.keyword === 'format' || error.keyword === 'anyOf',
      )
      expect(dateError).toBeDefined()

      expect(() => load(invalidDate)).toThrow(SchemaValidationError)
    })

    it('should validate URI formats', () => {
      const validURI = {
        esm: '1.0.0',
        metadata: {
          name: 'uri_test',
          references: [
            {
              url: 'https://example.com/paper',
              doi: '10.1000/182',
              citation: 'Test paper',
            },
          ],
        },
        models: {
          test: {
            variables: {},
            equations: [],
          },
        },
      }

      const errors = validateSchema(validURI)
      expect(errors).toEqual([])
    })

    it('should fail with invalid URI formats', () => {
      const invalidURI = {
        esm: '1.0.0',
        metadata: {
          name: 'bad_uri_test',
          references: [
            {
              url: 'not-a-valid-uri', // Invalid URI format
              citation: 'Test paper',
            },
          ],
        },
        models: {
          test: {
            variables: {},
            equations: [],
          },
        },
      }

      const errors = validateSchema(invalidURI)
      expect(errors.length).toBeGreaterThan(0)

      // Should find format validation error
      const formatError = errors.find(
        (error) => error.keyword === 'format' && error.message?.includes('uri'),
      )
      expect(formatError).toBeDefined()

      expect(() => load(invalidURI)).toThrow(SchemaValidationError)
    })
  })

  /**
   * 0.x made an `observed` variable's `expression` schema-REQUIRED through a
   * conditional (`if type == "observed" then required: ["expression"]`). Both
   * halves of that rule are gone: `type` is now exactly `unknown | parameter`,
   * and a variable carries no `expression` at all — an unknown's behavior is
   * stated by the model's `equations` and nowhere else.
   *
   * A removed field is only really removed if the schema REFUSES it, so what
   * used to be "the conditional fires" is pinned here as "both spellings of the
   * old shape are rejected". ModelVariable is additionalProperties:false and
   * `type` is an enum, which is what makes the refusal loud instead of a silent
   * drop of a field the reader still believes is doing something.
   */
  describe('clean break: the removed `observed` type and `expression` field', () => {
    it('should reject the removed `observed` variable type', () => {
      const invalid = {
        esm: '1.0.0',
        metadata: { name: 'test' },
        models: {
          test: {
            variables: {
              bad_observed: {
                type: 'observed',
                expression: { op: '+', args: ['x', 'y'] },
              },
            },
            equations: [],
          },
        },
      }

      const errors = validateSchema(invalid)
      expect(errors.length).toBeGreaterThan(0)
      expect(
        errors.some((error) => error.path.includes('bad_observed') && error.keyword === 'enum'),
      ).toBe(true)

      expect(() => load(invalid)).toThrow(SchemaValidationError)
    })

    it('should reject an `expression` field on a variable of a valid type', () => {
      // The likelier 0.x residue: the type was migrated to `unknown` but the
      // expression sidecar was left behind. Silently ignoring it would keep the
      // document loading while the equation it describes goes missing.
      const invalid = {
        esm: '1.0.0',
        metadata: { name: 'test' },
        models: {
          test: {
            variables: {
              leftover: {
                type: 'unknown',
                expression: { op: '+', args: ['x', 'y'] },
              },
            },
            equations: [],
          },
        },
      }

      const errors = validateSchema(invalid)
      expect(
        errors.some(
          (error) => error.path.includes('leftover') && error.keyword === 'additionalProperties',
        ),
      ).toBe(true)

      expect(() => load(invalid)).toThrow(SchemaValidationError)
    })

    it('should accept both 1.0.0 variable types, neither carrying an expression', () => {
      const valid = {
        esm: '1.0.0',
        metadata: { name: 'test' },
        models: {
          test: {
            variables: {
              unknown_var: {
                type: 'unknown',
                units: 'kg/m3',
              },
              param_var: {
                type: 'parameter',
                default: 1.0,
              },
            },
            // `unknown_var` is an observed unknown: what 0.x wrote as an
            // `expression` on the variable is this bare-LHS equation.
            equations: [{ lhs: 'unknown_var', rhs: { op: '+', args: ['x', 'y'] } }],
          },
        },
      }

      const errors = validateSchema(valid)
      expect(errors).toEqual([])

      const result = load(valid)
      expect(result.esm).toBe('1.0.0')
    })
  })
})
