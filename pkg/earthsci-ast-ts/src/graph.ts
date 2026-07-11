/**
 * Graph generation utilities for ESM files
 *
 * Provides functions to extract different graph representations from ESM files,
 * as specified in the ESM Libraries Specification Section 4.8.
 */

import type {
  EsmFile,
  CouplingEntry,
  Model,
  ReactionSystem,
  Equation,
  Reaction,
  Expr,
  ExpressionNode,
  Reference,
} from './types.js'
import { freeVariables } from './expression.js'
import {
  forEachComponent,
  forEachModelVariable,
  forEachEquation,
  isReferenceStub,
  type ContainerKind,
  type ComponentEntry,
} from './traverse.js'
import { formatChemicalName } from './pretty-print.js'

/** Graph node representing a component in the system */
export interface ComponentNode {
  /** Unique identifier for this component */
  id: string
  /** Display name for the component */
  name: string
  /** Type of component */
  type: 'model' | 'reaction_system' | 'data_loader'
  /** Optional description */
  description?: string
  /** Optional reference information */
  reference?: Reference
  /** Metadata with counts for this component */
  metadata: {
    /** Number of variables */
    var_count: number
    /** Number of equations */
    eq_count: number
    /** Number of species (for reaction systems) */
    species_count: number
  }
}

/** Graph edge representing a coupling relationship */
export interface CouplingEdge {
  /** Unique identifier for this edge */
  id: string
  /** Source component ID */
  from: string
  /** Target component ID */
  to: string
  /** Type of coupling */
  type: CouplingEntry['type']
  /** Display label for the edge */
  label: string
  /** Optional description */
  description?: string
  /** Full coupling entry for editing */
  coupling: CouplingEntry
}

/** System graph representation with components and couplings */
export interface ComponentGraph {
  /** All components in the system */
  nodes: ComponentNode[]
  /** All coupling relationships */
  edges: CouplingEdge[]
}

/**
 * Directed graph with node/edge lists plus adjacency, predecessor, and
 * successor lookups (ESM Libraries Specification §4.8). Nodes are addressed by
 * a string key (`ComponentNode.id` / `VariableNode.name`); edges reference
 * those keys through `source`/`target`.
 */
export interface Graph<N, E> {
  /** All nodes in the graph */
  nodes: N[]
  /** All edges in the graph */
  edges: Array<{ source: string; target: string; data: E }>
  /** Get adjacent nodes for a given node */
  adjacency(node: string): string[]
  /** Get predecessor nodes for a given node */
  predecessors(node: string): string[]
  /** Get successor nodes for a given node */
  successors(node: string): string[]
}

/** Graph node representing a variable/parameter/species in the system */
export interface VariableNode {
  /** Unique identifier for this variable (scoped, e.g., "Transport.temperature") */
  name: string
  /** Type of variable */
  kind: 'state' | 'parameter' | 'observed' | 'brownian' | 'discrete' | 'species'
  /** Units if specified */
  units?: string
  /** System/component this variable belongs to */
  system: string
}

/**
 * Graph edge representing a dependency between variables.
 *
 * The `equation_index` sentinel {@link NON_EQUATION_INDEX} (`-1`) marks a
 * dependency that does not originate from a positionally-numbered equation or
 * reaction — i.e. an observed/expression definition or a coupling variable map.
 */
export interface DependencyEdge {
  /** Source variable name */
  source: string
  /** Target variable name */
  target: string
  /**
   * PROVENANCE category of the dependency — which structural site produced it,
   * NOT a classification of the operators involved. See {@link EDGE_PROVENANCE}
   * for the mapping. These values are historical labels and do NOT track the
   * actual operator: an equation edge is always `'additive'` (even for
   * `w = u * v`) and an observed-definition edge is always `'multiplicative'`
   * (even for `w = u + v`), regardless of the `+`/`*`/etc. actually used. Do
   * not read arithmetic meaning into them.
   */
  relationship: 'additive' | 'multiplicative' | 'rate' | 'stoichiometric'
  /**
   * Position of the equation/reaction that created this dependency, or
   * {@link NON_EQUATION_INDEX} (`-1`) when the dependency has no positional
   * equation (observed-variable definitions and coupling maps).
   */
  equation_index: number
  /** The expression that created this dependency */
  expression: Expr
}

/**
 * Sentinel `equation_index` for {@link DependencyEdge}s that are not produced by
 * a positionally-numbered equation or reaction (observed-variable definitions
 * and coupling variable maps).
 */
