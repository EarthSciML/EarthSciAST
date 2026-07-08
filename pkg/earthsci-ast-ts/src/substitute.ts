/**
 * Expression substitution functionality for the ESM format
 *
 * Provides immutable substitution operations that replace variable references
 * with bound expressions throughout ESM structures.
 */

import type { Expr, ExprNode, Model, ReactionSystem, EsmFile } from './types.js'
import { isNumericLiteral } from './numeric-literal.js'

/**
 * Context for resolving scoped references during substitution
 */
export interface SubstitutionContext {
  esmFile: EsmFile
}

/**
 * Recursively substitute variable references in an expression with bound expressions.
 * Handles scoped references (Model.Subsystem.var) by splitting on '.' and matching
 * path through system hierarchy per format spec Section 4.3.
 *
 * NOTE: when a `context` is supplied, any dotted reference NOT covered by
 * `bindings` is resolved through the file hierarchy and replaced with the
 * referenced variable's DECLARED DEFAULT VALUE. Callers that only want to
 * rename/replace bound names must omit `context`.
 *
 * @param expr - Expression to substitute into
 * @param bindings - Variable name to expression mappings
 * @param context - Optional context; enables default-value inlining for
 *   scoped references (see note above)
 * @returns New expression with substitutions applied (immutable)
 */
export function substitute(
  expr: Expr,
  bindings: Record<string, Expr>,
  context?: SubstitutionContext,
): Expr {
  // Base cases: numeric literals (plain numbers or tagged int/float
  // canonical-form leaves) remain unchanged.
  if (typeof expr === 'number' || isNumericLiteral(expr)) {
    return expr
  }

  // String case: variable reference
  if (typeof expr === 'string') {
    // Check for direct binding (guarded lookup: `bindings` is caller data,
    // so do not trust its own hasOwnProperty)
    if (Object.prototype.hasOwnProperty.call(bindings, expr)) {
      return bindings[expr]!
    }

    // Check for scoped reference (e.g., "Model.Subsystem.var")
    if (context && expr.includes('.')) {
      const resolvedValue = resolveScopedReference(expr, context.esmFile)
      if (resolvedValue !== null) {
        return resolvedValue
      }
    }

    return expr
  }

  // ExpressionNode case: recursively substitute arguments
  const node = expr as ExprNode
  const substitutedArgs = node.args.map((arg) => substitute(arg, bindings, context))

  // Return new node with substituted arguments
  return {
    ...node,
    args: substitutedArgs as [Expr, ...Expr[]],
  }
}

/**
 * Resolve scoped variable reference like "Model.Subsystem.var" by navigating
 * through the system hierarchy as specified in Section 4.3 of the spec.
 *
 * @param reference - Scoped reference string (e.g., "SuperFast.GasPhase.O3")
 * @param esmFile - ESM file containing the model hierarchy
 * @returns The default value of the referenced variable, or null if not found
 */
function resolveScopedReference(reference: string, esmFile: EsmFile): Expr | null {
  const parts = reference.split('.')
  if (parts.length < 2) {
    return null // Not a scoped reference
  }

  const [systemName, ...pathParts] = parts
  const variableName = pathParts.pop()!

  // Try to find in models (unresolved refs cannot be navigated)
  const rootModel = esmFile.models?.[systemName]
  if (rootModel && !('ref' in rootModel)) {
    let current: Model = rootModel as Model

    // Navigate through inline-model subsystems
    for (const pathPart of pathParts) {
      const next = current.subsystems?.[pathPart]
      if (!next || 'ref' in next || 'kind' in next) {
        return null
      }
      current = next as Model
    }

    // Check if variable exists and return its default value
    const variable = current.variables?.[variableName]
    if (variable && variable.default !== undefined) {
      return variable.default
    }
  }

  // Try to find in reaction systems
  const rootSystem = esmFile.reaction_systems?.[systemName]
  if (rootSystem) {
    let current: ReactionSystem = rootSystem

    // Navigate through inline subsystems (unresolved refs cannot be navigated)
    for (const pathPart of pathParts) {
      const next = current.subsystems?.[pathPart]
      if (!next || 'ref' in next) {
        return null
      }
      current = next as ReactionSystem
    }

    // Check if species exists and return its default value
    const species = current.species?.[variableName]
    if (species && species.default !== undefined) {
      return species.default
    }

    // Check if parameter exists and return its default value
    const parameter = current.parameters?.[variableName]
    if (parameter && parameter.default !== undefined) {
      return parameter.default
    }
  }

  // Try to find in data loaders
  if (esmFile.data_loaders && esmFile.data_loaders[systemName]) {
    const dataLoader = esmFile.data_loaders[systemName]
    if (dataLoader.variables && dataLoader.variables[variableName]) {
      // Data loaders don't have default values, return the variable name as a placeholder
      return reference
    }
  }

  return null
}

