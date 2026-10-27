/**
 * Reaction system ODE derivation for the ESM format
 *
 * This module provides utilities for deriving ordinary differential equations (ODEs)
 * from reaction systems using standard mass action kinetics.
 */

import type {
  ReactionSystem,
  Model,
  Reaction,
  ModelVariable,
  Equation,
  Expression,
} from './types.js'

/**
 * Derive ODEs from a reaction system using mass action kinetics
 *
 * Generates an ODE model from reaction stoichiometry and rate laws. For each reaction
 * with rate k, substrates {Si} with stoichiometries {ni}, products {Pj} with
 * stoichiometries {mj}:
 * - rate law: v = k * prod(Si^ni)
 * - ODE contribution: dX/dt += net_stoich_X * v
 *
 * Handles:
 * - Source reactions (null substrates): rate is the direct production term
 * - Sink reactions (null products): rate is the direct loss term
 * - Constraint equations are appended as additional equations
 *
 * @param system ReactionSystem to derive ODEs from
 * @returns Model with species as state variables, derived ODEs plus constraints
 */
export function deriveOdes(system: ReactionSystem): Model {
  const variables: { [key: string]: ModelVariable } = {}
  const equations: Equation[] = []

  // Convert species to UNKNOWNS. Each gets a `D(s,t)` equation below, which is
  // what makes it an ODE state under the derived classification — the 0.x
  // `type: 'state'` declaration said the same thing twice, and 1.0.0 keeps only
  // the equation (esm-spec 6.3.1).
  //
  // EXCEPT a reservoir species (`constant: true`, esm-spec 7.4), which is held
  // fixed and gets no ODE, so it lowers to a PARAMETER carrying its declared
  // `default` as the fixed value. This binding alone did not do that: Julia
  // (reactions.jl), Python (reactions.py), Rust (reactions.rs) and Go
  // (reactions.go) all skip reservoirs here, and this binding's OWN flatten
  // path (flatten.ts, `constant === true`) already did. Two of those bindings'
  // comments even cite TypeScript as doing it. It was caught by
  // tests/conformance/reactions/species_order.json, whose reservoir case is the
  // first shared fixture to look.
  for (const [speciesName, species] of Object.entries(system.species)) {
    variables[speciesName] = {
      type: species.constant === true ? 'parameter' : 'unknown',
      units: species.units,
      default: species.default,
      description: species.description,
    }
  }

  // Copy parameters
  for (const [paramName, param] of Object.entries(system.parameters)) {
    variables[paramName] = {
      type: 'parameter',
      units: param.units,
      default: param.default,
      description: param.description,
    }
  }

  // The species' ODEs: the one lowering flatten uses too, so a system's
  // equations are the same whichever entry point reached them.
  equations.push(...lowerReactionsToEquations(system))

  // Add constraint equations if present
  if (system.constraint_equations) {
    equations.push(...system.constraint_equations)
  }

  return {
    variables,
    equations,
    reference: system.reference,
  }
}

/**
 * Lower a reaction list to `D(species, t) = Σ net_stoich · rate` equations by
 * mass action (esm-spec §7.4), in the canonical form of esm-libraries-spec
 * §4.6.2, which every binding emits byte for byte
 * (`tests/conformance/reactions/lowering_form.json`):
 *
 * - the rate law is the reaction's `rate` alone when it has no substrates, and
 *   otherwise ONE n-ary `*` whose first operand is the `rate` and whose further
 *   operands are its substrates in listed order (the bare species for a
 *   coefficient of 1, `species ^ coefficient` otherwise);
 * - a species' term for a reaction is that rate law when its net coefficient
 *   `P - S` is exactly 1, and `{op: '*', args: [coefficient, rateLaw]}`
 *   otherwise (a loss of 1 is `-1 * rateLaw`, not a unary minus); a net
 *   coefficient of 0 contributes no term;
 * - the right-hand side is the only term, or ONE n-ary `+` over the terms in
 *   reaction order. Nothing is simplified: a literal `1` or `0` rate stays.
 *
 * Species are visited in declaration order. A reservoir species
 * (`constant: true`) and a species with no term get no equation
 * (esm-libraries-spec §4.6.1); a reservoir is still a factor in the rate laws.
 *
 * This binding's numbers carry no integer/float distinction, so the integer
 * literal the specification asks for is simply the number.
 */
export function lowerReactionsToEquations(system: ReactionSystem): Equation[] {
  const speciesNames = Object.keys(system.species ?? {})
  const terms: Record<string, Expression[]> = {}
  for (const name of speciesNames) terms[name] = []

  for (const reaction of system.reactions ?? []) {
    const rateLaw = massActionRate(reaction)
    for (const name of speciesNames) {
      let produced = 0
      let consumed = 0
      for (const p of reaction.products ?? []) if (p.species === name) produced += p.stoichiometry
      for (const s of reaction.substrates ?? []) if (s.species === name) consumed += s.stoichiometry
      const net = produced - consumed
      if (net === 0) continue
      terms[name].push(net === 1 ? rateLaw : { op: '*', args: [net, rateLaw] })
    }
  }

  const equations: Equation[] = []
  for (const name of speciesNames) {
    if ((system.species ?? {})[name]?.constant === true) continue
    const speciesTerms = terms[name]
    if (speciesTerms.length === 0) continue
    equations.push({
      lhs: { op: 'D', args: [name], wrt: 't' },
      rhs:
        speciesTerms.length === 1
          ? speciesTerms[0]
          : { op: '+', args: speciesTerms as [Expression, ...Expression[]] },
    })
  }
  return equations
}

