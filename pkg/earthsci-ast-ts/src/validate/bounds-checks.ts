/**
 * The structural rules for a model variable's `lb` / `ub` (esm-spec §6.3.2):
 *
 * 1. a reference that resolves to no variable — `undefined_variable`;
 * 2. a referenced variable whose declared shape is neither scalar nor the
 *    bounded variable's — `variable_bound_shape_mismatch`;
 * 3. a reference to the bounded variable itself, or to an observed whose
 *    definition reads it, directly or through other observeds —
 *    `variable_bound_circular`;
 * 4. two number bounds with `lb > ub` — `variable_bounds_inverted`.
 *
 * A reference resolves exactly as a variable reference in the owning model's
 * expressions: {@link scopedNameFrom}, the resolver the `circular_dependency`
 * graph uses (esm-spec §4.9.7). Rule 3 walks the same observed definitions as
 * that graph ({@link documentObservedReads}). Rules 2 and 3 are skipped for a
 * reference rule 1 reports.
 */

import { ERROR_CODES } from '../errors.js'
import { numericValue } from '../numeric-literal.js'
import type { EsmFile, Model, ReactionSystem, SubsystemRef } from '../types.js'
import type { StructuralError } from './types.js'
import { isInlineModel, scopedNameFrom } from './expr-utils.js'
import { documentObservedReads, type ObservedReads } from './coupling-checks.js'

const SIDES = ['lb', 'ub'] as const

/** A declared shape as compared by rule 2: `[]` for scalar (omitted, `null` or empty). */
function declaredShape(shape: unknown): string[] {
  return Array.isArray(shape) ? (shape as string[]) : []
}

function sameShape(a: string[], b: string[]): boolean {
  return a.length === b.length && a.every((name, i) => name === b[i])
}

function showShape(shape: string[]): string {
  return shape.length === 0 ? '(scalar)' : `[${shape.join(', ')}]`
}

/**
 * Every variable a bound can name, keyed by full scoped name, with its declared
 * shape: the variables of inline models and subsystems at any depth, and the
 * species (always scalar) and parameters of reaction systems.
 */
function declaredShapes(esmFile: EsmFile): Map<string, string[]> {
  const shapes = new Map<string, string[]>()
  const walkModel = (scope: string, model: Model): void => {
    for (const [name, variable] of Object.entries(model.variables ?? {})) {
      shapes.set(`${scope}.${name}`, declaredShape(variable.shape))
    }
    for (const [name, sub] of Object.entries(model.subsystems ?? {})) {
      if (isInlineModel(sub)) walkModel(`${scope}.${name}`, sub)
    }
  }
  const walkReactions = (scope: string, rs: ReactionSystem | SubsystemRef): void => {
    if ('ref' in rs) return
    for (const name of Object.keys(rs.species ?? {})) shapes.set(`${scope}.${name}`, [])
    for (const [name, param] of Object.entries(rs.parameters ?? {})) {
      shapes.set(`${scope}.${name}`, declaredShape((param as { shape?: unknown }).shape))
    }
    for (const [name, sub] of Object.entries(rs.subsystems ?? {})) {
      walkReactions(`${scope}.${name}`, sub)
    }
  }
  for (const [name, model] of Object.entries(esmFile.models ?? {})) {
    if (isInlineModel(model)) walkModel(name, model)
  }
  for (const [name, rs] of Object.entries(esmFile.reaction_systems ?? {})) {
    walkReactions(name, rs)
  }
  return shapes
}

/**
 * The chain of observeds from `start` whose definitions lead to `target`
 * (`[start, ..., target]`), or `undefined` when none does. Only an observed has
 * a definition to follow; a state, a parameter, an algebraic unknown or a
 * species ends the walk.
 */
