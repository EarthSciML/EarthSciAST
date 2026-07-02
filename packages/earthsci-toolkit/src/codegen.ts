/**
 * Code generation for the ESM format
 *
 * This module provides:
 * - In-language AST → JavaScript lowering (`compileExpression` /
 *   `evaluateExpression`) — the official ESS TypeScript runner per
 *   `AGENTS.md` "Official per-binding runners". A canonical-form
 *   `Expr` is lowered to a closure that takes a free-variable bindings
 *   map and returns the scalar numeric result.
 * - Self-contained script generation in target languages: Julia
 *   (ModelingToolkit / Catalyst / EarthSciMLBase / OrdinaryDiffEq) and
 *   Python (SymPy / earthsci_toolkit / SciPy).
 */

import type { Expr, EsmFile, Model, ReactionSystem, Expression, ExpressionNode, Equation, ModelVariable, Species, Reaction, ContinuousEvent, DiscreteEvent, CouplingEntry, Domain, DataLoader } from './types.js'
import { toAscii } from './pretty-print.js'
import { isNumericLiteral, numericValue } from './numeric-literal.js'
import { dispatchClosedFunction } from './registered_functions.js'

/**
 * Compiled expression closure produced by {@link compileExpression}.
 * Accepts a `bindings` map of free-variable name → numeric value and
 * returns the scalar result.
 */
export type CompiledExpression = (bindings: Map<string, number>) => number

/**
 * Rewrite-target ops (esm-spec §4.2, docs/rfcs/open-op-namespace-fixpoint-rewrite.md):
 * a spatial / right-hand-side `D`, and the `grad`/`div`/`laplacian` sugar ops.
 * They carry NO evaluator implementation — each MUST be lowered to an
 * `aggregate`/`makearray` stencil by a rewrite rule (§9.6) before evaluation.
 * This format ships no discretization rules (the std-lib lives in
 * EarthSciDiscretizations). One reaching the evaluator means no rule lowered it.
 */
const REWRITE_TARGET_OPS = new Set<string>(['D', 'grad', 'div', 'laplacian'])

/**
 * Error carrying the stable, cross-binding `unlowered_operator` diagnostic
 * (esm-spec §4.2 / §9.6.3 constraint 6 / §9.6.8). Raised when a rewrite-target
 * op reaches evaluation/compilation without having been lowered — the uniform
 * gate that supersedes the old per-binding UnreachableSpatialOperator /
 * UnsupportedDimensionality codes. Loading stays permissive (the op namespace
 * is open); the gate fires only at evaluation, mirroring the Julia `_compile`
 * gate in tree_walk.jl.
 */
export class UnloweredOperatorError extends Error {
  readonly code = 'unlowered_operator'
  constructor(message: string) {
    super(`[unlowered_operator] ${message}`)
    this.name = 'UnloweredOperatorError'
  }
}

/**
 * Lower a canonical-AST {@link Expr} into a JavaScript function for
 * in-process scalar evaluation. This is the official ESS TypeScript
 * runner entry point for evaluating an expression against a bindings
 * map (per AGENTS.md "Official per-binding runners" and audit
 * esm-rv3 §1.3 / bead esm-3r4).
 *
 * The walker rejects unlowered `enum` ops (lower via `lowerEnums()` at
 * load time) and array-valued `const` nodes (those are consumed by
 * container ops such as `interp.searchsorted` and `index`, not by
 * scalar evaluation).
 */
export function compileExpression(expr: Expr): CompiledExpression {
  return (bindings: Map<string, number>) => evalExprNode(expr, bindings)
}

/**
 * Compile and apply in one step. Equivalent to
 * `compileExpression(expr)(bindings)` but avoids allocating a closure
 * for one-shot callers (`simplify`'s constant-folding path,
 * fixed-point observed-variable resolution, unit-conversion
 * folding).
 */
export function evaluateExpression(expr: Expr, bindings: Map<string, number>): number {
  return evalExprNode(expr, bindings)
}

