/**
 * esm-spec §6.6.3 / §6.6.4 — the inline-test assertion pass predicate and the
 * tolerance-resolution order it consumes.
 *
 * This binding does not simulate, so nothing here computes an `actual`. What it
 * does own is the COMPARISON: `units-fixture.test.ts` evaluates observed
 * expressions under a test's bindings and checks them against the fixture's
 * expected values, and that comparison has to be the same one Julia, Python and
 * Rust make or a shared fixture means two different things depending on who
 * reads it. It lives in `src/` rather than in the test file because a predicate
 * defined inside its only caller is a predicate nothing can hold to a contract —
 * which is exactly how ~12 hand-rolled copies across three bindings drifted from
 * the spec (#223). It is deliberately NOT re-exported from `index.ts`: it is
 * this binding's internal definition of the rule, not public API.
 */

/** A `{abs?, rel?}` tolerance at any of the three §6.6.4 levels. */
export interface AssertionTolerance {
  abs?: number
  rel?: number
}

/**
 * The §6.6.4 implementation default: `rel = 1e-6`, no `abs` bound. Matches the
 * Julia reference runner and the Python / Rust ports.
 */
export const DEFAULT_REL_TOL = 1e-6

/**
 * esm-spec §6.6.4 precedence: assertion > test > model > implementation default.
 * The FIRST level that is present wins outright, and a bound it does not spell
 * is `0` — which is what all three executing bindings do.
 */
export function resolveTolerance(
  modelTol: AssertionTolerance | undefined | null,
  testTol: AssertionTolerance | undefined | null,
  assertionTol: AssertionTolerance | undefined | null,
): { rel: number; abs: number } {
  for (const cand of [assertionTol, testTol, modelTol]) {
    if (cand === undefined || cand === null) continue
    return { rel: cand.rel ?? 0, abs: cand.abs ?? 0 }
  }
  return { rel: DEFAULT_REL_TOL, abs: 0 }
}

/**
 * esm-spec §6.6.3's pass predicate — Julia `isapprox` semantics:
 *
 * ```
 * actual === expected
 *   || (both FINITE and |actual − expected| ≤ max(abs, rel · max(|actual|, |expected|)))
 * ```
 *
 * Three clauses carry weight, and each of them has been dropped by some
 * re-implementation of this rule:
 *
 * 1. **The relative bound scales by `max(|actual|, |expected|)`**, not by
 *    `|expected|` alone, and it is a `max` with `abs`, not a sum with it.
 *    `abs + rel·|expected|` is numpy `isclose`, which is strictly more
 *    permissive. The readings agree everywhere except on an overshoot
 *    (`|actual| > |expected|`), so the divergence is invisible to any corpus
 *    of passing assertions.
 * 2. **No epsilon floor** on that scale. The bound is a product, so a zero
 *    `expected` needs no protection, and a floor diverges on subnormals
 *    (`a=1e-320, e=0, rel=0.5` passes with an `ε=1e-300` floor and fails
 *    without). The consequence is intended: a nonzero actual against a zero
 *    expected needs `abs`, or `rel ≥ 1`.
 * 3. **Finiteness is judged BEFORE tolerance**, and that clause contradicts the
 *    bound rather than following from it: with `actual = ±Infinity` both sides
 *    of the bound are `Infinity`, so it holds for EVERY expected value and an
 *    overflowed product reports PASS whatever it expected. `NaN` fails on its
 *    own (every IEEE-754 comparison with NaN is false), so only the infinite
 *    case needs the guard. The equality clause keeps the one case a non-finite
 *    value legitimately matches — the same infinity with the same sign — and,
 *    because `-0 === 0` under IEEE-754, leaves signed zeros unaffected.
 *
 * `rel === 0 && abs === 0` is EXACT-EQUALITY mode, not "no bound": the §6.6.4
 * default applies when tolerance is ABSENT, not when a document spells both
 * bounds as zero.
 *
 * Pinned across the bindings by the shared `assertion_tolerance` conformance
 * category (CONFORMANCE_SPEC §5.32).
 */
export function checkAssertion(
  actual: number,
  expected: number,
  rel: number,
  abs: number,
): boolean {
  if (actual === expected) return true
  if (!Number.isFinite(actual) || !Number.isFinite(expected)) return false
  // Exact-equality mode; the equality above already answered it.
  if (rel === 0 && abs === 0) return false
  return (
    Math.abs(actual - expected) <=
    Math.max(abs, rel * Math.max(Math.abs(actual), Math.abs(expected)))
  )
}
