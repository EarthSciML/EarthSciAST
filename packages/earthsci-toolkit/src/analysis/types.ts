/**
 * Advanced expression analysis and manipulation types
 *
 * This module defines the core types for advanced expression analysis,
 * including dependency graphs, complexity metrics, and manipulation utilities.
 */

import type { Expr } from '../types.js';
import type { Graph } from '../graph.js';

/** Node representing a variable in a dependency graph */
export interface DependencyNode {
  /** Variable name */
  name: string;
  /** Type of variable (state, parameter, observed, brownian, species) */
  kind: 'state' | 'parameter' | 'observed' | 'brownian' | 'species';
  /** System/model this variable belongs to */
  system: string;
  /** Units if specified */
  units?: string;
  /** Definition expression if available */
  definition?: Expr;
  /** Nesting level in the dependency graph */
  depth: number;
}

/** Edge representing a dependency relationship between variables */
export interface DependencyRelation {
  /** Source variable */
  source: string;
  /** Target variable */
  target: string;
  /** Type of dependency */
  type: 'direct' | 'indirect' | 'circular' | 'parameter_dependency' | 'definition_dependency';
  /** Strength/weight of dependency (0-1) */
  weight: number;
  /** Expression that creates this dependency */
  expression?: Expr;
}

/** Graph representing variable dependencies */
export interface DependencyGraph extends Graph<DependencyNode, DependencyRelation> {
  /** Check for circular dependencies */
  hasCircularDependencies(): boolean;
  /** Get strongly connected components */
  getStronglyConnectedComponents(): DependencyNode[][];
  /** Topological sort of dependencies */
  topologicalSort(): DependencyNode[];
}

/** Complexity metrics for an expression */
export interface ComplexityMetrics {
  /** Total depth of the expression tree */
  depth: number;
  /** Total number of operations */
  operationCount: number;
  /** Number of unique variables */
  variableCount: number;
  /** Number of constants */
  constantCount: number;
  /** Distribution of operation types */
  operationTypes: Record<string, number>;
  /** Estimated computational cost (arbitrary units) */
  computationalCost: number;
  /** Memory usage estimate (arbitrary units) */
  memoryUsage: number;
}

/** Common subexpression identification result */
export interface CommonSubexpression {
  /** The common subexpression */
  expression: Expr;
  /** Locations where this subexpression appears */
  locations: ExpressionLocation[];
  /** Number of occurrences */
  count: number;
  /** Estimated cost savings from factoring out */
  savings: number;
}

/** Location of an expression within a larger structure */
export interface ExpressionLocation {
  /** Path to the expression (e.g., ['models', 'Transport', 'equations', 0, 'rhs']) */
  path: string[];
  /** Human-readable description */
  description: string;
  /** Parent expression context */
  context?: Expr;
}

/** Result of symbolic differentiation */
export interface DerivativeResult {
  /** The derivative expression */
  derivative: Expr;
  /** Variable with respect to which we differentiated */
  variable: string;
  /** Simplified form if different from derivative */
  simplified?: Expr;
  /** Chain rule components if applicable */
  chainComponents?: Array<{
    expression: Expr;
    derivative: Expr;
  }>;
}

