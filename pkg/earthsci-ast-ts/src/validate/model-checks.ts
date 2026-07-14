/**
 * Structural validators that operate on a single Model: equation/unknown
 * balance, reference integrity, event consistency, and unit-related checks
 * (physical constants, conversion factors, default units).
 */

import { isExprNode } from '../expression.js'
import { ERROR_CODES } from '../errors.js'
import { parseUnit, tryParseUnit, dimsEqual, type ParsedUnit } from '../units.js'
import type { EsmFile, Model, Expression, AffectEquation } from '../types.js'
import type { StructuralError } from './types.js'
import {
  extractVariableReferences,
  collectIndexSymbols,
  lhsAssignmentTarget,
  countDerivatives,
  resolveScopedReference,
  expressionReferencesName,
} from './expr-utils.js'
import { isAffineTempUnit } from './unit-format.js'
import { forEachExpressionScope } from '../traverse.js'

/**
 * Check equation-unknown balance for a model.
 *
 * The balance rule depends on the model's `system_kind` (spec §4, default
 * `"ode"`), because the two kinds are well-posed in different ways:
 *
 *  - **ODE / SDE / PDE** — a TIME-STEPPING system. Each state variable needs a
 *    defining time derivative, so the count is of DERIVATIVES (`D(v,t)`, or the
 *    derivative carried inside an `aggregate` contracted body), plus the
 *    element-defined relational form (`index(v,i) = aggregate(…)`) that credits
 *    the state variable its LHS assigns to.
 *
 *  - **NONLINEAR (algebraic)** — a system with NO time derivative at all
 *    (aerosol equilibrium, Mogi inversion). Well-posedness is simply UNKNOWNS vs
 *    EQUATIONS: `n` state variables need `n` equations, and an equation is any
 *    equation — its LHS need not be (and generally is not) a bare variable. In
 *    `tests/valid/nonlinear_isorropia_shape.esm` the closing equation is
 *    `H*H*SO4 = Ksp`, whose LHS is a PRODUCT. Counting only derivative or
 *    bare-assignment LHSs credited it zero, so a perfectly balanced 2×2
 *    equilibrium system was reported as `equation_count_mismatch` — a false
 *    rejection of a valid file, and of the one system kind whose defining
 *    feature is that it has no derivatives.
 */
