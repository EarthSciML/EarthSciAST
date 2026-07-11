/**
 * ESM Format validation wrapper for cross-language conformance testing.
 *
 * Provides a standardized validation interface that matches the format expected
 * by the conformance test runner across all language implementations.
 */

import {
  validateSchema,
  load,
  ParseError,
  SchemaValidationError,
  type SchemaError,
} from './parse.js'
import { ExpressionTemplateError } from './lower-expression-templates.js'
import { EnumLoweringError } from './lower-enums.js'
import {
  LosslessJsonParseError,
  CanonicalNonfiniteError,
  losslessJsonParse,
  stripNumericLiterals,
} from './numeric-literal.js'
import { isExprNode, forEachChild } from './expression.js'
import type { Expr } from './expression.js'
import { ERROR_CODES } from './errors.js'
import {
  checkDimensions,
  parseUnit,
  isDimensionless,
  dimsEqual,
  type UnitWarning,
  type CanonicalDims,
  type ParsedUnit,
} from './units.js'
import type {
  EsmFile,
  Model,
  DataLoader,
  ReactionSystem,
  Expression,
  CouplingOperatorCompose,
  CouplingCouple,
  CouplingVariableMap,
  SubsystemRef,
  AffectEquation,
} from './types.js'

/**
 * Validation error with structured details
 */
export interface ValidationError {
  path: string
  message: string
  code: string
  details: Record<string, unknown>
}

/**
 * Structured validation result
 */
export interface ValidationResult {
  is_valid: boolean
  schema_errors: ValidationError[]
  structural_errors: ValidationError[]
  unit_warnings: UnitWarning[]
}

/**
 * Structural errors share the exact `ValidationError` shape. This alias is a
 * readability marker used on the return types of the structural validators
 * below (as opposed to schema errors); it introduces no new fields.
 */
export type StructuralError = ValidationError

/** Narrow a `models` / `subsystems` map value to an inline Model. */
function isInlineModel(v: Model | DataLoader | SubsystemRef): v is Model {
  return !('ref' in v) && !('kind' in v)
}

// ---------------------------------------------------------------------------
// Expression-tree walkers.
//
// These four walkers (extractVariableReferences, collectIndexSymbols,
// countDerivatives, expressionReferencesName) share a common leaf-discrimination
// rule via `isExprNode` (number/string/NumericLiteral leaves vs operator nodes)
// AND a common DESCENT: every one now recurses through `forEachChild` (the
// shared full-child walker in expression.ts), so each visits the COMPLETE set of
// expression-bearing fields (`args`, the aggregate/integral scalar bodies
// `expr`/`filter`/`key`/`lower`/`upper`, `makearray` `values`, `table_lookup`
// `axes`, and template `bindings`) instead of the historical `args`-only subset.
//
// Descending the aggregate bodies is only sound because the bound-symbol
// collector (collectIndexSymbols) now models EVERY binder those bodies can
// introduce — not just aggregate `output_idx`/`ranges` and `index` element
// positions, but also the `argmin`/`argmax` `arg` witness and its own `ranges`,
// the `skolem` invented-key name (the first positional arg, e.g. the
// `skolem('edge', …)` term in tests/valid/aggregate/skolem_distinct_rank.esm or
// the `skolem('bin', …)` term in nearest_generator_argmin.esm), and
// `apply_expression_template` `bindings` parameter names. Every such name is a
// scoped iteration/invention symbol, NOT a declared variable, so
// validateReferenceIntegrity treats it as bound and does not flag it — keeping
// emitted diagnostics byte-identical to the old `args`-only walkers on valid
// fixtures while gaining the deeper descent. (`join` is deliberately NOT an
// expression-child field, so `forEachChild` never descends into it and its
// `on` operands are never surfaced as references.)
// ---------------------------------------------------------------------------

/**
 * Extract all variable references from an expression, descending the full child
 * set via {@link forEachChild}. `args` are visited first (preserving the
 * historical DFS order of the previous `args`-only walker), then the remaining
 * expression-bearing fields, so any name the old walker surfaced keeps its
 * relative position; binder-introduced names newly reachable under the deeper
 * bodies are filtered out by {@link collectIndexSymbols} at the call site.
 */
function extractVariableReferences(expr: Expression): string[] {
  const variables: string[] = []

  function visit(node: Expr): void {
    if (typeof node === 'string') {
      // String references are variable names
      variables.push(node)
    } else if (isExprNode(node)) {
      // Operator node — recurse over every expression-bearing child.
      forEachChild(node, (child) => visit(child))
    }
    // number / NumericLiteral leaves carry no variables
  }

  visit(expr)
  return Array.from(new Set(variables)) // Remove duplicates
}

/**
 * Collect the binder-introduced symbols an expression scopes — the names that
 * are iteration positions or invented values rather than declared variables, so
 * reference integrity must not flag them as undefined. Descent is the same
 * full-child walk (`forEachChild`) as {@link extractVariableReferences}, so
 * every symbol that function can surface from any nested body is captured here.
 *
 * Binders modelled:
 *   - `aggregate` `output_idx` entries and `ranges` keys (loop variables);
 *   - `argmin` / `argmax` `arg` witness and their own `ranges` keys;
 *   - `skolem` invented-key name (the first positional `args` entry);
 *   - `index(array, i, j, …)` element positions after the array head;
 *   - `apply_expression_template` `bindings` parameter names.
 */
function collectIndexSymbols(expr: Expression): Set<string> {
  const symbols = new Set<string>()

  function visit(node: Expr): void {
    if (!isExprNode(node)) return

    // Aggregate output indices are bound loop variables.
    if (node.op === 'aggregate') {
      for (const idx of node.output_idx || []) {
        if (typeof idx === 'string') symbols.add(idx)
      }
    }

    // `ranges` keys are bound loop variables on aggregate AND on the
    // argmin/argmax reducers, which carry their own inner contraction range.
    if (node.ranges && typeof node.ranges === 'object') {
      for (const key of Object.keys(node.ranges)) symbols.add(key)
    }

    // argmin/argmax bind an arg-witness symbol naming the winning index.
    if ((node.op === 'argmin' || node.op === 'argmax') && typeof node.arg === 'string') {
      symbols.add(node.arg)
    }

    // skolem(name, ...): the first positional arg is the invented-key binder,
    // not a declared variable reference.
    if (node.op === 'skolem' && node.args.length > 0 && typeof node.args[0] === 'string') {
      symbols.add(node.args[0])
    }

    if (node.op === 'index') {
      // index(array, pos1, pos2, ...): positions after the array head are
      // index expressions; bare-name positions are bound index symbols.
      for (let i = 1; i < node.args.length; i++) {
        const pos = node.args[i]
        if (typeof pos === 'string') symbols.add(pos)
      }
    }

    // apply_expression_template bindings map its formal parameter names, which
    // are template-local and not references in the enclosing scope.
    if (node.bindings && typeof node.bindings === 'object') {
      for (const key of Object.keys(node.bindings)) symbols.add(key)
    }

    forEachChild(node, (child) => visit(child))
  }

  visit(expr)
  return symbols
}

/**
 * The variable a derivative differentiates. Either a bare name (`D(v)`) or the
 * array head of an `index` node (`D(index(v, i...))`) — the aggregate-IR form
 * that differentiates a single element of an arrayed state variable.
 */
function derivativeTargetVariable(arg: Expression): string | undefined {
  if (typeof arg === 'string') return arg
  if (isExprNode(arg)) {
    if (arg.op === 'index' && arg.args && arg.args.length > 0) {
      const head = arg.args[0]
      if (typeof head === 'string') return head
    }
  }
  return undefined
}

