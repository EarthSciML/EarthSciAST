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
    const err = result.structural_errors.find((e) => e.code === 'undefined_data_loader_variable')
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
    const err = result.structural_errors.find((e) => e.code === 'undefined_data_loader_variable')
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

/**
 * The six checker bugs where the SPEC sanctions what the checker rejected. Each
 * was proved a CHECKER bug (not a fixture bug) against the shared corpus: the
 * named valid fixture is pinned VALID and was being rejected.
 */
describe('spec-sanctioned constructs the checker used to reject', () => {
  it('(a) treats the independent variable and spatial coordinates as implicitly declared', () => {
    // Spec §5.3's own example writes `t` with no declaration; a spatial
    // coordinate is referenced by name and declared nowhere (§11: a domain
    // carries no grid). Fixtures: cadence/pure_pointwise.esm (t),
    // initial_conditions/expression_ignition_front_1d.esm (x).
    const result = validate({
      esm: '0.1.0',
      metadata: { name: 'implicit-coords' },
      models: {
        M: {
          variables: { u: { type: 'state', units: '1' }, A: { type: 'parameter', default: 1 } },
          equations: [
            {
              lhs: { op: 'D', args: ['u'], wrt: 't' },
              // `t` (independent variable) and `x` (spatial coordinate): neither
              // is declared, and neither is an undefined variable.
              rhs: { op: '*', args: ['A', { op: 'sin', args: [{ op: '+', args: ['t', 'x'] }] }] },
            },
          ],
        },
      },
    })
    expect(result.structural_errors.filter((e) => e.code === 'undefined_variable')).toEqual([])
  })

  it('(a) honours a domain that renames the independent variable', () => {
    const result = validate({
      esm: '0.1.0',
      metadata: { name: 'renamed-time' },
      domain: { independent_variable: 'time' },
      models: {
        M: {
          variables: { u: { type: 'state', units: '1' } },
          equations: [
            { lhs: { op: 'D', args: ['u'], wrt: 'time' }, rhs: { op: '*', args: [-1, 'time'] } },
          ],
        },
      },
    })
    expect(result.structural_errors.filter((e) => e.code === 'undefined_variable')).toEqual([])
  })

  it('(b) accepts the _var placeholder in event affects of a coupled model', () => {
    // Spec §6.4: "_var" is substituted with each matching state variable when
    // coupled via operator_compose. Fixture: full_coupled.esm.
    const file = {
      esm: '0.1.0',
      metadata: { name: 'op-style' },
      models: {
        Transport: {
          variables: { u: { type: 'state', units: '1' } },
          equations: [{ lhs: { op: 'D', args: ['u'], wrt: 't' }, rhs: 0 }],
          continuous_events: [
            {
              name: 'clamp',
              conditions: [{ op: '-', args: ['u', 0.001] }],
              affects: [{ lhs: '_var', rhs: 0.001 }],
              affect_neg: [{ lhs: '_var', rhs: 0 }],
            },
          ],
        },
        Chem: { variables: {}, equations: [] },
      },
      coupling: [{ type: 'operator_compose', systems: ['Chem', 'Transport'] }],
    }
    const result = validate(file)
    expect(result.structural_errors.filter((e) => e.code === 'event_var_undeclared')).toEqual([])

    // ...but a genuinely undeclared target is still flagged, coupled or not.
    const bad = structuredClone(file)
    bad.models.Transport.continuous_events[0].affects[0].lhs = 'nonexistent_var'
    expect(validate(bad).structural_errors.some((e) => e.code === 'event_var_undeclared')).toBe(
      true,
    )
  })

  it('(c) resolves scoped references at ARBITRARY depth in coupling', () => {
    // Spec §4.6. Fixture: scoped_refs_coupling.esm, whose variable_map reads
    // `Meteorology.Temperature.surface_temp` (3 levels) and whose `couple`
    // entry names the SUBSYSTEM `Meteorology.Temperature`.
    const result = validate({
      esm: '0.1.0',
      metadata: { name: 'deep-scope' },
      models: {
        Chem: { variables: { T: { type: 'parameter', units: 'K', default: 300 } }, equations: [] },
        Meteorology: {
          variables: {},
          equations: [],
          subsystems: {
            Temperature: {
              variables: { surface_temp: { type: 'state', units: 'K' } },
              equations: [{ lhs: { op: 'D', args: ['surface_temp'], wrt: 't' }, rhs: 0 }],
            },
          },
        },
      },
      coupling: [
        {
          type: 'variable_map',
          from: 'Meteorology.Temperature.surface_temp',
          to: 'Chem.T',
          transform: 'param_to_var',
        },
        { type: 'couple', systems: ['Chem', 'Meteorology.Temperature'] },
      ],
    })
    expect(result.structural_errors).toEqual([])

    // A deep path that does NOT exist is still unresolved.
    const bad = validate({
      esm: '0.1.0',
      metadata: { name: 'deep-scope-bad' },
      models: {
        Chem: { variables: { T: { type: 'parameter', units: 'K', default: 300 } }, equations: [] },
        Meteorology: { variables: {}, equations: [] },
      },
      coupling: [
        {
          type: 'variable_map',
          from: 'Meteorology.Temperature.surface_temp',
          to: 'Chem.T',
          transform: 'param_to_var',
        },
      ],
    })
    expect(bad.structural_errors.some((e) => e.code === 'unresolved_scoped_ref')).toBe(true)
  })

  it('(d) allows a scoped reference in a reaction rate', () => {
    // Fixture: events_cross_system.esm — an Arrhenius rate reading another
    // system's temperature.
    const result = validate({
      esm: '0.1.0',
      metadata: { name: 'cross-system-rate' },
      models: {
        Met: { variables: { T: { type: 'state', units: 'K' } }, equations: [] },
      },
      reaction_systems: {
        Chem: {
          species: { A: { units: 'mol/m^3' }, B: { units: 'mol/m^3' } },
          parameters: { k: { units: '1/s', default: 1 } },
          reactions: [
            {
              id: 'r1',
              substrates: [{ species: 'A', stoichiometry: 1 }],
              products: [{ species: 'B', stoichiometry: 1 }],
              // The rate reads Met.T — another system's variable.
              rate: { op: '*', args: ['k', 'A', { op: '/', args: ['Met.T', 'Met.T'] }] },
            },
          ],
        },
      },
    })
    expect(result.structural_errors.filter((e) => e.code === 'undefined_parameter')).toEqual([])

    // An unresolvable scoped rate reference is still reported.
    const bad = validate({
      esm: '0.1.0',
      metadata: { name: 'cross-system-rate-bad' },
      reaction_systems: {
        Chem: {
          species: { A: { units: 'mol/m^3' } },
          parameters: { k: { units: '1/s', default: 1 } },
          reactions: [
            {
              id: 'r1',
              substrates: [{ species: 'A', stoichiometry: 1 }],
              products: null,
              rate: { op: '*', args: ['k', 'Nowhere.T'] },
            },
          ],
        },
      },
    })
    expect(bad.structural_errors.some((e) => e.code === 'unresolved_scoped_ref')).toBe(true)
  })

  it('(e) balances a nonlinear system by UNKNOWNS vs EQUATIONS', () => {
    // Fixture: nonlinear_isorropia_shape.esm — 2 unknowns, 2 algebraic
    // equations, the second of which has a PRODUCT LHS (`H*H*SO4 = Ksp`) that
    // credits no variable under the ODE rule.
    const balanced = validate({
      esm: '0.1.0',
      metadata: { name: 'equilibrium' },
      models: {
        Eq: {
          system_kind: 'nonlinear',
          variables: {
            H: { type: 'state', units: 'mol/m^3' },
            SO4: { type: 'state', units: 'mol/m^3' },
            Ksp: { type: 'parameter', units: 'mol^3/m^9', default: 1 },
          },
          equations: [
            { lhs: 'H', rhs: { op: '*', args: [2, 'SO4'] } },
            { lhs: { op: '*', args: ['H', 'H', 'SO4'] }, rhs: 'Ksp' },
          ],
        },
      },
    })
    expect(balanced.structural_errors.filter((e) => e.code === 'equation_count_mismatch')).toEqual(
      [],
    )

    // An UNDER-determined algebraic system is still a mismatch: 2 unknowns, 1 eq.
    const underdetermined = validate({
      esm: '0.1.0',
      metadata: { name: 'equilibrium-bad' },
      models: {
        Eq: {
          system_kind: 'nonlinear',
          variables: {
            H: { type: 'state', units: 'mol/m^3' },
            SO4: { type: 'state', units: 'mol/m^3' },
          },
          equations: [{ lhs: 'H', rhs: { op: '*', args: [2, 'SO4'] } }],
        },
      },
    })
    expect(
      underdetermined.structural_errors.some((e) => e.code === 'equation_count_mismatch'),
    ).toBe(true)
  })

  it('(g) treats a construct-BOUND loop index as in scope, without allowlisting letters', () => {
    // An `aggregate` binds its `output_idx` / `ranges` names, and an `index`
    // element position is a bound index. Those names are in scope inside the
    // construct's body and are never `undefined_variable`. Critically, the scope
    // is derived from the BINDERS actually present — not from a list of
    // single-letter names — so an unbound name is still reported even when it
    // sits in the very same body.
    const boundIndex = validate({
      esm: '0.1.0',
      metadata: { name: 'bound-index' },
      models: {
        M: {
          variables: {
            u: { type: 'state', units: '1', shape: ['cells'] },
            k: { type: 'parameter', units: '1/s', default: 1 },
          },
          equations: [
            {
              lhs: {
                op: 'aggregate',
                args: [],
                output_idx: ['i'],
                ranges: { i: [1, 3] },
                expr: { op: 'D', args: [{ op: 'index', args: ['u', 'i'] }], wrt: 't' },
              },
              rhs: {
                op: 'aggregate',
                args: [],
                output_idx: ['i'],
                ranges: { i: [1, 3] },
                // `i` is bound by the enclosing aggregate; `k` and `u` are declared.
                expr: { op: '*', args: ['k', { op: 'index', args: ['u', 'i'] }] },
              },
            },
          ],
        },
      },
      index_sets: { cells: { kind: 'interval', size: 3 } },
    })
    expect(boundIndex.structural_errors.filter((e) => e.code === 'undefined_variable')).toEqual([])

    // An UNBOUND name inside the same aggregate body is still undefined — the
    // binder set is derived, not an allowlist. `j` is a single letter and is NOT
    // excused.
    const unbound = validate({
      esm: '0.1.0',
      metadata: { name: 'unbound-index' },
      models: {
        M: {
          variables: {
            u: { type: 'state', units: '1', shape: ['cells'] },
          },
          equations: [
            {
              lhs: {
                op: 'aggregate',
                args: [],
                output_idx: ['i'],
                ranges: { i: [1, 3] },
                expr: { op: 'D', args: [{ op: 'index', args: ['u', 'i'] }], wrt: 't' },
              },
              rhs: {
                op: 'aggregate',
                args: [],
                output_idx: ['i'],
                ranges: { i: [1, 3] },
                // `j` is bound by nothing, and `undefined_xyz` is not declared.
                expr: { op: '*', args: ['j', 'undefined_xyz'] },
              },
            },
          ],
        },
      },
      index_sets: { cells: { kind: 'interval', size: 3 } },
    })
    const undefinedNames = unbound.structural_errors
      .filter((e) => e.code === 'undefined_variable')
      .map((e) => (e.details as { variable: string }).variable)
      .sort()
    expect(undefinedNames).toEqual(['j', 'undefined_xyz'])
  })

  it('(f) emits the canonical subsystem-ref code', () => {
    const result = validate({
      esm: '0.1.0',
      metadata: { name: 'unresolved-ref' },
      models: {
        Atmosphere: {
          variables: { temp: { type: 'parameter', units: 'K', default: 300 } },
          equations: [],
          subsystems: { Missing: { ref: './does_not_exist.esm' } },
        },
      },
    })
    const refErrors = result.structural_errors.filter((e) => e.code === 'unresolved_subsystem_ref')
    expect(refErrors).toHaveLength(1)
    expect(refErrors[0].path).toBe('/models/Atmosphere/subsystems/Missing')
    expect(refErrors[0].details).toMatchObject({
      ref: './does_not_exist.esm',
      subsystem: 'Missing',
      parent_model: 'Atmosphere',
    })
  })

  it('promotes an unparseable unit to unit_parse_error at the variable', () => {
    const result = validate({
      esm: '0.1.0',
      metadata: { name: 'bad-unit' },
      models: {
        TestModel: {
          variables: { c: { type: 'state', units: 'not_a_unit' } },
          equations: [{ lhs: { op: 'D', args: ['c'], wrt: 't' }, rhs: 0 }],
        },
      },
    })
    const parseErrors = result.structural_errors.filter((e) => e.code === 'unit_parse_error')
    expect(parseErrors).toHaveLength(1)
    expect(parseErrors[0].path).toBe('/models/TestModel/variables/c')
    expect(parseErrors[0].details).toMatchObject({ variable: 'c', units: 'not_a_unit' })
  })
})