export const NON_EQUATION_INDEX = -1

/**
 * PROVENANCE categories for {@link DependencyEdge.relationship}. Each KEY names
 * the structural site that produced the edge; each VALUE is the wire string
 * emitted downstream (kept identical for back-compat and exporter styling).
 *
 * The values are historical and intentionally do NOT describe the operator:
 * an `equation` edge is always `'additive'` and a `definition` edge always
 * `'multiplicative'` no matter which operators (`+`, `*`, `-`, …) appear in the
 * source expression. Call sites reference these constants so the intent
 * (provenance, not arithmetic) is explicit at the point of use.
 */
const EDGE_PROVENANCE = {
  /** An RHS variable of a dynamic equation → its LHS (state) variable. */
  equation: 'additive',
  /** A free variable of an observed/expression definition → the defined value. */
  definition: 'multiplicative',
  /** A reaction-rate variable → a species the reaction produces or consumes. */
  rate: 'rate',
  /** A substrate species → a product species via reaction stoichiometry. */
  stoichiometry: 'stoichiometric',
} as const

/**
 * Assemble a {@link Graph} from a node list and a `source`/`target`/`data` edge
 * list, wiring the adjacency / predecessor / successor lookups.
 *
 * `keyOf` extracts each node's identity string (`node.id` for component graphs,
 * `node.name` for variable graphs); edges reference nodes by that same key. All
 * nodes are pre-registered, so a lookup on a KNOWN node with no incident edges
 * returns `[]` (not `undefined`); a lookup on an UNKNOWN key also returns `[]`.
 * An edge whose endpoint is not a registered node contributes no adjacency (the
 * `?.` guard skips it silently), matching the hand-rolled plumbing this helper
 * replaces.
 *
 * Shared by {@link componentGraph}, {@link expressionGraph}, and the analysis
 * dependency-graph builder so the closure/adjacency semantics live in one place.
 */
export function buildGraph<N, E>(
  nodes: N[],
  edges: Array<{ source: string; target: string; data: E }>,
  keyOf: (node: N) => string,
): Graph<N, E> {
  const adjacencyMap = new Map<string, Set<string>>()
  const predecessorMap = new Map<string, Set<string>>()
  const successorMap = new Map<string, Set<string>>()

  // Initialize maps for all nodes so known-but-unconnected nodes resolve to [].
  for (const node of nodes) {
    const key = keyOf(node)
    adjacencyMap.set(key, new Set())
    predecessorMap.set(key, new Set())
    successorMap.set(key, new Set())
  }

  // Build adjacency relationships from edges.
  for (const { source, target } of edges) {
    // Adjacency includes both predecessors and successors.
    adjacencyMap.get(source)?.add(target)
    adjacencyMap.get(target)?.add(source)
    // Predecessors (nodes that point TO this node).
    predecessorMap.get(target)?.add(source)
    // Successors (nodes that this node points TO).
    successorMap.get(source)?.add(target)
  }

  return {
    nodes,
    edges,

    adjacency(node: string): string[] {
      return Array.from(adjacencyMap.get(node) || [])
    },

    predecessors(node: string): string[] {
      return Array.from(predecessorMap.get(node) || [])
    },

    successors(node: string): string[] {
      return Array.from(successorMap.get(node) || [])
    },
  }
}

/**
 * Extract the raw component nodes and coupling edges (the {@link ComponentGraph}
 * `{nodes, edges}` shape) from an ESM file. Shared by {@link componentGraph}
 * (which wraps it in the adjacency-bearing {@link Graph}) and the deprecated
 * {@link component_graph} alias.
 */
