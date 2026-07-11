/**
 * Tests for structural validation
 */

import { describe, it, expect } from 'vitest'
import { validate } from './validate.js'
import { readFixture } from './test-helpers.js'

describe('Structural validation', () => {
  it('should detect equation count mismatch', () => {
    const data = {
      esm: '0.1.0',
      metadata: { name: 'test' },
      models: {
        TestModel: {
          variables: {
            x: { type: 'state', default: 1.0 },
            y: { type: 'state', default: 2.0 },
          },
          equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 'y' }],
        },
      },
    }

    const result = validate(data)

    expect(result.is_valid).toBe(false)
    expect(result.structural_errors).toHaveLength(1)
    expect(result.structural_errors[0].code).toBe('equation_count_mismatch')
    expect(result.structural_errors[0].path).toBe('/models/TestModel')
    expect(result.structural_errors[0].details.missing_equations_for).toEqual(['y'])
    expect(result.unit_warnings).toBeDefined()
    expect(Array.isArray(result.unit_warnings)).toBe(true)
  })

  it('should detect undefined variable in equation', () => {
    const data = {
      esm: '0.1.0',
      metadata: { name: 'test' },
      models: {
        TestModel: {
          variables: {
            x: { type: 'state', default: 1.0 },
          },
          equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 'undefined_var' }],
        },
      },
    }

    const result = validate(data)

    expect(result.is_valid).toBe(false)
    expect(result.structural_errors.some((err) => err.code === 'undefined_variable')).toBe(true)
    expect(result.unit_warnings).toBeDefined()
    expect(Array.isArray(result.unit_warnings)).toBe(true)
  })

  it('should detect undefined system in coupling', () => {
    const data = {
      esm: '0.1.0',
      metadata: { name: 'test' },
      models: {
        TestModel: {
          variables: {
            x: { type: 'state', default: 1.0 },
          },
          equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 1.0 }],
        },
      },
      coupling: [
        {
          type: 'operator_compose',
          systems: ['TestModel', 'NonExistentModel'],
        },
      ],
    }

    const result = validate(data)

    expect(result.is_valid).toBe(false)
    expect(result.structural_errors.some((err) => err.code === 'undefined_system')).toBe(true)
    expect(result.unit_warnings).toBeDefined()
    expect(Array.isArray(result.unit_warnings)).toBe(true)
  })

  it('should detect null reaction', () => {
    const data = {
      esm: '0.1.0',
      metadata: { name: 'test' },
      reaction_systems: {
        TestSystem: {
          species: {
            A: { default: 1.0 },
          },
          parameters: {
            k: { default: 0.1 },
          },
          reactions: [
            {
              id: 'R1',
              substrates: null,
              products: null,
              rate: 'k',
            },
          ],
        },
      },
    }

    const result = validate(data)

    expect(result.is_valid).toBe(false)
    expect(result.structural_errors.some((err) => err.code === 'null_reaction')).toBe(true)
    expect(result.unit_warnings).toBeDefined()
    expect(Array.isArray(result.unit_warnings)).toBe(true)
  })

  it('should detect undefined species in reaction', () => {
    const data = {
      esm: '0.1.0',
      metadata: { name: 'test' },
      reaction_systems: {
        TestSystem: {
          species: {
            A: { default: 1.0 },
          },
          parameters: {
            k: { default: 0.1 },
          },
          reactions: [
            {
              id: 'R1',
              substrates: [{ species: 'B', stoichiometry: 1 }], // B not declared
              products: [{ species: 'A', stoichiometry: 1 }],
              rate: 'k',
            },
          ],
        },
      },
    }

    const result = validate(data)

    expect(result.is_valid).toBe(false)
    expect(result.structural_errors.some((err) => err.code === 'undefined_species')).toBe(true)
    expect(result.unit_warnings).toBeDefined()
    expect(Array.isArray(result.unit_warnings)).toBe(true)
  })

  it('should pass validation for valid data', () => {
    const data = {
      esm: '0.1.0',
      metadata: { name: 'test' },
      models: {
        TestModel: {
          variables: {
            x: { type: 'state', default: 1.0 },
            y: { type: 'parameter', default: 2.0 },
          },
          equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 'y' }],
        },
      },
    }

    const result = validate(data)

    expect(result.is_valid).toBe(true)
    expect(result.structural_errors).toHaveLength(0)
    expect(result.unit_warnings).toBeDefined()
    expect(Array.isArray(result.unit_warnings)).toBe(true)
  })

  it('should include unit_warnings field in ValidationResult', () => {
    const data = {
      esm: '0.1.0',
      metadata: { name: 'test' },
      models: {
        TestModel: {
          variables: {
            x: { type: 'state', default: 1.0 },
          },
          equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 1.0 }],
        },
      },
    }

    const result = validate(data)

    // Ensure the ValidationResult has all required fields per spec Section 3.4
    expect(result).toHaveProperty('is_valid')
    expect(result).toHaveProperty('schema_errors')
    expect(result).toHaveProperty('structural_errors')
    expect(result).toHaveProperty('unit_warnings')
    expect(Array.isArray(result.unit_warnings)).toBe(true)
  })

  it('rejects reaction rate with stoichiometry mismatch (unit_inconsistency)', () => {
    // 2nd-order A + B -> C with a 1st-order rate constant (1/s) —
    // the reference fixture for the cross-binding dimensional check.
    const data = {
      esm: '0.1.0',
      metadata: { name: 'BadReactions' },
      reaction_systems: {
        BadReactions: {
          species: {
            A: { units: 'mol/L', default: 1.0 },
            B: { units: 'mol/L', default: 1.0 },
            C: { units: 'mol/L', default: 0.0 },
          },
          parameters: {
            k: { units: '1/s', default: 0.1 },
          },
          reactions: [
            {
              id: 'R1',
              substrates: [
                { species: 'A', stoichiometry: 1 },
                { species: 'B', stoichiometry: 1 },
              ],
              products: [{ species: 'C', stoichiometry: 1 }],
              rate: 'k',
            },
          ],
        },
      },
    }

    const result = validate(data)

    expect(result.is_valid).toBe(false)
    const err = result.structural_errors.find((e) => e.code === 'unit_inconsistency')
    expect(err).toBeDefined()
    expect(err!.path).toBe('/reaction_systems/BadReactions/reactions/0')
    expect(err!.message).toBe(
      'Reaction rate expression has incompatible units for reaction stoichiometry',
    )
    expect(err!.details).toEqual({
      reaction_id: 'R1',
      rate_units: '1/s',
      expected_rate_units: 'L/(mol*s)',
      reaction_order: 2,
    })
  })

  it('accepts reaction rate with matching stoichiometry (2nd-order)', () => {
    // ESM rate fields hold the rate CONSTANT (dims = conc^(1-order)/time);
    // the integrator multiplies by substrate concentrations at evaluation
    // time. So a 2nd-order constant must carry L/mol/s ≡ L/(mol*s) dims.
    const data = {
      esm: '0.1.0',
      metadata: { name: 'GoodReactions' },
      reaction_systems: {
        GoodReactions: {
          species: {
            A: { units: 'mol/L', default: 1.0 },
            B: { units: 'mol/L', default: 1.0 },
            C: { units: 'mol/L', default: 0.0 },
          },
          parameters: {
            // L/mol/s equals L/(mol*s) dimensionally; the current parseUnit
            // does not accept parenthesized denominators so we use the
            // linear form.
            k: { units: 'L/mol/s', default: 0.1 },
          },
          reactions: [
            {
              id: 'R1',
              substrates: [
                { species: 'A', stoichiometry: 1 },
                { species: 'B', stoichiometry: 1 },
              ],
              products: [{ species: 'C', stoichiometry: 1 }],
              rate: 'k',
            },
          ],
        },
      },
    }

    const result = validate(data)
    expect(result.structural_errors.some((e) => e.code === 'unit_inconsistency')).toBe(false)
  })

  it('skips stoichiometry check when first substrate is dimensionless (mol/mol)', () => {
    // Atmospheric-chemistry convention: a 1/s rate constant with
    // mole-fraction species is well-formed because the rate expression
    // typically carries a number-density factor.
    const data = {
      esm: '0.1.0',
      metadata: { name: 'DimlessReactions' },
      reaction_systems: {
        DimlessReactions: {
          species: {
            A: { units: 'mol/mol', default: 1.0 },
            B: { units: 'mol/mol', default: 1.0 },
            C: { units: 'mol/mol', default: 0.0 },
          },
          parameters: {
            k: { units: '1/s', default: 0.1 },
          },
          reactions: [
            {
              id: 'R1',
              substrates: [
                { species: 'A', stoichiometry: 1 },
                { species: 'B', stoichiometry: 1 },
              ],
              products: [{ species: 'C', stoichiometry: 1 }],
              rate: 'k',
            },
          ],
        },
      },
    }

    const result = validate(data)
    expect(result.structural_errors.some((e) => e.code === 'unit_inconsistency')).toBe(false)
  })

  // units_dimensional_constant_error.esm declares the ideal gas constant 'R'
  // with units 'kcal/mol' — missing the temperature dimension (canonical is
  // 'J/(mol*K)'). Must be rejected as a structural unit_inconsistency error
  // at the usage site `gas_law_calculation` (mirrors Python's
  // parse._check_physical_constant_units, gt-3tgv).
  it('should reject units_dimensional_constant_error.esm with unit_inconsistency at usage site', () => {
    const content = readFixture('invalid', 'units_dimensional_constant_error.esm')
    const result = validate(content)
    expect(result.is_valid).toBe(false)
    const err = result.structural_errors.find(
      (e) =>
        e.code === 'unit_inconsistency' &&
        e.message === 'Physical constant used with incorrect dimensional analysis',
    )
    expect(err).toBeDefined()
    expect(err!.path).toBe('/models/ConstantUnitsModel/variables/gas_law_calculation')
    expect(err!.details.constant_name).toBe('R')
    expect(err!.details.constant_description).toBe('ideal gas constant')
    expect(err!.details.declared_units).toBe('kcal/mol')
    expect(err!.details.canonical_units).toBe('J/(mol*K)')
  })
})
describe('variable_map expression transforms (schema widening)', () => {
  const exprTransformFile = () => ({
    esm: '0.8.0',
    metadata: { name: 'vm_expr_transform' },
    models: {
      Src: {
        variables: { F: { type: 'state', default: 1.0 } },
        equations: [{ lhs: { op: 'D', args: ['F'], wrt: 't' }, rhs: 0 }],
      },
      Sink: {
        variables: { offset: { type: 'parameter', default: 0.5 } },
        equations: [],
      },
    },
    coupling: [
      {
        type: 'variable_map',
        from: 'Src.F',
        to: 'Sink.offset',
        transform: {
          op: '+',
          args: [{ op: '*', args: [2.0, 'Src.F'] }, 'Sink.offset'],
        },
      },
    ],
  })

  it('accepts an object (Expression) transform', () => {
    const result = validate(exprTransformFile())

    expect(result.schema_errors).toEqual([])
    expect(result.structural_errors).toEqual([])
    expect(result.is_valid).toBe(true)
  })

  it('rejects a non-enum bare string transform', () => {
    const data = exprTransformFile()
    ;(data.coupling[0] as any).transform = 'bogus_name'

    const result = validate(data)

    expect(result.is_valid).toBe(false)
    expect(result.schema_errors.length).toBeGreaterThan(0)
    expect(result.schema_errors.some((e) => e.path.includes('/coupling/0'))).toBe(true)
  })

  it('rejects factor alongside an Expression transform', () => {
    const data = exprTransformFile()
    ;(data.coupling[0] as any).factor = 2.0

    const result = validate(data)

    expect(result.is_valid).toBe(false)
    expect(result.schema_errors.length).toBeGreaterThan(0)
    expect(result.schema_errors.some((e) => e.path.includes('/coupling/0'))).toBe(true)
  })
})

