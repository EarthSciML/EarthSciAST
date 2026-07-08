/**
 * Tests for expression substitution functionality
 */

import { describe, it, expect } from 'vitest'
import {
  substitute,
  substituteInModel,
  substituteInReactionSystem,
  type SubstitutionContext,
} from './substitute.js'
import type { Expr, Model, ReactionSystem, EsmFile, Reaction } from './types.js'

describe('substitute', () => {
  it('handles number literals unchanged', () => {
    const expr: Expr = 42
    const bindings = { x: 10 }
    expect(substitute(expr, bindings)).toBe(42)
  })

  it('substitutes simple variable references', () => {
    const expr: Expr = 'x'
    const bindings = { x: 42 }
    expect(substitute(expr, bindings)).toBe(42)
  })

  it('leaves unbound variables unchanged', () => {
    const expr: Expr = 'y'
    const bindings = { x: 42 }
    expect(substitute(expr, bindings)).toBe('y')
  })

  it('substitutes variables with expressions', () => {
    const expr: Expr = 'x'
    const bindings: Record<string, Expr> = { x: { op: '+', args: [1, 2] } }
    expect(substitute(expr, bindings)).toEqual({ op: '+', args: [1, 2] })
  })

  it('handles nested function calls', () => {
    const expr: Expr = {
      op: 'exp',
      args: [
        {
          op: '/',
          args: [
            {
              op: '*',
              args: [-1370, 'T'],
            },
            'R',
          ],
        },
      ],
    }
    const bindings = { T: 298.15, R: 8.314 }
    const expected: Expr = {
      op: 'exp',
      args: [
        {
          op: '/',
          args: [
            {
              op: '*',
              args: [-1370, 298.15],
            },
            8.314,
          ],
        },
      ],
    }
    expect(substitute(expr, bindings)).toEqual(expected)
  })

  it('handles multiple levels of nesting with repeated variables', () => {
    const expr: Expr = {
      op: '+',
      args: [
        { op: '*', args: ['A', { op: 'sin', args: [{ op: '*', args: ['omega', 't'] }] }] },
        { op: '*', args: ['A', { op: 'cos', args: [{ op: '*', args: ['omega', 't'] }] }] },
      ],
    }
    const bindings = { A: 2.5, omega: 1.5 }
    const expected: Expr = {
      op: '+',
      args: [
        { op: '*', args: [2.5, { op: 'sin', args: [{ op: '*', args: [1.5, 't'] }] }] },
        { op: '*', args: [2.5, { op: 'cos', args: [{ op: '*', args: [1.5, 't'] }] }] },
      ],
    }
    expect(substitute(expr, bindings)).toEqual(expected)
  })

  it('handles derivative expressions', () => {
    const expr: Expr = {
      op: 'D',
      args: [{ op: '*', args: ['k', 'concentration'] }],
      wrt: 't',
    }
    const bindings = { k: 0.1, concentration: 'C_species' }
    const expected: Expr = {
      op: 'D',
      args: [{ op: '*', args: [0.1, 'C_species'] }],
      wrt: 't',
    }
    expect(substitute(expr, bindings)).toEqual(expected)
  })

  it('handles conditional expressions', () => {
    const expr: Expr = {
      op: 'ifelse',
      args: [
        { op: '>', args: [{ op: '*', args: ['x', 'scale'] }, 'threshold'] },
        { op: '*', args: ['x', 'amplification'] },
        { op: '/', args: ['x', 'damping'] },
      ],
    }
    const bindings = { scale: 2.0, threshold: 10.0, amplification: 1.5, damping: 0.8 }
    const expected: Expr = {
      op: 'ifelse',
      args: [
        { op: '>', args: [{ op: '*', args: ['x', 2.0] }, 10.0] },
        { op: '*', args: ['x', 1.5] },
        { op: '/', args: ['x', 0.8] },
      ],
    }
    expect(substitute(expr, bindings)).toEqual(expected)
  })

  it('handles scoped references (Model.Subsystem.var)', () => {
    const expr: Expr = {
      op: '+',
      args: [
        'SuperFast.GasPhase.O3',
        { op: '*', args: ['SuperFast.k_NO_O3', 'SuperFast.GasPhase.NO'] },
      ],
    }
    const bindings = {
      'SuperFast.GasPhase.O3': 1.0e-8,
      'SuperFast.k_NO_O3': 1.8e-12,
      'SuperFast.GasPhase.NO': 1.0e-10,
    }
    const expected: Expr = {
      op: '+',
      args: [1.0e-8, { op: '*', args: [1.8e-12, 1.0e-10] }],
    }
    expect(substitute(expr, bindings)).toEqual(expected)
  })

  it('fails to resolve hierarchical scoped references without full context', () => {
    // This test demonstrates the current limitation:
    // When bindings only contain variable names without the full scoped path,
    // the substitute function cannot resolve scoped references like "Model.Subsystem.var"
    const expr: Expr = {
      op: '+',
      args: [
        'SuperFast.GasPhase.O3', // This scoped reference won't be found
        'k_NO_O3', // This direct reference will be found
      ],
    }

    // Bindings contain only local variable names (as they would appear within a system)
    const bindings = {
      O3: 1.0e-8, // Local variable name within GasPhase subsystem
      k_NO_O3: 1.8e-12, // Variable name within SuperFast system
    }

    const result = substitute(expr, bindings)

    // The scoped reference should remain unresolved (as a string)
    // because the current implementation can't navigate the hierarchy
    expect(result).toEqual({
      op: '+',
      args: [
        'SuperFast.GasPhase.O3', // Unchanged - not resolved
        1.8e-12, // Resolved from direct binding
      ],
    })
  })

  it('resolves hierarchical scoped references with context', () => {
    // Create a mock ESM file with hierarchical structure
    const esmFile: EsmFile = {
      esm: '0.1.0',
      metadata: { name: 'test' },
      models: {
        SuperFast: {
          variables: {
            k_NO_O3: { type: 'parameter', default: 1.8e-12 },
          },
          equations: [],
          subsystems: {
            GasPhase: {
              variables: {
                O3: { type: 'state', default: 1.0e-8 },
                NO: { type: 'state', default: 1.0e-10 },
              },
              equations: [],
            },
          },
        },
      },
    }

    const context: SubstitutionContext = { esmFile }

    const expr: Expr = {
      op: '+',
      args: [
        'SuperFast.GasPhase.O3', // Should resolve to 1.0e-8
        { op: '*', args: ['SuperFast.k_NO_O3', 'SuperFast.GasPhase.NO'] }, // Should resolve to 1.8e-12 * 1.0e-10
      ],
    }

    const bindings = {} // No direct bindings needed - using scoped resolution

    const result = substitute(expr, bindings, context)

    const expected: Expr = {
      op: '+',
      args: [1.0e-8, { op: '*', args: [1.8e-12, 1.0e-10] }],
    }

    expect(result).toEqual(expected)
  })

  it('resolves scoped references in reaction systems', () => {
    const esmFile: EsmFile = {
      esm: '0.1.0',
      metadata: { name: 'test' },
      reaction_systems: {
        SimpleOzone: {
          species: {
            O3: { default: 40e-9 },
            NO: { default: 0.1e-9 },
          },
          parameters: {
            T: { default: 298.15 },
          },
          reactions: [
            // Off-schema empty substrate/product lists (the schema requires
            // null or a non-empty list); irrelevant to the scoped-reference
            // lookup under test, so keep the fixture as-is via a cast.
            {
              id: 'R1',
              substrates: [],
              products: [],
              rate: 1.0,
            } as unknown as Reaction,
          ],
        },
      },
    }

    const context: SubstitutionContext = { esmFile }

    const expr: Expr = {
      op: 'exp',
      args: [{ op: '/', args: [-1370, 'SimpleOzone.T'] }],
    }

    const result = substitute(expr, {}, context)

    const expected: Expr = {
      op: 'exp',
      args: [{ op: '/', args: [-1370, 298.15] }],
    }

    expect(result).toEqual(expected)
  })

  it('handles scoped references to data loaders', () => {
    const esmFile: EsmFile = {
      esm: '0.1.0',
      metadata: { name: 'test' },
      data_loaders: {
        GEOSFP: {
          kind: 'grid',
          source: {
            url_template: 's3://geosfp/{date:%Y/%m/%d}/GEOSFP.{date:%Y%m%d}.A1.05x0625.nc4',
          },
          variables: {
            T: { file_variable: 'T', units: 'K', description: 'Temperature' },
            u: { file_variable: 'U', units: 'm/s', description: 'Eastward wind' },
          },
        },
      },
    }

    const context: SubstitutionContext = { esmFile }

    const expr: Expr = {
      op: '*',
      args: ['GEOSFP.T', 'scale_factor'],
    }

    const bindings = { scale_factor: 1.1 }

    const result = substitute(expr, bindings, context)

    // For data loaders, the reference should remain as is since they don't have default values
    const expected: Expr = {
      op: '*',
      args: ['GEOSFP.T', 1.1],
    }

    expect(result).toEqual(expected)
  })
})

