/**
 * Advanced expression analysis and manipulation types
 *
 * This module defines the core types for advanced expression analysis,
 * including dependency graphs, complexity metrics, and manipulation utilities.
 */

import type { Expr } from '../types.js'
import type { Graph, VariableNode } from '../graph.js'

/**
 * The kind of a variable node. Derived from graph.ts's {@link VariableNode} so
 * the union lives in exactly one place (analysis and the parent graph module
 * must agree on the vocabulary of variable kinds).
 */
export type VariableKind = VariableNode['kind']

/**
 * Node representing a variable in a dependency graph.
 *
 * Overlaps graph.ts's {@link VariableNode} (both carry `name`/`kind`/`units`/
 * `system`); this analysis variant additionally tracks the defining expression
 * ({@link definition}) and the topological {@link depth}. The two families are
 * kept separate because they are produced by different builders
 * (`analysis/buildDependencyGraph` vs graph.ts's `expressionGraph`) with
 * different edge payloads; the shared `kind` vocabulary is unified via
 * {@link VariableKind}.
 */
export interface DependencyNode {
  /** Variable name */
  name: string
  /** Type of variable (state, parameter, observed, brownian, discrete, species) */
  kind: VariableKind
  /** System/model this variable belongs to */
  system: string
  /** Units if specified */
  units?: string
  /** Definition expression if available */
  definition?: Expr
  /** Nesting level in the dependency graph */
  depth: number
}

/**
 * Edge representing a dependency relationship between variables.
 *
 * Analysis-local counterpart of graph.ts's {@link DependencyEdge}; the two use
 * disjoint edge vocabularies (`type` here vs `relationship`/`equation_index`
 * there) because they are built by different graph constructors.
 */
export interface DependencyRelation {
  /** Source variable */
  source: string
  /** Target variable */
  target: string
  /** Type of dependency */
  type: 'direct' | 'circular' | 'parameter_dependency' | 'definition_dependency'
  /** Expression that creates this dependency */
  expression?: Expr
}

/** Graph representing variable dependencies */
export interface DependencyGraph extends Graph<DependencyNode, DependencyRelation> {
  /** Check for circular dependencies */
  hasCircularDependencies(): boolean
  /**
   * Circular-dependency cycles. Each entry is one back-edge cycle found by a
   * DFS over the directed edges; distinct cycles may share nodes (these are
   * NOT strongly-connected components).
   */
  getCycles(): DependencyNode[][]
  /**
   * @deprecated Misnomer — this does NOT compute strongly-connected
   * components; it returns the raw DFS cycles from {@link getCycles}. Use
   * {@link getCycles} instead.
   */
  getStronglyConnectedComponents(): DependencyNode[][]
  /** Topological sort of dependencies */
  topologicalSort(): DependencyNode[]
}

/** Complexity metrics for an expression */
export interface ComplexityMetrics {
  /** Total depth of the expression tree */
  depth: number
  /** Total number of operations */
  operationCount: number
  /** Number of unique variables */
  variableCount: number
  /** Number of constants */
  constantCount: number
  /** Distribution of operation types */
  operationTypes: Record<string, number>
  /** Estimated computational cost (arbitrary units) */
  computationalCost: number
  /** Memory usage estimate (arbitrary units) */
  memoryUsage: number
}

/** A single numerical-stability finding produced by `detectStabilityIssues`. */
export interface StabilityIssue {
  /** Human-readable description of the issue */
  issue: string
  /** Severity of the issue */
  severity: 'low' | 'medium' | 'high'
  /** Path to the offending subexpression (e.g. `['args[1]']`) */
  path: string[]
  /** Suggested remediation */
  suggestion: string
}

/** Common subexpression identification result */
export interface CommonSubexpression {
  /** The common subexpression */
  expression: Expr
  /** Locations where this subexpression appears */
  locations: ExpressionLocation[]
  /** Number of occurrences */
  count: number
  /** Estimated cost savings from factoring out */
  savings: number
}

/** Location of an expression within a larger structure */
export interface ExpressionLocation {
  /** Path to the expression (e.g. `['root', 'args[0]', 'args[1]']`) */
  path: string[]
  /** Human-readable description */
  description: string
  /** Parent expression context */
  context?: Expr
}

/** Result of symbolic differentiation */
export interface DerivativeResult {
  /** The derivative expression */
  derivative: Expr
  /** Variable with respect to which we differentiated */
  variable: string
  /** Simplified form if different from derivative */
  simplified?: Expr
  /**
   * For {@link higherOrderDerivative}: one entry per differentiation order,
   * recording the expression at that order (`expression`) and its derivative
   * (`derivative`, i.e. the expression at the next order). These are the
   * successive derivative steps, NOT chain-rule multiplicative factors.
   */
  chainComponents?: Array<{
    expression: Expr
    derivative: Expr
  }>
}