function evalExprNode(expr: Expr, bindings: Map<string, number>): number {
  if (typeof expr === 'number') {
    return expr
  } else if (isNumericLiteral(expr)) {
    return expr.value
  } else if (typeof expr === 'string') {
    if (bindings.has(expr)) {
      return bindings.get(expr)!
    }
    throw new Error(`Unbound variable: ${expr}`)
  } else if (typeof expr === 'object' && (expr as ExpressionNode).op) {
    const node = expr as any

    // const: inline literal — only meaningful as a scalar when its
    // value is a number; array-valued const nodes are extracted by
    // callers that consume them (e.g. interp.searchsorted's xs arg).
    if (node.op === 'const') {
      const v = node.value
      if (typeof v === 'number') return v
      if (Array.isArray(v)) {
        throw new Error('const node with array value cannot be evaluated as a scalar; arrays are consumed by container ops (e.g. interp.searchsorted, index)')
      }
      throw new Error(`const node with non-numeric value: ${typeof v}`)
    }

    // enum nodes should have been lowered to const at load time. If
    // we see one here, the file was evaluated before the lowering
    // pass ran.
    if (node.op === 'enum') {
      throw new Error("enum op encountered during evaluateExpression(); enum nodes must be lowered to 'const' integer nodes via lowerEnums() at load time")
    }

    // fn: closed function registry dispatch (esm-spec §9.2). Most
    // args evaluate to scalars; interp.searchsorted's second arg is
    // a const array that we extract WITHOUT evaluating it through
    // the scalar path.
    if (node.op === 'fn') {
      const fnName = node.name
      if (typeof fnName !== 'string') {
        throw new Error('fn op missing required string `name` field')
      }
      const fnArgs = node.args.map((arg: any) => {
        if (arg && typeof arg === 'object' && (arg as ExpressionNode).op === 'const' && Array.isArray((arg as any).value)) {
          return (arg as any).value
        }
        return evalExprNode(arg, bindings)
      })
      return dispatchClosedFunction(fnName, fnArgs)
    }

    // Rewrite-target op gate (esm-spec §4.2 / §9.6.8): a spatial/RHS `D` or a
    // grad/div/laplacian sugar op that reaches evaluation was never lowered to
    // a stencil. Fire the uniform `unlowered_operator` diagnostic BEFORE
    // evaluating args (mirrors the Julia `_compile` gate). Loading stays
    // permissive — the open namespace tolerates these ops until evaluation.
    if (typeof node.op === 'string' && REWRITE_TARGET_OPS.has(node.op)) {
      const wrt = node.op === 'D' && typeof node.wrt === 'string' ? ` (wrt=${node.wrt})` : ''
      throw new UnloweredOperatorError(
        `unlowered rewrite-target operator '${node.op}'${wrt} reached evaluation: ` +
          `it must be lowered to a stencil by a rewrite rule before evaluation ` +
          `(esm-spec §4.2 / §9.6.8). This format ships no discretization rules ` +
          `(they live in EarthSciDiscretizations).`,
      )
    }

    const args: number[] = node.args.map((arg: any) => evalExprNode(arg, bindings))

    switch (node.op) {
      case '+':
        return args.reduce((sum, val) => sum + val, 0)
      case '-':
        if (args.length === 1) return -args[0]
        return args.reduce((diff, val, idx) => idx === 0 ? val : diff - val)
      case '*':
        return args.reduce((prod, val) => prod * val, 1)
      case '/':
        if (args.length !== 2) throw new Error('Division requires exactly 2 arguments')
        if (args[1] === 0) throw new Error('Division by zero')
        return args[0] / args[1]
      case '^':
        if (args.length !== 2) throw new Error('Exponentiation requires exactly 2 arguments')
        return Math.pow(args[0], args[1])
      case 'exp':
        if (args.length !== 1) throw new Error('exp requires exactly 1 argument')
        return Math.exp(args[0])
      case 'log':
        if (args.length !== 1) throw new Error('log requires exactly 1 argument')
        if (args[0] <= 0) throw new Error('log argument must be positive')
        return Math.log(args[0])
      case 'log10':
        if (args.length !== 1) throw new Error('log10 requires exactly 1 argument')
        if (args[0] <= 0) throw new Error('log10 argument must be positive')
        return Math.log10(args[0])
      case 'sqrt':
        if (args.length !== 1) throw new Error('sqrt requires exactly 1 argument')
        if (args[0] < 0) throw new Error('sqrt argument must be non-negative')
        return Math.sqrt(args[0])
      case 'abs':
        if (args.length !== 1) throw new Error('abs requires exactly 1 argument')
        return Math.abs(args[0])
      case 'sin':
        if (args.length !== 1) throw new Error('sin requires exactly 1 argument')
        return Math.sin(args[0])
      case 'cos':
        if (args.length !== 1) throw new Error('cos requires exactly 1 argument')
        return Math.cos(args[0])
      case 'tan':
        if (args.length !== 1) throw new Error('tan requires exactly 1 argument')
        return Math.tan(args[0])
      case 'asin':
        if (args.length !== 1) throw new Error('asin requires exactly 1 argument')
        if (args[0] < -1 || args[0] > 1) throw new Error('asin argument must be in [-1, 1]')
        return Math.asin(args[0])
      case 'acos':
        if (args.length !== 1) throw new Error('acos requires exactly 1 argument')
        if (args[0] < -1 || args[0] > 1) throw new Error('acos argument must be in [-1, 1]')
        return Math.acos(args[0])
      case 'atan':
        if (args.length !== 1) throw new Error('atan requires exactly 1 argument')
        return Math.atan(args[0])
      case 'atan2':
        if (args.length !== 2) throw new Error('atan2 requires exactly 2 arguments')
        return Math.atan2(args[0], args[1])
      case 'sinh':
        if (args.length !== 1) throw new Error('sinh requires exactly 1 argument')
        return Math.sinh(args[0])
      case 'cosh':
        if (args.length !== 1) throw new Error('cosh requires exactly 1 argument')
        return Math.cosh(args[0])
      case 'tanh':
        if (args.length !== 1) throw new Error('tanh requires exactly 1 argument')
        return Math.tanh(args[0])
      case 'asinh':
        if (args.length !== 1) throw new Error('asinh requires exactly 1 argument')
        return Math.asinh(args[0])
      case 'acosh':
        if (args.length !== 1) throw new Error('acosh requires exactly 1 argument')
        if (args[0] < 1) throw new Error('acosh argument must be >= 1')
        return Math.acosh(args[0])
      case 'atanh':
        if (args.length !== 1) throw new Error('atanh requires exactly 1 argument')
        if (args[0] <= -1 || args[0] >= 1) throw new Error('atanh argument must be in (-1, 1)')
        return Math.atanh(args[0])
      case 'min':
        if (args.length < 2) throw new Error('min requires at least 2 arguments')
        return Math.min(...args)
      case 'max':
        if (args.length < 2) throw new Error('max requires at least 2 arguments')
        return Math.max(...args)
      case 'floor':
        if (args.length !== 1) throw new Error('floor requires exactly 1 argument')
        return Math.floor(args[0])
      case 'ceil':
        if (args.length !== 1) throw new Error('ceil requires exactly 1 argument')
        return Math.ceil(args[0])
      case 'sign':
        if (args.length !== 1) throw new Error('sign requires exactly 1 argument')
        return Math.sign(args[0])
      case '>':
        if (args.length !== 2) throw new Error('> requires exactly 2 arguments')
        return args[0] > args[1] ? 1 : 0
      case '<':
        if (args.length !== 2) throw new Error('< requires exactly 2 arguments')
        return args[0] < args[1] ? 1 : 0
      case '>=':
        if (args.length !== 2) throw new Error('>= requires exactly 2 arguments')
        return args[0] >= args[1] ? 1 : 0
      case '<=':
        if (args.length !== 2) throw new Error('<= requires exactly 2 arguments')
        return args[0] <= args[1] ? 1 : 0
      case '==':
        if (args.length !== 2) throw new Error('== requires exactly 2 arguments')
        return args[0] === args[1] ? 1 : 0
      case '!=':
        if (args.length !== 2) throw new Error('!= requires exactly 2 arguments')
        return args[0] !== args[1] ? 1 : 0
      case 'and':
        return args.every(x => x !== 0) ? 1 : 0
      case 'or':
        return args.some(x => x !== 0) ? 1 : 0
      case 'not':
        if (args.length !== 1) throw new Error('not requires exactly 1 argument')
        return args[0] === 0 ? 1 : 0
      case 'ifelse':
        if (args.length !== 3) throw new Error('ifelse requires exactly 3 arguments')
        return args[0] !== 0 ? args[1] : args[2]
      default:
        throw new Error(`Unsupported operator: ${node.op}`)
    }
  }

  throw new Error('Invalid expression type')
}

