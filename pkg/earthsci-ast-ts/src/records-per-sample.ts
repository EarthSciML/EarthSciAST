/**
 * Record axes (esm-spec §8.5.1), shared by structural validation and `flatten`.
 *
 * A data-fed parameter receives two records per query time when its record
 * shape begins with a RECORD AXIS (an `interval` index set carrying
 * `"records": true`), and one otherwise. The record shape is the parameter's
 * own `shape` whenever it declares one (`[]` included), or else, when `shape`
 * is absent, the declared `shape` of every `param_to_var` target it is the
 * `from` of (none: an empty record shape).
 *
 * Validation sees only the inline `coupling` and the document as loaded (this
 * binding's `load*` does not mount `{ref}` components); `flatten` sees the
 * `coupling_import`-expanded sequence. Both judge a site with
 * {@link recordShapeFindings}, and `flatten` reads each `LoaderField`'s count
 * from {@link recordCount}.
 *
 * The deprecated `from.records_per_sample` / `temporal.records_per_sample` is
 * checked against the shape, never obeyed; {@link deprecatedRecordsPerSampleSites}
 * lists where it is written, for the load-time warning.
 */

import { ERROR_CODES } from './errors.js'
import type { EsmFile, Model, ModelVariable, ParameterUpdate } from './types.js'

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
 * Is index set `name` a record axis (an `interval` carrying `"records": true`)?
 * `undefined` when that cannot be decided yet: the document does not declare
 * it while `{ref}` mounts that may declare it remain.
 */
function isRecordAxis(esmFile: EsmFile, name: string, unmountedRefs: boolean): boolean | undefined {
  const set = (esmFile.index_sets ?? {})[name] as { kind?: string; records?: unknown } | undefined
  if (set === undefined) return unmountedRefs ? undefined : false
  return set.kind === 'interval' && set.records === true
}

type SourceMap = Record<
  string,
  { temporal?: { start?: string; records_per_sample?: number } } | undefined
>

/** The deprecated value a `data` rule is written with: its own, else its source's. */
function writtenRecordsPerSample(
  rule: ParameterUpdate,
  source: NonNullable<SourceMap[string]>,
): number | undefined {
  const own = (rule as { from?: { records_per_sample?: number } }).from?.records_per_sample
  return own ?? source.temporal?.records_per_sample
}

/**
 * The record shapes of a data-fed parameter, as far as they can be seen:
 * `shapes` holds the reachable ones (with the `param_to_var` target each came
 * from); a target whose declaration cannot be reached is left out, never read
 * as empty. `emptyByAbsence` marks the empty record shape of a shapeless
 * parameter that is the `from` of no target.
 */
interface RecordShapes {
  shapes: Array<{ shape: string[]; target?: string }>
  emptyByAbsence: boolean
}

function recordShapes(
  esmFile: EsmFile,
  site: ParameterUpdateSite,
  targets: ReadonlyMap<string, readonly string[]>,
): RecordShapes {
  const own = site.variable.shape
  if (own !== undefined && own !== null) {
    return { shapes: [{ shape: [...own] }], emptyByAbsence: false }
  }
  const mapped = targets.get(site.scopedName) ?? []
  if (mapped.length === 0) return { shapes: [{ shape: [] }], emptyByAbsence: true }
  const shapes: RecordShapes['shapes'] = []
  for (const target of mapped) {
    const shape = declaredShape(esmFile, target)
    if (shape !== undefined) shapes.push({ shape, target })
  }
  return { shapes, emptyByAbsence: false }
}

/** The source of a data-fed rule (a `data` rule with `from` naming a declared source). */
function dataFedSource(
  esmFile: EsmFile,
  site: ParameterUpdateSite,
): { name: string; source: NonNullable<SourceMap[string]> } | undefined {
  const { rule } = site
  if (rule.kind !== 'data') return undefined
  if ((rule as { from?: unknown }).from === undefined) return undefined
  const name = (rule as { source: string }).source
  const source = ((esmFile.data_sources ?? {}) as SourceMap)[name]
  return source === undefined || source === null ? undefined : { name, source }
}

