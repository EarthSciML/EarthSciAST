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
import { isNumericLiteral, numericValue } from './numeric-literal.js'

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

  // Check for references in equations
  const references: string[] = []

  if (model.equations) {
    for (let i = 0; i < model.equations.length; i++) {
      const equation = model.equations[i]
      if (referencesVariable(equation.lhs, name) || referencesVariable(equation.rhs, name)) {
        references.push(`equation ${i}`)
      }
    }
  }

  // Check for references in events
  if (model.continuous_events) {
    for (let i = 0; i < model.continuous_events.length; i++) {
      const event = model.continuous_events[i]
      for (const condition of event.conditions || []) {
        if (referencesVariable(condition, name)) {
          references.push(`continuous_event ${i} condition`)
          break
        }
      }
      if (event.affects) {
        for (let j = 0; j < event.affects.length; j++) {
          if (event.affects[j].lhs === name || referencesVariable(event.affects[j].rhs, name)) {
            references.push(`continuous_event ${i} affect ${j}`)
          }
        }
      }
    }
  }

  if (model.discrete_events) {
    for (let i = 0; i < model.discrete_events.length; i++) {
      const event = model.discrete_events[i]
      if (
        event.trigger?.type === 'condition' &&
        referencesVariable(event.trigger.expression, name)
      ) {
        references.push(`discrete_event ${i} trigger`)
      }
      if (event.affects) {
        for (let j = 0; j < event.affects.length; j++) {
          if (event.affects[j].lhs === name || referencesVariable(event.affects[j].rhs, name)) {
            references.push(`discrete_event ${i} affect ${j}`)
          }
        }
      }
    }
  }

  if (references.length > 0) {
    throw new VariableInUseError(name, references)
  }

  const { [name]: _removed, ...remainingVariables } = model.variables
  return {
    ...model,
    variables: remainingVariables,
  }
}

/**
 * Rename a variable throughout a model
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
    // Find equation by LHS
    indexToRemove = equations.findIndex((eq) => expressionsEqual(eq.lhs, indexOrLhs))
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
 * Apply substitutions to all equations in a model
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
  const reactionIndex = system.reactions.findIndex((r) => r.id === id)
  if (reactionIndex === -1) {
    throw new EntityNotFoundError('Reaction', id)
  }

  const newReactions = system.reactions.filter((r) => r.id !== id)
  if (newReactions.length === 0) {
    throw new Error('Cannot remove the last reaction from a reaction system')
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
 * Remove an event from a model by name
 * @param model Model to remove event from
 * @param name Event name to remove
 * @returns New model with event removed
 * @throws EntityNotFoundError if event not found
 */
export function removeEvent(model: Model, name: string): Model {
  let found = false
  const updatedModel = { ...model }

  // Try to remove from continuous events
  if (model.continuous_events) {
    const index = model.continuous_events.findIndex((e) => e.name === name)
    if (index !== -1) {
      updatedModel.continuous_events = model.continuous_events.filter((e) => e.name !== name)
      found = true
    }
  }

  // Try to remove from discrete events
  if (model.discrete_events && !found) {
    const index = model.discrete_events.findIndex((e) => e.name === name)
    if (index !== -1) {
      updatedModel.discrete_events = model.discrete_events.filter((e) => e.name !== name)
      found = true
    }
  }

  if (!found) {
    throw new EntityNotFoundError('Event', name)
  }

  return updatedModel
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
 * Check if an expression references a specific variable
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

  // ExpressionNode case
  const node = expr as any
  if (node.args && Array.isArray(node.args)) {
    return node.args.some((arg: Expr) => referencesVariable(arg, variableName))
  }

  return false
}

/**
 * Check if two expressions are structurally equal
 * @param a First expression
 * @param b Second expression
 * @returns True if expressions are equal
 */
function expressionsEqual(a: Expr, b: Expr): boolean {
  if (typeof a === 'string' || typeof b === 'string') {
    return typeof a === 'string' && typeof b === 'string' && a === b
  }

  // Numeric literals: compare by underlying value, treating plain numbers
  // and tagged NumericLiteral leaves as equal when they share a value.
  const na = numericValue(a)
  const nb = numericValue(b)
  if (na !== undefined || nb !== undefined) {
    return na !== undefined && nb !== undefined && Object.is(na, nb)
  }

  // ExpressionNode case
  const nodeA = a as any
  const nodeB = b as any

  if (nodeA.op !== nodeB.op) {
    return false
  }

  if (!nodeA.args && !nodeB.args) {
    return true
  }

  if (!nodeA.args || !nodeB.args || nodeA.args.length !== nodeB.args.length) {
    return false
  }

  return nodeA.args.every((arg: Expr, i: number) => expressionsEqual(arg, nodeB.args[i]))
}