describe('scoped-reference split keeps the full variable path (splitScopedRef)', () => {
  // Regression for the split('.', 2) truncation bug: a 3-segment
  // data-loader ref like "Weather.deep.path" must report the ENTIRE remainder
  // ("deep.path") as the missing variable, not the truncated first segment
  // ("deep"). Mirrors Go's strings.SplitN(from, ".", 2) remainder semantics.
  it('reports the whole dotted remainder for a 3-segment data-loader from-ref', () => {
    const data = {
      esm: '0.8.0',
      metadata: { name: 'split_scoped_ref' },
      models: {
        M: {
          variables: { x: { type: 'state', default: 0.0 } },
          equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 0 }],
        },
      },
      data_loaders: {
        Weather: {
          kind: 'grid',
          source: { url_template: '/data/weather_{date:%Y%m%d}.nc' },
          variables: {
            T: { file_variable: 'T2', units: 'K', description: 'Temperature' },
          },
        },
      },
      coupling: [
        {
          type: 'variable_map',
          from: 'Weather.deep.path',
          to: 'M.x',
          transform: 'param_to_var',
        },
      ],
    }

    const result = validate(data)

    expect(result.is_valid).toBe(false)
    const err = result.structural_errors.find(
      (e) => e.code === 'undefined_data_loader_variable',
    )
    expect(err).toBeDefined()
    expect(err!.path).toBe('/coupling/0/from')
    // The FIX: full remainder, not the truncated 'deep'.
    expect(err!.details.variable).toBe('deep.path')
    expect(err!.details.data_loader).toBe('Weather')
  })

  it('is unchanged for the common 2-segment data-loader from-ref', () => {
    const data = {
      esm: '0.8.0',
      metadata: { name: 'split_scoped_ref_2seg' },
      models: {
        M: {
          variables: { x: { type: 'state', default: 0.0 } },
          equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 0 }],
        },
      },
      data_loaders: {
        Weather: {
          kind: 'grid',
          source: { url_template: '/data/weather_{date:%Y%m%d}.nc' },
          variables: {
            T: { file_variable: 'T2', units: 'K', description: 'Temperature' },
          },
        },
      },
      coupling: [
        {
          type: 'variable_map',
          from: 'Weather.missing_var',
          to: 'M.x',
          transform: 'param_to_var',
        },
      ],
    }

    const result = validate(data)

    expect(result.is_valid).toBe(false)
    const err = result.structural_errors.find(
      (e) => e.code === 'undefined_data_loader_variable',
    )
    expect(err).toBeDefined()
    expect(err!.details.variable).toBe('missing_var')
  })
})

