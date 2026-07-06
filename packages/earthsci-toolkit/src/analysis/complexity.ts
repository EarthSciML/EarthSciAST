/**
 * Expression complexity metrics and analysis
 *
 * This module provides functions to analyze the computational complexity
 * of expressions, including depth, operation counts, and estimated costs.
 */

import type { Expr } from '../types.js';
import type { ComplexityMetrics } from './types.js';
import { freeVariables } from '../expression.js';
import { numericValue } from '../numeric-literal.js';

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
    memoryUsage: 0
  };

  // Analyze the expression recursively
  analyzeExpressionRecursive(expr, metrics, 0);

  // Count unique variables
  metrics.variableCount = freeVariables(expr).size;

  // Calculate final costs
  metrics.computationalCost = calculateComputationalCost(metrics);
  metrics.memoryUsage = calculateMemoryUsage(metrics);

  return metrics;
}

/**
 * Recursively analyze expression structure
 */
function analyzeExpressionRecursive(expr: Expr, metrics: ComplexityMetrics, depth: number) {
  // Update maximum depth
  metrics.depth = Math.max(metrics.depth, depth);

  // Constants: plain numbers AND tagged NumericLiteral leaves ({kind, value})
  // produced by canonical-mode parsing.
  if (numericValue(expr) !== undefined) {
    metrics.constantCount++;
  } else if (typeof expr === 'string') {
    // Variable - will be counted later in freeVariables call
    // Just increment memory usage
    metrics.memoryUsage += 1;
  } else if (typeof expr === 'object' && expr.op) {
    // Operation node
    metrics.operationCount++;
    metrics.operationTypes[expr.op] = (metrics.operationTypes[expr.op] || 0) + 1;

    // Recursively analyze arguments
    for (const arg of expr.args) {
      analyzeExpressionRecursive(arg, metrics, depth + 1);
    }
  }
}

/**
 * Calculate estimated computational cost based on operation types
 */
function calculateComputationalCost(metrics: ComplexityMetrics): number {
  // Cost weights for different operations (relative to addition)
  const operationCosts: Record<string, number> = {
    // Basic arithmetic
    '+': 1,
    '-': 1,
    '*': 2,
    '/': 4,
    '^': 8,
    'sqrt': 6,
    'abs': 1,

    // Transcendental functions (expensive)
    'exp': 20,
    'log': 15,
    'log10': 15,
    'sin': 12,
    'cos': 12,
    'tan': 15,
    'asin': 18,
    'acos': 18,
    'atan': 18,
    'atan2': 20,
    'sinh': 15,
    'cosh': 15,
    'tanh': 15,
    'asinh': 18,
    'acosh': 18,
    'atanh': 18,

    // Logic operations
    '>': 2,
    '<': 2,
    '>=': 2,
    '<=': 2,
    '==': 2,
    '!=': 2,
    'and': 2,
    'or': 2,
    'not': 1,
    'ifelse': 3,

    // Statistical operations
    'min': 3,
    'max': 3,
    'floor': 2,
    'ceil': 2,
    'sign': 1,

    // Rewrite-target / calculus ops (expensive; lowered to stencils before
    // evaluation — see esm-spec §4.2)
    'D': 30,
    'grad': 50,
    'div': 40,
    'laplacian': 80,
    'integral': 50,

    // Event operations
    'Pre': 5,

    // Default for unknown operations
    'default': 10
  };

  let totalCost = 0;

  for (const [operation, count] of Object.entries(metrics.operationTypes)) {
    const cost = operationCosts[operation] || operationCosts.default;
    totalCost += cost * count;
  }

  // Add cost for variable lookups
  totalCost += metrics.variableCount * 1;

  // Add cost for constants (minimal but not zero)
  totalCost += metrics.constantCount * 0.1;

  // Add depth penalty (deeper expressions are more expensive due to stack usage)
  totalCost += metrics.depth * 2;

  // Ensure minimum cost of 1 for any non-trivial expression
  if (totalCost === 0 && (metrics.variableCount > 0 || metrics.constantCount > 0)) {
    totalCost = 1;
  }

  return totalCost;
}

