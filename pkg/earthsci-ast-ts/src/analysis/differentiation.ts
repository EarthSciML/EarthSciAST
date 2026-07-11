/**
 * Symbolic differentiation capabilities
 *
 * This module provides functions to compute symbolic derivatives
 * of expressions with respect to variables, supporting the chain rule
 * and various mathematical functions.
 */

import type { Expr, ExpressionNode } from '../types.js'
import type { DerivativeResult } from './types.js'
import { simplify, freeVariables, isExprNode, deepEqualExpr } from '../expression.js'
import { numericValue } from '../numeric-literal.js'

/**
 * Thrown when {@link differentiate} encounters an operator with no
 * differentiation rule, or a known operator applied with an arity its rule
 * does not cover. Callers that need a boolean answer should use
 * {@link isDifferentiable}.
 */
export class NonDifferentiableExpressionError extends Error {
  constructor(
    public readonly op: string,
    public readonly variable: string,
  ) {
    super(`No differentiation rule for operator '${op}' (d/d${variable})`)
    this.name = 'NonDifferentiableExpressionError'
  }
}

/** Thrown by {@link higherOrderDerivative} when `order` is not positive. */
export class InvalidDerivativeOrderError extends Error {
  constructor(public readonly order: number) {
    super(`Derivative order must be positive (got ${order})`)
    this.name = 'InvalidDerivativeOrderError'
  }
}

/**
 * Differentiation rules for single-argument elementary functions, keyed by
 * operator. Each rule receives the argument `u`, its derivative `du`, and the
 * original `node` (so e.g. `exp` can reuse `e^u` verbatim), and returns the
 * derivative expression. Arity is validated by the caller before dispatch, so
 * these bodies may assume exactly one argument.
 */
type UnaryDerivativeRule = (u: Expr, du: Expr, node: ExpressionNode) => Expr

const UNARY_DERIVATIVE_RULES: Record<string, UnaryDerivativeRule> = {
  // d/dx (e^u) = e^u * u'
  exp: (_u, du, node) => ({ op: '*', args: [node, du] }),
  // d/dx (ln(u)) = u'/u
  log: (u, du) => ({ op: '/', args: [du, u] }),
  // d/dx (log₁₀(u)) = u'/(u * ln(10))
  log10: (u, du) => ({ op: '/', args: [du, { op: '*', args: [u, Math.LN10] }] }),
  // d/dx (sin(u)) = cos(u) * u'
  sin: (u, du) => ({ op: '*', args: [{ op: 'cos', args: [u] }, du] }),
  // d/dx (cos(u)) = -sin(u) * u'
  cos: (u, du) => ({ op: '*', args: [{ op: '-', args: [{ op: 'sin', args: [u] }] }, du] }),
  // d/dx (tan(u)) = (1/cos²(u)) * u'
  tan: (u, du) => ({
    op: '*',
    args: [{ op: '/', args: [1, { op: '^', args: [{ op: 'cos', args: [u] }, 2] }] }, du],
  }),
  // d/dx (arcsin(u)) = u'/√(1-u²)
  asin: (u, du) => ({
    op: '/',
    args: [du, { op: 'sqrt', args: [{ op: '-', args: [1, { op: '^', args: [u, 2] }] }] }],
  }),
  // d/dx (arccos(u)) = -u'/√(1-u²)
  acos: (u, du) => ({
    op: '/',
    args: [
      { op: '-', args: [du] },
      { op: 'sqrt', args: [{ op: '-', args: [1, { op: '^', args: [u, 2] }] }] },
    ],
  }),
  // d/dx (arctan(u)) = u'/(1+u²)
  atan: (u, du) => ({ op: '/', args: [du, { op: '+', args: [1, { op: '^', args: [u, 2] }] }] }),
  // d/dx (sinh(u)) = cosh(u) * u'
  sinh: (u, du) => ({ op: '*', args: [{ op: 'cosh', args: [u] }, du] }),
  // d/dx (cosh(u)) = sinh(u) * u'
  cosh: (u, du) => ({ op: '*', args: [{ op: 'sinh', args: [u] }, du] }),
  // d/dx (tanh(u)) = (1/cosh²(u)) * u'
  tanh: (u, du) => ({
    op: '*',
    args: [{ op: '/', args: [1, { op: '^', args: [{ op: 'cosh', args: [u] }, 2] }] }, du],
  }),
  // d/dx (asinh(u)) = u'/√(u²+1)
  asinh: (u, du) => ({
    op: '/',
    args: [du, { op: 'sqrt', args: [{ op: '+', args: [{ op: '^', args: [u, 2] }, 1] }] }],
  }),
  // d/dx (acosh(u)) = u'/√(u²-1)
  acosh: (u, du) => ({
    op: '/',
    args: [du, { op: 'sqrt', args: [{ op: '-', args: [{ op: '^', args: [u, 2] }, 1] }] }],
  }),
  // d/dx (atanh(u)) = u'/(1-u²)
  atanh: (u, du) => ({ op: '/', args: [du, { op: '-', args: [1, { op: '^', args: [u, 2] }] }] }),
  // d/dx (√u) = u'/(2√u)
  sqrt: (u, du) => ({ op: '/', args: [du, { op: '*', args: [2, { op: 'sqrt', args: [u] }] }] }),
  // d/dx (|u|) = u' * sign(u)
  abs: (u, du) => ({ op: '*', args: [du, { op: 'sign', args: [u] }] }),
}

