/**
 * The record-shape half of `records_per_sample_invalid` (esm-spec §8.5.1 rule
 * 3), shared by structural validation and `flatten`.
 *
 * A parameter whose effective `records_per_sample` is 2 needs a record shape
 * whose first entry is an index set of exactly two members. The record shape is
 * the parameter's own `shape` whenever it declares one (`[]` included), or else,
 * when `shape` is absent, the declared `shape` of every
 * `param_to_var` target it is the `from` of. Validation sees only the inline
 * `coupling` and the document as loaded (this binding's `load*` does not mount
 * `{ref}` components); `flatten` sees the `coupling_import`-expanded sequence.
 * Both judge a site with {@link recordShapeFailure}.
 */

import type { EsmFile, Model, ModelVariable, ParameterUpdate } from './types.js'
import { effectiveRecordsPerSample } from './types.js'

/**
 * One `update` rule of a parameter: its name, scoped name (`Model[.Sub…].var`),
 * declaration, the rule itself, and the rule's JSON pointer. The object form of
 * `update` points at `update`, the array form at `update/<i>`.
 */
export interface ParameterUpdateSite {
  variableName: string
  scopedName: string
  variable: ModelVariable
  rule: ParameterUpdate
  path: string
}

/**
 * Every `update` rule in the document, in top-level models and in their inline
 * subsystems at any depth. A `{ref}` component not yet mounted is skipped.
 */
export function* forEachParameterUpdate(esmFile: EsmFile): Generator<ParameterUpdateSite> {
  function* walkModel(
    model: Model,
    modelPath: string,
    scope: string,
  ): Generator<ParameterUpdateSite> {
    for (const [variableName, variable] of Object.entries(model.variables ?? {})) {
      if (variable?.update === undefined) continue
      const base = `${modelPath}/variables/${variableName}/update`
      const scopedName = `${scope}.${variableName}`
      if (Array.isArray(variable.update)) {
        for (const [i, rule] of variable.update.entries()) {
          yield { variableName, scopedName, variable, rule, path: `${base}/${i}` }
        }
      } else {
        yield { variableName, scopedName, variable, rule: variable.update, path: base }
      }
    }
    for (const [childName, child] of Object.entries(model.subsystems ?? {})) {
      if (child === null || typeof child !== 'object' || 'ref' in child) continue
      yield* walkModel(
        child as Model,
        `${modelPath}/subsystems/${childName}`,
        `${scope}.${childName}`,
      )
    }
  }

  for (const [modelName, model] of Object.entries(esmFile.models ?? {})) {
    if (model === null || typeof model !== 'object' || 'ref' in model) continue
    yield* walkModel(model as Model, `/models/${modelName}`, modelName)
  }
}

/** Every `param_to_var` target of each `from`, in coupling order. */
export function paramToVarTargets(entries: readonly unknown[]): Map<string, string[]> {
  const targets = new Map<string, string[]>()
  for (const raw of entries) {
    const entry = raw as Record<string, unknown> | null
    if (
      entry?.type !== 'variable_map' ||
      entry.transform !== 'param_to_var' ||
      typeof entry.from !== 'string' ||
      typeof entry.to !== 'string'
    ) {
      continue
    }
    const list = targets.get(entry.from)
    if (list === undefined) targets.set(entry.from, [entry.to])
    else list.push(entry.to)
  }
  return targets
}

/** Is index set `name` an `interval` of size 2 or a `categorical` of two members? */
function indexSetHasTwoMembers(esmFile: EsmFile, name: string): boolean {
  const set = (esmFile.index_sets ?? {})[name] as
    { kind?: string; size?: unknown; members?: unknown[] } | undefined
  if (set === undefined) return false
  if (set.kind === 'interval') return set.size === 2
  if (set.kind === 'categorical') return Array.isArray(set.members) && set.members.length === 2
  return false
}

/**
 * The declared `shape` of the variable a scoped name names (`[]` when it
 * declares none), or `undefined` when the declaration cannot be reached: a
 * missing model, subsystem or variable, or one behind an unmounted `{ref}`.
 */
function declaredShape(esmFile: EsmFile, scoped: string): string[] | undefined {
  const parts = scoped.split('.')
  if (parts.length < 2) return undefined
  const [head, ...tail] = parts
  const model = esmFile.models?.[head]
  if (model === null || typeof model !== 'object' || 'ref' in model) return undefined
  let current: Model = model as Model
  for (const segment of tail.slice(0, -1)) {
    const sub = current.subsystems?.[segment]
    if (sub === null || typeof sub !== 'object' || 'ref' in sub || 'kind' in sub) return undefined
    current = sub as Model
  }
  const variable = current.variables?.[tail[tail.length - 1]]
  if (variable === null || typeof variable !== 'object') return undefined
  return variable.shape ?? []
}

