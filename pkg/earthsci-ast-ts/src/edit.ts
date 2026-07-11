/**
 * Immutable editing operations for the ESM format
 *
 * This module provides comprehensive editing operations for ESM files, models,
 * and reaction systems. All operations are immutable and return new objects.
 */

import type {
  EsmFile,
  Model,
  ReactionSystem,
  ModelVariable,
  Equation,
  Reaction,
  Species,
  ContinuousEvent,
  DiscreteEvent,
  CouplingEntry,
  CouplingVariableMap,
  Expr,
} from './types.js'
import { substituteInModel } from './substitute.js'
import { isNumericLiteral } from './numeric-literal.js'
import { deepEqualExpr, forEachChild, isExprNode } from './expression.js'
import { forEachEquation, forEachModelVariable, isReferenceStub } from './traverse.js'

/**
 * Error thrown when attempting to remove a variable that is still referenced
 */
export class VariableInUseError extends Error {
  constructor(
    public variableName: string,
    public references: string[],
  ) {
    super(`Cannot remove variable "${variableName}": still referenced in ${references.join(', ')}`)
    this.name = 'VariableInUseError'
  }
}

/**
 * Error thrown when attempting an operation on a non-existent entity
 */
export class EntityNotFoundError extends Error {
  constructor(
    public entityType: string,
    public entityName: string,
  ) {
    super(`${entityType} "${entityName}" not found`)
    this.name = 'EntityNotFoundError'
  }
}

// =============================================================================
// Variable Operations
// =============================================================================

/**
 * Add a new variable to a model
 * @param model Model to add variable to
 * @param name Variable name
 * @param variable Variable definition
 * @returns New model with variable added
 */
export function addVariable(model: Model, name: string, variable: ModelVariable): Model {
  return {
    ...model,
    variables: {
      ...model.variables,
      [name]: variable,
    },
  }
}

/**
 * Remove a variable from a model, with reference checking
 * @param model Model to remove variable from
 * @param name Variable name to remove
 * @returns New model with variable removed
 * @throws VariableInUseError if variable is still referenced
 * @throws EntityNotFoundError if variable doesn't exist
 */
export function removeVariable(model: Model, name: string): Model {
  if (!model.variables || !(name in model.variables)) {
    throw new EntityNotFoundError('Variable', name)
  }

  // A Set collapses the same site reported from more than one position (e.g.
  // an equation matching in both `lhs` and `rhs`) into a single reference, and
  // preserves discovery order.
  const references = new Set<string>()

  // Scan every EXPRESSION read-site — the same set `substituteInModel` rewrites
  // (equations, observed-variable expressions, event conditions/triggers/affect
  // RHSs, recursing into inline subsystems) — via the shared enumerator, so
  // removal safety and renaming can never again disagree on where a variable
  // can appear.
  forEachModelExpressionSite(model, (expr, site) => {
    if (referencesVariable(expr, name)) references.add(site)
  })

  // Event affect TARGETS are variable NAMES (`string`), not expression
  // read-sites: a variable written by an event is still in use, so it is
  // checked here rather than in the Expression-typed enumerator above.
  for (const [i, event] of (model.continuous_events ?? []).entries()) {
    for (const [j, affect] of (event.affects ?? []).entries()) {
      if (affect.lhs === name) references.add(`continuous_event ${i} affect ${j}`)
    }
  }
  for (const [i, event] of (model.discrete_events ?? []).entries()) {
    for (const [j, affect] of (event.affects ?? []).entries()) {
      if (affect.lhs === name) references.add(`discrete_event ${i} affect ${j}`)
    }
  }

  if (references.size > 0) {
    throw new VariableInUseError(name, [...references])
  }

  const { [name]: _removed, ...remainingVariables } = model.variables
  return {
    ...model,
    variables: remainingVariables,
  }
}

/**
 * Rename a variable throughout a model.
 *
 * The rewrite covers exactly the expression sites `removeVariable` scans (via
 * `substituteInModel` — equations, observed-variable expressions, event
 * conditions/triggers/affect RHSs, and inline subsystems), so a rename never
 * leaves a dangling reference in a site the removal guard would have flagged.
 *
 * @param model Model to rename variable in
 * @param oldName Current variable name
 * @param newName New variable name
 * @returns New model with variable renamed
 * @throws EntityNotFoundError if variable doesn't exist
 */
