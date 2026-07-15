/**
 * File-level structural validators: unresolved subsystem refs, coupling-entry
 * reference integrity, circular cross-model references, data-loader variable
 * references in coupling, and data-loader temporal-resolution durations.
 */

import { ERROR_CODES } from '../errors.js'
import type {
  EsmFile,
  Model,
  ReactionSystem,
  Expression,
  CouplingOperatorCompose,
  CouplingCouple,
  CouplingVariableMap,
  SubsystemRef,
} from '../types.js'
import type { StructuralError } from './types.js'
import {
  collectIndexSymbols,
  extractVariableReferences,
  resolveScopedReference,
  splitScopedRef,
} from './expr-utils.js'
import { isExpressionLike } from '../traverse.js'

/**
 * Flag any `{ref}` (unresolved SubsystemRef) entries in one component's
 * `subsystems` map. Shared by the models and reaction-systems passes, which
 * differ only in the JSON path prefix and the parent component's name.
 *
 * The code is `unresolved_subsystem_ref` — the canonical, cross-binding name for
 * a subsystem reference that does not resolve (pinned by
 * `tests/invalid/expected_errors.json` on `subsystem_ref_not_found.esm`). The
 * synchronous `validate()` does NO file I/O, so a `{ref}` that reaches it is by
 * construction unresolved; call `resolveSubsystemRefs()` first to inline it.
 *
 * The sibling code `ambiguous_subsystem_ref` (a ref that resolves to a file
 * holding MORE than one top-level system) is raised by the resolver in
 * `ref-loading.ts`, which is the only layer that reads the referenced file and
 * can therefore tell the two apart.
 */
