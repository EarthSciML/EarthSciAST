/**
 * Coupled System Flattening for the ESM format
 *
 * Transforms a multi-system ESM file into a single unified flattened system
 * by namespacing all variables with their source system prefix and processing
 * coupling entries to produce a unified equation set.
 */

import type {
  EsmFile,
  Model,
  ReactionSystem,
  Expression,
  ExpressionNode,
  CouplingEntry,
} from './types.js'
import { numericValue } from './numeric-literal.js'
import { expandCouplingImports, type CouplingImportOptions } from './coupling-imports.js'

/** Options for {@link flatten}. Only needed when the file uses `coupling_import`. */
export type FlattenOptions = CouplingImportOptions

/**
 * A single equation in the flattened system, with dot-namespaced variable names.
 */
export interface FlattenedEquation {
  /** Dot-namespaced LHS variable name (e.g., "Atmos.O3") */
  lhs: string
  /** Expression string with namespaced references */
  rhs: string
  /** Name of the source system this equation originated from */
  sourceSystem: string
}

/**
 * Metadata describing the origin of the flattened system.
 */
export interface FlattenMetadata {
  /** Names of all source systems that were flattened */
  sourceSystems: string[]
  /** Human-readable descriptions of coupling rules applied */
  couplingRules: string[]
}

/**
 * A fully flattened representation of a coupled ESM system.
 */
export interface FlattenedSystem {
  /** All state variable names (dot-namespaced) */
  stateVariables: string[]
  /** All parameter names (dot-namespaced) */
  parameters: string[]
  /** All brownian (Wiener) noise variables (dot-namespaced). Any brownian => SDE system. */
  brownianVariables: string[]
  /** Observed/derived variables: namespaced name -> expression string */
  variables: Record<string, string>
  /** All equations from all systems, with namespaced references */
  equations: FlattenedEquation[]
  /** Provenance metadata */
  metadata: FlattenMetadata
}

/**
 * Flatten a multi-system ESM file into a single unified system.
 *
 * The algorithm:
 * 1. Iterates over all models and reaction_systems in the file
 * 2. Namespaces all variables with their system name prefix (dot notation)
 * 3. Processes coupling entries to produce variable mappings and connector equations
 * 4. Returns a unified flattened system
 *
 * @param file - The ESM file to flatten
 * @returns A FlattenedSystem with all variables namespaced and equations unified
 */
export function flatten(file: EsmFile, options: FlattenOptions = {}): FlattenedSystem {
  const stateVariables: string[] = []
  const parameters: string[] = []
  const brownianVariables: string[] = []
  const variables: Record<string, string> = {}
  const equations: FlattenedEquation[] = []
  const sourceSystems: string[] = []
  const couplingRules: string[] = []

  // 1. Process all models (unresolved SubsystemRef entries carry no
  // variables or equations — flattening them is a no-op, so skip them,
  // but still record the system name)
  if (file.models) {
    for (const [systemName, model] of Object.entries(file.models)) {
      sourceSystems.push(systemName)
      if ('ref' in model) continue
      flattenModel(
        systemName,
        model as Model,
        stateVariables,
        parameters,
        brownianVariables,
        variables,
        equations,
      )
    }
  }

  // 2. Process all reaction systems
  if (file.reaction_systems) {
    for (const [systemName, rs] of Object.entries(file.reaction_systems)) {
      sourceSystems.push(systemName)
      flattenReactionSystem(systemName, rs, stateVariables, parameters, variables, equations)
    }
  }

  // 3. Expand coupling_import entries (esm-spec §10.10.3), then process the
  // resulting coupling sequence. A file with no coupling_import entries yields
  // its `coupling` array verbatim and needs no options.
  const coupling = expandCouplingImports(file, options)
  if (coupling) {
    for (const entry of coupling) {
      processCouplingEntry(entry, equations, variables, couplingRules)
    }
  }

  return {
    stateVariables,
    parameters,
    brownianVariables,
    variables,
    equations,
    metadata: {
      sourceSystems,
      couplingRules,
    },
  }
}

/**
 * Flatten a single Model and its subsystems into the accumulator arrays.
 */