/**
 * The variable an equation LHS assigns to, peeling derivative, element-index,
 * and aggregate-output wrappers down to the underlying name. Used to credit a
 * relational / algebraic equation (e.g. the aggregate-IR `index(v, i) =
 * aggregate(...)` produced by skolem / distinct / rank) that defines a state
 * variable without a time derivative.
 */
function lhsAssignmentTarget(lhs: Expression): string | undefined {
  if (typeof lhs === 'string') return lhs
  if (isExprNode(lhs)) {
    switch (lhs.op) {
      case 'D':
      case 'index':
        return lhs.args && lhs.args.length > 0 ? lhsAssignmentTarget(lhs.args[0]) : undefined
      case 'aggregate':
        return lhs.expr !== undefined ? lhsAssignmentTarget(lhs.expr) : undefined
      default:
        return undefined
    }
  }
  return undefined
}

/**
 * Count D(var, t) derivatives in an expression.
 *
 * Recognises the aggregate-IR derivative forms in addition to the bare
 * `D(v)`: an `index`-wrapped derivative `D(index(v, i))`, and a derivative
 * carried in an aggregate's contracted body (`aggregate(output_idx:[i],
 * expr: D(index(v, i)))`), whose `D` lives under `expr` rather than `args`.
 */
function countDerivatives(expr: Expression): { [variable: string]: number } {
  const derivatives: { [variable: string]: number } = {}

  function visit(node: Expr): void {
    if (!isExprNode(node)) return
    if (node.op === 'D' && node.args.length >= 1) {
      const target = derivativeTargetVariable(node.args[0])
      if (target !== undefined) {
        derivatives[target] = (derivatives[target] || 0) + 1
      }
    }
    // Recurse over every expression-bearing child. An aggregate carries its
    // contracted body (and any LHS derivative) in `expr`, not `args`, which
    // `forEachChild` descends alongside `args`.
    forEachChild(node, (child) => visit(child))
  }

  visit(expr)
  return derivatives
}

/**
 * Resolve scoped variable reference like "Model.Subsystem.var"
 */
function resolveScopedReference(reference: string, esmFile: EsmFile): boolean {
  const parts = reference.split('.')
  if (parts.length < 2) {
    return false // Not a scoped reference
  }

  const [systemName, ...pathParts] = parts
  const variableName = pathParts.pop()!

  // Try to find in models
  if (esmFile.models && esmFile.models[systemName]) {
    let current: Model | DataLoader | SubsystemRef = esmFile.models[systemName]

    // Navigate through subsystems (unresolved refs and data loaders
    // carry none, so navigation simply fails for them)
    for (const pathPart of pathParts) {
      const subsystems: Model['subsystems'] =
        'subsystems' in current ? current.subsystems : undefined
      if (!subsystems || !subsystems[pathPart]) {
        return false
      }
      current = subsystems[pathPart]
    }

    // Check if variable exists
    return 'variables' in current && !!current.variables && variableName in current.variables
  }

  // Try to find in reaction systems
  if (esmFile.reaction_systems && esmFile.reaction_systems[systemName]) {
    let current: ReactionSystem | SubsystemRef = esmFile.reaction_systems[systemName]

    // Navigate through subsystems (unresolved refs carry none, so
    // navigation simply fails for them)
    for (const pathPart of pathParts) {
      const subsystems: ReactionSystem['subsystems'] =
        'subsystems' in current ? current.subsystems : undefined
      if (!subsystems || !subsystems[pathPart]) {
        return false
      }
      current = subsystems[pathPart]
    }

    // Check if species or parameter exists
    return (
      ('species' in current && !!current.species && variableName in current.species) ||
      ('parameters' in current && !!current.parameters && variableName in current.parameters)
    )
  }

  // Try to find in data loaders (RFC pure-io-data-loaders): a loader-scoped
  // reference like "InitialConditions.O3_init" names a variable the loader
  // exposes. Loaders have no subsystems, so only a single-segment path
  // resolves.
  const loader = esmFile.data_loaders?.[systemName]
  if (loader && pathParts.length === 0) {
    return !!loader.variables && variableName in loader.variables
  }

  return false
}

/**
 * Split a scoped reference like `"System.var"` or `"System.Sub.var"` into its
 * head system segment and the ENTIRE remaining dotted path.
 *
 * Unlike a 2-limit split (`ref.split('.', 2)`), the remainder keeps every
 * trailing segment, so `"A.b.c"` → `["A", "b.c"]` rather than truncating to
 * `"b"`. This matches Go's `strings.SplitN(ref, ".", 2)` remainder semantics,
 * so the (system, variable-path) decomposition is identical across bindings.
 * Callers that need a scoped ref's system head and variable path share this
 * one helper (both `validateCouplingIntegrity` and `validateDataLoaderReferences`
 * previously parsed the same field two incompatible ways).
 */
function splitScopedRef(ref: string): [string, string] {
  const dot = ref.indexOf('.')
  if (dot < 0) return [ref, '']
  return [ref.slice(0, dot), ref.slice(dot + 1)]
}

/**
 * Check equation-unknown balance for a model
 */
function validateEquationBalance(model: Model, modelPath: string): StructuralError[] {
  const errors: StructuralError[] = []

  // Count state variables
  const stateVariables = Object.entries(model.variables || {})
    .filter(([_, variable]) => variable.type === 'state')
    .map(([name, _]) => name)

  // Count equations driving each state variable. A normal ODE contributes a
  // D(var,t) derivative; an aggregate LHS contributes the derivative carried
  // in its contracted body. A relational / algebraic equation with no time
  // derivative (the aggregate-IR `index(v, i) = aggregate(...)` form emitted
  // by skolem / distinct / rank) instead credits the state variable its LHS
  // assigns to, so element-defined state still balances the unknown count.
  const derivativeCounts: { [variable: string]: number } = {}

  for (const equation of model.equations || []) {
    const lhsDerivatives = countDerivatives(equation.lhs)
    if (Object.keys(lhsDerivatives).length > 0) {
      for (const [variable, count] of Object.entries(lhsDerivatives)) {
        derivativeCounts[variable] = (derivativeCounts[variable] || 0) + count
      }
    } else {
      const target = lhsAssignmentTarget(equation.lhs)
      if (target !== undefined && stateVariables.includes(target)) {
        derivativeCounts[target] = (derivativeCounts[target] || 0) + 1
      }
    }
  }

  const odeEquationCount = Object.values(derivativeCounts).reduce((sum, count) => sum + count, 0)

  if (stateVariables.length !== odeEquationCount) {
    const missingEquations = stateVariables.filter((varName) => !(varName in derivativeCounts))

    errors.push({
      path: modelPath,
      code: ERROR_CODES.EQUATION_COUNT_MISMATCH,
      message: `Number of ODE equations (${odeEquationCount}) does not match number of state variables (${stateVariables.length})`,
      details: {
        state_variables: stateVariables,
        ode_equations: odeEquationCount,
        missing_equations_for: missingEquations,
      },
    })
  }

  return errors
}

/**
 * Check reference integrity for a model
 */
