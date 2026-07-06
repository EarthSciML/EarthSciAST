/**
 * Expression structural operations for the ESM format
 *
 * This module provides utilities for analyzing and manipulating mathematical
 * expressions in the ESM format AST.
 */

import type { Expression, ExpressionNode, Model } from './types.js'
import { isNumericLiteral, type NumericLiteral } from './numeric-literal.js'
import { evaluateExpression } from './codegen.js'

/**
 * Type alias for better readability. Widened to accept `NumericLiteral`
 * leaves (per discretization RFC §5.4.1) alongside plain JS numbers.
 */
export type Expr = Expression | NumericLiteral

/**
 * Extract all variable references from an expression
 * @param expr Expression to analyze
 * @returns Set of variable names referenced in the expression
 */
export function freeVariables(expr: Expr): Set<string> {
  const variables = new Set<string>()

  if (typeof expr === 'string') {
    variables.add(expr)
  } else if (typeof expr === 'number' || isNumericLiteral(expr)) {
    // Numeric literals contain no variables
    return variables
  } else if (typeof expr === 'object' && (expr as ExpressionNode).op) {
    // ExpressionNode - recursively analyze arguments
    for (const arg of (expr as ExpressionNode).args) {
      const childVars = freeVariables(arg as Expr)
      childVars.forEach(v => variables.add(v))
    }
  }

  return variables
}

/**
 * Extract free parameters from an expression within a model context
 * @param expr Expression to analyze
 * @param model Model context to determine parameter vs state variables
 * @returns Set of parameter names referenced in the expression
 */
export function freeParameters(expr: Expr, model: Model): Set<string> {
  const allVars = freeVariables(expr)
  const parameters = new Set<string>()

  for (const varName of allVars) {
    const variable = model.variables[varName]
    if (variable && variable.type === 'parameter') {
      parameters.add(varName)
    }
  }

  return parameters
}

/**
 * Check if an expression contains a specific variable
 * @param expr Expression to search
 * @param varName Variable name to look for
 * @returns True if the variable appears in the expression
 */
export function contains(expr: Expr, varName: string): boolean {
  if (typeof expr === 'string') {
    return expr === varName
  } else if (typeof expr === 'number' || isNumericLiteral(expr)) {
    return false
  } else if (typeof expr === 'object' && (expr as ExpressionNode).op) {
    // ExpressionNode - recursively check arguments
    return (expr as ExpressionNode).args.some(arg => contains(arg as Expr, varName))
  }

  return false
}

/**
 * Simplify an expression using basic algebraic rules
 * @param expr Expression to simplify
 * @returns Simplified expression
 */