/**
 * Generate a self-contained Julia script from an ESM file
 * @param file ESM file to generate Julia code for
 * @returns Julia script as a string
 */
export function toJuliaCode(file: EsmFile): string {
  const lines: string[] = []

  // Header comment
  lines.push(`# Generated Julia script from ESM file`)
  lines.push(`# ESM version: ${file.esm}`)
  if (file.metadata?.title) {
    lines.push(`# Title: ${file.metadata.title}`)
  }
  if (file.metadata?.description) {
    lines.push(`# Description: ${file.metadata.description}`)
  }
  lines.push('')

  // Using statements
  lines.push('# Package imports')
  lines.push('using ModelingToolkit')
  lines.push('using Catalyst')
  lines.push('using EarthSciMLBase')
  lines.push('using OrdinaryDiffEq')
  lines.push('using Unitful')
  lines.push('')

  // Generate models
  if (file.models && Object.keys(file.models).length > 0) {
    lines.push('# Models')
    for (const [name, model] of Object.entries(file.models)) {
      lines.push(...generateModelCode(name, model))
      lines.push('')
    }
  }

  // Generate reaction systems
  if (file.reaction_systems && Object.keys(file.reaction_systems).length > 0) {
    lines.push('# Reaction Systems')
    for (const [name, reactionSystem] of Object.entries(file.reaction_systems)) {
      lines.push(...generateReactionSystemCode(name, reactionSystem))
      lines.push('')
    }
  }

  // Generate events
  if (file.events && Object.keys(file.events).length > 0) {
    lines.push('# Events')
    for (const [name, event] of Object.entries(file.events)) {
      lines.push(...generateEventCode(name, event))
      lines.push('')
    }
  }

  // Generate coupling code
  if (file.coupling && file.coupling.length > 0) {
    lines.push('# Coupling')
    for (const coupling of file.coupling) {
      lines.push(...generateCouplingCode(coupling))
    }
    lines.push('')
  }

  // Generate domain code
  if (file.domain) {
    lines.push('# Domain')
    lines.push(...generateDomainCode(file.domain))
    lines.push('')
  }

  // Generate data loaders code
  if (file.data_loaders && Object.keys(file.data_loaders).length > 0) {
    lines.push('# Data Loaders')
    for (const [name, dataLoader] of Object.entries(file.data_loaders)) {
      lines.push(...generateDataLoaderCode(name, dataLoader))
    }
    lines.push('')
  }

  return lines.join('\n')
}

/**
 * Generate a self-contained Python script from an ESM file
 * @param file ESM file to generate Python code for
 * @returns Python script as a string
 */