function extractComponentGraph(esmFile: EsmFile): ComponentGraph {
  const nodes: ComponentNode[] = []
  const edges: CouplingEdge[] = []

  // Extract nodes from different component types

  // Models. Unresolved SubsystemRef entries still appear as nodes (they are
  // components of the system) but carry no counts.
  if (esmFile.models) {
    for (const [id, model] of Object.entries(esmFile.models)) {
      const inline = 'ref' in model ? undefined : (model as Model)
      nodes.push({
        id,
        name: id,
        type: 'model',
        description: inline?.reference?.notes,
        reference: inline?.reference,
        metadata: {
          var_count: inline?.variables ? Object.keys(inline.variables).length : 0,
          eq_count: inline?.equations ? inline.equations.length : 0,
          species_count: 0,
        },
      })
    }
  }

  // Reaction systems
  if (esmFile.reaction_systems) {
    for (const [id, reactionSystem] of Object.entries(esmFile.reaction_systems)) {
      nodes.push({
        id,
        name: id,
        type: 'reaction_system',
        description: reactionSystem.reference?.notes,
        reference: reactionSystem.reference,
        metadata: {
          var_count: 0,
          eq_count: reactionSystem.reactions ? reactionSystem.reactions.length : 0,
          species_count: reactionSystem.species ? Object.keys(reactionSystem.species).length : 0,
        },
      })
    }
  }

  // Data loaders
  if (esmFile.data_loaders) {
    for (const [id, dataLoader] of Object.entries(esmFile.data_loaders)) {
      nodes.push({
        id,
        name: id,
        type: 'data_loader',
        description: dataLoader.reference?.notes,
        reference: dataLoader.reference,
        metadata: {
          var_count: dataLoader.variables ? Object.keys(dataLoader.variables).length : 0,
          eq_count: 0,
          species_count: 0,
        },
      })
    }
  }

  // Extract edges from coupling entries
  if (esmFile.coupling) {
    esmFile.coupling.forEach((coupling, index) => {
      const edgeId = `coupling-${index}`

      switch (coupling.type) {
        case 'operator_compose':
          // operator_compose connects multiple systems
          if (coupling.systems && coupling.systems.length >= 2) {
            // Create edges between consecutive systems
            for (let i = 0; i < coupling.systems.length - 1; i++) {
              edges.push({
                id: `${edgeId}-${i}`,
                from: coupling.systems[i],
                to: coupling.systems[i + 1],
                type: 'operator_compose',
                label: 'compose',
                description: coupling.description,
                coupling,
              })
            }
          }
          break

        case 'couple':
          // couple connects exactly two systems
          if (coupling.systems && coupling.systems.length === 2) {
            edges.push({
              id: edgeId,
              from: coupling.systems[0],
              to: coupling.systems[1],
              type: 'couple',
              label: 'couple',
              description: coupling.description,
              coupling,
            })
          }
          break

        case 'variable_map':
          // variable_map connects two variables from different components
          if (coupling.from && coupling.to) {
            const fromParts = coupling.from.split('.')
            const toParts = coupling.to.split('.')

            if (fromParts.length >= 2 && toParts.length >= 2) {
              const fromComponent = fromParts[0]
              const toComponent = toParts[0]
              const variable = fromParts.slice(1).join('.')

              edges.push({
                id: edgeId,
                from: fromComponent,
                to: toComponent,
                type: 'variable_map',
                label: variable,
                description: coupling.description || `${coupling.from} → ${coupling.to}`,
                coupling,
              })
            }
          }
          break

        case 'callback': {
          // callback connects a source to a target via a callback function.
          // The current schema no longer declares source/target/callback on
          // CouplingCallback; tolerate legacy entries that still carry them.
          const cb = coupling as typeof coupling & {
            source?: string
            target?: string
            callback?: string
          }
          if (cb.source && cb.target) {
            edges.push({
              id: edgeId,
              from: cb.source,
              to: cb.target,
              type: 'callback',
              label: cb.callback || 'callback',
              description: coupling.description,
              coupling,
            })
          }
          break
        }

        case 'event':
          // A cross-system event is not a directed data flow between two
          // components; its system references live inside condition/affect
          // expressions. It contributes no component-graph edge.
          break
      }
    })
  }

  return { nodes, edges }
}

/**
 * Extract the system graph from an ESM file.
 * Returns a directed graph (ESM Libraries Specification §4.8) where nodes are
 * model components and edges are coupling rules, with adjacency helpers.
 */
export function componentGraph(file: EsmFile): Graph<ComponentNode, CouplingEdge> {
  const { nodes, edges } = extractComponentGraph(file)

  // Convert CouplingEdge (from/to) into the Graph edge (source/target/data) shape.
  const graphEdges = edges.map((edge) => ({
    source: edge.from,
    target: edge.to,
    data: edge,
  }))

  return buildGraph(nodes, graphEdges, (node) => node.id)
}

