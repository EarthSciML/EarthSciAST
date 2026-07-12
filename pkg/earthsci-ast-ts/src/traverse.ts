/**
 * Shared component/variable/equation traversal for ESM files.
 *
 * Model and reaction-system traversal was historically re-implemented with
 * DIVERGENT skip rules in `graph.ts` (`processModel`/`processReactionSystem`),
 * `flatten.ts` (`flattenModel`/`flattenReactionSystem`), and `units.ts`
 * (`validateUnits`). This module provides ONE documented policy that those
 * call sites can share, so subsystem descent, reference-stub handling, and
 * scoped-name composition are defined in exactly one place.
 *
 * Scope: this walker yields COMPONENTS (models / reaction systems),
 * VARIABLES, and EQUATIONS. It deliberately does NOT walk expression trees —
 * that is `mapChildren`/`freeVariables` in `expression.ts`. Callers that need
 * to inspect an equation RHS or an observed-variable expression walk it
 * themselves with the expression utilities.
 */

import type {
  EsmFile,
  Model,
  ReactionSystem,
  ModelVariable,
  Equation,
  SubsystemRef,
  DataLoader,
} from './types.js'

/** The two top-level containers a component can live under. */
export type ContainerKind = 'models' | 'reaction_systems'

/**
 * A component entry as it appears in a `models`/`reaction_systems` map or in a
 * component's `subsystems` map. It is either a real inline component
 * (`Model` / `ReactionSystem`), an include-by-reference stub (`SubsystemRef`,
 * discriminated by `ref`), or — for a model subsystem only — an inline data
 * loader (`DataLoader`, discriminated by `kind`).
 */
export type ComponentEntry = Model | ReactionSystem | SubsystemRef | DataLoader

/**
 * A reference-stub subsystem: either a `{ref}` include (`SubsystemRef`) or a
 * `{kind}` data loader (`DataLoader`). These are resolved/bound elsewhere, so
 * the traversal treats them as opaque leaves.
 */
export type ReferenceStub = SubsystemRef | DataLoader

/**
 * One visit emitted by {@link forEachComponent}. `isReference` discriminates
 * the payload: real inline components (`false`) carry a `Model | ReactionSystem`;
 * reference stubs (`true`) carry a `SubsystemRef | DataLoader`. Narrow on
 * `isReference` first, then on `kind` to pick `Model` vs `ReactionSystem`.
 */
export type ComponentVisit =
  | {
      kind: ContainerKind
      /** The component's own key within its parent map. */
      name: string
      /** Dot-composed path from the file root, e.g. `Parent.Child`. */
      scopedName: string
      isReference: false
      component: Model | ReactionSystem
    }
  | {
      kind: ContainerKind
      name: string
      scopedName: string
      isReference: true
      component: ReferenceStub
    }

/**
 * A reference-stub entry is one carrying `ref` (a `SubsystemRef` include) or
 * `kind` (an inline `DataLoader`). Real components (`Model` / `ReactionSystem`)
 * carry neither — a `Model` uses `system_kind`, and both use `reference`
 * (not `ref`) for provenance — so this test cleanly separates the two.
 */
export function isReferenceStub(entry: ComponentEntry): entry is ReferenceStub {
  return 'ref' in entry || 'kind' in entry
}

/**
 * Visit every model and reaction system in a file.
 *
 * Top-level entries under `models` and `reaction_systems` are always visited.
 * When `opts.recurse` is true (default `false`), the walk descends into the
 * `subsystems` of every real inline component, composing `scopedName` with dot
 * separators (`Parent.Child.Grandchild`).
 *
 * Subsystem / skip policy (the single, shared rule replacing three divergent
 * ones):
 *
 *   - Real inline components (`Model` / `ReactionSystem`) are visited with
 *     `isReference: false` and, under `recurse`, descended into.
 *   - Reference-stub subsystems — entries carrying `ref` (a `SubsystemRef`
 *     include) or `kind` (an inline `DataLoader`) — are visited as LEAVES with
 *     `isReference: true` and are NEVER descended into, even under `recurse`.
 *     Their contents are resolved elsewhere (ref resolution / loader binding),
 *     so any nested structure they happen to carry is intentionally ignored.
 *
 * The callback order is: each entry is emitted before its own subsystems
 * (pre-order), in `Object.entries` iteration order.
 */
export function forEachComponent(
  file: EsmFile,
  cb: (visit: ComponentVisit) => void,
  opts?: { recurse?: boolean },
): void {
  const recurse = opts?.recurse ?? false

  const visit = (kind: ContainerKind, name: string, scopedName: string, entry: ComponentEntry) => {
    if (isReferenceStub(entry)) {
      cb({ kind, name, scopedName, isReference: true, component: entry })
      return
    }

    const component = entry as Model | ReactionSystem
    cb({ kind, name, scopedName, isReference: false, component })

    if (!recurse || !component.subsystems) return
    for (const [subName, subEntry] of Object.entries(component.subsystems)) {
      visit(kind, subName, `${scopedName}.${subName}`, subEntry)
    }
  }

  if (file.models) {
    for (const [name, entry] of Object.entries(file.models)) {
      visit('models', name, name, entry)
    }
  }
  if (file.reaction_systems) {
    for (const [name, entry] of Object.entries(file.reaction_systems)) {
      visit('reaction_systems', name, name, entry)
    }
  }
}

/**
 * Visit every variable of a model, in declaration (`Object.entries`) order.
 * The callback receives the variable value first and its key second, mirroring
 * {@link forEachEquation}'s `(equation, index)` shape.
 */
export function forEachModelVariable(
  model: Model,
  cb: (variable: ModelVariable, name: string) => void,
): void {
  for (const [name, variable] of Object.entries(model.variables ?? {})) {
    cb(variable, name)
  }
}

/**
 * Visit the equations of a component.
 *
 * Coverage (documented, since the component types are disjoint):
 *   - `Model.equations` — the dynamic ODE/DAE equations.
 *   - `ReactionSystem.constraint_equations` — algebraic/ODE constraints.
 *
 * A `Model` has no `constraint_equations` field and a `ReactionSystem` has no
 * `equations` field, so exactly one list applies per component; both are
 * checked defensively and, if both were present, are visited in the order
 * `[...equations, ...constraint_equations]`.
 *
 * Intentionally NOT covered (out of scope — separate structures the caller
 * handles directly): `Model.initialization_equations` (t=0 only), and
 * `ReactionSystem.reactions` (which are not `{lhs, rhs}` equations).
 *
 * `index` is the position within the concatenated equation sequence, starting
 * at 0.
 */
export function forEachEquation(
  component: Model | ReactionSystem,
  cb: (equation: Equation, index: number) => void,
): void {
  let index = 0
  const equations = (component as Model).equations
  if (Array.isArray(equations)) {
    for (const equation of equations) cb(equation, index++)
  }
  const constraintEquations = (component as ReactionSystem).constraint_equations
  if (Array.isArray(constraintEquations)) {
    for (const equation of constraintEquations) cb(equation, index++)
  }
}
