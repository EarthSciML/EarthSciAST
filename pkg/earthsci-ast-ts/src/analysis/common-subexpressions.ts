/**
 * Common subexpression identification and elimination
 *
 * This module provides functions to identify repeated subexpressions
 * within expressions or across multiple expressions in a model.
 */

import type { Expr, ExpressionNode, Model, EsmFile } from '../types.js'
import type { CommonSubexpression, ExpressionLocation } from './types.js'
import { analyzeComplexity } from './complexity.js'
import { isExprNode, forEachChild } from '../expression.js'
import { canonicalJson } from '../canonicalize.js'

/**
 * Default minimum {@link analyzeComplexity} cost a subexpression must reach to
 * be considered for factoring. Shared by every entry point below.
 */
export const DEFAULT_MIN_COMPLEXITY = 5

/**
 * Canonical key used to group structurally-identical subexpressions. Keying on
 * {@link canonicalJson} preserves every distinguishing field (`op`, `args`,
 * `wrt`, `dim`, `value`, ...), so distinct nodes that merely share op/args are
 * NOT collapsed. Falls back to a full structural stringification if a node
 * cannot be canonicalized (e.g. a non-finite literal).
 */
function subexpressionKey(expr: ExpressionNode): string {
  try {
    return canonicalJson(expr)
  } catch {
    return JSON.stringify(expr)
  }
}

/**
 * Walk every named expression's tree, group structurally-identical
 * subexpressions above the complexity threshold, and return those appearing
 * more than once (highest estimated savings first). `makeLocation` renders each
 * occurrence's {@link ExpressionLocation}, letting the single-expression and
 * across-expression entry points share one collector while keeping their
 * distinct location vocabularies.
 */
function collectCommonSubexpressions(
  items: Array<{ expr: Expr; name: string }>,
  minComplexity: number,
  makeLocation: (name: string, path: string[], context?: Expr) => ExpressionLocation,
): CommonSubexpression[] {
  const subexpressionMap = new Map<
    string,
    { expression: Expr; locations: ExpressionLocation[]; count: number }
  >()

  for (const item of items) {
    const visit = (currentExpr: Expr, path: string[], context?: Expr): void => {
      if (!isExprNode(currentExpr)) return

      const complexity = analyzeComplexity(currentExpr).computationalCost
      if (complexity >= minComplexity) {
        const key = subexpressionKey(currentExpr)

        let entry = subexpressionMap.get(key)
        if (!entry) {
          entry = { expression: currentExpr, locations: [], count: 0 }
          subexpressionMap.set(key, entry)
        }
        entry.count++
        entry.locations.push(makeLocation(item.name, path, context))
      }

      // Recurse through every expression-bearing child (args, aggregate
      // bodies, integral bounds, ...) via the shared walker.
      forEachChild(currentExpr, (child, childKey, index) => {
        const segment = index !== undefined ? `${childKey}[${index}]` : childKey
        visit(child, [...path, segment], currentExpr)
      })
    }

    visit(item.expr, ['root'])
  }

  const results: CommonSubexpression[] = []
  for (const data of subexpressionMap.values()) {
    if (data.count > 1) {
      const complexity = analyzeComplexity(data.expression).computationalCost
      const savings = complexity * (data.count - 1) // Cost saved by factoring out.
      results.push({
        expression: data.expression,
        locations: data.locations,
        count: data.count,
        savings,
      })
    }
  }

  // Sort by potential savings (highest first).
  return results.sort((a, b) => b.savings - a.savings)
}

/**
 * Find common subexpressions in a single expression
 * @param expr Expression to analyze
 * @param minComplexity Minimum complexity threshold for considering subexpressions
 * @returns Array of common subexpressions found
 */
export function findCommonSubexpressions(
  expr: Expr,
  minComplexity: number = DEFAULT_MIN_COMPLEXITY,
): CommonSubexpression[] {
  return collectCommonSubexpressions([{ expr, name: 'root' }], minComplexity, (_name, path, context) => ({
    path: [...path],
    description: `Path: ${path.join(' -> ')}`,
    context,
  }))
}

/**
 * Find common subexpressions across multiple expressions
 * @param expressions Array of expressions to analyze
 * @param minComplexity Minimum complexity threshold
 * @returns Array of common subexpressions found across expressions
 */
export function findCommonSubexpressionsAcrossExpressions(
  expressions: Array<{ expr: Expr; name: string }>,
  minComplexity: number = DEFAULT_MIN_COMPLEXITY,
): CommonSubexpression[] {
  return collectCommonSubexpressions(expressions, minComplexity, (name, path, context) => ({
    path: [name, ...path],
    description: `Expression "${name}" at ${path.join(' -> ')}`,
    context,
  }))
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
  minComplexity: number = DEFAULT_MIN_COMPLEXITY,
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
  minComplexity: number = DEFAULT_MIN_COMPLEXITY,
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
 * Estimate the cost savings from factoring out common subexpressions
 * @param commonSubexpressions Array of common subexpressions
 * @returns Total estimated cost savings
 */
export function estimateSavings(commonSubexpressions: CommonSubexpression[]): number {
  return commonSubexpressions.reduce((total, subexpr) => total + subexpr.savings, 0)
}

/**
 * Generate variable names for factored subexpressions.
 *
 * Keyed by the {@link CommonSubexpression} object itself so callers can look up
 * a generated name directly from the array element (the previous private
 * string key could not be reconstructed by callers).
 * @param commonSubexpressions Array of common subexpressions
 * @param prefix Prefix for generated variable names
 * @returns Map from each common subexpression to its generated variable name
 */
export function generateFactoredVariableNames(
  commonSubexpressions: CommonSubexpression[],
  prefix: string = 'temp_',
): Map<CommonSubexpression, string> {
  const nameMap = new Map<CommonSubexpression, string>()
  let counter = 1

  for (const subexpr of commonSubexpressions) {
    if (!nameMap.has(subexpr)) {
      nameMap.set(subexpr, `${prefix}${counter++}`)
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
