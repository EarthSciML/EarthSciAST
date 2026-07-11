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
import { forEachComponent, forEachModelVariable } from './traverse.js'
import { OPS } from './op-registry.js'

/** Options for {@link flatten}. Only needed when the file uses `coupling_import`. */
export type FlattenOptions = CouplingImportOptions

/**
 * A single equation in the flattened system, with dot-namespaced variable names.
 */
export interface FlattenedEquation {
  /** Dot-namespaced LHS variable name (e.g., "Atmos.O3") */
  lhs: string
  /**
   * Expression string with namespaced references.
   *
   * For equations produced from a `couple` connector, the string uses a
   * `transform(expr)` pseudo-function convention: the connector's `transform`
   * (`"additive"` / `"multiplicative"` / `"replacement"`) is emitted as the
   * function name wrapping the (already-scoped) connector expression — e.g.
   * `additive(A.x)`. These are provenance/intent markers, not scalar operators
   * in {@link OPS}; a downstream consumer interprets the wrapper.
   */
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
 * The single mutable accumulator threaded through the flatten helpers.
 *
 * It holds every growing output of a flatten run. Passing one object (instead
 * of the historical four positional `string[]` params plus maps, which were
 * transposition-prone and differed between {@link flattenModel} and
 * {@link flattenReactionSystem}) means each helper touches exactly the fields
 * it needs and the field↔argument mapping cannot silently drift.
 */
interface FlattenAccumulator {
  /** All state variable names (dot-namespaced). */
  stateVariables: string[]
  /** All parameter names (dot-namespaced). */
  parameters: string[]
  /** All brownian (Wiener) noise variable names (dot-namespaced). */
  brownianVariables: string[]
  /** Observed/derived variables: namespaced name -> expression string. */
  variables: Record<string, string>
  /** All equations from all systems, with namespaced references. */
  equations: FlattenedEquation[]
  /** Names of the top-level source systems, in file order. */
  sourceSystems: string[]
  /** Human-readable descriptions of the coupling rules applied. */
  couplingRules: string[]
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
  const acc: FlattenAccumulator = {
    stateVariables: [],
    parameters: [],
    brownianVariables: [],
    variables: {},
    equations: [],
    sourceSystems: [],
    couplingRules: [],
  }

  // 1 & 2. Walk every model and reaction system (and, recursively, their inline
  // subsystems) through the shared `traverse.js` policy, so subsystem descent
  // and reference-stub skipping are defined in exactly ONE place (previously
  // re-implemented divergently here, in graph.ts, and in units.ts). Reference
  // stubs — `{ref}` includes and `{kind}` data loaders — are visited as leaves
  // (`isReference`) and never descended into; they carry no variables or
  // equations, so flattening them is a no-op. Top-level systems are still
  // recorded in `sourceSystems`; a top-level entry is one whose composed
  // `scopedName` equals its own `name` (subsystems gain a dotted prefix).
  forEachComponent(
    file,
    (visit) => {
      if (visit.scopedName === visit.name) acc.sourceSystems.push(visit.name)
      if (visit.isReference) return
      if (visit.kind === 'models') {
        flattenModel(acc, visit.scopedName, visit.component as Model)
      } else {
        flattenReactionSystem(acc, visit.scopedName, visit.component as ReactionSystem)
      }
    },
    { recurse: true },
  )

  // 3. Expand coupling_import entries (esm-spec §10.10.3), then process the
  // resulting coupling sequence. A file with no coupling_import entries yields
  // its `coupling` array verbatim and needs no options.
  const coupling = expandCouplingImports(file, options)
  if (coupling) {
    for (const entry of coupling) {
      processCouplingEntry(acc, entry)
    }
  }

