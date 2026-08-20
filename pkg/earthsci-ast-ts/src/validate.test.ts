/**
 * Tests for structural validation
 */

import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { validate } from './validate.js'
import { readFixture, REPO_ROOT } from './test-helpers.js'

describe('Structural validation', () => {
  it('should detect equation count mismatch', () => {
    const data = {
      esm: '1.0.0',
      metadata: { name: 'test' },
      models: {
        TestModel: {
          variables: {
            x: { type: 'unknown', default: 1.0 },
            y: { type: 'unknown', default: 2.0 },
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
      esm: '1.0.0',
      metadata: { name: 'test' },
      models: {
        TestModel: {
          variables: {
            x: { type: 'unknown', default: 1.0 },
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
      esm: '1.0.0',
      metadata: { name: 'test' },
      models: {
        TestModel: {
          variables: {
            x: { type: 'unknown', default: 1.0 },
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
      esm: '1.0.0',
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
      esm: '1.0.0',
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
      esm: '1.0.0',
      metadata: { name: 'test' },
      models: {
        TestModel: {
          variables: {
            x: { type: 'unknown', default: 1.0 },
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
      esm: '1.0.0',
      metadata: { name: 'test' },
      models: {
        TestModel: {
          variables: {
            x: { type: 'unknown', default: 1.0 },
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
      esm: '1.0.0',
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
      esm: '1.0.0',
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
      esm: '1.0.0',
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
    esm: '1.0.0',
    metadata: { name: 'vm_expr_transform' },
    models: {
      Src: {
        variables: { F: { type: 'unknown', default: 1.0 } },
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
  // Regression for the split('.', 2) truncation bug: the head/remainder split of
  // a scoped reference must keep EVERY trailing segment — "Meteo.Layer.temp"
  // splits as ["Meteo", "Layer.temp"], not ["Meteo", "Layer"] — so a deep
  // reference is navigated all the way down instead of being cut off after one
  // step. Mirrors Go's strings.SplitN(from, ".", 2) remainder semantics.
  //
  // In 0.x this was pinned through a DATA LOADER ref ("Weather.deep.path") and
  // the `undefined_data_loader_variable` code. From 1.0.0 a data source is not
  // a coupling endpoint, exposes no variables, and is not a scoped-name path
  // root (esm-spec §5.5), so that code is retired and the shape it described no
  // longer exists. The split semantics survive unchanged, and are pinned here
  // where deep references actually live: a chain of model subsystems.
  const deepRefFile = (from: string) => ({
    esm: '1.0.0',
    metadata: { name: 'split_scoped_ref' },
    models: {
      M: {
        variables: { x: { type: 'unknown', default: 0.0 } },
        equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 0 }],
      },
      Meteo: {
        variables: {},
        equations: [],
        subsystems: {
          Layer: {
            variables: { temp: { type: 'unknown', units: 'K', default: 300 } },
            equations: [{ lhs: { op: 'D', args: ['temp'], wrt: 't' }, rhs: 0 }],
          },
        },
      },
    },
    coupling: [{ type: 'variable_map', from, to: 'M.x', transform: 'param_to_var' }],
  })

  it('navigates the whole dotted remainder of a 3-segment from-ref', () => {
    // `Meteo.Layer.temp` resolves only if the remainder "Layer.temp" survives
    // the split intact: truncating to "Layer" would look for a VARIABLE named
    // "Layer" on `Meteo` and report a spurious unresolved reference.
    const result = validate(deepRefFile('Meteo.Layer.temp'))

    expect(result.structural_errors.filter((e) => e.code === 'unresolved_scoped_ref')).toEqual([])
    expect(result.is_valid).toBe(true)
  })

  it('reports the leaf name and the full reference when a deep ref does not resolve', () => {
    const result = validate(deepRefFile('Meteo.Layer.missing_var'))

    expect(result.is_valid).toBe(false)
    const err = result.structural_errors.find((e) => e.code === 'unresolved_scoped_ref')
    expect(err).toBeDefined()
    expect(err!.path).toBe('/coupling/0/from')
    // The undefined NAME is the leaf; the whole dotted path is kept alongside it
    // so a reader can see which chain was walked.
    expect(err!.details.variable).toBe('missing_var')
    expect(err!.details.reference).toBe('Meteo.Layer.missing_var')
    expect(err!.details.system).toBe('Meteo')
  })

  it('refuses a data SOURCE as a coupling endpoint (it is not a path root)', () => {
    // The 1.0.0 replacement for the retired `undefined_data_loader_variable`:
    // `Weather.T` no longer names anything, because a `data_sources` entry is
    // not a component and heads no scope. A model consumes it through a
    // parameter `update`, never through a coupling entry.
    const result = validate({
      esm: '1.0.0',
      metadata: { name: 'source_is_not_an_endpoint' },
      models: {
        M: {
          variables: { x: { type: 'unknown', default: 0.0 } },
          equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 0 }],
        },
      },
      data_sources: {
        Weather: {
          kind: 'grid',
          source: { url_template: '/data/weather_{date:%Y%m%d}.nc' },
        },
      },
      coupling: [
        { type: 'variable_map', from: 'Weather.T', to: 'M.x', transform: 'param_to_var' },
      ],
    })

    expect(result.is_valid).toBe(false)
    const err = result.structural_errors.find((e) => e.code === 'unresolved_scoped_ref')
    expect(err).toBeDefined()
    expect(err!.path).toBe('/coupling/0/from')
    expect(err!.details.reference).toBe('Weather.T')
    expect(err!.details.system).toBe('Weather')
  })

  it('reports `data_source_undefined` when a parameter update names no declared source', () => {
    // The other half of the replacement: naming a source is now a parameter's
    // `update.source`, and that string is schema-valid whatever it says — so
    // the existence check is structural.
    const file = (source: string) => ({
      esm: '1.0.0',
      metadata: { name: 'source_ref' },
      models: {
        M: {
          variables: {
            x: { type: 'unknown', default: 0.0 },
            T: {
              type: 'parameter',
              units: 'K',
              shape: [],
              update: { kind: 'data', source, from: { file_variable: 'T2M' } },
            },
          },
          equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 0 }],
        },
      },
      data_sources: {
        Weather: {
          kind: 'grid',
          source: { url_template: '/data/weather_{date:%Y%m%d}.nc' },
        },
      },
    })

    expect(validate(file('Weather')).is_valid).toBe(true)

    const result = validate(file('Nowhere'))
    expect(result.is_valid).toBe(false)
    const err = result.structural_errors.find((e) => e.code === 'data_source_undefined')
    expect(err).toBeDefined()
    expect(err!.path).toBe('/models/M/variables/T/update')
    expect(err!.details).toMatchObject({
      variable: 'T',
      source: 'Nowhere',
      available_sources: ['Weather'],
    })
  })
})

describe('validate(str) JSON parsing (shared losslessJsonParse routing)', () => {
  // validate() parses string input through the same `losslessJsonParse`
  // machinery `load()` uses (tagged leaves stripped back to plain numbers),
  // rather than a divergent bare `JSON.parse`. A malformed string is still
  // reported in the historical `json_parse_error` envelope — same code,
  // empty-string document-root path, `details.error` shape, and `Invalid JSON: `
  // message prefix.
  it('reports malformed JSON in the json_parse_error envelope', () => {
    const result = validate('{ "esm": "1.0.0", ')

    expect(result.is_valid).toBe(false)
    expect(result.structural_errors).toEqual([])
    expect(result.unit_warnings).toEqual([])
    expect(result.schema_errors).toHaveLength(1)
    const err = result.schema_errors[0]
    expect(err.code).toBe('json_parse_error')
    expect(err.path).toBe('')
    expect(err.message.startsWith('Invalid JSON: ')).toBe(true)
    expect(typeof err.details.error).toBe('string')
    expect(err.message).toBe(`Invalid JSON: ${err.details.error}`)
  })

  it('rejects trailing content after the JSON document', () => {
    const result = validate('{"esm":"1.0.0","metadata":{"name":"x"}} trailing')

    expect(result.is_valid).toBe(false)
    expect(result.schema_errors).toHaveLength(1)
    expect(result.schema_errors[0].code).toBe('json_parse_error')
  })

  it('parses a valid string identically to the equivalent object', () => {
    const obj = {
      esm: '1.0.0',
      metadata: { name: 'parse_parity' },
      models: {
        M: {
          variables: {
            x: { type: 'unknown', default: 1.0 },
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
      esm: '1.0.0',
      metadata: { name: 'implicit-coords' },
      models: {
        M: {
          variables: { u: { type: 'unknown', units: '1' }, A: { type: 'parameter', default: 1 } },
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
      esm: '1.0.0',
      metadata: { name: 'renamed-time' },
      domain: { independent_variable: 'time' },
      models: {
        M: {
          variables: { u: { type: 'unknown', units: '1' } },
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
      esm: '1.0.0',
      metadata: { name: 'op-style' },
      models: {
        Transport: {
          variables: { u: { type: 'unknown', units: '1' } },
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
      esm: '1.0.0',
      metadata: { name: 'deep-scope' },
      models: {
        Chem: { variables: { T: { type: 'parameter', units: 'K', default: 300 } }, equations: [] },
        Meteorology: {
          variables: {},
          equations: [],
          subsystems: {
            Temperature: {
              variables: { surface_temp: { type: 'unknown', units: 'K' } },
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
      esm: '1.0.0',
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
      esm: '1.0.0',
      metadata: { name: 'cross-system-rate' },
      models: {
        // `T` is an unknown, so it needs its own equation: from 1.0.0 the
        // balance check counts unknowns against equations, and a declared
        // unknown with no equation is `equation_count_mismatch`.
        Met: {
          variables: { T: { type: 'unknown', units: 'K' } },
          equations: [{ lhs: { op: 'D', args: ['T'], wrt: 't' }, rhs: 0 }],
        },
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
      esm: '1.0.0',
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
      esm: '1.0.0',
      metadata: { name: 'equilibrium' },
      models: {
        Eq: {
          system_kind: 'nonlinear',
          variables: {
            H: { type: 'unknown', units: 'mol/m^3' },
            SO4: { type: 'unknown', units: 'mol/m^3' },
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
      esm: '1.0.0',
      metadata: { name: 'equilibrium-bad' },
      models: {
        Eq: {
          system_kind: 'nonlinear',
          variables: {
            H: { type: 'unknown', units: 'mol/m^3' },
            SO4: { type: 'unknown', units: 'mol/m^3' },
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
      esm: '1.0.0',
      metadata: { name: 'bound-index' },
      models: {
        M: {
          variables: {
            u: { type: 'unknown', units: '1', shape: ['cells'] },
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
      esm: '1.0.0',
      metadata: { name: 'unbound-index' },
      models: {
        M: {
          variables: {
            u: { type: 'unknown', units: '1', shape: ['cells'] },
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
      esm: '1.0.0',
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
      esm: '1.0.0',
      metadata: { name: 'bad-unit' },
      models: {
        TestModel: {
          variables: { c: { type: 'unknown', units: 'not_a_unit' } },
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

/**
 * (h) Reference integrity applies to EVERY expression-bearing field, not just
 * `equations`.
 *
 * This was a silent false NEGATIVE: an undefined name in an observed variable's
 * `expression` (or a guess, an event condition, an affect RHS, ...) was simply
 * invisible. Each case below follows the same three-way discipline: a DEFINED
 * name in the sidecar validates, an UNDEFINED name in that SAME sidecar errors,
 * and the error pointer names the sidecar field.
 */
describe('(h) reference integrity covers every expression-bearing field', () => {
  /** Build a one-model file, applying `patch` to the model. */
  const fileWith = (patch: Record<string, unknown>) => ({
    esm: '1.0.0',
    metadata: { name: 'sidecars' },
    models: {
      M: {
        variables: {
          u: { type: 'unknown', units: '1' },
          k: { type: 'parameter', units: '1', default: 1 },
        },
        equations: [{ lhs: { op: 'D', args: ['u'], wrt: 't' }, rhs: 0 }],
        ...patch,
      },
    },
  })

  const undefinedIn = (file: object) =>
    validate(file).structural_errors.filter((e) => e.code === 'undefined_variable')

  // Each case: [label, a patch using the DEFINED name `k`, the same patch using
  // an UNDEFINED name, the JSON Pointer the error must carry].
  const cases: Array<[string, Record<string, unknown>, Record<string, unknown>, string]> = [
    [
      // 0.x wrote an observed variable's defining expression as a SIDECAR
      // (`variables.obs.expression`) and that pointer is what this case pinned.
      // From 1.0.0 an unknown's behaviour is stated by the model's `equations`
      // and nowhere else, so the same defect now lives at an equation RHS — the
      // case is kept (the name still has to resolve) with the pointer that
      // position now carries. Note the extra equation: `obs` is a third unknown
      // and would otherwise unbalance the model.
      'an observed unknown`s defining equation',
      {
        variables: {
          u: { type: 'unknown', units: '1' },
          k: { type: 'parameter', units: '1', default: 1 },
          obs: { type: 'unknown', units: '1' },
        },
        equations: [
          { lhs: { op: 'D', args: ['u'], wrt: 't' }, rhs: 0 },
          { lhs: 'obs', rhs: { op: '*', args: [2, 'k'] } },
        ],
      },
      {
        variables: {
          u: { type: 'unknown', units: '1' },
          k: { type: 'parameter', units: '1', default: 1 },
          obs: { type: 'unknown', units: '1' },
        },
        equations: [
          { lhs: { op: 'D', args: ['u'], wrt: 't' }, rhs: 0 },
          { lhs: 'obs', rhs: { op: '*', args: [2, 'nope'] } },
        ],
      },
      '/models/M/equations/1/rhs',
    ],
    [
      'a solver guess',
      { guesses: { u: { op: '*', args: [2, 'k'] } } },
      { guesses: { u: { op: '*', args: [2, 'nope'] } } },
      '/models/M/guesses/u',
    ],
    [
      'an initialization equation',
      { initialization_equations: [{ lhs: 'u', rhs: { op: '*', args: [2, 'k'] } }] },
      { initialization_equations: [{ lhs: 'u', rhs: { op: '*', args: [2, 'nope'] } }] },
      '/models/M/initialization_equations/0/rhs',
    ],
    [
      'a continuous-event condition',
      {
        continuous_events: [
          {
            name: 'e',
            conditions: [{ op: '-', args: ['u', 'k'] }],
            affects: [{ lhs: 'u', rhs: 0 }],
          },
        ],
      },
      {
        continuous_events: [
          {
            name: 'e',
            conditions: [{ op: '-', args: ['u', 'nope'] }],
            affects: [{ lhs: 'u', rhs: 0 }],
          },
        ],
      },
      '/models/M/continuous_events/0/conditions/0',
    ],
    [
      'a continuous-event affect RHS',
      {
        continuous_events: [
          {
            name: 'e',
            conditions: [{ op: '-', args: ['u', 1] }],
            affects: [{ lhs: 'u', rhs: { op: '*', args: [2, 'k'] } }],
          },
        ],
      },
      {
        continuous_events: [
          {
            name: 'e',
            conditions: [{ op: '-', args: ['u', 1] }],
            affects: [{ lhs: 'u', rhs: { op: '*', args: [2, 'nope'] } }],
          },
        ],
      },
      '/models/M/continuous_events/0/affects/0/rhs',
    ],
    [
      'a discrete-event condition trigger',
      {
        discrete_events: [
          {
            name: 'e',
            trigger: { type: 'condition', expression: { op: '>', args: ['u', 'k'] } },
            affects: [{ lhs: 'u', rhs: 0 }],
          },
        ],
      },
      {
        discrete_events: [
          {
            name: 'e',
            trigger: { type: 'condition', expression: { op: '>', args: ['u', 'nope'] } },
            affects: [{ lhs: 'u', rhs: 0 }],
          },
        ],
      },
      '/models/M/discrete_events/0/trigger/expression',
    ],
    [
      'a discrete-event affect RHS',
      {
        discrete_events: [
          {
            name: 'e',
            trigger: { type: 'periodic', interval: 1 },
            affects: [{ lhs: 'u', rhs: { op: '*', args: [2, 'k'] } }],
          },
        ],
      },
      {
        discrete_events: [
          {
            name: 'e',
            trigger: { type: 'periodic', interval: 1 },
            affects: [{ lhs: 'u', rhs: { op: '*', args: [2, 'nope'] } }],
          },
        ],
      },
      '/models/M/discrete_events/0/affects/0/rhs',
    ],
  ]

  it.each(cases)('checks %s', (_label, definedPatch, undefinedPatch, pointer) => {
    // A DEFINED name in the sidecar validates.
    expect(undefinedIn(fileWith(definedPatch))).toEqual([])

    // An UNDEFINED name in the SAME sidecar is reported...
    const errors = undefinedIn(fileWith(undefinedPatch))
    expect(errors).toHaveLength(1)
    expect((errors[0].details as { variable: string }).variable).toBe('nope')
    // ...and the pointer names the sidecar field, not just the model.
    expect(errors[0].path).toBe(pointer)
  })

  it('binds an `integral`s integration variable, and still flags its free bounds', () => {
    // `integral.var` is a BINDER (schema: "the name of the spatial dimension
    // being integrated over"), in scope in the integrand AND the bounds — the
    // cumulative form writes `upper: "<var>"`. Its `lower`, however, is an
    // ordinary expression: a free name there is a real reference.
    // `cumu` is an observed UNKNOWN: 1.0.0 states it with a bare-string equation
    // LHS rather than a `variables.cumu.expression` sidecar, so the integral now
    // sits at an equation RHS and the model needs the matching second equation.
    const bound = validate(
      fileWith({
        variables: {
          u: { type: 'unknown', units: '1' },
          xmin: { type: 'parameter', units: '1', default: 0 },
          cumu: { type: 'unknown', units: '1' },
        },
        equations: [
          { lhs: { op: 'D', args: ['u'], wrt: 't' }, rhs: 0 },
          {
            lhs: 'cumu',
            rhs: { op: 'integral', args: ['u'], var: 's', lower: 'xmin', upper: 's' },
          },
        ],
      }),
    )
    // `s` is bound by `var` — not an undefined variable, and NOT excused by any
    // x/y/z allowlist.
    expect(bound.structural_errors.filter((e) => e.code === 'undefined_variable')).toEqual([])

    // The same integral with an UNDECLARED lower bound is reported.
    const freeBound = undefinedIn(
      fileWith({
        variables: {
          u: { type: 'unknown', units: '1' },
          cumu: { type: 'unknown', units: '1' },
        },
        equations: [
          { lhs: { op: 'D', args: ['u'], wrt: 't' }, rhs: 0 },
          {
            lhs: 'cumu',
            rhs: { op: 'integral', args: ['u'], var: 's', lower: 'nope', upper: 's' },
          },
        ],
      }),
    )
    expect(freeBound).toHaveLength(1)
    expect((freeBound[0].details as { variable: string }).variable).toBe('nope')
  })

  it('resolves a reference to the ENCLOSING component`s own mounted subsystem', () => {
    // spec §4.6: a model that mounts subsystem `Calendar` names its variables
    // `Calendar.x`. Resolving only from the FILE ROOT found no top-level
    // `Calendar` and reported the valid lib_*_subsystem_inclusion fixtures as
    // unresolved scoped refs.
    // `w` and the subsystem's `seconds_since_midnight` are observed UNKNOWNS:
    // each is stated by a bare-LHS equation rather than by a `variables.*
    // .expression` sidecar, so both components carry one equation per unknown.
    const ownSubsystemFile = (reference: string) => ({
      esm: '1.0.0',
      metadata: { name: 'own-subsystem' },
      models: {
        Diurnal: {
          variables: {
            u: { type: 'unknown', units: '1' },
            w: { type: 'unknown', units: '1' },
          },
          equations: [
            { lhs: { op: 'D', args: ['u'], wrt: 't' }, rhs: 0 },
            { lhs: 'w', rhs: { op: '*', args: [2, reference] } },
          ],
          subsystems: {
            Calendar: {
              variables: {
                seconds_since_midnight: { type: 'unknown', units: 's' },
              },
              equations: [{ lhs: 'seconds_since_midnight', rhs: 0 }],
            },
          },
        },
      },
    })

    const result = validate(ownSubsystemFile('Calendar.seconds_since_midnight'))
    expect(result.structural_errors.filter((e) => e.code === 'unresolved_scoped_ref')).toEqual([])

    // A name the mounted subsystem does NOT declare is still unresolved.
    const bad = validate(ownSubsystemFile('Calendar.nope'))
    expect(bad.structural_errors.some((e) => e.code === 'unresolved_scoped_ref')).toBe(true)
  })
})

/**
 * ANTI-VACUITY GUARD for the observed-variable dimensional check.
 *
 * The units discriminator fixture (`tests/valid/units_registry_grammar.esm`)
 * asserts a registry/grammar contract through 14 OBSERVED variables whose
 * declared units must equal the dimension their expression computes. Such a
 * fixture is only worth anything if the checker actually COMPARES the two: a
 * binding that never performs that comparison reports `is_valid: true` while
 * checking nothing at all, and the fixture then manufactures confidence instead
 * of catching regressions. (That is exactly the "tests that assert nothing"
 * disease the audit was about.)
 *
 * So this pins the comparison itself, in both directions — corrupt the
 * DECLARATION, and corrupt the EXPRESSION, and both must be rejected. If the
 * declared-vs-computed check is ever lost, these fail loudly rather than the
 * fixture silently going vacuous.
 */
describe('observed unknowns: declared units are compared against the computed dimension', () => {
  // An observed unknown is one whose defining equation has a BARE-STRING LHS
  // (§6.3.1) — 1.0.0's spelling of what 0.x declared as `type: "observed"` with
  // an `expression` sidecar. The comparison being guarded is unchanged: the
  // variable's declared `units` against the dimension its defining RHS computes.
  const model = (units: string, rhs: unknown) => ({
    esm: '1.0.0',
    metadata: { name: 'nonvacuous' },
    models: {
      M: {
        variables: {
          u: { type: 'unknown', units: 'm/s' },
          T: { type: 'parameter', units: 'K', default: 300 },
          obs: { type: 'unknown', units },
        },
        equations: [
          { lhs: { op: 'D', args: ['u'], wrt: 't' }, rhs: 0 },
          { lhs: 'obs', rhs },
        ],
      },
    },
  })
  const inconsistencies = (file: object) =>
    validate(file).structural_errors.filter((e) => e.code === 'unit_inconsistency')

  it('accepts an observed unknown whose declaration MATCHES its defining equation', () => {
    expect(inconsistencies(model('m/s', 'u'))).toEqual([])
  })

  // A mismatch is now reported TWICE, from two independent checks that both
  // bite: the equation's own two sides no longer agree (`/models/M/equations/1`)
  // AND the declared-vs-computed comparison fails at the variable
  // (`/models/M/variables/obs`). The second is the one this guard exists for —
  // the first would still fire from a plain algebraic equation — so both paths
  // are pinned rather than just a count.
  const paths = (errors: ReturnType<typeof inconsistencies>) => errors.map((e) => e.path).sort()

  it('rejects a corrupted DECLARATION (declared unit no longer matches the expression)', () => {
    expect(paths(inconsistencies(model('kg', 'u')))).toEqual([
      '/models/M/equations/1',
      '/models/M/variables/obs',
    ])
  })

  it('rejects a corrupted EXPRESSION (expression no longer computes the declared unit)', () => {
    // `u * T` is m·K/s, not m/s.
    expect(paths(inconsistencies(model('m/s', { op: '*', args: ['u', 'T'] })))).toEqual([
      '/models/M/equations/1',
      '/models/M/variables/obs',
    ])
  })
})

/**
 * (h) sites 8-11 — the expression positions that live OUTSIDE a model's
 * `variables`/`equations`: an inline test assertion's `reference`, a data
 * loader's `unit_conversion`, and the two coupling expression slots.
 */
describe('(h) reference integrity covers the non-model expression sites', () => {
  it('checks a test assertion reference (site 8)', () => {
    const withTests = (reference: unknown) => ({
      esm: '1.0.0',
      metadata: { name: 'assertion-ref' },
      models: {
        TestModel: {
          variables: {
            y: { type: 'unknown', units: '1' },
            k: { type: 'parameter', units: '1/s', default: 1 },
          },
          equations: [{ lhs: { op: 'D', args: ['y'], wrt: 't' }, rhs: 0 }],
          tests: [
            {
              id: 't0',
              time_span: { start: 0, end: 1 },
              assertions: [{ variable: 'y', time: 1, expected: 0, reference }],
            },
          ],
        },
      },
    })
    expect(
      validate(withTests({ op: '*', args: ['k', 'y'] })).structural_errors.filter(
        (e) => e.code === 'undefined_variable',
      ),
    ).toEqual([])

    const errors = validate(
      withTests({ op: '*', args: ['k', 'undefined_xyz'] }),
    ).structural_errors.filter((e) => e.code === 'undefined_variable')
    expect(errors).toHaveLength(1)
    expect(errors[0].path).toBe('/models/TestModel/tests/0/assertions/0/reference')
  })

  it('checks a data-source binding unit_conversion (site 9)', () => {
    // In 0.x `unit_conversion` hung off a data LOADER variable
    // (`/data_loaders/L/variables/v/unit_conversion`). From 1.0.0 the source
    // exposes no variables at all: the CONSUMING parameter binds a
    // `file_variable` through `update.from` and owns both the units and the
    // conversion. Same expression position, new home — and the check must
    // follow it there, or every conversion in the format goes unchecked again.
    const withConversion = (unit_conversion: unknown) => ({
      esm: '1.0.0',
      metadata: { name: 'unit-conv' },
      models: {
        TestModel: {
          variables: {
            y: { type: 'unknown', units: '1' },
            k: { type: 'parameter', units: '1', default: 1 },
            v: {
              type: 'parameter',
              units: '1',
              // A `data` update makes the parameter a buffer, so `shape` is
              // required; an empty shape is the scalar case.
              shape: [],
              update: {
                kind: 'data',
                source: 'L',
                from: { file_variable: 'v', unit_conversion },
              },
            },
          },
          equations: [{ lhs: { op: 'D', args: ['y'], wrt: 't' }, rhs: 0 }],
        },
      },
      data_sources: {
        L: { kind: 'grid', source: { url_template: 'file:///d.nc' } },
      },
    })
    // A plain numeric factor carries no references.
    expect(validate(withConversion(2.5)).structural_errors).toEqual([])
    // A declared name resolves (the conversion may scale by a model's parameter).
    expect(
      validate(withConversion({ op: '*', args: ['k', 2] })).structural_errors.filter(
        (e) => e.code === 'undefined_variable',
      ),
    ).toEqual([])

    const errors = validate(
      withConversion({ op: '*', args: ['k', 'undefined_xyz'] }),
    ).structural_errors.filter((e) => e.code === 'undefined_variable')
    expect(errors).toHaveLength(1)
    expect(errors[0].path).toBe('/models/TestModel/variables/v/update/from/unit_conversion')
  })

  it('checks the two coupling expression slots (sites 10 & 11)', () => {
    const base = {
      esm: '1.0.0',
      metadata: { name: 'coupling-expr' },
      models: {
        TestModel: {
          variables: { y: { type: 'unknown', units: '1' } },
          equations: [{ lhs: { op: 'D', args: ['y'], wrt: 't' }, rhs: 0 }],
        },
        Other: {
          variables: {
            w: { type: 'unknown', units: '1' },
            p: { type: 'parameter', units: '1', default: 1 },
          },
          equations: [{ lhs: { op: 'D', args: ['w'], wrt: 't' }, rhs: 0 }],
        },
      },
    }
    const scopedRefs = (file: object) =>
      validate(file).structural_errors.filter((e) => e.code === 'unresolved_scoped_ref')

    // Site 11 — variable_map Expression transform.
    const vmap = (transform: unknown) => ({
      ...base,
      coupling: [{ type: 'variable_map', from: 'TestModel.y', to: 'Other.p', transform }],
    })
    expect(scopedRefs(vmap({ op: '*', args: ['TestModel.y', 2] }))).toEqual([])
    const t = scopedRefs(vmap({ op: '*', args: ['TestModel.y', 'TestModel.undefined_xyz'] }))
    expect(t).toHaveLength(1)
    expect(t[0].path).toBe('/coupling/0/transform')

    // Site 10 — couple connector equation expression.
    const conn = (expression: unknown) => ({
      ...base,
      coupling: [
        {
          type: 'couple',
          systems: ['TestModel', 'Other'],
          connector: {
            equations: [{ from: 'TestModel.y', to: 'Other.w', transform: 'additive', expression }],
          },
        },
      ],
    })
    expect(scopedRefs(conn({ op: '*', args: ['TestModel.y', 2] }))).toEqual([])
    const c = scopedRefs(conn({ op: '*', args: ['TestModel.y', 'TestModel.undefined_xyz'] }))
    expect(c).toHaveLength(1)
    expect(c[0].path).toBe('/coupling/0/connector/equations/0/expression')
  })
})

/**
 * (k) The declaration-site set must be COMPLETE, or tightening a false NEGATIVE
 * just trades it for a false POSITIVE.
 */
describe('(k) complete declaration-site set', () => {
  it('credits names a `callback` coupling injects into its target_system', () => {
    // `coupling[i].config.callback_variables[j].name` is a real declaration,
    // made from OUTSIDE the component. Missing it falsely rejected
    // `tests/coupling/callback_examples.esm`.
    const file = (couplingVarName: string) => ({
      esm: '1.0.0',
      metadata: { name: 'callback-decl' },
      models: {
        WeatherModel: {
          variables: { temp: { type: 'unknown', units: 'K' } },
          equations: [
            {
              lhs: { op: 'D', args: ['temp'], wrt: 't' },
              rhs: { op: '+', args: [0, 'external_temperature_forcing'] },
            },
          ],
        },
      },
      coupling: [
        {
          type: 'callback',
          callback_id: 'cb',
          config: {
            target_system: 'WeatherModel',
            callback_variables: [{ name: couplingVarName, units: 'K/s' }],
          },
        },
      ],
    })

    // The callback declares exactly the name the equation uses.
    expect(
      validate(file('external_temperature_forcing')).structural_errors.filter(
        (e) => e.code === 'undefined_variable',
      ),
    ).toEqual([])

    // ...and the check still BITES: a callback declaring some OTHER name leaves
    // `external_temperature_forcing` genuinely undefined.
    const errors = validate(file('something_else')).structural_errors.filter(
      (e) => e.code === 'undefined_variable',
    )
    expect(errors).toHaveLength(1)
    expect((errors[0].details as { variable: string }).variable).toBe(
      'external_temperature_forcing',
    )
  })

  it('emits `details.variable` — not `variable_name` — at the new (h) sites', () => {
    // CONFORMANCE_SPEC row (j): the corpus settled on `variable`.
    const result = validate({
      esm: '1.0.0',
      metadata: { name: 'details-key' },
      models: {
        M: {
          variables: {
            u: { type: 'unknown', units: '1' },
            obs: { type: 'unknown', units: '1' },
          },
          equations: [
            { lhs: { op: 'D', args: ['u'], wrt: 't' }, rhs: 0 },
            { lhs: 'obs', rhs: { op: '*', args: [2, 'nope'] } },
          ],
        },
      },
    })
    const error = result.structural_errors.find((e) => e.code === 'undefined_variable')!
    expect(error.details).toHaveProperty('variable', 'nope')
    expect(error.details).not.toHaveProperty('variable_name')
  })
})

describe('an unknown defined as the constant 0 is not "missing" its defining equation', () => {
  // The original bug was a truthiness test: `!variable.expression` is true for
  // the NUMBER ZERO, so an observed variable defined as exactly `0.0` — e.g.
  // `temperature_factor` in `tests/valid/events_cross_system.esm` — was reported
  // as `missing_observed_expr`.
  //
  // 1.0.0 retires that code along with the `expression` sidecar it read: an
  // unknown is DEFINED by an equation, and the discriminating power the code had
  // now lives in `equation_count_mismatch`'s `missing_equations_for`, which names
  // exactly the unknowns nothing defines. The falsy-zero trap is unchanged in
  // kind (an equation whose RHS is `0` still defines its LHS), so the guard is
  // kept, retargeted at the check that replaced it.
  const withRhs = (rhs: unknown) => ({
    esm: '1.0.0',
    metadata: { name: 'falsy-zero' },
    models: {
      M: {
        variables: {
          u: { type: 'unknown', units: '1' },
          obs: { type: 'unknown', units: '1' },
        },
        equations: [
          { lhs: { op: 'D', args: ['u'], wrt: 't' }, rhs: 0 },
          { lhs: 'obs', rhs },
        ],
      },
    },
  })
  const mismatches = (file: object) =>
    validate(file).structural_errors.filter((e) => e.code === 'equation_count_mismatch')

  it('accepts the constant 0 as a defining right-hand side', () => {
    expect(mismatches(withRhs(0))).toEqual([])
    expect(mismatches(withRhs(0.0))).toEqual([])
    expect(validate(withRhs(0)).is_valid).toBe(true)
  })

  it('still reports an unknown that no equation defines', () => {
    // Drop the defining equation entirely: `obs` is now an unknown with nothing
    // to state it, which is the 1.0.0 shape of "an observed variable with no
    // expression" — an equation-balance error that NAMES the offending unknown.
    const file = withRhs(0)
    file.models.M.equations.pop()

    const errors = mismatches(file)
    expect(errors).toHaveLength(1)
    expect(errors[0].path).toBe('/models/M')
    expect(errors[0].message).toBe('Number of equations (1) does not match number of unknowns (2)')
    expect(errors[0].details).toEqual({
      unknowns: ['u', 'obs'],
      equations: 1,
      missing_equations_for: ['obs'],
    })
    expect(validate(file).is_valid).toBe(false)
  })
})

/**
 * F-2 — `validate(data, { basePath })`.
 *
 * `validate()` is contractually I/O-free, which means that WITHOUT a base
 * directory it cannot open a `{ref}` target and therefore cannot tell a MISSING
 * mount from a PRESENT one: both come back `unresolved_subsystem_ref`. Every
 * subsystem-ref and template-import pin in the shared corpus is unsatisfiable
 * under that signature — the harness asserts a `(code, path)` pair the binding
 * has no way to compute.
 *
 * `basePath` closes that hole. It is OPTIONAL, so the old signature keeps its old
 * behaviour exactly.
 */
describe('validate({ basePath }) resolves relative refs and template imports', () => {
  const fixture = (rel: string) => join(REPO_ROOT, rel)
  const codes = (r: ReturnType<typeof validate>) =>
    [...r.schema_errors, ...r.structural_errors].map((e) => `${e.code}@${e.path}`)

  it('validates a subsystem-ref fixture clean WITH a basePath, and reports it unresolved WITHOUT one', () => {
    const path = fixture('tests/valid/lib_calendar_subsystem_inclusion.esm')
    const content = readFileSync(path, 'utf-8')

    // WITH: the `{ref}` mount is opened, the component is inlined, and the
    // observed expression's `Calendar.seconds_since_midnight` now resolves.
    expect(validate(content, { basePath: dirname(path) }).is_valid).toBe(true)

    // WITHOUT: unchanged legacy behaviour — the mount is honestly reported as
    // unresolved rather than silently passed over.
    const without = validate(content)
    expect(without.is_valid).toBe(false)
    expect(codes(without)).toContain('unresolved_subsystem_ref@/models/Diurnal/subsystems/Calendar')
  })

  it('resolves the §4.7 index-set merge and §9.7 template imports through a basePath', () => {
    for (const rel of [
      'tests/valid/subsystem_index_set_merge.esm',
      'tests/valid/template_import_minimal.esm',
    ]) {
      const path = fixture(rel)
      const result = validate(readFileSync(path, 'utf-8'), { basePath: dirname(path) })
      expect(result.is_valid, `${rel}: ${codes(result).join(', ')}`).toBe(true)
    }
  })

  it('still REJECTS a ref whose target does not exist, at the offending mount', () => {
    // The point of `basePath` is that a present target and a missing one become
    // distinguishable. This one is genuinely missing, and must stay rejected —
    // with the pinned code, at the pinned path (the mount, not the document root).
    const path = fixture('tests/invalid/subsystem_ref_not_found.esm')
    const result = validate(readFileSync(path, 'utf-8'), { basePath: dirname(path) })
    expect(result.is_valid).toBe(false)
    expect(codes(result)).toContain(
      'unresolved_subsystem_ref@/models/Atmosphere/subsystems/Missing',
    )
  })

  it('reports an AMBIGUOUS target — a verdict only reachable by opening the file', () => {
    // §4.7 requires a referenced file to hold exactly one top-level component;
    // this target holds three. No I/O-free checker can know that, so without a
    // `basePath` the best available answer is the coarser "unresolved".
    const path = fixture('tests/invalid/subsystem_ref_ambiguous.esm')
    const content = readFileSync(path, 'utf-8')

    expect(codes(validate(content, { basePath: dirname(path) }))).toContain(
      'ambiguous_subsystem_ref@/models/ClimateModel/subsystems/Atm',
    )
    expect(codes(validate(content))).toContain(
      'unresolved_subsystem_ref@/models/ClimateModel/subsystems/Atm',
    )
  })
})
