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
 * VARIABLES, EQUATIONS, and every EXPRESSION POSITION a component carries
 * ({@link forEachExpressionScope}). It deliberately does NOT walk INSIDE an
 * expression tree — that is `mapChildren`/`forEachChild` in `expression.ts`.
 * The division of labour is the point: this module answers "WHICH expressions
 * does a component have, and where do they live?", and `forEachChild` answers
 * "what is inside one expression?". A checker that composes the two sees every
 * name in the document; a checker that hand-rolls either half sees a subset.
 */

import { isNumericLiteral } from './numeric-literal.js'
import type {
  EsmFile,
  Model,
  ReactionSystem,
  ModelVariable,
  Equation,
  Expression,
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

/**
 * Is `value` an ESM `Expression` (a number, a variable name, or an operator
 * node) rather than a structured sidecar that merely OCCUPIES an expression
 * slot?
 *
 * The distinction matters at the two `oneOf` sites: a test assertion's
 * `reference` is either an inline Expression or a `{from_file: …}` shape, and a
 * data loader's `unit_conversion` is either a plain numeric factor or an
 * Expression. Handing the non-expression alternative to a reference walker would
 * mine its keys for "variables" that are nothing of the sort.
 */
export function isExpressionLike(value: unknown): boolean {
  if (typeof value === 'string' || typeof value === 'number') return true
  if (value === null || typeof value !== 'object') return false
  // An operator node, or a tagged int/float NumericLiteral leaf.
  return 'op' in (value as object) || isNumericLiteral(value)
}

/**
 * One expression position: the expression itself, plus the JSON Pointer naming
 * the field it was found in.
 */
export interface ExpressionSite {
  expr: Expression
  /** JSON Pointer, e.g. `/models/M/variables/v/expression`. */
  path: string
}

/**
 * A group of expression positions that share ONE binder scope.
 *
 * An equation is a single scope holding its `lhs` AND `rhs`, because a binder
 * introduced on one side is visible on the other: the aggregate-IR form
 * `aggregate(output_idx:[i], D(index(u,i))) ~ aggregate(output_idx:[i], k*index(u,i))`
 * binds `i` across the whole relation. Every other position (an observed
 * variable's `expression`, an event condition, an affect RHS, a solver guess) is
 * its own scope of one.
 */
export type ExpressionScope = ExpressionSite[]

/**
 * Visit EVERY expression-bearing field of a component, grouped into binder
 * scopes and tagged with its JSON Pointer.
 *
 * THIS IS THE FIX FOR THE SILENT HOLE. Reference integrity used to walk
 * `equations` and nothing else, so an undefined name anywhere else in the
 * document was INVISIBLE — a false negative that nothing caught and no fixture
 * pinned. The positions below were all unchecked:
 *
 *   - `variables[v].expression`            — an OBSERVED variable's defining expression
 *   - `initialization_equations[i].lhs/rhs` — t=0 equations
 *   - `guesses[v]`                          — nonlinear-solver initial guesses
 *   - `discrete_events[i].trigger.expression`     — a `type: "condition"` trigger
 *   - `discrete_events[i].affects[j].rhs`         — the affect's VALUE
 *   - `continuous_events[i].conditions[j]`        — the root-finding conditions
 *   - `continuous_events[i].affects[j].rhs`
 *   - `continuous_events[i].affect_neg[j].rhs`
 *
 * (An affect's `lhs` is a plain variable NAME, not an expression; it is checked
 * by `validateEventConsistency`, which is why it is not yielded here.)
 *
 * A reaction system's `constraint_equations` are yielded by the same
 * `forEachEquation` policy; its `reactions[].rate` is not an `{lhs, rhs}`
 * equation and is checked by `validateReactionConsistency`.
 *
 * Enumerating positions here — rather than hand-rolling a second walk per
 * checker — is what makes "every expression in the document" a property of ONE
 * function that can be extended once, instead of a promise each checker has to
 * keep independently.
 */
export function forEachExpressionScope(
  component: Model | ReactionSystem,
  componentPath: string,
  cb: (scope: ExpressionScope) => void,
): void {
  const model = component as Model

  // `equations` (+ a reaction system's `constraint_equations`) — the historical
  // coverage, kept byte-identical: one scope per equation, holding both sides.
  const equationsKey =
    Array.isArray(model.equations) ||
    !Array.isArray((component as ReactionSystem).constraint_equations)
      ? 'equations'
      : 'constraint_equations'
  forEachEquation(component, (equation, index) => {
    cb([
      { expr: equation.lhs, path: `${componentPath}/${equationsKey}/${index}/lhs` },
      { expr: equation.rhs, path: `${componentPath}/${equationsKey}/${index}/rhs` },
    ])
  })

  // t=0 equations — deliberately outside `forEachEquation` (see its docstring),
  // and therefore previously unchecked by every caller of it.
  const initEquations = model.initialization_equations
  if (Array.isArray(initEquations)) {
    initEquations.forEach((equation: Equation, index: number) => {
      const base = `${componentPath}/initialization_equations/${index}`
      cb([
        { expr: equation.lhs, path: `${base}/lhs` },
        { expr: equation.rhs, path: `${base}/rhs` },
      ])
    })
  }

  // An OBSERVED variable's defining expression — the named hole.
  for (const [name, variable] of Object.entries(model.variables ?? {})) {
    const expression = (variable as ModelVariable)?.expression
    if (expression !== undefined && expression !== null) {
      cb([{ expr: expression, path: `${componentPath}/variables/${name}/expression` }])
    }
  }

  // Nonlinear-solver initial guesses.
  for (const [name, guess] of Object.entries(model.guesses ?? {})) {
    if (guess !== undefined && guess !== null) {
      cb([{ expr: guess as Expression, path: `${componentPath}/guesses/${name}` }])
    }
  }

  // Discrete events: a `condition` trigger's expression, and every affect RHS.
  ;(model.discrete_events ?? []).forEach((event, i) => {
    const base = `${componentPath}/discrete_events/${i}`
    const trigger = event?.trigger as { expression?: Expression } | undefined
    if (trigger?.expression !== undefined && trigger.expression !== null) {
      cb([{ expr: trigger.expression, path: `${base}/trigger/expression` }])
    }
    ;(event?.affects ?? []).forEach((affect, j) => {
      if (affect?.rhs !== undefined && affect.rhs !== null) {
        cb([{ expr: affect.rhs as Expression, path: `${base}/affects/${j}/rhs` }])
      }
    })
  })

  // Inline-test assertions: a `reference` solution may be an inline Expression
  // evaluated over the component's coordinates (the other form is a `from_file`
  // shape, which carries no variable references and is skipped).
  ;((model as { tests?: unknown[] }).tests ?? []).forEach((test, i) => {
    const assertions = (test as { assertions?: unknown[] })?.assertions ?? []
    assertions.forEach((assertion, j) => {
      const reference = (assertion as { reference?: unknown })?.reference
      if (isExpressionLike(reference)) {
        cb([
          {
            expr: reference as Expression,
            path: `${componentPath}/tests/${i}/assertions/${j}/reference`,
          },
        ])
      }
    })
  })

  // Continuous events: root-finding conditions, and every affect / affect_neg RHS.
  ;(model.continuous_events ?? []).forEach((event, i) => {
    const base = `${componentPath}/continuous_events/${i}`
    ;(event?.conditions ?? []).forEach((condition, j) => {
      if (condition !== undefined && condition !== null) {
        cb([{ expr: condition, path: `${base}/conditions/${j}` }])
      }
    })
    for (const field of ['affects', 'affect_neg'] as const) {
      const affects = event?.[field]
      if (!Array.isArray(affects)) continue
      affects.forEach((affect, j) => {
        if (affect?.rhs !== undefined && affect.rhs !== null) {
          cb([{ expr: affect.rhs as Expression, path: `${base}/${field}/${j}/rhs` }])
        }
      })
    }
  })
}