export function toPythonCode(file: EsmFile): string {
  const lines: string[] = []

  // Header comment
  lines.push(`# Generated Python script from ESM file`)
  lines.push(`# ESM version: ${file.esm}`)
  if (file.metadata?.title) {
    lines.push(`# Title: ${file.metadata.title}`)
  }
  if (file.metadata?.description) {
    lines.push(`# Description: ${file.metadata.description}`)
  }
  lines.push('')

  // Import statements
  lines.push('# Package imports')
  lines.push('import sympy as sp')
  lines.push('import earthsci_toolkit as esm')
  lines.push('import scipy')
  lines.push('from sympy import Function')
  lines.push('')

  // Generate models
  if (file.models && Object.keys(file.models).length > 0) {
    lines.push('# Models')
    for (const [name, model] of Object.entries(file.models)) {
      lines.push(...generatePythonModelCode(name, model))
      lines.push('')
    }
  }

  // Generate reaction systems
  if (file.reaction_systems && Object.keys(file.reaction_systems).length > 0) {
    lines.push('# Reaction Systems')
    for (const [name, reactionSystem] of Object.entries(file.reaction_systems)) {
      lines.push(...generatePythonReactionSystemCode(name, reactionSystem))
      lines.push('')
    }
  }

  // Generate simulation setup with actual default values
  lines.push('# Simulation setup')
  lines.push('tspan = (0, 10)  # time span')

  // Collect default values from all models and reaction systems
  const parameters: { [key: string]: any } = {}
  const initialConditions: { [key: string]: any } = {}

  // Collect from models
  if (file.models) {
    for (const model of Object.values(file.models)) {
      if (model.variables) {
        for (const [varName, variable] of Object.entries(model.variables)) {
          if (variable.type === 'parameter' && variable.default !== undefined) {
            parameters[varName] = variable.default
          } else if (variable.type === 'state' && variable.default !== undefined) {
            initialConditions[varName] = variable.default
          }
        }
      }
    }
  }

  // Collect from reaction systems
  if (file.reaction_systems) {
    for (const reactionSystem of Object.values(file.reaction_systems)) {
      if (reactionSystem.species) {
        for (const [speciesName, species] of Object.entries(reactionSystem.species)) {
          // Handle both "default" and "initial_value" properties, with "default" taking precedence
          const initialValue = species.default !== undefined ? species.default : (species as any).initial_value
          if (initialValue !== undefined) {
            initialConditions[speciesName] = initialValue
          }
        }
      }
    }
  }

  // Generate parameters dictionary
  if (Object.keys(parameters).length > 0) {
    lines.push('parameters = {')
    for (const [name, value] of Object.entries(parameters)) {
      lines.push(`    "${name}": ${value},`)
    }
    lines.push('}')
  } else {
    lines.push('parameters = {}  # no parameter defaults specified')
  }

  // Generate initial conditions dictionary
  if (Object.keys(initialConditions).length > 0) {
    lines.push('initial_conditions = {')
    for (const [name, value] of Object.entries(initialConditions)) {
      lines.push(`    "${name}": ${value},`)
    }
    lines.push('}')
  } else {
    lines.push('initial_conditions = {}  # no initial condition defaults specified')
  }

  lines.push('')
  lines.push('# result = esm.simulate(tspan=tspan, parameters=parameters, initial_conditions=initial_conditions)')
  lines.push('')

  // Generate coupling, domain, and data loader code
  if (file.coupling && file.coupling.length > 0) {
    lines.push('# Coupling')
    for (const coupling of file.coupling) {
      lines.push(...generatePythonCouplingCode(coupling))
    }
    lines.push('')
  }

  if (file.domain) {
    lines.push('# Domain')
    lines.push(...generatePythonDomainCode(file.domain))
    lines.push('')
  }

  // Generate data loaders code
  if (file.data_loaders && Object.keys(file.data_loaders).length > 0) {
    lines.push('# Data Loaders')
    for (const [name, dataLoader] of Object.entries(file.data_loaders)) {
      lines.push(...generatePythonDataLoaderCode(name, dataLoader))
    }
    lines.push('')
  }

  return lines.join('\n')
}

/**
 * Generate Julia code for a model
 */
function generateModelCode(name: string, model: Model): string[] {
  const lines: string[] = []

  lines.push(`# Model: ${name}`)

  // Collect state variables and parameters
  const stateVars: (ModelVariable & { name: string })[] = []
  const parameters: (ModelVariable & { name: string })[] = []

  if (model.variables) {
    for (const [varName, variable] of Object.entries(model.variables)) {
      if (variable.type === 'state') {
        stateVars.push({ ...variable, name: varName })
      } else if (variable.type === 'parameter') {
        parameters.push({ ...variable, name: varName })
      }
    }
  }

  // Generate @variables declaration
  if (stateVars.length > 0) {
    const varDecls = stateVars.map(v => formatVariableDeclaration(v, v.name)).join(' ')
    lines.push(`@variables t ${varDecls}`)
  }

  // Generate @parameters declaration
  if (parameters.length > 0) {
    const paramDecls = parameters.map(v => formatVariableDeclaration(v, v.name)).join(' ')
    lines.push(`@parameters ${paramDecls}`)
  }

  // Generate equations
  if (model.equations && model.equations.length > 0) {
    lines.push('')
    lines.push('eqs = [')
    for (const equation of model.equations) {
      lines.push(`    ${formatEquation(equation)},`)
    }
    lines.push(']')
  }

  // Generate @named ODESystem
  lines.push('')
  lines.push(`@named ${name}_system = ODESystem(eqs)`)

  return lines
}

/**
 * Generate Julia code for a reaction system
 */
function generateReactionSystemCode(name: string, reactionSystem: ReactionSystem): string[] {
  const lines: string[] = []

  lines.push(`# Reaction System: ${name}`)

  // Generate @species declaration
  if (reactionSystem.species && Object.keys(reactionSystem.species).length > 0) {
    const speciesDecls = Object.entries(reactionSystem.species)
      .map(([name, s]) => formatSpeciesDeclaration(s, name)).join(' ')
    lines.push(`@species ${speciesDecls}`)
  }

  // Generate @parameters for reaction parameters
  const reactionParams = new Set<string>()
  if (reactionSystem.reactions) {
    for (const reaction of Object.values(reactionSystem.reactions)) {
      // Extract parameter names from rate expressions
      if (reaction.rate) {
        const paramNames = extractParameterNames(reaction.rate)
        paramNames.forEach(p => reactionParams.add(p))
      }
    }
  }

  if (reactionParams.size > 0) {
    lines.push(`@parameters ${Array.from(reactionParams).join(' ')}`)
  }

  // Generate reactions
  if (reactionSystem.reactions && Object.keys(reactionSystem.reactions).length > 0) {
    lines.push('')
    lines.push('rxs = [')
    for (const reaction of Object.values(reactionSystem.reactions)) {
      lines.push(`    ${formatReaction(reaction)},`)
    }
    lines.push(']')
  }

  // Generate @named ReactionSystem
  lines.push('')
  lines.push(`@named ${name}_system = ReactionSystem(rxs)`)

  return lines
}

/**
 * Generate Julia code for events
 */
