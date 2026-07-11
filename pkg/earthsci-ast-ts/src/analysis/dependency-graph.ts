/**
 * Variable dependency graph construction and analysis
 *
 * This module provides functions to construct and analyze dependency graphs
 * for variables in ESM files, supporting circular dependency detection,
 * topological sorting, and dead code elimination.
 */

import type { Model, EsmFile, ReactionSystem, Equation, Expr } from '../types.js'
import type { DependencyGraph, DependencyNode, DependencyRelation } from './types.js'
import { freeVariables } from '../expression.js'
import { buildGraph, lhsTargetName } from '../graph.js'
import { forEachModelVariable, forEachEquation, isReferenceStub } from '../traverse.js'

/**
 * `system` value stamped on nodes when {@link buildDependencyGraph} is called
 * with `mergeAcrossSystems: true`: variables from every component are folded
 * into one namespace, so their individual originating system is discarded and
 * recorded under this shared sentinel.
 */
const MERGED_SYSTEM = 'merged'

/** The `{ source, target, data }` edge shape used throughout this module. */
type RawEdge = { source: string; target: string; data: DependencyRelation }

/**
 * Build a dependency graph from an ESM file, model, or expression
 * @param target The target to analyze
 * @param options Analysis options
 * @returns Dependency graph with nodes and edges
 */