/**
 * The number of records the first decidable record shape gives (1 or 2), or
 * `undefined` when none can be decided. Record shapes that disagree are
 * refused by {@link recordShapeFindings}; this reads the first.
 */
function countOf(
  esmFile: EsmFile,
  shapes: RecordShapes,
  unmountedRefs: boolean,
): { count: 1 | 2; shape: string[]; target?: string } | undefined {
  for (const { shape, target } of shapes.shapes) {
    if (shape.length === 0) return { count: 1, shape, target }
    const first = isRecordAxis(esmFile, shape[0], unmountedRefs)
    if (first === undefined) continue
    return { count: first ? 2 : 1, shape, target }
  }
  return undefined
}

/**
 * The number of records data-fed parameter `site` receives, for its
 * `LoaderField` (esm-libraries-spec "Loader fields"): 2 when its record shape,
 * judged against the `param_to_var` edges in `targets`, begins with a record
 * axis, else 1.
 */
export function recordCount(
  esmFile: EsmFile,
  site: ParameterUpdateSite,
  targets: ReadonlyMap<string, readonly string[]>,
): 1 | 2 {
  const unmountedRefs = hasUnmountedRefs(esmFile)
  return countOf(esmFile, recordShapes(esmFile, site, targets), unmountedRefs)?.count ?? 1
}

/** A finding on one `update` rule: its code, message and details. */
export interface RecordShapeFinding {
  code: string
  message: string
  details: Record<string, unknown>
}

/**
 * Judge one `update` rule against esm-spec §8.5.1: rule 2
 * (`record_axis_misplaced`), then, for a record shape beginning with a record
 * axis, rule 3 (`record_axis_time_invariant_source`), then the deprecated
 * written value's agreement with the shape (`records_per_sample_invalid`).
 * Returns at most one finding.
 *
 * A non-data rule, or one whose source is undeclared, is not judged here (the
 * validator reports those). A `param_to_var` target whose declaration cannot
 * be reached is skipped, and so is a record shape whose first entry names an
 * index set undeclared while `unmountedRefs`. An empty record shape by
 * absence of any target is deferred while `targetsMayArriveLater` (validation
 * sets it when the document has a `coupling_import` entry `flatten` expands).
 */
