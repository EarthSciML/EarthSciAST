/**
 * Expression complexity metrics and analysis
 *
 * This module provides functions to analyze the computational complexity
 * of expressions, including depth, operation counts, and estimated costs.
 */

import type { Expr } from '../types.js'
import type { ComplexityMetrics, StabilityIssue } from './types.js'
import { freeVariables, isExprNode, forEachChild } from '../expression.js'
import { numericValue } from '../numeric-literal.js'
import { opCost } from '../op-registry.js'

// --- Computational-cost weights (calculateComputationalCost) ----------------
/** Cost charged per unique variable lookup. */
const VARIABLE_LOOKUP_COST = 1
/** Cost charged per constant literal (small but non-zero). */
const CONSTANT_COST = 0.1
/** Cost charged per unit of expression depth (stack pressure). */
const DEPTH_COST = 2

// --- Memory-usage weights (calculateMemoryUsage) ----------------------------
/** Memory charged per operation node (op + args array + metadata). */
const OP_NODE_MEMORY = 3
/** Memory charged per unique variable (lookup slot). */
const VARIABLE_MEMORY = 2
/** Memory charged per constant literal. */
const CONSTANT_MEMORY = 1
/** Memory charged per unit of expression depth (stack frame). */
const DEPTH_MEMORY = 1

// --- classifyComplexity level boundaries (inclusive upper bounds) -----------
const COMPLEXITY_TRIVIAL_MAX = 5
const COMPLEXITY_SIMPLE_MAX = 20
const COMPLEXITY_MODERATE_MAX = 50
const COMPLEXITY_COMPLEX_MAX = 150

/** Minimum cost for a subexpression to be reported by findExpensiveSubexpressions. */
const EXPENSIVE_COST_THRESHOLD = 10

// --- detectStabilityIssues thresholds ---------------------------------------
/** A constant denominator with magnitude below this is flagged as unstable. */
const SMALL_DENOMINATOR = 1e-6
/** A constant exponent with magnitude above this is flagged as large. */
const LARGE_EXPONENT = 100

/**
 * Operations whose multiple arguments can be evaluated independently (and thus
 * in parallel). Hoisted to module scope so it is built once, not per node.
 */
const PARALLELIZABLE_OPS: ReadonlySet<string> = new Set([
  '+',
  '*',
  'and',
  'or',
  'min',
  'max',
  // Element-wise operations
  'sin',
  'cos',
  'exp',
  'log',
  'sqrt',
  'abs',
])

/**
 * Analyze the complexity of an expression
 * @param expr Expression to analyze
 * @returns Complexity metrics
 */
export function analyzeComplexity(expr: Expr): ComplexityMetrics {
  const metrics: ComplexityMetrics = {
    depth: 0,
    operationCount: 0,
    variableCount: 0,
    constantCount: 0,
    operationTypes: {},
    computationalCost: 0,
    memoryUsage: 0,
  }

  // Analyze the expression recursively
  analyzeExpressionRecursive(expr, metrics, 0)

  // Count unique variables
  metrics.variableCount = freeVariables(expr).size

  // Calculate final costs
  metrics.computationalCost = calculateComputationalCost(metrics)
  metrics.memoryUsage = calculateMemoryUsage(metrics)

  return metrics
}

/**
 * Recursively analyze expression structure
 */
function analyzeExpressionRecursive(expr: Expr, metrics: ComplexityMetrics, depth: number) {
  // Update maximum depth
  metrics.depth = Math.max(metrics.depth, depth)

  // Constants: plain numbers AND tagged NumericLiteral leaves ({kind, value})
  // produced by canonical-mode parsing.
  if (numericValue(expr) !== undefined) {
    metrics.constantCount++
  } else if (isExprNode(expr)) {
    // Operation node
    metrics.operationCount++
    metrics.operationTypes[expr.op] = (metrics.operationTypes[expr.op] || 0) + 1

    // Recursively analyze every child (args, aggregate bodies, ...).
    forEachChild(expr, (child) => analyzeExpressionRecursive(child, metrics, depth + 1))
  }
  // Variable-reference strings contribute no operation/constant here; unique
  // variables are counted via freeVariables in analyzeComplexity.
}

/**
 * Calculate estimated computational cost based on operation types. Per-op
 * cost weights come from the central op registry (op-registry.ts).
 */
