/**
 * Drives the shared reaction species-ORDER corpus
 * (`tests/conformance/reactions/species_order.json`).
 *
 * WHY this pin exists: species order is *observable* — it is the ROW order of
 * `stoichiometricMatrix` and the EQUATION order of the model `deriveOdes`
 * returns — yet nothing in `tests/` asserted it, and all five bindings drifted
 * apart unnoticed for the length of the project (Go sorted in both operations,
 * Rust sorted in `stoichiometric_matrix` only, Julia/Python/TypeScript used
 * declaration order in both). See API_SPEC.md §5.10. The corpus pins
 * DECLARATION order — the order the document writes the `species` object's
 * keys in — as canonical for both operations. Every case declares its species
 * in an order that is NOT their sorted order, so a binding that sorts fails
 * rather than passing by coincidence.
 *
 * What this corpus deliberately does NOT pin is the RETURN SHAPE of
 * `stoichiometric_matrix`. TypeScript alone returns `{matrix, species,
 * reactions}` where the other four bindings return a bare matrix; that split is
 * a known, separate divergence recorded in API_SPEC.md §5.10, so this driver
 * simply compares the `matrix` member. Because TypeScript *is* the binding that
 * exposes `species`, it can additionally assert the row LABELS against
 * `species_declaration_order` — a stronger check no other binding can make.
 *
 * `odeStates()` is NOT used here: it sorts its result by design
 * (esm-spec §6.3.1), so an assertion built on it would pass vacuously in every
 * binding. The equation order is read straight off each equation's LHS
 * `D(<species>, t)` node instead.
 */
import { describe, expect, it } from 'vitest'
import { loadDocument } from './parse.js'
import { deriveOdes, stoichiometricMatrix } from './reactions.js'
import { readFixture } from './test-helpers.js'
import type { Equation, ReactionSystem } from './types.js'

interface SpeciesOrderCase {
  name: string
  description: string
  system: string
  species_declaration_order: string[]
  species_sorted_order: string[]
  derive_odes_equation_species: string[]
  stoichiometric_matrix: number[][]
  document: object
}

interface SpeciesOrderCorpus {
  description: string
  why: string
  how_to_drive: string
  cases: SpeciesOrderCase[]
}

const corpus: SpeciesOrderCorpus = JSON.parse(
  readFixture('conformance', 'reactions', 'species_order.json'),
) as SpeciesOrderCorpus

/** Resolve the named reaction system out of a freshly loaded document. */
function systemOf(testCase: SpeciesOrderCase): ReactionSystem {
  const file = loadDocument(testCase.document)
  const systems = (file.reaction_systems ?? {}) as Record<string, ReactionSystem>
  const system = systems[testCase.system]
  expect(system, `case ${testCase.name}: no reaction system named ${testCase.system}`).toBeDefined()
  return system
}

/**
 * The species an ODE equation is written for: the FIRST argument of its LHS
 * `D(<species>, t)` node.
 */
function lhsSpecies(equation: Equation): string {
  const lhs = equation.lhs as { op?: string; args?: unknown[] }
  expect(lhs.op).toBe('D')
  const first = lhs.args?.[0]
  expect(typeof first).toBe('string')
  return first as string
}

describe('reaction species order corpus', () => {
  // Anti-vacuity: a corpus that failed to load, or shrank to a single case,
  // would otherwise make every assertion below silently disappear.
  it('reads at least 2 cases', () => {
    expect(corpus.cases.length).toBeGreaterThanOrEqual(2)
  })

  for (const testCase of corpus.cases) {
    describe(testCase.name, () => {
      // Anti-vacuity, per case: if a case ever declared its species in sorted
      // order, a binding that sorts would pass it by coincidence and the pin
      // would be worthless.
      it('declares its species in an order that is NOT the sorted order', () => {
        expect(testCase.species_declaration_order).not.toEqual(testCase.species_sorted_order)
        expect([...testCase.species_declaration_order].sort()).toEqual(
          testCase.species_sorted_order,
        )
      })

      it('stoichiometricMatrix rows follow species declaration order', () => {
        const system = systemOf(testCase)
        const result = stoichiometricMatrix(system)
        // Only `matrix` is compared against the corpus: the surrounding
        // `{matrix, species, reactions}` struct is TypeScript's own return
        // shape (API_SPEC.md §5.10) and is deliberately not what the corpus
        // pins.
        expect(result.matrix).toEqual(testCase.stoichiometric_matrix)
        // Stronger check available only in this binding, since only TypeScript
        // recovers the row labels: the rows really are the declared species,
        // in declaration order.
        expect(result.species).toEqual(testCase.species_declaration_order)
      })

      it('deriveOdes emits its equations in species declaration order', () => {
        const model = deriveOdes(systemOf(testCase))
        expect(model.equations.map(lhsSpecies)).toEqual(testCase.derive_odes_equation_species)
      })

      // A reservoir species (`constant: true`, esm-spec §7.4) is held fixed:
      // it keeps its stoichiometric matrix ROW, but contributes no equation and
      // is typed `parameter` rather than `unknown`. This binding's `deriveOdes`
      // ignored `constant` until this corpus was added -- it was the only one of
      // the five that did -- so the assertion is spelled out rather than left
      // implicit in the equation list above.
      it('types a reservoir species as a parameter and gives it no equation', () => {
        const system = systemOf(testCase)
        const model = deriveOdes(system)
        const emitted = model.equations.map(lhsSpecies)
        for (const [name, species] of Object.entries(system.species)) {
          if (species.constant === true) {
            expect(model.variables[name].type).toBe('parameter')
            expect(emitted).not.toContain(name)
          } else {
            expect(model.variables[name].type).toBe('unknown')
          }
        }
      })
    })
  }
})