/**
 * Extract the system graph from an ESM file in the legacy `{nodes, edges}`
 * {@link ComponentGraph} shape (edges as {@link CouplingEdge} carrying
 * `from`/`to`).
 *
 * @deprecated Prefer {@link componentGraph}, which returns the richer
 * {@link Graph} with adjacency/predecessor/successor helpers. This snake_case
 * alias is retained because the editor's web-components consume the flat
 * `{nodes, edges}` shape; it will be removed once those callers migrate.
 */
export function component_graph(esmFile: EsmFile): ComponentGraph {
  return extractComponentGraph(esmFile)
}

/**
 * Utility to check if a component exists in the ESM file
 */
export function componentExists(esmFile: EsmFile, componentId: string): boolean {
  return !!(
    esmFile.models?.[componentId] ||
    esmFile.reaction_systems?.[componentId] ||
    esmFile.data_loaders?.[componentId]
  )
}

/**
 * Get the type of a component by its ID
 */
export function getComponentType(
  esmFile: EsmFile,
  componentId: string,
): ComponentNode['type'] | null {
  if (esmFile.models?.[componentId]) return 'model'
  if (esmFile.reaction_systems?.[componentId]) return 'reaction_system'
  if (esmFile.data_loaders?.[componentId]) return 'data_loader'
  return null
}

// ---------------------------------------------------------------------------
// expressionGraph — variable-level dependency graph
//
// `expressionGraph` is a thin dispatcher over the target-type union; the actual
// node/edge assembly lives in module-scope helpers that take an explicit
// `ExprGraphBuilder` context (rather than closing over per-call mutable state).
// Model / reaction-system / subsystem enumeration is delegated to the shared
// `traverse.js` walker so the skip rules are defined in exactly one place.
// ---------------------------------------------------------------------------

/**
 * Mutable accumulator threaded through the `expressionGraph` helpers. Holds the
 * growing node/edge lists and the dedup map, and exposes the two mutation
 * primitives (`addNode`, `addDependency`) so the helpers never touch the raw
 * arrays directly.
 */
interface ExprGraphBuilder {
  readonly nodes: VariableNode[]
  readonly edges: Array<{ source: string; target: string; data: DependencyEdge }>
  readonly nodeMap: Map<string, VariableNode>
  /** Add a node (deduped by scoped name); returns the scoped name. */
  addNode(name: string, kind: VariableNode['kind'], units?: string, system?: string): string
  /** Append a dependency edge from `sourceVar` to `targetVar`. */
  addDependency(
    sourceVar: string,
    targetVar: string,
    relationship: DependencyEdge['relationship'],
    equationIndex: number,
    expression: Expr,
  ): void
}

/** Create a fresh {@link ExprGraphBuilder} backed by empty node/edge lists. */
function createExprGraphBuilder(): ExprGraphBuilder {
  const nodes: VariableNode[] = []
  const edges: Array<{ source: string; target: string; data: DependencyEdge }> = []
  const nodeMap = new Map<string, VariableNode>()

  return {
    nodes,
    edges,
    nodeMap,

    addNode(name, kind, units, system = 'default') {
      const scopedName = system !== 'default' ? `${system}.${name}` : name
      if (!nodeMap.has(scopedName)) {
        const node: VariableNode = { name: scopedName, kind, units, system }
        nodes.push(node)
        nodeMap.set(scopedName, node)
      }
      return scopedName
    },

    addDependency(sourceVar, targetVar, relationship, equationIndex, expression) {
      const edgeData: DependencyEdge = {
        source: sourceVar,
        target: targetVar,
        relationship,
        equation_index: equationIndex,
        expression,
      }
      edges.push({ source: sourceVar, target: targetVar, data: edgeData })
    },
  }
}

/**
 * The variable name an equation LHS defines: a bare name, or the name under
 * derivative / element-index / aggregate-output wrappers (`D(x)`,
 * `index(v, i)`, `aggregate(..., expr: D(index(v, i)))`).
 *
 * Exported so other dependency-graph builders (see `analysis/`) share one
 * definition instead of copying it.
 */
export function lhsTargetName(lhs: Expr): string | undefined {
  if (typeof lhs === 'string') return lhs
  if (lhs && typeof lhs === 'object' && 'op' in lhs) {
    const node = lhs as ExpressionNode
    switch (node.op) {
      case 'D':
      case 'index':
        return node.args && node.args.length > 0 ? lhsTargetName(node.args[0]) : undefined
      case 'aggregate': {
        const body = (node as { expr?: Expr }).expr
        return body !== undefined ? lhsTargetName(body) : undefined
      }
      default:
        return undefined
    }
  }
  return undefined
}