function flattenModel(
  prefix: string,
  model: Model,
  stateVariables: string[],
  parameters: string[],
  brownianVariables: string[],
  variables: Record<string, string>,
  equations: FlattenedEquation[],
): void {
  // Collect the set of variable names in this model for namespacing expressions
  const localNames = new Set<string>(Object.keys(model.variables || {}))

  // Process variables
  for (const [varName, variable] of Object.entries(model.variables || {})) {
    const namespacedName = `${prefix}.${varName}`

    switch (variable.type) {
      case 'state':
        stateVariables.push(namespacedName)
        break
      case 'parameter':
        parameters.push(namespacedName)
        break
      case 'brownian':
        brownianVariables.push(namespacedName)
        break
      case 'observed':
        if (variable.expression !== undefined) {
          variables[namespacedName] = namespaceExpression(variable.expression, prefix, localNames)
        }
        break
    }
  }

  // Process equations
  for (const eq of model.equations || []) {
    equations.push({
      lhs: namespaceExpression(eq.lhs, prefix, localNames),
      rhs: namespaceExpression(eq.rhs, prefix, localNames),
      sourceSystem: prefix,
    })
  }

  // Recursively process inline-model subsystems (data loaders and
  // unresolved refs carry no equations)
  if (model.subsystems) {
    for (const [subName, subModel] of Object.entries(model.subsystems)) {
      if ('ref' in subModel || 'kind' in subModel) continue
      flattenModel(
        `${prefix}.${subName}`,
        subModel as Model,
        stateVariables,
        parameters,
        brownianVariables,
        variables,
        equations,
      )
    }
  }
}

/**
 * Flatten a single ReactionSystem and its subsystems into the accumulator arrays.
 */
function flattenReactionSystem(
  prefix: string,
  rs: ReactionSystem,
  stateVariables: string[],
  parameters: string[],
  variables: Record<string, string>,
  equations: FlattenedEquation[],
): void {
  // Collect local names for namespacing
  const localNames = new Set<string>([
    ...Object.keys(rs.species || {}),
    ...Object.keys(rs.parameters || {}),
  ])

  // Species are state variables
  for (const speciesName of Object.keys(rs.species || {})) {
    stateVariables.push(`${prefix}.${speciesName}`)
  }

  // Parameters
  for (const paramName of Object.keys(rs.parameters || {})) {
    parameters.push(`${prefix}.${paramName}`)
  }

  // Convert reactions to equations
  for (const reaction of rs.reactions || []) {
    const rateStr = namespaceExpression(reaction.rate, prefix, localNames)

    // For each product, add rate * stoichiometry
    if (reaction.products) {
      for (const product of reaction.products) {
        const lhs = `${prefix}.${product.species}`
        const stoich = product.stoichiometry
        const rhsExpr = stoich === 1 ? rateStr : `${stoich} * ${rateStr}`
        equations.push({
          lhs,
          rhs: rhsExpr,
          sourceSystem: prefix,
        })
      }
    }

    // For each substrate, subtract rate * stoichiometry
    if (reaction.substrates) {
      for (const substrate of reaction.substrates) {
        const lhs = `${prefix}.${substrate.species}`
        const stoich = substrate.stoichiometry
        const rhsExpr = stoich === 1 ? `-${rateStr}` : `-${stoich} * ${rateStr}`
        equations.push({
          lhs,
          rhs: rhsExpr,
          sourceSystem: prefix,
        })
      }
    }
  }

  // Process constraint equations if present
  if (rs.constraint_equations) {
    for (const eq of rs.constraint_equations) {
      equations.push({
        lhs: namespaceExpression(eq.lhs, prefix, localNames),
        rhs: namespaceExpression(eq.rhs, prefix, localNames),
        sourceSystem: prefix,
      })
    }
  }

  // Recursively process inline subsystems (unresolved refs are skipped)
  if (rs.subsystems) {
    for (const [subName, subRs] of Object.entries(rs.subsystems)) {
      if ('ref' in subRs) continue
      flattenReactionSystem(
        `${prefix}.${subName}`,
        subRs as ReactionSystem,
        stateVariables,
        parameters,
        variables,
        equations,
      )
    }
  }
}

/**
 * Process a single coupling entry and add resulting equations/mappings.
 */