function calculateComputationalCost(metrics: ComplexityMetrics): number {
  let totalCost = 0

  for (const [operation, count] of Object.entries(metrics.operationTypes)) {
    totalCost += opCost(operation) * count
  }

  // Add cost for variable lookups
  totalCost += metrics.variableCount * VARIABLE_LOOKUP_COST

  // Add cost for constants (minimal but not zero)
  totalCost += metrics.constantCount * CONSTANT_COST

  // Add depth penalty (deeper expressions are more expensive due to stack usage)
  totalCost += metrics.depth * DEPTH_COST

  return totalCost
}

/**
 * Calculate estimated memory usage
 */
function calculateMemoryUsage(metrics: ComplexityMetrics): number {
  // Base memory usage for different components
  let memoryUsage = 0

  // Each operation node requires memory
  memoryUsage += metrics.operationCount * OP_NODE_MEMORY

  // Each unique variable requires memory for lookup
  memoryUsage += metrics.variableCount * VARIABLE_MEMORY

  // Each constant requires storage
  memoryUsage += metrics.constantCount * CONSTANT_MEMORY

  // Depth affects stack memory usage
  memoryUsage += metrics.depth * DEPTH_MEMORY

  return memoryUsage
}

/**
 * Compare complexity of two expressions
 * @param expr1 First expression
 * @param expr2 Second expression
 * @returns Comparison result (-1: expr1 simpler, 0: equal, 1: expr1 more complex)
 */
export function compareComplexity(expr1: Expr, expr2: Expr): number {
  const metrics1 = analyzeComplexity(expr1)
  const metrics2 = analyzeComplexity(expr2)

  // Primary comparison: computational cost
  const costDiff = metrics1.computationalCost - metrics2.computationalCost
  if (Math.abs(costDiff) > 1) {
    return Math.sign(costDiff)
  }

  // Secondary comparison: operation count
  const opDiff = metrics1.operationCount - metrics2.operationCount
  if (opDiff !== 0) {
    return Math.sign(opDiff)
  }

  // Tertiary comparison: depth
  const depthDiff = metrics1.depth - metrics2.depth
  if (depthDiff !== 0) {
    return Math.sign(depthDiff)
  }

  // Quaternary comparison: variable count
  const varDiff = metrics1.variableCount - metrics2.variableCount
  return Math.sign(varDiff)
}

/**
 * Classify expression complexity level
 * @param expr Expression to classify
 * @returns Complexity level
 */
export function classifyComplexity(
  expr: Expr,
): 'trivial' | 'simple' | 'moderate' | 'complex' | 'very_complex' {
  const metrics = analyzeComplexity(expr)

  // Classification based on computational cost
  if (metrics.computationalCost <= COMPLEXITY_TRIVIAL_MAX) {
    return 'trivial'
  } else if (metrics.computationalCost <= COMPLEXITY_SIMPLE_MAX) {
    return 'simple'
  } else if (metrics.computationalCost <= COMPLEXITY_MODERATE_MAX) {
    return 'moderate'
  } else if (metrics.computationalCost <= COMPLEXITY_COMPLEX_MAX) {
    return 'complex'
  } else {
    return 'very_complex'
  }
}

/**
 * Find the most expensive sub-expressions in an expression
 * @param expr Expression to analyze
 * @param limit Maximum number of results to return
 * @returns Array of expensive sub-expressions with their costs
 */
export function findExpensiveSubexpressions(
  expr: Expr,
  limit: number = 5,
): Array<{
  expression: Expr
  cost: number
  path: string[]
}> {
  const results: Array<{ expression: Expr; cost: number; path: string[] }> = []

  function analyzeRecursive(currentExpr: Expr, path: string[]) {
    const cost = analyzeComplexity(currentExpr).computationalCost

    // Only include expressions that are worth optimizing
    if (cost > EXPENSIVE_COST_THRESHOLD) {
      results.push({
        expression: currentExpr,
        cost,
        path: [...path],
      })
    }

    // Recursively analyze sub-expressions
    if (isExprNode(currentExpr)) {
      forEachChild(currentExpr, (child, key, index) => {
        const segment = index !== undefined ? `${key}[${index}]` : key
        analyzeRecursive(child, [...path, segment])
      })
    }
  }

  analyzeRecursive(expr, [])

  // Sort by cost descending and limit results
  return results.sort((a, b) => b.cost - a.cost).slice(0, limit)
}