export function buildDependencyGraph(
  target: EsmFile | Model | ReactionSystem | Expr,
  options: {
    includeParameters?: boolean
    includeObserved?: boolean
    mergeAcrossSystems?: boolean
  } = {},
): DependencyGraph {
  const nodes: DependencyNode[] = []
  const edges: RawEdge[] = []
  const nodeMap = new Map<string, DependencyNode>()

  const { includeParameters = true, includeObserved = true, mergeAcrossSystems = false } = options

  // Scoped variable name: bare when merging systems, `system.var` otherwise.
  function scopedName(varName: string, system: string): string {
    return mergeAcrossSystems ? varName : `${system}.${varName}`
  }

  // Add a node (deduped by scoped name); returns the created/existing node.
  function addNode(
    name: string,
    kind: DependencyNode['kind'],
    system: string,
    units?: string,
    definition?: Expr,
  ): DependencyNode {
    const scopedVarName = scopedName(name, system)

    let node = nodeMap.get(scopedVarName)
    if (!node) {
      node = {
        name: scopedVarName,
        kind,
        system: mergeAcrossSystems ? MERGED_SYSTEM : system,
        units,
        definition,
        depth: 0, // Calculated after the graph is assembled.
      }
      nodes.push(node)
      nodeMap.set(scopedVarName, node)
    }

    return node
  }

  // Append a dependency edge.
  function addDependency(
    sourceVar: string,
    targetVar: string,
    type: DependencyRelation['type'],
    expression?: Expr,
  ) {
    edges.push({
      source: sourceVar,
      target: targetVar,
      data: { source: sourceVar, target: targetVar, type, expression },
    })
  }

  // Process a model (variables, equations, and inline subsystems recursively).
  function processModel(model: Model, systemId: string) {
    forEachModelVariable(model, (variable, varName) => {
      if (variable.type === 'parameter' && !includeParameters) return
      if (variable.type === 'observed' && !includeObserved) return

      addNode(varName, variable.type, systemId, variable.units, variable.expression)

      // A variable with a definition expression depends on its free variables.
      if (variable.expression) {
        for (const depVar of freeVariables(variable.expression)) {
          // Referenced-but-undeclared variables default to 'parameter'.
          addNode(depVar, 'parameter', systemId)
          addDependency(
            scopedName(depVar, systemId),
            scopedName(varName, systemId),
            'definition_dependency',
            variable.expression,
          )
        }
      }
    })

    forEachEquation(model, (equation) => processEquation(equation, systemId))

    // Inline-model subsystems recurse; reference stubs (`{ref}` includes and
    // `{kind}` data loaders) carry no equations and are skipped.
    if (model.subsystems) {
      for (const [subSystemId, subModel] of Object.entries(model.subsystems)) {
        if (isReferenceStub(subModel)) continue
        const fullSubSystemId = mergeAcrossSystems ? systemId : `${systemId}.${subSystemId}`
        processModel(subModel as Model, fullSubSystemId)
      }
    }
  }

  // Process a reaction system (species, parameters, and reactions).
  function processReactionSystem(reactionSystem: ReactionSystem, systemId: string) {
    if (reactionSystem.species) {
      for (const [speciesName, species] of Object.entries(reactionSystem.species)) {
        addNode(speciesName, 'species', systemId, species.units)
      }
    }

    if (reactionSystem.parameters && includeParameters) {
      for (const [paramName, parameter] of Object.entries(reactionSystem.parameters)) {
        addNode(paramName, 'parameter', systemId, parameter.units)
      }
    }

    if (reactionSystem.reactions) {
      reactionSystem.reactions.forEach((reaction) => {
        const rateVars = freeVariables(reaction.rate)

        const involvedSpecies = new Set<string>()
        if (reaction.substrates) {
          for (const substrate of reaction.substrates) involvedSpecies.add(substrate.species)
        }
        if (reaction.products) {
          for (const product of reaction.products) involvedSpecies.add(product.species)
        }

        for (const species of involvedSpecies) {
          for (const rateVar of rateVars) {
            addDependency(
              scopedName(rateVar, systemId),
              scopedName(species, systemId),
              'parameter_dependency',
              reaction.rate,
            )
          }
        }
      })
    }
  }

  // Process an equation: RHS free variables depend on the LHS target.
  function processEquation(equation: Equation, systemId: string) {
    const targetName = lhsTargetName(equation.lhs)
    if (targetName === undefined) return // no recognizable defined variable
    addNode(targetName, 'state', systemId)

    for (const rhsVar of freeVariables(equation.rhs)) {
      addNode(rhsVar, 'parameter', systemId) // Default assumption for undeclared vars.
      addDependency(
        scopedName(rhsVar, systemId),
        scopedName(targetName, systemId),
        'direct',
        equation.rhs,
      )
    }
  }

  // Process a single expression: its free variables feed a synthetic result.
  function processExpression(expr: Expr, targetVar: string, systemId: string) {
    addNode(targetVar, 'observed', systemId, undefined, expr)
    for (const depVar of freeVariables(expr)) {
      addNode(depVar, 'parameter', systemId)
      addDependency(scopedName(depVar, systemId), scopedName(targetVar, systemId), 'direct', expr)
    }
  }

  // Dispatch on the target type (each check keys off a shape-unique field).
  if (typeof target === 'object' && target !== null && 'esm' in target) {
    const esmFile = target as EsmFile

    // Inline models (unresolved refs carry no variables).
    if (esmFile.models) {
      for (const [modelId, model] of Object.entries(esmFile.models)) {
        if ('ref' in model) continue
        processModel(model as Model, modelId)
      }
    }

    if (esmFile.reaction_systems) {
      for (const [systemId, reactionSystem] of Object.entries(esmFile.reaction_systems)) {
        processReactionSystem(reactionSystem, systemId)
      }
    }
  } else if (typeof target === 'object' && target !== null && 'variables' in target) {
    processModel(target as Model, 'default')
  } else if (typeof target === 'object' && target !== null && 'species' in target) {
    processReactionSystem(target as ReactionSystem, 'default')
  } else {
    processExpression(target as Expr, 'result', 'default')
  }

  // Calculate depths using topological sort.
  calculateDepths(nodes, edges)

  // Detect circular dependencies and mark the participating edges.
  const circularDeps = detectCircularDependencies(edges)
  for (const edge of edges) {
    if (
      circularDeps.some(
        (cycle) =>
          cycle.some((node) => node === edge.source) && cycle.some((node) => node === edge.target),
      )
    ) {
      edge.data.type = 'circular'
    }
  }

  // The base Graph (nodes/edges + adjacency/predecessor/successor lookups) is
  // assembled by the shared graph.ts helper; this builder only layers on the
  // dependency-specific methods below.
  const base = buildGraph(nodes, edges, (node) => node.name)

  const getCycles = (): DependencyNode[][] =>
    circularDeps.map((cycle) =>
      cycle
        .map((nodeName) => nodeMap.get(nodeName))
        .filter((node): node is DependencyNode => node !== undefined),
    )

  return {
    ...base,

    hasCircularDependencies(): boolean {
      return circularDeps.length > 0
    },

    getCycles,

    /** @deprecated Misnomer — returns raw DFS cycles, not SCCs. Use getCycles. */
    getStronglyConnectedComponents(): DependencyNode[][] {
      return getCycles()
    },

    topologicalSort(): DependencyNode[] {
      return topologicalSort(nodes, edges)
    },
  }
}

/**
 * Build the adjacency list, in-degree map, and name→node map shared by the
 * two Kahn's-algorithm passes ({@link calculateDepths} and
 * {@link topologicalSort}).
 */
function buildAdjacency(nodes: DependencyNode[], edges: RawEdge[]) {
  const inDegree = new Map<string, number>()
  const adjacencyList = new Map<string, string[]>()
  const nodeMap = new Map<string, DependencyNode>()

  for (const node of nodes) {
    inDegree.set(node.name, 0)
    adjacencyList.set(node.name, [])
    nodeMap.set(node.name, node)
  }

  for (const edge of edges) {
    adjacencyList.get(edge.source)?.push(edge.target)
    inDegree.set(edge.target, (inDegree.get(edge.target) || 0) + 1)
  }

  return { inDegree, adjacencyList, nodeMap }
}

