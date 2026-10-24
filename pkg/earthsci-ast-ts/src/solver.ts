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
 * This module carries the parts that are NOT advisory: the spec-version gates
 * (§2.2.4), the §2.2.2 tolerance resolution order, and the §2.2.6 resolution of
 * `solver.external`. TypeScript ships no
 * integrator, so `resolveTolerances` exists for parity and for callers driving
 * another runtime.
 */

import { ERROR_CODES } from './errors.js'
import { EsmMachineryError } from './lower-expression-templates.js'
import type { Solver } from './generated.js'
import type { EsmFile } from './types.js'
import { absoluteBase, removeDotSegments, SCHEME_RE } from './data-source-urls.js'

/**
 * Binding default relative tolerance (API_SPEC §5.8) — the bottom of the
 * §2.2.2 chain, used when neither the caller nor `solver.reltol` sets one.
 */
export const DEFAULT_RELTOL = 1e-4
/**
 * Binding default absolute tolerance (API_SPEC §5.8) — the bottom of the
 * §2.2.2 chain, used when neither the caller nor `solver.abstol` sets one.
 */
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
 * Reject `solver.external` in a file declaring esm < 1.3.0.
 *
 * `external` arrives at `esm: 1.3.0`; a 1.1.0 or 1.2.0 document whose `solver`
 * block carries it is rejected with `solver_external_version_too_old` at
 * `/solver/external` (esm-spec §2.2.4 requirement 4). The same block without
 * `external` stays valid. Below 1.1.0 the whole block is refused first, by
 * {@link rejectSolverPreV11}.
 */
export function rejectSolverExternalPreV13(view: unknown): void {
  if (!isObject(view)) return
  const solver = view.solver
  if (!isObject(solver) || !('external' in solver)) return
  const esm = view.esm
  if (typeof esm !== 'string') return
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(esm)
  if (!m) return
  const major = Number(m[1])
  const minor = Number(m[2])
  if (major > 1 || (major === 1 && minor >= 3)) return
  throw new EsmMachineryError(
    ERROR_CODES.SOLVER_EXTERNAL_VERSION_TOO_OLD,
    `\`solver.external\` requires esm >= 1.3.0; file declares ${esm}. Offending path: /solver/external`,
  )
}

function checkSolverExternal(external: string): void {
  if (!external.includes('${')) return
  throw new EsmMachineryError(
    ERROR_CODES.SOLVER_EXTERNAL_UNRESOLVED,
    `/solver/external '${external}' carries an unexpanded '\${...}' variable. ` +
      'esm-spec §2.2.6 does not expand environment variables into a run-configuration ' +
      'reference: a run configuration chosen by the environment is not reproducible. ' +
      'Write a path relative to this document, or pass the run configuration at the call site.',
  )
}

/**
 * Refuse a `solver.external` carrying `${` with `solver_external_unresolved`
 * (esm-spec §2.2.6). Runs at load on the raw JSON; a non-string `external` is
 * left to schema validation.
 */
export function rejectSolverExternalUnresolved(view: unknown): void {
  if (!isObject(view)) return
  const solver = view.solver
  if (!isObject(solver) || typeof solver.external !== 'string') return
  checkSolverExternal(solver.external)
}

/**
 * The location `solver.external` names, resolved by esm-spec §2.2.6, or `null`
 * when the root document's `solver` block carries none.
 *
 * A URL (`scheme://…`) is returned unchanged. An absolute path has its dot
 * segments removed and is prefixed `file://`. Anything else is joined onto the
 * base, dot segments removed, and prefixed `file://`. The base is `base` when
 * given — a relative one is taken against the working directory — and otherwise
 * the directory recorded at load: the directory of the file `loadPath` read,
 * the `basePath` load option, or the working directory of a `loadString` /
 * `loadDocument`. A document built in memory resolves against the working
 * directory.
 *
 * Purely lexical: it never touches the filesystem, and a location that does not
 * exist resolves normally. The authored string stays in the document and is
 * what `toJson` writes; the resolved location is never written back. A mounted
 * leaf's `solver` block does not cross the mount, so only the root's
 * `external` is consulted.
 *
 * @throws {EsmMachineryError} `solver_external_unresolved` when `external`
 *   carries `${` (only reachable for a document built in memory; load refuses it).
 */
export function solverExternalLocation(file: EsmFile, base?: string): string | null {
  const external = file.solver?.external
  if (typeof external !== 'string') return null
  checkSolverExternal(external)
  if (SCHEME_RE.test(external)) return external
  if (external.startsWith('/')) return 'file://' + removeDotSegments(external)
  const dir = base ?? file.documentBase ?? '.'
  return 'file://' + removeDotSegments(absoluteBase(dir).replace(/\/+$/, '') + '/' + external)
}

/**
 * Reject declared `units` on any expression node in a document declaring
 * `esm` < 1.2.0 (esm-spec §4.8.5 item 6), naming the first offending node.
 * Runs on the raw JSON before schema validation, like {@link rejectSolverPreV11}.
 */
export function rejectConstUnitsPreV12(view: unknown): void {
  if (!isObject(view)) return
  const esm = view.esm
  if (typeof esm !== 'string') return
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(esm)
  if (!m) return
  const major = Number(m[1])
  const minor = Number(m[2])
  if (major > 1 || (major === 1 && minor >= 2)) return
  const find = (node: unknown, at: string): string | null => {
    if (Array.isArray(node)) {
      for (let i = 0; i < node.length; i++) {
        const hit = find(node[i], `${at}/${i}`)
        if (hit !== null) return hit
      }
    } else if (isObject(node)) {
      if ('op' in node && 'units' in node) return at
      for (const key of Object.keys(node)) {
        const hit = find(node[key], `${at}/${key}`)
        if (hit !== null) return hit
      }
    }
    return null
  }
  const path = find(view, '')
  if (path === null) return
  throw new EsmMachineryError(
    ERROR_CODES.CONST_UNITS_VERSION_TOO_OLD,
    `declared \`units\` on an expression node require esm >= 1.2.0; file declares ${esm}. Offending path: ${path}`,
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
 * Map a `solver` block with nothing set to absence (esm-spec §2.2).
 *
 * `"solver": {}` is legal — every other optional top-level container admits an
 * empty object, and making this one the exception would be a rule with no
 * payoff — but it means exactly what omitting the block means, so it is
 * normalized away AT LOAD. `toJson` serializes the whole document object, so
 * without this an empty block would survive `parse → emit` here while Python
 * and Julia dropped it: the five bindings disagreeing on one document.
 *
 * Returns a SHALLOW COPY without the key, or `null` when there is nothing to
 * drop — the same shape as `resolveDataSourceUrls`, and for the same two
 * reasons. Deleting in place would (a) mutate the caller's own object, since a
 * non-canonical object input is passed through by reference, and (b) land on
 * the wrong tree in canonical mode, where the validation view is a separate
 * stripped copy from the document the `EsmFile` is built out of — so `{}` would
 * survive to emit on exactly the path this normalization exists to make
 * uniform.
 */
export function normalizeEmptySolver(view: unknown): Record<string, unknown> | null {
  if (!isObject(view)) return null
  const solver = view.solver
  if (!isObject(solver)) return null
  if (Object.keys(solver).length > 0) return null
  const { solver: _dropped, ...rest } = view
  return rest
}
