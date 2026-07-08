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
export function deriveODEs(system: ReactionSystem): Model {
  const variables: { [key: string]: ModelVariable } = {}
  const equations: Equation[] = []

  // Convert species to state variables
  for (const [speciesName, species] of Object.entries(system.species)) {
    variables[speciesName] = {
      type: 'state',
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

  // Build ODE right-hand sides for each species
  const odeRhs: { [species: string]: Expression[] } = {}

  // Initialize ODE RHS for each species
  for (const speciesName of Object.keys(system.species)) {
    odeRhs[speciesName] = []
  }

  // Process each reaction
  for (const reaction of system.reactions) {
    const rateLaw = buildRateLaw(reaction)

    // Add contributions to species ODEs
    addReactionContribution(odeRhs, reaction, rateLaw)
  }

  // Create ODE equations (d[species]/dt = RHS)
  for (const [speciesName, rhsTerms] of Object.entries(odeRhs)) {
    if (rhsTerms.length === 0) {
      // No reactions affect this species
      equations.push({
        lhs: { op: 'D', args: [speciesName], wrt: 't' },
        rhs: 0,
      })
    } else if (rhsTerms.length === 1) {
      // Single term
      equations.push({
        lhs: { op: 'D', args: [speciesName], wrt: 't' },
        rhs: rhsTerms[0],
      })
    } else {
      // Sum multiple terms - ensure we have at least one term for the non-empty array requirement
      equations.push({
        lhs: { op: 'D', args: [speciesName], wrt: 't' },
        rhs: { op: '+', args: rhsTerms as [Expression, ...Expression[]] },
      })
    }
  }

  // Add constraint equations if present
  if (system.constraint_equations) {
    equations.push(...system.constraint_equations)
  }

  return {
    variables,
    equations,
    coupletype: system.coupletype,
    reference: system.reference,
  }
}

/**
 * Build mass action rate law for a reaction
 *
 * For a reaction with rate constant k and substrates {Si} with stoichiometries {ni}:
 * rate_law = k * prod(Si^ni)
 *
 * For source reactions (null substrates): rate_law = k (direct production)
 * For sink reactions: rate_law includes substrate concentrations as normal
 *
 * @param reaction Reaction to build rate law for
 * @returns Expression representing the rate law
 */
function buildRateLaw(reaction: Reaction): Expression {
  const rate = reaction.rate

  // For source reactions (null substrates), rate is used directly
  if (!reaction.substrates) {
    return rate
  }

  // For reactions with substrates, build mass action kinetics
  const terms: Expression[] = [rate]

  for (const substrate of reaction.substrates) {
    if (substrate.stoichiometry === 1) {
      // Simple first-order term
      terms.push(substrate.species)
    } else {
      // Higher-order term: [species]^stoichiometry
      terms.push({
        op: '^',
        args: [substrate.species, substrate.stoichiometry],
      })
    }
  }

  if (terms.length === 1) {
    return terms[0]
  } else if (terms.length > 1) {
    return {
      op: '*',
      args: terms as [Expression, ...Expression[]],
    }
  } else {
    // Should not happen, but handle empty case
    return 1
  }
}

/**
 * Add reaction contribution to species ODE right-hand sides
 *
 * For each species involved in the reaction, add term:
 * net_stoich_X * rate_law
 *
 * where net_stoich_X = product_stoich - substrate_stoich
 *
 * @param odeRhs Object mapping species names to arrays of RHS terms
 * @param reaction Reaction to process
 * @param rateLaw Rate law expression for this reaction
 */
function addReactionContribution(
  odeRhs: { [species: string]: Expression[] },
  reaction: Reaction,
  rateLaw: Expression,
): void {
  // Calculate net stoichiometry for each species
  const netStoich: { [species: string]: number } = {}

  // Subtract substrate stoichiometries
  if (reaction.substrates) {
    for (const substrate of reaction.substrates) {
      netStoich[substrate.species] = (netStoich[substrate.species] || 0) - substrate.stoichiometry
    }
  }

  // Add product stoichiometries
  if (reaction.products) {
    for (const product of reaction.products) {
      netStoich[product.species] = (netStoich[product.species] || 0) + product.stoichiometry
    }
  }

  // Add terms to ODE RHS for each affected species
  for (const [speciesName, stoich] of Object.entries(netStoich)) {
    if (stoich === 0) {
      // No net change for this species
      continue
    }

    let term: Expression
    if (stoich === 1) {
      // Coefficient of 1, use rate law directly
      term = rateLaw
    } else if (stoich === -1) {
      // Coefficient of -1, negate rate law
      term = { op: '-', args: [rateLaw] }
    } else {
      // Other coefficient, multiply
      term = { op: '*', args: [stoich, rateLaw] }
    }

    if (odeRhs[speciesName]) {
      odeRhs[speciesName].push(term)
    }
  }
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