function flagRefSubsystems(
  subsystems: Record<string, unknown>,
  pathPrefix: string,
  parentName: string,
): StructuralError[] {
  const errors: StructuralError[] = []
  for (const [subsystemName, subsystem] of Object.entries(subsystems)) {
    if (subsystem && typeof subsystem === 'object' && 'ref' in subsystem) {
      const ref = (subsystem as SubsystemRef).ref
      if (typeof ref === 'string') {
        errors.push({
          path: `${pathPrefix}/${subsystemName}`,
          code: ERROR_CODES.UNRESOLVED_SUBSYSTEM_REF,
          message: `Subsystem reference '${ref}' could not be resolved — file does not exist`,
          details: { ref, subsystem: subsystemName, parent_model: parentName },
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
      errors.push(
        ...flagRefSubsystems(model.subsystems, `/models/${modelName}/subsystems`, modelName),
      )
    }
  }
  if (esmFile.reaction_systems) {
    for (const [systemName, system] of Object.entries(esmFile.reaction_systems)) {
      if (!system.subsystems) continue
      errors.push(
        ...flagRefSubsystems(
          system.subsystems,
          `/reaction_systems/${systemName}/subsystems`,
          systemName,
        ),
      )
    }
  }
  return errors
}

/**
 * Does `ref` name a system — at ARBITRARY DEPTH?
 *
 * A coupling `systems` entry may name a top-level component (`Atmosphere`) or a
 * SUBSYSTEM of one, by its dotted path (`AtmosphericChemistry.Aerosols`,
 * `EmissionSources.Biogenic.Forest` — both from
 * `tests/valid/scoped_refs_coupling.esm`). Scoped references are arbitrary-depth
 * (spec §4.6), so membership is decided by NAVIGATING the `subsystems` chain,
 * not by testing the whole dotted string against the top-level key set — which
 * is what made every subsystem-scoped `couple` entry an `undefined_system`.
 */
function systemPathExists(ref: string, esmFile: EsmFile): boolean {
  const [head, rest] = splitScopedRef(ref)
  const root =
    (esmFile.models || {})[head] ??
    (esmFile.reaction_systems || {})[head] ??
    (esmFile.data_loaders || {})[head]
  if (!root) return false
  if (rest === '') return true

  let current: unknown = root
  for (const segment of rest.split('.')) {
    const subsystems =
      current && typeof current === 'object'
        ? (current as { subsystems?: Record<string, unknown> }).subsystems
        : undefined
    if (!subsystems || !(segment in subsystems)) return false
    current = subsystems[segment]
  }
  return true
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
      // An entry may name a subsystem at arbitrary depth — see
      // {@link systemPathExists}.
      const systemsEntry = coupling as CouplingOperatorCompose | CouplingCouple
      for (const systemName of systemsEntry.systems) {
        if (!systemPathExists(systemName, esmFile)) {
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
          const [systemName, variablePath] = splitScopedRef(ref)
          if (!availableSystems.has(systemName)) {
            // A `variable_map` whose `from`/`to` names a system that does not
            // exist. NOTE — the shared corpus currently pins this ONE defect two
            // incompatible ways, and no implementation can satisfy both:
            //
            //   undefined_system.esm                  from: "NonExistentSystem.temperature"
            //     -> undefined_system      @ /coupling/0
            //   unresolved_scoped_ref.esm             from: "NonExistentSystem.T"
            //     -> unresolved_scoped_ref @ /coupling/0/from
            //   unresolved_scoped_ref_missing_system.esm
            //                       from: "NonExistentModel.MissingSubsystem.temperature"
            //     -> unresolved_scoped_ref @ /coupling/0/from
            //
            // Same shape, same stated intent ("coupling references nonexistent
            // system"), different pins. We emit the code that two of the three
            // agree on and have reported the contradiction upstream; when the
            // corpus settles on one spelling, this branch follows it.
            errors.push({
              path: `${couplingPath}/${field}`,
              code: ERROR_CODES.UNRESOLVED_SCOPED_REF,
              message: `Scoped reference "${ref}" references nonexistent system "${systemName}"`,
              details: { reference: ref, system: systemName },
            })
          } else if (
            (esmFile.models || {})[systemName] ||
            (esmFile.reaction_systems || {})[systemName]
          ) {
            // Resolve the variable at ARBITRARY DEPTH (spec §4.6):
            // `Meteorology.Temperature.surface_temp` names `surface_temp` inside
            // the `Temperature` SUBSYSTEM of the `Meteorology` model. The old
            // code took the whole remainder as a flat variable name and looked
            // up `variables["Temperature.surface_temp"]`, which of course missed
            // — reporting a valid, pinned fixture as an unresolved scoped ref.
            // `resolveScopedReference` walks the `subsystems` chain and then
            // checks `variables` / `species` / `parameters`.
            //
            // Whether a DATA LOADER exposes a variable is NOT resolved here —
            // that is the sole responsibility of `validateDataLoaderReferences`
            // (which covers both `from` and `to`), so a loader-only head falls
            // through this branch entirely.
            if (!resolveScopedReference(ref, esmFile)) {
              const variableName = variablePath.split('.').pop() ?? variablePath
              errors.push({
                path: `${couplingPath}/${field}`,
                code: ERROR_CODES.UNRESOLVED_SCOPED_REF,
                message: `Variable "${variableName}" not found in system "${systemName}"`,
                details: {
                  reference: ref,
                  system: systemName,
                  variable: variableName,
                },
              })
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
        // A dependency cycle is carried by no single model, so it is pinned at
        // the smallest node that CONTAINS the whole cycle — the `/models`
        // container — rather than at any one member model
        // (CONFORMANCE_SPEC §7.1.2; `circular_coupling.esm` → `/models`). The
        // concrete cycle is still surfaced in the message and `details.cycle`
        // for whoever has to fix it.
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
 * The declared units of a dot-qualified variable (`SystemA.temperature`,
 * `Meteorology.Temperature.surface_temp`), or undefined when the variable is
 * missing or carries no declared units. Navigates model subsystems and looks a
 * reaction system's species / parameters up by key. Mirrors the Python /
 * Julia `_lookup_variable_units` used by the flatten-time §4.7.6 preflight.
 */
function lookupVariableUnits(esmFile: EsmFile, qualified: string): string | undefined {
  const parts = qualified.split('.')
  if (parts.length < 2) return undefined
  const [head, ...tail] = parts

  const model = esmFile.models?.[head]
  if (model && !('ref' in model) && !('kind' in model)) {
    let current: Model = model as Model
    for (const segment of tail.slice(0, -1)) {
      const sub = current.subsystems?.[segment]
      if (!sub || 'ref' in sub || 'kind' in sub) return undefined
      current = sub as Model
    }
    return current.variables?.[tail[tail.length - 1]]?.units
  }

  const rs = esmFile.reaction_systems?.[head]
  if (rs && !('ref' in rs)) {
    let current: ReactionSystem = rs as ReactionSystem
    for (const segment of tail.slice(0, -1)) {
      const sub = current.subsystems?.[segment]
      if (!sub || 'ref' in sub) return undefined
      current = sub as ReactionSystem
    }
    const name = tail[tail.length - 1]
    return current.species?.[name]?.units ?? current.parameters?.[name]?.units
  }

  return undefined
}

/**
 * (F-6) `domain_unit_mismatch` — reject an `identity`-transform `variable_map`
 * coupling whose `from` and `to` variables carry declared units that are both
 * present, non-empty, and DIFFERENT (esm-spec §4.7.6). An identity map asserts
 * the two domains are the same quantity in the same units; `K` on one side and
 * `degC` on the other is a modelling error the flatten-time preflight in the
 * evaluating bindings (Julia/Python/Rust `_check_variable_map_units`) already
 * catches — this lifts that check into `validate()`.
 *
 * Comparison is by unit STRING, not dimension: `K` and `degC` share the
 * temperature dimension yet are not interchangeable under identity. Matching or
 * absent units are legal (positive control:
 * `tests/valid/coupling_variable_map_identity_units_match.esm`). `param_to_var`
 * and `conversion_factor` transforms are EXEMPT (an Expression transform is not
 * `"identity"` either, so it is skipped).
 */
export function validateCouplingDomainUnits(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []
  if (!esmFile.coupling) return errors

  for (let i = 0; i < esmFile.coupling.length; i++) {
    const entry = esmFile.coupling[i]
    if (entry.type !== 'variable_map') continue
    const vm = entry as CouplingVariableMap
    if (vm.transform !== 'identity') continue
    if (typeof vm.from !== 'string' || typeof vm.to !== 'string') continue

    const fromUnits = lookupVariableUnits(esmFile, vm.from)
    const toUnits = lookupVariableUnits(esmFile, vm.to)
    // Absent or empty on either side ⇒ nothing to prove; equal ⇒ fine.
    if (!fromUnits || !toUnits || fromUnits === toUnits) continue

    errors.push({
      path: `/coupling/${i}`,
      code: ERROR_CODES.DOMAIN_UNIT_MISMATCH,
      message: `identity variable_map couples "${vm.from}" (units "${fromUnits}") to "${vm.to}" (units "${toUnits}"); an identity mapping requires matching units`,
      details: { from: vm.from, to: vm.to, from_units: fromUnits, to_units: toUnits },
    })
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

/**
 * Every name declared anywhere in the document: each model's `variables`, each
 * reaction system's `species` / `parameters`, and each data loader's `variables`.
 *
 * This is the scope a DATA LOADER's `unit_conversion` resolves against. A loader
 * is pure I/O with no equations of its own, and its conversion expression may
 * scale a loaded field by a model's declared parameter — so the loader's own
 * variable map is too narrow a scope. (`tests/invalid/undefined_variable_in_unit_conversion.esm`
 * states this explicitly: "`y` and `k` are declared; the ONLY defect is the
 * undefined name `undefined_xyz`", where `y`/`k` belong to a MODEL.)
 */
function documentDeclaredNames(esmFile: EsmFile): Set<string> {
  const names = new Set<string>()
  for (const model of Object.values(esmFile.models ?? {})) {
    if ('ref' in model) continue
    for (const name of Object.keys((model as { variables?: object }).variables ?? {})) {
      names.add(name)
    }
  }
  for (const system of Object.values(esmFile.reaction_systems ?? {})) {
    for (const name of Object.keys((system as { species?: object }).species ?? {})) names.add(name)
    for (const name of Object.keys((system as { parameters?: object }).parameters ?? {})) {
      names.add(name)
    }
  }
  for (const loader of Object.values(esmFile.data_loaders ?? {})) {
    for (const name of Object.keys(loader.variables ?? {})) names.add(name)
  }
  return names
}

/**
 * (h) site 9 — reference integrity for a data loader's `unit_conversion`
 * expression (spec §8.5 / §4.9.5).
 *
 * `unit_conversion` is `oneOf` a plain numeric factor or a full Expression AST.
 * The Expression form was never reference-checked, so an undefined name in it
 * was invisible.
 */
export function validateDataLoaderExpressions(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []
  if (!esmFile.data_loaders) return errors

  const declared = documentDeclaredNames(esmFile)
  const declaredIndexSets = new Set(Object.keys(esmFile.index_sets || {}))

  for (const [loaderName, loader] of Object.entries(esmFile.data_loaders)) {
    for (const [varName, variable] of Object.entries(loader.variables ?? {})) {
      const conversion = (variable as { unit_conversion?: unknown }).unit_conversion
      // The numeric-factor alternative carries no references.
      if (!isExpressionLike(conversion) || typeof conversion === 'number') continue
      const path = `/data_loaders/${loaderName}/variables/${varName}/unit_conversion`
      const bound = collectIndexSymbols(conversion as Expression)
      for (const ref of extractVariableReferences(conversion as Expression)) {
        if (ref.includes('.')) {
          if (!resolveScopedReference(ref, esmFile)) {
            errors.push({
              path,
              code: ERROR_CODES.UNRESOLVED_SCOPED_REF,
              message: `Variable "${ref}" referenced in unit_conversion expression does not resolve`,
              details: { variable: ref },
            })
          }
        } else if (!declared.has(ref) && !declaredIndexSets.has(ref) && !bound.has(ref)) {
          errors.push({
            path,
            code: ERROR_CODES.UNDEFINED_VARIABLE,
            message: `Variable "${ref}" referenced in unit_conversion expression but not declared`,
            details: { variable: ref },
          })
        }
      }
    }
  }
  return errors
}

/**
 * (h) sites 10 & 11 — reference integrity for the two EXPRESSION positions a
 * coupling entry carries: a `variable_map`'s Expression `transform`, and a
 * `couple`'s `connector.equations[j].expression`.
 *
 * In COUPLING context every reference is FULLY QUALIFIED (spec §4.6): a coupling
 * entry sits outside any component, so there is no local scope for a bare name to
 * mean anything in. A bare name is therefore unresolvable, and a dotted name that
 * names nothing is too — both are `unresolved_scoped_ref` (the same code
 * `bare_reference_errors.esm` already pins for bare refs in coupling).
 *
 * Neither position was reference-checked: an Expression transform and a connector
 * equation could name any variable at all, in any system, and nothing looked.
 */
export function validateCouplingExpressions(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []
  if (!esmFile.coupling) return errors

  const check = (expr: unknown, path: string, context: string): void => {
    if (!isExpressionLike(expr)) return
    const bound = collectIndexSymbols(expr as Expression)
    for (const ref of extractVariableReferences(expr as Expression)) {
      if (bound.has(ref)) continue
      // Fully-qualified or not, it must RESOLVE. A bare name never can.
      if (!resolveScopedReference(ref, esmFile)) {
        errors.push({
          path,
          code: ERROR_CODES.UNRESOLVED_SCOPED_REF,
          message: `Variable "${ref}" referenced in ${context} does not resolve`,
          details: { reference: ref },
        })
      }
    }
  }

  esmFile.coupling.forEach((coupling, i) => {
    const base = `/coupling/${i}`

    // A `variable_map` transform is either a named string transform or an
    // Expression; only the Expression form carries references.
    const transform = (coupling as { transform?: unknown }).transform
    if (typeof transform !== 'string') {
      check(transform, `${base}/transform`, 'variable_map Expression transform')
    }

    // A `couple` connector's equations each carry an optional Expression.
    const connector = (coupling as { connector?: { equations?: unknown[] } }).connector
    ;(connector?.equations ?? []).forEach((equation, j) => {
      const expression = (equation as { expression?: unknown })?.expression
      check(
        expression,
        `${base}/connector/equations/${j}/expression`,
        'connector equation expression',
      )
    })
  })

  return errors
}
