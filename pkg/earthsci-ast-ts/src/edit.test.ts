/**
 * Tests for immutable editing operations
 */

import { describe, it, expect, beforeEach } from 'vitest'
import {
  addVariable,
  removeVariable,
  renameVariable,
  addEquation,
  removeEquation,
  substituteInEquations,
  addReaction,
  removeReaction,
  addSpecies,
  removeSpecies,
  addContinuousEvent,
  addDiscreteEvent,
  removeEvent,
  addCoupling,
  removeCoupling,
  compose,
  mapVariable,
  merge,
  extract,
  VariableInUseError,
  EntityNotFoundError,
} from './edit.js'
import type {
  Model,
  ReactionSystem,
  EsmFile,
  ModelVariable,
  Equation,
  Reaction,
  Species,
  ContinuousEvent,
  DiscreteEvent,
  CouplingEntry,
} from './types.js'

describe('edit', () => {
  let model: Model
  let reactionSystem: ReactionSystem
  let esmFile: EsmFile

  beforeEach(() => {
    model = {
      variables: {
        x: {
          type: 'state',
          units: 'm',
          description: 'Position',
        },
        v: {
          type: 'state',
          units: 'm/s',
          description: 'Velocity',
        },
        k: {
          type: 'parameter',
          units: '1/s',
          default: 1,
          description: 'Rate constant',
        },
      },
      equations: [
        { lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 'v' },
        {
          lhs: { op: 'D', args: ['v'], wrt: 't' },
          rhs: { op: '*', args: [{ op: '-', args: ['k'] }, 'x'] },
        },
      ],
    }

    reactionSystem = {
      species: {
        A: {
          units: 'mol/L',
          description: 'Species A',
        },
        B: {
          units: 'mol/L',
          description: 'Species B',
        },
      },
      parameters: {
        rate: {
          units: '1/s',
          default: 0.1,
          description: 'Rate constant',
        },
      },
      reactions: [
        {
          id: 'r1',
          substrates: [{ species: 'A', stoichiometry: 1 }],
          products: [{ species: 'B', stoichiometry: 1 }],
          rate: 'rate',
        },
      ],
    }

    // Deliberately schema-incomplete fixture (no `esm` version field;
    // `version` is not a schema Metadata field): the edit operations under
    // test must pass such fields/omissions through untouched.
    esmFile = {
      metadata: { name: 'test', version: '0.1.0' },
      models: { TestModel: model },
      reaction_systems: { TestSystem: reactionSystem },
    } as unknown as EsmFile
  })

  describe('Variable Operations', () => {
    it('should add a new variable', () => {
      const newVar: ModelVariable = {
        type: 'observed',
        units: 'K',
        expression: 'x',
        description: 'Temperature',
      }

      const result = addVariable(model, 'temp', newVar)

      expect(result).not.toBe(model) // immutable
      expect(result.variables.temp).toEqual(newVar)
      expect(result.variables.x).toEqual(model.variables.x) // original preserved
    })

    it('should remove a variable when not in use', () => {
      // Create model without references to 'k'
      const modelWithoutKReference = {
        ...model,
        equations: [
          { lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 'v' },
          { lhs: { op: 'D', args: ['v'], wrt: 't' }, rhs: { op: '*', args: [-1, 'x'] } },
        ],
      }

      const result = removeVariable(modelWithoutKReference, 'k')

      expect(result).not.toBe(modelWithoutKReference)
      expect(result.variables.k).toBeUndefined()
      expect(result.variables.x).toEqual(model.variables.x)
    })

    it('should throw error when removing variable that is in use', () => {
      expect(() => removeVariable(model, 'k')).toThrow(VariableInUseError)
    })

    it('should throw error when removing non-existent variable', () => {
      expect(() => removeVariable(model, 'nonexistent')).toThrow(EntityNotFoundError)
    })

    it('should rename a variable throughout the model', () => {
      const result = renameVariable(model, 'k', 'rate_constant')

      expect(result).not.toBe(model)
      expect(result.variables.k).toBeUndefined()
      expect(result.variables.rate_constant).toEqual(model.variables.k)

      // Check that equations were updated
      const secondEq = result.equations[1]
      expect(secondEq.rhs).toEqual({ op: '*', args: [{ op: '-', args: ['rate_constant'] }, 'x'] })
    })

    it('should throw error when renaming non-existent variable', () => {
      expect(() => renameVariable(model, 'nonexistent', 'new_name')).toThrow(EntityNotFoundError)
    })

    it('renames references inside event conditions and affect RHSs (unified sites)', () => {
      const m: Model = {
        variables: { x: { type: 'state' }, v: { type: 'state' } },
        equations: [{ lhs: { op: 'D', args: ['x'], wrt: 't' }, rhs: 'v' }],
        continuous_events: [
          {
            name: 'e',
            conditions: [{ op: '>', args: ['x', 10] }],
            affects: [{ lhs: 'v', rhs: { op: '-', args: ['x'] } }],
          },
        ],
      }

      const result = renameVariable(m, 'x', 'pos')

      // removeVariable scans event sites, so renameVariable must rewrite them
      // too — otherwise a rename leaves a reference removal would have flagged.
      expect(result.continuous_events![0]!.conditions[0]).toEqual({ op: '>', args: ['pos', 10] })
      expect(result.continuous_events![0]!.affects[0]!.rhs).toEqual({ op: '-', args: ['pos'] })
    })

    it('detects references inside event conditions (unified sites)', () => {
      const m: Model = {
        variables: { x: { type: 'state' }, v: { type: 'state' } },
        equations: [{ lhs: { op: 'D', args: ['v'], wrt: 't' }, rhs: 0 }],
        continuous_events: [
          {
            name: 'e',
            conditions: [{ op: '>', args: ['x', 10] }],
            affects: [{ lhs: 'v', rhs: 0 }],
          },
        ],
      }

      expect(() => removeVariable(m, 'x')).toThrow(VariableInUseError)
    })
  })

  describe('Equation Operations', () => {
    it('should add a new equation', () => {
      const newEquation: Equation = {
        lhs: 'y',
        rhs: { op: '+', args: ['x', 'v'] },
      }

      const result = addEquation(model, newEquation)

      expect(result).not.toBe(model)
      expect(result.equations).toHaveLength(3)
      expect(result.equations[2]).toEqual(newEquation)
    })

    it('should remove equation by index', () => {
      const result = removeEquation(model, 0)

      expect(result).not.toBe(model)
      expect(result.equations).toHaveLength(1)
      expect(result.equations[0]).toEqual(model.equations[1])
    })

    it('should remove equation by LHS', () => {
      const lhs = { op: 'D', args: ['x'], wrt: 't' }
      const result = removeEquation(model, lhs)

      expect(result).not.toBe(model)
      expect(result.equations).toHaveLength(1)
      expect(result.equations[0]).toEqual(model.equations[1])
    })

    it('should throw error when removing equation with invalid index', () => {
      expect(() => removeEquation(model, 10)).toThrow(EntityNotFoundError)
    })

    it('removeEquation by LHS distinguishes consts with different values (field-aware equality)', () => {
      // `value` is object-typed on the schema node; these are deliberately
      // hand-shaped `const` leaves that differ only in their numeric value.
      const constNode = (v: number) => ({ op: 'const', value: v, args: [] }) as unknown as Equation['lhs']
      const m: Model = {
        variables: {},
        equations: [
          { lhs: constNode(1), rhs: 'a' },
          { lhs: constNode(2), rhs: 'b' },
        ],
      }

      // The old field-blind equality compared only op/args, so both consts
      // looked equal and removeEquation deleted equation 0. deepEqualExpr
      // distinguishes them, so the value:2 equation is the one removed.
      const result = removeEquation(m, constNode(2))
      expect(result.equations).toHaveLength(1)
      expect(result.equations![0]!.rhs).toBe('a')

      // A value that matches neither equation is genuinely not found.
      expect(() => removeEquation(m, constNode(3))).toThrow(EntityNotFoundError)
    })

    it('should apply substitutions to equations', () => {
      const bindings = { k: 'k_new' }
      const result = substituteInEquations(model, bindings)

      expect(result).not.toBe(model)
      const secondEq = result.equations[1]
      expect(secondEq.rhs).toEqual({ op: '*', args: [{ op: '-', args: ['k_new'] }, 'x'] })
    })
  })

  describe('Reaction Operations', () => {
    it('should add a new reaction', () => {
      const newReaction: Reaction = {
        id: 'r2',
        substrates: [{ species: 'B', stoichiometry: 1 }],
        products: null,
        rate: { op: '*', args: ['rate', 'B'] },
      }

      const result = addReaction(reactionSystem, newReaction)

      expect(result).not.toBe(reactionSystem)
      expect(result.reactions).toHaveLength(2)
      expect(result.reactions[1]).toEqual(newReaction)
    })

    it('should remove a reaction by ID', () => {
      // Add another reaction first to avoid removing the last one
      const systemWithTwoReactions = addReaction(reactionSystem, {
        id: 'r2',
        substrates: [{ species: 'B', stoichiometry: 1 }],
        products: null,
        rate: { op: '*', args: ['rate', 'B'] },
      })

      const result = removeReaction(systemWithTwoReactions, 'r1')

      expect(result).not.toBe(systemWithTwoReactions)
      expect(result.reactions).toHaveLength(1)
      expect(result.reactions[0].id).toBe('r2')
    })

    it('should throw error when removing non-existent reaction', () => {
      expect(() => removeReaction(reactionSystem, 'nonexistent')).toThrow(EntityNotFoundError)
    })

    it('should add a new species', () => {
      const newSpecies: Species = {
        units: 'mol/L',
        description: 'Species C',
      }

      const result = addSpecies(reactionSystem, 'C', newSpecies)

      expect(result).not.toBe(reactionSystem)
      expect(result.species.C).toEqual(newSpecies)
      expect(result.species.A).toEqual(reactionSystem.species.A)
    })

    it('should remove species when not in use', () => {
      // Create a system where species B is not used
      const systemWithoutBUsage: ReactionSystem = {
        ...reactionSystem,
        reactions: [
          {
            id: 'r1',
            substrates: [{ species: 'A', stoichiometry: 1 }],
            products: null,
            rate: 'rate',
          },
        ],
      }

      const result = removeSpecies(systemWithoutBUsage, 'B')

      expect(result).not.toBe(systemWithoutBUsage)
      expect(result.species.B).toBeUndefined()
      expect(result.species.A).toEqual(reactionSystem.species.A)
    })

    it('should throw error when removing species that is in use', () => {
      expect(() => removeSpecies(reactionSystem, 'A')).toThrow(VariableInUseError)
    })
  })

  describe('Event Operations', () => {
    it('should add a continuous event', () => {
      // Legacy event shape (`condition` instead of the schema's
      // `conditions`); addContinuousEvent appends it untouched.
      const event = {
        name: 'boundary_hit',
        condition: { op: '>', args: ['x', 10] },
        affects: [{ lhs: 'v', rhs: { op: '-', args: ['v'] } }],
      } as unknown as ContinuousEvent

      const result = addContinuousEvent(model, event)

      expect(result).not.toBe(model)
      expect(result.continuous_events).toHaveLength(1)
      expect(result.continuous_events![0]).toEqual(event)
    })

    it('should add a discrete event', () => {
      // Legacy event shape (`condition` instead of the schema's
      // `trigger`); addDiscreteEvent appends it untouched.
      const event = {
        name: 'reset',
        condition: { op: '>', args: ['x', 5] },
        affects: [{ lhs: 'x', rhs: 0 }],
      } as unknown as DiscreteEvent

      const result = addDiscreteEvent(model, event)

      expect(result).not.toBe(model)
      expect(result.discrete_events).toHaveLength(1)
      expect(result.discrete_events![0]).toEqual(event)
    })

    it('should remove an event by name', () => {
      const modelWithEvent = addContinuousEvent(model, {
        name: 'test_event',
        condition: { op: '>', args: ['x', 1] },
        affects: [{ lhs: 'v', rhs: 0 }],
      } as unknown as ContinuousEvent)

      const result = removeEvent(modelWithEvent, 'test_event')

      expect(result).not.toBe(modelWithEvent)
      expect(result.continuous_events).toEqual([])
    })

    it('should throw error when removing non-existent event', () => {
      expect(() => removeEvent(model, 'nonexistent')).toThrow(EntityNotFoundError)
    })
  })

  describe('Coupling Operations', () => {
    it('should add a coupling entry', () => {
      // Legacy coupling shape (`vars` instead of the schema's
      // `connector`); addCoupling appends it untouched.
      const coupling = {
        type: 'couple' as const,
        systems: ['TestModel', 'TestSystem'],
        vars: [['TestModel.x', 'TestSystem.A']],
      } as unknown as CouplingEntry

      const result = addCoupling(esmFile, coupling)

      expect(result).not.toBe(esmFile)
      expect(result.coupling).toHaveLength(1)
      expect(result.coupling![0]).toEqual(coupling)
    })

    it('should remove a coupling entry by index', () => {
      const fileWithCoupling = addCoupling(esmFile, {
        type: 'couple' as const,
        systems: ['TestModel', 'TestSystem'],
        vars: [['TestModel.x', 'TestSystem.A']],
      } as unknown as CouplingEntry)

      const result = removeCoupling(fileWithCoupling, 0)

      expect(result).not.toBe(fileWithCoupling)
      expect(result.coupling).toBeUndefined()
    })

    it('should create a compose coupling', () => {
      const result = compose(esmFile, 'TestModel', 'TestSystem')

      expect(result).not.toBe(esmFile)
      expect(result.coupling).toHaveLength(1)
      expect(result.coupling![0]).toEqual({
        type: 'operator_compose',
        systems: ['TestModel', 'TestSystem'],
      })
    })

    it('should create a variable mapping', () => {
      const result = mapVariable(esmFile, 'TestModel.x', 'TestSystem.A')

      expect(result).not.toBe(esmFile)
      expect(result.coupling).toHaveLength(1)
      expect(result.coupling![0]).toEqual({
        type: 'variable_map',
        from: 'TestModel.x',
        to: 'TestSystem.A',
        transform: 'param_to_var',
      })
    })

    it('should create a variable mapping with an expression transform', () => {
      const transform = {
        op: '+',
        args: [{ op: '*', args: [2.0, 'TestModel.x'] }, 'TestSystem.A'],
      }
      const result = mapVariable(esmFile, 'TestModel.x', 'TestSystem.A', transform)

      expect(result).not.toBe(esmFile)
      expect(result.coupling).toHaveLength(1)
      expect(result.coupling![0]).toEqual({
        type: 'variable_map',
        from: 'TestModel.x',
        to: 'TestSystem.A',
        transform,
      })
    })
  })

  describe('File-level Operations', () => {
    it('should merge two ESM files', () => {
      // Deliberately schema-incomplete fixture, matching `esmFile` above.
      const fileB = {
        metadata: { name: 'fileB', version: '0.1.0' },
        models: {
          ModelB: {
            variables: { y: { type: 'state', units: 'm' } },
            equations: [{ lhs: 'y', rhs: 1 }],
          },
        },
      } as unknown as EsmFile

      const result = merge(esmFile, fileB)

      expect(result).not.toBe(esmFile)
      expect(result.models!.TestModel).toEqual(esmFile.models!.TestModel)
      expect(result.models!.ModelB).toEqual(fileB.models!.ModelB)
    })

    it('should extract a component', () => {
      const result = extract(esmFile, 'TestModel')

      expect(result).not.toBe(esmFile)
      expect(result.models!.TestModel).toEqual(esmFile.models!.TestModel)
      expect(result.reaction_systems).toBeUndefined()
    })

    it('should throw error when extracting non-existent component', () => {
      expect(() => extract(esmFile, 'NonExistent')).toThrow(EntityNotFoundError)
    })
  })
})