describe('validate(str) JSON parsing (shared losslessJsonParse routing)', () => {
  // validate() parses string input through the same `losslessJsonParse`
  // machinery `load()` uses (tagged leaves stripped back to plain numbers),
  // rather than a divergent bare `JSON.parse`. A malformed string is still
  // reported in the historical `json_parse_error` envelope — same code, `$`
  // path, `details.error` shape, and `Invalid JSON: ` message prefix.
  it('reports malformed JSON in the json_parse_error envelope', () => {
    const result = validate('{ "esm": "0.1.0", ')

    expect(result.is_valid).toBe(false)
    expect(result.structural_errors).toEqual([])
    expect(result.unit_warnings).toEqual([])
    expect(result.schema_errors).toHaveLength(1)
    const err = result.schema_errors[0]
    expect(err.code).toBe('json_parse_error')
    expect(err.path).toBe('$')
    expect(err.message.startsWith('Invalid JSON: ')).toBe(true)
    expect(typeof err.details.error).toBe('string')
    expect(err.message).toBe(`Invalid JSON: ${err.details.error}`)
  })

  it('rejects trailing content after the JSON document', () => {
    const result = validate('{"esm":"0.1.0","metadata":{"name":"x"}} trailing')

    expect(result.is_valid).toBe(false)
    expect(result.schema_errors).toHaveLength(1)
    expect(result.schema_errors[0].code).toBe('json_parse_error')
  })

  it('parses a valid string identically to the equivalent object', () => {
    const obj = {
      esm: '0.1.0',
      metadata: { name: 'parse_parity' },
      models: {
        M: {
          variables: {
            x: { type: 'state', default: 1.0 },
            k: { type: 'parameter', default: 2.0 },
          },
          equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 'k' }],
        },
      },
    }

    const fromString = validate(JSON.stringify(obj))
    const fromObject = validate(obj)

    // Routing the string through the lossless parser (then stripping tagged
    // leaves back to plain numbers) yields the same result as the object path.
    expect(fromString).toEqual(fromObject)
    expect(fromString.is_valid).toBe(true)
    expect(fromString.structural_errors).toEqual([])
  })
})
