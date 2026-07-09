import { describe, it, expect } from 'vitest'
import { deriveODEs, stoichiometricMatrix, substrateMatrix, productMatrix } from './reactions.js'
import { isExprNode } from './expression.js'
import type { ReactionSystem } from './types.js'

describe('Reaction system ODE derivation', () => {
  describe('deriveODEs', () => {
    it('should handle simple single reaction', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 1.0 },
          B: { units: 'mol/L', default: 0.0 },
        },
        parameters: {
          k1: { default: 0.1, units: '1/s' },
        },
        reactions: [
          {
            id: 'R1',
            substrates: [{ species: 'A', stoichiometry: 1 }],
            products: [{ species: 'B', stoichiometry: 1 }],
            rate: 'k1',
          },
        ],
      }

      const model = deriveODEs(system)

      // Check variables
      expect(model.variables.A).toEqual({
        type: 'state',
        units: 'mol/L',
        default: 1.0,
      })
      expect(model.variables.B).toEqual({
        type: 'state',
        units: 'mol/L',
        default: 0.0,
      })
      expect(model.variables.k1).toEqual({
        type: 'parameter',
        default: 0.1,
        units: '1/s',
      })

      // Check equations
      expect(model.equations).toHaveLength(2)

      // d[A]/dt = -k1 * A
      const eqnA = model.equations.find(
        (eq) =>
          isExprNode(eq.lhs) && eq.lhs.op === 'D' && eq.lhs.args[0] === 'A' && eq.lhs.wrt === 't',
      )
      expect(eqnA).toBeDefined()
      expect(eqnA?.rhs).toEqual({
        op: '-',
        args: [{ op: '*', args: ['k1', 'A'] }],
      })

      // d[B]/dt = k1 * A
      const eqnB = model.equations.find(
        (eq) =>
          isExprNode(eq.lhs) && eq.lhs.op === 'D' && eq.lhs.args[0] === 'B' && eq.lhs.wrt === 't',
      )
      expect(eqnB).toBeDefined()
      expect(eqnB?.rhs).toEqual({
        op: '*',
        args: ['k1', 'A'],
      })
    })

    it('should handle source reaction (null substrates)', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 0.0 },
        },
        parameters: {
          k_source: { default: 0.5, units: 'mol/L/s' },
        },
        reactions: [
          {
            id: 'R_source',
            substrates: null, // Source reaction: ∅ → A
            products: [{ species: 'A', stoichiometry: 1 }],
            rate: 'k_source',
          },
        ],
      }

      const model = deriveODEs(system)

      // d[A]/dt = k_source (direct production)
      const eqnA = model.equations.find(
        (eq) =>
          isExprNode(eq.lhs) && eq.lhs.op === 'D' && eq.lhs.args[0] === 'A' && eq.lhs.wrt === 't',
      )
      expect(eqnA?.rhs).toBe('k_source')
    })

    it('should handle sink reaction (null products)', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 1.0 },
        },
        parameters: {
          k_sink: { default: 0.1, units: '1/s' },
        },
        reactions: [
          {
            id: 'R_sink',
            substrates: [{ species: 'A', stoichiometry: 1 }],
            products: null, // Sink reaction: A → ∅
            rate: 'k_sink',
          },
        ],
      }

      const model = deriveODEs(system)

      // d[A]/dt = -k_sink * A (direct loss)
      const eqnA = model.equations.find(
        (eq) =>
          isExprNode(eq.lhs) && eq.lhs.op === 'D' && eq.lhs.args[0] === 'A' && eq.lhs.wrt === 't',
      )
      expect(eqnA?.rhs).toEqual({
        op: '-',
        args: [{ op: '*', args: ['k_sink', 'A'] }],
      })
    })

    it('should handle reactions with stoichiometry > 1', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 1.0 },
          B: { units: 'mol/L', default: 0.0 },
        },
        parameters: {
          k1: { default: 0.1, units: 'L/mol/s' },
        },
        reactions: [
          {
            id: 'R1',
            substrates: [{ species: 'A', stoichiometry: 2 }], // 2A → B
            products: [{ species: 'B', stoichiometry: 1 }],
            rate: 'k1',
          },
        ],
      }

      const model = deriveODEs(system)

      // d[A]/dt = -2 * k1 * A^2
      const eqnA = model.equations.find(
        (eq) =>
          isExprNode(eq.lhs) && eq.lhs.op === 'D' && eq.lhs.args[0] === 'A' && eq.lhs.wrt === 't',
      )
      expect(eqnA?.rhs).toEqual({
        op: '*',
        args: [-2, { op: '*', args: ['k1', { op: '^', args: ['A', 2] }] }],
      })

      // d[B]/dt = k1 * A^2
      const eqnB = model.equations.find(
        (eq) =>
          isExprNode(eq.lhs) && eq.lhs.op === 'D' && eq.lhs.args[0] === 'B' && eq.lhs.wrt === 't',
      )
      expect(eqnB?.rhs).toEqual({
        op: '*',
        args: ['k1', { op: '^', args: ['A', 2] }],
      })
    })

    it('should handle multiple reactions affecting same species', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 1.0 },
          B: { units: 'mol/L', default: 0.0 },
          C: { units: 'mol/L', default: 0.0 },
        },
        parameters: {
          k1: { default: 0.1, units: '1/s' },
          k2: { default: 0.05, units: '1/s' },
        },
        reactions: [
          {
            id: 'R1',
            substrates: [{ species: 'A', stoichiometry: 1 }],
            products: [{ species: 'B', stoichiometry: 1 }],
            rate: 'k1',
          },
          {
            id: 'R2',
            substrates: [{ species: 'A', stoichiometry: 1 }],
            products: [{ species: 'C', stoichiometry: 1 }],
            rate: 'k2',
          },
        ],
      }

      const model = deriveODEs(system)

      // d[A]/dt = -(k1 * A) - (k2 * A) = -(k1 + k2) * A (summed terms)
      const eqnA = model.equations.find(
        (eq) =>
          isExprNode(eq.lhs) && eq.lhs.op === 'D' && eq.lhs.args[0] === 'A' && eq.lhs.wrt === 't',
      )
      expect(eqnA?.rhs).toEqual({
        op: '+',
        args: [
          { op: '-', args: [{ op: '*', args: ['k1', 'A'] }] },
          { op: '-', args: [{ op: '*', args: ['k2', 'A'] }] },
        ],
      })

      // d[B]/dt = k1 * A
      const eqnB = model.equations.find(
        (eq) =>
          isExprNode(eq.lhs) && eq.lhs.op === 'D' && eq.lhs.args[0] === 'B' && eq.lhs.wrt === 't',
      )
      expect(eqnB?.rhs).toEqual({
        op: '*',
        args: ['k1', 'A'],
      })

      // d[C]/dt = k2 * A
      const eqnC = model.equations.find(
        (eq) =>
          isExprNode(eq.lhs) && eq.lhs.op === 'D' && eq.lhs.args[0] === 'C' && eq.lhs.wrt === 't',
      )
      expect(eqnC?.rhs).toEqual({
        op: '*',
        args: ['k2', 'A'],
      })
    })

    it('should handle species with no reactions', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 1.0 },
          B: { units: 'mol/L', default: 0.0 }, // B is not in any reactions
        },
        parameters: {
          k1: { default: 0.1, units: '1/s' },
        },
        reactions: [
          // Only reaction: A → ∅ (sink)
          {
            id: 'R1',
            substrates: [{ species: 'A', stoichiometry: 1 }],
            products: null,
            rate: 'k1',
          },
        ],
      }

      const model = deriveODEs(system)

      // d[B]/dt = 0 (no reactions affect B)
      const eqnB = model.equations.find(
        (eq) =>
          isExprNode(eq.lhs) && eq.lhs.op === 'D' && eq.lhs.args[0] === 'B' && eq.lhs.wrt === 't',
      )
      expect(eqnB?.rhs).toBe(0)
    })

    it('should append constraint equations', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 1.0 },
          B: { units: 'mol/L', default: 0.0 },
        },
        parameters: {
          k1: { default: 0.1, units: '1/s' },
          total: { default: 1.0, units: 'mol/L' },
        },
        reactions: [
          {
            id: 'R1',
            substrates: [{ species: 'A', stoichiometry: 1 }],
            products: [{ species: 'B', stoichiometry: 1 }],
            rate: 'k1',
          },
        ],
        constraint_equations: [
          {
            lhs: 'total',
            rhs: { op: '+', args: ['A', 'B'] }, // Conservation constraint
          },
        ],
      }

      const model = deriveODEs(system)

      // Should have 2 ODEs + 1 constraint = 3 equations total
      expect(model.equations).toHaveLength(3)

      // Check that constraint equation was appended
      const constraintEqn = model.equations.find((eq) => eq.lhs === 'total')
      expect(constraintEqn).toBeDefined()
      expect(constraintEqn?.rhs).toEqual({
        op: '+',
        args: ['A', 'B'],
      })
    })

    it('should preserve reference', () => {
      const system: ReactionSystem = {
        reference: { doi: '10.1000/test', url: 'https://example.com' },
        species: {
          A: { units: 'mol/L', default: 1.0 },
        },
        parameters: {
          k1: { default: 0.1, units: '1/s' },
        },
        reactions: [
          {
            id: 'R1',
            substrates: [{ species: 'A', stoichiometry: 1 }],
            products: null,
            rate: 'k1',
          },
        ],
      }

      const model = deriveODEs(system)

      expect(model.reference).toEqual({ doi: '10.1000/test', url: 'https://example.com' })
    })

    it('should handle complex rate expressions', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 1.0 },
          B: { units: 'mol/L', default: 0.0 },
        },
        parameters: {
          k_base: { default: 0.1, units: '1/s' },
          T: { default: 298, units: 'K' },
        },
        reactions: [
          {
            id: 'R1',
            substrates: [{ species: 'A', stoichiometry: 1 }],
            products: [{ species: 'B', stoichiometry: 1 }],
            rate: {
              op: '*',
              args: ['k_base', { op: 'exp', args: [{ op: '/', args: [1000, 'T'] }] }],
            }, // Arrhenius rate: k_base * exp(1000/T)
          },
        ],
      }

      const model = deriveODEs(system)

      // d[A]/dt = -(k_base * exp(1000/T)) * A
      const eqnA = model.equations.find(
        (eq) =>
          isExprNode(eq.lhs) && eq.lhs.op === 'D' && eq.lhs.args[0] === 'A' && eq.lhs.wrt === 't',
      )
      expect(eqnA?.rhs).toEqual({
        op: '-',
        args: [
          {
            op: '*',
            args: [
              {
                op: '*',
                args: ['k_base', { op: 'exp', args: [{ op: '/', args: [1000, 'T'] }] }],
              },
              'A',
            ],
          },
        ],
      })
    })
  })

  describe('stoichiometricMatrix', () => {
    it('should compute net stoichiometric matrix for simple reaction', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 1.0 },
          B: { units: 'mol/L', default: 0.0 },
        },
        parameters: {
          k1: { default: 0.1, units: '1/s' },
        },
        reactions: [
          {
            id: 'R1',
            substrates: [{ species: 'A', stoichiometry: 1 }],
            products: [{ species: 'B', stoichiometry: 1 }],
            rate: 'k1',
          },
        ],
      }

      const result = stoichiometricMatrix(system)

      expect(result.species).toEqual(['A', 'B'])
      expect(result.reactions).toEqual(['R1'])
      expect(result.matrix).toEqual([
        [-1], // A: -1 (substrate)
        [1], // B: +1 (product)
      ])
    })

    it('should handle multiple reactions and species', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 1.0 },
          B: { units: 'mol/L', default: 0.0 },
          C: { units: 'mol/L', default: 0.0 },
        },
        parameters: {
          k1: { default: 0.1, units: '1/s' },
          k2: { default: 0.05, units: '1/s' },
        },
        reactions: [
          {
            id: 'R1',
            substrates: [{ species: 'A', stoichiometry: 1 }],
            products: [{ species: 'B', stoichiometry: 1 }],
            rate: 'k1',
          },
          {
            id: 'R2',
            substrates: [{ species: 'B', stoichiometry: 1 }],
            products: [{ species: 'C', stoichiometry: 1 }],
            rate: 'k2',
          },
        ],
      }

      const result = stoichiometricMatrix(system)

      expect(result.species).toEqual(['A', 'B', 'C'])
      expect(result.reactions).toEqual(['R1', 'R2'])
      expect(result.matrix).toEqual([
        [-1, 0], // A: -1 in R1, 0 in R2
        [1, -1], // B: +1 in R1, -1 in R2
        [0, 1], // C: 0 in R1, +1 in R2
      ])
    })

    it('should handle source reactions (null substrates)', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 0.0 },
        },
        parameters: {
          k_source: { default: 0.5, units: 'mol/L/s' },
        },
        reactions: [
          {
            id: 'R_source',
            substrates: null,
            products: [{ species: 'A', stoichiometry: 1 }],
            rate: 'k_source',
          },
        ],
      }

      const result = stoichiometricMatrix(system)

      expect(result.matrix).toEqual([
        [1], // A: 0 (no substrates) - 0 + 1 (product) = +1
      ])
    })

    it('should handle sink reactions (null products)', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 1.0 },
        },
        parameters: {
          k_sink: { default: 0.1, units: '1/s' },
        },
        reactions: [
          {
            id: 'R_sink',
            substrates: [{ species: 'A', stoichiometry: 1 }],
            products: null,
            rate: 'k_sink',
          },
        ],
      }

      const result = stoichiometricMatrix(system)

      expect(result.matrix).toEqual([
        [-1], // A: 0 (no products) - 1 (substrate) = -1
      ])
    })

    it('should handle reactions with stoichiometry > 1', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 1.0 },
          B: { units: 'mol/L', default: 0.0 },
        },
        parameters: {
          k1: { default: 0.1, units: 'L/mol/s' },
        },
        reactions: [
          {
            id: 'R1',
            substrates: [{ species: 'A', stoichiometry: 2 }],
            products: [{ species: 'B', stoichiometry: 1 }],
            rate: 'k1',
          },
        ],
      }

      const result = stoichiometricMatrix(system)

      expect(result.matrix).toEqual([
        [-2], // A: 0 - 2 = -2
        [1], // B: 1 - 0 = +1
      ])
    })

    it('should handle species not involved in reactions', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 1.0 },
          B: { units: 'mol/L', default: 0.0 },
          C: { units: 'mol/L', default: 0.0 }, // Not in any reactions
        },
        parameters: {
          k1: { default: 0.1, units: '1/s' },
        },
        reactions: [
          {
            id: 'R1',
            substrates: [{ species: 'A', stoichiometry: 1 }],
            products: [{ species: 'B', stoichiometry: 1 }],
            rate: 'k1',
          },
        ],
      }

      const result = stoichiometricMatrix(system)

      expect(result.matrix).toEqual([
        [-1], // A: -1
        [1], // B: +1
        [0], // C: 0 (not involved)
      ])
    })
  })

  describe('substrateMatrix', () => {
    it('should compute substrate stoichiometric matrix', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 1.0 },
          B: { units: 'mol/L', default: 0.0 },
        },
        parameters: {
          k1: { default: 0.1, units: '1/s' },
        },
        reactions: [
          {
            id: 'R1',
            substrates: [{ species: 'A', stoichiometry: 2 }],
            products: [{ species: 'B', stoichiometry: 1 }],
            rate: 'k1',
          },
        ],
      }

      const result = substrateMatrix(system)

      expect(result).toEqual([
        [2], // A: substrate with stoichiometry 2
        [0], // B: not a substrate
      ])
    })

    it('should handle null substrates (source reactions)', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 0.0 },
        },
        parameters: {
          k_source: { default: 0.5, units: 'mol/L/s' },
        },
        reactions: [
          {
            id: 'R_source',
            substrates: null,
            products: [{ species: 'A', stoichiometry: 1 }],
            rate: 'k_source',
          },
        ],
      }

      const result = substrateMatrix(system)

      expect(result).toEqual([
        [0], // A: no substrates
      ])
    })

    it('should handle multiple reactions', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 1.0 },
          B: { units: 'mol/L', default: 0.0 },
          C: { units: 'mol/L', default: 0.0 },
        },
        parameters: {
          k1: { default: 0.1, units: '1/s' },
          k2: { default: 0.05, units: '1/s' },
        },
        reactions: [
          {
            id: 'R1',
            substrates: [{ species: 'A', stoichiometry: 1 }],
            products: [{ species: 'B', stoichiometry: 1 }],
            rate: 'k1',
          },
          {
            id: 'R2',
            substrates: [{ species: 'B', stoichiometry: 2 }],
            products: [{ species: 'C', stoichiometry: 1 }],
            rate: 'k2',
          },
        ],
      }

      const result = substrateMatrix(system)

      expect(result).toEqual([
        [1, 0], // A: substrate in R1 with stoich 1, not in R2
        [0, 2], // B: not substrate in R1, substrate in R2 with stoich 2
        [0, 0], // C: not a substrate in either reaction
      ])
    })
  })

  describe('productMatrix', () => {
    it('should compute product stoichiometric matrix', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 1.0 },
          B: { units: 'mol/L', default: 0.0 },
        },
        parameters: {
          k1: { default: 0.1, units: '1/s' },
        },
        reactions: [
          {
            id: 'R1',
            substrates: [{ species: 'A', stoichiometry: 1 }],
            products: [{ species: 'B', stoichiometry: 2 }],
            rate: 'k1',
          },
        ],
      }

      const result = productMatrix(system)

      expect(result).toEqual([
        [0], // A: not a product
        [2], // B: product with stoichiometry 2
      ])
    })

    it('should handle null products (sink reactions)', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 1.0 },
        },
        parameters: {
          k_sink: { default: 0.1, units: '1/s' },
        },
        reactions: [
          {
            id: 'R_sink',
            substrates: [{ species: 'A', stoichiometry: 1 }],
            products: null,
            rate: 'k_sink',
          },
        ],
      }

      const result = productMatrix(system)

      expect(result).toEqual([
        [0], // A: no products
      ])
    })

    it('should handle multiple reactions', () => {
      const system: ReactionSystem = {
        species: {
          A: { units: 'mol/L', default: 1.0 },
          B: { units: 'mol/L', default: 0.0 },
          C: { units: 'mol/L', default: 0.0 },
        },
        parameters: {
          k1: { default: 0.1, units: '1/s' },
          k2: { default: 0.05, units: '1/s' },
        },
        reactions: [
          {
            id: 'R1',
            substrates: [{ species: 'A', stoichiometry: 1 }],
            products: [{ species: 'B', stoichiometry: 2 }],
            rate: 'k1',
          },
          {
            id: 'R2',
            substrates: [{ species: 'B', stoichiometry: 1 }],
            products: [{ species: 'C', stoichiometry: 3 }],
            rate: 'k2',
          },
        ],
      }

      const result = productMatrix(system)

      expect(result).toEqual([
        [0, 0], // A: not a product in either reaction
        [2, 0], // B: product in R1 with stoich 2, not in R2
        [0, 3], // C: not product in R1, product in R2 with stoich 3
      ])
    })
  })
})
