/**
 * Cadence-class seeding for the dependency-partition pass
 * (CONFORMANCE_SPEC §5.7, normative; RFC semiring-faq-unified-ir §6.1).
 *
 * Every value is determined at one of three cadences, totally ordered
 * `const ⊏ discrete ⊏ continuous`, and a node's class is `max` over its inputs.
 * This module supplies the LEAF SEEDS that recursion bottoms out at, plus the
 * `max`-over-an-expression helper built on them.
 *
 * **The seeds come from the §6.3.1 classification API, never from a locally
 * re-derived notion of the categories.** §5.7.2 states the leaf-seed table in
 * terms of those functions precisely so that five bindings cannot disagree
 * about which nodes fold. Re-deriving "is this a state" here would be a sixth
 * derivation and a sixth chance to be wrong.
 *
 * | Leaf | Seed |
 * |---|---|
 * | the independent variable `t` | `continuous` |
 * | an unknown in `odeStates` | `continuous` |
 * | an unknown in `algebraicUnknowns` | `continuous` |
 * | an unknown in `observedUnknowns` | the join of its DEFINING EQUATION's RHS |
 * | a parameter in `brownianParameters` | `continuous` (resampled every step) |
 * | a parameter in `discreteParameters` | `discrete`, refined by its source |
 * | a parameter in `sampledParameters` / `constantParameters` | `const` |
 * | a numeric literal, index-set name, bound index symbol | `const` |
 *
 * The OBSERVED leaf is the one 1.0.0 changes, and it must not be shortcut.
 * Before 1.0.0 an observed leaf seeded `const`, with the code admitting that
 * was imprecise and unexercised. That is now both unavailable (observed and
 * ODE-state are the same declared type) and unsound, since an observed defined
 * from a state is `continuous`. Seeding every unknown `continuous` is equally
 * wrong the other way: it would stop a STATE-FREE observed from folding, and
 * const-folding exactly those is what the geometry and projection-pushdown
 * paths rely on. So an observed leaf resolves to the join of its defining
 * equation's RHS, transitively, memoised, with a cycle guard.
 */

import type { EsmFile, Expression, Model } from './types.js'
import { ERROR_CODES, EsmDiagnosticError } from './errors.js'
import { forEachChild, isExprNode } from './expression.js'
import { isRecurrenceCandidate } from './recurrence.js'
import {
  odeStates,
  observedUnknowns,
  algebraicUnknowns,
  brownianParameters,
  parameterClass,
  updateRules,
  observedDefinitions,
} from './classification.js'

/** The three cadence classes, totally ordered `const ⊏ discrete ⊏ continuous`. */
export type CadenceClass = 'const' | 'discrete' | 'continuous'

const RANK: Record<CadenceClass, number> = { const: 0, discrete: 1, continuous: 2 }

/** The join (`max`) of two cadence classes. */
export function joinCadence(a: CadenceClass, b: CadenceClass): CadenceClass {
  return RANK[a] >= RANK[b] ? a : b
}

/** The join of any number of cadence classes; `const` when there are none. */
export function joinAll(classes: Iterable<CadenceClass>): CadenceClass {
  let out: CadenceClass = 'const'
  for (const c of classes) out = joinCadence(out, c)
  return out
}

/** Raised when the observed-definition chain contains a cycle. */
export class CadenceCycleError extends EsmDiagnosticError {
  constructor(public readonly cycle: string[]) {
    super(
      ERROR_CODES.CIRCULAR_DEPENDENCY,
      `Cyclic observed definition while seeding cadence: ${cycle.join(' -> ')}`,
    )
    this.name = 'CadenceCycleError'
  }
}

/**
 * A reusable cadence seeder for ONE model. Holds the memo table for observed
 * resolution, so a chain of observeds is resolved once rather than once per
 * reference.
 */
export class CadenceSeeder {
  private readonly states: Set<string>
  private readonly algebraic: Set<string>
  private readonly brownian: Set<string>
  private readonly observedDefs: Map<string, Expression>
  private readonly memo = new Map<string, CadenceClass>()
  private readonly inProgress: string[] = []
  private readonly independentVariable: string
  /**
   * Memo for {@link isRecurrence}. A recurrence body reads itself once per lag —
   * 38 times in `tests/fixtures/recurrence/07_recurrence_thirty_eight_lags.esm`
   * — and each read reaches `leaf` as a separate self-edge, so without this the
   * whole well-foundedness analysis would re-run per lag.
   */
  private readonly recurrenceMemo = new Map<string, boolean>()