function dependenceChain(
  start: string,
  target: string,
  reads: Map<string, ObservedReads>,
  esmFile: EsmFile,
): string[] | undefined {
  const parent = new Map<string, string>([[start, start]])
  const pending = [start]
  while (pending.length > 0) {
    const node = pending.pop()!
    const definition = reads.get(node)
    if (definition === undefined) continue
    for (const ref of definition.refs) {
      const next = scopedNameFrom(ref, definition.scope, definition.model, esmFile)
      if (next === undefined || parent.has(next)) continue
      parent.set(next, node)
      if (next === target) {
        const chain = [next]
        for (let at = node; ; at = parent.get(at)!) {
          chain.unshift(at)
          if (at === start) return chain
        }
      }
      pending.push(next)
    }
  }
  return undefined
}

/**
 * Check the bounds of every variable of the inline models and subsystems of
 * `esmFile`, at any depth (esm-spec §6.3.2).
 */
export function validateVariableBounds(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []
  let shapes: Map<string, string[]> | undefined
  let reads: Map<string, ObservedReads> | undefined

  const checkModel = (scope: string, path: string, model: Model): void => {
    // A name relative to this model, for messages: `a` rather than `M.a`.
    const local = (name: string): string =>
      name.startsWith(`${scope}.`) ? name.slice(scope.length + 1) : name

    for (const [name, variable] of Object.entries(model.variables ?? {})) {
      if (variable.lb === undefined && variable.ub === undefined) continue
      const varPath = `${path}/variables/${name}`
      const self = `${scope}.${name}`

      for (const side of SIDES) {
        const reference: unknown = variable[side]
        if (typeof reference !== 'string' || reference === '') continue
        shapes ??= declaredShapes(esmFile)
        reads ??= documentObservedReads(esmFile).reads
        const at = `${varPath}/${side}`

        // A bare name is a variable of this model; `shapes` holds every
        // declared one, so a lookup miss is an unresolved reference.
        const target = scopedNameFrom(reference, scope, model, esmFile)
        const targetShape = target === undefined ? undefined : shapes.get(target)
        if (target === undefined || targetShape === undefined) {
          errors.push({
            path: at,
            code: ERROR_CODES.UNDEFINED_VARIABLE,
            message: `Variable "${reference}" referenced as the ${side} of '${name}' but not declared`,
            details: { variable: reference, bound: side },
          })
          continue
        }

        const ownShape = declaredShape(variable.shape)
        if (targetShape.length > 0 && !sameShape(targetShape, ownShape)) {
          errors.push({
            path: at,
            code: ERROR_CODES.VARIABLE_BOUND_SHAPE_MISMATCH,
            message:
              `The ${side} of '${name}' references '${reference}', shaped ${showShape(targetShape)}; ` +
              `a bound must be scalar or the bounded variable's shape ${showShape(ownShape)}`,
            details: { variable: name, bound: side, reference },
          })
        }

        const chain = target === self ? [self] : dependenceChain(target, self, reads, esmFile)
        if (chain !== undefined) {
          errors.push({
            path: at,
            code: ERROR_CODES.VARIABLE_BOUND_CIRCULAR,
            message:
              target === self
                ? `The ${side} of '${name}' refers to '${name}' itself`
                : `The ${side} of '${name}' refers to '${reference}', whose definition depends on ` +
                  `'${name}' (${chain.map(local).join(' -> ')})`,
            details: { variable: name, bound: side, reference },
          })
        }
      }

      const lb = numericValue(variable.lb)
      const ub = numericValue(variable.ub)
      if (lb !== undefined && ub !== undefined && lb > ub) {
        errors.push({
          path: varPath,
          code: ERROR_CODES.VARIABLE_BOUNDS_INVERTED,
          message: `'${name}' has lb ${lb} greater than ub ${ub}`,
          details: { variable: name, lb, ub },
        })
      }
    }

    for (const [subName, sub] of Object.entries(model.subsystems ?? {})) {
      if (isInlineModel(sub))
        checkModel(`${scope}.${subName}`, `${path}/subsystems/${subName}`, sub)
    }
  }

  for (const [name, model] of Object.entries(esmFile.models ?? {})) {
    if (isInlineModel(model)) checkModel(name, `/models/${name}`, model)
  }
  return errors
}