export function simplify(expr: Expr): Expr {
  if (typeof expr === 'number' || typeof expr === 'string') {
    return expr
  }

  if (isNumericLiteral(expr)) {
    // NumericLiteral leaves carry a kind tag that simplify is not
    // responsible for folding. Canonical int/float folding lives in
    // canonicalize() per RFC §5.4. Return unchanged.
    return expr
  }

  if (typeof expr === 'object' && (expr as ExpressionNode).op) {
    // First simplify all arguments recursively
    const simplifiedArgs = expr.args.map(arg => simplify(arg))

    // Apply simplification rules based on operator
    switch (expr.op) {
      case '+': {
        // Remove zeros: x + 0 -> x
        const nonZeroTerms = simplifiedArgs.filter(arg => arg !== 0)
        if (nonZeroTerms.length === 0) return 0
        if (nonZeroTerms.length === 1) return nonZeroTerms[0]

        // Separate constants and variables for partial constant folding
        const constants = nonZeroTerms.filter(arg => typeof arg === 'number') as number[]
        const variables = nonZeroTerms.filter(arg => typeof arg !== 'number')

        // If all terms are constants, return the sum
        if (variables.length === 0) {
          return constants.reduce((sum, val) => sum + val, 0)
        }

        // If there are constants to fold, combine them
        if (constants.length > 1) {
          const constantSum = constants.reduce((sum, val) => sum + val, 0)
          if (constantSum === 0) {
            // If constant sum is zero, just return variables
            return variables.length === 1 ? variables[0] : { ...expr, args: variables as [Expression, ...Expression[]] }
          } else {
            // Include the folded constant with variables
            const finalTerms = [...variables, constantSum]
            return { ...expr, args: finalTerms as [Expression, ...Expression[]] }
          }
        }

        return { ...expr, args: nonZeroTerms as [Expression, ...Expression[]] }
      }

      case '*': {
        // Zero multiplication: x * 0 -> 0
        if (simplifiedArgs.some(arg => arg === 0)) return 0

        // Remove ones: x * 1 -> x
        const nonOneFactors = simplifiedArgs.filter(arg => arg !== 1)
        if (nonOneFactors.length === 0) return 1
        if (nonOneFactors.length === 1) return nonOneFactors[0]

        // Separate constants and variables for partial constant folding
        const constantFactors = nonOneFactors.filter(arg => typeof arg === 'number') as number[]
        const variableFactors = nonOneFactors.filter(arg => typeof arg !== 'number')

        // If all factors are constants, return the product
        if (variableFactors.length === 0) {
          return constantFactors.reduce((prod, val) => prod * val, 1)
        }

        // If there are constants to fold, combine them
        if (constantFactors.length > 1) {
          const constantProd = constantFactors.reduce((prod, val) => prod * val, 1)
          if (constantProd === 0) {
            return 0
          } else if (constantProd === 1) {
            // If constant product is one, just return variables
            return variableFactors.length === 1 ? variableFactors[0] : { ...expr, args: variableFactors as [Expression, ...Expression[]] }
          } else {
            // Include the folded constant with variables
            const finalFactors = [...variableFactors, constantProd]
            return { ...expr, args: finalFactors as [Expression, ...Expression[]] }
          }
        }

        return { ...expr, args: nonOneFactors as [Expression, ...Expression[]] }
      }

      case '-':
        if (simplifiedArgs.length === 1) {
          // Unary minus: -(-x) -> x would need deeper analysis
          if (typeof simplifiedArgs[0] === 'number') {
            return -simplifiedArgs[0]
          }
        } else if (simplifiedArgs.length === 2) {
          // Binary subtraction: x - 0 -> x
          if (simplifiedArgs[1] === 0) return simplifiedArgs[0]

          // Constant folding
          if (typeof simplifiedArgs[0] === 'number' && typeof simplifiedArgs[1] === 'number') {
            return simplifiedArgs[0] - simplifiedArgs[1]
          }
        }

        return { ...expr, args: simplifiedArgs as [Expression, ...Expression[]] }

      case '/':
        if (simplifiedArgs.length === 2) {
          // x / 1 -> x
          if (simplifiedArgs[1] === 1) return simplifiedArgs[0]

          // Constant folding. A zero denominator is left unfolded — a pure
          // simplifier must not throw, and 0/0 vs x/0 semantics belong to
          // evaluation, not rewriting.
          if (typeof simplifiedArgs[0] === 'number' && typeof simplifiedArgs[1] === 'number'
              && simplifiedArgs[1] !== 0) {
            return simplifiedArgs[0] / simplifiedArgs[1]
          }
        }

        return { ...expr, args: simplifiedArgs as [Expression, ...Expression[]] }

      case '^':
        if (simplifiedArgs.length === 2) {
          // x^0 -> 1
          if (simplifiedArgs[1] === 0) return 1

          // x^1 -> x
          if (simplifiedArgs[1] === 1) return simplifiedArgs[0]

          // 1^x -> 1 (sound for every finite x)
          if (simplifiedArgs[0] === 1) return 1

          // NOTE: 0^x is NOT folded to 0 — that identity only holds for
          // x > 0, which cannot be assumed for a symbolic exponent.

          // Constant folding
          if (typeof simplifiedArgs[0] === 'number' && typeof simplifiedArgs[1] === 'number') {
            return Math.pow(simplifiedArgs[0], simplifiedArgs[1])
          }
        }

        return { ...expr, args: simplifiedArgs as [Expression, ...Expression[]] }

      default:
        // For other operators, apply constant folding if all args are
        // numeric. Folding goes through the official codegen runner so
        // we share one dispatch table with the per-call evaluator.
        if (simplifiedArgs.every(arg => typeof arg === 'number')) {
          try {
            const tempBindings = new Map<string, number>()
            return evaluateExpression({ ...expr, args: simplifiedArgs as [Expression, ...Expression[]] }, tempBindings)
          } catch {
            return { ...expr, args: simplifiedArgs as [Expression, ...Expression[]] }
          }
        }

        return { ...expr, args: simplifiedArgs as [Expression, ...Expression[]] }
    }
  }

  return expr
}