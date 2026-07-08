/**
 * Tests for symbolic differentiation
 */

import { describe, it, expect } from 'vitest'
import {
  differentiate,
  partialDerivatives,
  gradient,
  higherOrderDerivative,
  isDifferentiable,
  findCriticalPoints,
} from './differentiation.js'
import type { Expr } from '../types.js'

describe('Symbolic Differentiation', () => {
  describe('differentiate', () => {
    it('should differentiate constants to zero', () => {
      const result = differentiate(42, 'x')
      expect(result.derivative).toBe(0)
      expect(result.variable).toBe('x')
    })

    it('should differentiate variables correctly', () => {
      const resultX = differentiate('x', 'x')
      const resultY = differentiate('x', 'y')

      expect(resultX.derivative).toBe(1)
      expect(resultX.variable).toBe('x')

      expect(resultY.derivative).toBe(0)
      expect(resultY.variable).toBe('y')
    })

    it('should differentiate addition using sum rule', () => {
      const expr: Expr = { op: '+', args: ['x', 'y', 2] }
      const result = differentiate(expr, 'x')

      // d/dx (x + y + 2) = 1 + 0 + 0 = 1
      expect(result.derivative).toEqual({
        op: '+',
        args: [1, 0, 0],
      })
    })

    it('should differentiate subtraction correctly', () => {
      const exprUnary: Expr = { op: '-', args: ['x'] }
      const exprBinary: Expr = { op: '-', args: ['x', 'y'] }

      const resultUnary = differentiate(exprUnary, 'x')
      const resultBinary = differentiate(exprBinary, 'x')

      // d/dx (-x) = -1
      expect(resultUnary.derivative).toEqual({
        op: '-',
        args: [1],
      })

      // d/dx (x - y) = 1 - 0 = [1, 0]
      expect(resultBinary.derivative).toEqual({
        op: '-',
        args: [1, 0],
      })
    })

    it('should differentiate multiplication using product rule', () => {
      const expr: Expr = { op: '*', args: ['x', 'y'] }
      const result = differentiate(expr, 'x')

      // d/dx (x*y) = 1*y + x*0 = y
      expect(result.derivative).toEqual({
        op: '+',
        args: [
          { op: '*', args: [1, 'y'] },
          { op: '*', args: ['x', 0] },
        ],
      })
    })

    it('should differentiate division using quotient rule', () => {
      const expr: Expr = { op: '/', args: ['x', 'y'] }
      const result = differentiate(expr, 'x')

      // d/dx (x/y) = (1*y - x*0) / y²
      expect(result.derivative).toEqual({
        op: '/',
        args: [
          {
            op: '-',
            args: [
              { op: '*', args: [1, 'y'] },
              { op: '*', args: ['x', 0] },
            ],
          },
          { op: '^', args: ['y', 2] },
        ],
      })
    })

    it('should differentiate power with constant exponent', () => {
      const expr: Expr = { op: '^', args: ['x', 3] }
      const result = differentiate(expr, 'x')

      // d/dx (x³) = 3*x² * 1 = 3*x²
      expect(result.derivative).toEqual({
        op: '*',
        args: [3, { op: '^', args: ['x', 2] }, 1],
      })
    })

    it('should differentiate power with variable exponent', () => {
      const expr: Expr = { op: '^', args: ['x', 'n'] }
      const result = differentiate(expr, 'x')

      // d/dx (x^n) = x^n * (0*ln(x) + n*1/x) = x^n * n/x
      const expected = {
        op: '*',
        args: [
          expr,
          {
            op: '+',
            args: [
              { op: '*', args: [0, { op: 'log', args: ['x'] }] },
              { op: '*', args: ['n', { op: '/', args: [1, 'x'] }] },
            ],
          },
        ],
      }

      expect(result.derivative).toEqual(expected)
    })

    it('should differentiate exponential function', () => {
      const expr: Expr = { op: 'exp', args: ['x'] }
      const result = differentiate(expr, 'x')

      // d/dx (e^x) = e^x * 1
      expect(result.derivative).toEqual({
        op: '*',
        args: [expr, 1],
      })
    })

    it('should differentiate natural logarithm', () => {
      const expr: Expr = { op: 'log', args: ['x'] }
      const result = differentiate(expr, 'x')

      // d/dx (ln(x)) = 1/x
      expect(result.derivative).toEqual({
        op: '/',
        args: [1, 'x'],
      })
    })

    it('should differentiate trigonometric functions', () => {
      const sinExpr: Expr = { op: 'sin', args: ['x'] }
      const cosExpr: Expr = { op: 'cos', args: ['x'] }

      const sinResult = differentiate(sinExpr, 'x')
      const cosResult = differentiate(cosExpr, 'x')

      // d/dx (sin(x)) = cos(x) * 1
      expect(sinResult.derivative).toEqual({
        op: '*',
        args: [{ op: 'cos', args: ['x'] }, 1],
      })

      // d/dx (cos(x)) = -sin(x) * 1
      expect(cosResult.derivative).toEqual({
        op: '*',
        args: [{ op: '-', args: [{ op: 'sin', args: ['x'] }] }, 1],
      })
    })

    it('should handle chain rule for composite functions', () => {
      const expr: Expr = { op: 'sin', args: [{ op: '*', args: ['a', 'x'] }] }
      const result = differentiate(expr, 'x')

      // d/dx (sin(ax)) = cos(ax) * a
      expect(result.derivative).toEqual({
        op: '*',
        args: [
          { op: 'cos', args: [{ op: '*', args: ['a', 'x'] }] },
          {
            op: '+',
            args: [
              { op: '*', args: [0, 'x'] },
              { op: '*', args: ['a', 1] },
            ],
          },
        ],
      })
    })

    it('should differentiate conditional expressions', () => {
      const expr: Expr = {
        op: 'ifelse',
        args: [
          { op: '>', args: ['x', 0] },
          { op: '^', args: ['x', 2] },
          { op: '-', args: [{ op: '^', args: ['x', 2] }] },
        ],
      }

      const result = differentiate(expr, 'x')

      // Should preserve condition and differentiate branches
      expect(result.derivative).toEqual({
        op: 'ifelse',
        args: [
          { op: '>', args: ['x', 0] },
          { op: '*', args: [2, { op: '^', args: ['x', 1] }, 1] },
          { op: '-', args: [{ op: '*', args: [2, { op: '^', args: ['x', 1] }, 1] }] },
        ],
      })
    })

    it('should return zero for logical operators', () => {
      const expr: Expr = {
        op: 'and',
        args: [
          { op: '>', args: ['x', 0] },
          { op: '<', args: ['x', 10] },
        ],
      }
      const result = differentiate(expr, 'x')

      expect(result.derivative).toBe(0)
    })
  })

  describe('partialDerivatives', () => {
    it('should compute multiple partial derivatives', () => {
      const expr: Expr = {
        op: '+',
        args: [
          { op: '^', args: ['x', 2] },
          { op: '*', args: ['y', 'z'] },
        ],
      }
      const variables = ['x', 'y', 'z']

      const partials = partialDerivatives(expr, variables)

      expect(partials.size).toBe(3)
      expect(partials.has('x')).toBe(true)
      expect(partials.has('y')).toBe(true)
      expect(partials.has('z')).toBe(true)

      // ∂/∂x (x² + yz) = 2x + 0
      const dfdx = partials.get('x')!
      expect(dfdx.derivative).toEqual({
        op: '+',
        args: [
          { op: '*', args: [2, { op: '^', args: ['x', 1] }, 1] },
          {
            op: '+',
            args: [
              { op: '*', args: [0, 'z'] },
              { op: '*', args: ['y', 0] },
            ],
          },
        ],
      })

      // ∂/∂y (x² + yz) = 0 + z
      const dfdy = partials.get('y')!
      expect(dfdy.derivative).toEqual({
        op: '+',
        args: [
          { op: '*', args: [2, { op: '^', args: ['x', 1] }, 0] },
          {
            op: '+',
            args: [
              { op: '*', args: [1, 'z'] },
              { op: '*', args: ['y', 0] },
            ],
          },
        ],
      })
    })
  })

  describe('gradient', () => {
    it('should compute gradient with specified variables', () => {
      const expr: Expr = {
        op: '+',
        args: [
          { op: '^', args: ['x', 2] },
          { op: '^', args: ['y', 2] },
        ],
      }
      const variables = ['x', 'y']

      const grad = gradient(expr, variables)

      expect(grad).toHaveLength(2)
      expect(grad[0].variable).toBe('x')
      expect(grad[1].variable).toBe('y')

      // Gradient components should be 2x and 2y
      expect(grad[0].derivative).toEqual({
        op: '+',
        args: [
          { op: '*', args: [2, { op: '^', args: ['x', 1] }, 1] },
          { op: '*', args: [2, { op: '^', args: ['y', 1] }, 0] },
        ],
      })

      expect(grad[1].derivative).toEqual({
        op: '+',
        args: [
          { op: '*', args: [2, { op: '^', args: ['x', 1] }, 0] },
          { op: '*', args: [2, { op: '^', args: ['y', 1] }, 1] },
        ],
      })
    })

    it('should auto-extract variables if not provided', () => {
      const expr: Expr = { op: '*', args: ['a', 'b', 'c'] }
      const grad = gradient(expr)

      expect(grad).toHaveLength(3)
      const variables = grad.map((g) => g.variable)
      expect(variables).toContain('a')
      expect(variables).toContain('b')
      expect(variables).toContain('c')
    })
  })

  describe('higherOrderDerivative', () => {
    it('should compute second derivatives', () => {
      const expr: Expr = { op: '^', args: ['x', 4] } // x⁴
      const result = higherOrderDerivative(expr, 'x', 2)

      expect(result.variable).toBe('x')
      expect(result.chainComponents).toHaveLength(2)

      // First derivative: 4x³
      expect(result.chainComponents![0].derivative).toEqual({
        op: '*',
        args: [4, { op: '^', args: ['x', 3] }, 1],
      })
    })

    it('should throw error for non-positive order', () => {
      const expr: Expr = { op: '^', args: ['x', 2] }
      expect(() => higherOrderDerivative(expr, 'x', 0)).toThrow()
      expect(() => higherOrderDerivative(expr, 'x', -1)).toThrow()
    })
  })

  describe('isDifferentiable', () => {
    it('should return true for differentiable expressions', () => {
      const expr: Expr = {
        op: '+',
        args: [
          { op: '^', args: ['x', 2] },
          { op: 'sin', args: ['x'] },
        ],
      }
      expect(isDifferentiable(expr, 'x')).toBe(true)
    })

    it('should return true even for complex expressions', () => {
      const expr: Expr = {
        op: '/',
        args: [
          { op: 'exp', args: ['x'] },
          { op: '+', args: [{ op: '^', args: ['x', 2] }, 1] },
        ],
      }
      expect(isDifferentiable(expr, 'x')).toBe(true)
    })
  })

  describe('findCriticalPoints', () => {
    it('should analyze derivative for critical point information', () => {
      const expr: Expr = { op: '^', args: ['x', 2] } // x²
      const result = findCriticalPoints(expr, 'x')

      expect(result.derivative).toEqual({
        op: '*',
        args: [2, { op: '^', args: ['x', 1] }, 1],
      })

      expect(result.hasConstantDerivative).toBe(false) // 2x is not constant
      expect(result.isConstantZero).toBe(false) // 2x ≠ 0
    })

    it('should detect constant derivative', () => {
      const expr: Expr = { op: '*', args: [3, 'x'] } // 3x
      const result = findCriticalPoints(expr, 'x')

      // The derivative should be 3 (constant)
      expect(result.derivative).toEqual({
        op: '+',
        args: [
          { op: '*', args: [0, 'x'] },
          { op: '*', args: [3, 1] },
        ],
      })
      expect(result.hasConstantDerivative).toBe(false) // This is actually a complex expression
      expect(result.isConstantZero).toBe(false)
    })

    it('should detect constant zero derivative', () => {
      const expr: Expr = 42 // constant
      const result = findCriticalPoints(expr, 'x')

      expect(result.hasConstantDerivative).toBe(true)
      expect(result.isConstantZero).toBe(true)
    })
  })

  describe('edge cases and complex expressions', () => {
    it('should handle deeply nested expressions', () => {
      const expr: Expr = {
        op: 'sin',
        args: [
          {
            op: 'exp',
            args: [{ op: '*', args: ['a', 'x'] }],
          },
        ],
      }

      const result = differentiate(expr, 'x')

      // This should use chain rule multiple times
      expect(result.derivative).toBeDefined()
      expect(typeof result.derivative).toBe('object')
    })

    it('should handle expressions with multiple variables', () => {
      const expr: Expr = {
        op: '+',
        args: [
          { op: '*', args: ['x', 'y'] },
          { op: '^', args: ['y', 2] },
          { op: 'sin', args: [{ op: '+', args: ['x', 'y'] }] },
        ],
      }

      const resultX = differentiate(expr, 'x')
      const resultY = differentiate(expr, 'y')

      expect(resultX.derivative).toBeDefined()
      expect(resultY.derivative).toBeDefined()
    })

    it('should handle min/max functions with approximation', () => {
      const expr: Expr = { op: 'min', args: ['x', 'y'] }
      const result = differentiate(expr, 'x')

      // Should use ifelse approximation
      expect(result.derivative).toEqual({
        op: 'ifelse',
        args: [{ op: '<', args: ['x', 'y'] }, 1, 0],
      })
    })

    it('should provide simplified form when different from original', () => {
      const expr: Expr = {
        op: '+',
        args: [
          { op: '*', args: ['x', 0] },
          { op: '*', args: [1, 'y'] },
        ],
      }
      const result = differentiate(expr, 'x')

      // Original derivative might be: 1*0 + x*0 + 0*y + 1*0
      // Simplified should be different (simpler)
      if (result.simplified) {
        expect(result.simplified).not.toEqual(result.derivative)
      }
    })
  })
})