export function renameVariable(model: Model, oldName: string, newName: string): Model {
  if (!model.variables || !(oldName in model.variables)) {
    throw new EntityNotFoundError('Variable', oldName)
  }

  // Create substitution binding
  const bindings = { [oldName]: newName }

  // Apply substitution throughout the model
  let updatedModel = substituteInModel(model, bindings)

  // Update variable declarations
  const { [oldName]: variable, ...otherVariables } = updatedModel.variables
  updatedModel = {
    ...updatedModel,
    variables: {
      ...otherVariables,
      [newName]: variable,
    },
  }

  return updatedModel
}

// =============================================================================
// Equation Operations
// =============================================================================

/**
 * Add a new equation to a model
 * @param model Model to add equation to
 * @param equation Equation to add
 * @returns New model with equation added
 */
export function addEquation(model: Model, equation: Equation): Model {
  const equations = model.equations || []
  return {
    ...model,
    equations: [...equations, equation],
  }
}

/**
 * Remove an equation from a model
 * @param model Model to remove equation from
 * @param indexOrLhs Either the numeric index or the LHS expression of the equation
 * @returns New model with equation removed
 * @throws EntityNotFoundError if equation not found
 */
export function removeEquation(model: Model, indexOrLhs: number | Expr): Model {
  const equations = model.equations || []

  let indexToRemove: number

  if (typeof indexOrLhs === 'number') {
    indexToRemove = indexOrLhs
    if (indexToRemove < 0 || indexToRemove >= equations.length) {
      throw new EntityNotFoundError('Equation', `index ${indexToRemove}`)
    }
  } else {
    // Find equation by LHS using field-aware structural equality, so e.g. two
    // `const` nodes with different `value`s (or derivatives differing only in
    // `wrt`) are NOT treated as the same equation.
    indexToRemove = equations.findIndex((eq) => deepEqualExpr(eq.lhs, indexOrLhs))
    if (indexToRemove === -1) {
      throw new EntityNotFoundError('Equation', `with LHS ${JSON.stringify(indexOrLhs)}`)
    }
  }

  const newEquations = equations.filter((_, i) => i !== indexToRemove)
  return {
    ...model,
    equations: newEquations,
  }
}

/**
 * Apply substitutions across a model.
 *
 * NOTE: despite the historical name, this does NOT touch only equations — it is
 * a thin alias for {@link substituteInModel} and therefore also rewrites
 * observed-variable expressions, event expression positions, and inline
 * subsystems. See `substituteInModel` for the full list of rewritten sites.
 *
 * @deprecated The name understates its blast radius; call `substituteInModel`
 *   (exported from `substitute.js`) directly. Retained as a public back-compat
 *   export (re-exported via `index.ts` and `analysis/index.ts`).
 * @param model Model to apply substitutions to
 * @param bindings Variable name to expression mappings
 * @returns New model with substitutions applied
 */
export function substituteInEquations(model: Model, bindings: Record<string, Expr>): Model {
  return substituteInModel(model, bindings)
}

// =============================================================================
// Reaction Operations
// =============================================================================

/**
 * Add a new reaction to a reaction system
 * @param system ReactionSystem to add reaction to
 * @param reaction Reaction to add
 * @returns New reaction system with reaction added
 */
export function addReaction(system: ReactionSystem, reaction: Reaction): ReactionSystem {
  return {
    ...system,
    reactions: [...system.reactions, reaction] as [Reaction, ...Reaction[]],
  }
}

/**
 * Remove a reaction from a reaction system
 * @param system ReactionSystem to remove reaction from
 * @param id Reaction ID to remove
 * @returns New reaction system with reaction removed
 * @throws EntityNotFoundError if reaction not found
 */