/**
 * Does the document still hold a `{ref}` mount, as a top-level model or as a
 * subsystem at any depth of a model or reaction system? Mounting one merges
 * its `index_sets` into the document's (esm-spec §4.7).
 */
export function hasUnmountedRefs(esmFile: EsmFile): boolean {
  const walk = (component: unknown): boolean => {
    if (component === null || typeof component !== 'object') return false
    if ('ref' in component) return true
    const subsystems = (component as { subsystems?: Record<string, unknown> }).subsystems
    return Object.values(subsystems ?? {}).some(walk)
  }
  return (
    Object.values(esmFile.models ?? {}).some(walk) ||
    Object.values(esmFile.reaction_systems ?? {}).some(walk)
  )
}

/**
 * Does `shape` start with an index set of exactly two members? `undefined`
 * when that cannot be decided yet: the first entry names an index set the
 * document does not declare while `{ref}` mounts that may declare it remain.
 */
function hasPairAxis(
  esmFile: EsmFile,
  shape: readonly string[],
  unmountedRefs: boolean,
): boolean | undefined {
  if (shape.length === 0) return false
  if (unmountedRefs && (esmFile.index_sets ?? {})[shape[0]] === undefined) return undefined
  return indexSetHasTwoMembers(esmFile, shape[0])
}

/** A record shape that fails rule 3, and the `param_to_var` target it came from. */
export interface RecordShapeFailure {
  shape: string[]
  target?: string
}

/**
 * Judge one `update` rule's record shape (esm-spec §8.5.1 rule 3). Returns the
 * first failing record shape, or `undefined` when there is none to report: the
 * rule is not a `data` rule with an effective 2 from a source with a `temporal`
 * block (rules 1 and 2 are the validator's), every record shape it can see
 * passes, or what remains cannot be decided here.
 *
 * A target whose declaration cannot be reached is not decidable and is
 * skipped, and so is a record shape whose first index set is undeclared while
 * `unmountedRefs` (a mount may still declare it). A declared `shape: []` is
 * always a failure; no `shape` and no target at all is a failure unless
 * `targetsMayArriveLater`, which validation sets when the document has a
 * `coupling_import` entry that `flatten` will expand.
 */
export function recordShapeFailure(
  esmFile: EsmFile,
  site: ParameterUpdateSite,
  targets: ReadonlyMap<string, readonly string[]>,
  options: { targetsMayArriveLater: boolean; unmountedRefs: boolean },
): RecordShapeFailure | undefined {
  const { rule, variable, scopedName } = site
  if (rule.kind !== 'data') return undefined
  const binding = (rule as { from?: { records_per_sample?: number } }).from
  if (binding === undefined) return undefined
  const sources = (esmFile.data_sources ?? {}) as Record<
    string,
    { temporal?: { records_per_sample?: number } }
  >
  const source = sources[(rule as { source: string }).source]
  if (source?.temporal === undefined) return undefined
  if (effectiveRecordsPerSample(binding, source) !== 2) return undefined

  // The declared `shape` is the record shape whenever one is declared, `[]`
  // (a scalar buffer) included; only an ABSENT `shape` takes its targets'.
  const own = variable.shape
  if (own !== undefined && own !== null) {
    return hasPairAxis(esmFile, own, options.unmountedRefs) === false
      ? { shape: [...own] }
      : undefined
  }

  const mapped = targets.get(scopedName) ?? []
  if (mapped.length === 0) return options.targetsMayArriveLater ? undefined : { shape: [] }
  for (const target of mapped) {
    const shape = declaredShape(esmFile, target)
    if (shape === undefined) continue
    if (hasPairAxis(esmFile, shape, options.unmountedRefs) === false) return { shape, target }
  }
  return undefined
}

/** The rule-3 diagnostic message for `failure` on parameter `variableName`. */
export function recordShapeMessage(variableName: string, failure: RecordShapeFailure): string {
  const from = failure.target === undefined ? '' : ` (from param_to_var target '${failure.target}')`
  return `Parameter '${variableName}' asks for two records per sample, so its first dimension must be an index set of exactly two members; its record shape${from} is ${JSON.stringify(failure.shape)}`
}