/**
 * Calculate depth levels for nodes using topological ordering (Kahn's
 * algorithm), writing each node's longest-path depth back into `node.depth`.
 */
function calculateDepths(nodes: DependencyNode[], edges: RawEdge[]) {
  const { inDegree, adjacencyList, nodeMap } = buildAdjacency(nodes, edges)

  const queue: string[] = []
  for (const node of nodes) {
    if (inDegree.get(node.name) === 0) {
      queue.push(node.name)
      node.depth = 0
    }
  }

  while (queue.length > 0) {
    const current = queue.shift()!
    const currentNode = nodeMap.get(current)!

    for (const neighbor of adjacencyList.get(current) || []) {
      const neighborNode = nodeMap.get(neighbor)!
      const newInDegree = (inDegree.get(neighbor) || 0) - 1
      inDegree.set(neighbor, newInDegree)

      neighborNode.depth = Math.max(neighborNode.depth, currentNode.depth + 1)

      if (newInDegree === 0) {
        queue.push(neighbor)
      }
    }
  }
}

/**
 * Detect circular dependencies using DFS.
 *
 * Returns one entry per back-edge cycle discovered; entries may overlap (a node
 * can appear in several cycles). These are NOT strongly-connected components.
 */
function detectCircularDependencies(edges: RawEdge[]): string[][] {
  const graph = new Map<string, string[]>()
  const visited = new Set<string>()
  const recStack = new Set<string>()
  const cycles: string[][] = []

  for (const edge of edges) {
    if (!graph.has(edge.source)) {
      graph.set(edge.source, [])
    }
    graph.get(edge.source)?.push(edge.target)
  }

  function dfs(node: string, path: string[]): void {
    visited.add(node)
    recStack.add(node)
    path.push(node)

    for (const neighbor of graph.get(node) || []) {
      if (!visited.has(neighbor)) {
        dfs(neighbor, [...path])
      } else if (recStack.has(neighbor)) {
        // Found a cycle
        const cycleStart = path.indexOf(neighbor)
        const cycle = path.slice(cycleStart).concat([neighbor])
        cycles.push(cycle)
      }
    }

    recStack.delete(node)
  }

  for (const node of graph.keys()) {
    if (!visited.has(node)) {
      dfs(node, [])
    }
  }

  return cycles
}

/**
 * Perform topological sort of dependency nodes using Kahn's algorithm.
 */
function topologicalSort(nodes: DependencyNode[], edges: RawEdge[]): DependencyNode[] {
  const { inDegree, adjacencyList, nodeMap } = buildAdjacency(nodes, edges)

  const queue: string[] = []
  const result: DependencyNode[] = []

  for (const node of nodes) {
    if (inDegree.get(node.name) === 0) {
      queue.push(node.name)
    }
  }

  while (queue.length > 0) {
    const current = queue.shift()!
    result.push(nodeMap.get(current)!)

    for (const neighbor of adjacencyList.get(current) || []) {
      const newInDegree = (inDegree.get(neighbor) || 0) - 1
      inDegree.set(neighbor, newInDegree)

      if (newInDegree === 0) {
        queue.push(neighbor)
      }
    }
  }

  return result
}

/**
 * Find dependency-graph sinks: non-state variables that nothing else depends
 * on. Note this includes terminal observed outputs — a sink is only truly
 * "dead" if it is also not consumed outside the model (plots, couplings,
 * downstream tooling), which this graph cannot see. State variables are
 * excluded because they are integration outputs by definition.
 */
export function findDeadVariables(graph: DependencyGraph): DependencyNode[] {
  const deadVars: DependencyNode[] = []

  for (const node of graph.nodes) {
    if (graph.successors(node.name).length === 0 && node.kind !== 'state') {
      deadVars.push(node)
    }
  }

  return deadVars
}

/**
 * Enumerate every path from `startNode` to a sink (a node with no successors),
 * following successor edges. Paths that revisit a node or exceed `maxDepth`
 * hops are pruned.
 */
export function findDependencyChains(
  graph: DependencyGraph,
  startNode: string,
  maxDepth: number = 10,
): string[][] {
  const chains: string[][] = []

  function dfs(currentNode: string, path: string[], visited: Set<string>, depth: number) {
    if (depth > maxDepth || visited.has(currentNode)) {
      return
    }

    visited.add(currentNode)
    path.push(currentNode)

    const successors = graph.successors(currentNode)
    if (successors.length === 0) {
      // Leaf node - add the complete chain
      chains.push([...path])
    } else {
      for (const successor of successors) {
        dfs(successor, [...path], new Set(visited), depth + 1)
      }
    }
  }

  dfs(startNode, [], new Set(), 0)
  return chains
}