export function removeReaction(system: ReactionSystem, id: string): ReactionSystem {
  if (!system.reactions.some((r) => r.id === id)) {
    throw new EntityNotFoundError('Reaction', id)
  }

  const newReactions = system.reactions.filter((r) => r.id !== id)
  if (newReactions.length === 0) {
    // A reaction system must retain at least one reaction (the `reactions`
    // tuple is non-empty by schema); the sole remaining reaction is therefore
    // still required. Reuse the file's typed "still in use" error rather than a
    // bare `Error` amid the module's typed-error convention.
    throw new VariableInUseError(id, ['reaction system must retain at least one reaction'])
  }

  return {
    ...system,
    reactions: newReactions as [Reaction, ...Reaction[]],
  }
}

/**
 * Add a new species to a reaction system
 * @param system ReactionSystem to add species to
 * @param name Species name
 * @param species Species definition
 * @returns New reaction system with species added
 */
export function addSpecies(system: ReactionSystem, name: string, species: Species): ReactionSystem {
  return {
    ...system,
    species: {
      ...system.species,
      [name]: species,
    },
  }
}

/**
 * Remove a species from a reaction system, with reference checking
 * @param system ReactionSystem to remove species from
 * @param name Species name to remove
 * @returns New reaction system with species removed
 * @throws VariableInUseError if species is still referenced in reactions
 * @throws EntityNotFoundError if species doesn't exist
 */
export function removeSpecies(system: ReactionSystem, name: string): ReactionSystem {
  if (!(name in system.species)) {
    throw new EntityNotFoundError('Species', name)
  }

  // Check for references in reactions
  const references: string[] = []

  for (let i = 0; i < system.reactions.length; i++) {
    const reaction = system.reactions[i]

    // Check substrates
    if (reaction.substrates) {
      for (const substrate of reaction.substrates) {
        if (substrate.species === name) {
          references.push(`reaction ${reaction.id} substrates`)
        }
      }
    }

    // Check products
    if (reaction.products) {
      for (const product of reaction.products) {
        if (product.species === name) {
          references.push(`reaction ${reaction.id} products`)
        }
      }
    }

    // Check rate expression
    if (referencesVariable(reaction.rate, name)) {
      references.push(`reaction ${reaction.id} rate`)
    }
  }

  if (references.length > 0) {
    throw new VariableInUseError(name, references)
  }

  const { [name]: _removed, ...remainingSpecies } = system.species
  return {
    ...system,
    species: remainingSpecies,
  }
}

// =============================================================================
// Event Operations
// =============================================================================

/**
 * Add a continuous event to a model
 * @param model Model to add event to
 * @param event Continuous event to add
 * @returns New model with event added
 */
export function addContinuousEvent(model: Model, event: ContinuousEvent): Model {
  const events = model.continuous_events || []
  return {
    ...model,
    continuous_events: [...events, event],
  }
}

/**
 * Add a discrete event to a model
 * @param model Model to add event to
 * @param event Discrete event to add
 * @returns New model with event added
 */
export function addDiscreteEvent(model: Model, event: DiscreteEvent): Model {
  const events = model.discrete_events || []
  return {
    ...model,
    discrete_events: [...events, event],
  }
}

/**
 * Remove events from a model by name.
 *
 * Remove-ALL semantics: EVERY event whose `name` matches is removed, not just
 * the first. Containers are tried in order — if any continuous event matches,
 * only continuous events are filtered; otherwise discrete events are filtered
 * (a name present in both containers is removed only from `continuous_events`).
 * The emptied array is kept as `[]` rather than dropped (pinned by
 * `edit.test.ts`).
 *
 * @param model Model to remove event(s) from
 * @param name Event name to remove
 * @returns New model with matching event(s) removed
 * @throws EntityNotFoundError if no event with that name exists
 */
export function removeEvent(model: Model, name: string): Model {
  if (model.continuous_events?.some((e) => e.name === name)) {
    return {
      ...model,
      continuous_events: model.continuous_events.filter((e) => e.name !== name),
    }
  }

  if (model.discrete_events?.some((e) => e.name === name)) {
    return {
      ...model,
      discrete_events: model.discrete_events.filter((e) => e.name !== name),
    }
  }

  throw new EntityNotFoundError('Event', name)
}

// =============================================================================
// Coupling Operations
// =============================================================================

/**
 * Add a coupling entry to an ESM file
 * @param file ESM file to add coupling to
 * @param entry Coupling entry to add
 * @returns New ESM file with coupling added
 */
