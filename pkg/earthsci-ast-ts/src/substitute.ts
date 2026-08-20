/**
 * Expression substitution functionality for the ESM format
 *
 * Provides immutable substitution operations that replace variable references
 * with bound expressions throughout ESM structures.
 */

import type { Expr, ExprNode, Model, ReactionSystem, EsmFile } from './types.js'
import { isNumericLiteral } from './numeric-literal.js'
import { mapChildren } from './expression.js'

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

  // ExpressionNode case: substitute EVERY expression-bearing child, not just
  // `args`. `mapChildren` (expression.ts) enumerates the complete, canonical
  // child set — `args`, aggregate `expr`/`filter`/`key`, integral
  // `lower`/`upper`, `makearray` `values`, `table_lookup` `axes`, and template
  // `bindings` — so structural subexpressions are no longer silently skipped.
  // Every non-child metadata field (`op`, `wrt`, `reduce`, `dim`, ...) is
  // preserved verbatim.
  return mapChildren(expr as ExprNode, (child) => substitute(child, bindings, context))
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

  // Try to find in reaction systems (unresolved refs cannot be navigated)
  const rootSystem = esmFile.reaction_systems?.[systemName]
  if (rootSystem && !('ref' in rootSystem)) {
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

  // NOTE: no data-source branch. A `data_sources` entry exposes no variables of
  // its own from 1.0.0 and is not a path root in a scoped reference, so
  // `Source.field` names nothing and there is nothing here to resolve. The
  // 0.x branch returned `null` for a loader variable anyway — a loader declared
  // no default, so a reference into one never inlined — which is exactly what
  // falling through to the final `return null` still does.
  return null
}

/**
 * Apply substitution across an ENTIRE model, not just its equations.
 *
 * The rewritten expression sites are, exhaustively (this is the single write
 * definition of "a model's expression sites"; `edit.ts`'s read-side
 * `forEachModelExpressionSite` MUST cover the same set):
 *   - every equation `lhs` / `rhs`;
 *   - every observed variable's `expression`;
 *   - every continuous event's `conditions[]`, `affects[].rhs`, and
 *     `affect_neg[].rhs`;
 *   - every discrete event's condition-`trigger.expression` and `affects[].rhs`;
 *   - recursively, every inline-model subsystem (data loaders and unresolved
 *     `{ref}` subsystems pass through unchanged).
 *
 * Event affect `lhs` values are write-TARGET names (`string`), not expression
 * read-sites, and are intentionally left untouched — substitution replaces
 * references, not assignment targets.
 *
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

  // Variables carry no expression from 1.0.0 — an observed unknown's definition
  // is an equation, substituted above — so they pass through unchanged.
  const variables = model.variables

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

  // Substitute in continuous-event expression positions (conditions and affect
  // RHSs). Absent/legacy-shaped fields are preserved verbatim via the spread.
  const continuous_events = model.continuous_events?.map((event) => ({
    ...event,
    ...(Array.isArray(event.conditions) && {
      conditions: event.conditions.map((c) => substitute(c, bindings, context)),
    }),
    ...(Array.isArray(event.affects) && {
      affects: event.affects.map((a) => ({ ...a, rhs: substitute(a.rhs, bindings, context) })),
    }),
    ...(Array.isArray(event.affect_neg) && {
      affect_neg: event.affect_neg.map((a) => ({
        ...a,
        rhs: substitute(a.rhs, bindings, context),
      })),
    }),
  })) as Model['continuous_events']

  // Substitute in discrete-event expression positions (a condition trigger's
  // expression and affect RHSs). Non-condition triggers carry no expression.
  const discrete_events = model.discrete_events?.map((event) => ({
    ...event,
    ...(event.trigger?.type === 'condition' && {
      trigger: {
        ...event.trigger,
        expression: substitute(event.trigger.expression, bindings, context),
      },
    }),
    ...(Array.isArray(event.affects) && {
      affects: event.affects.map((a) => ({ ...a, rhs: substitute(a.rhs, bindings, context) })),
    }),
  })) as Model['discrete_events']

  return {
    ...model,
    equations,
    variables,
    ...(subsystems && { subsystems }),
    ...(continuous_events && { continuous_events }),
    ...(discrete_events && { discrete_events }),
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