/** Add a model's variables (+ observed-definition edges) and equations. */
function processModel(b: ExprGraphBuilder, model: Model, systemId: string): void {
  forEachModelVariable(model, (variable, varName) => {
    b.addNode(varName, variable.type, variable.units, systemId)

    // If it's an observed variable with an expression, create dependencies.
    if (variable.type === 'observed' && variable.expression) {
      const observedVar = b.addNode(varName, 'observed', variable.units, systemId)
      for (const freeVar of freeVariables(variable.expression)) {
        const sourceVar = b.addNode(freeVar, 'parameter', undefined, systemId)
        b.addDependency(
          sourceVar,
          observedVar,
          EDGE_PROVENANCE.definition,
          NON_EQUATION_INDEX,
          variable.expression,
        )
      }
    }
  })

  forEachEquation(model, (equation, index) => processEquation(b, equation, index, systemId))
}

/** Add a reaction system's species, parameters, reactions, and constraints. */
function processReactionSystem(
  b: ExprGraphBuilder,
  reactionSystem: ReactionSystem,
  systemId: string,
): void {
  for (const [speciesName, species] of Object.entries(reactionSystem.species || {})) {
    b.addNode(speciesName, 'species', species.units, systemId)
  }

  for (const [paramName, parameter] of Object.entries(reactionSystem.parameters || {})) {
    b.addNode(paramName, 'parameter', parameter.units, systemId)
  }

  const reactions = reactionSystem.reactions || []
  reactions.forEach((reaction, index) => processReaction(b, reaction, index, systemId))

  // Constraint equations are numbered after the reactions.
  if (reactionSystem.constraint_equations) {
    reactionSystem.constraint_equations.forEach((equation, index) => {
      processEquation(b, equation, index + reactions.length, systemId)
    })
  }
}

/** Add an equation's LHS/RHS dependency edges. */
function processEquation(
  b: ExprGraphBuilder,
  equation: Equation,
  equationIndex: number,
  systemId: string,
): void {
  const targetName = lhsTargetName(equation.lhs)
  if (targetName === undefined) return // no recognizable defined variable
  const lhsVar = b.addNode(targetName, 'state', undefined, systemId)

  // Create dependencies from all RHS variables to the LHS variable.
  for (const rhsVar of freeVariables(equation.rhs)) {
    const sourceVar = b.addNode(rhsVar, 'parameter', undefined, systemId)
    b.addDependency(sourceVar, lhsVar, EDGE_PROVENANCE.equation, equationIndex, equation.rhs)
  }
}

/** Add a reaction's rate (parameter→species) and stoichiometric edges. */
function processReaction(
  b: ExprGraphBuilder,
  reaction: Reaction,
  reactionIndex: number,
  systemId: string,
): void {
  const rateVars = freeVariables(reaction.rate)

  // Substrates are consumed (negative stoichiometry).
  if (reaction.substrates) {
    for (const substrate of reaction.substrates) {
      const substrateVar = b.addNode(substrate.species, 'species', undefined, systemId)

      // Rate parameters affect the substrate species.
      for (const rateVar of rateVars) {
        const paramVar = b.addNode(rateVar, 'parameter', undefined, systemId)
        b.addDependency(paramVar, substrateVar, EDGE_PROVENANCE.rate, reactionIndex, reaction.rate)
      }
    }
  }

  // Products are produced (positive stoichiometry).
  if (reaction.products) {
    for (const product of reaction.products) {
      const productVar = b.addNode(product.species, 'species', undefined, systemId)

      // Rate parameters affect the product species.
      for (const rateVar of rateVars) {
        const paramVar = b.addNode(rateVar, 'parameter', undefined, systemId)
        b.addDependency(paramVar, productVar, EDGE_PROVENANCE.rate, reactionIndex, reaction.rate)
      }

      // Substrates affect products through stoichiometry.
      if (reaction.substrates) {
        for (const substrate of reaction.substrates) {
          const substrateVar = b.addNode(substrate.species, 'species', undefined, systemId)
          b.addDependency(
            substrateVar,
            productVar,
            EDGE_PROVENANCE.stoichiometry,
            reactionIndex,
            reaction.rate,
          )
        }
      }
    }
  }
}

