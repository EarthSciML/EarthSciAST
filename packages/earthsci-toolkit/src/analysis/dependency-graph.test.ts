/**
 * Tests for dependency graph construction and analysis
 */

import { describe, it, expect } from 'vitest'
import {
  buildDependencyGraph,
  findDeadVariables,
  findDependencyChains,
} from './dependency-graph.js'
import type { Model, Expr } from '../types.js'

describe('Dependency Graph Analysis', () => {
  describe('buildDependencyGraph', () => {
    it('should build dependency graph for simple expression', () => {
      const expr: Expr = {
        op: '+',
        args: ['x', { op: '*', args: ['k', 'y'] }],
      }

      const graph = buildDependencyGraph(expr)

      expect(graph.nodes).toHaveLength(4) // x, k, y, result
      expect(graph.edges).toHaveLength(3) // x->result, k->result, y->result

      // Check node names
      const nodeNames = graph.nodes.map((n) => n.name)
      expect(nodeNames).toContain('default.x')
      expect(nodeNames).toContain('default.k')
      expect(nodeNames).toContain('default.y')
      expect(nodeNames).toContain('default.result')
    })

    it('should build dependency graph for model with variables', () => {
      const model: Model = {
        variables: {
          T: { type: 'parameter', units: 'K' },
          P: { type: 'parameter', units: 'Pa' },
          rho: {
            type: 'observed',
            expression: { op: '/', args: ['P', { op: '*', args: ['R', 'T'] }] },
            units: 'kg/m³',
          },
        },
        equations: [
          {
            lhs: 'drho_dt',
            rhs: { op: '*', args: ['k', { op: '-', args: ['rho_eq', 'rho'] }] },
          },
        ],
      }

      const graph = buildDependencyGraph(model)

      // Should have nodes for all variables plus equation variables
      expect(graph.nodes.length).toBeGreaterThan(5)

      // Check for specific dependencies
      const rhoNode = graph.nodes.find((n) => n.name === 'default.rho')
      expect(rhoNode).toBeDefined()
      expect(rhoNode?.kind).toBe('observed')

      // Check that rho depends on P, R, and T
      const rhoPredecessors = graph.predecessors('default.rho')
      expect(rhoPredecessors).toContain('default.P')
      expect(rhoPredecessors).toContain('default.T')
    })

    it('should detect circular dependencies', () => {
      // Create a model with circular dependency

      const model: Model = {
        variables: {
          x: { type: 'observed', expression: { op: '+', args: ['z', 'a'] } },
          z: { type: 'observed', expression: { op: '*', args: ['x', 'b'] } }, // Circular!
          a: { type: 'parameter' },
          b: { type: 'parameter' },
        },
        equations: [],
      }

      const graph = buildDependencyGraph(model)

      expect(graph.hasCircularDependencies()).toBe(true)
      const cycles = graph.getStronglyConnectedComponents()
      expect(cycles.length).toBeGreaterThan(0)

      // Should find x and z in a cycle
      const cycleNodes = cycles.flat().map((n) => n.name)
      expect(cycleNodes).toContain('default.x')
      expect(cycleNodes).toContain('default.z')
    })

    it('should calculate node depths correctly', () => {
      const model: Model = {
        variables: {
          a: { type: 'parameter' },
          b: { type: 'observed', expression: { op: '*', args: ['a', 2] } },
          c: { type: 'observed', expression: { op: '+', args: ['b', 1] } },
          d: { type: 'observed', expression: { op: '/', args: ['c', 'a'] } },
        },
        equations: [],
      }

      const graph = buildDependencyGraph(model)

      const aNode = graph.nodes.find((n) => n.name === 'default.a')
      const bNode = graph.nodes.find((n) => n.name === 'default.b')
      const cNode = graph.nodes.find((n) => n.name === 'default.c')
      const dNode = graph.nodes.find((n) => n.name === 'default.d')

      expect(aNode?.depth).toBe(0) // Parameter, no dependencies
      expect(bNode?.depth).toBe(1) // Depends on a
      expect(cNode?.depth).toBe(2) // Depends on b
      expect(dNode?.depth).toBe(3) // Depends on c and a, max is c's depth + 1
    })

    it('should handle merge across systems option', () => {
      const model: Model = {
        variables: {
          x: { type: 'parameter' },
        },
        equations: [],
        subsystems: {
          sub1: {
            variables: {
              y: { type: 'observed', expression: { op: '+', args: ['x', 1] } },
            },
            equations: [],
          },
        },
      }

      const graphSeparate = buildDependencyGraph(model, { mergeAcrossSystems: false })
      const graphMerged = buildDependencyGraph(model, { mergeAcrossSystems: true })

      // Separate: should have system.variable names
      const separateNodes = graphSeparate.nodes.map((n) => n.name)
      expect(separateNodes.some((name) => name.includes('.'))).toBe(true)

      // Merged: should have just variable names
      const mergedNodes = graphMerged.nodes.map((n) => n.name)
      expect(mergedNodes).toContain('x')
      expect(mergedNodes).toContain('y')
    })
  })

  describe('findDeadVariables', () => {
    it('should find unused variables', () => {
      const model: Model = {
        variables: {
          used: { type: 'parameter' },
          unused: { type: 'parameter' },
          result: { type: 'observed', expression: { op: '*', args: ['used', 2] } },
        },
        equations: [],
      }

      const graph = buildDependencyGraph(model)
      const deadVars = findDeadVariables(graph)

      expect(deadVars).toHaveLength(2) // unused and result (no successors)
      const deadNames = deadVars.map((v) => v.name)
      expect(deadNames).toContain('default.unused')
      expect(deadNames).toContain('default.result')
    })
  })

  describe('findDependencyChains', () => {
    it('should find dependency chains from parameter to outputs', () => {
      const model: Model = {
        variables: {
          input: { type: 'parameter' },
          intermediate: { type: 'observed', expression: { op: '*', args: ['input', 2] } },
          output: { type: 'observed', expression: { op: '+', args: ['intermediate', 1] } },
        },
        equations: [],
      }

      const graph = buildDependencyGraph(model)
      const chains = findDependencyChains(graph, 'default.input')

      expect(chains.length).toBeGreaterThan(0)

      // Should find chain: input -> intermediate -> output
      const longChain = chains.find((chain) => chain.length === 3)
      expect(longChain).toBeDefined()
      expect(longChain).toEqual(['default.input', 'default.intermediate', 'default.output'])
    })

    it('should respect max depth limit', () => {
      const model: Model = {
        variables: {
          a: { type: 'parameter' },
          b: { type: 'observed', expression: { op: '+', args: ['a', 1] } },
          c: { type: 'observed', expression: { op: '+', args: ['b', 1] } },
          d: { type: 'observed', expression: { op: '+', args: ['c', 1] } },
          e: { type: 'observed', expression: { op: '+', args: ['d', 1] } },
        },
        equations: [],
      }

      const graph = buildDependencyGraph(model)
      const chains = findDependencyChains(graph, 'default.a', 3)

      // All chains should be <= 3 in length
      for (const chain of chains) {
        expect(chain.length).toBeLessThanOrEqual(3)
      }
    })
  })

  describe('graph interface methods', () => {
    it('should provide correct adjacency information', () => {
      const expr: Expr = {
        op: '+',
        args: ['x', { op: '*', args: ['y', 'z'] }],
      }

      const graph = buildDependencyGraph(expr)

      // x should be adjacent to result
      const xAdjacent = graph.adjacency('default.x')
      expect(xAdjacent).toContain('default.result')

      // result should have x, y, z as predecessors
      const resultPreds = graph.predecessors('default.result')
      expect(resultPreds).toContain('default.x')
      expect(resultPreds).toContain('default.y')
      expect(resultPreds).toContain('default.z')

      // x should have result as successor
      const xSuccessors = graph.successors('default.x')
      expect(xSuccessors).toContain('default.result')
    })
  })

  describe('topological sorting', () => {
    it('should provide topologically sorted nodes', () => {
      const model: Model = {
        variables: {
          a: { type: 'parameter' },
          b: { type: 'observed', expression: { op: '+', args: ['a', 1] } },
          c: { type: 'observed', expression: { op: '*', args: ['b', 2] } },
        },
        equations: [],
      }

      const graph = buildDependencyGraph(model)
      const sorted = graph.topologicalSort()

      // Find positions
      const aPos = sorted.findIndex((n) => n.name === 'default.a')
      const bPos = sorted.findIndex((n) => n.name === 'default.b')
      const cPos = sorted.findIndex((n) => n.name === 'default.c')

      // a should come before b, b should come before c
      expect(aPos).toBeLessThan(bPos)
      expect(bPos).toBeLessThan(cPos)
    })
  })
})