function validateReferenceIntegrity(
  model: Model,
  modelPath: string,
  esmFile: EsmFile,
): StructuralError[] {
  const errors: StructuralError[] = []
  const declaredVariables = new Set(Object.keys(model.variables || {}))
  // Declared index sets are a legitimate, non-variable identifier namespace
  // (RFC semiring-faq-unified-ir §5.2). An `aggregate` may name an index set
  // as a positional operand — the value-invention form
  // `aggregate(args:["faces"], ...)` enumerates over the `faces` set itself
  // (the mesh-edge enumeration of ess-my4.3.10 / §7.3). Such a name is not a
  // declared variable, so credit the document-scoped `index_sets` keys here,
  // exactly as the binder symbols below credit aggregate range / `index`
  // positions (the aggregate-aware fix of ess-my4.1.7). A genuinely-undefined
  // reference still matches neither set and is flagged. As of v0.8.0 the
  // `index_sets` registry is a single, document-level field shared by every
  // model (a sibling of `models` / `domain`), not a per-model field.
  const declaredIndexSets = new Set(Object.keys(esmFile.index_sets || {}))

  // Check equations
  for (let i = 0; i < (model.equations || []).length; i++) {
    const equation = model.equations![i]
    const equationPath = `${modelPath}/equations/${i}`

    // Binder-introduced index / contraction symbols (aggregate ranges and
    // output indices, `index` element positions) are iteration positions,
    // not declared variables — collect them so they are not flagged as
    // undefined references below.
    const boundSymbols = new Set<string>([
      ...collectIndexSymbols(equation.lhs),
      ...collectIndexSymbols(equation.rhs),
    ])

    const checkSide = (expr: Expression, sidePath: string): void => {
      for (const varRef of extractVariableReferences(expr)) {
        if (varRef.includes('.')) {
          // Scoped reference
          if (!resolveScopedReference(varRef, esmFile)) {
            errors.push({
              path: sidePath,
              code: ERROR_CODES.UNRESOLVED_SCOPED_REF,
              message: `Scoped reference "${varRef}" cannot be resolved`,
              details: { reference: varRef },
            })
          }
        } else if (
          !declaredVariables.has(varRef) &&
          !declaredIndexSets.has(varRef) &&
          !boundSymbols.has(varRef)
        ) {
          // Local reference
          errors.push({
            path: sidePath,
            code: ERROR_CODES.UNDEFINED_VARIABLE,
            message: `Variable "${varRef}" referenced in equation is not declared`,
            details: { variable: varRef },
          })
        }
      }
    }

    checkSide(equation.lhs, `${equationPath}/lhs`)
    checkSide(equation.rhs, `${equationPath}/rhs`)
  }

  // Check observed variables have expressions
  for (const [varName, variable] of Object.entries(model.variables || {})) {
    if (variable.type === 'observed' && !variable.expression) {
      errors.push({
        path: `${modelPath}/variables/${varName}`,
        code: ERROR_CODES.MISSING_OBSERVED_EXPR,
        message: `Observed variable "${varName}" is missing its expression field`,
        details: { variable: varName },
      })
    }
  }

  return errors
}

/**
 * Flag affect-equation LHS targets that are not declared variables. Shared by
 * the discrete-event `affects`, continuous-event `affects`, and continuous-event
 * `affect_neg` loops, which are byte-identical apart from the array path segment
 * and the human-readable context phrase.
 *
 * `phrase` is interpolated verbatim into the message, preserving the historical
 * per-site wording — "event affects" vs "continuous event affects" vs
 * "continuous event affect_neg" — which the cross-language goldens pin, so it is
 * NOT unified. `basePath` is the array's JSON path (e.g. `.../affects`); the
 * per-element `/${j}/lhs` suffix is appended here.
 */
function checkAffectTargets(
  affects: AffectEquation[] | null | undefined,
  declaredVariables: Set<string>,
  basePath: string,
  phrase: string,
): StructuralError[] {
  const errors: StructuralError[] = []
  if (!affects) return errors
  for (let j = 0; j < affects.length; j++) {
    const affect = affects[j]
    if (!declaredVariables.has(affect.lhs)) {
      errors.push({
        path: `${basePath}/${j}/lhs`,
        code: ERROR_CODES.EVENT_VAR_UNDECLARED,
        message: `Variable "${affect.lhs}" in ${phrase} is not declared`,
        details: { variable: affect.lhs },
      })
    }
  }
  return errors
}

/**
 * Check discrete parameters in events
 */
function validateEventConsistency(model: Model, modelPath: string): StructuralError[] {
  const errors: StructuralError[] = []
  const declaredVariables = new Set(Object.keys(model.variables || {}))
  const declaredParameters = new Set(
    Object.entries(model.variables || {})
      .filter(([_, variable]) => variable.type === 'parameter')
      .map(([name, _]) => name),
  )

  // Check discrete events
  for (let i = 0; i < (model.discrete_events || []).length; i++) {
    const event = model.discrete_events![i]
    const eventPath = `${modelPath}/discrete_events/${i}`

    // Check discrete_parameters entries
    if (event.discrete_parameters) {
      for (const paramName of event.discrete_parameters) {
        if (!declaredParameters.has(paramName)) {
          errors.push({
            path: `${eventPath}/discrete_parameters`,
            code: ERROR_CODES.INVALID_DISCRETE_PARAM,
            message: `discrete_parameters entry "${paramName}" does not match a declared parameter`,
            details: { parameter: paramName },
          })
        }
      }
    }

    // Check affects variables
    errors.push(
      ...checkAffectTargets(event.affects, declaredVariables, `${eventPath}/affects`, 'event affects'),
    )

    // Check functional affect variables
    if (event.functional_affect) {
      for (const varName of event.functional_affect.read_vars || []) {
        if (!declaredVariables.has(varName)) {
          errors.push({
            path: `${eventPath}/functional_affect/read_vars`,
            code: ERROR_CODES.EVENT_VAR_UNDECLARED,
            message: `Variable "${varName}" in functional_affect read_vars is not declared`,
            details: { variable: varName },
          })
        }
      }

      for (const paramName of event.functional_affect.read_params || []) {
        if (!declaredParameters.has(paramName)) {
          errors.push({
            path: `${eventPath}/functional_affect/read_params`,
            code: ERROR_CODES.EVENT_VAR_UNDECLARED,
            message: `Parameter "${paramName}" in functional_affect read_params is not declared`,
            details: { variable: paramName },
          })
        }
      }
    }
  }

  // Check continuous events
  for (let i = 0; i < (model.continuous_events || []).length; i++) {
    const event = model.continuous_events![i]
    const eventPath = `${modelPath}/continuous_events/${i}`

    // Check affects variables
    errors.push(
      ...checkAffectTargets(
        event.affects,
        declaredVariables,
        `${eventPath}/affects`,
        'continuous event affects',
      ),
    )

    // Check affect_neg variables
    errors.push(
      ...checkAffectTargets(
        event.affect_neg,
        declaredVariables,
        `${eventPath}/affect_neg`,
        'continuous event affect_neg',
      ),
    )
  }

  return errors
}

/**
 * Check reaction consistency for a reaction system
 */