/** Add a single expression's free-variable → result dependency edges. */
function processExpression(
  b: ExprGraphBuilder,
  expr: Expr,
  targetVar: string,
  equationIndex: number,
  systemId: string,
): void {
  const targetVariable = b.addNode(targetVar, 'observed', undefined, systemId)
  for (const freeVar of freeVariables(expr)) {
    const sourceVar = b.addNode(freeVar, 'parameter', undefined, systemId)
    b.addDependency(sourceVar, targetVariable, EDGE_PROVENANCE.definition, equationIndex, expr)
  }
}

/** Add cross-system dependency edges for `variable_map` coupling entries. */
function processCoupling(b: ExprGraphBuilder, coupling: CouplingEntry[]): void {
  for (const entry of coupling) {
    if (entry.type === 'variable_map') {
      const fromParts = entry.from.split('.')
      const toParts = entry.to.split('.')

      if (fromParts.length >= 2 && toParts.length >= 2) {
        const fromSystem = fromParts[0]
        const fromVar = fromParts.slice(1).join('.')
        const toSystem = toParts[0]
        const toVar = toParts.slice(1).join('.')

        const sourceVar = b.addNode(fromVar, 'parameter', undefined, fromSystem)
        const targetVar = b.addNode(toVar, 'parameter', undefined, toSystem)

        b.addDependency(
          sourceVar,
          targetVar,
          EDGE_PROVENANCE.definition,
          NON_EQUATION_INDEX,
          entry.from,
        )
      }
    }
  }
}

/**
 * Process one component and, recursively, its inline subsystems. Reference-stub
 * subsystems (`{ref}` includes and `{kind}` data loaders) are skipped via the
 * shared {@link isReferenceStub} predicate. Scoped names compose with a dot,
 * preserving the historical quirk that a `'default'` root yields bare child
 * names (`child`, not `default.child`) — this only applies when a bare
 * `Model` / `ReactionSystem` is passed directly to {@link expressionGraph}.
 */
function processComponentTree(
  b: ExprGraphBuilder,
  kind: ContainerKind,
  component: Model | ReactionSystem,
  systemId: string,
): void {
  if (kind === 'models') {
    processModel(b, component as Model, systemId)
  } else {
    processReactionSystem(b, component as ReactionSystem, systemId)
  }

  const subsystems = (component as { subsystems?: Record<string, ComponentEntry> }).subsystems
  if (!subsystems) return
  for (const [childName, child] of Object.entries(subsystems)) {
    if (isReferenceStub(child)) continue
    const childScoped = systemId === 'default' ? childName : `${systemId}.${childName}`
    processComponentTree(b, kind, child as Model | ReactionSystem, childScoped)
  }
}

/**
 * Extract a variable-level dependency graph from an ESM file, model, reaction
 * system, equation, reaction, or expression. Nodes are variables/parameters/
 * species; edges represent dependencies (ESM Libraries Specification §4.8).
 *
 * @param target The target to analyze (EsmFile, Model, ReactionSystem, Equation, Reaction, or Expr)
 * @param options Optional settings. `mergeCoupled` folds `variable_map` coupling
 *   entries into cross-system edges (EsmFile targets only). `merge_coupled` is a
 *   deprecated alias accepted for back-compat.
 * @returns Graph with VariableNode nodes and DependencyEdge edges
 */
export function expressionGraph(
  target: EsmFile | Model | ReactionSystem | Equation | Reaction | Expr,
  options: {
    mergeCoupled?: boolean
    /** @deprecated Use `mergeCoupled`. */
    merge_coupled?: boolean
  } = {},
): Graph<VariableNode, DependencyEdge> {
  const mergeCoupled = options.mergeCoupled ?? options.merge_coupled ?? false
  const b = createExprGraphBuilder()

  // Dispatch on the target type (order matters: each check keys off a field
  // unique to that shape).
  if (typeof target === 'object' && target !== null && 'esm' in target) {
    // EsmFile — walk every inline model / reaction system (and their inline
    // subsystems) through the shared traversal, skipping reference stubs.
    const esmFile = target as EsmFile
    forEachComponent(
      esmFile,
      (visit) => {
        if (visit.isReference) return
        processComponentTree(b, visit.kind, visit.component, visit.scopedName)
      },
      { recurse: false },
    )

    if (mergeCoupled && esmFile.coupling) {
      processCoupling(b, esmFile.coupling)
    }
  } else if (typeof target === 'object' && target !== null && 'variables' in target) {
    processComponentTree(b, 'models', target as Model, 'default')
  } else if (typeof target === 'object' && target !== null && 'species' in target) {
    processComponentTree(b, 'reaction_systems', target as ReactionSystem, 'default')
  } else if (typeof target === 'object' && target !== null && 'lhs' in target) {
    processEquation(b, target as Equation, 0, 'default')
  } else if (typeof target === 'object' && target !== null && 'rate' in target && !('op' in target)) {
    // Reaction (schema field is `rate`; every reaction carries one).
    processReaction(b, target as Reaction, 0, 'default')
  } else {
    // Expression — analyze dependencies within the expression itself.
    processExpression(b, target as Expr, 'expr_result', 0, 'default')
  }

  return buildGraph(b.nodes, b.edges, (node) => node.name)
}