/** The mass-action rate law `k · ∏ Sᵢ^nᵢ` of one reaction (see above). */
function massActionRate(reaction: Reaction): Expression {
  const substrates = reaction.substrates ?? []
  if (substrates.length === 0) return reaction.rate
  const factors: Expression[] = [reaction.rate]
  for (const substrate of substrates) {
    factors.push(
      substrate.stoichiometry === 1
        ? substrate.species
        : { op: '^', args: [substrate.species, substrate.stoichiometry] },
    )
  }
  return { op: '*', args: factors as [Expression, ...Expression[]] }
}

/**
 * Compute stoichiometric matrix from a reaction system
 *
 * Returns the net stoichiometric matrix (species × reactions) where:
 * - Rows are species (in declaration order)
 * - Columns are reactions (in array order)
 * - Entry [i][j] = (stoichiometry as product) - (stoichiometry as substrate) for species i in reaction j
 * - Null substrates contribute 0 to substrate stoichiometry
 * - Null products contribute 0 to product stoichiometry
 *
 * @param system ReactionSystem to compute matrix from
 * @returns Object containing matrix, species list, and reactions list
 */
export function stoichiometricMatrix(system: ReactionSystem): {
  matrix: number[][]
  species: string[]
  reactions: string[]
} {
  const species = Object.keys(system.species)
  const reactions = system.reactions.map((r) => r.id)

  // Initialize matrix with zeros
  const matrix: number[][] = species.map(() => new Array(reactions.length).fill(0))

  // Fill matrix with net stoichiometry
  system.reactions.forEach((reaction, reactionIndex) => {
    species.forEach((speciesName, speciesIndex) => {
      let substrateCoeff = 0
      let productCoeff = 0

      // Get substrate stoichiometry
      if (reaction.substrates) {
        for (const substrate of reaction.substrates) {
          if (substrate.species === speciesName) {
            substrateCoeff += substrate.stoichiometry
          }
        }
      }

      // Get product stoichiometry
      if (reaction.products) {
        for (const product of reaction.products) {
          if (product.species === speciesName) {
            productCoeff += product.stoichiometry
          }
        }
      }

      // Net stoichiometry = product - substrate
      matrix[speciesIndex][reactionIndex] = productCoeff - substrateCoeff
    })
  })

  return { matrix, species, reactions }
}

/**
 * Compute substrate stoichiometric matrix from a reaction system
 *
 * Returns the substrate stoichiometric matrix (species × reactions) where:
 * - Rows are species (in declaration order)
 * - Columns are reactions (in array order)
 * - Entry [i][j] = substrate stoichiometry for species i in reaction j
 * - Null substrates contribute 0
 *
 * @param system ReactionSystem to compute matrix from
 * @returns Substrate stoichiometric matrix
 */
export function substrateMatrix(system: ReactionSystem): number[][] {
  const species = Object.keys(system.species)
  const numReactions = system.reactions.length

  // Initialize matrix with zeros
  const matrix: number[][] = species.map(() => new Array(numReactions).fill(0))

  // Fill matrix with substrate stoichiometry
  system.reactions.forEach((reaction, reactionIndex) => {
    if (reaction.substrates) {
      for (const substrate of reaction.substrates) {
        const speciesIndex = species.indexOf(substrate.species)
        if (speciesIndex >= 0) {
          matrix[speciesIndex][reactionIndex] += substrate.stoichiometry
        }
      }
    }
  })

  return matrix
}

/**
 * Compute product stoichiometric matrix from a reaction system
 *
 * Returns the product stoichiometric matrix (species × reactions) where:
 * - Rows are species (in declaration order)
 * - Columns are reactions (in array order)
 * - Entry [i][j] = product stoichiometry for species i in reaction j
 * - Null products contribute 0
 *
 * @param system ReactionSystem to compute matrix from
 * @returns Product stoichiometric matrix
 */
export function productMatrix(system: ReactionSystem): number[][] {
  const species = Object.keys(system.species)
  const numReactions = system.reactions.length

  // Initialize matrix with zeros
  const matrix: number[][] = species.map(() => new Array(numReactions).fill(0))

  // Fill matrix with product stoichiometry
  system.reactions.forEach((reaction, reactionIndex) => {
    if (reaction.products) {
      for (const product of reaction.products) {
        const speciesIndex = species.indexOf(product.species)
        if (speciesIndex >= 0) {
          matrix[speciesIndex][reactionIndex] += product.stoichiometry
        }
      }
    }
  })

  return matrix
}

/**
 * @deprecated Spelling alias for {@link deriveOdes}, kept for one minor per
 * API_SPEC.md §10. The canonical name is `derive_odes`, whose TypeScript
 * transliteration (API_SPEC §2/§2.1) is `deriveOdes`, matching the siblings
 * `odeStates` / `isOdeState`. Removed at the next major.
 */
export const deriveODEs = deriveOdes
