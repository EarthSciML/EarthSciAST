/**
 * Structural validators that operate on a single Model: equation/unknown
 * balance, reference integrity, event consistency, and unit-related checks
 * (physical constants, conversion factors, default units).
 */

import { isExprNode, forEachChild } from '../expression.js'
import { isFloatLit, numericValue } from '../numeric-literal.js'
import { ERROR_CODES } from '../errors.js'
import { parseUnit, tryParseUnit, dimsEqual, type ParsedUnit } from '../units.js'
import type { EsmFile, Model, Expression, ExpressionNode, AffectEquation } from '../types.js'
import type { Expr } from '../expression.js'
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
import { documentDeclaredNames } from './coupling-checks.js'

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

  // (5) A coupled model — operator-composed or a coupling target — is checked
  // against the DOCUMENT-WIDE declared names, not just its own. Composition
  // merges the participating systems' scopes, so such a model legitimately
  // references another composed system's state by bare name (the end-to-end
  // atmosphere/land fixtures do exactly this). Its one reserved implicit name is
  // the §6.4 placeholder `_var`. A name declared NOWHERE in the document is still
  // an `undefined_variable` — that residue is the F-1 false negative the former
  // blanket exemption let through.
  if (isCoupled) {
    names.add(OPERATOR_VAR_PLACEHOLDER)
    for (const n of documentDeclaredNames(esmFile)) names.add(n)
  }

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

// ---------------------------------------------------------------------------
// F-6 static `aggregate` semantics (RFC semiring-faq-unified-ir).
//
// Three checks decidable from the SINGLE document — no evaluation, solver, or
// other file. Each descends every expression position of a model
// (`forEachExpressionScope`), finds the `aggregate` nodes reachable inside, and
// reports at the CONTAINING EXPRESSION FIELD's JSON Pointer (`.../equations/i/
// lhs` or `/rhs`), the Phase-2 pointer convention, because that is where the
// shared corpus pins the finding.
// ---------------------------------------------------------------------------

/**
 * Every `aggregate` node reachable from `expr`, including nested ones (an
 * aggregate carried inside another aggregate's `expr`/`key` body). Descent is
 * the shared `forEachChild` full-child walk, so aggregates hidden in any
 * expression-bearing field are found; `ranges`/`join` are structural metadata,
 * not expression children, so the walker never mistakes their contents for
 * subexpressions.
 */
function collectAggregates(expr: Expression): ExpressionNode[] {
  const found: ExpressionNode[] = []
  const visit = (node: Expr): void => {
    if (!isExprNode(node)) return
    if (node.op === 'aggregate') found.push(node)
    forEachChild(node, visit)
  }
  visit(expr)
  return found
}

/**
 * The join-key columns of an `aggregate` — the index symbols named on either
 * side of every `join[k].on` pair. These are the columns whose VALUES must
 * compare equal, so their member types must be exact-equality types.
 */
function joinKeyColumns(agg: ExpressionNode): Set<string> {
  const cols = new Set<string>()
  const joins = agg.join
  if (!Array.isArray(joins)) return cols
  for (const clause of joins) {
    for (const pair of clause?.on ?? []) {
      for (const col of pair) if (typeof col === 'string') cols.add(col)
    }
  }
  return cols
}

/**
 * The range an aggregate index symbol iterates, IF it is an index-set
 * reference `{ from: NAME }` (as opposed to a dense integer tuple). Returns the
 * referenced index-set NAME, else undefined.
 */
function rangeIndexSetName(range: unknown): string | undefined {
  if (range && typeof range === 'object' && !Array.isArray(range) && 'from' in range) {
    const from = (range as { from?: unknown }).from
    if (typeof from === 'string') return from
  }
  return undefined
}

/**
 * The first categorical `members` entry that cannot serve as a value-equality
 * join key: a NULL (unmatchable — a null key joins to nothing and nulls never
 * compare equal) or a FLOAT (a float repr is not portable across bindings, so
 * equality on it is not defined). Integers and strings are fine. Returns the
 * offending value and the reason, or undefined when every member is admissible.
 *
 * Handles both the plain-`number` and the tagged-`NumericLiteral` leaf shapes a
 * loaded document can carry: a value declared with a decimal point is a float
 * whatever its numeric value (`isFloatLit`), and a plain number that is not an
 * integer is a float too (`!Number.isInteger`).
 */
function invalidJoinKeyMember(
  members: readonly unknown[],
): { value: unknown; reason: 'null' | 'float' } | undefined {
  for (const member of members) {
    if (member === null) return { value: member, reason: 'null' }
    const value = numericValue(member)
    if (value !== undefined && (isFloatLit(member) || !Number.isInteger(value))) {
      return { value, reason: 'float' }
    }
  }
  return undefined
}

/**
 * F-6 check `join_key_invalid_type` (RFC §5.3 / §5.7 rule 1): an `aggregate`
 * whose value-equality `join` keys on a column drawn from a categorical index
 * set whose `members` contain a FLOAT or a NULL. Emitted once per offending
 * aggregate at its containing equation field.
 */
