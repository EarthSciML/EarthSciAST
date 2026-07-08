/**
 * Common subexpression identification and elimination
 *
 * This module provides functions to identify repeated subexpressions
 * within expressions or across multiple expressions in a model.
 */

import type { Expr, Model, EsmFile } from '../types.js'
import type { CommonSubexpression, ExpressionLocation } from './types.js'
import { analyzeComplexity } from './complexity.js'
import { isExprNode } from '../expression.js'
import { isNumericLiteral, isIntLit } from '../numeric-literal.js'

/**
 * Find common subexpressions in a single expression
 * @param expr Expression to analyze
 * @param minComplexity Minimum complexity threshold for considering subexpressions
 * @returns Array of common subexpressions found
 */
export function findCommonSubexpressions(
  expr: Expr,
  minComplexity: number = 5,
): CommonSubexpression[] {
  const subexpressionMap = new Map<
    string,
    {
      expression: Expr
      locations: ExpressionLocation[]
      count: number
    }
  >()

  // Recursively extract subexpressions
  function extractSubexpressions(currentExpr: Expr, path: string[], context?: Expr) {
    if (isExprNode(currentExpr)) {
      const complexity = analyzeComplexity(currentExpr).computationalCost

      // Only consider subexpressions above the complexity threshold
      if (complexity >= minComplexity) {
        const key = serializeExpression(currentExpr)

        if (!subexpressionMap.has(key)) {
          subexpressionMap.set(key, {
            expression: currentExpr,
            locations: [],
            count: 0,
          })
        }

        const entry = subexpressionMap.get(key)!
        entry.count++
        entry.locations.push({
          path: [...path],
          description: `Path: ${path.join(' -> ')}`,
          context,
        })
      }

      // Recursively process arguments
      currentExpr.args.forEach((arg, index) => {
        extractSubexpressions(arg, [...path, `args[${index}]`], currentExpr)
      })
    }
  }

  extractSubexpressions(expr, ['root'])

  // Convert to CommonSubexpression format, filtering for actual duplicates
  const results: CommonSubexpression[] = []

  for (const data of subexpressionMap.values()) {
    if (data.count > 1) {
      // Only include actual duplicates
      const complexity = analyzeComplexity(data.expression).computationalCost
      const savings = complexity * (data.count - 1) // Cost saved by factoring out

      results.push({
        expression: data.expression,
        locations: data.locations,
        count: data.count,
        savings,
      })
    }
  }

  // Sort by potential savings (highest first)
  return results.sort((a, b) => b.savings - a.savings)
}

/**
 * Find common subexpressions across multiple expressions
 * @param expressions Array of expressions to analyze
 * @param minComplexity Minimum complexity threshold
 * @returns Array of common subexpressions found across expressions
 */
export function findCommonSubexpressionsAcrossExpressions(
  expressions: Array<{ expr: Expr; name: string }>,
  minComplexity: number = 5,
): CommonSubexpression[] {
  const subexpressionMap = new Map<
    string,
    {
      expression: Expr
      locations: ExpressionLocation[]
      count: number
    }
  >()

  // Process each expression
  expressions.forEach((item) => {
    function extractSubexpressions(currentExpr: Expr, path: string[], context?: Expr) {
      if (isExprNode(currentExpr)) {
        const complexity = analyzeComplexity(currentExpr).computationalCost

        if (complexity >= minComplexity) {
          const key = serializeExpression(currentExpr)

          if (!subexpressionMap.has(key)) {
            subexpressionMap.set(key, {
              expression: currentExpr,
              locations: [],
              count: 0,
            })
          }

          const entry = subexpressionMap.get(key)!
          entry.count++
          entry.locations.push({
            path: [item.name, ...path],
            description: `Expression "${item.name}" at ${path.join(' -> ')}`,
            context,
          })
        }

        // Recursively process arguments
        currentExpr.args.forEach((arg, index) => {
          extractSubexpressions(arg, [...path, `args[${index}]`], currentExpr)
        })
      }
    }

    extractSubexpressions(item.expr, ['root'])
  })

  // Convert to CommonSubexpression format
  const results: CommonSubexpression[] = []

  for (const data of subexpressionMap.values()) {
    if (data.count > 1) {
      const complexity = analyzeComplexity(data.expression).computationalCost
      const savings = complexity * (data.count - 1)

      results.push({
        expression: data.expression,
        locations: data.locations,
        count: data.count,
        savings,
      })
    }
  }

  return results.sort((a, b) => b.savings - a.savings)
}

/**
 * Collect every analyzable expression in a model — observed-variable
 * definitions, equation right-hand sides, and inline subsystems
 * (recursively) — with dot-path names for location reporting.
 */
function collectModelExpressions(
  model: Model,
  prefix: string,
  out: Array<{ expr: Expr; name: string }>,
): void {
  if (model.variables) {
    for (const [varName, variable] of Object.entries(model.variables)) {
      if (variable.expression) {
        out.push({
          expr: variable.expression,
          name: `${prefix}variable.${varName}`,
        })
      }
    }
  }

  if (model.equations) {
    model.equations.forEach((equation, index) => {
      out.push({
        expr: equation.rhs,
        name: `${prefix}equation[${index}].rhs`,
      })
    })
  }

  if (model.subsystems) {
    for (const [subsystemName, subsystem] of Object.entries(model.subsystems)) {
      // Unresolved refs and data-loader subsystems carry no expressions.
      if ('ref' in subsystem || 'kind' in subsystem) continue
      collectModelExpressions(subsystem as Model, `${prefix}Subsystem "${subsystemName}" `, out)
    }
  }
}