/**
 * Calculate estimated memory usage
 */
function calculateMemoryUsage(metrics: ComplexityMetrics): number {
  // Base memory usage for different components
  let memoryUsage = 0;

  // Each operation node requires memory
  memoryUsage += metrics.operationCount * 3; // op + args array + metadata

  // Each unique variable requires memory for lookup
  memoryUsage += metrics.variableCount * 2;

  // Each constant requires storage
  memoryUsage += metrics.constantCount * 1;

  // Depth affects stack memory usage
  memoryUsage += metrics.depth * 1;

  return memoryUsage;
}

/**
 * Compare complexity of two expressions
 * @param expr1 First expression
 * @param expr2 Second expression
 * @returns Comparison result (-1: expr1 simpler, 0: equal, 1: expr1 more complex)
 */
export function compareComplexity(expr1: Expr, expr2: Expr): number {
  const metrics1 = analyzeComplexity(expr1);
  const metrics2 = analyzeComplexity(expr2);

  // Primary comparison: computational cost
  const costDiff = metrics1.computationalCost - metrics2.computationalCost;
  if (Math.abs(costDiff) > 1) {
    return Math.sign(costDiff);
  }

  // Secondary comparison: operation count
  const opDiff = metrics1.operationCount - metrics2.operationCount;
  if (opDiff !== 0) {
    return Math.sign(opDiff);
  }

  // Tertiary comparison: depth
  const depthDiff = metrics1.depth - metrics2.depth;
  if (depthDiff !== 0) {
    return Math.sign(depthDiff);
  }

  // Quaternary comparison: variable count
  const varDiff = metrics1.variableCount - metrics2.variableCount;
  return Math.sign(varDiff);
}

/**
 * Classify expression complexity level
 * @param expr Expression to classify
 * @returns Complexity level
 */
export function classifyComplexity(expr: Expr): 'trivial' | 'simple' | 'moderate' | 'complex' | 'very_complex' {
  const metrics = analyzeComplexity(expr);

  // Classification based on computational cost
  if (metrics.computationalCost <= 5) {
    return 'trivial';
  } else if (metrics.computationalCost <= 20) {
    return 'simple';
  } else if (metrics.computationalCost <= 50) {
    return 'moderate';
  } else if (metrics.computationalCost <= 150) {
    return 'complex';
  } else {
    return 'very_complex';
  }
}

/**
 * Find the most expensive sub-expressions in an expression
 * @param expr Expression to analyze
 * @param limit Maximum number of results to return
 * @returns Array of expensive sub-expressions with their costs
 */
export function findExpensiveSubexpressions(expr: Expr, limit: number = 5): Array<{
  expression: Expr;
  cost: number;
  path: string[];
}> {
  const results: Array<{ expression: Expr; cost: number; path: string[] }> = [];

  function analyzeRecursive(currentExpr: Expr, path: string[]) {
    const cost = analyzeComplexity(currentExpr).computationalCost;

    // Only include expressions that are worth optimizing
    if (cost > 10) {
      results.push({
        expression: currentExpr,
        cost,
        path: [...path]
      });
    }

    // Recursively analyze sub-expressions
    if (typeof currentExpr === 'object' && currentExpr.op) {
      currentExpr.args.forEach((arg, index) => {
        analyzeRecursive(arg, [...path, `args[${index}]`]);
      });
    }
  }

  analyzeRecursive(expr, []);

  // Sort by cost descending and limit results
  return results
    .sort((a, b) => b.cost - a.cost)
    .slice(0, limit);
}

/**
 * Estimate parallel execution potential
 * @param expr Expression to analyze
 * @returns Parallelization score (0-1, higher means more parallelizable)
 */
