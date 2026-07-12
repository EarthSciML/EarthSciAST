/**
 * Structural validators that operate on a single ReactionSystem: reactant /
 * rate reference consistency, the `ic`-in-reaction-system rejection, and the
 * mass-action dimensional constraint on reaction rates.
 */

import { isExprNode } from '../expression.js'
import { ERROR_CODES } from '../errors.js'
import {
  checkDimensions,
  parseUnit,
  isDimensionless,
  dimsEqual,
  type CanonicalDims,
  type ParsedUnit,
} from '../units.js'
import type { ReactionSystem, Expression } from '../types.js'
import type { StructuralError } from './types.js'
import { extractVariableReferences } from './expr-utils.js'
import { formatExpectedRateUnits } from './unit-format.js'

/**
 * Check reaction consistency for a reaction system
 */
export function validateReactionConsistency(
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
export function validateReactionSystemICs(
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
export function validateReactionRateUnits(
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
