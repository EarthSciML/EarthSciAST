/**
 * The load-time half of variable bounds (esm-spec §6.3.2): the esm 2.1.0
 * version gate, and the floor a resolved document is raised to when a mounted
 * leaf brought bounds into it. The structural rules live in
 * `validate/bounds-checks.ts`.
 *
 * Both functions read the raw JSON, so they run before schema validation and
 * see a `{ ref }` subsystem as the stub it is: a referenced file is held to its
 * own declared version when it is loaded (esm-spec §4.7).
 */

import { ERROR_CODES } from './errors.js'
import { EsmMachineryError } from './lower-expression-templates.js'

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

/** Whether the document declares an `esm` version below 2.1.0. */
function declaredBelowV21(view: Record<string, unknown>): boolean {
  const esm = view.esm
  if (typeof esm !== 'string') return false
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(esm)
  if (!m) return false
  const major = Number(m[1])
  const minor = Number(m[2])
  return major < 2 || (major === 2 && minor < 1)
}

/**
 * The JSON pointer of the first `lb` / `ub` on a variable of `model` or of one
 * of its inline subsystems, at any depth, in document order (a variable's
 * `lb` before its `ub`, a model's own variables before its subsystems'), or
 * `null` when there is none.
 */
function firstBoundIn(model: unknown, at: string): string | null {
  if (!isObject(model)) return null
  if (isObject(model.variables)) {
    for (const [name, variable] of Object.entries(model.variables)) {
      if (!isObject(variable)) continue
      for (const side of ['lb', 'ub']) {
        if (side in variable) return `${at}/variables/${name}/${side}`
      }
    }
  }
  if (isObject(model.subsystems)) {
    for (const [name, sub] of Object.entries(model.subsystems)) {
      const hit = firstBoundIn(sub, `${at}/subsystems/${name}`)
      if (hit !== null) return hit
    }
  }
  return null
}

function firstBound(view: Record<string, unknown>): string | null {
  if (!isObject(view.models)) return null
  for (const [name, model] of Object.entries(view.models)) {
    const hit = firstBoundIn(model, `/models/${name}`)
    if (hit !== null) return hit
  }
  return null
}

/**
 * Reject `lb` / `ub` on any model variable in a file declaring esm < 2.1.0
 * with `variable_bounds_version_too_old`, naming the first such field. Runs on
 * the raw JSON before schema validation, so the author sees the version rather
 * than an unknown-property error.
 */
export function rejectVariableBoundsPreV21(view: unknown): void {
  if (!isObject(view) || !declaredBelowV21(view)) return
  const path = firstBound(view)
  if (path === null) return
  throw new EsmMachineryError(
    ERROR_CODES.VARIABLE_BOUNDS_VERSION_TOO_OLD,
    `variable bounds (\`lb\` / \`ub\`) require esm >= 2.1.0; file declares ${String(view.esm)}. Offending path: ${path}`,
  )
}

/**
 * Raise a RESOLVED document's declared `esm` to 2.1.0 when it carries a bound
 * but declares less. FLOOR only.
 *
 * The gate reads the file that holds the bound (esm-spec §4.7), so a 2.0.0
 * parent may mount a 2.1.0 leaf that declares one. Once the leaf is inlined the
 * resolved document carries the bound under the parent's version, and
 * `validate()` re-enters the loader with exactly that object; without the floor
 * the gate would refuse a document nobody mis-authored.
 */
export function raiseVariableBoundsVersionFloor(doc: unknown): void {
  if (needsVariableBoundsVersionFloor(doc)) (doc as Record<string, unknown>).esm = '2.1.0'
}

/**
 * Whether `doc` carries a variable bound under a declared `esm` below 2.1.0, so
 * an emitter must raise the version to 2.1.0 for the document to read back.
 * Reads the declared version before walking the models.
 */
export function needsVariableBoundsVersionFloor(doc: unknown): boolean {
  return isObject(doc) && declaredBelowV21(doc) && firstBound(doc) !== null
}