function validateReactionConsistency(
  reactionSystem: ReactionSystem,
  systemPath: string,
): StructuralError[] {
  const errors: StructuralError[] = []
  const declaredSpecies = new Set(Object.keys(reactionSystem.species || {}))
  const declaredParameters = new Set(Object.keys(reactionSystem.parameters || {}))

  for (let i = 0; i < (reactionSystem.reactions || []).length; i++) {
    const reaction = reactionSystem.reactions![i]
    const reactionPath = `${systemPath}/reactions/${i}`

    // Check for null-null reactions
    if (reaction.substrates === null && reaction.products === null) {
      errors.push({
        path: reactionPath,
        code: ERROR_CODES.NULL_REACTION,
        message: `Reaction "${reaction.id}" has both substrates: null and products: null`,
        details: { reaction_id: reaction.id },
      })
    }

    // Check substrates and products. The two blocks were byte-identical apart
    // from the reactant role, which only varies the path segment and the
    // "reaction <role>" message wording — so they share one loop.
    for (const role of ['substrates', 'products'] as const) {
      const reactants = reaction[role]
      if (!reactants || !Array.isArray(reactants)) continue
      for (let j = 0; j < reactants.length; j++) {
        const reactant = reactants[j]
        if (reactant && !declaredSpecies.has(reactant.species)) {
          errors.push({
            path: `${reactionPath}/${role}/${j}/species`,
            code: ERROR_CODES.UNDEFINED_SPECIES,
            message: `Species "${reactant.species}" in reaction ${role} is not declared`,
            details: { species: reactant.species, reaction_id: reaction.id },
          })
        }

        // Check stoichiometry is positive integer
        if (
          reactant &&
          (!Number.isInteger(reactant.stoichiometry) || reactant.stoichiometry <= 0)
        ) {
          errors.push({
            path: `${reactionPath}/${role}/${j}/stoichiometry`,
            code: ERROR_CODES.INVALID_STOICHIOMETRY,
            message: `Stoichiometry must be a positive integer, got ${reactant.stoichiometry}`,
            details: { stoichiometry: reactant.stoichiometry, reaction_id: reaction.id },
          })
        }
      }
    }

    // Check rate expression references. NOTE: the `undefined_parameter` code
    // covers BOTH undeclared species and undeclared parameters in a rate
    // expression; the code string is conformance-pinned so it is not split by
    // reference kind.
    const rateVars = extractVariableReferences(reaction.rate)
    for (const varRef of rateVars) {
      if (!declaredSpecies.has(varRef) && !declaredParameters.has(varRef)) {
        errors.push({
          path: `${reactionPath}/rate`,
          code: ERROR_CODES.UNDEFINED_PARAMETER,
          message: `Variable "${varRef}" in rate expression is not declared as species or parameter`,
          details: { variable: varRef, reaction_id: reaction.id },
        })
      }
    }
  }

  return errors
}

/**
 * Reject `ic`-op equations placed inside a reaction system's
 * `constraint_equations` (spec §11.4.1).
 *
 * A reaction system has no `equations` field and hosts no initial conditions:
 * a species' initial value is its scalar `species.default`, and a non-constant
 * / spatial IC is declared with a scoped-reference `ic` equation in a MODEL
 * (`ic(Chemistry.O3) ~ <field>`), never inside the reaction system. Such a file
 * is SCHEMA-VALID (`constraint_equations` is an array of Equation and `ic` is a
 * legal op) but MUST be rejected structurally with code `ic_in_reaction_system`.
 */
function validateReactionSystemICs(
  reactionSystem: ReactionSystem,
  systemName: string,
  systemPath: string,
): StructuralError[] {
  const errors: StructuralError[] = []
  const constraintEquations = reactionSystem.constraint_equations
  if (!constraintEquations) return errors

  for (let i = 0; i < constraintEquations.length; i++) {
    const lhs = constraintEquations[i]?.lhs
    if (!isExprNode(lhs)) continue
    const node = lhs
    if (node.op !== 'ic') continue

    let species: string | null = null
    if (node.args && node.args.length > 0 && typeof node.args[0] === 'string') {
      species = node.args[0]
    }

    errors.push({
      path: `${systemPath}/constraint_equations/${i}`,
      code: ERROR_CODES.IC_IN_REACTION_SYSTEM,
      message:
        'ic equation not allowed in a reaction system; a reaction system has no equations ' +
        'field and hosts no ic equations (ICs are model-hosted: species.default, or a ' +
        'scoped-reference ic equation in a model, spec §11.4.1)',
      details: {
        system: systemName,
        species,
        constraint_equation_index: i,
      },
    })
  }

  return errors
}

/**
 * Build a unit-binding map for a single reaction system covering its species
 * and parameters. Mirrors the binding environment used by validateUnits but
 * scoped to one system so dimensional checks see the author-declared units
 * for each symbol.
 */
function buildReactionSystemUnitBindings(reactionSystem: ReactionSystem): Map<string, ParsedUnit> {
  const bindings = new Map<string, ParsedUnit>()
  if ('species' in reactionSystem && reactionSystem.species) {
    for (const [name, species] of Object.entries(reactionSystem.species)) {
      if (species && species.units) {
        bindings.set(name, parseUnit(species.units))
      }
    }
  }
  if ('parameters' in reactionSystem && reactionSystem.parameters) {
    for (const [name, param] of Object.entries(reactionSystem.parameters)) {
      if (param && param.units) {
        bindings.set(name, parseUnit(param.units))
      }
    }
  }
  return bindings
}

/**
 * Split a unit string like "mol/L" into ("mol", "L") or "mol/(L*s)" into
 * ("mol", "L*s"). The split is on the first top-level '/'. If no '/' appears,
 * the whole string is the numerator. Matches Go's splitUnitNumDen so the
 * expected_rate_units payloads line up byte-for-byte across bindings.
 */
function splitUnitNumDen(s: string): [string, string] {
  const trimmed = s.trim()
  if (trimmed === '') return ['', '']
  let depth = 0
  for (let i = 0; i < trimmed.length; i++) {
    const c = trimmed[i]
    if (c === '(') depth++
    else if (c === ')') depth--
    else if (c === '/' && depth === 0) {
      const num = trimmed.slice(0, i).trim()
      let den = trimmed.slice(i + 1).trim()
      if (den.startsWith('(') && den.endsWith(')')) {
        den = den.slice(1, -1)
      }
      return [num, den]
    }
  }
  return [trimmed, '']
}

/**
 * Render a unit factor raised to an integer power. Parenthesizes compound
 * factors when the exponent is not 1. Mirrors Go's powerFactor.
 */
function powerFactor(s: string, n: number): string {
  const t = s.trim()
  if (t === '') return ''
  if (n === 1) return t
  if (/[*/]/.test(t)) return `(${t})^${n}`
  return `${t}^${n}`
}

/**
 * Compose the canonical expected rate-unit string from the reference species
 * unit string and total reaction order: rate_units = species_units^(1-order) / s.
 * Matches the contract in tests/invalid/expected_errors.json and the Go
 * formatExpectedRateUnits helper so cross-binding details stay identical.
 *
 *   ("mol/L", 2) → "L/(mol*s)"
 *   ("mol/L", 1) → "1/s"
 *   ("mol/L", 0) → "mol/(L*s)"
 *   ("mol/m^3", 2) → "m^3/(mol*s)"
 */
function formatExpectedRateUnits(speciesUnits: string, totalOrder: number): string {
  let exp = 1 - totalOrder
  if (exp === 0) return '1/s'
  let [num, den] = splitUnitNumDen(speciesUnits)
  if (exp < 0) {
    ;[num, den] = [den, num]
    exp = -exp
  }
  let numStr = powerFactor(num, exp)
  const denFactors: string[] = []
  const df = powerFactor(den, exp)
  if (df !== '') denFactors.push(df)
  denFactors.push('s')
  if (numStr === '') numStr = '1'
  if (denFactors.length === 1) return `${numStr}/${denFactors[0]}`
  return `${numStr}/(${denFactors.join('*')})`
}

/**
 * If the rate expression is a bare variable reference (species or parameter
 * name), return its declared unit string. Otherwise returns the empty string.
 * Matches Go's rateVarName + unit lookup so rate_units details align across
 * bindings for the bare-variable case that the cross-binding fixture uses.
 */