function generateEventCode(name: string, event: ContinuousEvent | DiscreteEvent): string[] {
  const lines: string[] = []

  if ('condition' in event) {
    // Continuous event
    lines.push(`# Continuous Event: ${name}`)
    const condition = formatExpression(event.condition)
    const affect = formatAffect(event.affect)
    lines.push(`${name}_event = SymbolicContinuousCallback(${condition}, ${affect})`)
  } else {
    // Discrete event
    lines.push(`# Discrete Event: ${name}`)
    const trigger = formatDiscreteTrigger(event.trigger)
    const affect = formatAffect(event.affect)
    lines.push(`${name}_event = DiscreteCallback(${trigger}, ${affect})`)
  }

  return lines
}

/**
 * Generate coupling code for Julia
 */
function generateCouplingCode(coupling: CouplingEntry): string[] {
  const lines: string[] = []

  // Generate comment first for clarity
  lines.push(`# Coupling ${coupling.type}: ${coupling.from} -> ${coupling.to}`)

  // Different coupling implementations based on type
  switch (coupling.type) {
    case 'explicit':
      lines.push(`${coupling.from}_to_${coupling.to}_coupling = ConnectorSystem([`)
      if (coupling.variables && coupling.variables.length > 0) {
        for (const variable of coupling.variables) {
          lines.push(`    ${coupling.from}_system.${variable} ~ ${coupling.to}_system.${variable},`)
        }
      }
      lines.push(`])`)
      break
    case 'operator_compose':
      lines.push(`${coupling.from}_${coupling.to}_composed = compose(${coupling.from}_system, ${coupling.to}_system)`)
      break
    case 'operator_apply':
      lines.push(`${coupling.from}_${coupling.to}_applied = apply(${coupling.from}_operator, ${coupling.to}_system)`)
      break
    default:
      lines.push(`# Coupling type '${coupling.type}' implementation`)
      lines.push(`${coupling.from}_${coupling.to}_coupling = couple(${coupling.from}_system, ${coupling.to}_system)`)
  }

  return lines
}

/**
 * Generate domain code for Julia
 */
function generateDomainCode(domain: Domain): string[] {
  const lines: string[] = []

  // Independent variable (time)
  const timeVar = domain.independent_variable || 't'
  lines.push(`# Time domain setup`)
  lines.push(`@variables ${timeVar}`)

  // Temporal domain
  if (domain.temporal) {
    lines.push(`# Temporal domain`)
    const start = domain.temporal.start || '0.0'
    const end = domain.temporal.end || '1.0'
    lines.push(`tspan = (${start}, ${end})`)
  }

  return lines
}

/**
 * Generate data loader code for Julia
 */
function generateDataLoaderCode(name: string, dataLoader: DataLoader): string[] {
  const lines: string[] = []

  lines.push(`# Data loader: ${name}`)
  lines.push(`${name}_loader = DataLoader(`)
  lines.push(`  kind = "${dataLoader.kind}",`)
  lines.push(`  url_template = "${dataLoader.source.url_template}",`)
  if (dataLoader.source.mirrors && dataLoader.source.mirrors.length > 0) {
    const mirrors = dataLoader.source.mirrors.map((m) => `"${m}"`).join(', ')
    lines.push(`  mirrors = [${mirrors}],`)
  }
  if (dataLoader.temporal) {
    if (dataLoader.temporal.start) {
      lines.push(`  temporal_start = "${dataLoader.temporal.start}",`)
    }
    if (dataLoader.temporal.end) {
      lines.push(`  temporal_end = "${dataLoader.temporal.end}",`)
    }
    if (dataLoader.temporal.file_period) {
      lines.push(`  file_period = "${dataLoader.temporal.file_period}",`)
    }
    if (dataLoader.temporal.frequency) {
      lines.push(`  frequency = "${dataLoader.temporal.frequency}",`)
    }
    if (dataLoader.temporal.records_per_file !== undefined) {
      const rpf = dataLoader.temporal.records_per_file
      const rendered = typeof rpf === 'string' ? `"${rpf}"` : String(rpf)
      lines.push(`  records_per_file = ${rendered},`)
    }
    if (dataLoader.temporal.time_variable) {
      lines.push(`  time_variable = "${dataLoader.temporal.time_variable}",`)
    }
  }
  lines.push(`)`)

  lines.push(`# Variables exposed by ${name}:`)
  for (const [variable, info] of Object.entries(dataLoader.variables)) {
    const desc = info.description ? ` - ${info.description}` : ''
    lines.push(`#   ${variable} <- ${info.file_variable} (${info.units})${desc}`)
  }

  return lines
}

/**
 * Format a variable declaration with defaults and units
 */
function formatVariableDeclaration(variable: ModelVariable, name: string): string {
  let decl = name

  // Add default value and units if present (check both "units" and "unit" properties for compatibility)
  const units = variable.units || (variable as any).unit
  if (variable.default !== undefined || units) {
    decl += '('
    const parts: string[] = []

    if (variable.default !== undefined) {
      // Ensure decimal point for floating point numbers.
      const defaultVal = variable.default
      const n = numericValue(defaultVal)
      if (n !== undefined && Number.isInteger(n)) {
        parts.push(`${n}.0`)
      } else if (n !== undefined) {
        parts.push(`${n}`)
      } else {
        parts.push(`${defaultVal}`)
      }
    }

    if (units) {
      parts.push(`u"${units}"`)
    }

    decl += parts.join(', ')
    decl += ')'
  }

  return decl
}

/**
 * Format a species declaration
 */
function formatSpeciesDeclaration(species: Species, name: string): string {
  let decl = name

  // Add default value if present (check both "default" and "initial_value" properties for compatibility)
  const initialValue = species.default !== undefined ? species.default : (species as any).initial_value
  if (initialValue !== undefined) {
    // Ensure decimal point for floating point numbers
    const n = numericValue(initialValue)
    if (n !== undefined && Number.isInteger(n)) {
      decl += `(${n}.0)`
    } else if (n !== undefined) {
      decl += `(${n})`
    } else {
      decl += `(${initialValue})`
    }
  }

  return decl
}

