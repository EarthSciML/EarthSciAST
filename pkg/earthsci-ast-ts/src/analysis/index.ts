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
 *
 * It re-exports only the symbols it owns. Graph generation/export
 * (`expressionGraph`, `toDot`, ...), unit analysis, reaction ODE derivation,
 * and model-editing operations live in their own modules and are re-exported
 * from the package root (`../index.ts`), not duplicated here.
 */

// Re-export all analysis-owned types
export type {
  DependencyNode,
  DependencyRelation,
  DependencyGraph,
  VariableKind,
  ComplexityMetrics,
  StabilityIssue,
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
  DEFAULT_MIN_COMPLEXITY,
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
  InvalidDerivativeOrderError,
} from './differentiation.js'

import type { Expr, Model, EsmFile } from '../types.js'
import type {
  ComplexityMetrics,
  CommonSubexpression,
  DependencyGraph as DependencyGraphType,
  DerivativeResult,
  StabilityIssue,
} from './types.js'
import { isExprNode } from '../expression.js'
import { analyzeComplexity, detectStabilityIssues } from './complexity.js'
import { findCommonSubexpressions, DEFAULT_MIN_COMPLEXITY } from './common-subexpressions.js'
import { buildDependencyGraph } from './dependency-graph.js'
import { gradient, partialDerivatives } from './differentiation.js'

/** Combined results returned by {@link analyzeExpression}. */
export interface AnalysisResults {
  complexity?: ComplexityMetrics
  stabilityIssues?: StabilityIssue[]
  commonSubexpressions?: CommonSubexpression[]
  dependencyGraph?: DependencyGraphType
  partialDerivatives?: Map<string, DerivativeResult>
  gradient?: DerivativeResult[]
}

/** Options controlling which analyses {@link analyzeExpression} runs. */
export interface AnalysisOptions {
  /** Compute complexity metrics and stability issues (expression targets only). */
  includeComplexity?: boolean
  /** Identify common subexpressions (expression targets only). */
  includeSubexpressions?: boolean
  /** Build the variable dependency graph. */
  includeDependencies?: boolean
  /** Compute partial derivatives and gradient (expression targets only). */
  includeDerivatives?: boolean
  /** Variables to differentiate with respect to (required for derivatives). */
  variables?: string[]
  /** Minimum complexity threshold for common-subexpression detection. */
  minComplexityThreshold?: number
}

/**
 * Perform comprehensive analysis of an expression or model.
 * @param target Expression, Model, or ESM file to analyze
 * @param options Analysis options
 * @returns Complete analysis results
 */
export function analyzeExpression(
  target: Expr | Model | EsmFile,
  options: AnalysisOptions = {},
): AnalysisResults {
  const {
    includeComplexity = true,
    includeSubexpressions = true,
    includeDependencies = true,
    includeDerivatives = false,
    variables = [],
    minComplexityThreshold = DEFAULT_MIN_COMPLEXITY,
  } = options

  const results: AnalysisResults = {}

  // Complexity, subexpression, and derivative analyses only apply to a single
  // expression node; the guard narrows `target` to ExpressionNode.
  if (isExprNode(target)) {
    if (includeComplexity) {
      results.complexity = analyzeComplexity(target)
      results.stabilityIssues = detectStabilityIssues(target)
    }

    if (includeSubexpressions) {
      results.commonSubexpressions = findCommonSubexpressions(target, minComplexityThreshold)
    }

    if (includeDerivatives && variables.length > 0) {
      results.partialDerivatives = partialDerivatives(target, variables)
      results.gradient = gradient(target, variables)
    }
  }

  if (includeDependencies) {
    results.dependencyGraph = buildDependencyGraph(target)
  }

  return results
}

/**
 * Static namespace wrapping {@link analyzeExpression}.
 * @deprecated Call {@link analyzeExpression} directly.
 */
export const ExpressionAnalyzer = {
  analyze: analyzeExpression,
}