// ---------------------------------------------------------------------------
// Graph exporters (DOT / Mermaid / JSON)
// ---------------------------------------------------------------------------

// Chemical subscript formatting for node/edge labels delegates to the
// element-aware formatter in pretty-print.ts so the same species renders
// identically everywhere.
const formatChemicalSubscripts = formatChemicalName

/** Narrow a graph node to a {@link ComponentNode} (carries `type`). */
function isComponentNode(node: object): node is ComponentNode {
  return 'type' in node
}

/** Narrow a graph node to a {@link VariableNode} (carries `kind`). */
function isVariableNode(node: object): node is VariableNode {
  return 'kind' in node
}

/** Narrow an edge payload to a {@link CouplingEdge} (carries `type`). */
function isCouplingEdgeData(data: unknown): data is CouplingEdge {
  return typeof data === 'object' && data !== null && 'type' in data
}

/** Narrow an edge payload to a {@link DependencyEdge} (carries `relationship`). */
function isDependencyEdgeData(data: unknown): data is DependencyEdge {
  return typeof data === 'object' && data !== null && 'relationship' in data
}

/**
 * The stable string key for a graph node: `id` for {@link ComponentNode},
 * `name` for {@link VariableNode}, falling back to `String(node)`.
 */
function nodeKey(node: object): string {
  if ('id' in node) return (node as { id: string }).id
  if ('name' in node) return (node as { name: string }).name
  return String(node)
}

/** The display label for a graph node (its `name` if any, else its key), with
 *  chemical subscripts applied. */
function nodeLabel(node: object): string {
  const raw = 'name' in node ? (node as { name: string }).name : nodeKey(node)
  return formatChemicalSubscripts(raw)
}

/**
 * Export graph as Graphviz DOT format.
 * Node shapes: box for models, ellipse for data_loaders, diamond for operators.
 * Edge styles: solid for compose, dashed for variable_map.
 */
export function toDot<N extends object, E>(graph: Graph<N, E>): string {
  const lines: string[] = []

  lines.push('digraph {')
  lines.push('  rankdir=TB;')
  lines.push('  node [fontname="Arial"];')
  lines.push('  edge [fontname="Arial"];')
  lines.push('')

  // Add nodes
  for (const node of graph.nodes) {
    let shape = 'ellipse'
    let color = 'lightblue'

    // Type-specific formatting for ComponentNode
    if (isComponentNode(node)) {
      switch (node.type) {
        case 'model':
          shape = 'box'
          color = 'lightgreen'
          break
        case 'reaction_system':
          shape = 'box'
          color = 'lightcoral'
          break
        case 'data_loader':
          shape = 'ellipse'
          color = 'lightyellow'
          break
      }
    }
    // Type-specific formatting for VariableNode
    else if (isVariableNode(node)) {
      switch (node.kind) {
        case 'state':
          shape = 'box'
          color = 'lightgreen'
          break
        case 'parameter':
          shape = 'ellipse'
          color = 'lightblue'
          break
        case 'observed':
          shape = 'box'
          color = 'lightyellow'
          break
        case 'brownian':
          shape = 'diamond'
          color = 'lightgrey'
          break
        case 'species':
          shape = 'ellipse'
          color = 'lightcoral'
          break
      }
    }

    lines.push(
      `  "${nodeKey(node)}" [label="${nodeLabel(node)}", shape=${shape}, fillcolor=${color}, style=filled];`,
    )
  }

  lines.push('')

  // Add edges
  for (const edge of graph.edges) {
    let style = 'solid'
    let color = 'black'
    let label = ''

    // Edge-specific formatting for CouplingEdge
    if (isCouplingEdgeData(edge.data)) {
      switch (edge.data.type) {
        case 'operator_compose':
        case 'couple':
          style = 'solid'
          color = 'blue'
          label = edge.data.label || ''
          break
        case 'variable_map':
          style = 'dashed'
          color = 'green'
          label = formatChemicalSubscripts(edge.data.label || '')
          break
        case 'callback':
          style = 'dotted'
          color = 'orange'
          label = edge.data.label || ''
          break
      }
    }
    // Edge-specific formatting for DependencyEdge
    else if (isDependencyEdgeData(edge.data)) {
      switch (edge.data.relationship) {
        case 'additive':
          style = 'solid'
          color = 'blue'
          label = '+'
          break
        case 'multiplicative':
          style = 'solid'
          color = 'red'
          label = '*'
          break
        case 'rate':
          style = 'dashed'
          color = 'purple'
          label = 'rate'
          break
        case 'stoichiometric':
          style = 'dotted'
          color = 'green'
          label = 'stoich'
          break
      }
    }

    const labelAttr = label ? `, label="${label}"` : ''
    lines.push(
      `  "${edge.source}" -> "${edge.target}" [style=${style}, color=${color}${labelAttr}];`,
    )
  }

  lines.push('}')
  return lines.join('\n')
}