/**
 * Format an equation using ~ syntax
 */
function formatEquation(equation: Equation): string {
  const lhs = formatExpression(equation.lhs)
  const rhs = formatExpression(equation.rhs)
  return `${lhs} ~ ${rhs}`
}

/**
 * Format a reaction
 */
function formatReaction(reaction: Reaction): string {
  const rate = reaction.rate ? formatExpression(reaction.rate) : '1.0'

  // Format substrates (reactants) - handle both "substrates" and "reactants" properties for compatibility
  const substrates = reaction.substrates || (reaction as any).reactants
  const reactants = substrates ?
    substrates.map((r: any) => r.stoichiometry && r.stoichiometry !== 1 ?
      `${r.stoichiometry}*${r.species}` : r.species).join(' + ') :
    '∅'

  // Format products
  const products = reaction.products ?
    reaction.products.map(p => p.stoichiometry && p.stoichiometry !== 1 ?
      `${p.stoichiometry}*${p.species}` : p.species).join(' + ') :
    '∅'

  return `Reaction(${rate}, [${reactants}], [${products}])`
}

/**
 * Format an expression for Julia code generation
 */
function formatExpression(expr: Expression): string {
  const n = numericValue(expr)
  if (n !== undefined) {
    return n.toString()
  }

  if (typeof expr === 'string') {
    return expr
  }

  if (typeof expr === 'object' && expr.op) {
    return formatExpressionNode(expr)
  }

  throw new Error(`Unsupported expression type: ${typeof expr}`)
}

/**
 * Format an expression node for Julia, applying operator mappings
 */
function formatExpressionNode(node: ExpressionNode): string {
  const { op, args, wrt } = node

  // Apply expression mappings as specified in task description
  switch (op) {
    case '+':
      return args.map(formatExpression).join(' + ')
    case '*':
      return args.map(formatExpression).join(' * ')
    case 'D':
      // D(x,t) → D(x) (remove time parameter)
      if (args.length >= 1) {
        return `D(${formatExpression(args[0])})`
      }
      return 'D()'
    case 'exp':
      return `exp(${args.map(formatExpression).join(', ')})`
    case 'ifelse':
      return `ifelse(${args.map(formatExpression).join(', ')})`
    case 'Pre':
      return `Pre(${args.map(formatExpression).join(', ')})`
    case '^':
      return args.map(formatExpression).join(' ^ ')
    case 'grad':
      // grad(x,y) → Differential(y)(x)
      if (args.length >= 2) {
        return `Differential(${formatExpression(args[1])})(${formatExpression(args[0])})`
      } else if (args.length === 1) {
        // Default to x if dimension not specified
        return `Differential(x)(${formatExpression(args[0])})`
      }
      return 'Differential(x)()'
    case '-':
      if (args.length === 1) {
        return `-${formatExpression(args[0])}`
      } else {
        return args.map(formatExpression).join(' - ')
      }
    case '/':
      return args.map(formatExpression).join(' / ')
    case '<': case '>': case '<=': case '>=': case '==': case '!=':
      return args.map(formatExpression).join(` ${op} `)
    case 'and':
      return args.map(formatExpression).join(' && ')
    case 'or':
      return args.map(formatExpression).join(' || ')
    case 'not':
      return `!(${formatExpression(args[0])})`
    default:
      // For other operators, use function call syntax
      return `${op}(${args.map(formatExpression).join(', ')})`
  }
}

/**
 * Format affect clause for events
 */
function formatAffect(affect: any): string {
  if (Array.isArray(affect)) {
    return `[${affect.map(formatAffectEquation).join(', ')}]`
  } else if (affect && typeof affect === 'object' && (affect.lhs || affect.rhs)) {
    return formatAffectEquation(affect)
  } else {
    return 'nothing'
  }
}

/**
 * Format a single affect equation
 */
function formatAffectEquation(affect: any): string {
  if (affect.lhs && affect.rhs) {
    return `${formatExpression(affect.lhs)} ~ ${formatExpression(affect.rhs)}`
  }
  return 'nothing'
}

/**
 * Format discrete event trigger
 */
function formatDiscreteTrigger(trigger: any): string {
  if (trigger.condition) {
    return formatExpression(trigger.condition)
  }
  return 'true'
}

/**
 * Extract parameter names from an expression
 */
function extractParameterNames(expr: Expression): Set<string> {
  const params = new Set<string>()

  if (typeof expr === 'string') {
    // Simple heuristic: single letters or names starting with k/K are likely parameters
    if (expr.length === 1 || expr.startsWith('k') || expr.startsWith('K')) {
      params.add(expr)
    }
  } else if (typeof expr === 'object' && expr.op) {
    // Recursively extract from arguments
    for (const arg of expr.args) {
      const childParams = extractParameterNames(arg)
      childParams.forEach(p => params.add(p))
    }
  }

  return params
}

/**
 * Generate Python code for a model
 */