function processCouplingEntry(
  entry: CouplingEntry,
  equations: FlattenedEquation[],
  variables: Record<string, string>,
  couplingRules: string[],
): void {
  switch (entry.type) {
    case 'operator_compose': {
      const [sys1, sys2] = entry.systems
      let ruleDesc = `operator_compose(${sys1}, ${sys2})`

      if (entry.translate) {
        for (const [from, target] of Object.entries(entry.translate)) {
          const targetVar = typeof target === 'string' ? target : target.var
          const factor =
            typeof target === 'object' && target.factor !== undefined ? target.factor : 1
          const namespacedFrom = `${sys1}.${from}`
          const namespacedTo = `${sys2}.${targetVar}`

          if (factor !== 1) {
            variables[namespacedTo] = `${factor} * ${namespacedFrom}`
          } else {
            variables[namespacedTo] = namespacedFrom
          }
        }
        ruleDesc += ` with translations`
      }

      couplingRules.push(ruleDesc)
      break
    }

    case 'couple': {
      const [sys1, sys2] = entry.systems
      const ruleDesc = `couple(${sys1}, ${sys2})`

      for (const connEq of entry.connector.equations) {
        const exprStr =
          connEq.expression !== undefined ? expressionToString(connEq.expression) : connEq.from

        equations.push({
          lhs: connEq.to,
          rhs: `${connEq.transform}(${exprStr})`,
          sourceSystem: `coupling(${sys1},${sys2})`,
        })
      }

      couplingRules.push(ruleDesc)
      break
    }

    case 'variable_map': {
      if (typeof entry.transform === 'object' && entry.transform !== null) {
        // Expression transform (esm-spec §8.6): the mapped value IS the
        // expression, whose references are already fully scoped — render it
        // with the shared coupling-scope printer (no namespacing).
        variables[entry.to] = expressionToString(entry.transform as Expression)
        couplingRules.push(`variable_map(${entry.from} -> ${entry.to}, expression)`)
        break
      }
      const ruleDesc = `variable_map(${entry.from} -> ${entry.to}, ${entry.transform})`
      if (entry.transform === 'conversion_factor' && entry.factor !== undefined) {
        variables[entry.to] = `${entry.factor} * ${entry.from}`
      } else {
        variables[entry.to] = entry.from
      }
      couplingRules.push(ruleDesc)
      break
    }

    case 'callback': {
      couplingRules.push(`callback(${entry.callback_id})`)
      break
    }

    case 'event': {
      const name = entry.name || 'unnamed'
      couplingRules.push(`event(${name}, ${entry.event_type})`)
      break
    }
  }
}

/**
 * Convert an Expression AST to a string representation, namespacing local variable
 * references with the given prefix.
 */
function namespaceExpression(expr: Expression, prefix: string, localNames: Set<string>): string {
  const n = numericValue(expr)
  if (n !== undefined) {
    return String(n)
  }

  if (typeof expr === 'string') {
    // If it's a local variable, namespace it
    if (localNames.has(expr)) {
      return `${prefix}.${expr}`
    }
    // If it already has a dot (scoped reference), return as-is
    if (expr.includes('.')) {
      return expr
    }
    // Special variable names like "t" (time) are left unnamespaced
    return expr
  }

  // ExpressionNode
  const node = expr as ExpressionNode
  return expressionNodeToString(node, prefix, localNames)
}

/**
 * Convert an ExpressionNode to a string with namespaced variable references.
 */
function expressionNodeToString(
  node: ExpressionNode,
  prefix: string,
  localNames: Set<string>,
): string {
  const args = node.args.map((arg) => namespaceExpression(arg, prefix, localNames))

  // Binary infix operators
  const infixOps = new Set(['+', '-', '*', '/', '^', '>', '<', '>=', '<=', '==', '!=', 'and', 'or'])

  if (infixOps.has(node.op)) {
    if (args.length === 1 && node.op === '-') {
      return `(-${args[0]})`
    }
    return `(${args.join(` ${node.op} `)})`
  }

  // D (derivative) operator
  if (node.op === 'D') {
    const wrt = node.wrt || 't'
    return `D(${args[0]}, ${wrt})`
  }

  // Spatial operators
  if (node.op === 'grad' || node.op === 'div' || node.op === 'laplacian') {
    const dim = node.dim ? `, ${node.dim}` : ''
    return `${node.op}(${args[0]}${dim})`
  }

  // ifelse
  if (node.op === 'ifelse') {
    return `ifelse(${args.join(', ')})`
  }

  // not (unary)
  if (node.op === 'not') {
    return `not(${args[0]})`
  }

  // Pre operator
  if (node.op === 'Pre') {
    return `Pre(${args[0]})`
  }

  // All other functions: fn(arg1, arg2, ...)
  return `${node.op}(${args.join(', ')})`
}

/**
 * Convert a raw Expression to string without namespacing (used for coupling entries
 * where variables are already scoped).
 */
function expressionToString(expr: Expression): string {
  const n = numericValue(expr)
  if (n !== undefined) {
    return String(n)
  }
  if (typeof expr === 'string') {
    return expr
  }
  // ExpressionNode - use empty prefix and empty local names
  return expressionNodeToString(expr as ExpressionNode, '', new Set())
}