/**
 * Estimate parallel execution potential
 * @param expr Expression to analyze
 * @returns Parallelization score (0-1, higher means more parallelizable)
 */
export function estimateParallelPotential(expr: Expr): number {
  if (!isExprNode(expr)) {
    return 0 // Atomic expressions can't be parallelized
  }

  let parallelizableOps = 0
  let totalOps = 0

  function analyzeParallelism(currentExpr: Expr) {
    if (isExprNode(currentExpr)) {
      totalOps++

      if (PARALLELIZABLE_OPS.has(currentExpr.op) && currentExpr.args.length > 1) {
        parallelizableOps++
      }

      // Recursively analyze children
      forEachChild(currentExpr, (child) => analyzeParallelism(child))
    }
  }

  analyzeParallelism(expr)

  return totalOps > 0 ? parallelizableOps / totalOps : 0
}

/**
 * Detect numerical stability issues in expressions
 * @param expr Expression to analyze
 * @returns Array of potential stability issues
 */
export function detectStabilityIssues(expr: Expr): StabilityIssue[] {
  const issues: StabilityIssue[] = []

  function analyzeStability(currentExpr: Expr, path: string[]) {
    if (isExprNode(currentExpr)) {
      // Check for division operations
      if (currentExpr.op === '/' && currentExpr.args.length === 2) {
        const denominator = currentExpr.args[1]
        const denominatorValue = numericValue(denominator)

        if (denominatorValue !== undefined) {
          // Division by small constants
          if (Math.abs(denominatorValue) < SMALL_DENOMINATOR) {
            issues.push({
              issue: 'Division by very small constant',
              severity: 'high',
              path: [...path, 'args[1]'],
              suggestion: 'Consider using reciprocal multiplication or check for zero',
            })
          }
        } else if (typeof denominator === 'object') {
          // Division by expressions that could be zero
          issues.push({
            issue: 'Division by expression (potential zero)',
            severity: 'medium',
            path: [...path, 'args[1]'],
            suggestion: 'Add bounds checking or use safe division',
          })
        }
      }

      // Check for logarithms of small numbers
      if (currentExpr.op === 'log' || currentExpr.op === 'log10') {
        const argument = numericValue(currentExpr.args[0])
        if (argument !== undefined && argument <= 0) {
          issues.push({
            issue: 'Logarithm of non-positive number',
            severity: 'high',
            path: [...path, 'args[0]'],
            suggestion: 'Ensure argument is positive or add bounds checking',
          })
        }
      }

      // Check for square roots of negative numbers
      if (currentExpr.op === 'sqrt') {
        const argument = numericValue(currentExpr.args[0])
        if (argument !== undefined && argument < 0) {
          issues.push({
            issue: 'Square root of negative number',
            severity: 'high',
            path: [...path, 'args[0]'],
            suggestion: 'Ensure argument is non-negative or use absolute value',
          })
        }
      }

      // Check for very large exponents
      if (currentExpr.op === '^' && currentExpr.args.length === 2) {
        const exponent = numericValue(currentExpr.args[1])
        if (exponent !== undefined && Math.abs(exponent) > LARGE_EXPONENT) {
          issues.push({
            issue: 'Very large exponent',
            severity: 'medium',
            path: [...path, 'args[1]'],
            suggestion: 'Consider using exp() and log() for large powers',
          })
        }
      }

      // Check for inverse trigonometric functions with out-of-range arguments
      if (
        (currentExpr.op === 'asin' || currentExpr.op === 'acos') &&
        currentExpr.args.length === 1
      ) {
        const argument = numericValue(currentExpr.args[0])
        if (argument !== undefined && (argument < -1 || argument > 1)) {
          issues.push({
            issue: 'Inverse trig function with out-of-range argument',
            severity: 'high',
            path: [...path, 'args[0]'],
            suggestion: 'Clamp argument to [-1, 1] range',
          })
        }
      }

      // Recursively analyze children
      forEachChild(currentExpr, (child, key, index) => {
        const segment = index !== undefined ? `${key}[${index}]` : key
        analyzeStability(child, [...path, segment])
      })
    }
  }

  analyzeStability(expr, [])
  return issues
}
