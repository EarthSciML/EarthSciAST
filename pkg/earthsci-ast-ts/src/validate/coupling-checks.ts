/**
 * File-level structural validators: unresolved subsystem refs, coupling-entry
 * reference integrity, circular cross-model references, data-loader variable
 * references in coupling, and data-loader temporal-resolution durations.
 */

import { ERROR_CODES } from '../errors.js'
import type {
  EsmFile,
  CouplingOperatorCompose,
  CouplingCouple,
  CouplingVariableMap,
  SubsystemRef,
} from '../types.js'
import type { StructuralError } from './types.js'
import { extractVariableReferences, splitScopedRef } from './expr-utils.js'

/**
 * Flag subsystem entries that are unresolved SubsystemRef objects.
 * The synchronous validate() function cannot resolve external file references;
 * call resolveSubsystemRefs() before validate() to inline them first.
 */
/**
 * Flag any `{ref}` (unresolved SubsystemRef) entries in one component's
 * `subsystems` map. Shared by the models and reaction-systems passes, which
 * differ only in the JSON path prefix.
 */
function flagRefSubsystems(
  subsystems: Record<string, unknown>,
  pathPrefix: string,
): StructuralError[] {
  const errors: StructuralError[] = []
  for (const [subsystemName, subsystem] of Object.entries(subsystems)) {
    if (subsystem && typeof subsystem === 'object' && 'ref' in subsystem) {
      const ref = (subsystem as SubsystemRef).ref
      if (typeof ref === 'string') {
        errors.push({
          path: `${pathPrefix}/${subsystemName}`,
          code: ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF,
          message: `Subsystem '${subsystemName}' is an unresolved file reference ('${ref}'). Call resolveSubsystemRefs() before validate().`,
          details: { ref },
        })
      }
    }
  }
  return errors
}

export function validateSubsystemRefs(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []
  if (esmFile.models) {
    for (const [modelName, model] of Object.entries(esmFile.models)) {
      if ('ref' in model || !model.subsystems) continue
      errors.push(...flagRefSubsystems(model.subsystems, `/models/${modelName}/subsystems`))
    }
  }
  if (esmFile.reaction_systems) {
    for (const [systemName, system] of Object.entries(esmFile.reaction_systems)) {
      if (!system.subsystems) continue
      errors.push(
        ...flagRefSubsystems(system.subsystems, `/reaction_systems/${systemName}/subsystems`),
      )
    }
  }
  return errors
}

/**
 * Check coupling entries reference integrity
 */