function rateUnitStringFromExpression(rate: Expression, reactionSystem: ReactionSystem): string {
  if (typeof rate !== 'string') return ''
  const param = (reactionSystem.parameters || {})[rate]
  if (param && param.units) return param.units
  const species = (reactionSystem.species || {})[rate]
  if (species && species.units) return species.units
  return ''
}

/**
 * Enforce the mass-action dimensional constraint for reaction rates from
 * spec §7.4: rate dimensions must equal concentration^(1-total_order)/time,
 * where the reference concentration unit is the first substrate's declared
 * units. Mirrors validate_reaction_system_dimensions in Julia and
 * validateReactionRateUnits in Go.
 *
 * Skipped when the first substrate is dimensionless (mol/mol, ppm, …)
 * because atmospheric-chemistry rate expressions commonly bake a
 * number-density factor into the rate constant, making the
 * stoichiometric-order convention ambiguous there.
 */
function validateReactionRateUnits(
  reactionSystem: ReactionSystem,
  systemPath: string,
): StructuralError[] {
  const errors: StructuralError[] = []
  if (!reactionSystem.reactions) return errors

  const bindings = buildReactionSystemUnitBindings(reactionSystem)
  const speciesMap = reactionSystem.species || {}

  for (let i = 0; i < reactionSystem.reactions.length; i++) {
    const reaction = reactionSystem.reactions[i]
    if (!reaction || !reaction.substrates || reaction.substrates.length === 0) continue

    const firstSubstrate = reaction.substrates[0]
    const firstSpecies = speciesMap[firstSubstrate.species]
    if (!firstSpecies || !firstSpecies.units) continue

    const concUnit = parseUnit(firstSpecies.units)
    if (isDimensionless(concUnit)) continue

    let resolvable = true
    let totalOrder = 0
    for (const sub of reaction.substrates) {
      if (!sub || !bindings.has(sub.species)) {
        resolvable = false
        break
      }
      if (typeof sub.stoichiometry === 'number') {
        totalOrder += sub.stoichiometry
      }
    }
    if (!resolvable) continue

    const rateResult = checkDimensions(reaction.rate, bindings)
    // COUPLING: this skip test string-matches the human-readable warning prose
    // emitted by checkDimensions in units.ts. It is intentionally left as a
    // substring match here — units.ts owns that wording and is off-limits to
    // this module. A Wave-2 units effort is separately introducing structured
    // warning codes; do NOT depend on those here until they land (changing this
    // to a code check now would decouple from the current units.ts message).
    if (rateResult.warnings.some((w) => w.includes('Unknown variable'))) continue

    const expectedPower = 1 - totalOrder
    const expectedDims: CanonicalDims = {}
    for (const [k, v] of Object.entries(concUnit.dims)) {
      if (v == null) continue
      expectedDims[k as keyof CanonicalDims] = v * expectedPower
    }
    const sKey = 's' as keyof CanonicalDims
    expectedDims[sKey] = (expectedDims[sKey] ?? 0) - 1

    if (dimsEqual(rateResult.dimensions.dims, expectedDims)) continue

    errors.push({
      path: `${systemPath}/reactions/${i}`,
      code: ERROR_CODES.UNIT_INCONSISTENCY,
      message: 'Reaction rate expression has incompatible units for reaction stoichiometry',
      details: {
        reaction_id: reaction.id,
        rate_units: rateUnitStringFromExpression(reaction.rate, reactionSystem),
        expected_rate_units: formatExpectedRateUnits(firstSpecies.units, totalOrder),
        reaction_order: totalOrder,
      },
    })
  }

  return errors
}

/**
 * Well-known physical constants whose declared units can be dimensionally
 * verified against a canonical form. Conservative on purpose — names chosen
 * to minimize collision with common non-constant uses (e.g., no `c` for
 * speed of light, which conflicts with concentration). Mirrors Python's
 * `_KNOWN_PHYSICAL_CONSTANTS` (gt-j91l / gt-3tgv).
 */
const KNOWN_PHYSICAL_CONSTANTS: Array<{
  name: string
  canonical: string
  description: string
}> = [
  { name: 'R', canonical: 'J/(mol*K)', description: 'ideal gas constant' },
  { name: 'k_B', canonical: 'J/K', description: 'Boltzmann constant' },
  { name: 'N_A', canonical: '1/mol', description: 'Avogadro constant' },
]

/**
 * Return true if the expression tree references a variable by exact name
 * (string leaf match).
 */
function expressionReferencesName(expr: Expr | undefined | null, name: string): boolean {
  if (expr === undefined || expr === null) return false
  if (typeof expr === 'string') return expr === name
  if (isExprNode(expr)) {
    let found = false
    forEachChild(expr, (child) => {
      if (!found && expressionReferencesName(child, name)) found = true
    })
    return found
  }
  return false
}

/**
 * Flag parameters whose name matches a well-known physical constant but whose
 * declared units are dimensionally incompatible with the canonical form (e.g.,
 * `R` declared as `kcal/mol` — missing temperature — instead of `J/(mol*K)`).
 * Reports at the first observed-variable usage site in the same model;
 * otherwise at the declaration. Mirrors Python's
 * `parse._check_physical_constant_units`.
 */
function validatePhysicalConstantUnits(model: Model, modelPath: string): StructuralError[] {
  const errors: StructuralError[] = []
  const variables = model.variables || {}

  for (const { name, canonical, description } of KNOWN_PHYSICAL_CONSTANTS) {
    const declaration = variables[name]
    if (!declaration) continue
    if (declaration.type !== 'parameter') continue
    const declared = declaration.units
    if (!declared) continue

    const declaredUnit = parseUnit(declared)
    const canonicalUnit = parseUnit(canonical)
    if (dimsEqual(declaredUnit.dims, canonicalUnit.dims)) continue

    let usageName: string | undefined
    for (const [otherName, otherVar] of Object.entries(variables)) {
      if (otherVar.type !== 'observed') continue
      if (expressionReferencesName(otherVar.expression, name)) {
        usageName = otherName
        break
      }
    }
    const targetName = usageName ?? name
    errors.push({
      path: `${modelPath}/variables/${targetName}`,
      code: ERROR_CODES.UNIT_INCONSISTENCY,
      message: 'Physical constant used with incorrect dimensional analysis',
      details: {
        constant_name: name,
        constant_description: description,
        declared_units: declared,
        canonical_units: canonical,
      },
    })
  }
  return errors
}

const AFFINE_TEMP_UNITS = new Set(['C', 'degC', 'Celsius'])

function isAffineTempUnit(u: string): boolean {
  return AFFINE_TEMP_UNITS.has(u.trim())
}

/**
 * Flag observed variables whose expression has the shape `<numeric> * <var>`
 * (or `<var> * <numeric>`) when the declared output units and the source
 * variable's units are dimensionally compatible but the numeric literal
 * disagrees with the correct linear scale factor. Mirrors Python's
 * parse._check_conversion_factor_consistency (gt-nvdv) and Go's
 * checkConversionFactorConsistency (gt-abh1). Affine conversions
 * (e.g., degC→K) are excluded.
 */