export function estimateParallelPotential(expr: Expr): number {
  if (typeof expr !== 'object' || !expr.op) {
    return 0; // Atomic expressions can't be parallelized
  }

  let parallelizableOps = 0;
  let totalOps = 0;

  function analyzeParallelism(currentExpr: Expr) {
    if (typeof currentExpr === 'object' && currentExpr.op) {
      totalOps++;

      // Operations that can be parallelized
      const parallelizableOperations = new Set([
        '+', '*', 'and', 'or', 'min', 'max',
        // Element-wise operations
        'sin', 'cos', 'exp', 'log', 'sqrt', 'abs'
      ]);

      if (parallelizableOperations.has(currentExpr.op) && currentExpr.args.length > 1) {
        parallelizableOps++;
      }

      // Recursively analyze arguments
      for (const arg of currentExpr.args) {
        analyzeParallelism(arg);
      }
    }
  }

  analyzeParallelism(expr);

  return totalOps > 0 ? parallelizableOps / totalOps : 0;
}

/**
 * Detect numerical stability issues in expressions
 * @param expr Expression to analyze
 * @returns Array of potential stability issues
 */
export function detectStabilityIssues(expr: Expr): Array<{
  issue: string;
  severity: 'low' | 'medium' | 'high';
  path: string[];
  suggestion: string;
}> {
  const issues: Array<{
    issue: string;
    severity: 'low' | 'medium' | 'high';
    path: string[];
    suggestion: string;
  }> = [];

  function analyzeStability(currentExpr: Expr, path: string[]) {
    if (typeof currentExpr === 'object' && currentExpr.op) {
      // Check for division operations
      if (currentExpr.op === '/' && currentExpr.args.length === 2) {
        const denominator = currentExpr.args[1];
        const denominatorValue = numericValue(denominator);

        if (denominatorValue !== undefined) {
          // Division by small constants
          if (Math.abs(denominatorValue) < 1e-6) {
            issues.push({
              issue: 'Division by very small constant',
              severity: 'high',
              path: [...path, 'args[1]'],
              suggestion: 'Consider using reciprocal multiplication or check for zero'
            });
          }
        } else if (typeof denominator === 'object') {
          // Division by expressions that could be zero
          issues.push({
            issue: 'Division by expression (potential zero)',
            severity: 'medium',
            path: [...path, 'args[1]'],
            suggestion: 'Add bounds checking or use safe division'
          });
        }
      }

      // Check for logarithms of small numbers
      if (currentExpr.op === 'log' || currentExpr.op === 'log10') {
        const argument = numericValue(currentExpr.args[0]);
        if (argument !== undefined && argument <= 0) {
          issues.push({
            issue: 'Logarithm of non-positive number',
            severity: 'high',
            path: [...path, 'args[0]'],
            suggestion: 'Ensure argument is positive or add bounds checking'
          });
        }
      }

      // Check for square roots of negative numbers
      if (currentExpr.op === 'sqrt') {
        const argument = numericValue(currentExpr.args[0]);
        if (argument !== undefined && argument < 0) {
          issues.push({
            issue: 'Square root of negative number',
            severity: 'high',
            path: [...path, 'args[0]'],
            suggestion: 'Ensure argument is non-negative or use absolute value'
          });
        }
      }

      // Check for very large exponents
      if (currentExpr.op === '^' && currentExpr.args.length === 2) {
        const exponent = numericValue(currentExpr.args[1]);
        if (exponent !== undefined && Math.abs(exponent) > 100) {
          issues.push({
            issue: 'Very large exponent',
            severity: 'medium',
            path: [...path, 'args[1]'],
            suggestion: 'Consider using exp() and log() for large powers'
          });
        }
      }

      // Check for inverse trigonometric functions with out-of-range arguments
      if ((currentExpr.op === 'asin' || currentExpr.op === 'acos') && currentExpr.args.length === 1) {
        const argument = numericValue(currentExpr.args[0]);
        if (argument !== undefined && (argument < -1 || argument > 1)) {
          issues.push({
            issue: 'Inverse trig function with out-of-range argument',
            severity: 'high',
            path: [...path, 'args[0]'],
            suggestion: 'Clamp argument to [-1, 1] range'
          });
        }
      }

      // Recursively analyze arguments
      currentExpr.args.forEach((arg, index) => {
        analyzeStability(arg, [...path, `args[${index}]`]);
      });
    }
  }

  analyzeStability(expr, []);
  return issues;
}