/**
 * Apply substitution across all equations in a model.
 * Returns a new model with substitutions applied (immutable).
 *
 * @param model - Model to substitute into
 * @param bindings - Variable name to expression mappings
 * @param context - Optional context for resolving scoped references
 * @returns New model with substitutions applied
 */
export function substituteInModel(
  model: Model,
  bindings: Record<string, Expr>,
  context?: SubstitutionContext,
): Model {
  // Substitute in all equations. substitute() may return tagged
  // NumericLiteral leaves, which are an in-memory-only widening of the
  // schema's Expression type (see types.ts); cast back to the schema view.
  const equations = (model.equations || []).map((eq) => ({
    ...eq,
    lhs: substitute(eq.lhs, bindings, context),
    rhs: substitute(eq.rhs, bindings, context),
  })) as Model['equations']

  // Substitute in variable expressions (for observed variables)
  const variables = Object.fromEntries(
    Object.entries(model.variables || {}).map(([name, variable]) => [
      name,
      {
        ...variable,
        ...(variable.expression && {
          expression: substitute(variable.expression, bindings, context),
        }),
      },
    ]),
  ) as Model['variables']

  // Substitute in inline-model subsystems recursively; data loaders and
  // unresolved refs pass through unchanged.
  const subsystems = model.subsystems
    ? Object.fromEntries(
        Object.entries(model.subsystems).map(([name, subsystem]) => [
          name,
          'ref' in subsystem || 'kind' in subsystem
            ? subsystem
            : substituteInModel(subsystem as Model, bindings, context),
        ]),
      )
    : undefined

  return {
    ...model,
    equations,
    variables,
    ...(subsystems && { subsystems }),
  }
}

/**
 * Apply substitution across all rate expressions in a reaction system.
 * Returns a new reaction system with substitutions applied (immutable).
 *
 * @param system - ReactionSystem to substitute into
 * @param bindings - Variable name to expression mappings
 * @param context - Optional context for resolving scoped references
 * @returns New reaction system with substitutions applied
 */
export function substituteInReactionSystem(
  system: ReactionSystem,
  bindings: Record<string, Expr>,
  context?: SubstitutionContext,
): ReactionSystem {
  // Substitute in all reaction rate expressions
  const reactions = system.reactions.map((reaction) => ({
    ...reaction,
    rate: substitute(reaction.rate, bindings, context),
  })) as [(typeof system.reactions)[0], ...(typeof system.reactions)[0][]]

  // Substitute in constraint equations if present. As above, tagged
  // NumericLiteral leaves are an in-memory-only widening of the schema's
  // Expression type; cast back to the schema view.
  const constraint_equations = system.constraint_equations?.map((eq) => ({
    ...eq,
    lhs: substitute(eq.lhs, bindings, context),
    rhs: substitute(eq.rhs, bindings, context),
  })) as ReactionSystem['constraint_equations']

  // Substitute in inline subsystems recursively; unresolved refs pass
  // through unchanged.
  const subsystems = system.subsystems
    ? Object.fromEntries(
        Object.entries(system.subsystems).map(([name, subsystem]) => [
          name,
          'ref' in subsystem
            ? subsystem
            : substituteInReactionSystem(subsystem as ReactionSystem, bindings, context),
        ]),
      )
    : undefined

  return {
    ...system,
    reactions,
    ...(constraint_equations && { constraint_equations }),
    ...(subsystems && { subsystems }),
  }
}
