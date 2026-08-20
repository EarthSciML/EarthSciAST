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
      // `rho` is an OBSERVED unknown because its defining equation has a bare
      // variable LHS (esm-spec §6.3.1). That equation is where the definition
      // lives from 1.0.0 on; there is no `variables.rho.expression` to read,
      // and the node's `kind` is derived from the equation, not declared.
      const model: Model = {
        variables: {
          T: { type: 'parameter', units: 'K' },
          P: { type: 'parameter', units: 'Pa' },
          rho: { type: 'unknown', units: 'kg/m³' },
        },
        equations: [
          { lhs: 'rho', rhs: { op: '/', args: ['P', { op: '*', args: ['R', 'T'] }] } },
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
          x: { type: 'unknown' },
          z: { type: 'unknown' },
          a: { type: 'parameter' },
          b: { type: 'parameter' },
        },
        equations: [
          { lhs: 'x', rhs: { op: '+', args: ['z', 'a'] } },
          { lhs: 'z', rhs: { op: '*', args: ['x', 'b'] } }, // Circular!
        ],
      }

      const graph = buildDependencyGraph(model)

      expect(graph.hasCircularDependencies()).toBe(true)
      const cycles = graph.getCycles()
      expect(cycles.length).toBeGreaterThan(0)

      // Deprecated alias should return the same cycles.
      expect(graph.getStronglyConnectedComponents()).toEqual(cycles)

      // Should find x and z in a cycle
      const cycleNodes = cycles.flat().map((n) => n.name)
      expect(cycleNodes).toContain('default.x')
      expect(cycleNodes).toContain('default.z')
    })

    it('should calculate node depths correctly', () => {
      const model: Model = {
        variables: {
          a: { type: 'parameter' },
          b: { type: 'unknown' },
          c: { type: 'unknown' },
          d: { type: 'unknown' },
        },
        equations: [
          { lhs: 'b', rhs: { op: '*', args: ['a', 2] } },
          { lhs: 'c', rhs: { op: '+', args: ['b', 1] } },
          { lhs: 'd', rhs: { op: '/', args: ['c', 'a'] } },
        ],
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
              y: { type: 'unknown' },
            },
            equations: [{ lhs: 'y', rhs: { op: '+', args: ['x', 1] } }],
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
          result: { type: 'unknown' },
        },
        equations: [{ lhs: 'result', rhs: { op: '*', args: ['used', 2] } }],
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
          intermediate: { type: 'unknown' },
          output: { type: 'unknown' },
        },
        equations: [
          { lhs: 'intermediate', rhs: { op: '*', args: ['input', 2] } },
          { lhs: 'output', rhs: { op: '+', args: ['intermediate', 1] } },
        ],
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
          b: { type: 'unknown' },
          c: { type: 'unknown' },
          d: { type: 'unknown' },
          e: { type: 'unknown' },
        },
        equations: [
          { lhs: 'b', rhs: { op: '+', args: ['a', 1] } },
          { lhs: 'c', rhs: { op: '+', args: ['b', 1] } },
          { lhs: 'd', rhs: { op: '+', args: ['c', 1] } },
          { lhs: 'e', rhs: { op: '+', args: ['d', 1] } },
        ],
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
          b: { type: 'unknown' },
          c: { type: 'unknown' },
        },
        equations: [
          { lhs: 'b', rhs: { op: '+', args: ['a', 1] } },
          { lhs: 'c', rhs: { op: '*', args: ['b', 2] } },
        ],
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