export function addCoupling(file: EsmFile, entry: CouplingEntry): EsmFile {
  const coupling = file.coupling || []
  return {
    ...file,
    coupling: [...coupling, entry],
  }
}

/**
 * Remove a coupling entry from an ESM file by index
 * @param file ESM file to remove coupling from
 * @param index Index of coupling entry to remove
 * @returns New ESM file with coupling removed
 * @throws EntityNotFoundError if index is out of bounds
 */
export function removeCoupling(file: EsmFile, index: number): EsmFile {
  const coupling = file.coupling || []

  if (index < 0 || index >= coupling.length) {
    throw new EntityNotFoundError('Coupling', `index ${index}`)
  }

  // NOTE: empty-collection convention is deliberately drop-to-`undefined` here
  // (pinned by `edit.test.ts` — `coupling` is optional at the file root), which
  // differs from `removeEvent`/`removeEquation` that keep an emptied `[]` (also
  // test-pinned). The two shapes cannot be unified without breaking a pinned
  // test, so each op keeps its established, tested convention.
  const newCoupling = coupling.filter((_, i) => i !== index)
  return {
    ...file,
    coupling: newCoupling.length > 0 ? newCoupling : undefined,
  }
}

/**
 * Compose two systems using a coupling entry
 * @param file ESM file
 * @param a First system name
 * @param b Second system name
 * @returns New ESM file with composition coupling added
 */
export function compose(file: EsmFile, a: string, b: string): EsmFile {
  const coupling: CouplingEntry = {
    type: 'operator_compose',
    systems: [a, b],
  }

  return addCoupling(file, coupling)
}

/**
 * Map a variable from one system to another with optional transformation
 * @param file ESM file
 * @param from Source variable reference
 * @param to Target variable reference
 * @param transform Optional transformation: one of the named transform strings,
 *   or an Expression operator node evaluated in the flattened coupled system's
 *   scope (esm-spec §8.6 — the regridding form)
 * @returns New ESM file with variable mapping coupling added
 */
export function mapVariable(
  file: EsmFile,
  from: string,
  to: string,
  transform: CouplingVariableMap['transform'] = 'param_to_var',
): EsmFile {
  const coupling: CouplingEntry = {
    type: 'variable_map',
    from,
    to,
    transform,
  }

  return addCoupling(file, coupling)
}

// =============================================================================
// File-level Operations
// =============================================================================

/**
 * Merge two ESM files
 * @param fileA First ESM file
 * @param fileB Second ESM file
 * @returns New ESM file with merged content
 */
export function merge(fileA: EsmFile, fileB: EsmFile): EsmFile {
  return {
    ...fileA,
    models: {
      ...fileA.models,
      ...fileB.models,
    },
    reaction_systems: {
      ...fileA.reaction_systems,
      ...fileB.reaction_systems,
    },
    data_loaders: {
      ...fileA.data_loaders,
      ...fileB.data_loaders,
    },
    coupling: [...(fileA.coupling || []), ...(fileB.coupling || [])],
  }
}

/**
 * Extract a specific component from an ESM file into a new file
 * @param file ESM file to extract from
 * @param componentName Name of the component to extract
 * @returns New ESM file containing only the specified component
 * @throws EntityNotFoundError if component not found
 */
export function extract(file: EsmFile, componentName: string): EsmFile {
  const extracted: EsmFile = {
    esm: file.esm,
    metadata: file.metadata,
  }

  // Check models
  if (file.models && componentName in file.models) {
    extracted.models = { [componentName]: file.models[componentName] }
    return extracted
  }

  // Check reaction systems
  if (file.reaction_systems && componentName in file.reaction_systems) {
    extracted.reaction_systems = { [componentName]: file.reaction_systems[componentName] }
    return extracted
  }

  // Check data loaders
  if (file.data_loaders && componentName in file.data_loaders) {
    extracted.data_loaders = { [componentName]: file.data_loaders[componentName] }
    return extracted
  }

  throw new EntityNotFoundError('Component', componentName)
}

/**
 * Derive ODEs from reaction systems (delegates to reactions.ts)
 * @param system ReactionSystem to derive ODEs from
 * @returns Model with derived ODEs
 */
