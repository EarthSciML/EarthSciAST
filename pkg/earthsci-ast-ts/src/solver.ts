/**
 * Document-scoped solver hints (esm-spec §2.2).
 *
 * The `solver` block records numerics the document knows about *itself* —
 * stiffness, integration tolerances, and a splitting hint — which each binding
 * maps to its own integrator.
 *
 * Every field is ADVISORY: a binding may ignore any or all of them and still
 * conform. Advisory governs the MECHANISM, never the OUTCOME — the
 * CONFORMANCE_SPEC §5.9 requirement to integrate successfully and agree within
 * the error band is untouched by this block and is not excused by it.
 *
 * This module carries the parts that are NOT advisory: the spec-version gate
 * (§2.2.4) and the §2.2.2 tolerance resolution order. TypeScript ships no
 * integrator, so `resolveTolerances` exists for parity and for callers driving
 * another runtime.
 */

import { ERROR_CODES } from './errors.js'
import { EsmMachineryError } from './lower-expression-templates.js'
import type { Solver } from './generated.js'

/** Binding defaults (API_SPEC §5.8) — the bottom of the §2.2.2 chain. */
export const DEFAULT_RELTOL = 1e-4
export const DEFAULT_ABSTOL = 1e-6

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

/**
 * Reject a top-level `solver` block in a file declaring esm < 1.1.0.
 *
 * The block arrives at `esm: 1.1.0`; a document declaring an earlier version
 * that carries one is rejected with `solver_version_too_old` (esm-spec
 * §2.2.4). Mirrors `rejectTemplateImportsPreV08`.
 */
export function rejectSolverPreV11(view: unknown): void {
  if (!isObject(view)) return
  if (!('solver' in view)) return
  const esm = view.esm
  if (typeof esm !== 'string') return
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(esm)
  if (!m) return
  const major = Number(m[1])
  const minor = Number(m[2])
  if (major > 1 || (major === 1 && minor >= 1)) return
  throw new EsmMachineryError(
    ERROR_CODES.SOLVER_VERSION_TOO_OLD,
    `the top-level \`solver\` block requires esm >= 1.1.0; file declares ${esm}. Offending path: /solver`,
  )
}

/**
 * Resolve integration tolerances most-specific first (esm-spec §2.2.2):
 *
 * 1. An explicit argument at the call site — wins outright.
 * 2. Otherwise the document's `solver.abstol` / `solver.reltol`.
 * 3. Otherwise the binding default (`reltol` 1e-4, `abstol` 1e-6).
 *
 * The two resolve INDEPENDENTLY, so a document declaring only `reltol` leaves
 * `abstol` on the default — the same per-field fall-through §6.6.4 uses.
 *
 * These are INTEGRATION tolerances, a different quantity from the `tolerance`
 * object an assertion is COMPARED at (§6.6.4).
 */
export function resolveTolerances(
  solver: Solver | undefined | null,
  opts: { abstol?: number; reltol?: number } = {},
): { abstol: number; reltol: number } {
  return {
    abstol: opts.abstol ?? solver?.abstol ?? DEFAULT_ABSTOL,
    reltol: opts.reltol ?? solver?.reltol ?? DEFAULT_RELTOL,
  }
}

/**
 * Map a `solver` block with nothing set to absence (esm-spec §2.2), in place on
 * the raw document view.
 *
 * `"solver": {}` is legal — every other optional top-level container admits an
 * empty object, and making this one the exception would be a rule with no
 * payoff — but it means exactly what omitting the block means, so it is
 * normalized away AT LOAD. `toJson` serializes the whole document object, so
 * without this an empty block would survive `parse → emit` here while Python
 * and Julia dropped it: the five bindings disagreeing on one document.
 */
export function normalizeEmptySolver(view: unknown): void {
  if (!isObject(view)) return
  const solver = view.solver
  if (!isObject(solver)) return
  if (Object.keys(solver).length === 0) delete view.solver
}
