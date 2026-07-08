/**
 * Advanced Expression Analysis and Manipulation
 *
 * This module provides analysis and manipulation capabilities for
 * mathematical expressions in the ESM format:
 *
 * - Variable dependency graph construction and analysis
 * - Expression complexity metrics
 * - Common subexpression identification
 * - Symbolic differentiation
 * - System graph generation with multiple export formats
 */

// Re-export all types
export type {
  DependencyNode,
  DependencyRelation,
  DependencyGraph,
  ComplexityMetrics,
  CommonSubexpression,
  ExpressionLocation,
  DerivativeResult,
} from './types.js'

// Dependency graph analysis
export {
  buildDependencyGraph,
  findDeadVariables,
  findDependencyChains,
} from './dependency-graph.js'

// Complexity analysis
export {
  analyzeComplexity,
  compareComplexity,
  classifyComplexity,
  findExpensiveSubexpressions,
  estimateParallelPotential,
  detectStabilityIssues,
} from './complexity.js'

// Common subexpression identification
export {
  findCommonSubexpressions,
  findCommonSubexpressionsAcrossExpressions,
  findCommonSubexpressionsInModel,
  findCommonSubexpressionsInEsmFile,
  estimateSavings,
  generateFactoredVariableNames,
  groupSubexpressionsByType,
} from './common-subexpressions.js'

// Symbolic differentiation
export {
  differentiate,
  partialDerivatives,
  gradient,
  higherOrderDerivative,
  isDifferentiable,
  findCriticalPoints,
  NonDifferentiableExpressionError,
} from './differentiation.js'

// Import graph functionality from existing modules
export {
  componentGraph,
  expressionGraph,
  toDot,
  toMermaid,
  toJsonGraph,
  componentExists,
  getComponentType,
} from '../graph.js'

// Import unit analysis functionality
export {
  parseUnit,
  checkDimensions,
  validateUnits,
  type UnitResult,
  type UnitWarning,
} from '../units.js'

// Import ODE derivation and stoichiometry functionality
export { deriveODEs, stoichiometricMatrix, substrateMatrix, productMatrix } from '../reactions.js'

// Import programmatic model editing operations
export {
  addVariable,
  removeVariable,
  renameVariable,
  addEquation,
  removeEquation,
  substituteInEquations,
  addReaction,
  removeReaction,
  addSpecies,
  removeSpecies,
  addContinuousEvent,
  addDiscreteEvent,
  removeEvent,
  addCoupling,
  removeCoupling,
  compose,
  mapVariable,
  merge,
  extract,
  VariableInUseError,
  EntityNotFoundError,
} from '../edit.js'

import type { Expr, Model, EsmFile } from '../types.js'
import type {
  ComplexityMetrics,
  CommonSubexpression,
  DependencyGraph as DependencyGraphType,
  DerivativeResult,
} from './types.js'
import { analyzeComplexity, detectStabilityIssues } from './complexity.js'
import { findCommonSubexpressions } from './common-subexpressions.js'
import { buildDependencyGraph } from './dependency-graph.js'
import { gradient, partialDerivatives } from './differentiation.js'

/** Combined results returned by {@link ExpressionAnalyzer.analyze}. */
export interface AnalysisResults {
  complexity?: ComplexityMetrics
  stabilityIssues?: ReturnType<typeof detectStabilityIssues>
  commonSubexpressions?: CommonSubexpression[]
  dependencyGraph?: DependencyGraphType
  partialDerivatives?: Map<string, DerivativeResult>
  gradient?: DerivativeResult[]
}

/**
 * Main analysis class providing a unified interface to all analysis capabilities
 */
export class ExpressionAnalyzer {
  /**
   * Perform comprehensive analysis of an expression or model
   * @param target Expression, Model, or ESM file to analyze
   * @param options Analysis options
   * @returns Complete analysis results
   */
  static analyze(
    target: Expr | Model | EsmFile,
    options: {
      includeComplexity?: boolean
      includeSubexpressions?: boolean
      includeDependencies?: boolean
      includeDerivatives?: boolean
      variables?: string[]
      minComplexityThreshold?: number
    } = {},
  ): AnalysisResults {
    const {
      includeComplexity = true,
      includeSubexpressions = true,
      includeDependencies = true,
      includeDerivatives = false,
      variables = [],
      minComplexityThreshold = 5,
    } = options

    const results: AnalysisResults = {}
    const isExpressionNode = typeof target === 'object' && target !== null && 'op' in target

    if (includeComplexity && isExpressionNode) {
      results.complexity = analyzeComplexity(target as Expr)
      results.stabilityIssues = detectStabilityIssues(target as Expr)
    }

    if (includeSubexpressions && isExpressionNode) {
      results.commonSubexpressions = findCommonSubexpressions(
        target as Expr,
        minComplexityThreshold,
      )
    }

    if (includeDependencies) {
      results.dependencyGraph = buildDependencyGraph(target)
    }

    if (includeDerivatives && isExpressionNode && variables.length > 0) {
      results.partialDerivatives = partialDerivatives(target as Expr, variables)
      results.gradient = gradient(target as Expr, variables)
    }

    return results
  }
}