function generatePythonModelCode(name: string, model: Model): string[] {
  const lines: string[] = []

  lines.push(`# Model: ${name}`)

  // Collect state variables and parameters
  const stateVars: (ModelVariable & { name: string })[] = []
  const parameters: (ModelVariable & { name: string })[] = []

  if (model.variables) {
    for (const [varName, variable] of Object.entries(model.variables)) {
      if (variable.type === 'state') {
        stateVars.push({ ...variable, name: varName })
      } else if (variable.type === 'parameter') {
        parameters.push({ ...variable, name: varName })
      }
    }
  }

  // Generate time symbol if needed
  const hasDerivatives = model.equations && model.equations.some(eq =>
    hasDerivativeInExpression(eq.lhs) || hasDerivativeInExpression(eq.rhs)
  )
  if (hasDerivatives) {
    lines.push('# Time variable')
    lines.push('t = sp.Symbol(\'t\')')
    lines.push('')
  }

  // Generate symbol/function definitions
  if (stateVars.length > 0) {
    lines.push('# State variables')
    for (const variable of stateVars) {
      // Check both "units" and "unit" properties for compatibility
      const units = variable.units || (variable as any).unit
      const comment = units ? `  # ${units}` : ''
      if (variable.name && variable.name.includes('(')) {
        // Function symbol (e.g., contains parentheses)
        lines.push(`${variable.name} = sp.Function('${variable.name.split('(')[0]}')${comment}`)
      } else {
        // Regular symbol - but make it a function if derivatives are present
        if (hasDerivatives) {
          lines.push(`${variable.name} = sp.Function('${variable.name}')${comment}`)
        } else {
          lines.push(`${variable.name} = sp.Symbol('${variable.name}')${comment}`)
        }
      }
    }
    lines.push('')
  }

  if (parameters.length > 0) {
    lines.push('# Parameters')
    for (const parameter of parameters) {
      // Check both "units" and "unit" properties for compatibility
      const units = parameter.units || (parameter as any).unit
      const comment = units ? `  # ${units}` : ''
      lines.push(`${parameter.name} = sp.Symbol('${parameter.name}')${comment}`)
    }
    lines.push('')
  }

  // Generate equations
  if (model.equations && model.equations.length > 0) {
    lines.push('# Equations')
    for (const [i, equation] of model.equations.entries()) {
      const lhs = formatPythonExpression(equation.lhs)
      const rhs = formatPythonExpression(equation.rhs)
      lines.push(`eq${i + 1} = sp.Eq(${lhs}, ${rhs})`)
    }
  }

  return lines
}

/**
 * Generate Python code for a reaction system
 */
function generatePythonReactionSystemCode(name: string, reactionSystem: ReactionSystem): string[] {
  const lines: string[] = []

  lines.push(`# Reaction System: ${name}`)

  // Generate species symbols
  if (reactionSystem.species && Object.keys(reactionSystem.species).length > 0) {
    lines.push('# Species')
    for (const [name, species] of Object.entries(reactionSystem.species)) {
      lines.push(`${name} = sp.Symbol('${name}')`)
    }
    lines.push('')
  }

  // Generate reaction rate expressions
  if (reactionSystem.reactions && Object.keys(reactionSystem.reactions).length > 0) {
    lines.push('# Rate expressions')
    for (const [reactionName, reaction] of Object.entries(reactionSystem.reactions)) {
      if (reaction.rate) {
        const rateExpr = formatPythonExpression(reaction.rate)
        lines.push(`${reactionName}_rate = ${rateExpr}`)
      }
    }
    lines.push('')

    lines.push('# Stoichiometry setup (TODO: Implement reaction network)')
    for (const [reactionName, reaction] of Object.entries(reactionSystem.reactions)) {
      lines.push(`# Reaction: ${reactionName}`)
      // Handle both "substrates" and "reactants" properties for compatibility
      const substrates = reaction.substrates || (reaction as any).reactants
      if (substrates) {
        const reactantStr = substrates
          .map((r: any) => r.stoichiometry && r.stoichiometry !== 1 ? `${r.stoichiometry}*${r.species}` : r.species)
          .join(' + ')
        lines.push(`#   Reactants: ${reactantStr}`)
      }
      if (reaction.products) {
        const productStr = reaction.products
          .map(p => p.stoichiometry && p.stoichiometry !== 1 ? `${p.stoichiometry}*${p.species}` : p.species)
          .join(' + ')
        lines.push(`#   Products: ${productStr}`)
      }
    }
  }

  return lines
}

/**
 * Generate coupling code for Python
 */
function generatePythonCouplingCode(coupling: CouplingEntry): string[] {
  const lines: string[] = []

  lines.push(`# Coupling ${coupling.type}: ${coupling.from} -> ${coupling.to}`)

  // Different coupling implementations based on type
  switch (coupling.type) {
    case 'explicit':
      lines.push(`${coupling.from}_to_${coupling.to}_coupling = esm.ExplicitCoupling(`)
      lines.push(`    from_model="${coupling.from}",`)
      lines.push(`    to_model="${coupling.to}",`)
      if (coupling.variables && coupling.variables.length > 0) {
        lines.push(`    variables=${JSON.stringify(coupling.variables)}`)
      }
      lines.push(`)`)
      break
    case 'operator_compose':
      lines.push(`${coupling.from}_${coupling.to}_composed = esm.compose_systems(${coupling.from}_system, ${coupling.to}_system)`)
      break
    case 'operator_apply':
      lines.push(`${coupling.from}_${coupling.to}_applied = esm.apply_operator(${coupling.from}_operator, ${coupling.to}_system)`)
      break
    default:
      lines.push(`# Coupling type '${coupling.type}' implementation`)
      lines.push(`${coupling.from}_${coupling.to}_coupling = esm.couple_systems(${coupling.from}_system, ${coupling.to}_system)`)
  }

  return lines
}

/**
 * Generate domain code for Python
 */
function generatePythonDomainCode(domain: Domain): string[] {
  const lines: string[] = []

  lines.push(`# Domain configuration`)

  // Independent variable (time)
  const timeVar = domain.independent_variable || 't'
  lines.push(`${timeVar} = sp.Symbol('${timeVar}')`)

  // Temporal domain
  if (domain.temporal) {
    lines.push(`# Temporal domain`)
    const start = domain.temporal.start || '0.0'
    const end = domain.temporal.end || '1.0'
    lines.push(`tspan = (${start}, ${end})`)

    if (domain.temporal.reference_time) {
      lines.push(`reference_time = "${domain.temporal.reference_time}"`)
    }
  }

  // Domain setup
  lines.push(`domain = esm.Domain(`)
  if (domain.temporal) {
    lines.push(`    temporal=esm.TemporalDomain(`)
    lines.push(`        start=${domain.temporal.start || '0.0'},`)
    lines.push(`        end=${domain.temporal.end || '1.0'}`)
    lines.push(`    )`)
  }
  lines.push(`)`)

  return lines
}