  constructor(
    private readonly model: Model,
    private readonly esmFile?: EsmFile,
  ) {
    this.states = new Set(odeStates(model))
    this.algebraic = new Set(algebraicUnknowns(model))
    this.brownian = new Set(brownianParameters(model))
    this.observedDefs = observedDefinitions(model)
    this.independentVariable = esmFile?.domain?.independent_variable || 't'
  }

  /**
   * Whether `name`'s defining equation is a causal-recurrence CANDIDATE --
   * array-shaped, with an `index` self-read in its own RHS -- and so whether its
   * self-edge is an ordering the §4.3.1.1 rules govern rather than a cycle.
   *
   * Candidacy, not well-foundedness: see `isRecurrenceCandidate` for why the
   * stricter predicate would mask the very codes §5.19.5 requires. Delegated
   * wholesale to `recurrence.js` so the seeder and the validator cannot disagree
   * about which equations the construct covers. Memoized because a recurrence
   * body reads itself once per lag.
   */
  private isRecurrence(name: string): boolean {
    const memoized = this.recurrenceMemo.get(name)
    if (memoized !== undefined) return memoized
    const verdict = isRecurrenceCandidate(this.model, name, this.esmFile)
    this.recurrenceMemo.set(name, verdict)
    return verdict
  }

  /** The set of observed unknowns, for callers that want to enumerate them. */
  observedNames(): string[] {
    return observedUnknowns(this.model)
  }

  /**
   * The cadence seed of a single NAME appearing as a leaf.
   *
   * A name that is not declared in this model — an index-set name, a bound index
   * symbol, a relation tag, a coupled reference — seeds `const`, matching the
   * final row of the §5.7.2 table.
   */
  leaf(name: string): CadenceClass {
    if (name === this.independentVariable) return 'continuous'

    const memoized = this.memo.get(name)
    if (memoized !== undefined) return memoized

    const variable = this.model.variables?.[name]
    if (variable === undefined) return 'const'

    if (variable.type === 'parameter') {
      const seed = this.parameterSeed(name)
      this.memo.set(name, seed)
      return seed
    }

    // An unknown.
    if (this.states.has(name) || this.algebraic.has(name)) {
      this.memo.set(name, 'continuous')
      return 'continuous'
    }

    // Observed: the join of its DEFINING EQUATION's RHS, resolved transitively.
    // The observed sub-DAG is acyclic (§4.9.4 balance plus the DAE contract), so
    // the recursion terminates; a cycle is a defect and is REPORTED rather than
    // silently seeded.
    //
    // The SELF-EDGE `V -> V` is the one exception, and it is dropped rather than
    // reported (esm-spec §4.3.1.1, CONFORMANCE_SPEC §5.19.5). A causal
    // self-reference — `V`'s own defining `aggregate` reading `index(V, k-1)` —
    // is an ORDERING WITHIN one variable, not a dependency between two: the
    // sweep publishes cell `k-1` before it evaluates cell `k`, so there is
    // nothing to break. It therefore contributes `const`, which is
    // `joinCadence`'s identity, leaving `V`'s seed to come from its other
    // inputs. Mirrors the `n != self_name` retains every executing binding
    // already applies to the observed dependency graph (Rust
    // `dependency_order_observed`, `classify_segment_invariant_observeds`).
    //
    // The exemption is narrow in TWO ways, and both matter.
    //
    // It applies only to the edge closing on the definition being expanded RIGHT
    // NOW, which is why this tests the TOP of the stack rather than membership:
    // a longer path (`V -> W -> V`) is a genuine cycle through DISTINCT
    // variables and still throws below.
    //
    // And it applies only when the equation is a recurrence CANDIDATE: the
    // variable is array-shaped and its RHS carries an `index` self-read. A
    // self-reference with no `index` read at all -- a scalar `x ~ x + 1`, or a
    // bare `s ~ s + 1` over an array -- is not an ordering in any sense; it is
    // an equation reading a name nothing binds, nothing else will report it, and
    // it keeps its cycle rejection. That is §5.19.5's converse duty: admitting a
    // recurrence must not weaken any cycle rejection.
    //
    // Candidacy rather than WELL-FOUNDEDNESS, deliberately. A malformed array
    // self-read (`index(s, k+1)`, `index(s, 2*k)`, one inside a `makearray`
    // region) has to surface as `recurrence_not_wellfounded` /
    // `recurrence_unsupported_form` at the offending expression, because those
    // codes are the cross-binding contract. Gating on well-foundedness would
    // make this cycle error fire first for exactly those documents and collapse
    // the file to a single `load_error`, losing the code -- the same masking
    // defect this feature began as, moved from the legal case to the illegal
    // one. So the drop hands the equation to `validateRecurrenceEquations`,
    // which owns the verdict either way.
    if (this.inProgress[this.inProgress.length - 1] === name && this.isRecurrence(name)) {
      return 'const'
    }
    if (this.inProgress.includes(name)) {
      throw new CadenceCycleError([...this.inProgress.slice(this.inProgress.indexOf(name)), name])
    }
    const definition = this.observedDefs.get(name)
    if (definition === undefined) {
      // An unknown with no defining equation is an unbalanced system, which
      // `equation_count_mismatch` reports. Seed conservatively.
      this.memo.set(name, 'continuous')
      return 'continuous'
    }

    this.inProgress.push(name)
    let seed: CadenceClass
    try {
      seed = this.expression(definition)
    } finally {
      this.inProgress.pop()
    }
    this.memo.set(name, seed)
    return seed
  }