function validateConversionFactorConsistency(model: Model, modelPath: string): StructuralError[] {
  const errors: StructuralError[] = []
  const variables = model.variables || {}

  for (const [vname, vdef] of Object.entries(variables)) {
    if (vdef.type !== 'observed') continue
    if (vdef.expression === undefined || vdef.expression === null) continue
    const lhsUnits = vdef.units
    if (!lhsUnits) continue

    const expr = vdef.expression
    if (!isExprNode(expr)) continue
    const node = expr
    if (node.op !== '*' || !node.args || node.args.length !== 2) continue

    let numeric: number | undefined
    let varRef: string | undefined
    for (const a of node.args) {
      if (typeof a === 'number') {
        numeric = a
      } else if (typeof a === 'string') {
        varRef = a
      }
    }
    if (numeric === undefined || varRef === undefined) continue

    const src = variables[varRef]
    if (!src || !src.units) continue
    const srcUnits = src.units
    if (srcUnits === lhsUnits) continue

    let srcU: ParsedUnit
    let lhsU: ParsedUnit
    try {
      srcU = parseUnit(srcUnits)
      lhsU = parseUnit(lhsUnits)
    } catch {
      continue
    }
    if (!dimsEqual(srcU.dims, lhsU.dims)) continue
    if (isAffineTempUnit(srcUnits) || isAffineTempUnit(lhsUnits)) continue
    if (lhsU.scale === 0) continue

    const factor = srcU.scale / lhsU.scale
    if (factor === 0) continue

    const tol = 1e-9 * Math.max(Math.abs(factor), 1)
    if (Math.abs(numeric - factor) <= tol) continue

    errors.push({
      path: `${modelPath}/variables/${vname}`,
      code: ERROR_CODES.UNIT_INCONSISTENCY,
      message: 'Unit conversion factor is incorrect for specified unit transformation',
      details: {
        variable: vname,
        declared_units: lhsUnits,
        source_units: srcUnits,
        declared_factor: numeric,
        expected_factor: factor,
      },
    })
  }
  return errors
}

/**
 * Flag subsystem entries that are unresolved SubsystemRef objects.
 * The synchronous validate() function cannot resolve external file references;
 * call resolveSubsystemRefs() before validate() to inline them first.
 */
/**
 * Flag any `{ref}` (unresolved SubsystemRef) entries in one component's
 * `subsystems` map. Shared by the models and reaction-systems passes, which
 * differ only in the JSON path prefix.
 */
function flagRefSubsystems(
  subsystems: Record<string, unknown>,
  pathPrefix: string,
): StructuralError[] {
  const errors: StructuralError[] = []
  for (const [subsystemName, subsystem] of Object.entries(subsystems)) {
    if (subsystem && typeof subsystem === 'object' && 'ref' in subsystem) {
      const ref = (subsystem as SubsystemRef).ref
      if (typeof ref === 'string') {
        errors.push({
          path: `${pathPrefix}/${subsystemName}`,
          code: ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF,
          message: `Subsystem '${subsystemName}' is an unresolved file reference ('${ref}'). Call resolveSubsystemRefs() before validate().`,
          details: { ref },
        })
      }
    }
  }
  return errors
}

function validateSubsystemRefs(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []
  if (esmFile.models) {
    for (const [modelName, model] of Object.entries(esmFile.models)) {
      if ('ref' in model || !model.subsystems) continue
      errors.push(...flagRefSubsystems(model.subsystems, `/models/${modelName}/subsystems`))
    }
  }
  if (esmFile.reaction_systems) {
    for (const [systemName, system] of Object.entries(esmFile.reaction_systems)) {
      if (!system.subsystems) continue
      errors.push(
        ...flagRefSubsystems(system.subsystems, `/reaction_systems/${systemName}/subsystems`),
      )
    }
  }
  return errors
}

/**
 * Flag model variables where default_units is set and the conversion from
 * default_units to units is affine (e.g., degC → K) rather than a pure
 * scale factor. Affine unit conversions are not expressible as a simple
 * default value and must use an explicit expression instead.
 */
function validateDefaultUnits(model: Model, modelPath: string): StructuralError[] {
  const errors: StructuralError[] = []
  if (!model.variables) return errors
  for (const [vname, vdef] of Object.entries(model.variables)) {
    const { units, default_units } = vdef
    if (!default_units || !units || default_units === units) continue
    if (isAffineTempUnit(default_units) || isAffineTempUnit(units)) {
      errors.push({
        path: `${modelPath}/variables/${vname}`,
        code: ERROR_CODES.UNIT_INCONSISTENCY,
        message: `default_units '${default_units}' requires an affine conversion to/from '${units}'; use an expression instead of a scalar default`,
        details: { variable: vname, units, default_units },
      })
    }
  }
  return errors
}

/**
 * Check coupling entries reference integrity
 */
function validateCouplingIntegrity(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []

  if (!esmFile.coupling) return errors

  // Collect all available systems
  const availableSystems = new Set([
    ...Object.keys(esmFile.models || {}),
    ...Object.keys(esmFile.reaction_systems || {}),
    ...Object.keys(esmFile.data_loaders || {}),
  ])

  for (let i = 0; i < esmFile.coupling.length; i++) {
    const coupling = esmFile.coupling[i]
    const couplingPath = `/coupling/${i}`

    if (coupling.type === 'operator_compose' || coupling.type === 'couple') {
      // operator_compose and couple both carry a `systems` list and their
      // existence checks were byte-identical, so the two branches are merged.
      const systemsEntry = coupling as CouplingOperatorCompose | CouplingCouple
      for (const systemName of systemsEntry.systems) {
        if (!availableSystems.has(systemName)) {
          errors.push({
            path: `${couplingPath}/systems`,
            code: ERROR_CODES.UNDEFINED_SYSTEM,
            message: `Coupling entry references nonexistent system "${systemName}"`,
            details: { system: systemName },
          })
        }
      }
    } else if (coupling.type === 'variable_map') {
      // Check from/to system references exist
      const vmEntry = coupling as CouplingVariableMap
      // `factor` is a scaling slot for the scaling string transforms only; an
      // Expression transform spells its own arithmetic, so a `factor` alongside
      // it is a modeling error.
      //
      // NOTE (kept, not deleted): this check is effectively UNREACHABLE through
      // the public `validate()` — the JSON schema already rejects the
      // `factor` + Expression-transform combination, and structural validation
      // runs only when `schema_errors.length === 0`. It is retained as a
      // defensive structural mirror of that schema rule (and would fire if
      // performStructuralValidation were ever driven on a schema-invalid file).
      if (
        vmEntry.factor !== undefined &&
        typeof vmEntry.transform === 'object' &&
        vmEntry.transform !== null
      ) {
        errors.push({
          path: `${couplingPath}/factor`,
          code: ERROR_CODES.FACTOR_WITH_EXPRESSION_TRANSFORM,
          message: `variable_map with an Expression transform must not carry 'factor'; fold the scaling into the expression`,
          details: { factor: vmEntry.factor },
        })
      }
      for (const field of ['from', 'to'] as const) {
        const ref = vmEntry[field]
        if (typeof ref === 'string' && ref.includes('.')) {
          const [systemName, varName] = splitScopedRef(ref)
          if (!availableSystems.has(systemName)) {
            errors.push({
              path: `${couplingPath}/${field}`,
              code: ERROR_CODES.UNRESOLVED_SCOPED_REF,
              message: `Scoped reference "${ref}" references nonexistent system "${systemName}"`,
              details: { reference: ref, system: systemName },
            })
          } else {
            // Check variable exists in the system
            const system =
              (esmFile.models || {})[systemName] || (esmFile.reaction_systems || {})[systemName]
            if (system) {
              const vars = (system as any).variables || (system as any).species || {}
              const params = (system as any).parameters || {}
              if (!vars[varName] && !params[varName]) {
                // Check data loaders
                const dataLoader = (esmFile.data_loaders || {})[systemName]
                const loaderVariables = dataLoader?.variables || {}
                if (!loaderVariables[varName]) {
                  errors.push({
                    path: `${couplingPath}/${field}`,
                    code: ERROR_CODES.UNRESOLVED_SCOPED_REF,
                    message: `Variable "${varName}" not found in system "${systemName}"`,
                    details: { reference: ref, system: systemName, variable: varName },
                  })
                }
              }
            }
          }
        }
      }
    }
  }

  return errors
}