/**
 * Generate data loader code for Python
 */
function generatePythonDataLoaderCode(name: string, dataLoader: DataLoader): string[] {
  const lines: string[] = []

  lines.push(`# Data loader: ${name}`)
  lines.push(`${name}_loader = esm.DataLoader(`)
  lines.push(`    kind="${dataLoader.kind}",`)
  lines.push(`    url_template="${dataLoader.source.url_template}",`)
  if (dataLoader.source.mirrors && dataLoader.source.mirrors.length > 0) {
    const mirrors = dataLoader.source.mirrors.map((m) => `"${m}"`).join(', ')
    lines.push(`    mirrors=[${mirrors}],`)
  }
  if (dataLoader.temporal) {
    if (dataLoader.temporal.start) {
      lines.push(`    temporal_start="${dataLoader.temporal.start}",`)
    }
    if (dataLoader.temporal.end) {
      lines.push(`    temporal_end="${dataLoader.temporal.end}",`)
    }
    if (dataLoader.temporal.file_period) {
      lines.push(`    file_period="${dataLoader.temporal.file_period}",`)
    }
    if (dataLoader.temporal.frequency) {
      lines.push(`    frequency="${dataLoader.temporal.frequency}",`)
    }
    if (dataLoader.temporal.records_per_file !== undefined) {
      const rpf = dataLoader.temporal.records_per_file
      const rendered = typeof rpf === 'string' ? `"${rpf}"` : String(rpf)
      lines.push(`    records_per_file=${rendered},`)
    }
    if (dataLoader.temporal.time_variable) {
      lines.push(`    time_variable="${dataLoader.temporal.time_variable}",`)
    }
  }
  lines.push(`)`)

  lines.push(`# Variables exposed by ${name}:`)
  for (const [variable, info] of Object.entries(dataLoader.variables)) {
    const desc = info.description ? ` - ${info.description}` : ''
    lines.push(`#   ${variable} <- ${info.file_variable} (${info.units})${desc}`)
  }

  return lines
}

/**
 * Format an expression for Python code generation
 */
function formatPythonExpression(expr: Expression): string {
  const n = numericValue(expr)
  if (n !== undefined) {
    return n.toString()
  }

  if (typeof expr === 'string') {
    return expr
  }

  if (typeof expr === 'object' && expr.op) {
    return formatPythonExpressionNode(expr)
  }

  throw new Error(`Unsupported expression type: ${typeof expr}`)
}

/**
 * Format an expression node for Python, applying operator mappings
 */
function formatPythonExpressionNode(node: ExpressionNode): string {
  const { op, args } = node

  // Apply expression mappings as specified in task description
  switch (op) {
    case '+':
      return args.map(formatPythonExpression).join(' + ')
    case '*':
      return args.map(formatPythonExpression).join(' * ')
    case 'D':
      // D(x,t) → Derivative(x(t), t)
      if (args.length >= 1) {
        const varName = formatPythonExpression(args[0])
        // Assume time variable t
        return `sp.Derivative(${varName}(t), t)`
      }
      return 'sp.Derivative()'
    case 'exp':
      return `sp.exp(${args.map(formatPythonExpression).join(', ')})`
    case 'ifelse':
      // ifelse(condition, true_val, false_val) → sp.Piecewise((true_val, condition), (false_val, True))
      if (args.length >= 3) {
        const condition = formatPythonExpression(args[0])
        const trueVal = formatPythonExpression(args[1])
        const falseVal = formatPythonExpression(args[2])
        return `sp.Piecewise((${trueVal}, ${condition}), (${falseVal}, True))`
      }
      return `sp.Piecewise((0, True))`
    case 'Pre':
      // Pre → Function('Pre')
      return `Function('Pre')(${args.map(formatPythonExpression).join(', ')})`
    case '^':
      // ^ → **
      return args.map(formatPythonExpression).join(' ** ')
    case 'grad':
      // grad(x,y) → sp.Derivative(x, y)
      if (args.length >= 2) {
        const func = formatPythonExpression(args[0])
        const var_ = formatPythonExpression(args[1])
        return `sp.Derivative(${func}, ${var_})`
      } else if (args.length === 1) {
        // Default to x if dimension not specified
        return `sp.Derivative(${formatPythonExpression(args[0])}, x)`
      }
      return 'sp.Derivative()'
    case '-':
      if (args.length === 1) {
        return `-${formatPythonExpression(args[0])}`
      } else {
        return args.map(formatPythonExpression).join(' - ')
      }
    case '/':
      return args.map(formatPythonExpression).join(' / ')
    case '<': case '>': case '<=': case '>=': case '==': case '!=':
      return args.map(formatPythonExpression).join(` ${op} `)
    case 'and':
      return args.map(formatPythonExpression).join(' & ')
    case 'or':
      return args.map(formatPythonExpression).join(' | ')
    case 'not':
      return `~(${formatPythonExpression(args[0])})`
    default:
      // For other operators, use function call syntax
      return `${op}(${args.map(formatPythonExpression).join(', ')})`
  }
}

/**
 * Check if an expression contains derivatives
 */
function hasDerivativeInExpression(expr: Expression): boolean {
  if (typeof expr === 'object' && expr.op) {
    if (expr.op === 'D') {
      return true
    }
    return expr.args.some(arg => hasDerivativeInExpression(arg))
  }
  return false
}