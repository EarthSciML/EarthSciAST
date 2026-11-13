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
  CouplingEntry,
  CouplingImport,
} from '../types.js'
import type { StructuralError } from './types.js'
import {
  collectIndexSymbols,
  extractVariableReferences,
  isInlineModel,
  resolveScopedReference,
  scopedNameFrom,
  splitScopedRef,
} from './expr-utils.js'
import { isExpressionLike } from '../traverse.js'
import { collectRoleSegments, expandCouplingImports } from '../coupling-imports.js'
import { derivativeTarget } from '../classification.js'
import { observedDefinitionReads } from './observed-checks.js'
import { recurrenceGroups } from '../recurrence.js'
import {
  forEachParameterUpdate,
  hasUnmountedRefs,
  paramToVarTargets,
  recordShapeFindings,
} from '../records-per-sample.js'

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
      if ('ref' in system || !system.subsystems) continue
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
  // A data source is NOT a path root: from 1.0.0 it is not a component, so
  // `Source.field` names nothing resolvable (esm-spec 5.5).
  const root = (esmFile.models || {})[head] ?? (esmFile.reaction_systems || {})[head]
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
 * Resolve a coupling library's role-scoped refs against its declared
 * `coupling_roles`. esm-spec §10.9 suspends ordinary §4.6 system resolution for a
 * library validated on its own and requires the top-level segment at every
 * §10.10.2 occurrence site to name a declared role instead. Sharing
 * {@link collectRoleSegments} with the import-time check is what keeps the two
 * sites naming the same set of sites.
 */