  /**
   * A parameter's seed: `continuous` when Brownian, `const` when sampled or
   * constant, otherwise `discrete` subject to the source refinement.
   *
   * **Source-seeded refinement** (§5.7.2, RFC pure-io-data-loaders §4.6). When a
   * parameter's `update` is the `data` kind, its `source` names a `data_sources`
   * entry, and it is the SOURCE — not the parameter's own declaration — that
   * fixes the seed. A source WITH `temporal` keeps the parameter `discrete`
   * (its refresh cadence is the source's update times); one WITHOUT describes
   * non-time-varying data, so the parameter refines down to `const` — loaded
   * once. Any other update kind, or a `source` that resolves to no entry, keeps
   * the `discrete` seed.
   *
   * This is the one context in which a leaf's seed reads a document field
   * outside its own declaration.
   */
  private parameterSeed(name: string): CadenceClass {
    const variable = this.model.variables![name]
    const cls = parameterClass(variable)
    if (cls === 'brownian') return 'continuous'
    if (cls === 'sampled' || cls === 'constant') return 'const'

    // Discrete. Refine only when EVERY rule is a `data` update whose source is
    // declared and non-temporal: one rule refreshing on any other trigger keeps
    // the parameter piecewise-constant on that trigger's cadence.
    const rules = updateRules(variable.update)
    const allConstData = rules.every((rule) => {
      if (rule.kind !== 'data') return false
      const source = this.esmFile?.data_sources?.[rule.source]
      if (source === undefined) return false // undeclared: keep DISCRETE
      return source.temporal === undefined
    })
    return allConstData ? 'const' : 'discrete'
  }

  /**
   * The cadence of an EXPRESSION: `max` over its leaves.
   *
   * The gather rule needs no special case — index expressions are ordinary
   * children, so `index(u, index(nbr, i, k))` splits naturally, the inner
   * neighbour selection staying `const` while the outer value load is
   * `continuous` because it touches `u`.
   */
  expression(expr: Expression): CadenceClass {
    if (typeof expr === 'number') return 'const'
    if (typeof expr === 'string') return this.leaf(expr)
    if (!isExprNode(expr)) return 'const'

    let out: CadenceClass = 'const'
    forEachChild(expr, (child) => {
      out = joinCadence(out, this.expression(child as Expression))
      return undefined
    })
    return out
  }
}

/** The cadence seed of one leaf NAME in a model. */
export function leafCadence(model: Model, name: string, esmFile?: EsmFile): CadenceClass {
  return new CadenceSeeder(model, esmFile).leaf(name)
}

/** The cadence of an expression in a model: `max` over its leaves. */
export function expressionCadence(model: Model, expr: Expression, esmFile?: EsmFile): CadenceClass {
  return new CadenceSeeder(model, esmFile).expression(expr)
}