/**
 * Check for circular cross-model variable references (without explicit coupling)
 */
function validateCircularReferences(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []
  if (!esmFile.models) return errors

  // Build dependency graph: which models reference which other models
  const modelDeps = new Map<string, Set<string>>()

  for (const [modelName, model] of Object.entries(esmFile.models)) {
    const deps = new Set<string>()
    // Check all equations for cross-model references (unresolved
    // SubsystemRef entries carry no equations)
    const equations = 'ref' in model ? [] : model.equations || []
    for (const equation of equations) {
      const refs = [
        ...extractVariableReferences(equation.lhs),
        ...extractVariableReferences(equation.rhs),
      ]
      for (const ref of refs) {
        if (ref.includes('.')) {
          const targetModel = ref.split('.')[0]
          if (targetModel !== modelName && esmFile.models[targetModel]) {
            deps.add(targetModel)
          }
        }
      }
    }
    modelDeps.set(modelName, deps)
  }

  // Detect cycles using DFS
  const visited = new Set<string>()
  const inStack = new Set<string>()

  // Returns void: the boolean was never read by any caller (cycles are
  // reported by pushing to `errors`, and recursion ignores the result).
  function dfs(node: string, path: string[]): void {
    if (inStack.has(node)) {
      const cycleStart = path.indexOf(node)
      const cycle = path.slice(cycleStart).concat(node)
      errors.push({
        path: '/models',
        message: `Circular dependency detected: ${cycle.join(' → ')}`,
        code: ERROR_CODES.CIRCULAR_DEPENDENCY,
        details: { cycle },
      })
      return
    }
    if (visited.has(node)) return

    visited.add(node)
    inStack.add(node)
    path.push(node)

    for (const dep of modelDeps.get(node) || []) {
      dfs(dep, [...path])
    }

    inStack.delete(node)
  }

  for (const modelName of modelDeps.keys()) {
    if (!visited.has(modelName)) {
      dfs(modelName, [])
    }
  }

  return errors
}

/**
 * Validate data loader variable references in coupling entries.
 *
 * NOTE (overlap, deferred): `validateCouplingIntegrity` also checks a
 * variable_map `from`/`to` against a system's members and, for a data-loader
 * head, emits `unresolved_scoped_ref` — whereas THIS pass emits the more
 * specific `undefined_data_loader_variable`. The two do not collide in
 * practice: `validateCouplingIntegrity` only reaches the loader-variable check
 * when the head also resolves as a model/reaction_system (a name collision),
 * otherwise `system` is undefined and it emits nothing. Consolidating them
 * would change WHICH code fires for such a collision, so they are kept separate
 * and the overlap is documented rather than merged.
 */
function validateDataLoaderReferences(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []
  if (!esmFile.coupling || !esmFile.data_loaders) return errors

  for (let i = 0; i < esmFile.coupling.length; i++) {
    const coupling = esmFile.coupling[i]
    const couplingPath = `/coupling/${i}`

    if (coupling.type === 'variable_map' && 'from' in coupling) {
      const from = (coupling as any).from as string
      if (from && from.includes('.')) {
        // Keep the FULL variable path after the source head — a 2-limit split
        // (`from.split('.', 2)`) would truncate "Loader.a.b" to variable "a"
        // (a JS-vs-Go SplitN discrepancy). splitScopedRef mirrors Go's
        // strings.SplitN(from, ".", 2) remainder semantics.
        const [sourceName, varName] = splitScopedRef(from)
        // Check if source is a data loader
        if (esmFile.data_loaders[sourceName]) {
          const loader = esmFile.data_loaders[sourceName]
          const loaderVariables = loader.variables || {}
          if (!(varName in loaderVariables)) {
            errors.push({
              path: `${couplingPath}/from`,
              message: `Data loader '${sourceName}' does not expose variable '${varName}'`,
              code: ERROR_CODES.UNDEFINED_DATA_LOADER_VARIABLE,
              details: {
                data_loader: sourceName,
                variable: varName,
                available: Object.keys(loaderVariables),
              },
            })
          }
        }
      }
    }
  }

  return errors
}

/**
 * Validate file_period and frequency fields in data loader temporal sections
 * are valid ISO 8601 durations
 */
function validateTemporalResolution(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []
  if (!esmFile.data_loaders) return errors

  // ISO 8601 duration pattern: P[nY][nM][nD][T[nH][nM][nS]]
  const iso8601DurationPattern =
    /^P(?:\d+Y)?(?:\d+M)?(?:\d+D)?(?:T(?:\d+H)?(?:\d+M)?(?:\d+(?:\.\d+)?S)?)?$/
  const isValidDuration = (v: unknown): v is string =>
    typeof v === 'string' && v !== 'P' && v !== 'PT' && iso8601DurationPattern.test(v)

  const durationFields: Array<'file_period' | 'frequency'> = ['file_period', 'frequency']

  for (const [loaderName, loader] of Object.entries(esmFile.data_loaders)) {
    const temporal = loader.temporal
    if (!temporal || typeof temporal !== 'object') continue
    for (const field of durationFields) {
      const value = temporal[field]
      if (value !== undefined && !isValidDuration(value)) {
        errors.push({
          path: `/data_loaders/${loaderName}/temporal/${field}`,
          message: `Invalid ISO 8601 duration: '${value}'`,
          code: ERROR_CODES.INVALID_TEMPORAL_DURATION,
          details: { field, value },
        })
      }
    }
  }

  return errors
}

/**
 * Promote dimensional-consistency warnings to structural errors for invalid
 * files. The classification is carried on the warning itself
 * (UnitWarning.code, assigned in units.ts beside the message definitions).
 */
function promoteUnitWarningsToErrors(warnings: UnitWarning[]): StructuralError[] {
  return warnings
    .filter((warning) => warning.code === ERROR_CODES.DIMENSIONAL_MISMATCH)
    .map((warning) => ({
      // NOTE: the `'$'` root-path sentinel here (and in validate()'s catch
      // blocks) is left as-is rather than normalized to the schema layer's
      // `'/'`. It is only emitted for a location-less warning; changing it
      // would alter an emitted `path` string, which the cross-language goldens
      // may pin, so normalization is deferred.
      path: warning.location ? `/${warning.location.replace(/\./g, '/')}` : '$',
      message: warning.message,
      code: ERROR_CODES.UNIT_ERROR,
      details: { equation: warning.equation || '' },
    }))
}

/**
 * Main structural validation function. Runs every structural (post-schema)
 * validator over a loaded ESM file and returns the aggregated errors.
 */