function validateCouplingRoleRefs(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []
  const roles = new Set(Object.keys(esmFile.coupling_roles || {}))
  const entries = esmFile.coupling || []
  for (let i = 0; i < entries.length; i++) {
    const unknown = [...collectRoleSegments(entries[i])].filter((seg) => !roles.has(seg)).sort()
    for (const role of unknown) {
      errors.push({
        path: `/coupling/${i}`,
        code: ERROR_CODES.COUPLING_EDGE_UNKNOWN_ROLE,
        message: `edge references "${role}", which is not a declared role (esm-spec §10.9: a coupling library's refs name a role in \`coupling_roles\`)`,
        details: { role, expected_in: 'coupling_roles' },
      })
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

  // In a coupling-library file (esm-spec §10.9) every endpoint prefix names a
  // declared ROLE, not a system, and the library holds no models by definition —
  // resolving them against the model/reaction-system key set would reject every
  // well-formed library. `coupling_roles` is the sole positive identifier of the
  // kind.
  if (esmFile.coupling_roles) return validateCouplingRoleRefs(esmFile)

  // Collect all available systems
  // Data sources are deliberately absent: a source cannot be a coupling
  // endpoint from 1.0.0, so naming one here is an `undefined_system`.
  const availableSystems = new Set([
    ...Object.keys(esmFile.models || {}),
    ...Object.keys(esmFile.reaction_systems || {}),
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
            // There is no data-source carve-out any more: a source is not a
            // coupling endpoint, so every head reaching here is a model or a
            // reaction system and resolves (or fails) on its own terms.
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

  errors.push(...validateImportedCouplingEdges(esmFile))
  return errors
}

/**
 * The component a `bind` points a role at for `reference`, and the role(s) that
 * point there. A bind value may be a dotted subsystem path (`Parent.Child`,
 * esm-spec §10.10.1), so the LONGEST bound component that prefixes the
 * reference wins; a reference no bind covers falls back to its own head segment.
 */
function boundComponentFor(
  bind: Record<string, string> | undefined,
  reference: string,
): { component: string; role: string } {
  let component = ''
  for (const bound of Object.values(bind ?? {})) {
    if (reference !== bound && !reference.startsWith(`${bound}.`)) continue
    if (bound.length > component.length) component = bound
  }
  if (component === '') component = reference.split('.')[0] ?? reference
  const role = Object.entries(bind ?? {})
    .filter(([, bound]) => bound === component)
    .map(([r]) => r)
    .sort()
    .join(', ')
  return { component, role }
}

/**
 * Validate the edges each `coupling_import` expands to (esm-spec §10.10.3).
 *
 * The loop above walks the SOURCE `coupling` array, where an import is still
 * `{ type, ref, bind }` and its edges do not exist, so a mis-bind — a
 * structurally complete `bind` that points a role at a component lacking a
 * variable the library references — passed `validate` and surfaced only at
 * flatten. Each import is expanded on its own, against the base the loader
 * recorded for the document, and its edges go through the same checks as a
 * hand-authored edge; a finding is re-pointed at the import entry and names the
 * library, the role and the bound component. An import that cannot be expanded
 * at all is left to flatten, which owns those §10.11 diagnostics.
 */
function validateImportedCouplingEdges(esmFile: EsmFile): StructuralError[] {
  const findings: StructuralError[] = []
  // Expanding an import reads its library from disk; without the base the
  // loader recorded on the document, the ref would resolve against the working
  // directory, so a document with no known location is left to flatten.
  const base = esmFile.couplingImportBase
  if (base === undefined) return findings
  const coupling = esmFile.coupling ?? []
  for (let i = 0; i < coupling.length; i++) {
    const entry = coupling[i]
    if (entry.type !== 'coupling_import') continue
    const imp = entry as CouplingImport
    const single = { ...esmFile, coupling: [entry] } as EsmFile
    Object.defineProperty(single, 'couplingImportBase', {
      value: base,
      enumerable: false,
      writable: true,
      configurable: true,
    })
    let edges: CouplingEntry[] | undefined
    try {
      edges = expandCouplingImports(single)
    } catch {
      continue
    }
    if (!edges || edges.length === 0) continue
    for (const e of validateCouplingIntegrity({ ...esmFile, coupling: edges } as EsmFile)) {
      if (e.code !== ERROR_CODES.UNRESOLVED_SCOPED_REF) continue
      const details = (e.details ?? {}) as Record<string, unknown>
      const reference = typeof details.reference === 'string' ? details.reference : ''
      const { component, role } = boundComponentFor(imp.bind, reference)
      findings.push({
        ...e,
        path: `/coupling/${i}`,
        message: `coupling_import '${imp.ref}' binds role '${role}' to '${component}', which does not provide '${reference}' referenced by the library: ${e.message}`,
        details: { ...details, coupling_import: imp.ref, role, bound_component: component },
      })
    }
  }
  return findings
}

/** One observed unknown's definition, as {@link documentObservedReads} records it. */
export interface ObservedReads {
  /** Scoped name of the model or subsystem that defines it (`ModelN.Sub`). */
  scope: string
  /** That model or subsystem, the enclosing scope its references resolve in. */
  model: Model
  /** The free references its defining RHS makes, as written. */
  refs: Set<string>
}

/**
 * The nodes of the esm-spec §4.9.7 graph with their unresolved reads, keyed by
 * full scoped name, plus each component's recurrence groups in scoped names.
 *
 * A node is an observed unknown (§6.3.1) of an inline model or subsystem at any
 * depth, unless some equation of the document puts it under `D(·, t)` through
 * its scoped name, which makes it a state of the coupled system. References
 * resolve through {@link scopedNameFrom}. Shared by the `circular_dependency`
 * graph and the variable-bound circularity rule (esm-spec §6.3.2 rule 3), so
 * the two walk the same definitions.
 */
export function documentObservedReads(esmFile: EsmFile): {
  reads: Map<string, ObservedReads>
  groupsByScope: string[][]
} {
  const reads = new Map<string, ObservedReads>()
  const groupsByScope: string[][] = []
  const derivativeStates = new Set<string>()

  const walk = (scope: string, model: Model): void => {
    for (const eq of model.equations ?? []) {
      const target = derivativeTarget(eq.lhs)
      if (target === undefined || !target.includes('.')) continue
      const state = scopedNameFrom(target, scope, model, esmFile)
      if (state !== undefined) derivativeStates.add(state)
    }
    for (const [name, refs] of observedDefinitionReads(model, esmFile)) {
      reads.set(`${scope}.${name}`, { scope, model, refs })
    }
    for (const g of recurrenceGroups(model, esmFile)) {
      groupsByScope.push([...g].map((n) => `${scope}.${n}`))
    }
    for (const [subName, sub] of Object.entries(model.subsystems ?? {})) {
      if (isInlineModel(sub)) walk(`${scope}.${subName}`, sub)
    }
  }
  for (const [name, model] of Object.entries(esmFile.models ?? {})) {
    if (isInlineModel(model)) walk(name, model)
  }

  for (const state of derivativeStates) reads.delete(state)
  return { reads, groupsByScope }
}

/**
 * The document-wide observed dependency graph of esm-spec §4.9.7, as a SORTED
 * adjacency map keyed by full scoped name (`ModelA.a`, `ModelN.Sub.c`).
 *
 * Nodes are the OBSERVED unknowns (§6.3.1, `observedUnknowns`) of every
 * inline model and subsystem at every depth, minus any unknown some equation
 * of the document puts under `D(·, t)` through its scoped name (that makes it
 * a state of the coupled system). States, parameters, algebraic unknowns,
 * unknowns with no equation and unresolved names are not nodes, so a read of
 * one is not an edge.
 *
 * Edges come from {@link observedDefinitionReads}, the same walk the
 * per-model `observed_cycle` graph uses. A reference, in an observed's
 * definition or under a `D`, resolves with the reference-integrity precedence
 * (esm-spec §4.8.4, "A scoped reference carries its target's units"): the
 * reading component's own names, then a path relative to its own subsystems,
 * then a top-level system path (§4.6). That is {@link scopedNameFrom}.
 *
 * A `{ref}` subsystem that reaches `validate` is unresolved (the synchronous
 * validator does no file I/O); it carries no equations, contributes no nodes,
 * and is reported on its own as `unresolved_subsystem_ref`.
 */
function crossScopeObservedGraph(esmFile: EsmFile): Map<string, string[]> {
  const { reads, groupsByScope } = documentObservedReads(esmFile)
  const resolve = (ref: string, scope: string, model: Model): string | undefined =>
    scopedNameFrom(ref, scope, model, esmFile)

  const sets = new Map<string, Set<string>>()
  for (const [node, { scope, model, refs }] of reads) {
    const successors = new Set<string>()
    for (const ref of refs) {
      const target = resolve(ref, scope, model)
      if (target !== undefined && reads.has(target)) successors.add(target)
    }
    sets.set(node, successors)
  }
  // esm-spec §4.3.1.2: a recurrence group is swept as ONE unit, so here it is
  // one node — its first member — carrying every member's external reads.
  // CONTRACTED rather than stripped of its internal edges: a cycle that leaves
  // the group through another scope and comes back (`a ->(group) b -> X.c -> a`)
  // is a real cycle, and dropping `a -> b` would hide it.
  for (const g of groupsByScope) {
    const members = g.filter((n) => sets.has(n)).sort()
    if (members.length === 0) continue
    const rep = members[0]
    const merged = new Set<string>()
    for (const m of members) {
      for (const s of sets.get(m) ?? []) merged.add(s)
      sets.delete(m)
    }
    for (const m of members) merged.delete(m)
    sets.set(rep, merged)
    for (const [n, succ] of sets) {
      if (![...succ].some((x) => members.includes(x))) continue
      const kept = new Set([...succ].filter((x) => !members.includes(x)))
      if (n !== rep) kept.add(rep)
      sets.set(n, kept)
    }
  }
  const graph = new Map<string, string[]>()
  for (const [node, succ] of sets) graph.set(node, [...succ].sort())
  return graph
}

/** The model or subsystem a scoped name lives in: everything before its last dot. */
function scopeOf(scopedName: string): string {
  return scopedName.slice(0, scopedName.lastIndexOf('.'))
}

/**
 * `circular_dependency` (esm-spec §4.9.7): a cycle among OBSERVED unknowns that
 * crosses a scope boundary (two top-level models, or a model and one of its
 * subsystems). A state's or a parameter's value is known at every
 * right-hand-side evaluation, so reading it orders nothing; only an observed's
 * definition can.
 *
 * The traversal is pinned so every binding names the same cycle: a DFS with
 * roots in lexicographic order of scoped name and successors in lexicographic
 * order; the first back edge `V -> W` closes the cycle `W ... V W` along the
 * search path. A back edge whose cycle lies in one scope is that scope's
 * `observed_cycle` (reported by {@link validateObservedCycles}), so it is
 * skipped and the search continues. One finding per document, at `/models`
 * (the smallest node containing the whole cycle).
 *
 * Iterative for the same reason `validateObservedCycles` is: the depth is the
 * length of the longest observed chain, a property of the document.
 */
export function validateCircularReferences(esmFile: EsmFile): StructuralError[] {
  if (!esmFile.models) return []
  const graph = crossScopeObservedGraph(esmFile)

  const ON_CHAIN = 1
  const FINISHED = 2
  const state = new Map<string, number>()

  const firstCycleFrom = (root: string): string[] | undefined => {
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
        const cycle = [...chain.slice(chain.indexOf(successor)), successor]
        const scope = scopeOf(cycle[0])
        if (cycle.some((n) => scopeOf(n) !== scope)) return cycle
        continue
      }
      if (seen === FINISHED) continue
      state.set(successor, ON_CHAIN)
      chain.push(successor)
      cursor.push(0)
    }
    return undefined
  }

  for (const root of [...graph.keys()].sort()) {
    if (state.get(root) !== undefined) continue
    const cycle = firstCycleFrom(root)
    if (cycle === undefined) continue
    return [
      {
        path: '/models',
        message: `Circular dependency among observeds: ${cycle.join(' → ')}`,
        code: ERROR_CODES.CIRCULAR_DEPENDENCY,
        details: { cycle },
      },
    ]
  }
  return []
}

/**
 * `data_source_undefined` - a parameter's `update.source` names no entry in the
 * document's top-level `data_sources` (esm-spec 5.5).
 *
 * This REPLACES the 0.x `validateDataLoaderReferences`, which asked whether a
 * coupling endpoint `Loader.field` named a variable the loader exposed. From
 * 1.0.0 a data source is not a coupling endpoint and exposes no variables, so
 * that question cannot be asked. `update.source` is the only way to name a
 * source, and being an ordinary string it is schema-valid by construction and
 * therefore genuinely reaches structural validation.
 */
export function validateDataSourceReferences(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []
  const available = Object.keys(esmFile.data_sources ?? {})
  const declared = new Set(available)

  for (const { variableName, rule, path } of forEachParameterUpdate(esmFile)) {
    if (rule.kind !== 'data') continue
    if (declared.has(rule.source)) continue
    errors.push({
      path,
      code: ERROR_CODES.DATA_SOURCE_UNDEFINED,
      message: `Parameter update names data source '${rule.source}', which the document does not declare`,
      details: {
        variable: variableName,
        source: rule.source,
        available_sources: available,
      },
    })
  }
  return errors
}

/**
 * Record axes (esm-spec §8.5.1). `record_axis_invalid` at `/index_sets/<name>`
 * for a record axis whose folded `size` is not 2 (a still-symbolic size is
 * skipped). Then, on every `update` rule at any depth, of models and of
 * reaction systems: the deprecated `from.records_per_sample` on a rule that is
 * not `data` (`records_per_sample_invalid`), and for a data-fed rule the record-shape
 * rules `record_axis_misplaced`, `record_axis_time_invariant_source` and the
 * written value's agreement (`records_per_sample_invalid`), judged by
 * {@link recordShapeFindings} against the inline `coupling`. A target this
 * document cannot reach is left to `flatten`, and so is an empty record shape
 * when a `coupling_import` may supply the edge.
 */
export function validateRecordsPerSample(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []
  for (const [name, set] of Object.entries(esmFile.index_sets ?? {})) {
    const { records, size } = set as { records?: unknown; size?: unknown }
    if (records !== true || typeof size !== 'number' || size === 2) continue
    errors.push({
      path: `/index_sets/${name}`,
      code: ERROR_CODES.RECORD_AXIS_INVALID,
      message: `Index set '${name}' is a record axis ("records": true), so its size must be 2; it is ${size}`,
      details: { index_set: name, size },
    })
  }
  const coupling = (esmFile.coupling ?? []) as Array<Record<string, unknown>>
  const targets = paramToVarTargets(coupling)
  const hasImport = coupling.some((entry) => entry?.type === 'coupling_import')
  const unmountedRefs = hasUnmountedRefs(esmFile)
  for (const site of forEachParameterUpdate(esmFile, { reactionSystems: true })) {
    const { variableName, rule, path } = site
    if (rule.kind !== 'data') {
      const binding = (rule as { from?: { records_per_sample?: number } }).from
      if (binding?.records_per_sample !== undefined) {
        errors.push({
          path,
          code: ERROR_CODES.RECORDS_PER_SAMPLE_INVALID,
          message: `Parameter '${variableName}' sets from.records_per_sample on a '${rule.kind}' rule; only a 'data' rule names a source to read records from`,
          details: { variable: variableName, kind: rule.kind },
        })
      }
      continue
    }
    for (const finding of recordShapeFindings(esmFile, site, targets, {
      targetsMayArriveLater: hasImport,
      unmountedRefs,
    })) {
      errors.push({ path, ...finding })
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
 * Validate `file_period` and `frequency` in a data SOURCE's temporal section
 * are valid ISO 8601 durations. Only the enclosing block was renamed by 1.0.0;
 * the rule is unchanged.
 */
export function validateTemporalResolution(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []
  if (!esmFile.data_sources) return errors

  // ISO 8601 duration pattern: P[nY][nM][nD][T[nH][nM][nS]]
  const iso8601DurationPattern =
    /^P(?:\d+Y)?(?:\d+M)?(?:\d+D)?(?:T(?:\d+H)?(?:\d+M)?(?:\d+(?:\.\d+)?S)?)?$/
  const isValidDuration = (v: unknown): v is string =>
    typeof v === 'string' && v !== 'P' && v !== 'PT' && iso8601DurationPattern.test(v)

  const durationFields: Array<'file_period' | 'frequency'> = ['file_period', 'frequency']

  for (const [sourceName, source] of Object.entries(esmFile.data_sources)) {
    const temporal = source.temporal
    if (!temporal || typeof temporal !== 'object') continue
    for (const field of durationFields) {
      const value = temporal[field]
      if (value !== undefined && !isValidDuration(value)) {
        errors.push({
          path: `/data_sources/${sourceName}/temporal/${field}`,
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
 * Every name declared anywhere in the document: each model's `variables` and
 * each reaction system's `species` / `parameters`.
 *
 * This is the scope a `unit_conversion` resolves against. The conversion may
 * scale a loaded field by a model's declared parameter, so the CONSUMING
 * model's own scope would still be too narrow for a document-wide answer.
 * (`tests/invalid/undefined_variable_in_unit_conversion.esm` states this
 * explicitly: "`y` and `k` are declared; the ONLY defect is the undefined name
 * `undefined_xyz`".)
 */
export function documentDeclaredNames(esmFile: EsmFile): Set<string> {
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
  // A data SOURCE contributes no names: from 1.0.0 it declares no variables of
  // its own. The parameter that reads it is a model variable and is already
  // counted above.
  return names
}

/**
 * (h) site 9 - reference integrity for a `unit_conversion` expression
 * (esm-spec 8.5 / 4.9.5).
 *
 * `unit_conversion` is a full Expression AST (a plain number is one), and its
 * free names must resolve. In 0.x it lived on a loader variable; from 1.0.0 it
 * lives on the CONSUMING parameter's `update.from` binding, since the parameter
 * IS the loaded field and owns the units.
 */
export function validateDataSourceExpressions(esmFile: EsmFile): StructuralError[] {
  const errors: StructuralError[] = []

  const declared = documentDeclaredNames(esmFile)
  const declaredIndexSets = new Set(Object.keys(esmFile.index_sets || {}))

  for (const { rule, path: updatePath } of forEachParameterUpdate(esmFile)) {
    if (rule.kind === 'wiener') continue
    const conversion = rule.from?.unit_conversion
    // The numeric-factor spelling carries no references.
    if (!isExpressionLike(conversion) || typeof conversion === 'number') continue
    const path = `${updatePath}/from/unit_conversion`
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