export function validateCouplingIntegrity(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []

  if (!esmFile.coupling) return errors

  // Collect all available systems
  const availableSystems = new Set([
    ...Object.keys(esmFile.models || {}),
    ...Object.keys(esmFile.reaction_systems || {}),
    ...Object.keys(esmFile.data_loaders || {}),
  ])

  for (let i = 0; i < esmFile.coupling.length; i++) {
    const coupling = esmFile.coupling[i]
    const couplingPath = `/coupling/${i}`

    if (coupling.type === 'operator_compose' || coupling.type === 'couple') {
      // operator_compose and couple both carry a `systems` list and their
      // existence checks were byte-identical, so the two branches are merged.
      const systemsEntry = coupling as CouplingOperatorCompose | CouplingCouple
      for (const systemName of systemsEntry.systems) {
        if (!availableSystems.has(systemName)) {
          errors.push({
            path: `${couplingPath}/systems`,
            code: ERROR_CODES.UNDEFINED_SYSTEM,
            message: `Coupling entry references nonexistent system "${systemName}"`,
            details: { system: systemName },
          })
        }
      }
    } else if (coupling.type === 'variable_map') {
      // Check from/to system references exist
      const vmEntry = coupling as CouplingVariableMap
      // `factor` is a scaling slot for the scaling string transforms only; an
      // Expression transform spells its own arithmetic, so a `factor` alongside
      // it is a modeling error.
      //
      // NOTE (kept, not deleted): this check is effectively UNREACHABLE through
      // the public `validate()` — the JSON schema already rejects the
      // `factor` + Expression-transform combination, and structural validation
      // runs only when `schema_errors.length === 0`. It is retained as a
      // defensive structural mirror of that schema rule (and would fire if
      // performStructuralValidation were ever driven on a schema-invalid file).
      if (
        vmEntry.factor !== undefined &&
        typeof vmEntry.transform === 'object' &&
        vmEntry.transform !== null
      ) {
        errors.push({
          path: `${couplingPath}/factor`,
          code: ERROR_CODES.FACTOR_WITH_EXPRESSION_TRANSFORM,
          message: `variable_map with an Expression transform must not carry 'factor'; fold the scaling into the expression`,
          details: { factor: vmEntry.factor },
        })
      }
      for (const field of ['from', 'to'] as const) {
        const ref = vmEntry[field]
        if (typeof ref === 'string' && ref.includes('.')) {
          const [systemName, varName] = splitScopedRef(ref)
          if (!availableSystems.has(systemName)) {
            errors.push({
              path: `${couplingPath}/${field}`,
              code: ERROR_CODES.UNRESOLVED_SCOPED_REF,
              message: `Scoped reference "${ref}" references nonexistent system "${systemName}"`,
              details: { reference: ref, system: systemName },
            })
          } else {
            // Check the variable exists in the model / reaction_system. Whether
            // a DATA LOADER exposes a variable is NOT resolved here — that is the
            // sole responsibility of `validateDataLoaderReferences` (which covers
            // both `from` and `to`). A loader-only head therefore leaves `system`
            // undefined and this branch emits nothing, deferring to that pass.
            const system =
              (esmFile.models || {})[systemName] || (esmFile.reaction_systems || {})[systemName]
            if (system) {
              const vars = (system as any).variables || (system as any).species || {}
              const params = (system as any).parameters || {}
              if (!vars[varName] && !params[varName]) {
                errors.push({
                  path: `${couplingPath}/${field}`,
                  code: ERROR_CODES.UNRESOLVED_SCOPED_REF,
                  message: `Variable "${varName}" not found in system "${systemName}"`,
                  details: { reference: ref, system: systemName, variable: varName },
                })
              }
            }
          }
        }
      }
    }
  }

  return errors
}

/**
 * Check for circular cross-model variable references (without explicit coupling)
 */
export function validateCircularReferences(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []
  if (!esmFile.models) return errors

  // Build dependency graph: which models reference which other models
  const modelDeps = new Map<string, Set<string>>()

  for (const [modelName, model] of Object.entries(esmFile.models)) {
    const deps = new Set<string>()
    // Check all equations for cross-model references (unresolved
    // SubsystemRef entries carry no equations)
    const equations = 'ref' in model ? [] : model.equations || []
    for (const equation of equations) {
      const refs = [
        ...extractVariableReferences(equation.lhs),
        ...extractVariableReferences(equation.rhs),
      ]
      for (const ref of refs) {
        if (ref.includes('.')) {
          const targetModel = ref.split('.')[0]
          if (targetModel !== modelName && esmFile.models[targetModel]) {
            deps.add(targetModel)
          }
        }
      }
    }
    modelDeps.set(modelName, deps)
  }

  // Detect cycles using DFS
  const visited = new Set<string>()
  const inStack = new Set<string>()

  // Returns void: the boolean was never read by any caller (cycles are
  // reported by pushing to `errors`, and recursion ignores the result).
  function dfs(node: string, path: string[]): void {
    if (inStack.has(node)) {
      const cycleStart = path.indexOf(node)
      const cycle = path.slice(cycleStart).concat(node)
      errors.push({
        path: '/models',
        message: `Circular dependency detected: ${cycle.join(' → ')}`,
        code: ERROR_CODES.CIRCULAR_DEPENDENCY,
        details: { cycle },
      })
      return
    }
    if (visited.has(node)) return

    visited.add(node)
    inStack.add(node)
    path.push(node)

    for (const dep of modelDeps.get(node) || []) {
      dfs(dep, [...path])
    }

    inStack.delete(node)
  }

  for (const modelName of modelDeps.keys()) {
    if (!visited.has(modelName)) {
      dfs(modelName, [])
    }
  }

  return errors
}