/**
 * Export graph as Mermaid flowchart format for Markdown embedding.
 */
export function toMermaid<N extends object, E>(graph: Graph<N, E>): string {
  const lines: string[] = []

  lines.push('flowchart TD')

  // Add node definitions with shapes
  for (const node of graph.nodes) {
    const id = nodeKey(node)
    const label = nodeLabel(node)

    let shape: string

    // Type-specific shapes for ComponentNode
    if (isComponentNode(node)) {
      switch (node.type) {
        case 'model':
        case 'reaction_system':
          shape = `[${label}]` // Rectangle
          break
        case 'data_loader':
          shape = `((${label}))` // Circle
          break
        default:
          shape = `[${label}]`
      }
    }
    // Type-specific shapes for VariableNode
    else if (isVariableNode(node)) {
      switch (node.kind) {
        case 'state':
        case 'observed':
          shape = `[${label}]` // Rectangle
          break
        case 'parameter':
        case 'species':
          shape = `((${label}))` // Circle
          break
        case 'brownian':
          shape = `{${label}}` // Diamond-like
          break
        default:
          shape = `[${label}]`
      }
    } else {
      shape = `[${label}]`
    }

    lines.push(`  ${id}${shape}`)
  }

  lines.push('')

  // Add edges
  for (const edge of graph.edges) {
    let arrowStyle = '-->'
    let label = ''

    // Edge-specific formatting
    if (isCouplingEdgeData(edge.data)) {
      switch (edge.data.type) {
        case 'variable_map':
          arrowStyle = '-.->'
          label = formatChemicalSubscripts(edge.data.label || '')
          break
        case 'operator_compose':
        case 'couple':
        case 'callback':
          arrowStyle = '-->'
          label = edge.data.label || ''
          break
      }
    } else if (isDependencyEdgeData(edge.data)) {
      switch (edge.data.relationship) {
        case 'additive':
          label = '+'
          break
        case 'multiplicative':
          label = '*'
          break
        case 'rate':
          arrowStyle = '-.->'
          label = 'rate'
          break
        case 'stoichiometric':
          arrowStyle = '-..->'
          label = 'stoich'
          break
      }
    }

    const labelPart = label ? `|${label}|` : ''
    lines.push(`  ${edge.source} ${arrowStyle}${labelPart} ${edge.target}`)
  }

  return lines.join('\n')
}

/**
 * Export graph as JSON adjacency list format for web consumption.
 */
export function toJsonGraph<N extends object, E>(graph: Graph<N, E>): string {
  const jsonGraph = {
    nodes: graph.nodes.map((node) => ({
      // `id` first, then every node property (a ComponentNode's own `id`
      // overwrites with the same value; a VariableNode gains `id === name`).
      id: nodeKey(node),
      ...node,
    })),
    edges: graph.edges.map((edge) => ({
      source: edge.source,
      target: edge.target,
      data: edge.data,
    })),
    adjacency: {} as Record<string, string[]>,
  }

  // Build adjacency list
  for (const node of graph.nodes) {
    const id = nodeKey(node)
    jsonGraph.adjacency[id] = graph.adjacency(id)
  }

  return JSON.stringify(jsonGraph, null, 2)
}