export function recordShapeFindings(
  esmFile: EsmFile,
  site: ParameterUpdateSite,
  targets: ReadonlyMap<string, readonly string[]>,
  options: { targetsMayArriveLater: boolean; unmountedRefs: boolean },
): RecordShapeFinding[] {
  const fed = dataFedSource(esmFile, site)
  if (fed === undefined) return []
  const { variableName } = site
  const shapes = recordShapes(esmFile, site, targets)
  if (shapes.emptyByAbsence && options.targetsMayArriveLater) return []
  const from = (target?: string): string =>
    target === undefined ? '' : ` (from param_to_var target '${target}')`
  const targetDetail = (target?: string): Record<string, string> =>
    target === undefined ? {} : { target }

  // Rule 2: a record axis anywhere but first, or record shapes that disagree
  // about beginning with one.
  const firsts: Array<{ first: boolean; shape: string[]; target?: string }> = []
  for (const { shape, target } of shapes.shapes) {
    for (const [i, name] of shape.entries()) {
      if (i === 0 || isRecordAxis(esmFile, name, options.unmountedRefs) !== true) continue
      return [
        {
          code: ERROR_CODES.RECORD_AXIS_MISPLACED,
          message:
            `Parameter '${variableName}' is data-fed, and its record shape${from(target)} ` +
            `${JSON.stringify(shape)} names record axis '${name}' at position ${i + 1}; a record ` +
            `axis must be the first entry of a record shape (esm-spec §8.5.1)`,
          details: { variable: variableName, shape, axis: name, ...targetDetail(target) },
        },
      ]
    }
    const first =
      shape.length === 0 ? false : isRecordAxis(esmFile, shape[0], options.unmountedRefs)
    if (first !== undefined) firsts.push({ first, shape, target })
  }
  const withAxis = firsts.find((f) => f.first)
  const withoutAxis = firsts.find((f) => !f.first)
  if (withAxis !== undefined && withoutAxis !== undefined) {
    return [
      {
        code: ERROR_CODES.RECORD_AXIS_MISPLACED,
        message:
          `Parameter '${variableName}' is data-fed, and its record shapes disagree: ` +
          `${JSON.stringify(withAxis.shape)}${from(withAxis.target)} begins with a record axis ` +
          `while ${JSON.stringify(withoutAxis.shape)}${from(withoutAxis.target)} does not ` +
          `(esm-spec §8.5.1)`,
        details: {
          variable: variableName,
          shapes: firsts.map((f) => ({ shape: f.shape, ...targetDetail(f.target) })),
        },
      },
    ]
  }

  const decided = countOf(esmFile, shapes, options.unmountedRefs)
  if (decided === undefined) return []
  // A misplaced axis stops here; the two checks below are independent, so a
  // rule may carry both.
  const findings: RecordShapeFinding[] = []

  // Rule 3: a pair needs a successor record, so a time-varying source.
  if (decided.count === 2 && !fed.source.temporal?.start) {
    findings.push({
      code: ERROR_CODES.RECORD_AXIS_TIME_INVARIANT_SOURCE,
      message:
        `Parameter '${variableName}' receives two records (its record shape` +
        `${from(decided.target)} ${JSON.stringify(decided.shape)} begins with a record axis) ` +
        `from data source '${fed.name}', which is time-invariant (it declares no temporal ` +
        `start) and so has no successor record (esm-spec §8.5.1)`,
      details: { variable: variableName, source: fed.name, shape: decided.shape },
    })
  }

  // The deprecated written value must agree with the shape.
  const written = writtenRecordsPerSample(site.rule, fed.source)
  if (written !== undefined && written !== decided.count) {
    findings.push({
      code: ERROR_CODES.RECORDS_PER_SAMPLE_INVALID,
      message:
        `Parameter '${variableName}' is written with records_per_sample ${written}, but its ` +
        `record shape${from(decided.target)} ${JSON.stringify(decided.shape)} gives it ` +
        `${decided.count === 1 ? 'one record' : 'two records'}: two exactly when its first ` +
        `entry is an interval index set with "records": true (esm-spec §8.5.1)`,
      details: {
        variable: variableName,
        records_per_sample: written,
        records: decided.count,
        shape: decided.shape,
        ...targetDetail(decided.target),
      },
    })
  }
  return findings
}

/**
 * The sorted JSON pointers at which the deprecated `records_per_sample` is
 * written in `esmFile` (esm-spec §8.3, §8.5.1):
 * `/data_sources/<S>/temporal/records_per_sample` and
 * `/models/<M>[/subsystems/<S>…]/variables/<v>/update[/<i>]/from/records_per_sample`.
 * Components behind an unmounted `{ref}` are not visited.
 */
export function deprecatedRecordsPerSampleSites(esmFile: EsmFile): string[] {
  const sites: string[] = []
  const sources = (esmFile.data_sources ?? {}) as SourceMap
  for (const [name, source] of Object.entries(sources)) {
    if (source?.temporal?.records_per_sample !== undefined) {
      sites.push(`/data_sources/${name}/temporal/records_per_sample`)
    }
  }
  for (const { rule, path } of forEachParameterUpdate(esmFile)) {
    const from = (rule as { from?: { records_per_sample?: number } }).from
    if (from?.records_per_sample !== undefined) sites.push(`${path}/from/records_per_sample`)
  }
  return sites.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))
}

/** The load-time `deprecated_records_per_sample` warning naming `sites`. */
export function deprecatedRecordsPerSampleWarning(sites: readonly string[]): string {
  return (
    'deprecated_records_per_sample: `records_per_sample` is deprecated and is removed at ' +
    'esm 1.4.0; the number of records a data-fed parameter receives is said by its record ' +
    'shape, two when its first axis is an interval index set with "records": true ' +
    `(esm-spec §8.5.1). Written at: ${sites.join(', ')}.`
  )
}