export { deriveODEs } from './reactions.js'

// =============================================================================
// Utility Functions
// =============================================================================

/**
 * Enumerate every EXPRESSION read-site in a model, in a single documented
 * order, and report each to `visit(expr, site)` with a human-readable location
 * label (used verbatim in `VariableInUseError` reference lists).
 *
 * This is the shared, read-side definition of "a model's expression sites"; it
 * MUST stay in lockstep with the write-side set rewritten by
 * `substituteInModel` (substitute.ts) so `removeVariable` (which scans these
 * sites) and `renameVariable` (which rewrites them) can never disagree on where
 * a variable may appear. Component/equation/variable walking is delegated to
 * `traverse.js`; each yielded value is an `Expression`-typed child that the
 * caller walks with the expression utilities.
 *
 * Sites, in order: equation `lhs`/`rhs`; observed-variable `expression`;
 * continuous-event `conditions[]`, `affects[].rhs`, `affect_neg[].rhs`;
 * discrete-event condition-`trigger.expression`, `affects[].rhs`; then, recursed
 * with a dotted `prefix`, every inline-model subsystem (reference stubs and
 * data loaders are opaque leaves, skipped). Affect `lhs` targets are `string`
 * names, not expression sites, and are handled by the caller.
 */
function forEachModelExpressionSite(
  model: Model,
  visit: (expr: Expr, site: string) => void,
  prefix = '',
): void {
  forEachEquation(model, (equation, i) => {
    visit(equation.lhs, `${prefix}equation ${i}`)
    visit(equation.rhs, `${prefix}equation ${i}`)
  })

  forEachModelVariable(model, (variable, name) => {
    if (variable.expression !== undefined) {
      visit(variable.expression, `${prefix}variable ${name} expression`)
    }
  })

  for (const [i, event] of (model.continuous_events ?? []).entries()) {
    for (const condition of event.conditions ?? []) {
      visit(condition, `${prefix}continuous_event ${i} condition`)
    }
    for (const [j, affect] of (event.affects ?? []).entries()) {
      visit(affect.rhs as Expr, `${prefix}continuous_event ${i} affect ${j}`)
    }
    if (Array.isArray(event.affect_neg)) {
      for (const [j, affect] of event.affect_neg.entries()) {
        visit(affect.rhs as Expr, `${prefix}continuous_event ${i} affect_neg ${j}`)
      }
    }
  }

  for (const [i, event] of (model.discrete_events ?? []).entries()) {
    if (event.trigger?.type === 'condition') {
      visit(event.trigger.expression, `${prefix}discrete_event ${i} trigger`)
    }
    for (const [j, affect] of (event.affects ?? []).entries()) {
      visit(affect.rhs as Expr, `${prefix}discrete_event ${i} affect ${j}`)
    }
  }

  for (const [name, subsystem] of Object.entries(model.subsystems ?? {})) {
    if (!isReferenceStub(subsystem)) {
      forEachModelExpressionSite(subsystem as Model, visit, `${prefix}${name}.`)
    }
  }
}

/**
 * Check if an expression references a specific variable.
 *
 * Recursion is delegated to the shared `forEachChild` walker (expression.ts),
 * so EVERY expression-bearing field is covered — aggregate `expr`/`filter`,
 * integral bounds, `makearray` values, `table_lookup` axes, etc. — not just
 * `args`.
 *
 * @param expr Expression to check
 * @param variableName Variable name to look for
 * @returns True if the expression references the variable
 */
function referencesVariable(expr: Expr, variableName: string): boolean {
  if (typeof expr === 'string') {
    // A scoped reference like "Model.Sub.var" references the variable when
    // one of its dot-separated segments matches exactly. Substring matching
    // would falsely match "x" against "prefix.xy".
    return expr === variableName || (expr.includes('.') && expr.split('.').includes(variableName))
  }

  if (typeof expr === 'number' || isNumericLiteral(expr)) {
    return false
  }

  if (isExprNode(expr)) {
    let found = false
    forEachChild(expr, (child) => {
      if (!found && referencesVariable(child, variableName)) found = true
    })
    return found
  }

  return false
}