  return {
    stateVariables: acc.stateVariables,
    parameters: acc.parameters,
    brownianVariables: acc.brownianVariables,
    variables: acc.variables,
    equations: acc.equations,
    metadata: {
      sourceSystems: acc.sourceSystems,
      couplingRules: acc.couplingRules,
    },
  }
}

/**
 * Flatten a single Model into the accumulator. Subsystem descent is driven by
 * {@link forEachComponent} in {@link flatten}, so this handles only THIS
 * model's own variables and equations.
 */
function flattenModel(acc: FlattenAccumulator, prefix: string, model: Model): void {
  // Collect the set of variable names in this model for namespacing expressions
  const localNames = new Set<string>(Object.keys(model.variables || {}))

  // Process variables
  forEachModelVariable(model, (variable, varName) => {
    const namespacedName = `${prefix}.${varName}`

    switch (variable.type) {
      case 'state':
        acc.stateVariables.push(namespacedName)
        break
      case 'parameter':
        acc.parameters.push(namespacedName)
        break
      case 'brownian':
        acc.brownianVariables.push(namespacedName)
        break
      case 'observed':
        if (variable.expression !== undefined) {
          acc.variables[namespacedName] = namespaceExpression(
            variable.expression,
            prefix,
            localNames,
          )
        }
        break
    }
  })

  // Process equations
  for (const eq of model.equations || []) {
    acc.equations.push({
      lhs: namespaceExpression(eq.lhs, prefix, localNames),
      rhs: namespaceExpression(eq.rhs, prefix, localNames),
      sourceSystem: prefix,
    })
  }
}

/**
 * Flatten a single ReactionSystem into the accumulator. Subsystem descent is
 * driven by {@link forEachComponent} in {@link flatten}, so this handles only
 * THIS system's own species, parameters, reactions, and constraint equations.
 */
function flattenReactionSystem(acc: FlattenAccumulator, prefix: string, rs: ReactionSystem): void {
  // Collect local names for namespacing
  const localNames = new Set<string>([
    ...Object.keys(rs.species || {}),
    ...Object.keys(rs.parameters || {}),
  ])

  // Species are state variables
  for (const speciesName of Object.keys(rs.species || {})) {
    acc.stateVariables.push(`${prefix}.${speciesName}`)
  }

  // Parameters
  for (const paramName of Object.keys(rs.parameters || {})) {
    acc.parameters.push(`${prefix}.${paramName}`)
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
        acc.equations.push({
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
        acc.equations.push({
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
      acc.equations.push({
        lhs: namespaceExpression(eq.lhs, prefix, localNames),
        rhs: namespaceExpression(eq.rhs, prefix, localNames),
        sourceSystem: prefix,
      })
    }
  }
}

/**
 * Process a single coupling entry and add resulting equations/mappings.
 */
function processCouplingEntry(acc: FlattenAccumulator, entry: CouplingEntry): void {
  const { variables, equations, couplingRules } = acc
  switch (entry.type) {
    case 'operator_compose': {
      // `operator_compose.systems` is schema-pinned to EXACTLY two entries
      // (esm-schema `[string, string]`, minItems/maxItems 2), so destructuring
      // the pair is complete — there is no chain to iterate. (graph.ts loops
      // over consecutive pairs only as a defensive generalization for its
      // structural edge view; a well-formed entry always yields one pair.)
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
      // `couple.systems` is likewise schema-pinned to exactly two entries.
      const [sys1, sys2] = entry.systems
      const ruleDesc = `couple(${sys1}, ${sys2})`

      for (const connEq of entry.connector.equations) {
        const exprStr =
          connEq.expression !== undefined ? expressionToString(connEq.expression) : connEq.from

        // The connector's `transform` (additive/multiplicative/replacement) is
        // emitted as a `transform(expr)` pseudo-function wrapper — see the
        // FlattenedEquation.rhs doc for this convention.
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
      // KNOWN LIMITATION (documented, output intentionally unchanged): only the
      // `conversion_factor` transform consumes `entry.factor` (as `factor *
      // from`). The `additive` and `multiplicative` transforms — and any
      // `factor` supplied with them — currently collapse to an identity map
      // (`to = from`), silently dropping the scaling/offset. The flattened
      // rhs strings for those transforms are NOT yet spec-pinned, so emitting
      // one here would introduce untested output; handling them is deferred to
      // a wave that pins their string form. `param_to_var`/`identity` are
      // correctly identity maps.
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
 * The infix operators this printer renders as `(a op b)`.
 *
 * op-registry.ts (`OPS[op].precedence`) is the single source of truth for
 * which operators are infix: an op is infix iff it carries a `precedence`.
 * This printer fully parenthesizes, so it needs the membership set but never
 * the precedence VALUES. Two precedence-bearing ops are deliberately excluded
 * because this printer renders them specially rather than infix: `not` (a
 * unary op emitted as `not(x)` below) and `=` (emitted via the generic
 * `fn(args...)` fallback). Excluding exactly those reproduces the historical
 * set (`+ - * / ^ > < >= <= == != and or`), so emitted rhs strings are
 * byte-identical — while new infix ops added to op-registry now flow through
 * automatically.
 */
const INFIX_OPS: ReadonlySet<string> = new Set(
  Object.entries(OPS)
    .filter(([op, info]) => info.precedence !== undefined && op !== 'not' && op !== '=')
    .map(([op]) => op),
)

/**
 * Convert an ExpressionNode to a string with namespaced variable references.
 */
function expressionNodeToString(
  node: ExpressionNode,
  prefix: string,
  localNames: Set<string>,
): string {
  const args = node.args.map((arg) => namespaceExpression(arg, prefix, localNames))

  if (INFIX_OPS.has(node.op)) {
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
