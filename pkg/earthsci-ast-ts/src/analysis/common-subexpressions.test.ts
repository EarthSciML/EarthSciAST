/**
 * Tests for common subexpression identification
 */

import { describe, it, expect } from 'vitest'
import {
  findCommonSubexpressions,
  findCommonSubexpressionsAcrossExpressions,
  findCommonSubexpressionsInModel,
  estimateSavings,
  generateFactoredVariableNames,
  groupSubexpressionsByType,
} from './common-subexpressions.js'
import { isExprNode } from '../expression.js'
import type { Expr, Model } from '../types.js'

describe('Common Subexpression Analysis', () => {
  describe('findCommonSubexpressions', () => {
    it('should find repeated subexpressions in single expression', () => {
      const expr: Expr = {
        op: '+',
        args: [
          { op: '*', args: ['k', 'T'] }, // Common subexpression
          { op: '/', args: [{ op: '*', args: ['k', 'T'] }, 'R'] }, // Same subexpression repeated
        ],
      }

      const commonSubs = findCommonSubexpressions(expr, 2) // Low threshold for testing

      expect(commonSubs.length).toBeGreaterThan(0)

      // Should find k*T as common subexpression
      const ktExpr = commonSubs.find(
        (sub) =>
          isExprNode(sub.expression) &&
          sub.expression.op === '*' &&
          sub.expression.args.includes('k') &&
          sub.expression.args.includes('T'),
      )

      expect(ktExpr).toBeDefined()
      expect(ktExpr?.count).toBe(2)
      expect(ktExpr?.locations).toHaveLength(2)
    })

    it('should respect minimum complexity threshold', () => {
      const expr: Expr = {
        op: '+',
        args: [
          { op: '+', args: ['x', 'y'] }, // Simple repeated expression
          { op: '+', args: ['x', 'y'] }, // Same expression
        ],
      }

      const lowThreshold = findCommonSubexpressions(expr, 1)
      const highThreshold = findCommonSubexpressions(expr, 10)

      expect(lowThreshold.length).toBeGreaterThan(highThreshold.length)
    })

    it('should calculate savings correctly', () => {
      const expr: Expr = {
        op: '+',
        args: [
          { op: 'exp', args: ['x'] }, // Expensive operation
          { op: 'exp', args: ['x'] }, // Repeated
          { op: 'exp', args: ['x'] }, // Repeated again
        ],
      }

      const commonSubs = findCommonSubexpressions(expr, 5)

      expect(commonSubs.length).toBeGreaterThan(0)
      const expSub = commonSubs[0]
      expect(expSub.count).toBe(3)
      expect(expSub.savings).toBeGreaterThan(0)
      // Savings should be cost * (count - 1)
      expect(expSub.savings).toBeGreaterThan(20) // exp is expensive
    })

    it('should sort results by savings descending', () => {
      const expr: Expr = {
        op: '+',
        args: [
          { op: '+', args: ['x', 'y'] }, // Cheap repeated expression
          { op: '+', args: ['x', 'y'] },
          { op: 'exp', args: ['z'] }, // Expensive repeated expression
          { op: 'exp', args: ['z'] },
        ],
      }

      const commonSubs = findCommonSubexpressions(expr, 2)

      // Should be sorted by savings (highest first)
      for (let i = 1; i < commonSubs.length; i++) {
        expect(commonSubs[i - 1].savings).toBeGreaterThanOrEqual(commonSubs[i].savings)
      }
    })
  })

  describe('findCommonSubexpressionsAcrossExpressions', () => {
    it('should find common subexpressions across multiple expressions', () => {
      const expressions = [
        { expr: { op: '+', args: [{ op: '*', args: ['k', 'T'] }, 'C1'] }, name: 'expr1' },
        { expr: { op: '-', args: ['P', { op: '*', args: ['k', 'T'] }] }, name: 'expr2' },
        { expr: { op: '/', args: [{ op: '*', args: ['k', 'T'] }, 'R'] }, name: 'expr3' },
      ]

      const commonSubs = findCommonSubexpressionsAcrossExpressions(expressions, 2)

      expect(commonSubs.length).toBeGreaterThan(0)

      // Should find k*T across all expressions
      const ktSub = commonSubs.find(
        (sub) =>
          isExprNode(sub.expression) &&
          sub.expression.op === '*' &&
          sub.expression.args.includes('k') &&
          sub.expression.args.includes('T'),
      )

      expect(ktSub).toBeDefined()
      expect(ktSub?.count).toBe(3)
      expect(ktSub?.locations).toHaveLength(3)

      // Locations should reference the different expressions
      const locationNames = ktSub?.locations.map((loc) => loc.path[0])
      expect(locationNames).toContain('expr1')
      expect(locationNames).toContain('expr2')
      expect(locationNames).toContain('expr3')
    })

    it('should provide meaningful location descriptions', () => {
      const expressions = [
        { expr: { op: 'sin', args: ['x'] }, name: 'sine_expr' },
        { expr: { op: 'cos', args: [{ op: 'sin', args: ['x'] }] }, name: 'cosine_expr' },
      ]

      const commonSubs = findCommonSubexpressionsAcrossExpressions(expressions, 5)
      expect(commonSubs.length).toBeGreaterThan(0)

      const sinSub = commonSubs[0]
      expect(sinSub.locations).toHaveLength(2)

      for (const location of sinSub.locations) {
        expect(location.description).toContain('Expression')
        expect(typeof location.description).toBe('string')
        expect(location.description.length).toBeGreaterThan(0)
      }
    })
  })

  describe('findCommonSubexpressionsInModel', () => {
    it('should find common subexpressions within a model', () => {
      const model: Model = {
        variables: {
          T: { type: 'parameter' },
          k: { type: 'parameter' },
          density: {
            type: 'observed',
            expression: { op: '/', args: ['P', { op: '*', args: ['k', 'T'] }] },
          },
          pressure: {
            type: 'observed',
            expression: { op: '*', args: [{ op: '*', args: ['k', 'T'] }, 'V'] },
          },
        },
        equations: [
          {
            lhs: 'dT_dt',
            rhs: { op: '*', args: ['alpha', { op: '*', args: ['k', 'T'] }] },
          },
        ],
      }

      const commonSubs = findCommonSubexpressionsInModel(model, 2)

      expect(commonSubs.length).toBeGreaterThan(0)

      // Should find k*T used in multiple places
      const ktSub = commonSubs.find(
        (sub) =>
          isExprNode(sub.expression) &&
          sub.expression.op === '*' &&
          sub.expression.args.includes('k') &&
          sub.expression.args.includes('T'),
      )

      expect(ktSub).toBeDefined()
      expect(ktSub?.count).toBeGreaterThanOrEqual(2)

      // Check location descriptions include variable and equation references
      const locationDescs = ktSub?.locations.map((loc) => loc.description).join(' ')
      expect(locationDescs).toMatch(/variable|equation/)
    })

    it('should handle models with subsystems', () => {
      const model: Model = {
        variables: {
          global_k: { type: 'parameter' },
          main_var: {
            type: 'observed',
            expression: { op: '*', args: ['global_k', 2] }, // Same expression repeated
          },
        },
        equations: [],
        subsystems: {
          sub1: {
            variables: {
              local_var: {
                type: 'observed',
                expression: { op: '*', args: ['global_k', 2] }, // Same expression as main_var
              },
            },
            equations: [
              {
                lhs: 'dx_dt',
                rhs: { op: '*', args: ['global_k', 2] }, // Same expression again
              },
            ],
          },
        },
      }

      const commonSubs = findCommonSubexpressionsInModel(model, 1)

      // Check that we actually found common subexpressions first
      expect(commonSubs.length).toBeGreaterThan(0)

      // Should find expressions involving global_k and include subsystem info
      const subSystemLocations = commonSubs
        .flatMap((sub) => sub.locations)
        .filter((loc) => loc.description.includes('Subsystem'))

      expect(subSystemLocations.length).toBeGreaterThan(0)
    })
  })

  describe('estimateSavings', () => {
    it('should calculate total savings correctly', () => {
      const commonSubs = [
        {
          expression: { op: 'exp', args: ['x'] },
          locations: [],
          count: 3,
          savings: 40, // 20 * (3-1)
        },
        {
          expression: { op: 'sin', args: ['y'] },
          locations: [],
          count: 2,
          savings: 12, // 12 * (2-1)
        },
      ]

      const totalSavings = estimateSavings(commonSubs)
      expect(totalSavings).toBe(52) // 40 + 12
    })
  })

  describe('generateFactoredVariableNames', () => {
    it('should generate unique variable names', () => {
      const commonSubs = [
        {
          expression: { op: 'exp', args: ['x'] },
          locations: [],
          count: 2,
          savings: 20,
        },
        {
          expression: { op: 'sin', args: ['y'] },
          locations: [],
          count: 2,
          savings: 12,
        },
      ]

      const nameMap = generateFactoredVariableNames(commonSubs, 'CSE_')

      expect(nameMap.size).toBe(2)
      const names = Array.from(nameMap.values())
      expect(names).toContain('CSE_1')
      expect(names).toContain('CSE_2')

      // Names should be unique
      expect(new Set(names).size).toBe(names.length)
    })

    it('should use default prefix when none provided', () => {
      const commonSubs = [
        {
          expression: { op: 'exp', args: ['x'] },
          locations: [],
          count: 2,
          savings: 20,
        },
      ]

      const nameMap = generateFactoredVariableNames(commonSubs)
      const names = Array.from(nameMap.values())
      expect(names[0]).toMatch(/^temp_\d+$/)
    })
  })

  describe('groupSubexpressionsByType', () => {
    it('should group subexpressions by operation type', () => {
      const commonSubs = [
        {
          expression: { op: 'exp', args: ['x'] },
          locations: [],
          count: 2,
          savings: 20,
        },
        {
          expression: { op: 'exp', args: ['y'] },
          locations: [],
          count: 3,
          savings: 40,
        },
        {
          expression: { op: 'sin', args: ['z'] },
          locations: [],
          count: 2,
          savings: 12,
        },
        {
          expression: 'constant_expr',
          locations: [],
          count: 2,
          savings: 1,
        },
      ]

      const grouped = groupSubexpressionsByType(commonSubs)

      expect(grouped['exp']).toHaveLength(2)
      expect(grouped['sin']).toHaveLength(1)
      expect(grouped['atomic']).toHaveLength(1) // string expression
    })

    it('should handle empty input', () => {
      const grouped = groupSubexpressionsByType([])
      expect(Object.keys(grouped)).toHaveLength(0)
    })
  })

  describe('edge cases', () => {
    it('should handle expressions with no common subexpressions', () => {
      const expr: Expr = {
        op: '+',
        args: [
          { op: '*', args: ['a', 'b'] },
          { op: '/', args: ['c', 'd'] },
          { op: '^', args: ['e', 'f'] },
        ],
      }

      const commonSubs = findCommonSubexpressions(expr, 5)
      expect(commonSubs).toHaveLength(0)
    })

    it('should handle very simple expressions', () => {
      const expr: Expr = { op: '+', args: ['x', 'y'] }
      const commonSubs = findCommonSubexpressions(expr, 1)
      expect(commonSubs).toHaveLength(0) // No repetition
    })

    it('should NOT collapse subexpressions that differ only in a non-arg field', () => {
      // `D(u) wrt x` and `D(u) wrt y` share op and args but are DISTINCT
      // expressions. Keying on canonical JSON (which retains `wrt`) keeps them
      // apart; the old op/args-only serializer wrongly merged them, reporting a
      // bogus common subexpression.
      const distinct: Expr = {
        op: '+',
        args: [
          { op: 'D', args: ['u'], wrt: 'x' },
          { op: 'D', args: ['u'], wrt: 'y' },
        ],
      }
      const distinctSubs = findCommonSubexpressions(distinct, 5)
      const mergedD = distinctSubs.find(
        (sub) => isExprNode(sub.expression) && sub.expression.op === 'D',
      )
      expect(mergedD).toBeUndefined()

      // Two genuinely identical D nodes ARE a common subexpression.
      const same: Expr = {
        op: '+',
        args: [
          { op: 'D', args: ['u'], wrt: 'x' },
          { op: 'D', args: ['u'], wrt: 'x' },
        ],
      }
      const sameSubs = findCommonSubexpressions(same, 5)
      const commonD = sameSubs.find(
        (sub) => isExprNode(sub.expression) && sub.expression.op === 'D',
      )
      expect(commonD).toBeDefined()
      expect(commonD?.count).toBe(2)
    })

    it('should handle deeply nested identical subexpressions', () => {
      const deepExpr: Expr = {
        op: 'exp',
        args: [
          {
            op: 'sin',
            args: [{ op: '*', args: ['omega', 't'] }],
          },
        ],
      }

      const expr: Expr = {
        op: '+',
        args: [deepExpr, deepExpr, deepExpr],
      }

      const commonSubs = findCommonSubexpressions(expr, 10)
      expect(commonSubs.length).toBeGreaterThan(0)

      // Should find the deep expression as common
      const deepSub = commonSubs.find(
        (sub) => isExprNode(sub.expression) && sub.expression.op === 'exp',
      )
      expect(deepSub).toBeDefined()
      expect(deepSub?.count).toBe(3)
    })
  })
})
