/**
 * The structural rule that governs a model's OBSERVED DEFINITIONS as a whole
 * (esm-spec §4.9.6): {@link validateObservedCycles} — `observed_cycle`.
 *
 * An observed unknown is *defined* by the RHS of the equation whose LHS names
 * it (§6.3.1), so a model's observed definitions induce a dependency graph over
 * the observed names — `V → W` whenever `W` occurs free in `V`'s defining RHS
 * and `W` is itself an observed of the same model. A cycle in that graph means
 * no evaluation order satisfies every definition, and it is decidable from the
 * equations alone: no shapes, no values, no solver. That is why it lives here,
 * at the same layer as `undefined_variable` and `equation_count_mismatch`, and
 * not in whatever a binding does afterwards.
 *
 * Issue #181 is the reason the check exists as a NAMED diagnostic rather than
 * as whatever the build happens to say. A binding that lets the cycle through
 * materializes the observeds in some order, reads one that has no value yet,
 * and reports whichever name its walk reached first — typically an observed
 * that is declared, referenced and defined perfectly well. The shared fixture
 * `tests/invalid/observed_cycle_array_elementwise.esm` is built around exactly
 * that misattribution: its `in_pbl` is the innocent bystander, and it must not
 * appear on the reported cycle.
 *
 * This rule needs no evaluator, which is why a parse-and-validate binding can
 * and must implement it (CONFORMANCE_SPEC §5.19.5 rejection parity).
 */

import { ERROR_CODES } from '../errors.js'
import { observedDefinitions } from '../classification.js'
import { isRecurrenceCandidate } from '../recurrence.js'
import type { EsmFile, Model } from '../types.js'
import type { StructuralError } from './types.js'
import { extractVariableReferences, collectIndexSymbols } from './expr-utils.js'

/**
 * The observed-definition dependency graph of one model, as a SORTED adjacency
 * map: every observed name, mapped to the observeds its own defining RHS names,
 * in sorted order.
 *
 * Sorted on both axes — the keys the DFS takes as roots, and each node's
 * successors — because the cycle a diagnostic NAMES is chosen by the traversal
 * order. `gamfac -> hpbl -> wscale -> gamfac` and `hpbl -> wscale -> gamfac ->
 * hpbl` describe the same defect, and a graph walked in insertion or hash order
 * would hand a different one of them to two runs over the same document.
 *
 * Binder-introduced symbols are subtracted before the intersection, exactly as
 * {@link validateReferenceIntegrity} subtracts them: an `aggregate` range key,
 * an `index` position, an `argmin` witness is a scoped iteration symbol, not a
 * reference, so one that happens to share a name with an observed must not
 * manufacture an edge.
 */
function observedDependencyGraph(
  model: Model,
  esmFile: EsmFile | undefined,
): Map<string, string[]> {
  const definitions = observedDefinitions(model)
  const graph = new Map<string, string[]>()

  for (const [name, rhs] of definitions) {
    const bound = collectIndexSymbols(rhs)
    const successors = new Set(
      extractVariableReferences(rhs).filter((ref) => !bound.has(ref) && definitions.has(ref)),
    )

    // esm-spec §4.3.1.1: a causal self-read is an ORDERING WITHIN one variable,
    // not a dependency between two — the sweep publishes cell `k-1` before it
    // evaluates cell `k` — so the self-edge `V -> V` is dropped for a recurrence
    // CANDIDATE, and only for one.
    //
    // Candidacy, never the well-foundedness verdict (CONFORMANCE_SPEC §5.19.5).
    // Gating on the verdict would make an ILL-founded self-read non-exempt, so
    // this check would fire first and the `recurrence_not_wellfounded` /
    // `recurrence_unsupported_form` diagnosis — which is the cross-binding
    // contract for exactly those documents — would never be reached. Gating
    // instead on "is this a self-edge at all" is the mirror-image mistake: a
    // scalar `x ~ x + 1`, or a bare `s ~ s + 1` over an array, has no axis to
    // fold along, can never be a recurrence, and IS a cycle of length one that
    // this check must keep reporting. `isRecurrenceCandidate` is the same
    // predicate the cadence seeder drops its self-edge on, so the two cannot
    // disagree about which equations the construct covers.
    if (successors.has(name) && isRecurrenceCandidate(model, name, esmFile)) {
      successors.delete(name)
    }

    graph.set(name, [...successors].sort())
  }

  return graph
}

