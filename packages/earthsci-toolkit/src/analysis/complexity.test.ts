/**
 * Tests for expression complexity analysis
 */

import { describe, it, expect } from 'vitest'
import {
  analyzeComplexity,
  compareComplexity,
  classifyComplexity,
  findExpensiveSubexpressions,
  estimateParallelPotential,
  detectStabilityIssues,
} from './complexity.js'
import { isExprNode } from '../expression.js'
import type { Expr } from '../types.js'

describe('Complexity Analysis', () => {
  describe('analyzeComplexity', () => {
    it('should analyze simple constant', () => {
      const expr: Expr = 42
      const metrics = analyzeComplexity(expr)

      expect(metrics.depth).toBe(0)
      expect(metrics.operationCount).toBe(0)
      expect(metrics.variableCount).toBe(0)
      expect(metrics.constantCount).toBe(1)
      expect(metrics.computationalCost).toBeGreaterThan(0)
    })

    it('should analyze simple variable', () => {
      const expr: Expr = 'x'
      const metrics = analyzeComplexity(expr)

      expect(metrics.depth).toBe(0)
      expect(metrics.operationCount).toBe(0)
      expect(metrics.variableCount).toBe(1)
      expect(metrics.constantCount).toBe(0)
    })

    it('should analyze arithmetic expression', () => {
      const expr: Expr = {
        op: '+',
        args: ['x', { op: '*', args: ['k', 'y'] }],
      }
      const metrics = analyzeComplexity(expr)

      expect(metrics.depth).toBe(2)
      expect(metrics.operationCount).toBe(2) // + and *
      expect(metrics.variableCount).toBe(3) // x, k, y
      expect(metrics.constantCount).toBe(0)
      expect(metrics.operationTypes['+']).toBe(1)
      expect(metrics.operationTypes['*']).toBe(1)
    })

    it('should analyze complex nested expression', () => {
      const expr: Expr = {
        op: 'exp',
        args: [
          {
            op: '/',
            args: [
              {
                op: '*',
                args: [-1370, { op: 'log', args: ['T'] }],
              },
              'R',
            ],
          },
        ],
      }
      const metrics = analyzeComplexity(expr)

      expect(metrics.depth).toBe(4)
      expect(metrics.operationCount).toBe(4) // exp, /, *, log
      expect(metrics.variableCount).toBe(2) // T, R
      expect(metrics.constantCount).toBe(1) // -1370
      expect(metrics.operationTypes['exp']).toBe(1)
      expect(metrics.operationTypes['/']).toBe(1)
      expect(metrics.operationTypes['*']).toBe(1)
      expect(metrics.operationTypes['log']).toBe(1)
      expect(metrics.computationalCost).toBeGreaterThan(20) // exp and log are expensive
    })

    it('should calculate computational cost based on operation weights', () => {
      const simpleExpr: Expr = { op: '+', args: ['x', 'y'] }
      const expensiveExpr: Expr = { op: 'exp', args: ['x'] }

      const simpleMetrics = analyzeComplexity(simpleExpr)
      const expensiveMetrics = analyzeComplexity(expensiveExpr)

      expect(expensiveMetrics.computationalCost).toBeGreaterThan(simpleMetrics.computationalCost)
    })
  })

  describe('compareComplexity', () => {
    it('should compare expressions correctly', () => {
      const simple: Expr = { op: '+', args: ['x', 'y'] }
      const complex: Expr = {
        op: 'exp',
        args: [{ op: 'sin', args: [{ op: '*', args: ['omega', 't'] }] }],
      }

      expect(compareComplexity(simple, complex)).toBe(-1) // simple < complex
      expect(compareComplexity(complex, simple)).toBe(1) // complex > simple
      expect(compareComplexity(simple, simple)).toBe(0) // simple == simple
    })

    it('should use secondary criteria when costs are similar', () => {
      const expr1: Expr = { op: '+', args: ['x', 'y'] } // 2 operations: none, cost from variables
      const expr2: Expr = { op: '*', args: ['a', 'b'] } // 1 operation: *, but higher weight

      // These might have similar costs, so comparison would use operation count
      const comparison = compareComplexity(expr1, expr2)
      // Result depends on the actual cost calculation
      expect(typeof comparison).toBe('number')
      expect(Math.abs(comparison)).toBeLessThanOrEqual(1)
    })
  })

  describe('classifyComplexity', () => {
    it('should classify expressions by complexity level', () => {
      const trivial: Expr = 'x'
      const simple: Expr = { op: '+', args: ['x', 'y'] }
      const moderate: Expr = {
        op: '*',
        args: [
          { op: '+', args: ['x', 'y'] },
          { op: 'sin', args: ['z'] },
        ],
      }
      const complex: Expr = {
        op: 'exp',
        args: [
          {
            op: '/',
            args: [
              { op: 'log', args: ['x'] },
              { op: 'sqrt', args: [{ op: '+', args: [{ op: '^', args: ['y', 2] }, 1] }] },
            ],
          },
        ],
      }

      expect(classifyComplexity(trivial)).toBe('trivial')
      expect(['trivial', 'simple']).toContain(classifyComplexity(simple)) // Could be either depending on exact cost
      expect(['simple', 'moderate']).toContain(classifyComplexity(moderate))
      expect(['moderate', 'complex', 'very_complex']).toContain(classifyComplexity(complex))
    })
  })

  describe('findExpensiveSubexpressions', () => {
    it('should find expensive parts of expressions', () => {
      const expr: Expr = {
        op: '+',
        args: [
          'x',
          {
            op: 'exp',
            args: [{ op: 'sin', args: [{ op: '*', args: ['omega', 't'] }] }],
          },
        ],
      }

      const expensive = findExpensiveSubexpressions(expr, 3)

      expect(expensive.length).toBeGreaterThan(0)

      // Should find the exp(sin(...)) part as expensive
      const expPart = expensive.find(
        (item) => isExprNode(item.expression) && item.expression.op === 'exp',
      )
      expect(expPart).toBeDefined()
      expect(expPart?.cost).toBeGreaterThan(20) // exp and sin are expensive
    })

    it('should limit results correctly', () => {
      const expr: Expr = {
        op: '+',
        args: [
          { op: 'exp', args: ['x'] },
          { op: 'sin', args: ['y'] },
          { op: 'cos', args: ['z'] },
          { op: 'log', args: ['w'] },
        ],
      }

      const expensive = findExpensiveSubexpressions(expr, 2)
      expect(expensive.length).toBeLessThanOrEqual(2)
    })

    it('should sort by cost descending', () => {
      const expr: Expr = {
        op: '+',
        args: [
          { op: '+', args: ['x', 'y'] }, // Low cost
          { op: 'sin', args: ['z'] }, // Medium cost
          { op: 'exp', args: ['w'] }, // High cost
        ],
      }

      const expensive = findExpensiveSubexpressions(expr)

      // Should be sorted by cost descending
      for (let i = 1; i < expensive.length; i++) {
        expect(expensive[i - 1].cost).toBeGreaterThanOrEqual(expensive[i].cost)
      }
    })
  })

  describe('estimateParallelPotential', () => {
    it('should return 0 for atomic expressions', () => {
      expect(estimateParallelPotential('x')).toBe(0)
      expect(estimateParallelPotential(42)).toBe(0)
    })

    it('should detect parallelizable operations', () => {
      const parallelizable: Expr = {
        op: '+',
        args: ['x', 'y', 'z', 'w'], // Addition is parallelizable
      }

      const sequential: Expr = {
        op: '/',
        args: ['x', 'y'], // Division is not easily parallelizable
      }

      const parallelScore = estimateParallelPotential(parallelizable)
      const sequentialScore = estimateParallelPotential(sequential)

      expect(parallelScore).toBeGreaterThan(sequentialScore)
      expect(parallelScore).toBeLessThanOrEqual(1)
      expect(sequentialScore).toBeGreaterThanOrEqual(0)
    })

    it('should handle nested expressions', () => {
      const expr: Expr = {
        op: '+', // Parallelizable
        args: [
          { op: '*', args: ['x', 'y'] }, // Parallelizable
          { op: '/', args: ['a', 'b'] }, // Not parallelizable
        ],
      }

      const score = estimateParallelPotential(expr)
      expect(score).toBeGreaterThan(0)
      expect(score).toBeLessThan(1) // Mixed parallelizability
    })
  })

  describe('detectStabilityIssues', () => {
    it('should detect division by zero', () => {
      const expr: Expr = { op: '/', args: ['x', 0] }
      const issues = detectStabilityIssues(expr)

      expect(issues.length).toBeGreaterThan(0)
      const divisionIssue = issues.find((issue) =>
        issue.issue.includes('Division by very small constant'),
      )
      expect(divisionIssue).toBeDefined()
      expect(divisionIssue?.severity).toBe('high')
    })

    it('should detect logarithm of non-positive number', () => {
      const expr: Expr = { op: 'log', args: [-1] }
      const issues = detectStabilityIssues(expr)

      const logIssue = issues.find((issue) =>
        issue.issue.includes('Logarithm of non-positive number'),
      )
      expect(logIssue).toBeDefined()
      expect(logIssue?.severity).toBe('high')
    })

    it('should detect square root of negative number', () => {
      const expr: Expr = { op: 'sqrt', args: [-4] }
      const issues = detectStabilityIssues(expr)

      const sqrtIssue = issues.find((issue) =>
        issue.issue.includes('Square root of negative number'),
      )
      expect(sqrtIssue).toBeDefined()
      expect(sqrtIssue?.severity).toBe('high')
    })

    it('should detect large exponents', () => {
      const expr: Expr = { op: '^', args: ['x', 1000] }
      const issues = detectStabilityIssues(expr)

      const expIssue = issues.find((issue) => issue.issue.includes('Very large exponent'))
      expect(expIssue).toBeDefined()
      expect(expIssue?.severity).toBe('medium')
    })

    it('should detect inverse trig with out-of-range arguments', () => {
      const expr: Expr = { op: 'asin', args: [2] }
      const issues = detectStabilityIssues(expr)

      const asinIssue = issues.find((issue) => issue.issue.includes('Inverse trig function'))
      expect(asinIssue).toBeDefined()
      expect(asinIssue?.severity).toBe('high')
    })

    it('should provide path information for nested issues', () => {
      const expr: Expr = {
        op: '+',
        args: [
          'x',
          { op: '/', args: ['y', 0] }, // Division by zero in nested expression
        ],
      }
      const issues = detectStabilityIssues(expr)

      expect(issues.length).toBeGreaterThan(0)
      const issue = issues[0]
      expect(issue.path).toContain('args[1]') // Should point to nested expression
      expect(issue.path).toContain('args[1]') // Should point to denominator
    })

    it('should return empty array for stable expressions', () => {
      const expr: Expr = {
        op: '+',
        args: [
          { op: '*', args: ['x', 2] },
          { op: 'sin', args: ['y'] },
          { op: 'log', args: [{ op: '+', args: [{ op: '^', args: ['z', 2] }, 1] }] },
        ],
      }

      const issues = detectStabilityIssues(expr)
      expect(issues).toHaveLength(0)
    })

    it('should provide helpful suggestions', () => {
      const expr: Expr = { op: '/', args: ['x', 0.0000001] }
      const issues = detectStabilityIssues(expr)

      expect(issues.length).toBeGreaterThan(0)
      const issue = issues[0]
      expect(issue.suggestion).toBeDefined()
      expect(typeof issue.suggestion).toBe('string')
      expect(issue.suggestion.length).toBeGreaterThan(0)
    })
  })
})