describe('substituteInModel', () => {
  it('substitutes in model equations', () => {
    const model: Model = {
      variables: {
        x: { type: 'state', units: 'm' },
        k: { type: 'parameter', default: 1.0 },
      },
      equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: { op: '*', args: ['k', 'x'] } }],
    }
    const bindings = { k: 2.5 }
    const result = substituteInModel(model, bindings)

    expect(result.equations[0]!.rhs).toEqual({ op: '*', args: [2.5, 'x'] })
    expect(result.variables).toEqual(model.variables) // Variables unchanged
  })

  it('substitutes in observed variable expressions', () => {
    const model: Model = {
      variables: {
        x: { type: 'state' },
        y: { type: 'observed', expression: { op: '*', args: ['k', 'x'] } },
      },
      equations: [],
    }
    const bindings = { k: 2.0 }
    const result = substituteInModel(model, bindings)

    expect(result.variables.y?.expression).toEqual({ op: '*', args: [2.0, 'x'] })
  })
})

describe('substituteInReactionSystem', () => {
  it('substitutes in reaction rate expressions', () => {
    const system: ReactionSystem = {
      species: {
        A: { units: 'mol/L' },
        B: { units: 'mol/L' },
      },
      parameters: {
        k: { default: 1.0, units: '1/s' },
      },
      reactions: [
        {
          id: 'R1',
          substrates: [{ species: 'A', stoichiometry: 1 }],
          products: [{ species: 'B', stoichiometry: 1 }],
          rate: { op: '*', args: ['k', 'A'] },
        },
      ],
    }
    const bindings = { k: 1.5 }
    const result = substituteInReactionSystem(system, bindings)

    expect(result.reactions[0]!.rate).toEqual({ op: '*', args: [1.5, 'A'] })
  })

  it('substitutes in constraint equations when present', () => {
    const system: ReactionSystem = {
      species: { A: { units: 'mol/L' } },
      parameters: { k: { default: 1.0 } },
      reactions: [{ id: 'R1', substrates: null, products: null, rate: 1.0 }],
      constraint_equations: [{ lhs: 'total', rhs: { op: '*', args: ['k', 'A'] } }],
    }
    const bindings = { k: 2.0 }
    const result = substituteInReactionSystem(system, bindings)

    expect(result.constraint_equations?.[0]?.rhs).toEqual({ op: '*', args: [2.0, 'A'] })
  })
})