export function validateEquationBalance(model: Model, modelPath: string): StructuralError[] {
  const errors: StructuralError[] = []

  // Count state variables — the UNKNOWNS, under either rule.
  const stateVariables = Object.entries(model.variables || {})
    .filter(([_, variable]) => variable.type === 'state')
    .map(([name, _]) => name)

  const equations = model.equations || []

  // An algebraic (nonlinear) system balances unknowns against the equation
  // COUNT: every equation constrains the system, whatever shape its LHS has.
  if (model.system_kind === 'nonlinear') {
    if (stateVariables.length !== equations.length) {
      errors.push({
        path: modelPath,
        code: ERROR_CODES.EQUATION_COUNT_MISMATCH,
        message: `Number of equations (${equations.length}) does not match number of unknowns (${stateVariables.length})`,
        details: {
          state_variables: stateVariables,
          ode_equations: equations.length,
          missing_equations_for: [],
        },
      })
    }
    return errors
  }

  // Count equations driving each state variable. A normal ODE contributes a
  // D(var,t) derivative; an aggregate LHS contributes the derivative carried
  // in its contracted body. A relational / algebraic equation with no time
  // derivative (the aggregate-IR `index(v, i) = aggregate(...)` form emitted
  // by skolem / distinct / rank) instead credits the state variable its LHS
  // assigns to, so element-defined state still balances the unknown count.
  const derivativeCounts: { [variable: string]: number } = {}

  for (const equation of equations) {
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
 * The Cartesian spatial-coordinate names that are IMPLICITLY declared — never
 * `undefined_variable`.
 *
 * A spatial coordinate is not a declared variable. In v0.8.0 a domain carries no
 * grid (spec §11: "A domain does not carry spatial-grid geometry"), so a
 * coordinate is "ordinary data associated with the spatial index" and is
 * referenced BY NAME from a coordinate expression — e.g. the expression initial
 * condition `ic(u) ~ 0.5*(1 + tanh((x - 0.3)/0.15))` in
 * `tests/valid/initial_conditions/expression_ignition_front_1d.esm`, where `x`
 * is the 1-D spatial coordinate and is declared nowhere. Flagging it as an
 * undefined variable rejected that valid, pinned fixture.
 *
 * Named axes (`lon`, `lat`, `lev`) need no entry here: they are `index_sets`
 * keys, which {@link validateReferenceIntegrity} already credits. This set is
 * only the conventional SHORT axes, matching the Python binding's
 * `_CLOSED_SHORT_AXES`.
 */
const SPATIAL_COORDINATE_NAMES: readonly string[] = ['x', 'y', 'z']

/**
 * The independent (time) variable's name: the domain's `independent_variable`,
 * defaulting to `"t"` (spec §11.3). It is IMPLICITLY declared — spec §5.3's own
 * event example writes `t` in an equation with no declaration anywhere, and
 * `tests/valid/cadence/pure_pointwise.esm` writes the analytic forcing
 * `A*sin(omega*t)` in a file with no `domain` block at all.
 */
function independentVariableName(esmFile: EsmFile): string {
  return esmFile.domain?.independent_variable || 't'
}

/**
 * The names every component may reference WITHOUT declaring them: the domain's
 * independent variable and the conventional spatial coordinates. Shared by the
 * model and reaction-system reference-integrity passes so the two cannot drift.
 */
export function implicitNames(esmFile: EsmFile): Set<string> {
  return new Set<string>([independentVariableName(esmFile), ...SPATIAL_COORDINATE_NAMES])
}

/**
 * Check reference integrity for a model — across EVERY expression-bearing field,
 * not just `equations`.
 *
 * This used to walk `model.equations` and nothing else, which made an undefined
 * name anywhere ELSE in the document INVISIBLE: an observed variable's
 * `expression`, a solver `guess`, an event condition, an affect's RHS. That is a
 * false NEGATIVE — nothing caught it and no fixture pinned it, which is exactly
 * why it survived (and is the same blind spot that let several `units_*` invalid
 * fixtures hide their defect inside an observed expression).
 *
 * The fix is structural rather than a second hand-rolled walk. Two keystones
 * compose, and every name in the document is the product of the two:
 *
 *   - {@link forEachExpressionScope} (traverse.ts) enumerates WHICH expressions
 *     the component has and the JSON Pointer each one lives at;
 *   - `extractVariableReferences` / `collectIndexSymbols` descend INSIDE one
 *     expression through `forEachChild` (expression.ts), so every
 *     expression-bearing sidecar — `expr`, `filter`, `key`, `lower`, `upper`,
 *     `values`, `axes`, `bindings` — is visited, not just `args`.
 *
 * Adding a new expression position to the format now means teaching ONE
 * enumerator, instead of silently under-checking until someone notices.
 */
/**
 * (k) The COMPLETE set of sites at which a name may be DECLARED for a component
 * — the union a reference must be checked against (esm-spec §4.9.5).
 *
 * Reference integrity is only ever as good as this set. Miss a site and the
 * checker FALSELY REJECTS valid documents, which is the failure mode that made
 * the previous design so tempting: the orchestrator simply SKIPPED reference
 * integrity for any model appearing in a coupling entry, because such a model
 * legitimately names things it does not declare locally. That bought
 * false-positive safety at the cost of a total false NEGATIVE — an entire
 * coupled model went unchecked, and any undefined variable in it was invisible.
 *
 * The sites, exhaustively:
 *
 *   1. `variables` — states, parameters and observed alike (one map, §4.2).
 *   2. `index_sets` — the document-scoped registry; an `aggregate` may name a
 *      set positionally, so the name is an identifier, not a variable.
 *   3. BINDER symbols — `arrayop`/`aggregate` `output_idx`, `argmin`/`argmax`
 *      witnesses, an `integral`'s integration `var`. Scope-local, so they are
 *      supplied per-scope by the caller, not here.
 *   4. IMPLICIT coordinates — the domain's `independent_variable` and the
 *      spatial coordinate names. Independent coordinates are not unknowns and
 *      never appear in `variables`.
 *   5. `_var` — the §6.4 operator-model placeholder, legal WHEREVER A STATE
 *      VARIABLE IS legal (equation LHS/RHS, event affects, `read_vars`) in a
 *      model that is operator-composed or is a coupling target. Substitution
 *      supplies its referent at composition time.
 *   6. COUPLING-INJECTED names — `coupling[i].config.callback_variables[j].name`,
 *      which a `callback` entry injects into `config.target_system`. These are
 *      real declarations made from OUTSIDE the component, and missing them is
 *      what falsely rejected `tests/coupling/callback_examples.esm`.
 *   7. Names reachable by SCOPED reference (`Other.x`, `Calendar.y`) — resolved
 *      separately by `resolveScopedReference`, against the file root AND the
 *      enclosing component's own mounted subsystems.
 *
 * With the union complete, a coupled model no longer needs an exemption: it is
 * checked like everything else, and the names coupling gives it are simply
 * DECLARED.
 */
export function declaredNamesFor(
  model: Model,
  modelName: string,
  esmFile: EsmFile,
  isCoupled: boolean,
): Set<string> {
  const names = new Set<string>(Object.keys(model.variables || {}))

  // (2) document-scoped index sets
  for (const indexSet of Object.keys(esmFile.index_sets || {})) names.add(indexSet)

  // (4) implicit independent coordinates
  for (const implicit of implicitNames(esmFile)) names.add(implicit)

  // (5) the operator-model placeholder, only where composition can bind it
  if (isCoupled) names.add(OPERATOR_VAR_PLACEHOLDER)

  // (6) names a `callback` coupling entry injects into this component
  for (const entry of esmFile.coupling ?? []) {
    const config = (
      entry as { config?: { target_system?: string; callback_variables?: unknown[] } }
    ).config
    if (!config || config.target_system !== modelName) continue
    for (const callbackVariable of config.callback_variables ?? []) {
      const name = (callbackVariable as { name?: unknown }).name
      if (typeof name === 'string') names.add(name)
    }
  }

  return names
}

export function validateReferenceIntegrity(
  model: Model,
  modelPath: string,
  esmFile: EsmFile,
  modelName = modelPath.split('/').pop() ?? '',
  isCoupled = false,
): StructuralError[] {
  const errors: StructuralError[] = []
  const declaredVariables = declaredNamesFor(model, modelName, esmFile, isCoupled)
  const checkExpression = (expr: Expression, sitePath: string, boundSymbols: Set<string>): void => {
    for (const varRef of extractVariableReferences(expr)) {
      if (varRef.includes('.')) {
        // Scoped reference
        // `model` is the ENCLOSING scope: a reference to this model's own mounted
        // subsystem (`Calendar.seconds_since_midnight`) resolves against it.
        if (!resolveScopedReference(varRef, esmFile, model)) {
          errors.push({
            path: sitePath,
            code: ERROR_CODES.UNRESOLVED_SCOPED_REF,
            message: `Scoped reference "${varRef}" cannot be resolved`,
            details: { reference: varRef },
          })
        }
        // `declaredVariables` is the COMPLETE declaration-site union (see
        // `declaredNamesFor`); `boundSymbols` adds the binders in scope HERE.
      } else if (!declaredVariables.has(varRef) && !boundSymbols.has(varRef)) {
        // Local reference
        errors.push({
          path: sitePath,
          code: ERROR_CODES.UNDEFINED_VARIABLE,
          message: `Variable "${varRef}" referenced in equation is not declared`,
          details: { variable: varRef },
        })
      }
    }
  }

  // EVERY expression position the component carries — equations, observed
  // expressions, initialization equations, solver guesses, event triggers,
  // event conditions, and affect RHSs — each tagged with the JSON Pointer of
  // the field it lives in, so the error names the SIDECAR at fault and not just
  // the enclosing model.
  forEachExpressionScope(model, modelPath, (scope) => {
    // Binder-introduced index / contraction symbols (aggregate ranges and
    // output indices, `index` element positions, template binding names) are
    // iteration positions, not declared variables — collect them so they are not
    // flagged as undefined references. The scope is the unit: an equation's two
    // sides share one binder scope, so an `i` bound on the LHS is in scope on
    // the RHS.
    const boundSymbols = new Set<string>()
    for (const site of scope) {
      for (const symbol of collectIndexSymbols(site.expr)) boundSymbols.add(symbol)
    }
    for (const site of scope) {
      checkExpression(site.expr, site.path, boundSymbols)
    }
  })

  // Check observed variables have expressions
  for (const [varName, variable] of Object.entries(model.variables || {})) {
    // `=== undefined`, NOT `!expression`. An Expression may be the NUMBER ZERO,
    // and `!0` is `true` — so an observed variable defined as the perfectly legal
    // constant `0.0` (e.g. `temperature_factor` in
    // `tests/valid/events_cross_system.esm`) was reported as MISSING its
    // expression. The same falsy trap would swallow a `0` guess or bound.
    if (variable.type === 'observed' && variable.expression === undefined) {
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
 * The operator-style state-variable placeholder (spec §6.4): "The special
 * variable `"_var"` is a placeholder used in operator-style models. When coupled
 * via `operator_compose`, it is substituted with each matching state variable
 * from the target system."
 *
 * It is therefore a legal event-affect target and `read_vars` entry in a coupled
 * model, and is declared nowhere — substitution supplies its referent at
 * composition time.
 */
const OPERATOR_VAR_PLACEHOLDER = '_var'

/**
 * Check discrete parameters in events.
 *
 * `isCoupled` marks a model that participates in a coupling entry
 * (`operator_compose` / `couple` / `variable_map`). For such a model the
 * `_var` placeholder is a legal affect target — see
 * {@link OPERATOR_VAR_PLACEHOLDER}. This restores an internal consistency the
 * checker had lost: the orchestrator ALREADY skips reference integrity for a
 * coupled model precisely because its equations may name variables another
 * system provides, yet event consistency went on demanding that every affect
 * target be locally declared — so `tests/valid/full_coupled.esm`, whose
 * operator-composed `Transport` model affects `_var` exactly as §6.4 prescribes,
 * was rejected. Genuine undeclared targets are still flagged: only the one
 * spec-defined placeholder is admitted, and only where composition can bind it.
 */
export function validateEventConsistency(
  model: Model,
  modelPath: string,
  isCoupled = false,
): StructuralError[] {
  const errors: StructuralError[] = []
  const declaredVariables = new Set(Object.keys(model.variables || {}))
  const declaredParameters = new Set(
    Object.entries(model.variables || {})
      .filter(([_, variable]) => variable.type === 'parameter')
      .map(([name, _]) => name),
  )
  if (isCoupled) {
    declaredVariables.add(OPERATOR_VAR_PLACEHOLDER)
  }

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
      ...checkAffectTargets(
        event.affects,
        declaredVariables,
        `${eventPath}/affects`,
        'event affects',
      ),
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
 * Flag parameters whose name matches a well-known physical constant but whose
 * declared units are dimensionally incompatible with the canonical form (e.g.,
 * `R` declared as `kcal/mol` — missing temperature — instead of `J/(mol*K)`).
 * Reports at the first observed-variable usage site in the same model;
 * otherwise at the declaration. Mirrors Python's
 * `parse._check_physical_constant_units`.
 */
export function validatePhysicalConstantUnits(model: Model, modelPath: string): StructuralError[] {
  const errors: StructuralError[] = []
  const variables = model.variables || {}

  for (const { name, canonical, description } of KNOWN_PHYSICAL_CONSTANTS) {
    const declaration = variables[name]
    if (!declaration) continue
    if (declaration.type !== 'parameter') continue
    const declared = declaration.units
    if (!declared) continue

    // An unparseable declaration is INDETERMINATE, not "different from
    // canonical" — we cannot prove a mismatch against a dimension we could not
    // read, so skip rather than report. (`parseUnit` is strict and would throw;
    // `tryParseUnit` is the fallible form.)
    const declaredUnit = tryParseUnit(declared)
    const canonicalUnit = tryParseUnit(canonical)
    if (declaredUnit === null || canonicalUnit === null) continue
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

/**
 * Flag observed variables whose expression has the shape `<numeric> * <var>`
 * (or `<var> * <numeric>`) when the declared output units and the source
 * variable's units are dimensionally compatible but the numeric literal
 * disagrees with the correct linear scale factor. Mirrors Python's
 * parse._check_conversion_factor_consistency (gt-nvdv) and Go's
 * checkConversionFactorConsistency (gt-abh1). Affine conversions
 * (e.g., degC→K) are excluded.
 */
export function validateConversionFactorConsistency(
  model: Model,
  modelPath: string,
): StructuralError[] {
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
 * Flag model variables where default_units is set and the conversion from
 * default_units to units is affine (e.g., degC → K) rather than a pure
 * scale factor. Affine unit conversions are not expressible as a simple
 * default value and must use an explicit expression instead.
 */
export function validateDefaultUnits(model: Model, modelPath: string): StructuralError[] {
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