/**
 * Find common subexpressions in a model (including its subsystems). All of
 * the model's expressions are analyzed in a single pass so duplicates that
 * span the parent and a subsystem are counted together.
 * @param model Model to analyze
 * @param minComplexity Minimum complexity threshold
 * @returns Array of common subexpressions found in the model
 */
export function findCommonSubexpressionsInModel(
  model: Model,
  minComplexity: number = 5,
): CommonSubexpression[] {
  const expressions: Array<{ expr: Expr; name: string }> = []
  collectModelExpressions(model, '', expressions)
  return findCommonSubexpressionsAcrossExpressions(expressions, minComplexity)
}

/**
 * Find common subexpressions across an entire ESM file. All models' and
 * reaction systems' raw expressions are aggregated into ONE analysis pass so
 * occurrence counts and locations reflect actual appearances — including
 * duplicates local to a single model and duplicates spanning components.
 * @param esmFile ESM file to analyze
 * @param minComplexity Minimum complexity threshold
 * @returns Array of common subexpressions found across the file
 */
export function findCommonSubexpressionsInEsmFile(
  esmFile: EsmFile,
  minComplexity: number = 5,
): CommonSubexpression[] {
  const expressions: Array<{ expr: Expr; name: string }> = []

  // Collect from models (unresolved refs carry no expressions)
  if (esmFile.models) {
    for (const [modelId, model] of Object.entries(esmFile.models)) {
      if ('ref' in model) continue
      collectModelExpressions(model as Model, `model.${modelId}.`, expressions)
    }
  }

  // Collect rate expressions from reaction systems
  if (esmFile.reaction_systems) {
    for (const [systemId, reactionSystem] of Object.entries(esmFile.reaction_systems)) {
      if (reactionSystem.reactions) {
        reactionSystem.reactions.forEach((reaction, index) => {
          expressions.push({
            expr: reaction.rate,
            name: `reaction_system.${systemId}.reaction[${index}].rate`,
          })
        })
      }
    }
  }

  return findCommonSubexpressionsAcrossExpressions(expressions, minComplexity)
}

/**
 * Generate a canonical string representation of an expression for comparison
 * @param expr Expression to serialize
 * @returns Canonical string representation
 */
function serializeExpression(expr: Expr): string {
  if (typeof expr === 'number') {
    return `n:${expr}`
  } else if (isNumericLiteral(expr)) {
    // Tagged canonical-mode literal: key by value, keeping the int/float
    // distinction so int 2 and float 2.0 do not collapse.
    return `${isIntLit(expr) ? 'i' : 'n'}:${expr.value}`
  } else if (typeof expr === 'string') {
    return `v:${expr}`
  } else if (isExprNode(expr)) {
    // Sort arguments for commutative operations to ensure canonical form
    const commutativeOps = new Set(['+', '*', 'and', 'or', 'min', 'max'])

    let args = expr.args
    if (commutativeOps.has(expr.op)) {
      // Sort arguments by their serialized form for commutative operations
      args = [...expr.args].sort((a, b) =>
        serializeExpression(a).localeCompare(serializeExpression(b)),
      )
    }

    const serializedArgs = args.map((arg) => serializeExpression(arg)).join(',')

    // Include additional properties if they exist
    const extras = []
    if ('dim' in expr && expr.dim) extras.push(`dim:${expr.dim}`)
    if ('units' in expr && expr.units) extras.push(`units:${expr.units}`)

    const extrasStr = extras.length > 0 ? `|${extras.join('|')}` : ''

    return `op:${expr.op}(${serializedArgs})${extrasStr}`
  }

  return 'unknown'
}

/**
 * Estimate the cost savings from factoring out common subexpressions
 * @param commonSubexpressions Array of common subexpressions
 * @returns Total estimated cost savings
 */
export function estimateSavings(commonSubexpressions: CommonSubexpression[]): number {
  return commonSubexpressions.reduce((total, subexpr) => total + subexpr.savings, 0)
}

/**
 * Generate variable names for factored subexpressions
 * @param commonSubexpressions Array of common subexpressions
 * @param prefix Prefix for generated variable names
 * @returns Map of expressions to generated variable names
 */
export function generateFactoredVariableNames(
  commonSubexpressions: CommonSubexpression[],
  prefix: string = 'temp_',
): Map<string, string> {
  const nameMap = new Map<string, string>()
  let counter = 1

  for (const subexpr of commonSubexpressions) {
    const key = serializeExpression(subexpr.expression)
    if (!nameMap.has(key)) {
      nameMap.set(key, `${prefix}${counter++}`)
    }
  }

  return nameMap
}

/**
 * Group common subexpressions by their structure type
 * @param commonSubexpressions Array of common subexpressions
 * @returns Grouped subexpressions by operation type
 */
export function groupSubexpressionsByType(
  commonSubexpressions: CommonSubexpression[],
): Record<string, CommonSubexpression[]> {
  const groups: Record<string, CommonSubexpression[]> = {}

  for (const subexpr of commonSubexpressions) {
    let groupKey = 'atomic'

    if (isExprNode(subexpr.expression)) {
      groupKey = subexpr.expression.op
    }

    if (!groups[groupKey]) {
      groups[groupKey] = []
    }
    groups[groupKey].push(subexpr)
  }

  return groups
}
