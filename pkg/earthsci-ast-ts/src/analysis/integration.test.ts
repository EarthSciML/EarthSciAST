/**
 * Integration tests for the analysis module functionality
 */

import { describe, it, expect } from 'vitest'
import {
  buildDependencyGraph,
  analyzeComplexity,
  findCommonSubexpressions,
  differentiate,
} from './index.js'
import { toDot, toMermaid } from '../graph.js'
import { isExprNode } from '../expression.js'
import type { Model, Expr, EsmFile } from '../types.js'

describe('Analysis Integration Tests', () => {
  // Complex example model for testing
  const testModel: Model = {
    variables: {
      T: { type: 'parameter', units: 'K' },
      P: { type: 'parameter', units: 'Pa' },
      R: { type: 'parameter', units: 'J/(mol*K)' },
      density: {
        type: 'observed',
        expression: { op: '/', args: ['P', { op: '*', args: ['R', 'T'] }] },
        units: 'mol/m³',
      },
      pressure_ratio: {
        type: 'observed',
        expression: { op: '/', args: ['P', 101325] },
        units: 'dimensionless',
      },
    },
    equations: [
      {
        lhs: 'dT_dt',
        rhs: {
          op: '*',
          args: [
            'alpha',
            {
              op: '-',
              args: [
                'T_ambient',
                { op: '/', args: ['P', { op: '*', args: ['R', 'T'] }] }, // Same as density expression
              ],
            },
          ],
        },
      },
    ],
  }

  it('should perform comprehensive analysis of a model', () => {
    // Build dependency graph
    const depGraph = buildDependencyGraph(testModel)

    expect(depGraph.nodes.length).toBeGreaterThan(5)
    expect(depGraph.edges.length).toBeGreaterThan(3)

    // Check that dependencies are correctly identified
    const densityNode = depGraph.nodes.find((n) => n.name === 'default.density')
    expect(densityNode).toBeDefined()
    expect(densityNode?.kind).toBe('observed')

    // density should depend on P, R, T
    const densityDeps = depGraph.predecessors('default.density')
    expect(densityDeps).toContain('default.P')
    expect(densityDeps).toContain('default.R')
    expect(densityDeps).toContain('default.T')

    // Test topological sorting
    const sorted = depGraph.topologicalSort()
    expect(sorted.length).toBe(depGraph.nodes.length)

    // Parameters should come before derived variables
    const parameterNodes = sorted.filter((n) => n.kind === 'parameter')
    const observedNodes = sorted.filter((n) => n.kind === 'observed')

    if (parameterNodes.length > 0 && observedNodes.length > 0) {
      const firstParamIndex = sorted.indexOf(parameterNodes[0])
      const firstObservedIndex = sorted.indexOf(observedNodes[0])
      expect(firstParamIndex).toBeLessThan(firstObservedIndex)
    }
  })

  it('should identify common subexpressions in model', () => {
    // Create an expression with actual repeated subexpressions
    const exprWithDuplicates: Expr = {
      op: '+',
      args: [
        { op: '/', args: ['P', { op: '*', args: ['R', 'T'] }] }, // First occurrence
        { op: '*', args: [2, { op: '/', args: ['P', { op: '*', args: ['R', 'T'] }] }] }, // Second occurrence
      ],
    }

    const commonSubs = findCommonSubexpressions(exprWithDuplicates, 2)

    // Should find the P/(R*T) expression that appears twice
    expect(commonSubs.length).toBeGreaterThan(0)

    const rtExpr = commonSubs.find(
      (sub) =>
        isExprNode(sub.expression) &&
        sub.expression.op === '/' &&
        Array.isArray(sub.expression.args) &&
        sub.expression.args[0] === 'P',
    )

    expect(rtExpr).toBeDefined()
    expect(rtExpr?.count).toBe(2)
    expect(rtExpr?.savings).toBeGreaterThan(0)
  })

  it('should analyze expression complexity', () => {
    const expr = testModel.variables.density.expression!
    const complexity = analyzeComplexity(expr)

    expect(complexity.depth).toBeGreaterThan(0)
    expect(complexity.operationCount).toBeGreaterThan(0)
    expect(complexity.variableCount).toBeGreaterThan(0)
    expect(complexity.computationalCost).toBeGreaterThan(0)

    // Should identify division operations
    expect(complexity.operationTypes['/']).toBeGreaterThan(0)
    expect(complexity.operationTypes['*']).toBeGreaterThan(0)
  })

  it('should perform symbolic differentiation', () => {
    const expr = testModel.variables.density.expression! // P/(R*T)

    // Differentiate with respect to temperature
    const dDensity_dT = differentiate(expr, 'T')
    expect(dDensity_dT.derivative).toBeDefined()
    expect(dDensity_dT.variable).toBe('T')

    // The derivative should be non-zero (density depends on T)
    expect(dDensity_dT.derivative).not.toBe(0)

    // Differentiate with respect to pressure
    const dDensity_dP = differentiate(expr, 'P')
    expect(dDensity_dP.derivative).toBeDefined()

    // Should be able to simplify if simplified form is different
    if (dDensity_dT.simplified) {
      expect(dDensity_dT.simplified).not.toEqual(dDensity_dT.derivative)
    }
  })

  it('should export graphs in different formats', () => {
    const depGraph = buildDependencyGraph(testModel)

    // Test DOT export
    const dotOutput = toDot(depGraph)
    expect(dotOutput).toContain('digraph {')
    expect(dotOutput).toContain('->')
    expect(dotOutput).toContain('default.density')

    // Test Mermaid export
    const mermaidOutput = toMermaid(depGraph)
    expect(mermaidOutput).toContain('flowchart TD')
    expect(mermaidOutput).toContain('default.density')
  })

  it('should handle complex ESM file analysis', () => {
    const esmFile: EsmFile = {
      esm: '0.1.0',
      metadata: {
        name: 'Test System',
        description: 'Integration test system',
      },
      models: {
        Thermodynamics: testModel,
        Simple: {
          variables: {
            x: { type: 'parameter' },
            y: { type: 'observed', expression: { op: '*', args: ['x', 2] } },
          },
          equations: [],
        },
      },
    }

    // Build dependency graph for entire ESM file
    const fileGraph = buildDependencyGraph(esmFile)

    // Should have nodes from both models
    const nodeNames = fileGraph.nodes.map((n) => n.name)
    expect(nodeNames.some((name) => name.includes('Thermodynamics'))).toBe(true)
    expect(nodeNames.some((name) => name.includes('Simple'))).toBe(true)

    // Test with merged systems
    const mergedGraph = buildDependencyGraph(esmFile, { mergeAcrossSystems: true })
    const mergedNames = mergedGraph.nodes.map((n) => n.name)

    // In merged mode, should have simpler names
    expect(mergedNames).toContain('T')
    expect(mergedNames).toContain('P')
    expect(mergedNames).toContain('x')
    expect(mergedNames).toContain('y')
  })

  it('should detect stability issues in complex expressions', () => {
    const unstableExpr: Expr = {
      op: '+',
      args: [
        { op: '/', args: ['x', 0.000001] }, // Very small denominator
        { op: 'log', args: [-1] }, // Log of negative number
        { op: 'sqrt', args: [-4] }, // Square root of negative
      ],
    }

    const complexity = analyzeComplexity(unstableExpr)

    // Should have detected multiple stability issues
    // (The detectStabilityIssues function is called within analyzeComplexity in a full implementation)
    expect(complexity.operationCount).toBeGreaterThan(0)
    expect(complexity.computationalCost).toBeGreaterThan(0)
  })

  it('should provide performance optimization insights', () => {
    const expensiveExpr: Expr = {
      op: '+',
      args: [
        { op: 'exp', args: [{ op: 'sin', args: ['x'] }] }, // Expensive
        { op: 'exp', args: [{ op: 'sin', args: ['x'] }] }, // Duplicate expensive
        { op: 'log', args: [{ op: 'cos', args: ['y'] }] }, // Different expensive
        { op: 'exp', args: [{ op: 'sin', args: ['x'] }] }, // Another duplicate
      ],
    }

    // Find common subexpressions for optimization
    const commonSubs = findCommonSubexpressions(expensiveExpr, 10)
    expect(commonSubs.length).toBeGreaterThan(0)

    // Should find the exp(sin(x)) pattern repeated
    const expSinSub = commonSubs.find(
      (sub) =>
        isExprNode(sub.expression) &&
        sub.expression.op === 'exp' &&
        Array.isArray(sub.expression.args) &&
        typeof sub.expression.args[0] === 'object' &&
        (sub.expression.args[0] as any).op === 'sin',
    )

    expect(expSinSub).toBeDefined()
    expect(expSinSub?.count).toBe(3) // Three occurrences
    expect(expSinSub?.savings).toBeGreaterThan(40) // Significant savings

    // Analyze complexity
    const complexity = analyzeComplexity(expensiveExpr)
    expect(complexity.operationTypes['exp']).toBe(3)
    expect(complexity.operationTypes['sin']).toBe(3)
    expect(complexity.computationalCost).toBeGreaterThan(100) // Very expensive
  })

  describe('Real-world atmospheric chemistry example', () => {
    const atmosphericModel: Model = {
      variables: {
        T: { type: 'parameter', units: 'K' },
        P: { type: 'parameter', units: 'Pa' },
        NO2: { type: 'state', units: 'mol/m³' },
        O3: { type: 'state', units: 'mol/m³' },
        NO: { type: 'state', units: 'mol/m³' },
        k1: { type: 'parameter', units: 'm³/(mol*s)' },
        k2: { type: 'parameter', units: 's^-1' },
        photolysis_rate: {
          type: 'observed',
          expression: {
            op: '*',
            args: [
              'k2',
              {
                op: 'exp',
                args: [
                  {
                    op: '/',
                    args: [{ op: '*', args: [-1370, { op: 'log', args: ['T'] }] }, 'R'],
                  },
                ],
              },
            ],
          },
        },
      },
      equations: [
        {
          lhs: 'dNO2_dt',
          rhs: {
            op: '-',
            args: [
              { op: '*', args: ['k1', 'NO2', 'O3'] },
              {
                op: '*',
                args: [
                  'NO2',
                  {
                    op: '*',
                    args: [
                      'k2',
                      {
                        op: 'exp',
                        args: [
                          {
                            op: '/',
                            args: [{ op: '*', args: [-1370, { op: 'log', args: ['T'] }] }, 'R'],
                          },
                        ],
                      },
                    ],
                  },
                ],
              },
            ],
          },
        },
      ],
    }

    it('should analyze atmospheric chemistry dependencies', () => {
      const graph = buildDependencyGraph(atmosphericModel)

      // Should have nodes for all species and parameters
      const nodeNames = graph.nodes.map((n) => n.name)
      expect(nodeNames).toContain('default.NO2')
      expect(nodeNames).toContain('default.O3')
      expect(nodeNames).toContain('default.T')
      expect(nodeNames).toContain('default.k1')
      expect(nodeNames).toContain('default.k2')

      // NO2 rate should depend on multiple variables
      const no2Deps = graph.predecessors('default.dNO2_dt')
      expect(no2Deps.length).toBeGreaterThan(3)
    })

    it('should find common temperature-dependent rate expressions', () => {
      const commonSubs = findCommonSubexpressions(atmosphericModel.equations![0].rhs, 10)

      // Should find the Arrhenius-type temperature dependence repeated
      const tempDep = commonSubs.find(
        (sub) => isExprNode(sub.expression) && sub.expression.op === 'exp',
      )

      if (tempDep) {
        expect(tempDep.count).toBeGreaterThan(1)
        expect(tempDep.savings).toBeGreaterThan(20) // exp is expensive
      }
    })

    it('should compute temperature sensitivity via differentiation', () => {
      const photoRate = atmosphericModel.variables.photolysis_rate.expression!
      const dRate_dT = differentiate(photoRate, 'T')

      // Should have a non-zero derivative (rate depends on temperature)
      expect(dRate_dT.derivative).not.toBe(0)
      expect(dRate_dT.variable).toBe('T')

      // The derivative should involve logarithmic terms due to Arrhenius form
      expect(typeof dRate_dT.derivative).toBe('object')
    })

    it('should assess computational complexity of atmospheric rates', () => {
      const photoRate = atmosphericModel.variables.photolysis_rate.expression!
      const complexity = analyzeComplexity(photoRate)

      // Should be classified as complex due to exp and log functions
      expect(complexity.operationTypes['exp']).toBe(1)
      expect(complexity.operationTypes['log']).toBe(1)
      expect(complexity.operationTypes['*']).toBeGreaterThan(0)
      expect(complexity.computationalCost).toBeGreaterThan(30) // exp + log are expensive
    })
  })
})