/**
 * Compute the symbolic derivative of an expression with respect to a variable
 * @param expr Expression to differentiate
 * @param variable Variable with respect to which to differentiate
 * @returns Derivative result with simplified form
 */
export function differentiate(expr: Expr, variable: string): DerivativeResult {
  const derivative = computeDerivative(expr, variable)
  const simplified = simplify(derivative)

  return {
    derivative,
    variable,
    simplified: deepEqualExpr(derivative, simplified) ? undefined : simplified,
  }
}

/**
 * Compute partial derivatives with respect to multiple variables
 * @param expr Expression to differentiate
 * @param variables Array of variables to differentiate with respect to
 * @returns Map of variable names to their derivative results
 */
export function partialDerivatives(expr: Expr, variables: string[]): Map<string, DerivativeResult> {
  const results = new Map<string, DerivativeResult>()

  for (const variable of variables) {
    results.set(variable, differentiate(expr, variable))
  }

  return results
}

/**
 * Compute the gradient (all first partial derivatives)
 * @param expr Expression to differentiate
 * @param variables Array of variables (if not provided, will extract from expression)
 * @returns Gradient as array of derivatives
 */
export function gradient(expr: Expr, variables?: string[]): DerivativeResult[] {
  if (!variables) {
    // Extract variables from the expression
    variables = Array.from(freeVariables(expr))
  }

  return variables.map((variable) => differentiate(expr, variable))
}

/**
 * Core differentiation logic using symbolic rules
 */
function computeDerivative(expr: Expr, variable: string): Expr {
  // Base cases. numericValue covers plain numbers AND tagged NumericLiteral
  // leaves from canonical-mode parsing.
  if (numericValue(expr) !== undefined) {
    // d/dx (constant) = 0
    return 0
  }

  if (typeof expr === 'string') {
    // d/dx (x) = 1, d/dx (y) = 0 where y ≠ x
    return expr === variable ? 1 : 0
  }

  if (isExprNode(expr)) {
    const args = expr.args

    // Single-argument elementary functions share the rule table above. An
    // arity mismatch (e.g. sin with two arguments) is non-differentiable — it
    // must throw, NOT fabricate 0, so isDifferentiable() reports it honestly.
    const unaryRule = UNARY_DERIVATIVE_RULES[expr.op]
    if (unaryRule) {
      if (args.length !== 1) {
        throw new NonDifferentiableExpressionError(expr.op, variable)
      }
      const u = args[0]
      return unaryRule(u, computeDerivative(u, variable), expr)
    }

    switch (expr.op) {
      // Basic arithmetic
      case '+':
        // d/dx (u + v) = du/dx + dv/dx
        return {
          op: '+',
          args: args.map((arg) => computeDerivative(arg, variable)),
        }

      case '-':
        if (args.length === 1) {
          // d/dx (-u) = -du/dx
          return {
            op: '-',
            args: [computeDerivative(args[0], variable)],
          }
        } else {
          // d/dx (u - v) = du/dx - dv/dx
          return {
            op: '-',
            args: args.map((arg) => computeDerivative(arg, variable)),
          }
        }

      case '*':
        // Product rule: d/dx (uv) = u'v + uv'
        // For multiple factors: d/dx (uvw) = u'vw + uv'w + uvw'
        if (args.length === 2) {
          const [u, v] = args
          const du = computeDerivative(u, variable)
          const dv = computeDerivative(v, variable)

          return {
            op: '+',
            args: [
              { op: '*', args: [du, v] },
              { op: '*', args: [u, dv] },
            ],
          }
        } else if (args.length > 2) {
          // Use product rule recursively
          const first = args[0]
          const rest = { op: '*', args: args.slice(1) } as Expr
          return computeDerivative({ op: '*', args: [first, rest] }, variable)
        }
        throw new NonDifferentiableExpressionError(expr.op, variable)

      case '/':
        // Quotient rule: d/dx (u/v) = (u'v - uv')/v²
        if (args.length === 2) {
          const [u, v] = args
          const du = computeDerivative(u, variable)
          const dv = computeDerivative(v, variable)

          return {
            op: '/',
            args: [
              {
                op: '-',
                args: [
                  { op: '*', args: [du, v] },
                  { op: '*', args: [u, dv] },
                ],
              },
              { op: '^', args: [v, 2] },
            ],
          }
        }
        throw new NonDifferentiableExpressionError(expr.op, variable)

      case '^':
        // Power rule: d/dx (u^n) = n * u^(n-1) * u'
        if (args.length === 2) {
          const [base, exponent] = args

          // Special case: constant exponent (plain number or tagged literal)
          const exponentValue = numericValue(exponent)
          if (exponentValue !== undefined) {
            if (exponentValue === 0) return 0
            if (exponentValue === 1) return computeDerivative(base, variable)

            const du = computeDerivative(base, variable)
            return {
              op: '*',
              args: [exponentValue, { op: '^', args: [base, exponentValue - 1] }, du],
            }
          }

          // General case: d/dx (u^v) = u^v * (v' * ln(u) + v * u'/u)
          const du = computeDerivative(base, variable)
          const dv = computeDerivative(exponent, variable)

          return {
            op: '*',
            args: [
              expr, // u^v
              {
                op: '+',
                args: [
                  { op: '*', args: [dv, { op: 'log', args: [base] }] },
                  { op: '*', args: [exponent, { op: '/', args: [du, base] }] },
                ],
              },
            ],
          }
        }
        throw new NonDifferentiableExpressionError(expr.op, variable)

      // Comparison and logical operators have no well-defined derivative in the
      // usual sense; treat as locally constant (0).
      case '>':
      case '<':
      case '>=':
      case '<=':
      case '==':
      case '!=':
      case 'and':
      case 'or':
      case 'not':
        return 0

      case 'ifelse':
        // d/dx (ifelse(cond, a, b)) = ifelse(cond, da/dx, db/dx)
        // Note: This assumes the condition doesn't depend on x
        if (args.length === 3) {
          const [condition, trueBranch, falseBranch] = args
          return {
            op: 'ifelse',
            args: [
              condition,
              computeDerivative(trueBranch, variable),
              computeDerivative(falseBranch, variable),
            ],
          }
        }
        throw new NonDifferentiableExpressionError(expr.op, variable)

      case 'min':
      case 'max':
        // These functions are not differentiable at the boundary, but we can provide
        // a reasonable approximation using the ifelse construct
        if (args.length === 2) {
          const [u, v] = args
          const du = computeDerivative(u, variable)
          const dv = computeDerivative(v, variable)

          const condition =
            expr.op === 'min' ? { op: '<', args: [u, v] } : { op: '>', args: [u, v] }

          return {
            op: 'ifelse',
            args: [condition, du, dv],
          }
        }
        throw new NonDifferentiableExpressionError(expr.op, variable)

      default:
        // No differentiation rule for this operator — throw so
        // isDifferentiable() gives a meaningful answer instead of a
        // placeholder pseudo-op that no evaluator understands.
        throw new NonDifferentiableExpressionError(expr.op, variable)
    }
  }

  // Fallback: return 0 for anything we can't differentiate
  return 0
}