/**
 * Reject a dependency cycle among a component's observed unknowns (esm-spec
 * §4.9.6; issue #181).
 *
 * ONE cycle is reported per component — the first the sorted DFS closes — for
 * the same reason {@link validateCircularReferences} reports one per document:
 * a second cycle is usually the same defect seen from another entry point, and
 * an author breaks them one at a time regardless.
 *
 * The finding is pinned at the COMPONENT, `/models/<M>` (or the subsystem's own
 * path), because a cycle is carried by no single equation — the same pointer
 * convention `equation_count_mismatch` follows. The `(code, path)` pair is what
 * the shared corpus pins; the prose is not, but naming the observeds on the
 * cycle IS required of every binding, so the message joins them with `" -> "`
 * and `details.cycle` carries the closed path in traversal order.
 */
export function validateObservedCycles(
  model: Model,
  componentPath: string,
  esmFile?: EsmFile,
): StructuralError[] {
  const graph = observedDependencyGraph(model, esmFile)
  if (graph.size === 0) return []

  // Tri-state DFS: unseen -> on the current chain -> finished. Membership of
  // the CHAIN, not of `visited`, is what closes a cycle; a node already
  // finished on an earlier root is a shared tail, not a cycle.
  //
  // ITERATIVE, not recursive. The depth of this walk is the length of the
  // longest observed CHAIN, which is a property of the document rather than of
  // its expression nesting; a recursive version overflowed the JS call stack on
  // an ACYCLIC chain of a few thousand observeds, and the overflow surfaced as
  // a single `load_error: Maximum call stack size exceeded` at the document
  // root that took every other structural finding with it. Each frame holds the
  // node's own successor cursor, so resuming a parent after a child finishes
  // picks up exactly where it left off.
  const ON_CHAIN = 1
  const FINISHED = 2
  const state = new Map<string, number>()

  function firstCycleFrom(root: string): string[] | undefined {
    if (state.get(root) !== undefined) return undefined
    const chain: string[] = [root]
    const cursor: number[] = [0]
    state.set(root, ON_CHAIN)
    while (chain.length > 0) {
      const name = chain[chain.length - 1]
      const successors = graph.get(name) ?? []
      const i = cursor[cursor.length - 1]++
      if (i >= successors.length) {
        state.set(name, FINISHED)
        chain.pop()
        cursor.pop()
        continue
      }
      const successor = successors[i]
      const seen = state.get(successor)
      if (seen === ON_CHAIN) {
        // Close the cycle at its ENTRY node: the suffix of the chain from where
        // this name first appeared, with the name repeated to close it
        // (`["gamfac", "hpbl", "wscale", "gamfac"]`). This is a path, so it is
        // ordered semantically rather than by the §7.1.0 lexicographic rule.
        const start = chain.indexOf(successor)
        return [...chain.slice(start === -1 ? 0 : start), successor]
      }
      if (seen === FINISHED) continue
      state.set(successor, ON_CHAIN)
      chain.push(successor)
      cursor.push(0)
    }
    return undefined
  }

  for (const root of [...graph.keys()].sort()) {
    const cycle = firstCycleFrom(root)
    if (cycle === undefined) continue
    return [
      {
        path: componentPath,
        code: ERROR_CODES.OBSERVED_CYCLE,
        message:
          `Observed dependency cycle: ${cycle.join(' -> ')}. Each of these observed ` +
          'variables is defined in terms of the next, so no evaluation order satisfies every ' +
          'definition (esm-spec §4.9.6). Break the cycle by splitting one observed into a ' +
          'pre-value and a post-value.',
        details: { cycle, dependency_type: 'observed_definitions' },
      },
    ]
  }

  return []
}