function performStructuralValidation(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []

  // Collect systems that participate in coupling — these may reference
  // variables from other systems, so equation balance and reference
  // integrity checks must be relaxed.
  const coupledSystems = new Set<string>()
  if (esmFile.coupling) {
    for (const entry of esmFile.coupling) {
      if ('systems' in entry && Array.isArray((entry as any).systems)) {
        for (const s of (entry as any).systems) {
          coupledSystems.add(s)
        }
      }
      if ('from' in entry && typeof (entry as any).from === 'string') {
        const fromSystem = (entry as any).from.split('.')[0]
        coupledSystems.add(fromSystem)
      }
      if ('to' in entry && typeof (entry as any).to === 'string') {
        const toSystem = (entry as any).to.split('.')[0]
        coupledSystems.add(toSystem)
      }
    }
  }

  // Validate models. Unresolved SubsystemRef entries are reported by
  // validateSubsystemRefs below; DataLoader subsystems carry no equations.
  if (esmFile.models) {
    for (const [modelName, model] of Object.entries(esmFile.models)) {
      if (!isInlineModel(model)) continue
      const modelPath = `/models/${modelName}`
      const isCoupled = coupledSystems.has(modelName)

      // Skip equation balance and reference integrity for coupled models,
      // as they may reference variables provided by other systems.
      if (!isCoupled) {
        errors.push(...validateEquationBalance(model, modelPath))
        errors.push(...validateReferenceIntegrity(model, modelPath, esmFile))
      }
      errors.push(...validateEventConsistency(model, modelPath))
      errors.push(...validatePhysicalConstantUnits(model, modelPath))
      errors.push(...validateConversionFactorConsistency(model, modelPath))
      errors.push(...validateDefaultUnits(model, modelPath))

      // Recursively validate subsystems
      if (model.subsystems) {
        for (const [subsystemName, subsystem] of Object.entries(model.subsystems)) {
          if (!isInlineModel(subsystem)) continue
          const subsystemPath = `${modelPath}/subsystems/${subsystemName}`
          if (!isCoupled) {
            errors.push(...validateEquationBalance(subsystem, subsystemPath))
            errors.push(...validateReferenceIntegrity(subsystem, subsystemPath, esmFile))
          }
          errors.push(...validateEventConsistency(subsystem, subsystemPath))
          errors.push(...validatePhysicalConstantUnits(subsystem, subsystemPath))
          errors.push(...validateConversionFactorConsistency(subsystem, subsystemPath))
        }
      }
    }
  }

  // Validate reaction systems
  if (esmFile.reaction_systems) {
    for (const [systemName, reactionSystem] of Object.entries(esmFile.reaction_systems)) {
      const systemPath = `/reaction_systems/${systemName}`

      errors.push(...validateReactionConsistency(reactionSystem, systemPath))
      errors.push(...validateReactionRateUnits(reactionSystem, systemPath))
      errors.push(...validateReactionSystemICs(reactionSystem, systemName, systemPath))

      // Recursively validate subsystems (unresolved SubsystemRef
      // entries carry no species/reactions — validating them is a
      // no-op, so skip them; validateSubsystemRefs flags them below)
      if (reactionSystem.subsystems) {
        for (const [subsystemName, subsystem] of Object.entries(reactionSystem.subsystems)) {
          if ('ref' in subsystem) continue
          const subsystemPath = `${systemPath}/subsystems/${subsystemName}`
          errors.push(...validateReactionConsistency(subsystem, subsystemPath))
          errors.push(...validateReactionRateUnits(subsystem, subsystemPath))
        }
      }
    }
  }

  // Validate subsystem ref resolution
  errors.push(...validateSubsystemRefs(esmFile))

  // Validate coupling integrity
  errors.push(...validateCouplingIntegrity(esmFile))

  // Check for circular cross-model references
  errors.push(...validateCircularReferences(esmFile))

  // Validate data loader variable references in coupling
  errors.push(...validateDataLoaderReferences(esmFile))

  // Validate temporal resolution in data loaders
  errors.push(...validateTemporalResolution(esmFile))

  return errors
}

/**
 * Structured error code for an exception thrown by load(). Explicit mapping
 * (rather than deriving a code from the constructor name) so the codes are
 * stable strings that renames cannot silently change.
 */
function loadErrorCode(error: Error): string {
  if (error instanceof SchemaValidationError) return ERROR_CODES.SCHEMA_VALIDATION_ERROR
  if (error instanceof ParseError) return ERROR_CODES.PARSE_ERROR
  if (error instanceof ExpressionTemplateError) return ERROR_CODES.EXPRESSION_TEMPLATE_ERROR
  if (error instanceof EnumLoweringError) return ERROR_CODES.ENUM_LOWERING_ERROR
  if (error instanceof LosslessJsonParseError) return ERROR_CODES.JSON_PARSE_ERROR
  if (error instanceof CanonicalNonfiniteError) return ERROR_CODES.NONFINITE_NUMBER
  return ERROR_CODES.LOAD_ERROR
}

/**
 * Convert a SchemaError to our ValidationError format
 */
function convertSchemaError(error: SchemaError): ValidationError {
  return {
    path: error.path,
    message: error.message,
    code: error.keyword,
    details: {
      keyword: error.keyword,
    },
  }
}

/**
 * Validate ESM data and return structured validation result.
 *
 * @param data - ESM data as JSON string or object
 * @returns ValidationResult with validation status and errors
 */
export function validate(data: string | object): ValidationResult {
  const schema_errors: ValidationError[] = []
  const structural_errors: ValidationError[] = []
  const unit_warnings: UnitWarning[] = []

  try {
    let parsedData: object

    // Parse JSON if string, routing through the same `losslessJsonParse`
    // machinery `load()` uses rather than a divergent bare `JSON.parse`. The
    // tagged int/float leaves it produces are immediately stripped back to
    // plain JS numbers (`stripNumericLiterals`) so this non-canonical surface
    // (schema validation + `load(object)` below both expect plain numbers) is
    // unchanged from the previous `JSON.parse` result. A parse failure is
    // mapped to the historical `json_parse_error` envelope below — same `code`,
    // `path`, `details` shape, and `Invalid JSON: ` prefix — so the emitted
    // malformed-input diagnostic stays in the shape callers and
    // `validate.test.ts` expect.
    if (typeof data === 'string') {
      try {
        parsedData = stripNumericLiterals(losslessJsonParse(data)) as object
      } catch (e: unknown) {
        const error = e as Error
        return {
          is_valid: false,
          schema_errors: [
            {
              path: '$',
              message: `Invalid JSON: ${error.message}`,
              code: ERROR_CODES.JSON_PARSE_ERROR,
              details: { error: error.message },
            },
          ],
          structural_errors: [],
          unit_warnings: [],
        }
      }
    } else {
      parsedData = data
    }

    // Validate against schema
    const schemaErrors = validateSchema(parsedData)
    schema_errors.push(...schemaErrors.map(convertSchemaError))

    // Try structural validation by loading the data
    if (schema_errors.length === 0) {
      try {
        // Schema validation already ran above; collect unit warnings
        // from the load pipeline instead of re-running validateUnits.
        const esmFile = load(parsedData, {
          assumeValid: true,
          onUnitWarning: (warning) => unit_warnings.push(warning),
        })
        // Perform structural validation
        structural_errors.push(...performStructuralValidation(esmFile))

        // Promote unit incompatibility warnings to structural errors
        structural_errors.push(...promoteUnitWarningsToErrors(unit_warnings))
      } catch (e: unknown) {
        const error = e as Error
        structural_errors.push({
          path: '$',
          message: error.message || String(e),
          code: loadErrorCode(error),
          details: {
            exception_type: error.constructor.name,
            error: error.message || String(e),
          },
        })
      }
    }
  } catch (e: unknown) {
    // Unexpected error
    const error = e as Error
    return {
      is_valid: false,
      schema_errors: [
        {
          path: '$',
          message: `Validation failed with unexpected error: ${error.message || String(e)}`,
          code: ERROR_CODES.UNEXPECTED_ERROR,
          details: {
            exception_type: error.constructor.name,
            error: error.message || String(e),
          },
        },
      ],
      structural_errors: [],
      unit_warnings: [],
    }
  }

  return {
    is_valid: schema_errors.length === 0 && structural_errors.length === 0,
    schema_errors,
    structural_errors,
    unit_warnings,
  }
}