/**
 * Compute higher-order derivatives
 * @param expr Expression to differentiate
 * @param variable Variable with respect to which to differentiate
 * @param order Order of derivative (default: 1)
 * @returns Higher-order derivative result
 */
export function higherOrderDerivative(
  expr: Expr,
  variable: string,
  order: number = 1,
): DerivativeResult {
  if (order <= 0) {
    throw new InvalidDerivativeOrderError(order)
  }

  let current = expr
  const chainComponents: Array<{ expression: Expr; derivative: Expr }> = []

  for (let i = 0; i < order; i++) {
    const derivative = computeDerivative(current, variable)
    chainComponents.push({
      expression: current,
      derivative,
    })
    current = derivative
  }

  const simplified = simplify(current)

  return {
    derivative: current,
    variable,
    simplified: deepEqualExpr(current, simplified) ? undefined : simplified,
    chainComponents,
  }
}

/**
 * Check if an expression is differentiable with respect to a variable
 * @param expr Expression to check
 * @param variable Variable to check differentiability with respect to
 * @returns True if differentiable, false otherwise
 */
export function isDifferentiable(expr: Expr, variable: string): boolean {
  try {
    computeDerivative(expr, variable)
    // If we get a result without throwing, it's differentiable
    return true
  } catch {
    return false
  }
}

/**
 * Find critical points (where derivative equals zero)
 * This is a symbolic analysis - actual solving would require numerical methods
 * @param expr Expression to analyze
 * @param variable Variable to find critical points for
 * @returns Information about potential critical points
 */
export function findCriticalPoints(
  expr: Expr,
  variable: string,
): {
  derivative: Expr
  simplified?: Expr
  hasConstantDerivative: boolean
  isConstantZero: boolean
} {
  const derivative = computeDerivative(expr, variable)
  const simplified = simplify(derivative)

  return {
    derivative,
    simplified: deepEqualExpr(derivative, simplified) ? undefined : simplified,
    hasConstantDerivative: typeof derivative === 'number',
    isConstantZero: derivative === 0,
  }
}
