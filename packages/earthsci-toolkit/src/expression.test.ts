import { describe, it, expect } from 'vitest'
import { freeVariables, freeParameters, contains, simplify } from './expression.js'
import type { Model, Expr } from './types.js'

describe('Expression structural operations', () => {
  describe('freeVariables', () => {
    it('should return empty set for numbers', () => {
      expect(freeVariables(42)).toEqual(new Set())
    })

    it('should return single variable for string', () => {
      expect(freeVariables('x')).toEqual(new Set(['x']))
    })

    it('should collect variables from simple expression', () => {
      const expr: Expr = {
        op: '+',
        args: ['x', 'y']
      }
      expect(freeVariables(expr)).toEqual(new Set(['x', 'y']))
    })

    it('should collect variables from nested expression', () => {
      const expr: Expr = {
        op: '*',
        args: [
          { op: '+', args: ['x', 2] },
          { op: 'sin', args: ['y'] }
        ]
      }
      expect(freeVariables(expr)).toEqual(new Set(['x', 'y']))
    })

    it('should handle duplicate variables', () => {
      const expr: Expr = {
        op: '+',
        args: ['x', { op: '*', args: ['x', 2] }]
      }
      expect(freeVariables(expr)).toEqual(new Set(['x']))
    })
  })

  describe('freeParameters', () => {
    const testModel: Model = {
      variables: {
        'x': { type: 'state' },
        'k': { type: 'parameter' },
        'T': { type: 'parameter' },
        'C': { type: 'observed', expression: { op: '*', args: ['k', 'T'] } }
      },
      equations: []
    }

    it('should return empty set for expression with no parameters', () => {
      const expr: Expr = { op: '+', args: ['x', 2] }
      expect(freeParameters(expr, testModel)).toEqual(new Set())
    })

    it('should identify parameters in simple expression', () => {
      const expr: Expr = { op: '*', args: ['k', 'x'] }
      expect(freeParameters(expr, testModel)).toEqual(new Set(['k']))
    })

    it('should identify multiple parameters', () => {
      const expr: Expr = { op: '+', args: ['k', 'T'] }
      expect(freeParameters(expr, testModel)).toEqual(new Set(['k', 'T']))
    })

    it('should handle variables not in model', () => {
      const expr: Expr = { op: '+', args: ['k', 'unknown'] }
      expect(freeParameters(expr, testModel)).toEqual(new Set(['k']))
    })
  })

  describe('contains', () => {
    it('should return true for matching string', () => {
      expect(contains('x', 'x')).toBe(true)
    })

    it('should return false for non-matching string', () => {
      expect(contains('x', 'y')).toBe(false)
    })

    it('should return false for numbers', () => {
      expect(contains(42, 'x')).toBe(false)
    })

    it('should find variable in expression args', () => {
      const expr: Expr = { op: '+', args: ['x', 'y'] }
      expect(contains(expr, 'x')).toBe(true)
      expect(contains(expr, 'y')).toBe(true)
      expect(contains(expr, 'z')).toBe(false)
    })

    it('should find variable in nested expression', () => {
      const expr: Expr = {
        op: '*',
        args: [
          { op: '+', args: ['x', 2] },
          { op: 'sin', args: ['y'] }
        ]
      }
      expect(contains(expr, 'x')).toBe(true)
      expect(contains(expr, 'y')).toBe(true)
      expect(contains(expr, 'z')).toBe(false)
    })
  })

  // Per-op `evaluate` testset retired with esm-3r4: the in-process
  // scalar evaluator now lives in `codegen.ts` (`compileExpression` /
  // `evaluateExpression`), and its op-dispatch contract is covered by
  // `codegen.test.ts`. `simplify` (below) exercises that path through
  // its constant-folding default branch.

  describe('simplify', () => {
    it('should return numbers and variables as-is', () => {
      expect(simplify(42)).toBe(42)
      expect(simplify('x')).toBe('x')
    })

    describe('addition simplification', () => {
      it('should remove zeros', () => {
        const expr: Expr = { op: '+', args: ['x', 0, 'y'] }
        expect(simplify(expr)).toEqual({ op: '+', args: ['x', 'y'] })
      })

      it('should collapse to single term when only one non-zero', () => {
        const expr: Expr = { op: '+', args: ['x', 0, 0] }
        expect(simplify(expr)).toBe('x')
      })

      it('should return zero when all terms are zero', () => {
        const expr: Expr = { op: '+', args: [0, 0] }
        expect(simplify(expr)).toBe(0)
      })

      it('should fold constants', () => {
        const expr: Expr = { op: '+', args: [2, 3, 5] }
        expect(simplify(expr)).toBe(10)
      })

      it('should combine constant folding with zero removal', () => {
        const expr: Expr = { op: '+', args: ['x', 2, 0, 3] }
        expect(simplify(expr)).toEqual({ op: '+', args: ['x', 5] })
      })
    })

    describe('multiplication simplification', () => {
      it('should return zero for zero multiplication', () => {
        const expr: Expr = { op: '*', args: ['x', 0, 'y'] }
        expect(simplify(expr)).toBe(0)
      })

      it('should remove ones', () => {
        const expr: Expr = { op: '*', args: ['x', 1, 'y'] }
        expect(simplify(expr)).toEqual({ op: '*', args: ['x', 'y'] })
      })

      it('should collapse to single factor when only one non-one', () => {
        const expr: Expr = { op: '*', args: ['x', 1, 1] }
        expect(simplify(expr)).toBe('x')
      })

      it('should return one when all factors are one', () => {
        const expr: Expr = { op: '*', args: [1, 1] }
        expect(simplify(expr)).toBe(1)
      })

      it('should fold constants', () => {
        const expr: Expr = { op: '*', args: [2, 3, 5] }
        expect(simplify(expr)).toBe(30)
      })
    })

    describe('subtraction simplification', () => {
      it('should simplify x - 0 to x', () => {
        const expr: Expr = { op: '-', args: ['x', 0] }
        expect(simplify(expr)).toBe('x')
      })

      it('should fold constants', () => {
        const expr: Expr = { op: '-', args: [10, 3] }
        expect(simplify(expr)).toBe(7)
      })

      it('should handle unary minus', () => {
        const expr: Expr = { op: '-', args: [5] }
        expect(simplify(expr)).toBe(-5)
      })
    })

    describe('division simplification', () => {
      it('should simplify x / 1 to x', () => {
        const expr: Expr = { op: '/', args: ['x', 1] }
        expect(simplify(expr)).toBe('x')
      })

      it('should NOT simplify 0 / x (x could be 0, making the result NaN)', () => {
        const expr: Expr = { op: '/', args: [0, 'x'] }
        expect(simplify(expr)).toEqual({ op: '/', args: [0, 'x'] })
      })

      it('should fold constants', () => {
        const expr: Expr = { op: '/', args: [6, 2] }
        expect(simplify(expr)).toBe(3)
      })

      it('should leave a zero denominator unfolded rather than throwing', () => {
        const expr: Expr = { op: '/', args: [1, 0] }
        expect(simplify(expr)).toEqual({ op: '/', args: [1, 0] })
      })
    })

    describe('exponentiation simplification', () => {
      it('should simplify x^0 to 1', () => {
        const expr: Expr = { op: '^', args: ['x', 0] }
        expect(simplify(expr)).toBe(1)
      })

      it('should simplify x^1 to x', () => {
        const expr: Expr = { op: '^', args: ['x', 1] }
        expect(simplify(expr)).toBe('x')
      })

      it('should NOT simplify 0^x (the identity only holds for x > 0)', () => {
        const expr: Expr = { op: '^', args: [0, 'x'] }
        expect(simplify(expr)).toEqual({ op: '^', args: [0, 'x'] })
      })

      it('should simplify 1^x to 1', () => {
        const expr: Expr = { op: '^', args: [1, 'x'] }
        expect(simplify(expr)).toBe(1)
      })

      it('should fold constants', () => {
        const expr: Expr = { op: '^', args: [2, 3] }
        expect(simplify(expr)).toBe(8)
      })
    })

    describe('recursive simplification', () => {
      it('should simplify nested expressions', () => {
        const expr: Expr = {
          op: '+',
          args: [
            { op: '*', args: ['x', 1] },
            { op: '+', args: [2, 3] }
          ]
        }
        expect(simplify(expr)).toEqual({ op: '+', args: ['x', 5] })
      })

      it('should handle complex nested case', () => {
        const expr: Expr = {
          op: '*',
          args: [
            { op: '+', args: ['x', 0] },
            { op: '^', args: ['y', 1] }
          ]
        }
        expect(simplify(expr)).toEqual({ op: '*', args: ['x', 'y'] })
      })
    })
  })
})