export function validateAggregateJoinKeys(
  model: Model,
  modelPath: string,
  esmFile: EsmFile,
): StructuralError[] {
  const errors: StructuralError[] = []
  const indexSets = esmFile.index_sets || {}
  forEachExpressionScope(model, modelPath, (scope) => {
    for (const site of scope) {
      for (const agg of collectAggregates(site.expr)) {
        const cols = joinKeyColumns(agg)
        if (cols.size === 0) continue
        const ranges = agg.ranges || {}
        for (const col of cols) {
          const setName = rangeIndexSetName(ranges[col])
          if (setName === undefined) continue
          const indexSet = indexSets[setName]
          if (!indexSet || indexSet.kind !== 'categorical' || !Array.isArray(indexSet.members)) {
            continue
          }
          const bad = invalidJoinKeyMember(indexSet.members)
          if (bad) {
            errors.push({
              path: site.path,
              code: ERROR_CODES.JOIN_KEY_INVALID_TYPE,
              message: `aggregate join key column "${col}" draws from categorical index set "${setName}" whose members include a ${bad.reason} (${JSON.stringify(bad.value)}); a value-equality join key must be an integer or string`,
              details: { column: col, index_set: setName, reason: bad.reason },
            })
            break // one finding per aggregate is enough
          }
        }
      }
    }
  })
  return errors
}

/**
 * F-6 check `undefined_index_set` (RFC §5.2): an `aggregate` `ranges` entry
 * `{ from: NAME }` whose NAME is not a key of the document-scoped `index_sets`
 * registry. No implicit interval is inferred, so a typo cannot silently become
 * an empty set. Emitted per offending aggregate field.
 */
export function validateAggregateIndexSets(
  model: Model,
  modelPath: string,
  esmFile: EsmFile,
): StructuralError[] {
  const errors: StructuralError[] = []
  const declared = new Set(Object.keys(esmFile.index_sets || {}))
  forEachExpressionScope(model, modelPath, (scope) => {
    for (const site of scope) {
      for (const agg of collectAggregates(site.expr)) {
        const reported = new Set<string>() // one finding per (site, name)
        for (const range of Object.values(agg.ranges || {})) {
          const setName = rangeIndexSetName(range)
          if (setName === undefined || declared.has(setName) || reported.has(setName)) continue
          reported.add(setName)
          errors.push({
            path: site.path,
            code: ERROR_CODES.UNDEFINED_INDEX_SET,
            message: `aggregate range references index set "${setName}", which is not declared in the document index_sets registry`,
            details: { index_set: setName, declared: [...declared] },
          })
        }
      }
    }
  })
  return errors
}

/**
 * Semirings under which `distinct: true` is a RELATIONAL / value-invention
 * aggregate (set semantics, index-set-producing). Only `bool_and_or` — the
 * relational specialization (RFC §5.1) — qualifies today; the check is written
 * against a set so a future boolean/relational semiring is covered without a
 * second edit.
 */
const RELATIONAL_SEMIRINGS: ReadonlySet<string> = new Set(['bool_and_or'])

/**
 * F-6 check `relational_node_in_continuous` (CONFORMANCE_SPEC §5.7 guard 2):
 * a relational / value-invention `aggregate` (`distinct: true` under a
 * relational semiring) whose `key`/`expr` reads a declared STATE variable. Such
 * a node's cadence class is CONTINUOUS (class = max over inputs; a state input
 * is CONTINUOUS), and relational work may not run on the per-step hot path.
 *
 * The positive control is `tests/valid/cadence/pure_topology.esm`: the same
 * `distinct` + `bool_and_or` primitives, but the `key` reads only CONST mesh
 * PARAMETERS (`face_lo`/`face_hi`), so no state variable is read and the node
 * folds at compile time — allowed.
 */
export function validateRelationalNodesInContinuous(
  model: Model,
  modelPath: string,
): StructuralError[] {
  const errors: StructuralError[] = []
  const stateVariables = new Set(
    Object.entries(model.variables || {})
      .filter(([, variable]) => variable.type === 'state')
      .map(([name]) => name),
  )
  if (stateVariables.size === 0) return errors

  forEachExpressionScope(model, modelPath, (scope) => {
    for (const site of scope) {
      for (const agg of collectAggregates(site.expr)) {
        if (agg.distinct !== true) continue
        const semiring = agg.semiring ?? 'sum_product'
        if (!RELATIONAL_SEMIRINGS.has(semiring)) continue

        // A state variable read in the `key` (the Skolem term whose distinct
        // values are enumerated) or the `expr` body makes the invented set
        // depend on the continuously-evolving state.
        const referenced = new Set<string>()
        for (const field of [agg.key, agg.expr]) {
          if (field === undefined) continue
          for (const ref of extractVariableReferences(field as Expression)) referenced.add(ref)
        }
        const stateRead = [...referenced].find((ref) => stateVariables.has(ref))
        if (stateRead !== undefined) {
          errors.push({
            path: site.path,
            code: ERROR_CODES.RELATIONAL_NODE_IN_CONTINUOUS,
            message: `relational aggregate (distinct under ${semiring}) reads state variable "${stateRead}", classing the value-invention node CONTINUOUS; relational work may not run on the per-step hot path`,
            details: { semiring, state_variable: stateRead },
          })
        }
      }
    }
  })
  return errors
}