/**
 * Validate data-loader variable references in coupling entries.
 *
 * This pass is the SINGLE authority for whether a data-loader-exposed variable
 * resolves, covering BOTH endpoints of a `variable_map` (`from` AND `to`): a
 * scoped ref whose head names a data loader is checked here and only here,
 * always emitting `undefined_data_loader_variable`. `validateCouplingIntegrity`
 * deliberately does NOT resolve loader-headed refs (it keeps only model /
 * reaction_system membership handling), so the two passes no longer overlap —
 * even for a name collision (a head that resolves as both a model/reaction_system
 * AND a data loader): the loader-exposed-variable question is answered solely
 * here, while `validateCouplingIntegrity`'s model-membership check independently
 * governs the model side.
 */
export function validateDataLoaderReferences(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []
  if (!esmFile.coupling || !esmFile.data_loaders) return errors

  for (let i = 0; i < esmFile.coupling.length; i++) {
    const coupling = esmFile.coupling[i]
    const couplingPath = `/coupling/${i}`
    if (coupling.type !== 'variable_map') continue
    const vmEntry = coupling as CouplingVariableMap

    for (const field of ['from', 'to'] as const) {
      const ref = vmEntry[field]
      if (typeof ref !== 'string' || !ref.includes('.')) continue
      // Keep the FULL variable path after the source head — a 2-limit split
      // (`ref.split('.', 2)`) would truncate "Loader.a.b" to variable "a"
      // (a JS-vs-Go SplitN discrepancy). splitScopedRef mirrors Go's
      // strings.SplitN(ref, ".", 2) remainder semantics.
      const [sourceName, varName] = splitScopedRef(ref)
      // Only a data-loader head is this pass's concern.
      const loader = esmFile.data_loaders[sourceName]
      if (!loader) continue
      const loaderVariables = loader.variables || {}
      if (!(varName in loaderVariables)) {
        errors.push({
          path: `${couplingPath}/${field}`,
          message: `Data loader '${sourceName}' does not expose variable '${varName}'`,
          code: ERROR_CODES.UNDEFINED_DATA_LOADER_VARIABLE,
          details: {
            data_loader: sourceName,
            variable: varName,
            available: Object.keys(loaderVariables),
          },
        })
      }
    }
  }

  return errors
}

/**
 * Validate file_period and frequency fields in data loader temporal sections
 * are valid ISO 8601 durations
 */
export function validateTemporalResolution(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []
  if (!esmFile.data_loaders) return errors

  // ISO 8601 duration pattern: P[nY][nM][nD][T[nH][nM][nS]]
  const iso8601DurationPattern =
    /^P(?:\d+Y)?(?:\d+M)?(?:\d+D)?(?:T(?:\d+H)?(?:\d+M)?(?:\d+(?:\.\d+)?S)?)?$/
  const isValidDuration = (v: unknown): v is string =>
    typeof v === 'string' && v !== 'P' && v !== 'PT' && iso8601DurationPattern.test(v)

  const durationFields: Array<'file_period' | 'frequency'> = ['file_period', 'frequency']

  for (const [loaderName, loader] of Object.entries(esmFile.data_loaders)) {
    const temporal = loader.temporal
    if (!temporal || typeof temporal !== 'object') continue
    for (const field of durationFields) {
      const value = temporal[field]
      if (value !== undefined && !isValidDuration(value)) {
        errors.push({
          path: `/data_loaders/${loaderName}/temporal/${field}`,
          message: `Invalid ISO 8601 duration: '${value}'`,
          code: ERROR_CODES.INVALID_TEMPORAL_DURATION,
          details: { field, value },
        })
      }
    }
  }

  return errors
}
